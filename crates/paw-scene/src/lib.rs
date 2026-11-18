//! The scene: what one window of a view shows, for every frontend.
//!
//! A scene is a tree of nodes, each with a rectangle in **cell units** (a
//! terminal's cells; a window's cell of its monospace font) relative to its
//! parent, in drawing order. The kernel builds it as a view draws
//! (`paw-core`'s `scene` module), keeps it, and sends a frontend what changed
//! since it last did as a [`Patch`]; the frontend applies the patch to its
//! copy and draws that. Both sides find what is under the pointer with
//! [`Scene::hit`], and [`Scene::to_cells`] lowers a scene to the cells a
//! terminal shows. See docs/protocol.md, "Scenes".
//!
//! Nodes:
//!
//! - `run`: text in one style along a row (what `buf:text` writes);
//! - `fill`: a rectangle restyled, and its characters overwritten when it
//!   has one (`buf:fill`);
//! - `picture`: a drawing (`paw.canvas` operations) over its rectangle, in
//!   pixels of a size it says, under the cells or over them;
//! - `group`: its kids, placed from its corner and cut to it;
//! - `plane`: its kids, placed in a domain of its own (beats along x and
//!   pitch along y, say), mapped to units by an [`Axis`] each way;
//! - a role (`clip`, `fader`...): a named element over its rectangle,
//!   with its look's data in `props`; a frontend that does not know the
//!   role draws its kids, the role's cells.
//!
//! Any node may be a hit region (`hit`) and be bound to a live value
//! (`bind`) a frontend moves without a new scene.

pub mod cells;

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize, Serializer};
use serde_json::Value;

use cells::{Cells, Color, Rect, Style};

/// A rectangle in units: x, y, width, height.
pub type Units = [f32; 4];

/// Whole numbers go on the wire without a decimal point.
fn short<S: Serializer>(rect: &Units, s: S) -> Result<S::Ok, S::Error> {
    let numbers: Vec<Value> = rect.iter().map(|v| number(*v as f64)).collect();
    numbers.serialize(s)
}

fn short_opt<S: Serializer>(rect: &Option<Units>, s: S) -> Result<S::Ok, S::Error> {
    match rect {
        Some(rect) => short(rect, s),
        None => s.serialize_none(),
    }
}

fn number(v: f64) -> Value {
    if v.fract() == 0.0 && v.abs() < 1e15 { Value::from(v as i64) } else { Value::from(v) }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Node {
    /// Its name, unique in the scene: what it is kept and diffed by.
    #[serde(rename = "k")]
    pub key: String,
    #[serde(flatten)]
    pub kind: Kind,
    /// Where it is, in units of its parent's space.
    #[serde(rename = "r", serialize_with = "short")]
    pub rect: Units,
    /// What it is cut to, in its parent's space; its parent's cut without.
    #[serde(default, skip_serializing_if = "Option::is_none", serialize_with = "short_opt")]
    pub clip: Option<Units>,
    #[serde(rename = "s", default, skip_serializing_if = "Style::is_plain")]
    pub style: Style,
    /// Makes its rectangle a hit region: what a press there is on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hit: Option<Value>,
    /// A live value the frontend moves it by (`position`, `meter:12`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bind: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub kids: Vec<String>,
}

impl Node {
    pub fn new(key: impl Into<String>, kind: Kind, rect: Units) -> Node {
        Node { key: key.into(), kind, rect, clip: None, style: Style::default(), hit: None, bind: None, kids: Vec::new() }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "lowercase")]
pub enum Kind {
    Group,
    Run {
        text: String,
    },
    Fill {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ch: Option<char>,
    },
    Picture(Picture),
    Plane(Plane),
    Role {
        role: String,
        #[serde(default)]
        props: Value,
    },
}

/// A drawing over a node's rectangle.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Picture {
    /// The drawing (see `paw.canvas.paint`), in pixels of a rectangle `px`
    /// big, which a frontend scales to the node's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ops: Option<Value>,
    /// Or the content key of a drawing too big to send each time, which a
    /// frontend asks for once (`scene.blob`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blob: Option<String>,
    pub px: [f32; 2],
    /// Under the cells drawn in its rectangle (their backgrounds under it,
    /// their text over it), as `buf:strip` with `under` keeps it; else over.
    #[serde(default)]
    pub under: bool,
}

