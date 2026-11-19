//! The window's loop: winit's events, egui's passes and OpenGL (glutin,
//! egui_glow), in place of eframe's, so that the main window is drawn
//! again only where its picture changed (crate::damage), onto what the
//! last frame left in the buffer, and shown only then
//! (`EGL_KHR_swap_buffers_with_damage`): a frame that changes nothing is
//! neither drawn nor shown. On a graphics card that saves the compositor's
//! work; on the processor (llvmpipe), where each pixel drawn costs, it is
//! most of the window's cost.
//!
//! The views in windows of their own are egui's immediate viewports, drawn
//! whole within the main window's pass, as eframe draws them.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::num::NonZeroU32;
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context as _, Result, anyhow};
use egui::{ViewportBuilder, ViewportClass, ViewportCommand, ViewportId, ViewportIdPair, ViewportInfo};
use egui_glow::glow::{self, HasContext as _};
use glutin::config::{Config, ConfigTemplateBuilder};
use glutin::context::{ContextApi, ContextAttributesBuilder, GlProfile, NotCurrentContext, NotCurrentGlContext as _, PossiblyCurrentContext, PossiblyCurrentGlContext as _};
use glutin::display::{GetGlDisplay as _, GlDisplay as _};
use glutin::surface::{GlSurface as _, Surface, SurfaceAttributesBuilder, SwapInterval, WindowSurface};
use winit::application::ApplicationHandler;
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy};
use winit::raw_window_handle::{HasDisplayHandle as _, HasWindowHandle as _, RawDisplayHandle};
use winit::window::{Window, WindowId};

use crate::damage::Damage;

/// What the loop runs: the program's window.
pub trait App {
    /// The colour the window is cleared to under everything.
    fn clear_color(&self) -> [f32; 4];
    /// The input of a frame of the main window, before egui sees it.
    fn raw_input_hook(&mut self, _ctx: &egui::Context, _raw: &mut egui::RawInput) {}
    /// Draw the main window.
    fn ui(&mut self, ui: &mut egui::Ui);
    /// Whether the main window is drawn again only where it changed
    /// (`paw.opt.window_cache`); else whole, every frame.
    fn partial(&self) -> bool {
        true
    }
    /// The window is closing.
    fn on_exit(&mut self) {}
}

/// The OpenGL the window draws with, for the program to report.
pub struct GlInfo {
    pub renderer: String,
    pub version: String,
}

/// A frame of a window is asked for, at a time.
#[derive(Debug)]
struct Wake {
    viewport: ViewportId,
    when: Instant,
    pass: u64,
}

/// How long to wait for the compositor's call to draw (Wayland paces the
/// frames so) before running the window's pass without drawing.
const MISSED_REDRAW: Duration = Duration::from_millis(250);

/// A window: the main one, or a view in a window of its own.
struct Viewport {
    ids: ViewportIdPair,
    builder: ViewportBuilder,
    info: ViewportInfo,
    /// Commands given before the window existed.
    deferred: Vec<ViewportCommand>,
    actions: Vec<egui_winit::ActionRequested>,
    window: Option<Arc<Window>>,
    state: Option<egui_winit::State>,
    surface: Option<Surface<WindowSurface>>,
}

impl Viewport {
    fn new(ids: ViewportIdPair, builder: ViewportBuilder) -> Viewport {
        Viewport { ids, builder, info: ViewportInfo::default(), deferred: Vec::new(), actions: Vec::new(), window: None, state: None, surface: None }
    }

    fn commands(&mut self, ctx: &egui::Context, mut commands: Vec<ViewportCommand>) {
        self.deferred.append(&mut commands);
        if let Some(window) = &self.window {
            egui_winit::process_viewport_commands(ctx, &mut self.info, std::mem::take(&mut self.deferred), window, &mut self.actions);
        }
    }
}

/// OpenGL, and the windows it draws.
struct Gl {
    ctx: egui::Context,
    config: Config,
    swap_interval: SwapInterval,
    current: Option<PossiblyCurrentContext>,
    not_current: Option<NotCurrentContext>,
    /// The window the context was last made current on.
    current_on: Option<ViewportId>,
    painter: egui_glow::Painter,
    viewports: HashMap<ViewportId, Viewport>,
    by_window: HashMap<WindowId, ViewportId>,
    started: Instant,
}

