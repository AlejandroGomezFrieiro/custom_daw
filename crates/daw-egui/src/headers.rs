//! The tracks' headers down the left of the arrange view: number, name,
//! input, monitor, M S R and the automation mode, a fader with its level and
//! a pan knob, what the track goes through, and its meters.

use egui::{Align2, CornerRadius, Id, Pos2, Rect, Sense, Stroke, Ui, pos2, vec2};
use serde_json::json;

use crate::app::View;
use crate::arrange::{Geo, Gesture, HEADER_W};
use crate::icons;
use crate::model::{self, Track, decibels, pan_text};
use crate::theme::{T_BASE, T_SMALL, alpha, mono, mono_medium, sans, semi, th};
use crate::widgets::{self, Look, Moved};

/// What a header hints, by what is under the pointer.
const HEADER_HINT: &str = "track: click selects · double click renames · drag up or down to move it, into or out of a group · right click for colour and more";

impl View {
    pub fn headers(&mut self, ui: &mut Ui, pane: Rect, geo: &Geo) {
        let t = th();
        let area = Rect::from_min_max(pos2(pane.left(), geo.lanes.top()), pos2(pane.left() + HEADER_W, pane.bottom()));
        let mut child = ui.new_child(egui::UiBuilder::new().max_rect(area).id_salt("headers"));
        child.set_clip_rect(area.intersect(ui.clip_rect()));
        let ui = &mut child;
        let pointer = ui.input(|i| i.pointer.latest_pos());
        let tracks = self.s.tracks.clone();
        for (index, track) in tracks.iter().enumerate() {
            let mut top = geo.row_top(index);
            // A header dragged to move its track follows the pointer.
            if let (Some(Gesture::Header { row, from }), Some(p)) = (&self.arrange.gesture, pointer)
                && *row == index
                && (p.y - from).abs() > 6.0
            {
                top += p.y - from;
            }
            let mut height = (track.size * geo.rh - 1.0).max(18.0);
            if let (Some(Gesture::Size { id, from, .. }), Some(p)) = (&self.arrange.gesture, pointer)
                && *id == track.id
            {
                height = (height + p.y - from).max(18.0);
            }
            let rect = Rect::from_min_size(pos2(area.left(), top), vec2(HEADER_W, height));
            if rect.bottom() < area.top() || rect.top() > area.bottom() {
                continue;
            }
            self.header(ui, index, track, rect, geo);
        }
        // Under the last track: how to make another.
        let add = Rect::from_min_size(pos2(area.left() + 10.0, geo.row_top(tracks.len()) + 6.0), vec2(110.0, 26.0));
        if widgets::button(ui, add, Id::unique("new-track"), Some(icons::PH_PLUS), "New track", Look::quiet()).clicked() {
            self.open_menu("add_track", json!([]), add.left_bottom() + vec2(0.0, 2.0));
        }
        let _ = t;
    }

