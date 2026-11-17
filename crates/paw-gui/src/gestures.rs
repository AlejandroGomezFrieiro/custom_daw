//! The window's gestures, driven in-process (egui_kittest): the window is
//! drawn from what a kernel told it (tests/fixture.json, made by
//! tests/fixture.sh), a stand-in kernel takes its calls, and each test says
//! which `paw.frontend.act` a gesture sends, with what. What a gesture then
//! means is the kernel's, tested in the Lua suite; the window tests in
//! tests/window.rs drive a real window and kernel end to end.

use std::cell::RefCell;
use std::path::Path;
use std::rc::Rc;

use anyhow::Result;
use egui::{Event, Modifiers, PointerButton, Pos2, pos2, vec2};
use egui_kittest::Harness;
use egui_kittest::kittest::Queryable;
use serde_json::{Value, json};

use crate::app::{Kernel, View};

const FIXTURE: &str = include_str!("../tests/fixture.json");

type Calls = Rc<RefCell<Vec<(String, Value)>>>;

/// The scenes' patches a test has the stand-in kernel push.
type Patches = Rc<RefCell<Vec<Value>>>;

/// A kernel that answers from the fixture and keeps every call.
struct Fake {
    state: Option<Value>,
    calls: Calls,
    patches: Patches,
}

impl Kernel for Fake {
    fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        self.calls.borrow_mut().push((method.to_string(), params.clone()));
        let fixture: Value = serde_json::from_str(FIXTURE)?;
        let code = params[0].as_str().unwrap_or("");
        Ok(if code.contains("paw.frontend.menu(") {
            json!([{ "label": "First" }, { "separator": true }, { "label": "More", "items": [{ "label": "Inner" }] }, { "label": "Quit", "window": "quit" }])
        } else if code.contains("paw.frontend.clip(") {
            fixture["clip"].clone()
        } else if code.contains("search_devices") {
            json!([{ "line": "Synth  · builtin instrument", "kind": "synth" }])
        } else if code.contains("paw.frontend.closing()") {
            json!({ "modified": true, "name": "song" })
        } else if code.contains("paw.frontend.act.lane(") {
            json!(7)
        } else {
            Value::Null
        })
    }
    fn state(&mut self) -> Result<Option<Value>> {
        Ok(self.state.take())
    }
    fn send_file(&mut self, path: &Path) -> Result<String> {
        Ok(path.to_string_lossy().into())
    }
    fn listening(&self) -> bool {
        false
    }
    fn patches(&mut self) -> Vec<Value> {
        std::mem::take(&mut *self.patches.borrow_mut())
    }
}

/// The main area as the kernel lays it out for a window of 1500 by 960:
/// the arrange view over the piano roll, the device panel beside them.
fn panes() -> Value {
    json!({
        "panes": [
            { "win": 1, "view": "arrange", "kind": "native", "x": 0, "y": 0, "w": 1088, "h": 500, "focused": true },
            { "win": 2, "view": "pianoroll", "kind": "native", "x": 0, "y": 500, "w": 1088, "h": 396, "focused": false },
            { "win": 3, "view": "devices", "kind": "native", "x": 1088, "y": 0, "w": 412, "h": 896, "focused": false },
        ],
        "borders": [{ "dir": "v", "x": 0, "y": 500, "length": 1088 }],
        "tabs": [{ "title": "arrange" }],
        "tab": 1,
    })
}

/// A window drawn from the fixture, `change` applied to the state first.
fn window_with(change: impl FnOnce(&mut Value)) -> (Harness<'static, View>, Calls) {
    let (harness, calls, _) = window_and_patches(change);
    calls.borrow_mut().clear();
    (harness, calls)
}

/// The same, with the calls of its first frames kept, and a way to push it
/// the scenes' patches.
fn window_and_patches(change: impl FnOnce(&mut Value)) -> (Harness<'static, View>, Calls, Patches) {
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    crate::theme::set_theme(crate::theme::Theme::from_palette(&fixture["palette"]));
    let mut state = fixture["state"].clone();
    state["modal"]["panes"] = panes();
    change(&mut state);
    let calls: Calls = Rc::default();
    let patches: Patches = Rc::default();
    let view = View::new(Box::new(Fake { state: Some(state), calls: calls.clone(), patches: patches.clone() }), true);
    // The window's fonts are given in the first frame and drawn with from the next.
    let mut first = true;
    let mut harness = Harness::builder().with_size(vec2(1500.0, 960.0)).with_step_dt(1.0 / 60.0).build_ui_state(
        move |ui, view: &mut View| {
            if std::mem::take(&mut first) {
                ui.ctx().set_fonts(crate::theme::fonts(None));
                return;
            }
            view.frame(ui)
        },
        view,
    );
    harness.run_steps(3);
    (harness, calls, patches)
}

fn window() -> (Harness<'static, View>, Calls) {
    window_with(|_| {})
}

fn button(h: &Harness<View>, pos: Pos2, button: PointerButton, pressed: bool, modifiers: Modifiers) {
    h.event(Event::PointerButton { pos, button, pressed, modifiers });
}

/// A press and a release where it was, with what is held.
fn click_with(h: &mut Harness<View>, pos: Pos2, b: PointerButton, m: Modifiers) {
    h.event(Event::ModifiersChanged(m));
    h.hover_at(pos);
    button(h, pos, b, true, m);
    button(h, pos, b, false, m);
    h.event(Event::ModifiersChanged(Modifiers::NONE));
    // Long enough after that the next click is not a double one.
    h.run_steps(30);
}

fn click(h: &mut Harness<View>, pos: Pos2) {
    click_with(h, pos, PointerButton::Primary, Modifiers::NONE);
}

fn right_click(h: &mut Harness<View>, pos: Pos2) {
    click_with(h, pos, PointerButton::Secondary, Modifiers::NONE);
}

