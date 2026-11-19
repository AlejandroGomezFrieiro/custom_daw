//! `paw-gui`: a window onto a kernel.
//!
//! The frontend holds no project state. The kernel pushes the state to
//! draw when it changes over the control socket, and what the user does
//! goes back as commands. With `--socket` it attaches to a kernel that is
//! already running; otherwise it starts one of its own and stops it on exit.

use std::path::PathBuf;
use std::process::Child;

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};

mod app;
mod canvas;
mod chrome;
mod client;
mod dialogs;
mod icons;
mod damage;
mod keys;
mod menu;
mod model;
mod panes;
mod pictures;
mod portal;
mod roles;
mod runner;
mod scene;
#[cfg(test)]
mod gestures;
mod theme;
mod timeline;
mod widgets;

use client::Client;

const HELP: &str = "\
paw-gui: a graphical frontend for paw

Usage:
  paw-gui [kernel options] [project]   start a kernel and show it
  paw-gui --socket <path>              show a kernel that is already running
  paw-gui --connect <host:port> --token-file <path>
                                       show one running on another machine
                                       (started with --listen-tcp; the token
                                       is also taken from --token or $PAW_TOKEN)
    --accept-certificate               take the certificate it shows though
                                       another was remembered for it
    --no-tls                           connect in the clear, to one started
                                       with --no-tls
    --listen-audio                     play its sound here (about 1 Mbit/s);
                                       also in the engine menu

Options:
  --renderer gpu|software   draw with OpenGL on the graphics card (the
                            default) or have Mesa draw on the processor
                            (llvmpipe); also PAW_GUI_RENDERER

Kernel options are passed on to `paw --headless`; see `paw --help`.
";

/// How the window is drawn: OpenGL on whatever driver the system has, or
/// asked of Mesa's processor driver.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Renderer {
    Gpu,
    Software,
}

/// The renderer asked for with `--renderer` (taken out of `args`, which go
/// on to the kernel), else by `env` (`PAW_GUI_RENDERER`); else the GPU.
fn renderer_choice(args: &mut Vec<String>, env: Option<&str>) -> Result<Renderer> {
    let named = match args.iter().position(|a| a == "--renderer") {
        Some(at) => {
            let name = args.get(at + 1).context("--renderer needs gpu or software")?.clone();
            args.drain(at..at + 2);
            Some(name)
        }
        None => env.filter(|name| !name.is_empty()).map(str::to_string),
    };
    match named.as_deref() {
        None | Some("gpu") => Ok(Renderer::Gpu),
        Some("software") => Ok(Renderer::Software),
        Some(other) => bail!("the renderer is gpu or software, not {other}"),
    }
}

/// Whether an OpenGL renderer draws on the processor: Mesa's llvmpipe,
/// softpipe and swrast, and lavapipe under zink.
pub fn is_software(renderer: &str) -> bool {
    let name = renderer.to_lowercase();
    ["llvmpipe", "softpipe", "swrast", "software rasterizer", "lavapipe"].iter().any(|n| name.contains(n))
}

/// What the window tells the kernel of the OpenGL that draws it
/// (`paw.frontend.window_renderer`): the renderer's name and version,
/// whether it draws on the processor, and the likely cause when it does:
/// `asked` (`--renderer software`, `PAW_GUI_RENDERER`), `libgl`
/// (`LIBGL_ALWAYS_SOFTWARE` set), `no-card` (no graphics card in
/// /dev/dri) or `driver` (a card, but its driver or DRI3 missing).
fn renderer_report(renderer: &str, version: &str, asked: bool, libgl: bool, card: bool) -> Value {
    let software = is_software(renderer);
    let cause = match () {
        _ if !software => None,
        _ if asked => Some("asked"),
        _ if libgl => Some("libgl"),
        _ if !card => Some("no-card"),
        _ => Some("driver"),
    };
    json!({ "renderer": renderer, "version": version, "software": software, "cause": cause })
}

/// Whether the machine has a graphics card the window could draw on.
fn has_card() -> bool {
    std::fs::read_dir("/dev/dri").is_ok_and(|dir| dir.flatten().any(|e| e.file_name().to_string_lossy().starts_with("renderD")))
}

