//! The windows the kernel draws (a pane of the main area that the window
//! has no drawing of its own for, a view in a window of its own), from
//! their scenes (crates/paw-scene). The kernel pushes what changed of each
//! as it changes (`scene.patch`), and every frame draws from the copy kept
//! here, asking nothing: the cells as text in the window's monospace font,
//! block characters, braille and sextants as rectangles, the pictures as
//! images made again only when their drawing changes, the roles it knows
//! (crate::roles: faders, meters, switches...) as widgets, the meters moved
//! by the live values (`scene.live`). The window tells the kernel how big
//! each window is, in cells (`scene.area`), and passes the pointer on in
//! the same units (`scene.input`), where the view's hit regions give it its
//! meaning. See runtime/lua/paw/scene.lua and docs/reference/protocol.md.

use std::collections::{HashMap, HashSet};

use egui::{Color32, ColorImage, CornerRadius, Id, Pos2, Rect, Shape, Stroke, TextureHandle, Ui, pos2, vec2};
use paw_scene::cells::{BOLD, Run, STRIKE, UNDERLINE};
use paw_scene::{Kind, Node, Patch, Scene};
use serde_json::{Value, json};
use unicode_width::UnicodeWidthChar;

use crate::app::View;
use crate::panes::pointer_events;
use crate::roles;
use crate::theme::{hex, mono, mono_medium};

/// The size of the monospace font cells are drawn in.
pub const MONO_SIZE: f32 = 13.0;

/// The window's cell, in points: a character of its monospace font wide,
/// a row of it high. Views drawn in cells are laid out on it.
pub fn cell(ctx: &egui::Context) -> (f32, f32) {
    let font = mono(MONO_SIZE);
    ctx.fonts_mut(|f| (f.glyph_width(&font, 'M'), f.row_height(&font)))
}

/// A drawing in a scene, and the image made of it.
struct Picture {
    /// Its node's key.
    key: String,
    /// Where it is in units, and the part of it that shows.
    rect: [f32; 4],
    clip: Option<[f32; 4]>,
    under: bool,
    /// The size in pixels it was drawn for.
    px: [f32; 2],
    ops: Value,
    /// The image, and its size in pixels.
    image: Option<(TextureHandle, [usize; 2])>,
}

/// A window's scene, and what is drawn of it.
#[derive(Default)]
struct Shown {
    scene: Scene,
    /// The scene lowered to cells, as rows of runs.
    rows: Vec<Vec<Run>>,
    pictures: Vec<Picture>,
    /// The roles painted here, where they are and what they are cut to, in
    /// units (left, top, right, bottom).
    roles: Vec<(Node, [f64; 4], [f64; 4])>,
    /// The runs and fills drawn over those roles, painted over them again.
    over: Vec<(Node, [f64; 4], [f64; 4])>,
    /// The shapes of the cells' backgrounds and of their text, and where,
    /// on what cell and at what scale they were made.
    shapes: Option<(Vec<Shape>, Vec<Shape>, [f32; 5])>,
}

#[derive(Default)]
pub struct Scenes {
    shown: HashMap<String, Shown>,
    /// The size each window was last said to be, in units.
    told: HashMap<String, [f32; 2]>,
    /// The windows drawn this frame.
    seen: HashSet<String>,
    /// Where each window was last drawn, in points.
    placed: HashMap<String, Rect>,
    /// The clip a drag in the arrange view moves, while the pointer is
    /// over the session view's slots, where letting go puts it.
    pub dragged_clip: Option<i64>,
    /// The window the pointer was over last frame, and this frame: the
    /// kernel is told when it leaves one, for the hint it gave there.
    hovered: Option<String>,
    hovering: Option<String>,
    /// Drawings sent by their content key, fetched once.
    blobs: HashMap<String, Value>,
    /// The window's cell, once measured: the kernel is told it then.
    pub cell: Option<(f32, f32)>,
    /// What bound nodes are moved by, as the kernel last sent it.
    pub live: Value,
}

impl Scenes {
    /// The window's cell, or the size it has before it is measured.
    pub fn cell(&self) -> (f32, f32) {
        self.cell.unwrap_or((7.8, 17.0))
    }
}

/// A colour as a scene writes it.
fn colour(text: &str) -> Color32 {
    hex(text).unwrap_or(Color32::GRAY)
}