fn double_click(h: &mut Harness<View>, pos: Pos2) {
    h.hover_at(pos);
    for _ in 0..2 {
        button(h, pos, PointerButton::Primary, true, Modifiers::NONE);
        button(h, pos, PointerButton::Primary, false, Modifiers::NONE);
    }
    h.run_steps(2);
}

/// A press at `from`, moves in steps to `to`, a release there.
fn drag_with(h: &mut Harness<View>, from: Pos2, to: Pos2, b: PointerButton, m: Modifiers) {
    h.event(Event::ModifiersChanged(m));
    h.hover_at(from);
    button(h, from, b, true, m);
    for step in 1..=8 {
        h.hover_at(from + (to - from) * step as f32 / 8.0);
    }
    button(h, to, b, false, m);
    h.event(Event::ModifiersChanged(Modifiers::NONE));
    h.run_steps(2);
}

fn drag(h: &mut Harness<View>, from: Pos2, to: Pos2) {
    drag_with(h, from, to, PointerButton::Primary, Modifiers::NONE);
}

/// The arguments of the last `paw.frontend.act.<name>` the window sent.
fn acted(calls: &Calls, name: &str) -> Option<Vec<Value>> {
    let code = format!("return paw.frontend.act.{name}(...)");
    calls.borrow().iter().rev().find(|(m, p)| m == "eval" && p[0] == code.as_str()).map(|(_, p)| p.as_array().unwrap()[1..].to_vec())
}

fn act(calls: &Calls, name: &str) -> Vec<Value> {
    acted(calls, name).unwrap_or_else(|| panic!("no {name} among {:?}", calls.borrow().iter().map(|c| c.1[0].clone()).collect::<Vec<_>>()))
}

/// Whether a command line or Lua containing `words` was sent.
fn sent(calls: &Calls, words: &str) -> bool {
    calls.borrow().iter().any(|(_, p)| p.to_string().contains(words))
}

fn num(v: &Value) -> f64 {
    v.as_f64().unwrap()
}

// Where things are, as the window draws them at 1500 by 960 with the
// fixture: the main area starts under the transport bar (40 and a line),
// the ruler is 28 high and the markers' band 18, a row is 66 high, and a
// beat 28 wide from the headers' 240.
const AREA_TOP: f32 = 41.0;
const LANES_TOP: f32 = AREA_TOP + 28.0 + 18.0;
fn beat_x(beat: f32) -> f32 {
    240.0 + beat * 28.0
}
/// The tops of track A (its clips, then its lane row), B and C.
const ROW_A: f32 = LANES_TOP;
const LANE_ROW_A: f32 = LANES_TOP + 66.0;
const ROW_B: f32 = LANES_TOP + 66.0 * 1.8;
const ROW_C: f32 = ROW_B + 66.0;

// ------------------------------------------------------------- the timeline

#[test]
fn a_click_on_the_timeline_puts_the_cursor_and_a_drag_selects_time() {
    let (mut h, calls) = window();
    click(&mut h, pos2(beat_x(10.0), ROW_C + 30.0));
    let args = act(&calls, "select");
    assert_eq!(args[0], 5, "track C");
    assert!((num(&args[1]) - 10.0).abs() < 0.05, "at beat 10: {args:?}");
    drag(&mut h, pos2(beat_x(2.0), ROW_B + 20.0), pos2(beat_x(6.0), ROW_C + 20.0));
    let args = act(&calls, "select_range");
    assert_eq!((args[0].clone(), args[2].clone()), (json!(2), json!(3)), "rows B to C");
    assert!((num(&args[1]) - 2.0).abs() < 0.05 && (num(&args[3]) - 6.0).abs() < 0.05);
}

#[test]
fn a_double_click_on_an_empty_lane_makes_a_clip() {
    let (mut h, calls) = window();
    double_click(&mut h, pos2(beat_x(20.3), ROW_C + 30.0));
    let args = act(&calls, "add_clip");
    assert_eq!(args[0], 5);
    assert!((num(&args[1]) - 20.3).abs() < 0.05);
}

#[test]
fn a_right_drag_chooses_clips_in_a_box_and_a_right_click_opens_the_menu() {
    let (mut h, calls) = window();
    drag_with(&mut h, pos2(beat_x(1.0), ROW_A + 10.0), pos2(beat_x(14.0), ROW_B + 30.0), PointerButton::Secondary, Modifiers::SHIFT);
    let args = act(&calls, "select_clips_box");
    assert_eq!((args[0].clone(), args[2].clone(), args[4].clone()), (json!(1), json!(2), json!("add")));
    right_click(&mut h, pos2(beat_x(20.0), ROW_C + 30.0));
    assert!(sent(&calls, "paw.frontend.menu(") && sent(&calls, "\"timeline\""), "the timeline's menu");
    assert!(h.state().menu.is_some());
}

#[test]
fn the_middle_button_pans_and_ctrl_and_the_wheel_zoom() {
    let (mut h, _) = window();
    // Wide enough to pan: a beat 80 pixels.
    h.state_mut().arrange.zoom = 80.0;
    h.run_steps(2);
    drag_with(&mut h, pos2(700.0, ROW_C + 30.0), pos2(500.0, ROW_C + 30.0), PointerButton::Middle, Modifiers::NONE);
    assert!(h.state().arrange.scroll.x > 150.0, "panned: {:?}", h.state().arrange.scroll);
    let zoom = h.state().arrange.zoom;
    h.event(Event::ModifiersChanged(Modifiers::CTRL));
    h.event(Event::MouseWheel { unit: egui::MouseWheelUnit::Line, delta: vec2(0.0, 1.0), modifiers: Modifiers::CTRL, phase: egui::TouchPhase::Move, source: egui::MouseWheelSource::Wheel });
    h.run_steps(2);
    assert!(h.state().arrange.zoom > zoom, "zoomed in");
}

