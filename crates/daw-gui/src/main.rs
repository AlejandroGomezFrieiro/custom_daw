//! `daw-gui`: a window onto a kernel.
//!
//! The frontend holds no project state. It asks the kernel for the state to
//! draw thirty times a second over the control socket, and sends what the user
//! does back as commands. With `--socket` it attaches to a kernel that is
//! already running; otherwise it starts one of its own and stops it on exit.

use std::cell::RefCell;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::rc::Rc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Value, json};
use slint::{
    Color, ComponentHandle, Image, Model, ModelRc, Rgba8Pixel, SharedPixelBuffer, SharedString,
    Timer, TimerMode, VecModel,
};

slint::include_modules!();

const HELP: &str = "\
daw-gui: a graphical frontend for daw

Usage:
  daw-gui [kernel options] [project]   start a kernel and show it
  daw-gui --socket <path>              show a kernel that is already running

Kernel options are passed on to `daw --headless`; see `daw --help`.
";

/// How long a message stays in the toolbar.
const MESSAGE_TIME: Duration = Duration::from_secs(5);

/// A connection to a kernel's control socket.
struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
}

impl Client {
    fn connect(path: &Path) -> Result<Self> {
        let stream = UnixStream::connect(path)?;
        Ok(Self {
            reader: BufReader::new(stream.try_clone()?),
            writer: stream,
        })
    }

    fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        writeln!(
            self.writer,
            "{}",
            json!({ "id": 1, "method": method, "params": params })
        )?;
        let mut line = String::new();
        if self.reader.read_line(&mut line)? == 0 {
            bail!("the kernel went away");
        }
        let response: Value = serde_json::from_str(&line).context("bad response")?;
        match response.get("error").and_then(Value::as_str) {
            // Lua errors carry a traceback; the first line says what happened.
            Some(error) => Err(anyhow!("{}", error.lines().next().unwrap_or(error))),
            None => Ok(response["result"].clone()),
        }
    }

    /// Run Lua in the kernel with `args` as `...`.
    fn eval(&mut self, code: &str, args: Value) -> Result<Value> {
        let mut params = vec![json!(code)];
        params.extend(args.as_array().cloned().unwrap_or_default());
        self.call("eval", Value::Array(params))
    }
}

/// Start a kernel without a UI and connect to it.
fn start_kernel(args: &[String]) -> Result<(Client, Child)> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let socket = runtime.join(format!("daw-gui-{}.sock", std::process::id()));
    // The `daw` binary beside this one, else whichever is on the path.
    let beside = std::env::current_exe()
        .ok()
        .and_then(|exe| Some(exe.parent()?.join("daw")));
    let binary = std::env::var_os("DAW_BIN")
        .map(PathBuf::from)
        .or(beside.filter(|path| path.is_file()))
        .unwrap_or_else(|| PathBuf::from("daw"));
    let mut child = Command::new(&binary);
    child
        .arg("--headless")
        .arg("--listen")
        .arg(&socket)
        .args(args)
        .stdin(Stdio::null());
    // If this program dies without saying goodbye, the kernel must not be left
    // running with the audio device.
    unsafe {
        child.pre_exec(|| {
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
            Ok(())
        });
    }
    let mut child = child
        .spawn()
        .with_context(|| format!("starting {}", binary.display()))?;
    // The first start can take a while: it looks through every installed plugin.
    let deadline = Instant::now() + Duration::from_secs(120);
    loop {
        if let Ok(client) = Client::connect(&socket) {
            return Ok((client, child));
        }
        if let Some(status) = child.try_wait()? {
            bail!("the kernel stopped before it was ready ({status})");
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            bail!("the kernel did not open its socket");
        }
        std::thread::sleep(Duration::from_millis(30));
    }
}

/// Replace a model's rows, touching only the ones that differ so that the
/// elements showing unchanged rows (a slider being dragged, say) stay alive.
fn sync<T: Clone + PartialEq + 'static>(model: &VecModel<T>, rows: Vec<T>) {
    if model.row_count() != rows.len() {
        model.set_vec(rows);
        return;
    }
    for (index, row) in rows.into_iter().enumerate() {
        if model.row_data(index).as_ref() != Some(&row) {
            model.set_row_data(index, row);
        }
    }
}

fn text(value: &Value) -> SharedString {
    value.as_str().unwrap_or_default().into()
}

fn number(value: &Value) -> f32 {
    value.as_f64().unwrap_or(0.0) as f32
}

fn rows(value: &Value) -> &[Value] {
    value.as_array().map(Vec::as_slice).unwrap_or(&[])
}

/// Fader position, 0 to 1, for a volume from -60 to +6 dB.
fn fader(db: f32) -> f32 {
    ((db + 60.0) / 66.0).clamp(0.0, 1.0)
}

/// Meter length, 0 to 1, for a linear peak level: -60 dB at the foot, 0 dB
/// at `ZERO_DB`, +6 dB at the top.
fn meter(peak: f32) -> f32 {
    ((20.0 * peak.max(1e-6).log10() + 60.0) / 66.0).clamp(0.0, 1.0)
}

/// Where 0 dB is along a meter.
const ZERO_DB: f32 = 60.0 / 66.0;

/// A number of decibels as the window writes them, with a true minus sign.
fn decibels(db: f32) -> String {
    if db <= -60.0 {
        return "\u{2212}inf".into();
    }
    let text = format!("{:.1}", if db.abs() < 0.05 { 0.0 } else { db });
    text.replacen('-', "\u{2212}", 1)
}

/// A meter's peaks, held a moment and then let fall, and the light that
/// comes on when a level reaches 0 dB and stays on until it is cleared.
#[derive(Clone, Copy, Default, Debug, PartialEq)]
struct PeakHold {
    /// Each side's peak, as a meter length, and how long it has been held.
    level: [f32; 2],
    held: [f32; 2],
    clipped: bool,
}

impl PeakHold {
    /// How long a peak stays before it falls, and how fast it falls then.
    const HOLD: f32 = 1.5;
    const FALL: f32 = 20.0 / 66.0;

