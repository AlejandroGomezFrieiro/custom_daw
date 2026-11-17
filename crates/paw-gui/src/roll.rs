//! The piano roll: the notes of one MIDI clip (or of several edited
//! together), and under them a strip for how hard each is played or for a
//! controller drawn with a pencil. It is shown in its pane of the main
//! window or in a window of its own.
//!
//! The pointer follows REAPER's MIDI editor: the left button draws, moves
//! and stretches notes, the right button chooses with a box (or removes a
//! note it clicks, or opens the menu on empty grid), Shift leaves the grid,
//! Ctrl copies or toggles, Alt erases. What each gesture means is the
//! kernel's: this only reports them.

use std::collections::{HashMap, HashSet};

use egui::{Align2, Color32, CornerRadius, Id, Pos2, Rect, Sense, Shape, Stroke, StrokeKind, Ui, Vec2, pos2, vec2};
use serde_json::{Value, json};

use crate::app::{State, View};
use crate::icons;
use crate::menu::{Item, choices};
use crate::model::{self, flag, int, number, rows, text};
use crate::theme::{T_SMALL, alpha, colour, mix, mode_colour, sans, semi, th};
use crate::widgets::{self, Look};

const KEYS_W: f32 = 64.0;
const TOOLBAR_H: f32 = 32.0;
const STRIP_H: f32 = 80.0;
const PANEL_W: f32 = 180.0;
const ROW_WHITE: Color32 = Color32::from_rgb(0x23, 0x24, 0x28);
const ROW_BLACK: Color32 = Color32::from_rgb(0x1e, 0x1f, 0x22);
const NAMES: [&str; 12] = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"];
const STRIPS: [&str; 5] = ["Velocity", "Pitch bend", "Modulation", "Expression", "Sustain pedal"];
const STRIPS_SHORT: [&str; 5] = ["Velocity", "Bend", "Mod", "Expr", "Pedal"];
const GRIDS: [(&str, f32); 8] = [("1/1", 4.0), ("1/2", 2.0), ("1/4", 1.0), ("1/8", 0.5), ("1/16", 0.25), ("1/32", 0.125), ("1/8 triplet", 1.0 / 3.0), ("1/16 triplet", 1.0 / 6.0)];

/// A note of the roll, in the roll's beats.
#[derive(Clone, Debug)]
pub struct Note {
    pub pitch: i64,
    pub start: f32,
    pub length: f32,
    pub velocity: f32,
    pub selected: bool,
    pub color: Color32,
}

/// A mark of a layer of the kernel's roll: a box over notes' rows, or a
/// chip with a label that may be clicked.
#[derive(Clone, Debug, PartialEq)]
pub struct Mark {
    pitch: i64,
    start: f32,
    length: f32,
    fill: Color32,
    edge: Option<Color32>,
    ink: Color32,
    label: String,
    badge: bool,
    slot: i64,
    act: String,
    arg: f32,
    tip: String,
}

fn marks(list: &Value, origin: f32) -> Vec<Mark> {
    rows(list)
        .iter()
        .map(|m| {
            let a = m["alpha"].as_f64().unwrap_or(1.0) as f32;
            let badge = flag(&m["badge"]);
            Mark {
                pitch: m["pitch"].as_i64().unwrap_or(60).clamp(0, 127),
                start: number(&m["start"]) - origin,
                length: number(&m["length"]),
                fill: alpha(colour(&m["fill"]), a),
                edge: m["edge"].as_str().and_then(crate::theme::hex),
                // Dark on a strong chip, light on anything fainter.
                ink: if badge && a >= 0.5 { Color32::from_rgb(0x12, 0x13, 0x16) } else { Color32::from_rgb(0xe4, 0xe5, 0xe8) },
                label: text(&m["label"]),
                badge,
                slot: int(&m["slot"]),
                act: text(&m["act"]),
                arg: number(&m["arg"]),
                tip: text(&m["tip"]),
            }
        })
        .collect()
}

/// What a press over the roll took hold of.
#[derive(Clone, Debug)]
enum Grip {
    /// The left button on empty grid: a note being drawn from `at`.
    Draw { at: f32, pitch: i64, from: Pos2 },
    /// A note grabbed by its body, or one of its ends (-1 the start, 1 the end).
    Note { index: usize, end: i8, from: Pos2, toggling: bool },
    /// A box: with the left button and Ctrl, or the right (and the note
    /// it went down on).
    Box { from: Pos2, left: bool, note: Option<usize> },
    Erase { points: Vec<(f32, f32)> },
    Pan { from: Pos2, scroll: Vec2 },
    /// The keyboard: sounding keys, or (right) choosing their notes.
    Keys { held: i64, choose: Option<i64> },
    /// The strip: the pencil, a line (right), a box (Ctrl), the chosen
    /// moves dragged by a handle.
    Pencil { points: Vec<(f32, f32)> },
    Line { from: Pos2 },
    StripBox { from: Pos2 },
    Moves { from: Pos2, toggling: bool },
    /// A scroll bar dragged.
    Bar { across: bool, from: Pos2, scroll: Vec2 },
}

pub struct Roll {
    /// The clip open, and when what it shows has to be fetched again.
    pub open: Option<i64>,
    pub stale: bool,
    revision: i64,
    /// In a window of its own.
    pub detached: bool,
    pub panel: bool,
    pub hint: String,
    // What the kernel says of it: the clip and the notes of the clips
    // edited, their places as the kernel counts them, the track's other
    // notes, the controller moves, the layers.
    title: String,
    track: String,
    color: Color32,
    /// Where the roll's beats start, in the beats of the clip it has open:
    /// before 0 when another clip it edits starts earlier.
    origin: f32,
    /// The song's beat where the roll's start is, and how far the clips
    /// edited reach.
    start: f32,
    length: f32,
    hidden: i64,
    notes: Vec<Note>,
    refs: Vec<(i64, i64)>,
    ghosts: Vec<Note>,
    context: Vec<Mark>,
    controls: Vec<Value>,
    panel_rows: Vec<Value>,
    middle: Option<i64>,
    // What moves with the keyboard: from `modal.roll`.
    pitch: i64,
    cursor: f32,
    step: f32,
    snap: bool,
    chosen_text: String,
    step_input: bool,
    status: String,
    chord: String,
    chords: Vec<(f32, f32, String)>,
    layers: (Vec<Mark>, Vec<Mark>),
    tools: Vec<Value>,
    diagnostics: Vec<(usize, i64, f32, f32, i64)>,
    messages: HashMap<usize, (String, Vec<String>)>,
    controls_chosen: HashSet<i64>,
    chord_keys: [bool; 128],
    // How it is seen.
    pub zoom: f32,
    note_h: f32,
    scroll: Vec2,
    /// What the strip shows: 0 velocity, 1 pitch wheel, 2 modulation, 3
    /// expression, 4 sustain pedal.
    lane: usize,
    grip: Option<Grip>,
    centre_pending: bool,
    revealed: (i64, f32),
    /// While a stroke crosses the velocity strip: what it gives each note.
    vel_preview: Vec<f32>,
    grid_size: Vec2,
}

impl Default for Roll {
    fn default() -> Self {
        Roll {
            open: None,
            stale: false,
            revision: -1,
            detached: false,
            panel: false,
            hint: String::new(),
            title: String::new(),
            track: String::new(),
            color: Color32::from_rgb(0x5f, 0xb5, 0x6a),
            origin: 0.0,
            start: 0.0,
            length: 4.0,
            hidden: 0,
            notes: Vec::new(),
            refs: Vec::new(),
            ghosts: Vec::new(),
            context: Vec::new(),
            controls: Vec::new(),
            panel_rows: Vec::new(),
            middle: None,
            pitch: 60,
            cursor: 0.0,
            step: 0.25,
            snap: true,
            chosen_text: String::new(),
            step_input: false,
            status: String::new(),
            chord: String::new(),
            chords: Vec::new(),
            layers: (Vec::new(), Vec::new()),
            tools: Vec::new(),
            diagnostics: Vec::new(),
            messages: HashMap::new(),
            controls_chosen: HashSet::new(),
            chord_keys: [false; 128],
            zoom: 80.0,
            note_h: 12.0,
            scroll: vec2(0.0, 40.0 * 12.0),
            lane: 0,
            grip: None,
            centre_pending: true,
            revealed: (-1, -1.0),
            vel_preview: Vec::new(),
            grid_size: Vec2::ZERO,
        }
    }
}

/// What the strip under the roll shows, by its number there: the kind of
/// controller and, for a control change, which.
fn strip_kind(lane: usize) -> Option<(&'static str, Option<i64>)> {
    match lane {
        1 => Some(("bend", None)),
        2 => Some(("cc", Some(1))),
        3 => Some(("cc", Some(11))),
        4 => Some(("cc", Some(64))),
        _ => None,
    }
}

fn is_black(pitch: i64) -> bool {
    matches!(pitch.rem_euclid(12), 1 | 3 | 6 | 8 | 10)
}

fn pitch_name(pitch: i64) -> String {
    format!("{}{}", NAMES[pitch.rem_euclid(12) as usize], pitch.div_euclid(12) - 1)
}

/// A length as a part of a whole note when it is a number of 64ths.
fn length_name(beats: f32) -> String {
    if (beats * 16.0 - (beats * 16.0).round()).abs() > 0.02 {
        return format!("{} beats", (beats * 100.0).round() / 100.0);
    }
    let n = (beats * 16.0).round() as i64;
    if n <= 0 {
        return "0".into();
    }
    let common = [64, 32, 16, 8, 4, 2, 1].into_iter().find(|c| n % c == 0).unwrap_or(1);
    format!("{}/{}", n / common, 64 / common)
}

fn grid_name(grid: f32) -> String {
    if (grid * 3.0 - (grid * 3.0).round()).abs() < 0.001 && (grid * 16.0 - (grid * 16.0).round()).abs() > 0.001 {
        format!("{}T", length_name(grid * 3.0 / 2.0))
    } else {
        length_name(grid)
    }
}

fn severity_colour(severity: i64) -> Color32 {
    match severity {
        1 => Color32::from_rgb(0xef, 0x5b, 0x5b),
        2 => Color32::from_rgb(0xe8, 0xa3, 0x3d),
        3 => Color32::from_rgb(0x6a, 0xa9, 0xe9),
        _ => Color32::from_rgb(0x8a, 0x91, 0xa3),
    }
}

/// How the roll is seen, for one gesture: what it takes to turn the
/// pointer's place into beats and pitches.
#[derive(Clone, Copy)]
struct Lens {
    zoom: f32,
    note_h: f32,
    scroll: Vec2,
    lane: usize,
}

impl Lens {
    fn beat(&self, grid: Rect, x: f32) -> f32 {
        (x - grid.left() + self.scroll.x) / self.zoom
    }
    fn pitch_at(&self, grid: Rect, y: f32) -> i64 {
        127 - ((y - grid.top() + self.scroll.y) / self.note_h).floor() as i64
    }
}