// ----------------------------------------------------------------- clips

#[test]
fn a_click_chooses_a_clip_ctrl_toggles_and_shift_adds() {
    let (mut h, calls) = window();
    let body = pos2(beat_x(5.5), ROW_A + 40.0);
    click(&mut h, body);
    assert_eq!(act(&calls, "select_clip")[2], "only");
    click_with(&mut h, body, PointerButton::Primary, Modifiers::CTRL);
    assert_eq!(act(&calls, "select_clip")[2], "toggle");
    click_with(&mut h, body, PointerButton::Primary, Modifiers::SHIFT);
    assert_eq!(act(&calls, "select_clip")[2], "add");
}

#[test]
fn a_clip_dragged_moves_by_beats_and_rows_and_ctrl_copies() {
    let (mut h, calls) = window();
    drag(&mut h, pos2(beat_x(5.5), ROW_A + 40.0), pos2(beat_x(13.5), ROW_B + 40.0));
    let args = act(&calls, "drag_clips");
    assert_eq!(args[0], 2);
    assert!((num(&args[1]) - 8.0).abs() < 0.05, "eight beats: {args:?}");
    assert_eq!((args[2].clone(), args[3].clone()), (json!(1), json!(false)), "a row down, not a copy");
    drag_with(&mut h, pos2(beat_x(5.5), ROW_A + 40.0), pos2(beat_x(7.5), ROW_A + 40.0), PointerButton::Primary, Modifiers::CTRL);
    assert_eq!(act(&calls, "drag_clips")[3], true, "Ctrl copies");
}

#[test]
fn either_edge_of_a_clip_trims_it_and_alt_slips() {
    let (mut h, calls) = window();
    drag(&mut h, pos2(beat_x(8.0) - 4.0, ROW_A + 40.0), pos2(beat_x(10.0) - 4.0, ROW_A + 40.0));
    let args = act(&calls, "trim_clips");
    assert_eq!(args[1], "end");
    assert!((num(&args[2]) - 2.0).abs() < 0.05);
    drag_with(&mut h, pos2(beat_x(4.0) + 3.0, ROW_A + 40.0), pos2(beat_x(5.0) + 3.0, ROW_A + 40.0), PointerButton::Primary, Modifiers::ALT);
    let args = act(&calls, "trim_clips");
    assert_eq!((args[1].clone(), args[4].clone()), (json!("start"), json!(true)), "the start, slipped");
}

#[test]
fn a_double_click_on_a_clip_opens_its_notes_and_a_right_click_its_menu() {
    let (mut h, calls) = window();
    double_click(&mut h, pos2(beat_x(5.5), ROW_A + 40.0));
    assert_eq!(act(&calls, "open_clip"), [json!(2)]);
    right_click(&mut h, pos2(beat_x(6.0), ROW_A + 40.0));
    let menu = calls.borrow().iter().rev().find(|c| c.1[0].as_str().unwrap_or("").contains("paw.frontend.menu(")).cloned().unwrap();
    assert_eq!(menu.1[1], "clip");
    assert_eq!(menu.1[2][0], 2);
    assert!((num(&menu.1[2][1]) - 6.0).abs() < 0.05, "the beat clicked");
}

#[test]
fn an_audio_clips_fades_gain_and_warp_markers_take_the_pointer() {
    let (mut h, calls) = window_with(|s| {
        let clip = &mut s["clips"][0];
        clip["midi"] = json!(false);
        clip["stamp"] = Value::Null;
        clip["waveform"] = json!("w");
        clip["fade_in"] = json!(1);
        clip["warps"] = json!([2]);
    });
    // The fade-in's handle is a beat in, at the top.
    drag(&mut h, pos2(beat_x(5.0), ROW_A + 5.0), pos2(beat_x(6.0), ROW_A + 5.0));
    let args = act(&calls, "set_fade");
    assert_eq!(args[1], "in");
    assert!((num(&args[2]) - 2.0).abs() < 0.1, "{args:?}");
    // The gain line along the top.
    drag(&mut h, pos2(beat_x(7.0), ROW_A + 3.0), pos2(beat_x(7.0), ROW_A + 23.0));
    assert!((num(&act(&calls, "set_clip_gain")[1]) + 5.0).abs() < 0.5, "a quarter of a dB a pixel down");
    // The warp marker's handle, two beats in.
    drag(&mut h, pos2(beat_x(6.0), ROW_A + 4.0), pos2(beat_x(6.5), ROW_A + 4.0));
    let args = act(&calls, "warp_move");
    assert_eq!(args[1], 1);
    // A double click on the top band puts a marker.
    double_click(&mut h, pos2(beat_x(7.5), ROW_A + 8.0));
    assert!((num(&act(&calls, "warp_add")[1]) - 7.5).abs() < 0.05);
}

// ------------------------------------------------------------- the ruler

#[test]
fn the_ruler_clicks_loops_and_moves_tempo_flags() {
    let (mut h, calls) = window();
    click(&mut h, pos2(beat_x(3.0), AREA_TOP + 20.0));
    assert!((num(&act(&calls, "ruler_click")[0]) - 3.0).abs() < 0.05);
    drag(&mut h, pos2(beat_x(2.0), AREA_TOP + 5.0), pos2(beat_x(6.0), AREA_TOP + 5.0));
    let args = act(&calls, "set_loop");
    assert!((num(&args[0]) - 2.0).abs() < 0.05 && (num(&args[1]) - 6.0).abs() < 0.05);
    // The tempo flag at beat 16.
    drag(&mut h, pos2(beat_x(16.0) + 8.0, AREA_TOP + 14.0), pos2(beat_x(18.0) + 8.0, AREA_TOP + 14.0));
    let args = act(&calls, "tempo_mark");
    assert_eq!((args[0].clone(), args[1].clone()), (json!("move"), json!("tempo")));
    assert!((num(&args[3]) - 18.0).abs() < 0.05);
    double_click(&mut h, pos2(beat_x(16.0) + 8.0, AREA_TOP + 14.0));
    assert_eq!(act(&calls, "tempo_mark")[0], "edit");
}

