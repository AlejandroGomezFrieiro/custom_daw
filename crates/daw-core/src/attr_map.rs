//! A track's attribute map (`track.attr_map`): how the MIDI 2.0 attributes
//! of its notes (articulations, mostly) reach an instrument that does not
//! take them, as the keyswitches, controllers, program changes and channels
//! it does take.
//!
//! The map is plain data, written by whatever knows the instrument (the
//! articulations extension writes it from an articulation file); the core
//! only plays it, so a project plays the same with no extension loaded:
//!
//! ```lua
//! track.attr_map = {
//!   send = "change",                  -- or "every": before every note
//!   chase = { 1, 11 },                -- controllers sent again after a change
//!   default = { out = "ks=C1" },      -- notes with no attribute
//!   arts = { ["11.0"] = { out = "ks=D1" }, ["11.A"] = { out = "ks=E1 cc1=90" } },
//!   by_type = { [0x13] = { out = "ks=G1" } },   -- a whole classification, or another type
//!   attribute = true,                 -- notes keep their attribute too (false: drop it)
//! }
//! ```
//!
//! `out` is events separated by spaces: `ks=D1` (a keyswitch struck, with
//! `:velocity` from 1 to 127 if wanted), `hold=D1` (held while the
//! articulation lasts), `ccN=V` (0 to 127), `pc=P` or `pc=P/BANK`,
//! `bend=X` (-1 to 1), `ch=N` (the note itself goes out on channel N, 1 to
//! 16, and so do these events), `attr` (the note keeps its attribute even
//! when the map drops the others). An articulation is found by its M2-123
//! code (`"11.A"`, with the variation `"11.A.2"`), falling back as the
//! profile says: the subclass without the variation, the classification's
//! entry in `by_type`, subclass 0 of the classification, then `"10.0"`; an
//! attribute of another type by `by_type`, and a note with none, or with
//! nothing found, by `default`.
//!
//! [`downgrade`] puts the events in a track's sorted events, each change
//! just before the note it is for, on the note's beat (the order a
//! keyswitched sampler needs), and lists the changes as switches the engine
//! sends again when playback starts after them.

use std::collections::{BTreeMap, HashMap};

use anyhow::{Context, Result, bail};
use daw_engine::{Attr, ClipSet, Ctl, EventKind, MidiEv, Switch};
use serde::{Deserialize, Serialize};

/// How long a keyswitch that is struck is held, in beats.
const STRIKE: f64 = 1.0 / 64.0;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AttrMap {
    #[serde(default)]
    pub send: SendWhen,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub chase: Vec<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default: Option<Art>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub arts: BTreeMap<String, Art>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub by_type: BTreeMap<TypeKey, Art>,
    #[serde(default = "yes", skip_serializing_if = "is_true")]
    pub attribute: bool,
}

fn yes() -> bool {
    true
}

fn is_true(b: &bool) -> bool {
    *b
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SendWhen {
    /// Only when a note's articulation is not the one before it.
    #[default]
    Change,
    /// Before every note.
    Every,
}

/// What one articulation sends: `{ out = "ks=D1" }`, or the line alone.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Art {
    Line(String),
    Table {
        out: String,
        /// Anything else an entry carries (a name, a tag) is the writer's,
        /// kept as given.
        #[serde(flatten)]
        rest: serde_json::Map<String, serde_json::Value>,
    },
}

impl Art {
    fn out(&self) -> &str {
        match self {
            Art::Line(out) | Art::Table { out, .. } => out,
        }
    }
}

/// An attribute type as a key of `by_type`: a number in Lua, a string in
/// the project file ("17" or "0x11").
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TypeKey(pub u8);

impl Serialize for TypeKey {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.0.to_string())
    }
}

