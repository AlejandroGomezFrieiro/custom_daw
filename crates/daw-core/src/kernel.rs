//! The kernel: one thread that owns the session and the Lua state and takes
//! turns handling input, RPC calls and timers.
//!
//! Almost everything a user sees is Lua. The kernel only calls a handful of
//! entry points in `daw._kernel` (`key`, `mouse`, `settle`, `render`, `rpc`, …)
//! and exposes `daw.api` for Lua to call back into.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow};
use daw_engine::backend::BackendOptions;
use daw_engine::{EventKind, Registry};
use include_dir::{Dir, include_dir};
use mlua::{FromLuaMulti, Function, IntoLuaMulti, Lua, LuaSerdeExt, Table, Value as LuaValue};
use serde_json::Value;

use crate::api::{self, Env, Shared};
use crate::grid::{Color, Grid, Highlights, Style};
use crate::remote::{self, RemoteFrontend};
use crate::rpc::{ClientId, Clients};
use crate::session::Session;
use crate::watchdog::Watchdog;

/// How often plugins get their turn on the main thread. Their editors are
/// drawn from here, so this is also their frame rate.
const IDLE_PERIOD: Duration = Duration::from_millis(16);

static RUNTIME: Dir = include_dir!("$CARGO_MANIFEST_DIR/../../runtime/lua");

#[derive(Clone, Debug)]
pub enum InputEvent {
    /// A key in Neovim notation: `a`, `<C-s>`, `<Space>`, `<S-Tab>`.
    Key(String),
    Mouse {
        kind: String,
        button: String,
        x: u16,
        y: u16,
        mods: String,
    },
    Resize(u16, u16),
    Paste(String),
}

pub enum KernelMsg {
    Input(InputEvent),
    /// A message that arrived at a MIDI port.
    Midi(u32, EventKind),
    Rpc {
        /// The connection the call came over, or 0 for none.
        client: ClientId,
        method: String,
        params: Value,
        reply: Sender<Result<Value, String>>,
    },
    /// A connection closed: whatever it had asked to be sent stops.
    Gone(ClientId),
}

/// Something that shows the grid to a person.
pub trait Frontend {
    fn present(&mut self, grid: &Grid, cursor: Option<(u16, u16)>) -> Result<()>;
}

pub struct KernelOpts {
    pub backend: BackendOptions,
    /// Every kind of device that can be created: the built-in ones and plugins.
    pub registry: Registry,
    pub config_dir: PathBuf,
    pub runtime_dir: Option<PathBuf>,
    pub clean: bool,
    /// Running a script (`-l`), not a session somebody works in.
    pub scripted: bool,
    pub argv: Vec<String>,
}

pub struct Kernel {
    shared: Rc<Shared>,
    lua: Lua,
    tx: Sender<KernelMsg>,
    rx: Receiver<KernelMsg>,
    /// Everything showing the grid: the program's own terminal (as
    /// connection 0) and the terminals attached over connections. They all
    /// show the one screen, as wide and tall as whichever was sized last.
    frontends: Vec<(ClientId, Box<dyn Frontend>)>,
}

impl Drop for Kernel {
    fn drop(&mut self) {
        self.shared.watchdog.detach();
    }
}

impl Kernel {
    pub fn new(opts: KernelOpts) -> Result<Self> {
        // The devices chosen on this machine before, unless the command line
        // names others.
        let device_file = crate::audio::file();
        let mut backend = opts.backend.clone();
        crate::audio::apply(&mut backend, &crate::audio::load(&device_file));
        let mut session = Session::new(&backend, opts.registry)?;
        session.device_file = Some(device_file);
        session.set_peak_dir(Some(crate::peaks::cache_dir()));
        let (tx, rx) = channel();
        // MIDI input goes straight to the engine; scripts hear of it here.
        let midi_tx = tx.clone();
        session.set_midi_tap(Box::new(move |port, kind| {
            let _ = midi_tx.send(KernelMsg::Midi(port, kind));
        }));
        let started = Instant::now();
        let shared = Rc::new(Shared {
            session: RefCell::new(session),
            grid: RefCell::new(Grid::new(80, 24)),
            highlights: RefCell::new(Highlights::default()),
            dirty: Cell::new(true),
            attached: Cell::new(false),
            cursor: Cell::new(None),
            timers: RefCell::new(Vec::new()),
            next_timer: Cell::new(0),
            state: RefCell::new(HashMap::new()),
            quit: Cell::new(None),
            reload: Cell::new(false),
            log: RefCell::new(VecDeque::new()),
            io: RefCell::new(Default::default()),
            started,
            clients: Clients::default(),
            input_from: Cell::new(0),
            detach: RefCell::new(Vec::new()),
            watchdog: Watchdog::new(started),
            env: Env {
                config_dir: opts.config_dir,
                runtime_dir: opts.runtime_dir,
                clean: opts.clean,
                scripted: opts.scripted,
                argv: opts.argv,
            },
        });
        Ok(Self {
            shared,
            lua: Lua::new(),
            tx,
            rx,
            frontends: Vec::new(),
        })
    }

