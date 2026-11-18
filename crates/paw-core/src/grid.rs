//! The screen: a grid of styled character cells that Lua draws into and
//! frontends display. This is the whole contract between the UI code and
//! whatever is showing it.

use std::collections::HashMap;

pub use paw_scene::cells::{
    BOLD, Cell, Color, DIM, ITALIC, REVERSE, Rect, Run, STRIKE, Style, UNDERLINE, hex, rgb,
};

/// What a terminal can show besides cells, as its frontend found out when
/// it started (or a remote one said with `ui.attach`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Caps {
    /// Images by the kitty graphics protocol.
    pub graphics: bool,
    /// The size of a cell in pixels; 0 when the terminal does not say.
    pub cell: (u16, u16),
    /// The pointer reported in pixels (mode 1016).
    pub pixel_mouse: bool,
    /// The terminal's own foreground and background colours, when it said.
    pub fg: Option<(u8, u8, u8)>,
    pub bg: Option<(u8, u8, u8)>,
    /// Strips can be placed under the text (a negative z): in any terminal
    /// that shows images. Where a coloured background would hide them
    /// (Konsole), the terminal's frontend paints it into the picture.
    pub under: bool,
}

impl Caps {
    /// Whether a view can be shown in pixels on this terminal.
    pub fn pixels(&self) -> bool {
        self.graphics && self.cell.0 > 0 && self.cell.1 > 0
    }

    pub fn to_json(&self) -> serde_json::Value {
        let colour = |c: Option<(u8, u8, u8)>| c.map(hex);
        serde_json::json!({
            "graphics": self.graphics, "cell": [self.cell.0, self.cell.1],
            "pixel_mouse": self.pixel_mouse, "fg": colour(self.fg), "bg": colour(self.bg),
            "under": self.under,
        })
    }

    pub fn from_json(value: &serde_json::Value) -> Caps {
        let colour = |v: &serde_json::Value| match v.as_str().and_then(Color::parse) {
            Some(Color::Rgb(r, g, b)) => Some((r, g, b)),
            _ => None,
        };
        let size = |v: &serde_json::Value| v.as_u64().unwrap_or(0).min(1000) as u16;
        Caps {
            graphics: value["graphics"].as_bool().unwrap_or(false),
            cell: (size(&value["cell"][0]), size(&value["cell"][1])),
            pixel_mouse: value["pixel_mouse"].as_bool().unwrap_or(false),
            fg: colour(&value["fg"]),
            bg: colour(&value["bg"]),
            under: value["under"].as_bool().unwrap_or(false),
        }
    }
}

/// Cells a view shows pixels in (a strip, `buf:strip`, or `buf:surface`):
/// its drawing, the operations of `paw.canvas`, for the frontend to make
/// into pixels at `cell` pixels a cell, and which of its cells something
/// drawn after it covers (a menu, a floating view), where the pixels must
/// not show.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Surface {
    /// What the strip is: images and their placements are kept by it, so
    /// two strips of one view, or one view in two windows, are apart.
    pub key: String,
    pub rect: Rect,
    pub cell: (u16, u16),
    /// Placed under the text: its cells are drawn by the view as usual and
    /// show above the picture.
    pub under: bool,
    /// A flag for each cell, row by row.
    pub covered: Vec<bool>,
    pub ops: std::sync::Arc<serde_json::Value>,
    /// Still being drawn by its view ([`Grid::seal_surfaces`]): what is
    /// written in its cells now is the view's own, not something over it.
    pub open: bool,
    /// How many cells of the whole strip are left of and above what shows
    /// (`rect`), when part of it is off its window: a clip scrolled in.
    pub offset: (i32, i32),
    /// The whole strip's size in cells, when part of it is off its window;
    /// (0, 0) when all of it shows. Its drawing is of the whole, so that
    /// scrolling it moves pieces already made.
    pub whole: (i32, i32),
}

impl Surface {
    /// The whole strip's size in cells: what shows, and what is off its window.
    pub fn whole(&self) -> (i32, i32) {
        if self.whole == (0, 0) { (self.rect.w, self.rect.h) } else { self.whole }
    }

    pub fn is_covered(&self, col: u16, row: u16) -> bool {
        self.covered
            .get(row as usize * self.rect.w.max(0) as usize + col as usize)
            .copied()
            .unwrap_or(false)
    }

    /// Covered cells as runs along rows: `[col, row, cols]` each, from the
    /// surface's corner.
    pub fn covered_runs(&self) -> Vec<[u16; 3]> {
        let w = self.rect.w.max(0) as usize;
        let mut out = Vec::new();
        for (row, cells) in self.covered.chunks(w.max(1)).enumerate() {
            let mut col = 0;
            while col < cells.len() {
                if cells[col] {
                    let start = col;
                    while col < cells.len() && cells[col] {
                        col += 1;
                    }
                    out.push([start as u16, row as u16, (col - start) as u16]);
                } else {
                    col += 1;
                }
            }
        }
        out
    }
}