/// How a plane's domain maps to units along one way: `per` units for each
/// unit of the domain (negative to run up or left), `from` at its edge.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Axis {
    pub domain: String,
    pub from: f64,
    pub per: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Plane {
    pub x: Axis,
    pub y: Axis,
}

/// What a press landed on: the node's key and hit, and where, in the
/// domain of the innermost plane it is in (in units of the scene else).
#[derive(Clone, Debug, PartialEq)]
pub struct Hit {
    pub key: String,
    pub hit: Value,
    pub at: [f64; 2],
}

/// A scene: the nodes of one window by key, in order from the root.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Scene {
    /// Its size in units.
    pub size: [f32; 2],
    pub root: Vec<String>,
    pub nodes: HashMap<String, Node>,
    /// The colours `default` stands for: the theme's text and background.
    pub fg: String,
    pub bg: String,
    /// Where the text cursor is, when the view shows one, in units.
    pub cursor: Option<[f32; 2]>,
    /// How many patches made it.
    pub rev: u64,
}

/// What changed of a window's scene: everything but `win` and `rev` is left
/// out when it did not.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Patch {
    pub win: String,
    pub rev: u64,
    /// The whole scene: what the frontend had of the window goes first.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub full: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<[f32; 2]>,
    /// The keys of the root's kids, in order.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root: Option<Vec<String>>,
    /// Nodes new or changed (a node whose kids changed among them).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub set: Vec<Node>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub drop: Vec<String>,
    /// `[fg, bg]`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub colors: Option<[String; 2]>,
    /// `[x, y]`, or `[]` for none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<Vec<f32>>,
}

impl Patch {
    /// Whether it changes nothing.
    pub fn is_empty(&self) -> bool {
        !self.full
            && self.size.is_none()
            && self.root.is_none()
            && self.set.is_empty()
            && self.drop.is_empty()
            && self.colors.is_none()
            && self.cursor.is_none()
    }
}

/// How a space maps to the scene's units, along x and along y:
/// `unit = a + b * value`.
#[derive(Clone, Copy, Debug)]
struct Map {
    x: (f64, f64),
    y: (f64, f64),
}

impl Map {
    const UNITS: Map = Map { x: (0.0, 1.0), y: (0.0, 1.0) };

    /// A rectangle of this space in units, edges in order.
    fn rect(&self, r: &Units) -> [f64; 4] {
        let along = |(a, b): (f64, f64), at: f32, len: f32| {
            let (p, q) = (a + b * at as f64, a + b * (at + len) as f64);
            (p.min(q), p.max(q))
        };
        let (x0, x1) = along(self.x, r[0], r[2]);
        let (y0, y1) = along(self.y, r[1], r[3]);
        [x0, y0, x1, y1]
    }

    /// The space of a node's kids.
    fn inside(&self, node: &Node) -> Map {
        let (r, (ax, bx), (ay, by)) = (&node.rect, self.x, self.y);
        match &node.kind {
            Kind::Plane(plane) => Map {
                x: (ax + bx * (r[0] as f64 - plane.x.per * plane.x.from), bx * plane.x.per),
                y: (ay + by * (r[1] as f64 - plane.y.per * plane.y.from), by * plane.y.per),
            },
            _ => Map { x: (ax + bx * r[0] as f64, bx), y: (ay + by * r[1] as f64, by) },
        }
    }

    /// A point in units, in this space.
    fn back(&self, at: [f64; 2]) -> [f64; 2] {
        [(at[0] - self.x.0) / self.x.1, (at[1] - self.y.0) / self.y.1]
    }
}

