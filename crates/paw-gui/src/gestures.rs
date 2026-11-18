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

/// The scenes' patches a test has the stand-in kernel push; a value
/// `{ "scene.live": ... }` among them is pushed as the live values.
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
        let code = params[0].as_str().unwrap_or("");
        Ok(if code.contains("paw.frontend.menu(") {
            json!([{ "label": "First" }, { "separator": true }, { "label": "More", "items": [{ "label": "Inner" }] }, { "label": "Quit", "window": "quit" }])
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
        let mut patches = self.patches.borrow_mut();
        let (live, rest): (Vec<Value>, Vec<Value>) = std::mem::take(&mut *patches).into_iter().partition(|p| p.get("scene.live").is_some());
        *patches = live;
        rest
    }
    fn live(&mut self) -> Option<Value> {
        let mut patches = self.patches.borrow_mut();
        let at = patches.iter().rposition(|p| p.get("scene.live").is_some())?;
        let live = patches.remove(at)["scene.live"].take();
        patches.retain(|p| p.get("scene.live").is_none());
        Some(live)
    }
}

/// The main area as the kernel lays it out for a window of 1500 by 960:
/// the arrange view over the piano roll (both of which the kernel draws),
/// the device panel beside them.
fn panes() -> Value {
    json!({
        "panes": [
            { "win": 1, "view": "arrange", "kind": "cells", "titled": true, "x": 0, "y": 0, "w": 1088, "h": 500, "focused": true },
            { "win": 2, "view": "pianoroll", "kind": "cells", "x": 0, "y": 500, "w": 1088, "h": 396, "focused": false },
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
// fixture: the main area starts under the transport bar (40 and a line).
const AREA_TOP: f32 = 41.0;

// ------------------------------------------------------------- the arrange view

/// The arrange view as the kernel sends it to a window that paints clips
/// (paw/views/arrange.lua): all of it one hit region, its timeline a plane
/// of beats along from 30 columns in, two units a beat, and of the view's
/// lines down from its second; a clip on it between cells; a header's
/// switch; a level across a row, bound to the track's meter.
fn arrange_scene() -> paw_scene::Patch {
    use paw_scene::{Axis, Kind, Node, Plane};
    let mut scene = paw_scene::Scene::new([130.0, 25.0]);
    (scene.fg, scene.bg) = ("#c9ced8".into(), "#101216".into());
    let mut all = Node::new("hit@0,0", Kind::Group, [0.0, 0.0, 130.0, 25.0]);
    all.hit = Some(json!({ "kind": "arrange" }));
    scene.push(None, all);
    let plane = Plane { x: Axis { domain: "beat".into(), from: 0.0, per: 2.0 }, y: Axis { domain: "line".into(), from: 1.0, per: 1.0 } };
    scene.push(None, Node::new("timeline", Kind::Plane(plane), [30.0, 1.0, 100.0, 22.0]));
    let props = json!({ "id": 7, "name": "verse", "label": "verse", "color": "#e0a050", "midi": true, "length": 4.5, "per": 2.0 });
    scene.push(Some("timeline"), Node::new("timeline/clip:7", Kind::Role { role: "clip".into(), props }, [2.25, 1.0, 4.5, 4.0]));
    let props = json!({ "letter": "M", "on": true, "tone": "mute", "label": "mute" });
    scene.push(None, Node::new("switch@20,1", Kind::Role { role: "switch".into(), props }, [20.0, 1.0, 1.0, 1.0]));
    let mut level = Node::new("hmeter@4,2", Kind::Role { role: "hmeter".into(), props: json!({ "at": 0.9, "label": "level" }) }, [4.0, 2.0, 14.0, 1.0]);
    level.bind = Some("meter:1".into());
    scene.push(None, level);
    let mut patch = paw_scene::Scene::diff(&paw_scene::Scene::default(), &scene, "1");
    patch.full = true;
    patch
}

/// The arrange view's pane, drawn from its scene, and the patches it is sent.
fn arrange_window() -> (Harness<'static, View>, Calls, Patches) {
    let (mut h, calls, patches) = window_and_patches(|_| {});
    patches.borrow_mut().push(serde_json::to_value(arrange_scene()).unwrap());
    h.run_steps(2);
    calls.borrow_mut().clear();
    (h, calls, patches)
}

#[test]
fn the_arrange_view_is_the_kernels_scene_its_clips_painted_between_cells() {
    let (h, calls, _) = arrange_window();
    let cell = h.state().scenes.cell.unwrap();
    // The pane shows its ruler as its first row, under no title: the scene
    // starts at the pane's corner. Beat 2.25 is 4.5 units into the plane
    // (30 in); the clip's line, 1, the plane's first, a row down.
    let origin = pos2(0.0, AREA_TOP);
    let clip = h.get_by_label("verse").rect();
    assert!((clip.left() - (origin.x + 34.5 * cell.0)).abs() < 0.5, "{clip:?}");
    assert!((clip.top() - (origin.y + cell.1)).abs() < 0.5 && (clip.width() - 9.0 * cell.0).abs() < 0.5, "{clip:?}");
    assert!(h.query_by_label("mute").is_some() && h.query_by_label("level").is_some(), "the header's switch and level, as widgets");
    assert!(!calls.borrow().iter().any(|(_, p)| p[0].as_str().is_some_and(|c| c.contains("frontend.preview"))), "a clip with no content key asks for nothing");
}

#[test]
fn a_headers_level_moves_with_the_live_values() {
    let (mut h, _, patches) = arrange_window();
    let loud = crate::theme::th().meter_hot;
    let lit = |h: &Harness<View>| h.output().shapes.iter().any(|c| matches!(&c.shape, egui::Shape::Rect(r) if r.fill == loud));
    assert!(!lit(&h), "nothing before the live values");
    patches.borrow_mut().push(json!({ "scene.live": { "meters": { "1": [1.0, 0.2] }, "peaks": { "1": 1.0 } } }));
    h.run_steps(2);
    assert!(lit(&h), "the level reached 0 dB with scene.live");
}

#[test]
fn a_clip_painted_asks_once_for_its_notes_by_its_key() {
    let (mut h, calls, patches) = window_and_patches(|_| {});
    let mut patch = arrange_scene();
    for node in &mut patch.set {
        if let paw_scene::Kind::Role { role, props } = &mut node.kind
            && role == "clip"
        {
            props["content"] = json!("stamp:1");
        }
    }
    patches.borrow_mut().push(serde_json::to_value(patch).unwrap());
    h.run_steps(4);
    let asked = |calls: &Calls| calls.borrow().iter().filter(|(m, p)| m == "eval" && p[0] == "return paw.frontend.preview(...)").count();
    assert_eq!(asked(&calls), 1, "fetched once, by its key");
    h.run_steps(4);
    assert_eq!(asked(&calls), 1, "and kept");
}

#[test]
fn a_drag_of_a_clip_and_the_wheel_go_back_in_units_with_fractions() {
    let (mut h, calls, _) = arrange_window();
    let cell = h.state().scenes.cell.unwrap();
    let clip = h.get_by_label("verse").rect();
    let from = clip.left_center() + vec2(3.0 * cell.0, 0.0);
    drag(&mut h, from, from + vec2(2.5 * cell.0, cell.1));
    let inputs: Vec<Value> = calls.borrow().iter().filter(|(m, p)| m == "scene.input" && p[0] == "1").map(|(_, p)| p[1].clone()).collect();
    let down = inputs.iter().find(|e| e["kind"] == "down").expect("the press passed on");
    assert!((num(&down["x"]) - 37.5).abs() < 0.05, "on the clip, in units: {down}");
    let last = inputs.iter().rev().find(|e| e["kind"] == "move").expect("the drag passed on");
    assert!((num(&last["x"]) - 40.0).abs() < 0.05 && (num(&last["y"]) - num(&down["y"]) - 1.0).abs() < 0.05, "two cells and a half on, a row down: {last}");
    assert!(inputs.iter().any(|e| e["kind"] == "up"));
    calls.borrow_mut().clear();
    right_click(&mut h, from);
    assert!(calls.borrow().iter().any(|(m, p)| m == "scene.input" && p[1]["kind"] == "down" && p[1]["button"] == "right"), "a right click, for the kernel's menu");
    calls.borrow_mut().clear();
    h.hover_at(from);
    h.event(Event::MouseWheel { unit: egui::MouseWheelUnit::Line, delta: vec2(0.0, -1.0), modifiers: Modifiers::CTRL, phase: egui::TouchPhase::Move, source: egui::MouseWheelSource::Wheel });
    h.run_steps(2);
    assert!(calls.borrow().iter().any(|(m, p)| m == "scene.input" && p[1]["kind"] == "wheel" && p[1]["ctrl"] == true), "Ctrl and the wheel to the kernel, which zooms");
}

// ---------------------------------------------------------- the piano roll

/// The piano roll as the kernel sends it to a window that paints notes
/// (paw/views/pianoroll.lua): its grid a plane of beats along, four units a
/// beat, and pitches up from 64 on its first row; a note in it between
/// cells, with its hit region; a button of its row of tools.
fn roll_scene() -> paw_scene::Patch {
    use paw_scene::{Axis, Kind, Node, Plane};
    let mut scene = paw_scene::Scene::new([80.0, 20.0]);
    (scene.fg, scene.bg) = ("#c9ced8".into(), "#101216".into());
    let plane = Plane { x: Axis { domain: "beat".into(), from: 0.0, per: 4.0 }, y: Axis { domain: "pitch".into(), from: 65.0, per: -1.0 } };
    let mut grid = Node::new("roll", Kind::Plane(plane), [5.0, 3.0, 60.0, 10.0]);
    grid.hit = Some(json!({ "kind": "grid" }));
    scene.push(None, grid);
    let props = json!({ "label": "C4", "color": "#5fb56a", "velocity": 100 });
    let mut note = Node::new("roll/note:2:1", Kind::Role { role: "note".into(), props }, [1.5, 60.0, 0.5, 1.0]);
    note.hit = Some(json!({ "kind": "note", "clip": 2, "place": 1 }));
    scene.push(Some("roll"), note);
    let props = json!({ "text": " quantize ", "label": "quantize" });
    let mut tool = Node::new("button@1,1", Kind::Role { role: "button".into(), props }, [1.0, 1.0, 10.0, 1.0]);
    tool.hit = Some(json!({ "kind": "tool", "name": "quantize" }));
    scene.push(None, tool);
    let mut patch = paw_scene::Scene::diff(&paw_scene::Scene::default(), &scene, "2");
    patch.full = true;
    patch
}

/// The piano roll's pane, drawn from its scene, and the patches it is sent.
fn roll_window() -> (Harness<'static, View>, Calls, Patches) {
    let (mut h, calls, patches) = window_and_patches(|_| {});
    patches.borrow_mut().push(serde_json::to_value(roll_scene()).unwrap());
    h.run_steps(2);
    calls.borrow_mut().clear();
    (h, calls, patches)
}

#[test]
fn the_piano_roll_is_the_kernels_scene_its_notes_painted_between_cells() {
    let (h, _, _) = roll_window();
    let watch = h.state().scenes.cell.unwrap();
    // Where the kernel's plane puts it: beat 1.5 is six units into the
    // plane (5 in), pitch 60 its fifth row (3 down); half a beat is two units.
    let origin = pos2(6.0, AREA_TOP + 500.0 + 24.0 - watch.1);
    let note = h.get_by_label("C4").rect();
    assert!((note.left() - (origin.x + 11.0 * watch.0)).abs() < 0.5, "{note:?}");
    assert!((note.top() - (origin.y + 7.0 * watch.1)).abs() < 0.5 && (note.width() - 2.0 * watch.0).abs() < 0.5, "{note:?}");
    assert!(h.query_by_label("quantize").is_some(), "the row of tools, as buttons");
}

#[test]
fn a_drag_of_a_note_and_a_click_on_a_tool_go_back_in_units_with_fractions() {
    let (mut h, calls, _) = roll_window();
    let cell = h.state().scenes.cell.unwrap();
    let note = h.get_by_label("C4").rect();
    drag(&mut h, note.left_center() + vec2(2.0, 0.0), note.left_center() + vec2(2.0 + 1.5 * cell.0, -cell.1));
    let inputs: Vec<Value> = calls.borrow().iter().filter(|(m, p)| m == "scene.input" && p[0] == "2").map(|(_, p)| p[1].clone()).collect();
    let down = inputs.iter().find(|e| e["kind"] == "down").expect("the press passed on");
    let x = 11.0 + 2.0 / cell.0 as f64;
    assert!((num(&down["x"]) - x).abs() < 0.05 && (num(&down["y"]) - 7.5).abs() < 0.05, "on the note, in units: {down}");
    let last = inputs.iter().rev().find(|e| e["kind"] == "move").expect("the drag passed on");
    assert!((num(&last["x"]) - (x + 1.5)).abs() < 0.05 && (num(&last["y"]) - 6.5).abs() < 0.05, "a cell and a half on, a row up: {last}");
    assert!(inputs.iter().any(|e| e["kind"] == "up"));
    calls.borrow_mut().clear();
    let tool = h.get_by_label("quantize").rect().center();
    click(&mut h, tool);
    assert!(calls.borrow().iter().any(|(m, p)| m == "scene.input" && p[1]["kind"] == "down"), "the tool's press to the kernel, whose gesture it is");
}

#[test]
fn a_menu_the_kernel_opens_is_shown_by_the_window_and_chosen_or_let_go() {
    let (mut h, calls) = window_with(|s| s["modal"]["menu"] = json!(1));
    let menu = h.state().menu.as_ref().expect("the kernel's menu shown");
    assert!(matches!(&menu.source, crate::menu::Source::Kernel { kind, .. } if kind == "shown"));
    let first = menu.at + vec2(40.0, 4.0 + 12.0);
    click(&mut h, first);
    let choose = act(&calls, "menu_choose");
    assert_eq!((choose[0].clone(), choose[2].clone()), (json!("shown"), json!([1])), "its first entry, done by the kernel");
    let (mut h, calls) = window_with(|s| s["modal"]["menu"] = json!(1));
    h.event(Event::Key { key: egui::Key::Escape, physical_key: None, pressed: true, repeat: false, modifiers: Modifiers::NONE });
    h.run_steps(2);
    assert!(h.state().menu.is_none() && acted(&calls, "menu_dismiss").is_some(), "Esc lets go of it, in the kernel too");
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
    let (mut h, calls) = window();
    h.event(Event::Key { key: egui::Key::Plus, physical_key: None, pressed: true, repeat: false, modifiers: Modifiers::CTRL });
    h.run_steps(2);
    assert!(sent(&calls, "zoom by=1.4142"), "the focused view's zoom, in the kernel");
    h.event(Event::Key { key: egui::Key::Num0, physical_key: None, pressed: true, repeat: false, modifiers: Modifiers::CTRL });
    h.run_steps(2);
    assert!(sent(&calls, "zoom fit"));
    h.event(Event::Key { key: egui::Key::ArrowDown, physical_key: None, pressed: true, repeat: false, modifiers: Modifiers::CTRL });
    h.run_steps(2);
    assert!(sent(&calls, "paw.opt.track_height"), "taller tracks");
    assert!(!calls.borrow().iter().any(|(m, _)| m == "keys"), "none of them a key of the kernel's mappings");
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
    let at = h.get_by_label("Automation").rect().center();
    click(&mut h, at);
    assert!(sent(&calls, "lane.rows"), "Automation shows the selected track's lanes as rows");
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

// ------------------------------------------------------------------ the mixer

/// A window with the piano roll's pane given to the mixer, which the kernel
/// draws, and the patches it is sent.
fn mixer_window() -> (Harness<'static, View>, Calls, Patches) {
    window_and_patches(|s| {
        s["modal"]["panes"]["panes"][1]["view"] = json!("mixer");
        s["modal"]["panes"]["panes"][1]["kind"] = json!("cells");
    })
}

/// A strip of the mixer as the kernel sends it to a window that paints the
/// widget roles (paw/views/mixer.lua): the roles without their cells, a
/// fader with its hit region, a meter bound to its track's, a switch.
fn strip_scene() -> paw_scene::Patch {
    use paw_scene::{Kind, Node};
    let mut scene = paw_scene::Scene::new([40.0, 14.0]);
    (scene.fg, scene.bg) = ("#c9ced8".into(), "#101216".into());
    let role = |key: &str, role: &str, rect, props: Value| Node::new(key, Kind::Role { role: role.into(), props }, rect);
    scene.push(None, role("chip@4,1", "chip", [4.0, 1.0, 9.0, 1.0], json!({ "text": "B", "color": "#e0a050", "label": "strip of B" })));
    let mut hit = Node::new("g@4,3", Kind::Group, [4.0, 3.0, 9.0, 8.0]);
    hit.hit = Some(json!({ "kind": "fader", "track": 3 }));
    scene.push(None, hit);
    let mut meter = role("meter@5,3", "meter", [5.0, 3.0, 2.0, 8.0], json!({ "hold": 0 }));
    meter.bind = Some("meter:3".into());
    scene.push(None, meter);
    scene.push(None, role("fader@8,3", "fader", [8.0, 3.0, 3.0, 8.0], json!({ "at": 0.5, "zero": 0.8, "label": "fader of B" })));
    let mut mute = role("switch@5,12", "switch", [5.0, 12.0, 1.0, 1.0], json!({ "letter": "M", "on": true, "tone": "mute", "label": "mute of B" }));
    mute.hit = Some(json!({ "kind": "flag", "track": 3, "flag": "mute" }));
    scene.push(None, mute);
    let mut patch = paw_scene::Scene::diff(&paw_scene::Scene::default(), &scene, "2");
    patch.full = true;
    patch
}

#[test]
fn the_mixer_is_painted_from_its_scene_with_widgets_and_its_meters_move_with_the_live_values() {
    let (mut h, calls, patches) = mixer_window();
    let watch = calls.borrow().iter().find(|(m, _)| m == "scene.watch").map(|(_, p)| p[0].clone()).expect("scenes watched");
    assert!(watch["live"] == true && watch["roles"].as_array().is_some_and(|r| r.contains(&json!("fader"))), "{watch}");
    patches.borrow_mut().push(serde_json::to_value(strip_scene()).unwrap());
    h.run_steps(2);
    // Where the kernel laid each out: the pane's picture starts 6 in and a
    // row over the title's foot (500 down the main area).
    let cell = h.state().scenes.cell.unwrap();
    let origin = pos2(6.0, AREA_TOP + 500.0 + 24.0 - cell.1);
    let fader = h.get_by_label("fader of B").rect();
    assert!((fader.left() - (origin.x + 8.0 * cell.0)).abs() < 0.5 && (fader.height() - 8.0 * cell.1).abs() < 0.5, "{fader:?}");
    assert!(h.query_by_label("mute of B").is_some() && h.query_by_label("strip of B").is_some());
    // A meter that reached full scale lights its clip light, from the live
    // values alone.
    let clip = crate::theme::th().meter_clip;
    let lit = |h: &Harness<View>| h.output().shapes.iter().any(|c| matches!(&c.shape, egui::Shape::Rect(r) if r.fill == clip));
    assert!(!lit(&h), "nothing before the live values");
    patches.borrow_mut().push(json!({ "scene.live": { "meters": { "3": [1.0, 0.2] }, "peaks": { "3": 1.0 }, "clips": { "3": true } } }));
    h.run_steps(2);
    assert!(lit(&h), "the meter moved with scene.live");
    patches.borrow_mut().push(json!({ "scene.live": { "meters": { "3": [0.1, 0.1] }, "peaks": { "3": 0.1 }, "clips": [] } }));
    h.run_steps(2);
    assert!(!lit(&h), "and its light went out with them");
}

#[test]
fn a_drag_on_the_mixers_fader_goes_back_in_cells_with_fractions() {
    let (mut h, calls, patches) = mixer_window();
    patches.borrow_mut().push(serde_json::to_value(strip_scene()).unwrap());
    h.run_steps(2);
    calls.borrow_mut().clear();
    let fader = h.get_by_label("fader of B").rect();
    let cell = h.state().scenes.cell.unwrap();
    drag(&mut h, fader.center(), fader.center() - vec2(0.0, 1.5 * cell.1));
    let inputs: Vec<Value> = calls.borrow().iter().filter(|(m, _)| m == "scene.input").map(|(_, p)| p[1].clone()).collect();
    let down = inputs.iter().find(|e| e["kind"] == "down").expect("the press passed on");
    assert!((num(&down["x"]) - 9.5).abs() < 0.05 && (num(&down["y"]) - 7.0).abs() < 0.05, "the fader's middle in units: {down}");
    let last = inputs.iter().rev().find(|e| e["kind"] == "move").expect("the drag passed on");
    assert!((num(&last["y"]) - 5.5).abs() < 0.05, "a row and a half up, in fractions of a row: {last}");
    assert!(inputs.iter().any(|e| e["kind"] == "up"));
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
        s["modal"]["panes"]["panes"][1]["kind"] = json!("native");
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
        include_str!("canvas.rs"),
        include_str!("chrome.rs"),
        include_str!("devices.rs"),
        include_str!("dialogs.rs"),
        include_str!("menu.rs"),
        include_str!("roles.rs"),
        include_str!("model.rs"),
        include_str!("panes.rs"),
        include_str!("session.rs"),
        include_str!("timeline.rs"),
        include_str!("widgets.rs"),
        include_str!("../../../runtime/lua/paw/window_menus.lua"),
        include_str!("../../../runtime/lua/paw/mouse_menus.lua"),
        include_str!("../../../runtime/lua/paw/views/arrange_mouse.lua"),
        include_str!("../../../runtime/lua/paw/roles/arrange.lua"),
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
    // The arrange view's pane is one the kernel draws too: the help's is the second.
    let area = calls.borrow().iter().find(|(m, p)| m == "scene.area" && p[0] == "2").map(|(_, p)| p.clone()).expect("the pane's size said");
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
