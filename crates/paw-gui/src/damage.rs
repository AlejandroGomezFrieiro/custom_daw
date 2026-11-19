//! What changed on the screen from one frame to the next, so that the
//! window draws again only there, onto what the last frame left (see
//! crate::runner).
//!
//! The screen is cut into squares of `TILE` pixels. Each square keeps the
//! shapes that reach into it, in their order. A square whose shapes are the
//! same as in the last frame (and whose pictures did not change) shows the
//! same pixels: it is not drawn again. While the song plays, only the
//! squares of the playhead, the meters and the time change, a few percent
//! of the window. A frame where no square changed is not drawn or shown at
//! all.
//!
//! A buffer that the driver gives back is a few frames old
//! (`EGL_EXT_buffer_age`): it is brought up to date with the changes of
//! those frames, which are kept here.

use std::collections::{HashSet, VecDeque};
use std::sync::Arc;

use egui::epaint::ClippedShape;
use egui::{Shape, TextureId};

/// The side of a square of the screen, in pixels.
pub const TILE: i32 = 32;

/// A rectangle of pixels from the top left: left, top, right, bottom.
pub type Px = [i32; 4];

/// The most rectangles a frame is drawn again in; more are joined.
const MOST_RECTS: usize = 12;

/// The frames of changes kept, for a buffer as old as that.
const HISTORY: usize = 4;

#[derive(Default)]
pub struct Damage {
    /// The scale and size of the screen the last frame had.
    ppp: f32,
    screen: [u32; 2],
    /// Columns and rows of squares.
    cols: i32,
    rows: i32,
    /// The last frame's shapes, where each shows (pixels, a pixel more each
    /// way for the smoothed edge), and by square the shapes in it.
    shapes: Vec<ClippedShape>,
    bounds: Vec<Px>,
    bins: Vec<Vec<u32>>,
    /// The lists of the frame before, kept for their room.
    spare: Vec<Vec<u32>>,
    /// The squares that changed in this frame.
    fresh: Vec<bool>,
    /// The squares changed in each frame shown, the newest last.
    history: VecDeque<Vec<bool>>,
    /// The shapes and their places in squares, all told, for the counts.
    pub counted: u64,
    pub pushes: u64,
    pub passes: u64,
}

impl Damage {
    /// Take the frame's shapes, drawn at `ppp` pixels a point on a screen of
    /// `screen` pixels; `textures` are those whose pixels changed in it, and
    /// `all` says that every square is to be drawn again. Returns whether
    /// any square changed.
    pub fn frame(&mut self, shapes: Vec<ClippedShape>, ppp: f32, screen: [u32; 2], textures: &HashSet<TextureId>, all: bool) -> bool {
        let resized = self.ppp != ppp || self.screen != screen;
        if resized {
            self.ppp = ppp;
            self.screen = screen;
            self.cols = (screen[0] as i32 + TILE - 1) / TILE;
            self.rows = (screen[1] as i32 + TILE - 1) / TILE;
            self.history.clear();
        }
        let squares = (self.cols * self.rows).max(0) as usize;
        let mut bins = std::mem::take(&mut self.spare);
        bins.resize_with(squares, Vec::new);
        bins.iter_mut().for_each(Vec::clear);
        let mut bounds = Vec::with_capacity(shapes.len());
        for (i, shape) in shapes.iter().enumerate() {
            let px = self.pixels(shape);
            bounds.push(px);
            let Some(((x0, x1), (y0, y1))) = self.squares_of(px) else { continue };
            for y in y0..=y1 {
                for x in x0..=x1 {
                    bins[(y * self.cols + x) as usize].push(i as u32);
                    self.pushes += 1;
                }
            }
        }
        let mut fresh = vec![all || resized; squares];
        if !all && !resized {
            // A shape is compared with the last frame's once, however many
            // squares it reaches: the last answer is kept.
            let mut asked: Vec<(u32, bool)> = vec![(u32::MAX, false); shapes.len()];
            for (square, now) in bins.iter().enumerate() {
                let before = &self.bins[square];
                fresh[square] = now.len() != before.len()
                    || now.iter().zip(before).any(|(&i, &j)| {
                        let (last, same_as) = asked[i as usize];
                        let same = if last == j { same_as } else { same(&shapes[i as usize], &self.shapes[j as usize]) && !uses(&shapes[i as usize].shape, textures) };
                        asked[i as usize] = (j, same);
                        !same
                    });
            }
        }
        self.counted += shapes.len() as u64;
        self.passes += 1;
        self.shapes = shapes;
        self.bounds = bounds;
        self.spare = std::mem::replace(&mut self.bins, bins);
        self.fresh = fresh;
        self.fresh.iter().any(|f| *f)
    }