fn overlap(a: [f64; 4], b: [f64; 4]) -> [f64; 4] {
    [a[0].max(b[0]), a[1].max(b[1]), a[2].min(b[2]), a[3].min(b[3])]
}

/// A rectangle in units as the whole cells it covers.
fn whole(r: [f64; 4]) -> Rect {
    let (x, y) = (r[0].floor() as i32, r[1].floor() as i32);
    Rect { x, y, w: (r[2].floor() as i32 - x).max(0), h: (r[3].floor() as i32 - y).max(0) }
}

impl Scene {
    pub fn new(size: [f32; 2]) -> Scene {
        Scene { size, ..Scene::default() }
    }

    /// Add a node as the last kid of `parent` (of the root without).
    pub fn push(&mut self, parent: Option<&str>, node: Node) {
        let key = node.key.clone();
        match parent.and_then(|p| self.nodes.get_mut(p)) {
            Some(parent) => parent.kids.push(key.clone()),
            None => self.root.push(key.clone()),
        }
        self.nodes.insert(key, node);
    }

    /// What changed from `old` to `new`, for the window `win`.
    pub fn diff(old: &Scene, new: &Scene, win: &str) -> Patch {
        let mut patch = Patch { win: win.to_string(), rev: old.rev + 1, ..Patch::default() };
        if old.size != new.size {
            patch.size = Some(new.size);
        }
        if old.root != new.root {
            patch.root = Some(new.root.clone());
        }
        // In drawing order, so that a patch reads as the scene does.
        new.walk(&mut |node| {
            if old.nodes.get(&node.key) != Some(node) {
                patch.set.push(node.clone());
            }
        });
        let mut gone: Vec<String> = old.nodes.keys().filter(|k| !new.nodes.contains_key(*k)).cloned().collect();
        gone.sort();
        patch.drop = gone;
        if (&old.fg, &old.bg) != (&new.fg, &new.bg) {
            patch.colors = Some([new.fg.clone(), new.bg.clone()]);
        }
        if old.cursor != new.cursor {
            patch.cursor = Some(new.cursor.map_or_else(Vec::new, |c| c.to_vec()));
        }
        patch
    }

    /// Take in a patch made by [`Scene::diff`] against this scene (or
    /// against none, for a full one).
    pub fn apply(&mut self, patch: &Patch) {
        if patch.full {
            *self = Scene::default();
        }
        self.rev = patch.rev;
        if let Some(size) = patch.size {
            self.size = size;
        }
        if let Some(root) = &patch.root {
            self.root = root.clone();
        }
        for key in &patch.drop {
            self.nodes.remove(key);
        }
        for node in &patch.set {
            self.nodes.insert(node.key.clone(), node.clone());
        }
        if let Some([fg, bg]) = &patch.colors {
            (self.fg, self.bg) = (fg.clone(), bg.clone());
        }
        if let Some(cursor) = &patch.cursor {
            self.cursor = (cursor.len() == 2).then(|| [cursor[0], cursor[1]]);
        }
    }

    /// Every node reachable from the root, in drawing order.
    pub fn walk<'a>(&'a self, f: &mut dyn FnMut(&'a Node)) {
        let mut seen = HashSet::new();
        self.walk_from(&self.root, &mut seen, f);
    }

    fn walk_from<'a>(&'a self, keys: &'a [String], seen: &mut HashSet<&'a str>, f: &mut dyn FnMut(&'a Node)) {
        for key in keys {
            // A key named twice, or a node its own kid, is drawn once.
            if let Some(node) = self.nodes.get(key)
                && seen.insert(key.as_str())
            {
                f(node);
                self.walk_from(&node.kids, seen, f);
            }
        }
    }