#[derive(Clone, Default, PartialEq)]
pub struct Grid {
    pub width: u16,
    pub height: u16,
    pub cells: Vec<Cell>,
    /// The terminal keeps the pointer for its own selection instead of
    /// reporting it (`paw.opt.mouse` off); set by the runtime as it draws.
    pub mouse_off: bool,
    pub surfaces: Vec<Surface>,
}

impl Grid {
    pub fn new(width: u16, height: u16) -> Self {
        Self {
            width,
            height,
            cells: vec![Cell::default(); width as usize * height as usize],
            mouse_off: false,
            surfaces: Vec::new(),
        }
    }

    pub fn resize(&mut self, width: u16, height: u16) {
        *self = Self::new(width, height);
    }

    pub fn clear(&mut self) {
        self.cells.fill(Cell::default());
        self.surfaces.clear();
    }

    /// Keep a rectangle of cells for pixels, under the name `key`. Over
    /// the text (`under` false) its cells are made blank, in the terminal's
    /// own colours, so that nothing in them breaks the image; under the
    /// text they are left to the view, which goes on drawing them until it
    /// is done ([`Grid::seal_surfaces`]). Returns the surface's index, or
    /// nothing when the rectangle is off the screen.
    pub fn surface(&mut self, key: &str, area: Rect, cell: (u16, u16), under: bool) -> Option<usize> {
        let area = area.intersect(&self.rect());
        if area.w <= 0 || area.h <= 0 {
            return None;
        }
        if !under {
            // Covered by one shown later, a surface already there shows less.
            self.fill(area, area, Some(' '), Style { fg: Some(Color::Default), bg: Some(Color::Default), on: 0, off: 0xff });
        }
        self.surfaces.push(Surface {
            key: key.to_string(),
            rect: area,
            cell,
            under,
            covered: vec![false; (area.w * area.h) as usize],
            ops: Default::default(),
            open: under,
            offset: (0, 0),
            whole: (0, 0),
        });
        Some(self.surfaces.len() - 1)
    }

    /// [`Grid::surface`] for the part of `whole` inside `clip` that is on
    /// the screen, keeping where that part is in the whole.
    pub fn surface_part(&mut self, key: &str, whole: Rect, clip: Rect, cell: (u16, u16), under: bool) -> Option<usize> {
        let index = self.surface(key, whole.intersect(&clip), cell, under)?;
        let s = &mut self.surfaces[index];
        s.offset = (s.rect.x - whole.x, s.rect.y - whole.y);
        if (s.rect.w, s.rect.h) != (whole.w, whole.h) {
            s.whole = (whole.w, whole.h);
        }
        Some(index)
    }

    /// The view that kept the open surfaces is done: what is written over
    /// them from now on (a menu, a floating view) covers them.
    pub fn seal_surfaces(&mut self) {
        for surface in &mut self.surfaces {
            surface.open = false;
        }
    }

    pub fn rect(&self) -> Rect {
        Rect {
            x: 0,
            y: 0,
            w: self.width as i32,
            h: self.height as i32,
        }
    }

    /// Draw text starting at `(x, y)`, keeping inside `clip`. Returns how many
    /// columns the text takes, whether or not all of it was visible.
    pub fn text(&mut self, clip: Rect, x: i32, y: i32, text: &str, style: Style) -> i32 {
        let surfaces = &mut self.surfaces;
        paw_scene::cells::write_text(&mut self.cells, self.width, clip, x, y, text, style, |x, y| cover(surfaces, x, y))
    }

    /// Restyle an area and, when `ch` is given, overwrite its characters.
    pub fn fill(&mut self, clip: Rect, area: Rect, ch: Option<char>, style: Style) {
        let surfaces = &mut self.surfaces;
        paw_scene::cells::write_fill(&mut self.cells, self.width, clip, area, ch, style, |x, y| cover(surfaces, x, y))
    }

    /// The grid as rows of runs of one style each, with the terminal's own
    /// colours given as `fg` and `bg`.
    pub fn runs(&self, fg: (u8, u8, u8), bg: (u8, u8, u8)) -> Vec<Vec<Run>> {
        paw_scene::cells::runs(&self.cells, self.width, fg, bg)
    }
}

/// Mark the cell at `(x, y)` covered in any surface it is in.
fn cover(surfaces: &mut [Surface], x: i32, y: i32) {
    for surface in surfaces {
        let r = surface.rect;
        if !surface.open && r.contains(x, y) {
            surface.covered[((y - r.y) * r.w + (x - r.x)) as usize] = true;
        }
    }
}

/// Named styles, so that views say what something is and themes say how it looks.
#[derive(Default)]
pub struct Highlights {
    groups: HashMap<String, Highlight>,
    /// Groups as they were defined in 24-bit colour, where the terminal is
    /// shown a nearer form of them: what a window draws.
    full: HashMap<String, Highlight>,
    /// Read the 24-bit forms while set: while a view is drawn for a window.
    pub full_colour: bool,
}

pub enum Highlight {
    Style(Style),
    /// Use whatever another group is set to.
    Link(String),
}

