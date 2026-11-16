//! The `daw` command: start the kernel with a terminal UI, without one, to run
//! a script, or to talk to an instance that is already running.

mod terminal;

use std::path::PathBuf;
use std::process::ExitCode;

use anyhow::{Context, Result, bail};
use daw_core::{Kernel, KernelOpts, rpc};
use daw_engine::Registry;
use daw_engine::backend::BackendOptions;
use serde_json::Value;

const HELP: &str = "\
daw: a hackable DAW

Usage:
  daw [options] [project]         open the terminal UI (a sound file starts a project with it)
  daw -l <script.lua> [args...]   run a Lua script without a UI, then exit
  daw --headless [project]        run without a UI until told to quit
  daw ctl <method> [params...]    call a running instance over its socket
  daw attach                      show a running instance's terminal UI here

Options:
  -e <lua>          run Lua code after startup (repeatable)
  --keys <keys>     type keys after startup, such as 'jj<Space>'
  --clean           skip your configuration and extensions
  --config <dir>    configuration directory (default: ~/.config/daw)
  --runtime <dir>   load the Lua runtime from disk instead of the built-in copy
  --audio <name>    audio backend: auto, null, pipewire, alsa, jack
  --rate <hz>       sample rate
  --buffer <n>      frames per audio callback
  --output <name>   output device by name or part of it (see :audio)
  --input <name>    input device by name or part of it
  --no-input        do not open the audio device's input
  --listen <path>   control socket path (default: $XDG_RUNTIME_DIR/daw.sock)
  --no-listen       do not open a control socket
  --listen-tcp <address>
                    also take connections from the network, on host:port
                    (127.0.0.1:7700; 0.0.0.0:7700 for any machine that knows
                    the token). Not encrypted: for a network you trust
  --token-file <path>
                    where the token for network connections is kept
                    (default: ~/.local/state/daw/token, made if missing)
  --no-plugins      do not look for CLAP, LV2 and VST3 plugins
  --plugins-in-process
                    load plugins into this process, not each into its own
  --plugins-offline open the project with every plugin offline (:plugins.online)
  -h, --help        show this help
  -V, --version     show the version

ctl and attach reach the instance on this machine's socket, or:
  --socket <path>           another socket
  --connect <host:port>     an instance listening on the network, with
  --token <token> or --token-file <path> (or $DAW_TOKEN)

ctl examples:
  daw ctl eval 'return daw.transport.position'
  daw ctl cmd transport.toggle
  daw ctl track_add '{\"name\": \"Bass\"}'
  daw ctl --connect studio:7700 --token-file studio.token cmd transport.toggle

In an attached terminal, `:detach` leaves and the instance runs on.
";

#[derive(Default)]
struct Args {
    project: Option<PathBuf>,
    script: Option<PathBuf>,
    script_args: Vec<String>,
    exprs: Vec<String>,
    keys: Vec<String>,
    headless: bool,
    clean: bool,
    config: Option<PathBuf>,
    runtime: Option<PathBuf>,
    audio: Option<String>,
    rate: Option<u32>,
    buffer: Option<u32>,
    output: Option<String>,
    input: Option<String>,
    no_input: bool,
    listen: Option<PathBuf>,
    no_listen: bool,
    listen_tcp: Option<String>,
    token_file: Option<PathBuf>,
    no_plugins: bool,
    plugins_in_process: bool,
    plugins_offline: bool,
}

