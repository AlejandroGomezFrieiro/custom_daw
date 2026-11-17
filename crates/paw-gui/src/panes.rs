//! The main area as the kernel's tabs and windows lay it out
//! (`runtime/lua/paw/panes.lua`): where each view the window draws itself
//! goes, the pictures of the views the kernel paints, the borders, the tabs
//! and the pane with the keyboard. Gestures go back to `paw.panes`.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use egui::{Align2, ColorImage, CornerRadius, Id, Pos2, Rect, Sense, Stroke, StrokeKind, TextureHandle, Ui, pos2, vec2};
use serde_json::{Value, json};

use crate::app::View;
use crate::icons;
use crate::model::{number, rows, text};
use crate::theme::{T_SMALL, alpha, semi, th};
use crate::widgets::{self, Look};

/// The size of the monospace font a view drawn in cells is painted in.
const MONO_SIZE: f32 = 13.0;
/// The height of a kernel's pane's title along its top, and the inset of
/// its picture from the pane's sides and bottom.
pub const HEADING: f32 = 24.0;
pub const PAD: f32 = 6.0;
/// The row of tabs along the top, when there is more than one.
const TABS: f32 = 28.0;

/// A cell of the monospace font as the rasterizer draws it: `paw.canvas`
/// lays a view drawn in cells out on it.
pub fn cell() -> (f32, f32) {
    // A run is drawn at the size that fills the cell's height: the width
    // is a character's at that size, so that a run fills its cells exactly.
    let font = paw_raster::Font::Mono;
    let height = (font.line_height() * MONO_SIZE).ceil();
    (paw_raster::measure(font, "M", height / font.line_height()), height)
}

/// A drawing (see `paw.canvas.paint`) as an image of `size` logical pixels,
/// at the screen's scale.
pub fn raster(ops: &Value, size: (f32, f32), scale: f32) -> ColorImage {
    let (width, height) = ((size.0 * scale).round().max(1.0) as u32, (size.1 * scale).round().max(1.0) as u32);
    match paw_raster::Drawing::parse(ops).paint_scaled(width, height, scale) {
        Some(pixmap) => ColorImage::from_rgba_premultiplied([width as usize, height as usize], pixmap.data()),
        None => ColorImage::new([width as usize, height as usize], vec![egui::Color32::TRANSPARENT; (width * height) as usize]),
    }
}

/// What a painted pane shows, and when and at what size it was painted.
struct Drawn {
    painted: Instant,
    size: (f32, f32),
    ops: Value,
    texture: TextureHandle,
}

#[derive(Default)]
pub struct Panes {
    /// The size of the main area the kernel was last told.
    told: (f32, f32),
    drawn: HashMap<i64, Drawn>,
    /// A border being dragged, by its place.
    border: Option<usize>,
}

/// Where each view the window draws itself goes, in the main area.
pub fn natives(state: &Value) -> Vec<(String, Rect)> {
    rows(&state["panes"])
        .iter()
        .filter(|p| p["kind"] == "native")
        .map(|p| (text(&p["view"]), pane_rect(p)))
        .collect()
}

fn pane_rect(p: &Value) -> Rect {
    Rect::from_min_size(pos2(number(&p["x"]), number(&p["y"])), vec2(number(&p["w"]), number(&p["h"])))
}

/// A pointer event as `paw.panes.pointer` and `paw.canvas.pointer` take it.
pub fn pointer_event(kind: &str, at: Pos2, button: &str, m: egui::Modifiers) -> Value {
    json!({ "kind": kind, "x": at.x, "y": at.y, "button": button, "ctrl": m.ctrl, "shift": m.shift, "alt": m.alt })
}

/// The pointer's events over `rect` this frame, in its own coordinates, as
/// a view that paints takes them: down, up, move (a button held), double,
/// hover, wheel.
pub fn pointer_events(ui: &Ui, rect: Rect, id: Id) -> Vec<Value> {
    let response = ui.interact(rect, id, Sense::click_and_drag());
    let mut out = Vec::new();
    let held = ui.data(|d| d.get_temp::<bool>(id)).unwrap_or(false);
    ui.input(|i| {
        let m = i.modifiers;
        let at = |p: Pos2| (p - rect.min).to_pos2();
        for event in &i.events {
            match event {
                egui::Event::PointerButton { pos, button, pressed, modifiers } => {
                    let name = match button {
                        egui::PointerButton::Secondary => "right",
                        egui::PointerButton::Middle => "middle",
                        _ => "left",
                    };
                    if *pressed && response.hovered() {
                        out.push(pointer_event("down", at(*pos), name, *modifiers));
                    } else if !*pressed && (held || response.hovered()) {
                        out.push(pointer_event("up", at(*pos), name, *modifiers));
                    }
                }
                egui::Event::PointerMoved(pos) if held => out.push(pointer_event("move", at(*pos), "left", m)),
                egui::Event::PointerMoved(pos) if response.hovered() => out.push(pointer_event("hover", at(*pos), "left", m)),
                egui::Event::MouseWheel { delta, modifiers, .. } if response.hovered() => {
                    if let Some(pos) = i.pointer.hover_pos() {
                        let p = at(pos);
                        out.push(json!({ "kind": "wheel", "x": p.x, "y": p.y, "dx": delta.x, "dy": delta.y, "ctrl": modifiers.ctrl, "shift": modifiers.shift }));
                    }
                }
                _ => {}
            }
        }
    });
    // Not within `input`: a response asks the context, and the lock is held.
    if response.double_clicked()
        && let Some(pos) = ui.input(|i| i.pointer.interact_pos())
    {
        out.push(pointer_event("double", (pos - rect.min).to_pos2(), "left", ui.input(|i| i.modifiers)));
    }
    let pressed = response.is_pointer_button_down_on() || (held && ui.input(|i| i.pointer.any_down()));
    ui.data_mut(|d| d.insert_temp(id, pressed));
    out
}

