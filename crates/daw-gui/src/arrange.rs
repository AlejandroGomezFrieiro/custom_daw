//! The arrange view: the ruler along the top, the tracks' headers down the
//! left, and the timeline with the clips beside them. What is drawn is only
//! what shows; what a gesture means is the kernel's (`daw.frontend.act`).

use std::collections::HashMap;

use egui::{Align2, Color32, CornerRadius, Id, Pos2, Rect, Sense, Shape, Stroke, StrokeKind, Ui, Vec2, pos2, vec2};
use serde_json::json;

use crate::app::View;
use crate::icons;
use crate::model::{self, Clip, LANE_ROW, TAKE_ROW, flag, int, number, rows};
use crate::pictures::{self, notched};
use crate::theme::{T_MICRO, T_SMALL, alpha, mix, mode_colour, sans, semi, th};
use crate::widgets::{self, Look};

/// The track headers' width: the timeline starts there.
pub const HEADER_W: f32 = 240.0;
/// The ruler's own row, and the bands under it.
pub const RULER_MAIN: f32 = 28.0;
pub const BAND_H: f32 = 18.0;
/// The tempo lane's height, and where in it a tempo at the bottom or the
/// top of its range is drawn.
pub const TEMPO_LANE: f32 = 56.0;
pub fn tempo_y(value: f32) -> f32 {
    (0.12 + (1.0 - value) * 0.76) * TEMPO_LANE
}

/// What a press over the arrange view took hold of, kept until it is let go.
#[derive(Clone, Debug)]
pub enum Gesture {
    /// The left button on empty lanes: a click puts the cursor, a drag
    /// selects a stretch of time.
    Lane { at: Pos2 },
    /// The right button: a box that chooses clips, or a click for a menu
    /// (on a clip, or on the timeline).
    Marquee { from: Pos2, clip: Option<i64> },
    /// The middle button pans.
    Pan { from: Pos2, scroll: Vec2 },
    /// A clip, and the chosen ones with it: moved by whole rows and beats.
    Clip { id: i64, group: bool, row: usize, from: Pos2, content_y: f32 },
    /// An edge of a clip and the same edge of the chosen ones.
    Trim { id: i64, start: bool, group: bool, at: f32, from: f32 },
    Fade { id: i64, out: bool, from: f32 },
    Gain { id: i64, from: f32, start: f32 },
    Warp { id: i64, index: usize, from: f32 },
    /// The pencil over a track's lane, or over a lane shown as a row.
    Pencil { row: usize, lane: Option<i64>, top: f32, span: f32, points: Vec<(f32, f32)> },
    /// A point of a lane dragged.
    Point { lane: i64, index: usize, beat: f32, value: f32, span: f32, from: Pos2 },
    /// A drag across a take lane.
    Take { track: i64, take: i64, from: f32 },
    /// The ruler: 1 the loop's start, 2 its end, 3 the punch in, 4 the
    /// punch out, 0 none; and whether it began in the top band.
    Ruler { grab: u8, top: bool, from: f32 },
    TempoMark { beat: f32, tempo: bool, from: f32 },
    Marker { id: i64, beat: f32, from: f32 },
    TempoPencil { points: Vec<(f32, f32)> },
    TempoPoint { beat: f32, value: f32, from: Pos2 },
    /// A header dragged up or down to move its track.
    Header { row: usize, from: f32 },
    /// A header's bottom edge dragged, to make the track taller or shorter.
    Size { id: i64, from: f32, clip_size: f32 },
    /// M, S or R pressed and swept across the others.
    Sweep { row: usize, flag: &'static str, on: bool, last: usize, moved: bool },
}

pub struct Arrange {
    /// Pixels to a beat, and the height of a track's row.
    pub zoom: f32,
    pub row_height: f32,
    /// How far the timeline is scrolled, in pixels.
    pub scroll: Vec2,
    /// The timeline's size as last drawn.
    pub size: Vec2,
    pub gesture: Option<Gesture>,
    /// The track whose name is being typed over.
    pub renaming: Option<(i64, String)>,
    /// The lane each track shows over its clips, when one was chosen.
    pub shown: HashMap<i64, i64>,
    /// Where the headers were drawn, and the timeline's measures then: for
    /// a device dropped on a header.
    pub last: Option<(Rect, Geo)>,
}

impl Default for Arrange {
    fn default() -> Self {
        Arrange { zoom: 28.0, row_height: 66.0, scroll: Vec2::ZERO, size: vec2(800.0, 400.0), gesture: None, renaming: None, shown: HashMap::new(), last: None }
    }
}

impl Arrange {
    /// Taller or shorter tracks. The header shows less as there is less room.
    pub fn zoom_rows(&mut self, taller: bool) {
        let h = self.row_height;
        self.row_height = if taller {
            if h < 44.0 { 44.0 } else if h < 66.0 { 66.0 } else if h < 96.0 { 96.0 } else { 140.0 }
        } else if h > 96.0 {
            96.0
        } else if h > 66.0 {
            66.0
        } else if h > 44.0 {
            44.0
        } else {
            28.0
        };
    }

    pub fn zoom_step(&mut self, closer: bool) {
        self.zoom = if closer { (self.zoom * 1.4).min(320.0) } else { (self.zoom / 1.4).max(3.0) };
    }

    /// The whole song across the timeline.
    pub fn zoom_fit(&mut self, length: f32, bar: f32) {
        self.zoom = ((self.size.x - 24.0) / bar.max(length + bar)).clamp(3.0, 320.0);
        self.scroll.x = 0.0;
    }

    /// The row of the header at a point of the window, if one is there.
    pub fn header_at(&self, pos: Pos2) -> Option<usize> {
        let (headers, geo) = self.last.as_ref()?;
        headers.contains(pos).then(|| geo.row_at(pos.y))
    }

    /// Zoom by a wheel step, keeping the beat under the pointer (at `x` in
    /// the timeline's content) where it is.
    pub fn zoom_at(&mut self, closer: bool, x: f32) {
        if (closer && self.zoom < 320.0) || (!closer && self.zoom > 3.0) {
            let factor = if closer { 1.2 } else { 1.0 / 1.2 };
            let new = (self.zoom * factor).clamp(3.0, 320.0);
            self.scroll.x = (self.scroll.x + x * (new / self.zoom - 1.0)).max(0.0);
            self.zoom = new;
        }
    }
}

/// Where things are, for one frame.
#[derive(Clone)]
pub struct Geo {
    pub lanes: Rect,
    pub zoom: f32,
    pub rh: f32,
    pub scroll: Vec2,
    /// Where each row starts, in rows of the zoom's height, and after the
    /// last where they all end.
    pub tops: Vec<f32>,
}

impl Geo {
    pub fn x(&self, beat: f32) -> f32 {
        self.lanes.left() + beat * self.zoom - self.scroll.x
    }
    pub fn beat(&self, x: f32) -> f32 {
        (x - self.lanes.left() + self.scroll.x) / self.zoom
    }
    pub fn row_top(&self, row: usize) -> f32 {
        self.lanes.top() - self.scroll.y + self.tops.get(row).copied().unwrap_or(*self.tops.last().unwrap_or(&0.0)) * self.rh
    }
    /// The row at a height on the screen, from 0.
    pub fn row_at(&self, y: f32) -> usize {
        let at = (y - self.lanes.top() + self.scroll.y) / self.rh;
        let n = self.tops.len().saturating_sub(1);
        self.tops.iter().take(n).rposition(|top| *top <= at).unwrap_or(0)
    }
    /// The first beat and the last that show.
    pub fn seen(&self) -> (f32, f32) {
        (self.scroll.x / self.zoom, (self.scroll.x + self.lanes.width()) / self.zoom)
    }
}

/// What Shift and Ctrl held with a click or a box mean.
fn mode(m: egui::Modifiers) -> &'static str {
    if m.ctrl {
        "toggle"
    } else if m.shift {
        "add"
    } else {
        "only"
    }
}

/// A curve as a line through points on the screen.
fn polyline(points: Vec<Pos2>, colour: Color32, width: f32) -> Shape {
    Shape::line(points, Stroke::new(width, colour))
}

impl View {
    pub fn arrange_geo(&self, rect: Rect) -> Geo {
        let mut tops: Vec<f32> = self.s.tracks.iter().map(|t| t.top).collect();
        tops.push(self.s.tracks.last().map_or(0.0, |t| t.top + t.size));
        Geo { lanes: Rect::from_min_max(pos2(rect.left() + HEADER_W, rect.top() + self.ruler_height()), rect.max), zoom: self.arrange.zoom, rh: self.arrange.row_height, scroll: self.arrange.scroll, tops }
    }