    /// Take in both sides' levels, `dt` seconds after the last ones.
    fn update(&mut self, levels: [f32; 2], dt: f32) {
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

    /// The louder side's peak in dB, for a strip's readout.
    fn text(&self) -> String {
        let level = self.level[0].max(self.level[1]);
        decibels(if level <= 0.0 {
            -60.0
        } else {
            level * 66.0 - 60.0
        })
    }
}

/// A parameter's name with a capital letter, as a label.
fn capitalised(name: &str) -> String {
    let mut chars = name.chars();
    chars.next().map_or_else(String::new, |first| {
        first.to_uppercase().chain(chars).collect()
    })
}

/// How many keys of the piano roll show at once.
const ROLL_ROWS: i32 = 18;

/// A colour as the kernel writes it, `#rrggbb`.
fn colour(value: &Value) -> Color {
    let hex = value.as_str().unwrap_or("#7a8194").trim_start_matches('#');
    let channel =
        |at: usize| u8::from_str_radix(hex.get(at..at + 2).unwrap_or("80"), 16).unwrap_or(0x80);
    Color::from_rgb_u8(channel(0), channel(2), channel(4))
}

thread_local! {
    /// The song's bar and beat lines as the kernel last sent them: (beat,
    /// bar from 1, beat in the bar from 0), for the piano roll.
    static SONG_LINES: RefCell<Vec<(f64, i64, i64)>> = const { RefCell::new(Vec::new()) };
}

/// A song position as bar.beat.sixteenth by the tempo map's lines.
fn place_of(pos: f64) -> SharedString {
    SONG_LINES.with(|lines| {
        let lines = lines.borrow();
        let i = lines.partition_point(|l| l.0 <= pos + 1e-4);
        let Some(&(beat, bar, index)) = i.checked_sub(1).and_then(|i| lines.get(i)) else {
            return SharedString::from("1.1.1");
        };
        let unit = lines.get(i).map_or(1.0, |next| next.0 - beat).max(1e-6);
        let part = (((pos - beat) / unit * 4.0 + 1e-4).floor() as i64).clamp(0, 3) + 1;
        format!("{bar}.{}.{part}", index + 1).into()
    })
}

/// The song's lines over a clip, in the clip's beats, for the piano roll.
fn roll_lines(start: f32, length: f32) -> ModelRc<RollLine> {
    let (start, length) = (start as f64, length as f64);
    let lines: Vec<RollLine> = SONG_LINES.with(|lines| {
        lines
            .borrow()
            .iter()
            .filter(|l| l.0 >= start - 1e-6 && l.0 <= start + length + 8.0)
            .map(|&(beat, bar, index)| RollLine {
                at: (beat - start) as f32,
                bar: index == 0,
                label: if index == 0 {
                    format!("{bar}").into()
                } else {
                    format!("{bar}.{}", index + 1).into()
                },
            })
            .collect()
    });
    ModelRc::from(Rc::new(VecModel::from(lines)))
}

/// The tempo map's bar and beat lines, as the kernel sends them.
fn tempo_lines(list: &Value) -> Vec<RulerLine> {
    SONG_LINES.with(|lines| {
        *lines.borrow_mut() = rows(list)
            .iter()
            .map(|l| {
                let index = l["index"].as_i64().unwrap_or(0);
                (
                    number(&l["beat"]) as f64,
                    l["bar"].as_i64().unwrap_or(1),
                    index,
                )
            })
            .collect();
    });
    let lines: Vec<RulerLine> = rows(list)
        .iter()
        .map(|l| RulerLine {
            beat: number(&l["beat"]),
            label: text(&l["label"]),
            next: number(&l["next"]),
            bar: l["bar"].as_i64().unwrap_or(1) as i32,
            place: text(&l["place"]),
        })
        .collect();
    lines
}

/// A lane's curve over beats `from` to `to` alone, as a path in pixels at
/// `zoom` (a beat's width): flat before its first point and after its
/// last. Only the stretch that shows is drawn, however long the song.
fn lane_path(
    points: &[(f32, f32)],
    from: f32,
    to: f32,
    zoom: f32,
    y: impl Fn(f32) -> f32,
) -> String {
    let (Some(first), Some(last)) = (points.first(), points.last()) else {
        return String::new();
    };
    let at = |beat: f32| -> f32 {
        if beat <= first.0 {
            return first.1;
        }
        if beat >= last.0 {
            return last.1;
        }
        let next = points.partition_point(|p| p.0 <= beat);
        let (a, b) = (points[next - 1], points[next]);
        if b.0 - a.0 <= f32::EPSILON {
            b.1
        } else {
            a.1 + (b.1 - a.1) * (beat - a.0) / (b.0 - a.0)
        }
    };
    let from = from.max(0.0);
    let to = to.max(from);
    let mut path = format!("M {:.1} {:.1}", from * zoom, y(at(from)));
    for (beat, value) in points.iter().filter(|p| p.0 > from && p.0 < to) {
        path += &format!(" L {:.1} {:.1}", beat * zoom, y(*value));
    }
    path += &format!(" L {:.1} {:.1}", to * zoom, y(at(to)));
    path
}

/// The lines of `all` to draw when beats `from` to `to` show at `zoom`
/// pixels a beat: those in view and a little beyond, and when bars are
/// too close together to tell apart, only every second, fourth or eighth.
/// A long song has thousands of lines, and each one drawn is an element.
fn lines_in_view(all: &[RulerLine], from: f32, to: f32, zoom: f32) -> Vec<RulerLine> {
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
    all.iter()
        .filter(|l| l.beat >= from && l.beat <= to)
        .filter(|l| {
            if l.label.is_empty() {
                beats_show
            } else {
                (l.bar - 1) % every == 0
            }
        })
        .cloned()
        .collect()
}

/// Tempo and signature changes, for the ruler's flags.
fn tempo_marks(list: &Value) -> ModelRc<TempoMark> {
    let marks: Vec<TempoMark> = rows(list)
        .iter()
        .map(|m| TempoMark {
            beat: number(&m["beat"]),
            text: text(&m["text"]),
            tempo: m["kind"] == "tempo",
        })
        .collect();
    ModelRc::from(Rc::new(VecModel::from(marks)))
}

/// Where a pan from -1 to 1 points, in a few letters: `L30`, `C`, `R100`.
/// A menu's entries as the kernel lists them: `{ label, checked }`.
fn choices(list: &Value) -> ModelRc<ChoiceData> {
    let entries: Vec<ChoiceData> = rows(list)
        .iter()
        .map(|entry| ChoiceData {
            label: text(&entry["label"]),
            checked: entry["checked"].as_bool().unwrap_or(false),
        })
        .collect();
    ModelRc::from(Rc::new(VecModel::from(entries)))
}

fn pan_text(pan: f32) -> String {
    let amount = (pan.abs() * 100.0).round() as i32;
    match amount {
        0 => "C".into(),
        _ if pan < 0.0 => format!("L{amount}"),
        _ => format!("R{amount}"),
    }
}

/// A picture to tint: opaque where `lit` says so, clear elsewhere.
fn mask(width: usize, height: usize, lit: impl Fn(usize, usize) -> bool) -> Image {
    let mut buffer = SharedPixelBuffer::<Rgba8Pixel>::new(width as u32, height as u32);
    for (index, pixel) in buffer.make_mut_slice().iter_mut().enumerate() {
        let on = lit(index % width, index / width);
        *pixel = Rgba8Pixel::new(255, 255, 255, if on { 255 } else { 0 });
    }
    Image::from_rgba8(buffer)
}

/// A clip's notes as a small piano roll: `flat` is start, length and pitch
/// for each note, and the picture covers the clip's `length` beats.
fn notes_picture(flat: &[f32], length: f32) -> Image {
    const HEIGHT: usize = 24;
    let notes: Vec<(f32, f32, f32)> = flat.chunks_exact(3).map(|n| (n[0], n[1], n[2])).collect();
    if notes.is_empty() || length <= 0.0 {
        return Image::default();
    }
    let width = ((length * 12.0) as usize).clamp(16, 2048);
    let low = notes.iter().map(|n| n.2).fold(f32::MAX, f32::min);
    let high = notes.iter().map(|n| n.2).fold(f32::MIN, f32::max);
    // A few pitches fill the height; many share it, a row or two each.
    let span = (high - low + 1.0).max(6.0);
    let thick = ((HEIGHT as f32 / span).floor() as usize).clamp(2, 4);
    let mut rows = vec![false; width * HEIGHT];
    for (start, len, pitch) in notes {
        let x0 = ((start / length * width as f32) as usize).min(width - 1);
        let x1 = (((start + len) / length * width as f32).ceil() as usize).clamp(x0 + 1, width);
        // A hair off the end, so that notes that follow each other stay apart.
        let x1 = if x1 - x0 > 2 { x1 - 1 } else { x1 };
        let centre = (pitch - low + 0.5 + (span - (high - low + 1.0)) / 2.0) / span;
        let y0 = (((1.0 - centre) * HEIGHT as f32) as usize).min(HEIGHT - thick);
        for y in y0..y0 + thick {
            rows[y * width + x0..y * width + x1].fill(true);
        }
    }
    mask(width, HEIGHT, |x, y| rows[y * width + x])
}

/// A picture to tint, as opaque at each place as `alpha` says.
fn shade(width: usize, height: usize, alpha: impl Fn(usize, usize) -> u8) -> Image {
    let mut buffer = SharedPixelBuffer::<Rgba8Pixel>::new(width as u32, height as u32);
    for (index, pixel) in buffer.make_mut_slice().iter_mut().enumerate() {
        // The colour is carried in full so that tinting keeps the shading.
        let a = alpha(index % width, index / width);
        *pixel = Rgba8Pixel::new(a, a, a, a);
    }
    Image::from_rgba8(buffer)
}

/// How many points to ask for to draw a waveform `pixels` wide: the next
/// power of two, so that a small change of zoom does not fetch it again.
fn wave_points(pixels: f32) -> usize {
    (pixels.max(1.0) as usize)
        .next_power_of_two()
        .clamp(64, 4096)
}

/// An audio clip's waveform, a column for each (min, max, rms) of `peaks`:
/// how far the wave reaches each way, drawn lightly, and inside it how loud
/// it is, drawn solid, as a waveform looks in an audio editor.
fn wave_picture(peaks: &[f32]) -> Image {
    const HEIGHT: usize = 64;
    let columns: Vec<(f32, f32, f32)> = peaks
        .chunks_exact(3)
        .map(|p| {
            (
                p[0].clamp(-1.0, 1.0),
                p[1].clamp(-1.0, 1.0),
                p[2].clamp(0.0, 1.0),
            )
        })
        .collect();
    if columns.is_empty() {
        return Image::default();
    }
    let half = HEIGHT as f32 / 2.0;
    shade(columns.len(), HEIGHT, |x, y| {
        let (low, high, rms) = columns[x];
        // Up from the middle is positive.
        let at = (half - (y as f32 + 0.5)) / half;
        if at.abs() <= rms.max(0.5 / half) {
            255
        } else if at <= high && at >= low {
            130
        } else {
            0
        }
    })
}

/// A key press in the notation of the kernel's key mappings: `a`, `<CR>`,
/// `<C-r>`, `<S-Left>`. None for a press of a modifier alone.
fn notation(text: &str, ctrl: bool, alt: bool, shift: bool) -> Option<String> {
    use slint::platform::Key;
    let mut chars = text.chars();
    let key = chars.next()?;
    if chars.next().is_some() {
        // Composed text arrives whole.
        return Some(text.replace('<', "<lt>"));
    }
    let named = [
        (Key::Escape, "Esc"),
        (Key::Return, "CR"),
        (Key::Backspace, "BS"),
        (Key::Tab, "Tab"),
        (Key::Backtab, "S-Tab"),
        (Key::Delete, "Del"),
        (Key::UpArrow, "Up"),
        (Key::DownArrow, "Down"),
        (Key::LeftArrow, "Left"),
        (Key::RightArrow, "Right"),
        (Key::Home, "Home"),
        (Key::End, "End"),
        (Key::PageUp, "PageUp"),
        (Key::PageDown, "PageDown"),
        (Key::Insert, "Insert"),
    ];
    let (name, is_char) = match named.iter().find(|(k, _)| char::from(*k) == key) {
        Some((_, name)) => (name.to_string(), false),
        None if key == ' ' => ("Space".to_string(), false),
        None if key == '<' => ("lt".to_string(), false),
        // With Control held some systems send the control character.
        None if ctrl && (key as u32) < 0x20 => (((key as u8 + 0x60) as char).to_string(), true),
        // What is left below a space, or in the private range Slint uses for
        // keys, is a modifier or a key with no name here.
        None if (key as u32) < 0x20
            || key == '\u{7f}'
            || ('\u{e000}'..='\u{f8ff}').contains(&key) =>
        {
            return None;
        }
        None => (key.to_string(), true),
    };
    let mut prefix = String::new();
    if ctrl {
        prefix.push_str("C-");
    }
    if alt {
        prefix.push_str("A-");
    }
    // Shift is already part of a typed character, and of `S-Tab`.
    if shift && !is_char && name != "S-Tab" {
        prefix.push_str("S-");
    }
    Some(if prefix.is_empty() && is_char {
        name
    } else {
        format!("<{prefix}{name}>")
    })
}

/// Keys the window gives a meaning of its own, as other programs do, before
/// they go to the kernel's key mappings: in the piano roll Ctrl-A chooses
/// every note (`gA`) rather than raising the note under the cursor.
fn window_keys(keys: String, in_roll: bool) -> String {
    if in_roll && keys == "<C-a>" {
        "gA".to_string()
    } else {
        keys
    }
}

/// An automation lane as the kernel reports it, with its points as
/// (beat, height from 0 to 1 over the stretch it is drawn over).
struct Lane {
    id: i32,
    name: SharedString,
    param: bool,
    enabled: bool,
    points: Vec<(f32, f32)>,
}

/// Height of a track's row in the timeline, and of the strip under the
/// piano roll, in pixels: as in the `.slint` files.
/// How a click or a box changes which notes are chosen, as the kernel names it.
const MODES: [&str; 3] = ["only", "add", "toggle"];
/// How tall a lane shown as a row of its own is, as a share of the height
/// of a track at the zoom.
const LANE_ROW: f32 = 0.8;
/// And a take lane.
const TAKE_ROW: f32 = 0.6;
const STRIP: f32 = 79.0;

/// A clip with takes on a track that shows its take lanes, as the kernel
/// reports it: its row, where it is, which take plays, and each take's name
/// and the key that changes when its picture does.
struct TakeClip {
    id: i32,
    row: usize,
    start: f32,
    length: f32,
    midi: bool,
    take: i32,
    takes: Vec<(SharedString, String)>,
}

/// What the strip under the piano roll shows, by its number there: the
/// kind of controller and, for a control change, which.
fn strip_kind(lane: i32) -> Option<(&'static str, Option<i64>)> {
    match lane {
        1 => Some(("bend", None)),
        2 => Some(("cc", Some(1))),
        3 => Some(("cc", Some(11))),
        4 => Some(("cc", Some(64))),
        _ => None,
    }
}

/// A stroke of the pencil as a path, with `x` and `y` giving where a beat
/// and a height are in pixels.
fn stroke_path(points: &[(f32, f32)], x: impl Fn(f32) -> f32, y: impl Fn(f32) -> f32) -> String {
    let mut path = String::new();
    for (index, (beat, value)) in points.iter().enumerate() {
        let command = if index == 0 { "M" } else { "L" };
        path += &format!("{command} {:.1} {:.1} ", x(*beat), y(*value));
    }
    path
}

/// What a stroke over the velocity strip gives each note, as the kernel's
/// `draw_velocities` will: the height drawn above the start of each note
/// within the stretch drawn over (or within `reach` beats of a click), only
/// the chosen notes when any are chosen; -1 for the notes it leaves alone.
fn velocity_preview(stroke: &[(f32, f32)], notes: &[NoteData], reach: f32) -> Vec<f32> {
    let mut points = stroke.to_vec();
    points.sort_by(|a, b| a.0.total_cmp(&b.0));
    let (Some(first), Some(last)) = (points.first().copied(), points.last().copied()) else {
        return Vec::new();
    };
    let height = |beat: f32| {
        if beat <= first.0 {
            return first.1;
        }
        for pair in points.windows(2) {
            let (a, b) = (pair[0], pair[1]);
            if beat <= b.0 {
                return if b.0 > a.0 {
                    a.1 + (b.1 - a.1) * (beat - a.0) / (b.0 - a.0)
                } else {
                    b.1
                };
            }
        }
        last.1
    };
    let any = notes.iter().any(|n| n.selected);
    notes
        .iter()
        .map(|n| {
            let within = n.start >= first.0 - reach - 1e-6 && n.start <= last.0 + reach + 1e-6;
            if within && (!any || n.selected) {
                height(n.start).clamp(1.0 / 127.0, 1.0)
            } else {
                -1.0
            }
        })
        .collect()
}

/// A window an extension's view paints in.
struct Canvas {
    window: CanvasWindow,
    items: Rc<VecModel<CanvasItem>>,
    painted: Instant,
    size: (f32, f32),
}

/// A colour of a drawing: `#rrggbb`, `#rrggbbaa`, or nothing for none.
fn paint_colour(value: &Value) -> Color {
    let hex = value.as_str().unwrap_or("").trim_start_matches('#');
    let channel = |at: usize| {
        hex.get(at..at + 2)
            .and_then(|h| u8::from_str_radix(h, 16).ok())
    };
    match (channel(0), channel(2), channel(4)) {
        (Some(r), Some(g), Some(b)) => Color::from_argb_u8(channel(6).unwrap_or(255), r, g, b),
        _ => Color::from_argb_u8(0, 0, 0, 0),
    }
}

/// One operation of a drawing (see `daw.canvas.paint`) as the window shows it.
fn canvas_item(op: &Value) -> Option<CanvasItem> {
    let clear = Color::from_argb_u8(0, 0, 0, 0);
    let mut item = CanvasItem {
        kind: 0,
        x: 0.0,
        y: 0.0,
        w: 0.0,
        h: 0.0,
        text: SharedString::new(),
        fill: clear,
        stroke: clear,
        stroke_width: 1.0,
        radius: 0.0,
        size: 12.0,
        bold: false,
        align: 0,
    };
    match op[0].as_str()? {
        "r" => {
            (item.x, item.y) = (number(&op[1]), number(&op[2]));
            (item.w, item.h) = (number(&op[3]), number(&op[4]));
            (item.fill, item.stroke) = (paint_colour(&op[5]), paint_colour(&op[6]));
            (item.stroke_width, item.radius) = (number(&op[7]), number(&op[8]));
        }
        "t" => {
            item.kind = 1;
            (item.x, item.y) = (number(&op[1]), number(&op[2]));
            item.text = text(&op[3]);
            item.fill = paint_colour(&op[4]);
            item.size = number(&op[5]);
            item.bold = number(&op[6]) > 0.5;
            item.align = match op[7].as_str() {
                Some("center") => 1,
                Some("right") => 2,
                _ => 0,
            };
            (item.w, item.h) = (number(&op[8]).min(4000.0), item.size * 1.5);
            if item.align == 1 {
                // Centred text is centred on its `x`.
                item.x -= item.w / 2.0;
            } else if item.align == 2 {
                item.x -= item.w;
            }
        }
        "p" => {
            item.kind = 2;
            item.text = text(&op[1]);
            (item.stroke, item.stroke_width) = (paint_colour(&op[2]), number(&op[3]));
            item.fill = paint_colour(&op[4]);
        }
        _ => return None,
    }
    Some(item)
}

/// What the window shows, and which revision of the project it reflects.
struct View {
    /// How many notes of the clip in the piano roll are hidden before its
    /// start and left out of the roll.
    roll_hidden: usize,
    /// Where each row of the timeline starts, in rows of the zoom's height,
    /// and after the last where they all end: for `row-at-rows`.
    tops: Rc<RefCell<Vec<f32>>>,
    revision: i64,
    tracks: Rc<VecModel<TrackData>>,
    clips: Rc<VecModel<ClipData>>,
    devices: Rc<VecModel<DeviceData>>,
    /// The parameter rows of each device, in the order of `devices`.
    params: Vec<Rc<VecModel<ParamData>>>,
    /// The picture inside each clip (its notes or its waveform), with the
    /// key that says when to make it again.
    pictures: HashMap<i32, (String, Image)>,
    /// Every track's automation lanes as the kernel last reported them,
    /// by row, kept to redraw their curves when the zoom changes.
    lane_data: Vec<(i32, Vec<Lane>)>,
    /// The lane each track shows, by track id, when one was chosen; and the
    /// one each row ended up showing.
    shown: HashMap<i32, i32>,
    row_lane: Vec<Option<i32>>,
    /// What the pencil has drawn so far over a lane, as (beat, height).
    pencil: Vec<(f32, f32)>,
    /// And over the piano roll's strip.
    control_stroke: Vec<(f32, f32)>,
    /// Where the piano roll's eraser has gone, as (beat, pitch).
    erase_stroke: Vec<(f32, f32)>,
    /// Notes of the roll's track's other clips that sound during its clip,
    /// and which keys sound now.
    ghosts: Rc<VecModel<NoteData>>,
    sounding: Rc<VecModel<bool>>,
    /// The velocities a stroke over the strip is giving, by note, -1 for
    /// none: shown until the kernel's own come back.
    vel_preview: Rc<VecModel<f32>>,
    /// The controller moves of the clip in the piano roll, and which kind
    /// the strip shows.
    roll_controls: Vec<Value>,
    strip: i32,
    controls: Rc<VecModel<ControlData>>,
    /// The piano roll's own window, and whether the roll is in it.
    roll_window: RollWindow,
    detached: bool,
    /// Where the take being made began.
    rec_start: Option<f32>,
    /// The views that paint, as the kernel lists them: name, title, size.
    windows: Vec<(String, String, f32, f32)>,
    /// Set when something happened that a painted view may show.
    repaint: bool,
    lanes: Rc<VecModel<LaneData>>,
    points: Rc<VecModel<PointData>>,
    /// The lanes shown as rows of their own, and their points; and for
    /// each row, the ids of the lanes its track shows that way.
    strips: Rc<VecModel<LaneData>>,
    strip_points: Rc<VecModel<PointData>>,
    lane_rows: Vec<Vec<i32>>,
    /// How many take lanes each row shows under its clips, the clips that
    /// have takes on those rows, and what is drawn of them: the lanes, the
    /// takes of the clips in view, and each take's picture by clip and take
    /// with the key that says when to make it again.
    take_rows: Vec<usize>,
    take_clips: Vec<TakeClip>,
    take_lanes: Rc<VecModel<TakeLaneData>>,
    take_pieces: Rc<VecModel<TakePiece>>,
    take_pictures: HashMap<(i32, usize), (String, Image)>,
    markers: Rc<VecModel<MarkerData>>,
    /// Every bar and beat line of the song, and the ones being drawn: those
    /// of the stretch `lines_for` (beats, and the zoom they were chosen at).
    all_lines: Vec<RulerLine>,
    /// The stretch of the song, in beats, the lanes' curves are laid out over.
    lanes_for: Option<(f32, f32)>,
    ruler_lines: Rc<VecModel<RulerLine>>,
    lines_for: Option<(f32, f32, f32)>,
    render_ranges: Rc<VecModel<RangeChoice>>,
    /// What the File menu was asked for while there were changes to save.
    leaving: String,
    zoom: f32,
    /// The height of a track's row the automation was last drawn for.
    row: f32,
    /// The kinds of the devices the search box lists, and what was typed.
    hits: Vec<String>,
    query: String,
    /// The clip open in the piano roll, and whether its notes need fetching.
    roll: Option<i32>,
    roll_stale: bool,
    notes: Rc<VecModel<NoteData>>,
    hints: Rc<VecModel<HintData>>,
    clip_entries: Rc<VecModel<MenuEntry>>,
    /// The tracks the selected one can play into, by id, the master first.
    route_ids: Vec<i64>,
    route_targets: Rc<VecModel<SharedString>>,
    route_sends: Rc<VecModel<SendData>>,
    track_entries: Rc<VecModel<MenuEntry>>,
    timeline_entries: Rc<VecModel<MenuEntry>>,
    message_until: Option<Instant>,
    /// The meters' held peaks and clip lights, by track id, and when the
    /// meters were last read.
    peaks: HashMap<i32, PeakHold>,
    meters_at: Option<Instant>,
}

impl View {
    fn show(&mut self, ui: &App, message: &str, is_error: bool) {
        ui.set_message(message.into());
        ui.set_message_is_error(is_error);
        self.message_until = Some(Instant::now() + MESSAGE_TIME);
    }

    /// Ask the kernel what to draw and update the window.
    /// Keep the lines that are drawn to the stretch of the song that shows.
    fn show_lines(&mut self, ui: &App) {
        let (from, to, zoom) = (ui.get_view_start(), ui.get_view_end(), ui.get_zoom());
        let span = (to - from).max(1.0);
        if let Some((kept_from, kept_to, kept_zoom)) = self.lines_for
            && kept_zoom == zoom
            && from >= kept_from
            && to <= kept_to
            // Zoomed out so far that the stretch kept is the whole song.
            && kept_to - kept_from < span * 4.0
        {
            return;
        }
        // A screen's worth on either side, so that scrolling a little needs nothing new.
        let (keep_from, keep_to) = (from - span, to + span);
        sync(
            &self.ruler_lines,
            lines_in_view(&self.all_lines, keep_from, keep_to, zoom),
        );
        self.lines_for = Some((keep_from, keep_to, zoom));
    }