    fn header(&mut self, ui: &mut Ui, index: usize, track: &Track, rect: Rect, geo: &Geo) {
        let t = th();
        let selected = track.id == self.s.selected;
        let p = ui.painter().clone();
        p.rect_filled(rect, CornerRadius::ZERO, if selected { t.panel_sel } else { t.panel });
        // A stripe in the track's colour, and a line under it.
        p.rect_filled(Rect::from_min_size(rect.min, vec2(4.0, rect.height())), CornerRadius::ZERO, track.color);
        p.hline(rect.x_range(), rect.bottom() + 0.5, Stroke::new(1.0, t.divider));
        let clip_px = track.clip_size * geo.rh;
        let pad_top = if clip_px < 40.0 { 4.0 } else if clip_px < 60.0 { 3.0 } else { 6.0 };
        // The whole header first: what is on it comes after and over it.
        let body = ui.interact(rect, Id::unique(("header", track.id)), Sense::click_and_drag());
        if !track.master {
            self.header_body(ui, index, track, &body, rect);
        } else if body.clicked() {
            self.pass("select", json!([track.id, self.s.cursor]));
        }
        widgets::hint_on(&body, HEADER_HINT);
        // Its number.
        if !track.master {
            let y = rect.top() + if geo.rh < 40.0 { 4.0 } else if geo.rh < 60.0 { 3.0 } else { 6.0 } + 10.0;
            p.text(pos2(rect.left() + 8.0, y), Align2::LEFT_CENTER, track.number.to_string(), mono(T_SMALL), if selected { t.text_2 } else { t.text_3 });
        }
        // The first line: name and switches. A member of a group stands a
        // step in under it.
        let left = rect.left() + 34.0 + track.depth as f32 * 12.0;
        let right = rect.right() - 30.0;
        let line = Rect::from_min_max(pos2(left, rect.top() + pad_top), pos2(right, rect.top() + pad_top + 20.0));
        let buttons = if track.master { 0.0 } else { 6.0 * 22.0 };
        let mut x = line.left();
        if track.group {
            let fold = Rect::from_min_size(pos2(x, line.top()), vec2(16.0, 20.0));
            let response = ui.interact(fold, Id::unique(("fold", track.id)), Sense::click());
            let shape = if track.folded { icons::CARET_RIGHT } else { icons::CARET_DOWN };
            widgets::icon(ui, Rect::from_center_size(fold.center(), vec2(12.0, 12.0)), shape, if response.hovered() { t.text } else { t.text_2 });
            widgets::hint_on(&response, "group: fold its tracks away, or open it");
            if response.clicked() {
                self.pass("fold", json!([track.id]));
            }
            x += 18.0;
        }
        let name_w = (line.right() - buttons - x).max(0.0);
        let renaming = self.arrange.renaming.as_ref().is_some_and(|(id, _)| *id == track.id);
        if renaming {
            self.rename_box(ui, Rect::from_min_size(pos2(x, line.top()), vec2(name_w, 20.0)));
        } else {
            let name = if track.folded { format!("{}   +{}", track.name, track.members) } else { track.name.clone() };
            let font = if selected || track.group { semi(T_BASE) } else { sans(T_BASE) };
            widgets::text_in(ui, pos2(x, line.center().y), &name, font, t.text, name_w);
        }
        if !track.master {
            self.switches(ui, index, track, pos2(line.right() - buttons + 2.0, line.top() + 1.0));
        }
        let mut y = line.bottom() + if clip_px < 60.0 { 2.0 } else { 4.0 };
        // The fader and the pan.
        if clip_px >= 44.0 {
            let row = Rect::from_min_max(pos2(line.left() - track.depth as f32 * 12.0 + track.depth as f32 * 12.0, y), pos2(line.right(), y + 16.0));
            let fader = Rect::from_min_max(row.min, pos2(row.right() - 16.0 - 6.0 - 40.0 - 6.0, row.bottom()));
            let (response, moved) = widgets::slider(ui, fader, Id::unique(("volume", track.id)), model::fader(track.volume), false);
            widgets::hint_on(&response, "volume: drag · wheel to nudge · double click for 0 dB");
            for m in moved {
                match m {
                    Moved::To(v) => self.pass("set_volume", json!([track.id, -60.0 + v * 66.0])),
                    Moved::Reset => self.pass("set_volume", json!([track.id, 0.0])),
                    Moved::Held(on) => self.pass("hold", json!([track.id, "volume", 0, "", on])),
                }
            }
            p.text(pos2(fader.right() + 6.0 + 40.0, row.center().y), Align2::RIGHT_CENTER, decibels(track.volume), mono_medium(T_SMALL), t.text_2);
            let knob = Rect::from_min_size(pos2(row.right() - 16.0, row.top()), vec2(16.0, 16.0));
            let (response, moved) = widgets::knob(ui, knob, Id::unique(("pan", track.id)), (track.pan + 1.0) / 2.0);
            widgets::hint_on(&response, format!("pan {}: drag up and down · wheel to nudge · double click for the centre", pan_text(track.pan)));
            for m in moved {
                match m {
                    Moved::To(v) => self.pass("set_pan", json!([track.id, v * 2.0 - 1.0])),
                    Moved::Reset => self.pass("set_pan", json!([track.id, 0.0])),
                    Moved::Held(on) => self.pass("hold", json!([track.id, "pan", 0, "", on])),
                }
            }
            y = row.bottom() + if clip_px < 60.0 { 2.0 } else { 4.0 };
        }
        // What the track's sound goes through; or, while automation is
        // edited, which lane the track shows.
        if clip_px >= 60.0 {
            let width = line.right() - line.left();
            if !self.show_automation {
                let mut said = String::new();
                if !track.kind.is_empty() {
                    said += &format!("{}  ·  ", track.kind);
                }
                if !track.input_label.is_empty() {
                    said += &format!("{}  ›  ", track.input_label);
                }
                said += if track.chain.is_empty() { if track.master { "" } else { "no devices" } } else { &track.chain };
                widgets::text_in(ui, pos2(line.left(), y + 7.0), &said, sans(T_SMALL), t.text_3, width);
                if clip_px >= 96.0 {
                    let pan = pan_text(track.pan);
                    let said = if pan == "C" { "Pan centre".to_string() } else { format!("Pan {pan}") };
                    widgets::text_in(ui, pos2(line.left(), y + 7.0 + 18.0), &said, sans(T_SMALL), t.text_3, width);
                }
            } else {
                let name = self.shown_lane(index).map_or("Volume".to_string(), |l| l.name.clone());
                let pick = Rect::from_min_size(pos2(line.left(), y), vec2(width, 14.0));
                let response = ui.interact(pick, Id::unique(("lane-pick", track.id)), Sense::click());
                widgets::text_in(ui, pos2(pick.left(), pick.center().y), &format!("{name}  ▾"), semi(T_SMALL), if response.hovered() { t.text } else { t.text_2 }, width);
                widgets::hint_on(&response, "automation: click to choose what this track's lane moves; a parameter is added from its device on the right");
                if response.clicked() {
                    let mut choices = vec!["Volume".to_string(), "Pan".to_string()];
                    choices.extend(track.lanes.iter().filter(|l| l.param).map(|l| l.name.clone()));
                    let items = choices.iter().map(|c| crate::menu::Item::new(c.clone()).checked(c == &name)).collect();
                    self.open_local_menu(&format!("lane:{}", track.id), items, response.interact_pointer_pos().unwrap_or(pick.left_bottom()));
                }
            }
        }
        // Its meters, left and right, with the clip light on top.
        let well = Rect::from_min_size(pos2(rect.right() - 24.0, rect.top() + 4.0), vec2(20.0, rect.height() - 8.0));
        p.rect_filled(well, CornerRadius::same(2), t.well);
        let level = |side: usize| self.s.levels.get(index * 2 + side).copied().unwrap_or(0.0);
        let peak = self.peaks.get(&track.id).copied().unwrap_or_default();
        if widgets::clip_light(ui, Rect::from_min_size(well.min + vec2(3.0, 2.0), vec2(14.0, 4.0)), Id::unique(("clip-light", track.id)), peak.clipped) {
            self.peaks.insert(track.id, model::PeakHold::default());
        }
        let meter_h = (well.height() - 10.0).max(0.0);
        widgets::meter(ui, Rect::from_min_size(well.min + vec2(3.0, 8.0), vec2(6.0, meter_h)), level(0), peak.level[0], true);
        widgets::meter(ui, Rect::from_min_size(well.min + vec2(11.0, 8.0), vec2(6.0, meter_h)), level(1), peak.level[1], true);
        // The bottom edge: drag to make the track taller or shorter, double
        // click for the height of the others.
        let edge = Rect::from_min_size(pos2(rect.left(), rect.bottom() - 4.0), vec2(rect.width(), 5.0));
        let response = ui.interact(edge, Id::unique(("edge", track.id)), Sense::click_and_drag());
        if response.hovered() || response.dragged() {
            ui.ctx().set_cursor_icon(egui::CursorIcon::ResizeVertical);
            widgets::hint("track height: drag the bottom edge · double click for the others' height · Ctrl and the wheel over the headers for all");
        }
        if response.double_clicked() {
            self.pass("set_track_height", json!([track.id, 1]));
        } else if response.drag_started()
            && let Some(p) = response.interact_pointer_pos()
        {
            self.arrange.gesture = Some(Gesture::Size { id: track.id, from: p.y, clip_size: track.clip_size });
        }
    }

