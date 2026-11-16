//! The window, driven for real: each scenario starts an X server on a display
//! of its own, a window manager and the window with a setup script, makes
//! pointer and key gestures with xdotool, and asks the kernel over the
//! window's control socket what it holds afterwards.
//!
//! These need Xvfb, openbox and xdotool (ImageMagick and tesseract too, to photograph
//! the window and find words on it). The dev shell has them; without them the tests
//! say what is missing and pass. A failed scenario leaves `failure.png` and
//! the window's output in its directory under `target/tmp/window`.

use std::fs;
use std::io::Write as _;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Condvar, Mutex, Once};
use std::time::{Duration, Instant};

/// Where things are in the window, in pixels from the corner of its content,
/// worked out from `ui/app.slint` (`header-width`, `row-height`, the
/// ruler's rows, the zoom `beat` starts at) and checked against a
/// screenshot. Scenarios compute their positions from these.
mod place {
    /// The track headers' width: the timeline starts here.
    pub const HEADER_W: i32 = 240;
    /// The transport bar along the top.
    pub const TRANSPORT_H: i32 = 40;
    /// The ruler's main row.
    pub const RULER_H: i32 = 28;
    /// The band under the ruler that shows markers and regions, once there is one.
    pub const MARKER_BAND: i32 = 18;
    /// A track's row at the default height.
    pub const ROW_H: i32 = 66;
    /// A lane shown as a row under its track is this share of a row.
    pub const LANE_ROW_H: i32 = ROW_H * 4 / 5;
    /// A take lane shown under a track's clips is this share of a row.
    pub const TAKE_ROW_H: i32 = ROW_H * 3 / 5;
    /// Pixels to a beat at the zoom the window starts with.
    pub const BEAT_PX: f64 = 28.0;

    /// The x of a beat in the timeline, with the view at the start of the song.
    pub fn beat_x(beat: f64) -> i32 {
        HEADER_W + (beat * BEAT_PX).round() as i32
    }
    /// The y of the top of a track's row (from 0), the markers' band shown or not.
    pub fn row_top(row: i32, markers: bool) -> i32 {
        TRANSPORT_H + RULER_H + if markers { MARKER_BAND } else { 0 } + row * ROW_H
    }
    /// The y of the markers' band's middle.
    pub fn marker_y() -> i32 {
        TRANSPORT_H + RULER_H + MARKER_BAND / 2
    }
}

type Point = (i32, i32);

/// A word read off the screen: where it is in the window, and which line of
/// text it is on.
struct Word {
    text: String,
    line: (u32, u32, u32),
    x: i32,
    y: i32,
    w: i32,
    h: i32,
}

/// How much a screenshot is enlarged before it is read.
const OCR_SCALE: i32 = 3;

/// A word as it is compared: lower case letters and digits only, so that
/// "Render…" and "render" are one.
fn plain(word: &str) -> String {
    word.chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

const DEMO: &str = "dofile('examples/demo-song.lua')";

// ---------------------------------------------------------------- tools

fn on_path(name: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|dir| dir.join(name))
        .find(|path| path.is_file())
}

struct Tools {
    xvfb: PathBuf,
    openbox: PathBuf,
    xdotool: PathBuf,
    import: PathBuf,
    convert: PathBuf,
    tesseract: PathBuf,
}

fn tools() -> Result<Tools, String> {
    let find = |name: &'static str| on_path(name).ok_or(name);
    let all = (
        find("Xvfb"),
        find("openbox"),
        find("xdotool"),
        find("import"),
        find("tesseract"),
        find("convert"),
    );
    match all {
        (Ok(xvfb), Ok(openbox), Ok(xdotool), Ok(import), Ok(tesseract), Ok(convert)) => Ok(Tools {
            xvfb,
            openbox,
            xdotool,
            import,
            tesseract,
            convert,
        }),
        (a, b, c, d, e, f) => {
            let missing: Vec<&str> = [a, b, c, d, e, f]
                .into_iter()
                .filter_map(Result::err)
                .collect();
            Err(format!(
                "{} not installed (`nix develop` has them)",
                missing.join(", ")
            ))
        }
    }
}

/// The `daw` binary beside the window's, built when it is not there.
fn kernel_binary() -> PathBuf {
    let gui = PathBuf::from(env!("CARGO_BIN_EXE_daw-gui"));
    let dir = gui.parent().unwrap().to_path_buf();
    let daw = dir.join("daw");
    static BUILD: Once = Once::new();
    BUILD.call_once(|| {
        if daw.is_file() {
            return;
        }
        let cargo = std::env::var_os("CARGO").unwrap_or_else(|| "cargo".into());
        let mut build = Command::new(cargo);
        build.args(["build", "-p", "daw-tui"]);
        if dir.file_name().is_some_and(|name| name == "release") {
            build.arg("--release");
        }
        let status = build.current_dir(repo()).status();
        assert!(status.is_ok_and(|s| s.success()), "building the daw binary");
    });
    daw
}

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap()
}

// -------------------------------------------------------- a counting gate

/// How many scenes run at once: each is an X server, a window and a kernel.
static SLOTS: (Mutex<usize>, Condvar) = (Mutex::new(0), Condvar::new());
const MAX_SCENES: usize = 3;

struct Slot;

impl Slot {
    fn take() -> Slot {
        let (count, free) = &SLOTS;
        let mut count = count.lock().unwrap();
        while *count >= MAX_SCENES {
            count = free.wait(count).unwrap();
        }
        *count += 1;
        Slot
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        *SLOTS.0.lock().unwrap() -= 1;
        SLOTS.1.notify_one();
    }
}

// ---------------------------------------------------------------- a scene

