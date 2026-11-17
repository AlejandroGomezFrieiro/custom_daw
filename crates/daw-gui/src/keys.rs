//! Key presses in the notation of the kernel's key mappings: `a`, `<CR>`,
//! `<C-r>`, `<S-Left>`. Every key goes to the kernel whenever no text box
//! in the window has the keyboard, so the window is driven exactly as the
//! terminal is.

use egui::{Event, Key, Modifiers};

/// The name of a key that has one in the mappings' notation.
fn named(key: Key, shift: bool) -> Option<&'static str> {
    Some(match key {
        Key::Escape => "Esc",
        Key::Enter => "CR",
        Key::Backspace => "BS",
        Key::Tab if shift => "S-Tab",
        Key::Tab => "Tab",
        Key::Delete => "Del",
        Key::ArrowUp => "Up",
        Key::ArrowDown => "Down",
        Key::ArrowLeft => "Left",
        Key::ArrowRight => "Right",
        Key::Home => "Home",
        Key::End => "End",
        Key::PageUp => "PageUp",
        Key::PageDown => "PageDown",
        Key::Insert => "Insert",
        Key::Space => "Space",
        Key::F1 => "F1",
        Key::F2 => "F2",
        Key::F3 => "F3",
        Key::F4 => "F4",
        Key::F5 => "F5",
        Key::F6 => "F6",
        Key::F7 => "F7",
        Key::F8 => "F8",
        Key::F9 => "F9",
        Key::F10 => "F10",
        Key::F11 => "F11",
        Key::F12 => "F12",
        _ => return None,
    })
}

/// Turns the window's input events into keys for the mappings. A key held
/// with Control or Alt is written from its key event, and the text the
/// system may send after it is not sent again.
#[derive(Default)]
pub struct Keys {
    skip_text: bool,
}

impl Keys {
    /// The keys of a frame's events. Text the system sends with a key held
    /// with Control or Alt comes in the same frame as the key.
    pub fn notations(&mut self, events: &[Event]) -> Vec<String> {
        let keys = events.iter().filter_map(|e| self.notation(e)).collect();
        self.skip_text = false;
        keys
    }

    fn notation(&mut self, event: &Event) -> Option<String> {
        match event {
            Event::Key { key, pressed: true, modifiers, .. } => {
                self.skip_text = false;
                let keys = key_notation(*key, *modifiers)?;
                // Text that comes with it is the same key.
                self.skip_text = modifiers.ctrl || modifiers.alt || named(*key, false).is_some();
                Some(keys)
            }
            Event::Text(text) | Event::Ime(egui::ImeEvent::Commit(text)) => {
                if std::mem::take(&mut self.skip_text) {
                    return None;
                }
                text_notation(text)
            }
            _ => None,
        }
    }
}

/// Typed text: a character as itself, `<` as `<lt>`; composed text whole.
pub fn text_notation(text: &str) -> Option<String> {
    if text.is_empty() || text == " " {
        return None;
    }
    // Control characters are keys, sent as their key events.
    if text.chars().any(|c| (c as u32) < 0x20 || c == '\u{7f}') {
        return None;
    }
    Some(text.replace('<', "<lt>"))
}

/// A key pressed: named keys with what is held, and with Control or Alt the
/// character on the key. Plain characters come as text instead.
pub fn key_notation(key: Key, modifiers: Modifiers) -> Option<String> {
    let mut prefix = String::new();
    if modifiers.ctrl {
        prefix.push_str("C-");
    }
    if modifiers.alt {
        prefix.push_str("A-");
    }
    if let Some(name) = named(key, modifiers.shift) {
        // Shift is part of `S-Tab` already.
        if modifiers.shift && name != "S-Tab" {
            prefix.push_str("S-");
        }
        return Some(format!("<{prefix}{name}>"));
    }
    if !(modifiers.ctrl || modifiers.alt) {
        return None;
    }
    // The minus key's symbol is the true minus sign; the mappings write `-`.
    let symbol = if key == Key::Minus { "-" } else { key.symbol_or_name() };
    let mut chars = symbol.chars();
    let c = chars.next()?;
    if chars.next().is_some() {
        return None;
    }
    // Letters as the mappings write them, small; `<` as `lt`.
    let c = if c.is_ascii_alphabetic() { c.to_ascii_lowercase().to_string() } else if c == '<' { "lt".into() } else { c.to_string() };
    Some(format!("<{prefix}{c}>"))
}

/// Keys the window gives a meaning of its own, as other programs do, before
/// they go to the kernel's key mappings: in the piano roll Ctrl-A chooses
/// every note (`gA`) rather than raising the note under the cursor.
pub fn window_keys(keys: String, in_roll: bool) -> String {
    if in_roll && keys == "<C-a>" { "gA".to_string() } else { keys }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(key: Key, modifiers: Modifiers) -> Event {
        Event::Key { key, physical_key: None, pressed: true, repeat: false, modifiers }
    }

    #[test]
    fn keys_are_written_as_mappings_write_them() {
        let mut keys = Keys::default();
        let mut all = |events: &[Event]| keys.notations(events);
        // A letter comes as its key and its text: the text is what counts.
        assert_eq!(all(&[key(Key::A, Modifiers::NONE), Event::Text("a".into())]), ["a"]);
        assert_eq!(all(&[key(Key::R, Modifiers::CTRL)]), ["<C-r>"]);
        assert_eq!(all(&[key(Key::Space, Modifiers::NONE), Event::Text(" ".into())]), ["<Space>"]);
        assert_eq!(all(&[Event::Text("<".into())]), ["<lt>"]);
        assert_eq!(all(&[key(Key::Enter, Modifiers::NONE)]), ["<CR>"]);
        assert_eq!(all(&[key(Key::Tab, Modifiers::SHIFT)]), ["<S-Tab>"]);
        assert_eq!(all(&[key(Key::ArrowLeft, Modifiers::SHIFT)]), ["<S-Left>"]);
        // Alt and a letter, and the text the system sends with it once.
        assert_eq!(all(&[key(Key::X, Modifiers::ALT), Event::Text("x".into())]), ["<A-x>"]);
        assert_eq!(all(&[Event::Text("3".into()), key(Key::A, Modifiers::CTRL)]), ["3", "<C-a>"]);
        assert_eq!(all(&[Event::Text("É".into())]), ["É"]);
        assert_eq!(all(&[key(Key::Minus, Modifiers::CTRL)]), ["<C-->"]);
    }

    #[test]
    fn ctrl_a_chooses_every_note_in_the_piano_roll_only() {
        assert_eq!(window_keys("<C-a>".into(), true), "gA");
        assert_eq!(window_keys("<C-a>".into(), false), "<C-a>");
        assert_eq!(window_keys("x".into(), true), "x");
    }
}
