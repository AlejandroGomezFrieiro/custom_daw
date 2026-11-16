//! The control socket: other processes, on this machine or another, call
//! into a running kernel and hear from it, one JSON object per line.
//!
//! Request: `{"id": 1, "method": "eval", "params": ["return daw.transport.position"]}`
//! Reply: `{"id": 1, "result": 3.5}` or `{"id": 1, "error": "..."}`
//! Pushed: `{"event": "transport.play", "payload": {"position": 0}}`
//!
//! A connection only hears what it asked for (`subscribe`, `frontend.watch`,
//! `ui.attach`: see docs/protocol.md). Replies and events go out through one
//! queue per connection, in the order they were made.
//!
//! Two ways in: a Unix socket, which whoever may open the file may use, and
//! TCP, where a connection first has to show that it knows the token
//! without sending it (`hello`). TCP is not encrypted: it is for a network
//! you trust, and for anything else it goes through SSH or a VPN.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result, bail};
pub use daw_proto::{ClientId, Connection, VERSION, proof, sha256};
use daw_proto::hex;
use serde_json::{Value, json};

use crate::kernel::KernelMsg;

/// Every open connection's way out. Cheap to clone; the kernel keeps one to
/// push events with.
#[derive(Clone, Default)]
pub struct Clients {
    out: Arc<Mutex<HashMap<ClientId, Sender<String>>>>,
    next: Arc<AtomicU64>,
}

impl Clients {
    fn add(&self, out: Sender<String>) -> ClientId {
        let id = self.next.fetch_add(1, Ordering::Relaxed) + 1;
        self.out.lock().unwrap().insert(id, out);
        id
    }

    fn remove(&self, id: ClientId) {
        self.out.lock().unwrap().remove(&id);
    }

    /// Queue a line for a connection. False when it is gone.
    pub fn send(&self, id: ClientId, line: String) -> bool {
        let out = self.out.lock().unwrap();
        out.get(&id).is_some_and(|out| out.send(line).is_ok())
    }

    /// Push an event to a connection. False when it is gone.
    pub fn push(&self, id: ClientId, event: &str, payload: &Value) -> bool {
        self.send(id, json!({ "event": event, "payload": payload }).to_string())
    }

    /// The connections that are open.
    pub fn ids(&self) -> Vec<ClientId> {
        let mut ids: Vec<ClientId> = self.out.lock().unwrap().keys().copied().collect();
        ids.sort_unstable();
        ids
    }
}

/// Removes the socket file when the server goes away.
pub struct Server {
    path: PathBuf,
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Where the control socket lives unless told otherwise.
pub fn default_path() -> PathBuf {
    let dir = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    dir.join("daw.sock")
}

/// Listen on `path` and forward calls to the kernel.
pub fn serve(path: &Path, kernel: Sender<KernelMsg>, clients: Clients) -> Result<Server> {
    if path.exists() {
        if UnixStream::connect(path).is_ok() {
            bail!(
                "another instance is already listening on {}",
                path.display()
            );
        }
        // Left behind by an instance that did not shut down cleanly.
        std::fs::remove_file(path)?;
    }
    let listener =
        UnixListener::bind(path).with_context(|| format!("listening on {}", path.display()))?;
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let (kernel, clients) = (kernel.clone(), clients.clone());
            std::thread::spawn(move || {
                if let Ok(writer) = stream.try_clone() {
                    connection(stream, writer, kernel, clients, None);
                }
            });
        }
    });
    Ok(Server {
        path: path.to_path_buf(),
    })
}

/// Listen on a TCP address (`127.0.0.1:7700`, `0.0.0.0:7700`) for
/// connections that know `token`. Returns the address bound, which says
/// which port was given when the address asked for port 0.
pub fn serve_tcp(
    address: &str,
    token: String,
    kernel: Sender<KernelMsg>,
    clients: Clients,
) -> Result<std::net::SocketAddr> {
    if token.len() < 16 {
        bail!("the token for network connections is too short to be one: 16 characters at least");
    }
    let listener =
        TcpListener::bind(address).with_context(|| format!("listening on {address}"))?;
    let bound = listener.local_addr()?;
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let (kernel, clients, token) = (kernel.clone(), clients.clone(), token.clone());
            std::thread::spawn(move || {
                // Small messages both ways: do not wait to fill a packet.
                let _ = stream.set_nodelay(true);
                if let Ok(writer) = stream.try_clone() {
                    connection(stream, writer, kernel, clients, Some(token));
                }
            });
        }
    });
    Ok(bound)
}

/// Where the token for network connections is kept on this machine:
/// `$XDG_STATE_HOME/daw/token`.
pub fn token_path() -> PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state"))
        })
        .unwrap_or_else(std::env::temp_dir)
        .join("daw")
        .join("token")
}

