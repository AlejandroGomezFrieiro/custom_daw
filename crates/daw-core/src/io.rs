//! Helper processes and Unix sockets, for extensions that drive a program of
//! their own (a renderer, a language server) from Lua.
//!
//! Everything is addressed by number and moves as plain bytes, so `daw.api`
//! stays plain data. Reads never block: scripts poll from a timer. Handles
//! live in the kernel, not in the Lua state, so they survive `:reload`.

use std::collections::{BTreeMap, HashMap};
use std::fs::OpenOptions;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde_json::{Value, json};

/// How long a write may wait for the other side to make room.
const WRITE_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct SpawnOpts {
    pub env: BTreeMap<String, String>,
    pub cwd: Option<PathBuf>,
    /// File that receives the program's output and errors, appended to.
    /// Without it they are discarded.
    pub log: Option<PathBuf>,
}

#[derive(Default)]
pub struct Io {
    next: u64,
    procs: HashMap<u64, Child>,
    listeners: HashMap<u64, (UnixListener, PathBuf)>,
    streams: HashMap<u64, UnixStream>,
}

impl Io {
    fn id(&mut self) -> u64 {
        self.next += 1;
        self.next
    }

    pub fn spawn(&mut self, argv: &[String], opts: SpawnOpts) -> Result<u64> {
        let (program, args) = argv.split_first().context("nothing to run")?;
        let mut command = Command::new(program);
        command.args(args).envs(&opts.env).stdin(Stdio::null());
        if let Some(cwd) = &opts.cwd {
            command.current_dir(cwd);
        }
        match &opts.log {
            Some(path) => {
                let file = OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(path)
                    .with_context(|| format!("opening {}", path.display()))?;
                command.stdout(file.try_clone()?).stderr(file);
            }
            None => {
                command.stdout(Stdio::null()).stderr(Stdio::null());
            }
        }
        // A helper has no reason to outlive the program that drives it: if
        // the program ends without stopping it, however it ends, the helper
        // is asked to finish.
        #[cfg(target_os = "linux")]
        unsafe {
            command.pre_exec(|| {
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
                Ok(())
            });
        }
        let child = command
            .spawn()
            .with_context(|| format!("starting {program}"))?;
        let id = self.id();
        self.procs.insert(id, child);
        Ok(id)
    }

    /// `{ running, code, pid }`; `code` is nil while running or when a signal ended it.
    pub fn status(&mut self, id: u64) -> Result<Value> {
        let child = self
            .procs
            .get_mut(&id)
            .with_context(|| format!("no process {id}"))?;
        let pid = child.id();
        Ok(match child.try_wait()? {
            None => json!({ "running": true, "pid": pid }),
            Some(status) => json!({ "running": false, "code": status.code(), "pid": pid }),
        })
    }

    /// Ask a process to finish, as Ctrl-C in a terminal would, and leave it
    /// the time to: `status` says when it has, and `kill` forgets it.
    pub fn stop(&mut self, id: u64) -> Result<()> {
        let child = self
            .procs
            .get_mut(&id)
            .with_context(|| format!("no process {id}"))?;
        if child.try_wait()?.is_none() {
            unsafe {
                libc::kill(child.id() as libc::pid_t, libc::SIGTERM);
            }
        }
        Ok(())
    }

    /// Stop a process and forget it.
    pub fn kill(&mut self, id: u64) {
        if let Some(mut child) = self.procs.remove(&id) {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    /// Listen on a socket file, replacing a stale one.
    pub fn listen(&mut self, path: PathBuf) -> Result<u64> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        }
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path)
            .with_context(|| format!("listening on {}", path.display()))?;
        listener.set_nonblocking(true)?;
        let id = self.id();
        self.listeners.insert(id, (listener, path));
        Ok(id)
    }

    pub fn connect(&mut self, path: PathBuf) -> Result<u64> {
        let stream = UnixStream::connect(&path)
            .with_context(|| format!("connecting to {}", path.display()))?;
        stream.set_nonblocking(true)?;
        let id = self.id();
        self.streams.insert(id, stream);
        Ok(id)
    }

    /// A connection waiting on a listener, if there is one.
    pub fn accept(&mut self, id: u64) -> Result<Option<u64>> {
        let (listener, _) = self
            .listeners
            .get(&id)
            .with_context(|| format!("no listener {id}"))?;
        match listener.accept() {
            Ok((stream, _)) => {
                stream.set_nonblocking(true)?;
                let id = self.id();
                self.streams.insert(id, stream);
                Ok(Some(id))
            }
            Err(err) if err.kind() == ErrorKind::WouldBlock => Ok(None),
            Err(err) => Err(err.into()),
        }
    }

    /// Up to `max` bytes that have arrived: empty when nothing has, `None`
    /// once the other side has closed the connection.
    pub fn read(&mut self, id: u64, max: usize) -> Result<Option<Vec<u8>>> {
        let stream = self
            .streams
            .get_mut(&id)
            .with_context(|| format!("no connection {id}"))?;
        let mut buf = vec![0u8; max.clamp(1, 1 << 24)];
        loop {
            return match stream.read(&mut buf) {
                Ok(0) => Ok(None),
                Ok(n) => {
                    buf.truncate(n);
                    Ok(Some(buf))
                }
                Err(err) if err.kind() == ErrorKind::WouldBlock => Ok(Some(Vec::new())),
                Err(err) if err.kind() == ErrorKind::Interrupted => continue,
                Err(err) if err.kind() == ErrorKind::ConnectionReset => Ok(None),
                Err(err) => Err(err.into()),
            };
        }
    }

    /// Write all of `data`, waiting for room if the other side is slow.
    pub fn write(&mut self, id: u64, data: &[u8]) -> Result<()> {
        let stream = self
            .streams
            .get_mut(&id)
            .with_context(|| format!("no connection {id}"))?;
        let deadline = Instant::now() + WRITE_TIMEOUT;
        let mut rest = data;
        while !rest.is_empty() {
            match stream.write(rest) {
                Ok(0) => bail!("connection {id} is closed"),
                Ok(n) => rest = &rest[n..],
                Err(err) if err.kind() == ErrorKind::WouldBlock => {
                    if Instant::now() > deadline {
                        bail!("connection {id} stopped taking data");
                    }
                    std::thread::sleep(Duration::from_millis(1));
                }
                Err(err) if err.kind() == ErrorKind::Interrupted => {}
                Err(err) => return Err(err.into()),
            }
        }
        Ok(())
    }

    /// Close a connection or a listener, removing a listener's socket file.
    pub fn close(&mut self, id: u64) {
        self.streams.remove(&id);
        if let Some((_, path)) = self.listeners.remove(&id) {
            let _ = std::fs::remove_file(path);
        }
    }
}

impl Drop for Io {
    fn drop(&mut self) {
        let ids: Vec<u64> = self.listeners.keys().copied().collect();
        for id in ids {
            self.close(id);
        }
        self.streams.clear();
        // A closed connection is how most helpers learn to quit, so give them a
        // moment to finish what they are writing before stopping them.
        let deadline = Instant::now() + Duration::from_millis(500);
        while Instant::now() < deadline
            && self
                .procs
                .values_mut()
                .any(|child| matches!(child.try_wait(), Ok(None)))
        {
            std::thread::sleep(Duration::from_millis(10));
        }
        let ids: Vec<u64> = self.procs.keys().copied().collect();
        for id in ids {
            self.kill(id);
        }
    }
}
