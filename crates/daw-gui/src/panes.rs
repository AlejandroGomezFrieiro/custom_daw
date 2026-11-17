//! The main area as the kernel's tabs and windows lay it out
//! (`runtime/lua/daw/panes.lua`, `ui/panes.slint`): where each view the
//! window draws itself goes, the pictures of the views the kernel paints,
//! the borders, the tabs and the pane with the keyboard. Gestures go back
//! to `daw.panes`.

use std::collections::HashMap;
use std::rc::Rc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use slint::{ComponentHandle, Image, Model, ModelRc, VecModel};

use crate::{App, BorderData, Client, PaneData, PaneRect, PaneSizes, TabData, number, raster, rows, sync, text};

/// The size of the monospace font a view drawn in cells is painted in.
const MONO_SIZE: f32 = 13.0;

/// What a painted pane shows, and when and at what size it was painted.
struct Drawn {
    painted: Instant,
    size: (f32, f32),
    ops: Value,
    image: Image,
}

pub struct Panes {
    model: Rc<VecModel<PaneData>>,
    borders: Rc<VecModel<BorderData>>,
    tabs: Rc<VecModel<TabData>>,
    /// The size of the main area the kernel was last told.
    area: (f32, f32),
    drawn: HashMap<i32, Drawn>,
    /// Each pane's window and where it is in the main area, with whether it
    /// has the keyboard: a press there gives it the keyboard.
    rects: Vec<(i32, [f32; 4], bool)>,
}

/// A cell of the monospace font as the rasterizer draws it: `daw.canvas`
/// lays a view drawn in cells out on it.
fn cell() -> (f32, f32) {
    // A run is drawn at the size that fills the cell's height: the width
    // is a character's at that size, so that a run fills its cells exactly.
    let font = daw_raster::Font::Mono;
    let height = (font.line_height() * MONO_SIZE).ceil();
    (daw_raster::measure(font, "M", height / font.line_height()), height)
}

fn rect(value: &Value) -> PaneRect {
    PaneRect {
        x: number(&value["x"]),
        y: number(&value["y"]),
        w: number(&value["w"]),
        h: number(&value["h"]),
        shown: value.is_object(),
    }
}

impl Panes {
    pub fn new(ui: &App) -> Self {
        let panes = Self {
            model: Rc::new(VecModel::default()),
            borders: Rc::new(VecModel::default()),
            tabs: Rc::new(VecModel::default()),
            area: (0.0, 0.0),
            drawn: HashMap::new(),
            rects: Vec::new(),
        };
        ui.set_panes(ModelRc::from(panes.model.clone()));
        ui.set_pane_borders(ModelRc::from(panes.borders.clone()));
        ui.set_tabs(ModelRc::from(panes.tabs.clone()));
        panes
    }

    /// Pass the panes' gestures on to the kernel.
    pub fn install(&self, ui: &App, eval: impl Fn(&str, Value) + Clone + 'static) {
        ui.on_pane_pointer({
            let eval = eval.clone();
            move |win, kind, x, y, button, ctrl, shift, alt| {
                let kind = ["down", "up", "move", "double", "hover"][kind.clamp(0, 4) as usize];
                let button = ["left", "right", "middle"][button.clamp(0, 2) as usize];
                let event = json!({
                    "kind": kind, "x": x, "y": y, "button": button, "ctrl": ctrl, "shift": shift, "alt": alt,
                });
                eval("daw.panes.pointer(...)", json!([win, event]));
            }
        });
        ui.on_pane_wheel({
            let eval = eval.clone();
            move |win, x, y, dx, dy, ctrl, shift| {
                let event = json!({ "kind": "wheel", "x": x, "y": y, "dx": dx, "dy": dy, "ctrl": ctrl, "shift": shift });
                eval("daw.panes.pointer(...)", json!([win, event]));
            }
        });
        ui.on_pane_border({
            let eval = eval.clone();
            // The kernel counts from 1.
            move |index, x, y| eval("daw.panes.border(...)", json!([index + 1, x, y]))
        });
        ui.on_pane_tab({
            let eval = eval.clone();
            move |index| eval("daw.panes.tab(...)", json!([index + 1]))
        });
        ui.on_pane_close(move |win| eval("daw.panes.close(...)", json!([win])));
    }

