//! The device panel: the selected track's name, a box to add a device by
//! typing part of its name, where the track's sound goes, and a card for
//! each device with its preset, its mix and its parameters.

use egui::{Align2, Color32, CornerRadius, Id, Pos2, Rect, Sense, Stroke, StrokeKind, Ui, pos2, vec2};
use serde_json::{Value, json};

use crate::app::View;
use crate::icons;
use crate::model::{self, capitalised, decibels, flag, int, number, rows, text};
use crate::theme::{T_BASE, T_MICRO, T_SMALL, T_TITLE, alpha, mono, mono_medium, sans, semi, th};
use crate::widgets::{self, Look, Moved};

#[derive(Default)]
pub struct Devices {
    /// What was typed in the search box, and what the kernel found for it:
    /// the line to show and the device's kind.
    pub query: String,
    pub hits: Vec<(String, String)>,
    /// How far the cards are scrolled.
    pub scroll: f32,
    /// A card's name dragged: the device, and where the press was.
    pub drag: Option<(i64, Pos2)>,
    /// Where each card was drawn, for a card dropped among them.
    cards: Vec<(f32, f32)>,
}

impl Devices {
    /// The devices changed: those dragged may have gone.
    pub fn project(&mut self, devices: &Value) {
        if let Some((id, _)) = self.drag
            && !rows(devices).iter().any(|d| int(&d["id"]) == id)
        {
            self.drag = None;
        }
    }
}

impl View {
    pub fn draw_devices(&mut self, ui: &mut Ui, rect: Rect) {
        let t = th();
        let p = ui.painter().clone();
        p.rect_filled(rect, CornerRadius::ZERO, t.panel);
        // Its name, on a stripe of its colour.
        let selected = self.s.track(self.s.selected).cloned();
        let head = Rect::from_min_size(rect.min, vec2(rect.width(), 40.0));
        p.rect_filled(Rect::from_min_size(head.min, vec2(4.0, 40.0)), CornerRadius::ZERO, selected.as_ref().map_or(t.text_off, |s| s.color));
        let devices = rows(&self.s.devices).to_vec();
        let count = if devices.len() == 1 { "1 device".to_string() } else { format!("{} devices", devices.len()) };
        p.text(pos2(head.right() - 12.0, head.center().y), Align2::RIGHT_CENTER, &count, sans(T_SMALL), t.text_3);
        let count_w = widgets::text_width(ui, &count, sans(T_SMALL));
        let (name, colour) = match &selected {
            Some(s) => (s.name.clone(), t.text),
            None => ("No track selected".to_string(), t.text_3),
        };
        widgets::text_in(ui, pos2(head.left() + 14.0, head.center().y), &name, semi(T_TITLE), colour, head.width() - 14.0 - 12.0 - count_w - 8.0);
        p.hline(head.x_range(), head.bottom() - 0.5, Stroke::new(1.0, t.divider));
        let inner = Rect::from_min_max(pos2(rect.left() + 10.0, head.bottom() + 10.0), pos2(rect.right() - 10.0, rect.bottom() - 10.0));
        let mut y = inner.top();
        y = self.device_search(ui, inner, y);
        if self.s.selected >= 0 && !flag(&self.s.routing["master"]) && self.s.routing.is_object() {
            y = self.routing(ui, inner, y) + 8.0;
        }
        if devices.is_empty() && self.s.selected >= 0 && self.devices.hits.is_empty() {
            let galley = p.layout("Nothing on this track yet. Type “synth”, “drums” or the name of a plugin above.".into(), sans(T_SMALL), t.text_3, inner.width());
            let h = galley.size().y;
            p.galley(pos2(inner.left(), y), galley, t.text_3);
            y += h + 8.0;
        }
        // The cards, scrolled with the wheel.
        let list = Rect::from_min_max(pos2(inner.left(), y), inner.max);
        let total: f32 = devices.iter().map(|d| card_height(d) + 8.0).sum();
        self.devices.scroll = self.devices.scroll.clamp(0.0, (total - list.height()).max(0.0));
        let mut child = ui.new_child(egui::UiBuilder::new().max_rect(list).id_salt("device-cards"));
        child.set_clip_rect(list.intersect(ui.clip_rect()));
        let mut cy = list.top() - self.devices.scroll;
        self.devices.cards.clear();
        for (at, device) in devices.iter().enumerate() {
            let h = card_height(device);
            let card = Rect::from_min_size(pos2(list.left(), cy), vec2(list.width(), h));
            self.devices.cards.push((cy, h));
            if card.bottom() >= list.top() && card.top() <= list.bottom() {
                self.card(&mut child, card, at, devices.len(), device);
            } else {
                // Out of view: no element of it is made.
            }
            cy += h + 8.0;
        }
        self.device_drop(ui, list);
        if View::pointer_in(ui, list).is_some() && !widgets::wheel_taken() {
            self.devices.scroll = (self.devices.scroll - widgets::wheel_y(ui) * 40.0).clamp(0.0, (total - list.height()).max(0.0));
        }
    }

