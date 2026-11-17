//! The terminal frontend: shows the kernel's grid and turns terminal events
//! into kernel input.

use std::io::{BufWriter, Read, Stdout, Write, stdout};
use std::os::fd::AsRawFd;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use crossterm::event::{
    self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent,
    MouseEventKind,
};
use crossterm::style::{
    Attribute, Color as TermColor, Print, SetAttribute, SetBackgroundColor, SetForegroundColor,
};
use crossterm::{cursor, execute, queue, terminal};
use daw_core::grid::{self, Caps, Cell, Color, Grid};
use daw_core::{Frontend, InputEvent};
use daw_raster::kitty;
use daw_raster::probe::{self, Probe};

use crate::graphics::{self, Graphics};

pub struct Terminal {
    out: BufWriter<Stdout>,
    /// What is on screen now, to send only the cells that changed.
    shown: Option<Grid>,
    /// Whether the terminal reports the pointer, or keeps it for its own
    /// selection (`daw.opt.mouse` off).
    mouse: bool,
    /// What the terminal said about itself at startup.
    probe: Probe,
    /// Images, when the terminal shows them.
    graphics: Option<Graphics>,
    /// What strips under the text had painted in, where backgrounds hide them.
    backing: graphics::Backing,
    /// A cell's size in pixels, as width << 16 | height, for the thread
    /// that reads the pointer in pixels.
    cell: Arc<AtomicU32>,
}

/// What [`restore`] sends, as plain bytes for a signal handler to write:
/// the pointer and pasting reported no more (crossterm's
/// `DisableMouseCapture` turns off 1006, 1015, 1003, 1002 and 1000; and
/// pixels, 1016), the normal screen back, the cursor shown.
const RESTORE: &[u8] =
    b"\x1b[?2004l\x1b[?1016l\x1b[?1006l\x1b[?1015l\x1b[?1003l\x1b[?1002l\x1b[?1000l\x1b[?1049l\x1b[?25h";

/// Images were shown: leaving deletes them, or they stay in the pane.
static IMAGES: AtomicBool = AtomicBool::new(false);

/// The terminal's settings before raw mode, for a signal handler to put back.
static COOKED: std::sync::OnceLock<libc::termios> = std::sync::OnceLock::new();

/// Killed (`kill`, a multiplexer closing the pane), the program would leave
/// the terminal reporting every move of the pointer to the shell. A handler
/// gives it back, then lets the signal end the program as it would have.
extern "C" fn on_signal(signal: libc::c_int) {
    unsafe {
        if IMAGES.load(Ordering::Relaxed) {
            libc::write(1, kitty::DELETE_ALL.as_ptr().cast(), kitty::DELETE_ALL.len());
        }
        libc::write(1, RESTORE.as_ptr().cast(), RESTORE.len());
        if let Some(cooked) = COOKED.get() {
            libc::tcsetattr(0, libc::TCSANOW, cooked);
        }
        libc::signal(signal, libc::SIG_DFL);
        libc::raise(signal);
    }
}