    /// The ruler's own row, a band for markers when there are any, a row for
    /// each extension's band, and the tempo lane when it shows.
    pub fn ruler_height(&self) -> f32 {
        RULER_MAIN + self.marker_band() + self.band_rows() as f32 * BAND_H + if self.s.project["tempo_lane"].is_object() { TEMPO_LANE } else { 0.0 }
    }

    pub fn marker_band(&self) -> f32 {
        if rows(&self.s.project["markers"]).is_empty() { 0.0 } else { BAND_H }
    }

    pub fn band_rows(&self) -> i64 {
        int(&self.s.project["bands"]["rows"])
    }

    /// The arrange view in its pane.
    pub fn draw_arrange(&mut self, ui: &mut Ui, rect: Rect) {
        let t = th();
        // What the content is: as wide as the song and some bars more.
        let bar = self.s.bar();
        let length = number(&self.s.project["length"]);
        let bars = ((length + 8.0 * bar) / bar).ceil();
        let geo0 = self.arrange_geo(rect);
        let content = vec2(bars * bar * self.arrange.zoom, geo0.tops.last().copied().unwrap_or(0.0) * self.arrange.row_height + 40.0);
        let lanes = geo0.lanes;
        self.arrange.size = lanes.size();
        let max = (content - lanes.size()).max(Vec2::ZERO);
        self.arrange.scroll = self.arrange.scroll.clamp(Vec2::ZERO, max);
        let geo = self.arrange_geo(rect);
        let headers = Rect::from_min_max(pos2(rect.left(), geo.lanes.top()), pos2(rect.left() + HEADER_W, rect.bottom()));
        self.arrange.last = Some((headers, geo.clone()));
        self.timeline(ui, &geo);
        self.ruler(ui, rect, &geo);
        self.headers(ui, rect, &geo);
        self.zoom_box(ui, rect);
        self.arrange_gestures(ui, &geo);
        // The wheel, unless a control under the pointer (a fader) took it.
        if !widgets::wheel_taken() {
            self.wheel_over_arrange(ui, rect, &geo0);
        }
        if self.s.tracks.len() <= 1 {
            let at = pos2(rect.left() + HEADER_W + 60.0, geo.lanes.top() + 110.0);
            let p = ui.painter();
            p.text(at, Align2::LEFT_TOP, "A new project", semi(18.0), t.text);
            let said = "Press “New track”, put an instrument on it from the panel on the right, then double click in its lane to make a clip and again on the clip to write notes.";
            let galley = p.layout(said.into(), sans(12.0), t.text_2, 420.0);
            let h = galley.size().y;
            p.galley(at + vec2(0.0, 30.0), galley, t.text_2);
            let galley = p.layout("The space bar plays. Every key of the terminal interface works here too; ? lists them.".into(), sans(12.0), t.text_3, 420.0);
            p.galley(at + vec2(0.0, 38.0 + h), galley, t.text_3);
        }
    }

    /// The wheel: scrolls, with Shift sideways; with Ctrl it zooms in time
    /// where the pointer is (over the headers, every track taller or
    /// shorter); with Alt the tracks taller and shorter.
    fn wheel_over_arrange(&mut self, ui: &Ui, rect: Rect, geo: &Geo) {
        let Some(pos) = View::pointer_in(ui, rect) else { return };
        if self.menu.is_some() || self.dialogs.open() || ui.ctx().layer_id_at(pos).is_some_and(|l| l.order != egui::Order::Background) {
            return;
        }
        let wheels: Vec<(Vec2, egui::Modifiers)> = ui.input(|i| {
            i.events
                .iter()
                .filter_map(|e| match e {
                    egui::Event::MouseWheel { unit, delta, modifiers, .. } => {
                        let scale = match unit {
                            egui::MouseWheelUnit::Point => 1.0,
                            egui::MouseWheelUnit::Line => 40.0,
                            egui::MouseWheelUnit::Page => 400.0,
                        };
                        Some((*delta * scale, *modifiers))
                    }
                    _ => None,
                })
                .collect()
        });
        let over_headers = pos.x < rect.left() + HEADER_W;
        for (delta, m) in wheels {
            let dy = if delta.y != 0.0 { delta.y } else { delta.x };
            if m.ctrl {
                if over_headers {
                    self.arrange.zoom_rows(dy > 0.0);
                } else {
                    self.arrange.zoom_at(dy > 0.0, pos.x - geo.lanes.left() + geo.scroll.x);
                }
            } else if m.alt {
                self.arrange.zoom_rows(dy > 0.0);
            } else if m.shift {
                self.arrange.scroll.x = (self.arrange.scroll.x - dy).max(0.0);
            } else {
                self.arrange.scroll.x = (self.arrange.scroll.x - delta.x).max(0.0);
                self.arrange.scroll.y = (self.arrange.scroll.y - delta.y).max(0.0);
            }
        }
    }

    /// Zoom, in the corner of the timeline: in time, the whole song, and
    /// the height of the tracks.
    fn zoom_box(&mut self, ui: &mut Ui, rect: Rect) {
        let t = th();
        let fit_w = widgets::button_width(ui, "Fit", false, 24.0);
        let width = 2.0 + 24.0 * 4.0 + fit_w + 5.0 + 1.0 + 2.0;
        let bx = Rect::from_min_size(pos2(rect.right() - width - 14.0, rect.bottom() - 28.0 - 14.0), vec2(width, 28.0));
        ui.painter().rect(bx, CornerRadius::same(4), alpha(t.card, 0.96), Stroke::new(1.0, t.card_line), StrokeKind::Inside);
        let mut x = bx.left() + 2.0;
        let mut over = false;
        let mut button = |ui: &mut Ui, x: &mut f32, w: f32, shape: Option<icons::Icon>, label: &str| {
            let r = Rect::from_min_size(pos2(*x, bx.top() + 2.0), vec2(w, 24.0));
            *x += w + 1.0;
            let response = widgets::button(ui, r, Id::unique(("zoom", label, w as i32, shape.map(|s| s.0.len()))), shape, label, Look::quiet());
            over |= response.hovered();
            response.clicked()
        };
        if button(ui, &mut x, 24.0, Some(icons::MAGNIFYING_GLASS_MINUS), "") {
            self.arrange.zoom_step(false);
        }
        if button(ui, &mut x, 24.0, Some(icons::MAGNIFYING_GLASS_PLUS), "") {
            self.arrange.zoom_step(true);
        }
        if button(ui, &mut x, fit_w, None, "Fit") {
            let length = number(&self.s.project["length"]);
            self.arrange.zoom_fit(length, self.s.bar());
        }
        ui.painter().vline(x + 0.5, (bx.top() + 2.0)..=(bx.bottom() - 2.0), Stroke::new(1.0, t.card_line));
        x += 2.0;
        if button(ui, &mut x, 24.0, Some(icons::ARROWS_IN_LINE_VERTICAL), "") {
            self.arrange.zoom_rows(false);
        }
        if button(ui, &mut x, 24.0, Some(icons::ARROWS_OUT_LINE_VERTICAL), "") {
            self.arrange.zoom_rows(true);
        }
        if over {
            widgets::hint("zoom: − and + in time (Ctrl − and Ctrl +, or Ctrl and the wheel) · Fit shows the whole song (Ctrl 0) · the arrows make tracks shorter and taller (Ctrl ↑ ↓, or Alt and the wheel)");
        }
    }

    // ------------------------------------------------------------ the timeline

