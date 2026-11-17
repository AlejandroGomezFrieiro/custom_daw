//! The mixer: a strip per track from its left edge, the master pinned at
//! the right. Each strip has where it plays into, its devices, its sends,
//! pan, a fader with a scale beside its meters, the level and the peak held,
//! M S R and its name on its colour.

use egui::{Align2, CornerRadius, Id, Rect, Sense, Stroke, StrokeKind, Ui, pos2, vec2};
use serde_json::json;

use crate::app::View;
use crate::model::{PeakHold, Track, decibels, pan_text};
use crate::theme::{T_MICRO, T_SMALL, alpha, mono_medium, semi, sans, th};
use crate::widgets::{self, Moved, taper};

#[derive(Default)]
pub struct Mixer {
    /// How far the strips are scrolled sideways.
    pub scroll: f32,
}

impl View {
    pub fn draw_mixer(&mut self, ui: &mut Ui, rect: Rect) {
        let t = th();
        ui.painter().rect_filled(rect, CornerRadius::ZERO, t.surface);
        ui.painter().hline(rect.x_range(), rect.top() + 0.5, Stroke::new(1.0, t.divider));
        let tracks = self.s.tracks.clone();
        let Some(master) = tracks.last().cloned() else { return };
        let others = tracks.len() - 1;
        // Strips share the width the master leaves, as wide as a name needs
        // and no wider than a fader looks right, from the left edge as a
        // console's are; the master stays at the right.
        let strip_w = ((rect.width() - 92.0) / others.max(1) as f32 - 1.0).clamp(72.0, 112.0);
        let area = Rect::from_min_max(pos2(rect.left(), rect.top() + 1.0), pos2(rect.right() - 89.0, rect.bottom()));
        let content = others as f32 * (strip_w + 1.0);
        self.mixer.scroll = self.mixer.scroll.clamp(0.0, (content - area.width()).max(0.0));
        // Every strip keeps rows for as many sends as the track with most
        // has, so that their faders share a baseline.
        let send_rows = tracks.iter().map(|t| t.sends.len().min(3)).max().unwrap_or(0);
        let mut child = ui.new_child(egui::UiBuilder::new().max_rect(area).id_salt("mixer-strips"));
        child.set_clip_rect(area.intersect(ui.clip_rect()));
        for (index, track) in tracks.iter().enumerate().take(others) {
            let x = area.left() + index as f32 * (strip_w + 1.0) - self.mixer.scroll;
            if x > area.right() || x + strip_w < area.left() {
                continue;
            }
            let strip = Rect::from_min_size(pos2(x, area.top()), vec2(strip_w, area.height()));
            self.strip(&mut child, strip, index, track, send_rows);
        }
        let strip = Rect::from_min_max(pos2(rect.right() - 88.0, rect.top() + 1.0), rect.max);
        self.strip(ui, strip, tracks.len() - 1, &master, send_rows);
        // The wheel, either way, moves the strips sideways, unless a control
        // under the pointer took it.
        if View::pointer_in(ui, area).is_some() && !widgets::wheel_taken() {
            self.mixer.scroll = (self.mixer.scroll - widgets::wheel_y(ui) * 40.0).clamp(0.0, (content - area.width()).max(0.0));
        }
    }

