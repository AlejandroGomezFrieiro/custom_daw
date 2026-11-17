//! The session view: a column of slots under each track and a scene for each
//! row, for launching clips while the song plays. A clip can be dragged from
//! the timeline into a slot.
//!
//! What the mouse does:
//!   the play mark of a slot   pressed launches the clip (or stops the track,
//!                             on an empty slot); let go stops a gate clip
//!   the rest of a slot        click chooses it, double click opens its notes
//!                             (an empty one gets a new MIDI clip first), drag
//!                             moves the clip to another slot (Ctrl copies)
//!   a scene                   launches its row
//!   under a column            the square stops the track, the arrow sends it
//!                             back to its timeline

use egui::{Align2, CornerRadius, Id, Pos2, Rect, Sense, Stroke, StrokeKind, Ui, Vec2, pos2, vec2};
use serde_json::{Value, json};

use crate::app::View;
use crate::icons;
use crate::model::{flag, int, number, rows, text};
use crate::theme::{T_BASE, T_SMALL, alpha, mix, sans, semi, th};
use crate::widgets::{self, Look};

const CELL_W: f32 = 118.0;
const CELL_H: f32 = 26.0;
const TOP_H: f32 = 30.0;
const HEAD_H: f32 = 24.0;
const GUTTER: f32 = 30.0;
const SCENES_W: f32 = 150.0;
/// Where the slots begin: under the names and the line saying what plays.
const SLOTS_TOP: f32 = HEAD_H + CELL_H;

#[derive(Default)]
pub struct Session {
    /// What each track plays from its slots, by column.
    launch: Vec<Value>,
    scroll: Vec2,
    /// The grid as last drawn, and the columns' track ids: for a clip
    /// dragged from the timeline onto a slot.
    grid: Option<Rect>,
    ids: Vec<i64>,
    rows: usize,
    /// A slot's clip being dragged: its id, its place, where the press was.
    drag: Option<(i64, (usize, i64), Pos2)>,
    /// The play mark held down, for a gate clip let go.
    pad: Option<(i64, i64)>,
}

impl Session {
    /// What moves with the song.
    pub fn tick(&mut self, state: &Value) {
        self.launch = rows(&state["launch"]).to_vec();
    }

    /// The column (its track's id) and row of a slot at a point of the
    /// window, while the session view shows.
    pub fn slot_at(&self, pos: Pos2) -> Option<(i64, i64)> {
        let grid = self.grid?;
        if !grid.contains(pos) {
            return None;
        }
        let c = ((pos.x - grid.left() - GUTTER + self.scroll.x) / CELL_W).floor();
        let r = ((pos.y - grid.top() - SLOTS_TOP + self.scroll.y) / CELL_H).floor();
        if c < 0.0 || r < 0.0 || r as usize >= self.rows {
            return None;
        }
        Some((*self.ids.get(c as usize)?, r as i64))
    }
}