    /// Where everything goes, from the kernel's state (`daw.panes.state`).
    pub fn modal(&mut self, ui: &App, state: &Value) {
        let mut natives: HashMap<&str, &Value> = HashMap::new();
        let mut panes = Vec::new();
        self.rects.clear();
        let mut focused = PaneRect { x: 0.0, y: 0.0, w: 0.0, h: 0.0, shown: false };
        let all = rows(&state["panes"]);
        for pane in all {
            let win = pane["win"].as_i64().unwrap_or(0) as i32;
            let at = [number(&pane["x"]), number(&pane["y"]), number(&pane["w"]), number(&pane["h"])];
            let is_focused = pane["focused"] == true;
            self.rects.push((win, at, is_focused));
            // The ring shows which of several has the keyboard.
            if is_focused && all.len() > 1 {
                focused = rect(pane);
            }
            let kind = match pane["kind"].as_str() {
                Some("native") => {
                    natives.insert(pane["view"].as_str().unwrap_or(""), pane);
                    continue;
                }
                Some("paint") => 1,
                _ => 2,
            };
            panes.push(PaneData {
                win,
                view: text(&pane["view"]),
                kind,
                title: text(&pane["title"]),
                x: at[0],
                y: at[1],
                w: at[2],
                h: at[3],
                focused: is_focused,
                image: self.drawn.get(&win).map(|d| d.image.clone()).unwrap_or_default(),
                // A view in cells draws a title row of its own, which the
                // pane's title covers.
                under: if kind == 2 { cell().1 } else { 0.0 },
            });
        }
        // A view the window draws itself keeps where it was while it is not
        // shown, only hidden: its parts keep their sizes.
        let place = |name: &str, old: PaneRect| match natives.get(name) {
            Some(pane) => rect(pane),
            None => PaneRect { shown: false, ..old },
        };
        ui.set_arrange_pane(place("arrange", ui.get_arrange_pane()));
        ui.set_devices_pane(place("devices", ui.get_devices_pane()));
        ui.set_roll_pane(place("pianoroll", ui.get_roll_pane()));
        ui.set_mixer_pane(place("mixer", ui.get_mixer_pane()));
        ui.set_session_pane(place("session", ui.get_session_pane()));
        ui.set_focus_pane(focused);
        let shown: Vec<i32> = panes.iter().map(|p| p.win).collect();
        self.drawn.retain(|win, _| shown.contains(win));
        // The pictures are put in as they are painted; the rest only when
        // something else changed.
        let same = self.model.row_count() == panes.len()
            && panes.iter().enumerate().all(|(i, p)| {
                self.model.row_data(i).is_some_and(|old| PaneData { image: old.image.clone(), ..p.clone() } == old)
            });
        if !same {
            sync(&self.model, panes);
        }
        let borders: Vec<BorderData> = rows(&state["borders"])
            .iter()
            .map(|b| BorderData {
                across: b["dir"] == "h",
                x: number(&b["x"]),
                y: number(&b["y"]),
                length: number(&b["length"]),
            })
            .collect();
        sync(&self.borders, borders);
        let current = state["tab"].as_i64().unwrap_or(1) as usize;
        let tabs: Vec<TabData> = rows(&state["tabs"])
            .iter()
            .enumerate()
            .map(|(i, t)| TabData { title: text(&t["title"]), current: i + 1 == current })
            .collect();
        sync(&self.tabs, tabs);
    }

    /// Tell the kernel the main area's size when it has changed, and paint
    /// the panes that may show something new: when something happened
    /// (`repaint`), at another size, now and then regardless, and a pane in
    /// cells every time (the kernel answers `same` when nothing changed).
    pub fn paint(&mut self, ui: &App, client: &mut Client, repaint: bool) {
        let area = (ui.get_area_width(), ui.get_area_height());
        if area != self.area && area.0 > 0.0 && area.1 > 0.0 {
            self.area = area;
            let _ = client.eval("daw.panes.area(...)", json!([area.0, area.1]));
        }
        let (cell_w, cell_h) = cell();
        let scale = ui.window().scale_factor();
        for index in 0..self.model.row_count() {
            let Some(mut pane) = self.model.row_data(index) else { continue };
            let sizes = ui.global::<PaneSizes>();
            let (heading, pad) = (sizes.get_heading(), sizes.get_pad());
            let size = ((pane.w - 2.0 * pad).max(1.0), (pane.h - heading + pane.under - pad).max(1.0));
            let cells = pane.kind == 2;
            let fresh = !self.drawn.contains_key(&pane.win);
            let stale = self
                .drawn
                .get(&pane.win)
                .is_none_or(|d| d.painted.elapsed() > Duration::from_millis(250) || d.size != size);
            if !(repaint || stale || cells) {
                continue;
            }
            let opts = json!({ "cell": { "w": cell_w, "h": cell_h }, "fresh": fresh, "glyphs": true });
            let Ok(drawing) = client.eval("return daw.panes.paint(...)", json!([pane.win, size.0, size.1, opts])) else {
                continue;
            };
            if drawing["same"] == true {
                if let Some(d) = self.drawn.get_mut(&pane.win) {
                    d.painted = Instant::now();
                }
                continue;
            }
            let unchanged = self.drawn.get(&pane.win).is_some_and(|d| d.ops == drawing["ops"] && d.size == size);
            if drawing["ops"].is_null() || unchanged {
                continue;
            }
            let image = raster(&drawing["ops"], size, scale);
            pane.image = image.clone();
            self.model.set_row_data(index, pane.clone());
            self.drawn.insert(pane.win, Drawn { painted: Instant::now(), size, ops: drawing["ops"].clone(), image });
        }
    }

    /// The window of the pane at a point of the window, if it does not
    /// have the keyboard already. None while a menu is open over the panes,
    /// or a text box has the keyboard: the press is theirs.
    pub fn pressed(&self, ui: &App, x: f32, y: f32) -> Option<i32> {
        if !ui.get_keys_focused() {
            return None;
        }
        let (x, y) = (x - ui.get_area_x(), y - ui.get_area_y());
        self.rects
            .iter()
            .find(|(_, r, _)| x >= r[0] && x < r[0] + r[2] && y >= r[1] && y < r[1] + r[3])
            .filter(|(_, _, focused)| !focused)
            .map(|(win, _, _)| *win)
    }
}