    fn refresh(&mut self, ui: &App, client: &mut Client) -> Result<()> {
        self.show_lines(ui);
        if self
            .message_until
            .is_some_and(|until| Instant::now() > until)
        {
            ui.set_message("".into());
            self.message_until = None;
        }
        let state = client.eval("daw.frontend.state(...)", json!([self.revision]))?;
        let playing = state["playing"].as_bool().unwrap_or(false);
        let recording = state["recording"].as_bool().unwrap_or(false);
        let position = number(&state["position"]);
        ui.set_playing(playing);
        ui.set_recording(recording);
        ui.set_position(position);
        // A take is drawn from where the playhead was when it began.
        match (recording, self.rec_start) {
            (true, None) => {
                self.rec_start = Some(position);
                ui.set_rec_start(position);
            }
            (false, Some(_)) => self.rec_start = None,
            _ => {}
        }
        for roll in self.rolls(ui) {
            roll.set_position(position);
            roll.set_playing(playing);
        }
        self.sound_keys(ui, playing, position);
        self.repaint |= playing || state.get("project").is_some();
        ui.set_time(text(&state["time"]));
        ui.set_clock(text(&state["clock"]));
        // The tempo and signature where the playhead is.
        if let Some(tempo) = state["tempo"].as_f64() {
            ui.set_tempo(format!("{tempo}").into());
            ui.set_signature(text(&state["signature"]));
        }
        ui.set_cpu(number(&state["cpu"]));
        ui.set_record_armed(state["armed"].as_bool().unwrap_or(false));
        ui.set_counting(state["counting"].as_i64().unwrap_or(0) as i32);
        let levels: Vec<f32> = rows(&state["levels"])
            .iter()
            .map(|v| meter(number(v)))
            .collect();

        if let Some(project) = state.get("project") {
            self.revision = state["revision"].as_i64().unwrap_or(0);
            self.project(ui, client, &state, project);
        }
        if state.get("project").is_some() {
            self.roll_stale = true;
        }
        self.modal(ui, client, &state["modal"])?;
        if let (Some(id), true) = (self.roll, std::mem::take(&mut self.roll_stale)) {
            self.show_roll(ui, client, id)?;
        }
        // Scrolled past the stretch the curves were laid out over.
        let out_of_view = self.lanes_for.is_none_or(|(from, to)| {
            ui.get_view_start() < from || ui.get_view_end() > to
        });
        if out_of_view && ui.get_zoom() == self.zoom && ui.get_row_height() == self.row {
            self.draw_lanes(ui);
            self.draw_takes(ui, client);
        }
        if ui.get_zoom() != self.zoom || ui.get_row_height() != self.row {
            self.draw_lanes(ui);
            self.draw_takes(ui, client);
            // Waveforms are drawn again at the width they now have.
            for index in 0..self.clips.row_count() {
                let Some(mut clip) = self.clips.row_data(index) else {
                    continue;
                };
                if clip.midi {
                    continue;
                }
                let Some(key) = self.pictures.get(&clip.id).map(|(key, _)| {
                    key.rsplit_once('@')
                        .map_or(key.as_str(), |(base, _)| base)
                        .to_string()
                }) else {
                    continue;
                };
                let picture =
                    self.picture(client, clip.id, &key, false, clip.length, ui.get_zoom());
                if picture != clip.preview {
                    clip.preview = picture;
                    self.clips.set_row_data(index, clip);
                }
            }
        }
        // The strip under the piano roll may have been switched.
        let strip = self.active_roll(ui).get_lane();
        if strip != self.strip {
            self.strip = strip;
            self.show_controls(ui);
        }
        // Meters move every frame, on their own: both sides of each track,
        // and what arrives at its input.
        let inputs: Vec<f32> = rows(&state["inputs"])
            .iter()
            .map(|v| meter(number(v)))
            .collect();
        // Peaks are held a moment, then fall.
        let now = Instant::now();
        let dt = self
            .meters_at
            .map_or(0.0, |at| now.duration_since(at).as_secs_f32().min(0.5));
        self.meters_at = Some(now);
        for (index, level) in levels.chunks_exact(2).enumerate() {
            let input = inputs.get(index).copied().unwrap_or(0.0);
            let Some(mut track) = self.tracks.row_data(index) else {
                continue;
            };
            let peak = self.peaks.entry(track.id).or_default();
            peak.update([level[0], level[1]], dt);
            let peak = *peak;
            if (track.level_l - level[0]).abs() > 0.004
                || (track.level_r - level[1]).abs() > 0.004
                || (track.input_level - input).abs() > 0.004
                || (track.hold_l - peak.level[0]).abs() > 0.004
                || (track.hold_r - peak.level[1]).abs() > 0.004
                || track.clipped != peak.clipped
            {
                track.level_l = level[0];
                track.level_r = level[1];
                track.input_level = input;
                track.hold_l = peak.level[0];
                track.hold_r = peak.level[1];
                track.clipped = peak.clipped;
                track.peak_text = peak.text().into();
                self.tracks.set_row_data(index, track);
            }
        }
        Ok(())
    }

    /// The piano roll's state in both of the windows that can show it.
    fn rolls<'a>(&'a self, ui: &'a App) -> [Roll<'a>; 2] {
        [ui.global::<Roll>(), self.roll_window.global::<Roll>()]
    }

    /// The one the roll is showing in.
    fn active_roll<'a>(&'a self, ui: &'a App) -> Roll<'a> {
        if self.detached {
            self.roll_window.global::<Roll>()
        } else {
            ui.global::<Roll>()
        }
    }

    /// Light the piano roll's keys whose notes sound at the playhead.
    fn sound_keys(&self, ui: &App, playing: bool, position: f32) {
        let mut lit = [false; 128];
        if playing && self.roll.is_some() {
            let at = position - ui.global::<Roll>().get_start();
            for note in self.notes.iter() {
                if note.start <= at && at < note.start + note.length {
                    lit[note.pitch.clamp(0, 127) as usize] = true;
                }
            }
        }
        for (pitch, on) in lit.into_iter().enumerate() {
            if self.sounding.row_data(pitch) != Some(on) {
                self.sounding.set_row_data(pitch, on);
            }
        }
    }

    /// Show the roll's open clip as closed, in both windows.
    fn close_roll(&mut self, ui: &App) {
        for roll in self.rolls(ui) {
            roll.set_open(false);
        }
        let _ = self.roll_window.hide();
    }

    /// Fill the strip under the piano roll with the controller it shows.
    fn show_controls(&mut self, ui: &App) {
        let moves: Vec<ControlData> = match strip_kind(self.strip) {
            None => Vec::new(),
            Some((kind, number)) => self
                .roll_controls
                .iter()
                .filter(|c| c["type"] == kind && c["key"].is_null())
                .filter(|c| number.is_none() || c["number"].as_i64() == number)
                .map(|c| ControlData {
                    start: self::number(&c["start"]),
                    value: if kind == "bend" {
                        (self::number(&c["value"]) + 1.0) / 2.0
                    } else {
                        self::number(&c["value"])
                    },
                })
                .collect(),
        };
        sync(&self.controls, moves);
        let _ = ui;
    }

    /// Show where the kernel's key mappings are: the mode, the prompt or
    /// message, the selection, the hints, and the panels' cursors.
    fn modal(&mut self, ui: &App, client: &mut Client, modal: &Value) -> Result<()> {
        ui.set_mode(text(&modal["mode"]));
        ui.set_mode_name(text(&modal["name"]));
        ui.set_pending(text(&modal["pending"]));
        ui.set_macro(text(&modal["recording"]));
        ui.set_focused(text(&modal["focused"]));
        ui.set_show_mixer(modal["mixer"].as_bool().unwrap_or(false));
        // A render in the background, and a controller being waited for.
        let render = &modal["render"];
        ui.set_rendering(render.is_object());
        ui.set_render_fraction(number(&render["fraction"]));
        ui.set_render_name(
            render["path"]
                .as_str()
                .and_then(|path| path.rsplit('/').next())
                .unwrap_or("")
                .into(),
        );
        ui.set_learning(text(&modal["learning"]));
        ui.set_selected_clip(modal["clip"].as_i64().unwrap_or(-1) as i32);
        for roll in self.rolls(ui) {
            roll.set_mode(text(&modal["mode"]));
            roll.set_focused(modal["focused"] == "pianoroll");
        }
        self.windows = rows(&modal["windows"])
            .iter()
            .map(|w| {
                (
                    text(&w["name"]).to_string(),
                    text(&w["title"]).to_string(),
                    number(&w["width"]),
                    number(&w["height"]),
                )
            })
            .collect();

        let prompt = &modal["prompt"];
        ui.set_prompt_open(prompt.is_object());
        ui.set_prompt(text(&prompt["prompt"]));
        ui.set_prompt_before(text(&prompt["before"]));
        ui.set_prompt_after(text(&prompt["after"]));
        ui.set_status(text(&modal["message"]["text"]));
        ui.set_status_level(match modal["message"]["level"].as_str() {
            Some("error") => 2,
            Some("warn") => 1,
            _ => 0,
        });

        // Rows are tracks from the top in the arrange view, and pitches from
        // the top key down in the piano roll.
        let selection = &modal["selection"];
        ui.set_sel_open(selection.is_object());
        if selection.is_object() {
            let (r0, r1) = (
                selection["r0"].as_i64().unwrap_or(0) as i32,
                selection["r1"].as_i64().unwrap_or(0) as i32,
            );
            ui.set_sel_kind(text(&selection["kind"]));
            ui.set_sel_row(if selection["view"] == "pianoroll" {
                127 - r1
            } else {
                r0 - 1
            });
            ui.set_sel_rows(r1 - r0 + 1);
            ui.set_sel_start(number(&selection["c0"]));
            ui.set_sel_end(number(&selection["c1"]));
        }
        for roll in self.rolls(ui) {
            roll.set_sel_open(selection.is_object());
            roll.set_sel_kind(ui.get_sel_kind());
            roll.set_sel_row(ui.get_sel_row());
            roll.set_sel_rows(ui.get_sel_rows());
            roll.set_sel_start(ui.get_sel_start());
            roll.set_sel_end(ui.get_sel_end());
        }

        let hints: Vec<HintData> = rows(&modal["hints"]["items"])
            .iter()
            .map(|hint| HintData {
                key: text(&hint["key"]),
                desc: text(&hint["desc"]),
            })
            .collect();
        sync(&self.hints, hints);
        for (kind, model) in [
            ("clip", &self.clip_entries),
            ("track", &self.track_entries),
            ("timeline", &self.timeline_entries),
        ] {
            let entries: Vec<MenuEntry> = rows(&modal["menus"][kind])
                .iter()
                .map(|entry| MenuEntry {
                    label: text(&entry["label"]),
                    only: text(&entry["only"]),
                })
                .collect();
            sync(model, entries);
        }
        ui.set_hint_title(text(&modal["hints"]["title"]));

        // A floating page is drawn by the kernel as text.
        if modal["float"].is_string() {
            let float = client.eval("daw.frontend.float(104, 40)", json!([]))?;
            let lines: Vec<&str> = rows(&float["lines"])
                .iter()
                .filter_map(Value::as_str)
                .collect();
            ui.set_float_title(text(&float["title"]));
            ui.set_float_lines(lines.len().max(1) as i32);
            ui.set_float_text(lines.join("\n").into());
        }
        ui.set_float_open(modal["float"].is_string());

        // The piano roll shows the clip the kernel's has open.
        let roll = &modal["roll"];
        let open = roll["clip"].as_i64().map(|id| id as i32);
        if open != self.roll {
            self.roll = open;
            match open {
                Some(id) => self.show_roll(ui, client, id)?,
                None => self.close_roll(ui),
            }
        }
        if open.is_some() {
            // Which notes are chosen with the pointer.
            let chosen: Vec<usize> = rows(&roll["selected"])
                .iter()
                .filter_map(|place| (place.as_u64()? as usize).checked_sub(1 + self.roll_hidden))
                .collect();
            for index in 0..self.notes.row_count() {
                let Some(mut note) = self.notes.row_data(index) else {
                    continue;
                };
                let selected = chosen.contains(&index);
                if note.selected != selected {
                    note.selected = selected;
                    self.notes.set_row_data(index, note);
                }
            }
            let pitch = roll["pitch"].as_i64().unwrap_or(60) as i32;
            let status: SharedString = if modal["mode"] == "i" {
                format!(
                    "entering notes · a is C{} · step {} · Esc to stop",
                    roll["octave"].as_i64().unwrap_or(4),
                    number(&roll["step"])
                )
                .into()
            } else {
                SharedString::default()
            };
            for shown in self.rolls(ui) {
                if pitch != shown.get_pitch() {
                    // Keep the cursor's row among the ones that show.
                    let (row, top) = (127 - pitch, shown.get_top());
                    if row < top + 1 {
                        shown.set_top((row - 3).clamp(0, 105));
                    } else if row > top + ROLL_ROWS - 2 {
                        shown.set_top((row - ROLL_ROWS + 4).clamp(0, 105));
                    }
                }
                shown.set_pitch(pitch);
                shown.set_cursor(number(&roll["beat"]));
                shown.set_step(number(&roll["step"]));
                shown.set_status(status.clone());
                shown.set_snap(roll["snap"].as_bool().unwrap_or(true));
                shown.set_chosen_text(text(&roll["chosen"]));
                shown.set_step_input(roll["step_input"].as_bool().unwrap_or(false));
            }
        }
        ui.set_row_device(modal["device"].as_i64().unwrap_or(0) as i32);
        ui.set_row_param(modal["param"].as_i64().unwrap_or(-1) as i32);
        Ok(())
    }

    /// Fetch the clip in the piano roll and show its notes, or close the roll
    /// if the clip is gone.
    fn show_roll(&mut self, ui: &App, client: &mut Client, id: i32) -> Result<()> {
        let clip = client.eval("daw.frontend.clip(...)", json!([id]))?;
        if clip.is_null() || clip["kind"] != "midi" {
            self.roll = None;
            self.close_roll(ui);
            return Ok(());
        }
        self.roll_hidden = clip["hidden"].as_u64().unwrap_or(0) as usize;
        let notes: Vec<NoteData> = rows(&clip["notes"])
            .iter()
            .map(|n| NoteData {
                pitch: n["pitch"].as_i64().unwrap_or(60) as i32,
                start: number(&n["start"]),
                length: number(&n["length"]),
                velocity: (number(&n["velocity"]) / 127.0).clamp(0.0, 1.0),
                selected: false,
            })
            .collect();
        let ghosts: Vec<NoteData> = rows(&clip["ghosts"])
            .iter()
            .map(|n| NoteData {
                pitch: n["pitch"].as_i64().unwrap_or(60) as i32,
                start: number(&n["start"]),
                length: number(&n["length"]),
                velocity: (number(&n["velocity"]) / 127.0).clamp(0.0, 1.0),
                selected: false,
            })
            .collect();
        sync(&self.ghosts, ghosts);
        sync(&self.vel_preview, Vec::new());
        let was_open = ui.global::<Roll>().get_open();
        let highest = notes.iter().map(|n| n.pitch).max().unwrap_or(72);
        sync(&self.notes, notes);
        self.roll_controls = rows(&clip["controls"]).to_vec();
        self.show_controls(ui);
        let track: SharedString = format!(
            "{} · bar {}",
            text(&clip["track_name"]),
            1 + (number(&clip["start"]) / ui.get_bar()) as i32
        )
        .into();
        for roll in self.rolls(ui) {
            if !was_open {
                // Open with the highest note a few rows from the top.
                roll.set_top((127 - highest - 4).clamp(0, 105));
            }
            roll.set_title(text(&clip["name"]));
            roll.set_track(track.clone());
            roll.set_color(colour(&clip["color"]));
            roll.set_start(number(&clip["start"]));
            roll.set_length(number(&clip["length"]));
            roll.set_bar(ui.get_bar());
            roll.set_lines(roll_lines(roll.get_start(), roll.get_length()));
            roll.set_open(true);
        }
        if self.detached {
            let _ = self.roll_window.show();
        }
        Ok(())
    }

