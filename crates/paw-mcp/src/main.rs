//! `paw-mcp`: a Model Context Protocol server for paw.
//!
//! It speaks MCP (JSON-RPC 2.0, one message per line) on stdin and stdout and
//! drives a paw kernel through the kernel's control socket. Everything it
//! does to the project goes through `paw.api`, so it is undoable like any
//! other edit. Logs go to stderr; stdout carries protocol messages only.

mod audio;
mod format;
mod kernel;
mod music;
mod tools;

use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};

use kernel::{Kernel, SpawnOpts};
use tools::{Policy, ToolError, Tools};

const HELP: &str = "\
paw-mcp: a Model Context Protocol server for paw, on stdin and stdout

Usage:
  paw-mcp [options]                     attach to a running kernel
  paw-mcp --spawn [project] [-- kernel options...]
                                        start a headless kernel of its own

Options:
  --socket <path>     the kernel's control socket (default: $PAW_SOCKET, else
                      $XDG_RUNTIME_DIR/paw.sock, where `paw` listens)
  --spawn             start `paw --headless` and stop it on exit; anything
                      after `--` is passed to it (such as --audio null)
  --paw <path>        the `paw` binary for --spawn (default: $PAW_BIN, the one
                      beside this program, or `paw` on the path)
  --root <dir>        where relative paths start and files may be written
                      (default: the current directory)
  --allow-eval        offer the escape hatches: run_command, send_keys and
                      eval_lua, which run arbitrary code in paw
  --allow-any-path    let save and render write outside --root
  --timeout <secs>    how long to wait for the kernel per call (default 600)
  -h, --help          show this help
  -V, --version       show the version
";

/// Protocol revisions with an `initialize` handshake, newest first.
const LEGACY_VERSIONS: [&str; 4] = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
/// Revisions that carry the version in each request's `_meta`.
const MODERN_VERSIONS: [&str; 1] = ["2026-07-28"];
const META_VERSION: &str = "io.modelcontextprotocol/protocolVersion";

struct Args {
    socket: Option<PathBuf>,
    spawn: bool,
    project: Option<PathBuf>,
    paw: Option<PathBuf>,
    kernel_args: Vec<String>,
    policy: Policy,
    timeout: u64,
}

fn parse_args() -> Result<Option<Args>> {
    let mut argv = std::env::args().skip(1);
    let mut args = Args {
        socket: None,
        spawn: false,
        project: None,
        paw: None,
        kernel_args: Vec::new(),
        policy: Policy {
            root: std::env::current_dir().context("no working directory")?,
            ..Policy::default()
        },
        timeout: 600,
    };
    while let Some(arg) = argv.next() {
        let mut value = |name: &str| argv.next().with_context(|| format!("{name} needs a value"));
        match arg.as_str() {
            "-h" | "--help" => {
                eprint!("{HELP}");
                return Ok(None);
            }
            "-V" | "--version" => {
                eprintln!("paw-mcp {}", env!("CARGO_PKG_VERSION"));
                return Ok(None);
            }
            "--socket" => args.socket = Some(value("--socket")?.into()),
            "--spawn" => args.spawn = true,
            "--paw" => args.paw = Some(value("--paw")?.into()),
            "--root" => {
                let root = PathBuf::from(value("--root")?);
                args.policy.root = std::path::absolute(&root)?
                    .canonicalize()
                    .with_context(|| format!("--root {}", root.display()))?;
            }
            "--allow-eval" => args.policy.allow_eval = true,
            "--allow-any-path" => args.policy.allow_any_path = true,
            "--timeout" => {
                args.timeout = value("--timeout")?
                    .parse()
                    .context("--timeout takes seconds")?
            }
            "--" => args.kernel_args = argv.by_ref().collect(),
            other if other.starts_with('-') => bail!("unknown option `{other}` (see --help)"),
            _ if args.project.is_none() => args.project = Some(arg.into()),
            _ => bail!("unexpected argument `{arg}`"),
        }
    }
    if !args.spawn && (args.project.is_some() || !args.kernel_args.is_empty()) {
        bail!("a project file and kernel options only go with --spawn");
    }
    if args.spawn && args.socket.is_some() {
        bail!("--spawn starts its own kernel; --socket attaches to one: pick one");
    }
    Ok(Some(args))
}