impl Gl {
    /// Make the context current on the window's surface.
    fn current(&mut self, id: ViewportId) -> Result<()> {
        let Some(surface) = self.viewports.get(&id).and_then(|v| v.surface.as_ref()) else { return Err(anyhow!("no surface")) };
        if self.current_on == Some(id)
            && let Some(current) = &self.current
            && surface.is_current(current)
        {
            return Ok(());
        }
        let not_current = match self.not_current.take() {
            Some(context) => context,
            None => {
                self.current_on = None;
                self.current.take().context("no OpenGL context")?.make_not_current()?
            }
        };
        self.current = Some(not_current.make_current(surface)?);
        self.current_on = Some(id);
        Ok(())
    }

    /// The window of a viewport, its egui state and its surface, made if
    /// missing.
    fn open(&mut self, id: ViewportId, event_loop: &ActiveEventLoop) -> Result<()> {
        let max_side = self.painter.max_texture_side();
        let viewport = self.viewports.get_mut(&id).context("no such viewport")?;
        if viewport.window.is_none() {
            let attributes = egui_winit::create_winit_window_attributes(&self.ctx, viewport.builder.clone());
            let window = glutin_winit::finalize_window(event_loop, attributes, &self.config)?;
            egui_winit::apply_viewport_builder_to_window(&self.ctx, &window, &viewport.builder);
            egui_winit::update_viewport_info(&mut viewport.info, &self.ctx, &window, true);
            viewport.window = Some(Arc::new(window));
        }
        let window = viewport.window.clone().unwrap();
        if viewport.state.is_none() {
            viewport.state = Some(egui_winit::State::new(self.ctx.clone(), id, event_loop, Some(window.scale_factor() as f32), event_loop.system_theme(), Some(max_side)));
        }
        if viewport.surface.is_none() {
            let (w, h): (u32, u32) = window.inner_size().into();
            let attributes = SurfaceAttributesBuilder::<WindowSurface>::new().build(
                window.window_handle()?.as_raw(),
                NonZeroU32::new(w).unwrap_or(NonZeroU32::MIN),
                NonZeroU32::new(h).unwrap_or(NonZeroU32::MIN),
            );
            let surface = unsafe { self.config.display().create_window_surface(&self.config, &attributes)? };
            viewport.surface = Some(surface);
            self.current(id)?;
            let viewport = &self.viewports[&id];
            if let (Some(surface), Some(current)) = (&viewport.surface, &self.current)
                && let Err(err) = surface.set_swap_interval(current, self.swap_interval)
            {
                eprintln!("paw-gui: the swap interval: {err}");
            }
        }
        if let Some(window) = &self.viewports[&id].window {
            self.by_window.insert(window.id(), id);
        }
        let viewport = self.viewports.get_mut(&id).unwrap();
        let deferred = std::mem::take(&mut viewport.deferred);
        viewport.commands(&self.ctx, deferred);
        Ok(())
    }

    /// The window has a new size: its surface too.
    fn resize(&mut self, id: ViewportId) {
        if self.current(id).is_err() {
            return;
        }
        let Some(viewport) = self.viewports.get(&id) else { return };
        if let (Some(window), Some(surface), Some(current)) = (&viewport.window, &viewport.surface, &self.current) {
            let (w, h): (u32, u32) = window.inner_size().into();
            if let (Some(w), Some(h)) = (NonZeroU32::new(w), NonZeroU32::new(h)) {
                surface.resize(current, w, h);
            }
        }
    }

    /// The input of a frame of a window.
    fn input(&mut self, id: ViewportId) -> Option<egui::RawInput> {
        let infos: egui::ViewportIdMap<ViewportInfo> = self.viewports.iter().map(|(id, v)| (*id, v.info.clone())).collect();
        let viewport = self.viewports.get_mut(&id)?;
        let (Some(window), Some(state)) = (&viewport.window, &mut viewport.state) else { return None };
        egui_winit::update_viewport_info(&mut viewport.info, &self.ctx, window, false);
        let mut raw = state.take_egui_input(window);
        raw.viewports = infos;
        raw.viewports.insert(id, viewport.info.clone());
        raw.time = Some(self.started.elapsed().as_secs_f64());
        Some(raw)
    }