impl Roll {
    /// How far the grid is scrolled.
    #[cfg(test)]
    pub fn scrolled(&self) -> Vec2 {
        self.scroll
    }

    fn lens(&self) -> Lens {
        Lens { zoom: self.zoom, note_h: self.note_h, scroll: self.scroll, lane: self.lane }
    }

    /// What the keyboard's state says of the roll: which clip is open, the
    /// cursor, the chosen notes, the layers.
    pub fn modal(&mut self, _s: &State, modal: &Value) {
        let roll = &modal["roll"];
        let open = roll["clip"].as_i64();
        if open != self.open {
            self.open = open;
            self.stale = true;
            self.centre_pending = true;
            self.grip = None;
            if open.is_none() {
                self.detached = false;
            }
        }
        if open.is_none() {
            return;
        }
        let revision = int(&roll["revision"]);
        if revision != self.revision {
            self.revision = revision;
            self.stale = true;
        }
        // Which notes are chosen with the pointer, in any clip edited.
        let chosen: HashSet<(i64, i64)> = rows(&roll["refs"]).iter().filter_map(|r| Some((r[0].as_i64()?, r[1].as_i64()?))).collect();
        for (note, r) in self.notes.iter_mut().zip(&self.refs) {
            note.selected = chosen.contains(r);
        }
        self.layers = (marks(&roll["under"], self.origin), marks(&roll["over"], self.origin));
        self.tools = rows(&roll["tools"]).to_vec();
        self.controls_chosen = rows(&roll["controls_chosen"]).iter().filter_map(Value::as_i64).collect();
        self.chords = rows(&roll["chords"]).iter().map(|c| (number(&c["start"]) - self.origin, number(&c["length"]), text(&c["label"]))).collect();
        self.chord_keys = [false; 128];
        for pitch in rows(&roll["sounding"]).iter().filter_map(Value::as_i64) {
            self.chord_keys[pitch.clamp(0, 127) as usize] = true;
        }
        self.pitch = roll["pitch"].as_i64().unwrap_or(60);
        self.cursor = number(&roll["beat"]) - self.origin;
        self.chord = text(&roll["chord"]);
        self.step = number(&roll["step"]);
        // What insert mode is doing, as the kernel words it.
        self.status = if modal["mode"] == "i" { text(&roll["insert"]) } else { String::new() };
        self.snap = roll["snap"].as_bool().unwrap_or(true);
        self.chosen_text = text(&roll["chosen"]);
        self.step_input = flag(&roll["step_input"]);
        // The notes diagnostics are about, by their place in the roll.
        self.diagnostics.clear();
        self.messages.clear();
        for mark in rows(&roll["marks"]) {
            let Some(index) = mark["index"].as_i64().and_then(|i| (i - self.hidden).try_into().ok()) else { continue };
            self.diagnostics.push((index, mark["pitch"].as_i64().unwrap_or(60), number(&mark["start"]) - self.origin, number(&mark["length"]), mark["severity"].as_i64().unwrap_or(2)));
            self.messages.insert(index, (text(&mark["message"]), rows(&mark["actions"]).iter().map(text).collect()));
        }
    }

    /// Take in the clip the roll has open (`paw.frontend.clip`).
    fn clip(&mut self, clip: &Value, id: i64, bar: f32) {
        self.hidden = int(&clip["hidden"]);
        // Other clips it edits may start before it: the roll's beats then
        // start where the first does.
        let origin = rows(&clip["editable"]).iter().map(|c| number(&c["offset"])).fold(0.0, f32::min);
        let own = colour(&clip["color"]);
        let was: HashSet<(i64, i64)> = self.notes.iter().zip(&self.refs).filter(|(n, _)| n.selected).map(|(_, r)| *r).collect();
        let mut refs: Vec<(i64, i64)> = (0..rows(&clip["notes"]).len() as i64).map(|i| (id, i + 1 + self.hidden)).collect();
        for n in rows(&clip["more"]) {
            refs.push((int(&n["clip"]), n["place"].as_i64().unwrap_or(1)));
        }
        let note = |n: &Value| Note {
            pitch: n["pitch"].as_i64().unwrap_or(60),
            start: number(&n["start"]) - origin,
            length: number(&n["length"]),
            velocity: (number(&n["velocity"]) / 127.0).clamp(0.0, 1.0),
            selected: false,
            color: n["color"].as_str().and_then(crate::theme::hex).unwrap_or(own),
        };
        self.notes = rows(&clip["notes"]).iter().chain(rows(&clip["more"])).map(note).collect();
        for (n, r) in self.notes.iter_mut().zip(&refs) {
            n.selected = was.contains(r);
        }
        self.refs = refs;
        self.ghosts = rows(&clip["ghosts"]).iter().map(note).collect();
        self.context = marks(&clip["context"], origin);
        self.controls = rows(&clip["controls"]).to_vec();
        self.panel_rows = rows(&clip["rows"]).to_vec();
        // How far the clips edited reach, from the origin.
        self.length = rows(&clip["editable"]).iter().map(|c| number(&c["offset"]) + number(&c["length"])).fold(number(&clip["length"]), f32::max) - origin;
        self.origin = origin;
        self.start = number(&clip["start"]) + origin;
        self.color = own;
        self.title = text(&clip["name"]);
        let editing = rows(&clip["editable"]).len();
        self.track = format!(
            "{} · bar {}{}",
            text(&clip["track_name"]),
            1 + (number(&clip["start"]) / bar.max(0.25)) as i64,
            if editing > 1 { format!(" · {editing} clips edited") } else { String::new() }
        );
        // The middle of the clip's notes, where the roll opens.
        self.middle = self.notes.iter().map(|n| (n.pitch, n.pitch)).reduce(|(lo, hi), (a, b)| (lo.min(a), hi.max(b))).map(|(lo, hi)| (lo + hi) / 2);
        self.vel_preview.clear();
    }

    /// The controller moves of the kind the strip shows: (beat, value 0..1
    /// up the strip, place among all the clip's moves, chosen).
    fn strip_moves(&self) -> Vec<(f32, f32, i64, bool)> {
        let Some((kind, number)) = strip_kind(self.lane) else { return Vec::new() };
        self.controls
            .iter()
            .filter(|c| c["type"] == kind && c["key"].is_null())
            .filter(|c| number.is_none() || c["number"].as_i64() == number)
            .map(|c| {
                let v = model::number(&c["value"]);
                let place = c["place"].as_i64().unwrap_or(0);
                (model::number(&c["start"]) - self.origin, if kind == "bend" { (v + 1.0) / 2.0 } else { v }, place, self.controls_chosen.contains(&place))
            })
            .collect()
    }

    fn x(&self, grid: Rect, beat: f32) -> f32 {
        grid.left() + beat * self.zoom - self.scroll.x
    }
    fn y(&self, grid: Rect, pitch: i64) -> f32 {
        grid.top() + (127 - pitch) as f32 * self.note_h - self.scroll.y
    }
    fn beat(&self, grid: Rect, x: f32) -> f32 {
        (x - grid.left() + self.scroll.x) / self.zoom
    }
    fn pitch_at(&self, grid: Rect, y: f32) -> i64 {
        127 - ((y - grid.top() + self.scroll.y) / self.note_h).floor() as i64
    }

    /// Scroll, kept within what there is.
    fn scroll_to(&mut self, to: Vec2) {
        let content = vec2(self.grid_size.x.max((self.length + 4.0) * self.zoom), 128.0 * self.note_h);
        self.scroll = to.clamp(Vec2::ZERO, (content - self.grid_size).max(Vec2::ZERO));
    }

    /// Bring the kernel's cursor into view: the least scrolling that shows
    /// it with a row or two to spare, or with `centre` the cursor in the
    /// middle, as the terminal does when it opens a clip.
    fn reveal(&mut self, centre: bool, bar: f32) {
        let size = self.grid_size;
        if size.y < 8.0 * self.note_h || size.x <= 0.0 {
            return;
        }
        self.centre_pending = false;
        if centre {
            // Opened: no wider than the clip and a bar, on its notes.
            self.zoom = self.zoom.max(size.x / (self.length + bar).max(1.0)).clamp(8.0, 640.0);
        }
        let cy = (127 - if centre { self.middle.unwrap_or(self.pitch) } else { self.pitch }) as f32 * self.note_h;
        let cx = self.cursor * self.zoom;
        let margin = (2.0 * self.note_h).min(size.y / 4.0);
        let above = cy - margin < self.scroll.y;
        let below = cy + self.note_h + margin > self.scroll.y + size.y;
        let aside = cx < self.scroll.x || cx + self.zoom > self.scroll.x + size.x;
        let x = if centre && cx < size.x * 0.8 {
            0.0
        } else if centre || aside {
            cx - if centre { size.x / 2.0 } else { size.x / 3.0 }
        } else {
            self.scroll.x
        };
        let y = if centre {
            cy + self.note_h / 2.0 - size.y / 2.0
        } else if above {
            cy - margin
        } else if below {
            cy + self.note_h + margin - size.y
        } else {
            self.scroll.y
        };
        self.scroll_to(vec2(x, y));
    }

    fn snapped(&self, beat: f32, free: bool, grid: f32) -> f32 {
        if free || !self.snap { beat.max(0.0) } else { ((beat / grid).round() * grid).max(0.0) }
    }

    fn place(&self, lines: &[model::Line], at: f32) -> String {
        model::place_of(lines, self.start + at)
    }

    fn describe(&self, lines: &[model::Line], pitch: i64, at: f32, beats: f32) -> String {
        format!("{}  ·  {}  ·  {}", pitch_name(pitch), self.place(lines, at), length_name(beats))
    }
}

impl View {
    /// A gesture of the roll, passed on with the clip first. A note is named
    /// by its clip, which the roll may edit with others, and its place
    /// there; beats are the roll's, which start at its origin.
    fn roll_pass(&self, name: &str, args: Value) {
        let Some(id) = self.roll.open else { return };
        let mut all = vec![json!(id)];
        let mut args = args.as_array().cloned().unwrap_or_default();
        if matches!(name, "drag_notes" | "stretch_notes" | "select_note" | "remove_note" | "set_velocity" | "note_action" | "note_hover")
            && let Some(index) = args.first().and_then(Value::as_i64)
            && let Some(&(clip, place)) = self.roll.refs.get((index - 1).max(0) as usize)
        {
            all[0] = json!(clip);
            args[0] = json!(place);
        }
        let origin = self.roll.origin as f64;
        if origin != 0.0 {
            let shift = |v: &mut Value| {
                if let Some(beat) = v.as_f64() {
                    *v = json!(beat + origin);
                }
            };
            let at: &[usize] = match name {
                "add_note" => &[1],
                "select_notes_box" => &[0, 2],
                "roll_seek" | "context_click" => &[0],
                "select_controls" | "line_controls" => &[2, 4],
                _ => &[],
            };
            for &i in at {
                if let Some(v) = args.get_mut(i) {
                    shift(v);
                }
            }
            let stroke = match name {
                "erase_notes" | "draw_velocities" => Some(0),
                "draw_controls" => Some(2),
                _ => None,
            };
            if let Some(points) = stroke.and_then(|i| args.get_mut(i)).and_then(Value::as_array_mut) {
                for point in points {
                    if let Some(first) = point.get_mut(0) {
                        shift(first);
                    }
                }
            }
        }
        all.extend(args);
        self.pass(name, Value::Array(all));
    }