    /// Lay out the lane each track shows, in pixels at the current zoom: the
    /// one chosen for it, else the first that holds anything, else its first.
    fn draw_lanes(&mut self, ui: &App) {
        self.zoom = ui.get_zoom();
        self.row = ui.get_row_height();
        let row_height = self.row;
        // What shows, and a screen's worth on either side: curves and points
        // are laid out over that stretch alone, and again when it is left.
        let (view_from, view_to) = (ui.get_view_start(), ui.get_view_end());
        let span = (view_to - view_from).max(1.0);
        let (from, to) = (view_from - span, view_to + span);
        self.lanes_for = Some((from, to));
        let (mut lanes, mut points) = (Vec::new(), Vec::new());
        let (mut strips, mut strip_points) = (Vec::new(), Vec::new());
        self.row_lane = Vec::new();
        for (row, (track, all)) in self.lane_data.iter().enumerate() {
            // The lanes shown as rows of their own, under the track's clips
            // and its take lanes.
            let clip_size = self.tracks.row_data(row).map_or(1.0, |t| t.clip_size);
            let takes = self.take_rows.get(row).copied().unwrap_or(0) as f32 * TAKE_ROW;
            for (place, id) in self.lane_rows.get(row).into_iter().flatten().enumerate() {
                let Some(lane) = all.iter().find(|l| l.id == *id) else {
                    continue;
                };
                let top = clip_size + takes + place as f32 * LANE_ROW;
                // A little room above and below the curve.
                let y = |value: f32| (0.08 + (1.0 - value) * 0.84) * row_height * LANE_ROW;
                let path = lane_path(&lane.points, from, to, self.zoom, y);
                strips.push(LaneData {
                    id: lane.id,
                    row: row as i32,
                    name: lane.name.clone(),
                    enabled: lane.enabled,
                    path: path.into(),
                    top,
                    span: LANE_ROW,
                });
                for (index, (beat, value)) in lane.points.iter().enumerate() {
                    if *beat < from || *beat > to {
                        continue;
                    }
                    strip_points.push(PointData {
                        lane: lane.id,
                        index: index as i32,
                        row: row as i32,
                        beat: *beat,
                        value: *value,
                        top: top + 0.08 * LANE_ROW,
                        span: 0.84 * LANE_ROW,
                    });
                }
            }
            let chosen = self
                .shown
                .get(track)
                .and_then(|id| all.iter().find(|l| l.id == *id));
            let lane = chosen
                .or_else(|| all.iter().find(|l| !l.points.is_empty()))
                .or(all.first());
            self.row_lane.push(lane.map(|l| l.id));
            let Some(lane) = lane else { continue };
            // Over the clips, which are as tall as the track is drawn.
            let size = clip_size;
            let y = |value: f32| (1.0 - value) * row_height * size;
            let path = lane_path(&lane.points, from, to, self.zoom, y);
            lanes.push(LaneData {
                id: lane.id,
                row: row as i32,
                name: lane.name.clone(),
                enabled: lane.enabled,
                path: path.into(),
                top: 0.0,
                span: size,
            });
            for (index, (beat, value)) in lane.points.iter().enumerate() {
                if *beat < from || *beat > to {
                    continue;
                }
                points.push(PointData {
                    lane: lane.id,
                    index: index as i32,
                    row: row as i32,
                    beat: *beat,
                    value: *value,
                    top: 0.0,
                    span: size,
                });
            }
        }
        sync(&self.lanes, lanes);
        sync(&self.points, points);
        sync(&self.strips, strips);
        sync(&self.strip_points, strip_points);
        // What each track's header says its lane is, and could be.
        for (row, (_, all)) in self.lane_data.iter().enumerate() {
            let Some(mut track) = self.tracks.row_data(row) else {
                continue;
            };
            let shown = self.row_lane.get(row).copied().flatten();
            let name = all
                .iter()
                .find(|l| Some(l.id) == shown)
                .map_or("Volume".into(), |l| l.name.clone());
            let mut choices: Vec<SharedString> = vec!["Volume".into(), "Pan".into()];
            choices.extend(all.iter().filter(|l| l.param).map(|l| l.name.clone()));
            let same =
                track.lane_name == name && track.lane_choices.iter().eq(choices.iter().cloned());
            if !same {
                track.lane_name = name;
                track.lane_choices = ModelRc::from(Rc::new(VecModel::from(choices)));
                self.tracks.set_row_data(row, track);
            }
        }
    }

    /// Lay out the take lanes, and the takes of the clips over the stretch
    /// of the song that shows and a screen's worth on either side, as
    /// `draw_lanes` does for curves: a long song has thousands of clips, and
    /// each piece drawn is an element and a picture.
    fn draw_takes(&mut self, ui: &App, client: &mut Client) {
        let (view_from, view_to) = (ui.get_view_start(), ui.get_view_end());
        let span = (view_to - view_from).max(1.0);
        let (from, to) = (view_from - span, view_to + span);
        let zoom = ui.get_zoom();
        let mut lanes = Vec::new();
        for (row, &count) in self.take_rows.iter().enumerate() {
            let Some(track) = self.tracks.row_data(row) else {
                continue;
            };
            for take in 0..count {
                lanes.push(TakeLaneData {
                    track: track.id,
                    row: row as i32,
                    take: take as i32 + 1,
                    top: track.clip_size + take as f32 * TAKE_ROW,
                    span: TAKE_ROW,
                });
            }
        }
        let mut pieces = Vec::new();
        let clips = std::mem::take(&mut self.take_clips);
        for clip in clips
            .iter()
            .filter(|c| c.start < to && c.start + c.length > from)
        {
            let Some(track) = self.tracks.row_data(clip.row) else {
                continue;
            };
            for (index, (name, key)) in clip.takes.iter().enumerate() {
                let picture = self.take_picture(client, clip, index + 1, key, zoom);
                pieces.push(TakePiece {
                    clip: clip.id,
                    row: clip.row as i32,
                    take: index as i32 + 1,
                    start: clip.start,
                    length: clip.length,
                    top: track.clip_size + index as f32 * TAKE_ROW,
                    span: TAKE_ROW,
                    name: name.clone(),
                    active: clip.take == index as i32 + 1,
                    picture,
                });
            }
        }
        self.take_clips = clips;
        sync(&self.take_lanes, lanes);
        sync(&self.take_pieces, pieces);
    }

    /// The picture of take `take` of a clip in its take lane, made again
    /// when `key` says what the take plays has changed.
    fn take_picture(
        &mut self,
        client: &mut Client,
        clip: &TakeClip,
        take: usize,
        key: &str,
        zoom: f32,
    ) -> Image {
        let points = wave_points(clip.length * zoom);
        let key = if clip.midi {
            key.to_string()
        } else {
            format!("{key}@{points}")
        };
        if let Some((known, picture)) = self.take_pictures.get(&(clip.id, take))
            && *known == key
        {
            return picture.clone();
        }
        let flat: Vec<f32> = client
            .eval("daw.frontend.take_preview(...)", json!([clip.id, take, points]))
            .map(|values| rows(&values).iter().map(number).collect())
            .unwrap_or_default();
        let picture = if clip.midi {
            notes_picture(&flat, clip.length)
        } else {
            wave_picture(&flat)
        };
        self.take_pictures
            .insert((clip.id, take), (key, picture.clone()));
        picture
    }

    /// The picture to draw inside a clip, made again when `key` says its
    /// notes or its waveform have changed.
    fn picture(
        &mut self,
        client: &mut Client,
        id: i32,
        key: &str,
        midi: bool,
        length: f32,
        zoom: f32,
    ) -> Image {
        // A waveform is fetched at about the width it is drawn at.
        let points = wave_points(length * zoom);
        let key = if midi {
            key.to_string()
        } else {
            format!("{key}@{points}")
        };
        let key = key.as_str();
        if let Some((known, picture)) = self.pictures.get(&id)
            && known == key
        {
            return picture.clone();
        }
        let flat: Vec<f32> = if midi {
            client.eval("daw.frontend.preview(...)", json!([id]))
        } else {
            client.eval("daw.frontend.peaks(...)", json!([id, points]))
        }
        .map(|values| rows(&values).iter().map(number).collect())
        .unwrap_or_default();
        let picture = if midi {
            notes_picture(&flat, length)
        } else {
            wave_picture(&flat)
        };
        self.pictures.insert(id, (key.to_string(), picture.clone()));
        picture
    }

    fn project(&mut self, ui: &App, client: &mut Client, state: &Value, project: &Value) {
        ui.set_project_name(text(&project["name"]));
        ui.set_modified(project["modified"].as_bool().unwrap_or(false));
        ui.set_tempo(format!("{}", project["tempo"].as_f64().unwrap_or(120.0)).into());
        ui.set_signature(text(&project["signature"]));
        ui.set_bar(number(&project["bar"]).max(0.25));
        self.all_lines = tempo_lines(&project["lines"]);
        self.lines_for = None;
        ui.set_tempo_marks(tempo_marks(&project["marks"]));
        let markers: Vec<MarkerData> = rows(&project["markers"])
            .iter()
            .map(|m| MarkerData {
                id: m["id"].as_i64().unwrap_or(0) as i32,
                beat: number(&m["beat"]),
                length: number(&m["length"]),
                name: text(&m["name"]),
            })
            .collect();
        sync(&self.markers, markers);
        ui.set_length(number(&project["length"]));
        ui.set_looping(project["loop_enabled"].as_bool().unwrap_or(false));
        ui.set_loop_start(number(&project["loop_start"]));
        ui.set_loop_end(number(&project["loop_end"]));
        ui.set_metronome(project["metronome"].as_bool().unwrap_or(false));
        ui.set_punching(project["punch_enabled"].as_bool().unwrap_or(false));
        ui.set_punch_start(number(&project["punch_start"]));
        ui.set_punch_end(number(&project["punch_end"]));
        ui.set_count_in(project["count_in"].as_i64().unwrap_or(0) as i32);
        ui.set_engine(text(&project["engine"]));
        let selected = state["selected"].as_i64().unwrap_or(-1) as i32;
        ui.set_selected(selected);
        ui.set_cursor(number(&state["cursor"]));

        ui.set_grid(number(&project["grid"]));
        for roll in self.rolls(ui) {
            roll.set_grid(number(&project["note_grid"]));
            roll.set_bar(number(&project["bar"]).max(0.25));
            roll.set_lines(roll_lines(roll.get_start(), roll.get_length()));
        }
        let mut selected_name = SharedString::new();
        let mut selected_colour = Color::from_rgb_u8(0x7a, 0x81, 0x94);
        let mut cursor_row = -1;
        let mut top = 0.0;
        let mut tops = Vec::new();
        self.lane_rows = rows(&state["tracks"])
            .iter()
            .map(|t| {
                rows(&t["lane_rows"])
                    .iter()
                    .filter_map(|id| id.as_i64().map(|id| id as i32))
                    .collect()
            })
            .collect();
        let lane_rows: Vec<usize> = self.lane_rows.iter().map(Vec::len).collect();
        self.take_rows = rows(&state["tracks"])
            .iter()
            .map(|t| t["take_rows"].as_u64().unwrap_or(0) as usize)
            .collect();
        let tracks: Vec<TrackData> = rows(&state["tracks"])
            .iter()
            .enumerate()
            .map(|(index, t)| {
                let id = t["id"].as_i64().unwrap_or(0) as i32;
                if id == selected {
                    selected_name = text(&t["name"]);
                    selected_colour = colour(&t["color"]);
                    cursor_row = index as i32;
                }
                let db = number(&t["volume"]);
                let chain = match t["output"].as_str() {
                    Some(output) if t["chain"].as_str().is_some_and(|c| !c.is_empty()) => {
                        format!("{}  → {output}", text(&t["chain"]))
                    }
                    Some(output) => format!("→ {output}"),
                    None => text(&t["chain"]).to_string(),
                };
                let old = self.tracks.row_data(index);
                // Its clips, and under them its take lanes and a row for
                // each automation lane it shows so.
                let clip_size = t["height"].as_f64().map_or(1.0, |h| h as f32);
                let size = clip_size
                    + self.take_rows[index] as f32 * TAKE_ROW
                    + lane_rows[index] as f32 * LANE_ROW;
                tops.push(top);
                top += size;
                let peak = self.peaks.get(&id).copied().unwrap_or_default();
                TrackData {
                    top: top - size,
                    size,
                    clip_size,
                    automation: t["automation"].as_str().unwrap_or("read").into(),
                    id,
                    depth: t["depth"].as_i64().unwrap_or(0) as i32,
                    group: t["group"].as_bool().unwrap_or(false),
                    folded: t["folded"].as_bool().unwrap_or(false),
                    members: t["members"].as_i64().unwrap_or(0) as i32,
                    name: text(&t["name"]),
                    color: colour(&t["color"]),
                    chain: chain.into(),
                    volume: fader(db),
                    pan: (number(&t["pan"]) + 1.0) / 2.0,
                    volume_text: decibels(db).into(),
                    pan_text: pan_text(number(&t["pan"])).into(),
                    mute: t["mute"].as_bool().unwrap_or(false),
                    solo: t["solo"].as_bool().unwrap_or(false),
                    armed: t["armed"].as_bool().unwrap_or(false),
                    input: text(&t["input"]),
                    input_label: text(&t["input_label"]),
                    monitor: t["monitor"].as_bool().unwrap_or(false),
                    // Kept where it is; updated with the meters.
                    input_level: old.as_ref().map_or(0.0, |old| old.input_level),
                    master: t["master"].as_bool().unwrap_or(false),
                    // Keep the meters where they are; they are updated separately.
                    level_l: old.as_ref().map_or(0.0, |old| old.level_l),
                    level_r: old.as_ref().map_or(0.0, |old| old.level_r),
                    hold_l: peak.level[0],
                    hold_r: peak.level[1],
                    clipped: peak.clipped,
                    peak_text: peak.text().into(),
                    number: index as i32 + 1,
                    output: t["output"].as_str().unwrap_or("Master").into(),
                    inserts: ModelRc::from(Rc::new(VecModel::from(
                        text(&t["chain"])
                            .split(" › ")
                            .filter(|name| !name.is_empty())
                            .map(SharedString::from)
                            .collect::<Vec<_>>(),
                    ))),
                    // Filled in when the lanes are laid out.
                    lane_name: old
                        .as_ref()
                        .map_or("Volume".into(), |old| old.lane_name.clone()),
                    lane_choices: old.map_or_else(ModelRc::default, |old| old.lane_choices),
                }
            })
            .collect();
        sync(&self.tracks, tracks);
        tops.push(top);
        *self.tops.borrow_mut() = tops;
        ui.set_rows_total(top.max(1.0));
        ui.set_selected_name(selected_name);
        ui.set_selected_color(selected_colour);
        ui.set_cursor_row(cursor_row);

        let clips: Vec<ClipData> = rows(&state["clips"])
            .iter()
            .map(|c| {
                let id = c["id"].as_i64().unwrap_or(0) as i32;
                let row = c["track"].as_i64().unwrap_or(0);
                let midi = c["midi"].as_bool().unwrap_or(false);
                let length = number(&c["length"]);
                ClipData {
                    // Whichever of the two the clip has says when to draw it again.
                    preview: match c["stamp"].as_str().or(c["waveform"].as_str()) {
                        Some(key) => self.picture(client, id, key, midi, length, ui.get_zoom()),
                        None => Image::default(),
                    },
                    id,
                    track: row as i32,
                    start: number(&c["start"]),
                    length,
                    name: text(&c["name"]),
                    midi,
                    muted: c["muted"].as_bool().unwrap_or(false),
                    selected: c["selected"].as_bool().unwrap_or(false),
                    fade_in: number(&c["fade_in"]),
                    fade_out: number(&c["fade_out"]),
                    gain: number(&c["gain"]),
                    takes: c["takes"].as_i64().unwrap_or(1) as i32,
                    take: c["take"].as_i64().unwrap_or(1) as i32,
                    color: colour(&state["tracks"][row as usize]["color"]),
                }
            })
            .collect();
        // Pictures of clips that are gone are not kept.
        self.pictures
            .retain(|id, _| clips.iter().any(|clip| clip.id == *id));
        sync(&self.clips, clips);
        // The clips whose takes show in take lanes.
        self.take_clips = rows(&state["clips"])
            .iter()
            .filter(|c| c["take_rows"].is_array())
            .map(|c| TakeClip {
                id: c["id"].as_i64().unwrap_or(0) as i32,
                row: c["track"].as_u64().unwrap_or(0) as usize,
                start: number(&c["start"]),
                length: number(&c["length"]),
                midi: c["midi"].as_bool().unwrap_or(false),
                take: c["take"].as_i64().unwrap_or(1) as i32,
                takes: rows(&c["take_rows"])
                    .iter()
                    .map(|t| (text(&t["name"]), t["key"].as_str().unwrap_or("").to_string()))
                    .collect(),
            })
            .collect();
        let shown: Vec<i32> = self.take_clips.iter().map(|c| c.id).collect();
        self.take_pictures.retain(|(id, _), _| shown.contains(id));
        self.draw_takes(ui, client);

        // Every lane, with its points as heights over the stretch it is drawn over.
        self.lane_data = rows(&state["tracks"])
            .iter()
            .map(|track| {
                let lanes = rows(&track["lanes"])
                    .iter()
                    .map(|lane| {
                        let (lo, hi) = (number(&lane["lo"]), number(&lane["hi"]));
                        let span = if hi > lo { hi - lo } else { 1.0 };
                        Lane {
                            id: lane["id"].as_i64().unwrap_or(0) as i32,
                            name: text(&lane["name"]),
                            param: lane["target"] == "param",
                            enabled: lane["enabled"].as_bool().unwrap_or(true),
                            points: rows(&lane["points"])
                                .iter()
                                .map(|p| {
                                    (number(&p[0]), ((number(&p[1]) - lo) / span).clamp(0.0, 1.0))
                                })
                                .collect(),
                        }
                    })
                    .collect();
                (track["id"].as_i64().unwrap_or(0) as i32, lanes)
            })
            .collect();
        self.draw_lanes(ui);

        let devices = rows(&state["devices"]);
        // With a different set of devices, start their parameter lists afresh.
        let same = devices.len() == self.devices.row_count()
            && devices.iter().enumerate().all(|(i, d)| {
                self.devices
                    .row_data(i)
                    .is_some_and(|old| old.id as i64 == d["id"].as_i64().unwrap_or(-1))
            });
        if !same {
            self.params = devices
                .iter()
                .map(|_| Rc::new(VecModel::default()))
                .collect();
        }
        let mut device_rows = Vec::new();
        for (device, params) in devices.iter().zip(&self.params) {
            let param_rows: Vec<ParamData> = rows(&device["params"])
                .iter()
                .map(|p| ParamData {
                    key: text(&p["key"]),
                    name: capitalised(&text(&p["name"])).into(),
                    value: number(&p["value"]),
                    text: text(&p["text"]),
                })
                .collect();
            sync(params, param_rows);
            device_rows.push(DeviceData {
                id: device["id"].as_i64().unwrap_or(0) as i32,
                name: text(&device["name"]),
                format: text(&device["format"]),
                has_editor: device["editor"]
                    .as_str()
                    .is_some_and(|editor| !editor.is_empty()),
                editor_open: device["editor"] == "open",
                stopped: text(&device["stopped"]),
                status: text(&device["status"]),
                bypass: device["bypass"].as_bool().unwrap_or(false),
                params: ModelRc::from(params.clone()),
                more: device["more"].as_i64().unwrap_or(0) as i32,
                preset: text(&device["preset"]),
                wet: number(&device["wet"]),
                gain: number(&device["gain"]),
            });
        }
        sync(&self.devices, device_rows);

        // Where the selected track's sound goes.
        let routing = &state["routing"];
        ui.set_route_master(routing["master"].as_bool().unwrap_or(false));
        ui.set_route_output(text(&routing["output"]));
        let targets = rows(&routing["targets"]);
        self.route_ids = targets
            .iter()
            .map(|t| t["id"].as_i64().unwrap_or(0))
            .collect();
        let names: Vec<SharedString> = targets.iter().map(|t| text(&t["name"])).collect();
        sync(&self.route_targets, names);
        let sends: Vec<SendData> = rows(&routing["sends"])
            .iter()
            .map(|send| {
                let db = number(&send["level"]);
                SendData {
                    name: text(&send["name"]),
                    value: fader(db),
                    text: format!("{db:.1} dB").replace('-', "−").into(),
                    pre: send["pre"].as_bool().unwrap_or(false),
                }
            })
            .collect();
        sync(&self.route_sends, sends);
    }
}