    fn strip(&mut self, ui: &mut Ui, rect: Rect, index: usize, track: &Track, send_rows: usize) {
        let t = th();
        let chosen = track.id == self.s.selected;
        let id = track.id;
        let p = ui.painter().clone();
        p.rect_filled(rect, CornerRadius::ZERO, if chosen { t.panel_sel } else { t.panel });
        p.vline(rect.right() + 0.5, rect.y_range(), Stroke::new(1.0, t.divider));
        // A click anywhere on it chooses its track.
        let body = ui.interact(rect, Id::unique(("strip", id)), Sense::click());
        if body.clicked() {
            self.pass("select", json!([id, self.s.cursor]));
        }
        // The row of the strip the keyboard is on, when the mixer has it.
        let row = self.s.modal["mixer_row"].clone();
        let here = self.s.focused() == "mixer" && row["track"].as_i64() == Some(id);
        let kind = if here { row["kind"].as_str().unwrap_or("").to_string() } else { String::new() };
        let kind = kind.as_str();
        let (row_index, field) = (row["index"].as_i64().unwrap_or(0), row["field"].as_str().unwrap_or("").to_string());
        let ring = |on: bool| Stroke::new(if on { 1.0 } else { 0.0 }, t.select);
        let short = rect.height() < 300.0;
        let inner = rect.shrink2(vec2(4.0, 0.0));
        let mut y = rect.top() + 4.0;
        // Where it plays into.
        let to = Rect::from_min_size(pos2(inner.left(), y), vec2(inner.width(), 20.0));
        p.rect_filled(to, CornerRadius::same(3), t.well);
        let said = if track.master {
            "→ Output".to_string()
        } else if track.vca {
            format!("VCA: {}", if track.vcas.is_empty() { "no tracks" } else { &track.vcas })
        } else {
            format!("→ {}{}", track.output, if track.vcas.is_empty() { String::new() } else { format!(" · VCA {}", track.vcas) })
        };
        let shown = widgets::elide(ui, &said, sans(T_SMALL), to.width() - 10.0);
        p.text(to.center(), Align2::CENTER_CENTER, shown, sans(T_SMALL), t.text_2);
        y = to.bottom() + 4.0;
        // Its devices, four at most (one when the strip is short); a click
        // picks one in the device panel. A VCA has none, but keeps their
        // rows so that its fader lines up.
        let slots = if short { 1 } else { 4 };
        for slot in 0..slots {
            let r = Rect::from_min_size(pos2(inner.left(), y), vec2(inner.width(), 18.0));
            let used = !track.vca && slot < track.inserts.len();
            let response = ui.interact(r, Id::unique(("strip-slot", id, slot)), if used { Sense::click() } else { Sense::hover() });
            let face = if track.vca {
                egui::Color32::TRANSPARENT
            } else if used {
                if response.hovered() { t.control_hover } else { t.control }
            } else {
                t.control_press
            };
            p.rect(r, CornerRadius::same(2), face, ring(kind == "insert" && row_index == slot as i64 + 1), StrokeKind::Inside);
            if used {
                let n = track.inserts.len();
                let name = if short && n > 1 {
                    format!("{} +{}", track.inserts[0], n - 1)
                } else if slot == 3 && n > 4 {
                    format!("+{} more", n - 3)
                } else {
                    track.inserts[slot].clone()
                };
                widgets::text_in(ui, pos2(r.left() + 5.0, r.center().y), &name, sans(T_SMALL), t.text, r.width() - 10.0);
            }
            if response.clicked() {
                self.pass("pick_device", json!([id, slot + 1]));
            }
            y += 22.0;
        }
        // Its sends, as many as the strip has room for, in as many rows as
        // the strip with most sends uses.
        let send_slots = send_rows.min(if short { 1 } else { 3 });
        for at in 0..send_slots {
            let r = Rect::from_min_size(pos2(inner.left(), y), vec2(inner.width(), 16.0));
            let used = !track.vca && at < track.sends.len();
            if used {
                let n = track.sends.len();
                let (name, level) = &track.sends[at];
                let said = if short && n > 1 { format!("+{n} sends") } else { format!("⇢ {name}  {}", decibels(*level)) };
                p.rect_stroke(r, CornerRadius::same(2), ring(kind == "send" && (row_index == at as i64 + 1 || short)), StrokeKind::Inside);
                widgets::text_in(ui, pos2(r.left() + 5.0, r.center().y), &said, sans(T_MICRO), t.text_2, r.width() - 10.0);
            }
            y += 20.0;
        }
        // The pan, or the room for it on a VCA.
        if !track.vca {
            let knob = Rect::from_center_size(pos2(rect.center().x, y + 13.0), vec2(24.0, 24.0));
            let (response, moved) = widgets::knob(ui, knob, Id::unique(("strip-pan", id)), (track.pan + 1.0) / 2.0);
            widgets::name(&response, &format!("pan of {}", track.name));
            if kind == "pan" {
                p.circle_stroke(knob.center(), 12.0, Stroke::new(1.0, t.select));
            }
            widgets::hint_on(&response, format!("pan {}: drag up and down · wheel to nudge · double click for the centre", pan_text(track.pan)));
            for m in moved {
                match m {
                    Moved::To(v) => self.pass("set_pan", json!([id, v * 2.0 - 1.0])),
                    Moved::Reset => self.pass("set_pan", json!([id, 0.0])),
                    Moved::Held(on) => self.pass("hold", json!([id, "pan", 0, "", on])),
                }
            }
        }
        y += 30.0;
        // From the foot: the name, M S R, the level and the peak held.
        let mut bottom = rect.bottom();
        let plate = Rect::from_min_max(pos2(rect.left(), bottom - 22.0), pos2(rect.right(), bottom));
        bottom = plate.top() - 4.0;
        p.rect_filled(plate, CornerRadius::ZERO, if track.master { t.control } else { track.color });
        let mut nx = plate.left() + 4.0;
        if !track.master {
            let n = track.number.to_string();
            p.text(pos2(nx, plate.center().y), Align2::LEFT_CENTER, &n, crate::theme::mono(T_SMALL), alpha(t.on_hue, 0.6));
            nx += widgets::text_width(ui, &n, crate::theme::mono(T_SMALL)) + 4.0;
        }
        let name = widgets::elide(ui, &track.name, semi(T_SMALL), plate.right() - 4.0 - nx);
        p.text(pos2((nx + plate.right() - 4.0) / 2.0, plate.center().y), Align2::CENTER_CENTER, name, semi(T_SMALL), if track.master { t.text } else { t.on_hue });
        if chosen {
            p.rect_stroke(plate, CornerRadius::ZERO, Stroke::new(1.0, egui::Color32::WHITE), StrokeKind::Inside);
        }
        let plate_response = ui.interact(plate, Id::unique(("strip-plate", id)), Sense::click());
        widgets::name(&plate_response, &format!("strip of {}", track.name));
        if plate_response.clicked() {
            self.pass("select", json!([id, self.s.cursor]));
        }
        if plate_response.secondary_clicked() && !track.master {
            self.open_menu("track", json!([id]), plate_response.interact_pointer_pos().unwrap_or(plate.left_top()));
        }
        // Mute, solo, arm.
        let flags = Rect::from_min_max(pos2(rect.left(), bottom - 20.0), pos2(rect.right(), bottom));
        bottom = flags.top() - 4.0;
        if !track.master {
            let start = flags.center().x - (3.0 * 20.0 + 2.0 * 2.0) / 2.0;
            for (i, (label, name, on, lit)) in [("M", "mute", track.mute, t.mute), ("S", "solo", track.solo, t.solo), ("R", "armed", track.armed, t.rec)].into_iter().enumerate() {
                let r = Rect::from_min_size(pos2(start + i as f32 * 22.0, flags.top() + 1.0), vec2(20.0, 18.0));
                let response = widgets::flag(ui, r, Id::unique(("strip-flag", id, name)), label, on, lit);
                widgets::name(&response, &format!("{name} of {}", track.name));
                if response.clicked() {
                    self.pass("toggle", json!([id, name]));
                }
                if kind == "toggle" && field == name {
                    ui.painter().rect_stroke(r, CornerRadius::same(3), Stroke::new(1.0, t.select), StrokeKind::Inside);
                }
            }
        }
        // The fader's level, and the loudest peak of late.
        let readouts = Rect::from_min_max(pos2(inner.left(), bottom - 18.0), pos2(inner.right(), bottom));
        bottom = readouts.top() - 4.0;
        let half = (readouts.width() - 2.0) / 2.0;
        let level = Rect::from_min_size(readouts.min, vec2(half, 18.0));
        p.rect(level, CornerRadius::same(2), t.well, ring(kind == "volume"), StrokeKind::Inside);
        p.text(level.center(), Align2::CENTER_CENTER, decibels(track.volume), mono_medium(T_SMALL), t.text);
        let peak_rect = Rect::from_min_size(pos2(level.right() + 2.0, level.top()), vec2(half, 18.0));
        let peak = self.peaks.get(&id).copied().unwrap_or_default();
        p.rect_filled(peak_rect, CornerRadius::same(2), if peak.clipped { alpha(t.meter_clip, 0.25) } else { t.well });
        p.text(peak_rect.center(), Align2::CENTER_CENTER, peak.text(), mono_medium(T_SMALL), if peak.clipped { t.meter_clip } else { t.text_2 });
        let mut clear = ui.interact(peak_rect, Id::unique(("strip-peak", id)), Sense::click()).clicked();
        // The fader with its scale, and the meters with the clip light.
        let body = Rect::from_min_max(pos2(inner.left(), y), pos2(inner.right(), bottom.max(y + 80.0)));
        let travel = body.height() - 36.0;
        for mark in [6.0f32, 0.0, -6.0, -12.0, -24.0, -48.0] {
            let said = if mark > 0.0 { format!("+{mark}") } else if mark < 0.0 { format!("−{}", -mark) } else { "0".into() };
            let my = body.top() + 18.0 + travel * (1.0 - taper(mark));
            p.text(pos2(body.left() + 18.0, my), Align2::RIGHT_CENTER, said, semi(T_MICRO), t.text_3);
        }
        let fader = Rect::from_min_size(pos2(body.left() + 20.0, body.top()), vec2(24.0, body.height()));
        let (response, moved) = widgets::fader(ui, fader, Id::unique(("strip-fader", id)), track.volume);
        widgets::name(&response, &format!("fader of {}", track.name));
        for m in moved {
            match m {
                Moved::To(db) => self.pass("set_volume", json!([id, db])),
                Moved::Reset => self.pass("set_volume", json!([id, 0.0])),
                Moved::Held(on) => self.pass("hold", json!([id, "volume", 0, "", on])),
            }
        }
        let well = Rect::from_min_max(pos2(body.right() - 18.0, body.top()), body.max);
        p.rect_filled(well, CornerRadius::same(2), t.well);
        clear |= widgets::clip_light(ui, Rect::from_min_size(well.min + vec2(2.0, 2.0), vec2(14.0, 4.0)), Id::unique(("strip-light", id)), peak.clipped);
        let lvl = |side: usize| self.s.levels.get(index * 2 + side).copied().unwrap_or(0.0);
        let mh = (well.height() - 10.0).max(0.0);
        widgets::meter(ui, Rect::from_min_size(well.min + vec2(2.0, 8.0), vec2(6.0, mh)), lvl(0), peak.level[0], true);
        widgets::meter(ui, Rect::from_min_size(well.min + vec2(10.0, 8.0), vec2(6.0, mh)), lvl(1), peak.level[1], true);
        if clear {
            self.peaks.insert(id, PeakHold::default());
        }
    }
}