fn parse_args(mut argv: impl Iterator<Item = String>) -> Result<Option<Args>> {
    let mut args = Args::default();
    while let Some(arg) = argv.next() {
        let mut value = |name: &str| argv.next().with_context(|| format!("{name} needs a value"));
        match arg.as_str() {
            "-h" | "--help" => {
                print!("{HELP}");
                return Ok(None);
            }
            "-V" | "--version" => {
                println!("daw {}", env!("CARGO_PKG_VERSION"));
                return Ok(None);
            }
            "-l" => {
                args.script = Some(value("-l")?.into());
                args.script_args = argv.by_ref().collect();
            }
            "-e" => args.exprs.push(value("-e")?),
            "--keys" => args.keys.push(value("--keys")?),
            "--headless" => args.headless = true,
            "--clean" => args.clean = true,
            "--config" => args.config = Some(value("--config")?.into()),
            "--runtime" => args.runtime = Some(value("--runtime")?.into()),
            "--audio" => args.audio = Some(value("--audio")?),
            "--rate" => {
                args.rate = Some(value("--rate")?.parse().context("--rate takes a number")?)
            }
            "--buffer" => {
                args.buffer = Some(
                    value("--buffer")?
                        .parse()
                        .context("--buffer takes a number")?,
                )
            }
            "--output" => args.output = Some(value("--output")?),
            "--input" => args.input = Some(value("--input")?),
            "--no-input" => args.no_input = true,
            "--listen" => args.listen = Some(value("--listen")?.into()),
            "--no-listen" => args.no_listen = true,
            "--listen-tcp" => args.listen_tcp = Some(value("--listen-tcp")?),
            "--token-file" => args.token_file = Some(value("--token-file")?.into()),
            "--no-plugins" => args.no_plugins = true,
            "--plugins-in-process" => args.plugins_in_process = true,
            "--plugins-offline" => args.plugins_offline = true,
            other if other.starts_with('-') => bail!("unknown option `{other}` (see --help)"),
            _ if args.project.is_none() => args.project = Some(arg.into()),
            _ => bail!("unexpected argument `{arg}`"),
        }
    }
    Ok(Some(args))
}

fn config_dir() -> PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("daw")
}

/// The terminal's stderr, kept while fd 2 points at a log file.
static REAL_STDERR: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(-1);

/// Send everything written to stderr into a file instead of the terminal.
fn quiet_stderr(log: &std::path::Path) {
    use std::os::fd::AsRawFd;
    if let Some(dir) = log.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let Ok(file) = std::fs::File::create(log) else {
        return;
    };
    unsafe {
        REAL_STDERR.store(libc::dup(2), std::sync::atomic::Ordering::Relaxed);
        libc::dup2(file.as_raw_fd(), 2);
    }
}

/// Undo [`quiet_stderr`], so that a final error message reaches the terminal.
fn restore_stderr() {
    let saved = REAL_STDERR.swap(-1, std::sync::atomic::Ordering::Relaxed);
    if saved >= 0 {
        unsafe {
            libc::dup2(saved, 2);
            libc::close(saved);
        }
    }
}

fn cache_dir() -> PathBuf {
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache")))
        .unwrap_or_else(std::env::temp_dir);
    base.join("daw")
}

/// Connect to the instance `ctl` and `attach` are pointed at by the options
/// at the front of their arguments, which are taken off.
fn connect(argv: &mut std::iter::Peekable<impl Iterator<Item = String>>) -> Result<rpc::Connection> {
    let mut socket = rpc::default_path();
    let mut address = None;
    let mut token = std::env::var("DAW_TOKEN").ok();
    while let Some(option) = argv.peek().filter(|a| a.starts_with("--")).cloned() {
        argv.next();
        let mut value = || argv.next().with_context(|| format!("{option} needs a value"));
        match option.as_str() {
            "--socket" => socket = value()?.into(),
            "--connect" => address = Some(value()?),
            "--token" => token = Some(value()?),
            "--token-file" => {
                let path = value()?;
                let text = std::fs::read_to_string(&path)
                    .with_context(|| format!("reading the token in {path}"))?;
                token = Some(text.trim().to_string());
            }
            other => bail!("unknown option `{other}` (see --help)"),
        }
    }
    match address {
        Some(address) => {
            // On the machine the instance runs on, its token is at hand.
            let token = match token {
                Some(token) => token,
                None => std::fs::read_to_string(rpc::token_path())
                    .map(|text| text.trim().to_string())
                    .context("--connect needs the token: --token, --token-file or $DAW_TOKEN")?,
            };
            rpc::Connection::tcp(&address, &token)
        }
        None => rpc::Connection::unix(&socket),
    }
}

/// `daw ctl <method> [params...]`: each parameter is JSON, or a plain string
/// when it does not parse as JSON.
fn ctl(argv: impl Iterator<Item = String>) -> Result<()> {
    let mut argv = argv.peekable();
    let mut connection = connect(&mut argv)?;
    let method = argv.next().context(
        "usage: daw ctl [--socket <path> | --connect <host:port>] <method> [params...]",
    )?;
    let params: Vec<Value> = argv
        .map(|p| serde_json::from_str(&p).unwrap_or(Value::String(p)))
        .collect();
    match connection.call(&method, Value::Array(params))? {
        Value::Null => {}
        Value::String(text) => println!("{text}"),
        other => println!("{}", serde_json::to_string_pretty(&other)?),
    }
    Ok(())
}