    /// Add a device by typing part of its name.
    fn device_search(&mut self, ui: &mut Ui, inner: Rect, y: f32) -> f32 {
        let t = th();
        let field = Rect::from_min_size(pos2(inner.left(), y), vec2(inner.width(), 28.0));
        let id = Id::unique("device-search");
        self.text_box(id);
        let focused = ui.memory(|m| m.has_focus(id));
        ui.painter().rect(field, CornerRadius::same(4), t.well, Stroke::new(1.0, if focused { t.select } else { Color32::TRANSPARENT }), StrokeKind::Inside);
        widgets::icon(ui, Rect::from_min_size(field.min + vec2(8.0, 7.0), vec2(14.0, 14.0)), icons::PH_PLUS, t.text_3);
        let enabled = self.s.selected >= 0;
        let hint = if enabled { "Add a device: its name, @instrument, @fav" } else { "Select a track to add devices" };
        let mut query = self.devices.query.clone();
        let edit = egui::TextEdit::singleline(&mut query)
            .id(id)
            .hint_text(egui::RichText::new(hint).color(t.text_3).font(sans(T_BASE)))
            .font(sans(T_BASE))
            .frame(egui::Frame::NONE)
            .margin(vec2(0.0, 6.0));
        let response = ui.add_enabled_ui(enabled, |ui| ui.put(Rect::from_min_max(field.min + vec2(28.0, 0.0), field.max - vec2(8.0, 0.0)), edit)).inner;
        let (enter, escape) = ui.input(|i| (i.key_pressed(egui::Key::Enter), i.key_pressed(egui::Key::Escape)));
        if response.changed() {
            self.search_devices(&query);
        }
        if response.lost_focus() && enter {
            if let Some((_, kind)) = self.devices.hits.first().cloned() {
                self.pass("add_device", json!([kind, query]));
            }
            self.search_devices("");
        } else if escape && (response.has_focus() || response.lost_focus()) {
            self.search_devices("");
            response.surrender_focus();
        }
        let mut y = field.bottom() + 8.0;
        // What the kernel found, a line a device; the star marks a favourite.
        if !self.devices.hits.is_empty() {
            let hits = self.devices.hits.clone();
            let h = (hits.len() as f32 * 24.0 + 8.0).min(190.0);
            let box_ = Rect::from_min_size(pos2(inner.left(), y), vec2(inner.width(), h));
            ui.painter().rect(box_, CornerRadius::same(4), t.card, Stroke::new(1.0, t.card_line), StrokeKind::Inside);
            let clip = ui.painter().with_clip_rect(box_.shrink(1.0));
            for (at, (line, kind)) in hits.iter().enumerate() {
                let row = Rect::from_min_size(pos2(box_.left() + 4.0, box_.top() + 4.0 + at as f32 * 24.0), vec2(box_.width() - 8.0, 24.0));
                if row.bottom() > box_.bottom() {
                    break;
                }
                let pick = Rect::from_min_max(row.min + vec2(22.0, 0.0), row.max);
                let response = ui.interact(pick, Id::unique(("device-hit", at)), Sense::click());
                let face = if response.hovered() { alpha(t.select, 0.25) } else if at == 0 { Color32::from_white_alpha(0x12) } else { Color32::TRANSPARENT };
                clip.rect_filled(row, CornerRadius::same(3), face);
                let star_rect = Rect::from_min_size(row.min, vec2(22.0, 24.0));
                let star = ui.interact(star_rect, Id::unique(("device-star", at)), Sense::click());
                clip.text(star_rect.center(), Align2::CENTER_CENTER, "☆", sans(T_BASE), if star.hovered() { t.warn } else { t.text_3 });
                widgets::text_in(ui, pos2(row.left() + 26.0, row.center().y), line, sans(T_BASE), t.text, row.width() - 34.0);
                if star.clicked() {
                    self.pass("toggle_favourite", json!([kind]));
                    self.flush();
                    let q = self.devices.query.clone();
                    self.search_devices(&q);
                }
                if response.clicked() {
                    self.pass("add_device", json!([kind, self.devices.query]));
                    self.search_devices("");
                }
            }
            y = box_.bottom() + 8.0;
        }
        y
    }

