//! The ruler over the timeline: the loop and the punch range, bars and
//! beats from the tempo map, the tempo and signature flags; under it the
//! markers, the extensions' bands and the tempo lane.

use egui::{Align2, Color32, CornerRadius, Id, Pos2, Rect, Sense, Shape, Stroke, Ui, pos2, vec2};
use serde_json::json;

use crate::app::View;
use crate::arrange::{BAND_H, Geo, Gesture, HEADER_W, RULER_MAIN, TEMPO_LANE, tempo_y};
use crate::model::{self, flag, number, rows, text};
use crate::theme::{T_MICRO, T_SMALL, alpha, mono, paint_colour, semi, th};
use crate::widgets;

impl View {
    pub fn ruler(&mut self, ui: &mut Ui, pane: Rect, geo: &Geo) {
        let t = th();
        let left = pane.left() + HEADER_W;
        let main = Rect::from_min_max(pos2(left, pane.top()), pos2(pane.right(), pane.top() + RULER_MAIN));
        let painter = ui.painter().with_clip_rect(main);
        painter.rect_filled(main, CornerRadius::ZERO, t.panel);
        let p = self.s.project.clone();
        let (from, to) = geo.seen();
        let looping = flag(&p["loop_enabled"]);
        let (loop_start, loop_end) = (number(&p["loop_start"]), number(&p["loop_end"]));
        let (punch_start, punch_end) = (number(&p["punch_start"]), number(&p["punch_end"]));
        let span = |a: f32, b: f32, y0: f32, y1: f32| Rect::from_x_y_ranges(geo.x(a).max(left - 1.0)..=geo.x(b).min(main.right() + 1.0), (main.top() + y0)..=(main.top() + y1));
        // The loop: a band along the top, amber while it is on.
        if loop_end > loop_start {
            if looping {
                painter.rect_filled(span(loop_start, loop_end, 0.0, RULER_MAIN), CornerRadius::ZERO, alpha(t.play, 0.2));
            }
            painter.rect_filled(span(loop_start, loop_end, 0.0, 8.0), CornerRadius::ZERO, if looping { alpha(t.play, 0.8) } else { alpha(t.text_3, 0.45) });
        }
        // The punch range: a red line under the loop's band.
        if punch_end > punch_start {
            let on = flag(&p["punch_enabled"]);
            painter.rect_filled(span(punch_start, punch_end, 8.0, 12.0), CornerRadius::ZERO, if on { alpha(t.rec, 0.9) } else { alpha(t.text_3, 0.35) });
        }
        // From the tempo map: half beats and beats as ticks from the foot,
        // bars as lines with their numbers.
        let bar_px = self.s.bar() * geo.zoom;
        for line in model::lines_in_view(&self.s.lines, from - 1.0, to + 1.0, geo.zoom) {
            let x = geo.x(line.beat).round() + 0.5;
            if geo.zoom >= 20.0 {
                painter.vline(geo.x((line.beat + line.next) / 2.0).round() + 0.5, (main.bottom() - 3.0)..=main.bottom(), Stroke::new(1.0, t.line_bar));
            }
            if line.label.is_empty() {
                if geo.zoom >= 6.0 {
                    painter.vline(x, (main.bottom() - 6.0)..=main.bottom(), Stroke::new(1.0, t.text_3));
                }
                if geo.zoom > 48.0 {
                    painter.text(pos2(x + 4.0, main.top() + 9.0), Align2::LEFT_TOP, &line.place, crate::theme::sans(T_SMALL), t.text_3);
                }
            } else {
                painter.vline(x, (main.top() + 8.0)..=main.bottom(), Stroke::new(1.0, t.line_bar));
                // Fewer numbers when bars are narrow.
                if bar_px >= 26.0 || (line.bar - 1) % 4 == 0 {
                    painter.text(pos2(x + 4.0, main.top() + 9.0), Align2::LEFT_TOP, &line.label, semi(T_SMALL), t.text_2);
                }
            }
        }
        // A loop being drawn in the top band, or an edge of it dragged.
        let pointer = ui.input(|i| i.pointer.latest_pos());
        if let (Some(Gesture::Ruler { grab, top, from }), Some(at)) = (&self.arrange.gesture, pointer)
            && (at.x - from).abs() > 4.0
        {
            let anchor = match grab {
                1 => Some(geo.x(loop_end)),
                2 => Some(geo.x(loop_start)),
                0 if *top => Some(*from),
                _ => None,
            };
            if let Some(a) = anchor {
                painter.rect_filled(Rect::from_x_y_ranges(a.min(at.x)..=a.max(at.x), main.y_range()), CornerRadius::ZERO, alpha(t.play, 0.3));
            }
            if *grab >= 3 {
                let a = geo.x(if *grab == 3 { punch_end } else { punch_start });
                painter.rect_filled(Rect::from_x_y_ranges(a.min(at.x)..=a.max(at.x), (main.top() + 8.0)..=(main.top() + 12.0)), CornerRadius::ZERO, t.rec);
            }
        }
        // The edit cursor, and the playhead's cap.
        painter.vline(geo.x(self.s.cursor).round() + 0.5, (main.top() + 8.0)..=main.bottom(), Stroke::new(1.0, t.select));
        let ph = geo.x(self.s.position);
        painter.add(Shape::convex_polygon(vec![pos2(ph - 4.5, main.bottom() - 6.0), pos2(ph + 4.5, main.bottom() - 6.0), pos2(ph, main.bottom())], t.play, Stroke::NONE));
        // The ruler's pointer: a click puts the edit cursor and the
        // playhead, a drag in the top half loops the stretch dragged over.
        let response = ui.interact(main, Id::unique("ruler"), Sense::click_and_drag());
        let near = |pos: Pos2, beat: f32| (pos.x - geo.x(beat)).abs() <= 5.0;
        let near_punch = |pos: Pos2, beat: f32| punch_end > punch_start && pos.y - main.top() >= 5.0 && pos.y - main.top() <= 16.0 && near(pos, beat);
        let marks = rows(&p["marks"]).to_vec();
        let flag_at = |pos: Pos2| -> Option<(f32, bool)> {
            marks.iter().rev().find_map(|m| {
                let beat = number(&m["beat"]);
                let x = geo.x(beat);
                let w = widgets::text_width(ui, &text(&m["text"]), mono(T_SMALL)) + 24.0;
                (pos.x >= x && pos.x <= x + w).then_some((beat, m["kind"] == "tempo"))
            })
        };
        if let Some(pos) = response.hover_pos() {
            if flag_at(pos).is_some() {
                widgets::hint("tempo flag: drag to move · double click to type a value · right click to remove");
            } else {
                widgets::hint("ruler: click puts the edit cursor and the playhead · drag in the top half loops a stretch · drag the loop's edges, or the red punch line's · double click turns the loop on or off");
            }
            let edge = (looping && (near(pos, loop_start) || near(pos, loop_end))) || near_punch(pos, punch_start) || near_punch(pos, punch_end);
            if edge {
                ui.ctx().set_cursor_icon(egui::CursorIcon::ResizeHorizontal);
            }
            let pressed = |b| ui.input(|i| i.pointer.button_pressed(b));
            if self.arrange.gesture.is_none() && pressed(egui::PointerButton::Primary) {
                self.arrange.gesture = Some(match flag_at(pos) {
                    Some((beat, tempo)) => Gesture::TempoMark { beat, tempo, from: pos.x },
                    None => {
                        let grab = if near_punch(pos, punch_start) {
                            3
                        } else if near_punch(pos, punch_end) {
                            4
                        } else if looping && near(pos, loop_start) {
                            1
                        } else if looping && near(pos, loop_end) {
                            2
                        } else {
                            0
                        };
                        Gesture::Ruler { grab, top: pos.y - main.top() < main.height() / 2.0, from: pos.x }
                    }
                });
            }
            if pressed(egui::PointerButton::Secondary)
                && let Some((beat, tempo)) = flag_at(pos)
            {
                let kind = if tempo { "tempo" } else { "signature" };
                self.open_menu("tempo_mark", json!([kind, beat]), pos);
            }
            if response.double_clicked() {
                self.arrange.gesture = None;
                match flag_at(pos) {
                    Some((beat, tempo)) => self.pass("tempo_mark", json!(["edit", if tempo { "tempo" } else { "signature" }, beat, 0])),
                    None => self.command("transport.loop"),
                }
            }
        }
        // Tempo and signature changes: a stem at the change's beat with a
        // small head, and the value beside the bar number.
        for m in &marks {
            let beat = number(&m["beat"]);
            let tempo = m["kind"] == "tempo";
            let mut x = geo.x(beat);
            if let (Some(Gesture::TempoMark { beat: b, from, .. }), Some(at)) = (&self.arrange.gesture, pointer)
                && *b == beat
            {
                x += at.x - from;
            }
            let colour = if tempo { t.accent } else { t.text_2 };
            painter.vline(x.round() + 0.5, (main.top() + 8.0)..=main.bottom(), Stroke::new(1.0, colour));
            painter.rect_filled(Rect::from_min_size(pos2(x.round(), main.top() + 8.0), vec2(5.0, 5.0)), CornerRadius::ZERO, colour);
            painter.text(pos2(x + 20.0, main.top() + 9.0), Align2::LEFT_TOP, text(&m["text"]), mono(T_SMALL), colour);
        }
        // The corner over the headers.
        let corner = Rect::from_min_size(pane.min, vec2(HEADER_W, self.ruler_height()));
        ui.painter().rect_filled(corner, CornerRadius::ZERO, t.panel);
        let n = self.s.tracks.len().saturating_sub(1);
        let said = if n == 1 { "1 TRACK".to_string() } else { format!("{n} TRACKS") };
        ui.painter().text(pos2(pane.left() + 12.0, pane.top() + RULER_MAIN / 2.0), Align2::LEFT_CENTER, said, semi(T_MICRO), t.text_3);
        self.markers(ui, pane, geo);
        self.bands(ui, pane, geo);
        self.tempo_lane(ui, pane, geo);
    }