struct Server {
    tools: Tools,
    /// The revision agreed by `initialize`, for legacy clients.
    version: Option<String>,
}

/// A JSON-RPC error.
struct RpcError {
    code: i64,
    message: String,
    data: Option<Value>,
}

fn rpc_error(code: i64, message: impl Into<String>) -> RpcError {
    RpcError {
        code,
        message: message.into(),
        data: None,
    }
}

impl Server {
    /// Handle one message; `None` for notifications and stray responses.
    fn handle(&mut self, message: &Value) -> Option<Value> {
        let Some(object) = message.as_object() else {
            return Some(error_response(
                Value::Null,
                rpc_error(-32600, "Invalid Request: not an object"),
            ));
        };
        let id = object.get("id").cloned();
        let Some(method) = object.get("method").and_then(Value::as_str) else {
            // A response to a request of ours; we send none.
            return match id {
                Some(_) if object.contains_key("result") || object.contains_key("error") => None,
                _ => Some(error_response(
                    id.unwrap_or(Value::Null),
                    rpc_error(-32600, "Invalid Request: no method"),
                )),
            };
        };
        let params = object.get("params").cloned().unwrap_or(json!({}));
        let Some(id) = id else {
            self.notification(method, &params);
            return None;
        };
        Some(match self.request(method, &params) {
            Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
            Err(err) => error_response(id, err),
        })
    }

    fn notification(&mut self, method: &str, _params: &Value) {
        match method {
            "notifications/initialized" => eprintln!("paw-mcp: client ready"),
            // Calls run one at a time and to completion; nothing to cancel.
            "notifications/cancelled" => {}
            _ => {}
        }
    }

    fn request(&mut self, method: &str, params: &Value) -> Result<Value, RpcError> {
        // A modern request names its revision in `_meta`; it needs no handshake.
        let modern = match params["_meta"][META_VERSION].as_str() {
            Some(v) if MODERN_VERSIONS.contains(&v) => true,
            Some(v) if method != "initialize" => {
                return Err(RpcError {
                    code: -32022,
                    message: "Unsupported protocol version".into(),
                    data: Some(json!({ "supported": MODERN_VERSIONS, "requested": v })),
                });
            }
            _ => false,
        };
        let mut result = match method {
            "initialize" => self.initialize(params),
            "server/discover" => Ok(json!({
                "supportedVersions": MODERN_VERSIONS,
                "capabilities": capabilities(),
                "_meta": { "io.modelcontextprotocol/serverInfo": server_info() },
                "instructions": tools::INSTRUCTIONS,
            })),
            "ping" => Ok(json!({})),
            "tools/list" => Ok(json!({ "tools": self.tools.list() })),
            "tools/call" => self.call(params),
            _ => Err(rpc_error(-32601, format!("Method not found: {method}"))),
        }?;
        if modern || method == "server/discover" {
            result["resultType"] = json!("complete");
        }
        Ok(result)
    }

    fn initialize(&mut self, params: &Value) -> Result<Value, RpcError> {
        let requested = params["protocolVersion"].as_str().unwrap_or("");
        // The requested revision when we speak it, else our newest.
        let version = if LEGACY_VERSIONS.contains(&requested) {
            requested
        } else {
            LEGACY_VERSIONS[0]
        };
        let client = &params["clientInfo"];
        eprintln!(
            "paw-mcp: {} {} asked for protocol {requested}; speaking {version}",
            client["name"].as_str().unwrap_or("a client"),
            client["version"].as_str().unwrap_or("")
        );
        self.version = Some(version.to_string());
        Ok(json!({
            "protocolVersion": version,
            "capabilities": capabilities(),
            "serverInfo": server_info(),
            "instructions": tools::INSTRUCTIONS,
        }))
    }

