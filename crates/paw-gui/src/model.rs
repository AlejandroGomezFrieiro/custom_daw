//! What the kernel says to draw (`paw.frontend.state`), read into plain
//! data, and the small sums the drawing makes on it: levels on a fader's
//! travel, which ruler lines show at a zoom, where a curve is at a beat.

use egui::Color32;
use serde_json::Value;

use crate::theme::colour;

pub fn text(value: &Value) -> String {
    value.as_str().unwrap_or_default().to_string()
}

pub fn number(value: &Value) -> f32 {
    value.as_f64().unwrap_or(0.0) as f32
}

pub fn int(value: &Value) -> i64 {
    value.as_i64().or_else(|| value.as_f64().map(|v| v as i64)).unwrap_or(0)
}

pub fn flag(value: &Value) -> bool {
    value.as_bool().unwrap_or(false)
}

pub fn rows(value: &Value) -> &[Value] {
    value.as_array().map(Vec::as_slice).unwrap_or(&[])
}

/// Fader position, 0 to 1, for a volume from -60 to +6 dB.
pub fn fader(db: f32) -> f32 {
    ((db + 60.0) / 66.0).clamp(0.0, 1.0)
}

/// Meter length, 0 to 1, for a linear peak level: -60 dB at the foot, 0 dB
/// at `ZERO_DB`, +6 dB at the top.
pub fn meter(peak: f32) -> f32 {
    ((20.0 * peak.max(1e-6).log10() + 60.0) / 66.0).clamp(0.0, 1.0)
}

/// Where 0 dB is along a meter.
pub const ZERO_DB: f32 = 60.0 / 66.0;

/// A number of decibels as the window writes them, with a true minus sign.
pub fn decibels(db: f32) -> String {
    if db <= -60.0 {
        return "\u{2212}inf".into();
    }
    let text = format!("{:.1}", if db.abs() < 0.05 { 0.0 } else { db });
    text.replacen('-', "\u{2212}", 1)
}

/// Where a pan from -1 to 1 points, in a few letters: `L30`, `C`, `R100`.
pub fn pan_text(pan: f32) -> String {
    let amount = (pan.abs() * 100.0).round() as i32;
    match amount {
        0 => "C".into(),
        _ if pan < 0.0 => format!("L{amount}"),
        _ => format!("R{amount}"),
    }
}

/// A parameter's name with a capital letter, as a label.
pub fn capitalised(name: &str) -> String {
    let mut chars = name.chars();
    chars.next().map_or_else(String::new, |first| first.to_uppercase().chain(chars).collect())
}

/// A meter's peaks, held a moment and then let fall, and the light that
/// comes on when a level reaches 0 dB and stays on until it is cleared.
#[derive(Clone, Copy, Default, Debug, PartialEq)]
pub struct PeakHold {
    /// Each side's peak, as a meter length, and how long it has been held.
    pub level: [f32; 2],
    held: [f32; 2],
    pub clipped: bool,
}

impl PeakHold {
    /// How long a peak stays before it falls, and how fast it falls then.
    pub const HOLD: f32 = 1.5;
    pub const FALL: f32 = 20.0 / 66.0;

    /// Take in both sides' levels, `dt` seconds after the last ones.
    pub fn update(&mut self, levels: [f32; 2], dt: f32) {
        for (side, &level) in levels.iter().enumerate() {
            if level >= self.level[side] {
                self.level[side] = level;
                self.held[side] = 0.0;
            } else {
                self.held[side] += dt;
                if self.held[side] > Self::HOLD {
                    self.level[side] = (self.level[side] - Self::FALL * dt).max(level);
                }
            }
            if level >= ZERO_DB - 1e-4 {
                self.clipped = true;
            }
        }
    }

    /// Whether a held peak is still above what is arriving, so falls later.
    pub fn moving(&self, levels: [f32; 2]) -> bool {
        self.level[0] > levels[0] + 1e-3 || self.level[1] > levels[1] + 1e-3
    }
}

/// A bar or beat line of the tempo map.
#[derive(Clone, Debug, PartialEq)]
pub struct Line {
    pub beat: f32,
    /// Where the next line is, for the ticks between.
    pub next: f32,
    pub bar: i64,
    /// The beat in its bar, from 0.
    pub index: i64,
    /// The bar's number on a bar line, empty on a beat line.
    pub label: String,
    /// `bar.beat`.
    pub place: String,
}