    fn timeline(&mut self, ui: &mut Ui, geo: &Geo) {
        let t = th();
        let lanes = geo.lanes;
        let painter = ui.painter().with_clip_rect(lanes.intersect(ui.clip_rect()));
        let (from, to) = geo.seen();
        let rows_bottom = geo.row_top(self.s.tracks.len());
        // The tracks' rows.
        for (index, track) in self.s.tracks.iter().enumerate() {
            let top = geo.row_top(index);
            let row = Rect::from_x_y_ranges(lanes.x_range(), top..=(top + track.size * geo.rh - 1.0));
            let fill = if track.id == self.s.selected {
                Color32::from_rgb(0x24, 0x26, 0x2b)
            } else if index % 2 == 0 {
                t.lane
            } else {
                t.lane_alt
            };
            painter.rect_filled(row, CornerRadius::ZERO, fill);
            painter.hline(lanes.x_range(), row.bottom() + 0.5, Stroke::new(1.0, t.divider));
        }
        // Half beats and beats of the signature, when there is room for
        // them, then bars, as the tempo map has them.
        let ys = lanes.top()..=rows_bottom.min(lanes.bottom());
        for line in model::lines_in_view(&self.s.lines, from - 1.0, to + 1.0, geo.zoom) {
            if geo.zoom >= 20.0 {
                painter.vline(geo.x((line.beat + line.next) / 2.0).round() + 0.5, ys.clone(), Stroke::new(1.0, t.line_sub));
            }
            if line.label.is_empty() {
                if geo.zoom >= 10.0 {
                    painter.vline(geo.x(line.beat).round() + 0.5, ys.clone(), Stroke::new(1.0, t.line_beat));
                }
            } else {
                painter.vline(geo.x(line.beat).round() + 0.5, ys.clone(), Stroke::new(1.0, t.line_bar));
            }
        }
        let span = |a: f32, b: f32| Rect::from_x_y_ranges(geo.x(a).max(lanes.left())..=geo.x(b).min(lanes.right()), ys.clone());
        // The loop, faintly, while it is on; and the punch range.
        let p = self.s.project.clone();
        if flag(&p["loop_enabled"]) && number(&p["loop_end"]) > number(&p["loop_start"]) {
            painter.rect_filled(span(number(&p["loop_start"]), number(&p["loop_end"])), CornerRadius::ZERO, Color32::from_rgba_unmultiplied(0xfe, 0xc1, 0x3a, 0x10));
        }
        if flag(&p["punch_enabled"]) && number(&p["punch_end"]) > number(&p["punch_start"]) {
            painter.rect_filled(span(number(&p["punch_start"]), number(&p["punch_end"])), CornerRadius::ZERO, alpha(t.rec, 0.06));
        }
        self.timeline_input(ui, geo);
        self.clips(ui, geo);
        // While a take is made: what has been recorded so far. Punched, only
        // what falls in the punch range.
        if self.s.recording
            && let Some(start) = self.rec_start
        {
            let punching = flag(&p["punch_enabled"]);
            let (a, b) = if punching {
                (start.max(number(&p["punch_start"])), self.s.position.min(number(&p["punch_end"])))
            } else {
                (start, self.s.position)
            };
            for (index, track) in self.s.tracks.iter().enumerate() {
                if !track.armed || (punching && b <= a) {
                    continue;
                }
                let top = geo.row_top(index) + 1.0;
                let r = Rect::from_min_max(pos2(geo.x(a), top), pos2(geo.x(b).max(geo.x(a) + 2.0), top + track.clip_size * geo.rh - 3.0));
                painter.rect(r, CornerRadius::same(2), alpha(t.rec, 0.3), Stroke::new(1.0, t.rec), StrokeKind::Inside);
            }
        }
        if self.show_automation {
            self.automation(ui, geo);
        }
        self.lane_rows(ui, geo);
        self.take_lanes(ui, geo);
        self.ex_marks(ui, geo);
        self.selection(ui, geo);
        // A box being drawn with the right button, or a stretch dragged out.
        let pointer = ui.input(|i| i.pointer.latest_pos());
        match (&self.arrange.gesture, pointer) {
            (Some(Gesture::Marquee { from, .. }), Some(p)) if (p - *from).length() > 4.0 => {
                painter.rect(Rect::from_two_pos(*from, p), CornerRadius::ZERO, alpha(t.select, 0.15), Stroke::new(1.0, t.select), StrokeKind::Inside);
            }
            (Some(Gesture::Lane { at }), Some(p)) if (p.x - at.x).abs() > 5.0 || (p.y - at.y).abs() > geo.rh / 2.0 => {
                let (r0, r1) = (geo.row_at(at.y.min(p.y)), geo.row_at(at.y.max(p.y)));
                let r = Rect::from_x_y_ranges(at.x.min(p.x)..=at.x.max(p.x), geo.row_top(r0)..=(geo.row_top(r1 + 1) - 1.0));
                painter.rect(r, CornerRadius::ZERO, alpha(t.select, 0.18), Stroke::new(1.0, t.select), StrokeKind::Inside);
            }
            _ => {}
        }
        // Edit cursor and playhead.
        let cursor_x = geo.x(self.s.cursor).round() + 0.5;
        painter.vline(cursor_x, ys.clone(), Stroke::new(1.0, t.select));
        if let Some(row) = self.s.row_of(self.s.selected)
            && !self.s.modal["selection"].is_object()
        {
            let grid = number(&p["grid"]).max(0.0);
            let top = geo.row_top(row);
            let r = Rect::from_min_size(pos2(geo.x(self.s.cursor), top), vec2((grid * geo.zoom).max(3.0), self.s.tracks[row].size * geo.rh - 1.0));
            let stroke = if self.s.focused() == "arrange" { Stroke::new(1.0, mode_colour(self.s.mode())) } else { Stroke::NONE };
            painter.rect(r, CornerRadius::ZERO, alpha(t.text, 0.10), stroke, StrokeKind::Inside);
        }
        painter.vline(geo.x(self.s.position).round() + 0.5, ys, Stroke::new(1.0, t.play));
    }

    /// Presses on the timeline itself (not on a clip, a point or a lane
    /// row): where they begin and what they become.
    fn timeline_input(&mut self, ui: &mut Ui, geo: &Geo) {
        let response = ui.interact(geo.lanes, Id::unique("timeline"), Sense::click_and_drag());
        if response.hovered() {
            widgets::hint("timeline: click puts the cursor · double click makes a clip · drag selects time · right drag chooses clips · middle drag pans · Ctrl and wheel zooms");
        }
        let (pos, m) = ui.input(|i| (i.pointer.interact_pos(), i.modifiers));
        let Some(pos) = pos else { return };
        let ids: Vec<i64> = self.s.tracks.iter().map(|t| t.id).collect();
        let track_at = |y: f32| ids.get(geo.row_at(y)).copied().unwrap_or(0);
        if response.hovered() && self.arrange.gesture.is_none() {
            let pressed = |b| ui.input(|i| i.pointer.button_pressed(b));
            if pressed(egui::PointerButton::Primary) {
                self.arrange.renaming = None;
                self.arrange.gesture = self.press_on_timeline(geo, pos, m);
                if self.arrange.gesture.is_none() {
                    self.pass("select", json!([track_at(pos.y), geo.beat(pos.x).max(0.0)]));
                    self.arrange.gesture = Some(Gesture::Lane { at: pos });
                }
            } else if pressed(egui::PointerButton::Secondary) {
                self.arrange.gesture = self.right_press_on_timeline(geo, pos);
            } else if pressed(egui::PointerButton::Middle) {
                self.arrange.gesture = Some(Gesture::Pan { from: pos, scroll: self.arrange.scroll });
            }
        }
        if response.double_clicked() {
            self.double_click_on_timeline(geo, pos);
        }
    }

    /// The gesture under way, after everything that can begin one was
    /// drawn: a press and a release can come in one frame.
    fn arrange_gestures(&mut self, ui: &Ui, geo: &Geo) {
        let (pos, m) = ui.input(|i| (i.pointer.interact_pos(), i.modifiers));
        if let Some(pos) = pos {
            self.gesture_moves(ui, geo, pos, m);
        }
    }

    /// What a left press at `pos` takes hold of, from the top: the
    /// selection, a point, a take lane, a lane row, the automation over the
    /// clips, a warp marker, a fade handle, the gain line, an edge, a clip.
    fn press_on_timeline(&mut self, geo: &Geo, pos: Pos2, m: egui::Modifiers) -> Option<Gesture> {
        if let Some(hit) = self.selection_at(geo, pos) {
            // A click on the selection lets go of it.
            let _ = hit;
            self.feed("<Esc>");
            return Some(Gesture::Lane { at: pos });
        }
        if let Some(g) = self.point_at(geo, pos) {
            return Some(g);
        }
        if let Some((track, take)) = self.take_lane_at(geo, pos) {
            return Some(Gesture::Take { track, take, from: pos.x });
        }
        if let Some((row, lane, top, span)) = self.lane_row_at(geo, pos) {
            let height = (1.0 - (pos.y - top) / span).clamp(0.0, 1.0);
            return Some(Gesture::Pencil { row, lane: Some(lane), top, span, points: vec![(geo.beat(pos.x).max(0.0), ((height - 0.08) / 0.84).clamp(0.0, 1.0))] });
        }
        if self.show_automation {
            let row = geo.row_at(pos.y);
            let top = geo.row_top(row);
            let span = self.s.tracks.get(row).map_or(1.0, |t| t.clip_size) * geo.rh;
            let height = (1.0 - (pos.y - top) / span).clamp(0.0, 1.0);
            return Some(Gesture::Pencil { row, lane: None, top, span, points: vec![(geo.beat(pos.x).max(0.0), height)] });
        }
        let (clip, rect) = self.clip_at(geo, pos)?;
        let title = clip_title(rect.height());
        let local = pos - rect.min;
        if !clip.midi {
            for (index, at) in clip.warps.iter().enumerate() {
                let x = geo.x(clip.start + at);
                if (pos.x - x).abs() <= 4.5 && local.y < title.max(10.0) {
                    return Some(Gesture::Warp { id: clip.id, index, from: pos.x });
                }
            }
            let (fade_in, fade_out) = fade_xs(clip, geo, rect);
            if local.y <= 9.0 && (pos.x - fade_in).abs() <= 4.5 {
                return Some(Gesture::Fade { id: clip.id, out: false, from: pos.x });
            }
            if local.y <= 9.0 && (pos.x - fade_out).abs() <= 4.5 {
                return Some(Gesture::Fade { id: clip.id, out: true, from: pos.x });
            }
            if local.y <= 5.0 && local.x >= 10.0 && local.x <= rect.width() - 10.0 {
                return Some(Gesture::Gain { id: clip.id, from: pos.y, start: clip.gain });
            }
        }
        if local.x < 7.0 {
            return Some(Gesture::Trim { id: clip.id, start: true, group: clip.selected, at: clip.start, from: pos.x });
        }
        if local.x > rect.width() - 7.0 {
            return Some(Gesture::Trim { id: clip.id, start: false, group: clip.selected, at: clip.start + clip.length, from: pos.x });
        }
        let _ = m;
        Some(Gesture::Clip { id: clip.id, group: clip.selected, row: clip.row, from: pos, content_y: pos.y })
    }