    /// The search box lists what the kernel finds (`paw.fx.search`).
    fn search_devices(&mut self, query: &str) {
        self.devices.query = query.to_string();
        self.devices.hits = if query.trim().is_empty() {
            Vec::new()
        } else {
            let found = self.ask("return paw.frontend.act.search_devices(...)", json!([query]));
            rows(&found).iter().map(|h| (text(&h["line"]), text(&h["kind"]))).collect()
        };
    }

    /// Where the track's sound goes: the track it plays into, and the
    /// tracks it is sent to as well.
    fn routing(&mut self, ui: &mut Ui, inner: Rect, y: f32) -> f32 {
        let t = th();
        let routing = self.s.routing.clone();
        let sends = rows(&routing["sends"]).to_vec();
        let h = 8.0 + 22.0 + sends.len() as f32 * 26.0 + 8.0;
        let card = Rect::from_min_size(pos2(inner.left(), y), vec2(inner.width(), h));
        ui.painter().rect_filled(card, CornerRadius::same(4), t.card);
        let track = self.s.selected;
        let row = Rect::from_min_size(card.min + vec2(8.0, 8.0), vec2(card.width() - 16.0, 22.0));
        ui.painter().text(pos2(row.left(), row.center().y), Align2::LEFT_CENTER, "OUTPUT", semi(T_MICRO), t.text_3);
        let out = Rect::from_min_max(pos2(row.left() + 52.0, row.top()), pos2(row.right() - 62.0 - 6.0, row.bottom()));
        let response = ui.interact(out, Id::unique("route-output"), Sense::click());
        ui.painter().rect_filled(out, CornerRadius::same(3), if response.hovered() { t.control_hover } else { t.control });
        widgets::text_in(ui, pos2(out.left() + 8.0, out.center().y), &text(&routing["output"]), sans(T_BASE), t.text, out.width() - 28.0);
        widgets::icon(ui, Rect::from_min_size(pos2(out.right() - 18.0, out.center().y - 6.0), vec2(12.0, 12.0)), icons::CARET_DOWN, t.text_2);
        widgets::hint_on(&response, "output: the track this one plays into; a bus or a group takes several");
        if response.clicked() {
            self.open_menu("output", json!([track]), out.left_bottom());
        }
        let send = Rect::from_min_size(pos2(row.right() - 62.0, row.top()), vec2(62.0, 22.0));
        let response = ui.interact(send, Id::unique("route-send"), Sense::click());
        ui.painter().rect_filled(send, CornerRadius::same(3), if response.hovered() { t.control_hover } else { t.control });
        widgets::icon(ui, Rect::from_min_size(pos2(send.left() + 8.0, send.center().y - 6.0), vec2(12.0, 12.0)), icons::PH_PLUS, t.text_2);
        ui.painter().text(pos2(send.left() + 24.0, send.center().y), Align2::LEFT_CENTER, "Send", sans(T_BASE), t.text);
        widgets::hint_on(&response, "send: also feed this track's sound to another, a reverb for one, at a level of its own");
        if response.clicked() {
            self.open_menu("send", json!([track]), send.left_bottom());
        }
        for (at, s) in sends.iter().enumerate() {
            let row = Rect::from_min_size(pos2(card.left() + 8.0, card.top() + 8.0 + 26.0 + at as f32 * 26.0), vec2(card.width() - 16.0, 22.0));
            widgets::text_in(ui, pos2(row.left(), row.center().y), &format!("→ {}", text(&s["name"])), sans(T_SMALL), t.text_2, 64.0);
            let db = number(&s["level"]);
            let slider = Rect::from_min_max(pos2(row.left() + 70.0, row.top() + 3.0), pos2(row.right() - 58.0 - 28.0 - 20.0 - 18.0, row.bottom() - 3.0));
            let (_, moved) = widgets::slider(ui, slider, Id::unique(("send", at)), model::fader(db), false);
            for m in moved {
                match m {
                    Moved::To(v) => self.pass("set_send", json!([track, at + 1, v * 66.0 - 60.0])),
                    Moved::Reset => self.pass("set_send", json!([track, at + 1, 0.0])),
                    Moved::Held(_) => {}
                }
            }
            let x = slider.right() + 6.0;
            ui.painter().text(pos2(x + 58.0, row.center().y), Align2::RIGHT_CENTER, format!("{} dB", decibels(db)), mono_medium(T_SMALL), t.text_2);
            let pre = Rect::from_min_size(pos2(x + 64.0, row.top() + 2.0), vec2(28.0, 18.0));
            if widgets::flag(ui, pre, Id::unique(("send-pre", at)), "pre", flag(&s["pre"]), t.select).clicked() {
                self.pass("set_send", json!([track, at + 1, Value::Null, !flag(&s["pre"])]));
            }
            let x_rect = Rect::from_min_size(pos2(pre.right() + 2.0, row.top() + 1.0), vec2(20.0, 20.0));
            if widgets::button(ui, x_rect, Id::unique(("send-x", at)), Some(icons::X), "", Look::quiet()).clicked() {
                self.pass("remove_send", json!([track, at + 1]));
            }
        }
        card.bottom()
    }