    /// A handle for other threads to send input and RPC calls to the kernel.
    pub fn sender(&self) -> Sender<KernelMsg> {
        self.tx.clone()
    }

    /// Show the screen on a frontend of the given size.
    pub fn attach(&mut self, frontend: Box<dyn Frontend>, width: u16, height: u16) {
        self.shared.grid.borrow_mut().resize(width, height);
        self.shared.attached.set(true);
        self.frontends.push((0, frontend));
    }

    /// The connections open on the control socket, to serve them with and
    /// to push events to.
    pub fn clients(&self) -> Clients {
        self.shared.clients.clone()
    }

    /// The calls that are the kernel's own business rather than Lua's: a
    /// connection becoming a terminal, typing into it, and leaving.
    fn remote_ui(&mut self, client: ClientId, method: &str, params: &Value) -> Result<Value, String> {
        match method {
            "ui.attach" => {
                let size = |v: &Value, default| v.as_u64().map_or(default, |n| n.clamp(1, 1000) as u16);
                let (width, height) = (size(&params[0], 80), size(&params[1], 24));
                self.frontends.retain(|(id, _)| *id != client);
                let frontend = RemoteFrontend::new(client, self.shared.clients.clone());
                self.frontends.push((client, Box::new(frontend)));
                self.shared.attached.set(true);
                self.handle(KernelMsg::Input(InputEvent::Resize(width, height)));
                Ok(Value::Bool(true))
            }
            "ui.input" => {
                if !self.frontends.iter().any(|(id, _)| *id == client) {
                    return Err("`ui.attach` first".into());
                }
                let event = remote::input_of(&params[0]).ok_or("not an input event")?;
                // Lua may ask which terminal a key came from (`:detach`).
                self.shared.input_from.set(client);
                self.handle(KernelMsg::Input(event));
                self.shared.input_from.set(0);
                Ok(Value::Null)
            }
            "ui.detach" => {
                self.detach(client);
                Ok(Value::Bool(true))
            }
            _ => Err(format!("no method `{method}`")),
        }
    }

    /// Stop showing the screen to a connection.
    fn detach(&mut self, client: ClientId) {
        let before = self.frontends.len();
        self.frontends.retain(|(id, _)| *id != client);
        if self.frontends.len() != before {
            self.shared.clients.push(client, "ui.detached", &Value::Null);
        }
        if self.frontends.is_empty() {
            self.shared.attached.set(false);
        }
    }

    /// Start a fresh Lua state and run the runtime, the user's configuration
    /// and their extensions in it. The session is untouched.
    pub fn boot(&mut self) -> Result<()> {
        self.shared.timers.borrow_mut().clear();
        // Extensions get the whole standard library, including `ffi` and `debug`.
        let lua = unsafe { Lua::unsafe_new() };
        api::install(&lua, &self.shared).map_err(lua_error)?;
        install_loader(&lua, &self.shared.env).map_err(lua_error)?;
        // The old state must not be interrupted once it is gone.
        self.shared.watchdog.detach();
        self.lua = lua;
        self.shared.watchdog.attach(&self.lua).map_err(lua_error)?;
        self.lua
            .load("require('daw')")
            .set_name("=boot")
            .exec()
            .map_err(lua_error)?;
        self.call::<()>("startup", ()).map_err(lua_error)?;
        self.settle();
        self.shared.dirty.set(true);
        Ok(())
    }