impl View {
    /// Tell the kernel the main area's size when it has changed; and a press
    /// anywhere in a pane gives it the keyboard.
    pub fn pane_area(&mut self, ui: &Ui, area: Rect) {
        let size = (area.width().round(), area.height().round());
        if size != self.panes.told && size.0 > 0.0 && size.1 > 0.0 {
            self.panes.told = size;
            self.eval("paw.panes.area(...)", json!([size.0, size.1]));
        }
        if self.menu.is_some() || self.text_focus || self.dialogs.open() {
            return;
        }
        let press = [egui::PointerButton::Primary, egui::PointerButton::Secondary, egui::PointerButton::Middle];
        let Some(pos) = press.into_iter().find_map(|b| crate::widgets::pressed_at(ui, b)) else { return };
        if !area.contains(pos) {
            return;
        }
        let at = pos - area.min.to_vec2();
        for pane in rows(&self.s.modal["panes"]["panes"]) {
            if pane_rect(pane).contains(at) && pane["focused"] != true {
                self.eval("paw.panes.focus(...)", json!([pane["win"]]));
                break;
            }
        }
    }

    /// The panes the kernel paints, the borders, the ring round the pane
    /// with the keyboard, and the tabs.
    pub fn draw_kernel_panes(&mut self, ui: &mut Ui, area: Rect, state: &Value) {
        let t = th();
        let all = rows(&state["panes"]).to_vec();
        let shown: Vec<i64> = all.iter().filter_map(|p| p["win"].as_i64()).collect();
        self.panes.drawn.retain(|win, _| shown.contains(win));
        let scale = ui.ctx().pixels_per_point();
        let (cell_w, cell_h) = cell();
        let mut painted_any = false;
        for pane in &all {
            let kind = pane["kind"].as_str().unwrap_or("");
            if kind == "native" {
                continue;
            }
            painted_any = true;
            let win = pane["win"].as_i64().unwrap_or(0);
            let rect = pane_rect(pane).translate(area.min.to_vec2());
            let focused = pane["focused"] == true;
            let cells = kind != "paint";
            // A view in cells draws a title row of its own, which the
            // pane's title covers.
            let under = if cells { cell_h } else { 0.0 };
            ui.painter().rect_filled(rect, CornerRadius::ZERO, t.surface);
            let picture = Rect::from_min_max(pos2(rect.left() + PAD, rect.top() + HEADING - under), pos2(rect.right() - PAD, rect.bottom() - PAD));
            let size = (picture.width().max(1.0), picture.height().max(1.0));
            // Painted again when something happened, at another size, now
            // and then regardless, and in cells every time (the kernel
            // answers `same` when nothing changed).
            let stale = self.panes.drawn.get(&win).is_none_or(|d| d.painted.elapsed() > Duration::from_millis(250) || d.size != size);
            if self.repaint || stale || cells {
                let fresh = !self.panes.drawn.contains_key(&win);
                let opts = json!({ "cell": { "w": cell_w, "h": cell_h }, "fresh": fresh, "glyphs": true });
                let drawing = self.ask("return paw.panes.paint(...)", json!([win, size.0, size.1, opts]));
                if drawing["same"] == true {
                    if let Some(d) = self.panes.drawn.get_mut(&win) {
                        d.painted = Instant::now();
                    }
                } else if !drawing["ops"].is_null() {
                    let unchanged = self.panes.drawn.get(&win).is_some_and(|d| d.ops == drawing["ops"] && d.size == size);
                    if !unchanged {
                        let image = raster(&drawing["ops"], size, scale);
                        let texture = ui.ctx().load_texture(format!("pane-{win}"), image, egui::TextureOptions::LINEAR);
                        self.panes.drawn.insert(win, Drawn { painted: Instant::now(), size, ops: drawing["ops"].clone(), texture });
                    } else if let Some(d) = self.panes.drawn.get_mut(&win) {
                        d.painted = Instant::now();
                    }
                }
            }
            if let Some(d) = self.panes.drawn.get(&win) {
                ui.painter().with_clip_rect(rect).image(d.texture.id(), picture, Rect::from_min_max(Pos2::ZERO, pos2(1.0, 1.0)), egui::Color32::WHITE);
            }
            for event in pointer_events(ui, picture, Id::unique(("pane-pointer", win))) {
                self.eval("paw.panes.pointer(...)", json!([win, event]));
                self.repaint = true;
            }
            // The title over the top, over the picture's own title row.
            let title = Rect::from_min_size(rect.min, vec2(rect.width(), HEADING));
            ui.painter().rect_filled(title, CornerRadius::ZERO, if focused { t.panel_sel } else { t.panel });
            widgets::text_in(
                ui,
                pos2(title.left() + 10.0, title.center().y),
                &text(&pane["title"]),
                semi(T_SMALL),
                if focused { t.text } else { t.text_2 },
                title.width() - 80.0,
            );
            let close = Rect::from_min_size(pos2(title.right() - 24.0, title.top() + 2.0), vec2(20.0, 20.0));
            let out = close.translate(vec2(-22.0, 0.0));
            let response = widgets::button(ui, out, Id::unique(("pane-out", win)), Some(icons::ARROW_SQUARE_OUT), "", Look::quiet());
            widgets::hint_on(&response, "open in a window of its own (Ctrl-w f)");
            if response.clicked() {
                self.command(&format!("view.window {}", text(&pane["view"])));
            }
            let response = widgets::button(ui, close, Id::unique(("pane-close", win)), Some(icons::X), "", Look::quiet());
            widgets::hint_on(&response, "close the window (:q)");
            if response.clicked() {
                self.eval("paw.panes.close(...)", json!([win]));
            }
        }
        if painted_any {
            self.again = Some(self.again.map_or(Duration::from_millis(250), |a| a.min(Duration::from_millis(250))));
        }
        // The borders between panes, dragged to share the room.
        for (i, border) in rows(&state["borders"]).iter().enumerate() {
            let across = border["dir"] == "h";
            let (x, y, length) = (number(&border["x"]), number(&border["y"]), number(&border["length"]));
            let grip = if across {
                Rect::from_min_size(pos2(area.left() + x - 3.0, area.top() + y), vec2(6.0, length))
            } else {
                Rect::from_min_size(pos2(area.left() + x, area.top() + y - 3.0), vec2(length, 6.0))
            };
            let response = ui.interact(grip, Id::unique(("pane-border", i)), Sense::drag());
            let lit = response.hovered() || response.dragged();
            let colour = if lit { alpha(t.select, 0.7) } else { t.divider };
            if across {
                ui.painter().vline(grip.center().x, grip.y_range(), Stroke::new(1.0, colour));
            } else {
                ui.painter().hline(grip.x_range(), grip.center().y, Stroke::new(1.0, colour));
            }
            if lit {
                ui.ctx().set_cursor_icon(if across { egui::CursorIcon::ResizeHorizontal } else { egui::CursorIcon::ResizeVertical });
                widgets::hint("drag to share the room between the windows");
            }
            if response.dragged()
                && let Some(pos) = response.interact_pointer_pos()
            {
                let at = pos - area.min.to_vec2();
                self.panes.border = Some(i);
                self.eval("paw.panes.border(...)", json!([i + 1, at.x, at.y]));
            }
        }
        // The ring round the pane with the keyboard, when there are several.
        if all.len() > 1
            && let Some(pane) = all.iter().find(|p| p["focused"] == true)
        {
            let rect = pane_rect(pane).translate(area.min.to_vec2());
            ui.painter().rect_stroke(rect.shrink(1.0), CornerRadius::ZERO, Stroke::new(2.0, alpha(t.select, 0.85)), StrokeKind::Middle);
        }
        // The tabs, along the top when there is more than one.
        let tabs = rows(&state["tabs"]);
        if tabs.len() > 1 {
            let bar = Rect::from_min_size(area.min, vec2(area.width(), TABS));
            ui.painter().rect_filled(bar, CornerRadius::ZERO, t.panel);
            ui.painter().hline(bar.x_range(), bar.bottom() - 0.5, Stroke::new(1.0, t.divider));
            let current = state["tab"].as_i64().unwrap_or(1) as usize;
            let mut x = bar.left() + 6.0;
            for (i, tab) in tabs.iter().enumerate() {
                let on = i + 1 == current;
                let label = format!("{}  {}", i + 1, text(&tab["title"]));
                let font = if on { semi(T_SMALL) } else { crate::theme::sans(T_SMALL) };
                let w = widgets::text_width(ui, &label, font.clone()) + 24.0;
                let rect = Rect::from_min_size(pos2(x, bar.top() + 3.0), vec2(w, TABS - 3.0));
                let response = ui.interact(rect, Id::unique(("tab", i)), Sense::click());
                let face = if on { t.surface } else if response.hovered() { egui::Color32::from_white_alpha(0x12) } else { egui::Color32::TRANSPARENT };
                ui.painter().rect_filled(rect, CornerRadius::same(4), face);
                if on {
                    ui.painter().rect_filled(Rect::from_min_size(rect.min, vec2(w, 2.0)), CornerRadius::ZERO, t.select);
                }
                ui.painter().text(rect.center(), Align2::CENTER_CENTER, label, font, if on { t.text } else { t.text_2 });
                if response.clicked() {
                    self.eval("paw.panes.tab(...)", json!([i + 1]));
                }
                x += w + 2.0;
            }
        }
    }
}