    /// After a pass: the windows it named are made or changed, and those
    /// it did not name are closed.
    fn outputs(&mut self, event_loop: Option<&ActiveEventLoop>, outputs: &egui::OrderedViewportIdMap<egui::ViewportOutput>) {
        for (id, output) in outputs {
            let ids = ViewportIdPair::from_self_and_parent(*id, output.parent);
            let viewport = self.viewports.entry(*id).or_insert_with(|| Viewport::new(ids, output.builder.clone()));
            viewport.ids = ids;
            let (mut changes, recreate) = viewport.builder.patch(output.builder.clone());
            if recreate {
                viewport.window = None;
                viewport.state = None;
                viewport.surface = None;
                if self.current_on == Some(*id) {
                    self.current_on = None;
                }
            }
            viewport.deferred.append(&mut changes);
            let old = viewport.window.as_ref().map(|w| w.inner_size());
            viewport.commands(&self.ctx, output.commands.clone());
            let new = viewport.window.as_ref().map(|w| w.inner_size());
            if old.is_some() && old != new {
                self.resize(*id);
            }
        }
        if let Some(event_loop) = event_loop {
            let missing: Vec<ViewportId> = self.viewports.iter().filter(|(_, v)| v.window.is_none() && outputs.get(&v.ids.this).is_some_and(|o| o.class == ViewportClass::Deferred)).map(|(id, _)| *id).collect();
            for id in missing {
                if let Err(err) = self.open(id, event_loop) {
                    eprintln!("paw-gui: a window could not open: {err:#}");
                }
            }
        }
        if let Some(on) = self.current_on
            && !outputs.contains_key(&on)
        {
            self.current_on = None;
        }
        self.viewports.retain(|id, _| outputs.contains_key(id));
        let viewports = &self.viewports;
        self.by_window.retain(|_, id| viewports.contains_key(id));
    }
}

/// The counts `PAW_GUI_STATS` prints every 10 seconds.
#[derive(Default)]
struct Stats {
    since: Option<Instant>,
    passes: u64,
    shown: u64,
    drawn_px: u64,
    changed_px: u64,
    uploads: u64,
    ages: [u64; 4],
}

impl Stats {
    fn report(&mut self, screen: [u32; 2]) {
        let Some(since) = self.since else { return };
        let seconds = since.elapsed().as_secs_f64();
        if seconds < 10.0 {
            return;
        }
        let shown = self.shown.max(1) as f64;
        let all = (screen[0] as f64 * screen[1] as f64).max(1.0);
        eprintln!(
            "paw-gui: stats: {} passes, {} frames shown in {seconds:.1} s ({:.1}/s), {:.0} pixels drawn a frame ({:.1}% of the window), {:.0} changed, {} uploads, buffer ages 0/1/2/3+: {:?}",
            self.passes,
            self.shown,
            self.shown as f64 / seconds,
            self.drawn_px as f64 / shown,
            self.drawn_px as f64 / shown / all * 100.0,
            self.changed_px as f64 / shown,
            self.uploads,
            self.ages,
        );
        *self = Stats { since: Some(Instant::now()), ..Stats::default() };
    }
}

/// The loop's state.
struct Runner {
    builder: ViewportBuilder,
    make: Option<Box<dyn FnOnce(&egui::Context, &GlInfo) -> Result<Box<dyn App>>>>,
    ctx: egui::Context,
    proxy: Arc<Mutex<EventLoopProxy<Wake>>>,
    gl: Option<Rc<RefCell<Gl>>>,
    app: Option<Box<dyn App>>,
    /// When each window is to be drawn next, and the redraws asked of
    /// winit and not come yet.
    next: HashMap<ViewportId, Instant>,
    asked: HashMap<ViewportId, Instant>,
    damage: Damage,
    stats: Stats,
    /// The main window has been shown (it starts hidden, until drawn).
    shown: bool,
    closing: bool,
    failed: Option<anyhow::Error>,
}