/// The X authority file to use when the one the environment names is gone:
/// the newest of those a desktop keeps in the runtime directory, else the
/// one in the home directory.
fn find_authority(runtime: Option<&std::path::Path>, home: Option<&std::path::Path>) -> Option<PathBuf> {
    let mut found: Vec<(std::time::SystemTime, PathBuf)> = Vec::new();
    for entry in runtime.and_then(|dir| std::fs::read_dir(dir).ok()).into_iter().flatten().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with("xauth_") || name.starts_with(".mutter-Xwaylandauth") {
            let modified = entry.metadata().and_then(|m| m.modified()).ok();
            found.push((modified.unwrap_or(std::time::UNIX_EPOCH), entry.path()));
        }
    }
    found.sort_by_key(|candidate| std::cmp::Reverse(candidate.0));
    found
        .into_iter()
        .map(|(_, path)| path)
        .chain(home.map(|home| home.join(".Xauthority")))
        .find(|path| path.exists())
}

/// A terminal that has outlived a restart of the display still names the
/// old display's authority file, and no window can be opened from it. Use
/// the one the display has now. Called before anything else is started: it
/// changes the environment, which the kernel started from here inherits.
fn repair_display_env() {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from);
    // The same for Wayland: a name with no compositor behind it would be
    // tried, fail, and leave no window at all. Without the name, X is used.
    if let Some(name) = std::env::var_os("WAYLAND_DISPLAY") {
        let socket = match &runtime {
            Some(dir) => dir.join(&name),
            None => PathBuf::from(&name),
        };
        if !socket.exists() && std::env::var_os("DISPLAY").is_some() {
            unsafe { std::env::remove_var("WAYLAND_DISPLAY") };
        }
    }
    let stale = std::env::var_os("XAUTHORITY").map(PathBuf::from);
    if std::env::var_os("DISPLAY").is_none() || stale.as_ref().is_none_or(|file| file.exists()) {
        return;
    }
    let home = std::env::var_os("HOME").map(PathBuf::from);
    if let Some(file) = find_authority(runtime.as_deref(), home.as_deref()) {
        unsafe { std::env::set_var("XAUTHORITY", file) };
    }
}

/// The program: the window, and the kernel it started, if it did.
struct Window {
    view: app::View,
    child: Option<Child>,
}

impl runner::App for Window {
    /// The window's surface, which every frame starts from.
    fn clear_color(&self) -> [f32; 4] {
        theme::th().surface.to_normalized_gamma_f32()
    }

    fn ui(&mut self, ui: &mut egui::Ui) {
        self.view.frame(ui);
    }

    fn partial(&self) -> bool {
        self.view.cache
    }

    /// Keys go to the kernel's mappings unless a text box of the window's
    /// has them: they are taken here, before egui would move its focus
    /// with Tab or press a button with Space.
    fn raw_input_hook(&mut self, _ctx: &egui::Context, raw: &mut egui::RawInput) {
        self.view.hooked = true;
        if self.view.text_focus {
            return;
        }
        let (keys, rest): (Vec<egui::Event>, Vec<egui::Event>) = raw.events.drain(..).partition(|e| {
            matches!(e, egui::Event::Key { .. } | egui::Event::Text(_) | egui::Event::Ime(_) | egui::Event::Copy | egui::Event::Cut | egui::Event::Paste(_))
        });
        raw.events = rest;
        // Escape still lets go of a menu or a dialog of the window's.
        if keys.iter().any(|e| matches!(e, egui::Event::Key { key: egui::Key::Escape, pressed: true, .. })) && (self.view.menu.is_some() || self.view.dialogs.open()) {
            raw.events.push(egui::Event::Key { key: egui::Key::Escape, physical_key: None, pressed: true, repeat: false, modifiers: egui::Modifiers::NONE });
            return;
        }
        self.view.pending_keys.extend(keys.into_iter().map(|e| match e {
            // Ctrl and c, x and v are keys like any other here.
            egui::Event::Copy => key_event(egui::Key::C),
            egui::Event::Cut => key_event(egui::Key::X),
            egui::Event::Paste(_) => key_event(egui::Key::V),
            other => other,
        }));
    }

    fn on_exit(&mut self) {
        if let Some(child) = &mut self.child {
            // The window is gone: so is the kernel it started, unless it has
            // ended already. What was unsaved was asked about before this.
            if !matches!(child.try_wait(), Ok(Some(_))) {
                let _ = self.view.k.borrow_mut().call("quit", json!([0]));
            }
            let _ = child.wait();
        }
    }
}

fn key_event(key: egui::Key) -> egui::Event {
    egui::Event::Key { key, physical_key: None, pressed: true, repeat: false, modifiers: egui::Modifiers::CTRL }
}