    /// The frame's shapes as the last frame's, but the live parts painted
    /// again (crate::live): `parts`, each by its number. Only the squares
    /// that their shapes reach, now or before, are compared and changed.
    /// `all` says that every square is to be drawn again. Returns whether
    /// any square changed.
    pub fn replay(&mut self, parts: Vec<(u32, Vec<ClippedShape>)>, all: bool) -> bool {
        let ranges = crate::live::ranges(&self.shapes);
        let fits = parts.iter().all(|(n, new)| ranges.iter().any(|(m, first, end)| m == n && end - first == new.len()));
        if !fits || all {
            // A part has more shapes or fewer: all of it is compared.
            let shapes = crate::live::splice(&self.shapes, &parts);
            return self.frame(shapes, self.ppp, self.screen, &HashSet::new(), all);
        }
        let squares = (self.cols * self.rows).max(0) as usize;
        let mut fresh = vec![false; squares];
        for (n, new) in parts {
            let Some(&(_, first, _)) = ranges.iter().find(|(m, _, _)| *m == n) else { continue };
            for (k, shape) in new.into_iter().enumerate() {
                let i = first + k;
                if same(&shape, &self.shapes[i]) {
                    continue;
                }
                let (before, now) = (self.bounds[i], self.pixels(&shape));
                for (px, add) in [(before, false), (now, true)] {
                    let Some(((x0, x1), (y0, y1))) = self.squares_of(px) else { continue };
                    for y in y0..=y1 {
                        for x in x0..=x1 {
                            let square = (y * self.cols + x) as usize;
                            fresh[square] = true;
                            let bin = &mut self.bins[square];
                            match (bin.binary_search(&(i as u32)), add) {
                                (Ok(at), false) => {
                                    bin.remove(at);
                                }
                                (Err(at), true) => bin.insert(at, i as u32),
                                _ => {}
                            }
                        }
                    }
                }
                self.shapes[i] = shape;
                self.bounds[i] = now;
            }
        }
        self.fresh = fresh;
        self.fresh.iter().any(|f| *f)
    }

    /// The scale and the size of the screen of the last frame.
    pub fn ppp(&self) -> f32 {
        self.ppp
    }

    pub fn screen(&self) -> [u32; 2] {
        self.screen
    }

    /// The rectangles changed in this frame: what is shown again.
    pub fn changed(&self) -> Vec<Px> {
        self.rects(&self.fresh)
    }

    /// The rectangles to draw again in a buffer `age` frames old (0: of
    /// unknown age): those changed in this frame and in the `age - 1`
    /// frames shown before it; all of the screen when they are not known.
    pub fn to_draw(&self, age: u32) -> Vec<Px> {
        let behind = age as usize;
        if behind == 0 || behind - 1 > self.history.len() {
            return vec![[0, 0, self.screen[0] as i32, self.screen[1] as i32]];
        }
        let mut squares = self.fresh.clone();
        for old in self.history.iter().rev().take(behind - 1) {
            for (s, o) in squares.iter_mut().zip(old) {
                *s |= *o;
            }
        }
        self.rects(&squares)
    }