impl<'de> Deserialize<'de> for TypeKey {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct Visit;
        impl serde::de::Visitor<'_> for Visit {
            type Value = TypeKey;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("an attribute type from 1 to 255")
            }
            fn visit_u64<E: serde::de::Error>(self, v: u64) -> Result<TypeKey, E> {
                u8::try_from(v)
                    .ok()
                    .filter(|v| *v > 0)
                    .map(TypeKey)
                    .ok_or_else(|| E::custom(format!("{v} is not an attribute type (1 to 255)")))
            }
            fn visit_i64<E: serde::de::Error>(self, v: i64) -> Result<TypeKey, E> {
                self.visit_u64(u64::try_from(v).unwrap_or(u64::MAX))
            }
            fn visit_f64<E: serde::de::Error>(self, v: f64) -> Result<TypeKey, E> {
                if v.fract() == 0.0 && v >= 0.0 {
                    self.visit_u64(v as u64)
                } else {
                    Err(E::custom(format!("{v} is not an attribute type")))
                }
            }
            fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<TypeKey, E> {
                let n = match v.strip_prefix("0x").or_else(|| v.strip_prefix("0X")) {
                    Some(hex) => u64::from_str_radix(hex, 16),
                    None => v.parse(),
                };
                n.map_err(|_| E::custom(format!("`{v}` is not an attribute type")))
                    .and_then(|n| self.visit_u64(n))
            }
        }
        d.deserialize_any(Visit)
    }
}

/// One event an articulation sends.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Out {
    /// A keyswitch struck and let go.
    Strike { key: u8, vel: f32 },
    /// A keyswitch held while the articulation lasts.
    Hold { key: u8, vel: f32 },
    /// A controller, a program change or the pitch wheel, on channel 0.
    Event(EventKind),
}

/// One articulation as it is played.
#[derive(Clone, Debug, Default, PartialEq)]
struct Compiled {
    outs: Vec<Out>,
    /// The channel the note goes out on, from 0.
    channel: Option<u8>,
    /// Whether the note keeps its attribute.
    attr: bool,
}

/// A map made ready to play.
pub struct Plan {
    every: bool,
    chase: Vec<u8>,
    arts: Vec<Compiled>,
    default: Option<usize>,
    by_code: HashMap<String, usize>,
    by_type: HashMap<u8, usize>,
}

impl AttrMap {
    /// The map ready to play, or what is wrong with it.
    pub fn plan(&self) -> Result<Plan> {
        let mut arts = Vec::new();
        let mut compile = |art: &Art, what: &str| -> Result<usize> {
            let c = compile(art.out(), self.attribute).with_context(|| format!("in {what}"))?;
            arts.push(c);
            Ok(arts.len() - 1)
        };
        let default = match &self.default {
            Some(art) => Some(compile(art, "`default`")?),
            None => None,
        };
        let mut by_code = HashMap::new();
        for (code, art) in &self.arts {
            let key = normal_code(code).with_context(|| {
                format!("`{code}` is not an articulation's code like \"11.A\" or \"10.2.3\"")
            })?;
            by_code.insert(key, compile(art, &format!("`arts[\"{code}\"]`"))?);
        }
        let mut by_type = HashMap::new();
        for (kind, art) in &self.by_type {
            by_type.insert(kind.0, compile(art, &format!("`by_type[{}]`", kind.0))?);
        }
        for cc in &self.chase {
            if *cc > 127 {
                bail!("controllers to chase go up to 127, not {cc}");
            }
        }
        Ok(Plan {
            every: self.send == SendWhen::Every,
            chase: self.chase.clone(),
            arts,
            default,
            by_code,
            by_type,
        })
    }
}

/// A code as the map keeps it: "11.A", "10.2.3" with a variation, in capitals.
fn normal_code(code: &str) -> Option<String> {
    let parts: Vec<&str> = code.trim().split('.').collect();
    let hex = |s: &str| u8::from_str_radix(s, 16).ok();
    match parts.as_slice() {
        [c, s] if c.len() == 2 && s.len() == 1 => {
            let (c, s) = (hex(c)?, hex(s)?);
            (0x10..=0x1f).contains(&c).then(|| format!("{c:X}.{s:X}"))
        }
        [c, s, v] if c.len() == 2 && s.len() == 1 && v.len() == 1 => {
            let (c, s, v) = (hex(c)?, hex(s)?, hex(v)?);
            (0x10..=0x1f)
                .contains(&c)
                .then(|| format!("{c:X}.{s:X}.{v:X}"))
        }
        _ => None,
    }
}