    /// Markers and regions, in a band of their own under the ruler: a region
    /// is a bar over its stretch, a marker a flag. A click goes there; a
    /// drag moves one; the menu renames, removes, and loops a region.
    fn markers(&mut self, ui: &mut Ui, pane: Rect, geo: &Geo) {
        let t = th();
        let markers = rows(&self.s.project["markers"]).to_vec();
        if markers.is_empty() {
            return;
        }
        let band = Rect::from_min_max(pos2(pane.left() + HEADER_W, pane.top() + RULER_MAIN), pos2(pane.right(), pane.top() + RULER_MAIN + BAND_H));
        let painter = ui.painter().with_clip_rect(band);
        painter.rect_filled(band, CornerRadius::ZERO, t.panel);
        painter.hline(band.x_range(), band.top() + 0.5, Stroke::new(1.0, t.divider));
        let pointer = ui.input(|i| i.pointer.latest_pos());
        let hover = ui.input(|i| i.pointer.hover_pos()).filter(|p| band.contains(*p));
        let mut boxes = Vec::new();
        for m in &markers {
            let (id, beat, length, name) = (m["id"].as_i64().unwrap_or(0), number(&m["beat"]), number(&m["length"]), text(&m["name"]));
            let region = length > 0.0;
            let mut x = geo.x(beat);
            if let (Some(Gesture::Marker { id: held, from, .. }), Some(at)) = (&self.arrange.gesture, pointer)
                && *held == id
            {
                x += at.x - from;
            }
            let name_w = widgets::text_width(ui, &name, semi(T_SMALL));
            let shown_x = if region { x.max(band.left() - 2.0) } else { x };
            let w = if region { (name_w + 12.0).max(geo.x(beat + length).min(band.right()) - shown_x) } else { name_w + 14.0 };
            let rect = Rect::from_min_size(pos2(shown_x, band.top() + 1.0), vec2(w, BAND_H - 2.0));
            let lit = hover.is_some_and(|p| rect.contains(p));
            if region {
                let fill = Rect::from_min_max(rect.min, pos2(geo.x(beat + length).min(band.right()).max(rect.left()), rect.bottom()));
                painter.rect_filled(fill, CornerRadius::same(2), alpha(t.select, if lit { 0.38 } else { 0.24 }));
            }
            painter.rect_filled(Rect::from_min_size(rect.min, vec2(if region { 2.0 } else { 1.0 }, rect.height())), CornerRadius::ZERO, if region { t.select } else { t.accent });
            painter.text(pos2(rect.left() + 6.0, rect.center().y), Align2::LEFT_CENTER, &name, semi(T_SMALL), if region { t.text } else { t.accent });
            boxes.push((rect, id, beat, length));
        }
        let response = ui.interact(band, Id::unique("markers"), Sense::click_and_drag());
        let Some(pos) = response.hover_pos().or(pointer.filter(|_| matches!(self.arrange.gesture, Some(Gesture::Marker { .. })))) else { return };
        let under = boxes.iter().rev().find(|b| b.0.contains(pos)).copied();
        if let Some((_, id, beat, length)) = under {
            widgets::hint("marker: click goes there · drag to move · double click renames · right click for more");
            if self.arrange.gesture.is_none() && ui.input(|i| i.pointer.primary_pressed()) {
                self.arrange.gesture = Some(Gesture::Marker { id, beat, from: pos.x });
            }
            if ui.input(|i| i.pointer.secondary_released()) {
                let m = json!({ "id": id, "length": if length > 0.0 { json!(length) } else { serde_json::Value::Null } });
                self.open_menu("marker", json!([m]), pos);
            }
            if response.double_clicked() {
                self.arrange.gesture = None;
                self.command(&format!("marker.rename id={id}"));
            }
        }
    }