    /// Call one of the entry points the Lua runtime registers in `daw._kernel`.
    fn call<R: FromLuaMulti>(&self, name: &str, args: impl IntoLuaMulti) -> mlua::Result<R> {
        let daw: Table = self.lua.globals().get("daw")?;
        let kernel: Table = daw.get("_kernel")?;
        kernel.get::<Function>(name)?.call(args)
    }

    fn report(&self, what: &str, err: mlua::Error) {
        let line = format!("{what}: {err}");
        if !self.shared.attached.get() {
            eprintln!("{line}");
        }
        self.shared.log(line);
    }

    /// Run a Lua file with `...` set to `args`.
    pub fn run_file(&mut self, path: &Path, args: Vec<String>) -> Result<()> {
        let code =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let name = format!("@{}", path.display());
        let result = self
            .lua
            .load(code)
            .set_name(name)
            .call::<()>(mlua::Variadic::from_iter(args));
        self.settle();
        result.map_err(lua_error)
    }

    /// Finish a turn: push edits to the engine, deliver the events they
    /// caused, and close the undo step.
    fn settle(&mut self) {
        if let Err(err) = self.call::<()>("settle", ()) {
            self.report("settle", err);
        }
        self.shared.session.borrow_mut().checkpoint();
    }

    fn handle(&mut self, msg: KernelMsg) {
        match msg {
            KernelMsg::Input(event) => {
                let result = match event {
                    InputEvent::Key(key) => self.call::<()>("key", key),
                    InputEvent::Paste(text) => self.call::<()>("paste", text),
                    InputEvent::Mouse {
                        kind,
                        button,
                        x,
                        y,
                        mods,
                    } => (|| {
                        let event = self.lua.create_table()?;
                        event.set("kind", kind)?;
                        event.set("button", button)?;
                        event.set("x", x)?;
                        event.set("y", y)?;
                        event.set("mods", mods)?;
                        self.call::<()>("mouse", event)
                    })(),
                    InputEvent::Resize(width, height) => {
                        self.shared.grid.borrow_mut().resize(width, height);
                        self.call::<()>("resize", (width, height))
                    }
                };
                if let Err(err) = result {
                    self.report("input", err);
                }
                self.shared.dirty.set(true);
            }
            KernelMsg::Midi(port, kind) => self.shared.session.borrow_mut().midi_event(port, kind),
            KernelMsg::Rpc {
                client,
                method,
                params,
                reply,
            } => {
                let result = if method.starts_with("ui.") {
                    self.remote_ui(client, &method, &params)
                } else {
                    (|| {
                        let params = api::to_lua(&self.lua, &params)?;
                        let value: LuaValue = self.call("rpc", (method, params, client))?;
                        self.lua.from_value::<Value>(value)
                    })()
                    .map_err(|err| err.to_string())
                };
                let _ = reply.send(result);
            }
            KernelMsg::Gone(client) => {
                self.detach(client);
                if let Err(err) = self.call::<()>("rpc_closed", client) {
                    self.report("rpc_closed", err);
                }
            }
        }
        // A terminal that asked to leave (`:detach`) is let go.
        let leaving: Vec<ClientId> = self.shared.detach.borrow_mut().drain(..).collect();
        for client in leaving {
            self.detach(client);
        }
    }

    fn fire_timers(&mut self) {
        for func in api::due_timers(&self.shared) {
            if let Err(err) = self.call::<()>("timer", func) {
                self.report("timer", err);
            }
        }
    }

    fn render(&mut self) {
        if self.frontends.is_empty() {
            return;
        }
        self.shared.dirty.set(false);
        self.shared.grid.borrow_mut().clear();
        self.shared.cursor.set(None);
        let result = api::render(&self.lua, &self.shared);
        if let Err(err) = result {
            // The Lua UI is broken, so the kernel draws the reason itself.
            let mut grid = self.shared.grid.borrow_mut();
            let style = Style {
                fg: Some(Color::Indexed(9)),
                ..Style::default()
            };
            let clip = grid.rect();
            for (row, line) in format!("render failed: {err}").lines().enumerate() {
                grid.text(clip, 0, row as i32, line, style);
            }
        }
        let (grid, cursor) = (self.shared.grid.borrow(), self.shared.cursor.get());
        let mut gone = Vec::new();
        for (client, frontend) in &mut self.frontends {
            if let Err(err) = frontend.present(&grid, cursor) {
                self.shared.log(format!("frontend: {err:#}"));
                // A terminal at the end of a connection that has closed.
                if *client != 0 {
                    gone.push(*client);
                }
            }
        }
        drop(grid);
        for client in gone {
            self.detach(client);
        }
    }