/// Block elements, braille and sextants as the parts of their cell they
/// cover (left, top, right, bottom, in fractions of it) and how opaque, so
/// that they fill it and join the next as the terminal shows them.
fn blocks(c: char) -> Option<(Vec<[f32; 4]>, f32)> {
    let u = c as u32;
    let mut parts = Vec::new();
    let mut alpha = 1.0;
    // The quadrants, by bit: upper left, upper right, lower left, lower right.
    const QUADRANTS: [u8; 10] = [0b0100, 0b1000, 0b0001, 0b1101, 0b1001, 0b0111, 0b1011, 0b0010, 0b0110, 0b1110];
    match u {
        0x2580 => parts.push([0.0, 0.0, 1.0, 0.5]),
        0x2581..=0x2588 => parts.push([0.0, 1.0 - (u - 0x2580) as f32 / 8.0, 1.0, 1.0]),
        0x2589..=0x258F => parts.push([0.0, 0.0, (0x2590 - u) as f32 / 8.0, 1.0]),
        0x2590 => parts.push([0.5, 0.0, 1.0, 1.0]),
        0x2591..=0x2593 => {
            alpha = (u - 0x2590) as f32 / 4.0;
            parts.push([0.0, 0.0, 1.0, 1.0]);
        }
        0x2594 => parts.push([0.0, 0.0, 1.0, 0.125]),
        0x2595 => parts.push([0.875, 0.0, 1.0, 1.0]),
        0x2596..=0x259F => {
            let bits = QUADRANTS[(u - 0x2596) as usize];
            for (bit, part) in [[0.0, 0.0, 0.5, 0.5], [0.5, 0.0, 1.0, 0.5], [0.0, 0.5, 0.5, 1.0], [0.5, 0.5, 1.0, 1.0]].into_iter().enumerate() {
                if bits & (1 << bit) != 0 {
                    parts.push(part);
                }
            }
        }
        0x2800..=0x28FF => {
            // Dots in two columns of four; the bits count down the first
            // column's three, the second's three, then the bottom two.
            const ROW: [f32; 8] = [0.0, 1.0, 2.0, 0.0, 1.0, 2.0, 3.0, 3.0];
            const COLUMN: [f32; 8] = [0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.0, 1.0];
            for bit in 0..8 {
                if (u - 0x2800) & (1 << bit) != 0 {
                    let (x, y) = ((COLUMN[bit] + 0.5) / 2.0, (ROW[bit] + 0.5) / 4.0);
                    parts.push([x - 0.12, y - 0.065, x + 0.12, y + 0.065]);
                }
            }
        }
        0x1FB00..=0x1FB3B => {
            // Six parts, a half wide and a third tall; the full left and
            // right halves are characters of their own, left out here.
            let mut bits = u - 0x1FB00 + 1;
            if bits >= 21 {
                bits += 1;
            }
            if bits >= 42 {
                bits += 1;
            }
            for bit in 0..6 {
                if bits & (1 << bit) != 0 {
                    let (x, y) = ((bit % 2) as f32 / 2.0, (bit / 2) as f32 / 3.0);
                    parts.push([x, y, x + 0.5, y + 1.0 / 3.0]);
                }
            }
        }
        _ => return None,
    }
    Some((parts, alpha))
}

impl Shown {
    /// Take in a patch, and what it changes of the cells and the pictures.
    fn take(&mut self, patch: &Patch, blobs: &HashMap<String, Value>) {
        self.scene.apply(patch);
        let (fg, bg) = self.scene.colors();
        self.rows = self.scene.to_cells().runs(fg, bg);
        let mut before: HashMap<String, Picture> = self.pictures.drain(..).map(|p| (p.key.clone(), p)).collect();
        let mut pictures = Vec::new();
        self.scene.walk(&mut |node| {
            let Kind::Picture(picture) = &node.kind else { return };
            let ops = match (&picture.ops, &picture.blob) {
                (Some(ops), _) => ops.clone(),
                (None, Some(key)) => blobs.get(key).cloned().unwrap_or(Value::Null),
                _ => Value::Null,
            };
            // A drawing that did not change keeps its image.
            let image = before.remove(&node.key).filter(|p| p.rect == node.rect && p.px == picture.px && p.ops == ops).and_then(|p| p.image);
            pictures.push(Picture { key: node.key.clone(), rect: node.rect, clip: node.clip, under: picture.under, px: picture.px, ops, image });
        });
        self.pictures = pictures;
        let mut placed = Vec::new();
        self.scene.placed(&mut |node, rect, cut| {
            if let Kind::Role { role, .. } = &node.kind
                && roles::KNOWN.contains(&role.as_str())
            {
                placed.push((node.clone(), rect, cut));
            }
        });
        self.roles = placed;
        self.over = self.scene.over_roles(&|role| roles::KNOWN.contains(&role));
        self.shapes = None;
    }