/// The token in `path`, made and written there (readable by its owner
/// alone) if there is none yet.
pub fn token_at(path: &Path) -> Result<String> {
    if let Ok(text) = std::fs::read_to_string(path) {
        let token = text.trim().to_string();
        if token.len() >= 16 {
            return Ok(token);
        }
    }
    use std::os::unix::fs::OpenOptionsExt;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    }
    let token = new_token();
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("writing {}", path.display()))?;
    writeln!(file, "{token}")?;
    Ok(token)
}

/// What a connection that has to show it knows the token is sent first,
/// and what it must answer with: see [`proof`].
fn nonce() -> String {
    let mut bytes = [0u8; 16];
    let read = std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut bytes));
    if read.is_err() {
        // No random device: the time and a counter still differ every time.
        static COUNT: AtomicU64 = AtomicU64::new(0);
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        let seed = format!("{now}:{}", COUNT.fetch_add(1, Ordering::Relaxed));
        bytes.copy_from_slice(&sha256(seed.as_bytes())[..16]);
    }
    hex(&bytes)
}

/// A new token for network connections: 32 random hexadecimal digits.
pub fn new_token() -> String {
    nonce()
}

/// Compare without stopping at the first difference.
fn same(a: &str, b: &str) -> bool {
    a.len() == b.len()
        && a.bytes()
            .zip(b.bytes())
            .fold(0u8, |diff, (x, y)| diff | (x ^ y))
            == 0
}

/// Serve one connection until it closes: its requests go to the kernel in
/// order, and whatever the kernel has for it goes out through `writer`.
fn connection(
    stream: impl Read,
    mut writer: impl Write + Send + 'static,
    kernel: Sender<KernelMsg>,
    clients: Clients,
    token: Option<String>,
) {
    let (out, queue): (Sender<String>, Receiver<String>) = channel();
    std::thread::spawn(move || {
        for line in queue {
            if writer.write_all(line.as_bytes()).is_err()
                || writer.write_all(b"\n").is_err()
                || writer.flush().is_err()
            {
                break;
            }
        }
    });
    let id = clients.add(out.clone());
    // Over the network, nothing is listened to before the token is shown.
    let challenge = token.as_ref().map(|_| nonce());
    let mut trusted = token.is_none();
    if let Some(nonce) = &challenge {
        let _ = out.send(
            json!({ "event": "hello", "payload": { "version": VERSION, "nonce": nonce } })
                .to_string(),
        );
    }
    for line in BufReader::new(stream).lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let request = match serde_json::from_str::<Value>(&line) {
            Ok(request) => request,
            Err(err) => {
                let _ = out.send(
                    json!({ "id": null, "error": format!("bad request: {err}") }).to_string(),
                );
                continue;
            }
        };
        let request_id = request["id"].clone();
        let method = request["method"].as_str().unwrap_or_default().to_string();
        let params = request.get("params").cloned().unwrap_or(json!([]));
        let outcome = if method == "hello" {
            // Who is there, and (over the network) the proof.
            let shown = params[0]["proof"].as_str().or(params["proof"].as_str());
            if let (Some(token), Some(nonce)) = (&token, &challenge) {
                trusted = shown.is_some_and(|shown| same(shown, &proof(token, nonce)));
            }
            if trusted {
                Ok(json!({ "version": VERSION, "client": id }))
            } else {
                Err("the token is not the right one".to_string())
            }
        } else if !trusted {
            Err("say `hello` with the proof of the token first".to_string())
        } else {
            let (reply, result) = channel();
            let sent = kernel.send(KernelMsg::Rpc {
                client: id,
                method,
                params,
                reply,
            });
            match sent {
                Ok(()) => result
                    .recv()
                    .unwrap_or_else(|_| Err("the kernel went away".to_string())),
                Err(_) => break,
            }
        };
        let response = match outcome {
            Ok(result) => json!({ "id": request_id, "result": result }),
            Err(error) => json!({ "id": request_id, "error": error }),
        };
        if out.send(response.to_string()).is_err() {
            break;
        }
        if !trusted {
            // One try: a wrong token ends the connection.
            break;
        }
    }
    clients.remove(id);
    let _ = kernel.send(KernelMsg::Gone(id));
}

/// Call a method on a running instance and wait for the answer.
pub fn call(path: &Path, method: &str, params: Value) -> Result<Value> {
    Connection::unix(path)?.call(method, params)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokens_are_long_differ_and_compare_whole() {
        assert_ne!(new_token(), new_token());
        assert_eq!(new_token().len(), 32);
        let a = proof("0123456789abcdef", "n1");
        assert!(same(&a, &proof("0123456789abcdef", "n1")));
        assert!(!same(&a, &a[..63]));
        assert!(!same(&a, &proof("0123456789abcdef", "n2")));
    }
}