impl Highlights {
    pub fn set(&mut self, name: &str, highlight: Highlight) {
        self.groups.insert(name.to_string(), highlight);
        self.full.remove(name);
    }

    /// Set a group's 24-bit form beside the one the terminal is shown.
    pub fn set_full(&mut self, name: &str, highlight: Highlight) {
        self.full.insert(name.to_string(), highlight);
    }

    /// The style of a group, following links. Unknown groups have no effect.
    pub fn get(&self, name: &str) -> Style {
        let mut name = name;
        for _ in 0..8 {
            let full = self.full_colour.then(|| self.full.get(name)).flatten();
            match full.or_else(|| self.groups.get(name)) {
                Some(Highlight::Style(style)) => return *style,
                Some(Highlight::Link(target)) => name = target,
                None => break,
            }
        }
        Style::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rows_become_runs_of_one_style_with_colours_resolved() {
        let mut grid = Grid::new(8, 2);
        let clip = grid.rect();
        let red = Style {
            fg: Some(Color::Rgb(255, 0, 0)),
            ..Style::default()
        };
        grid.text(clip, 0, 0, "ab", red);
        grid.text(clip, 2, 0, "界c", Style { on: REVERSE, ..red });
        let bold_dim = Style {
            fg: Some(Color::Indexed(196)),
            on: BOLD | DIM,
            ..Style::default()
        };
        grid.text(clip, 0, 1, "x", bold_dim);
        let runs = grid.runs((200, 200, 200), (0, 0, 0));
        assert_eq!(runs[0].len(), 3);
        assert_eq!((runs[0][0].text.as_str(), runs[0][0].fg.as_str(), runs[0][0].w), ("ab", "#ff0000", 2));
        // Reversed: the terminal's background in front and red behind; the
        // wide character takes two columns.
        let run = &runs[0][1];
        assert_eq!((run.text.as_str(), run.fg.as_str(), run.bg.as_str()), ("界c", "#000000", "#ff0000"));
        assert_eq!((run.x, run.w), (2, 3));
        assert_eq!((runs[0][2].x, runs[0][2].w, runs[0][2].fg.as_str()), (5, 3, "#c8c8c8"));
        // Indexed 196 is xterm's red, dimmed halfway to the background.
        assert_eq!((runs[1][0].fg.as_str(), runs[1][0].attrs), ("#7f0000", BOLD));
    }

    #[test]
    fn a_strip_under_the_text_keeps_the_views_cells_and_is_covered_only_after() {
        let mut grid = Grid::new(10, 4);
        let clip = grid.rect();
        let lane = Style { bg: Some(Color::Rgb(1, 2, 3)), ..Style::default() };
        grid.fill(clip, clip, Some(' '), lane);
        let area = Rect { x: 1, y: 1, w: 6, h: 2 };
        grid.surface("curve:1", area, (10, 20), false).unwrap();
        // Over the text: blank, in the terminal's colours.
        assert_eq!(grid.cells[11], Cell::default());
        grid.surfaces.clear();
        grid.fill(clip, clip, Some(' '), lane);
        grid.surface("curve:1", area, (10, 20), true).unwrap();
        assert_eq!(grid.cells[11].bg, Color::Rgb(1, 2, 3), "under the text the cells stay");
        // The view's own cursor and points: drawn, and not covers.
        grid.text(clip, 2, 1, "+", Style::default());
        assert_eq!(grid.cells[12].ch, '+');
        assert!(grid.surfaces[0].covered.iter().all(|c| !c));
        // Once the view is done, a menu over it covers it.
        grid.seal_surfaces();
        grid.text(clip, 3, 2, "ok", Style::default());
        assert_eq!(grid.surfaces[0].covered_runs(), vec![[2, 1, 2]]);
    }

    #[test]
    fn two_strips_side_by_side_are_each_covered_by_what_falls_in_them() {
        let mut grid = Grid::new(10, 4);
        let clip = grid.rect();
        grid.surface("a", Rect { x: 0, y: 0, w: 4, h: 2 }, (10, 20), false).unwrap();
        grid.surface("b", Rect { x: 4, y: 0, w: 4, h: 2 }, (10, 20), false).unwrap();
        grid.text(clip, 3, 1, "xy", Style::default());
        assert_eq!(grid.surfaces[0].covered_runs(), vec![[3, 1, 1]]);
        assert_eq!(grid.surfaces[1].covered_runs(), vec![[0, 1, 1]]);
    }

    #[test]
    fn full_colour_groups_are_read_only_when_asked_for() {
        let mut groups = Highlights::default();
        let style = |fg| Highlight::Style(Style { fg: Some(fg), ..Style::default() });
        groups.set("Normal", style(Color::Indexed(1)));
        groups.set_full("Normal", style(Color::Rgb(1, 2, 3)));
        groups.set("Text", Highlight::Link("Normal".into()));
        assert_eq!(groups.get("Text").fg, Some(Color::Indexed(1)));
        groups.full_colour = true;
        assert_eq!(groups.get("Text").fg, Some(Color::Rgb(1, 2, 3)));
    }
}