    /// Extensions' bands (`daw.frontend.bands`), a row each under the
    /// markers: an entry over its stretch, or a flag where it is, in its
    /// colour; a click runs what it stands for.
    fn bands(&mut self, ui: &mut Ui, pane: Rect, geo: &Geo) {
        let t = th();
        let rows_n = self.band_rows();
        if rows_n <= 0 {
            return;
        }
        let top = pane.top() + RULER_MAIN + self.marker_band();
        let area = Rect::from_min_max(pos2(pane.left() + HEADER_W, top), pos2(pane.right(), top + rows_n as f32 * BAND_H));
        let painter = ui.painter().with_clip_rect(area);
        painter.rect_filled(area, CornerRadius::ZERO, t.panel);
        painter.hline(area.x_range(), area.top() + 0.5, Stroke::new(1.0, t.divider));
        let hover = ui.input(|i| i.pointer.hover_pos()).filter(|p| area.contains(*p));
        let entries = rows(&self.s.project["bands"]["entries"]).to_vec();
        let mut clicked = None;
        let response = ui.interact(area, Id::unique("bands"), Sense::click());
        for e in &entries {
            let (beat, length) = (number(&e["beat"]), number(&e["length"]));
            let span = length > 0.0;
            let hue = paint_colour(&e["color"]);
            let colour = hue.unwrap_or(t.text_2);
            let name = text(&e["name"]);
            let y = area.top() + number(&e["row"]) * BAND_H + 1.0;
            let x = geo.x(beat).max(area.left() - 2.0);
            let w = if span { (geo.x(beat + length).min(area.right()) - x - 1.0).max(2.0) } else { widgets::text_width(ui, &name, semi(T_SMALL)) + 14.0 };
            let rect = Rect::from_min_size(pos2(x, y), vec2(w, BAND_H - 2.0));
            let active = flag(&e["active"]);
            let lit = hover.is_some_and(|p| rect.contains(p));
            let clip = painter.with_clip_rect(rect.intersect(area));
            if span {
                clip.rect_filled(rect, CornerRadius::same(2), alpha(colour, if lit && active { 0.34 } else { 0.2 }));
            } else {
                // A flag covers those before it, so that names do not run together.
                clip.rect_filled(rect, CornerRadius::ZERO, t.panel);
            }
            clip.rect_filled(Rect::from_min_size(rect.min, vec2(2.0, rect.height())), CornerRadius::ZERO, colour);
            // The name stays in sight while its stretch is.
            let tx = (rect.left() + 6.0).max(area.left() + 6.0);
            clip.text(pos2(tx, rect.center().y), Align2::LEFT_CENTER, &name, semi(T_SMALL), if hue.is_some() { t.text } else { t.text_2 });
            if lit {
                widgets::hint(text(&e["hint"]));
                if active {
                    ui.ctx().set_cursor_icon(egui::CursorIcon::PointingHand);
                    if response.clicked() {
                        clicked = Some((e["band"].clone(), e["index"].clone()));
                    }
                }
            }
        }
        if let Some((band, index)) = clicked {
            self.pass("band", json!([band, index]));
        }
    }

