//! Note and controller events passed to devices, with sample-accurate
//! offsets inside a block.
//!
//! The events are those of MIDI 2.0, at its resolution: velocities and
//! controller values are fractions, not seven-bit steps, and a controller
//! can belong to one note as well as to a channel. [`crate::ump`] turns
//! them into Universal MIDI Packets and back; MIDI 1.0 is the same events
//! with less detail.

/// A controller of a whole channel.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Ctl {
    /// A control change by index: 1 is the modulation wheel, 64 the
    /// sustain pedal. Values run from 0 to 1.
    Cc(u8),
    /// The pitch wheel, from -1 to 1 with 0 at rest.
    Bend,
    /// Channel pressure (aftertouch), from 0 to 1.
    Pressure,
    /// A registered controller (an RPN in MIDI 1.0) by bank and index, 0 to 1.
    Registered(u8, u8),
    /// An assignable controller (an NRPN in MIDI 1.0) by bank and index, 0 to 1.
    Assignable(u8, u8),
}

/// A controller of one sounding note.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum NoteCtl {
    /// The note's own pitch bend, from -1 to 1 over [`NOTE_BEND_RANGE`]
    /// semitones each way.
    Bend,
    /// The note's own pressure (polyphonic aftertouch), from 0 to 1.
    Pressure,
    /// A registered per-note controller by index, 0 to 1. The indexes mean
    /// what the control changes of the same number mean: 7 volume, 10 pan,
    /// 74 brightness.
    Registered(u8),
    /// An assignable per-note controller by index, 0 to 1.
    Assignable(u8),
}

/// How far a note's own pitch bend reaches, in semitones each way: the
/// default of MIDI 2.0 and of MPE.
pub const NOTE_BEND_RANGE: f64 = 48.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum EventKind {
    NoteOn {
        key: u8,
        vel: f32,
        ch: u8,
    },
    NoteOff {
        key: u8,
        ch: u8,
    },
    Control {
        ctl: Ctl,
        value: f64,
        ch: u8,
    },
    /// A controller of the note sounding on `key`.
    NoteControl {
        key: u8,
        ctl: NoteCtl,
        value: f64,
        ch: u8,
    },
    /// Choose a sound by number, with the bank it is in (fourteen bits)
    /// when that is said too.
    Program {
        program: u8,
        bank: Option<u16>,
        ch: u8,
    },
    AllNotesOff,
}

impl EventKind {
    /// The MIDI channel, from 0, of a message that has one.
    pub fn channel(&self) -> Option<u8> {
        match *self {
            EventKind::NoteOn { ch, .. }
            | EventKind::NoteOff { ch, .. }
            | EventKind::Control { ch, .. }
            | EventKind::NoteControl { ch, .. }
            | EventKind::Program { ch, .. } => Some(ch),
            EventKind::AllNotesOff => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Event {
    /// Offset in frames from the start of the block being processed.
    pub frame: u32,
    pub kind: EventKind,
}

/// Events dropped since the program started: pushed into a full list, or
/// arriving from a MIDI port faster than the engine took them.
static DROPPED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// How many events have been dropped so far (see [`EventBuf::push`]).
pub fn dropped() -> u64 {
    DROPPED.load(std::sync::atomic::Ordering::Relaxed)
}

pub(crate) fn count_dropped() {
    DROPPED.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
}

/// A fixed-capacity event list. Pushing past capacity drops the event, so the
/// audio thread never allocates.
pub struct EventBuf {
    events: Vec<Event>,
}

impl EventBuf {
    pub fn with_capacity(cap: usize) -> Self {
        Self {
            events: Vec::with_capacity(cap),
        }
    }

    pub fn push(&mut self, event: Event) {
        if self.events.len() < self.events.capacity() {
            self.events.push(event);
        } else {
            DROPPED.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        }
    }

    pub fn clear(&mut self) {
        self.events.clear();
    }

    pub fn as_slice(&self) -> &[Event] {
        &self.events
    }

    pub fn is_empty(&self) -> bool {
        self.events.is_empty()
    }
}