fn run() -> Result<()> {
    repair_display_env();
    // A font for Japanese and the like is looked for while the rest starts.
    let cjk = std::thread::spawn(theme::cjk_font);
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "-h" || a == "--help") {
        print!("{HELP}");
        return Ok(());
    }
    let env = std::env::var("PAW_GUI_RENDERER").ok();
    // Asked of Mesa before this program asks it too.
    let libgl = std::env::var_os("LIBGL_ALWAYS_SOFTWARE").is_some_and(|v| !v.is_empty() && v != "0");
    let asked = renderer_choice(&mut args, env.as_deref())? == Renderer::Software;
    if asked {
        // Mesa draws on the processor; any other driver is not asked.
        unsafe {
            std::env::set_var("LIBGL_ALWAYS_SOFTWARE", "1");
            std::env::set_var("GALLIUM_DRIVER", "llvmpipe");
        }
    }
    // An option of this program's own and its value, taken off the
    // arguments (the rest are the kernel's).
    let mut option = |name: &str| -> Result<Option<String>> {
        let Some(at) = args.iter().position(|a| a == name) else { return Ok(None) };
        let value = args.get(at + 1).with_context(|| format!("{name} needs a value"))?.clone();
        args.drain(at..at + 2);
        Ok(Some(value))
    };
    let socket = option("--socket")?.map(PathBuf::from);
    let address = option("--connect")?;
    let token = match (option("--token")?, option("--token-file")?) {
        (Some(token), _) => Some(token),
        (None, Some(path)) => Some(std::fs::read_to_string(&path).with_context(|| format!("reading the token in {path}"))?.trim().to_string()),
        (None, None) => std::env::var("PAW_TOKEN").ok(),
    };
    let (mut client, child) = match (&address, &socket) {
        (Some(address), _) => {
            let token = token.context("--connect needs the token: --token, --token-file or $PAW_TOKEN")?;
            let flag = |name: &str| args.iter().any(|a| a == name);
            let wire = if flag("--no-tls") {
                paw_proto::Wire::Plain
            } else {
                paw_proto::Wire::Tls { known: paw_proto::tls::known_path(), accept_new: flag("--accept-certificate") }
            };
            let mut client = Client::connect_tcp(address, &token, &wire)?;
            if flag("--listen-audio") {
                client.toggle_listening()?;
            }
            (client, None)
        }
        (None, Some(path)) => (Client::connect(path, false).with_context(|| format!("no kernel at {}", path.display()))?, None),
        (None, None) => {
            let (client, child) = client::start_kernel(&args)?;
            (client, Some(child))
        }
    };
    // The window's colours are the kernel's, and how it was left is kept there.
    let palette = client.eval("return paw.canvas.palette", json!([])).unwrap_or(Value::Null);
    theme::set_theme(theme::Theme::from_palette(&palette));
    let kept = client.eval("return paw.frontend.layout_get()", json!([])).unwrap_or(Value::Null);
    let size = |name: &str| kept[name].as_f64().filter(|v| *v >= 1.0).map(|v| v as f32);
    let mut viewport = egui::ViewportBuilder::default()
        .with_title("paw")
        .with_app_id("paw")
        .with_inner_size([size("width").unwrap_or(1400.0), size("height").unwrap_or(860.0)])
        .with_min_inner_size([860.0, 480.0])
        .with_drag_and_drop(true);
    // Asking for a position does nothing on Wayland, where the compositor
    // decides, and nothing was kept there.
    if let (Some(x), Some(y)) = (kept["x"].as_f64(), kept["y"].as_f64()) {
        viewport = viewport.with_position([x as f32, y as f32]);
    }
    let ours = child.is_some();
    let kernel_pid = child.as_ref().map(|c| c.id());
    runner::run(viewport, move |ctx, gl| {
        ctx.set_fonts(theme::fonts(cjk.join().ok().flatten()));
        ctx.set_visuals(visuals());
        // Which OpenGL draws the window: said in the log, and to the
        // kernel, which says it once when it is the processor.
        let (renderer, version) = (&gl.renderer, &gl.version);
        eprintln!("paw-gui: OpenGL renderer: {renderer} ({version})");
        let report = renderer_report(renderer, version, asked, libgl, has_card());
        let software = report["software"] == true;
        if let Err(err) = client.eval("paw.frontend.window_renderer_set(...)", json!([report])) {
            eprintln!("paw-gui: {err:#}");
        }
        let ctx = ctx.clone();
        // A frame for what came, and one only: egui draws two for a
        // request to draw at once.
        client.wake_on_events(move || ctx.request_repaint_after(std::time::Duration::from_millis(1)));
        let mut view = app::View::new(Box::new(client), ours);
        view.software = software;
        Ok(Box::new(Window { view, child }))
    })
    .map_err(|err| {
        // A kernel started for a window that never opened ends with it.
        if let Some(pid) = kernel_pid {
            unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) };
        }
        anyhow::anyhow!("the window could not start (OpenGL is needed: {err})")
    })?;
    Ok(())
}