    /// A device's card.
    fn card(&mut self, ui: &mut Ui, card: Rect, at: usize, count: usize, d: &Value) {
        let t = th();
        let id = int(&d["id"]);
        let focus_row = (self.s.focused() == "devices").then(|| (int(&self.s.modal["device"]), int(&self.s.modal["param"])));
        let outline = focus_row.is_some_and(|(dev, _)| dev == at as i64 + 1);
        ui.painter().rect(card, CornerRadius::same(4), t.card, Stroke::new(if outline { 1.0 } else { 0.0 }, t.select), StrokeKind::Inside);
        let bypass = flag(&d["bypass"]);
        let status = text(&d["status"]);
        let stopped = text(&d["stopped"]);
        let format = text(&d["format"]);
        // Its header: on or off, the name, and what can be done with it.
        let head = Rect::from_min_size(card.min + vec2(4.0, 0.0), vec2(card.width() - 8.0, 26.0));
        let b = |i: f32| Rect::from_min_size(pos2(head.right() - (i + 1.0) * 24.0, head.top() + 2.0), vec2(22.0, 22.0));
        let power = Rect::from_min_size(pos2(head.left(), head.top() + 2.0), vec2(22.0, 22.0));
        let response = widgets::button(ui, power, Id::unique(("power", id)), Some(icons::POWER), "", Look { idle_ink: Some(t.text_3), ..Look::quiet().on(!bypass) });
        widgets::name(&response, &format!("power of {}", text(&d["name"])));
        if response.clicked() {
            self.pass("toggle_bypass", json!([id]));
        }
        let mut right = 0.0;
        let device_name = text(&d["name"]);
        let response = widgets::button(ui, b(right), Id::unique(("dev-x", id)), Some(icons::X), "", Look::quiet());
        widgets::name(&response, &format!("remove {device_name}"));
        if response.clicked() {
            self.eval("return paw.api.device_remove(...)", json!([id]));
        }
        right += 1.0;
        let response = widgets::button(ui, b(right), Id::unique(("dev-down", id)), Some(icons::CARET_DOWN), "", Look::quiet().enabled(at + 1 < count));
        widgets::name(&response, &format!("move {device_name} down"));
        if response.clicked() {
            self.pass("move_device", json!([id, 1]));
        }
        right += 1.0;
        let response = widgets::button(ui, b(right), Id::unique(("dev-up", id)), Some(icons::CARET_UP), "", Look::quiet().enabled(at > 0));
        widgets::name(&response, &format!("move {device_name} up"));
        if response.clicked() {
            self.pass("move_device", json!([id, -1]));
        }
        right += 1.0;
        // Take a plugin offline: kept with its state, not run.
        if format != "builtin" && status != "offline" {
            let response = widgets::button(ui, b(right), Id::unique(("dev-offline", id)), Some(icons::PLUGS), "", Look::quiet());
            widgets::hint_on(&response, "offline: stop running this plugin and keep it with its saved state");
            if response.clicked() {
                self.pass("toggle_offline", json!([id]));
            }
            right += 1.0;
        }
        let editor = text(&d["editor"]);
        if !editor.is_empty() {
            if widgets::button(ui, b(right), Id::unique(("dev-editor", id)), Some(icons::ARROW_SQUARE_OUT), "", Look::quiet().on(editor == "open")).clicked() {
                self.eval("return paw.api.device_editor(...)", json!([id]));
            }
            right += 1.0;
        }
        let mut name_right = head.right() - right * 24.0 - 4.0;
        if format != "builtin" {
            let w = widgets::text_width(ui, &format, semi(T_MICRO));
            ui.painter().text(pos2(name_right, head.center().y), Align2::RIGHT_CENTER, &format, semi(T_MICRO), t.text_3);
            name_right -= w + 4.0;
        }
        // The name is also a handle: dragged onto a track's header it moves
        // the device there (Ctrl copies it), up or down the list it
        // reorders the chain.
        let name_rect = Rect::from_min_max(pos2(power.right() + 2.0, head.top()), pos2(name_right, head.bottom()));
        let response = ui.interact(name_rect, Id::unique(("dev-name", id)), Sense::drag());
        let dragging = self.devices.drag.is_some_and(|(d, _)| d == id);
        let colour = if dragging {
            t.select
        } else if status == "missing" {
            t.warn
        } else if status == "offline" || status == "loading" || bypass {
            t.text_3
        } else if !stopped.is_empty() {
            t.error
        } else {
            t.text
        };
        widgets::text_in(ui, pos2(name_rect.left(), name_rect.center().y), &text(&d["name"]), semi(T_BASE), colour, name_rect.width());
        if response.hovered() {
            ui.ctx().set_cursor_icon(egui::CursorIcon::Grab);
        }
        if response.dragged()
            && self.devices.drag.is_none()
            && let Some(p) = response.interact_pointer_pos()
        {
            self.devices.drag = Some((id, p));
        }
        ui.painter().hline(card.x_range(), head.bottom() + 0.5, Stroke::new(1.0, alpha(t.divider, 0.6)));
        let mut y = head.bottom() + 1.0;
        // The preset: the one loaded, a step either way, and a menu of them.
        let row = Rect::from_min_size(pos2(card.left() + 4.0, y + 4.0), vec2(card.width() - 8.0, 20.0));
        let back = Rect::from_min_size(row.min, vec2(widgets::button_width(ui, "◀", false, 20.0), 20.0));
        if widgets::button(ui, back, Id::unique(("preset-back", id)), None, "◀", Look::quiet()).clicked() {
            self.pass("preset_step", json!([id, -1]));
        }
        let fwd = Rect::from_min_size(pos2(row.right() - back.width(), row.top()), back.size());
        if widgets::button(ui, fwd, Id::unique(("preset-fwd", id)), None, "▶", Look::quiet()).clicked() {
            self.pass("preset_step", json!([id, 1]));
        }
        let menu = Rect::from_min_max(pos2(back.right() + 2.0, row.top()), pos2(fwd.left() - 2.0, row.bottom()));
        let preset = text(&d["preset"]);
        if self.dropdown(ui, menu, Id::unique(("preset", id)), &format!("{}  ▾", if preset.is_empty() { "No preset" } else { &preset }), !preset.is_empty(), "") {
            self.open_menu("preset", json!([id]), menu.left_bottom());
        }
        y += 26.0;
        // Where its further output pairs play, for a device with several.
        let pairs = int(&d["pairs"]);
        if pairs > 1 {
            let row = Rect::from_min_size(pos2(card.left() + 8.0, y), vec2(card.width() - 16.0, 22.0));
            ui.painter().text(pos2(row.left(), row.center().y), Align2::LEFT_CENTER, "Outs", sans(T_SMALL), t.text_3);
            let routed = int(&d["routed"]);
            let menu = Rect::from_min_max(pos2(row.left() + 36.0, row.top() + 1.0), pos2(row.right(), row.top() + 21.0));
            if self.dropdown(ui, menu, Id::unique(("outs", id)), &format!("{routed} of {} more pairs routed  ▾", pairs - 1), routed > 0, "") {
                self.open_menu("outputs", json!([id]), menu.left_bottom());
            }
            y += 22.0;
        }
        // The track it listens to, for a device with a side-chain.
        if flag(&d["keyed"]) {
            let row = Rect::from_min_size(pos2(card.left() + 8.0, y), vec2(card.width() - 16.0, 22.0));
            ui.painter().text(pos2(row.left(), row.center().y), Align2::LEFT_CENTER, "Key", sans(T_SMALL), t.text_3);
            let key = text(&d["sidechain"]);
            let menu = Rect::from_min_max(pos2(row.left() + 36.0, row.top() + 1.0), pos2(row.right(), row.top() + 21.0));
            let label = format!("{}  ▾", if key.is_empty() { "Its own input" } else { &key });
            if self.dropdown(ui, menu, Id::unique(("key", id)), &label, !key.is_empty(), "side-chain: the track this device listens to, such as a kick that ducks the bass") {
                self.open_menu("sidechain", json!([id]), menu.left_bottom());
            }
            y += 22.0;
        }
        // The host's mix around the device: how much of it is heard, and its level.
        let row = Rect::from_min_size(pos2(card.left() + 8.0, y), vec2(card.width() - 16.0, 22.0));
        let half = (row.width() - 6.0) / 2.0;
        let wet = number(&d["wet"]);
        let gain = number(&d["gain"]);
        for (n, (label, key, value, shown, width, centred)) in
            [("Wet", "fx_wet", wet, format!("{}%", (wet * 100.0).round()), 34.0, false), ("Out", "fx_gain", (gain + 24.0) / 48.0, format!("{} dB", (gain * 10.0).round() / 10.0), 48.0, true)].into_iter().enumerate()
        {
            let x = row.left() + n as f32 * (half + 6.0);
            ui.painter().text(pos2(x, row.center().y), Align2::LEFT_CENTER, label, sans(T_SMALL), t.text_3);
            let lw = widgets::text_width(ui, label, sans(T_SMALL)) + 6.0;
            let slider = Rect::from_min_max(pos2(x + lw, row.top() + 3.0), pos2(x + half - width - 6.0, row.bottom() - 3.0));
            let (_, moved) = widgets::slider(ui, slider, Id::unique((key, id)), value, centred);
            for m in moved {
                match m {
                    Moved::To(v) => self.pass("set_param", json!([id, key, v])),
                    Moved::Reset => self.pass("reset_param", json!([id, key])),
                    Moved::Held(_) => {}
                }
            }
            ui.painter().text(pos2(x + half, row.center().y), Align2::RIGHT_CENTER, shown, mono(T_SMALL), t.text);
        }
        y += 22.0;
        // A plugin being made, not installed, or offline: passed over until it runs.
        if matches!(status.as_str(), "loading" | "missing" | "offline") {
            let (shape, ink, said) = match status.as_str() {
                "missing" => (icons::WARNING, t.warn, "Not installed: kept with its saved state"),
                "offline" => (icons::PLUGS, t.text_3, "Offline: kept with its saved state"),
                _ => (icons::CIRCLE, t.text_3, "Loading…"),
            };
            let row = Rect::from_min_size(pos2(card.left() + 8.0, y + 8.0), vec2(card.width() - 16.0, 22.0));
            widgets::icon(ui, Rect::from_min_size(row.min + vec2(0.0, 4.0), vec2(14.0, 14.0)), shape, ink);
            widgets::text_in(ui, pos2(row.left() + 20.0, row.center().y), said, sans(T_SMALL), if status == "missing" { t.warn } else { t.text_2 }, row.width() - 90.0);
            if status == "offline" {
                let w = widgets::button_width(ui, "Online", false, 22.0);
                if widgets::button(ui, Rect::from_min_size(pos2(row.right() - w, row.top()), vec2(w, 22.0)), Id::unique(("online", id)), None, "Online", Look::default()).clicked() {
                    self.pass("toggle_offline", json!([id]));
                }
            }
            y += 30.0;
        }
        // A plugin that crashed or hung: what happened, and a way back.
        if !stopped.is_empty() && status != "missing" {
            let row = Rect::from_min_size(pos2(card.left() + 8.0, y + 8.0), vec2(card.width() - 16.0, 22.0));
            widgets::icon(ui, Rect::from_min_size(row.min + vec2(0.0, 4.0), vec2(14.0, 14.0)), icons::WARNING, t.error);
            let w = widgets::button_width(ui, "Restart", false, 22.0);
            widgets::text_in(ui, pos2(row.left() + 20.0, row.center().y), &format!("Stopped: {stopped}"), sans(T_SMALL), t.error, row.width() - 26.0 - w);
            if widgets::button(ui, Rect::from_min_size(pos2(row.right() - w, row.top()), vec2(w, 22.0)), Id::unique(("restart", id)), None, "Restart", Look::default()).clicked() {
                self.pass("restart_device", json!([id]));
            }
            y += 38.0;
        }
        // Its parameters.
        let faded = if bypass { 0.5 } else { 1.0 };
        y += 4.0;
        for (n, param) in rows(&d["params"]).iter().enumerate() {
            let row = Rect::from_min_size(pos2(card.left() + 8.0, y), vec2(card.width() - 12.0, 22.0));
            let key = text(&param["key"]);
            let focused = focus_row.is_some_and(|(dev, p)| dev == at as i64 + 1 && p == n as i64 + 1);
            let name_rect = Rect::from_min_size(row.min, vec2(84.0, 22.0));
            let name = capitalised(&text(&param["name"]));
            widgets::text_in(ui, pos2(name_rect.left(), name_rect.center().y), &name, sans(T_SMALL), alpha(if focused { t.select } else { t.text_2 }, faded), 84.0);
            // The name: a right click offers to automate the parameter, or to edit its curve.
            let response = ui.interact(name_rect, Id::unique(("param-name", id, n)), Sense::click());
            if response.secondary_clicked() {
                self.open_menu("param", json!([id, key]), response.interact_pointer_pos().unwrap_or(name_rect.left_bottom()));
            }
            let slider = Rect::from_min_max(pos2(name_rect.right() + 6.0, row.top() + 3.0), pos2(row.right() - 62.0 - 6.0 - 20.0 - 20.0 - 18.0, row.bottom() - 3.0));
            let (response, moved) = widgets::slider(ui, slider, Id::unique(("param", id, n)), number(&param["value"]), false);
            widgets::hint_on(&response, "parameter: drag · wheel to nudge · double click to put it back");
            for m in moved {
                match m {
                    Moved::To(v) => self.pass("set_param", json!([id, key, v])),
                    Moved::Reset => self.pass("reset_param", json!([id, key])),
                    Moved::Held(on) => self.pass("hold", json!([self.s.selected, "param", id, key, on])),
                }
            }
            let value_x = slider.right() + 6.0;
            let shown = widgets::elide(ui, &text(&param["text"]), mono_medium(T_SMALL), 62.0);
            ui.painter().text(pos2(value_x + 62.0, row.center().y), Align2::RIGHT_CENTER, shown, mono_medium(T_SMALL), alpha(t.text, faded));
            let auto = Rect::from_min_size(pos2(value_x + 68.0, row.top() + 2.0), vec2(20.0, 18.0));
            let response = widgets::button(ui, auto, Id::unique(("param-auto", id, n)), Some(icons::CHART_LINE), "", Look { idle_ink: Some(t.text_off), ..Look::quiet() });
            widgets::hint_on(&response, "automate: show this parameter's lane on the track, to draw how it moves over time");
            if response.clicked() {
                self.automate_param(id, &key);
            }
            let learn = auto.translate(vec2(20.0, 0.0));
            let response = widgets::button(ui, learn, Id::unique(("param-learn", id, n)), Some(icons::PLUGS), "", Look { idle_ink: Some(t.text_off), ..Look::quiet() });
            widgets::hint_on(&response, "learn: click, then move a knob or fader of a MIDI controller, and it moves this parameter from then on");
            if response.clicked() {
                self.command(&format!("learn.param {id} {key}"));
            }
            y += 22.0;
        }
        // The rest: found by name, and then shown first.
        let more = int(&d["more"]);
        if more > 0 {
            let row = Rect::from_min_size(pos2(card.left() + 8.0, y), vec2(card.width() - 12.0, 18.0));
            let response = ui.interact(row, Id::unique(("param-more", id)), Sense::click());
            widgets::text_in(ui, pos2(row.left(), row.center().y), &format!("and {more} more parameters: find one by name…"), sans(T_SMALL), if response.hovered() { t.text } else { t.text_3 }, row.width());
            if response.clicked() {
                self.pass("device_command", json!([id, "param"]));
            }
        }
    }