    /// Paint the runs and fills a view drew over the roles painted here,
    /// over them, as a terminal shows them: text and its background where
    /// it has one; a fill that only restyles (the selection, the cursor) a
    /// tint, so that what it covers still shows through.
    fn paint_over(&self, ctx: &egui::Context, painter: &egui::Painter, at: Pos2, (cw, ch): (f32, f32)) {
        let (fg, bg) = self.scene.colors();
        let colour = |c: Option<paw_scene::cells::Color>, or: (u8, u8, u8)| {
            c.map(|c| {
                let (r, g, b) = paw_scene::cells::rgb(c, or);
                Color32::from_rgb(r, g, b)
            })
        };
        for (node, rect, cut) in &self.over {
            let cells = |l: f64, t: f64, r: f64, b: f64| {
                Rect::from_min_max(pos2(at.x + l.floor() as f32 * cw, at.y + t.floor() as f32 * ch), pos2(at.x + r.floor() as f32 * cw, at.y + b.floor() as f32 * ch))
            };
            let shown = cells(rect[0], rect[1], rect[2], rect[3]);
            let p = painter.with_clip_rect(cells(cut[0], cut[1], cut[2], cut[3]).intersect(painter.clip_rect()));
            let back = colour(node.style.bg, bg);
            let ink = colour(node.style.fg, fg).unwrap_or(Color32::from_rgb(fg.0, fg.1, fg.2));
            let font = if node.style.on & BOLD != 0 { mono_medium(MONO_SIZE) } else { mono(MONO_SIZE) };
            let text = match &node.kind {
                Kind::Run { text } => Some(text.clone()),
                Kind::Fill { ch: Some(c) } => Some(c.to_string().repeat(shown.width().div_euclid(cw).max(1.0) as usize)),
                Kind::Fill { ch: None } => {
                    if let Some(back) = back {
                        p.rect_filled(shown, CornerRadius::ZERO, back.gamma_multiply(0.45));
                    }
                    None
                }
                _ => None,
            };
            let Some(text) = text else { continue };
            if let Some(back) = back {
                p.rect_filled(shown, CornerRadius::ZERO, back);
            }
            if text.trim().is_empty() {
                continue;
            }
            for row in 0..(shown.height() / ch).round().max(1.0) as usize {
                let galley = ctx.fonts_mut(|f| f.layout_no_wrap(text.clone(), font.clone(), ink));
                p.galley(pos2(shown.left(), shown.top() + row as f32 * ch), galley, ink);
            }
        }
    }