/// The X authority file to use when the one the environment names is gone:
/// the newest of those a desktop keeps in the runtime directory, else the
/// one in the home directory.
fn find_authority(runtime: Option<&Path>, home: Option<&Path>) -> Option<PathBuf> {
    let mut found: Vec<(std::time::SystemTime, PathBuf)> = Vec::new();
    for entry in runtime
        .and_then(|dir| std::fs::read_dir(dir).ok())
        .into_iter()
        .flatten()
        .flatten()
    {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with("xauth_") || name.starts_with(".mutter-Xwaylandauth") {
            let modified = entry.metadata().and_then(|m| m.modified()).ok();
            found.push((modified.unwrap_or(std::time::UNIX_EPOCH), entry.path()));
        }
    }
    found.sort_by_key(|candidate| std::cmp::Reverse(candidate.0));
    found
        .into_iter()
        .map(|(_, path)| path)
        .chain(home.map(|home| home.join(".Xauthority")))
        .find(|path| path.exists())
}

/// A terminal that has outlived a restart of the display still names the
/// old display's authority file, and no window can be opened from it. Use
/// the one the display has now. Called before anything else is started: it
/// changes the environment, which the kernel started from here inherits.
fn repair_display_env() {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from);
    // The same for Wayland: a name with no compositor behind it would be
    // tried, fail, and leave no window at all. Without the name, X is used.
    if let Some(name) = std::env::var_os("WAYLAND_DISPLAY") {
        let socket = match &runtime {
            Some(dir) => dir.join(&name),
            None => PathBuf::from(&name),
        };
        if !socket.exists() && std::env::var_os("DISPLAY").is_some() {
            unsafe { std::env::remove_var("WAYLAND_DISPLAY") };
        }
    }
    let stale = std::env::var_os("XAUTHORITY").map(PathBuf::from);
    if std::env::var_os("DISPLAY").is_none() || stale.as_ref().is_none_or(|file| file.exists()) {
        return;
    }
    let home = std::env::var_os("HOME").map(PathBuf::from);
    if let Some(file) = find_authority(runtime.as_deref(), home.as_deref()) {
        unsafe { std::env::set_var("XAUTHORITY", file) };
    }
}