/// `daw attach`: this terminal becomes a terminal of a running instance,
/// which may be on another machine. It shows that instance's one screen
/// (as its own terminal does, if it has one) and types into it; `:detach`
/// leaves, and so does the instance ending.
fn attach(argv: impl Iterator<Item = String>) -> Result<()> {
    let mut argv = argv.peekable();
    let mut connection = connect(&mut argv)?;
    if let Some(extra) = argv.next() {
        bail!("unexpected argument `{extra}`");
    }
    let (input, typed) = std::sync::mpsc::channel();
    let (mut screen, width, height) = terminal::Terminal::start(move |event| input.send(event).is_ok())?;
    connection.call("ui.attach", serde_json::json!([width, height]))?;
    let mut grid = daw_core::grid::Grid::new(width, height);
    use daw_core::Frontend;
    loop {
        // What was typed goes out; what the instance shows comes in.
        let mut idle = true;
        while let Ok(event) = typed.try_recv() {
            idle = false;
            connection.notify("ui.input", serde_json::json!([daw_core::remote::input_json(&event)]))?;
        }
        loop {
            match connection.events.try_recv() {
                Ok((name, payload)) => {
                    idle = false;
                    match name.as_str() {
                        "ui.grid" => {
                            let cursor = daw_core::remote::apply(&mut grid, &payload)?;
                            screen.present(&grid, cursor)?;
                        }
                        "ui.detached" => return Ok(()),
                        _ => {}
                    }
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => break,
                // The instance ended, or the connection did.
                Err(std::sync::mpsc::TryRecvError::Disconnected) => return Ok(()),
            }
        }
        if idle {
            std::thread::sleep(std::time::Duration::from_millis(4));
        }
    }
}

fn run() -> Result<i32> {
    let mut argv = std::env::args().skip(1).peekable();
    if argv.peek().map(String::as_str) == Some("ctl") {
        argv.next();
        ctl(argv)?;
        return Ok(0);
    }
    if argv.peek().map(String::as_str) == Some("attach") {
        argv.next();
        let result = attach(argv);
        terminal::restore();
        result?;
        return Ok(0);
    }
    // Started by a running instance to hold one plugin, or to look into
    // one plugin file, in a process of its own.
    match argv.peek().map(String::as_str) {
        Some("plugin-host") => {
            let args: Vec<String> = argv.skip(1).collect();
            return Ok(daw_plugins::sandbox::serve(&args));
        }
        Some("plugin-scan") => {
            let args: Vec<String> = argv.skip(1).collect();
            return Ok(daw_plugins::scan_main(&args));
        }
        _ => {}
    }
    let Some(args) = parse_args(argv)? else {
        return Ok(0);
    };
    let scripted = args.script.is_some();
    // A terminal older than the display it names cannot open a plugin's
    // window. Put that right while this is still the only thread.
    let display_note = daw_plugins::repair_display_env();

    // A script only makes sound if it asks for a device.
    let backend = args
        .audio
        .clone()
        .unwrap_or_else(|| if scripted { "null" } else { "auto" }.into());
    let mut registry = Registry::with_builtins();
    // The native half of extensions/utau; it does nothing until that is loaded.
    daw_utau::register(&mut registry);
    let mut plugin_notes = if args.no_plugins {
        Vec::new()
    } else {
        let cache = cache_dir().join("plugins.json");
        // Each plugin gets a process of its own, started from this program.
        if !args.plugins_in_process
            && let Ok(exe) = std::env::current_exe()
        {
            daw_plugins::sandbox::set_host_command(
                vec![exe.to_string_lossy().into_owned(), "plugin-host".into()],
                Some(&cache),
            );
        }
        let notes = daw_plugins::register(&mut registry, Some(&cache));
        daw_plugins::sandbox::wrap(&mut registry);
        registry.set_rescan(std::rc::Rc::new(move |registry, name| {
            daw_plugins::rescan(registry, Some(&cache), name)
        }));
        notes
    };
    plugin_notes.extend(display_note);
    let mut kernel = Kernel::new(KernelOpts {
        registry,
        backend: BackendOptions {
            backend,
            sample_rate: args.rate,
            buffer_size: args.buffer,
            input: !args.no_input,
            output_device: args.output.clone(),
            input_device: args.input.clone(),
            test_input: None,
        },
        config_dir: args.config.clone().unwrap_or_else(config_dir),
        runtime_dir: args
            .runtime
            .clone()
            .or_else(|| std::env::var_os("DAW_RUNTIME").map(PathBuf::from)),
        clean: args.clean,
        argv: args.script_args.clone(),
    })?;

    // A panic anywhere but inside a device (which the engine catches, bypasses
    // and reports) writes a safety copy of the project before the program ends.
    let hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        if daw_engine::guard::in_device() {
            return;
        }
        let copy = daw_core::session::panic::write_copy(&info.to_string());
        hook(info);
        if let Some(copy) = copy {
            eprintln!(
                "daw: the unsaved project was kept in {}; `:recover` opens it at the next start",
                copy.display()
            );
        }
    }));
    if !scripted && !args.headless {
        // Plugins write to stderr whenever they like, which would land in the
        // middle of the screen.
        quiet_stderr(&cache_dir().join("stderr.log"));
        let sender = kernel.sender();
        let (terminal, width, height) = terminal::Terminal::start(move |event| {
            sender.send(daw_core::KernelMsg::Input(event)).is_ok()
        })?;
        // A panic message printed into the alternate screen would be lost.
        // Only one on the main thread ends the program; a device's is caught.
        let hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            if !daw_engine::guard::in_device() && std::thread::current().name() == Some("main") {
                terminal::restore();
                restore_stderr();
            }
            hook(info);
        }));
        kernel.attach(Box::new(terminal), width, height);
    }
    kernel.boot()?;
    if !scripted {
        // Opening a project or adding a plugin does not wait for plugins
        // to be made: they come in as they are ready.
        kernel.eval("daw.api.load_apart(true)", &[])?;
    }
    for note in &plugin_notes {
        kernel.eval("daw.api.log('plugin scan: ' .. ...)", &[note])?;
        // Plugin files passed over because they failed before, in one line.
        if note.starts_with("skipped ") {
            kernel.eval("daw.notify(..., 'warn')", &[note])?;
        }
    }

    let _server = if scripted || args.no_listen {
        None
    } else {
        let path = args.listen.clone().unwrap_or_else(rpc::default_path);
        match rpc::serve(&path, kernel.sender(), kernel.clients()) {
            Ok(server) => Some(server),
            // The socket is a convenience: carry on without it when it is taken.
            Err(err) if args.listen.is_none() => {
                kernel.eval(
                    "daw.notify(..., 'warn')",
                    &[&format!("no control socket: {err:#}")],
                )?;
                None
            }
            Err(err) => return Err(err),
        }
    };

    if let Some(address) = &args.listen_tcp {
        // Other machines may connect, if they know the token.
        let token_file = args.token_file.clone().unwrap_or_else(rpc::token_path);
        let token = rpc::token_at(&token_file)?;
        let bound = rpc::serve_tcp(address, token, kernel.sender(), kernel.clients())?;
        let note = format!(
            "listening on {bound} for connections that know the token in {}",
            token_file.display()
        );
        // Without a terminal attached this goes to stderr as well.
        kernel.eval("daw.notify(...)", &[&note])?;
    }

    if let Some(project) = &args.project {
        // A project, or a sound file to start a project from.
        let open = if args.plugins_offline {
            "daw.open(..., { plugins_offline = true })"
        } else {
            "daw.open(...)"
        };
        // One that will not open but has a backup or safety copy starts the
        // program anyway, with those offered (`:recover`).
        kernel.eval(
            &format!(
                "local ok, err = pcall(function(...) {open} end, ...)
                 if not ok and not (daw.autosave and daw.autosave.offered) then error(err, 0) end"
            ),
            &[&project.to_string_lossy()],
        )?;
    }
    for expr in &args.exprs {
        kernel.eval(expr, &[])?;
    }
    for keys in &args.keys {
        kernel.eval("daw.keymap.feed(...)", &[keys])?;
    }
    if let Some(script) = &args.script {
        kernel.run_file(script, args.script_args.clone())?;
        return Ok(kernel.exit_code().unwrap_or(0));
    }
    kernel.run()
}

fn main() -> ExitCode {
    let result = run();
    restore_stderr();
    match result {
        Ok(code) => ExitCode::from(code.clamp(0, 255) as u8),
        Err(err) => {
            eprintln!("daw: {err:#}");
            ExitCode::FAILURE
        }
    }
}
