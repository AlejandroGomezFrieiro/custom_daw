//! The connection to paw kernel's control socket: one JSON object per
//! line, `{"id", "method", "params"}` out and `{"id", "result"|"error"}` back.
//!
//! The connection is made when it is first needed and made again after the
//! kernel goes away, so a kernel can be restarted under a running server.
//! With `--spawn` the server starts a kernel of its own and stops it on exit.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

/// Why a call did not produce a result.
#[derive(Debug)]
pub enum CallError {
    /// The kernel ran the call and reported an error: its message.
    Kernel(String),
    /// There is no kernel to talk to, or it went away.
    Unavailable(String),
}

impl std::fmt::Display for CallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CallError::Kernel(msg) | CallError::Unavailable(msg) => f.write_str(msg),
        }
    }
}

pub struct SpawnOpts {
    pub binary: PathBuf,
    pub project: Option<PathBuf>,
    pub args: Vec<String>,
}

pub struct Kernel {
    pub socket: PathBuf,
    timeout: Duration,
    conn: Option<(BufReader<UnixStream>, UnixStream)>,
    spawn: Option<SpawnOpts>,
    child: Option<Child>,
    next_id: u64,
    /// Said once in the next result: the kernel was restarted, say.
    pub notice: Option<String>,
}

/// Where `daw` listens unless told otherwise, as `daw ctl` finds it.
pub fn default_socket() -> PathBuf {
    if let Some(path) = std::env::var_os("DAW_SOCKET") {
        return path.into();
    }
    let dir = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    dir.join("daw.sock")
}

/// The `daw` binary: `$DAW_BIN`, the one beside this program, or `daw` on the path.
pub fn default_binary() -> PathBuf {
    let beside = std::env::current_exe()
        .ok()
        .and_then(|exe| Some(exe.parent()?.join("daw")));
    std::env::var_os("DAW_BIN")
        .map(PathBuf::from)
        .or(beside.filter(|path| path.is_file()))
        .unwrap_or_else(|| PathBuf::from("daw"))
}

impl Kernel {
    pub fn attach(socket: PathBuf, timeout: Duration) -> Self {
        Self {
            socket,
            timeout,
            conn: None,
            spawn: None,
            child: None,
            next_id: 1,
            notice: None,
        }
    }