    /// Presses on a header's body: click selects, a drag up or down moves
    /// the track, double click renames, the right button's menu.
    fn header_body(&mut self, ui: &Ui, index: usize, track: &Track, body: &egui::Response, rect: Rect) {
        if body.double_clicked() {
            self.arrange.gesture = None;
            self.arrange.renaming = Some((track.id, track.name.clone()));
            return;
        }
        if self.arrange.gesture.is_none()
            && body.is_pointer_button_down_on()
            && ui.input(|i| i.pointer.primary_pressed())
            && let Some(p) = ui.input(|i| i.pointer.interact_pos())
        {
            self.arrange.gesture = Some(Gesture::Header { row: index, from: p.y });
        }
        // The menu opens when the button is let go, where it was pressed.
        if body.secondary_clicked()
            && let Some(p) = body.interact_pointer_pos()
        {
            self.open_menu("track", json!([track.id]), p);
        }
        let _ = rect;
    }

    /// The name of a track being typed over, in its header.
    fn rename_box(&mut self, ui: &mut Ui, rect: Rect) {
        let Some((id, mut name)) = self.arrange.renaming.take() else { return };
        let edit_id = Id::unique(("rename", id));
        self.text_box(edit_id);
        let response = ui.put(rect, egui::TextEdit::singleline(&mut name).id(edit_id).font(sans(T_BASE)).margin(vec2(2.0, 2.0)));
        if !response.has_focus() && !response.lost_focus() {
            response.request_focus();
            if let Some(mut state) = egui::TextEdit::load_state(ui.ctx(), edit_id) {
                state.cursor.set_char_range(Some(egui::text::CCursorRange::two(egui::text::CCursor::new(0), egui::text::CCursor::new(name.chars().count()))));
                state.store(ui.ctx(), edit_id);
            }
        }
        let (enter, escape) = ui.input(|i| (i.key_pressed(egui::Key::Enter), i.key_pressed(egui::Key::Escape)));
        if escape {
            return;
        }
        if response.lost_focus() {
            if enter {
                self.pass("rename_track", json!([id, name]));
            }
            return;
        }
        self.arrange.renaming = Some((id, name));
    }

