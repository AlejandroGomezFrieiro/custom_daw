//! The control socket: other processes call into a running kernel with one
//! JSON object per line.
//!
//! Request: `{"id": 1, "method": "eval", "params": ["return daw.transport.position"]}`
//! Reply: `{"id": 1, "result": 3.5}` or `{"id": 1, "error": "..."}`

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Sender, channel};

use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Value, json};

use crate::kernel::KernelMsg;

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
pub fn serve(path: &Path, kernel: Sender<KernelMsg>) -> Result<Server> {
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
            let kernel = kernel.clone();
            std::thread::spawn(move || {
                let _ = connection(stream, kernel);
            });
        }
    });
    Ok(Server {
        path: path.to_path_buf(),
    })
}

fn connection(stream: UnixStream, kernel: Sender<KernelMsg>) -> Result<()> {
    let mut writer = stream.try_clone()?;
    for line in BufReader::new(stream).lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let (id, outcome) = match serde_json::from_str::<Value>(&line) {
            Ok(request) => {
                let method = request["method"].as_str().unwrap_or_default().to_string();
                let params = request.get("params").cloned().unwrap_or(json!([]));
                let (reply, result) = channel();
                kernel.send(KernelMsg::Rpc {
                    method,
                    params,
                    reply,
                })?;
                (request["id"].clone(), result.recv()?)
            }
            Err(err) => (Value::Null, Err(format!("bad request: {err}"))),
        };
        let response = match outcome {
            Ok(result) => json!({ "id": id, "result": result }),
            Err(error) => json!({ "id": id, "error": error }),
        };
        writeln!(writer, "{response}")?;
    }
    Ok(())
}

/// Call a method on a running instance and wait for the answer.
pub fn call(path: &Path, method: &str, params: Value) -> Result<Value> {
    let mut stream = UnixStream::connect(path)
        .with_context(|| format!("no running instance at {}", path.display()))?;
    writeln!(
        stream,
        "{}",
        json!({ "id": 1, "method": method, "params": params })
    )?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line)?;
    let response: Value = serde_json::from_str(&line).context("bad response")?;
    match response.get("error").and_then(Value::as_str) {
        Some(error) => Err(anyhow!("{error}")),
        None => Ok(response["result"].clone()),
    }
}