#[test]
fn a_marker_takes_a_click_and_a_drag() {
    let (mut h, calls) = window();
    click(&mut h, pos2(beat_x(8.0) + 12.0, AREA_TOP + 28.0 + 9.0));
    assert!(sent(&calls, "marker.goto id=1"));
    drag(&mut h, pos2(beat_x(8.0) + 12.0, AREA_TOP + 37.0), pos2(beat_x(10.0) + 12.0, AREA_TOP + 37.0));
    assert!(sent(&calls, "marker.set id=1 beat=10"), "{:?}", calls.borrow());
}

// ------------------------------------------------------------- the headers

#[test]
fn a_header_selects_its_track_and_dragged_moves_it() {
    let (mut h, calls) = window();
    click(&mut h, pos2(70.0, ROW_B + 17.0));
    assert_eq!(act(&calls, "select")[0], 3);
    drag(&mut h, pos2(70.0, ROW_B + 17.0), pos2(70.0, ROW_C + 50.0));
    assert_eq!(act(&calls, "move_track"), [json!(3), json!(3)]);
}

#[test]
fn m_s_and_r_toggle_and_a_press_swept_sets_them_all() {
    let (mut h, calls) = window();
    // M is at 134 on a header's first line.
    click(&mut h, pos2(134.0, ROW_B + 13.0));
    assert_eq!(act(&calls, "toggle"), [json!(3), json!("mute")]);
    drag(&mut h, pos2(134.0, ROW_A + 13.0), pos2(134.0, ROW_C + 13.0));
    let args = act(&calls, "sweep_flag");
    assert_eq!((args[0].clone(), args[1].clone(), args[2].clone()), (json!(1), json!(3), json!("mute")));
}

#[test]
fn a_header_renames_on_a_double_click_and_its_edge_sets_the_height() {
    let (mut h, calls) = window();
    double_click(&mut h, pos2(70.0, ROW_C + 13.0));
    assert!(h.state().arrange.renaming.is_some(), "a box to type the name in");
    h.event(Event::Key { key: egui::Key::A, physical_key: None, pressed: true, repeat: false, modifiers: Modifiers::CTRL });
    h.event(Event::Text("Zebra".into()));
    h.event(Event::Key { key: egui::Key::Enter, physical_key: None, pressed: true, repeat: false, modifiers: Modifiers::NONE });
    h.run_steps(3);
    assert_eq!(act(&calls, "rename_track"), [json!(5), json!("Zebra")]);
    drag(&mut h, pos2(100.0, ROW_C + 64.0), pos2(100.0, ROW_C + 97.0));
    let args = act(&calls, "set_track_height");
    assert!((num(&args[1]) - 1.5).abs() < 0.05, "half as tall again: {args:?}");
}

#[test]
fn a_headers_fader_sets_the_volume_and_a_double_click_puts_it_at_0_db() {
    let (mut h, calls) = window();
    // The fader's well runs from 38 to 128 on track C's second line.
    drag(&mut h, pos2(80.0, ROW_C + 37.0), pos2(120.0, ROW_C + 37.0));
    let args = act(&calls, "set_volume");
    assert_eq!(args[0], 5);
    assert!(sent(&calls, "\"volume\""), "held while dragged, for automation by touch");
    double_click(&mut h, pos2(100.0, ROW_C + 37.0));
    assert_eq!(act(&calls, "set_volume"), [json!(5), json!(0.0)]);
}

#[test]
fn a_right_click_on_a_header_opens_the_tracks_menu_and_its_input_button_the_inputs() {
    let (mut h, calls) = window();
    right_click(&mut h, pos2(60.0, ROW_C + 50.0));
    assert!(sent(&calls, "\"track\",[5]"), "{:?}", calls.borrow());
    h.state_mut().menu = None;
    click(&mut h, pos2(90.0, ROW_C + 13.0));
    assert!(sent(&calls, "\"input\",[5]"));
}

// ---------------------------------------------------- lanes, automation, takes

#[test]
fn a_lane_row_takes_a_click_and_a_stroke() {
    let (mut h, calls) = window();
    click(&mut h, pos2(beat_x(20.0), LANE_ROW_A + 26.0));
    let args = act(&calls, "add_point");
    assert_eq!(args[0], 7);
    drag(&mut h, pos2(beat_x(20.0), LANE_ROW_A + 45.0), pos2(beat_x(28.0), LANE_ROW_A + 8.0));
    let args = act(&calls, "draw_lane");
    assert_eq!(args[0], 7);
    assert!(args[1].as_array().unwrap().len() > 3, "the stroke's points");
}

#[test]
fn with_automation_shown_the_pencil_draws_over_the_clips() {
    let (mut h, calls) = window();
    h.state_mut().show_automation = true;
    h.run_steps(2);
    click(&mut h, pos2(beat_x(20.0), ROW_C + 20.0));
    assert!(sent(&calls, "paw.frontend.act.lane("), "a lane made for the track");
    assert_eq!(act(&calls, "add_point")[0], 7);
}

#[test]
fn a_take_lane_takes_a_click_and_a_swipe() {
    let (mut h, calls) = window_with(|s| {
        s["tracks"][1]["take_rows"] = json!(2);
        s["clips"][1]["take_rows"] = json!([{ "name": "take 1", "key": "a" }, { "name": "take 2", "key": "b" }]);
    });
    let lane = ROW_B + 66.0 + 66.0 * 0.6 + 10.0;
    click(&mut h, pos2(beat_x(13.0), lane));
    assert_eq!(&act(&calls, "take_click")[..2], [json!(3), json!(2)]);
    drag(&mut h, pos2(beat_x(13.0), lane), pos2(beat_x(15.0), lane));
    assert_eq!(&act(&calls, "comp")[..2], [json!(3), json!(2)]);
}

