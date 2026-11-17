//! The one instrument model every format reader produces.
//!
//! An instrument is regions: each says when it plays (key, velocity,
//! controllers, articulation, round robin, trigger) and how (sample, pitch,
//! loop, level, envelopes, filter). The player knows nothing of SFZ or
//! Decent Sampler; a new format is a reader that fills these structures.

use std::path::PathBuf;

/// What a region plays.
#[derive(Clone, Debug, PartialEq)]
pub enum Source {
    File(PathBuf),
    /// SFZ's generators (`*sine`, `*saw`, ...): one cycle, looped.
    Wave(Wave),
    Silence,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Wave {
    Sine,
    Saw,
    Square,
    Triangle,
    Noise,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Trigger {
    /// On note-on.
    Attack,
    /// On note-off (after the sustain pedal lets go of the note).
    Release,
    /// On note-off, whatever the pedal.
    ReleaseKey,
    /// On note-on when no other note is held.
    First,
    /// On note-on while another note is held.
    Legato,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LoopMode {
    /// Play to the end; a note-off releases.
    NoLoop,
    /// Play to the end whatever the note-off.
    OneShot,
    /// Loop through release.
    Continuous,
    /// Loop while the note is held, then play on past the loop.
    Sustain,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FilterKind {
    Lp1,
    Hp1,
    Lp2,
    Hp2,
    Bp2,
    Br2,
    Lp4,
    Hp4,
}

/// Delay, attack, hold, decay, sustain, release; times in seconds, levels
/// 0..1. Attack is a line, decay and release fall exponentially.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Envelope {
    pub delay: f32,
    pub start: f32,
    pub attack: f32,
    pub hold: f32,
    pub decay: f32,
    pub sustain: f32,
    pub release: f32,
    /// Seconds added per unit of velocity (0..1), SFZ's `ampeg_vel2*`.
    pub vel2attack: f32,
    pub vel2decay: f32,
    pub vel2release: f32,
    pub vel2sustain: f32,
}

impl Envelope {
    pub const AMP: Envelope = Envelope {
        delay: 0.0,
        start: 0.0,
        attack: 0.0,
        hold: 0.0,
        decay: 0.0,
        sustain: 1.0,
        release: 0.001,
        vel2attack: 0.0,
        vel2decay: 0.0,
        vel2release: 0.0,
        vel2sustain: 0.0,
    };
    /// A modulation envelope: SFZ's `fileg_*` and `pitcheg_*` sustain at 0.
    pub const MOD: Envelope = Envelope { sustain: 0.0, release: 0.0, ..Envelope::AMP };
}

#[derive(Clone, Debug, PartialEq)]
pub struct Filter {
    pub kind: FilterKind,
    /// Hz.
    pub cutoff: f32,
    /// dB.
    pub resonance: f32,
    /// Cents per key away from `keycenter`.
    pub keytrack: f32,
    pub keycenter: u8,
    /// Cents at full velocity.
    pub veltrack: f32,
    /// Cents at the envelope's peak.
    pub eg_depth: f32,
    pub eg: Envelope,
}

/// What a controller changes while a voice plays.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Target {
    /// Linear gain, depth in percent (100: from silence to full).
    Amplitude,
    /// dB.
    Volume,
    /// Percent of the pan range.
    Pan,
    /// Cents.
    Pitch,
    /// Cents.
    Cutoff,
    /// dB.
    Resonance,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CcMod {
    pub cc: u8,
    pub target: Target,
    pub depth: f32,
    /// Index into `Instrument::curves`.
    pub curve: Option<usize>,
    /// Smoothing in milliseconds.
    pub smooth: f32,
}

/// How a crossfade shapes its gain.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum XfCurve {
    /// Equal power.
    Power,
    /// Equal gain.
    Gain,
}

/// A fade in or out over a range of a value (key, velocity or a controller).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Fade {
    pub lo: f32,
    pub hi: f32,
    /// Fading in (0 at `lo`, 1 at `hi`) or out (1 at `lo`, 0 at `hi`).
    pub out: bool,
}

impl Fade {
    pub fn gain(&self, value: f32, curve: XfCurve) -> f32 {
        let t = if self.hi <= self.lo {
            if value >= self.hi { 1.0 } else { 0.0 }
        } else {
            ((value - self.lo) / (self.hi - self.lo)).clamp(0.0, 1.0)
        };
        let t = if self.out { 1.0 - t } else { t };
        match curve {
            XfCurve::Gain => t,
            XfCurve::Power => t.sqrt(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CcRange {
    pub cc: u8,
    /// 0..1, both ends included.
    pub lo: f32,
    pub hi: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SeqMode {
    /// Plays at its place in the cycle of `length` notes.
    RoundRobin,
    /// Plays when a random draw lands on its place.
    Random,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Region {
    pub source: Source,

    // --- when it plays ---
    pub lokey: u8,
    pub hikey: u8,
    pub lovel: u8,
    pub hivel: u8,
    pub lochan: u8,
    pub hichan: u8,
    pub cc_ranges: Vec<CcRange>,
    pub lorand: f32,
    pub hirand: f32,
    pub seq_length: u32,
    pub seq_position: u32,
    pub seq_mode: SeqMode,
    /// Switch layers of which at least one must be on (SFZ `sw_last`).
    pub switch_any: u128,
    /// Switch layers that must all be on (Decent Sampler groups and tags).
    pub switch_all: u128,
    /// A key that must be held (`sw_down`) or not held (`sw_up`).
    pub sw_down: Option<u8>,
    pub sw_up: Option<u8>,
    /// The note played before this one (`sw_previous`).
    pub sw_previous: Option<u8>,
    pub trigger: Trigger,

    // --- pitch ---
    /// The key at which the sample plays at its own pitch; `None` takes
    /// the sample file's, else 60.
    pub keycenter: Option<u8>,
    /// Cents per key.
    pub keytrack: f32,
    /// Cents.
    pub tune: f32,
    /// Semitones.
    pub transpose: i32,
    /// Cents at full velocity.
    pub pitch_veltrack: f32,
    /// Pitch bend range in cents.
    pub bend_up: f32,
    pub bend_down: f32,
    pub pitch_eg: Envelope,
    /// Cents at the pitch envelope's peak.
    pub pitch_eg_depth: f32,

    // --- the sample's span ---
    /// Frames.
    pub offset: u64,
    pub offset_random: u64,
    /// Last frame played (inclusive), when not the file's end.
    pub end: Option<u64>,
    /// Seconds before the voice sounds.
    pub delay: f32,
    /// `None` takes the file's loop if it has one.
    pub loop_mode: Option<LoopMode>,
    pub loop_start: Option<u64>,
    /// Inclusive, as SFZ counts it.
    pub loop_end: Option<u64>,
    /// Seconds.
    pub loop_crossfade: f32,
    /// Frames, when the format counts the crossfade so (overrides seconds).
    pub loop_crossfade_frames: u64,

    // --- level ---
    /// dB.
    pub volume: f32,
    /// Linear.
    pub amplitude: f32,
    /// -1 (left) .. 1 (right).
    pub pan: f32,
    /// Stereo width -1..1 (1 as recorded, 0 mono).
    pub width: f32,
    /// Where the stereo image sits, -1..1.
    pub position: f32,
    /// 0..1 of the gain that follows velocity (negative: softer is louder).
    pub amp_veltrack: f32,
    /// A gain per velocity, when not the square law.
    pub amp_velcurve: Option<usize>,
    pub amp_eg: Envelope,
    /// dB lost per second the note was held, for release triggers.
    pub rt_decay: f32,
    pub xf_key: Vec<Fade>,
    pub xf_vel: Vec<Fade>,
    pub xf_cc: Vec<(u8, Fade)>,
    pub xf_keycurve: XfCurve,
    pub xf_velcurve: XfCurve,
    pub xf_cccurve: XfCurve,
    pub filter: Option<Filter>,
    pub mods: Vec<CcMod>,

    // --- voices ---
    /// Choke groups this region belongs to (SFZ `group`, Decent Sampler tags).
    pub groups: Vec<i64>,
    /// A voice of this region stops when one of these groups starts a voice.
    pub off_by: Vec<i64>,
    /// Stop at once (a few milliseconds) rather than through the release.
    pub off_fast: bool,
    /// Seconds, for a normal stop.
    pub off_time: f32,
    /// Voices at most of this region's first group.
    pub polyphony: Option<u32>,
    /// Voices at most per key of this region's first group.
    pub note_polyphony: Option<u32>,
}

impl Default for Region {
    fn default() -> Self {
        Region {
            source: Source::Silence,
            lokey: 0,
            hikey: 127,
            lovel: 1,
            hivel: 127,
            lochan: 1,
            hichan: 16,
            cc_ranges: Vec::new(),
            lorand: 0.0,
            hirand: 1.0,
            seq_length: 1,
            seq_position: 1,
            seq_mode: SeqMode::RoundRobin,
            switch_any: 0,
            switch_all: 0,
            sw_down: None,
            sw_up: None,
            sw_previous: None,
            trigger: Trigger::Attack,
            keycenter: None,
            keytrack: 100.0,
            tune: 0.0,
            transpose: 0,
            pitch_veltrack: 0.0,
            bend_up: 200.0,
            bend_down: -200.0,
            pitch_eg: Envelope::MOD,
            pitch_eg_depth: 0.0,
            offset: 0,
            offset_random: 0,
            end: None,
            delay: 0.0,
            loop_mode: None,
            loop_start: None,
            loop_end: None,
            loop_crossfade: 0.0,
            loop_crossfade_frames: 0,
            volume: 0.0,
            amplitude: 1.0,
            pan: 0.0,
            width: 1.0,
            position: 0.0,
            amp_veltrack: 1.0,
            amp_velcurve: None,
            amp_eg: Envelope::AMP,
            rt_decay: 0.0,
            xf_key: Vec::new(),
            xf_vel: Vec::new(),
            xf_cc: Vec::new(),
            xf_keycurve: XfCurve::Power,
            xf_velcurve: XfCurve::Power,
            xf_cccurve: XfCurve::Power,
            filter: None,
            mods: Vec::new(),
            groups: Vec::new(),
            off_by: Vec::new(),
            off_fast: true,
            off_time: 0.006,
            polyphony: None,
            note_polyphony: None,
        }
    }
}

/// A way of playing the instrument: legato, staccato, pizzicato.
///
/// The instrument has switch layers (up to 128), each on or off; a region
/// names the layers it needs. Choosing an articulation, by its keyswitch
/// or by a note's MIDI 2.0 attribute, sets the layers in `mask` to
/// `values`.
#[derive(Clone, Debug, PartialEq)]
pub struct Articulation {
    pub name: String,
    /// The M2-123 code, `type << 16 | subclass << 12 | variation << 8`, as
    /// the format says it or as the name maps to one.
    pub m2: Option<u32>,
    pub keyswitch: Option<u8>,
    pub mask: u128,
    pub values: u128,
}

/// A keyswitch note: pressing it sets layers, like choosing an articulation.
#[derive(Clone, Debug, PartialEq)]
pub struct Switch {
    pub key: u8,
    pub mask: u128,
    pub values: u128,
    /// The note sounds nothing itself.
    pub swallow: bool,
}

/// A curve over 0..1 as 128 points (SFZ `<curve>`).
#[derive(Clone, Debug, PartialEq)]
pub struct Curve(pub [f32; 128]);

impl Curve {
    pub fn at(&self, x: f32) -> f32 {
        let p = x.clamp(0.0, 1.0) * 127.0;
        let i = (p as usize).min(126);
        let f = p - i as f32;
        self.0[i] + (self.0[i + 1] - self.0[i]) * f
    }

    /// SFZ's built-in curves 0 to 6.
    pub fn builtin() -> Vec<Curve> {
        let make = |f: &dyn Fn(f32) -> f32| {
            let mut c = [0.0; 128];
            for (i, v) in c.iter_mut().enumerate() {
                *v = f(i as f32 / 127.0);
            }
            Curve(c)
        };
        vec![
            make(&|x| x),
            make(&|x| x * 2.0 - 1.0),
            make(&|x| 1.0 - x),
            make(&|x| 1.0 - 2.0 * x),
            make(&|x| x * x),
            make(&|x| x.sqrt()),
            make(&|x| (1.0 - x).sqrt()),
        ]
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Instrument {
    pub name: String,
    /// The reader that made it: "sfz", "dspreset".
    pub format: String,
    pub path: PathBuf,
    pub regions: Vec<Region>,
    pub articulations: Vec<Articulation>,
    /// Keyswitch notes, for MIDI 1.0 input.
    pub switches: Vec<Switch>,
    /// The switch layers before any keyswitch.
    pub default_switch: u128,
    /// The articulation a note with no attribute plays when no keyswitch
    /// was pressed.
    pub default_articulation: Option<usize>,
    pub curves: Vec<Curve>,
    /// Controllers' first values, 0..1.
    pub cc_init: Vec<(u8, f32)>,
    pub cc_labels: Vec<(u8, String)>,
    pub key_labels: Vec<(u8, String)>,
    /// What the reader did not understand (unknown opcodes, missing files).
    pub warnings: Vec<String>,
}

impl Instrument {
    /// The lowest and highest key any attack region plays, keyswitches
    /// left out.
    pub fn range(&self) -> Option<(u8, u8)> {
        let switch_keys: Vec<u8> = self.switches.iter().map(|s| s.key).collect();
        let mut range: Option<(u8, u8)> = None;
        for r in &self.regions {
            if r.trigger == Trigger::Release || r.trigger == Trigger::ReleaseKey {
                continue;
            }
            for key in r.lokey..=r.hikey {
                if switch_keys.contains(&key) {
                    continue;
                }
                range = Some(match range {
                    None => (key, key),
                    Some((lo, hi)) => (lo.min(key), hi.max(key)),
                });
            }
        }
        range
    }

    pub fn warn(&mut self, message: impl Into<String>) {
        let message = message.into();
        if self.warnings.len() < 200 && !self.warnings.contains(&message) {
            self.warnings.push(message);
        }
    }
}