    fn right_press_on_timeline(&mut self, geo: &Geo, pos: Pos2) -> Option<Gesture> {
        if self.selection_at(geo, pos).is_some() {
            return Some(Gesture::Marquee { from: pos, clip: Some(-1) });
        }
        if let Some(Gesture::Point { lane, index, .. }) = self.point_at(geo, pos) {
            self.pass("remove_point", json!([lane, index + 1]));
            return None;
        }
        if let Some(g) = self.tempo_or_warp_right(geo, pos) {
            return Some(g);
        }
        let clip = self.clip_at(geo, pos).map(|(c, _)| c.id);
        Some(Gesture::Marquee { from: pos, clip })
    }

    fn tempo_or_warp_right(&mut self, geo: &Geo, pos: Pos2) -> Option<Gesture> {
        let (clip, rect) = self.clip_at(geo, pos)?;
        if clip.midi {
            return None;
        }
        let title = clip_title(rect.height());
        for (index, at) in clip.warps.iter().enumerate() {
            if (pos.x - geo.x(clip.start + at)).abs() <= 4.5 && pos.y - rect.top() < title.max(10.0) {
                self.open_menu("warp", json!([clip.id, index + 1]), pos);
                return Some(Gesture::Pan { from: pos, scroll: self.arrange.scroll });
            }
        }
        None
    }

    fn double_click_on_timeline(&mut self, geo: &Geo, pos: Pos2) {
        if self.show_automation || self.lane_row_at(geo, pos).is_some() || self.take_lane_at(geo, pos).is_some() {
            return;
        }
        match self.clip_at(geo, pos) {
            // On an audio clip's top band: a warp marker there.
            Some((clip, rect)) if !clip.midi && pos.y - rect.top() < clip_title(rect.height()).max(10.0) => {
                self.pass("warp_add", json!([clip.id, geo.beat(pos.x)]));
            }
            Some((clip, _)) => {
                self.pass("open_clip", json!([clip.id]));
            }
            None => {
                let track = self.s.tracks.get(geo.row_at(pos.y)).map_or(0, |t| t.id);
                self.pass("add_clip", json!([track, geo.beat(pos.x).max(0.0)]));
            }
        }
        // The second press of a double click began a gesture that is not one.
        self.arrange.gesture = None;
    }

    /// The gesture under way follows the pointer, and is done when let go.
    fn gesture_moves(&mut self, ui: &Ui, geo: &Geo, pos: Pos2, m: egui::Modifiers) {
        let Some(gesture) = self.arrange.gesture.clone() else { return };
        let released = |b| ui.input(|i| i.pointer.button_released(b));
        let double = ui.input(|i| i.pointer.button_double_clicked(egui::PointerButton::Primary));
        match gesture {
            Gesture::Lane { at } => {
                if released(egui::PointerButton::Primary) {
                    self.arrange.gesture = None;
                    if (pos.x - at.x).abs() > 5.0 || (pos.y - at.y).abs() > geo.rh / 2.0 {
                        let (r0, r1) = (geo.row_at(at.y.min(pos.y)), geo.row_at(at.y.max(pos.y)));
                        self.pass("select_range", json!([r0 + 1, geo.beat(at.x).max(0.0), r1 + 1, geo.beat(pos.x).max(0.0)]));
                    }
                }
            }
            Gesture::Marquee { from, clip } => {
                if released(egui::PointerButton::Secondary) {
                    self.arrange.gesture = None;
                    if (pos - from).length() > 4.0 {
                        let (a, b) = (from.min(pos), from.max(pos));
                        self.pass("select_clips_box", json!([geo.row_at(a.y) + 1, geo.beat(a.x), geo.row_at(b.y) + 1, geo.beat(b.x), mode(m)]));
                    } else {
                        match clip {
                            Some(-1) => self.open_menu("selection", json!([]), pos),
                            Some(id) => self.open_menu("clip", json!([id, geo.beat(pos.x)]), pos),
                            None => {
                                // A right click also puts the cursor, so that the menu acts there.
                                let track = self.s.tracks.get(geo.row_at(pos.y)).map_or(0, |t| t.id);
                                let beat = geo.beat(pos.x).max(0.0);
                                self.pass("select", json!([track, beat]));
                                self.open_menu("timeline", json!([track, beat]), pos);
                            }
                        }
                    }
                }
            }
            Gesture::Pan { from, scroll } => {
                self.arrange.scroll = (scroll - (pos - from)).max(Vec2::ZERO);
                if !ui.input(|i| i.pointer.any_down()) {
                    self.arrange.gesture = None;
                }
            }
            Gesture::Clip { id, row, from, content_y, .. } => {
                if released(egui::PointerButton::Primary) {
                    self.arrange.gesture = None;
                    if double {
                        return;
                    }
                    let d = pos - from;
                    let rows_moved = geo.row_at(content_y + d.y) as i64 - row as i64;
                    if let Some((column, slot)) = self.session.slot_at(pos)
                        && d.length() > 3.0
                    {
                        self.pass("clip_to_slot", json!([id, column, slot]));
                    } else if d.x.abs() > 3.0 || rows_moved != 0 {
                        self.pass("drag_clips", json!([id, d.x / geo.zoom, rows_moved, m.ctrl, m.shift]));
                    } else {
                        let beat = geo.beat(pos.x);
                        self.pass("select_clip", json!([id, beat.max(0.0), mode(m)]));
                    }
                }
            }
            Gesture::Trim { id, start, from, .. } => {
                if released(egui::PointerButton::Primary) {
                    self.arrange.gesture = None;
                    let dx = pos.x - from;
                    if dx.abs() > 2.0 {
                        self.pass("trim_clips", json!([id, if start { "start" } else { "end" }, dx / geo.zoom, m.shift, m.alt]));
                    }
                }
            }
            Gesture::Fade { id, out, from } => {
                if released(egui::PointerButton::Primary) {
                    self.arrange.gesture = None;
                    if (pos.x - from).abs() > 1.0
                        && let Some(clip) = self.s.clips.iter().find(|c| c.id == id)
                    {
                        let beats = if out { clip.fade_out - (pos.x - from) / geo.zoom } else { clip.fade_in + (pos.x - from) / geo.zoom };
                        self.pass("set_fade", json!([id, if out { "out" } else { "in" }, beats.clamp(0.0, clip.length)]));
                    }
                }
            }
            Gesture::Gain { id, from, start } => {
                // A quarter of a dB a pixel, a twentieth with Shift.
                let now = (start - (pos.y - from) * if m.shift { 0.05 } else { 0.25 }).clamp(-60.0, 24.0);
                widgets::hint(format!("clip gain: {} dB", (now * 10.0).round() / 10.0));
                if released(egui::PointerButton::Primary) {
                    self.arrange.gesture = None;
                    if (now - start).abs() > 0.01 {
                        self.pass("set_clip_gain", json!([id, now]));
                    }
                }
            }
            Gesture::Warp { id, index, from } => {
                if released(egui::PointerButton::Primary) {
                    self.arrange.gesture = None;
                    if (pos.x - from).abs() > 1.0
                        && let Some(clip) = self.s.clips.iter().find(|c| c.id == id)
                    {
                        let beat = clip.start + clip.warps.get(index).copied().unwrap_or(0.0) + (pos.x - from) / geo.zoom;
                        self.pass("warp_move", json!([id, index + 1, beat, m.shift]));
                    }
                }
            }
            Gesture::Pencil { row, lane, top, span, mut points } => {
                let raw = (1.0 - (pos.y - top) / span).clamp(0.0, 1.0);
                let height = if lane.is_some() { ((raw - 0.08) / 0.84).clamp(0.0, 1.0) } else { raw };
                let beat = geo.beat(pos.x).max(0.0);
                if points.last() != Some(&(beat, height)) {
                    points.push((beat, height));
                }
                if released(egui::PointerButton::Primary) {
                    self.arrange.gesture = None;
                    let lane = lane.or_else(|| self.lane_of(row));
                    let Some(lane) = lane else { return };
                    // How far the pointer went, in pixels: a click hardly moves.
                    let reach = points
                        .iter()
                        .map(|p| ((p.0 - points[0].0) * geo.zoom).abs() + ((p.1 - points[0].1) * span).abs())
                        .fold(0.0, f32::max);
                    if reach < 5.0 {
                        self.pass("add_point", json!([lane, points[0].0, points[0].1]));
                    } else {
                        let list: Vec<_> = points.iter().map(|(b, h)| json!([b, h])).collect();
                        self.pass("draw_lane", json!([lane, list]));
                    }
                } else {
                    self.arrange.gesture = Some(Gesture::Pencil { row, lane, top, span, points });
                }
            }
            Gesture::Point { lane, index, beat, value, span, from } => {
                if released(egui::PointerButton::Primary) {
                    self.arrange.gesture = None;
                    let d = pos - from;
                    self.pass("move_point", json!([lane, index + 1, (beat + d.x / geo.zoom).max(0.0), (value - d.y / span).clamp(0.0, 1.0)]));
                }
            }
            Gesture::Take { track, take, from } => {
                if released(egui::PointerButton::Primary) {
                    self.arrange.gesture = None;
                    if (pos.x - from).abs() <= 3.0 {
                        self.pass("take_click", json!([track, take, geo.beat(pos.x).max(0.0)]));
                    } else {
                        self.pass("comp", json!([track, take, geo.beat(from).max(0.0), geo.beat(pos.x).max(0.0), m.shift]));
                    }
                }
            }
            _ => self.ruler_moves(ui, geo, pos, m),
        }
    }

