//! Pixels in the terminal: the surfaces views show their drawings in
//! (`buf:surface`), made into pixels here, in the frontend, at this
//! terminal's cell size, and shown as kitty graphics placements.
//!
//! A surface is cut into pieces (whole cells, at the barlines its drawing
//! marks), each a terminal image kept by the hash of its pixels, so that an
//! edit sends again only the pieces it touched and nothing else is sent at
//! all. A piece is painted again only when an operation reaching into it
//! changed. What covers part of a surface (a menu, a floating view) is
//! left out of the placements, never relied on to hide them.
//!
//! The drawing's overlay (cursor, selection, playhead, the note under the
//! pointer: its layers other than the page) is an image of its own above
//! the page where the terminal is known to layer images well (herdr,
//! kitty, Ghostty), so it moves without the page being sent again; in any
//! other terminal (WezTerm) it is baked into the pieces it crosses.

use std::collections::HashMap;
use std::sync::Arc;

use daw_core::grid::{Grid, Surface};
use daw_raster::kitty::{Images, Place, Transfer};
use daw_raster::tiles::{self, Cells};
use daw_raster::{Drawing, Layers, straight_rgba};
use serde_json::Value;

/// What is known of one surface's drawing.
struct Shown {
    ops: Arc<Value>,
    drawing: Drawing,
    /// A piece's key ([`Drawing::piece_key`]) and the hash of its pixels,
    /// or nothing for a piece with nothing in it.
    pieces: HashMap<u64, Option<u64>>,
}

pub struct Graphics {
    images: Images,
    /// The terminal puts images above text well: the overlay is an image
    /// of its own (a sprite) rather than baked into the page.
    pub layered: bool,
    surfaces: HashMap<String, Shown>,
}

impl Graphics {
    pub fn new(transfer: Transfer, layered: bool) -> Self {
        Self {
            images: Images::new(transfer),
            layered,
            surfaces: HashMap::new(),
        }
    }

    /// Delete every image: on a change of size and when leaving.
    pub fn clear(&mut self, out: &mut Vec<u8>) {
        self.images.clear(out);
        self.surfaces.clear();
    }

    /// Place the surfaces of a grid that has just been drawn, after its
    /// cells: `written(x, y)` says whether the cell at a screen position
    /// was written in this frame, which takes an image away from it in
    /// some terminals, so whatever is placed there is placed again.
    pub fn frame(&mut self, out: &mut Vec<u8>, grid: &Grid, written: impl Fn(i32, i32) -> bool) {
        self.images.begin();
        for surface in &grid.surfaces {
            self.surface(out, surface, &written);
        }
        self.surfaces.retain(|name, _| grid.surfaces.iter().any(|s| &s.name == name));
        self.images.end(out);
    }

    fn surface(&mut self, out: &mut Vec<u8>, surface: &Surface, written: &impl Fn(i32, i32) -> bool) {
        let (cw, ch) = surface.cell;
        let (cols, rows) = (surface.rect.w.max(0) as u16, surface.rect.h.max(0) as u16);
        if cw == 0 || ch == 0 || cols == 0 || rows == 0 {
            return;
        }
        let shown = self.surfaces.entry(surface.name.clone()).or_insert_with(|| Shown {
            ops: Arc::default(),
            drawing: Drawing::default(),
            pieces: HashMap::new(),
        });
        if !Arc::ptr_eq(&shown.ops, &surface.ops) && *shown.ops != *surface.ops {
            shown.drawing = Drawing::parse(&surface.ops);
        }
        shown.ops = surface.ops.clone();
        // Pieces cached for drawings long gone are forgotten now and then.
        if shown.pieces.len() > 4096 {
            shown.pieces.clear();
        }
        let covered = surface.covered.iter().any(|c| *c);
        // Over a menu a sprite would show through it: baked while covered.
        let sprite = self.layered && !covered;
        let layers = if sprite { Layers::Page } else { Layers::Both };
        for tile in tiles::tiles(cols, rows, (cw, ch), &shown.drawing.cuts) {
            let area = [
                (tile.col * cw) as f32,
                (tile.row * ch) as f32,
                (tile.cols * cw) as f32,
                (tile.rows * ch) as f32,
            ];
            let key = shown.drawing.piece_key(area, layers);
            let image = match shown.pieces.get(&key).copied().flatten().and_then(|h| self.images.known(h)) {
                Some(id) => Some(id),
                None if shown.pieces.get(&key) == Some(&None) => None,
                None => {
                    let pixmap = shown.drawing.paint_piece(area, layers);
                    let rgba = pixmap.as_ref().map(straight_rgba).unwrap_or_default();
                    // Nothing drawn in it: nothing to show.
                    if rgba.chunks_exact(4).all(|px| px[3] == 0) {
                        shown.pieces.insert(key, None);
                        None
                    } else {
                        let (w, h) = (area[2] as u32, area[3] as u32);
                        shown.pieces.insert(key, Some(daw_raster::kitty::hash(&rgba, w, h)));
                        Some(self.images.image(out, &rgba, w, h))
                    }
                }
            };
            let Some(image) = image else { continue };
            for part in tiles::uncovered(tile, |c, r| surface.is_covered(c, r)) {
                let at = (surface.rect.x + part.col as i32, surface.rect.y + part.row as i32);
                let again = (0..part.rows as i32)
                    .any(|r| (0..part.cols as i32).any(|c| written(at.0 + c, at.1 + r)));
                let place = Place {
                    image,
                    src: [
                        ((part.col - tile.col) * cw) as u32,
                        ((part.row - tile.row) * ch) as u32,
                        (part.cols * cw) as u32,
                        (part.rows * ch) as u32,
                    ],
                    at: (at.0 as u16, at.1 as u16),
                    offset: (0, 0),
                    z: 0,
                };
                self.images.place(out, &placement(&surface.name, part), place, again);
            }
        }
        if sprite && let Some(area) = shown.drawing.overlay_box() {
            // Inside the surface only.
            let right = (area[0] + area[2]).min((cols * cw) as f32);
            let bottom = (area[1] + area[3]).min((rows * ch) as f32);
            let area = [area[0], area[1], right - area[0], bottom - area[1]];
            if area[2] >= 1.0 && area[3] >= 1.0 {
                let pixmap = shown.drawing.paint_piece(area, Layers::Overlay);
                let rgba = pixmap.as_ref().map(straight_rgba).unwrap_or_default();
                let (w, h) = (area[2] as u32, area[3] as u32);
                let image = self.images.image(out, &rgba, w, h);
                let (x, y) = (area[0] as u16, area[1] as u16);
                let place = Place {
                    image,
                    src: [0, 0, w, h],
                    at: ((surface.rect.x as u16) + x / cw, (surface.rect.y as u16) + y / ch),
                    offset: (x % cw, y % ch),
                    z: 1,
                };
                self.images.place(out, &format!("{}/overlay", surface.name), place, false);
            }
        }
    }
}