/// A pitch by name ("D1", "C#-1", "Eb4", with C4 as 60) or number.
fn pitch(text: &str) -> Option<u8> {
    if let Ok(n) = text.parse::<u8>() {
        return (n < 128).then_some(n);
    }
    let mut chars = text.chars();
    let base = match chars.next()?.to_ascii_uppercase() {
        'C' => 0,
        'D' => 2,
        'E' => 4,
        'F' => 5,
        'G' => 7,
        'A' => 9,
        'B' => 11,
        _ => return None,
    };
    let rest = chars.as_str();
    let accidentals = rest.len() - rest.trim_start_matches(['#', 'b']).len();
    let shift: i32 = rest[..accidentals]
        .chars()
        .map(|c| if c == '#' { 1 } else { -1 })
        .sum();
    let octave: i32 = rest[accidentals..].parse().ok()?;
    u8::try_from((octave + 1) * 12 + base + shift)
        .ok()
        .filter(|p| *p < 128)
}

/// The events of one `out` line.
fn compile(line: &str, keep_attr: bool) -> Result<Compiled> {
    let mut art = Compiled {
        attr: keep_attr,
        ..Default::default()
    };
    for word in line.split_whitespace() {
        let (what, value) = word.split_once('=').unwrap_or((word, ""));
        let number = |v: &str| -> Result<f64> {
            v.parse::<f64>()
                .ok()
                .filter(|n| n.is_finite())
                .with_context(|| format!("`{word}` needs a number"))
        };
        let seven = |v: &str| -> Result<u8> {
            let n = number(v)?;
            if !(0.0..=127.0).contains(&n) || n.fract() != 0.0 {
                bail!("`{word}`: a value from 0 to 127");
            }
            Ok(n as u8)
        };
        match what {
            "ks" | "hold" => {
                let (key, vel) = value.split_once(':').unwrap_or((value, "127"));
                let key = pitch(key).with_context(|| format!("`{word}`: no such key"))?;
                let vel = seven(vel)?.max(1) as f32 / 127.0;
                art.outs.push(if what == "ks" {
                    Out::Strike { key, vel }
                } else {
                    Out::Hold { key, vel }
                });
            }
            "pc" => {
                let (program, bank) = match value.split_once('/') {
                    Some((p, b)) => {
                        let bank = number(b)?;
                        if !(0.0..=16383.0).contains(&bank) || bank.fract() != 0.0 {
                            bail!("`{word}`: a bank from 0 to 16383");
                        }
                        (seven(p)?, Some(bank as u16))
                    }
                    None => (seven(value)?, None),
                };
                art.outs.push(Out::Event(EventKind::Program {
                    program,
                    bank,
                    ch: 0,
                }));
            }
            "bend" => {
                let value = number(value)?;
                if !(-1.0..=1.0).contains(&value) {
                    bail!("`{word}`: a bend from -1 to 1");
                }
                art.outs.push(Out::Event(EventKind::Control {
                    ctl: Ctl::Bend,
                    value,
                    ch: 0,
                }));
            }
            "ch" => {
                let ch = seven(value)?;
                if !(1..=16).contains(&ch) {
                    bail!("`{word}`: a channel from 1 to 16");
                }
                art.channel = Some(ch - 1);
            }
            "attr" if value.is_empty() => art.attr = true,
            _ if what.starts_with("cc") => {
                let cc =
                    seven(&what[2..]).with_context(|| format!("`{word}`: no such controller"))?;
                art.outs.push(Out::Event(EventKind::Control {
                    ctl: Ctl::Cc(cc),
                    value: seven(value)? as f64 / 127.0,
                    ch: 0,
                }));
            }
            _ => bail!(
                "`{word}` is not an event an articulation sends (ks=, hold=, ccN=, pc=, bend=, ch=, attr)"
            ),
        }
    }
    Ok(art)
}

impl Plan {
    /// The articulation a note plays, by its attribute.
    fn find(&self, attr: Attr) -> Option<usize> {
        if attr.is_none() {
            return self.default;
        }
        let code = |s: u16| format!("{:X}.{:X}", attr.kind, s);
        let (subclass, variation) = (attr.data >> 12, (attr.data >> 8) & 15);
        let found = if (0x10..=0x1f).contains(&attr.kind) {
            let exact = (variation > 0)
                .then(|| {
                    self.by_code
                        .get(&format!("{}.{variation:X}", code(subclass)))
                })
                .flatten();
            exact
                .or_else(|| self.by_code.get(&code(subclass)))
                .or_else(|| self.by_type.get(&attr.kind))
                .or_else(|| self.by_code.get(&code(0)))
                .or_else(|| self.by_code.get("10.0"))
        } else {
            self.by_type.get(&attr.kind)
        };
        found.copied().or(self.default)
    }