thread_local! {
    /// The event loop while it hands out an event: a window of a view is
    /// made in the main window's pass, where it is not passed down.
    static EVENT_LOOP: Cell<*const ActiveEventLoop> = const { Cell::new(std::ptr::null()) };
}

/// Make the event loop reachable while `f` runs.
fn with_loop<R>(event_loop: &ActiveEventLoop, f: impl FnOnce() -> R) -> R {
    let before = EVENT_LOOP.replace(event_loop as *const _);
    let out = f();
    EVENT_LOOP.set(before);
    out
}

fn current_loop<R>(f: impl FnOnce(&ActiveEventLoop) -> R) -> Option<R> {
    let at = EVENT_LOOP.get();
    // SAFETY: set only while the event loop lends it, by `with_loop`.
    (!at.is_null()).then(|| f(unsafe { &*at }))
}

/// Run the window until it closes: `builder` describes the main window;
/// `make` makes the program once OpenGL is there.
pub fn run(builder: ViewportBuilder, make: impl FnOnce(&egui::Context, &GlInfo) -> Result<Box<dyn App>> + 'static) -> Result<()> {
    let event_loop = EventLoop::<Wake>::with_user_event().build()?;
    let ctx = egui::Context::default();
    ctx.set_embed_viewports(false);
    ctx.options_mut(|o| o.max_passes = std::num::NonZeroUsize::new(2).unwrap());
    let proxy = Arc::new(Mutex::new(event_loop.create_proxy()));
    {
        let proxy = proxy.clone();
        ctx.set_request_repaint_callback(move |info| {
            if let Ok(proxy) = proxy.lock() {
                let _ = proxy.send_event(Wake { viewport: info.viewport_id, when: Instant::now() + info.delay, pass: info.current_cumulative_pass_nr });
            }
        });
    }
    let mut runner = Runner {
        builder,
        make: Some(Box::new(make)),
        ctx,
        proxy,
        gl: None,
        app: None,
        next: HashMap::new(),
        asked: HashMap::new(),
        damage: Damage::default(),
        stats: Stats { since: std::env::var_os("PAW_GUI_STATS").map(|_| Instant::now()), ..Stats::default() },
        shown: false,
        closing: false,
        failed: None,
    };
    event_loop.run_app(&mut runner)?;
    let _ = &runner.proxy;
    match runner.failed.take() {
        Some(err) => Err(err),
        None => Ok(()),
    }
}

