//! The control socket from outside: calls, pushed events, the token over
//! TCP, the frontend's state pushed in parts, and a terminal attached to a
//! kernel that runs without one.

use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use daw_core::grid::Grid;
use daw_core::rpc::Connection;
use serde_json::{Value, json};

/// A kernel without a UI, listening on a socket and on a TCP port of its
/// own, ended when the test is.
struct Instance {
    child: Child,
    socket: PathBuf,
    address: String,
    token: String,
    dir: PathBuf,
}

impl Drop for Instance {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn start(name: &str) -> Instance {
    // A short path: a Unix socket's must fit in 108 bytes.
    let dir = std::env::temp_dir().join(format!("daw-rt-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("daw.sock");
    let token_file = dir.join("token");
    let mut child = Command::new(env!("CARGO_BIN_EXE_daw"))
        .args(["--headless", "--clean", "--no-plugins", "--audio", "null"])
        .arg("--listen")
        .arg(&socket)
        .args(["--listen-tcp", "127.0.0.1:0", "--token-file"])
        .arg(&token_file)
        .env("XDG_CACHE_HOME", &dir)
        .env("XDG_STATE_HOME", &dir)
        .env("XDG_DATA_HOME", &dir)
        .stdin(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .expect("starting daw");
    // It says where it listens once it does.
    let mut address = String::new();
    let stderr = child.stderr.take().unwrap();
    for line in BufReader::new(stderr).lines().map_while(Result::ok) {
        assert!(!line.starts_with("daw: listening on /"), "{line}");
        if let Some(rest) = line.split("listening on ").nth(1) {
            address = rest.split_whitespace().next().unwrap().to_string();
            break;
        }
    }
    assert!(!address.is_empty(), "the kernel said where it listens");
    let token = std::fs::read_to_string(&token_file).unwrap().trim().to_string();
    Instance {
        child,
        socket,
        address,
        token,
        dir,
    }
}

/// The next event called `name`, within a generous while.
fn event(connection: &Connection, name: &str) -> Value {
    let until = Instant::now() + Duration::from_secs(20);
    while let Ok((got, payload)) = connection
        .events
        .recv_timeout(until.saturating_duration_since(Instant::now()))
    {
        if got == name {
            return payload;
        }
    }
    panic!("no `{name}` event arrived");
}

/// Whether anything at all is pushed within `wait`.
fn quiet(connection: &Connection, wait: Duration) -> bool {
    connection.events.recv_timeout(wait).is_err()
}

#[test]
fn calls_and_subscribed_events_over_the_socket() {
    let instance = start("events");
    let mut c = Connection::unix(&instance.socket).unwrap();
    assert!(c.client > 0, "hello gave the connection a number");
    assert_eq!(c.call("eval", json!(["return 1 + 1"])).unwrap(), json!(2));
    // Nothing is pushed that was not asked for.
    c.call("cmd", json!(["track.add"])).unwrap();
    assert!(quiet(&c, Duration::from_millis(300)));
    c.call("subscribe", json!(["transport.*", "track.added"])).unwrap();
    c.call("cmd", json!(["track.add"])).unwrap();
    assert!(event(&c, "track.added")["id"].is_number());
    c.call("cmd", json!(["transport.play"])).unwrap();
    assert!(event(&c, "transport.play")["position"].is_number());
    c.call("cmd", json!(["transport.stop"])).unwrap();
    event(&c, "transport.stop");
    // Another connection hears none of it, and an error is an error.
    let mut other = Connection::unix(&instance.socket).unwrap();
    other.call("cmd", json!(["track.add"])).unwrap();
    assert!(quiet(&other, Duration::from_millis(200)));
    let err = other.call("no_such_method", json!([])).unwrap_err();
    assert!(err.to_string().contains("no method"), "{err}");
    c.call("unsubscribe", json!([])).unwrap();
    // What was on its way before that still arrives.
    while !quiet(&c, Duration::from_millis(300)) {}
    c.call("cmd", json!(["track.add"])).unwrap();
    assert!(quiet(&c, Duration::from_millis(300)));
}

#[test]
fn the_network_wants_the_token() {
    let instance = start("token");
    let mut good = Connection::tcp(&instance.address, &instance.token).unwrap();
    assert_eq!(good.call("eval", json!(["return 6 * 7"])).unwrap(), json!(42));
    let wrong = "0".repeat(32);
    let refused = Connection::tcp(&instance.address, &wrong);
    assert!(refused.is_err(), "a wrong token is refused");
    // Without hello, nothing is answered but the refusal.
    use std::io::Write;
    let mut raw = std::net::TcpStream::connect(&instance.address).unwrap();
    let mut lines = BufReader::new(raw.try_clone().unwrap()).lines();
    let hello: Value = serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap();
    assert_eq!(hello["event"], "hello");
    assert!(hello["payload"]["nonce"].as_str().unwrap().len() >= 16);
    writeln!(raw, "{}", json!({ "id": 1, "method": "eval", "params": ["return 1"] })).unwrap();
    let answer: Value = serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap();
    assert!(answer["error"].as_str().unwrap().contains("hello"), "{answer}");
    assert!(lines.next().is_none(), "and the connection is closed");
    // The first connection is none the worse.
    assert_eq!(good.call("eval", json!(["return 'still here'"])).unwrap(), json!("still here"));
}

#[test]
fn a_watching_frontend_is_sent_what_changed_and_nothing_when_nothing_did() {
    let instance = start("watch");
    let mut c = Connection::unix(&instance.socket).unwrap();
    c.call("eval", json!(["daw.add_track({ name = 'one' })"])).unwrap();
    c.call("frontend.watch", json!([])).unwrap();
    let first = event(&c, "frontend.state");
    let sections = first["sections"].as_object().expect("the whole state at first");
    for name in ["project", "lines", "tracks", "clips", "devices", "view", "kinds"] {
        assert!(sections.contains_key(name), "the first state has `{name}`");
    }
    assert_eq!(sections["tracks"][0]["name"], "one");
    assert!(first["modal"].is_object() && first["levels"].is_array());
    assert!(quiet(&c, Duration::from_millis(400)), "an idle kernel sends nothing");
    // A change sends the parts it touched, and not the bar lines again.
    c.call("eval", json!(["daw.add_track({ name = 'two' })"])).unwrap();
    let next = event(&c, "frontend.state");
    let changed = next["sections"].as_object().expect("something changed");
    assert_eq!(changed["tracks"][1]["name"], "two");
    assert!(!changed.contains_key("lines"), "the lines did not change: {:?}", changed.keys());
    assert!(!changed.contains_key("kinds"));
    // While playing, the position comes without being asked for.
    c.call("eval", json!(["daw.tracks()[1]:add_clip({ start = 0, length = 64 })"])).unwrap();
    c.call("cmd", json!(["transport.play"])).unwrap();
    let mut moved = false;
    for _ in 0..40 {
        let state = event(&c, "frontend.state");
        if state["playing"] == true && state["position"].as_f64().unwrap_or(0.0) > 0.0 {
            moved = true;
            break;
        }
    }
    assert!(moved, "the playhead's position is pushed while playing");
    c.call("cmd", json!(["transport.stop"])).unwrap();
    c.call("frontend.unwatch", json!([])).unwrap();
    while !quiet(&c, Duration::from_millis(300)) {}
    c.call("eval", json!(["daw.add_track({ name = 'three' })"])).unwrap();
    assert!(quiet(&c, Duration::from_millis(300)), "no longer watching");
}

/// The screen a terminal attached over `c` shows, as lines of text, once
/// `ready` says it holds what is waited for.
fn screen(c: &Connection, grid: &mut Grid, ready: impl Fn(&str) -> bool) -> String {
    let until = Instant::now() + Duration::from_secs(20);
    loop {
        let text: String = grid
            .cells
            .chunks(grid.width.max(1) as usize)
            .map(|row| row.iter().filter(|c| c.ch != '\0').map(|c| c.ch).collect::<String>() + "\n")
            .collect();
        if ready(&text) {
            return text;
        }
        let wait = until.saturating_duration_since(Instant::now());
        match c.events.recv_timeout(wait) {
            Ok((name, payload)) if name == "ui.grid" => {
                daw_core::remote::apply(grid, &payload).unwrap();
            }
            Ok(_) => {}
            Err(_) => panic!("the screen never showed what was waited for:\n{text}"),
        }
    }
}

#[test]
fn a_terminal_attaches_to_a_kernel_without_one_types_and_leaves() {
    let instance = start("attach");
    let mut c = Connection::tcp(&instance.address, &instance.token).unwrap();
    c.call("eval", json!(["daw.add_track({ name = 'Remote bass' })"])).unwrap();
    assert!(c.call("ui.input", json!([{ "key": "j" }])).is_err(), "not before attaching");
    c.call("ui.attach", json!([100, 30])).unwrap();
    let mut grid = Grid::new(1, 1);
    let text = screen(&c, &mut grid, |t| t.contains("Remote bass") && t.contains("NORMAL"));
    assert_eq!((grid.width, grid.height), (100, 30));
    assert_eq!(text.lines().count(), 30);
    // Typing goes to the kernel's keys: a command line, and what it does.
    for key in [":", "t", "r", "a", "c", "k", ".", "a", "d", "d", "<CR>"] {
        c.notify("ui.input", json!([{ "key": key }])).unwrap();
    }
    screen(&c, &mut grid, |t| t.contains("Track 2"));
    assert_eq!(c.call("eval", json!(["return #daw.tracks()"])).unwrap(), json!(2));
    // A smaller terminal: the screen is sent whole again at the new size.
    c.notify("ui.input", json!([{ "resize": [60, 20] }])).unwrap();
    screen(&c, &mut grid, |t| t.lines().count() == 20 && t.contains("Track 2"));
    // `:detach` lets this terminal go; the kernel runs on.
    for key in [":", "d", "e", "t", "a", "c", "h", "<CR>"] {
        c.notify("ui.input", json!([{ "key": key }])).unwrap();
    }
    event(&c, "ui.detached");
    assert_eq!(c.call("eval", json!(["return daw.api.ui_attached()"])).unwrap(), json!(false));
    assert_eq!(c.call("eval", json!(["return #daw.tracks()"])).unwrap(), json!(2));
}
