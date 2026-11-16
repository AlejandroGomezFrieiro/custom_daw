//! The terminal frontend: shows the kernel's grid and turns terminal events
//! into kernel input.

use std::io::{BufWriter, Stdout, Write, stdout};

use anyhow::Result;
use crossterm::event::{
    self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent,
    MouseEventKind,
};
use crossterm::style::{
    Attribute, Color as TermColor, Print, SetAttribute, SetBackgroundColor, SetForegroundColor,
};
use crossterm::{cursor, execute, queue, terminal};
use daw_core::grid::{self, Cell, Color, Grid};
use daw_core::{Frontend, InputEvent};

pub struct Terminal {
    out: BufWriter<Stdout>,
    /// What is on screen now, to send only the cells that changed.
    shown: Option<Grid>,
}

impl Terminal {
    /// Take over the terminal and start handing its events to `send`, which
    /// says whether anyone is still listening: the kernel in this program,
    /// or a connection to one somewhere else.
    pub fn start(send: impl Fn(InputEvent) -> bool + Send + 'static) -> Result<(Self, u16, u16)> {
        terminal::enable_raw_mode()?;
        execute!(
            stdout(),
            terminal::EnterAlternateScreen,
            event::EnableMouseCapture,
            event::EnableBracketedPaste,
            cursor::Hide
        )?;
        let (width, height) = terminal::size()?;
        std::thread::spawn(move || {
            while let Ok(event) = event::read() {
                let input = match event {
                    Event::Key(key) if key.kind != KeyEventKind::Release => {
                        key_notation(key).map(InputEvent::Key)
                    }
                    Event::Mouse(mouse) => Some(mouse_event(mouse)),
                    Event::Resize(width, height) => Some(InputEvent::Resize(width, height)),
                    Event::Paste(text) => Some(InputEvent::Paste(text)),
                    _ => None,
                };
                if let Some(input) = input
                    && !send(input)
                {
                    break;
                }
            }
        });
        Ok((
            Self {
                out: BufWriter::with_capacity(1 << 16, stdout()),
                shown: None,
            },
            width,
            height,
        ))
    }
}

/// Give the terminal back. Safe to call more than once.
pub fn restore() {
    let _ = execute!(
        stdout(),
        event::DisableBracketedPaste,
        event::DisableMouseCapture,
        terminal::LeaveAlternateScreen,
        cursor::Show
    );
    let _ = terminal::disable_raw_mode();
}

impl Drop for Terminal {
    fn drop(&mut self) {
        restore();
    }
}

fn term_color(color: Color) -> TermColor {
    match color {
        Color::Default => TermColor::Reset,
        Color::Indexed(index) => TermColor::AnsiValue(index),
        Color::Rgb(r, g, b) => TermColor::Rgb { r, g, b },
    }
}

impl Frontend for Terminal {
    fn present(&mut self, grid: &Grid, cursor_at: Option<(u16, u16)>) -> Result<()> {
        let same_size = self
            .shown
            .as_ref()
            .is_some_and(|s| (s.width, s.height) == (grid.width, grid.height));
        if !same_size {
            self.shown = None;
            queue!(self.out, terminal::Clear(terminal::ClearType::All))?;
        }
        queue!(self.out, terminal::BeginSynchronizedUpdate, cursor::Hide)?;

        // The style and position the terminal is currently in.
        let mut style: Option<(Color, Color, u8)> = None;
        let mut at: Option<(u16, u16)> = None;
        let width = grid.width as usize;
        for (index, cell) in grid.cells.iter().enumerate() {
            let unchanged = self.shown.as_ref().is_some_and(|s| s.cells[index] == *cell);
            if unchanged || cell.ch == '\0' {
                continue;
            }
            let (x, y) = ((index % width) as u16, (index / width) as u16);
            if at != Some((x, y)) {
                queue!(self.out, cursor::MoveTo(x, y))?;
            }
            if style != Some((cell.fg, cell.bg, cell.attrs)) {
                self.set_style(cell)?;
                style = Some((cell.fg, cell.bg, cell.attrs));
            }
            queue!(self.out, Print(cell.ch))?;
            let wide = grid
                .cells
                .get(index + 1)
                .is_some_and(|next| next.ch == '\0');
            at = Some((x + if wide { 2 } else { 1 }, y));
        }
        queue!(self.out, SetAttribute(Attribute::Reset))?;
        if let Some((x, y)) = cursor_at {
            queue!(self.out, cursor::MoveTo(x, y), cursor::Show)?;
        }
        queue!(self.out, terminal::EndSynchronizedUpdate)?;
        self.out.flush()?;
        self.shown = Some(grid.clone());
        Ok(())
    }
}