    /// The tempo lane: the tempo map as a curve, a step where a change holds
    /// and a slope where it ramps.
    fn tempo_lane(&mut self, ui: &mut Ui, pane: Rect, geo: &Geo) {
        let t = th();
        let lane = self.s.project["tempo_lane"].clone();
        if !lane.is_object() {
            return;
        }
        let top = pane.top() + RULER_MAIN + self.marker_band() + self.band_rows() as f32 * BAND_H;
        let area = Rect::from_min_max(pos2(pane.left() + HEADER_W, top), pos2(pane.right(), top + TEMPO_LANE));
        let painter = ui.painter().with_clip_rect(area);
        painter.rect_filled(area, CornerRadius::ZERO, t.panel);
        painter.hline(area.x_range(), area.top() + 0.5, Stroke::new(1.0, t.divider));
        let (lo, hi) = (number(&lane["lo"]), number(&lane["hi"]));
        let height = |bpm: f32| ((bpm - lo) / (hi - lo).max(1.0)).clamp(0.0, 1.0);
        let points: Vec<(f32, f32, bool, f32)> = rows(&lane["points"])
            .iter()
            .map(|p| (number(&p["beat"]), height(number(&p["bpm"])), flag(&p["ramp"]), number(&p["bpm"])))
            .collect();
        let shaped: Vec<(f32, f32, bool)> = points.iter().map(|p| (p.0, p.1, p.2)).collect();
        let (from, to) = geo.seen();
        let curve: Vec<Pos2> = model::tempo_corners(&shaped, (from - 1.0).max(0.0), to + 1.0).iter().map(|(b, v)| pos2(geo.x(*b), area.top() + tempo_y(*v))).collect();
        painter.add(Shape::line(curve, Stroke::new(1.5, t.accent)));
        let pointer = ui.input(|i| i.pointer.latest_pos());
        if let Some(Gesture::TempoPencil { points }) = &self.arrange.gesture {
            let line: Vec<Pos2> = points.iter().map(|(b, v)| pos2(geo.x(*b), area.top() + tempo_y(*v))).collect();
            painter.add(Shape::line(line, Stroke::new(2.0, t.text)));
        }
        let hover = ui.input(|i| i.pointer.hover_pos()).filter(|p| area.contains(*p));
        let mut handle = None;
        for (beat, value, ramp, bpm) in &points {
            if *beat < from - 1.0 || *beat > to + 1.0 {
                continue;
            }
            let mut at = pos2(geo.x(*beat), area.top() + tempo_y(*value));
            let held = matches!(&self.arrange.gesture, Some(Gesture::TempoPoint { beat: b, .. }) if b == beat);
            if let (true, Some(Gesture::TempoPoint { from, .. }), Some(p)) = (held, &self.arrange.gesture, pointer) {
                at += p - *from;
            }
            let lit = hover.is_some_and(|p| (p - at).length() <= 5.0);
            if lit {
                handle = Some((*beat, *value));
            }
            let side = if lit || held { 8.0 } else { 6.0 };
            let r = Rect::from_center_size(at, vec2(side, side));
            let colour = if held { t.select } else if lit { Color32::WHITE } else { t.text };
            painter.rect_filled(r, CornerRadius::same(if *ramp { (side / 2.0) as u8 } else { 1 }), colour);
            if lit || held {
                painter.text(at + vec2(7.0, -7.0), Align2::LEFT_TOP, format!("{}", (bpm * 100.0).round() / 100.0), mono(T_SMALL), t.text);
            }
        }
        let response = ui.interact(area, Id::unique("tempo-lane"), Sense::click_and_drag());
        if let Some(pos) = response.hover_pos() {
            widgets::hint("tempo lane: click adds a change · hold and draw a curve · drag a change to move it · double click makes it ramp or hold · right click one removes it");
            let height_at = |y: f32| (((1.0 - (y - area.top()) / TEMPO_LANE) - 0.12) / 0.76).clamp(0.0, 1.0);
            if self.arrange.gesture.is_none() && ui.input(|i| i.pointer.primary_pressed()) {
                self.arrange.gesture = Some(match handle {
                    Some((beat, value)) => Gesture::TempoPoint { beat, value, from: pos },
                    None => Gesture::TempoPencil { points: vec![(geo.beat(pos.x).max(0.0), height_at(pos.y))] },
                });
            }
            if ui.input(|i| i.pointer.secondary_pressed())
                && let Some((beat, _)) = handle
            {
                self.pass("tempo_point_remove", json!([beat]));
            } else if ui.input(|i| i.pointer.secondary_released()) && handle.is_none() {
                self.open_menu("tempo_lane", json!([]), pos);
            }
            if response.double_clicked()
                && let Some((beat, _)) = handle
            {
                self.arrange.gesture = None;
                self.pass("tempo_point_ramp", json!([beat]));
            }
        }
        // What the lane's top and bottom are, in the corner.
        let corner = Rect::from_min_size(pos2(pane.left(), top), vec2(HEADER_W, TEMPO_LANE));
        let p = ui.painter();
        p.rect_filled(corner, CornerRadius::ZERO, t.panel);
        p.text(corner.min + vec2(12.0, 6.0), Align2::LEFT_TOP, "TEMPO", semi(T_MICRO), t.text_3);
        let bpm = self.s.tick["tempo"].as_f64().unwrap_or(120.0);
        p.text(corner.min + vec2(12.0, 22.0), Align2::LEFT_TOP, format!("{bpm} bpm"), mono(T_SMALL), t.text_2);
        p.text(pos2(corner.right() - 8.0, corner.top() + 6.0), Align2::RIGHT_TOP, format!("{hi:.0}"), mono(T_MICRO), t.text_3);
        p.text(pos2(corner.right() - 8.0, corner.bottom() - 6.0), Align2::RIGHT_BOTTOM, format!("{lo:.0}"), mono(T_MICRO), t.text_3);
    }

