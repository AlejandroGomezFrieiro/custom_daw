//! The small parts the window is built from: buttons, icons, text cut
//! to fit, the wheel. A control only
//! reports what is done to it and never changes its own value, so what it
//! shows is always what the kernel holds.

use std::cell::RefCell;

use egui::{Align2, Color32, CornerRadius, Id, Pos2, Rect, Response, Sense, Ui, Vec2, pos2};

use crate::icons::Icon;
use crate::theme::{self, Icons, T_BASE, alpha, medium, th};

thread_local! {
    /// What the pointer does where it is, for the status line: set by
    /// whatever is under it as the frame is drawn.
    static HINT: RefCell<String> = const { RefCell::new(String::new()) };
    static ICONS: RefCell<Icons> = RefCell::new(Icons::default());
}

/// Say what the pointer does over what is being drawn.
pub fn hint(text: impl Into<String>) {
    HINT.with(|h| *h.borrow_mut() = text.into());
}

/// Say it when `response` is under the pointer.
pub fn hint_on(response: &Response, text: impl Into<String>) {
    if response.hovered() {
        hint(text);
    }
}

/// The hint of this frame, taken: the next frame says its own.
pub fn take_hint() -> String {
    HINT.with(|h| std::mem::take(&mut *h.borrow_mut()))
}

/// Draw `icon` filling `rect` in `ink`.
pub fn icon(ui: &Ui, rect: Rect, icon: Icon, ink: Color32) {
    icon_on(ui.painter(), rect, icon, ink);
}

/// The same with a painter of its own, cut as it is.
pub fn icon_on(painter: &egui::Painter, rect: Rect, icon: Icon, ink: Color32) {
    let ctx = painter.ctx();
    let pixels = (rect.width().max(rect.height()) * ctx.pixels_per_point()).round().max(1.0) as u32;
    let texture = ICONS.with(|icons| icons.borrow_mut().get(ctx, icon, pixels));
    painter.image(texture.id(), rect, Rect::from_min_max(Pos2::ZERO, pos2(1.0, 1.0)), ink);
}

/// How a button looks.
#[derive(Clone, Copy)]
pub struct Look {
    pub on: bool,
    pub lit: Color32,
    /// No face until the pointer is on it, as a toolbar's buttons.
    pub quiet: bool,
    pub enabled: bool,
    /// The drawing's colour while off, if not the usual.
    pub idle_ink: Option<Color32>,
}

impl Default for Look {
    fn default() -> Self {
        Look { on: false, lit: th().select, quiet: false, enabled: true, idle_ink: None }
    }
}

impl Look {
    pub fn quiet() -> Self {
        Look { quiet: true, ..Look::default() }
    }
    pub fn on(self, on: bool) -> Self {
        Look { on, ..self }
    }
    pub fn lit(self, lit: Color32) -> Self {
        Look { lit, ..self }
    }
    pub fn enabled(self, enabled: bool) -> Self {
        Look { enabled, ..self }
    }
}

/// The width a button with `label` (and an icon or not) takes at `height`.
pub fn button_width(ui: &Ui, label: &str, has_icon: bool, height: f32) -> f32 {
    if label.is_empty() {
        return height;
    }
    let text = ui.fonts_mut(|f| f.layout_no_wrap(label.into(), medium(T_BASE), Color32::WHITE).size().x);
    8.0 + if has_icon { (if height <= 22.0 { 14.0 } else { 16.0 }) + 6.0 } else { 0.0 } + text + 10.0
}