impl Runner {
    /// OpenGL, the main window, and the program.
    fn start(&mut self, event_loop: &ActiveEventLoop) -> Result<()> {
        let builder = self.builder.clone().with_visible(false);
        let attributes = egui_winit::create_winit_window_attributes(&self.ctx, builder.clone());
        let template = ConfigTemplateBuilder::new().prefer_hardware_accelerated(None).with_depth_size(0).with_stencil_size(0).with_transparency(false);
        // EGL first: it says how old a buffer is and shows only what changed.
        let (window, config) = glutin_winit::DisplayBuilder::new()
            .with_preference(glutin_winit::ApiPreference::PreferEgl)
            .with_window_attributes(Some(attributes))
            .build(event_loop, template, |mut configs| configs.next().expect("an OpenGL configuration"))
            .map_err(|err| anyhow!("{err}"))?;
        let window = window.context("no window")?;
        egui_winit::apply_viewport_builder_to_window(&self.ctx, &window, &builder);
        let handle = Some(window.window_handle()?.as_raw());
        let tries = [
            ContextAttributesBuilder::new().build(handle),
            ContextAttributesBuilder::new().with_context_api(ContextApi::Gles(None)).build(handle),
            ContextAttributesBuilder::new().with_profile(GlProfile::Compatibility).build(handle),
        ];
        let mut context = Err(anyhow!("no OpenGL context"));
        for attributes in &tries {
            match unsafe { config.display().create_context(&config, attributes) } {
                Ok(made) => {
                    context = Ok(made);
                    break;
                }
                Err(err) => context = Err(anyhow!("{err}")),
            }
        }
        let context = context?;
        // On Wayland the compositor's calls to draw pace the frames; a
        // swap that waits would only hang a hidden window.
        let wayland = matches!(event_loop.display_handle()?.as_raw(), RawDisplayHandle::Wayland(_));
        let swap_interval = if wayland { SwapInterval::DontWait } else { SwapInterval::Wait(NonZeroU32::MIN) };
        let mut info = ViewportInfo::default();
        egui_winit::update_viewport_info(&mut info, &self.ctx, &window, true);
        let ppp = egui_winit::pixels_per_point(&self.ctx, &window);
        self.ctx.input_mut(|i| {
            i.raw.viewports.insert(ViewportId::ROOT, info.clone());
            i.pixels_per_point = ppp;
        });
        // The main window's surface, and the context current on it: glow
        // asks OpenGL its version when it starts.
        let (w, h): (u32, u32) = window.inner_size().into();
        let attributes = SurfaceAttributesBuilder::<WindowSurface>::new().build(
            window.window_handle()?.as_raw(),
            NonZeroU32::new(w).unwrap_or(NonZeroU32::MIN),
            NonZeroU32::new(h).unwrap_or(NonZeroU32::MIN),
        );
        let surface = unsafe { config.display().create_window_surface(&config, &attributes)? };
        let current = context.make_current(&surface)?;
        if let Err(err) = surface.set_swap_interval(&current, swap_interval) {
            eprintln!("paw-gui: the swap interval: {err}");
        }
        let mut root = Viewport::new(ViewportIdPair::ROOT, builder);
        root.info = info;
        root.window = Some(Arc::new(window));
        root.surface = Some(surface);
        let display = config.display();
        let gl = unsafe {
            glow::Context::from_loader_function(|name| {
                let name = std::ffi::CString::new(name).unwrap_or_default();
                display.get_proc_address(&name)
            })
        };
        let painter = egui_glow::Painter::new(Arc::new(gl), "", None, true).map_err(|err| anyhow!("{err}"))?;
        let mut gl = Gl {
            ctx: self.ctx.clone(),
            config,
            swap_interval,
            current: Some(current),
            not_current: None,
            current_on: Some(ViewportId::ROOT),
            painter,
            viewports: HashMap::from([(ViewportId::ROOT, root)]),
            by_window: HashMap::new(),
            started: Instant::now(),
        };
        gl.open(ViewportId::ROOT, event_loop)?;
        let info = unsafe {
            let raw = gl.painter.gl();
            GlInfo { renderer: raw.get_parameter_string(glow::RENDERER), version: raw.get_parameter_string(glow::VERSION) }
        };
        let gl = Rc::new(RefCell::new(gl));
        {
            let gl = Rc::downgrade(&gl);
            egui::Context::set_immediate_viewport_renderer(move |ctx, viewport| {
                if let Some(gl) = gl.upgrade() {
                    immediate(ctx, &gl, viewport);
                }
            });
        }
        self.gl = Some(gl);
        let make = self.make.take().context("started twice")?;
        self.app = Some(make(&self.ctx, &info)?);
        self.next.insert(ViewportId::ROOT, Instant::now());
        Ok(())
    }

    /// A pass of the main window, and its frame where it changed.
    fn frame(&mut self, event_loop: &ActiveEventLoop, draw: bool) {
        let (Some(gl), Some(app)) = (self.gl.clone(), self.app.as_mut()) else { return };
        self.asked.remove(&ViewportId::ROOT);
        let Some(mut raw) = gl.borrow_mut().input(ViewportId::ROOT) else { return };
        app.raw_input_hook(&self.ctx, &mut raw);
        let close = raw.viewport().close_requested();
        // The program's pass: it may draw the views in windows of their own.
        let output = self.ctx.run_ui(raw, |ui| app.ui(ui));
        self.stats.passes += 1;
        if close && !output.viewport_output.get(&ViewportId::ROOT).is_some_and(|o| o.commands.contains(&ViewportCommand::CancelClose)) {
            self.closing = true;
        }
        let partial = app.partial();
        let clear = app.clear_color();
        let mut gl = gl.borrow_mut();
        let gl = &mut *gl;
        if let Some(root) = gl.viewports.get_mut(&ViewportId::ROOT) {
            root.info.events.clear();
            if let (Some(window), Some(state)) = (&root.window, &mut root.state) {
                state.handle_platform_output(window, output.platform_output);
            }
        }
        let mut delta = output.textures_delta;
        self.stats.uploads += delta.set.len() as u64;
        if draw {
            self.paint(gl, output.shapes, output.pixels_per_point, &mut delta, partial, clear);
        }
        // Textures not drawn with are set (and let go) all the same.
        for (id, images) in delta.set.drain() {
            for image in images {
                gl.painter.set_texture(id, &image);
            }
        }
        for id in delta.free.drain() {
            gl.painter.free_texture(id);
        }
        gl.outputs(Some(event_loop), &output.viewport_output);
        let screen = gl.viewports.get(&ViewportId::ROOT).and_then(|v| v.window.as_ref()).map_or([0, 0], |w| w.inner_size().into());
        self.stats.report(screen);
        if self.closing {
            event_loop.exit();
        }
    }

