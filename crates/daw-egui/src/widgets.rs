//! The small parts the window is built from: buttons, the lettered
//! switches of a track, sliders, knobs, faders and meters. A control only
//! reports what is done to it and never changes its own value, so what it
//! shows is always what the kernel holds.

use std::cell::RefCell;

use egui::{Align2, Color32, CornerRadius, Id, Pos2, Rect, Response, Sense, Stroke, StrokeKind, Ui, Vec2, pos2, vec2};

use crate::icons::Icon;
use crate::theme::{self, Icons, T_BASE, T_SMALL, alpha, medium, semi, th};

thread_local! {
    /// What the pointer does where it is, for the status line: set by
    /// whatever is under it as the frame is drawn.
    static HINT: RefCell<String> = const { RefCell::new(String::new()) };
    static ICONS: RefCell<Icons> = RefCell::new(Icons::default());
    /// A control took the wheel this frame: what holds it does not scroll.
    static WHEEL_TAKEN: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Whether a control took the wheel this frame; and a new frame.
pub fn wheel_taken() -> bool {
    WHEEL_TAKEN.with(|w| w.get())
}
pub fn new_frame() {
    WHEEL_TAKEN.with(|w| w.set(false));
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
    let pixels = (rect.width().max(rect.height()) * ui.ctx().pixels_per_point()).round().max(1.0) as u32;
    let texture = ICONS.with(|icons| icons.borrow_mut().get(ui.ctx(), icon, pixels));
    ui.painter().image(texture.id(), rect, Rect::from_min_max(Pos2::ZERO, pos2(1.0, 1.0)), ink);
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

/// A small lettered switch of a track: mute, solo, arm. Off it is a plain
/// control with a dim letter; on, the state's colour with a dark one.
pub fn flag(ui: &mut Ui, rect: Rect, id: Id, label: &str, on: bool, lit: Color32) -> Response {
    let t = th();
    let response = ui.interact(rect, id, Sense::click_and_drag());
    let hover = response.hovered();
    let face = if on {
        if hover { theme::mix(lit, Color32::WHITE, 0.88) } else { lit }
    } else if response.is_pointer_button_down_on() {
        t.control_press
    } else if hover {
        t.control_hover
    } else {
        t.control
    };
    ui.painter().rect_filled(rect, CornerRadius::same(3), face);
    let ink = if on { t.on_hue } else if hover { t.text } else { t.text_2 };
    ui.painter().text(rect.center(), Align2::CENTER_CENTER, label, semi(T_SMALL), ink);
    response
}

/// What a control was made to do.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Moved {
    /// A new value, 0 to 1.
    To(f32),
    /// Back to where it rests (a double click).
    Reset,
    /// Taken hold of, or let go: for automation written while one is held.
    Held(bool),
}

/// Where a drag of a control began, kept between frames.
#[derive(Clone, Copy, Default)]
struct Grip {
    fine: bool,
    from: f32,
    from_at: f32,
    sent: f32,
}

fn grip(ui: &Ui, id: Id) -> Grip {
    ui.data(|d| d.get_temp(id)).unwrap_or_default()
}

fn set_grip(ui: &Ui, id: Id, grip: Grip) {
    ui.data_mut(|d| d.insert_temp(id, grip));
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
    if dy != 0.0 {
        WHEEL_TAKEN.with(|w| w.set(true));
    }
    (dy != 0.0).then(|| dy.signum())
}

/// What a press, a drag, a double click and the wheel do to a control:
/// pressed it takes the place `at` gives (or, with Shift, moves a tenth as
/// far from where it was), dragged it follows, the wheel nudges by `nudge`.
fn handle(
    ui: &Ui,
    response: &Response,
    id: Id,
    value: f32,
    pointer: impl Fn(Pos2) -> f32,
    fine_scale: f32,
    jumps: bool,
    nudge: f32,
) -> Vec<Moved> {
    let mut out = Vec::new();
    let shift = ui.input(|i| i.modifiers.shift);
    let pos = ui.input(|i| i.pointer.interact_pos());
    if response.double_clicked() {
        out.push(Moved::Reset);
        return out;
    }
    if response.is_pointer_button_down_on() && ui.input(|i| i.pointer.primary_pressed()) {
        if let Some(pos) = pos {
            let at = pointer(pos);
            let sent = if shift || !jumps { value } else { at };
            set_grip(ui, id, Grip { fine: shift, from: sent, from_at: at, sent });
            out.push(Moved::Held(true));
            if jumps && !shift {
                out.push(Moved::To(sent));
            }
        }
    } else if response.dragged_by(egui::PointerButton::Primary)
        && let Some(pos) = pos
    {
        let mut g = grip(ui, id);
        let at = pointer(pos);
        if shift != g.fine {
            g = Grip { fine: shift, from: g.sent, from_at: at, sent: g.sent };
        }
        let sent = if g.fine || !jumps {
            (g.from + (at - g.from_at) * if g.fine { fine_scale } else { 1.0 }).clamp(0.0, 1.0)
        } else {
            at.clamp(0.0, 1.0)
        };
        if sent != g.sent {
            out.push(Moved::To(sent));
        }
        set_grip(ui, id, Grip { sent, ..g });
    }
    if response.drag_stopped() || (response.clicked() && !response.dragged()) {
        out.push(Moved::Held(false));
    }
    if let Some(step) = wheel_step(ui, response) {
        out.push(Moved::To((value + step * nudge).clamp(0.0, 1.0)));
    }
    out
}

/// A slider across `rect`: grey on a dark well, blue while it is dragged.
/// `centred` fills it from the middle, as a pan is.
pub fn slider(ui: &mut Ui, rect: Rect, id: Id, value: f32, centred: bool) -> (Response, Vec<Moved>) {
    let t = th();
    let response = ui.interact(rect, id, Sense::click_and_drag());
    let well = Rect::from_min_size(pos2(rect.left() + 4.0, rect.center().y - 1.5), vec2(rect.width() - 8.0, 3.0));
    let p = ui.painter();
    p.rect_filled(well, CornerRadius::same(1), t.well);
    let v = value.clamp(0.0, 1.0);
    let (x0, x1) = if centred {
        let mid = well.left() + well.width() / 2.0;
        let at = well.left() + well.width() * v;
        (mid.min(at), mid.max(at))
    } else {
        (well.left(), well.left() + well.width() * v)
    };
    let pressed = response.is_pointer_button_down_on();
    let fill = if pressed { t.select } else if response.hovered() { t.text_2 } else { t.text_3 };
    p.rect_filled(Rect::from_x_y_ranges(x0..=x1, well.y_range()), CornerRadius::same(1), fill);
    let thumb = Rect::from_min_size(pos2(rect.left() + (rect.width() - 8.0) * v, rect.center().y - 7.0), vec2(8.0, 14.0));
    let face = if pressed { t.text } else if response.hovered() { Color32::from_rgb(0xdc, 0xde, 0xe3) } else { t.thumb };
    p.rect(thumb, CornerRadius::same(2), face, Stroke::new(1.0, Color32::from_black_alpha(0x60)), StrokeKind::Inside);
    let width = (rect.width() - 8.0).max(1.0);
    let moved = handle(ui, &response, id, value, |pos| (pos.x - rect.left() - 4.0) / width, 0.1, true, 0.02);
    (response, moved)
}

/// A small round knob, for a pan: drag up and down to turn it.
pub fn knob(ui: &mut Ui, rect: Rect, id: Id, value: f32) -> (Response, Vec<Moved>) {
    let t = th();
    let response = ui.interact(rect, id, Sense::click_and_drag());
    let r = rect.width().min(rect.height()) / 2.0;
    let face = if response.hovered() || response.is_pointer_button_down_on() { t.control_hover } else { t.control };
    let p = ui.painter();
    p.circle(rect.center(), r - 0.5, face, Stroke::new(1.0, t.divider));
    let turn = (value.clamp(0.0, 1.0) - 0.5) * 270f32.to_radians();
    let ink = if response.is_pointer_button_down_on() { t.select } else { t.text };
    let at = |d: f32| rect.center() + vec2(turn.sin(), -turn.cos()) * d;
    p.line_segment([at(r - 7.0), at(r - 2.5)], Stroke::new(2.0, ink));
    let moved = handle(ui, &response, id, value, |pos| -pos.y / 120.0, 0.1, false, 0.02);
    (response, moved)
}

/// Where a fader's cap sits for a level in dB, 0 to 1 along its travel:
/// 0 dB at 72%, +6 at the top, -60 at the foot, the marks of its scale
/// spaced as a mixer's are.
pub fn taper(db: f32) -> f32 {
    (if db <= -36.0 {
        (db + 60.0) / 24.0 * 0.14
    } else if db <= -24.0 {
        0.14 + (db + 36.0) / 12.0 * 0.11
    } else if db <= -12.0 {
        0.25 + (db + 24.0) / 12.0 * 0.17
    } else if db <= -6.0 {
        0.42 + (db + 12.0) / 6.0 * 0.14
    } else if db <= 0.0 {
        0.56 + (db + 6.0) / 6.0 * 0.16
    } else {
        0.72 + db / 6.0 * 0.28
    })
    .clamp(0.0, 1.0)
}

/// The level in dB at a place along a fader's travel.
pub fn taper_db(pos: f32) -> f32 {
    if pos <= 0.14 {
        pos / 0.14 * 24.0 - 60.0
    } else if pos <= 0.25 {
        (pos - 0.14) / 0.11 * 12.0 - 36.0
    } else if pos <= 0.42 {
        (pos - 0.25) / 0.17 * 12.0 - 24.0
    } else if pos <= 0.56 {
        (pos - 0.42) / 0.14 * 6.0 - 12.0
    } else if pos <= 0.72 {
        (pos - 0.56) / 0.16 * 6.0 - 6.0
    } else {
        (pos - 0.72) / 0.28 * 6.0
    }
}

/// An upright fader with a cap, for a mixer strip. `db` is the level;
/// what it reports is a level in dB too.
pub fn fader(ui: &mut Ui, rect: Rect, id: Id, db: f32) -> (Response, Vec<Moved>) {
    let t = th();
    let response = ui.interact(rect, id, Sense::click_and_drag());
    let travel = (rect.height() - 36.0).max(1.0);
    let at = taper(db);
    let p = ui.painter();
    p.rect_filled(
        Rect::from_min_size(pos2(rect.center().x - 2.0, rect.top() + 16.0), vec2(4.0, rect.height() - 32.0)),
        CornerRadius::same(2),
        t.well,
    );
    let cap = Rect::from_min_size(pos2(rect.left(), rect.top() + travel * (1.0 - at)), vec2(rect.width(), 36.0));
    let (top, bottom) = if response.is_pointer_button_down_on() {
        (t.text, t.thumb)
    } else if response.hovered() {
        (Color32::from_rgb(0xd7, 0xd9, 0xde), Color32::from_rgb(0xb7, 0xb9, 0xc0))
    } else {
        (t.thumb, t.thumb_low)
    };
    p.rect_filled(cap.with_max_y(cap.center().y), CornerRadius { nw: 3, ne: 3, sw: 0, se: 0 }, top);
    p.rect_filled(cap.with_min_y(cap.center().y), CornerRadius { nw: 0, ne: 0, sw: 3, se: 3 }, bottom);
    p.rect_stroke(cap, CornerRadius::same(3), Stroke::new(1.0, Color32::from_black_alpha(0x80)), StrokeKind::Inside);
    p.rect_filled(
        Rect::from_min_size(pos2(cap.left() + 3.0, cap.center().y - 1.0), vec2(cap.width() - 6.0, 2.0)),
        CornerRadius::ZERO,
        Color32::from_rgb(0x1b, 0x1c, 0x1f),
    );
    let moved = handle(ui, &response, id, at, |pos| 1.0 - (pos.y - rect.top() - 18.0) / travel, 0.1, true, 0.015)
        .into_iter()
        .map(|m| match m {
            Moved::To(pos) => Moved::To(taper_db(pos)),
            other => other,
        })
        .collect();
    (response, moved)
}

/// A level meter, coloured by position: green to -18 dBFS, then
/// yellow-green, yellow, orange, and red from 0 dB. `hold` is the peak
/// held a moment, drawn as a thin line.
pub fn meter(ui: &Ui, rect: Rect, level: f32, hold: f32, upright: bool) {
    let t = th();
    let p = ui.painter();
    p.rect_filled(rect, CornerRadius::ZERO, t.meter_well);
    let level = level.clamp(0.0, 1.0);
    let bands: [(f32, f32, Color32); 5] = [(0.0, 0.636, t.meter_low), (0.636, 0.773, t.meter_mid), (0.773, 0.864, t.meter_high), (0.864, 0.909, t.meter_hot), (0.909, 1.0, t.meter_clip)];
    for (from, to, colour) in bands {
        if level <= from {
            break;
        }
        let to = to.min(level);
        let band = if upright {
            Rect::from_x_y_ranges(rect.x_range(), (rect.bottom() - rect.height() * to)..=(rect.bottom() - rect.height() * from))
        } else {
            Rect::from_x_y_ranges((rect.left() + rect.width() * from)..=(rect.left() + rect.width() * to), rect.y_range())
        };
        p.rect_filled(band, CornerRadius::ZERO, colour);
    }
    if hold > 0.02 {
        let hold = hold.clamp(0.0, 1.0);
        let colour = if hold >= 0.909 { t.meter_clip } else { t.text };
        let line = if upright {
            Rect::from_min_size(pos2(rect.left(), rect.bottom() - rect.height() * hold), vec2(rect.width(), 1.0))
        } else {
            Rect::from_min_size(pos2(rect.left() + rect.width() * hold - 1.0, rect.top()), vec2(1.0, rect.height()))
        };
        p.rect_filled(line, CornerRadius::ZERO, colour);
    }
}

/// The light over a meter that comes on when the level reaches 0 dB and
/// stays on until it is clicked.
pub fn clip_light(ui: &mut Ui, rect: Rect, id: Id, on: bool) -> bool {
    let t = th();
    ui.painter().rect_filled(rect, CornerRadius::ZERO, if on { t.meter_clip } else { t.meter_well });
    ui.interact(rect.expand(2.0), id, Sense::click()).clicked()
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_fader_taper_goes_both_ways() {
        assert!((taper(0.0) - 0.72).abs() < 1e-6, "0 dB at 72% of the travel");
        for db in [-60.0, -40.0, -30.0, -18.0, -9.0, -3.0, 0.0, 3.0, 6.0] {
            assert!((taper_db(taper(db)) - db).abs() < 1e-3, "{db}");
        }
    }
}