    /// The input, monitor, M, S, R and automation switches of a header.
    fn switches(&mut self, ui: &mut Ui, index: usize, track: &Track, at: Pos2) {
        let t = th();
        let cell = |i: usize| Rect::from_min_size(pos2(at.x + i as f32 * 22.0, at.y), vec2(20.0, 18.0));
        // The input: what the track takes in, chosen from a menu, with the
        // level arriving there along its foot.
        let input = cell(0);
        let response = ui.interact(input, Id::unique(("input", track.id)), Sense::click());
        let has_input = !track.input.is_empty();
        let face = if has_input && (track.monitor || track.armed) {
            alpha(t.select, 0.25)
        } else if response.hovered() {
            t.control_hover
        } else {
            t.control
        };
        let p = ui.painter();
        p.rect_filled(input, CornerRadius::same(3), face);
        widgets::icon(ui, Rect::from_min_size(input.min + vec2(3.0, 2.0), vec2(14.0, 14.0)), icons::MICROPHONE, if has_input { t.select } else if response.hovered() { t.text } else { t.text_3 });
        if has_input {
            let level = self.s.inputs.get(index).copied().unwrap_or(0.0);
            let bar = Rect::from_min_size(pos2(input.left(), input.bottom() - 2.0), vec2(20.0 * level.min(1.0), 2.0));
            ui.painter().rect_filled(bar, CornerRadius::ZERO, if level > 0.89 { t.meter_clip } else { t.meter_low });
        }
        widgets::hint_on(&response, "input: click to choose what the track records, audio or MIDI · the bar along its foot is the level arriving");
        if response.clicked() {
            self.open_menu("input", json!([track.id]), input.left_bottom());
        }
        // Monitoring: a loudspeaker, lit while the input is heard.
        let monitor = cell(1);
        let response = ui.interact(monitor, Id::unique(("monitor", track.id)), Sense::click());
        let face = if track.monitor { t.select } else if response.hovered() { t.control_hover } else { t.control };
        ui.painter().rect_filled(monitor, CornerRadius::same(3), face);
        let ink = if track.monitor { t.on_hue } else if response.hovered() { t.text } else { t.text_3 };
        widgets::icon(ui, Rect::from_min_size(monitor.min + vec2(3.0, 2.0), vec2(14.0, 14.0)), icons::SPEAKER_HIGH, ink);
        widgets::hint_on(&response, "monitor: hear the input through the track's devices without arming it");
        if response.clicked() {
            self.pass("toggle", json!([track.id, "monitor"]));
        }
        // M, S and R: a press swept across the others sets them all as the
        // first was set.
        for (i, (label, name, on, lit)) in [("M", "mute", track.mute, t.mute), ("S", "solo", track.solo, t.solo), ("R", "armed", track.armed, t.rec)].into_iter().enumerate() {
            let rect = cell(2 + i);
            let response = widgets::flag(ui, rect, Id::unique((name, track.id)), label, on, lit);
            if name == "armed" {
                widgets::hint_on(&response, "arm: this track records when the record button is pressed");
            }
            if self.arrange.gesture.is_none() && response.is_pointer_button_down_on() && ui.input(|i| i.pointer.primary_pressed()) {
                self.arrange.gesture = Some(Gesture::Sweep { row: index, flag: name, on: !on, last: index, moved: false });
            }
        }
        // The automation mode: A while the lanes only play, lit with its
        // letter while moves are written.
        let letter = match track.automation.as_str() {
            "touch" => "T",
            "latch" => "L",
            "write" => "W",
            "off" => "–",
            _ => "A",
        };
        let lit = if track.automation == "off" { t.text_3 } else { t.rec };
        let response = widgets::flag(ui, cell(5), Id::unique(("automation", track.id)), letter, track.automation != "read", lit);
        widgets::hint_on(&response, format!("automation: {} · click for the next mode (read, touch, latch, write, off) · the track's menu has them all", track.automation));
        if response.clicked() {
            self.pass("track_command", json!([track.id, "automation"]));
        }
    }