    /// Draw what changed of the main window, onto the buffer as the driver
    /// gives it back, and show it.
    fn paint(&mut self, gl: &mut Gl, shapes: Vec<egui::epaint::ClippedShape>, ppp: f32, delta: &mut egui::TexturesDelta, partial: bool, clear: [f32; 4]) {
        let Some(window) = gl.viewports.get(&ViewportId::ROOT).and_then(|v| v.window.clone()) else { return };
        let screen: [u32; 2] = window.inner_size().into();
        if screen[0] == 0 || screen[1] == 0 {
            return;
        }
        // A picture given new pixels is drawn again where it shows; the
        // font's texture made anew changes all the text.
        let font = egui::TextureId::default();
        let fonts_anew = delta.set.iter().any(|(id, images)| *id == font && images.iter().any(|image| image.pos.is_none()));
        let textures: HashSet<egui::TextureId> = delta.set.iter().map(|(id, _)| *id).filter(|id| *id != font).collect();
        let all = !partial || !self.shown || fonts_anew;
        if !self.damage.frame(shapes, ppp, screen, &textures, all) {
            return;
        }
        if gl.current(ViewportId::ROOT).is_err() {
            return;
        }
        let Some(surface) = gl.viewports.get(&ViewportId::ROOT).and_then(|v| v.surface.as_ref()) else { return };
        let age = if all { 0 } else { surface.buffer_age() };
        self.stats.ages[(age as usize).min(3)] += 1;
        let rects = self.damage.to_draw(age);
        let changed = self.damage.changed();
        let raw = gl.painter.gl().clone();
        for (i, rect) in rects.iter().enumerate() {
            unsafe {
                raw.enable(glow::SCISSOR_TEST);
                raw.scissor(rect[0], screen[1] as i32 - rect[3], rect[2] - rect[0], rect[3] - rect[1]);
                raw.color_mask(true, true, true, true);
                raw.clear_color(clear[0], clear[1], clear[2], clear[3]);
                raw.clear(glow::COLOR_BUFFER_BIT);
            }
            let cut = egui::Rect::from_min_max(egui::pos2(rect[0] as f32, rect[1] as f32) / ppp, egui::pos2(rect[2] as f32, rect[3] as f32) / ppp);
            let mut primitives = self.ctx.tessellate(self.damage.shapes_in(*rect), ppp);
            primitives.retain_mut(|p| {
                p.clip_rect = p.clip_rect.intersect(cut);
                p.clip_rect.is_positive()
            });
            if i == 0 {
                gl.painter.paint_and_update_textures(screen, ppp, &primitives, delta);
            } else {
                gl.painter.paint_primitives(screen, ppp, &primitives);
            }
            self.stats.drawn_px += ((rect[2] - rect[0]) * (rect[3] - rect[1])) as u64;
        }
        self.stats.changed_px += changed.iter().map(|r| ((r[2] - r[0]) * (r[3] - r[1])) as u64).sum::<u64>();
        // Shown: only what changed, where the platform lets it say so.
        window.pre_present_notify();
        let Some(current) = &gl.current else { return };
        let surface = gl.viewports[&ViewportId::ROOT].surface.as_ref().unwrap();
        let swapped = match surface {
            Surface::Egl(egl) if !all => {
                let h = screen[1] as i32;
                let damage: Vec<glutin::surface::Rect> = changed.iter().map(|r| glutin::surface::Rect::new(r[0], h - r[3], r[2] - r[0], r[3] - r[1])).collect();
                match current {
                    glutin::context::PossiblyCurrentContext::Egl(context) => egl.swap_buffers_with_damage(context, &damage),
                    #[allow(unreachable_patterns)]
                    _ => surface.swap_buffers(current),
                }
            }
            _ => surface.swap_buffers(current),
        };
        if let Err(err) = swapped {
            eprintln!("paw-gui: showing the frame: {err}");
        }
        self.damage.shown();
        self.stats.shown += 1;
        if !self.shown {
            self.shown = true;
            window.set_visible(true);
        }
    }