    /// A gesture on the strip's moves: the kind it shows goes with it.
    fn strip_pass(&self, name: &str, args: Value) {
        let Some((kind, number)) = strip_kind(self.roll.lane) else { return };
        let mut all = vec![json!(kind), json!(number)];
        all.extend(args.as_array().cloned().unwrap_or_default());
        self.roll_pass(name, Value::Array(all));
    }

    /// What an entry of the roll's own menus does.
    pub fn roll_choice(&mut self, name: &str, at: usize) {
        match name {
            "roll-grid" => {
                if let Some((_, value)) = GRIDS.get(at) {
                    self.eval("paw.opt.note_grid = ...", json!([value]));
                }
            }
            "roll-length" => {
                let value = if at == 0 { 0.0 } else { GRIDS.get(at - 1).map_or(0.0, |g| g.1) };
                self.roll_pass("set_note_length", json!([value]));
            }
            "roll-strip" => {
                self.roll.lane = at.min(4);
            }
            _ => {}
        }
    }

    /// The roll's clip fetched again when it or what it shows changed.
    fn roll_fetch(&mut self) {
        let Some(id) = self.roll.open else { return };
        if !std::mem::take(&mut self.roll.stale) {
            return;
        }
        let clip = self.ask("return paw.frontend.clip(...)", json!([id]));
        if clip.is_null() || clip["kind"] != "midi" {
            return;
        }
        let bar = self.s.bar();
        self.roll.clip(&clip, id, bar);
    }

    /// The piano roll in `rect`: its pane, or its own window.
    pub fn draw_roll(&mut self, ui: &mut Ui, rect: Rect, window: bool) {
        let t = th();
        if self.roll.open.is_none() {
            ui.painter().rect_filled(rect, CornerRadius::ZERO, t.panel);
            return;
        }
        if self.roll.detached && !window {
            ui.painter().rect_filled(rect, CornerRadius::ZERO, t.panel);
            ui.painter().text(rect.center(), Align2::CENTER_CENTER, "The piano roll is in a window of its own", sans(T_SMALL), t.text_3);
            return;
        }
        self.roll_fetch();
        ui.painter().rect_filled(rect, CornerRadius::ZERO, t.panel);
        let chord_h = if self.roll.chords.is_empty() { 0.0 } else { 16.0 };
        let ruler_h = 22.0 + chord_h;
        let toolbar = Rect::from_min_size(rect.min, vec2(rect.width(), TOOLBAR_H));
        let body = Rect::from_min_max(pos2(rect.left(), toolbar.bottom()), rect.max);
        let panel_w = if self.roll.panel { PANEL_W } else { 0.0 };
        let grid = Rect::from_min_max(pos2(body.left() + KEYS_W, body.top() + ruler_h), pos2(body.right() - panel_w, body.bottom() - STRIP_H));
        let ruler = Rect::from_min_max(pos2(grid.left(), body.top()), pos2(grid.right(), body.top() + ruler_h));
        let keys = Rect::from_min_max(pos2(body.left(), grid.top()), pos2(grid.left(), grid.bottom()));
        let strip = Rect::from_min_max(pos2(body.left(), grid.bottom()), pos2(grid.right(), body.bottom()));
        self.roll.grid_size = grid.size();
        // The cursor moves, or a clip opens: keep it in view.
        let bar = self.s.bar();
        if self.roll.centre_pending {
            self.roll.reveal(true, bar);
            self.roll.revealed = (self.roll.pitch, self.roll.cursor);
        } else if (self.roll.pitch, self.roll.cursor) != self.roll.revealed {
            self.roll.revealed = (self.roll.pitch, self.roll.cursor);
            self.roll.reveal(false, bar);
        }
        let hover = ui.input(|i| i.pointer.hover_pos()).filter(|p| rect.contains(*p));
        let mut child = ui.new_child(egui::UiBuilder::new().max_rect(rect).id_salt(("roll", window)));
        child.set_clip_rect(rect.intersect(ui.clip_rect()));
        let ui = &mut child;
        self.roll_grid(ui, grid, hover);
        self.roll_ruler(ui, ruler, chord_h);
        self.roll_keys(ui, keys, grid, hover);
        self.roll_strip(ui, strip, grid);
        if self.roll.panel {
            self.roll_panel(ui, Rect::from_min_max(pos2(grid.right(), body.top()), body.max));
        }
        self.roll_toolbar(ui, toolbar, window);
        self.roll_gestures(ui, grid, keys, strip);
        self.roll_wheel(ui, grid, keys);
    }

    fn roll_toolbar(&mut self, ui: &mut Ui, bar: Rect, window: bool) {
        let t = th();
        let r = &self.roll;
        let p = ui.painter().clone();
        p.hline(bar.x_range(), bar.bottom() - 0.5, Stroke::new(1.0, t.divider));
        let (top, h) = (bar.top() + 4.0, 23.0);
        let mut x = bar.left() + 8.0;
        // The clip, in its track's colour.
        let title = if r.title.is_empty() { "clip".to_string() } else { r.title.clone() };
        let w = (widgets::text_width(ui, &title, semi(T_SMALL)) + 16.0).min(160.0);
        p.rect_filled(Rect::from_min_size(pos2(x, top), vec2(w, h)), CornerRadius::same(3), r.color);
        widgets::text_in(ui, pos2(x + 8.0, top + h / 2.0), &title, semi(T_SMALL), t.on_hue, w - 16.0);
        x += w + 4.0;
        let track_w = widgets::text_width(ui, &r.track, sans(T_SMALL));
        p.text(pos2(x, top + h / 2.0), Align2::LEFT_CENTER, &r.track, sans(T_SMALL), t.text_2);
        x += track_w + 10.0;
        if !r.chord.is_empty() {
            p.text(pos2(x, top + h / 2.0), Align2::LEFT_CENTER, &r.chord, semi(T_SMALL), t.text);
            x += widgets::text_width(ui, &r.chord, semi(T_SMALL)) + 4.0;
        }
        // From the right.
        let mut right = bar.right() - 6.0;
        let tool = |ui: &mut Ui, right: &mut f32, shape: Option<icons::Icon>, label: &str, on: bool, tip: &str, key: &str| -> bool {
            let w = if label.is_empty() { 24.0 } else { widgets::text_width(ui, label, sans(T_SMALL)) + if shape.is_some() { 32.0 } else { 14.0 } };
            let rect = Rect::from_min_size(pos2(*right - w, top), vec2(w, 24.0));
            *right -= w + 4.0;
            let response = widgets::button(ui, rect, Id::unique(("roll-tool", key, window)), shape, label, Look::quiet().on(on));
            if !tip.is_empty() && response.hovered() {
                widgets::hint(tip);
            }
            response.clicked()
        };
        if tool(ui, &mut right, Some(icons::X), "", false, "close the piano roll", "close") {
            self.pass("close_roll", json!([]));
        }
        let detach_tip = if self.roll.detached { "put the piano roll back in the main window" } else { "give the piano roll a window of its own" };
        if tool(ui, &mut right, Some(icons::ARROW_SQUARE_OUT), "", self.roll.detached, detach_tip, "detach") {
            self.roll.detached = !self.roll.detached;
        }
        if tool(ui, &mut right, Some(icons::PH_PLUS), "", false, "zoom in in time", "zoom-in") {
            self.roll.zoom = (self.roll.zoom * 1.3).min(640.0);
        }
        if tool(ui, &mut right, Some(icons::PH_MINUS), "", false, "zoom out in time (Ctrl and the wheel zoom where the pointer is)", "zoom-out") {
            self.roll.zoom = (self.roll.zoom / 1.3).max(8.0);
        }
        right -= 4.0;
        for (i, tl) in self.roll.tools.clone().iter().enumerate().rev() {
            if tool(ui, &mut right, None, &text(&tl["label"]), flag(&tl["on"]), &text(&tl["tip"]), &format!("layer{i}")) {
                self.roll_pass(&text(&tl["act"]), json!([]));
            }
        }
        if tool(ui, &mut right, None, "List", false, "the event list: every note and controller move of the clip, a row each, changed in place (also E)", "list") {
            self.roll_pass("open_event_list", json!([]));
        }
        if tool(ui, &mut right, Some(icons::KEYBOARD), "Step", self.roll.step_input, "step input: with the transport stopped, notes played on a MIDI keyboard are entered at the cursor, which then steps on (also :notes.step_input)", "step") {
            self.roll_pass("toggle_step_input", json!([]));
        }
        if tool(ui, &mut right, None, "Quantize", false, "quantize: the chosen notes, or all of them, start on the grid (also :notes.quantize)", "quantize") {
            self.roll_pass("quantize_notes", json!([]));
        }
        // The note length a click gives, and the grid.
        let grid_value = number(&self.s.project["note_grid"]).max(1.0 / 64.0);
        let drops: [(&str, String, &str, &str); 2] = [
            ("Note", length_name(self.roll.step), "roll-length", "the length a click gives a note, and that step input enters; drawing a note sets it"),
            ("Grid", grid_name(grid_value), "roll-grid", "the grid notes snap to and the lines it draws (also :grid)"),
        ];
        let mut magnet_at = 0.0;
        for (n, (label, value, name, tip)) in drops.into_iter().enumerate() {
            let w = widgets::text_width(ui, label, sans(T_SMALL)) + 5.0 + widgets::text_width(ui, &value, sans(T_SMALL)) + 30.0;
            let rect = Rect::from_min_size(pos2(right - w, top), vec2(w, 24.0));
            right -= w + 4.0;
            let response = ui.interact(rect, Id::unique(("roll-drop", name, window)), Sense::click());
            p.rect_filled(rect, CornerRadius::same(4), if response.hovered() { t.control_hover } else { t.control });
            p.text(pos2(rect.left() + 8.0, rect.center().y), Align2::LEFT_CENTER, label, sans(T_SMALL), t.text_3);
            p.text(pos2(rect.left() + 13.0 + widgets::text_width(ui, label, sans(T_SMALL)), rect.center().y), Align2::LEFT_CENTER, &value, sans(T_SMALL), t.text);
            p.add(Shape::convex_polygon(vec![pos2(rect.right() - 13.0, rect.center().y - 1.5), pos2(rect.right() - 7.0, rect.center().y - 1.5), pos2(rect.right() - 10.0, rect.center().y + 2.0)], t.text_2, Stroke::NONE));
            widgets::hint_on(&response, tip);
            if response.clicked() {
                let items: Vec<Item> = if name == "roll-grid" {
                    GRIDS.iter().map(|(n, v)| Item::new(*n).checked((grid_value - v).abs() < 0.001)).collect()
                } else {
                    let mut items = vec![Item::new("Grid")];
                    items.extend(GRIDS[..6].iter().map(|(n, v)| Item::new(*n).checked((self.roll.step - v).abs() < 0.001)));
                    items
                };
                self.open_local_menu(name, items, rect.left_bottom() + vec2(0.0, 2.0));
            }
            if n == 0 {
                magnet_at = right;
                right -= 28.0;
            }
        }
        // The magnet, between the two.
        let magnet = Rect::from_min_size(pos2(magnet_at - 24.0, top), vec2(24.0, 24.0));
        let response = widgets::button(ui, magnet, Id::unique(("roll-snap", window)), Some(icons::MAGNET), "", Look::quiet().on(self.roll.snap));
        widgets::hint_on(&response, "snap to the grid: notes land on it (Shift while dragging leaves it)");
        if response.clicked() {
            self.roll_pass("toggle_note_snap", json!([]));
        }
        let mut right2 = right;
        if tool(ui, &mut right2, Some(icons::PIANO_KEYS), "Tracks", self.roll.panel, "the tracks whose notes show behind these, and the clips edited together (also :roll.tracks)", "tracks") {
            self.roll.panel = !self.roll.panel;
        }
        let (said, ink) = if !self.roll.status.is_empty() { (self.roll.status.clone(), t.play_on) } else { (self.roll.chosen_text.clone(), t.text_2) };
        widgets::text_in(ui, pos2(x, top + h / 2.0), &said, sans(T_SMALL), ink, (right2 - x - 4.0).max(0.0));
    }