    /// The shapes of the cells' backgrounds and text, from `at`.
    fn shapes(&self, ctx: &egui::Context, at: Pos2, (cw, ch): (f32, f32)) -> (Vec<Shape>, Vec<Shape>) {
        let (mut back, mut text) = (Vec::new(), Vec::new());
        let bg = self.scene.bg.as_str();
        let cell_rect = |x: f32, y: f32, w: f32| Rect::from_min_size(pos2(at.x + x * cw, at.y + y * ch), vec2(w * cw, ch));
        ctx.fonts_mut(|fonts| {
            for (y, row) in self.rows.iter().enumerate() {
                let y = y as f32;
                for run in row {
                    if run.bg != bg {
                        back.push(Shape::rect_filled(cell_rect(run.x as f32, y, run.w as f32), CornerRadius::ZERO, colour(&run.bg)));
                    }
                    let fg = colour(&run.fg);
                    let font = if run.attrs & BOLD != 0 { mono_medium(MONO_SIZE) } else { mono(MONO_SIZE) };
                    // Characters of the font go together as one piece of
                    // text (`piece`, from column `from`); any other is drawn
                    // by itself, at its column.
                    let (mut piece, mut from, mut col) = (String::new(), run.x as f32, run.x as f32);
                    for c in run.text.chars().chain(['\n']) {
                        let width = if c == '\n' { 0.0 } else { c.width().unwrap_or(0) as f32 };
                        let joins = width == 1.0 && blocks(c).is_none() && (fonts.glyph_width(&font, c) - cw).abs() < 0.5;
                        if joins {
                            if piece.is_empty() {
                                from = col;
                            }
                            piece.push(c);
                            col += width;
                            continue;
                        }
                        if !piece.trim().is_empty() {
                            let galley = fonts.layout_no_wrap(std::mem::take(&mut piece), font.clone(), fg);
                            text.push(Shape::galley(cell_rect(from, y, 1.0).min, galley, fg));
                        }
                        piece.clear();
                        if width == 0.0 {
                            continue;
                        }
                        if let Some((parts, alpha)) = blocks(c) {
                            let cell = cell_rect(col, y, 1.0);
                            for [l, t, r, b] in parts {
                                let part = Rect::from_min_max(cell.lerp_inside(vec2(l, t)), cell.lerp_inside(vec2(r, b)));
                                text.push(Shape::rect_filled(part, CornerRadius::ZERO, fg.gamma_multiply(alpha)));
                            }
                        } else if !c.is_whitespace() {
                            let galley = fonts.layout_no_wrap(c.to_string(), font.clone(), fg);
                            text.push(Shape::galley(cell_rect(col, y, width).min, galley, fg));
                        }
                        col += width;
                    }
                    let line = |frac: f32| {
                        let r = cell_rect(run.x as f32, y, run.w as f32);
                        Shape::hline(r.x_range(), r.top() + r.height() * frac, Stroke::new(1.0, fg))
                    };
                    if run.attrs & UNDERLINE != 0 {
                        text.push(line(0.92));
                    }
                    if run.attrs & STRIKE != 0 {
                        text.push(line(0.5));
                    }
                }
            }
        });
        (back, text)
    }

    /// Draw the window's scene over `rect`, cut to `clip`; `id` is the
    /// window's.
    fn draw(&mut self, ui: &Ui, id: &str, rect: Rect, clip: Rect, cell: (f32, f32), live: &Value) {
        let painter = ui.painter().with_clip_rect(clip.intersect(ui.clip_rect()));
        painter.rect_filled(rect, CornerRadius::ZERO, colour(&self.scene.bg));
        let ppp = ui.ctx().pixels_per_point();
        let key = [rect.min.x, rect.min.y, cell.0, cell.1, ppp];
        if self.shapes.as_ref().is_none_or(|s| s.2 != key) {
            let (back, text) = self.shapes(ui.ctx(), rect.min, cell);
            self.shapes = Some((back, text, key));
        }
        let Some((back, text, _)) = &self.shapes else { return };
        painter.extend(back.iter().cloned());
        let text = text.clone();
        self.pictures(ui, &painter, rect.min, cell, true);
        painter.extend(text);
        for (node, at, cut) in &self.roles {
            let cut = roles::rect_of(*cut, rect.min, cell);
            let role_painter = painter.with_clip_rect(cut.intersect(painter.clip_rect()));
            let salt = Id::unique(("scene-role", id, &node.key));
            roles::paint(ui, &role_painter, salt, node, roles::rect_of(*at, rect.min, cell), cell, live);
        }
        self.paint_over(ui.ctx(), &painter, rect.min, cell);
        self.pictures(ui, &painter, rect.min, cell, false);
        if let Some([x, y]) = self.scene.cursor {
            let bar = Rect::from_min_size(pos2(rect.min.x + x * cell.0, rect.min.y + y * cell.1), vec2(2.0, cell.1));
            painter.rect_filled(bar, CornerRadius::ZERO, colour(&self.scene.fg));
        }
    }