    /// The lane a row's track shows, made as a volume lane if it has none.
    fn lane_of(&self, row: usize) -> Option<i64> {
        let track = self.s.tracks.get(row)?;
        self.shown_lane(row).map(|l| l.id).or_else(|| {
            self.ask("return daw.frontend.act.lane(...)", json!([track.id, "volume"])).as_i64()
        })
    }

    /// The lane a track shows over its clips: the one chosen for it, else
    /// the first that holds anything, else its first.
    pub fn shown_lane(&self, row: usize) -> Option<&model::Lane> {
        let track = self.s.tracks.get(row)?;
        let chosen = self.arrange.shown.get(&track.id).and_then(|id| track.lanes.iter().find(|l| l.id == *id));
        chosen.or_else(|| track.lanes.iter().find(|l| !l.points.is_empty())).or(track.lanes.first())
    }

    /// Which lane a track shows: volume, pan, or one of its parameters'.
    pub fn show_lane(&mut self, track: i64, choice: usize) {
        let made = match choice {
            0 => self.ask("return daw.frontend.act.lane(...)", json!([track, "volume"])).as_i64(),
            1 => self.ask("return daw.frontend.act.lane(...)", json!([track, "pan"])).as_i64(),
            _ => self.s.track(track).and_then(|t| t.lanes.iter().filter(|l| l.param).nth(choice - 2)).map(|l| l.id),
        };
        if let Some(lane) = made {
            self.arrange.shown.insert(track, lane);
            self.show_automation = true;
        }
    }

    /// Automate a device's parameter: it gets a lane, which the selected
    /// track shows.
    pub fn automate_param(&mut self, device: i64, key: &str) {
        let track = self.s.selected;
        if let Some(lane) = self.ask("return daw.frontend.act.lane(...)", json!([track, "param", device, key])).as_i64() {
            self.arrange.shown.insert(track, lane);
            self.show_automation = true;
        }
    }

    // ------------------------------------------------------------ the clips

    /// Where a clip is drawn, as it is (not dragged).
    fn clip_rect(&self, geo: &Geo, clip: &Clip) -> Rect {
        let top = geo.row_top(clip.row) + 1.0;
        let clip_size = self.s.tracks.get(clip.row).map_or(1.0, |t| t.clip_size);
        Rect::from_min_size(pos2(geo.x(clip.start), top), vec2((clip.length * geo.zoom - 1.0).max(6.0), clip_size * geo.rh - 3.0))
    }

    /// The clip under the pointer, the last drawn first.
    fn clip_at(&self, geo: &Geo, pos: Pos2) -> Option<(&Clip, Rect)> {
        self.s.clips.iter().rev().map(|c| (c, self.clip_rect(geo, c))).find(|(_, r)| r.contains(pos))
    }