fn run() -> Result<()> {
    repair_display_env();
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "-h" || a == "--help") {
        print!("{HELP}");
        return Ok(());
    }
    let socket = match args.iter().position(|a| a == "--socket") {
        Some(at) => {
            let path = args.get(at + 1).context("--socket needs a path")?.clone();
            args.drain(at..at + 2);
            Some(PathBuf::from(path))
        }
        None => None,
    };
    let (client, child) = match &socket {
        Some(path) => {
            let client = Client::connect(path)
                .with_context(|| format!("no kernel at {}", path.display()))?;
            (client, None)
        }
        None => {
            let (client, child) = start_kernel(&args)?;
            (client, Some(child))
        }
    };
    let client = Rc::new(RefCell::new(client));
    // The kernel this window started, if it did: it ends with the window.
    let child = Rc::new(RefCell::new(child));

    let ui = App::new()?;
    let view = Rc::new(RefCell::new(View {
        revision: -1,
        roll_hidden: 0,
        tops: Rc::new(RefCell::new(Vec::new())),
        tracks: Rc::new(VecModel::default()),
        clips: Rc::new(VecModel::default()),
        devices: Rc::new(VecModel::default()),
        params: Vec::new(),
        pictures: HashMap::new(),
        lane_data: Vec::new(),
        shown: HashMap::new(),
        row_lane: Vec::new(),
        pencil: Vec::new(),
        control_stroke: Vec::new(),
        erase_stroke: Vec::new(),
        ghosts: Rc::new(VecModel::default()),
        sounding: Rc::new(VecModel::from(vec![false; 128])),
        vel_preview: Rc::new(VecModel::default()),
        roll_controls: Vec::new(),
        strip: 0,
        controls: Rc::new(VecModel::default()),
        roll_window: RollWindow::new()?,
        detached: false,
        rec_start: None,
        windows: Vec::new(),
        repaint: true,
        lanes: Rc::new(VecModel::default()),
        points: Rc::new(VecModel::default()),
        strips: Rc::new(VecModel::default()),
        strip_points: Rc::new(VecModel::default()),
        lane_rows: Vec::new(),
        take_rows: Vec::new(),
        take_clips: Vec::new(),
        take_lanes: Rc::new(VecModel::default()),
        take_pieces: Rc::new(VecModel::default()),
        take_pictures: HashMap::new(),
        markers: Rc::new(VecModel::default()),
        all_lines: Vec::new(),
        lanes_for: None,
        ruler_lines: Rc::new(VecModel::default()),
        lines_for: None,
        render_ranges: Rc::new(VecModel::default()),
        leaving: String::new(),
        zoom: 0.0,
        row: 0.0,
        hits: Vec::new(),
        query: String::new(),
        roll: None,
        roll_stale: false,
        notes: Rc::new(VecModel::default()),
        hints: Rc::new(VecModel::default()),
        clip_entries: Rc::new(VecModel::default()),
        route_ids: Vec::new(),
        route_targets: Rc::new(VecModel::default()),
        route_sends: Rc::new(VecModel::default()),
        track_entries: Rc::new(VecModel::default()),
        timeline_entries: Rc::new(VecModel::default()),
        message_until: None,
        peaks: HashMap::new(),
        meters_at: None,
    }));
    ui.set_hints(ModelRc::from(view.borrow().hints.clone()));
    ui.set_clip_entries(ModelRc::from(view.borrow().clip_entries.clone()));
    ui.set_route_targets(ModelRc::from(view.borrow().route_targets.clone()));
    ui.set_route_sends(ModelRc::from(view.borrow().route_sends.clone()));
    ui.set_track_entries(ModelRc::from(view.borrow().track_entries.clone()));
    ui.set_timeline_entries(ModelRc::from(view.borrow().timeline_entries.clone()));
    for roll in view.borrow().rolls(&ui) {
        roll.on_place_of(|pos| place_of(pos as f64));
        roll.set_notes(ModelRc::from(view.borrow().notes.clone()));
        roll.set_controls(ModelRc::from(view.borrow().controls.clone()));
        roll.set_ghosts(ModelRc::from(view.borrow().ghosts.clone()));
        roll.set_sounding(ModelRc::from(view.borrow().sounding.clone()));
        roll.set_vel_preview(ModelRc::from(view.borrow().vel_preview.clone()));
    }
    ui.set_lanes(ModelRc::from(view.borrow().lanes.clone()));
    ui.set_points(ModelRc::from(view.borrow().points.clone()));
    ui.set_strips(ModelRc::from(view.borrow().strips.clone()));
    ui.set_strip_points(ModelRc::from(view.borrow().strip_points.clone()));
    ui.set_take_lanes(ModelRc::from(view.borrow().take_lanes.clone()));
    ui.set_take_pieces(ModelRc::from(view.borrow().take_pieces.clone()));
    ui.set_markers(ModelRc::from(view.borrow().markers.clone()));
    ui.set_ruler_lines(ModelRc::from(view.borrow().ruler_lines.clone()));
    ui.set_render_ranges(ModelRc::from(view.borrow().render_ranges.clone()));
    ui.set_tracks(ModelRc::from(view.borrow().tracks.clone()));
    ui.set_clips(ModelRc::from(view.borrow().clips.clone()));
    ui.set_devices(ModelRc::from(view.borrow().devices.clone()));

    // Every action is a call to the kernel; a failure shows in the toolbar.
    let act = {
        let (client, view, weak) = (client.clone(), view.clone(), ui.as_weak());
        move |result: &dyn Fn(&mut Client) -> Result<Value>| {
            let outcome = result(&mut client.borrow_mut());
            if let (Err(err), Some(ui)) = (outcome, weak.upgrade()) {
                view.borrow_mut().show(&ui, &format!("{err:#}"), true);
            }
        }
    };
    // What the pointer does is spelt out in the kernel, in
    // `daw.frontend.act`; here a gesture is only passed on.
    let pass = {
        let act = act.clone();
        move |name: &str, args: Value| {
            let code = format!("return daw.frontend.act.{name}(...)");
            act(&|c| c.eval(&code, args.clone()))
        }
    };
    ui.on_command({
        let act = act.clone();
        move |line| act(&|c| c.call("cmd", json!([line.as_str()])))
    });
    ui.on_feed({
        let pass = pass.clone();
        move |keys| pass("keys", json!([keys.as_str()]))
    });
    ui.on_seek({
        let act = act.clone();
        move |beat| act(&|c| c.call("transport_seek", json!([beat.max(0.0)])))
    });
    ui.on_tempo_mark({
        let pass = pass.clone();
        move |what, tempo, beat, to| {
            let kind = if tempo { "tempo" } else { "signature" };
            pass(
                "tempo_mark",
                json!([what.as_str(), kind, beat, to.max(0.0)]),
            )
        }
    });
    ui.on_set_loop({
        let pass = pass.clone();
        move |from, to| pass("set_loop", json!([from.max(0.0), to.max(0.0)]))
    });
    ui.on_split_clips({
        let pass = pass.clone();
        move |id| pass("menu_split", json!([id]))
    });
    ui.on_glue_clips({
        let pass = pass.clone();
        move |id| pass("menu_glue", json!([id]))
    });
    ui.on_float_pointer({
        let pass = pass.clone();
        move |kind, line, col| pass("float_pointer", json!([kind.as_str(), line, col]))
    });
    ui.on_set_loop_edge({
        let pass = pass.clone();
        move |start, beat| {
            pass(
                "set_loop_edge",
                json!([if start { "start" } else { "end" }, beat.max(0.0)]),
            )
        }
    });
    ui.on_set_punch_edge({
        let pass = pass.clone();
        move |start, beat, free| {
            pass(
                "set_punch_edge",
                json!([if start { "start" } else { "end" }, beat.max(0.0), free]),
            )
        }
    });
    // A drag across a take lane, and a click on one: the kernel says what
    // they make play where.
    ui.on_comp({
        let pass = pass.clone();
        move |track, take, from, to, free| {
            pass("comp", json!([track, take, from.max(0.0), to.max(0.0), free]))
        }
    });
    ui.on_take_click({
        let pass = pass.clone();
        move |track, take, beat| pass("take_click", json!([track, take, beat.max(0.0)]))
    });
    ui.on_ruler_click({
        let pass = pass.clone();
        move |beat| pass("ruler_click", json!([beat.max(0.0)]))
    });
    ui.on_select_track({
        let pass = pass.clone();
        move |id, beat| pass("select", json!([id, beat.max(0.0)]))
    });
    ui.on_select_range({
        let pass = pass.clone();
        move |row0, beat0, row1, beat1| {
            pass(
                "select_range",
                json!([row0, beat0.max(0.0), row1, beat1.max(0.0)]),
            )
        }
    });
    ui.on_set_volume({
        let pass = pass.clone();
        move |id, position| pass("set_volume", json!([id, -60.0 + position * 66.0]))
    });
    ui.on_reset_volume({
        let pass = pass.clone();
        move |id| pass("set_volume", json!([id, 0.0]))
    });
    ui.on_toggle_flag({
        let pass = pass.clone();
        move |id, flag| pass("toggle", json!([id, flag.as_str()]))
    });
    ui.on_pick_device({
        let pass = pass.clone();
        move |id, slot| pass("pick_device", json!([id, slot]))
    });
    // A click on a clip light puts it out and lets the held peak go.
    ui.on_clear_clip({
        let (view, weak) = (view.clone(), ui.as_weak());
        move |id| {
            let mut view = view.borrow_mut();
            view.peaks.insert(id, PeakHold::default());
            for index in 0..view.tracks.row_count() {
                if let Some(mut track) = view.tracks.row_data(index)
                    && track.id == id
                {
                    track.clipped = false;
                    track.hold_l = 0.0;
                    track.hold_r = 0.0;
                    track.peak_text = PeakHold::default().text().into();
                    view.tracks.set_row_data(index, track);
                }
            }
            drop(view);
            if let Some(ui) = weak.upgrade() {
                ui.window().request_redraw();
            }
        }
    });
    // The menus of a track's input and of the audio devices are filled
    // from the kernel just before they open.
    ui.on_fill_input_menu({
        let (act, weak) = (act.clone(), ui.as_weak());
        move |id| {
            act(&|c| {
                let menu = c.eval("return daw.frontend.input_menu(...)", json!([id]))?;
                if let Some(ui) = weak.upgrade() {
                    ui.set_input_audio(choices(&menu["audio"]));
                    ui.set_input_midi(choices(&menu["midi"]));
                    ui.set_input_channel(choices(&menu["channel"]));
                }
                Ok(menu)
            })
        }
    });
    ui.on_choose_input({
        let pass = pass.clone();
        move |id, group, index| pass("choose_input", json!([id, group.as_str(), index]))
    });
    ui.on_fill_engine_menu({
        let (act, weak) = (act.clone(), ui.as_weak());
        move || {
            act(&|c| {
                let menu = c.eval("return daw.frontend.engine_menu()", json!([]))?;
                if let Some(ui) = weak.upgrade() {
                    ui.set_engine_info(choices(&menu["info"]));
                    ui.set_engine_output(choices(&menu["output"]));
                    ui.set_engine_input(choices(&menu["input"]));
                    ui.set_engine_block(choices(&menu["block"]));
                    ui.set_engine_rate(choices(&menu["rate"]));
                    ui.set_engine_backend(choices(&menu["backend"]));
                }
                Ok(menu)
            })
        }
    });
    ui.on_choose_engine({
        let pass = pass.clone();
        move |group, index| pass("choose_engine", json!([group.as_str(), index]))
    });
    // The search box lists what the kernel finds (`daw.fx.search`): a line
    // per device, by its place in the list.
    let search = {
        let (act, view, weak) = (act.clone(), view.clone(), ui.as_weak());
        move |query: &str| {
            let Some(ui) = weak.upgrade() else { return };
            view.borrow_mut().query = query.to_string();
            let found = if query.trim().is_empty() {
                Value::Null
            } else {
                let found = std::cell::RefCell::new(Value::Null);
                act(&|c| {
                    *found.borrow_mut() = c.eval(
                        "return daw.frontend.act.search_devices(...)",
                        json!([query]),
                    )?;
                    Ok(Value::Null)
                });
                found.into_inner()
            };
            let (mut lines, mut hits) = (Vec::new(), Vec::new());
            for hit in rows(&found) {
                lines.push(text(&hit["line"]));
                hits.push(text(&hit["kind"]).to_string());
            }
            view.borrow_mut().hits = hits;
            ui.set_device_matches(ModelRc::from(Rc::new(VecModel::from(lines))));
        }
    };
    ui.on_add_device({
        let (pass, view, weak) = (pass.clone(), view.clone(), ui.as_weak());
        move |line| {
            let Some(ui) = weak.upgrade() else { return };
            let at = ui.get_device_matches().iter().position(|l| l == line);
            let view = view.borrow();
            if let Some(kind) = at.and_then(|at| view.hits.get(at)) {
                pass("add_device", json!([kind, view.query]))
            }
        }
    });
    ui.on_search_devices({
        let search = search.clone();
        move |query| search(query.as_str())
    });
    ui.on_toggle_favourite({
        let (pass, view, weak) = (pass.clone(), view.clone(), ui.as_weak());
        move |line| {
            let Some(ui) = weak.upgrade() else { return };
            let at = ui.get_device_matches().iter().position(|l| l == line);
            let (kind, query) = {
                let view = view.borrow();
                (
                    at.and_then(|at| view.hits.get(at).cloned()),
                    view.query.clone(),
                )
            };
            if let Some(kind) = kind {
                pass("toggle_favourite", json!([kind]));
                search(&query);
            }
        }
    });
    ui.on_toggle_editor({
        let act = act.clone();
        move |id| act(&|c| c.call("device_editor", json!([id])))
    });
    // Routing gestures name the selected track and, for a target, its id.
    ui.on_choose_output({
        let (pass, view, weak) = (pass.clone(), view.clone(), ui.as_weak());
        move |at| {
            let Some(ui) = weak.upgrade() else { return };
            let target = view
                .borrow()
                .route_ids
                .get(at as usize)
                .copied()
                .unwrap_or(0);
            pass("set_output", json!([ui.get_selected(), target]))
        }
    });
    ui.on_add_send({
        let (pass, view, weak) = (pass.clone(), view.clone(), ui.as_weak());
        move |at| {
            let Some(ui) = weak.upgrade() else { return };
            if let Some(target) = view.borrow().route_ids.get(at as usize).copied()
                && target != 0
            {
                pass("add_send", json!([ui.get_selected(), target, -6.0]))
            }
        }
    });
    ui.on_set_send({
        let (pass, weak) = (pass.clone(), ui.as_weak());
        move |at, value| {
            let Some(ui) = weak.upgrade() else { return };
            pass(
                "set_send",
                json!([ui.get_selected(), at + 1, value * 66.0 - 60.0]),
            )
        }
    });
    ui.on_toggle_send_pre({
        let (pass, view, weak) = (pass.clone(), view.clone(), ui.as_weak());
        move |at| {
            let Some(ui) = weak.upgrade() else { return };
            let pre = view
                .borrow()
                .route_sends
                .row_data(at as usize)
                .is_some_and(|s| s.pre);
            pass(
                "set_send",
                json!([ui.get_selected(), at + 1, Value::Null, !pre]),
            )
        }
    });
    ui.on_remove_send({
        let (pass, weak) = (pass.clone(), ui.as_weak());
        move |at| {
            let Some(ui) = weak.upgrade() else { return };
            pass("remove_send", json!([ui.get_selected(), at + 1]))
        }
    });
    ui.on_fold_track({
        let pass = pass.clone();
        move |id| pass("fold", json!([id]))
    });
    ui.on_restart_device({
        let pass = pass.clone();
        move |id| pass("restart_device", json!([id]))
    });
    ui.on_preset_step({
        let pass = pass.clone();
        move |id, step| pass("preset_step", json!([id, step]))
    });
    // The preset menu is filled from the kernel just before it opens.
    ui.on_fill_preset_menu({
        let (act, weak) = (act.clone(), ui.as_weak());
        move |id| {
            act(&|c| {
                let names = c.eval("return daw.frontend.act.preset_menu(...)", json!([id]))?;
                if let Some(ui) = weak.upgrade() {
                    let names: Vec<SharedString> = names
                        .as_array()
                        .map(|list| {
                            list.iter()
                                .map(|n| SharedString::from(n.as_str().unwrap_or("")))
                                .collect()
                        })
                        .unwrap_or_default();
                    ui.set_preset_names(ModelRc::from(Rc::new(VecModel::from(names))));
                }
                Ok(Value::Null)
            })
        }
    });
    ui.on_choose_preset({
        let pass = pass.clone();
        move |id, index| pass("preset_choose", json!([id, index]))
    });
    // Where each device card is in the inspector's list, for a drop there.
    let cards: Rc<RefCell<Vec<(f32, f32)>>> = Rc::default();
    ui.on_card_place({
        let cards = cards.clone();
        move |at, y, height| {
            let mut cards = cards.borrow_mut();
            let at = at.max(0) as usize;
            if cards.len() <= at {
                cards.resize(at + 1, (0.0, 0.0));
            }
            cards[at] = (y, height);
        }
    });
    ui.on_drop_device({
        let (pass, weak) = (pass.clone(), ui.as_weak());
        move |id, track, y, copy| {
            if track >= 0 {
                return pass("drop_device", json!([id, track, copy]));
            }
            let Some(ui) = weak.upgrade() else { return };
            // The place among the cards whose middle the drop is above.
            let count = ui.get_devices().row_count();
            let cards = cards.borrow();
            let index = (0..count)
                .find(|&i| {
                    cards
                        .get(i)
                        .is_some_and(|(top, height)| y < top + height / 2.0)
                })
                .unwrap_or(count);
            pass("place_device", json!([id, index + 1, copy]))
        }
    });
    ui.on_device_command({
        let pass = pass.clone();
        move |id, line| pass("device_command", json!([id, line.as_str()]))
    });
    ui.on_toggle_offline({
        let pass = pass.clone();
        move |id| pass("toggle_offline", json!([id]))
    });
    ui.on_select_clip({
        let pass = pass.clone();
        move |id, beat, mode| {
            pass(
                "select_clip",
                json!([id, beat.max(0.0), MODES[mode.clamp(0, 2) as usize]]),
            )
        }
    });
    ui.on_select_clips_box({
        let pass = pass.clone();
        move |row0, beat0, row1, beat1, mode| {
            pass(
                "select_clips_box",
                json!([row0, beat0, row1, beat1, MODES[mode.clamp(0, 2) as usize]]),
            )
        }
    });
    ui.on_move_clip({
        let pass = pass.clone();
        move |id, beats, rows, copy, free| pass("drag_clips", json!([id, beats, rows, copy, free]))
    });
    ui.on_resize_clip({
        let pass = pass.clone();
        move |id, length| pass("resize_clip", json!([id, length]))
    });
    ui.on_trim_edge({
        let pass = pass.clone();
        move |id, start, beats, free, slip| {
            pass(
                "trim_clips",
                json!([id, if start { "start" } else { "end" }, beats, free, slip]),
            )
        }
    });
    ui.on_set_fade({
        let pass = pass.clone();
        move |id, out, beats| {
            pass(
                "set_fade",
                json!([id, if out { "out" } else { "in" }, beats]),
            )
        }
    });
    ui.on_set_clip_gain({
        let pass = pass.clone();
        move |id, db| pass("set_clip_gain", json!([id, db]))
    });
    ui.on_clip_command({
        let pass = pass.clone();
        move |id, beat, line| pass("clip_command", json!([id, beat, line.as_str()]))
    });
    ui.on_track_command({
        let pass = pass.clone();
        move |id, line| pass("track_command", json!([id, line.as_str()]))
    });
    // Entries are named by their place from 1 in the kernel, from 0 here.
    ui.on_menu_entry({
        let pass = pass.clone();
        move |kind, index, target, beat| {
            pass("menu", json!([kind.as_str(), index + 1, target, beat]))
        }
    });
    // The row at a height in the timeline, in rows of the zoom's height.
    ui.on_row_at_rows({
        let tops = view.borrow().tops.clone();
        move |at| {
            let tops = tops.borrow();
            tops.iter()
                .take(tops.len().saturating_sub(1))
                .rposition(|top| *top <= at)
                .unwrap_or(0) as i32
        }
    });
    ui.on_set_track_height({
        let pass = pass.clone();
        move |id, share| pass("set_track_height", json!([id, share]))
    });
    ui.on_sweep_flag({
        let pass = pass.clone();
        move |row0, row1, flag, on| pass("sweep_flag", json!([row0, row1, flag.as_str(), on]))
    });
    ui.on_move_track({
        let pass = pass.clone();
        move |id, index| pass("move_track", json!([id, index.max(1)]))
    });
    // Notes are named by their place from 1 in the kernel, from 0 here.
    let roll = {
        let (pass, view) = (pass.clone(), view.clone());
        move |name: &str, args: Value| {
            let Some(id) = view.borrow().roll else { return };
            let mut all = vec![json!(id)];
            let mut args = args.as_array().cloned().unwrap_or_default();
            // The roll leaves out the notes hidden before the clip's start,
            // which come first: a note's place is past them.
            let skip = view.borrow().roll_hidden;
            if matches!(
                name,
                "drag_notes" | "stretch_notes" | "select_note" | "remove_note" | "set_velocity"
            ) && let Some(place) = args.first().and_then(Value::as_i64)
            {
                args[0] = json!(place + skip as i64);
            }
            all.extend(args);
            pass(name, Value::Array(all))
        }
    };
    let roll_window = view.borrow().roll_window.clone_strong();
    // The roll reports through a global of whichever window it is in.
    for (shown, in_window) in [
        (ui.global::<Roll>(), false),
        (roll_window.global::<Roll>(), true),
    ] {
        shown.on_drag_notes({
            let roll = roll.clone();
            move |index, beats, pitches, copy, free| {
                roll("drag_notes", json!([index + 1, beats, pitches, copy, free]))
            }
        });
        shown.on_stretch_notes({
            let roll = roll.clone();
            move |index, start, end, free| {
                roll("stretch_notes", json!([index + 1, start, end, free]))
            }
        });
        shown.on_select_note({
            let roll = roll.clone();
            move |index, mode| {
                roll(
                    "select_note",
                    json!([index + 1, MODES[mode.clamp(0, 2) as usize]]),
                )
            }
        });
        shown.on_box_select({
            let roll = roll.clone();
            move |beat0, pitch0, beat1, pitch1, mode| {
                roll(
                    "select_notes_box",
                    json!([
                        beat0,
                        pitch0,
                        beat1,
                        pitch1,
                        MODES[mode.clamp(0, 2) as usize]
                    ]),
                )
            }
        });
        shown.on_add_note({
            let roll = roll.clone();
            move |pitch, start, length, free| roll("add_note", json!([pitch, start, length, free]))
        });
        shown.on_remove_note({
            let roll = roll.clone();
            move |index| roll("remove_note", json!([index + 1]))
        });
        shown.on_set_velocity({
            let roll = roll.clone();
            move |index, velocity| roll("set_velocity", json!([index + 1, velocity * 127.0]))
        });
        shown.on_audition({
            let roll = roll.clone();
            move |pitch| roll("audition", json!([pitch]))
        });
        shown.on_close({
            let pass = pass.clone();
            move || pass("close_roll", json!([]))
        });
        shown.on_set_grid({
            let act = act.clone();
            move |grid| act(&|c| c.eval("daw.opt.note_grid = ...", json!([grid])))
        });
        shown.on_clear_controls({
            let (roll, view) = (roll.clone(), view.clone());
            move || {
                let strip = view.borrow().strip;
                if let Some((kind, number)) = strip_kind(strip) {
                    roll("clear_controls", json!([kind, number]));
                }
            }
        });
        // The pencil over the strip: drawn here as it goes, sent when lifted.
        shown.on_draw_control({
            let (roll, view, weak) = (roll.clone(), view.clone(), ui.as_weak());
            move |beat, height, phase| {
                let Some(ui) = weak.upgrade() else { return };
                let mut view = view.borrow_mut();
                if phase == 0 {
                    view.control_stroke.clear();
                }
                view.control_stroke.push((beat.max(0.0), height));
                let zoom = view.active_roll(&ui).get_zoom();
                let path = stroke_path(
                    &view.control_stroke,
                    |beat| beat * zoom,
                    |height| (1.0 - height) * (STRIP - 4.0) + 2.0,
                );
                let done = phase == 2;
                for shown in view.rolls(&ui) {
                    shown.set_stroke(if done { "".into() } else { path.clone().into() });
                }
                // Over velocities the bars themselves follow the pencil.
                if view.strip == 0 {
                    let notes: Vec<NoteData> = view.notes.iter().collect();
                    let preview =
                        velocity_preview(&view.control_stroke, &notes, 4.0 / zoom.max(1.0));
                    sync(&view.vel_preview, preview);
                }
                if done {
                    let points: Vec<Value> = view
                        .control_stroke
                        .drain(..)
                        .map(|(beat, height)| json!([beat, height]))
                        .collect();
                    let strip = view.strip;
                    drop(view);
                    if let Some((kind, number)) = strip_kind(strip) {
                        roll("draw_controls", json!([kind, number, points]));
                    } else if strip == 0 {
                        // A click reaches the bar within a few pixels.
                        roll("draw_velocities", json!([points, 4.0 / zoom.max(1.0)]));
                    }
                }
            }
        });
        // The eraser: gathered here as it goes, sent when lifted.
        shown.on_erase({
            let (roll, view) = (roll.clone(), view.clone());
            move |beat, pitch, phase| {
                let mut view = view.borrow_mut();
                if phase == 0 {
                    view.erase_stroke.clear();
                }
                view.erase_stroke.push((beat.max(0.0), pitch));
                if phase == 2 {
                    let points: Vec<Value> = view
                        .erase_stroke
                        .drain(..)
                        .map(|(beat, pitch)| json!([beat, pitch]))
                        .collect();
                    drop(view);
                    roll("erase_notes", json!([points]));
                }
            }
        });
        // Any other gesture, by the name of its function in the kernel.
        shown.on_act({
            let roll = roll.clone();
            move |name, args| {
                let args: Vec<f32> = args.iter().collect();
                roll(name.as_str(), json!(args))
            }
        });
        // Its own window, or back into the main one.
        shown.on_detach({
            let (view, weak) = (view.clone(), ui.as_weak());
            move || {
                let Some(ui) = weak.upgrade() else { return };
                let mut view = view.borrow_mut();
                view.detached = !view.detached;
                // The window it moves to takes over where the other was.
                let (top, zoom, lane) = {
                    let from = if view.detached {
                        ui.global::<Roll>()
                    } else {
                        view.roll_window.global::<Roll>()
                    };
                    (from.get_top(), from.get_zoom(), from.get_lane())
                };
                for shown in view.rolls(&ui) {
                    shown.set_detached(view.detached);
                    shown.set_top(top);
                    shown.set_zoom(zoom);
                    shown.set_lane(lane);
                }
                let _ = if view.detached {
                    view.roll_window.show()
                } else {
                    view.roll_window.hide()
                };
            }
        });
        shown.on_focus_keys({
            let (weak, window) = (ui.as_weak(), roll_window.as_weak());
            move || {
                if in_window {
                    if let Some(window) = window.upgrade() {
                        window.invoke_focus_keys();
                    }
                } else if let Some(ui) = weak.upgrade() {
                    ui.invoke_focus_keys();
                }
            }
        });
    }
    // Closing the roll's window puts the roll back in the main one.
    roll_window.window().on_close_requested({
        let (view, weak) = (view.clone(), ui.as_weak());
        move || {
            if let Some(ui) = weak.upgrade() {
                let mut view = view.borrow_mut();
                view.detached = false;
                for shown in view.rolls(&ui) {
                    shown.set_detached(false);
                }
            }
            slint::CloseRequestResponse::HideWindow
        }
    });
    roll_window.on_key({
        let (act, weak) = (act.clone(), ui.as_weak());
        move |key, ctrl, alt, shift| {
            let focused = weak.upgrade().map(|ui| ui.get_focused());
            if let Some(keys) = notation(&key, ctrl, alt, shift) {
                let keys = window_keys(keys, focused.as_deref() == Some("pianoroll"));
                act(&|c| c.call("keys", json!([keys])))
            }
        }
    });
    ui.on_record({
        let pass = pass.clone();
        move || pass("record", json!([]))
    });
    // The lane a row shows, made as a volume lane if the track has none.
    let lane_of = {
        let (client, view) = (client.clone(), view.clone());
        move |row: i32| -> Option<i32> {
            let (known, track) = {
                let view = view.borrow();
                (
                    view.row_lane.get(row.max(0) as usize).copied().flatten(),
                    view.tracks.row_data(row.max(0) as usize).map(|t| t.id),
                )
            };
            known.or_else(|| {
                let made = client
                    .borrow_mut()
                    .eval(
                        "return daw.frontend.act.lane(...)",
                        json!([track?, "volume"]),
                    )
                    .ok()?;
                made.as_i64().map(|id| id as i32)
            })
        }
    };
    // The pencil over a track: a click adds a point, a stroke draws a curve.
    ui.on_pencil({
        let (pass, view, weak, lane_of) =
            (pass.clone(), view.clone(), ui.as_weak(), lane_of.clone());
        move |row, beat, height, phase| {
            let Some(ui) = weak.upgrade() else { return };
            let mut view = view.borrow_mut();
            if phase == 0 {
                view.pencil.clear();
            }
            view.pencil.push((beat.max(0.0), height));
            if phase < 2 {
                let zoom = ui.get_zoom();
                let path = stroke_path(
                    &view.pencil,
                    |beat| beat * zoom,
                    |height| (1.0 - height) * ui.get_row_height(),
                );
                ui.set_pencil_row(row);
                ui.set_pencil_path(path.into());
                return;
            }
            ui.set_pencil_row(-1);
            let stroke: Vec<(f32, f32)> = view.pencil.drain(..).collect();
            drop(view);
            let Some(lane) = lane_of(row) else { return };
            // How far the pointer went, in pixels: a click hardly moves.
            let reach = stroke
                .iter()
                .map(|p| {
                    ((p.0 - stroke[0].0) * ui.get_zoom()).abs()
                        + ((p.1 - stroke[0].1) * ui.get_row_height()).abs()
                })
                .fold(0.0, f32::max);
            if reach < 5.0 {
                pass("add_point", json!([lane, stroke[0].0, stroke[0].1]));
            } else {
                let points: Vec<Value> = stroke.iter().map(|(b, h)| json!([b, h])).collect();
                pass("draw_lane", json!([lane, points]));
            }
        }
    });
    ui.on_move_point({
        let pass = pass.clone();
        move |lane, index, beat, value| {
            pass(
                "move_point",
                json!([lane, index + 1, beat.max(0.0), value.clamp(0.0, 1.0)]),
            )
        }
    });
    ui.on_remove_point({
        let pass = pass.clone();
        move |lane, index| pass("remove_point", json!([lane, index + 1]))
    });
    ui.on_lane_command({
        let (pass, view) = (pass.clone(), view.clone());
        move |row, what| {
            let lane = view
                .borrow()
                .row_lane
                .get(row.max(0) as usize)
                .copied()
                .flatten();
            if let Some(lane) = lane {
                pass(
                    if what == "clear" {
                        "clear_lane"
                    } else {
                        "toggle_lane"
                    },
                    json!([lane]),
                );
            }
        }
    });
    // Which lane a track shows: volume, pan, or one of its parameters'.
    let show = {
        let (client, view, weak) = (client.clone(), view.clone(), ui.as_weak());
        move |track: i32, args: Value| {
            let made = client
                .borrow_mut()
                .eval("return daw.frontend.act.lane(...)", args);
            let (Ok(made), Some(ui)) = (made, weak.upgrade()) else {
                return;
            };
            if let Some(lane) = made.as_i64() {
                let mut view = view.borrow_mut();
                view.shown.insert(track, lane as i32);
                // Ask for the project again, with the lane in it.
                view.revision = -1;
                ui.set_show_automation(true);
            }
        }
    };
    ui.on_show_lane({
        let (show, view) = (show.clone(), view.clone());
        move |track, choice| {
            let existing = {
                let view = view.borrow();
                let lanes = view.lane_data.iter().find(|(id, _)| *id == track);
                lanes.and_then(|(_, all)| {
                    let params: Vec<&Lane> = all.iter().filter(|l| l.param).collect();
                    params.get((choice - 2).max(0) as usize).map(|l| l.id)
                })
            };
            match choice {
                0 => show(track, json!([track, "volume"])),
                1 => show(track, json!([track, "pan"])),
                _ => {
                    if let Some(lane) = existing {
                        let mut view = view.borrow_mut();
                        view.shown.insert(track, lane);
                        view.revision = -1;
                    }
                }
            }
        }
    });
    ui.on_automate_param({
        let (show, weak) = (show.clone(), ui.as_weak());
        move |device, key| {
            let Some(ui) = weak.upgrade() else { return };
            let track = ui.get_selected();
            show(track, json!([track, "param", device, key.as_str()]));
        }
    });
    ui.on_set_pan({
        let pass = pass.clone();
        move |id, position| pass("set_pan", json!([id, position * 2.0 - 1.0]))
    });
    ui.on_rename_track({
        let pass = pass.clone();
        move |id, name| pass("rename_track", json!([id, name.as_str()]))
    });
    ui.on_add_clip_at({
        let pass = pass.clone();
        move |track, beat| pass("add_clip", json!([track, beat.max(0.0)]))
    });
    // The piano roll is the kernel's: opening and closing it there is what
    // makes it show here, and puts the keyboard in it.
    ui.on_open_clip({
        let pass = pass.clone();
        move |id| pass("open_clip", json!([id]))
    });
    ui.on_key({
        let (act, weak) = (act.clone(), ui.as_weak());
        move |key, ctrl, alt, shift| {
            let focused = weak.upgrade().map(|ui| ui.get_focused());
            if let Some(keys) = notation(&key, ctrl, alt, shift) {
                let keys = window_keys(keys, focused.as_deref() == Some("pianoroll"));
                act(&|c| c.call("keys", json!([keys])))
            }
        }
    });
    ui.on_remove_device({
        let act = act.clone();
        move |id| act(&|c| c.call("device_remove", json!([id])))
    });
    ui.on_move_device({
        let pass = pass.clone();
        move |id, by| pass("move_device", json!([id, by]))
    });
    ui.on_toggle_bypass({
        let pass = pass.clone();
        move |id| pass("toggle_bypass", json!([id]))
    });
    ui.on_set_param({
        let pass = pass.clone();
        move |id, key, position| pass("set_param", json!([id, key.as_str(), position]))
    });
    ui.on_reset_param({
        let pass = pass.clone();
        move |id, key| pass("reset_param", json!([id, key.as_str()]))
    });

    // A control taken hold of or let go, for automation written by touch.
    ui.on_hold({
        let pass = pass.clone();
        move |track, what, device, param, on| {
            pass(
                "hold",
                json!([track, what.as_str(), device, param.as_str(), on]),
            )
        }
    });
    // The pencil over a lane shown as a row of its own.
    ui.on_strip_pencil({
        let (pass, view, weak) = (pass.clone(), view.clone(), ui.as_weak());
        move |lane, beat, height, phase| {
            let Some(ui) = weak.upgrade() else { return };
            let mut view = view.borrow_mut();
            if phase == 0 {
                view.pencil.clear();
            }
            // The curve has a little room above and below it in its row.
            let height = ((height - 0.08) / 0.84).clamp(0.0, 1.0);
            view.pencil.push((beat.max(0.0), height));
            let span = LANE_ROW * ui.get_row_height();
            if phase < 2 {
                let zoom = ui.get_zoom();
                let path = stroke_path(
                    &view.pencil,
                    |beat| beat * zoom,
                    |height| (0.08 + (1.0 - height) * 0.84) * span,
                );
                ui.set_strip_pencil_lane(lane);
                ui.set_strip_pencil_path(path.into());
                return;
            }
            ui.set_strip_pencil_lane(-1);
            let stroke: Vec<(f32, f32)> = view.pencil.drain(..).collect();
            drop(view);
            // How far the pointer went, in pixels: a click hardly moves.
            let reach = stroke
                .iter()
                .map(|p| {
                    ((p.0 - stroke[0].0) * ui.get_zoom()).abs() + ((p.1 - stroke[0].1) * span).abs()
                })
                .fold(0.0, f32::max);
            if reach < 5.0 {
                pass("add_point", json!([lane, stroke[0].0, stroke[0].1]));
            } else {
                let points: Vec<Value> = stroke.iter().map(|(b, h)| json!([b, h])).collect();
                pass("draw_lane", json!([lane, points]));
            }
        }
    });
    ui.on_lane_id_command({
        let pass = pass.clone();
        move |lane, what| {
            let name = match what.as_str() {
                "clear" => "clear_lane",
                "toggle" => "toggle_lane",
                _ => "hide_lane_rows",
            };
            pass(name, json!([lane]))
        }
    });

    // The render dialog: what it starts from is asked for when it opens.
    ui.on_open_render({
        let (client, view, weak) = (client.clone(), view.clone(), ui.as_weak());
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let info = client
                .borrow_mut()
                .eval("return daw.frontend.render_dialog()", json!([]));
            match info {
                Ok(info) => {
                    let ranges: Vec<RangeChoice> = rows(&info["ranges"])
                        .iter()
                        .map(|r| RangeChoice {
                            name: text(&r["name"]),
                            label: text(&r["label"]),
                        })
                        .collect();
                    sync(&view.borrow().render_ranges, ranges);
                    ui.set_render_range(0);
                    ui.set_render_path(text(&info["path"]));
                    ui.set_render_open(true);
                }
                Err(err) => view.borrow_mut().show(&ui, &format!("{err:#}"), true),
            }
        }
    });
    ui.on_start_render({
        let (pass, view, weak) = (pass.clone(), view.clone(), ui.as_weak());
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let range = view
                .borrow()
                .render_ranges
                .row_data(ui.get_render_range().max(0) as usize)
                .map_or("song".to_string(), |r| r.name.to_string());
            let tail: f64 = ui.get_render_tail().trim().parse().unwrap_or(1.0);
            let normalize = if ui.get_render_normalize() {
                json!(-1.0)
            } else {
                Value::Null
            };
            pass(
                "render",
                json!([{
                    "path": ui.get_render_path().as_str(), "range": range,
                    "format": if ui.get_render_flac() { "flac" } else { "wav" },
                    "bits": ui.get_render_bits(), "tail": tail.max(0.0), "normalize": normalize,
                    "dither": ui.get_render_dither(), "mono": ui.get_render_mono(),
                    "stems": ui.get_render_stems(),
                }]),
            );
            ui.set_render_open(false);
            ui.invoke_focus_keys();
        }
    });

    // Leaving the project (quitting, starting a new one, opening another)
    // asks first when there are changes to save. Returns whether it asked.
    let leave = {
        let (client, view, weak, pass, child) = (
            client.clone(),
            view.clone(),
            ui.as_weak(),
            pass.clone(),
            child.clone(),
        );
        move |what: &str| -> bool {
            let Some(ui) = weak.upgrade() else {
                return false;
            };
            let closing = client
                .borrow_mut()
                .eval("return daw.frontend.closing()", json!([]))
                .unwrap_or(Value::Null);
            // A kernel that was running before this window is not this
            // window's to save or to end.
            let ours = child.borrow().is_some();
            if closing["modified"].as_bool().unwrap_or(false) && (ours || what != "quit") {
                view.borrow_mut().leaving = what.to_string();
                ui.set_closing_name(text(&closing["name"]));
                ui.set_closing_what(what.into());
                ui.set_closing(true);
                return true;
            }
            if what == "quit" {
                let _ = slint::quit_event_loop();
            } else {
                pass("leave", json!(["go", what]));
            }
            false
        }
    };
    ui.on_file_action({
        let leave = leave.clone();
        move |what| {
            leave(what.as_str());
        }
    });
    ui.on_close_choice({
        let (pass, view, weak) = (pass.clone(), view.clone(), ui.as_weak());
        move |choice| {
            let Some(ui) = weak.upgrade() else { return };
            ui.set_closing(false);
            ui.invoke_focus_keys();
            if choice != "cancel" {
                // Saved or not, the kernel then does what was asked: when
                // that was to quit, the window goes when the kernel has.
                let what = view.borrow().leaving.clone();
                pass("leave", json!([choice.as_str(), what]));
            }
        }
    });
    // The recent projects are fetched when the File menu opens; the kernel
    // asks the question about unsaved changes as it does for Open.
    let recent: Rc<RefCell<Vec<String>>> = Rc::default();
    ui.on_fill_recent_menu({
        let (act, weak, recent) = (act.clone(), ui.as_weak(), recent.clone());
        move || {
            act(&|c| {
                let menu = c.eval("return daw.frontend.recent_menu()", json!([]))?;
                *recent.borrow_mut() = rows(&menu).iter().map(|entry| text(&entry["path"]).to_string()).collect();
                if let Some(ui) = weak.upgrade() {
                    ui.set_recent_list(choices(&menu));
                }
                Ok(menu)
            })
        }
    });
    ui.on_open_recent({
        let (leave, recent) = (leave.clone(), recent.clone());
        move |at| {
            let path = usize::try_from(at).ok().and_then(|at| recent.borrow().get(at).cloned());
            if let Some(path) = path {
                leave(&format!("open:{path}"));
            }
        }
    });

    // How the window was left comes back, and is kept again once a change
    // has stood for a second and when the window closes.
    let layout = |ui: &App| {
        let scale = ui.window().scale_factor();
        let size = ui.window().size().to_logical(scale);
        json!({
            "width": size.width.round(), "height": size.height.round(), "zoom": ui.get_zoom(),
            "row_height": ui.get_row_height(),
            "roll_height": ui.get_roll_height(),
            "mixer": ui.get_show_mixer(),
        })
    };
    ui.window().on_close_requested({
        let (leave, client, weak, layout) = (leave.clone(), client.clone(), ui.as_weak(), layout);
        move || {
            if let Some(ui) = weak.upgrade() {
                let _ = client.borrow_mut().eval("daw.frontend.layout_set(...)", json!([layout(&ui)]));
            }
            if leave("quit") {
                slint::CloseRequestResponse::KeepWindowShown
            } else {
                slint::CloseRequestResponse::HideWindow
            }
        }
    });

    // Views that paint have windows of their own, opened and closed as the
    // kernel lists them.
    let canvases: Rc<RefCell<HashMap<String, Canvas>>> = Rc::default();
    let timer = Timer::default();
    timer.start(TimerMode::Repeated, Duration::from_millis(33), {
        let (client, view, weak) = (client.clone(), view.clone(), ui.as_weak());
        let (canvases, act, child) = (canvases.clone(), act.clone(), child.clone());
        move || {
            let Some(ui) = weak.upgrade() else { return };
            let (windows, repaint) = {
                let mut view = view.borrow_mut();
                if let Err(err) = view.refresh(&ui, &mut client.borrow_mut()) {
                    // The kernel this window started has ended (it was told
                    // to quit, or it died): so does the window.
                    let gone = child
                        .borrow_mut()
                        .as_mut()
                        .is_some_and(|child| matches!(child.try_wait(), Ok(Some(_))));
                    if gone {
                        let _ = slint::quit_event_loop();
                        return;
                    }
                    view.show(&ui, &format!("{err:#}"), true);
                }
                (view.windows.clone(), std::mem::take(&mut view.repaint))
            };
            let mut canvases = canvases.borrow_mut();
            canvases.retain(|name, canvas| {
                let open = windows.iter().any(|w| &w.0 == name);
                if !open {
                    let _ = canvas.window.hide();
                }
                open
            });
            for (name, title, width, height) in &windows {
                if !canvases.contains_key(name) {
                    let Ok(window) = CanvasWindow::new() else { continue };
                    let items = Rc::new(VecModel::default());
                    window.set_name(name.as_str().into());
                    window.set_items(ModelRc::from(items.clone()));
                    window.window().set_size(slint::LogicalSize::new(*width, *height));
                    let send = {
                        let (act, view, name) = (act.clone(), view.clone(), name.clone());
                        move |event: Value| {
                            act(&|c| c.eval("daw.canvas.pointer(...)", json!([name, event])));
                            view.borrow_mut().repaint = true;
                        }
                    };
                    window.on_pointer({
                        let send = send.clone();
                        move |kind, x, y, button, ctrl, shift, alt| {
                            let kind = ["down", "up", "move", "double"][kind.clamp(0, 3) as usize];
                            let button = ["left", "right", "middle"][button.clamp(0, 2) as usize];
                            send(json!({
                                "kind": kind, "x": x, "y": y, "button": button,
                                "ctrl": ctrl, "shift": shift, "alt": alt,
                            }))
                        }
                    });
                    window.on_wheel({
                        let send = send.clone();
                        move |x, y, dx, dy, ctrl, shift| {
                            send(json!({ "kind": "wheel", "x": x, "y": y, "dx": dx, "dy": dy, "ctrl": ctrl, "shift": shift }))
                        }
                    });
                    window.on_key({
                        let (act, view) = (act.clone(), view.clone());
                        move |key, ctrl, alt, shift| {
                            if let Some(keys) = notation(&key, ctrl, alt, shift) {
                                act(&|c| c.call("keys", json!([keys])));
                                view.borrow_mut().repaint = true;
                            }
                        }
                    });
                    window.window().on_close_requested({
                        let (act, name) = (act.clone(), name.clone());
                        move || {
                            act(&|c| c.eval("daw.canvas.close(...)", json!([name])));
                            slint::CloseRequestResponse::HideWindow
                        }
                    });
                    let _ = window.show();
                    canvases.insert(
                        name.clone(),
                        Canvas {
                            window,
                            items,
                            painted: Instant::now() - Duration::from_secs(1),
                            size: (0.0, 0.0),
                        },
                    );
                }
                let Some(canvas) = canvases.get_mut(name) else { continue };
                canvas.window.set_heading(title.as_str().into());
                // Painted again when something may have changed, when the
                // window has another size, and now and then regardless.
                let size = (canvas.window.get_canvas_width(), canvas.window.get_canvas_height());
                let stale = canvas.painted.elapsed() > Duration::from_millis(250);
                if !(repaint || stale || size != canvas.size) {
                    continue;
                }
                canvas.painted = Instant::now();
                canvas.size = size;
                let drawing = client
                    .borrow_mut()
                    .eval("return daw.canvas.paint(...)", json!([name, size.0, size.1]));
                if let Ok(drawing) = drawing {
                    let items: Vec<CanvasItem> = rows(&drawing["ops"]).iter().filter_map(canvas_item).collect();
                    sync(&canvas.items, items);
                }
            }
        }
    });

    let kept = client
        .borrow_mut()
        .eval("return daw.frontend.layout_get()", json!([]))
        .unwrap_or(Value::Null);
    let size = |name: &str| kept[name].as_f64().filter(|v| *v >= 1.0).map(|v| v as f32);
    if let (Some(width), Some(height)) = (size("width"), size("height")) {
        ui.window().set_size(slint::LogicalSize::new(width, height));
    }
    if let Some(zoom) = size("zoom") {
        ui.set_zoom(zoom);
    }
    if let Some(height) = size("row_height") {
        ui.set_row_height(height);
    }
    if let Some(height) = size("roll_height") {
        ui.set_roll_height(height);
    }
    if kept["mixer"].as_bool() == Some(true) {
        act(&|c| {
            c.eval("if not daw.ui.visible('mixer') then daw.commands.exec('view.toggle mixer') end", json!([]))
        });
    }
    let saver = Timer::default();
    {
        let (client, weak) = (client.clone(), ui.as_weak());
        // What was last kept, and what has been seen since and for how long.
        let mut done = layout(&ui);
        let mut seen = (done.clone(), Instant::now());
        saver.start(TimerMode::Repeated, Duration::from_millis(250), move || {
            let Some(ui) = weak.upgrade() else { return };
            let now = layout(&ui);
            if now != seen.0 {
                seen = (now, Instant::now());
            } else if seen.0 != done && seen.1.elapsed() >= Duration::from_secs(1) {
                let _ = client.borrow_mut().eval("daw.frontend.layout_set(...)", json!([seen.0]));
                done = seen.0.clone();
            }
        });
    }

    ui.run()?;
    drop(saver);
    drop(timer);
    if let Some(child) = child.borrow_mut().as_mut() {
        // The window is gone: so is the kernel it started, unless it has
        // ended already. What was unsaved was asked about before this.
        if !matches!(child.try_wait(), Ok(Some(_))) {
            let _ = client.borrow_mut().call("quit", json!([0]));
        }
        let _ = child.wait();
    }
    Ok(())
}