/// A button with a drawing, a word, or both, in `rect`.
pub fn button(ui: &mut Ui, rect: Rect, id: Id, icon_shape: Option<Icon>, label: &str, look: Look) -> Response {
    let t = th();
    let sense = if look.enabled { Sense::click() } else { Sense::hover() };
    let response = ui.interact(rect, id, sense);
    if !label.is_empty() {
        response.widget_info(|| egui::WidgetInfo::labeled(egui::Role::Button, look.enabled, label));
    }
    let (hover, pressed) = (response.hovered() && look.enabled, response.is_pointer_button_down_on());
    let face = if !look.enabled {
        if look.quiet { Color32::TRANSPARENT } else { t.control_press }
    } else if look.quiet {
        if pressed {
            Color32::from_black_alpha(0x33)
        } else if look.on {
            alpha(look.lit, 0.12)
        } else if hover {
            Color32::from_white_alpha(0x12)
        } else {
            Color32::TRANSPARENT
        }
    } else if pressed {
        t.control_press
    } else if look.on {
        alpha(look.lit, 0.2)
    } else if hover {
        t.control_hover
    } else {
        t.control
    };
    let radius = if rect.height() <= 22.0 { 3.0 } else { 4.0 };
    ui.painter().rect_filled(rect, CornerRadius::same(radius as u8), face);
    let side = if rect.height() <= 22.0 { 14.0 } else { 16.0 };
    let has_label = !label.is_empty();
    let mut x = if has_label { rect.left() + 8.0 } else { rect.center().x - side / 2.0 };
    if let Some(shape) = icon_shape {
        let ink = if !look.enabled {
            t.text_off
        } else if look.on {
            look.lit
        } else if let Some(idle) = look.idle_ink {
            if hover { theme::mix(idle, Color32::WHITE, 0.75) } else { idle }
        } else if hover || !look.quiet {
            t.text
        } else {
            t.text_2
        };
        icon(ui, Rect::from_min_size(pos2(x, rect.center().y - side / 2.0), Vec2::splat(side)), shape, ink);
        x += side + 6.0;
    }
    if has_label {
        let colour = if !look.enabled { t.text_off } else if look.on && look.quiet { look.lit } else { t.text };
        ui.painter().text(pos2(x, rect.center().y), Align2::LEFT_CENTER, label, medium(T_BASE), colour);
    }
    response
}

/// Where `button` went down this frame, if it did.
pub fn pressed_at(ui: &Ui, button: egui::PointerButton) -> Option<Pos2> {
    ui.input(|i| {
        i.events.iter().find_map(|e| match e {
            egui::Event::PointerButton { pos, button: b, pressed: true, .. } if *b == button => Some(*pos),
            _ => None,
        })
    })
}

/// Name a control that shows a drawing and no word, for whoever cannot see it.
pub fn name(response: &Response, name: &str) {
    response.widget_info(|| egui::WidgetInfo::labeled(egui::Role::Button, true, name));
}

/// How far the wheel turned this frame, up and down (sideways where it
/// turned only that way), in its own steps.
pub fn wheel_y(ui: &Ui) -> f32 {
    ui.input(|i| {
        i.events
            .iter()
            .filter_map(|e| match e {
                egui::Event::MouseWheel { delta, .. } => Some(if delta.y != 0.0 { delta.y } else { delta.x }),
                _ => None,
            })
            .sum()
    })
}

/// The wheel over `response`, one step up (+1) or down (-1).
pub fn wheel_step(ui: &Ui, response: &Response) -> Option<f32> {
    if !response.hovered() {
        return None;
    }
    let dy = wheel_y(ui);
    (dy != 0.0).then(|| dy.signum())
}

/// Text cut short with an ellipsis to fit `width`.
pub fn elide(ui: &Ui, text: &str, font: egui::FontId, width: f32) -> String {
    let fits = |s: &str| ui.fonts_mut(|f| f.layout_no_wrap(s.to_string(), font.clone(), Color32::WHITE).size().x) <= width;
    if width <= 0.0 {
        return String::new();
    }
    if fits(text) {
        return text.to_string();
    }
    let chars: Vec<char> = text.chars().collect();
    let (mut lo, mut hi) = (0, chars.len());
    while lo < hi {
        let mid = (lo + hi).div_ceil(2);
        let s: String = chars[..mid].iter().collect::<String>() + "…";
        if fits(&s) { lo = mid } else { hi = mid - 1 }
    }
    chars[..lo].iter().collect::<String>() + "…"
}

/// Text at `pos` (its left, centred up and down), cut to `width`.
pub fn text_in(ui: &Ui, pos: Pos2, text: &str, font: egui::FontId, colour: Color32, width: f32) {
    let shown = elide(ui, text, font.clone(), width);
    ui.painter().text(pos, Align2::LEFT_CENTER, shown, font, colour);
}

/// How wide `text` is in `font`.
pub fn text_width(ui: &Ui, text: &str, font: egui::FontId) -> f32 {
    ui.fonts_mut(|f| f.layout_no_wrap(text.to_string(), font, Color32::WHITE).size().x)
}