pub fn lines(list: &Value) -> Vec<Line> {
    rows(list)
        .iter()
        .map(|l| Line {
            beat: number(&l["beat"]),
            next: number(&l["next"]),
            bar: l["bar"].as_i64().unwrap_or(1),
            index: l["index"].as_i64().unwrap_or(0),
            label: text(&l["label"]),
            place: text(&l["place"]),
        })
        .collect()
}

/// The lines of `all` to draw when beats `from` to `to` show at `zoom`
/// pixels a beat: those in view, and when bars are too close together to
/// tell apart, only every second, fourth or eighth.
pub fn lines_in_view(all: &[Line], from: f32, to: f32, zoom: f32) -> Vec<&Line> {
    // The first bar's width, for how many to leave out.
    let bar_beats = all
        .iter()
        .filter(|l| !l.label.is_empty())
        .map(|l| l.beat)
        .take(2)
        .fold((None, 4.0), |(first, width), beat| match first {
            None => (Some(beat), width),
            Some(first) => (Some(first), (beat - first).max(0.25)),
        })
        .1;
    let mut every = 1;
    while bar_beats * zoom * (every as f32) < 5.0 && every < 1024 {
        every *= 2;
    }
    let beats_show = zoom >= 6.0;
    let start = all.partition_point(|l| l.beat < from);
    all[start..]
        .iter()
        .take_while(|l| l.beat <= to)
        .filter(|l| if l.label.is_empty() { beats_show } else { (l.bar - 1) % every == 0 })
        .collect()
}

/// A song position as bar.beat.sixteenth by the tempo map's lines.
pub fn place_of(lines: &[Line], pos: f32) -> String {
    let i = lines.partition_point(|l| l.beat <= pos + 1e-4);
    let Some(line) = i.checked_sub(1).and_then(|i| lines.get(i)) else {
        return "1.1.1".into();
    };
    let unit = lines.get(i).map_or(1.0, |next| next.beat - line.beat).max(1e-6);
    let part = (((pos - line.beat) / unit * 4.0 + 1e-4).floor() as i64).clamp(0, 3) + 1;
    format!("{}.{}.{part}", line.bar, line.index + 1)
}

/// The value of a curve of points `(beat, value)` at `beat`: flat before
/// its first point and after its last, straight between.
pub fn curve_at(points: &[(f32, f32)], beat: f32) -> Option<f32> {
    let (first, last) = (points.first()?, points.last()?);
    if beat <= first.0 {
        return Some(first.1);
    }
    if beat >= last.0 {
        return Some(last.1);
    }
    let next = points.partition_point(|p| p.0 <= beat);
    let (a, b) = (points[next - 1], points[next]);
    Some(if b.0 - a.0 <= f32::EPSILON { b.1 } else { a.1 + (b.1 - a.1) * (beat - a.0) / (b.0 - a.0) })
}

/// A curve over beats `from` to `to` alone, as points `(beat, value)`: the
/// curve at both ends and its points between. Only the stretch that shows
/// is drawn, however long the song.
pub fn curve_in_view(points: &[(f32, f32)], from: f32, to: f32) -> Vec<(f32, f32)> {
    let from = from.max(0.0);
    let to = to.max(from);
    let Some(start) = curve_at(points, from) else { return Vec::new() };
    let mut out = vec![(from, start)];
    let first = points.partition_point(|p| p.0 <= from);
    out.extend(points[first..].iter().take_while(|p| p.0 < to).copied());
    out.push((to, curve_at(points, to).unwrap_or(start)));
    out
}