fn main() {
    if let Err(err) = run() {
        eprintln!("daw-gui: {err:#}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_newest_authority_file_is_found() {
        let dir = std::env::temp_dir().join(format!("daw-gui-test-{}", std::process::id()));
        let (runtime, home) = (dir.join("run"), dir.join("home"));
        std::fs::create_dir_all(&runtime).unwrap();
        std::fs::create_dir_all(&home).unwrap();
        assert_eq!(find_authority(Some(&runtime), Some(&home)), None);
        std::fs::write(home.join(".Xauthority"), "x").unwrap();
        assert_eq!(
            find_authority(Some(&runtime), Some(&home)),
            Some(home.join(".Xauthority")),
            "the one at home when the desktop keeps none"
        );
        std::fs::write(runtime.join("xauth_old"), "x").unwrap();
        std::thread::sleep(Duration::from_millis(20));
        std::fs::write(runtime.join("xauth_new"), "x").unwrap();
        std::fs::write(runtime.join("other"), "x").unwrap();
        assert_eq!(
            find_authority(Some(&runtime), Some(&home)),
            Some(runtime.join("xauth_new")),
            "the desktop's newest first"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn keys_are_written_as_mappings_write_them() {
        assert_eq!(notation("a", false, false, false).as_deref(), Some("a"));
        assert_eq!(notation("r", true, false, false).as_deref(), Some("<C-r>"));
        assert_eq!(
            notation(" ", false, false, false).as_deref(),
            Some("<Space>")
        );
        assert_eq!(notation("<", false, false, false).as_deref(), Some("<lt>"));
    }

    #[test]
    fn peaks_are_held_then_fall_and_the_clip_light_stays_on() {
        let mut peak = PeakHold::default();
        peak.update([0.5, 0.25], 0.0);
        assert_eq!(peak.level, [0.5, 0.25], "the loudest level is held");
        peak.update([0.1, 0.1], 1.0);
        assert_eq!(peak.level, [0.5, 0.25], "for a moment");
        peak.update([0.1, 0.1], 1.0);
        assert!(peak.level[0] < 0.5, "then it falls");
        assert!(
            (peak.level[0] - (0.5 - PeakHold::FALL)).abs() < 1e-4,
            "at 20 dB a second"
        );
        assert!(!peak.clipped, "no light below 0 dB");
        peak.update([meter(1.0), 0.0], 0.1);
        assert!(peak.clipped, "the light comes on at 0 dB");
        assert_eq!(peak.text(), "0.0", "the peak in dB");
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
    }

    #[test]
    fn a_velocity_stroke_is_previewed_as_the_kernel_draws_it() {
        let note = |start: f32, selected: bool| NoteData {
            pitch: 60,
            start,
            length: 1.0,
            velocity: 0.5,
            selected,
        };
        let notes = [
            note(0.0, false),
            note(1.0, false),
            note(2.0, false),
            note(4.0, false),
        ];
        let stroke = [(0.0, 0.0), (4.0, 1.0)];
        assert_eq!(
            velocity_preview(&stroke, &notes, 0.0)[1..],
            [0.25, 0.5, 1.0],
            "each note takes the height above its start"
        );
        let chosen = [note(0.0, false), note(1.0, true)];
        assert_eq!(
            velocity_preview(&stroke, &chosen, 0.0),
            [-1.0, 0.25],
            "only the chosen notes, when some are chosen"
        );
        assert_eq!(
            velocity_preview(&[(1.05, 0.5)], &notes, 0.1),
            [-1.0, 0.5, -1.0, -1.0],
            "a click reaches the note starting nearby"
        );
    }

    #[test]
    fn a_lane_is_drawn_over_the_stretch_in_view_alone() {
        let points = [(0.0, 0.0), (100.0, 1.0), (200.0, 0.0)];
        let y = |v: f32| v * 10.0;
        // In the middle of a slope: it starts and ends on the slope.
        assert_eq!(
            lane_path(&points, 50.0, 150.0, 2.0, y),
            "M 100.0 5.0 L 200.0 10.0 L 300.0 5.0"
        );
        // Past the last point the lane is flat; before 0 there is nothing.
        assert_eq!(
            lane_path(&points, 300.0, 400.0, 1.0, y),
            "M 300.0 0.0 L 400.0 0.0"
        );
        assert_eq!(
            lane_path(&points, -50.0, 50.0, 1.0, y),
            "M 0.0 0.0 L 50.0 5.0"
        );
        assert_eq!(lane_path(&[], 0.0, 10.0, 1.0, y), "");
    }

    #[test]
    fn only_the_lines_in_view_are_drawn_and_fewer_when_bars_are_narrow() {
        let line = |beat: f32, bar: i32, label: &str| RulerLine {
            beat,
            label: label.into(),
            next: beat + 1.0,
            bar,
            place: "".into(),
        };
        let all: Vec<RulerLine> = (0..4000)
            .map(|i| {
                let bar = i / 4 + 1;
                if i % 4 == 0 {
                    line(i as f32, bar, &bar.to_string())
                } else {
                    line(i as f32, bar, "")
                }
            })
            .collect();
        let near = lines_in_view(&all, 100.0, 132.0, 28.0);
        assert_eq!(near.len(), 33, "every beat of the stretch, and no other");
        // A beat a pixel wide: bars alone, and of those every second one.
        let far = lines_in_view(&all, 0.0, 4000.0, 1.0);
        assert!(far.iter().all(|l| !l.label.is_empty()), "no beat lines");
        assert_eq!(far.len(), 500, "every second bar when a bar is 4 px");
    }

    #[test]
    fn ctrl_a_chooses_every_note_in_the_piano_roll_only() {
        assert_eq!(window_keys("<C-a>".into(), true), "gA");
        assert_eq!(window_keys("<C-a>".into(), false), "<C-a>");
        assert_eq!(window_keys("x".into(), true), "x");
    }

    #[test]
    fn colours_and_pans_are_read() {
        let c = colour(&json!("#ff8000"));
        assert_eq!((c.red(), c.green(), c.blue()), (255, 128, 0));
        assert_eq!(pan_text(0.0), "C");
        assert_eq!(pan_text(-0.3), "L30");
        assert_eq!(pan_text(1.0), "R100");
    }
}
