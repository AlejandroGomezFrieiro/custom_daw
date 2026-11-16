//! The screen: a grid of styled character cells that Lua draws into and
//! frontends display. This is the whole contract between the UI code and
//! whatever is showing it.

use std::collections::HashMap;

use unicode_width::UnicodeWidthChar;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Color {
    /// The terminal's own foreground or background.
    #[default]
    Default,
    Indexed(u8),
    Rgb(u8, u8, u8),
}

impl Color {
    /// Parse `#rrggbb`, `#rgb`, a colour name, or `default`.
    pub fn parse(text: &str) -> Option<Color> {
        if let Some(hex) = text.strip_prefix('#') {
            let digit = |i: usize| u8::from_str_radix(hex.get(i..i + 1)?, 16).ok();
            let pair = |i: usize| u8::from_str_radix(hex.get(i..i + 2)?, 16).ok();
            return match hex.len() {
                6 => Some(Color::Rgb(pair(0)?, pair(2)?, pair(4)?)),
                3 => Some(Color::Rgb(digit(0)? * 17, digit(1)? * 17, digit(2)? * 17)),
                _ => None,
            };
        }
        const NAMES: [&str; 8] = [
            "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        ];
        let lower = text.to_ascii_lowercase();
        let (bright, base) = match lower.strip_prefix("bright") {
            Some(rest) => (8, rest.trim_start_matches(['_', '-'])),
            None => (0, lower.as_str()),
        };
        match base {
            "default" | "none" => Some(Color::Default),
            "gray" | "grey" => Some(Color::Indexed(8)),
            _ => NAMES
                .iter()
                .position(|n| *n == base)
                .map(|i| Color::Indexed(i as u8 + bright)),
        }
    }
}

pub const BOLD: u8 = 1;
pub const DIM: u8 = 2;
pub const ITALIC: u8 = 4;
pub const UNDERLINE: u8 = 8;
pub const REVERSE: u8 = 16;
pub const STRIKE: u8 = 32;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cell {
    /// `'\0'` marks the second half of a double-width character.
    pub ch: char,
    pub fg: Color,
    pub bg: Color,
    pub attrs: u8,
}

impl Default for Cell {
    fn default() -> Self {
        Self {
            ch: ' ',
            fg: Color::Default,
            bg: Color::Default,
            attrs: 0,
        }
    }
}

/// A change to apply to cells. Anything left `None` keeps what the cell had,
/// so text can be drawn over a background that was filled earlier.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Style {
    pub fg: Option<Color>,
    pub bg: Option<Color>,
    pub on: u8,
    pub off: u8,
}

impl Style {
    fn apply(&self, cell: &mut Cell) {
        if let Some(fg) = self.fg {
            cell.fg = fg;
        }
        if let Some(bg) = self.bg {
            cell.bg = bg;
        }
        cell.attrs = (cell.attrs | self.on) & !self.off;
    }
}

/// A rectangle of cells: position, then size.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    pub fn intersect(&self, other: &Rect) -> Rect {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        let right = (self.x + self.w).min(other.x + other.w);
        let bottom = (self.y + self.h).min(other.y + other.h);
        Rect {
            x,
            y,
            w: (right - x).max(0),
            h: (bottom - y).max(0),
        }
    }

    fn contains(&self, x: i32, y: i32) -> bool {
        x >= self.x && x < self.x + self.w && y >= self.y && y < self.y + self.h
    }
}

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
        }
    }
}

/// Cells a view shows pixels in (`buf:surface`): its drawing, the
/// operations of `daw.canvas.paint`, for the frontend to make into pixels
/// at `cell` pixels a cell, and which of its cells something drawn after
/// it covers (a menu, a floating view), where the pixels must not show.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Surface {
    pub name: String,
    pub rect: Rect,
    pub cell: (u16, u16),
    /// A flag for each cell, row by row.
    pub covered: Vec<bool>,
    pub ops: std::sync::Arc<serde_json::Value>,
}

impl Surface {
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
    /// reporting it (`daw.opt.mouse` off); set by the runtime as it draws.
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

    /// Keep a rectangle of cells for pixels: blank, in the terminal's own
    /// colours, so that nothing in them breaks the image. Returns the
    /// surface's index, or nothing when the rectangle is off the screen.
    pub fn surface(&mut self, name: &str, area: Rect, cell: (u16, u16)) -> Option<usize> {
        let area = area.intersect(&self.rect());
        if area.w <= 0 || area.h <= 0 {
            return None;
        }
        // Covered by one shown later, a surface already there shows less.
        self.fill(area, area, Some(' '), Style { fg: Some(Color::Default), bg: Some(Color::Default), on: 0, off: 0xff });
        self.surfaces.push(Surface {
            name: name.to_string(),
            rect: area,
            cell,
            covered: vec![false; (area.w * area.h) as usize],
            ops: Default::default(),
        });
        Some(self.surfaces.len() - 1)
    }