/// The tempo map as corners `(beat, height 0..1)` over beats `from` to
/// `to`: a level run to the next change where a point holds, a sloping
/// line where it ramps. Each point is `(beat, height, ramps)`.
pub fn tempo_corners(points: &[(f32, f32, bool)], from: f32, to: f32) -> Vec<(f32, f32)> {
    let Some(last) = points.last() else { return Vec::new() };
    let mut corners: Vec<(f32, f32)> = Vec::new();
    for (i, point) in points.iter().enumerate() {
        if i > 0 && !points[i - 1].2 {
            corners.push((point.0, points[i - 1].1));
        }
        corners.push((point.0, point.1));
    }
    corners.push((to.max(last.0), last.1));
    let mut out: Vec<(f32, f32)> = Vec::new();
    for pair in corners.windows(2) {
        let (a, b) = (pair[0], pair[1]);
        if b.0 > a.0 {
            let (x0, x1) = (a.0.max(from), b.0.min(to));
            if x1 >= x0 {
                let at = |x: f32| a.1 + (b.1 - a.1) * (x - a.0) / (b.0 - a.0);
                if out.is_empty() {
                    out.push((x0, at(x0)));
                }
                out.push((x1, at(x1)));
            }
        } else if a.0 >= from && a.0 <= to {
            if out.is_empty() {
                out.push(a);
            }
            out.push((a.0, b.1));
        }
    }
    out
}

/// What a stroke over the velocity strip gives each note, as the kernel's
/// `draw_velocities` will: the height drawn above the start of each note
/// within the stretch drawn over (or within `reach` beats of a click), only
/// the chosen notes when any are chosen; -1 for the notes it leaves alone.
pub fn velocity_preview(stroke: &[(f32, f32)], notes: &[(f32, bool)], reach: f32) -> Vec<f32> {
    let mut points = stroke.to_vec();
    points.sort_by(|a, b| a.0.total_cmp(&b.0));
    let (Some(first), Some(last)) = (points.first().copied(), points.last().copied()) else {
        return Vec::new();
    };
    let any = notes.iter().any(|n| n.1);
    notes
        .iter()
        .map(|&(start, selected)| {
            let within = start >= first.0 - reach - 1e-6 && start <= last.0 + reach + 1e-6;
            if within && (!any || selected) {
                curve_at(&points, start).unwrap_or(0.0).clamp(1.0 / 127.0, 1.0)
            } else {
                -1.0
            }
        })
        .collect()
}

/// An automation lane, with its points as (beat, height from 0 to 1 over
/// the stretch it is drawn over).
#[derive(Clone, Debug)]
pub struct Lane {
    pub id: i64,
    pub name: String,
    pub param: bool,
    pub enabled: bool,
    pub points: Vec<(f32, f32)>,
}

/// How tall a lane shown as a row of its own is, as a share of the height
/// of a track at the zoom; and a take lane.
pub const LANE_ROW: f32 = 0.8;
pub const TAKE_ROW: f32 = 0.6;

#[derive(Clone, Debug)]
pub struct Track {
    pub id: i64,
    pub number: usize,
    pub name: String,
    pub color: Color32,
    /// What its sound goes through and where it goes, in a few words.
    pub chain: String,
    pub kind: String,
    pub volume: f32,
    pub pan: f32,
    pub mute: bool,
    pub solo: bool,
    pub armed: bool,
    pub input: String,
    pub input_label: String,
    pub monitor: bool,
    pub master: bool,
    pub depth: i64,
    pub group: bool,
    pub folded: bool,
    pub members: i64,
    pub automation: String,
    /// Where its row starts and how tall it is, in rows of the zoom's
    /// height; the part its clips take.
    pub top: f32,
    pub size: f32,
    pub clip_size: f32,
    pub lanes: Vec<Lane>,
    pub lane_rows: Vec<i64>,
    pub take_rows: usize,
}