    fn roll_ruler(&mut self, ui: &mut Ui, ruler: Rect, chord_h: f32) {
        let t = th();
        let r = &self.roll;
        let p = ui.painter().with_clip_rect(ruler);
        p.rect_filled(ruler.expand2(vec2(KEYS_W, 0.0)), CornerRadius::ZERO, t.panel);
        // The chords that sound, over every pitched track.
        for (start, length, label) in &r.chords {
            let (x0, x1) = (r.x(ruler, *start), r.x(ruler, start + length));
            if x1 < ruler.left() || x0 > ruler.right() {
                continue;
            }
            p.vline(x0.round() + 0.5, (ruler.top() + 2.0)..=(ruler.top() + chord_h), Stroke::new(1.0, t.text_3));
            p.with_clip_rect(Rect::from_x_y_ranges(x0..=x1, ruler.y_range()).intersect(ruler)).text(pos2(x0 + 4.0, ruler.top() + 1.0), Align2::LEFT_TOP, label, semi(T_SMALL), t.text);
        }
        // Bars and beats of the song, as the tempo map lays them over the clip.
        let (from, to) = (r.start + r.beat(ruler, ruler.left()) - 1.0, r.start + r.beat(ruler, ruler.right()) + 1.0);
        for line in model::lines_in_view(&self.s.lines, from, to, r.zoom) {
            let at = line.beat - r.start;
            let x = r.x(ruler, at).round() + 0.5;
            let bar = !line.label.is_empty();
            p.vline(x, if bar { ruler.y_range() } else { egui::Rangef::new(ruler.bottom() - 6.0, ruler.bottom()) }, Stroke::new(1.0, if bar { t.line_bar } else { t.text_3 }));
            if bar || r.zoom > 48.0 {
                let label = if bar { line.label.clone() } else { line.place.clone() };
                p.text(pos2(x + 4.0, ruler.top() + chord_h + 3.0), Align2::LEFT_TOP, label, if bar { semi(T_SMALL) } else { sans(T_SMALL) }, if bar { t.text_2 } else { t.text_3 });
            }
        }
        // Grid steps between the beats, when there is room.
        let grid = number(&self.s.project["note_grid"]).max(1.0 / 64.0);
        if grid * r.zoom >= 10.0 && grid < 1.0 {
            let first = (r.scroll.x / (grid * r.zoom)).floor() as i64;
            let n = (ruler.width() / (grid * r.zoom)).ceil() as i64 + 1;
            for i in 0..n {
                let x = r.x(ruler, (first + i) as f32 * grid);
                p.vline(x.round() + 0.5, (ruler.bottom() - 3.0)..=ruler.bottom(), Stroke::new(1.0, t.text_off));
            }
        }
        // The end of the clip.
        let end = r.x(ruler, r.length);
        if end < ruler.right() {
            p.rect_filled(Rect::from_x_y_ranges(end..=ruler.right(), ruler.y_range()), CornerRadius::ZERO, Color32::from_black_alpha(0x66));
        }
        for (_, _, start, _, severity) in &r.diagnostics {
            p.rect_filled(Rect::from_min_size(pos2(r.x(ruler, *start), ruler.bottom() - 8.0), vec2(3.0, 8.0)), CornerRadius::ZERO, severity_colour(*severity));
        }
        // The playhead, with its cap.
        let pos = self.s.position - r.start;
        if pos >= 0.0 && pos <= r.length {
            let x = r.x(ruler, pos);
            p.add(Shape::convex_polygon(vec![pos2(x - 4.5, ruler.bottom() - 6.0), pos2(x + 4.5, ruler.bottom() - 6.0), pos2(x, ruler.bottom())], t.play, Stroke::NONE));
        }
        p.hline(ruler.expand2(vec2(KEYS_W, 0.0)).x_range(), ruler.bottom() - 0.5, Stroke::new(1.0, t.divider));
        let response = ui.interact(ruler, Id::unique("roll-ruler"), Sense::click());
        if response.hovered() {
            self.roll.hint = "ruler: click to put the playhead there".into();
        }
        if let Some(p) = widgets::pressed_on(ui, &response, egui::PointerButton::Primary) {
            let beat = self.roll.beat(ruler, p.x);
            self.roll_pass("roll_seek", json!([beat]));
        }
    }

    /// The keyboard, scrolling with the notes. A click or a drag sounds the
    /// keys; a drag with the right button chooses their notes.
    fn roll_keys(&mut self, ui: &mut Ui, keys: Rect, grid: Rect, hover: Option<Pos2>) {
        let t = th();
        let r = &self.roll;
        let p = ui.painter().with_clip_rect(keys);
        p.rect_filled(keys, CornerRadius::ZERO, t.key_white);
        let hover_pitch = hover.filter(|h| h.y >= grid.top() && h.y < grid.bottom() && h.x < grid.right()).map(|h| r.pitch_at(grid, h.y));
        let held = match &r.grip {
            Some(Grip::Keys { held, choose: None }) => *held,
            _ => -1,
        };
        let sounding = self.sounding_now();
        let (top, bottom) = (r.pitch_at(grid, grid.bottom()).max(0), r.pitch_at(grid, grid.top()).min(127));
        for pitch in top..=bottom {
            let y = r.y(grid, pitch);
            let row = Rect::from_min_size(pos2(keys.left(), y), vec2(keys.width(), r.note_h));
            let lit = sounding[pitch as usize] || held == pitch;
            if !is_black(pitch) && (lit || hover_pitch == Some(pitch)) {
                p.rect_filled(row, CornerRadius::ZERO, if lit { t.select } else { Color32::from_rgb(0xc5, 0xe6, 0xff) });
            }
            // Lines between white keys: where E meets F and B meets C, and
            // in the middle of a black key.
            if pitch.rem_euclid(12) == 0 || pitch.rem_euclid(12) == 5 {
                p.hline(row.x_range(), row.bottom() - 0.5, Stroke::new(1.0, t.key_line));
            }
            if is_black(pitch) {
                p.hline(row.x_range(), row.center().y, Stroke::new(1.0, t.key_line));
                let face = if lit { t.select } else if hover_pitch == Some(pitch) { Color32::from_rgb(0x3a, 0x3c, 0x42) } else { t.key_black };
                p.rect_filled(Rect::from_min_size(row.min, vec2(keys.width() * 0.6, r.note_h)), CornerRadius::ZERO, face);
            }
            let dot = r.chord_keys[pitch as usize];
            if pitch.rem_euclid(12) == 0 && r.note_h >= 8.0 {
                let size = (r.note_h - 1.0).min(10.0);
                p.text(pos2(row.right() - if dot { 14.0 } else { 5.0 }, row.center().y), Align2::RIGHT_CENTER, format!("C{}", pitch / 12 - 1), semi(size), t.text_off);
            }
            // The keys sounding at the cursor: the chord there.
            if dot {
                let d = (r.note_h - 3.0).min(7.0);
                p.circle_filled(pos2(row.right() - 10.0 + d / 2.0, row.center().y), d / 2.0, mode_colour("i"));
            }
        }
        p.vline(keys.right() - 0.5, keys.y_range(), Stroke::new(1.0, t.divider));
        // The range a right drag is choosing.
        if let (Some(Grip::Keys { choose: Some(from), .. }), Some(h)) = (&r.grip, ui.input(|i| i.pointer.latest_pos())) {
            let under = r.pitch_at(grid, h.y).clamp(0, 127);
            let (lo, hi) = ((*from).min(under), (*from).max(under));
            let rect = Rect::from_min_max(pos2(keys.left(), r.y(grid, hi)), pos2(keys.right(), r.y(grid, lo) + r.note_h));
            p.rect(rect, CornerRadius::ZERO, alpha(t.select, 0.15), Stroke::new(1.0, t.select), StrokeKind::Inside);
        }
    }

    /// Which keys sound at the playhead, while it plays.
    fn sounding_now(&self) -> [bool; 128] {
        let mut lit = [false; 128];
        if self.s.playing {
            let at = self.s.position - self.roll.start;
            for n in &self.roll.notes {
                if n.start <= at && at < n.start + n.length {
                    lit[n.pitch.clamp(0, 127) as usize] = true;
                }
            }
        }
        lit
    }

