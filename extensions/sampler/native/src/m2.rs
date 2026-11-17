//! The MIDI 2.0 Note-On Orchestral Articulation Profile (M2-123): codes
//! for articulations, names that map to them, and its fallback order.
//!
//! A code is `type << 16 | data` with the attribute type the
//! classification (0x10..0x1F) and the data `subclass:4 variation:4
//! direction:2 reserved:2 reset-round-robin:1 string:3`. Written as
//! `11.A` (classification 0x11, subclass A) or `11.A.2` with a variation.

use crate::model::Articulation;

/// Words in an articulation's name and the code they stand for; the
/// longest word found wins.
const VOCABULARY: &[(&str, u32)] = &[
    ("legato", 0x102),
    ("leg", 0x102),
    ("slur", 0x102),
    ("portamento", 0x104),
    ("gliss", 0x104),
    ("detache", 0x105),
    ("marcato", 0x106),
    ("marc", 0x106),
    ("martele", 0x107),
    ("non vib", 0x108),
    ("senza vib", 0x108),
    ("nv", 0x108),
    ("vib", 0x109),
    ("sustain", 0x100),
    ("sus", 0x100),
    ("long", 0x100),
    ("arco", 0x100),
    ("ordinario", 0x100),
    ("staccatissimo", 0x114),
    ("spiccato", 0x115),
    ("spicc", 0x115),
    ("sautille", 0x116),
    ("staccato", 0x110),
    ("stacc", 0x110),
    ("stac", 0x110),
    ("short", 0x110),
    ("portato", 0x119),
    ("tenuto", 0x118),
    ("bartok", 0x11B),
    ("snap", 0x11B),
    ("pizzicato", 0x11A),
    ("pizz", 0x11A),
    ("col legno", 0x11C),
    ("tremolo", 0x120),
    ("trem", 0x120),
    ("flutter", 0x120),
    ("growl", 0x121),
    ("double tongue", 0x124),
    ("triple tongue", 0x125),
    ("multitongued", 0x129),
    ("trill", 0x130),
    ("harmonics", 0x140),
    ("harmonic", 0x140),
    ("harm", 0x140),
    ("col legno tratto", 0x142),
    ("flautando", 0x143),
    ("flaut", 0x143),
    ("cuivre", 0x146),
    ("fall", 0x150),
    ("doit", 0x152),
    ("rip", 0x153),
    ("shake", 0x158),
    ("cresc", 0x159),
    ("decresc", 0x15A),
    ("dim", 0x15A),
    ("swell", 0x15B),
    ("sfz", 0x15D),
    ("run", 0x160),
    ("fx", 0x170),
    ("effects", 0x170),
];

/// The code a name stands for, by the words in it.
pub fn code_for_name(name: &str) -> Option<u32> {
    let text: String = name
        .to_lowercase()
        .replace(['_', '-'], " ")
        .replace('é', "e")
        .chars()
        .map(|c| if c.is_alphabetic() || c == ' ' { c } else { ' ' })
        .collect();
    let words: Vec<&str> = text.split_whitespace().collect();
    let joined = format!(" {} ", words.join(" "));
    // Trills: a minor second unless the name says major (`M2`, `maj`, `whole`).
    if joined.contains(" trill ") || joined.contains(" tr ") {
        let major = name.contains("M2") || joined.contains(" maj") || joined.contains(" whole");
        return Some(if major { 0x132000 } else { 0x130000 });
    }
    VOCABULARY
        .iter()
        .filter(|(word, _)| joined.contains(&format!(" {word} ")))
        .max_by_key(|(word, _)| word.len())
        .map(|&(_, code)| code << 12)
}

pub fn format_code(code: u32) -> String {
    let class = code >> 16;
    let subclass = (code >> 12) & 0xF;
    let variation = (code >> 8) & 0xF;
    if variation == 0 {
        format!("{class:X}.{subclass:X}")
    } else {
        format!("{class:X}.{subclass:X}.{variation:X}")
    }
}

pub fn parse_code(text: &str) -> Option<u32> {
    let mut parts = text.trim().split('.');
    let class = u32::from_str_radix(parts.next()?, 16).ok()?;
    let subclass = parts.next().map_or(Some(0), |s| u32::from_str_radix(s, 16).ok())?;
    let variation = parts.next().map_or(Some(0), |s| u32::from_str_radix(s, 16).ok())?;
    if !(0x10..=0x1F).contains(&class) || subclass > 15 || variation > 15 {
        return None;
    }
    Some(class << 16 | subclass << 12 | variation << 8)
}