/// egui's own widgets (text boxes, scrolling) in the window's colours.
fn visuals() -> egui::Visuals {
    let t = theme::th();
    let mut v = egui::Visuals::dark();
    v.panel_fill = t.surface;
    v.window_fill = t.card;
    v.extreme_bg_color = t.well;
    v.override_text_color = Some(t.text);
    v.selection.bg_fill = theme::alpha(t.select, 0.4);
    v.selection.stroke = egui::Stroke::new(1.0, t.select);
    v.widgets.inactive.bg_fill = t.control;
    v.widgets.inactive.weak_bg_fill = t.control;
    v.widgets.hovered.weak_bg_fill = t.control_hover;
    v.widgets.active.weak_bg_fill = t.control_press;
    v.text_cursor.stroke = egui::Stroke::new(1.5, t.select);
    v
}

fn main() {
    if let Err(err) = run() {
        eprintln!("paw-gui: {err:#}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn the_newest_authority_file_is_found() {
        let dir = std::env::temp_dir().join(format!("paw-gui-test-{}", std::process::id()));
        let (runtime, home) = (dir.join("run"), dir.join("home"));
        std::fs::create_dir_all(&runtime).unwrap();
        std::fs::create_dir_all(&home).unwrap();
        assert_eq!(find_authority(Some(&runtime), Some(&home)), None);
        std::fs::write(home.join(".Xauthority"), "x").unwrap();
        assert_eq!(find_authority(Some(&runtime), Some(&home)), Some(home.join(".Xauthority")), "the one at home when the desktop keeps none");
        std::fs::write(runtime.join("xauth_old"), "x").unwrap();
        std::thread::sleep(Duration::from_millis(20));
        std::fs::write(runtime.join("xauth_new"), "x").unwrap();
        std::fs::write(runtime.join("other"), "x").unwrap();
        assert_eq!(find_authority(Some(&runtime), Some(&home)), Some(runtime.join("xauth_new")), "the desktop's newest first");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_renderer_is_chosen_by_option_then_environment() {
        let mut args: Vec<String> = ["--renderer", "software", "song.json"].map(String::from).into();
        assert_eq!(renderer_choice(&mut args, Some("gpu")).unwrap(), Renderer::Software);
        assert_eq!(args, ["song.json"], "the option is not passed on to the kernel");
        assert_eq!(renderer_choice(&mut args, Some("software")).unwrap(), Renderer::Software);
        assert_eq!(renderer_choice(&mut args, None).unwrap(), Renderer::Gpu);
        assert_eq!(renderer_choice(&mut args, Some("")).unwrap(), Renderer::Gpu);
        assert!(renderer_choice(&mut args, Some("vulkan")).is_err());
        assert!(renderer_choice(&mut vec!["--renderer".into()], None).is_err());
    }

    #[test]
    fn a_renderer_on_the_processor_is_told_with_its_likely_cause() {
        let card = renderer_report("AMD Radeon 890M (radeonsi, gfx1150, LLVM 19.1.7, DRM 3.61)", "4.6 (Compatibility Profile) Mesa 25.1.5", false, false, true);
        assert_eq!(card["software"], false);
        assert_eq!(card["cause"], Value::Null);
        let llvmpipe = "llvmpipe (LLVM 19.1.7, 256 bits)";
        let cause = |asked, libgl, card| renderer_report(llvmpipe, "4.5", asked, libgl, card)["cause"].clone();
        assert_eq!(cause(true, true, true), "asked", "asked for first: --renderer software, PAW_GUI_RENDERER");
        assert_eq!(cause(false, true, true), "libgl");
        assert_eq!(cause(false, false, false), "no-card");
        assert_eq!(cause(false, false, true), "driver", "a card, but no driver or no DRI3");
        for name in ["softpipe", "Mesa X11 swrast", "Software Rasterizer", "zink Vulkan 1.3(llvmpipe (LLVM 19.1.7, 256 bits) (MESA_LLVMPIPE))"] {
            assert!(is_software(name), "{name}");
        }
        assert!(!is_software("Mesa Intel(R) Graphics (ADL GT2)"));
    }
}