    /// The gestures of the ruler and the bands under it, as the pointer
    /// moves and is let go.
    pub fn ruler_moves(&mut self, ui: &Ui, geo: &Geo, pos: Pos2, m: egui::Modifiers) {
        let Some(gesture) = self.arrange.gesture.clone() else { return };
        let released = ui.input(|i| i.pointer.primary_released());
        let beat = |x: f32| geo.beat(x).max(0.0);
        match gesture {
            Gesture::Ruler { grab, top, from } => {
                if !released {
                    return;
                }
                self.arrange.gesture = None;
                let moved = (pos.x - from).abs();
                if grab >= 3 && moved > 2.0 {
                    self.pass("set_punch_edge", json!([if grab == 3 { "start" } else { "end" }, beat(pos.x), m.shift]));
                } else if moved <= 4.0 {
                    self.pass("ruler_click", json!([beat(pos.x)]));
                } else if grab == 1 || grab == 2 {
                    self.pass("set_loop_edge", json!([if grab == 1 { "start" } else { "end" }, beat(pos.x)]));
                } else if top {
                    self.pass("set_loop", json!([beat(from), beat(pos.x)]));
                } else {
                    self.pass("ruler_click", json!([beat(pos.x)]));
                }
            }
            Gesture::TempoMark { beat: at, tempo, from } => {
                if released {
                    self.arrange.gesture = None;
                    if (pos.x - from).abs() > 3.0 {
                        let to = (at + (pos.x - from) / geo.zoom).max(0.0);
                        self.pass("tempo_mark", json!(["move", if tempo { "tempo" } else { "signature" }, at, to]));
                    }
                }
            }
            Gesture::Marker { id, beat: at, from } => {
                if released {
                    self.arrange.gesture = None;
                    if (pos.x - from).abs() > 3.0 {
                        self.command(&format!("marker.set id={id} beat={}", (at + (pos.x - from) / geo.zoom).max(0.0)));
                    } else {
                        self.command(&format!("marker.goto id={id}"));
                    }
                }
            }
            Gesture::TempoPencil { mut points } => {
                let top = geo.lanes.top() - TEMPO_LANE;
                let height = (((1.0 - (pos.y - top) / TEMPO_LANE) - 0.12) / 0.76).clamp(0.0, 1.0);
                points.push((beat(pos.x), height));
                if released {
                    self.arrange.gesture = None;
                    // How far the pointer went, in pixels: a click hardly moves.
                    let reach = points
                        .iter()
                        .map(|p| ((p.0 - points[0].0) * geo.zoom).abs() + ((p.1 - points[0].1) * TEMPO_LANE).abs())
                        .fold(0.0, f32::max);
                    if reach < 5.0 {
                        self.pass("tempo_point_add", json!([points[0].0, points[0].1]));
                    } else {
                        let list: Vec<_> = points.iter().map(|(b, h)| json!([b, h])).collect();
                        self.pass("tempo_draw", json!([list]));
                    }
                } else {
                    self.arrange.gesture = Some(Gesture::TempoPencil { points });
                }
            }
            Gesture::TempoPoint { beat: at, value, from } => {
                if released {
                    self.arrange.gesture = None;
                    let d = pos - from;
                    if d.x.abs() > 2.0 || d.y.abs() > 2.0 {
                        let height = (0.88 - (1.0 - value) * 0.76 - d.y / TEMPO_LANE).clamp(0.0, 1.0);
                        let height = ((height - 0.12) / 0.76).clamp(0.0, 1.0);
                        self.pass("tempo_point_move", json!([at, (at + d.x / geo.zoom).max(0.0), height]));
                    }
                }
            }
            _ => self.header_moves(ui, geo, pos, m),
        }
    }
}