    fn roll_grid(&mut self, ui: &mut Ui, grid: Rect, hover: Option<Pos2>) {
        let t = th();
        let r = &self.roll;
        let p = ui.painter().with_clip_rect(grid);
        let (from, to) = (r.beat(grid, grid.left()) - 1.0, r.beat(grid, grid.right()) + 1.0);
        // Rows: white keys and black keys, a line between octaves, and a
        // faint light on the row under the pointer.
        let hover_pitch = hover.filter(|h| grid.contains(*h)).map(|h| r.pitch_at(grid, h.y));
        let (low, high) = (r.pitch_at(grid, grid.bottom()).max(0), r.pitch_at(grid, grid.top()).min(127));
        for pitch in low..=high {
            let row = Rect::from_min_size(pos2(grid.left(), r.y(grid, pitch)), vec2(grid.width(), r.note_h));
            p.rect_filled(row, CornerRadius::ZERO, if is_black(pitch) { ROW_BLACK } else { ROW_WHITE });
            if pitch.rem_euclid(12) == 0 || pitch.rem_euclid(12) == 5 {
                p.hline(row.x_range(), row.bottom() - 0.5, Stroke::new(1.0, if pitch.rem_euclid(12) == 0 { t.line_beat } else { t.line_sub }));
            }
            if hover_pitch == Some(pitch) {
                p.rect_filled(row, CornerRadius::ZERO, Color32::from_white_alpha(0x08));
            }
        }
        // Grid steps when there is room, then beats, then bars.
        let step = number(&self.s.project["note_grid"]).max(1.0 / 64.0);
        if step * r.zoom >= 10.0 && step < 1.0 {
            let first = (r.scroll.x / (step * r.zoom)).floor() as i64;
            for i in 0..((grid.width() / (step * r.zoom)).ceil() as i64 + 1) {
                p.vline(r.x(grid, (first + i) as f32 * step).round() + 0.5, grid.y_range(), Stroke::new(1.0, t.line_sub));
            }
        }
        for line in model::lines_in_view(&self.s.lines, r.start + from, r.start + to, r.zoom) {
            let bar = !line.label.is_empty();
            p.vline(r.x(grid, line.beat - r.start).round() + 0.5, grid.y_range(), Stroke::new(1.0, if bar { t.line_bar } else { t.line_beat }));
        }
        let note_rect = |start: f32, length: f32, pitch: i64| {
            Rect::from_min_size(pos2(r.x(grid, start), r.y(grid, pitch)), vec2((length * r.zoom - 1.0).max(3.0), r.note_h - 1.0))
        };
        let visible = |start: f32, length: f32, pitch: i64| start <= to && start + length >= from && pitch >= low - 1 && pitch <= high + 1;
        // Notes of the track's other clips, faint, behind these.
        for g in &r.ghosts {
            if visible(g.start, g.length, g.pitch) {
                let rect = note_rect(g.start, g.length, g.pitch).shrink2(vec2(0.0, 0.5)).translate(vec2(0.0, 0.5));
                p.rect(rect, CornerRadius::same(2), alpha(r.color, 0.10), Stroke::new(1.0, alpha(r.color, 0.28)), StrokeKind::Inside);
            }
        }
        // Other tracks' notes and the kernel's layers behind the notes.
        let mut chips = Vec::new();
        for m in r.context.iter().chain(&r.layers.0) {
            if m.badge || visible(m.start, m.length, m.pitch) {
                chips.extend(self.roll_mark(ui, &p, grid, m, hover));
            }
        }
        // The note being drawn.
        let r = &self.roll;
        let pointer = ui.input(|i| i.pointer.latest_pos());
        let shift = ui.input(|i| i.modifiers.shift);
        if let (Some(Grip::Draw { at, pitch, from }), Some(now)) = (&r.grip, pointer) {
            let drawn = self.drawn_length(grid, *at, *from, now, shift);
            let rect = note_rect(*at, drawn, *pitch);
            p.rect(rect, CornerRadius::same(2), mix(r.color, Color32::WHITE, 0.7), Stroke::new(1.0, Color32::WHITE), StrokeKind::Inside);
        }
        // The notes, the grabbed and the chosen following a drag.
        let (follow, held_selected, shown) = self.drag_shown(grid, pointer, shift);
        let copy = ui.input(|i| i.modifiers.ctrl);
        let eraser: Vec<(f32, f32)> = match &r.grip {
            Some(Grip::Erase { points }) => points.clone(),
            _ => Vec::new(),
        };
        for (index, n) in r.notes.iter().enumerate() {
            if !visible(n.start, n.length, n.pitch) && follow != Some(index) {
                continue;
            }
            let follows = follow == Some(index) || (n.selected && follow.is_some() && held_selected);
            let lit = n.selected || follow == Some(index);
            let base = note_rect(n.start, n.length, n.pitch);
            let mut rect = base;
            if follows {
                let (dx, dy, ds, de) = shown;
                rect = Rect::from_min_max(pos2(base.left() + dx + ds, base.top() + dy), pos2((base.right() + dx + de).max(base.left() + dx + ds + 3.0), base.bottom() + dy));
                // A copy leaves the note where it was.
                if copy && (dx != 0.0 || dy != 0.0) {
                    p.rect_filled(base, CornerRadius::same(2), mix(n.color, ROW_WHITE, 0.5));
                }
            }
            let crossed = eraser.iter().any(|(b, pitch)| *b >= n.start && *b < n.start + n.length && pitch.floor() as i64 == n.pitch);
            let over = hover.is_some_and(|h| base.contains(h));
            // Loud notes at the track's full colour, quiet ones fainter;
            // chosen ones light, with a white edge.
            let face = if crossed {
                t.text_off
            } else if lit {
                mix(n.color, Color32::WHITE, 0.7)
            } else if over {
                mix(n.color, Color32::WHITE, 0.85)
            } else {
                mix(n.color, ROW_BLACK, 0.45 + 0.55 * n.velocity)
            };
            p.rect(rect, CornerRadius::same(2), face, Stroke::new(1.0, if lit { Color32::WHITE } else { Color32::from_black_alpha(0x60) }), StrokeKind::Inside);
            if rect.width() >= 28.0 && r.note_h >= 11.0 {
                let pitch = n.pitch + if follows { -(shown.1 / r.note_h).round() as i64 } else { 0 };
                p.with_clip_rect(rect.intersect(grid)).text(pos2(rect.left() + 4.0, rect.center().y), Align2::LEFT_CENTER, pitch_name(pitch), semi(9.0), t.on_hue);
            }
        }
        // The kernel's layers in front of the notes.
        for m in self.roll.layers.1.clone().iter() {
            if m.badge || visible(m.start, m.length, m.pitch) {
                chips.extend(self.roll_mark(ui, &p, grid, m, hover));
            }
        }
        let r = &self.roll;
        // The notes diagnostics are about, outlined in the colour of the
        // worst said of each.
        for (_, pitch, start, length, severity) in &r.diagnostics {
            let rect = note_rect(*start, *length, *pitch).expand(2.0);
            p.rect_stroke(rect, CornerRadius::same(3), Stroke::new(2.0, severity_colour(*severity)), StrokeKind::Inside);
        }
        // Past the end of the clip.
        let end = r.x(grid, r.length);
        if end < grid.right() {
            p.rect_filled(Rect::from_x_y_ranges(end.max(grid.left())..=grid.right(), grid.y_range()), CornerRadius::ZERO, Color32::from_black_alpha(0x66));
        }
        // The box that chooses notes.
        if let (Some(Grip::Box { from, .. }), Some(now)) = (&r.grip, pointer)
            && (now - *from).abs().max_elem() > 3.0
        {
            p.rect(Rect::from_two_pos(*from, now), CornerRadius::ZERO, alpha(t.select, 0.15), Stroke::new(1.0, t.select), StrokeKind::Inside);
        }
        // The selection of visual mode.
        let sel = &self.s.modal["selection"];
        if sel.is_object() && sel["view"] == "pianoroll" && self.s.focused() == "pianoroll" {
            let (c0, c1) = (number(&sel["c0"]) - r.origin, number(&sel["c1"]) - r.origin);
            let (r0, r1) = (int(&sel["r0"]), int(&sel["r1"]));
            let kind = sel["kind"].as_str().unwrap_or("");
            let xs = if kind == "line" { grid.x_range() } else { egui::Rangef::new(r.x(grid, c0), r.x(grid, c1)) };
            let ys = if kind == "char" { grid.y_range() } else { egui::Rangef::new(r.y(grid, r1), r.y(grid, r1) + (r1 - r0 + 1) as f32 * r.note_h) };
            p.rect(Rect::from_x_y_ranges(xs, ys), CornerRadius::ZERO, alpha(t.select, 0.15), Stroke::new(1.0, t.select), StrokeKind::Inside);
        }
        // The cursor: one grid step, or in insert mode the note about to be entered.
        let mode = self.s.mode();
        let width = (if mode == "i" || r.step_input { r.step } else { step }) * r.zoom;
        let cursor = Rect::from_min_size(pos2(r.x(grid, r.cursor), r.y(grid, r.pitch)), vec2(width.max(3.0), r.note_h - 1.0));
        let focused = self.s.focused() == "pianoroll";
        let edge = if r.step_input { t.rec } else { mode_colour(mode) };
        p.rect(cursor, CornerRadius::ZERO, Color32::from_white_alpha(0x10), Stroke::new(if focused || r.step_input { 1.0 } else { 0.0 }, edge), StrokeKind::Inside);
        let pos = self.s.position - r.start;
        if pos >= 0.0 && pos <= r.length {
            p.vline(r.x(grid, pos).round() + 0.5, grid.y_range(), Stroke::new(1.0, t.play));
        }
        // Where the view is in the clip and among the keys: thin bars.
        let content = vec2(grid.width().max((r.length + self.s.bar()) * r.zoom), 128.0 * r.note_h);
        if content.x > grid.width() + 1.0 {
            let w = (grid.width() * grid.width() / content.x).max(24.0);
            let bar = Rect::from_min_size(pos2(grid.left() + r.scroll.x / content.x * grid.width(), grid.bottom() - 5.0), vec2(w, 4.0));
            let lit = hover.is_some_and(|h| bar.expand(2.0).contains(h)) || matches!(r.grip, Some(Grip::Bar { across: true, .. }));
            p.rect_filled(bar, CornerRadius::same(2), Color32::from_white_alpha(if lit { 0x50 } else { 0x24 }));
        }
        let h = (grid.height() * grid.height() / content.y).max(24.0);
        let vbar = Rect::from_min_size(pos2(grid.right() - 5.0, grid.top() + r.scroll.y / content.y * grid.height()), vec2(4.0, h));
        let lit = hover.is_some_and(|h| vbar.expand(2.0).contains(h)) || matches!(r.grip, Some(Grip::Bar { across: false, .. }));
        p.rect_filled(vbar, CornerRadius::same(2), Color32::from_white_alpha(if lit { 0x50 } else { 0x24 }));
        // A chip clicked does what it stands for.
        for (act, arg) in chips {
            self.roll_pass(&act, json!([arg]));
        }
    }