    fn clips(&mut self, ui: &mut Ui, geo: &Geo) {
        let t = th();
        let lanes = geo.lanes;
        let (from, to) = geo.seen();
        let ctx = ui.ctx().clone();
        let pointer = ui.input(|i| i.pointer.latest_pos());
        let hover = ui.input(|i| i.pointer.hover_pos()).filter(|p| lanes.contains(*p));
        let current = self.s.modal["clip"].as_i64().unwrap_or(-1);
        // Shown where it would land, while dragged.
        let (drag_id, drag_group, drag_offset) = match (&self.arrange.gesture, pointer) {
            (Some(Gesture::Clip { id, group, row, from, content_y }), Some(p)) if (p - *from).length() > 3.0 => {
                let grid = number(&self.s.project["grid"]).max(1e-6) * geo.zoom;
                let dx = p.x - from.x;
                let shown = if ui.input(|i| i.modifiers.shift) { dx } else { (dx / grid).round() * grid };
                let rows_moved = geo.row_at(content_y + (p.y - from.y));
                let dy = geo.row_top(rows_moved) - geo.row_top(*row);
                (*id, *group, vec2(shown, dy))
            }
            _ => (-1, false, Vec2::ZERO),
        };
        let trim = match (&self.arrange.gesture, pointer) {
            (Some(Gesture::Trim { id, start, group, at, from }), Some(p)) => {
                let (shift, alt) = ui.input(|i| (i.modifiers.shift, i.modifiers.alt));
                let free = shift && !(alt && !*start);
                let slip = alt && !(shift && !*start);
                let dx = p.x - from;
                let grid = number(&self.s.project["grid"]).max(1e-6) * geo.zoom;
                let shown = if free || slip { dx } else { ((at * geo.zoom + dx) / grid).round() * grid - at * geo.zoom };
                Some((*id, *start, *group, shown, slip, dx))
            }
            _ => None,
        };
        let clips = std::mem::take(&mut self.s.clips);
        let mut hover_hint = None;
        for clip in &clips {
            if clip.start > to + 1.0 || clip.start + clip.length < from - 1.0 {
                continue;
            }
            let base = self.clip_rect(geo, clip);
            let dragged = drag_id >= 0 && (clip.id == drag_id || (drag_group && clip.selected));
            let trimmed = trim.filter(|tr| clip.id == tr.0 || (tr.2 && clip.selected));
            let (trim_left, trim_right, slip) = match trimmed {
                Some((_, start, _, shown, slip, _)) if !slip => {
                    if start { ((shown).max(-clip.start * geo.zoom), 0.0, 0.0) } else { (0.0, shown, 0.0) }
                }
                Some((_, _, _, _, _, dx)) => (0.0, 0.0, dx),
                None => (0.0, 0.0, 0.0),
            };
            let mut rect = base;
            rect.min.x += trim_left;
            rect.max.x = (rect.max.x + trim_right).max(rect.min.x + 6.0);
            if dragged {
                rect = rect.translate(drag_offset);
            }
            if rect.right() < lanes.left() - 600.0 || rect.left() > lanes.right() + 600.0 {
                continue;
            }
            let colour = self.row_colour(clip.row);
            let selected_now = clip.id == current;
            let painter = ui.painter().with_clip_rect(rect.intersect(lanes));
            let face = if clip.muted { t.panel } else { mix(colour, t.lane, if selected_now { 0.40 } else { 0.26 }) };
            painter.rect_filled(rect, CornerRadius::same(2), face);
            // A title bar when the row has room for one.
            let title = clip_title(rect.height());
            if title > 0.0 {
                let bar = Rect::from_min_size(rect.min, vec2(rect.width(), title));
                let bar_face = if clip.muted { t.text_off } else if selected_now { mix(colour, Color32::WHITE, 0.80) } else { colour };
                painter.rect_filled(bar, CornerRadius { nw: 2, ne: 2, sw: 0, se: 0 }, bar_face);
                // The name stays in view while the clip's start is out of it.
                let x = (rect.left() + 5.0).max(lanes.left() + 5.0);
                let name = if clip.takes > 1 { format!("{}  ‹{}/{}›", clip.name, clip.take, clip.takes) } else { clip.name.clone() };
                let shown = widgets::elide(ui, &name, semi(T_SMALL), rect.right() - x - 3.0);
                painter.text(pos2(x, bar.center().y), Align2::LEFT_CENTER, shown, semi(T_SMALL), if clip.muted { t.text_3 } else { t.on_hue });
            }
            // Its notes, or its waveform: what plays moves with the pointer
            // while it is slipped, and stays put in time while the start is trimmed.
            if let Some(key) = &clip.key {
                let full_w = clip.length * geo.zoom - 1.0;
                let texture = self.clip_picture(&ctx, clip, key, full_w);
                if let Some(texture) = texture {
                    let full = Rect::from_min_size(pos2(base.left() + slip + if dragged { drag_offset.x } else { 0.0 }, rect.top() + title + 2.0), vec2(full_w.max(1.0), rect.height() - title - 4.0));
                    let ink = if clip.muted { t.text_3 } else { mix(colour, Color32::WHITE, 0.8) };
                    let shown = full.intersect(rect).intersect(lanes);
                    if shown.width() > 0.0 {
                        let u0 = (shown.left() - full.left()) / full.width();
                        let u1 = (shown.right() - full.left()) / full.width();
                        let uv = Rect::from_min_max(pos2(u0, 0.0), pos2(u1, 1.0));
                        painter.image(texture.id(), Rect::from_x_y_ranges(shown.x_range(), full.y_range()), uv, ink);
                    }
                }
            }
            // An audio clip's fades: the part above each line is faded away.
            if !clip.midi {
                let (fi, fo) = fade_xs(clip, geo, rect);
                let held = match (&self.arrange.gesture, pointer) {
                    (Some(Gesture::Fade { id, out, from }), Some(p)) if *id == clip.id => Some((*out, p.x - from)),
                    _ => None,
                };
                let fi = match held {
                    Some((false, dx)) => (fi + dx).clamp(rect.left(), rect.right()),
                    _ => fi,
                };
                let fo = match held {
                    Some((true, dx)) => (fo + dx).clamp(rect.left(), rect.right()),
                    _ => fo,
                };
                let shade = alpha(t.surface, 0.55);
                if fi > rect.left() + 0.5 {
                    painter.add(Shape::convex_polygon(vec![rect.left_top(), pos2(fi, rect.top()), rect.left_bottom()], shade, Stroke::new(1.0, t.text)));
                }
                if fo < rect.right() - 0.5 {
                    painter.add(Shape::convex_polygon(vec![rect.right_top(), rect.right_bottom(), pos2(fo, rect.top())], shade, Stroke::new(1.0, t.text)));
                }
                // The gain line, while it is dragged: as high in the waveform
                // as the clip plays, 0 dB half way up, +6 dB at the top.
                if let (Some(Gesture::Gain { id, from, start }), Some(p)) = (&self.arrange.gesture, pointer)
                    && *id == clip.id
                {
                    let shift = ui.input(|i| i.modifiers.shift);
                    let now = (start - (p.y - from) * if shift { 0.05 } else { 0.25 }).clamp(-60.0, 24.0);
                    let body = rect.height() - title - 4.0;
                    let y = rect.top() + title + 2.0 + (1.0 - (10f32.powf(now / 20.0) / 2.0).clamp(0.0, 1.0)) * body;
                    painter.hline(rect.x_range(), y, Stroke::new(1.0, t.select));
                }
                // The handles at the top corners.
                for x in [fi, fo] {
                    let handle = Rect::from_center_size(pos2(x, rect.top() + 4.5), vec2(9.0, 9.0));
                    let lit = hover.is_some_and(|p| handle.contains(p));
                    painter.rect_filled(handle, CornerRadius::same(2), if lit { t.select } else { alpha(t.text, 0.6) });
                }
                // Its warp markers: a line down the clip and a handle on its top band.
                for (index, at) in clip.warps.iter().enumerate() {
                    let mut x = geo.x(clip.start + at);
                    let held = matches!(&self.arrange.gesture, Some(Gesture::Warp { id, index: i, .. }) if *id == clip.id && *i == index);
                    if let (true, Some(Gesture::Warp { from, .. }), Some(p)) = (held, &self.arrange.gesture, pointer) {
                        x += p.x - from;
                    }
                    let lit = held || hover.is_some_and(|p| (p.x - x).abs() <= 4.5 && p.y - rect.top() < title.max(10.0));
                    painter.vline(x.round() + 0.5, rect.y_range(), Stroke::new(1.0, alpha(t.yellow, if lit { 1.0 } else { 0.7 })));
                    painter.add(Shape::convex_polygon(
                        vec![pos2(x - 4.5, rect.top()), pos2(x + 4.5, rect.top()), pos2(x, rect.top() + 7.0)],
                        if lit { t.select } else { t.yellow },
                        Stroke::NONE,
                    ));
                }
            }
            // Chosen, under the cursor or under the pointer: an outline.
            let over = hover.is_some_and(|p| rect.contains(p));
            if selected_now || clip.selected || over {
                let line = if selected_now || clip.selected { Color32::WHITE } else { Color32::from_white_alpha(0x40) };
                painter.rect_stroke(rect, CornerRadius::same(2), Stroke::new(1.0, line), StrokeKind::Inside);
            }
            if let Some(p) = hover.filter(|p| rect.contains(*p)) {
                let local = p - rect.min;
                if local.x < 7.0 {
                    painter.rect_filled(Rect::from_min_size(rect.min + vec2(1.0, 2.0), vec2(2.0, rect.height() - 4.0)), CornerRadius::same(1), Color32::from_white_alpha(0xa0));
                    hover_hint = Some("clip start: drag to trim it, what plays staying where it is · Shift off the grid · Alt slips what plays inside".to_string());
                    ui.ctx().set_cursor_icon(egui::CursorIcon::ResizeHorizontal);
                } else if local.x > rect.width() - 7.0 {
                    painter.rect_filled(Rect::from_min_size(pos2(rect.right() - 3.0, rect.top() + 2.0), vec2(2.0, rect.height() - 4.0)), CornerRadius::same(1), Color32::from_white_alpha(0xa0));
                    hover_hint = Some("clip end: drag to make the clip longer or shorter · Shift off the grid · Alt slips what plays inside".to_string());
                    ui.ctx().set_cursor_icon(egui::CursorIcon::ResizeHorizontal);
                } else if !clip.midi && local.y <= 5.0 {
                    hover_hint = Some(format!("clip gain: {} dB · drag up or down, with Shift finely", (clip.gain * 10.0).round() / 10.0));
                } else {
                    hover_hint = Some("clip: click chooses, Ctrl adds, Shift extends · drag moves the chosen, Ctrl copies, Shift off the grid · double click opens its notes · right click for more".to_string());
                }
            }
        }
        self.s.clips = clips;
        if let Some(h) = hover_hint
            && !self.show_automation
        {
            widgets::hint(h);
        }
    }

    /// The picture inside a clip, made again when its key says its notes or
    /// its waveform have changed. A waveform is fetched at about the width
    /// it is drawn at.
    fn clip_picture(&mut self, ctx: &egui::Context, clip: &Clip, key: &str, width: f32) -> Option<egui::TextureHandle> {
        let points = pictures::wave_points(width);
        let key = if clip.midi { key.to_string() } else { format!("{key}@{points}") };
        let (id, midi, length) = (clip.id, clip.midi, clip.length);
        let notches: Vec<f32> = clip.notches.iter().map(|b| b / length.max(1e-6)).collect();
        let k = &self.k;
        self.pictures.get(ctx, (id, 0), &key, || {
            let call = if midi {
                json!(["return daw.frontend.preview(...)", id])
            } else {
                json!(["return daw.frontend.peaks(...)", id, points])
            };
            let flat: Vec<f32> = k.borrow_mut().call("eval", call).map(|v| rows(&v).iter().map(number).collect()).unwrap_or_default();
            let picture = if midi { pictures::notes_picture(&flat, length) } else { pictures::wave_picture(&flat) };
            picture.map(|p| notched(p, &notches))
        })
    }

    // ------------------------------------------------------- automation