/// One window on a private display, with everything that serves it. Dropping
/// it ends every process, whether the scenario passed or not.
struct Scene {
    name: String,
    dir: PathBuf,
    tools: Tools,
    display: String,
    xvfb: Child,
    openbox: Child,
    gui: Child,
    /// The kernel the window is a client of, when it did not start one.
    kernel: Option<Child>,
    /// Where that kernel listens on the network.
    tcp: Option<String>,
    socket: PathBuf,
    daw: PathBuf,
    envs: Vec<(&'static str, PathBuf)>,
    /// Where the window's content starts on the screen.
    origin: Point,
    size: Point,
    _slot: Slot,
}

fn signal_group(child: &Child) {
    // Each process leads a group of its own: the window's kernel dies with it.
    unsafe { libc::kill(-(child.id() as i32), libc::SIGKILL) };
}

/// Start `program` as the leader of a group of its own.
fn spawn_group(command: &mut Command) -> Child {
    use std::os::unix::process::CommandExt;
    command
        .process_group(0)
        .spawn()
        .expect("starting a process")
}

/// Whether a server listens on the display, or one is starting on it (its
/// lock file names a process that runs). The files an X server killed
/// without notice leaves behind do not count.
fn display_in_use(number: u32) -> bool {
    let lock = fs::read_to_string(format!("/tmp/.X{number}-lock")).unwrap_or_default();
    let running = lock
        .trim()
        .parse::<u32>()
        .is_ok_and(|pid| Path::new(&format!("/proc/{pid}")).exists());
    running || UnixStream::connect(format!("/tmp/.X11-unix/X{number}")).is_ok()
}

/// An X server on the first display from 120 up that is free. Tests run side
/// by side, so the choice is made one at a time.
fn start_xvfb(tools: &Tools, dir: &Path) -> (Child, String) {
    static PROBE: Mutex<()> = Mutex::new(());
    let _one_at_a_time = PROBE.lock().unwrap();
    for number in 120..400 {
        let socket = format!("/tmp/.X11-unix/X{number}");
        if display_in_use(number) {
            continue;
        }
        let log = fs::File::create(dir.join("xvfb.out")).unwrap();
        let mut command = Command::new(&tools.xvfb);
        command
            .arg(format!(":{number}"))
            .args(["-screen", "0", "1500x960x24", "-nolisten", "tcp"])
            .stdout(Stdio::null())
            .stderr(log);
        let mut child = spawn_group(&mut command);
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if UnixStream::connect(&socket).is_ok() {
                return (child, format!(":{number}"));
            }
            if child.try_wait().unwrap().is_some() || Instant::now() > deadline {
                signal_group(&child);
                let _ = child.wait();
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
    panic!("no free display from :120 up");
}

/// The control socket's path has to fit in a socket address: a short
/// directory when the scratch one is too long.
fn runtime_dir(dir: &Path, name: &str) -> PathBuf {
    let here = dir.join("run");
    if here.as_os_str().len() < 60 {
        here
    } else {
        std::env::temp_dir().join(format!("daw-window-{}-{name}", std::process::id()))
    }
}

impl Scene {
    /// Start the window with `setup` run in its kernel; None, after saying
    /// so, when the tools for it are not installed.
    fn start(name: &str, setup: &str) -> Option<Scene> {
        Scene::launch(name, setup, false)
    }

    /// The same, but the window is a client of a kernel started beside it,
    /// reached over TCP with a token (`--connect`).
    fn start_remote(name: &str, setup: &str) -> Option<Scene> {
        Scene::launch(name, setup, true)
    }

    fn launch(name: &str, setup: &str, remote: bool) -> Option<Scene> {
        let tools = match tools() {
            Ok(tools) => tools,
            Err(missing) => {
                eprintln!("window test {name} skipped: {missing}");
                return None;
            }
        };
        let slot = Slot::take();
        let daw = kernel_binary();
        let dir = Path::new(env!("CARGO_TARGET_TMPDIR"))
            .join("window")
            .join(name);
        let _ = fs::remove_dir_all(&dir);
        let run = runtime_dir(&dir, name);
        let _ = fs::remove_dir_all(&run);
        let mut envs = vec![
            ("HOME", dir.join("home")),
            ("XDG_CACHE_HOME", dir.join("xdg/cache")),
            ("XDG_STATE_HOME", dir.join("xdg/state")),
            ("XDG_DATA_HOME", dir.join("xdg/data")),
            ("XDG_CONFIG_HOME", dir.join("xdg/config")),
            ("XDG_RUNTIME_DIR", run),
            // No test can reach the desktop's portals or session bus.
            (
                "DBUS_SESSION_BUS_ADDRESS",
                "unix:path=/nonexistent/bus".into(),
            ),
        ];
        for (key, path) in &envs {
            if *key != "DBUS_SESSION_BUS_ADDRESS" {
                fs::create_dir_all(path).unwrap();
            }
        }
        let (xvfb, display) = start_xvfb(&tools, &dir);
        envs.push(("DAW_BIN", daw.clone()));

        let mut command = Command::new(&tools.openbox);
        command
            .env("DISPLAY", &display)
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let openbox = spawn_group(&mut command);

        let out = fs::File::create(dir.join("window.out")).unwrap();
        let run = envs
            .iter()
            .find(|(k, _)| *k == "XDG_RUNTIME_DIR")
            .unwrap()
            .1
            .clone();
        let mut kernel = None;
        let mut window_args: Vec<String> =
            ["--clean", "--no-plugins", "--audio", "null", "-e", setup]
                .map(String::from)
                .to_vec();
        let mut socket = None;
        let mut tcp = None;
        if remote {
            let port = {
                let probe = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
                probe.local_addr().unwrap().port()
            };
            let token = dir.join("token");
            fs::write(&token, "window-test-token\n").unwrap();
            let unix = run.join("kernel.sock");
            let mut command = Command::new(&daw);
            command
                .args([
                    "--headless",
                    "--clean",
                    "--no-plugins",
                    "--audio",
                    "null",
                    "--listen",
                ])
                .arg(&unix)
                .arg("--listen-tcp")
                .arg(format!("127.0.0.1:{port}"))
                .arg("--token-file")
                .arg(&token)
                .args(["-e", setup])
                .current_dir(repo())
                .stdin(Stdio::null())
                .stdout(out.try_clone().unwrap())
                .stderr(out.try_clone().unwrap());
            for (key, value) in &envs {
                command.env(key, value);
            }
            kernel = Some(spawn_group(&mut command));
            let deadline = Instant::now() + Duration::from_secs(60);
            while UnixStream::connect(&unix).is_err() {
                assert!(Instant::now() < deadline, "the kernel never listened");
                std::thread::sleep(Duration::from_millis(100));
            }
            window_args = vec![
                "--connect".into(),
                format!("127.0.0.1:{port}"),
                "--token-file".into(),
                token.to_string_lossy().into_owned(),
            ];
            socket = Some(unix);
            tcp = Some(format!("127.0.0.1:{port}"));
        }
        let mut command = Command::new(env!("CARGO_BIN_EXE_daw-gui"));
        command
            .args(&window_args)
            .current_dir(repo())
            .env("DISPLAY", &display)
            .env("RUST_BACKTRACE", "1")
            .env_remove("WAYLAND_DISPLAY")
            .env_remove("XAUTHORITY")
            .stdin(Stdio::null())
            .stdout(out.try_clone().unwrap())
            .stderr(out);
        for (key, value) in &envs {
            command.env(key, value);
        }
        let gui = spawn_group(&mut command);
        let socket = socket.unwrap_or_else(|| run.join(format!("daw-gui-{}.sock", gui.id())));

        let mut scene = Scene {
            name: name.to_string(),
            dir,
            tools,
            display,
            xvfb,
            openbox,
            gui,
            kernel,
            tcp,
            socket,
            daw,
            envs,
            origin: (0, 0),
            size: (0, 0),
            _slot: slot,
        };
        scene.wait_until_shown();
        Some(scene)
    }

    fn wait_until_shown(&mut self) {
        let deadline = Instant::now() + Duration::from_secs(90);
        let id = loop {
            assert!(
                self.alive(),
                "the window ended while starting\n{}",
                self.output()
            );
            assert!(
                Instant::now() < deadline,
                "the window never showed\n{}",
                self.output()
            );
            if let Some(Ok(answer)) = self.try_ctl("return 1") {
                if answer.trim() == "1" {
                    let found = self.xdotool(&["search", "--onlyvisible", "--name", "^daw"]);
                    if let Some(id) = found.lines().next().filter(|l| !l.is_empty()) {
                        break id.to_string();
                    }
                }
            }
            std::thread::sleep(Duration::from_millis(100));
        };
        // At the corner of the screen, so that nothing is partly off it.
        self.xdotool(&["windowmove", &id, "0", "0"]);
        std::thread::sleep(Duration::from_millis(500));
        let geometry = self.xdotool(&["getwindowgeometry", "--shell", &id]);
        let value = |key: &str| -> i32 {
            geometry
                .lines()
                .find_map(|line| line.strip_prefix(key)?.strip_prefix('='))
                .and_then(|v| v.trim().parse().ok())
                .unwrap_or_else(|| panic!("no {key} in {geometry}"))
        };
        self.origin = (value("X"), value("Y"));
        self.size = (value("WIDTH"), value("HEIGHT"));
        // The first state has to arrive and be drawn.
        std::thread::sleep(Duration::from_millis(700));
    }

    fn env_path(&self, key: &str) -> &Path {
        &self.envs.iter().find(|(k, _)| *k == key).unwrap().1
    }

    // ------------------------------------------------------ the kernel

    fn try_ctl(&self, lua: &str) -> Option<Result<String, String>> {
        let output = Command::new(&self.daw)
            .arg("ctl")
            .arg("--socket")
            .arg(&self.socket)
            .arg("eval")
            .arg(lua)
            .envs(self.envs.iter().map(|(k, v)| (*k, v)))
            .output()
            .ok()?;
        let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if output.status.success() {
            Some(Ok(text))
        } else {
            let err = String::from_utf8_lossy(&output.stderr).trim().to_string();
            Some(Err(format!("{text} {err}")))
        }
    }

    /// Run Lua in the kernel (`return ...` to get something back) and say
    /// what it printed.
    fn ctl(&self, lua: &str) -> String {
        match self.try_ctl(lua) {
            Some(Ok(text)) => text,
            Some(Err(err)) => panic!("the kernel answered `{lua}` with an error: {err}"),
            None => panic!("could not run daw ctl"),
        }
    }

    fn number(&self, lua: &str) -> f64 {
        let text = self.ctl(lua);
        text.parse()
            .unwrap_or_else(|_| panic!("`{lua}` gave {text:?}, not a number"))
    }

    /// Wait up to `seconds` for a Lua expression to hold; what the kernel
    /// last said when it did not.
    fn wait_for(&self, condition: &str, seconds: u64) -> Result<(), String> {
        let lua = format!("return ({condition}) and true or false");
        let deadline = Instant::now() + Duration::from_secs(seconds);
        let mut last = String::new();
        while Instant::now() < deadline {
            last = match self.try_ctl(&lua) {
                Some(Ok(text)) if text == "true" => return Ok(()),
                Some(Ok(text)) => text,
                Some(Err(err)) => err,
                None => "no answer".into(),
            };
            std::thread::sleep(Duration::from_millis(100));
        }
        Err(last)
    }

    /// Wait for a Lua expression to hold, as the kernel will take a moment
    /// over what a gesture meant.
    fn expect(&self, what: &str, condition: &str) {
        let Err(last) = self.wait_for(condition, 15) else {
            return;
        };
        let now = self
            .try_ctl(&format!("return {condition}"))
            .map(|r| format!("{r:?}"))
            .unwrap_or_default();
        panic!(
            "{}: expected {what}: `{condition}` (last answer {last}, value {now})",
            self.name
        );
    }

    // ------------------------------------------------------ the window

    fn alive(&mut self) -> bool {
        self.gui.try_wait().unwrap().is_none()
    }

    fn output(&self) -> String {
        fs::read_to_string(self.dir.join("window.out")).unwrap_or_default()
    }

    fn assert_alive(&mut self, what: &str) {
        assert!(self.alive(), "the window ended {what}\n{}", self.output());
        let out = self.output();
        assert!(
            !out.contains("panicked"),
            "the window panicked {what}\n{out}"
        );
    }

    fn wait_gone(&mut self, what: &str) {
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline {
            if !self.alive() {
                return;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        panic!("{}: the window should have ended {what}", self.name);
    }

    /// The window's share of a processor over `seconds`, in percent of one.
    fn cpu_percent(&self, seconds: f64) -> f64 {
        let ticks = || -> f64 {
            let stat = fs::read_to_string(format!("/proc/{}/stat", self.gui.id())).unwrap();
            // Fields after the name in parentheses: user time is the 12th.
            let rest: Vec<&str> = stat[stat.rfind(')').unwrap() + 2..].split(' ').collect();
            rest[11].parse::<f64>().unwrap() + rest[12].parse::<f64>().unwrap()
        };
        let before = ticks();
        std::thread::sleep(Duration::from_secs_f64(seconds));
        let per_second = unsafe { libc::sysconf(libc::_SC_CLK_TCK) } as f64;
        (ticks() - before) / per_second / seconds * 100.0
    }

    // ----------------------------------------------------- the pointer

    fn xdotool(&self, args: &[&str]) -> String {
        let output = Command::new(&self.tools.xdotool)
            .args(args)
            .env("DISPLAY", &self.display)
            .output()
            .expect("running xdotool");
        String::from_utf8_lossy(&output.stdout).to_string()
    }

    fn screen(&self, at: Point) -> (String, String) {
        (
            (self.origin.0 + at.0).to_string(),
            (self.origin.1 + at.1).to_string(),
        )
    }

    fn pause(&self, seconds: f64) {
        std::thread::sleep(Duration::from_secs_f64(seconds));
    }

    fn mouse_to(&self, at: Point) {
        let (x, y) = self.screen(at);
        self.xdotool(&["mousemove", &x, &y]);
        self.pause(0.15);
    }

    fn click(&self, at: Point) {
        self.mouse_to(at);
        self.xdotool(&["click", "1"]);
        self.pause(0.3);
    }

    fn double_click(&self, at: Point) {
        self.mouse_to(at);
        self.xdotool(&["click", "--repeat", "2", "--delay", "50", "1"]);
        self.pause(0.4);
    }

    /// Press at `from`, move to `to` in steps, let go.
    fn drag(&self, from: Point, to: Point) {
        self.mouse_to(from);
        let mut args: Vec<String> = vec![
            "mousedown".into(),
            "1".into(),
            "sleep".into(),
            "0.15".into(),
        ];
        let steps = 14;
        for step in 1..=steps {
            let at = (
                from.0 + (to.0 - from.0) * step / steps,
                from.1 + (to.1 - from.1) * step / steps,
            );
            let (x, y) = self.screen(at);
            args.extend(["mousemove".into(), x, y, "sleep".into(), "0.03".into()]);
        }
        args.extend(["sleep".into(), "0.15".into(), "mouseup".into(), "1".into()]);
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        self.xdotool(&args);
        self.pause(0.4);
    }

    fn key(&self, keys: &str) {
        self.xdotool(&["key", keys]);
        self.pause(0.3);
    }

    fn type_text(&self, text: &str) {
        self.xdotool(&["type", "--delay", "20", text]);
        self.pause(0.3);
    }

    /// The wheel `times` steps up (zooming in, with Ctrl) over `at`.
    fn wheel_with_ctrl(&self, at: Point, up: bool, times: u32) {
        self.mouse_to(at);
        let button = if up { "4" } else { "5" };
        let times = times.to_string();
        self.xdotool(&[
            "keydown", "ctrl", "click", "--repeat", &times, "--delay", "80", button, "keyup",
            "ctrl",
        ]);
        self.pause(0.4);
    }

    /// The window's close button as a window manager sends it.
    fn close_window(&self) {
        self.mouse_to((self.size.0 / 2, self.size.1 / 2));
        self.key("alt+F4");
    }

    /// The file menu, from the project's name at the left of the transport bar.
    fn open_file_menu(&self) {
        self.click((40, place::TRANSPORT_H / 2));
    }

    /// File, Render…: the dialog, up when its Tail field shows.
    fn open_render_dialog(&self) {
        self.open_file_menu();
        self.click_text("Render");
        self.find_text("Tail", 0);
    }

    /// Type `path` in the open render dialog's file field and press Render.
    fn render_to(&self, path: &Path) {
        self.click_right_of("File", 150);
        self.key("ctrl+a");
        self.type_text(path.to_str().unwrap());
        self.click_last_text("Render");
    }

    // ----------------------------------------------- finding text on screen
    //
    // Menu entries and dialog buttons move whenever one is added, so they
    // are found by what they say: the window is photographed, enlarged,
    // inverted (light text on dark reads worse) and read by tesseract.

    /// The words on the window now, with where they are in the window, read
    /// three ways: inverted, with a global threshold and with a local one.
    /// Each misses text the others get (a dialog on a dimmed backdrop; a
    /// light button), and what is found by any counts.
    /// The first match from the top stops at the first reading that finds
    /// it; the last waits for all four, as a reading may miss a later one.
    fn screens(&self, text: &str, nth: i32) -> Vec<Vec<Word>> {
        let mut screens = Vec::new();
        for prepare in [
            &["-negate"][..],
            &["-threshold", "60%"],
            &["-lat", "60x60+3%"],
            &["-lat", "30x30-3%"],
        ] {
            screens.push(self.words(prepare));
            if nth >= 0 && Scene::locate(&screens, text, nth).is_some() {
                break;
            }
        }
        screens
    }

    fn words(&self, prepare: &[&str]) -> Vec<Word> {
        let (import, tesseract) = (&self.tools.import, &self.tools.tesseract);
        let crop = format!(
            "{}x{}+{}+{}",
            self.size.0, self.size.1, self.origin.0, self.origin.1
        );
        let mut shot = Command::new(import)
            .args(["-window", "root", "-crop", &crop, "+repage", "png:-"])
            .env("DISPLAY", &self.display)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("running import");
        let mut larger = Command::new(&self.tools.convert)
            .arg("png:-")
            .args(["-resize", &format!("{}%", OCR_SCALE * 100)])
            .args(prepare)
            .args(["-colorspace", "Gray", "png:-"])
            .stdin(Stdio::from(shot.stdout.take().unwrap()))
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("running convert");
        let read = Command::new(tesseract)
            .args(["stdin", "stdout", "--psm", "11", "tsv"])
            .stdin(Stdio::from(larger.stdout.take().unwrap()))
            .stderr(Stdio::null())
            .output()
            .expect("running tesseract");
        let _ = shot.wait();
        let _ = larger.wait();
        let scale = OCR_SCALE as f64;
        String::from_utf8_lossy(&read.stdout)
            .lines()
            .filter_map(|line| {
                let f: Vec<&str> = line.split('\t').collect();
                if f.len() < 12 || f[0] != "5" {
                    return None;
                }
                let n = |i: usize| f[i].parse::<f64>().ok();
                Some(Word {
                    text: f[11].to_string(),
                    line: (n(2)? as u32, n(3)? as u32, n(4)? as u32),
                    x: (n(6)? / scale) as i32,
                    y: (n(7)? / scale) as i32,
                    w: (n(8)? / scale) as i32,
                    h: (n(9)? / scale) as i32,
                })
            })
            .collect()
    }

    /// Where `text` is among `words`, as the middle of its words in the
    /// window: the `nth` match from the top of the window (the last with
    /// `nth` negative, counting from -1).
    fn locate(screens: &[Vec<Word>], text: &str, nth: i32) -> Option<Point> {
        let wanted: Vec<String> = text
            .split_whitespace()
            .map(plain)
            .filter(|w| !w.is_empty())
            .collect();
        let mut found: Vec<Point> = Vec::new();
        for words in screens {
            Scene::locate_in(words, &wanted, &mut found);
        }
        // The same words read in more than one way are one.
        let mut unique: Vec<Point> = Vec::new();
        for at in found {
            if !unique
                .iter()
                .any(|u| (u.0 - at.0).abs() < 12 && (u.1 - at.1).abs() < 12)
            {
                unique.push(at);
            }
        }
        let mut found = unique;
        found.sort_by_key(|&(x, y)| (y / 12, x));
        let at = if nth < 0 {
            found.len() as i32 + nth
        } else {
            nth
        };
        usize::try_from(at)
            .ok()
            .and_then(|at| found.get(at).copied())
    }

    fn locate_in(words: &[Word], wanted: &[String], found: &mut Vec<Point>) {
        let words: Vec<(&Word, String)> = words
            .iter()
            .map(|w| (w, plain(&w.text)))
            .filter(|(_, p)| !p.is_empty())
            .collect();
        for start in 0..words.len().saturating_sub(wanted.len() - 1) {
            let run = &words[start..start + wanted.len()];
            let same_line = run.iter().all(|(w, _)| w.line == run[0].0.line);
            if same_line && run.iter().zip(wanted).all(|((_, p), w)| p == w) {
                let left = run.iter().map(|(w, _)| w.x).min().unwrap();
                let right = run.iter().map(|(w, _)| w.x + w.w).max().unwrap();
                let top = run.iter().map(|(w, _)| w.y).min().unwrap();
                let bottom = run.iter().map(|(w, _)| w.y + w.h).max().unwrap();
                found.push(((left + right) / 2, (top + bottom) / 2));
            }
        }
    }

    /// Wait for `text` to show and say where.
    fn find_text(&self, text: &str, nth: i32) -> Point {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let screens = self.screens(text, nth);
            if let Some(at) = Scene::locate(&screens, text, nth) {
                return at;
            }
            if Instant::now() > deadline {
                let seen: Vec<&str> = screens.iter().flatten().map(|w| w.text.as_str()).collect();
                panic!(
                    "{}: no `{text}` on the screen; the words seen: {}",
                    self.name,
                    seen.join(" ")
                );
            }
            self.pause(0.3);
        }
    }

    /// Whether `text` shows within `seconds`.
    fn shows(&self, text: &str, seconds: u64) -> bool {
        let deadline = Instant::now() + Duration::from_secs(seconds);
        loop {
            if Scene::locate(&self.screens(text, 0), text, 0).is_some() {
                return true;
            }
            if Instant::now() > deadline {
                return false;
            }
            self.pause(0.3);
        }
    }

    /// Click the first `text` from the top of the window.
    fn click_text(&self, text: &str) {
        self.click(self.find_text(text, 0));
    }

    /// Click the last `text` (a dialog's button, under its title).
    fn click_last_text(&self, text: &str) {
        self.click(self.find_text(text, -1));
    }

    /// Click `dx` pixels right of `text`: a field beside its label.
    fn click_right_of(&self, text: &str, dx: i32) {
        let (x, y) = self.find_text(text, 0);
        self.click((x + dx, y));
    }

    fn shot(&self, file: &str) {
        let _ = Command::new(&self.tools.import)
            .args(["-window", "root"])
            .arg(self.dir.join(file))
            .env("DISPLAY", &self.display)
            .output();
    }
}

impl Drop for Scene {
    fn drop(&mut self) {
        if std::thread::panicking() {
            self.shot("failure.png");
            let out = self.output();
            let tail: Vec<&str> = out.lines().rev().take(20).collect();
            let tail: Vec<&str> = tail.into_iter().rev().collect();
            eprintln!(
                "window test {} failed; screenshot and output are in {}\n{}",
                self.name,
                self.dir.display(),
                tail.join("\n")
            );
        }
        for child in [
            Some(&mut self.gui),
            Some(&mut self.openbox),
            self.kernel.as_mut(),
        ]
        .into_iter()
        .flatten()
        {
            signal_group(child);
            let _ = child.wait();
        }
        // The X server is asked to go, so that it removes its socket.
        unsafe { libc::kill(self.xvfb.id() as i32, libc::SIGTERM) };
        let deadline = Instant::now() + Duration::from_secs(3);
        while self.xvfb.try_wait().unwrap().is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        signal_group(&self.xvfb);
        let _ = self.xvfb.wait();
        let _ = std::io::stderr().flush();
        // The socket is in a directory that may not be ours to keep.
        let run = self.env_path("XDG_RUNTIME_DIR").to_path_buf();
        if run.starts_with(std::env::temp_dir()) {
            let _ = fs::remove_dir_all(run);
        }
    }
}

/// Start a scene or end the test, saying why, when the tools are missing.
macro_rules! scene {
    ($name:expr, $setup:expr) => {
        match Scene::start($name, $setup) {
            Some(scene) => scene,
            None => return,
        }
    };
    ($name:expr, $setup:expr, remote) => {
        match Scene::start_remote($name, $setup) {
            Some(scene) => scene,
            None => return,
        }
    };
}

// ---------------------------------------------------------------- scenarios

#[test]
fn demo_song_shows_and_answers_the_pointer() {
    let mut w = scene!("demo", DEMO);

    // It starts with the demo song and shows it.
    w.pause(3.0);
    w.assert_alive("after showing the demo song");
    assert_eq!(w.number("return #daw.api.track_list()"), 5.0);
    w.shot("demo.png");

    // A click on a header selects the track.
    let keys = w.number("return daw.api.track_list()[3]") as i32;
    assert_eq!(
        w.ctl(&format!("return daw.api.track_get({keys}).name")),
        "Keys"
    );
    w.click((70, place::row_top(2, false) + 17));
    w.expect(
        "the cursor on Keys",
        &format!("daw.cursor.track_id() == {keys}"),
    );
    let first = w.number("return daw.api.track_list()[1]") as i32;
    w.click((70, place::row_top(0, false) + 17));
    w.expect(
        "the cursor on Drums",
        &format!("daw.cursor.track_id() == {first}"),
    );

    // The M button mutes the track, and again lets it sound.
    let bass = w.number("return daw.api.track_list()[2]") as i32;
    let mute = (134, place::row_top(1, false) + 17);
    w.click(mute);
    w.expect("Bass muted", &format!("daw.api.track_get({bass}).mute"));
    w.click(mute);
    w.expect(
        "Bass sounding",
        &format!("not daw.api.track_get({bass}).mute"),
    );

    // The file menu opens from the project's name; Render… opens the dialog,
    // and a typed path and the Render button write the file.
    let target = w.dir.join("render/song.wav");
    fs::create_dir_all(target.parent().unwrap()).unwrap();
    w.open_render_dialog();
    w.shot("render-dialog.png");
    w.render_to(&target);
    wait_for_file(&target, 1000);
    w.assert_alive("after rendering");
}

/// Wait for a file of at least `size` bytes.
fn wait_for_file(path: &Path, size: u64) {
    let deadline = Instant::now() + Duration::from_secs(60);
    while !fs::metadata(path).is_ok_and(|m| m.len() >= size) {
        assert!(Instant::now() < deadline, "no file at {}", path.display());
        std::thread::sleep(Duration::from_millis(200));
    }
}

/// A song with a project file, so that Save has somewhere to write.
fn saved_song(path: &Path) -> String {
    format!("{DEMO}\ndaw.project.save('{}')", path.display())
}

#[test]
fn closing_with_unsaved_changes_asks() {
    // Autosave on: a copy of the unsaved project is made and must go when
    // it is thrown away.
    let mut w = scene!("closing", &format!("daw.opt.autosave = 1\n{DEMO}"));
    let recovery = w.env_path("XDG_STATE_HOME").join("daw/recovery");
    let copies = || -> usize {
        fs::read_dir(&recovery)
            .map(|dir| dir.filter_map(Result::ok).count())
            .unwrap_or(0)
    };
    let deadline = Instant::now() + Duration::from_secs(30);
    while copies() == 0 {
        assert!(Instant::now() < deadline, "no recovery copy was made");
        w.pause(0.2);
    }

    // Cancel keeps it running.
    w.close_window();
    w.shot("closing.png");
    w.click_text("Cancel");
    w.pause(1.0);
    w.assert_alive("after Cancel");
    w.expect(
        "the project still unsaved",
        "daw.api.project_get().modified",
    );

    // Don't save ends it, and the copy goes with it.
    w.close_window();
    w.click_text("Don't save");
    w.wait_gone("after Don't save");
    assert_eq!(copies(), 0, "a recovery copy was left behind");
}

#[test]
fn closing_with_a_project_file_saves_it() {
    let file = {
        let mut dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join("window/closing-saves-files");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir.push("song.json");
        dir
    };
    let mut w = scene!("closing-saves", &saved_song(&file));
    w.ctl("daw.add_track({ name = 'Added after saving' })");
    w.expect("the added track unsaved", "daw.api.project_get().modified");
    let saved = fs::read_to_string(&file).unwrap();
    assert!(
        !saved.contains("Added after saving"),
        "the file already holds the change"
    );

    w.close_window();
    w.click_last_text("Save");
    w.wait_gone("after Save");
    let saved = fs::read_to_string(&file).unwrap();
    assert!(
        saved.contains("Added after saving"),
        "Save did not write the change into {}",
        file.display()
    );
}

#[test]
fn lane_rows_take_drawn_points_and_markers_take_clicks() {
    let mut w = scene!("lanes", DEMO);
    w.ctl("return daw.markers.add(8, 'Verse').id");

    // The first track's lanes as rows, and a drag across the row draws.
    let drums = w.number("return daw.api.track_list()[1]") as i32;
    w.ctl(&format!("return daw.frontend.act.lane_rows({drums})"));
    w.expect(
        "a lane row on Drums",
        &format!("#daw.frontend.state(0).tracks[1].lane_rows == 1"),
    );
    w.pause(0.8);
    let lane = w.number(&format!("return daw.api.lane_list({drums})[1].id")) as i32;
    assert_eq!(
        w.number(&format!("return #daw.api.lane_points({lane})")),
        0.0
    );
    let band = place::row_top(0, true) + place::ROW_H;
    let (low, high) = (
        band + place::LANE_ROW_H * 9 / 10,
        band + place::LANE_ROW_H / 10,
    );
    w.drag((place::beat_x(2.0), low), (place::beat_x(10.0), high));
    w.shot("lane-drawn.png");
    w.expect(
        "points drawn",
        &format!("#daw.api.lane_points({lane}) >= 6"),
    );
    w.expect(
        "points between the beats dragged across",
        &format!(
            "(function() local lo, hi = 1e9, -1e9 for _, p in ipairs(daw.api.lane_points({lane})) do lo = math.min(lo, p[1]) hi = math.max(hi, p[1]) end return lo >= 1.5 and hi <= 10.5 and hi >= 8 end)()"
        ),
    );
    w.expect(
        "a curve, not one level",
        &format!(
            "(function() local pts = daw.api.lane_points({lane}) return math.abs(pts[1][2] - pts[#pts][2]) > 0.5 end)()"
        ),
    );
    w.assert_alive("after drawing in a lane");

    // A click on the marker puts the edit cursor at it.
    w.expect("the cursor elsewhere", "daw.cursor.beat ~= 8");
    w.click((place::beat_x(8.0) + 24, place::marker_y()));
    w.expect("the edit cursor at the marker", "daw.cursor.beat == 8");
    w.assert_alive("after clicking a marker");
}

/// A track with a clip and an empty one, for gestures on clips.
const CLIP_SONG: &str = "
local a = daw.add_track({ name = 'A' })
daw.add_track({ name = 'B' })
a:add_clip({ start = 4, length = 4, name = 'c', notes = { { pitch = 60, start = 0, length = 1 } } })
";

#[test]
fn clips_move_trim_and_are_made_by_the_pointer() {
    let mut w = scene!("clips", CLIP_SONG);
    let a = w.number("return daw.api.track_list()[1]") as i32;
    let b = w.number("return daw.api.track_list()[2]") as i32;
    let clip = |field: &str| format!("daw.api.clip_get(daw.api.clip_list({a})[1].id).{field}");
    let top = place::row_top(0, false);
    let body = top + place::ROW_H * 2 / 3;
    assert_eq!(w.number(&format!("return {}", clip("start"))), 4.0);

    // Dragged eight beats along, it lands on the beat there.
    w.drag((place::beat_x(5.5), body), (place::beat_x(13.5), body));
    w.expect("the clip at beat 12", &format!("{} == 12", clip("start")));
    w.expect("its length kept", &format!("{} == 4", clip("length")));
    w.shot("clip-moved.png");

    // The end edge, dragged two beats, makes it longer.
    w.drag(
        (place::beat_x(16.0) - 3, body),
        (place::beat_x(18.0) - 3, body),
    );
    w.expect(
        "the clip six beats long",
        &format!("{} == 6", clip("length")),
    );
    w.expect("its start kept", &format!("{} == 12", clip("start")));

    // The start edge, dragged a beat in, shortens it from the front.
    w.drag(
        (place::beat_x(12.0) + 3, body),
        (place::beat_x(13.0) + 3, body),
    );
    w.expect(
        "the clip starting at 13",
        &format!("{} == 13", clip("start")),
    );
    w.expect(
        "the end kept",
        &format!(
            "{} == 18",
            format!("{} + {}", clip("start"), clip("length"))
        ),
    );

    // A double click on an empty stretch of the second track makes a clip.
    assert_eq!(w.number(&format!("return #daw.api.clip_list({b})")), 0.0);
    w.double_click((
        place::beat_x(20.3),
        place::row_top(1, false) + place::ROW_H / 2,
    ));
    w.expect("a clip on B at bar 20", &format!("#daw.api.clip_list({b}) == 1 and daw.api.clip_get(daw.api.clip_list({b})[1].id).start == 20"));
    w.assert_alive("after editing clips");
}

/// 4000 beats: long clips (one with a note every few beats), a long region,
/// and an automation lane with points all across it.
const LONG_SONG: &str = "
daw.project.tempo = 120
local track = daw.add_track({ name = 'Long' })
local notes = {}
for beat = 0, 2996, 4 do notes[#notes + 1] = { pitch = 48 + math.floor(beat / 4) % 24, start = beat, length = 2 } end
track:add_clip({ start = 0, length = 3000, name = 'long', notes = notes })
track:add_clip({ start = 3000, length = 1000, name = 'tail', notes = { { pitch = 60, start = 0, length = 4 } } })
daw.add_track({ name = 'Other' }):add_clip({ start = 100, length = 2000, name = 'other', notes = { { pitch = 50, start = 0, length = 8 } } })
daw.markers.add(100, 'Region', { length = 3000 })
daw.markers.add(2000, 'Middle')
local id = daw.api.track_list()[1]
local lane = daw.api.lane_add(id, { target = 'volume' })
for beat = 0, 4000, 8 do daw.api.lane_add_point(lane, beat, beat % 16 == 0 and -3 or -12) end
";

#[test]
fn a_very_long_song_does_not_hurt_the_window() {
    let mut w = scene!("long", LONG_SONG);
    w.expect(
        "the song 4000 beats long",
        "daw.api.project_get().length >= 4000",
    );
    w.ctl("return daw.frontend.act.lane_rows(daw.api.track_list()[1])");
    w.pause(3.0);
    w.assert_alive("after showing it");
    let idle = w.cpu_percent(3.0);
    assert!(
        idle < 40.0,
        "the window uses {idle:.0}% of a core when idle"
    );

    // Zooming in, and out again, with Ctrl and the wheel.
    let over = (
        place::beat_x(10.0),
        place::row_top(1, true) + place::ROW_H / 2,
    );
    w.wheel_with_ctrl(over, true, 12);
    w.assert_alive("after zooming in");
    w.wheel_with_ctrl(over, false, 20);
    w.assert_alive("after zooming out");
    w.key("ctrl+0");
    w.assert_alive("after showing the whole song");
    w.shot("long-fit.png");
    w.wheel_with_ctrl(over, true, 14);
    w.assert_alive("after zooming in again");

    // The notes of the long clip, in the piano roll, opened by a double
    // click (again if the window was too busy to take two clicks as one).
    let notes_at = (
        place::beat_x(10.0),
        place::row_top(0, true) + place::ROW_H * 2 / 3,
    );
    for _ in 0..3 {
        w.double_click(notes_at);
        if w.wait_for("daw.ui.visible('pianoroll')", 5).is_ok() {
            break;
        }
    }
    w.expect("the piano roll open", "daw.ui.visible('pianoroll')");
    w.pause(1.0);
    w.assert_alive("after opening the piano roll");
    w.shot("long-roll.png");
}

// The roll shows only the notes in view, so a clip of 3000 beats costs no
// more than a short one. (Before that it used about 90% of a core.)
#[test]
fn a_piano_roll_on_a_very_long_clip_is_idle() {
    let mut w = scene!("long-roll", LONG_SONG);
    let clip = w.number("return daw.api.clip_list(daw.api.track_list()[1])[1].id") as i32;
    w.ctl(&format!("return daw.frontend.act.open_clip({clip})"));
    w.expect("the piano roll open", "daw.ui.visible('pianoroll')");
    w.pause(3.0);
    let busy = w.cpu_percent(3.0);
    assert!(
        busy < 40.0,
        "the window uses {busy:.0}% of a core with the roll open"
    );
    w.assert_alive("at the end");
}

/// A directory of this test's own, outside the scene's (which is wiped at
/// the start), for files that must exist before the window starts.
fn files_dir(name: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR"))
        .join("window")
        .join(format!("{name}-files"));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn an_idle_window_uses_little_of_a_processor() {
    let mut w = scene!("idle", DEMO);
    w.pause(3.0);
    let idle = w.cpu_percent(5.0);
    assert!(idle < 5.0, "the idle window uses {idle:.1}% of a core");
    w.assert_alive("while idle");
}

#[test]
fn the_file_menu_lists_recent_projects_and_opens_one() {
    let dir = files_dir("recent");
    let file = dir.join("recentsong.json");
    let setup = format!(
        "daw.recent.use('{}/recent.json')\n{DEMO}\ndaw.project.save('{}')\ndaw.project.new()",
        dir.display(),
        file.display()
    );
    let mut w = scene!("recent", &setup);
    w.expect("an empty project", "daw.api.project_get().path == nil");
    w.open_file_menu();
    w.click_text("Open recent");
    w.shot("recent-menu.png");
    w.click_text("recentsong");
    w.expect(
        "the saved project open",
        &format!("daw.api.project_get().path == '{}'", file.display()),
    );
    w.expect("its tracks", "#daw.api.track_list() == 5");
    w.assert_alive("after opening a recent project");
}

#[test]
fn the_render_dialog_offers_mp3() {
    if on_path("ffmpeg").is_none() {
        eprintln!("window test mp3 skipped: ffmpeg is not installed");
        return;
    }
    let mut w = scene!("mp3", DEMO);
    let target = w.dir.join("render/song.mp3");
    fs::create_dir_all(target.parent().unwrap()).unwrap();
    w.open_render_dialog();
    w.click_text("MP3");
    w.render_to(&target);
    wait_for_file(&target, 1000);
    // MP3 starts with an ID3 tag or a frame header.
    let head = fs::read(&target).unwrap();
    assert!(
        head.starts_with(b"ID3") || (head[0] == 0xff && head[1] & 0xe0 == 0xe0),
        "not an MP3 file"
    );
    w.assert_alive("after rendering");
}

#[test]
fn take_lanes_show_the_takes_and_a_click_chooses_one() {
    let setup = "
local track = daw.add_track({ name = 'T' })
local id = daw.api.track_list()[1]
track:add_clip({ start = 0, length = 8, name = 'c', notes = { { pitch = 60, start = 0, length = 1 } } })
daw.takes.new(daw.api.clip_list(id)[1].id)
daw.cursor.set_track(id)
";
    let mut w = scene!("takes", setup);
    let clip = "daw.api.clip_list(daw.api.track_list()[1])[1].id";
    w.expect(
        "two takes, the second playing",
        &format!("select(2, daw.takes.count({clip})) == 2"),
    );
    w.ctl("return daw.commands.exec('take.lanes')");
    w.expect(
        "two take rows",
        "daw.frontend.state(0).tracks[1].take_rows == 2",
    );
    w.pause(0.8);
    w.shot("take-lanes.png");
    // Row k of the lanes is under the clip: the first take's row is the
    // first.
    let first = place::row_top(0, false) + place::ROW_H + place::TAKE_ROW_H / 2;
    w.click((place::beat_x(2.0), first));
    w.expect(
        "the first take playing",
        &format!("select(2, daw.takes.count({clip})) == 1"),
    );
    w.assert_alive("after choosing a take");
}

#[test]
fn the_more_menu_opens_a_view_in_a_window_of_its_own() {
    let mut w = scene!(
        "more",
        &format!("{DEMO}\ndaw.ext.load('extensions/undotree')")
    );
    assert_eq!(w.number("return #daw.canvas.windows()"), 0.0);
    w.click_text("More");
    w.shot("more-menu.png");
    w.click_text("Undo tree");
    w.expect(
        "the undo tree open in a window",
        "#daw.canvas.windows() == 1 and daw.canvas.windows()[1].name == 'undotree'",
    );
    w.pause(1.0);
    w.assert_alive("after opening a view in a window");
}

#[test]
fn the_window_follows_a_change_made_from_outside() {
    let mut w = scene!("pushed", DEMO);
    assert!(!w.shows("Zebra", 0), "the track is there before it is made");
    w.ctl("return daw.add_track({ name = 'Zebra' }).id");
    assert!(
        w.shows("Zebra", 10),
        "a track added from outside does not show in the window"
    );
    w.ctl("return daw.api.track_set(daw.api.track_list()[6], 'name', 'Okapi')");
    assert!(
        w.shows("Okapi", 10),
        "a track renamed from outside does not show"
    );
    w.assert_alive("after changes from outside");
}

#[test]
fn a_window_connects_to_a_kernel_over_tcp_and_a_wrong_token_is_refused() {
    let mut w = scene!("remote", DEMO, remote);
    assert!(w.shows("Drums", 20), "the remote project does not show");
    w.ctl("return daw.add_track({ name = 'Zebra' }).id");
    assert!(
        w.shows("Zebra", 10),
        "a change at the remote kernel does not show"
    );
    w.assert_alive("while connected");

    let refused = Command::new(env!("CARGO_BIN_EXE_daw-gui"))
        .args([
            "--connect",
            w.tcp.as_deref().unwrap(),
            "--token",
            "not-the-token",
        ])
        .env("DISPLAY", &w.display)
        .env("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent/bus")
        .output()
        .unwrap();
    let said = String::from_utf8_lossy(&refused.stderr).to_string()
        + &String::from_utf8_lossy(&refused.stdout);
    assert!(!refused.status.success(), "a wrong token was taken: {said}");
    assert!(said.contains("did not accept the token"), "{said}");
}

/// How reliably the screen is read, for whoever changes how: every text the
/// tests click, in each place they click it, over fresh windows. Run it
/// with `cargo test -p daw-gui --test window -- --ignored --nocapture
/// reading_the_screen`; it says how many readings found each text.
#[test]
#[ignore = "a measurement, not a test: it takes minutes"]
fn reading_the_screen_is_reliable() {
    const RUNS: usize = 8;
    let (mut tried, mut found) = (0, 0);
    for run in 0..RUNS {
        let mut w = scene!(
            "reading",
            &format!("{DEMO}\ndaw.ext.load('extensions/undotree')")
        );
        let mut check = |w: &Scene, texts: &[(&str, i32)]| {
            for &(text, nth) in texts {
                tried += 1;
                let at = Scene::locate(&w.screens(text, nth), text, nth);
                if at.is_some() {
                    found += 1;
                } else {
                    eprintln!("run {run}: `{text}` not found");
                }
            }
        };
        w.open_file_menu();
        check(
            &w,
            &[
                ("New project", 0),
                ("Open recent", 0),
                ("Save as", 0),
                ("Render", 0),
                ("Quit", 0),
            ],
        );
        w.click((700, 700));
        w.click_text("More");
        check(&w, &[("Undo tree", 0)]);
        w.click((700, 700));
        w.open_render_dialog();
        check(
            &w,
            &[
                ("File", 0),
                ("Tail", 0),
                ("MP3", 0),
                ("Cancel", 0),
                ("Render", -1),
            ],
        );
        w.click_text("Cancel");
        w.close_window();
        check(&w, &[("Don't save", 0), ("Cancel", 0), ("Save", -1)]);
    }
    eprintln!("read {found} of {tried}");
    assert_eq!(found, tried);
}