    /// A mark of a layer, drawn; a chip that does something takes a click,
    /// whose act and argument are given back.
    fn roll_mark(&self, ui: &mut Ui, p: &egui::Painter, grid: Rect, m: &Mark, hover: Option<Pos2>) -> Option<(String, f32)> {
        let r = &self.roll;
        let roomy = r.note_h >= 11.0;
        let rect = if m.badge {
            let label_w = widgets::text_width(ui, &m.label, semi(10.0));
            let h = r.note_h.max(14.0);
            Rect::from_min_size(pos2(r.x(grid, m.start) + m.slot as f32 * 20.0, r.y(grid, m.pitch) + r.note_h - h), vec2((label_w + 10.0).max(16.0), h))
        } else {
            Rect::from_min_size(pos2(r.x(grid, m.start), r.y(grid, m.pitch) + 1.0), vec2((m.length * r.zoom - 1.0).max(2.0), r.note_h - 2.0))
        };
        let over = hover.is_some_and(|h| rect.contains(h)) && !m.act.is_empty();
        let fill = if over { mix(m.fill, Color32::WHITE, 0.6) } else { m.fill };
        p.rect(rect, CornerRadius::same(if m.badge { 3 } else { 2 }), fill, Stroke::new(if m.badge { 0.0 } else { 1.0 }, m.edge.unwrap_or(Color32::TRANSPARENT)), StrokeKind::Inside);
        if m.badge || (rect.width() >= 28.0 && roomy) {
            let font = semi(if m.badge { 10.0 } else { 9.0 });
            let painter = p.with_clip_rect(rect.intersect(grid));
            if m.badge {
                painter.text(rect.center(), Align2::CENTER_CENTER, &m.label, font, m.ink);
            } else {
                painter.text(pos2(rect.left() + 4.0, rect.center().y), Align2::LEFT_CENTER, &m.label, font, m.ink);
            }
        }
        // Only a mark that does something takes the pointer: the notes
        // under the others stay within reach.
        if m.act.is_empty() {
            return None;
        }
        let response = ui.interact(rect.intersect(grid), Id::unique(("roll-mark", m.start.to_bits(), m.pitch, m.slot, m.label.as_str())), Sense::click());
        if response.hovered() {
            ui.ctx().set_cursor_icon(egui::CursorIcon::PointingHand);
            if !m.tip.is_empty() {
                widgets::hint(m.tip.clone());
            }
        }
        response.clicked().then(|| (m.act.clone(), m.arg))
    }

    /// The length a note being drawn has: a step for a click, else to where
    /// the pointer is, on the grid unless Shift or the magnet says not.
    fn drawn_length(&self, grid: Rect, at: f32, from: Pos2, now: Pos2, shift: bool) -> f32 {
        let r = &self.roll;
        let step = number(&self.s.project["note_grid"]).max(1.0 / 64.0);
        if (now.x - from.x).abs() <= 3.0 {
            return r.step;
        }
        let beat = r.beat(grid, now.x);
        if shift || !r.snap { (beat - at).max(1.0 / 64.0) } else { ((beat / step - 0.0001).ceil() * step - at).max(step) }
    }

    /// How far the notes held are drawn from where they are: moved, the
    /// start moved, the end moved; the note grabbed and whether it is chosen.
    fn drag_shown(&self, grid: Rect, pointer: Option<Pos2>, shift: bool) -> (Option<usize>, bool, (f32, f32, f32, f32)) {
        let r = &self.roll;
        let (Some(Grip::Note { index, end, from, toggling }), Some(now)) = (&r.grip, pointer) else {
            return (None, false, (0.0, 0.0, 0.0, 0.0));
        };
        let Some(held) = r.notes.get(*index) else { return (None, false, (0.0, 0.0, 0.0, 0.0)) };
        let d = now - *from;
        let moving = d.x.abs() > 3.0 || d.y.abs() > r.note_h / 2.0;
        if *toggling && !moving {
            return (Some(*index), held.selected, (0.0, 0.0, 0.0, 0.0));
        }
        let step = number(&self.s.project["note_grid"]).max(1.0 / 64.0);
        let snap = |x: f32| r.snapped(x / r.zoom, shift, step) * r.zoom;
        let _ = grid;
        let shown = match end {
            0 => (snap(held.start * r.zoom + d.x) - held.start * r.zoom, (d.y / r.note_h).round() * r.note_h, 0.0, 0.0),
            -1 => (0.0, 0.0, snap(held.start * r.zoom + d.x) - held.start * r.zoom, 0.0),
            _ => (0.0, 0.0, 0.0, snap((held.start + held.length) * r.zoom + d.x) - (held.start + held.length) * r.zoom),
        };
        (Some(*index), held.selected, shown)
    }

    /// The note under the pointer, the last drawn first, and which part of
    /// it: -1 its start, 1 its end, 0 its body.
    fn note_at(&self, grid: Rect, pos: Pos2) -> Option<(usize, i8)> {
        let r = &self.roll;
        r.notes.iter().enumerate().rev().find_map(|(i, n)| {
            let rect = Rect::from_min_size(pos2(r.x(grid, n.start), r.y(grid, n.pitch)), vec2((n.length * r.zoom - 1.0).max(3.0), r.note_h - 1.0));
            if !rect.contains(pos) {
                return None;
            }
            let edge = (rect.width() / 4.0).clamp(2.0, 5.0);
            Some((i, if pos.x < rect.left() + edge { -1 } else if pos.x > rect.right() - edge { 1 } else { 0 }))
        })
    }

    /// The strip: how hard each note is played, or a controller.
    fn roll_strip(&mut self, ui: &mut Ui, strip: Rect, grid: Rect) {
        let t = th();
        let p = ui.painter().with_clip_rect(strip);
        p.rect_filled(strip, CornerRadius::ZERO, t.surface);
        p.hline(strip.x_range(), strip.top() + 0.5, Stroke::new(1.0, t.divider));
        // Which of them, as a dropdown at the left.
        let side = Rect::from_min_size(strip.min, vec2(KEYS_W, strip.height()));
        p.rect_filled(side, CornerRadius::ZERO, t.panel);
        p.vline(side.right() - 0.5, side.y_range(), Stroke::new(1.0, t.divider));
        let drop = Rect::from_min_size(side.min + vec2(4.0, 6.0), vec2(KEYS_W - 8.0, 22.0));
        let response = ui.interact(drop, Id::unique("roll-strip-kind"), Sense::click());
        p.rect_filled(drop, CornerRadius::same(3), if response.hovered() { t.control_hover } else { t.control });
        widgets::text_in(ui, pos2(drop.left() + 5.0, drop.center().y), STRIPS_SHORT[self.roll.lane], sans(10.0), t.text, drop.width() - 16.0);
        p.add(Shape::convex_polygon(vec![pos2(drop.right() - 10.0, drop.center().y - 1.5), pos2(drop.right() - 4.0, drop.center().y - 1.5), pos2(drop.right() - 7.0, drop.center().y + 2.0)], t.text_2, Stroke::NONE));
        if response.clicked() {
            self.open_local_menu("roll-strip", choices(&STRIPS, Some(self.roll.lane)), drop.left_bottom() + vec2(0.0, 2.0));
        }
        let area = Rect::from_min_max(pos2(grid.left(), strip.top() + 1.0), pos2(grid.right(), strip.bottom()));
        let p = ui.painter().with_clip_rect(area);
        let r = &self.roll;
        let (from, to) = (r.start + r.beat(grid, area.left()) - 1.0, r.start + r.beat(grid, area.right()) + 1.0);
        for line in model::lines_in_view(&self.s.lines, from, to, r.zoom) {
            let bar = !line.label.is_empty();
            p.vline(r.x(grid, line.beat - r.start).round() + 0.5, area.y_range(), Stroke::new(1.0, if bar { t.line_bar } else { t.line_sub }));
        }
        let end = r.x(grid, r.length);
        if end < area.right() {
            p.rect_filled(Rect::from_x_y_ranges(end.max(area.left())..=area.right(), area.y_range()), CornerRadius::ZERO, Color32::from_black_alpha(0x66));
        }
        let grid_step = number(&self.s.project["note_grid"]).max(1.0 / 64.0);
        if r.lane == 0 {
            for (i, n) in r.notes.iter().enumerate() {
                let x = r.x(grid, n.start);
                if x < area.left() - 4.0 || x > area.right() {
                    continue;
                }
                let shown = r.vel_preview.get(i).copied().filter(|v| *v >= 0.0).unwrap_or(n.velocity);
                let h = ((area.height() - 8.0) * shown).max(2.0);
                let colour = if n.selected { t.select } else { mix(n.color, t.surface, 0.45 + 0.55 * n.velocity) };
                p.rect_filled(Rect::from_min_size(pos2(x, area.bottom() - h), vec2(3.0, h)), CornerRadius::ZERO, colour);
            }
        } else {
            if r.lane == 1 {
                p.hline(area.x_range(), area.center().y, Stroke::new(1.0, t.line_bar));
            }
            let moving = match (&r.grip, ui.input(|i| i.pointer.latest_pos())) {
                (Some(Grip::Moves { from, toggling: false }), Some(now)) if (now - *from).abs().max_elem() > 2.0 => now - *from,
                _ => Vec2::ZERO,
            };
            for (start, value, _, chosen) in r.strip_moves() {
                let follow = if chosen { moving } else { Vec2::ZERO };
                let top = ((area.height() - 4.0) * (1.0 - value) + 2.0 + follow.y).clamp(2.0, area.height() - 2.0);
                let rest = if r.lane == 1 { area.height() / 2.0 } else { area.height() - 2.0 };
                let x = r.x(grid, start) + follow.x;
                let bar = Rect::from_min_size(pos2(x, area.top() + top.min(rest)), vec2((grid_step * r.zoom - 1.0).max(2.0), (rest - top).abs().max(2.0)));
                p.rect_filled(bar, CornerRadius::ZERO, if chosen { t.select } else { alpha(r.color, 0.8) });
                if chosen {
                    let y = if top < rest { bar.top() } else { bar.bottom() - 2.0 };
                    p.rect_filled(Rect::from_min_size(pos2(bar.left(), y), vec2(bar.width(), 2.0)), CornerRadius::ZERO, Color32::WHITE);
                }
            }
        }
        // What the pencil draws, a line or a box being made.
        let pointer = ui.input(|i| i.pointer.latest_pos());
        match (&r.grip, pointer) {
            (Some(Grip::Pencil { points }), _) if r.lane != 0 => {
                let line: Vec<Pos2> = points.iter().map(|(b, v)| pos2(r.x(grid, *b), area.top() + (1.0 - v) * (area.height() - 4.0) + 2.0)).collect();
                p.add(Shape::line(line, Stroke::new(1.5, t.text)));
            }
            (Some(Grip::Line { from }), Some(now)) if (now - *from).abs().max_elem() > 3.0 => {
                p.line_segment([*from, now], Stroke::new(1.5, t.text));
            }
            (Some(Grip::StripBox { from }), Some(now)) if (now - *from).abs().max_elem() > 3.0 => {
                p.rect(Rect::from_two_pos(*from, now), CornerRadius::ZERO, alpha(t.select, 0.15), Stroke::new(1.0, t.select), StrokeKind::Inside);
            }
            _ => {}
        }
    }