impl Terminal {
    fn set_style(&mut self, cell: &Cell) -> Result<()> {
        queue!(
            self.out,
            SetAttribute(Attribute::Reset),
            SetForegroundColor(term_color(cell.fg)),
            SetBackgroundColor(term_color(cell.bg))
        )?;
        let attributes = [
            (grid::BOLD, Attribute::Bold),
            (grid::DIM, Attribute::Dim),
            (grid::ITALIC, Attribute::Italic),
            (grid::UNDERLINE, Attribute::Underlined),
            (grid::REVERSE, Attribute::Reverse),
            (grid::STRIKE, Attribute::CrossedOut),
        ];
        for (bit, attribute) in attributes {
            if cell.attrs & bit != 0 {
                queue!(self.out, SetAttribute(attribute))?;
            }
        }
        Ok(())
    }
}

/// A key press in Neovim notation, or `None` for keys that are not bindable.
fn key_notation(key: KeyEvent) -> Option<String> {
    let mods = key.modifiers;
    let (name, is_char) = match key.code {
        KeyCode::Char(' ') => ("Space".to_string(), false),
        KeyCode::Char('<') => ("lt".to_string(), false),
        KeyCode::Char(c) => (c.to_string(), true),
        KeyCode::Enter => ("CR".to_string(), false),
        KeyCode::Esc => ("Esc".to_string(), false),
        KeyCode::Backspace => ("BS".to_string(), false),
        KeyCode::Tab => ("Tab".to_string(), false),
        KeyCode::BackTab => ("S-Tab".to_string(), false),
        KeyCode::Left => ("Left".to_string(), false),
        KeyCode::Right => ("Right".to_string(), false),
        KeyCode::Up => ("Up".to_string(), false),
        KeyCode::Down => ("Down".to_string(), false),
        KeyCode::Home => ("Home".to_string(), false),
        KeyCode::End => ("End".to_string(), false),
        KeyCode::PageUp => ("PageUp".to_string(), false),
        KeyCode::PageDown => ("PageDown".to_string(), false),
        KeyCode::Delete => ("Del".to_string(), false),
        KeyCode::Insert => ("Insert".to_string(), false),
        KeyCode::F(n) => (format!("F{n}"), false),
        _ => return None,
    };
    let mut prefix = String::new();
    if mods.contains(KeyModifiers::CONTROL) {
        prefix.push_str("C-");
    }
    if mods.contains(KeyModifiers::ALT) {
        prefix.push_str("A-");
    }
    // Shift is already part of a typed character, and of `S-Tab`.
    if mods.contains(KeyModifiers::SHIFT) && !is_char && key.code != KeyCode::BackTab {
        prefix.push_str("S-");
    }
    Some(if prefix.is_empty() && is_char {
        name
    } else {
        format!("<{prefix}{name}>")
    })
}

fn mouse_event(mouse: MouseEvent) -> InputEvent {
    let button = |b: MouseButton| match b {
        MouseButton::Left => "left",
        MouseButton::Right => "right",
        MouseButton::Middle => "middle",
    };
    let (kind, button) = match mouse.kind {
        MouseEventKind::Down(b) => ("down", button(b)),
        MouseEventKind::Up(b) => ("up", button(b)),
        MouseEventKind::Drag(b) => ("drag", button(b)),
        MouseEventKind::Moved => ("move", ""),
        MouseEventKind::ScrollUp => ("scroll_up", ""),
        MouseEventKind::ScrollDown => ("scroll_down", ""),
        MouseEventKind::ScrollLeft => ("scroll_left", ""),
        MouseEventKind::ScrollRight => ("scroll_right", ""),
    };
    let mut mods = String::new();
    for (flag, letter) in [
        (KeyModifiers::CONTROL, 'C'),
        (KeyModifiers::ALT, 'A'),
        (KeyModifiers::SHIFT, 'S'),
    ] {
        if mouse.modifiers.contains(flag) {
            mods.push(letter);
        }
    }
    InputEvent::Mouse {
        kind: kind.into(),
        button: button.into(),
        x: mouse.column,
        y: mouse.row,
        mods,
    }
}