    /// What to send ahead of a note played live with `attr`: the events,
    /// and the channel the note goes out on.
    pub fn live(&self, attr: Attr) -> (Vec<EventKind>, Option<u8>, bool) {
        let Some(art) = self.find(attr).map(|i| &self.arts[i]) else {
            return (Vec::new(), None, true);
        };
        let ch = art.channel.unwrap_or(0);
        let mut events = Vec::new();
        for out in &art.outs {
            match *out {
                Out::Strike { key, vel } | Out::Hold { key, vel } => {
                    events.push(EventKind::NoteOn {
                        key,
                        vel,
                        ch,
                        attr: Attr::NONE,
                    });
                    events.push(EventKind::NoteOff { key, ch });
                }
                Out::Event(kind) => events.push(on_channel(kind, ch)),
            }
        }
        (events, art.channel, art.attr)
    }

    /// The channels other than the first that notes are sent to.
    pub fn channels(&self) -> Vec<u8> {
        let mut out: Vec<u8> = self.arts.iter().filter_map(|a| a.channel).collect();
        out.sort();
        out.dedup();
        out.retain(|ch| *ch != 0);
        out
    }
}

fn on_channel(kind: EventKind, ch: u8) -> EventKind {
    daw_engine::midi_out::on_channel(kind, Some(ch))
}

/// Put what a track's map sends into its sorted events: before each note
/// whose articulation is not the one before it (or every note), the
/// articulation's events on the note's beat, ahead of it; the note on its
/// articulation's channel; the attribute kept or dropped. Every change is
/// listed in `set.switches` for chasing.
pub fn downgrade(set: &mut ClipSet, plan: &Plan) {
    let midi = std::mem::take(&mut set.midi);
    let mut out = Vec::with_capacity(midi.len() + midi.len() / 2);
    // The articulation in force, and the keyswitches it holds down.
    let mut current: Option<usize> = None;
    let mut held: Vec<(u8, u8)> = Vec::new();
    // Where each key's sounding notes were sent, oldest first, when not 0.
    let mut routed: HashMap<u8, Vec<u8>> = HashMap::new();
    let mut controllers = [f64::NAN; 128];
    let mut last_beat = 0.0f64;
    for ev in midi {
        let beat = ev.beat;
        last_beat = last_beat.max(beat);
        let push = |out: &mut Vec<MidiEv>, kind| out.push(MidiEv { beat, kind });
        match ev.kind {
            EventKind::NoteOn { key, vel, ch, attr } => {
                let found = plan.find(attr);
                if let Some(i) = found
                    && (plan.every || current != Some(i))
                {
                    let art = &plan.arts[i];
                    let ch = art.channel.unwrap_or(0);
                    for (key, ch) in held.drain(..) {
                        push(&mut out, EventKind::NoteOff { key, ch });
                    }
                    let first = set.switch_events.len();
                    for o in &art.outs {
                        let kind = match *o {
                            Out::Strike { key, vel } | Out::Hold { key, vel } => {
                                EventKind::NoteOn {
                                    key,
                                    vel,
                                    ch,
                                    attr: Attr::NONE,
                                }
                            }
                            Out::Event(kind) => on_channel(kind, ch),
                        };
                        push(&mut out, kind);
                        set.switch_events.push(kind);
                        match *o {
                            Out::Strike { key, .. } => out.push(MidiEv {
                                beat: beat + STRIKE,
                                kind: EventKind::NoteOff { key, ch },
                            }),
                            Out::Hold { key, .. } => held.push((key, ch)),
                            Out::Event(_) => {}
                        }
                    }
                    // Some instruments put their controllers back when told
                    // to change: they are told again where they are.
                    for &cc in &plan.chase {
                        let value = controllers[cc as usize & 127];
                        if !value.is_nan() {
                            let ctl = Ctl::Cc(cc);
                            push(&mut out, EventKind::Control { ctl, value, ch });
                        }
                    }
                    if current != Some(i) {
                        let events = first..set.switch_events.len();
                        set.switches.push(Switch { beat, events });
                    }
                    current = Some(i);
                }
                let art = found.map(|i| &plan.arts[i]);
                let ch = art.and_then(|a| a.channel).unwrap_or(ch);
                if ch != 0 {
                    routed.entry(key).or_default().push(ch);
                }
                let attr = if art.is_none_or(|a| a.attr) {
                    attr
                } else {
                    Attr::NONE
                };
                push(&mut out, EventKind::NoteOn { key, vel, ch, attr });
            }
            EventKind::NoteOff { key, ch: 0 } => {
                let ch = match routed.get_mut(&key) {
                    Some(list) if !list.is_empty() => list.remove(0),
                    _ => 0,
                };
                push(&mut out, EventKind::NoteOff { key, ch });
            }
            EventKind::NoteControl {
                key,
                ctl,
                value,
                ch: 0,
            } => {
                let ch = routed
                    .get(&key)
                    .and_then(|l| l.first())
                    .copied()
                    .unwrap_or(0);
                push(
                    &mut out,
                    EventKind::NoteControl {
                        key,
                        ctl,
                        value,
                        ch,
                    },
                );
            }
            kind => {
                if let EventKind::Control {
                    ctl: Ctl::Cc(cc),
                    value,
                    ..
                } = kind
                {
                    controllers[cc as usize & 127] = value;
                }
                push(&mut out, kind);
            }
        }
    }
    // What is held down is let go after the last note.
    for (key, ch) in held {
        out.push(MidiEv {
            beat: last_beat,
            kind: EventKind::NoteOff { key, ch },
        });
    }
    set.midi = out;
    set.finish();
}