    /// Ask for a frame of a window at a time: a view in a window of its own
    /// is drawn in the main window's pass.
    fn wake(&mut self, viewport: ViewportId, when: Instant) {
        let root = match &self.gl {
            Some(gl) => gl.borrow().viewports.get(&viewport).map_or(ViewportId::ROOT, |v| if v.ids.this == ViewportId::ROOT { v.ids.this } else { v.ids.parent }),
            None => ViewportId::ROOT,
        };
        let at = self.next.entry(root).or_insert(when);
        *at = (*at).min(when);
    }

    /// Ask winit for the frames due, and sleep until the next.
    fn schedule(&mut self, event_loop: &ActiveEventLoop) {
        let now = Instant::now();
        let due: Vec<ViewportId> = self.next.iter().filter(|(_, at)| **at <= now).map(|(id, _)| *id).collect();
        for id in due {
            self.next.remove(&id);
            let window = self.gl.as_ref().and_then(|gl| gl.borrow().viewports.get(&id).and_then(|v| v.window.clone()));
            if let Some(window) = window {
                window.request_redraw();
                self.asked.entry(id).or_insert(now + MISSED_REDRAW);
            }
        }
        // A redraw the compositor withholds (a hidden window on Wayland):
        // the pass runs, so that the program goes on, but nothing is drawn.
        let late: Vec<ViewportId> = self.asked.iter().filter(|(_, at)| **at <= now).map(|(id, _)| *id).collect();
        for id in late {
            self.asked.remove(&id);
            if id == ViewportId::ROOT {
                with_loop(event_loop, || self.frame(event_loop, false));
            }
        }
        let next = self.next.values().chain(self.asked.values()).min().copied();
        event_loop.set_control_flow(match next {
            Some(at) => ControlFlow::WaitUntil(at),
            None => ControlFlow::Wait,
        });
    }
}

impl ApplicationHandler<Wake> for Runner {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.gl.is_some() || self.failed.is_some() {
            return;
        }
        if let Err(err) = with_loop(event_loop, || self.start(event_loop)) {
            self.failed = Some(err);
            event_loop.exit();
            return;
        }
        self.schedule(event_loop);
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, wake: Wake) {
        let pass = self.ctx.cumulative_pass_nr_for(wake.viewport);
        // A request made before the frame that answered it is old.
        if pass == wake.pass || pass == wake.pass + 1 {
            self.wake(wake.viewport, wake.when);
        }
        self.schedule(event_loop);
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, window_id: WindowId, event: WindowEvent) {
        let Some(gl) = self.gl.clone() else { return };
        let Some(id) = gl.borrow().by_window.get(&window_id).copied() else { return };
        match &event {
            WindowEvent::RedrawRequested => {
                if id == ViewportId::ROOT {
                    with_loop(event_loop, || self.frame(event_loop, true));
                } else {
                    self.wake(id, Instant::now());
                }
                self.schedule(event_loop);
                return;
            }
            WindowEvent::Resized(size) if size.width > 0 && size.height > 0 => {
                gl.borrow_mut().resize(id);
                self.wake(id, Instant::now());
            }
            WindowEvent::CloseRequested => {
                if id == ViewportId::ROOT && self.closing {
                    event_loop.exit();
                    return;
                }
                if let Some(viewport) = gl.borrow_mut().viewports.get_mut(&id) {
                    viewport.info.events.push(egui::ViewportEvent::Close);
                }
                self.wake(id, Instant::now());
            }
            WindowEvent::Occluded(occluded) => {
                if let Some(viewport) = gl.borrow_mut().viewports.get_mut(&id) {
                    viewport.info.occluded = Some(*occluded);
                }
            }
            _ => {}
        }
        let response = {
            let mut gl = gl.borrow_mut();
            let Some(viewport) = gl.viewports.get_mut(&id) else { return };
            match (&viewport.window, &mut viewport.state) {
                (Some(window), Some(state)) => state.on_window_event(window, &event),
                _ => return,
            }
        };
        if response.repaint {
            self.wake(id, Instant::now());
        }
        self.schedule(event_loop);
    }

    fn device_event(&mut self, _event_loop: &ActiveEventLoop, _device: winit::event::DeviceId, _event: winit::event::DeviceEvent) {}

    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        self.schedule(event_loop);
    }

    fn exiting(&mut self, _event_loop: &ActiveEventLoop) {
        if let Some(mut app) = self.app.take() {
            app.on_exit();
        }
        if let Some(gl) = self.gl.take() {
            let mut gl = gl.borrow_mut();
            let _ = gl.current(ViewportId::ROOT);
            gl.painter.destroy();
            gl.viewports.clear();
        }
    }
}