    /// The frame was shown: its changes are kept for older buffers.
    pub fn shown(&mut self) {
        self.history.push_back(self.fresh.clone());
        while self.history.len() > HISTORY {
            self.history.pop_front();
        }
    }

    /// The shapes of the frame that reach into `rect`, in their order.
    pub fn shapes_in(&self, rect: Px) -> Vec<ClippedShape> {
        self.shapes.iter().zip(&self.bounds).filter(|(_, b)| meets(**b, rect)).map(|(s, _)| s.clone()).collect()
    }

    /// The squares changed in this frame, for the counts.
    #[cfg(test)]
    fn fresh_count(&self) -> usize {
        self.fresh.iter().filter(|f| **f).count()
    }

    /// Where a shape shows, in pixels: what egui cuts it to, a pixel more
    /// each way for the edge it smooths.
    fn pixels(&self, shape: &ClippedShape) -> Px {
        let bounds = match &shape.shape {
            // A paint callback may draw anywhere it is given.
            Shape::Callback(callback) => callback.rect,
            other => other.visual_bounding_rect(),
        }
        .intersect(shape.clip_rect);
        if !bounds.is_positive() {
            return [0, 0, 0, 0];
        }
        let ppp = self.ppp;
        [
            (bounds.min.x * ppp).floor() as i32 - 1,
            (bounds.min.y * ppp).floor() as i32 - 1,
            (bounds.max.x * ppp).ceil() as i32 + 1,
            (bounds.max.y * ppp).ceil() as i32 + 1,
        ]
    }

    /// The columns and rows of the squares a rectangle reaches into.
    fn squares_of(&self, [l, t, r, b]: Px) -> Option<((i32, i32), (i32, i32))> {
        let (l, t) = (l.max(0), t.max(0));
        let (r, b) = (r.min(self.cols * TILE), b.min(self.rows * TILE));
        (l < r && t < b).then(|| ((l / TILE, (r - 1) / TILE), (t / TILE, (b - 1) / TILE)))
    }

    /// Squares as rectangles: the runs of each row, joined with the same
    /// run in the rows under it; joined further while there are too many.
    fn rects(&self, squares: &[bool]) -> Vec<Px> {
        let mut done: Vec<Px> = Vec::new();
        // Open rectangles, by the columns of their run.
        let mut open: Vec<(i32, i32, i32)> = Vec::new();
        for y in 0..self.rows {
            let mut runs = Vec::new();
            let mut x = 0;
            while x < self.cols {
                if squares[(y * self.cols + x) as usize] {
                    let from = x;
                    while x < self.cols && squares[(y * self.cols + x) as usize] {
                        x += 1;
                    }
                    runs.push((from, x));
                }
                x += 1;
            }
            let mut still = Vec::new();
            for (x0, x1, top) in open.drain(..) {
                if let Some(at) = runs.iter().position(|r| *r == (x0, x1)) {
                    runs.remove(at);
                    still.push((x0, x1, top));
                } else {
                    done.push([x0 * TILE, top * TILE, x1 * TILE, y * TILE]);
                }
            }
            still.extend(runs.into_iter().map(|(x0, x1)| (x0, x1, y)));
            open = still;
        }
        done.extend(open.into_iter().map(|(x0, x1, top)| [x0 * TILE, top * TILE, x1 * TILE, self.rows * TILE]));
        // Fewer, larger: each time the two whose join adds the least.
        while done.len() > MOST_RECTS {
            let area = |r: Px| (r[2] - r[0]) as i64 * (r[3] - r[1]) as i64;
            let mut best = (i64::MAX, 0, 1);
            for i in 0..done.len() {
                for j in i + 1..done.len() {
                    let joined = join(done[i], done[j]);
                    let added = area(joined) - area(done[i]) - area(done[j]);
                    if added < best.0 {
                        best = (added, i, j);
                    }
                }
            }
            let (_, i, j) = best;
            let other = done.swap_remove(j);
            done[i] = join(done[i], other);
        }
        // No two overlap: each is cleared, then all drawn at once.
        while let Some((i, j)) = (0..done.len()).flat_map(|i| (i + 1..done.len()).map(move |j| (i, j))).find(|&(i, j)| meets(done[i], done[j])) {
            let other = done.swap_remove(j);
            done[i] = join(done[i], other);
        }
        let (w, h) = (self.screen[0] as i32, self.screen[1] as i32);
        done.into_iter().map(|[l, t, r, b]| [l, t, r.min(w), b.min(h)]).filter(|[l, t, r, b]| l < r && t < b).collect()
    }
}