    /// The side panel: each track near the roll, and under it its clips.
    fn roll_panel(&mut self, ui: &mut Ui, rect: Rect) {
        let t = th();
        let p = ui.painter().with_clip_rect(rect);
        p.rect_filled(rect, CornerRadius::ZERO, t.panel);
        p.vline(rect.left() + 0.5, rect.y_range(), Stroke::new(1.0, t.divider));
        let rows_v = self.roll.panel_rows.clone();
        for (i, row) in rows_v.iter().enumerate() {
            let r = Rect::from_min_size(pos2(rect.left() + 1.0, rect.top() + 4.0 + i as f32 * 22.0), vec2(rect.width() - 1.0, 22.0));
            let clip = row["kind"] == "clip";
            let (on, active) = (flag(&row["on"]), flag(&row["active"]));
            let id = int(&row["id"]);
            let colour = colour(&row["color"]);
            let name_rect = Rect::from_min_max(pos2(r.left() + if clip { 34.0 } else { 0.0 }, r.top()), r.max);
            let response = ui.interact(name_rect, Id::unique(("roll-row", i)), Sense::click());
            if response.hovered() {
                p.rect_filled(r, CornerRadius::ZERO, Color32::from_white_alpha(0x0a));
                self.roll.hint = if clip { "clip: click to make it the one new notes go into · the box edits it with the others".into() } else { "track: click to show its notes behind these, or not".into() };
            }
            if clip {
                let bx = Rect::from_min_size(pos2(r.left() + 20.0, r.top() + 6.0), vec2(10.0, 10.0));
                let fill = if active { t.select } else if on { alpha(t.select, 0.3) } else { Color32::TRANSPARENT };
                p.rect(bx, CornerRadius::same(2), fill, Stroke::new(1.0, if on { t.select } else { t.text_3 }), StrokeKind::Inside);
                if ui.interact(bx.expand(2.0), Id::unique(("roll-row-box", i)), Sense::click()).clicked() {
                    self.roll_pass("roll_toggle_clip", json!([id]));
                }
            } else {
                p.rect_filled(Rect::from_min_size(pos2(r.left() + 8.0, r.top() + 7.0), vec2(8.0, 8.0)), CornerRadius::same(2), if on { colour } else { alpha(colour, 0.25) });
            }
            let ink = if clip { if on { t.text } else { t.text_2 } } else if on { t.text_2 } else { t.text_3 };
            let x = r.left() + if clip { 36.0 } else { 22.0 };
            widgets::text_in(ui, pos2(x, r.center().y), &text(&row["name"]), if active { semi(T_SMALL) } else { sans(T_SMALL) }, ink, r.right() - x - 8.0);
            if response.clicked() {
                if clip {
                    self.roll_pass("roll_activate", json!([id]));
                } else if !active {
                    self.roll_pass("roll_show_track", json!([id]));
                }
            }
        }
    }

    /// The pointer over the roll: where a gesture begins, how it goes on,
    /// and what it is when let go.
    fn roll_gestures(&mut self, ui: &mut Ui, grid: Rect, keys: Rect, strip: Rect) {
        let lines = self.s.lines.clone();
        let area = Rect::from_min_max(pos2(grid.left(), strip.top() + 1.0), pos2(grid.right(), strip.bottom()));
        let grid_r = ui.interact(grid, Id::unique("roll-grid"), Sense::click_and_drag());
        let keys_r = ui.interact(keys, Id::unique("roll-keys"), Sense::click_and_drag());
        let strip_r = ui.interact(area, Id::unique("roll-strip"), Sense::click_and_drag());
        let (pos, m) = ui.input(|i| (i.pointer.interact_pos(), i.modifiers));
        let pressed = |b| ui.input(|i| i.pointer.button_pressed(b));
        let released = |b| ui.input(|i| i.pointer.button_released(b));
        let (left, right, middle) = (egui::PointerButton::Primary, egui::PointerButton::Secondary, egui::PointerButton::Middle);
        let Some(pos) = pos else { return };
        let level_at = |y: f32| (1.0 - (y - area.top() - 2.0) / (area.height() - 4.0)).clamp(0.0, 1.0);
        // What the pointer hints where it is.
        if grid_r.hovered() && self.roll.grip.is_none() {
            self.roll.hint = match self.note_at(grid, pos) {
                Some((i, _)) => match self.roll.messages.get(&i) {
                    Some((message, _)) if !message.is_empty() => format!("{message} · Ctrl right click for its fixes"),
                    _ => "note: drag moves it and the others chosen (Shift off the grid, Ctrl copies) · either end changes its length · Shift or Ctrl click adds or takes it out · right click or double click removes · Ctrl right click: fixes and what the servers say".into(),
                },
                None => "piano roll: drag draws a note (Shift off the grid) · right drag or Ctrl drag chooses with a box · Alt drag erases · right click for the menu · wheel scrolls, Shift sideways, Ctrl zooms, Alt the rows · middle drag pans".into(),
            };
            if let Some((_, end)) = self.note_at(grid, pos)
                && end != 0
            {
                ui.ctx().set_cursor_icon(egui::CursorIcon::ResizeHorizontal);
            }
        } else if keys_r.hovered() && self.roll.grip.is_none() {
            self.roll.hint = "keyboard: click or drag to hear the keys · right drag chooses their notes".into();
        } else if strip_r.hovered() && self.roll.grip.is_none() {
            self.roll.hint = if self.roll.lane == 0 {
                "velocity: drag across the bars to set how hard the notes play (only the chosen ones, if any are chosen)".into()
            } else {
                "controller: draw it with the pointer held down · right drag draws a straight line · Ctrl drag chooses moves, a click on a move's head chooses it, dragging a head moves the chosen, Delete removes them · right click for the menu".into()
            };
        }
        // A double click removes a note.
        if grid_r.double_clicked()
            && let Some((index, 0)) = self.note_at(grid, pos)
        {
            self.roll.grip = None;
            self.roll_pass("remove_note", json!([index + 1]));
            return;
        }
        let r = &self.roll;
        let content = vec2(grid.width().max((r.length + self.s.bar()) * r.zoom), 128.0 * r.note_h);
        // Where a gesture begins.
        if self.roll.grip.is_none() {
            if grid_r.hovered() {
                let hbar = Rect::from_min_size(pos2(grid.left() + r.scroll.x / content.x * grid.width(), grid.bottom() - 7.0), vec2((grid.width() * grid.width() / content.x).max(24.0), 8.0));
                let vbar = Rect::from_min_size(pos2(grid.right() - 7.0, grid.top() + r.scroll.y / content.y * grid.height()), vec2(8.0, (grid.height() * grid.height() / content.y).max(24.0)));
                if pressed(left) && content.x > grid.width() + 1.0 && hbar.contains(pos) {
                    self.roll.grip = Some(Grip::Bar { across: true, from: pos, scroll: r.scroll });
                } else if pressed(left) && vbar.contains(pos) {
                    self.roll.grip = Some(Grip::Bar { across: false, from: pos, scroll: r.scroll });
                } else if pressed(middle) {
                    self.roll.grip = Some(Grip::Pan { from: pos, scroll: r.scroll });
                } else if pressed(left) && m.alt {
                    self.roll.grip = Some(Grip::Erase { points: vec![(r.beat(grid, pos.x).max(0.0), 127.5 - (pos.y - grid.top() + r.scroll.y) / r.note_h)] });
                } else if pressed(right) || (pressed(left) && m.ctrl && self.note_at(grid, pos).is_none()) {
                    let note = if pressed(right) { self.note_at(grid, pos) } else { None };
                    match note {
                        // A right click on a note's end removes it at once.
                        Some((index, end)) if end != 0 => self.roll_pass("remove_note", json!([index + 1])),
                        _ => self.roll.grip = Some(Grip::Box { from: pos, left: !pressed(right), note: note.map(|n| n.0) }),
                    }
                } else if pressed(left) {
                    match self.note_at(grid, pos) {
                        Some((index, end)) => {
                            let toggling = end == 0 && (m.shift || m.ctrl);
                            if end == 0 && !toggling && !self.roll.notes[index].selected {
                                self.roll_pass("select_note", json!([index + 1, "only"]));
                            }
                            self.roll.grip = Some(Grip::Note { index, end, from: pos, toggling });
                        }
                        None => {
                            let step = number(&self.s.project["note_grid"]).max(1.0 / 64.0);
                            let beat = r.beat(grid, pos.x);
                            let at = if m.shift || !r.snap { beat.max(0.0) } else { (beat / step).floor() * step };
                            let pitch = r.pitch_at(grid, pos.y);
                            self.roll.grip = Some(Grip::Draw { at, pitch, from: pos });
                        }
                    }
                }
            } else if keys_r.hovered() {
                let under = r.pitch_at(grid, pos.y).clamp(0, 127);
                if pressed(left) {
                    self.roll_pass("audition", json!([under]));
                    self.roll.grip = Some(Grip::Keys { held: under, choose: None });
                } else if pressed(right) {
                    self.roll.grip = Some(Grip::Keys { held: -1, choose: Some(under) });
                }
            } else if strip_r.hovered() {
                let beat = r.beat(grid, pos.x);
                let handle = (r.lane != 0).then(|| {
                    r.strip_moves().into_iter().find(|(start, value, _, _)| {
                        let x = r.x(grid, *start);
                        let top = area.top() + (area.height() - 4.0) * (1.0 - value) + 2.0;
                        let w = (number(&self.s.project["note_grid"]).max(1.0 / 64.0) * r.zoom + 3.0).max(6.0);
                        pos.x >= x - 2.0 && pos.x <= x - 2.0 + w && (pos.y - top).abs() <= 4.0
                    })
                });
                match handle.flatten() {
                    Some((_, _, place, chosen)) if pressed(left) => {
                        let toggling = m.ctrl || m.shift;
                        if toggling {
                            self.roll_pass("select_control", json!([place, if m.ctrl { "toggle" } else { "add" }]));
                        } else if !chosen {
                            self.roll_pass("select_control", json!([place, "only"]));
                        }
                        self.roll.grip = Some(Grip::Moves { from: pos, toggling });
                    }
                    Some(_) if pressed(right) => {
                        self.open_strip_menu(pos);
                    }
                    _ if pressed(left) && m.ctrl && r.lane != 0 => self.roll.grip = Some(Grip::StripBox { from: pos }),
                    _ if pressed(left) => self.roll.grip = Some(Grip::Pencil { points: vec![(beat.max(0.0), level_at(pos.y))] }),
                    _ if pressed(right) && r.lane != 0 => self.roll.grip = Some(Grip::Line { from: pos }),
                    _ => {}
                }
            }
        }
        // How it goes on, and what it is when let go.
        let Some(grip) = self.roll.grip.clone() else { return };
        let r = self.roll.lens();
        match grip {
            Grip::Bar { across, from, scroll } => {
                let d = pos - from;
                let to = if across { vec2(scroll.x + d.x * content.x / grid.width(), scroll.y) } else { vec2(scroll.x, scroll.y + d.y * content.y / grid.height()) };
                self.roll.scroll_to(to);
                if released(left) {
                    self.roll.grip = None;
                }
            }
            Grip::Pan { from, scroll } => {
                self.roll.scroll_to(scroll - (pos - from));
                if released(middle) {
                    self.roll.grip = None;
                }
            }
            Grip::Erase { mut points } => {
                let point = (r.beat(grid, pos.x).max(0.0), 127.5 - (pos.y - grid.top() + r.scroll.y) / r.note_h);
                if points.last() != Some(&point) {
                    points.push(point);
                }
                if released(left) {
                    self.roll.grip = None;
                    let list: Vec<Value> = points.iter().map(|(b, p)| json!([b, p])).collect();
                    self.roll_pass("erase_notes", json!([list]));
                } else {
                    self.roll.grip = Some(Grip::Erase { points });
                }
            }
            Grip::Box { from, left: by_left, note } => {
                let done = if by_left { released(left) } else { released(right) };
                if !done {
                    return;
                }
                self.roll.grip = None;
                if (pos - from).abs().max_elem() > 3.0 {
                    let (a, b) = (from.min(pos), from.max(pos));
                    let mode = if m.shift { "add" } else if m.ctrl && !by_left { "toggle" } else { "only" };
                    self.roll_pass("select_notes_box", json!([r.beat(grid, a.x), r.pitch_at(grid, b.y), r.beat(grid, b.x), r.pitch_at(grid, a.y), mode]));
                } else if !by_left && note.is_some() && m.ctrl {
                    let index = note.unwrap();
                    let (clip, place) = self.roll.refs.get(index).copied().unwrap_or((0, 0));
                    self.open_menu("note", json!([clip, place]), pos);
                } else if let (false, Some(index)) = (by_left, note) {
                    self.roll_pass("remove_note", json!([index + 1]));
                } else if !by_left {
                    if let Some(id) = self.roll.open {
                        self.open_menu("roll", json!([id]), pos);
                    }
                } else {
                    // Ctrl and a click: on another track's note, its clip is edited too.
                    self.roll_pass("context_click", json!([r.beat(grid, from.x), r.pitch_at(grid, from.y)]));
                }
            }
            Grip::Draw { at, pitch, from } => {
                let drawn = self.drawn_length(grid, at, from, pos, m.shift);
                self.roll.hint = self.roll.describe(&lines, pitch, at, drawn);
                if released(left) {
                    self.roll.grip = None;
                    self.roll.hint.clear();
                    let dragged = (pos.x - from.x).abs() > 3.0;
                    self.roll_pass("add_note", json!([pitch, at, if dragged { drawn } else { 0.0 }, m.shift]));
                }
            }
            Grip::Note { index, end, from, toggling } => {
                let d = pos - from;
                let moving = d.x.abs() > 3.0 || d.y.abs() > r.note_h / 2.0;
                if let Some(n) = self.roll.notes.get(index).cloned() {
                    let (_, _, shown) = self.drag_shown(grid, Some(pos), m.shift);
                    let r = &self.roll;
                    self.roll.hint = match end {
                        0 if moving => r.describe(&lines, n.pitch - (d.y / r.note_h).round() as i64, n.start + shown.0 / r.zoom, n.length),
                        -1 => r.describe(&lines, n.pitch, n.start + shown.2 / r.zoom, n.length - shown.2 / r.zoom),
                        1 => r.describe(&lines, n.pitch, n.start, n.length + shown.3 / r.zoom),
                        _ => self.roll.hint.clone(),
                    };
                }
                if released(left) {
                    self.roll.grip = None;
                    self.roll.hint.clear();
                    match end {
                        0 if toggling && !moving => self.roll_pass("select_note", json!([index + 1, "toggle"])),
                        0 if moving => self.roll_pass("drag_notes", json!([index + 1, d.x / r.zoom, -(d.y / r.note_h).round(), m.ctrl, m.shift])),
                        -1 if d.x.abs() > 2.0 => self.roll_pass("stretch_notes", json!([index + 1, d.x / r.zoom, 0, m.shift])),
                        1 if d.x.abs() > 2.0 => self.roll_pass("stretch_notes", json!([index + 1, 0, d.x / r.zoom, m.shift])),
                        _ => {}
                    }
                }
            }
            Grip::Keys { held, choose } => {
                let under = r.pitch_at(grid, pos.y).clamp(0, 127);
                match choose {
                    None => {
                        if under != held {
                            self.roll_pass("audition", json!([under]));
                            self.roll.grip = Some(Grip::Keys { held: under, choose });
                        }
                        if released(left) {
                            self.roll.grip = None;
                        }
                    }
                    Some(from) => {
                        if released(right) {
                            self.roll.grip = None;
                            let mode = if m.shift { "add" } else if m.ctrl { "toggle" } else { "only" };
                            self.roll_pass("select_pitches", json!([from, under, mode]));
                        }
                    }
                }
            }
            Grip::Pencil { mut points } => {
                let point = (r.beat(grid, pos.x).max(0.0), level_at(pos.y));
                if points.last() != Some(&point) {
                    points.push(point);
                }
                let reach = 4.0 / r.zoom.max(1.0);
                // Over velocities the bars themselves follow the pencil.
                if r.lane == 0 {
                    let notes: Vec<(f32, bool)> = self.roll.notes.iter().map(|n| (n.start, n.selected)).collect();
                    self.roll.vel_preview = model::velocity_preview(&points, &notes, reach);
                    self.roll.hint = format!("velocity {}", (127.0 * point.1).round());
                }
                if released(left) {
                    self.roll.grip = None;
                    self.roll.hint.clear();
                    let list: Vec<Value> = points.iter().map(|(b, h)| json!([b, h])).collect();
                    match strip_kind(self.roll.lane) {
                        Some((kind, number)) => self.roll_pass("draw_controls", json!([kind, number, list])),
                        // A click reaches the bar within a few pixels.
                        None => self.roll_pass("draw_velocities", json!([list, reach])),
                    }
                } else {
                    self.roll.grip = Some(Grip::Pencil { points });
                }
            }
            Grip::Line { from } => {
                self.roll.hint = if r.lane == 1 { format!("bend {}", (8192.0 * (level_at(pos.y) * 2.0 - 1.0)).round()) } else { format!("value {}", (127.0 * level_at(pos.y)).round()) };
                if released(right) {
                    self.roll.grip = None;
                    self.roll.hint.clear();
                    if (pos - from).abs().max_elem() > 3.0 {
                        self.strip_pass("line_controls", json!([r.beat(grid, from.x), level_at(from.y), r.beat(grid, pos.x), level_at(pos.y), m.shift]));
                    } else {
                        self.open_strip_menu(pos);
                    }
                }
            }
            Grip::StripBox { from } => {
                if released(left) {
                    self.roll.grip = None;
                    let (a, b) = (from.min(pos), from.max(pos));
                    self.strip_pass("select_controls", json!([r.beat(grid, a.x), level_at(b.y), r.beat(grid, b.x), level_at(a.y), if m.shift { "add" } else { "only" }]));
                }
            }
            Grip::Moves { from, toggling } => {
                let d = pos - from;
                if !toggling && d.abs().max_elem() > 2.0 {
                    self.roll.hint = format!("moving the chosen moves by {} beats", (d.x / r.zoom * 100.0).round() / 100.0);
                }
                if released(left) {
                    self.roll.grip = None;
                    self.roll.hint.clear();
                    if !toggling && d.abs().max_elem() > 2.0 {
                        self.roll_pass("move_controls", json!([d.x / r.zoom, -d.y / (area.height() - 4.0), m.shift]));
                    }
                }
            }
        }
    }