    fn call(&mut self, params: &Value) -> Result<Value, RpcError> {
        let name = params["name"]
            .as_str()
            .ok_or_else(|| rpc_error(-32602, "Invalid params: tools/call needs a `name`"))?;
        if !Tools::exists(name) {
            return Err(rpc_error(-32602, format!("Unknown tool: {name}")));
        }
        let args = params.get("arguments").cloned().unwrap_or(json!({}));
        let started = std::time::Instant::now();
        let outcome = self.tools.call(name, &args);
        let (text, is_error) = match outcome {
            Ok(text) => (text, false),
            Err(ToolError(text)) => (text, true),
        };
        eprintln!(
            "paw-mcp: {name} {} in {} ms",
            if is_error { "failed" } else { "done" },
            started.elapsed().as_millis()
        );
        Ok(json!({
            "content": [{ "type": "text", "text": text.trim_end() }],
            "isError": is_error,
        }))
    }
}

fn capabilities() -> Value {
    json!({ "tools": { "listChanged": false } })
}

fn server_info() -> Value {
    json!({
        "name": "paw-mcp",
        "title": "paw",
        "version": env!("CARGO_PKG_VERSION"),
    })
}

fn error_response(id: Value, err: RpcError) -> Value {
    let mut error = json!({ "code": err.code, "message": err.message });
    if let Some(data) = err.data {
        error["data"] = data;
    }
    json!({ "jsonrpc": "2.0", "id": id, "error": error })
}

fn run() -> Result<()> {
    let Some(args) = parse_args()? else {
        return Ok(());
    };
    let timeout = Duration::from_secs(args.timeout.max(1));
    let mut kernel = if args.spawn {
        let project = match &args.project {
            Some(p) => Some(std::path::absolute(p)?),
            None => None,
        };
        Kernel::spawned(
            SpawnOpts {
                binary: args.paw.clone().unwrap_or_else(kernel::default_binary),
                project,
                args: args.kernel_args.clone(),
            },
            timeout,
        )
    } else {
        Kernel::attach(
            args.socket.clone().unwrap_or_else(kernel::default_socket),
            timeout,
        )
    };
    if kernel.is_spawned() {
        // Start now, so the first tool call is quick and a broken setup shows
        // in the log at once; a failure is reported again on each call.
        if let Err(err) = kernel.start() {
            eprintln!("paw-mcp: {err}");
        }
    }
    eprintln!(
        "paw-mcp: kernel socket {}; root {}; eval {}; writes {}",
        kernel.socket.display(),
        args.policy.root.display(),
        if args.policy.allow_eval {
            "allowed"
        } else {
            "off"
        },
        if args.policy.allow_any_path {
            "anywhere"
        } else {
            "under the root only"
        }
    );
    let mut server = Server {
        tools: Tools {
            kernel,
            policy: args.policy,
        },
        version: None,
    };

    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout().lock();
    for line in stdin.lock().lines() {
        let line = line.context("reading stdin")?;
        if line.trim().is_empty() {
            continue;
        }
        let reply = match serde_json::from_str::<Value>(&line) {
            Err(err) => Some(error_response(
                Value::Null,
                rpc_error(-32700, format!("Parse error: {err}")),
            )),
            // A batch, as 2025-03-26 allows.
            Ok(Value::Array(batch)) if !batch.is_empty() => {
                let replies: Vec<Value> = batch.iter().filter_map(|m| server.handle(m)).collect();
                (!replies.is_empty()).then_some(Value::Array(replies))
            }
            Ok(message) => server.handle(&message),
        };
        if let Some(reply) = reply {
            writeln!(stdout, "{reply}")?;
            stdout.flush()?;
        }
    }
    eprintln!(
        "paw-mcp: stdin closed{}",
        if server.tools.kernel.is_spawned() {
            "; stopping the kernel"
        } else {
            ""
        }
    );
    let _ = server.version;
    server.tools.kernel.shutdown();
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("paw-mcp: {err:#}");
            ExitCode::FAILURE
        }
    }
}