    /// A field that opens a menu: its text, with `▾`.
    fn dropdown(&self, ui: &mut Ui, rect: Rect, id: Id, label: &str, set: bool, tip: &str) -> bool {
        let t = th();
        let response = ui.interact(rect, id, Sense::click());
        ui.painter().rect_filled(rect, CornerRadius::same(3), if response.hovered() { Color32::from_white_alpha(0x12) } else { t.well });
        widgets::text_in(ui, pos2(rect.left() + 8.0, rect.center().y), label, sans(T_SMALL), if set { t.text } else { t.text_3 }, rect.width() - 16.0);
        if !tip.is_empty() {
            widgets::hint_on(&response, tip);
        }
        response.clicked()
    }

    /// A card's name let go: on a track's header the device goes there
    /// (Ctrl copies it); in the list, before the card whose middle is below.
    fn device_drop(&mut self, ui: &Ui, list: Rect) {
        let Some((id, from)) = self.devices.drag else { return };
        let pos = ui.input(|i| i.pointer.interact_pos());
        if let Some(p) = pos
            && (p - from).length() > 6.0
        {
            widgets::hint("drop on a track's header to move the device there (Ctrl copies it), or up or down here to reorder");
            ui.ctx().set_cursor_icon(egui::CursorIcon::Grabbing);
        }
        if !ui.input(|i| i.pointer.primary_released()) {
            return;
        }
        self.devices.drag = None;
        let (Some(p), ctrl) = (pos, ui.input(|i| i.modifiers.ctrl)) else { return };
        if (p - from).length() <= 6.0 {
            return;
        }
        if let Some(track) = self.arrange.header_at(p).and_then(|row| self.s.tracks.get(row)).map(|t| t.id) {
            self.pass("drop_device", json!([id, track, ctrl]));
            return;
        }
        let count = self.devices.cards.len();
        let index = (0..count).find(|&i| self.devices.cards.get(i).is_some_and(|(top, h)| p.y < top + h / 2.0)).unwrap_or(count);
        let _ = list;
        self.pass("place_device", json!([id, index + 1, ctrl]));
    }
}

/// How tall a device's card is drawn.
fn card_height(d: &Value) -> f32 {
    let status = d["status"].as_str().unwrap_or("");
    let mut h = 26.0 + 1.0 + 26.0 + 22.0 + 4.0 + 6.0;
    if int(&d["pairs"]) > 1 {
        h += 22.0;
    }
    if flag(&d["keyed"]) {
        h += 22.0;
    }
    if matches!(status, "loading" | "missing" | "offline") {
        h += 30.0;
    }
    if d["stopped"].as_str().is_some_and(|s| !s.is_empty()) && status != "missing" {
        h += 38.0;
    }
    h += rows(&d["params"]).len() as f32 * 22.0;
    if int(&d["more"]) > 0 {
        h += 18.0;
    }
    h
}