/// Draw a view's window of its own, whole, in the main window's pass.
fn immediate(ctx: &egui::Context, gl: &RefCell<Gl>, viewport: egui::ImmediateViewport<'_>) {
    let egui::ImmediateViewport { ids, builder, mut viewport_ui_cb } = viewport;
    let id = ids.this;
    {
        let mut gl = gl.borrow_mut();
        let entry = gl.viewports.entry(id).or_insert_with(|| Viewport::new(ids, builder.clone()));
        entry.ids = ids;
        let (mut changes, recreate) = entry.builder.patch(builder);
        if recreate {
            entry.window = None;
            entry.state = None;
            entry.surface = None;
        }
        entry.deferred.append(&mut changes);
        let opened = current_loop(|event_loop| gl.open(id, event_loop));
        if let Some(Err(err)) = opened {
            eprintln!("paw-gui: a window could not open: {err:#}");
            return;
        }
    }
    let Some(input) = gl.borrow_mut().input(id) else { return };
    // The program's code for the window: no borrow is held, it may come back here.
    let output = ctx.run_ui(input, |ui| viewport_ui_cb(ui));
    let primitives = ctx.tessellate(output.shapes, output.pixels_per_point);
    let mut gl = gl.borrow_mut();
    let gl = &mut *gl;
    if let Some(viewport) = gl.viewports.get_mut(&id) {
        viewport.info.events.clear();
    }
    let mut delta = output.textures_delta;
    if gl.current(id).is_ok()
        && let Some(viewport) = gl.viewports.get(&id)
        && let (Some(window), Some(surface)) = (&viewport.window, &viewport.surface)
    {
        let screen: [u32; 2] = window.inner_size().into();
        egui_glow::painter::clear(gl.painter.gl(), screen, [0.0, 0.0, 0.0, 0.0]);
        gl.painter.paint_and_update_textures(screen, output.pixels_per_point, &primitives, &mut delta);
        window.pre_present_notify();
        if let Some(current) = &gl.current
            && let Err(err) = surface.swap_buffers(current)
        {
            eprintln!("paw-gui: showing a window: {err}");
        }
    }
    for (texture, images) in delta.set.drain() {
        for image in images {
            gl.painter.set_texture(texture, &image);
        }
    }
    for texture in delta.free.drain() {
        gl.painter.free_texture(texture);
    }
    if let Some(viewport) = gl.viewports.get_mut(&id)
        && let (Some(window), Some(state)) = (&viewport.window, &mut viewport.state)
    {
        state.handle_platform_output(window, output.platform_output);
    }
    for (vid, out) in &output.viewport_output {
        if let Some(viewport) = gl.viewports.get_mut(vid) {
            viewport.commands(&gl.ctx, out.commands.clone());
        }
    }
}
