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

#[derive(Clone, Default, PartialEq)]
pub struct Grid {
    pub width: u16,
    pub height: u16,
    pub cells: Vec<Cell>,
}

impl Grid {
    pub fn new(width: u16, height: u16) -> Self {
        Self {
            width,
            height,
            cells: vec![Cell::default(); width as usize * height as usize],
        }
    }

    pub fn resize(&mut self, width: u16, height: u16) {
        *self = Self::new(width, height);
    }

    pub fn clear(&mut self) {
        self.cells.fill(Cell::default());
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
        for y in area.y..area.y + area.h {
            for x in area.x..area.x + area.w {
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
}

pub enum Highlight {
    Style(Style),
    /// Use whatever another group is set to.
    Link(String),
}

impl Highlights {
    pub fn set(&mut self, name: &str, highlight: Highlight) {
        self.groups.insert(name.to_string(), highlight);
    }

    /// The style of a group, following links. Unknown groups have no effect.
    pub fn get(&self, name: &str) -> Style {
        let mut name = name;
        for _ in 0..8 {
            match self.groups.get(name) {
                Some(Highlight::Style(style)) => return *style,
                Some(Highlight::Link(target)) => name = target,
                None => break,
            }
        }
        Style::default()
    }
}