    /// Draw the pictures under the cells' text, or those over it, making
    /// the image of any that has none at the size it is shown at.
    fn pictures(&mut self, ui: &Ui, painter: &egui::Painter, at: Pos2, (cw, ch): (f32, f32), under: bool) {
        let ppp = ui.ctx().pixels_per_point();
        let units = |r: [f32; 4]| Rect::from_min_size(pos2(at.x + r[0] * cw, at.y + r[1] * ch), vec2(r[2] * cw, r[3] * ch));
        for p in self.pictures.iter_mut().filter(|p| p.under == under) {
            let rect = units(p.rect);
            let size = [(rect.width() * ppp).round().max(1.0) as usize, (rect.height() * ppp).round().max(1.0) as usize];
            if p.image.as_ref().is_none_or(|(_, made)| *made != size) {
                // The drawing's pixels to the image's: the drawing fills it.
                let scale = size[0] as f32 / p.px[0].max(1.0);
                let image = match paw_raster::Drawing::parse(&p.ops).paint_scaled(size[0] as u32, size[1] as u32, scale) {
                    Some(pixmap) => ColorImage::from_rgba_premultiplied(size, pixmap.data()),
                    None => ColorImage::new(size, vec![Color32::TRANSPARENT; size[0] * size[1]]),
                };
                let texture = ui.ctx().load_texture("scene-picture", image, egui::TextureOptions::LINEAR);
                p.image = Some((texture, size));
            }
            let Some((texture, _)) = &p.image else { continue };
            let shown = p.clip.map_or(painter.clip_rect(), |c| units(c).intersect(painter.clip_rect()));
            painter.with_clip_rect(shown).image(texture.id(), rect, Rect::from_min_max(Pos2::ZERO, pos2(1.0, 1.0)), Color32::WHITE);
        }
    }
}

impl View {
    /// Watch the scenes of this window's seat from the first frame, when
    /// the window's cell can be measured.
    pub fn scenes_watch(&mut self, ctx: &egui::Context) {
        if self.scenes.cell.is_some() {
            return;
        }
        let (w, h) = cell(ctx);
        self.scenes.cell = Some((w, h));
        // The roles it paints come without their cells; the meters move
        // with the live values.
        let watched = self.k.borrow_mut().call("scene.watch", json!([{ "cell": { "w": w, "h": h }, "roles": roles::KNOWN, "live": true }]));
        if let Err(err) = watched {
            self.show(&format!("{err:#}"), true);
        }
    }

    /// Take in what the kernel pushed of the scenes, fetching the drawings
    /// sent by their key that are not here yet.
    pub fn scene_patches(&mut self) {
        if let Some(live) = self.k.borrow_mut().live() {
            self.scenes.live = live;
            self.repaint = true;
        }
        let patches = self.k.borrow_mut().patches();
        for patch in patches {
            let Ok(patch) = serde_json::from_value::<Patch>(patch) else { continue };
            // What comes for a window after it went is of no use: a window
            // shown again is sent its whole scene.
            if !patch.full && !self.scenes.shown.contains_key(&patch.win) {
                continue;
            }
            for node in &patch.set {
                if let Kind::Picture(paw_scene::Picture { blob: Some(key), .. }) = &node.kind
                    && !self.scenes.blobs.contains_key(key)
                {
                    let ops = self.k.borrow_mut().call("scene.blob", json!([key])).unwrap_or(Value::Null);
                    self.scenes.blobs.insert(key.clone(), ops);
                }
            }
            let shown = self.scenes.shown.entry(patch.win.clone()).or_default();
            shown.take(&patch, &self.scenes.blobs);
            self.repaint = true;
        }
    }

    /// A window the kernel draws, over `rect` and cut to `clip`, named as
    /// the kernel names it (`3`, `view:undotree`): its size said when it
    /// changes, its scene drawn, and the pointer over it passed on.
    pub fn scene(&mut self, ui: &Ui, id: &str, rect: Rect, clip: Rect) {
        let cell = self.scenes.cell();
        self.scenes.seen.insert(id.to_string());
        self.scenes.placed.insert(id.to_string(), rect);
        if ui.rect_contains_pointer(clip) {
            self.scenes.hovering = Some(id.to_string());
        }
        let size = [rect.width().max(0.0) / cell.0, rect.height().max(0.0) / cell.1];
        if self.scenes.told.get(id) != Some(&size) {
            self.scenes.told.insert(id.to_string(), size);
            self.call_later("scene.area", json!([id, size[0], size[1]]));
        }
        if let Some(shown) = self.scenes.shown.get_mut(id) {
            shown.draw(ui, id, rect, clip, cell, &self.scenes.live);
        }
        for mut event in pointer_events(ui, rect, Id::unique(("scene-pointer", id))) {
            if self.to_slot(rect, &event) {
                continue;
            }
            event["x"] = json!(event["x"].as_f64().unwrap_or(0.0) / cell.0 as f64);
            event["y"] = json!(event["y"].as_f64().unwrap_or(0.0) / cell.1 as f64);
            self.call_later("scene.input", json!([id, event]));
        }
    }