    /// Mark the cell at `(x, y)` covered in any surface it is in.
    fn cover(&mut self, x: i32, y: i32) {
        for surface in &mut self.surfaces {
            let r = surface.rect;
            if r.contains(x, y) {
                surface.covered[((y - r.y) * r.w + (x - r.x)) as usize] = true;
            }
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

    fn cell_mut(&mut self, x: i32, y: i32) -> &mut Cell {
        &mut self.cells[y as usize * self.width as usize + x as usize]
    }

    /// Draw text starting at `(x, y)`, keeping inside `clip`. Returns how many
    /// columns the text takes, whether or not all of it was visible.
    pub fn text(&mut self, clip: Rect, x: i32, y: i32, text: &str, style: Style) -> i32 {
        let clip = clip.intersect(&self.rect());
        let mut col = x;
        for ch in text.chars() {
            let width = ch.width().unwrap_or(0) as i32;
            if width == 0 {
                continue;
            }
            if clip.contains(col, y) && clip.contains(col + width - 1, y) {
                if !self.surfaces.is_empty() {
                    self.cover(col, y);
                    self.cover(col + width - 1, y);
                }
                let cell = self.cell_mut(col, y);
                cell.ch = ch;
                style.apply(cell);
                if width == 2 {
                    let rest = self.cell_mut(col + 1, y);
                    rest.ch = '\0';
                    style.apply(rest);
                }
            }
            col += width;
        }
        col - x
    }

    /// Restyle an area and, when `ch` is given, overwrite its characters.
    pub fn fill(&mut self, clip: Rect, area: Rect, ch: Option<char>, style: Style) {
        let area = area.intersect(&clip).intersect(&self.rect());
        let cover = !self.surfaces.is_empty();
        for y in area.y..area.y + area.h {
            for x in area.x..area.x + area.w {
                if cover {
                    self.cover(x, y);
                }
                let cell = self.cell_mut(x, y);
                if let Some(ch) = ch {
                    cell.ch = ch;
                }
                style.apply(cell);
            }
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

/// A colour as red, green and blue, with `default` for the terminal's own.
/// The 256 indexed colours are xterm's.
pub fn rgb(color: Color, default: (u8, u8, u8)) -> (u8, u8, u8) {
    const BASE: [(u8, u8, u8); 16] = [
        (0x00, 0x00, 0x00),
        (0xcd, 0x31, 0x31),
        (0x0d, 0xbc, 0x79),
        (0xe5, 0xe5, 0x10),
        (0x24, 0x72, 0xc8),
        (0xbc, 0x3f, 0xbc),
        (0x11, 0xa8, 0xcd),
        (0xe5, 0xe5, 0xe5),
        (0x66, 0x66, 0x66),
        (0xf1, 0x4c, 0x4c),
        (0x23, 0xd1, 0x8b),
        (0xf5, 0xf5, 0x43),
        (0x3b, 0x8e, 0xea),
        (0xd6, 0x70, 0xd6),
        (0x29, 0xb8, 0xdb),
        (0xff, 0xff, 0xff),
    ];
    match color {
        Color::Default => default,
        Color::Rgb(r, g, b) => (r, g, b),
        Color::Indexed(i) if i < 16 => BASE[i as usize],
        Color::Indexed(i) if i < 232 => {
            let level = |n: u8| if n == 0 { 0 } else { 55 + 40 * n };
            let i = i - 16;
            (level(i / 36), level(i / 6 % 6), level(i % 6))
        }
        Color::Indexed(i) => {
            let grey = 8 + 10 * (i - 232);
            (grey, grey, grey)
        }
    }
}

fn hex((r, g, b): (u8, u8, u8)) -> String {
    format!("#{r:02x}{g:02x}{b:02x}")
}

/// A stretch of a row in one style, for a frontend that draws text rather
/// than cells: the column it starts at and how many it takes, its text, its
/// colours as `#rrggbb`, and what is left of its attributes (bold, italic,
/// underline, strike). Reverse and dim are already in its colours.
#[derive(Clone, Debug, PartialEq, serde::Serialize)]
pub struct Run {
    pub x: u16,
    pub w: u16,
    pub text: String,
    pub fg: String,
    pub bg: String,
    pub attrs: u8,
}

impl Grid {
    /// The grid as rows of runs of one style each, with the terminal's own
    /// colours given as `fg` and `bg`.
    pub fn runs(&self, fg: (u8, u8, u8), bg: (u8, u8, u8)) -> Vec<Vec<Run>> {
        let width = self.width.max(1) as usize;
        self.cells
            .chunks(width)
            .map(|row| {
                let mut runs: Vec<Run> = Vec::new();
                for (x, cell) in row.iter().enumerate() {
                    let (mut front, mut back) = (rgb(cell.fg, fg), rgb(cell.bg, bg));
                    if cell.attrs & REVERSE != 0 {
                        (front, back) = (back, front);
                    }
                    if cell.attrs & DIM != 0 {
                        let mix = |a: u8, b: u8| ((a as u16 + b as u16) / 2) as u8;
                        front = (mix(front.0, back.0), mix(front.1, back.1), mix(front.2, back.2));
                    }
                    let attrs = cell.attrs & (BOLD | ITALIC | UNDERLINE | STRIKE);
                    let (front, back) = (hex(front), hex(back));
                    match runs.last_mut() {
                        Some(run) if run.fg == front && run.bg == back && run.attrs == attrs => {
                            run.w += 1;
                            if cell.ch != '\0' {
                                run.text.push(cell.ch);
                            }
                        }
                        // The second half of a wide character goes with its first.
                        Some(run) if cell.ch == '\0' => run.w += 1,
                        _ => runs.push(Run {
                            x: x as u16,
                            w: 1,
                            text: if cell.ch == '\0' { String::new() } else { cell.ch.to_string() },
                            fg: front,
                            bg: back,
                            attrs,
                        }),
                    }
                }
                runs
            })
            .collect()
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