    /// Take turns until something asks to quit. Returns the exit code.
    pub fn run(&mut self) -> Result<i32> {
        let mut last_idle = Instant::now();
        loop {
            let next_timer = self.shared.timers.borrow().iter().map(|t| t.due).min();
            // Hosted plugins need regular attention on this thread.
            let next_idle = self
                .shared
                .session
                .borrow()
                .needs_idle()
                .then(|| last_idle + IDLE_PERIOD);
            let msg = match next_timer.into_iter().chain(next_idle).min() {
                Some(due) => match self
                    .rx
                    .recv_timeout(due.saturating_duration_since(Instant::now()))
                {
                    Ok(msg) => Some(msg),
                    Err(RecvTimeoutError::Timeout) => None,
                    Err(RecvTimeoutError::Disconnected) => {
                        return Err(anyhow!("kernel channel closed"));
                    }
                },
                None => Some(self.rx.recv()?),
            };
            if let Some(msg) = msg {
                self.handle(msg);
                // Take whatever else is already waiting before drawing.
                while let Ok(msg) = self.rx.try_recv() {
                    self.handle(msg);
                }
            }
            self.fire_timers();
            if last_idle.elapsed() >= IDLE_PERIOD {
                self.shared.session.borrow_mut().idle();
                last_idle = Instant::now();
            }
            self.settle();

            if self.shared.reload.replace(false)
                && let Err(err) = self.boot()
            {
                self.shared.log(format!("reload failed: {err:#}"));
                if !self.shared.attached.get() {
                    eprintln!("reload failed: {err:#}");
                }
            }
            if let Some(code) = self.shared.quit.get() {
                // Scripts get to tidy up: an `exit` event.
                if let Err(err) = self.call::<()>("exit", ()) {
                    self.report("exit", err);
                }
                return Ok(code);
            }
            if self.shared.dirty.get() {
                self.render();
            }
        }
    }

    /// Run Lua code with `...` set to `args`, as its own turn.
    pub fn eval(&mut self, code: &str, args: &[&str]) -> Result<()> {
        let args = mlua::Variadic::from_iter(args.iter().map(|a| a.to_string()));
        let result = self.lua.load(code).set_name("=eval").call::<()>(args);
        self.settle();
        result.map_err(lua_error)
    }

    pub fn exit_code(&self) -> Option<i32> {
        self.shared.quit.get()
    }
}

fn lua_error(err: mlua::Error) -> anyhow::Error {
    anyhow!("{err}")
}

/// Let `require` find the runtime modules built into the binary, and the
/// user's own modules ahead of them.
fn install_loader(lua: &Lua, env: &Env) -> mlua::Result<()> {
    let package: Table = lua.globals().get("package")?;
    let mut paths = Vec::new();
    let mut add = |dir: &Path| {
        paths.push(format!("{}/?.lua", dir.display()));
        paths.push(format!("{}/?/init.lua", dir.display()));
    };
    if !env.clean {
        add(&env.config_dir.join("lua"));
    }
    if let Some(runtime) = &env.runtime_dir {
        add(&runtime.join("lua"));
    }
    paths.push(package.get::<String>("path")?);
    package.set("path", paths.join(";"))?;

    let embedded = lua.create_function(|lua, name: String| {
        let path = name.replace('.', "/");
        for candidate in [format!("{path}.lua"), format!("{path}/init.lua")] {
            if let Some(file) = RUNTIME.get_file(&candidate) {
                let chunk = lua
                    .load(file.contents())
                    .set_name(format!("@runtime/lua/{candidate}"));
                return Ok(LuaValue::Function(chunk.into_function()?));
            }
        }
        Ok(LuaValue::String(lua.create_string(format!(
            "\n\tno built-in module '{name}'"
        ))?))
    })?;
    // After the path searcher, so files on disk can replace built-in modules.
    package.get::<Table>("loaders")?.push(embedded)
}