    /// A clip dragged from the arrange view over the session view's slots:
    /// let go there, it goes into the slot (`clip_to_slot`), and the drag
    /// in the kernel ends without moving it. True when the event was that.
    fn to_slot(&mut self, rect: Rect, event: &Value) -> bool {
        let at = rect.min + vec2(event["x"].as_f64().unwrap_or(0.0) as f32, event["y"].as_f64().unwrap_or(0.0) as f32);
        let Some((column, slot)) = self.session.slot_at(at) else {
            if event["kind"] == "up" {
                self.scenes.dragged_clip = None;
            }
            return false;
        };
        match event["kind"].as_str() {
            Some("move") if self.scenes.dragged_clip.is_none() => {
                self.scenes.dragged_clip = self.ask("local g = paw.mouse.gesture(); return g and g.clip", json!([])).as_i64();
                false
            }
            Some("up") => match self.scenes.dragged_clip.take() {
                Some(clip) => {
                    self.eval("paw.mouse.forget(); paw.api.ui_redraw()", json!([]));
                    self.pass("clip_to_slot", json!([clip, column, slot]));
                    true
                }
                None => false,
            },
            _ => false,
        }
    }

    /// The track whose header is under a point of the window, in a pane
    /// that shows the arrange view.
    pub fn header_at(&self, p: Pos2) -> Option<i64> {
        let cell = self.scenes.cell();
        let (id, rect) = self.scenes.placed.iter().find(|(_, r)| r.contains(p))?;
        let at = p - rect.min;
        self.ask("return paw.ui.views.arrange:header_track(...)", json!([id, at.x / cell.0, at.y / cell.1])).as_i64()
    }

    /// At the end of a frame: the windows not drawn in it are gone, and
    /// the kernel is told (a size of nothing), so that it keeps nothing of
    /// them either.
    pub fn scenes_done(&mut self) {
        let hovering = self.scenes.hovering.take();
        if let Some(left) = std::mem::replace(&mut self.scenes.hovered, hovering.clone())
            && Some(&left) != hovering.as_ref()
        {
            self.call_later("scene.input", json!([left, { "kind": "leave" }]));
        }
        let seen = std::mem::take(&mut self.scenes.seen);
        self.scenes.placed.retain(|id, _| seen.contains(id));
        let gone: Vec<String> = self.scenes.told.keys().filter(|id| !seen.contains(*id)).cloned().collect();
        for id in gone {
            self.scenes.told.remove(&id);
            self.scenes.shown.remove(&id);
            self.call_later("scene.area", json!([id, 0, 0]));
        }
        let named: HashSet<&String> = self
            .scenes
            .shown
            .values()
            .flat_map(|s| s.scene.nodes.values())
            .filter_map(|n| match &n.kind {
                Kind::Picture(paw_scene::Picture { blob: Some(key), .. }) => Some(key),
                _ => None,
            })
            .collect();
        let keep: HashSet<String> = named.into_iter().cloned().collect();
        self.scenes.blobs.retain(|key, _| keep.contains(key));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eighth_blocks_fill_from_the_bottom_and_quadrants_are_their_corners() {
        assert_eq!(blocks('▂').unwrap().0, vec![[0.0, 0.75, 1.0, 1.0]]);
        assert_eq!(blocks('█').unwrap().0, vec![[0.0, 0.0, 1.0, 1.0]]);
        assert_eq!(blocks('▎').unwrap().0, vec![[0.0, 0.0, 0.25, 1.0]]);
        assert_eq!(blocks('▚').unwrap().0, vec![[0.0, 0.0, 0.5, 0.5], [0.5, 0.5, 1.0, 1.0]]);
        assert_eq!(blocks('▒').unwrap().1, 0.5);
        // Braille: the full cell has eight dots, the first at the top left.
        let (dots, _) = blocks('⣿').unwrap();
        assert_eq!(dots.len(), 8);
        let (one, _) = blocks('⠁').unwrap();
        assert!(one[0][0] < 0.5 && one[0][1] < 0.25);
        assert!(blocks('a').is_none() && blocks('─').is_none());
    }
}