    /// What is under a point in units: the last node drawn there that is a
    /// hit region, inside every group and plane it is in.
    pub fn hit(&self, at: [f32; 2]) -> Option<Hit> {
        let at = [at[0] as f64, at[1] as f64];
        let all = [0.0, 0.0, self.size[0] as f64, self.size[1] as f64];
        self.hit_in(&self.root, Map::UNITS, all, at, 0)
    }

    fn hit_in(&self, keys: &[String], map: Map, cut: [f64; 4], at: [f64; 2], depth: usize) -> Option<Hit> {
        if depth > 64 {
            return None;
        }
        let inside = |r: [f64; 4]| at[0] >= r[0] && at[0] < r[2] && at[1] >= r[1] && at[1] < r[3];
        for key in keys.iter().rev() {
            let Some(node) = self.nodes.get(key) else { continue };
            let mut cut = cut;
            if let Some(clip) = &node.clip {
                cut = overlap(cut, map.rect(clip));
            }
            let rect = overlap(map.rect(&node.rect), cut);
            if !inside(rect) {
                continue;
            }
            if !node.kids.is_empty()
                && let Some(found) = self.hit_in(&node.kids, map.inside(node), rect, at, depth + 1)
            {
                return Some(found);
            }
            if let Some(hit) = &node.hit {
                let space = if matches!(node.kind, Kind::Plane(_)) { map.inside(node) } else { map };
                return Some(Hit { key: node.key.clone(), hit: hit.clone(), at: space.back(at) });
            }
        }
        None
    }

    /// The scene as a terminal shows it: its runs and fills written in
    /// order, groups and planes placing and cutting their kids, a role it
    /// draws as its kids. Pictures have no cells.
    pub fn to_cells(&self) -> Cells {
        let (w, h) = (self.size[0].max(0.0) as u16, self.size[1].max(0.0) as u16);
        let mut cells = Cells::new(w, h);
        let all = [0.0, 0.0, w as f64, h as f64];
        self.cells_in(&self.root, Map::UNITS, all, &mut cells, 0);
        cells
    }

    fn cells_in(&self, keys: &[String], map: Map, cut: [f64; 4], cells: &mut Cells, depth: usize) {
        if depth > 64 {
            return;
        }
        for key in keys {
            let Some(node) = self.nodes.get(key) else { continue };
            let mut cut = cut;
            if let Some(clip) = &node.clip {
                cut = overlap(cut, map.rect(clip));
            }
            let rect = map.rect(&node.rect);
            match &node.kind {
                Kind::Run { text } => {
                    let at = whole(rect);
                    cells.text(whole(cut), at.x, at.y, text, node.style);
                }
                Kind::Fill { ch } => cells.fill(whole(cut), whole(rect), *ch, node.style),
                Kind::Picture(_) => {}
                Kind::Group | Kind::Plane(_) | Kind::Role { .. } => {
                    self.cells_in(&node.kids, map.inside(node), overlap(cut, rect), cells, depth + 1)
                }
            }
        }
    }