fn join(a: Px, b: Px) -> Px {
    [a[0].min(b[0]), a[1].min(b[1]), a[2].max(b[2]), a[3].max(b[3])]
}

fn meets(a: Px, b: Px) -> bool {
    a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3]
}

/// Whether a shape is drawn from one of `textures`.
fn uses(shape: &Shape, textures: &HashSet<TextureId>) -> bool {
    if textures.is_empty() {
        return false;
    }
    match shape {
        Shape::Rect(rect) => rect.brush.as_ref().is_some_and(|b| textures.contains(&b.fill_texture_id)),
        Shape::Mesh(mesh) => textures.contains(&mesh.texture_id),
        Shape::Vec(shapes) => shapes.iter().any(|s| uses(s, textures)),
        _ => false,
    }
}

/// Two shapes the same: a text by its laid out lines, which are shared
/// while the text does not change, a mesh by its own, before they are
/// compared. A paint callback draws what it likes: never the same.
pub fn same(a: &ClippedShape, b: &ClippedShape) -> bool {
    if a.clip_rect != b.clip_rect || a.transform_after_tessellation != b.transform_after_tessellation {
        return false;
    }
    same_shape(&a.shape, &b.shape)
}

fn same_shape(a: &Shape, b: &Shape) -> bool {
    match (a, b) {
        (Shape::Text(x), Shape::Text(y)) => {
            x.pos == y.pos
                && x.underline == y.underline
                && x.fallback_color == y.fallback_color
                && x.override_text_color == y.override_text_color
                && x.opacity_factor == y.opacity_factor
                && x.angle == y.angle
                && (Arc::ptr_eq(&x.galley, &y.galley) || x.galley == y.galley)
        }
        (Shape::Mesh(x), Shape::Mesh(y)) => Arc::ptr_eq(x, y) || x == y,
        (Shape::Vec(x), Shape::Vec(y)) => x.len() == y.len() && x.iter().zip(y).all(|(a, b)| same_shape(a, b)),
        (Shape::Callback(_), _) | (_, Shape::Callback(_)) => false,
        (x, y) => x == y,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use egui::{Color32, CornerRadius, Rect, pos2, vec2};

    const SCREEN: [u32; 2] = [320, 200];

    fn fill(x: f32, y: f32, w: f32, h: f32, colour: Color32) -> ClippedShape {
        let everywhere = Rect::from_min_size(pos2(0.0, 0.0), vec2(4000.0, 4000.0));
        ClippedShape::new(everywhere, Shape::rect_filled(Rect::from_min_size(pos2(x, y), vec2(w, h)), CornerRadius::ZERO, colour))
    }

    fn frame(shapes: &[ClippedShape]) -> Vec<ClippedShape> {
        shapes.to_vec()
    }

    #[test]
    fn only_the_squares_a_changed_shape_reaches_are_drawn_again() {
        let mut d = Damage::default();
        let none = HashSet::new();
        // The ground, and a playhead one pixel wide.
        let mut shapes = vec![fill(0.0, 0.0, 320.0, 200.0, Color32::BLACK), fill(100.0, 0.0, 1.0, 200.0, Color32::WHITE)];
        assert!(d.frame(frame(&shapes), 1.0, SCREEN, &none, false), "the first frame is all new");
        assert_eq!(d.changed(), vec![[0, 0, 320, 200]]);
        d.shown();
        assert!(!d.frame(frame(&shapes), 1.0, SCREEN, &none, false), "nothing moved: no frame");
        // The playhead moves on by a pixel: its column of squares.
        shapes[1] = fill(101.0, 0.0, 1.0, 200.0, Color32::WHITE);
        assert!(d.frame(frame(&shapes), 1.0, SCREEN, &none, false));
        assert_eq!(d.changed(), vec![[96, 0, 128, 200]]);
        assert_eq!(d.fresh_count(), 7, "one column of 7 squares, of 70");
        d.shown();
        // Over the line between two columns: both.
        shapes[1] = fill(127.0, 0.0, 2.0, 200.0, Color32::WHITE);
        d.frame(frame(&shapes), 1.0, SCREEN, &none, false);
        assert_eq!(d.changed(), vec![[96, 0, 160, 200]]);
    }

    #[test]
    fn a_buffer_frames_old_is_brought_up_to_date_with_their_changes() {
        let mut d = Damage::default();
        let none = HashSet::new();
        let ground = fill(0.0, 0.0, 320.0, 200.0, Color32::BLACK);
        let at = |x: f32| vec![ground.clone(), fill(x, 10.0, 4.0, 4.0, Color32::RED)];
        d.frame(at(10.0), 1.0, SCREEN, &none, false);
        d.shown();
        d.frame(at(200.0), 1.0, SCREEN, &none, false);
        d.shown();
        d.frame(at(300.0), 1.0, SCREEN, &none, false);
        // This frame: the square left at 200 and the one reached at 300.
        assert_eq!(d.to_draw(1), vec![[192, 0, 224, 32], [288, 0, 320, 32]]);
        // Two frames old: the square left at 10 too.
        assert_eq!(d.to_draw(2).len(), 3);
        assert_eq!(d.to_draw(2)[0], [0, 0, 32, 32]);
        // Of unknown age, or older than the changes kept: all of it.
        assert_eq!(d.to_draw(0), vec![[0, 0, 320, 200]]);
        assert_eq!(d.to_draw(9), vec![[0, 0, 320, 200]]);
    }

    #[test]
    fn a_new_size_or_scale_or_a_changed_picture_is_drawn_again() {
        let mut d = Damage::default();
        let none = HashSet::new();
        let shapes = vec![fill(0.0, 0.0, 320.0, 200.0, Color32::BLACK)];
        d.frame(frame(&shapes), 1.0, SCREEN, &none, false);
        d.shown();
        assert!(d.frame(frame(&shapes), 1.5, SCREEN, &none, false), "scaled");
        assert_eq!(d.to_draw(1), vec![[0, 0, 320, 200]], "all of it, and no older changes count");
        d.shown();
        assert!(d.frame(frame(&shapes), 1.5, [400, 200], &none, false), "resized");
        d.shown();
        assert!(d.frame(frame(&shapes), 1.5, [400, 200], &none, true), "asked for all");
        d.shown();
        // A picture whose texture got new pixels, drawn the same.
        let texture = TextureId::User(7);
        let picture = ClippedShape::new(
            Rect::EVERYTHING,
            Shape::image(texture, Rect::from_min_size(pos2(40.0, 40.0), vec2(20.0, 20.0)), Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0)), Color32::WHITE),
        );
        let shapes = vec![shapes[0].clone(), picture];
        d.frame(frame(&shapes), 1.0, SCREEN, &none, false);
        d.shown();
        assert!(!d.frame(frame(&shapes), 1.0, SCREEN, &none, false));
        assert!(d.frame(frame(&shapes), 1.0, SCREEN, &HashSet::from([texture]), false));
        assert_eq!(d.changed(), vec![[32, 32, 64, 64]], "the square of the picture");
    }

    #[test]
    fn a_live_part_painted_again_changes_the_squares_a_whole_frame_would() {
        let none = HashSet::new();
        let ground = fill(0.0, 0.0, 320.0, 200.0, Color32::BLACK);
        let mark = |n: u32, end: bool| {
            let mut p = crate::live::Parts::default();
            let ctx = egui::Context::default();
            let painter = egui::Painter::new(ctx.clone(), egui::LayerId::background(), Rect::EVERYTHING);
            if end {
                p.list.push((egui::LayerId::background(), Rect::EVERYTHING, crate::live::Part::Clock { rect: Rect::NOTHING }));
                p.end(&painter, n);
            } else {
                p.begin(&painter, crate::live::Part::Clock { rect: Rect::NOTHING });
            }
            ctx.graphics_mut(|g| g.entry(egui::LayerId::background()).all_entries().next().cloned().unwrap())
        };
        let at = |x: f32| vec![ground.clone(), mark(0, false), fill(x, 10.0, 4.0, 4.0, Color32::RED), mark(0, true), fill(150.0, 150.0, 8.0, 8.0, Color32::WHITE)];
        let (mut whole, mut live) = (Damage::default(), Damage::default());
        for d in [&mut whole, &mut live] {
            d.frame(at(10.0), 1.0, SCREEN, &none, false);
            d.shown();
        }
        // The part moves twice: the same squares as a whole frame, each time.
        for x in [200.0, 40.0] {
            assert!(whole.frame(at(x), 1.0, SCREEN, &none, false));
            assert!(live.replay(vec![(0, vec![fill(x, 10.0, 4.0, 4.0, Color32::RED)])], false));
            assert_eq!(live.changed(), whole.changed());
            assert_eq!(live.bins, whole.bins, "each square keeps the shapes in it");
            whole.shown();
            live.shown();
        }
        // The same again: nothing to draw. More shapes: as a whole frame.
        assert!(!live.replay(vec![(0, vec![fill(40.0, 10.0, 4.0, 4.0, Color32::RED)])], false));
        assert!(live.replay(vec![(0, vec![fill(40.0, 10.0, 4.0, 4.0, Color32::RED), fill(90.0, 90.0, 4.0, 4.0, Color32::RED)])], false));
        assert_eq!(live.shapes.len(), 6);
    }

    #[test]
    fn many_changes_are_joined_into_few_rectangles() {
        let mut d = Damage::default();
        let none = HashSet::new();
        let screen = [1600, 960];
        let ground = fill(0.0, 0.0, 1600.0, 960.0, Color32::BLACK);
        // Thirty meters apart, each a few pixels: they all move.
        let meters = |h: f32| std::iter::once(ground.clone()).chain((0..30).map(|i| fill(i as f32 * 52.0 + 4.0, 900.0 - h, 6.0, h, Color32::GREEN))).collect::<Vec<_>>();
        d.frame(meters(100.0), 1.0, screen, &none, false);
        d.shown();
        d.frame(meters(120.0), 1.0, screen, &none, false);
        let rects = d.changed();
        assert!(rects.len() <= MOST_RECTS, "{} rectangles", rects.len());
        for (i, a) in rects.iter().enumerate() {
            assert!(rects[i + 1..].iter().all(|b| !meets(*a, *b)), "no two overlap: {rects:?}");
        }
        let area: i64 = rects.iter().map(|r| (r[2] - r[0]) as i64 * (r[3] - r[1]) as i64).sum();
        assert!(area < 1600 * 960 / 4, "far less than the screen: {area} pixels");
        // Each meter is in one of them.
        for i in 0..30 {
            let x = i * 52 + 6;
            assert!(rects.iter().any(|r| r[0] <= x && x < r[2] && r[1] <= 790 && 790 < r[3]), "meter {i}");
        }
        assert_eq!(d.shapes_in([0, 0, 40, 960]).len(), 2, "the ground and the first meter");
    }
}