    /// Automation over the clips while it is edited: one lane a track.
    fn automation(&mut self, ui: &mut Ui, geo: &Geo) {
        let t = th();
        let lanes = geo.lanes;
        let painter = ui.painter().with_clip_rect(lanes);
        painter.rect_filled(lanes, CornerRadius::ZERO, alpha(t.surface, 0.6));
        let (from, to) = geo.seen();
        let hover = ui.input(|i| i.pointer.hover_pos()).filter(|p| lanes.contains(*p));
        for row in 0..self.s.tracks.len() {
            let Some(lane) = self.shown_lane(row).cloned() else { continue };
            let track = &self.s.tracks[row];
            let top = geo.row_top(row);
            let span = track.clip_size * geo.rh;
            let colour = if lane.enabled { mix(track.color, Color32::WHITE, 0.7) } else { t.text_3 };
            let name = if lane.enabled { lane.name.clone() } else { format!("{} (off)", lane.name) };
            painter.text(pos2(lanes.left() + 8.0, top + 3.0), Align2::LEFT_TOP, name, semi(T_SMALL), colour);
            let y = |v: f32| top + (1.0 - v) * span;
            let line: Vec<Pos2> = model::curve_in_view(&lane.points, from - 1.0, to + 1.0).iter().map(|(b, v)| pos2(geo.x(*b), y(*v))).collect();
            painter.add(polyline(line, colour, 1.5));
            self.points(&painter, geo, &lane, top, span, hover);
        }
        if let Some(Gesture::Pencil { lane: None, row, top, span, points }) = &self.arrange.gesture {
            let _ = row;
            let line: Vec<Pos2> = points.iter().map(|(b, v)| pos2(geo.x(*b), top + (1.0 - v) * span)).collect();
            painter.add(polyline(line, t.text, 2.0));
        }
        if hover.is_some() && self.arrange.gesture.is_none() {
            widgets::hint("automation: click adds a point · hold and draw a curve · drag a point to move it · right click a point removes it");
        }
    }

    /// A lane's points in view, as handles; the one held follows the pointer.
    fn points(&self, painter: &egui::Painter, geo: &Geo, lane: &model::Lane, top: f32, span: f32, hover: Option<Pos2>) {
        let t = th();
        let (from, to) = geo.seen();
        let pointer = painter.ctx().input(|i| i.pointer.latest_pos());
        for (index, (beat, value)) in lane.points.iter().enumerate() {
            if *beat < from - 1.0 || *beat > to + 1.0 {
                continue;
            }
            let mut at = pos2(geo.x(*beat), top + (1.0 - value) * span);
            let held = matches!(&self.arrange.gesture, Some(Gesture::Point { lane: l, index: i, .. }) if *l == lane.id && *i == index);
            if let (true, Some(Gesture::Point { from, .. }), Some(p)) = (held, &self.arrange.gesture, pointer) {
                at += p - *from;
            }
            let lit = hover.is_some_and(|p| (p - at).length() <= 5.0);
            let r = if lit || held { 4.0 } else { 3.0 };
            painter.circle_filled(at, r, if held { t.select } else if lit { Color32::WHITE } else { t.text });
        }
    }

    /// The point of a shown lane under the pointer, if any.
    fn point_at(&self, geo: &Geo, pos: Pos2) -> Option<Gesture> {
        let mut found = None;
        let mut look = |lane: &model::Lane, top: f32, span: f32| {
            for (index, (beat, value)) in lane.points.iter().enumerate() {
                let at = pos2(geo.x(*beat), top + (1.0 - value) * span);
                if (pos - at).length() <= 5.0 {
                    found = Some(Gesture::Point { lane: lane.id, index, beat: *beat, value: *value, span, from: pos });
                }
            }
        };
        for (row, track) in self.s.tracks.iter().enumerate() {
            let base = geo.row_top(row) + (track.clip_size + track.take_rows as f32 * TAKE_ROW) * geo.rh;
            for (place, id) in track.lane_rows.iter().enumerate() {
                if let Some(lane) = track.lanes.iter().find(|l| l.id == *id) {
                    let top = base + place as f32 * LANE_ROW * geo.rh;
                    look(lane, top + 0.08 * LANE_ROW * geo.rh, 0.84 * LANE_ROW * geo.rh);
                }
            }
            if self.show_automation
                && let Some(lane) = self.shown_lane(row)
            {
                look(lane, geo.row_top(row), track.clip_size * geo.rh);
            }
        }
        found
    }

    /// The lane row (a lane shown as a row of its own) under the pointer:
    /// its row, lane, top and height.
    fn lane_row_at(&self, geo: &Geo, pos: Pos2) -> Option<(usize, i64, f32, f32)> {
        let row = geo.row_at(pos.y);
        let track = self.s.tracks.get(row)?;
        let base = geo.row_top(row) + (track.clip_size + track.take_rows as f32 * TAKE_ROW) * geo.rh;
        let span = LANE_ROW * geo.rh;
        let place = ((pos.y - base) / span).floor();
        if place < 0.0 {
            return None;
        }
        let lane = *track.lane_rows.get(place as usize)?;
        Some((row, lane, base + place * span, span))
    }

    /// Lanes shown as rows of their own, under the clips of their tracks.
    fn lane_rows(&mut self, ui: &mut Ui, geo: &Geo) {
        let t = th();
        let lanes = geo.lanes;
        let painter = ui.painter().with_clip_rect(lanes);
        let (from, to) = geo.seen();
        let hover = ui.input(|i| i.pointer.hover_pos()).filter(|p| lanes.contains(*p));
        for (row, track) in self.s.tracks.iter().enumerate() {
            let base = geo.row_top(row) + (track.clip_size + track.take_rows as f32 * TAKE_ROW) * geo.rh;
            for (place, id) in track.lane_rows.iter().enumerate() {
                let Some(lane) = track.lanes.iter().find(|l| l.id == *id) else { continue };
                let top = base + place as f32 * LANE_ROW * geo.rh;
                let rect = Rect::from_x_y_ranges(lanes.x_range(), top..=(top + LANE_ROW * geo.rh - 1.0));
                painter.rect_filled(rect, CornerRadius::ZERO, alpha(t.panel, 0.7));
                painter.hline(rect.x_range(), top + 0.5, Stroke::new(1.0, t.divider));
                let colour = if lane.enabled { mix(track.color, Color32::WHITE, 0.7) } else { t.text_3 };
                let name = if lane.enabled { lane.name.clone() } else { format!("{} (off)", lane.name) };
                painter.text(pos2(lanes.left() + 8.0, top + 2.0), Align2::LEFT_TOP, name, semi(T_SMALL), colour);
                let span = LANE_ROW * geo.rh;
                let y = |v: f32| top + (0.08 + (1.0 - v) * 0.84) * span;
                let line: Vec<Pos2> = model::curve_in_view(&lane.points, from - 1.0, to + 1.0).iter().map(|(b, v)| pos2(geo.x(*b), y(*v))).collect();
                painter.add(polyline(line, colour, 1.5));
                self.points(&painter, geo, lane, top + 0.08 * span, 0.84 * span, hover);
                if let Some(Gesture::Pencil { lane: Some(l), points, .. }) = &self.arrange.gesture
                    && l == id
                {
                    let line: Vec<Pos2> = points.iter().map(|(b, v)| pos2(geo.x(*b), y(*v))).collect();
                    painter.add(polyline(line, t.text, 2.0));
                }
                if hover.is_some_and(|p| rect.contains(p)) {
                    widgets::hint("lane: click adds a point · hold and draw a curve · drag a point to move it · right click a point removes it");
                }
            }
        }
    }

    // ------------------------------------------------------- take lanes

    /// The take lane under the pointer: its track and take.
    fn take_lane_at(&self, geo: &Geo, pos: Pos2) -> Option<(i64, i64)> {
        let row = geo.row_at(pos.y);
        let track = self.s.tracks.get(row)?;
        let base = geo.row_top(row) + track.clip_size * geo.rh;
        let k = ((pos.y - base) / (TAKE_ROW * geo.rh)).floor();
        (k >= 0.0 && (k as usize) < track.take_rows).then_some((track.id, k as i64 + 1))
    }

