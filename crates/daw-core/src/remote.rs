//! The terminal UI shown somewhere else: the kernel's screen sent over a
//! connection as the cells that changed, and put together again there.
//!
//! `ui.attach` makes a connection a frontend like the program's own
//! terminal: after every turn that changed the screen it is pushed a
//! `ui.grid` event,
//!
//!   { "w": 120, "h": 40, "full": false, "cursor": [x, y] or null,
//!     "runs": [ [x, y, "text", fg, bg, attrs], ... ] }
//!
//! where a run is a stretch of cells of one style on one row, colours are
//! `null` (the terminal's own), a number (one of its 256) or `"#rrggbb"`,
//! and `attrs` are the bits of [`crate::grid`]. `full` says that the screen
//! is to be cleared first (the first event, and after a change of size).
//! The other side keeps a [`Grid`] and gives each event to [`apply`].

use anyhow::{Result, bail};
use serde_json::{Value, json};

use crate::grid::{Cell, Color, Grid, Style};
use crate::kernel::{Frontend, InputEvent};
use crate::rpc::{ClientId, Clients};

fn color_json(color: Color) -> Value {
    match color {
        Color::Default => Value::Null,
        Color::Indexed(index) => json!(index),
        Color::Rgb(r, g, b) => json!(format!("#{r:02x}{g:02x}{b:02x}")),
    }
}