/// The name a part of a surface is placed under.
fn placement(surface: &str, part: Cells) -> String {
    format!("{surface}/{},{},{},{}", part.col, part.row, part.cols, part.rows)
}

/// Whether the cell at a screen position shows a surface's pixels: the
/// terminal's cursor is not shown there.
pub fn under_pixels(grid: &Grid, x: u16, y: u16) -> bool {
    grid.surfaces.iter().any(|s| {
        let (col, row) = (x as i32 - s.rect.x, y as i32 - s.rect.y);
        col >= 0 && row >= 0 && col < s.rect.w && row < s.rect.h && !s.is_covered(col as u16, row as u16)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use daw_core::grid::{Rect, Style};
    use serde_json::json;

    fn grid_with(ops: Value) -> Grid {
        let mut grid = Grid::new(20, 6);
        let index = grid.surface("notation", Rect { x: 2, y: 1, w: 8, h: 4 }, (10, 20)).unwrap();
        grid.surfaces[index].ops = Arc::new(ops);
        grid
    }

    fn page() -> Value {
        json!([
            ["r", 0, 0, 80, 1, "#ffffff", "", 1, 0],
            ["r", 0, 60, 50, 1, "#ffffff", "", 1, 0],
            ["cut", 40, 0, 80],
            ["layer", "cursor"],
            ["r", 12, 0, 2, 80, "#ff0000", "", 1, 0],
        ])
    }

    fn text(out: &[u8]) -> String {
        String::from_utf8_lossy(out).into_owned()
    }

    fn placements(out: &str) -> Vec<&str> {
        out.split("\x1b_G").filter(|c| c.starts_with("a=p")).collect()
    }

    #[test]
    fn a_surface_is_shown_in_pieces_cut_at_its_barline_and_sent_once() {
        let mut graphics = Graphics::new(Transfer::Zlib, false);
        let grid = grid_with(page());
        let mut out = Vec::new();
        graphics.frame(&mut out, &grid, |_, _| false);
        let sent = text(&out);
        // Two pieces, either side of the barline at 40 px (column 4).
        assert_eq!(sent.matches("a=t,").count(), 2, "{sent:?}");
        let placed = placements(&sent);
        assert_eq!(placed.len(), 2);
        assert!(sent.contains("\x1b[2;3H\x1b_Ga=p,i=1,p=1,x=0,y=0,w=40,h=80,z=0,C=1,q=2"), "{sent:?}");
        assert!(sent.contains("\x1b[2;7H\x1b_Ga=p,i=2,p=2,x=0,y=0,w=40,h=80,z=0,C=1,q=2"));

        // The same drawing again: nothing at all.
        out.clear();
        graphics.frame(&mut out, &grid_with(page()), |_, _| false);
        assert!(out.is_empty(), "{:?}", text(&out));
    }

    #[test]
    fn a_baked_cursor_moving_sends_only_the_piece_it_is_in() {
        let mut graphics = Graphics::new(Transfer::Zlib, false);
        let mut out = Vec::new();
        graphics.frame(&mut out, &grid_with(page()), |_, _| false);
        out.clear();
        let mut moved = page();
        moved[4][1] = json!(20);
        graphics.frame(&mut out, &grid_with(moved), |_, _| false);
        let sent = text(&out);
        assert_eq!(sent.matches("a=t,").count(), 1, "one piece sent: {sent:?}");
        assert!(sent.contains("\x1b_Ga=d,d=i,i=1,p=1,q=2\x1b\\\x1b[2;3H\x1b_Ga=p,i=3,p=1,"), "{sent:?}");
        assert!(!sent.contains("i=2"), "the other piece untouched");
    }

    #[test]
    fn where_images_layer_well_the_cursor_is_a_sprite_above_the_page() {
        let mut graphics = Graphics::new(Transfer::Zlib, true);
        let mut out = Vec::new();
        graphics.frame(&mut out, &grid_with(page()), |_, _| false);
        let sent = text(&out);
        // Two pieces of the page and the cursor, 2 px wide at x 12: in
        // column 1 of the surface, 2 px into it, above the page.
        assert_eq!(sent.matches("a=t,").count(), 3);
        assert!(sent.contains("\x1b[2;4H\x1b_Ga=p,i=3,p=3,x=0,y=0,w=2,h=80,X=2,Y=0,z=1,C=1,q=2"), "{sent:?}");
        out.clear();
        let mut moved = page();
        moved[4][1] = json!(25);
        graphics.frame(&mut out, &grid_with(moved), |_, _| false);
        // The same pixels moved: placed again, nothing sent.
        assert_eq!(text(&out), "\x1b[2;5H\x1b_Ga=p,i=3,p=3,x=0,y=0,w=2,h=80,X=5,Y=0,z=1,C=1,q=2\x1b\\");
    }

    #[test]
    fn what_a_menu_covers_is_left_out_and_shown_again_when_it_goes() {
        let mut graphics = Graphics::new(Transfer::Zlib, true);
        let mut out = Vec::new();
        let mut grid = grid_with(page());
        // A menu over the surface's columns 1 to 2, rows 1 to 2.
        let clip = grid.rect();
        grid.text(clip, 3, 2, "ab", Style::default());
        grid.text(clip, 3, 3, "cd", Style::default());
        graphics.frame(&mut out, &grid, |_, _| false);
        let sent = text(&out);
        assert!(!sent.contains("z=1"), "no sprite over a menu: baked");
        // The left piece around the menu: a row above, one left, one
        // right, a row below; the right piece whole.
        assert_eq!(placements(&sent).len(), 5, "{sent:?}");
        assert!(sent.contains("\x1b[3;3H\x1b_Ga=p,i=1,p=2,x=0,y=20,w=10,h=40,"), "{sent:?}");
        assert!(sent.contains("\x1b[3;6H\x1b_Ga=p,i=1,p=3,x=30,y=20,w=10,h=40,"));
        assert!(under_pixels(&grid, 2, 1) && !under_pixels(&grid, 3, 2));

        // The menu closes: its cells are written blank, the whole piece
        // is placed and the parts are taken away.
        out.clear();
        graphics.frame(&mut out, &grid_with(page()), |x, y| (3..5).contains(&x) && (2..4).contains(&y));
        let sent = text(&out);
        assert!(sent.contains("w=40,h=80,z=0"), "{sent:?}");
        assert!(sent.matches("a=d,d=i").count() >= 4);
    }

    #[test]
    fn cells_written_under_a_placement_have_it_placed_again() {
        let mut graphics = Graphics::new(Transfer::Zlib, false);
        let mut out = Vec::new();
        graphics.frame(&mut out, &grid_with(page()), |_, _| false);
        out.clear();
        graphics.frame(&mut out, &grid_with(page()), |x, y| (x, y) == (8, 2));
        assert_eq!(
            text(&out),
            "\x1b_Ga=d,d=i,i=2,p=2,q=2\x1b\\\x1b[2;7H\x1b_Ga=p,i=2,p=2,x=0,y=0,w=40,h=80,z=0,C=1,q=2\x1b\\"
        );
    }

    #[test]
    fn a_surface_that_goes_takes_its_images_with_it() {
        let mut graphics = Graphics::new(Transfer::Zlib, false);
        let mut out = Vec::new();
        graphics.frame(&mut out, &grid_with(page()), |_, _| false);
        out.clear();
        graphics.frame(&mut out, &Grid::new(20, 6), |_, _| false);
        assert_eq!(text(&out).matches("a=d,d=i").count(), 2);
        out.clear();
        graphics.clear(&mut out);
        assert_eq!(text(&out), "\x1b_Ga=d,d=A,q=2\x1b\\");
    }
}