pub fn tracks(list: &Value) -> Vec<Track> {
    let mut top = 0.0;
    rows(list)
        .iter()
        .enumerate()
        .map(|(index, t)| {
            let clip_size = t["height"].as_f64().map_or(1.0, |h| h as f32);
            let lane_rows: Vec<i64> = rows(&t["lane_rows"]).iter().filter_map(Value::as_i64).collect();
            let take_rows = t["take_rows"].as_u64().unwrap_or(0) as usize;
            let size = clip_size + take_rows as f32 * TAKE_ROW + lane_rows.len() as f32 * LANE_ROW;
            let chain = match t["output"].as_str() {
                Some(output) if t["chain"].as_str().is_some_and(|c| !c.is_empty()) => {
                    format!("{}  → {output}", text(&t["chain"]))
                }
                Some(output) => format!("→ {output}"),
                None => text(&t["chain"]),
            };
            let track = Track {
                id: int(&t["id"]),
                number: index + 1,
                name: text(&t["name"]),
                color: colour(&t["color"]),
                chain,
                kind: text(&t["kind"]),
                volume: number(&t["volume"]),
                pan: number(&t["pan"]),
                mute: flag(&t["mute"]),
                solo: flag(&t["solo"]),
                armed: flag(&t["armed"]),
                input: text(&t["input"]),
                input_label: text(&t["input_label"]),
                monitor: flag(&t["monitor"]),
                master: flag(&t["master"]),
                depth: int(&t["depth"]),
                group: flag(&t["group"]),
                folded: flag(&t["folded"]),
                members: int(&t["members"]),
                automation: t["automation"].as_str().unwrap_or("read").into(),
                top,
                size,
                clip_size,
                lanes: rows(&t["lanes"])
                    .iter()
                    .map(|lane| {
                        let (lo, hi) = (number(&lane["lo"]), number(&lane["hi"]));
                        let span = if hi > lo { hi - lo } else { 1.0 };
                        Lane {
                            id: int(&lane["id"]),
                            name: text(&lane["name"]),
                            param: lane["target"] == "param",
                            enabled: lane["enabled"].as_bool().unwrap_or(true),
                            points: rows(&lane["points"])
                                .iter()
                                .map(|p| (number(&p[0]), ((number(&p[1]) - lo) / span).clamp(0.0, 1.0)))
                                .collect(),
                        }
                    })
                    .collect(),
                lane_rows,
                take_rows,
            };
            top += size;
            track
        })
        .collect()
}

#[derive(Clone, Debug)]
pub struct Clip {
    pub id: i64,
    pub row: usize,
    pub start: f32,
    pub length: f32,
    pub name: String,
    pub midi: bool,
    pub muted: bool,
    pub selected: bool,
    pub fade_in: f32,
    pub fade_out: f32,
    pub gain: f32,
    pub takes: i64,
    pub take: i64,
    /// Where a looped clip's repeats begin, and its warp markers, in beats
    /// from its start.
    pub notches: Vec<f32>,
    pub warps: Vec<f32>,
    /// What says when its picture is to be made again: its notes' stamp or
    /// its waveform's.
    pub key: Option<String>,
    /// Each take's name and the key of its picture, in take lanes.
    pub take_rows: Option<Vec<(String, String)>>,
}