// ---------------------------------------------------------- the piano roll

const ROLL_TOP: f32 = AREA_TOP + 500.0;

/// The grid's top, under the toolbar and the ruler (and the chords' row
/// when there are chords).
fn roll_grid_top(h: &Harness<View>) -> f32 {
    let chords = h.state().s.modal["roll"]["chords"].as_array().is_some_and(|c| !c.is_empty());
    ROLL_TOP + 32.0 + 22.0 + if chords { 16.0 } else { 0.0 }
}

#[test]
fn the_piano_roll_draws_chooses_moves_and_removes_notes() {
    let (mut h, calls) = window();
    h.run_steps(3);
    let top = roll_grid_top(&h);
    let roll = &h.state().roll;
    let (zoom, row) = (roll.zoom, 12.0);
    let scroll = h.state().roll.scrolled();
    let at = |beat: f32, pitch: i64| pos2(64.0 + beat * zoom - scroll.x + 3.0, top + (127 - pitch) as f32 * row - scroll.y + 5.0);
    // A note: a click chooses it, a drag moves it.
    click(&mut h, at(0.3, 60));
    assert_eq!(act(&calls, "select_note"), [json!(2), json!(1), json!("only")]);
    drag(&mut h, at(0.3, 60), at(1.3, 62));
    let args = act(&calls, "drag_notes");
    assert_eq!(args[2].as_f64().map(|b| (b * 10.0).round()), Some(10.0), "a beat later: {args:?}");
    assert_eq!(args[3], 2.0, "two semitones up");
    // Empty grid: a drag draws a note.
    drag(&mut h, at(3.0, 72), at(3.9, 72));
    let args = act(&calls, "add_note");
    assert_eq!(args[1], 72);
    // The right button removes a note it clicks, and its box chooses.
    right_click(&mut h, at(1.3, 64));
    assert_eq!(act(&calls, "remove_note"), [json!(2), json!(2)]);
    drag_with(&mut h, at(0.1, 70), at(2.9, 58), PointerButton::Secondary, Modifiers::NONE);
    let args = act(&calls, "select_notes_box");
    assert_eq!(args[5], "only");
}

#[test]
fn the_rolls_keyboard_sounds_keys_and_its_strip_draws_velocities() {
    let (mut h, calls) = window();
    h.run_steps(3);
    let top = roll_grid_top(&h);
    let scroll = h.state().roll.scrolled();
    click(&mut h, pos2(20.0, top + (127.0 - 60.0) * 12.0 - scroll.y + 6.0));
    assert_eq!(act(&calls, "audition")[1], 60);
    let strip = ROLL_TOP + 396.0 - 40.0;
    drag(&mut h, pos2(80.0, strip + 30.0), pos2(400.0, strip - 30.0));
    let args = act(&calls, "draw_velocities");
    assert_eq!(args[0], 2);
}

#[test]
fn the_rolls_toolbar_quantizes_snaps_and_closes() {
    let (mut h, calls) = window();
    h.run_steps(3);
    let target = h.get_by_label("Quantize").rect().center();
    click(&mut h, target);
    assert_eq!(act(&calls, "quantize_notes"), [json!(2)]);
    let target = h.get_by_label("List").rect().center();
    click(&mut h, target);
    assert_eq!(act(&calls, "open_event_list"), [json!(2)]);
}

// -------------------------------------------------- devices, mixer, transport

#[test]
fn the_device_box_finds_and_adds_a_device() {
    let (mut h, calls) = window();
    click(&mut h, pos2(1300.0, AREA_TOP + 64.0));
    h.event(Event::Text("syn".into()));
    h.run_steps(3);
    assert!(sent(&calls, "search_devices"));
    h.event(Event::Key { key: egui::Key::Enter, physical_key: None, pressed: true, repeat: false, modifiers: Modifiers::NONE });
    h.run_steps(3);
    assert_eq!(act(&calls, "add_device"), [json!("synth"), json!("syn")]);
}

#[test]
fn a_devices_power_button_and_its_parameters_take_the_pointer() {
    let (mut h, calls) = window();
    let power = h.get_by_label("power of Synth").rect().center();
    click(&mut h, power);
    assert!(acted(&calls, "toggle_bypass").is_some(), "the power button");
}

#[test]
fn the_transport_buttons_and_the_file_menu() {
    let (mut h, calls) = window();
    let play = h.get_by_label("play").rect().center();
    click(&mut h, play);
    assert!(sent(&calls, "transport.toggle"));
    click(&mut h, pos2(40.0, 20.0));
    assert!(sent(&calls, "\"file\""));
    // A menu's entry is chosen by its place; one the window does itself is done here.
    let first = h.state().menu.as_ref().unwrap().at + vec2(40.0, 4.0 + 12.0);
    click(&mut h, first);
    let choose = act(&calls, "menu_choose");
    assert_eq!(choose[0], "file");
    assert_eq!(choose[2], json!([1]));
}

#[test]
fn quitting_with_changes_asks_and_save_says_so_to_the_kernel() {
    let (mut h, calls) = window();
    h.state_mut().leave("quit");
    h.run_steps(2);
    assert!(h.state().dialogs.closing.is_some(), "the question");
    let save = h.get_by_label("Save").rect().center();
    click(&mut h, save);
    assert_eq!(act(&calls, "leave"), [json!("save"), json!("quit")]);
}

// ------------------------------------------------------------------ keys