/// The code an articulation answers to: its own, or a custom one
/// (classifications 0x1A..0x1F, which M2-123 leaves to each library)
/// given by its place, so that every articulation can be chosen by a
/// note's attribute.
pub fn code_of(arts: &[Articulation], index: usize) -> (u32, bool) {
    if let Some(code) = arts[index].m2 {
        return (code, false);
    }
    let unnamed = arts[..index].iter().filter(|a| a.m2.is_none()).count() as u32;
    let class = (0x1A + unnamed / 16).min(0x1F);
    (class << 16 | (unnamed % 16) << 12, true)
}

/// Every articulation's code, in order.
pub fn codes(arts: &[Articulation]) -> Vec<u32> {
    (0..arts.len()).map(|i| code_of(arts, i).0).collect()
}

/// The articulation a note's attribute chooses among `codes`, by
/// M2-123's fallback: the exact variation, another variation of the
/// subclass, subclass 0 of the classification, then 10.0. `None`: the
/// attribute chooses nothing and the note plays what the keyswitches
/// chose.
pub fn resolve(codes: &[u32], attr_type: u8, data: u16) -> Option<usize> {
    if !(0x10..=0x1F).contains(&attr_type) {
        return None;
    }
    let class = attr_type as u32;
    let subclass = (data as u32 >> 12) & 0xF;
    let variation = (data as u32 >> 8) & 0xF;
    let find = |want: &dyn Fn(u32) -> bool| codes.iter().position(|&c| want(c));
    find(&|c| c == class << 16 | subclass << 12 | variation << 8)
        .or_else(|| find(&|c| c >> 12 == class << 4 | subclass))
        .or_else(|| find(&|c| c >> 12 == class << 4))
        .or_else(|| find(&|c| c >> 12 == 0x100))
}

/// Whether the attribute asks for the round robin counters to start again.
pub fn resets_round_robin(attr_type: u8, data: u16) -> bool {
    (0x10..=0x1F).contains(&attr_type) && data & 0x8 != 0
}

/// A key's name, middle C being C4 = 60 as paw names it.
pub fn key_name(key: u8) -> String {
    const NAMES: [&str; 12] = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
    format!("{}{}", NAMES[key as usize % 12], key as i32 / 12 - 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn art(name: &str) -> Articulation {
        Articulation { name: name.into(), m2: code_for_name(name), keyswitch: None, mask: 0, values: 0 }
    }

    #[test]
    fn names_map_to_codes() {
        assert_eq!(code_for_name("Sustain").map(format_code).as_deref(), Some("10.0"));
        assert_eq!(code_for_name("Legato").map(format_code).as_deref(), Some("10.2"));
        assert_eq!(code_for_name("Pizz").map(format_code).as_deref(), Some("11.A"));
        assert_eq!(code_for_name("Short Spiccato").map(format_code).as_deref(), Some("11.5"));
        assert_eq!(code_for_name("Col Legno").map(format_code).as_deref(), Some("11.C"));
        assert_eq!(code_for_name("trill M2").map(format_code).as_deref(), Some("13.2"));
        assert_eq!(code_for_name("Trill m2").map(format_code).as_deref(), Some("13.0"));
        assert_eq!(code_for_name("Rach"), None);
        assert_eq!(parse_code("11.A"), Some(0x11A000));
        assert_eq!(parse_code("11.A.2"), Some(0x11A200));
        assert_eq!(format_code(0x11A200), "11.A.2");
    }

    #[test]
    fn attributes_fall_back_as_the_profile_says() {
        let arts = vec![art("Sustain"), art("Staccato"), art("Pizzicato"), art("Rach")];
        assert_eq!(code_of(&arts, 3), (0x1A0000, true));
        let arts = &codes(&arts)[..];
        assert_eq!(resolve(arts, 0x11, 0xA000), Some(2));
        assert_eq!(resolve(arts, 0x11, 0xA300), Some(2), "another variation");
        assert_eq!(resolve(arts, 0x11, 0x5000), Some(1), "spiccato falls to staccato");
        assert_eq!(resolve(arts, 0x14, 0x0000), Some(0), "harmonics fall to sustain");
        assert_eq!(resolve(arts, 0x1A, 0x0000), Some(3), "the unnamed one has a custom code");
        assert_eq!(resolve(arts, 0, 0), None);
        assert!(resets_round_robin(0x10, 0x0008));
    }
}