pub fn clips(list: &Value) -> Vec<Clip> {
    rows(list)
        .iter()
        .map(|c| Clip {
            id: int(&c["id"]),
            row: c["track"].as_u64().unwrap_or(0) as usize,
            start: number(&c["start"]),
            length: number(&c["length"]),
            name: text(&c["name"]),
            midi: flag(&c["midi"]),
            muted: flag(&c["muted"]),
            selected: flag(&c["selected"]),
            fade_in: number(&c["fade_in"]),
            fade_out: number(&c["fade_out"]),
            gain: number(&c["gain"]),
            takes: c["takes"].as_i64().unwrap_or(1),
            take: c["take"].as_i64().unwrap_or(1),
            notches: rows(&c["notches"]).iter().map(number).collect(),
            warps: rows(&c["warps"]).iter().map(number).collect(),
            key: c["stamp"].as_str().or(c["waveform"].as_str()).map(String::from),
            take_rows: c["take_rows"].as_array().map(|list| {
                list.iter().map(|t| (text(&t["name"]), text(&t["key"]))).collect()
            }),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn peaks_are_held_then_fall_and_the_clip_light_stays_on() {
        let mut peak = PeakHold::default();
        peak.update([0.5, 0.25], 0.0);
        assert_eq!(peak.level, [0.5, 0.25], "the loudest level is held");
        peak.update([0.1, 0.1], 1.0);
        assert_eq!(peak.level, [0.5, 0.25], "for a moment");
        peak.update([0.1, 0.1], 1.0);
        assert!(peak.level[0] < 0.5, "then it falls");
        assert!((peak.level[0] - (0.5 - PeakHold::FALL)).abs() < 1e-4, "at 20 dB a second");
        assert!(!peak.clipped, "no light below 0 dB");
        peak.update([meter(1.0), 0.0], 0.1);
        assert!(peak.clipped, "the light comes on at 0 dB");
        peak.update([0.0, 0.0], 10.0);
        assert!(peak.clipped, "and stays on");
    }

    #[test]
    fn decibels_are_written_with_a_minus_sign() {
        assert_eq!(decibels(-4.0), "\u{2212}4.0");
        assert_eq!(decibels(-0.01), "0.0");
        assert_eq!(decibels(3.5), "3.5");
        assert_eq!(decibels(-90.0), "\u{2212}inf");
        assert_eq!(capitalised("attack"), "Attack");
        assert_eq!(pan_text(0.0), "C");
        assert_eq!(pan_text(-0.3), "L30");
        assert_eq!(pan_text(1.0), "R100");
    }

    #[test]
    fn a_velocity_stroke_is_previewed_as_the_kernel_draws_it() {
        let notes = [(0.0, false), (1.0, false), (2.0, false), (4.0, false)];
        let stroke = [(0.0, 0.0), (4.0, 1.0)];
        assert_eq!(velocity_preview(&stroke, &notes, 0.0)[1..], [0.25, 0.5, 1.0]);
        let chosen = [(0.0, false), (1.0, true)];
        assert_eq!(velocity_preview(&stroke, &chosen, 0.0), [-1.0, 0.25], "only the chosen notes");
        assert_eq!(velocity_preview(&[(1.05, 0.5)], &notes, 0.1), [-1.0, 0.5, -1.0, -1.0], "a click reaches a note nearby");
    }

    #[test]
    fn a_curve_is_drawn_over_the_stretch_in_view_alone() {
        let points = [(0.0, 0.0), (100.0, 1.0), (200.0, 0.0)];
        assert_eq!(curve_in_view(&points, 50.0, 150.0), [(50.0, 0.5), (100.0, 1.0), (150.0, 0.5)]);
        assert_eq!(curve_in_view(&points, 300.0, 400.0), [(300.0, 0.0), (400.0, 0.0)], "flat past the last");
        assert_eq!(curve_in_view(&points, -50.0, 50.0), [(0.0, 0.0), (50.0, 0.5)], "nothing before 0");
        assert!(curve_in_view(&[], 0.0, 10.0).is_empty());
        // The tempo map: a step holds, a ramp slopes.
        let tempo = [(0.0, 0.5, false), (4.0, 1.0, true), (8.0, 0.0, false)];
        assert_eq!(tempo_corners(&tempo, 0.0, 10.0), [(0.0, 0.5), (4.0, 0.5), (4.0, 1.0), (8.0, 0.0), (10.0, 0.0)]);
    }

    #[test]
    fn only_the_lines_in_view_are_drawn_and_fewer_when_bars_are_narrow() {
        let all: Vec<Line> = (0..4000)
            .map(|i| Line {
                beat: i as f32,
                next: i as f32 + 1.0,
                bar: i / 4 + 1,
                index: i % 4,
                label: if i % 4 == 0 { (i / 4 + 1).to_string() } else { String::new() },
                place: String::new(),
            })
            .collect();
        assert_eq!(lines_in_view(&all, 100.0, 132.0, 28.0).len(), 33, "every beat of the stretch");
        let far = lines_in_view(&all, 0.0, 4000.0, 1.0);
        assert!(far.iter().all(|l| !l.label.is_empty()), "no beat lines");
        assert_eq!(far.len(), 500, "every second bar when a bar is 4 px");
        assert_eq!(place_of(&all, 5.5), "2.2.3");
    }

    #[test]
    fn tracks_are_stacked_with_their_lane_rows() {
        let tracks = tracks(&json!([
            { "id": 1, "name": "A", "height": 1.0, "lane_rows": [7], "take_rows": 2 },
            { "id": 2, "name": "B", "height": 0.5 },
        ]));
        assert_eq!(tracks[0].size, 1.0 + 2.0 * TAKE_ROW + LANE_ROW);
        assert_eq!(tracks[1].top, tracks[0].size);
        assert_eq!(tracks[1].size, 0.5);
    }
}