#[test]
fn keys_go_to_the_kernels_mappings_and_ctrl_a_in_the_roll_chooses_every_note() {
    let (mut h, calls) = window();
    h.event(Event::Key { key: egui::Key::J, physical_key: None, pressed: true, repeat: false, modifiers: Modifiers::NONE });
    h.event(Event::Text("j".into()));
    h.run_steps(2);
    assert!(calls.borrow().iter().any(|(m, p)| m == "keys" && p[0] == "j"));
    h.event(Event::Key { key: egui::Key::A, physical_key: None, pressed: true, repeat: false, modifiers: Modifiers::CTRL });
    h.run_steps(2);
    assert!(calls.borrow().iter().any(|(m, p)| m == "keys" && p[0] == "gA"), "the fixture's roll has the keys");
}

#[test]
fn ctrl_and_plus_zoom_and_ctrl_0_shows_the_whole_song() {
    let (mut h, _) = window();
    let zoom = h.state().arrange.zoom;
    h.event(Event::Key { key: egui::Key::Plus, physical_key: None, pressed: true, repeat: false, modifiers: Modifiers::CTRL });
    h.run_steps(2);
    assert!(h.state().arrange.zoom > zoom);
    h.event(Event::Key { key: egui::Key::Num0, physical_key: None, pressed: true, repeat: false, modifiers: Modifiers::CTRL });
    h.run_steps(2);
    // The song and a bar across the timeline's 848 pixels, less a margin.
    let s = &h.state().s;
    let fit = (848.0 - 24.0) / (s.bar().max(crate::model::number(&s.project["length"]) + s.bar()));
    assert!((h.state().arrange.zoom - fit).abs() < 0.01 && h.state().arrange.scroll.x == 0.0);
}

// ----------------------------------------------------------------- fonts

/// Whether every character of `text` has a glyph of its own in the
/// window's fonts, with `cjk` as the system's font for Japanese, and is laid
/// out wide and drawn: not the replacement box.
fn drawn_with_glyphs_of_their_own(cjk: Option<(Vec<u8>, u32)>, text: &str) -> bool {
    let ctx = egui::Context::default();
    ctx.set_fonts(crate::theme::fonts(cjk));
    let _ = ctx.run_ui(egui::RawInput::default(), |_| {});
    let font = egui::FontId::proportional(14.0);
    let laid = ctx.fonts_mut(|f| f.layout_no_wrap(text.into(), font.clone(), egui::Color32::WHITE));
    let glyphs: Vec<_> = laid.rows.iter().flat_map(|r| r.glyphs.iter()).collect();
    assert_eq!(glyphs.len(), text.chars().count());
    for g in &glyphs {
        assert!(g.advance_width > 0.0, "{} has no width", g.chr);
        assert!(!g.uv_rect.is_nothing(), "{} draws nothing", g.chr);
    }
    ctx.fonts_mut(|f| text.chars().all(|ch| f.has_glyph(&font, ch)))
}

#[test]
fn japanese_lyrics_are_drawn_with_glyphs_of_their_own() {
    // With the bundled kana alone, as on a system with no font for Japanese.
    assert!(drawn_with_glyphs_of_their_own(None, "さくらサクラ"));
    // The test can fail: a kanji with no font for it is the box.
    assert!(!drawn_with_glyphs_of_their_own(None, "桜"));
    // With the system's font, kanji too.
    let Some(cjk) = crate::theme::cjk_font() else {
        eprintln!("no CJK font on this system: its kanji are not tried");
        return;
    };
    assert!(drawn_with_glyphs_of_their_own(Some(cjk), "さくら桜"));
}

// --------------------------------------------------- the transport bar's rest

#[test]
fn the_views_buttons_show_views_and_more_and_track_open_menus() {
    let (mut h, calls) = window();
    for (label, words) in [("Session", "view.toggle session"), ("Mixer", "view.toggle mixer"), ("Piano roll", "view.toggle pianoroll")] {
        let at = h.get_by_label(label).rect().center();
        click(&mut h, at);
        assert!(sent(&calls, words), "{label}");
    }
    let shown = h.state().show_automation;
    let at = h.get_by_label("Automation").rect().center();
    click(&mut h, at);
    assert_ne!(h.state().show_automation, shown, "Automation shows the lanes over the clips");
    for (label, kind) in [("More", "\"views\""), ("Track", "\"add_track\"")] {
        h.state_mut().menu = None;
        let at = h.get_by_label(label).rect().center();
        click(&mut h, at);
        assert!(sent(&calls, kind), "{label}'s menu");
    }
}

#[test]
fn the_transport_buttons_tempo_and_engine_take_the_pointer() {
    let (mut h, calls) = window();
    for (name, words) in [("stop", "transport.stop"), ("loop", "transport.loop"), ("click", "transport.metronome")] {
        let at = h.get_by_label(name).rect().center();
        click(&mut h, at);
        assert!(sent(&calls, words), "{name}");
    }
    let at = h.get_by_label("record").rect().center();
    click(&mut h, at);
    assert!(acted(&calls, "record").is_some());
    let at = h.get_by_label("start").rect().center();
    click(&mut h, at);
    assert!(calls.borrow().iter().any(|(_, p)| p[0] == "return paw.api.transport_seek(...)" && p[1] == 0.0), "back to the start");
    // The tempo: dragged up, a step up; the wheel down, a step down; a
    // double click types it.
    let tempo = h.get_by_label("tempo").rect().center();
    drag(&mut h, tempo, tempo - vec2(0.0, 30.0));
    assert!(sent(&calls, "tempo by=1"));
    h.hover_at(tempo);
    h.event(Event::MouseWheel { unit: egui::MouseWheelUnit::Line, delta: vec2(0.0, -1.0), modifiers: Modifiers::NONE, phase: egui::TouchPhase::Move, source: egui::MouseWheelSource::Wheel });
    h.run_steps(2);
    assert!(sent(&calls, "tempo by=-1"));
    double_click(&mut h, tempo);
    assert!(calls.borrow().iter().any(|(m, p)| m == "eval" && p.to_string().contains(":tempo ")), "the command line, with :tempo typed");
    let engine = h.get_by_label("engine").rect().center();
    click(&mut h, engine);
    assert!(sent(&calls, "\"engine\""), "the engine's menu");
}