    fn open_strip_menu(&mut self, at: Pos2) {
        if let (Some(id), Some((kind, number))) = (self.roll.open, strip_kind(self.roll.lane)) {
            self.open_menu("strip", json!([id, kind, number]), at);
        }
    }

    /// The wheel scrolls; with Shift sideways, with Ctrl it zooms in time
    /// and with Alt the rows, where the pointer is.
    fn roll_wheel(&mut self, ui: &Ui, grid: Rect, keys: Rect) {
        let over = Rect::from_min_max(keys.min, grid.max);
        let Some(pos) = View::pointer_in(ui, over) else { return };
        let wheels: Vec<(Vec2, egui::Modifiers)> = ui.input(|i| {
            i.events
                .iter()
                .filter_map(|e| match e {
                    egui::Event::MouseWheel { unit, delta, modifiers, .. } => {
                        let scale = if *unit == egui::MouseWheelUnit::Point { 1.0 } else { 40.0 };
                        Some((*delta * scale, *modifiers))
                    }
                    _ => None,
                })
                .collect()
        });
        for (delta, m) in wheels {
            let r = &mut self.roll;
            let dy = if delta.y != 0.0 { delta.y } else { delta.x };
            if m.ctrl && pos.x >= grid.left() {
                let by = if dy > 0.0 { 1.2 } else { 1.0 / 1.2 };
                if r.zoom * by >= 8.0 && r.zoom * by <= 640.0 {
                    let x = pos.x - grid.left() + r.scroll.x;
                    r.zoom *= by;
                    let to = vec2(r.scroll.x + x * (by - 1.0), r.scroll.y);
                    r.scroll_to(to);
                }
            } else if m.alt {
                let by = if dy > 0.0 { 1.0 } else { -1.0 };
                if r.note_h + by >= 6.0 && r.note_h + by <= 28.0 {
                    let y = pos.y - grid.top() + r.scroll.y;
                    r.note_h += by;
                    let to = vec2(r.scroll.x, r.scroll.y + y * (r.note_h / (r.note_h - by)) - y);
                    r.scroll_to(to);
                }
            } else if m.shift {
                let to = vec2(r.scroll.x - dy, r.scroll.y);
                r.scroll_to(to);
            } else {
                let to = r.scroll - delta;
                r.scroll_to(to);
            }
        }
    }

    /// The piano roll in a window of its own, while it is given one.
    pub fn roll_window(&mut self, ctx: &egui::Context) {
        if !self.roll.detached || self.roll.open.is_none() {
            return;
        }
        let title = format!("Notes – {} ({})", self.roll.title, self.roll.track);
        let builder = egui::ViewportBuilder::default().with_title(title).with_inner_size([1180.0, 640.0]).with_min_inner_size([560.0, 300.0]);
        let id = egui::ViewportId::from_hash_of("piano-roll");
        ctx.show_viewport_immediate(id, builder, |ctx, _class| {
            egui::CentralPanel::default().frame(egui::Frame::NONE).show(ctx, |ui| {
                let full = ui.max_rect();
                let status = Rect::from_min_max(pos2(full.left(), full.bottom() - 22.0), full.max);
                let roll = Rect::from_min_max(full.min, pos2(full.right(), status.top() - 1.0));
                self.draw_roll(ui, roll, true);
                let t = th();
                ui.painter().rect_filled(status, CornerRadius::ZERO, t.panel);
                let hint = if self.roll.hint.is_empty() { widgets::take_hint() } else { self.roll.hint.clone() };
                widgets::text_in(ui, pos2(status.left() + 10.0, status.center().y), &hint, sans(T_SMALL), t.text_2, status.width() - 20.0);
                // Keys typed here go to the kernel as in the main window.
                let events = ui.input(|i| i.events.clone());
                self.window_keys(&events);
                self.menu_popup(ui);
            });
            if ctx.input(|i| i.viewport().close_requested()) {
                // Closing the roll's window puts the roll back in the main one.
                self.roll.detached = false;
            }
        });
    }

    /// Clear what a frame of the roll said, before the next.
    pub fn roll_frame(&mut self) {
        if self.roll.grip.is_none() {
            self.roll.hint.clear();
        }
    }
}