fn color_of(value: &Value) -> Color {
    if let Some(index) = value.as_u64() {
        return Color::Indexed(index.min(255) as u8);
    }
    let hex = value.as_str().and_then(|s| s.strip_prefix('#'));
    match hex.and_then(|hex| u32::from_str_radix(hex, 16).ok()) {
        Some(rgb) => Color::Rgb((rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8),
        None => Color::Default,
    }
}

/// The cells of `grid` that differ from `shown` (all of them without it),
/// as runs of one style.
pub fn runs(grid: &Grid, shown: Option<&Grid>) -> Vec<Value> {
    let width = grid.width as usize;
    let mut out = Vec::new();
    // The run being gathered: where it starts, its style, its text, and the
    // column after its last cell.
    let mut run: Option<(usize, usize, Cell, String, usize)> = None;
    let mut close = |run: &mut Option<(usize, usize, Cell, String, usize)>| {
        if let Some((x, y, cell, text, _)) = run.take() {
            out.push(json!([
                x,
                y,
                text,
                color_json(cell.fg),
                color_json(cell.bg),
                cell.attrs
            ]));
        }
    };
    for (index, cell) in grid.cells.iter().enumerate() {
        let (x, y) = (index % width.max(1), index / width.max(1));
        // The second half of a wide character goes with its first.
        if cell.ch == '\0' {
            if let Some(run) = &mut run {
                run.4 = x + 1;
            }
            continue;
        }
        let wide = grid.cells.get(index + 1).is_some_and(|next| next.ch == '\0');
        let unchanged = shown.is_some_and(|shown| {
            shown.cells[index] == *cell
                && (!wide || shown.cells.get(index + 1).is_some_and(|c| c.ch == '\0'))
        });
        let joins = run.as_ref().is_some_and(|(_, row, style, _, next)| {
            *row == y
                && *next == x
                && (style.fg, style.bg, style.attrs) == (cell.fg, cell.bg, cell.attrs)
        });
        if unchanged {
            close(&mut run);
            continue;
        }
        if !joins {
            close(&mut run);
            run = Some((x, y, *cell, String::new(), x));
        }
        if let Some(run) = &mut run {
            run.3.push(cell.ch);
            run.4 = x + 1;
        }
    }
    close(&mut run);
    out
}

/// Put a `ui.grid` event into the grid kept on the receiving side. Returns
/// where the cursor is.
pub fn apply(grid: &mut Grid, payload: &Value) -> Result<Option<(u16, u16)>> {
    let (Some(width), Some(height)) = (payload["w"].as_u64(), payload["h"].as_u64()) else {
        bail!("a screen without a size");
    };
    let (width, height) = (width.min(1000) as u16, height.min(1000) as u16);
    if payload["full"].as_bool().unwrap_or(false) || (grid.width, grid.height) != (width, height) {
        *grid = Grid::new(width, height);
    }
    let clip = grid.rect();
    for run in payload["runs"].as_array().into_iter().flatten() {
        let (Some(x), Some(y), Some(text)) = (run[0].as_i64(), run[1].as_i64(), run[2].as_str())
        else {
            continue;
        };
        let attrs = run[5].as_u64().unwrap_or(0) as u8;
        let style = Style {
            fg: Some(color_of(&run[3])),
            bg: Some(color_of(&run[4])),
            on: attrs,
            off: !attrs,
        };
        grid.text(clip, x as i32, y as i32, text, style);
    }
    let cursor = &payload["cursor"];
    Ok(match (cursor[0].as_u64(), cursor[1].as_u64()) {
        (Some(x), Some(y)) => Some((x as u16, y as u16)),
        _ => None,
    })
}

/// A frontend at the other end of a connection.
pub struct RemoteFrontend {
    client: ClientId,
    clients: Clients,
    /// What that side shows now, to send only what changed.
    shown: Option<Grid>,
    cursor: Option<(u16, u16)>,
}

impl RemoteFrontend {
    pub fn new(client: ClientId, clients: Clients) -> Self {
        Self {
            client,
            clients,
            shown: None,
            cursor: None,
        }
    }
}

impl Frontend for RemoteFrontend {
    fn present(&mut self, grid: &Grid, cursor: Option<(u16, u16)>) -> Result<()> {
        let same_size = self
            .shown
            .as_ref()
            .is_some_and(|s| (s.width, s.height) == (grid.width, grid.height));
        let shown = self.shown.as_ref().filter(|_| same_size);
        let runs = runs(grid, shown);
        if runs.is_empty() && same_size && cursor == self.cursor {
            return Ok(());
        }
        let payload = json!({
            "w": grid.width, "h": grid.height, "full": !same_size,
            "cursor": cursor.map(|(x, y)| json!([x, y])), "runs": runs,
        });
        if !self.clients.push(self.client, "ui.grid", &payload) {
            bail!("connection {} is gone", self.client);
        }
        self.shown = Some(grid.clone());
        self.cursor = cursor;
        Ok(())
    }
}

/// What a remote terminal sends with `ui.input`, as the kernel takes input:
/// `{"key": "a"}`, `{"paste": "text"}`, `{"resize": [w, h]}`, or
/// `{"mouse": {"kind": "down", "button": "left", "x": 3, "y": 4, "mods": "C"}}`.
pub fn input_of(value: &Value) -> Option<InputEvent> {
    if let Some(key) = value["key"].as_str() {
        return Some(InputEvent::Key(key.to_string()));
    }
    if let Some(text) = value["paste"].as_str() {
        return Some(InputEvent::Paste(text.to_string()));
    }
    if let (Some(width), Some(height)) = (value["resize"][0].as_u64(), value["resize"][1].as_u64())
    {
        return Some(InputEvent::Resize(
            width.clamp(1, 1000) as u16,
            height.clamp(1, 1000) as u16,
        ));
    }
    let mouse = value.get("mouse")?;
    Some(InputEvent::Mouse {
        kind: mouse["kind"].as_str()?.to_string(),
        button: mouse["button"].as_str().unwrap_or("").to_string(),
        x: mouse["x"].as_u64()?.min(u16::MAX as u64) as u16,
        y: mouse["y"].as_u64()?.min(u16::MAX as u64) as u16,
        mods: mouse["mods"].as_str().unwrap_or("").to_string(),
    })
}

/// The other direction, for the program at the far end to send.
pub fn input_json(event: &InputEvent) -> Value {
    match event {
        InputEvent::Key(key) => json!({ "key": key }),
        InputEvent::Paste(text) => json!({ "paste": text }),
        InputEvent::Resize(width, height) => json!({ "resize": [width, height] }),
        InputEvent::Mouse {
            kind,
            button,
            x,
            y,
            mods,
        } => json!({ "mouse": { "kind": kind, "button": button, "x": x, "y": y, "mods": mods } }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::grid::{BOLD, Rect};

    fn painted() -> Grid {
        let mut grid = Grid::new(12, 3);
        let clip = grid.rect();
        let plain = Style::default();
        let loud = Style {
            fg: Some(Color::Rgb(255, 128, 0)),
            bg: Some(Color::Indexed(4)),
            on: BOLD,
            off: 0,
        };
        grid.text(clip, 0, 0, "tracks", plain);
        grid.text(clip, 2, 1, "音楽 ok", loud);
        grid.fill(
            clip,
            Rect {
                x: 0,
                y: 2,
                w: 12,
                h: 1,
            },
            Some('─'),
            loud,
        );
        grid
    }

    #[test]
    fn a_screen_sent_whole_is_the_same_screen_at_the_other_end() {
        let grid = painted();
        let payload = json!({ "w": 12, "h": 3, "full": true, "cursor": [3, 1], "runs": runs(&grid, None) });
        let mut far = Grid::new(1, 1);
        let cursor = apply(&mut far, &payload).unwrap();
        assert_eq!(cursor, Some((3, 1)));
        assert_eq!(far.cells, grid.cells, "every cell, wide characters included");
    }

    #[test]
    fn only_what_changed_is_sent_and_it_lands_where_it_belongs() {
        let before = painted();
        let mut after = before.clone();
        let clip = after.rect();
        after.text(clip, 3, 0, "X", Style::default());
        after.text(clip, 4, 1, "楽", Style { fg: Some(Color::Default), ..Style::default() });
        let changed = runs(&after, Some(&before));
        assert_eq!(changed.len(), 2, "two stretches changed: {changed:?}");
        assert_eq!(changed[0][2], "X");
        let mut far = before.clone();
        apply(&mut far, &json!({ "w": 12, "h": 3, "runs": changed })).unwrap();
        assert_eq!(far.cells, after.cells);
        assert!(runs(&after, Some(&after)).is_empty(), "nothing changed, nothing sent");
    }

    #[test]
    fn input_survives_the_trip() {
        for event in [
            InputEvent::Key("<C-s>".into()),
            InputEvent::Paste("two\nlines".into()),
            InputEvent::Resize(100, 30),
            InputEvent::Mouse {
                kind: "drag".into(),
                button: "left".into(),
                x: 7,
                y: 9,
                mods: "CS".into(),
            },
        ] {
            let back = input_of(&input_json(&event)).unwrap();
            assert_eq!(format!("{back:?}"), format!("{event:?}"));
        }
        assert!(input_of(&json!({ "nonsense": 1 })).is_none());
    }
}