#[test]
fn the_loops_edges_drag_and_a_double_click_on_the_ruler_turns_it_on_or_off() {
    let (mut h, calls) = window_with(|s| {
        s["project"]["loop_enabled"] = json!(true);
        s["project"]["loop_start"] = json!(4);
        s["project"]["loop_end"] = json!(12);
    });
    drag(&mut h, pos2(beat_x(12.0), AREA_TOP + 5.0), pos2(beat_x(14.0), AREA_TOP + 5.0));
    let args = act(&calls, "set_loop_edge");
    assert_eq!(args[0], "end");
    assert!((num(&args[1]) - 14.0).abs() < 0.05, "{args:?}");
    double_click(&mut h, pos2(beat_x(20.0), AREA_TOP + 5.0));
    assert!(sent(&calls, "transport.loop"));
}

// ------------------------------------------------------------------ the mixer

fn mixer_window() -> (Harness<'static, View>, Calls) {
    window_with(|s| {
        s["modal"]["panes"]["panes"][1]["view"] = json!("mixer");
    })
}

#[test]
fn a_strips_fader_pan_and_switches_take_the_pointer() {
    let (mut h, calls) = mixer_window();
    let fader = h.get_by_label("fader of B").rect();
    drag(&mut h, pos2(fader.center().x, fader.bottom() - 30.0), pos2(fader.center().x, fader.top() + 40.0));
    let args = act(&calls, "set_volume");
    assert_eq!(args[0], 3);
    assert!(num(&args[1]) > -5.0, "up is louder: {args:?}");
    assert!(sent(&calls, "\"volume\""), "held while dragged, for automation by touch");
    let pan = h.get_by_label("pan of B").rect().center();
    drag(&mut h, pan, pan - vec2(0.0, 40.0));
    assert!(num(&act(&calls, "set_pan")[1]) > 0.0, "up is to the right");
    double_click(&mut h, pan);
    assert_eq!(act(&calls, "set_pan"), [json!(3), json!(0.0)]);
    for name in ["mute", "solo", "armed"] {
        let at = h.get_by_label(&format!("{name} of C")).rect().center();
        click(&mut h, at);
        assert_eq!(act(&calls, "toggle"), [json!(5), json!(name)]);
    }
}

#[test]
fn a_strips_name_chooses_its_track_and_a_right_click_opens_its_menu() {
    let (mut h, calls) = mixer_window();
    let plate = h.get_by_label("strip of C").rect().center();
    click(&mut h, plate);
    assert_eq!(act(&calls, "select")[0], 5);
    right_click(&mut h, plate);
    assert!(sent(&calls, "\"track\",[5]"));
}

// ---------------------------------------------------------------- the devices

#[test]
fn a_devices_buttons_remove_and_move_it() {
    let (mut h, calls) = window_with(|s| {
        let synth = s["devices"][0].clone();
        let mut delay = synth.clone();
        delay["id"] = json!(9);
        delay["name"] = json!("Delay");
        s["devices"] = json!([synth, delay]);
    });
    let at = h.get_by_label("move Delay up").rect().center();
    click(&mut h, at);
    assert_eq!(act(&calls, "move_device"), [json!(9), json!(-1)]);
    let at = h.get_by_label("move Synth down").rect().center();
    click(&mut h, at);
    assert_eq!(act(&calls, "move_device"), [json!(8), json!(1)]);
    let at = h.get_by_label("remove Synth").rect().center();
    click(&mut h, at);
    assert!(calls.borrow().iter().any(|(_, p)| p[0] == "return paw.api.device_remove(...)" && p[1] == 8));
}

// ------------------------------------------------------------ the session view

#[test]
fn the_session_views_bar_stops_goes_back_captures_and_quantizes() {
    let (mut h, calls) = window_with(|s| {
        s["modal"]["panes"]["panes"][1]["view"] = json!("session");
        s["modal"]["session"] = json!(true);
    });
    let at = h.get_by_label("Stop all").rect().center();
    click(&mut h, at);
    assert!(acted(&calls, "stop_slots").is_some());
    let at = h.get_by_label("Back to timeline").rect().center();
    click(&mut h, at);
    assert!(acted(&calls, "back_to_timeline").is_some());
    let at = h.get_by_label("Capture").rect().center();
    click(&mut h, at);
    assert!(sent(&calls, "launch.capture"));
    let at = h.get_by_label("2bars").rect().center();
    click(&mut h, at);
    assert!(sent(&calls, "launch.quantize 2bars"));
}

// ------------------------------------------------------------------ the panes

#[test]
fn a_border_between_panes_dragged_shares_the_room() {
    let (mut h, calls) = window();
    // The border under the arrange view, 500 down the main area.
    drag(&mut h, pos2(500.0, AREA_TOP + 500.0), pos2(500.0, AREA_TOP + 420.0));
    let last = calls.borrow().iter().rev().find(|(_, p)| p[0] == "paw.panes.border(...)").cloned().expect("the border moved");
    assert_eq!(last.1[1], 1);
    assert!((num(&last.1[3]) - 420.0).abs() < 2.0, "{last:?}");
}

#[test]
fn a_press_in_a_pane_gives_it_the_keyboard() {
    let (mut h, calls) = window();
    click(&mut h, pos2(1300.0, AREA_TOP + 600.0));
    assert!(calls.borrow().iter().any(|(_, p)| p[0] == "paw.panes.focus(...)" && p[1] == 3), "the device panel");
}