/// The map of a track from Lua's or a file's data: nothing for nil, an
/// empty table or `false`.
pub fn parse(value: serde_json::Value) -> Result<Option<AttrMap>> {
    use serde_json::Value;
    match value {
        Value::Null | Value::Bool(false) => Ok(None),
        Value::Array(a) if a.is_empty() => Ok(None),
        Value::Object(o) if o.is_empty() => Ok(None),
        value => {
            let map: AttrMap = serde_json::from_value(value)
                .map_err(|err| anyhow::anyhow!("an attr_map cannot be that: {err}"))?;
            map.plan()?;
            Ok(Some(map))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(lua_like: serde_json::Value) -> Plan {
        parse(lua_like).unwrap().unwrap().plan().unwrap()
    }

    fn note(set: &mut ClipSet, beat: f64, key: u8, attr: Attr) {
        set.push_note_attr(beat, beat + 0.5, key, 0.8, attr);
    }

    fn m2(kind: u8, subclass: u16) -> Attr {
        Attr {
            kind,
            data: subclass << 12,
        }
    }

    /// The events as short words, in order.
    fn words(set: &ClipSet) -> Vec<String> {
        set.midi
            .iter()
            .map(|e| match e.kind {
                EventKind::NoteOn { key, ch, .. } => format!("{} on{key}/{ch}", e.beat),
                EventKind::NoteOff { key, ch } => format!("{} off{key}/{ch}", e.beat),
                EventKind::Control {
                    ctl: Ctl::Cc(n),
                    value,
                    ch,
                } => format!("{} cc{n}={}/{ch}", e.beat, (value * 127.0).round()),
                EventKind::Program { program, ch, .. } => format!("{} pc{program}/{ch}", e.beat),
                other => format!("{} {other:?}", e.beat),
            })
            .collect()
    }

    #[test]
    fn names_of_keys_and_codes_are_read() {
        assert_eq!(pitch("C4"), Some(60));
        assert_eq!(pitch("D1"), Some(26));
        assert_eq!(pitch("C#1"), Some(25));
        assert_eq!(pitch("Eb-1"), Some(3));
        assert_eq!(pitch("G9"), Some(127));
        assert_eq!(pitch("A9"), None);
        assert_eq!(pitch("24"), Some(24));
        assert_eq!(normal_code("11.a").as_deref(), Some("11.A"));
        assert_eq!(normal_code("10.2.3").as_deref(), Some("10.2.3"));
        assert_eq!(normal_code("20.0"), None);
        assert!(
            compile(
                "ks=D1 cc32=40 pc=3/258 bend=0.5 ch=2 attr hold=E1:90",
                false
            )
            .is_ok()
        );
        assert!(compile("ks=H1", false).is_err());
        assert!(compile("cc1=200", false).is_err());
        assert!(compile("ch=17", false).is_err());
        assert!(compile("xyz", false).is_err());
    }

    #[test]
    fn a_keyswitch_goes_before_its_note_on_the_same_beat_and_only_on_a_change() {
        let plan = map(serde_json::json!({
            "default": "ks=C1",
            "arts": { "11.0": { "out": "ks=D1" }, "11.A": "ks=E1" },
        }));
        let mut set = ClipSet::default();
        note(&mut set, 0.0, 60, Attr::NONE);
        note(&mut set, 1.0, 62, Attr::NONE);
        note(&mut set, 2.0, 64, m2(0x11, 0));
        note(&mut set, 3.0, 65, m2(0x11, 0));
        // Staccatissimo is not mapped: subclass 0 of its classification plays.
        note(&mut set, 4.0, 67, m2(0x11, 4));
        note(&mut set, 5.0, 69, m2(0x11, 0xA));
        set.finish();
        downgrade(&mut set, &plan);
        let on: Vec<String> = words(&set)
            .into_iter()
            .filter(|w| w.contains(" on"))
            .collect();
        assert_eq!(
            on,
            [
                "0 on24/0", "0 on60/0", "1 on62/0", "2 on26/0", "2 on64/0", "3 on65/0", "4 on67/0",
                "5 on28/0", "5 on69/0"
            ]
        );
        assert_eq!(
            set.switches.iter().map(|s| s.beat).collect::<Vec<_>>(),
            [0.0, 2.0, 5.0]
        );
        assert_eq!(set.switch_before(4.5).len(), 1);
        assert!(matches!(
            set.switch_before(4.5)[0],
            EventKind::NoteOn { key: 26, .. }
        ));
        assert!(set.switch_before(0.0).is_empty());
    }

    #[test]
    fn sent_before_every_note_held_routed_and_chased() {
        let plan = map(serde_json::json!({
            "send": "every",
            "chase": [1],
            "attribute": false,
            "arts": { "11.0": "hold=D1 cc32=40", "11.A": "ks=E1 ch=3 attr" },
        }));
        let mut set = ClipSet::default();
        set.push_event(
            0.0,
            EventKind::Control {
                ctl: Ctl::Cc(1),
                value: 0.5,
                ch: 0,
            },
        );
        note(&mut set, 0.0, 60, m2(0x11, 0));
        note(&mut set, 1.0, 62, m2(0x11, 0));
        note(&mut set, 2.0, 64, m2(0x11, 0xA));
        set.finish();
        downgrade(&mut set, &plan);
        let w = words(&set);
        // Every note is told again; the held keyswitch is let go at the change.
        assert!(w.contains(&"1 on26/0".to_string()), "{w:?}");
        assert!(w.contains(&"2 off26/0".to_string()), "{w:?}");
        // The pizzicato and its keyswitch go out on channel 3, with the controller chased.
        assert!(w.contains(&"2 on28/2".to_string()), "{w:?}");
        assert!(w.contains(&"2 on64/2".to_string()), "{w:?}");
        assert!(w.contains(&"2.5 off64/2".to_string()), "{w:?}");
        assert!(w.contains(&"2 cc1=64/2".to_string()), "{w:?}");
        let attr_of = |key| {
            set.midi.iter().find_map(|e| match e.kind {
                EventKind::NoteOn { key: k, attr, .. } if k == key => Some(attr),
                _ => None,
            })
        };
        assert_eq!(attr_of(60), Some(Attr::NONE), "the map drops attributes");
        assert_eq!(
            attr_of(64),
            Some(m2(0x11, 0xA)),
            "but `attr` keeps this one's"
        );
        // The order on a beat: controllers, then the keyswitch, then the note.
        let at2: Vec<&String> = w.iter().filter(|x| x.starts_with("2 ")).collect();
        let pos = |s: &str| at2.iter().position(|x| x.as_str() == s).unwrap();
        assert!(pos("2 on28/2") < pos("2 on64/2"), "{at2:?}");
    }

    #[test]
    fn a_map_keeps_what_it_was_given() {
        let value = serde_json::json!({
            "send": "change",
            "by_type": { "17": { "out": "pc=3", "name": "Shorts" } },
            "arts": { "10.0": "ks=C1" },
        });
        let map = parse(value).unwrap().unwrap();
        let back = serde_json::to_value(&map).unwrap();
        assert_eq!(back["by_type"]["17"]["name"], "Shorts");
        assert_eq!(parse(back).unwrap(), Some(map));
        assert!(parse(serde_json::json!({ "arts": { "11.0": "ks=Q" } })).is_err());
        assert_eq!(parse(serde_json::json!([])).unwrap(), None);
    }
}