    /// The gestures that began on a header, as the pointer moves and is let go.
    pub fn header_moves(&mut self, ui: &Ui, geo: &Geo, pos: Pos2, _m: egui::Modifiers) {
        let Some(gesture) = self.arrange.gesture.clone() else { return };
        let released = ui.input(|i| i.pointer.primary_released());
        match gesture {
            Gesture::Header { row, from } => {
                if !released {
                    return;
                }
                self.arrange.gesture = None;
                let Some(track) = self.s.tracks.get(row) else { return };
                let dy = if (pos.y - from).abs() > 6.0 { pos.y - from } else { 0.0 };
                let middle = geo.row_top(row) + track.size * geo.rh / 2.0 + dy;
                let to = geo.row_at(middle);
                if to != row && !track.master {
                    self.pass("move_track", json!([track.id, to + 1]));
                } else {
                    self.pass("select", json!([track.id, self.s.cursor]));
                }
            }
            Gesture::Size { id, from, clip_size } => {
                if released {
                    self.arrange.gesture = None;
                    let dy = pos.y - from;
                    if dy.abs() > 2.0 {
                        self.pass("set_track_height", json!([id, (clip_size * geo.rh + dy).max(18.0) / geo.rh]));
                    }
                }
            }
            Gesture::Sweep { row, flag, on, last, moved } => {
                // The master's row takes no flags.
                let now = geo.row_at(pos.y).min(self.s.tracks.len().saturating_sub(2));
                let was = moved;
                let moved = moved || now != row;
                if moved && (!was || now != last) {
                    self.pass("sweep_flag", json!([row + 1, now + 1, flag, on]));
                }
                if released {
                    self.arrange.gesture = None;
                    if !moved
                        && let Some(track) = self.s.tracks.get(row)
                    {
                        self.pass("toggle", json!([track.id, flag]));
                    }
                } else {
                    self.arrange.gesture = Some(Gesture::Sweep { row, flag, on, last: now, moved });
                }
            }
            _ => {}
        }
    }
}