impl Terminal {
    /// Take over the terminal and start handing its events to `send`, which
    /// says whether anyone is still listening: the kernel in this program,
    /// or a connection to one somewhere else.
    pub fn start(send: impl Fn(InputEvent) -> bool + Send + 'static) -> Result<(Self, u16, u16)> {
        unsafe {
            let mut cooked: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(0, &mut cooked) == 0 {
                let _ = COOKED.set(cooked);
            }
            for signal in [libc::SIGTERM, libc::SIGHUP] {
                libc::signal(signal, on_signal as extern "C" fn(libc::c_int) as libc::sighandler_t);
            }
        }
        terminal::enable_raw_mode()?;
        // Asked before anything else reads what the terminal sends.
        let mut probe = ask();
        if let Some(cell) = cell_size() {
            probe.cell = Some(cell);
        }
        let graphics = probe.transfer.filter(|_| probe.cell.is_some()).map(|transfer| {
            IMAGES.store(true, Ordering::Relaxed);
            Graphics::new(transfer, probe.layered())
        });
        // The pointer in pixels, where views show pixels and it is known
        // how big a cell is.
        probe.pixel_mouse &= graphics.is_some();
        execute!(
            stdout(),
            terminal::EnterAlternateScreen,
            event::EnableMouseCapture,
            event::EnableBracketedPaste,
            cursor::Hide
        )?;
        if probe.pixel_mouse {
            stdout().write_all(PIXEL_MOUSE)?;
            stdout().flush()?;
        }
        let (width, height) = terminal::size()?;
        let (cw, ch) = probe.cell.unwrap_or((0, 0));
        let cell = Arc::new(AtomicU32::new((cw as u32) << 16 | ch as u32));
        let pixels = probe.pixel_mouse;
        let seen = cell.clone();
        std::thread::spawn(move || {
            while let Ok(event) = event::read() {
                let input = match event {
                    Event::Key(key) if key.kind != KeyEventKind::Release => {
                        key_notation(key).map(InputEvent::Key)
                    }
                    Event::Mouse(mouse) => {
                        let packed = seen.load(Ordering::Relaxed);
                        let cell = (pixels && packed != 0).then_some(((packed >> 16) as u16, packed as u16));
                        Some(mouse_event(mouse, cell))
                    }
                    Event::Resize(width, height) => {
                        // A font zoom or another monitor: cells of another size.
                        if let Some((w, h)) = cell_size() {
                            let packed = (w as u32) << 16 | h as u32;
                            if seen.swap(packed, Ordering::Relaxed) != packed && !send(InputEvent::CellSize(w, h)) {
                                break;
                            }
                        }
                        Some(InputEvent::Resize(width, height))
                    }
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
                mouse: true,
                probe,
                graphics,
                backing: graphics::Backing::default(),
                cell,
            },
            width,
            height,
        ))
    }

    /// What this terminal can show besides cells, for the kernel to know.
    pub fn caps(&self) -> Caps {
        let packed = self.cell.load(Ordering::Relaxed);
        Caps {
            graphics: self.graphics.is_some(),
            cell: ((packed >> 16) as u16, packed as u16),
            pixel_mouse: self.probe.pixel_mouse,
            fg: self.probe.fg,
            bg: self.probe.bg,
            under: self.graphics.is_some(),
        }
    }

    /// What the terminal said about itself, in a line, for the log.
    pub fn describe(&self) -> String {
        let p = &self.probe;
        let packed = self.cell.load(Ordering::Relaxed);
        format!(
            "terminal: {}; images {}; cell {}x{} px; pointer in pixels {}",
            p.version.as_deref().unwrap_or("unnamed"),
            match (&self.graphics, p.transfer) {
                (Some(g), Some(t)) => format!("by {t:?}, overlay {}", if g.layered { "as a sprite" } else { "baked" }),
                _ => "no".into(),
            },
            packed >> 16,
            packed & 0xffff,
            if p.pixel_mouse { "yes" } else { "no" },
        )
    }
}

/// Mode 1016: the pointer reported in pixels, in the form of 1006.
const PIXEL_MOUSE: &[u8] = b"\x1b[?1016h";

/// The size of a cell in pixels from the terminal's size, when it says.
fn cell_size() -> Option<(u16, u16)> {
    let size = terminal::window_size().ok()?;
    (size.columns > 0 && size.rows > 0 && size.width > 0 && size.height > 0)
        .then(|| (size.width / size.columns, size.height / size.rows))
}

/// Ask the terminal what it is and can do, and read the answers until the
/// one to DA1, which comes last, or a second and a half has gone by.
fn ask() -> Probe {
    let mut found = Probe::default();
    let Ok(mut tty) = std::fs::OpenOptions::new().read(true).open("/dev/tty") else {
        return found;
    };
    let mut queries = Vec::new();
    probe::queries(&mut queries);
    if stdout().write_all(&queries).and_then(|_| stdout().flush()).is_err() {
        kitty::probe_done();
        return found;
    }
    let (mut buf, mut graphics) = (Vec::new(), Vec::new());
    let deadline = Instant::now() + Duration::from_millis(1500);
    while !found.done && Instant::now() < deadline {
        let left = deadline.saturating_duration_since(Instant::now());
        let mut pfd = libc::pollfd { fd: tty.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        if unsafe { libc::poll(&mut pfd, 1, left.as_millis() as i32) } <= 0 {
            continue;
        }
        let mut chunk = [0u8; 4096];
        match tty.read(&mut chunk) {
            Ok(n) if n > 0 => buf.extend_from_slice(&chunk[..n]),
            _ => break,
        }
        found.hear(probe::parse(&mut buf), &mut graphics);
    }
    kitty::probe_done();
    found
}

/// Give the terminal back. Safe to call more than once.
pub fn restore() {
    if IMAGES.swap(false, Ordering::Relaxed) {
        let _ = stdout().write_all(kitty::DELETE_ALL);
        let _ = stdout().write_all(b"\x1b[?1016l");
    }
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
        if let Some(graphics) = &mut self.graphics {
            // What the terminal never read goes too.
            let mut bytes = Vec::new();
            graphics.clear(&mut bytes);
            let _ = self.out.write_all(&bytes);
            let _ = self.out.flush();
        }
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
        // Where a coloured background would hide a strip under the text,
        // the strip paints it instead.
        let backed = if self.graphics.is_some() && !self.probe.under() { self.backing.backed(grid) } else { None };
        let grid = backed.as_ref().unwrap_or(grid);
        let same_size = self
            .shown
            .as_ref()
            .is_some_and(|s| (s.width, s.height) == (grid.width, grid.height));
        let mut images = Vec::new();
        if !same_size {
            self.shown = None;
            // Images placed for the old size go before the screen is cleared.
            if let Some(graphics) = &mut self.graphics {
                graphics.clear(&mut images);
                self.out.write_all(&images)?;
                images.clear();
            }
            queue!(self.out, terminal::Clear(terminal::ClearType::All))?;
        }
        if grid.mouse_off == self.mouse {
            self.mouse = !grid.mouse_off;
            if self.mouse {
                queue!(self.out, event::EnableMouseCapture)?;
                if self.probe.pixel_mouse {
                    self.out.write_all(PIXEL_MOUSE)?;
                }
            } else {
                queue!(self.out, event::DisableMouseCapture)?;
            }
        }
        queue!(self.out, terminal::BeginSynchronizedUpdate, cursor::Hide)?;

        // The style and position the terminal is currently in.
        let mut style: Option<(Color, Color, u8)> = None;
        let mut at: Option<(u16, u16)> = None;
        let width = grid.width as usize;
        // Cells written in this frame, where a surface's pixels are placed again.
        let track = self.graphics.is_some();
        let mut written = vec![false; if track { grid.cells.len() } else { 0 }];
        for (index, cell) in grid.cells.iter().enumerate() {
            let unchanged = self.shown.as_ref().is_some_and(|s| s.cells[index] == *cell);
            if unchanged || cell.ch == '\0' {
                continue;
            }
            let (x, y) = ((index % width) as u16, (index / width) as u16);
            if track {
                written[index] = true;
            }
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
        if let Some(graphics) = &mut self.graphics {
            graphics.frame(&mut images, grid, |x, y| {
                x >= 0 && y >= 0 && (x as usize) < width && written.get(y as usize * width + x as usize) == Some(&true)
            });
            self.out.write_all(&images)?;
        }
        if let Some((x, y)) = cursor_at
            && !graphics::under_pixels(grid, x, y)
        {
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
        // A terminal sends Ctrl-\ Ctrl-] Ctrl-^ Ctrl-_ as the bytes 0x1c to
        // 0x1f, which crossterm reads as Ctrl-4 to Ctrl-7: they are the keys
        // that were pressed (`Ctrl-]` follows a link in help).
        KeyCode::Char(c @ '4'..='7') if mods.contains(KeyModifiers::CONTROL) => {
            (['\\', ']', '^', '_'][c as usize - '4' as usize].to_string(), true)
        }
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

/// A pointer event, in cells; with the terminal reporting pixels, `cell`
/// is a cell's size, which makes cells of them.
fn mouse_event(mouse: MouseEvent, cell: Option<(u16, u16)>) -> InputEvent {
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
    let (x, y, pixel) = match cell {
        Some((w, h)) => (mouse.column / w.max(1), mouse.row / h.max(1), Some((mouse.column, mouse.row))),
        None => (mouse.column, mouse.row, None),
    };
    InputEvent::Mouse {
        kind: kind.into(),
        button: button.into(),
        x,
        y,
        mods,
        pixel,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_and_a_bracket_is_that_key_not_a_digit() {
        let ctrl = |c| key_notation(KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL));
        assert_eq!(ctrl('5').as_deref(), Some("<C-]>"));
        assert_eq!(ctrl('4').as_deref(), Some("<C-\\>"));
        assert_eq!(ctrl('w').as_deref(), Some("<C-w>"));
        let five = key_notation(KeyEvent::new(KeyCode::Char('5'), KeyModifiers::NONE));
        assert_eq!(five.as_deref(), Some("5"));
    }
}