    pub fn spawned(opts: SpawnOpts, timeout: Duration) -> Self {
        let name = format!("daw-mcp-{}.sock", std::process::id());
        let socket = [
            std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from),
            Some(std::env::temp_dir()),
            Some(PathBuf::from("/tmp")),
        ]
        .into_iter()
        .flatten()
        .map(|dir| dir.join(&name))
        // A Unix socket's path must fit in 108 bytes.
        .find(|path| path.as_os_str().len() < 100)
        .unwrap_or_else(|| PathBuf::from("/tmp").join(&name));
        let mut kernel = Self::attach(socket, timeout);
        kernel.spawn = Some(opts);
        kernel
    }

    pub fn is_spawned(&self) -> bool {
        self.spawn.is_some()
    }

    /// Start the kernel of a `--spawn` server, if it is not running.
    pub fn start(&mut self) -> Result<(), CallError> {
        let Some(opts) = &self.spawn else {
            return Ok(());
        };
        if let Some(child) = self.child.as_mut() {
            match child.try_wait() {
                Ok(None) => return Ok(()),
                Ok(Some(status)) => {
                    self.child = None;
                    self.conn = None;
                    self.notice = Some(format!(
                        "The kernel this server started had stopped ({status}); a new one was started with an empty project. Earlier ids and unsaved work are gone."
                    ));
                }
                Err(_) => self.child = None,
            }
        }
        let mut command = Command::new(&opts.binary);
        command
            .arg("--headless")
            .arg("--listen")
            .arg(&self.socket)
            .args(&opts.args)
            .stdin(Stdio::null());
        if let Some(project) = &opts.project {
            command.arg(project);
        }
        // Whatever the kernel prints must not reach stdout, which is the
        // protocol's: send it to stderr.
        match std::io::stderr().lock().try_clone_stdio() {
            Some(err) => command.stdout(err),
            None => command.stdout(Stdio::null()),
        };
        // If this server dies without saying goodbye, the kernel goes too.
        unsafe {
            command.pre_exec(|| {
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
                Ok(())
            });
        }
        let mut child = command.spawn().map_err(|err| {
            CallError::Unavailable(format!(
                "could not start the kernel `{}`: {err}. Build it with `cargo build -p daw-tui`, or say where it is with --daw or DAW_BIN.",
                opts.binary.display()
            ))
        })?;
        // The first start can take a while: it looks through every installed plugin.
        let deadline = Instant::now() + Duration::from_secs(120);
        loop {
            if let Ok(stream) = UnixStream::connect(&self.socket) {
                self.set_conn(stream)?;
                break;
            }
            if let Ok(Some(status)) = child.try_wait() {
                return Err(CallError::Unavailable(format!(
                    "the kernel stopped before it was ready ({status}); its messages are on this server's stderr"
                )));
            }
            if Instant::now() > deadline {
                let _ = child.kill();
                let _ = child.wait();
                return Err(CallError::Unavailable(
                    "the kernel did not open its socket within 120 s".into(),
                ));
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        self.child = Some(child);
        Ok(())
    }

    fn set_conn(&mut self, stream: UnixStream) -> Result<(), CallError> {
        let unavailable = |err: std::io::Error| CallError::Unavailable(err.to_string());
        stream
            .set_read_timeout(Some(self.timeout))
            .map_err(unavailable)?;
        let reader = BufReader::new(stream.try_clone().map_err(unavailable)?);
        self.conn = Some((reader, stream));
        Ok(())
    }

    fn unavailable(&self, err: impl std::fmt::Display) -> CallError {
        let how = if self.spawn.is_some() {
            "The kernel this server started is gone; the next call starts a new one.".to_string()
        } else {
            format!(
                "Start one with `daw --headless --listen {0}`{1}; this server reconnects on the next call.",
                self.socket.display(),
                if self.socket == default_socket() {
                    " (or run `daw` with its UI, which listens there by default)"
                } else {
                    ""
                }
            )
        };
        CallError::Unavailable(format!(
            "No paw kernel at {}: {err}. {how}",
            self.socket.display()
        ))
    }

    /// Whether the open connection's peer has hung up.
    fn stale(stream: &UnixStream) -> bool {
        use std::os::fd::AsRawFd;
        let mut byte = 0u8;
        let n = unsafe {
            libc::recv(
                stream.as_raw_fd(),
                (&mut byte as *mut u8).cast(),
                1,
                libc::MSG_PEEK | libc::MSG_DONTWAIT,
            )
        };
        match n {
            0 => true,
            n if n > 0 => false,
            _ => std::io::Error::last_os_error().kind() != std::io::ErrorKind::WouldBlock,
        }
    }

    fn connect(&mut self) -> Result<(), CallError> {
        if let Some((_, stream)) = &self.conn
            && !Self::stale(stream)
        {
            return Ok(());
        }
        self.conn = None;
        if self.spawn.is_some() {
            self.start()?;
            if self.conn.is_some() {
                return Ok(());
            }
        }
        let stream = UnixStream::connect(&self.socket).map_err(|err| self.unavailable(err))?;
        self.set_conn(stream)
    }

    /// Call a method on the kernel and wait for its answer.
    pub fn call(&mut self, method: &str, params: Value) -> Result<Value, CallError> {
        self.connect()?;
        let id = self.next_id;
        self.next_id += 1;
        let line = json!({ "id": id, "method": method, "params": params }).to_string();
        let (reader, writer) = self.conn.as_mut().unwrap();
        if let Err(err) = writeln!(writer, "{line}") {
            self.conn = None;
            return Err(self.unavailable(err));
        }
        let mut answer = String::new();
        match reader.read_line(&mut answer) {
            Ok(0) => {
                self.conn = None;
                return Err(self.unavailable(
                    "the kernel went away during the call (it may have crashed, or quit)",
                ));
            }
            Ok(_) => {}
            Err(err)
                if matches!(
                    err.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                // The answer may still come, and would then be read as the
                // answer to the next call: start afresh.
                self.conn = None;
                return Err(CallError::Unavailable(format!(
                    "the kernel did not answer within {} s; it may still be working (see --timeout)",
                    self.timeout.as_secs()
                )));
            }
            Err(err) => {
                self.conn = None;
                return Err(self.unavailable(err));
            }
        }
        let response: Value = serde_json::from_str(&answer)
            .map_err(|err| CallError::Unavailable(format!("bad answer from the kernel: {err}")))?;
        match response.get("error") {
            Some(Value::String(error)) => Err(CallError::Kernel(clean_error(error))),
            Some(other) if !other.is_null() => Err(CallError::Kernel(other.to_string())),
            _ => Ok(response.get("result").cloned().unwrap_or(Value::Null)),
        }
    }

    /// Run Lua in the kernel with `args` as `...`.
    pub fn eval(&mut self, code: &str, args: Vec<Value>) -> Result<Value, CallError> {
        let mut params = vec![json!(code)];
        params.extend(args);
        self.call("eval", Value::Array(params))
    }

    /// Stop a kernel this server started: ask it to quit, then insist.
    pub fn shutdown(&mut self) {
        let Some(mut child) = self.child.take() else {
            return;
        };
        if self.conn.is_some() {
            let _ = self.call("quit", json!([0]));
        }
        self.conn = None;
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if let Ok(Some(_)) = child.try_wait() {
                let _ = std::fs::remove_file(&self.socket);
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let _ = child.kill();
        let _ = child.wait();
        let _ = std::fs::remove_file(&self.socket);
    }
}

impl Drop for Kernel {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// The useful part of a Lua error: no traceback, no `runtime error:` prefix.
pub fn clean_error(error: &str) -> String {
    let text = error.split("\nstack traceback").next().unwrap_or(error);
    let text = text.trim();
    let text = text.strip_prefix("runtime error: ").unwrap_or(text);
    text.to_string()
}

trait CloneStdio {
    fn try_clone_stdio(&self) -> Option<Stdio>;
}

impl CloneStdio for std::io::StderrLock<'_> {
    fn try_clone_stdio(&self) -> Option<Stdio> {
        use std::os::fd::AsFd;
        self.as_fd().try_clone_to_owned().ok().map(Stdio::from)
    }
}