/// Every character the window's own code and the kernel's menus for it
/// write has a glyph in the bundled fonts, so none shows as a box.
#[test]
fn what_the_window_writes_has_glyphs() {
    let sources = [
        include_str!("app.rs"),
        include_str!("arrange.rs"),
        include_str!("canvas.rs"),
        include_str!("chrome.rs"),
        include_str!("devices.rs"),
        include_str!("dialogs.rs"),
        include_str!("headers.rs"),
        include_str!("menu.rs"),
        include_str!("mixer.rs"),
        include_str!("model.rs"),
        include_str!("panes.rs"),
        include_str!("roll.rs"),
        include_str!("ruler.rs"),
        include_str!("session.rs"),
        include_str!("widgets.rs"),
        include_str!("../../../runtime/lua/paw/window_menus.lua"),
        include_str!("../../../runtime/lua/paw/mouse_menus.lua"),
    ];
    let ctx = egui::Context::default();
    ctx.set_fonts(crate::theme::fonts(None));
    let _ = ctx.run_ui(egui::RawInput::default(), |_| {});
    let mut missing: Vec<char> = Vec::new();
    for source in sources {
        for ch in source.chars().filter(|c| !c.is_ascii()) {
            if missing.contains(&ch) {
                continue;
            }
            let has = ctx.fonts_mut(|f| f.has_glyph(&egui::FontId::proportional(12.0), ch) && f.has_glyph(&egui::FontId::monospace(12.0), ch));
            if !has {
                missing.push(ch);
            }
        }
    }
    assert!(missing.is_empty(), "no glyph for {missing:?}");
}

// ------------------------------------------------------------ the kernel's panes

/// A window with the piano roll's pane given to a view the kernel draws
/// in cells, and the patches it is sent.
fn kernel_pane_window() -> (Harness<'static, View>, Calls, Patches) {
    window_and_patches(|s| {
        s["modal"]["panes"]["panes"][1]["view"] = json!("help");
        s["modal"]["panes"]["panes"][1]["kind"] = json!("cells");
    })
}

/// The text of every piece of text the window drew in its last frame.
fn drawn_text(h: &Harness<View>) -> String {
    let mut out = String::new();
    for clipped in &h.output().shapes {
        if let egui::Shape::Text(text) = &clipped.shape {
            out.push_str(text.galley.text());
            out.push('\n');
        }
    }
    out
}

#[test]
fn a_pane_the_kernel_draws_is_sized_in_cells_and_drawn_from_its_scene() {
    let (mut h, calls, patches) = kernel_pane_window();
    let cell = h.state().scenes.cell.expect("the cell measured in the first frames");
    assert!(calls.borrow().iter().any(|(m, _)| m == "scene.watch"), "scenes watched");
    let area = calls.borrow().iter().find(|(m, _)| m == "scene.area").map(|(_, p)| p.clone()).expect("the pane's size said");
    assert_eq!(area[0], "2", "named by its window");
    // The pane is 1088 wide, inset 6 each side; 396 high, less the title
    // and the inset under it, and with the view's own title row, which the
    // window's title covers.
    let (cw, ch) = (cell.0 as f64, cell.1 as f64);
    assert!((num(&area[1]) - (1088.0 - 12.0) / cw).abs() < 0.01, "{area:?} in cells of {cell:?}");
    assert!((num(&area[2]) - (396.0 - 24.0 - 6.0 + ch) / ch).abs() < 0.01, "{area:?}");
    assert!(!drawn_text(&h).contains("from the kernel"), "nothing before a scene comes");
    let mut scene = paw_scene::Scene::new([40.0, 10.0]);
    (scene.fg, scene.bg) = ("#c9ced8".into(), "#101216".into());
    scene.push(None, paw_scene::Node::new("t0,1", paw_scene::Kind::Run { text: "drawn from the kernel".into() }, [0.0, 1.0, 21.0, 1.0]));
    let mut patch = paw_scene::Scene::diff(&paw_scene::Scene::default(), &scene, "2");
    patch.full = true;
    patches.borrow_mut().push(serde_json::to_value(&patch).unwrap());
    h.run_steps(2);
    assert!(drawn_text(&h).contains("drawn from the kernel"), "{}", drawn_text(&h));
    // Then only what changed comes, and is drawn.
    let mut next = scene.clone();
    next.nodes.get_mut("t0,1").unwrap().kind = paw_scene::Kind::Run { text: "changed by the kernel".into() };
    patches.borrow_mut().push(serde_json::to_value(paw_scene::Scene::diff(&scene, &next, "2")).unwrap());
    h.run_steps(2);
    let text = drawn_text(&h);
    assert!(text.contains("changed by the kernel") && !text.contains("drawn from the kernel"), "{text}");
}

#[test]
fn a_press_in_a_pane_the_kernel_draws_goes_back_in_cells() {
    let (mut h, calls, _) = kernel_pane_window();
    let cell = h.state().scenes.cell.unwrap();
    calls.borrow_mut().clear();
    // Three cells and a half in, two rows and a half under the picture's top.
    let top = AREA_TOP + 500.0 + 24.0 - cell.1;
    let at = pos2(6.0 + 3.5 * cell.0, top + 2.5 * cell.1);
    click(&mut h, at);
    let input = calls
        .borrow()
        .iter()
        .find(|(m, p)| m == "scene.input" && p[1]["kind"] == "down")
        .map(|(_, p)| p.clone())
        .expect("the press passed on");
    assert_eq!(input[0], "2");
    assert!((num(&input[1]["x"]) - 3.5).abs() < 0.01 && (num(&input[1]["y"]) - 2.5).abs() < 0.01, "{input:?}");
}