    /// The scene's colours for `default`, as red, green and blue.
    pub fn colors(&self) -> ((u8, u8, u8), (u8, u8, u8)) {
        let parse = |text: &str, or: (u8, u8, u8)| match Color::parse(text) {
            Some(color) => cells::rgb(color, or),
            None => or,
        };
        (parse(&self.fg, (0xd8, 0xd9, 0xdc)), parse(&self.bg, (0x18, 0x19, 0x1c)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cells::BOLD;
    use serde_json::json;

    fn run(key: &str, x: f32, y: f32, text: &str) -> Node {
        Node::new(key, Kind::Run { text: text.into() }, [x, y, text.chars().count() as f32, 1.0])
    }

    fn fill(key: &str, rect: Units, ch: Option<char>, style: Style) -> Node {
        Node { style, ..Node::new(key, Kind::Fill { ch }, rect) }
    }

    fn lines(cells: &Cells) -> Vec<String> {
        cells.cells.chunks(cells.width as usize).map(|row| row.iter().map(|c| c.ch).collect()).collect()
    }

    /// A roll: a plane of beats along x (two units a beat, from beat 4)
    /// and pitches running up (one row each, pitch 64 at the top).
    fn roll() -> Scene {
        let mut scene = Scene::new([20.0, 6.0]);
        scene.push(None, fill("bg", [0.0, 0.0, 20.0, 6.0], Some('.'), Style::default()));
        let plane = Plane {
            x: Axis { domain: "beat".into(), from: 4.0, per: 2.0 },
            y: Axis { domain: "pitch".into(), from: 65.0, per: -1.0 },
        };
        let mut grid = Node::new("roll", Kind::Plane(plane), [2.0, 1.0, 16.0, 4.0]);
        grid.hit = Some(json!({ "kind": "grid" }));
        scene.push(None, grid);
        let mut note = Node::new("note:1", Kind::Role { role: "note".into(), props: json!({ "velocity": 100 }) }, [5.0, 62.0, 1.5, 1.0]);
        note.hit = Some(json!({ "kind": "note", "id": 1 }));
        scene.push(Some("roll"), note);
        // The note's cells, which a frontend that does not know notes draws.
        scene.push(Some("note:1"), fill("note:1/cells", [0.0, 0.0, 1.5, 1.0], Some('█'), Style::default()));
        scene
    }

    #[test]
    fn a_patch_carries_what_changed_and_makes_the_same_scene() {
        let mut old = Scene::new([10.0, 2.0]);
        old.push(None, run("a", 0.0, 0.0, "one"));
        old.push(None, run("b", 0.0, 1.0, "two"));
        old.push(None, run("c", 5.0, 1.0, "gone"));
        let mut new = old.clone();
        new.nodes.get_mut("b").unwrap().kind = Kind::Run { text: "TWO".into() };
        new.nodes.remove("c");
        new.root.retain(|k| k != "c");
        new.push(None, fill("d", [0.0, 0.0, 10.0, 1.0], None, Style { on: BOLD, ..Style::default() }));
        new.cursor = Some([1.0, 1.0]);
        let patch = Scene::diff(&old, &new, "3");
        assert_eq!(patch.set.iter().map(|n| n.key.as_str()).collect::<Vec<_>>(), vec!["b", "d"]);
        assert_eq!(patch.drop, vec!["c".to_string()]);
        assert_eq!(patch.root.as_deref(), Some(&["a".to_string(), "b".into(), "d".into()][..]));
        assert_eq!(patch.size, None, "the size did not change");
        // Over the wire and back, then applied: the scene the kernel has.
        let wire = serde_json::to_string(&patch).unwrap();
        let mut copy = old.clone();
        copy.apply(&serde_json::from_str(&wire).unwrap());
        assert_eq!((copy.root.clone(), copy.nodes.clone(), copy.cursor), (new.root.clone(), new.nodes.clone(), new.cursor));
        assert!(Scene::diff(&new, &new, "3").is_empty(), "nothing changed, nothing to say");
    }

    #[test]
    fn nodes_on_the_wire_are_short() {
        let mut node = run("t3,5", 3.0, 5.0, "hi");
        node.style = Style { fg: Some(Color::Rgb(255, 0, 0)), ..Style::default() };
        node.clip = Some([0.0, 0.0, 80.0, 24.5]);
        assert_eq!(
            serde_json::to_value(&node).unwrap(),
            json!({ "k": "t3,5", "t": "run", "text": "hi", "r": [3, 5, 2, 1], "clip": [0, 0, 80, 24.5], "s": { "fg": "#ff0000" } })
        );
        let picture = Node::new("p", Kind::Picture(Picture { ops: None, blob: Some("pic:1f".into()), px: [78.0, 34.0], under: true }), [1.0, 2.0, 10.0, 2.0]);
        let back: Node = serde_json::from_value(serde_json::to_value(&picture).unwrap()).unwrap();
        assert_eq!(back, picture);
    }

    #[test]
    fn a_patch_with_nothing_but_a_moved_cursor_is_small() {
        let mut old = Scene::new([80.0, 24.0]);
        for y in 0..24 {
            old.push(None, run(&format!("t0,{y}"), 0.0, y as f32, &"x".repeat(80)));
        }
        let mut new = old.clone();
        new.cursor = Some([4.0, 4.0]);
        let wire = serde_json::to_string(&Scene::diff(&old, &new, "1")).unwrap();
        assert_eq!(wire, r#"{"win":"1","rev":1,"cursor":[4.0,4.0]}"#);
    }

    #[test]
    fn a_scene_lowers_to_the_cells_its_writes_make() {
        let mut scene = Scene::new([8.0, 2.0]);
        let back = Style { bg: Some(Color::Indexed(4)), ..Style::default() };
        scene.push(None, fill("bg", [0.0, 0.0, 8.0, 2.0], Some(' '), back));
        scene.push(None, run("a", 1.0, 0.0, "hello world"));
        // Cut to the first four columns, as a sub-buffer's writes are.
        let mut cut = run("b", 0.0, 1.0, "abcdefgh");
        cut.clip = Some([0.0, 1.0, 4.0, 1.0]);
        scene.push(None, cut);
        scene.push(None, fill("hl", [1.0, 0.0, 3.0, 1.0], None, Style { on: BOLD, ..Style::default() }));
        let cells = scene.to_cells();
        assert_eq!(lines(&cells), vec![" hello w", "abcd    "]);
        assert_eq!((cells.cells[0].attrs, cells.cells[1].attrs, cells.cells[4].attrs), (0, BOLD, 0));
        assert_eq!(cells.cells[9].bg, Color::Indexed(4), "text keeps the background under it");
    }

    #[test]
    fn a_plane_places_its_kids_by_their_domain_and_a_role_draws_its_cells() {
        let cells = roll().to_cells();
        // Beat 5 is two units into the plane (x 2 + 2); pitch 62 is the
        // third row of the plane (y 1 + 2), whose top edge is pitch 65 and
        // whose first row is pitch 64. A beat and a half is three units.
        assert_eq!(lines(&cells)[3], "....███.............");
        assert!(lines(&cells).iter().enumerate().all(|(y, l)| y == 3 || !l.contains('█')));
    }

    #[test]
    fn a_hit_finds_the_last_region_drawn_and_says_where_in_its_plane() {
        let scene = roll();
        let on_note = scene.hit([4.5, 3.5]).unwrap();
        assert_eq!((on_note.key.as_str(), on_note.hit["id"].as_i64()), ("note:1", Some(1)));
        // In the plane's domain: 2.5 units into it is beat 4 + 2.5 / 2,
        // 2.5 rows down is pitch 65 - 2.5.
        assert_eq!(on_note.at, [5.25, 62.5]);
        let empty = scene.hit([10.0, 1.5]).unwrap();
        assert_eq!((empty.key.as_str(), empty.at), ("roll", [8.0, 64.5]));
        assert_eq!(scene.hit([0.5, 0.5]), None, "the background is no hit region");
        assert_eq!(scene.hit([19.0, 5.5]), None, "nor is anything outside the plane");
    }

    #[test]
    fn a_kid_outside_its_group_neither_shows_nor_is_hit() {
        let mut scene = Scene::new([10.0, 3.0]);
        scene.push(None, Node::new("g", Kind::Group, [2.0, 1.0, 3.0, 1.0]));
        let mut wide = run("g/t", 0.0, 0.0, "abcdef");
        wide.hit = Some(json!("text"));
        scene.push(Some("g"), wide);
        assert_eq!(lines(&scene.to_cells())[1], "  abc     ");
        assert!(scene.hit([4.5, 1.5]).is_some());
        assert_eq!(scene.hit([6.5, 1.5]), None, "cut to the group");
    }
}