impl View {
    pub fn draw_session(&mut self, ui: &mut Ui, rect: Rect) {
        let t = th();
        let p = ui.painter().with_clip_rect(rect);
        p.rect_filled(rect, CornerRadius::ZERO, t.surface);
        p.hline(rect.x_range(), rect.top() + 0.5, Stroke::new(1.0, t.divider));
        if !flag(&self.s.modal["session"]) {
            self.session.grid = None;
            return;
        }
        // The bar along the top: where launches land, stop all, back, capture.
        let bar = Rect::from_min_size(rect.min + vec2(0.0, 1.0), vec2(rect.width(), TOP_H - 1.0));
        let y = bar.center().y;
        let mut x = bar.left() + 10.0;
        p.text(pos2(x, y), Align2::LEFT_CENTER, "Session", semi(T_BASE), t.text);
        x += widgets::text_width(ui, "Session", semi(T_BASE)) + 6.0;
        p.text(pos2(x, y), Align2::LEFT_CENTER, "launches land on", sans(T_SMALL), t.text_3);
        x += widgets::text_width(ui, "launches land on", sans(T_SMALL)) + 6.0;
        let quantize = text(&self.s.project["launch_quantize"]);
        for q in ["off", "1/16", "1/8", "1/4", "beat", "bar", "2bars", "4bars"] {
            let w = widgets::button_width(ui, q, false, 22.0);
            if widgets::button(ui, Rect::from_min_size(pos2(x, y - 11.0), vec2(w, 22.0)), Id::unique(("quantize", q)), None, q, Look::quiet().on(quantize == q)).clicked() {
                self.command(&format!("launch.quantize {q}"));
            }
            x += w + 6.0;
        }
        let mut right = bar.right() - 8.0;
        let capturing = flag(&self.s.modal["capturing"]);
        let buttons: [(&str, icons::Icon, Look, &str); 3] = [
            ("Stop all", icons::STOP_FILL, Look::quiet(), ""),
            ("Back to timeline", icons::ARROW_COUNTER_CLOCKWISE, Look::quiet(), ""),
            ("Capture", icons::RECORD_FILL, Look::quiet().on(capturing).lit(t.rec), "capture: what is launched is written into the timeline when the song stops"),
        ];
        for (label, shape, look, tip) in buttons {
            let w = widgets::button_width(ui, label, true, 22.0);
            let r = Rect::from_min_size(pos2(right - w, y - 11.0), vec2(w, 22.0));
            right -= w + 6.0;
            let response = widgets::button(ui, r, Id::unique(("session", label)), Some(shape), label, look);
            if !tip.is_empty() {
                widgets::hint_on(&response, tip);
            }
            if response.clicked() {
                match label {
                    "Stop all" => self.pass("stop_slots", json!([Value::Null])),
                    "Back to timeline" => self.pass("back_to_timeline", json!([Value::Null])),
                    _ => self.command("launch.capture"),
                }
            }
        }
        let grid = Rect::from_min_max(pos2(rect.left(), rect.top() + TOP_H), pos2(rect.right() - SCENES_W, rect.bottom()));
        let scenes_rect = Rect::from_min_max(pos2(grid.right(), grid.top()), rect.max);
        let columns: Vec<(i64, String, egui::Color32)> = self.s.tracks.iter().filter(|t| !t.master).map(|t| (t.id, t.name.clone(), t.color)).collect();
        let scenes: Vec<String> = rows(&self.s.project["scenes"]).iter().map(text).collect();
        self.session.ids = columns.iter().map(|c| c.0).collect();
        self.session.rows = scenes.len();
        self.session.grid = Some(grid);
        let content = vec2((GUTTER + columns.len() as f32 * CELL_W).max(grid.width()), (SLOTS_TOP + scenes.len() as f32 * CELL_H + 8.0).max(grid.height()));
        if View::pointer_in(ui, rect).is_some() {
            let wheel = widgets::wheel_y(ui) * 40.0;
            if ui.input(|i| i.modifiers.shift) {
                self.session.scroll.x -= wheel;
            } else {
                self.session.scroll.y -= wheel;
            }
        }
        self.session.scroll = self.session.scroll.clamp(Vec2::ZERO, (content - grid.size()).max(Vec2::ZERO));
        let origin = grid.min - self.session.scroll;
        let chosen_track = self.s.selected;
        let chosen_row = self.s.modal["slot_row"].as_i64().unwrap_or(-1);
        let p = ui.painter().with_clip_rect(grid);
        let state = |c: usize| self.session.launch.get(c).cloned().unwrap_or(Value::Null);
        let launch_of = |s: &Value, key: &str| s[key].as_i64().unwrap_or(-1);
        // The rows' numbers.
        for (row, _) in scenes.iter().enumerate() {
            let r = Rect::from_min_size(pos2(origin.x, origin.y + SLOTS_TOP + row as f32 * CELL_H), vec2(GUTTER - 6.0, CELL_H));
            p.text(pos2(r.right(), r.center().y), Align2::RIGHT_CENTER, (row + 1).to_string(), sans(T_SMALL), if row as i64 == chosen_row { t.text } else { t.text_3 });
        }
        let pointer = ui.input(|i| i.pointer.latest_pos());
        let drop = if self.arrange.gesture.as_ref().is_some_and(|g| matches!(g, crate::arrange::Gesture::Clip { .. })) {
            pointer.and_then(|p| self.session.slot_at(p))
        } else {
            None
        };
        let mut act: Option<(&str, Value)> = None;
        for (c, (id, name, colour)) in columns.iter().enumerate() {
            let s = state(c);
            let x = origin.x + GUTTER + c as f32 * CELL_W;
            let w = CELL_W - 2.0;
            // The name, in the track's colour.
            let head = Rect::from_min_size(pos2(x, origin.y), vec2(w, HEAD_H - 2.0));
            let on = *id == chosen_track;
            p.rect_filled(head, CornerRadius::same(3), if on { *colour } else { mix(*colour, t.surface, 0.45) });
            widgets::text_in(ui, pos2(head.left() + 6.0, head.center().y), name, semi(T_SMALL), if on { t.on_hue } else { t.bright }, w - 12.0);
            // What plays, and how to stop it or send it back.
            let line_y = origin.y + HEAD_H;
            let stop = Rect::from_min_size(pos2(x, line_y), vec2(22.0, 22.0));
            let stopped = flag(&s["stopped"]) || flag(&s["stopping"]);
            if widgets::button(ui, stop, Id::unique(("slot-stop", *id)), Some(icons::STOP_FILL), "", Look::quiet().on(stopped).lit(if flag(&s["stopping"]) { t.play } else { t.text_2 })).clicked() {
                act = Some(("stop_slots", json!([id])));
            }
            let back = stop.translate(vec2(24.0, 0.0));
            let can_back = launch_of(&s, "slot") >= 0 || flag(&s["stopped"]) || launch_of(&s, "queued") >= 0;
            let response = widgets::button(ui, back, Id::unique(("slot-back", *id)), Some(icons::ARROW_COUNTER_CLOCKWISE), "", Look::quiet().on(flag(&s["back"])).lit(t.play).enabled(can_back));
            widgets::hint_on(&response, "back to the track's timeline");
            if response.clicked() {
                act = Some(("back_to_timeline", json!([id])));
            }
            let plays = launch_of(&s, "slot");
            let said = if plays >= 0 { format!("plays {}", plays + 1) } else if flag(&s["stopped"]) { "stopped".into() } else { "timeline".into() };
            widgets::text_in(ui, pos2(back.right() + 2.0, back.center().y), &said, sans(T_SMALL), if plays >= 0 { t.play_on } else { t.text_3 }, w - 50.0);
            // The empty slots.
            for row in 0..scenes.len() as i64 {
                let r = Rect::from_min_size(pos2(x, origin.y + SLOTS_TOP + row as f32 * CELL_H), vec2(w, CELL_H - 2.0));
                let recording = launch_of(&s, "recording") == row;
                let face = if recording { alpha(t.rec, 0.3) } else if drop == Some((*id, row)) { alpha(t.select, 0.15) } else { t.lane };
                let chosen = on && row == chosen_row;
                p.rect(r, CornerRadius::same(3), face, Stroke::new(if chosen { 1.0 } else { 0.0 }, t.select), StrokeKind::Inside);
                // The empty slot's mark: launching it stops the track.
                let mark = Rect::from_min_size(pos2(r.left() + 7.0, r.center().y - 4.0), vec2(8.0, 8.0));
                p.rect_stroke(mark, CornerRadius::same(1), Stroke::new(1.0, if launch_of(&s, "queued") == row { t.play } else { t.text_off }), StrokeKind::Inside);
                let dot = Rect::from_center_size(pos2(r.right() - 13.0, r.center().y), vec2(18.0, 18.0));
                let rec = ui.interact(dot, Id::unique(("slot-rec", *id, row)), Sense::click());
                p.circle_filled(dot.center(), 5.0, if recording { t.rec } else if rec.hovered() { alpha(t.rec, 0.6) } else { alpha(t.text_off, 0.5) });
                if rec.clicked() {
                    act = Some(("record_slot", json!([id, row])));
                }
                let body = ui.interact(Rect::from_min_max(r.min, pos2(dot.left(), r.bottom())), Id::unique(("slot-empty", *id, row)), Sense::click());
                widgets::hint_on(&body, "empty slot: double click makes a MIDI clip · drop a clip from the timeline here · its square stops the track, its dot records a bar into it");
                if body.is_pointer_button_down_on() && ui.input(|i| i.pointer.primary_pressed()) && body.interact_pointer_pos().is_some_and(|p| p.x < r.left() + 24.0) {
                    act = Some(("press_slot", json!([id, row, true])));
                }
                if body.double_clicked() {
                    act = Some(("open_slot", json!([id, row])));
                } else if body.clicked() {
                    act = Some(("choose_slot", json!([id, row])));
                }
            }
        }
        // The clips, over the empty slots.
        let slots = rows(&self.s.slots).to_vec();
        for slot in &slots {
            let column = int(&slot["track"]) as usize;
            let Some((id, _, colour)) = columns.get(column).cloned() else { continue };
            let row = int(&slot["row"]);
            let clip = int(&slot["id"]);
            let s = state(column);
            let playing = launch_of(&s, "slot") == row;
            let queued = launch_of(&s, "queued") == row;
            let dragged = match (&self.session.drag, pointer) {
                (Some((d, _, from)), Some(now)) if *d == clip && (now - *from).length() > 4.0 => now - *from,
                _ => Vec2::ZERO,
            };
            let r = Rect::from_min_size(pos2(origin.x + GUTTER + column as f32 * CELL_W, origin.y + SLOTS_TOP + row as f32 * CELL_H), vec2(CELL_W - 2.0, CELL_H - 2.0)).translate(dragged);
            let muted = flag(&slot["muted"]);
            let face = if muted { mix(colour, t.surface, 0.15) } else if playing { mix(colour, t.surface, 0.55) } else { mix(colour, t.surface, 0.3) };
            let chosen = id == chosen_track && row == chosen_row;
            let fade = if dragged != Vec2::ZERO { 0.7 } else { 1.0 };
            p.rect(r, CornerRadius::same(3), alpha(face, fade), Stroke::new(if chosen { 1.0 } else { 0.0 }, t.select), StrokeKind::Inside);
            // How far round its loop it is.
            if playing {
                let progress = number(&s["progress"]).clamp(0.0, 1.0);
                p.rect_filled(Rect::from_min_size(r.min, vec2(r.width() * progress, r.height())), CornerRadius::same(3), colour);
            }
            let ink = if playing { t.on_hue } else if queued { t.play } else { alpha(t.bright, 0.75) };
            widgets::icon(ui, Rect::from_min_size(pos2(r.left() + 5.0, r.center().y - 6.0), vec2(12.0, 12.0)), if queued { icons::CARET_RIGHT } else { icons::PLAY_FILL }, ink);
            let mode = text(&slot["mode"]);
            let name = format!("{}{}", text(&slot["name"]), if mode == "trigger" || mode.is_empty() { String::new() } else { format!(" · {mode}") });
            widgets::text_in(ui, pos2(r.left() + 22.0, r.center().y), &name, if playing { semi(T_SMALL) } else { sans(T_SMALL) }, if playing { t.on_hue } else { t.bright }, r.width() - 26.0);
            let base = r.translate(-dragged);
            let response = ui.interact(base, Id::unique(("slot", clip)), Sense::click_and_drag());
            widgets::hint_on(&response, "clip: its play mark launches it · click chooses · double click opens its notes · drag moves it, Ctrl copies");
            // The play mark is a pad: pressed launches, let go stops a gate clip.
            if response.is_pointer_button_down_on()
                && ui.input(|i| i.pointer.primary_pressed())
                && let Some(at) = response.interact_pointer_pos()
            {
                if at.x < base.left() + 22.0 {
                    self.session.pad = Some((id, row));
                    act = Some(("press_slot", json!([id, row, true])));
                } else {
                    self.session.drag = Some((clip, (column, row), at));
                }
            }
            if response.double_clicked() {
                act = Some(("open_slot", json!([id, row])));
            }
        }
        // A pad let go, or a slot's clip dropped.
        if ui.input(|i| i.pointer.primary_released()) {
            if let Some((id, row)) = self.session.pad.take() {
                act = Some(("press_slot", json!([id, row, false])));
            }
            if let (Some((clip, (column, row), from)), Some(now)) = (self.session.drag.take(), pointer) {
                if (now - from).length() > 4.0 {
                    if let Some((track, to)) = self.session.slot_at(now)
                        && (Some(&track) != self.session.ids.get(column) || to != row)
                    {
                        let copy = ui.input(|i| i.modifiers.ctrl);
                        act = Some(("move_slot", json!([clip, track, to, copy])));
                    }
                } else if act.is_none() {
                    act = Some(("choose_slot", json!([self.session.ids.get(column), row])));
                }
            }
        }
        // The scenes, down the right, scrolled with the slots.
        let p = ui.painter().with_clip_rect(scenes_rect);
        p.vline(scenes_rect.left() + 0.5, scenes_rect.y_range(), Stroke::new(1.0, t.divider));
        let top = scenes_rect.top() - self.session.scroll.y;
        p.text(pos2(scenes_rect.left() + 10.0, top + (HEAD_H - 2.0) / 2.0), Align2::LEFT_CENTER, "Scenes", semi(T_SMALL), t.text_2);
        for (row, name) in scenes.iter().enumerate() {
            let r = Rect::from_min_size(pos2(scenes_rect.left() + 6.0, top + SLOTS_TOP + row as f32 * CELL_H), vec2(SCENES_W - 12.0, CELL_H - 2.0));
            let response = ui.interact(r.intersect(scenes_rect), Id::unique(("scene", row)), Sense::click());
            let face = if response.is_pointer_button_down_on() { t.control_press } else if response.hovered() { t.control_hover } else { t.control };
            p.rect_filled(r, CornerRadius::same(3), face);
            widgets::icon(ui, Rect::from_min_size(pos2(r.left() + 6.0, r.center().y - 6.0), vec2(12.0, 12.0)), icons::PLAY_FILL, t.text_2);
            widgets::text_in(ui, pos2(r.left() + 24.0, r.center().y), name, sans(T_SMALL), if row as i64 == chosen_row { t.bright } else { t.text_2 }, r.width() - 28.0);
            widgets::hint_on(&response, "scene: launches every clip in its row together");
            if response.clicked() {
                act = Some(("scene", json!([row])));
            }
        }
        if let Some((name, args)) = act {
            self.pass(name, args);
        }
    }
}