    /// Take lanes under the clips of their tracks: row k holds take k of
    /// each clip, lit where it is the one that plays.
    fn take_lanes(&mut self, ui: &mut Ui, geo: &Geo) {
        let t = th();
        let lanes = geo.lanes;
        let ctx = ui.ctx().clone();
        let (from, to) = geo.seen();
        let hover = ui.input(|i| i.pointer.hover_pos()).filter(|p| lanes.contains(*p));
        let tracks: Vec<(usize, f32, usize, Color32)> =
            self.s.tracks.iter().enumerate().filter(|(_, t)| t.take_rows > 0).map(|(i, t)| (i, t.clip_size, t.take_rows, t.color)).collect();
        if tracks.is_empty() {
            return;
        }
        let painter = ui.painter().with_clip_rect(lanes);
        for &(row, clip_size, count, _) in &tracks {
            for k in 0..count {
                let top = geo.row_top(row) + (clip_size + k as f32 * TAKE_ROW) * geo.rh;
                let rect = Rect::from_x_y_ranges(lanes.x_range(), top..=(top + TAKE_ROW * geo.rh - 1.0));
                painter.rect_filled(rect, CornerRadius::ZERO, alpha(t.panel, 0.55));
                painter.hline(rect.x_range(), top + 0.5, Stroke::new(1.0, t.divider));
            }
        }
        let clips: Vec<Clip> = self.s.clips.iter().filter(|c| c.take_rows.is_some() && c.start < to + 1.0 && c.start + c.length > from - 1.0).cloned().collect();
        for clip in &clips {
            let Some(&(_, clip_size, _, colour)) = tracks.iter().find(|tr| tr.0 == clip.row) else { continue };
            for (index, (name, key)) in clip.take_rows.as_ref().unwrap().iter().enumerate() {
                let take = index as i64 + 1;
                let active = clip.take == take;
                let top = geo.row_top(clip.row) + (clip_size + index as f32 * TAKE_ROW) * geo.rh + 1.0;
                let rect = Rect::from_min_size(pos2(geo.x(clip.start), top), vec2((clip.length * geo.zoom - 1.0).max(4.0), TAKE_ROW * geo.rh - 3.0));
                painter.rect_filled(rect, CornerRadius::same(2), if active { mix(colour, t.lane, 0.38) } else { t.lane_alt });
                let points = pictures::wave_points(clip.length * geo.zoom);
                let pkey = if clip.midi { key.clone() } else { format!("{key}@{points}") };
                let (id, midi, length) = (clip.id, clip.midi, clip.length);
                let notches: Vec<f32> = clip.notches.iter().map(|b| b / length.max(1e-6)).collect();
                let k = &self.k;
                let texture = self.pictures.get(&ctx, (id, index + 1), &pkey, || {
                    let flat: Vec<f32> = k
                        .borrow_mut()
                        .call("eval", json!(["return daw.frontend.take_preview(...)", id, take, points]))
                        .map(|v| rows(&v).iter().map(number).collect())
                        .unwrap_or_default();
                    let picture = if midi { pictures::notes_picture(&flat, length) } else { pictures::wave_picture(&flat) };
                    picture.map(|p| notched(p, &notches))
                });
                if let Some(texture) = texture {
                    let body = Rect::from_min_max(pos2(rect.left(), rect.top() + 2.0), pos2(rect.right(), rect.bottom() - 2.0));
                    let shown = body.intersect(lanes);
                    if shown.width() > 0.0 {
                        let u0 = (shown.left() - body.left()) / body.width();
                        let u1 = (shown.right() - body.left()) / body.width();
                        let ink = if active { mix(colour, Color32::WHITE, 0.8) } else { alpha(t.text_3, 0.7) };
                        painter.image(texture.id(), Rect::from_x_y_ranges(shown.x_range(), body.y_range()), Rect::from_min_max(pos2(u0, 0.0), pos2(u1, 1.0)), ink);
                    }
                }
                let x = (rect.left() + 4.0).max(lanes.left() + 4.0);
                let font = if active { semi(T_SMALL) } else { sans(T_SMALL) };
                let shown = widgets::elide(ui, name, font.clone(), rect.right() - x - 3.0);
                painter.text(pos2(x, rect.top() + 1.0), Align2::LEFT_TOP, shown, font, if active { t.text } else { t.text_3 });
                if active {
                    painter.rect_stroke(rect, CornerRadius::same(2), Stroke::new(1.0, alpha(colour, 0.8)), StrokeKind::Inside);
                }
            }
        }
        // The stretch being swiped over.
        if let (Some(Gesture::Take { from, .. }), Some(p)) = (&self.arrange.gesture, ui.input(|i| i.pointer.latest_pos()))
            && (p.x - from).abs() > 3.0
            && let Some((track, take)) = self.take_lane_at(geo, p)
        {
            let row = self.s.row_of(track).unwrap_or(0);
            let top = geo.row_top(row) + (self.s.tracks[row].clip_size + (take - 1) as f32 * TAKE_ROW) * geo.rh;
            let r = Rect::from_x_y_ranges(from.min(p.x)..=from.max(p.x), top..=(top + TAKE_ROW * geo.rh - 1.0));
            painter.rect(r, CornerRadius::ZERO, alpha(t.select, 0.3), Stroke::new(1.0, t.select), StrokeKind::Inside);
        }
        if hover.is_some_and(|p| self.take_lane_at(geo, p).is_some()) {
            widgets::hint("take lane: drag across to make this take play there · click chooses it for the piece under the pointer · Shift off the grid · right click for more");
            if ui.input(|i| i.pointer.secondary_released())
                && let Some((track, _)) = hover.and_then(|p| self.take_lane_at(geo, p))
            {
                self.arrange.gesture = None;
                self.open_menu("takes", json!([track]), hover.unwrap());
            }
        }
    }

    // ------------------------------------------------- the selection, Ex

    /// What an Ex line being typed would act on.
    fn ex_marks(&mut self, ui: &mut Ui, geo: &Geo) {
        let t = th();
        let ex = &self.s.modal["ex"];
        if !ex.is_object() {
            return;
        }
        let painter = ui.painter().with_clip_rect(geo.lanes);
        let rows_bottom = geo.row_top(self.s.tracks.len());
        if !ex["from"].is_null() {
            let (a, b) = (number(&ex["from"]), number(&ex["to"]));
            if b > a && a >= 0.0 {
                let r = Rect::from_x_y_ranges(geo.x(a)..=geo.x(b), (geo.lanes.top() - geo.scroll.y)..=rows_bottom);
                painter.rect(r, CornerRadius::ZERO, alpha(t.warn, 0.10), Stroke::new(1.0, alpha(t.warn, 0.5)), StrokeKind::Inside);
            }
        }
        for id in rows(&ex["tracks"]) {
            if let Some(row) = id.as_i64().and_then(|id| self.s.row_of(id)) {
                let top = geo.row_top(row);
                painter.rect_filled(Rect::from_min_size(pos2(geo.lanes.left(), top), vec2(3.0, self.s.tracks[row].size * geo.rh - 1.0)), CornerRadius::ZERO, t.warn);
            }
        }
        let current = ex["current"].as_i64();
        for m in rows(&ex["clips"]) {
            let Some(clip) = m["id"].as_i64().and_then(|id| self.s.clips.iter().find(|c| c.id == id)) else { continue };
            let r = Rect::from_min_size(pos2(geo.x(clip.start), geo.row_top(clip.row)), vec2(clip.length * geo.zoom, 16.0));
            painter.rect_filled(r, CornerRadius::ZERO, if current == Some(clip.id) { alpha(t.select, 0.55) } else { alpha(t.warn, 0.35) });
            let count = int(&m["count"]);
            if flag(&m["notes"]) && count > 0 {
                painter.text(pos2(r.right() - 4.0, r.center().y), Align2::RIGHT_CENTER, count.to_string(), sans(T_MICRO), t.text);
            }
        }
    }

    /// The selected stretch, by a drag here or by visual mode, in rows of
    /// tracks: where it is on the screen.
    fn selection_rect(&self, geo: &Geo) -> Option<Rect> {
        let sel = &self.s.modal["selection"];
        if !sel.is_object() || self.s.focused() != "arrange" || sel["kind"] == "clips" || sel["view"] == "pianoroll" {
            return None;
        }
        let (r0, r1) = (int(&sel["r0"]), int(&sel["r1"]));
        let row = (r0 - 1).max(0) as usize;
        let rows_n = (r1 - r0 + 1).max(1) as usize;
        let (top, bottom) = (geo.row_top(row), geo.row_top(row + rows_n) - 1.0);
        let xs = if sel["kind"] == "line" {
            geo.lanes.x_range()
        } else {
            egui::Rangef::new(geo.x(number(&sel["c0"])), geo.x(number(&sel["c1"])))
        };
        Some(Rect::from_x_y_ranges(xs, top..=bottom))
    }

    fn selection_at(&self, geo: &Geo, pos: Pos2) -> Option<Rect> {
        self.selection_rect(geo).filter(|r| r.contains(pos))
    }

    fn selection(&mut self, ui: &mut Ui, geo: &Geo) {
        let t = th();
        let Some(rect) = self.selection_rect(geo) else { return };
        ui.painter().with_clip_rect(geo.lanes).rect(rect, CornerRadius::ZERO, alpha(t.select, 0.22), Stroke::new(1.0, t.select), StrokeKind::Inside);
        if ui.input(|i| i.pointer.hover_pos()).is_some_and(|p| rect.contains(p) && geo.lanes.contains(p)) {
            widgets::hint("selection: right click to delete, copy, loop or mute it · click to let go · Delete removes it");
        }
    }
}

/// A clip's title bar, when its row has room for one.
pub fn clip_title(height: f32) -> f32 {
    if height + 3.0 >= 40.0 { 16.0 } else { 0.0 }
}

/// Where an audio clip's fades end, on the screen.
fn fade_xs(clip: &Clip, geo: &Geo, rect: Rect) -> (f32, f32) {
    let fi = (rect.left() + clip.fade_in * geo.zoom).clamp(rect.left(), rect.right());
    let fo = (rect.right() - clip.fade_out * geo.zoom).clamp(rect.left(), rect.right());
    (fi, fo)
}
