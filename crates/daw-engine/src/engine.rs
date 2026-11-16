//! The audio-thread side of the engine and the handle the main thread drives it with.
//!
//! Ownership rule: anything the audio thread uses is built on the main thread,
//! sent over as a `Box`, and sent back through the garbage queue when replaced.
//! The audio thread itself never allocates or frees.

use std::cell::UnsafeCell;
use std::collections::HashMap;
use std::ops::{Deref, DerefMut};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU32, AtomicU64, Ordering, Ordering::Relaxed};

use rtrb::{Consumer, Producer, PushError, RingBuffer};

use crate::automation::{self, AutoTarget, Automation};
use crate::clip::ClipSet;
use crate::device::{Device, Io, ProcessCtx};
use crate::event::{Ctl, Event, EventBuf, EventKind};
use crate::guard;
use crate::midi_out::MidiOut;
use crate::pool::Pool;
use crate::record::{MidiCapture, PUNCH_EPS, Take};
use crate::tempo::TempoMap;

/// Largest block handed to devices. Longer callbacks are split.
pub const MAX_BLOCK: usize = 1024;
pub const MAX_TRACKS: usize = 1024;
pub const MAX_DEVICES: usize = 8192;
/// Input channels beyond this many are ignored.
pub const MAX_INPUTS: usize = 32;

/// Index of a track or device in the engine's tables. Assigned by the main thread.
pub type Slot = u32;
/// The master track always lives in slot 0.
pub const MASTER: Slot = 0;
pub const NO_SLOT: Slot = u32::MAX;

const MSG_CAPACITY: usize = 16384;
const GARBAGE_CAPACITY: usize = 16384;
const MIDI_IN_CAPACITY: usize = 4096;
const METER_FALL_SECONDS: f32 = 0.3;

pub struct TrackRt {
    buf: [Vec<f32>; 2],
    chain: Box<[Slot]>,
    clips: Box<ClipSet>,
    automation: Box<Automation>,
    gain: f32,
    pan: f32,
    mute: bool,
    /// Silenced because another track is soloed: not heard, but what
    /// listens to it as a side-chain still hears it.
    quiet: bool,
    /// Per-channel gain actually applied at the end of the last block.
    applied: [f32; 2],
    /// The same for what is sent on before the fader: 0 when muted, else 1.
    applied_pre: f32,
    /// The same for what is heard of it after the fader: 0 when quiet.
    applied_heard: f32,
    /// Whether the track has produced a block yet. Until then a fader change
    /// takes effect at once rather than ramping from the default.
    started: bool,
    events: EventBuf,
    live: Vec<EventKind>,
    peak: [f32; 2],
    /// First input channel and how many channels (0, 1 or 2) the track takes.
    input_first: usize,
    input_channels: usize,
    /// Whether the input is heard.
    monitor: bool,
    /// Armed tracks without an audio input receive MIDI input.
    armed: bool,
    /// Which MIDI input it takes when armed: a port's key from
    /// [`crate::midi::port_key`], or 0 for every port; and a channel from 1
    /// to 16, or 0 for every channel.
    midi_port: u32,
    midi_channel: u8,
    /// Keys held down through MIDI input, released if the track is disarmed.
    held: u128,
    /// The MIDI output port it sends what it plays to, by its key (0 for
    /// none), the channel (1 to 16, or 0 for each message's own), and the
    /// form it goes in.
    midi_out: u32,
    midi_out_channel: u8,
    midi_out_form: crate::midi_form::Form,
    /// What it played this block, on its way to the port.
    sent: Vec<Event>,
    /// The track's clips were replaced: stop its notes, and start again those
    /// the new clips hold at the play position. Other tracks play on.
    flush: bool,
    chase: bool,
}

impl TrackRt {
    pub fn new() -> Box<Self> {
        Box::new(Self {
            buf: [vec![0.0; MAX_BLOCK], vec![0.0; MAX_BLOCK]],
            chain: Box::new([]),
            clips: Box::default(),
            automation: Box::default(),
            gain: 1.0,
            pan: 0.0,
            mute: false,
            quiet: false,
            applied: [1.0, 1.0],
            applied_pre: 1.0,
            applied_heard: 1.0,
            started: false,
            events: EventBuf::with_capacity(1024),
            live: Vec::with_capacity(256),
            peak: [0.0; 2],
            input_first: 0,
            input_channels: 0,
            monitor: false,
            armed: false,
            midi_port: 0,
            midi_channel: 0,
            held: 0,
            midi_out: 0,
            midi_out_channel: 0,
            midi_out_form: crate::midi_form::Form::Auto,
            sent: Vec::with_capacity(1024),
            flush: false,
            chase: false,
        })
    }

    /// An armed track with an audio input records that; one without plays
    /// and records MIDI input.
    fn takes_midi(&self) -> bool {
        self.armed && self.input_channels == 0
    }

    /// Whether a message from MIDI input on `port` is for this track.
    fn hears(&self, port: u32, kind: &EventKind) -> bool {
        self.takes_midi()
            && (self.midi_port == 0 || self.midi_port == port)
            && (self.midi_channel == 0
                || kind.channel().is_none_or(|ch| ch + 1 == self.midi_channel))
    }

    fn target_gains(&self) -> [f32; 2] {
        if self.mute {
            return [0.0, 0.0];
        }
        // Equal-power pan, scaled so that centre is unity gain.
        let angle = (self.pan.clamp(-1.0, 1.0) + 1.0) * std::f32::consts::FRAC_PI_4;
        let scale = self.gain * std::f32::consts::SQRT_2;
        [scale * angle.cos(), scale * angle.sin()]
    }
}

/// The longest a connection can be held back to wait for a slower one.
pub const MAX_DELAY: usize = 1 << 17;

/// A fixed delay on one connection between tracks. Devices that look ahead
/// report how late their output is; the connections of the tracks that are
/// not late are held back by the difference, so that everything arrives at a
/// mix point together. Empty, and free, when there is nothing to wait for.
#[derive(Default)]
pub struct Delay {
    ring: [Vec<f32>; 2],
    at: usize,
}

impl Delay {
    pub fn new(frames: usize) -> Self {
        let frames = frames.min(MAX_DELAY);
        Self {
            ring: [vec![0.0; frames], vec![0.0; frames]],
            at: 0,
        }
    }

    pub fn frames(&self) -> usize {
        self.ring[0].len()
    }

    fn clear(&mut self) {
        self.ring[0].fill(0.0);
        self.ring[1].fill(0.0);
    }

    /// Add `src`, this much later, into a pair of buffers, with a gain that
    /// moves from `from` to `to` over the block.
    fn mix(&mut self, src: [&[f32]; 2], dst: [&mut [f32]; 2], from: f32, to: f32) {
        let n = src[0].len();
        let len = self.ring[0].len();
        let step = (to - from) / n.max(1) as f32;
        for (ch, (src, dst)) in src.into_iter().zip(dst).enumerate() {
            let mut at = self.at;
            let ring = &mut self.ring[ch];
            for (i, (d, s)) in dst[..n].iter_mut().zip(src).enumerate() {
                let gain = from + step * (i + 1) as f32;
                if len == 0 {
                    *d += s * gain;
                } else {
                    *d += ring[at] * gain;
                    ring[at] = *s;
                    at += 1;
                    if at == len {
                        at = 0;
                    }
                }
            }
        }
        if len > 0 {
            self.at = (self.at + n) % len;
        }
    }
}

/// A send from one track into another.
pub struct SendRt {
    pub target: Slot,
    pub gain: f32,
    /// Taken after the devices but before the fader, pan and mute.
    pub pre: bool,
    pub delay: Delay,
}

impl SendRt {
    pub fn new(target: Slot, gain: f32) -> Self {
        Self {
            target,
            gain,
            pre: false,
            delay: Delay::default(),
        }
    }
}

/// A side-chain: a track's sound taken to a device on another track that
/// listens to it, such as a compressor ducking under a kick.
pub struct KeyRt {
    /// The device that listens, and the track it is on.
    pub device: Slot,
    pub track: Slot,
    /// Taken after the devices but before the fader, pan and mute, so that
    /// a muted track can still key.
    pub pre: bool,
    /// Lines the key up with the sound the device is processing.
    pub delay: Delay,
}

/// One of a device's further output pairs, played into another track.
/// It is taken from the device as it is: the fader, pan and mute of the
/// device's own track do not act on it, the target's do.
pub struct OutRt {
    /// The device, and which of its further pairs: 0 for its second.
    pub device: Slot,
    pub pair: usize,
    pub target: Slot,
    pub delay: Delay,
}

pub struct SchedEntry {
    pub slot: Slot,
    /// Where the track's output goes. [`NO_SLOT`] for the master track.
    pub output: Slot,
    /// How long the output waits for slower tracks that feed the same place.
    pub delay: Delay,
    pub sends: Vec<SendRt>,
    /// Devices elsewhere that listen to this track.
    pub keys: Vec<KeyRt>,
    /// Further output pairs of the track's devices, and where they go.
    pub outs: Vec<OutRt>,
}

impl SchedEntry {
    pub fn new(slot: Slot, output: Slot) -> Self {
        Self {
            slot,
            output,
            delay: Delay::default(),
            sends: Vec::new(),
            keys: Vec::new(),
            outs: Vec::new(),
        }
    }

    /// Whether something is taken from the track before its fader, which
    /// then waits until that has been done.
    fn taps_pre(&self) -> bool {
        self.sends.iter().any(|send| send.pre) || self.keys.iter().any(|key| key.pre)
    }
}

/// Processing order: every track appears after all tracks that feed it, and
/// the master track is last.
///
/// The entries are kept in groups: the tracks nothing feeds, then those fed
/// only by the first group, and so on. The tracks of a group do not depend on
/// each other, so they can be processed side by side; what they send on is
/// then added up in the order of the entries, on one thread, so that the
/// sums, and with them the output, do not depend on how many threads ran.
#[derive(Default)]
pub struct Schedule {
    pub entries: Vec<SchedEntry>,
    /// Frames by which the output is behind the transport, because of
    /// devices that report latency.
    pub latency: u32,
    /// Where each group ends in `entries`.
    groups: Vec<usize>,
}

impl Schedule {
    /// `entries` in an order where every track comes after all that feed it.
    pub fn new(entries: Vec<SchedEntry>, latency: u32) -> Self {
        // How many groups each track has to wait for.
        let mut waits: HashMap<Slot, usize> = HashMap::new();
        let mut keyed: Vec<(usize, SchedEntry)> = entries
            .into_iter()
            .map(|entry| {
                let group = waits.get(&entry.slot).copied().unwrap_or(0);
                let targets = std::iter::once(entry.output)
                    .chain(entry.sends.iter().map(|s| s.target))
                    .chain(entry.keys.iter().map(|k| k.track))
                    .chain(entry.outs.iter().map(|o| o.target));
                for target in targets {
                    let wait = waits.entry(target).or_default();
                    *wait = (*wait).max(group + 1);
                }
                // The master is last whatever feeds it.
                (
                    if entry.slot == MASTER {
                        usize::MAX
                    } else {
                        group
                    },
                    entry,
                )
            })
            .collect();
        keyed.sort_by_key(|(group, _)| *group);
        let mut groups = Vec::new();
        for (index, pair) in keyed.windows(2).enumerate() {
            if pair[0].0 != pair[1].0 {
                groups.push(index + 1);
            }
        }
        groups.push(keyed.len());
        Self {
            entries: keyed.into_iter().map(|(_, entry)| entry).collect(),
            latency,
            groups,
        }
    }

    /// Where the group that starts at entry `first` ends.
    fn group_end(&self, first: usize) -> usize {
        let at = self.groups.partition_point(|end| *end <= first);
        self.groups
            .get(at)
            .copied()
            .unwrap_or(self.entries.len())
            .clamp(first + 1, self.entries.len().max(first + 1))
    }
}

/// Something one thread at a time may work on: a track or a device, while
/// the tracks of a group are processed side by side. A second thread asking
/// for the same one is turned away, so even a schedule that names a track
/// twice, or two tracks that share a device, cannot make two threads touch it.
struct Guarded<T> {
    busy: AtomicBool,
    value: UnsafeCell<T>,
}

// Only the thread that set `busy` reaches the value.
unsafe impl<T: Send> Sync for Guarded<T> {}

impl<T> Guarded<T> {
    fn new(value: T) -> Self {
        Self {
            busy: AtomicBool::new(false),
            value: UnsafeCell::new(value),
        }
    }

    fn get_mut(&mut self) -> &mut T {
        self.value.get_mut()
    }

    fn claim(&self) -> Option<Claim<'_, T>> {
        self.busy
            .compare_exchange(false, true, Ordering::Acquire, Relaxed)
            .ok()
            .map(|_| Claim(self))
    }
}

struct Claim<'a, T>(&'a Guarded<T>);

impl<T> Deref for Claim<'_, T> {
    type Target = T;
    fn deref(&self) -> &T {
        unsafe { &*self.0.value.get() }
    }
}

impl<T> DerefMut for Claim<'_, T> {
    fn deref_mut(&mut self) -> &mut T {
        unsafe { &mut *self.0.value.get() }
    }
}

impl<T> Drop for Claim<'_, T> {
    fn drop(&mut self) {
        self.0.busy.store(false, Ordering::Release);
    }
}

pub enum Msg {
    InsertTrack {
        slot: Slot,
        track: Box<TrackRt>,
    },
    RemoveTrack {
        slot: Slot,
    },
    SetSchedule(Box<Schedule>),
    SetMix {
        slot: Slot,
        gain: f32,
        pan: f32,
        mute: bool,
        /// Silenced by another track's solo (see `TrackRt::quiet`).
        quiet: bool,
    },
    InsertDevice {
        slot: Slot,
        device: Box<dyn Device>,
    },
    /// Give a device a buffer for its side-chain, which the track it listens
    /// to fills each block, or take it away with `None`.
    SetKey {
        device: Slot,
        key: Option<Box<KeyBuf>>,
    },
    /// Give a device buffers for its further output pairs, as many as are
    /// routed somewhere, or take them away with `None`.
    SetOutputs {
        device: Slot,
        outs: Option<Box<OutBufs>>,
    },
    RemoveDevice {
        slot: Slot,
    },
    SetChain {
        track: Slot,
        chain: Box<[Slot]>,
    },
    SetParam {
        device: Slot,
        param: u32,
        value: f32,
    },
    SetBypass {
        device: Slot,
        bypass: bool,
    },
    /// The wet/dry mix and gain the host puts around a device (see `host`).
    SetHost {
        device: Slot,
        path: Box<crate::host::HostPath>,
    },
    /// Frames the device's output is behind its input, for the dry signal.
    SetDeviceLatency {
        device: Slot,
        frames: u32,
    },
    SetClips {
        track: Slot,
        clips: Box<ClipSet>,
    },
    /// While playing, the lanes set the track's fader, pan and device
    /// parameters at the start of each block, over whatever was set directly.
    SetAutomation {
        track: Slot,
        automation: Box<Automation>,
    },
    /// Follow a new tempo map from the next block on.
    SetTempoMap(Box<TempoMap>),
    /// Change the first tempo of the map, keeping its other points.
    SetTempo(f64),
    /// Change the first signature of the map, keeping its other points.
    SetTimeSig {
        num: u32,
        den: u32,
    },
    SetLoop {
        enabled: bool,
        start: f64,
        end: f64,
    },
    SetMetronome(bool),
    Play,
    /// Count in, then play: click `clicks` times, `every` frames apart and
    /// the first of every `per_bar` higher, and start playing on the frame
    /// `frames` from now, where the next click would have been. The clicks
    /// are heard as late as the song is (the schedule's latency), so that
    /// they lead into it evenly. [`Msg::Stop`] calls it off.
    CountIn {
        frames: u64,
        every: f64,
        clicks: u32,
        per_bar: u32,
    },
    Stop,
    Seek(f64),
    /// A note played live rather than from a clip, delivered at the next block.
    Live {
        track: Slot,
        event: EventKind,
    },
    /// Which input channels a track takes (`channels` is 0 for none), whether
    /// they are heard, and whether the track is armed.
    SetInput {
        track: Slot,
        first: usize,
        channels: usize,
        monitor: bool,
        armed: bool,
    },
    /// Which MIDI input an armed track without audio input takes: a port's
    /// key ([`crate::midi::port_key`]) or 0 for all, a channel from 1 to 16
    /// or 0 for all.
    SetMidiInput {
        track: Slot,
        port: u32,
        channel: u8,
    },
    /// The MIDI output port a track sends what it plays to, by its key (0
    /// for none), on a channel from 1 to 16 or 0 for each message's own,
    /// in a form for ports that take no MIDI 2.0.
    SetMidiOutput {
        track: Slot,
        port: u32,
        channel: u8,
        form: crate::midi_form::Form,
    },
    /// Where MIDI output goes: the queue a sender thread reads (see
    /// [`EngineHandle::midi_output`]), or nowhere.
    SetMidiOut(Option<Box<Producer<MidiOut>>>),
    /// Start capturing into a take, or stop with `None`.
    SetTake(Option<Box<Take>>),
    /// A note as if it came from a MIDI input port, by its key (0 for none
    /// in particular, which only tracks that take every port hear).
    MidiIn {
        port: u32,
        kind: EventKind,
    },
    /// Worker threads to process tracks on, or `None` for the audio thread alone.
    SetPool(Option<Box<Pool>>),
}

enum Garbage {
    Track(#[allow(dead_code)] Box<TrackRt>),
    Device(#[allow(dead_code)] Box<dyn Device>),
    Schedule(#[allow(dead_code)] Box<Schedule>),
    Chain(#[allow(dead_code)] Box<[Slot]>),
    Clips(#[allow(dead_code)] Box<ClipSet>),
    Automation(#[allow(dead_code)] Box<Automation>),
    Take(#[allow(dead_code)] Box<Take>),
    Pool(#[allow(dead_code)] Box<Pool>),
    Host(#[allow(dead_code)] Box<crate::host::HostPath>),
    Key(#[allow(dead_code)] Box<KeyBuf>),
    Outs(#[allow(dead_code)] Box<OutBufs>),
    MidiOut(#[allow(dead_code)] Box<Producer<MidiOut>>),
    TempoMap(#[allow(dead_code)] Box<TempoMap>),
}

/// Buckets of [`BlockStats`]: four per octave of processing time, from
/// [`BLOCK_STATS_FLOOR_NS`] up, which reaches past 10 seconds.
pub const BLOCK_BUCKETS: usize = 100;
/// Times below this land in the first bucket.
pub const BLOCK_STATS_FLOOR_NS: f64 = 250.0;

/// How long each call to [`Engine::process_input`] took, as a histogram the
/// audio thread fills with relaxed atomic adds: no allocation, no locks.
pub struct BlockStats {
    count: AtomicU64,
    frames: AtomicU64,
    total_ns: AtomicU64,
    max_ns: AtomicU64,
    buckets: [AtomicU64; BLOCK_BUCKETS],
}

/// A copy of [`BlockStats`] for the main thread to read.
#[derive(Clone, Debug, Default)]
pub struct BlockSummary {
    pub count: u64,
    pub frames: u64,
    pub total_ns: u64,
    pub max_ns: u64,
    pub buckets: Vec<u64>,
}

impl BlockStats {
    fn new() -> Self {
        Self {
            count: AtomicU64::new(0),
            frames: AtomicU64::new(0),
            total_ns: AtomicU64::new(0),
            max_ns: AtomicU64::new(0),
            buckets: std::array::from_fn(|_| AtomicU64::new(0)),
        }
    }

    /// The bucket a time falls in.
    pub fn bucket(ns: u64) -> usize {
        let ratio = ns as f64 / BLOCK_STATS_FLOOR_NS;
        if ratio < 1.0 {
            return 0;
        }
        ((ratio.log2() * 4.0) as usize + 1).min(BLOCK_BUCKETS - 1)
    }

    /// The upper edge of a bucket, in nanoseconds.
    pub fn bucket_limit_ns(index: usize) -> f64 {
        BLOCK_STATS_FLOOR_NS * 2f64.powf(index as f64 / 4.0)
    }

    pub fn record(&self, ns: u64, frames: usize) {
        self.count.fetch_add(1, Relaxed);
        self.frames.fetch_add(frames as u64, Relaxed);
        self.total_ns.fetch_add(ns, Relaxed);
        self.max_ns.fetch_max(ns, Relaxed);
        self.buckets[Self::bucket(ns)].fetch_add(1, Relaxed);
    }

    pub fn reset(&self) {
        self.count.store(0, Relaxed);
        self.frames.store(0, Relaxed);
        self.total_ns.store(0, Relaxed);
        self.max_ns.store(0, Relaxed);
        for b in &self.buckets {
            b.store(0, Relaxed);
        }
    }

    pub fn summary(&self) -> BlockSummary {
        BlockSummary {
            count: self.count.load(Relaxed),
            frames: self.frames.load(Relaxed),
            total_ns: self.total_ns.load(Relaxed),
            max_ns: self.max_ns.load(Relaxed),
            buckets: self.buckets.iter().map(|b| b.load(Relaxed)).collect(),
        }
    }
}

impl BlockSummary {
    /// The time below which a fraction `q` of the calls finished, to within
    /// a bucket (19%), in nanoseconds. Never above the largest time seen.
    pub fn quantile_ns(&self, q: f64) -> f64 {
        let total: u64 = self.buckets.iter().sum();
        if total == 0 {
            return 0.0;
        }
        let want = (q * total as f64).ceil().max(1.0) as u64;
        let mut seen = 0;
        for (i, n) in self.buckets.iter().enumerate() {
            seen += n;
            if seen >= want {
                return BlockStats::bucket_limit_ns(i).min(self.max_ns as f64);
            }
        }
        self.max_ns as f64
    }
}

/// State the audio thread publishes for everyone else to read.
pub struct Shared {
    position: AtomicU64,
    playing: AtomicBool,
    meters: Vec<[AtomicU32; 2]>,
    cpu: AtomicU32,
    xruns: AtomicU32,
    leaked: AtomicU32,
    seeks: AtomicU32,
    input_latency: AtomicU32,
    output_latency: AtomicU32,
    /// Frames the backend asked for in its last callback.
    period: AtomicU32,
    /// Peak level of each input channel, falling as track meters do.
    input_meters: [AtomicU32; MAX_INPUTS],
    latency: AtomicU32,
    threads: AtomicU32,
    /// Clicks of a count-in still to come before the song starts; 0 when
    /// there is no count under way.
    counting: AtomicU32,
    /// Processing time of every callback.
    pub blocks: BlockStats,
    /// What has gone wrong with each device slot: [`guard::PANICKED`],
    /// [`guard::NOT_FINITE`]. Cleared when a device is put in the slot.
    faults: Vec<AtomicU8>,
}

impl Shared {
    /// Things the audio thread could not hand back to be freed and leaked
    /// instead, because the garbage queue was full.
    pub fn leaked(&self) -> u32 {
        self.leaked.load(Relaxed)
    }

    /// How many [`Msg::Seek`] the engine has carried out. [`position`](Self::position)
    /// reflects a seek once this has counted it.
    pub fn seeks(&self) -> u32 {
        self.seeks.load(Relaxed)
    }

    /// Transport position in beats.
    pub fn position(&self) -> f64 {
        f64::from_bits(self.position.load(Relaxed))
    }

    pub fn playing(&self) -> bool {
        self.playing.load(Relaxed)
    }

    /// Beats of a count-in still to be counted before the song starts, or 0.
    pub fn counting(&self) -> u32 {
        self.counting.load(Relaxed)
    }

    /// Post-fader peak level of a track as linear `(left, right)`.
    pub fn meter(&self, slot: Slot) -> (f32, f32) {
        match self.meters.get(slot as usize) {
            Some(m) => (
                f32::from_bits(m[0].load(Relaxed)),
                f32::from_bits(m[1].load(Relaxed)),
            ),
            None => (0.0, 0.0),
        }
    }

    /// Fraction of the available time the last callbacks spent processing.
    pub fn cpu(&self) -> f32 {
        f32::from_bits(self.cpu.load(Relaxed))
    }

    pub fn set_cpu(&self, load: f32) {
        self.cpu.store(load.to_bits(), Relaxed);
    }

    pub fn xruns(&self) -> u32 {
        self.xruns.load(Relaxed)
    }

    /// What has gone wrong with the device in `slot` since it was put there
    /// ([`guard::PANICKED`], [`guard::NOT_FINITE`]); the bits in `clear` are
    /// taken, so that each is reported once.
    pub fn fault(&self, slot: Slot, clear: u8) -> u8 {
        self.faults
            .get(slot as usize)
            .map_or(0, |f| f.fetch_and(!clear, Relaxed))
    }

    fn set_fault(&self, slot: Slot, fault: u8) {
        if let Some(f) = self.faults.get(slot as usize) {
            f.fetch_or(fault, Relaxed);
        }
    }

    pub fn add_xrun(&self) {
        self.xruns.fetch_add(1, Relaxed);
    }

    /// Frames by which the output is behind the transport: the latency of
    /// the slowest path through the devices, which every other path waits for.
    pub fn latency(&self) -> u32 {
        self.latency.load(Relaxed)
    }

    /// Threads the engine processes tracks on, counting the audio thread.
    pub fn threads(&self) -> u32 {
        self.threads.load(Relaxed)
    }

    /// Seconds the backend holds input back before the engine sees it.
    pub fn input_latency(&self) -> f32 {
        f32::from_bits(self.input_latency.load(Relaxed))
    }

    pub fn set_input_latency(&self, seconds: f32) {
        self.input_latency.store(seconds.to_bits(), Relaxed);
    }

    /// Seconds from the engine producing a block to it being heard, as the
    /// backend reports it.
    pub fn output_latency(&self) -> f32 {
        f32::from_bits(self.output_latency.load(Relaxed))
    }

    pub fn set_output_latency(&self, seconds: f32) {
        self.output_latency.store(seconds.to_bits(), Relaxed);
    }

    /// Frames per callback as the backend last asked for them, 0 before the first.
    pub fn period(&self) -> u32 {
        self.period.load(Relaxed)
    }

    pub fn set_period(&self, frames: u32) {
        self.period.store(frames, Relaxed);
    }

    /// Peak level of input channel `channel` (from 0) as linear gain,
    /// whether or not any track takes it.
    pub fn input_meter(&self, channel: usize) -> f32 {
        self.input_meters
            .get(channel)
            .map_or(0.0, |m| f32::from_bits(m.load(Relaxed)))
    }
}

/// A device's side-chain input: a block of the track it listens to.
pub type KeyBuf = [Vec<f32>; 2];

/// A buffer for a side-chain, made on the main thread.
pub fn key_buf() -> Box<KeyBuf> {
    Box::new([vec![0.0; MAX_BLOCK], vec![0.0; MAX_BLOCK]])
}

/// A device's further output pairs: see [`Io::outputs`].
pub type OutBufs = Vec<Option<[Vec<f32>; 2]>>;

/// Buffers for the further output pairs that are routed, by their index
/// (0 for the second pair), made on the main thread.
pub fn out_bufs(routed: &[usize]) -> Box<OutBufs> {
    let count = routed.iter().map(|i| i + 1).max().unwrap_or(0);
    Box::new(
        (0..count)
            .map(|i| routed.contains(&i).then(|| [vec![0.0; MAX_BLOCK], vec![0.0; MAX_BLOCK]]))
            .collect(),
    )
}

struct DeviceSlot {
    device: Box<dyn Device>,
    bypass: bool,
    host: Option<Box<crate::host::HostPath>>,
    /// Where the track it listens to puts its sound, when it has a side-chain.
    key: Option<Box<KeyBuf>>,
    /// Where it puts its further output pairs, when some are routed.
    outs: Option<Box<OutBufs>>,
    /// It panicked: it is not run again, and what comes in goes on as it is.
    failed: bool,
    /// Its output held NaN or infinity, and that has been reported.
    flagged: bool,
}

impl DeviceSlot {
    /// A parameter of the device, or of the host's mix after the device's own.
    fn set_param(&mut self, index: u32, value: f32) {
        if !self
            .host
            .as_mut()
            .is_some_and(|h| h.set_param(index, value))
        {
            self.device.set_param(index, value);
        }
    }

    /// Run the device with the host's mix around it. False if it panicked.
    fn process(&mut self, ctx: &ProcessCtx, io: &mut Io) -> bool {
        match self.host.as_mut() {
            Some(host) => host.process(&mut *self.device, self.bypass, ctx, io),
            None if !self.bypass => guard::process(&mut *self.device, ctx, io),
            None => true,
        }
    }
}

#[derive(Default)]
struct Click {
    phase: f32,
    env: f32,
    freq: f32,
}

pub struct Engine {
    sample_rate: f64,
    tracks: Vec<Guarded<Option<Box<TrackRt>>>>,
    devices: Vec<Guarded<Option<DeviceSlot>>>,
    pool: Option<Box<Pool>>,
    schedule: Option<Box<Schedule>>,
    rx: Consumer<Msg>,
    garbage: Producer<Garbage>,
    shared: Arc<Shared>,
    /// Taken out while a block is processed, so that the tracks can read
    /// it while the engine is borrowed; always there between blocks.
    map: Option<Box<TempoMap>>,
    playing: bool,
    position: f64,
    loop_enabled: bool,
    loop_start: f64,
    loop_end: f64,
    metronome: bool,
    flush_notes: bool,
    /// Playback is about to start somewhere new: notes already under way at
    /// that position need to be started.
    chase: bool,
    /// Automated parameters must be sent again even if their value has not
    /// moved, because something else may have set them since.
    reapply: bool,
    seeks: u32,
    click: Click,
    /// The current block of input, one buffer per channel.
    inputs: Vec<Vec<f32>>,
    input_count: usize,
    take: Option<Box<Take>>,
    midi_rx: Consumer<(u32, EventKind)>,
    /// A count-in under way, or whose last clicks are still to be heard.
    count: Option<Count>,
    /// Where tracks' MIDI output goes, when something sends it on.
    midi_out: Option<Box<Producer<MidiOut>>>,
    /// When the block being made is heard, on [`midi_out::clock_ns`].
    ///
    /// [`midi_out::clock_ns`]: crate::midi_out::clock_ns
    heard_ns: u64,
}

/// A count-in: see [`Msg::CountIn`]. Frames count from when it began.
#[derive(Clone, Copy, Debug)]
struct Count {
    frames: u64,
    every: f64,
    clicks: u32,
    per_bar: u32,
    /// How late its clicks are heard, as the song is: the schedule's latency.
    delay: u64,
    elapsed: u64,
    /// The next click to sound, and whether the song has started.
    next: u32,
    started: bool,
}

impl Count {
    /// Where the clicks of the next `n` frames fall in them.
    fn clicks(&mut self, n: usize, starts: &mut [(usize, bool)], count: &mut usize) {
        while self.next < self.clicks {
            let at = (self.next as f64 * self.every).round() as u64 + self.delay;
            if at >= self.elapsed + n as u64 {
                break;
            }
            if at >= self.elapsed && *count < starts.len() {
                starts[*count] = ((at - self.elapsed) as usize, self.next % self.per_bar == 0);
                *count += 1;
            }
            self.next += 1;
        }
    }

    /// Beats still to be counted before the song starts.
    fn left(&self) -> u32 {
        if self.started {
            return 0;
        }
        (((self.frames - self.elapsed.min(self.frames)) as f64 / self.every.max(1.0)).ceil() as u32)
            .max(1)
    }
}

/// The main thread's end of the engine.
pub struct EngineHandle {
    tx: Producer<Msg>,
    garbage: Consumer<Garbage>,
    pub shared: Arc<Shared>,
    pub sample_rate: f64,
    midi_tx: Option<Producer<(u32, EventKind)>>,
}

impl EngineHandle {
    /// The sending end of the engine's MIDI input queue, for the one thread
    /// that reads MIDI ports. Notes pushed into it reach every armed track at
    /// the start of the next callback.
    /// Each message comes with the key of the port it came from.
    pub fn take_midi_input(&mut self) -> Option<Producer<(u32, EventKind)>> {
        self.midi_tx.take()
    }

    /// The receiving end of a new queue of the MIDI the tracks send to their
    /// output ports, for the one thread that sends it on
    /// ([`MidiOutputs::set_queue`]). Until one is asked for, nothing is
    /// sent: an offline render never is.
    ///
    /// [`MidiOutputs::set_queue`]: crate::midi_out::MidiOutputs::set_queue
    pub fn midi_output(&mut self) -> Consumer<MidiOut> {
        let (tx, rx) = RingBuffer::new(crate::midi_out::MIDI_OUT_CAPACITY);
        self.send(Msg::SetMidiOut(Some(Box::new(tx))));
        rx
    }

    /// Queue a message, or hand it back if the queue is full.
    pub fn try_send(&mut self, msg: Msg) -> Result<(), Msg> {
        self.tx.push(msg).map_err(|PushError::Full(msg)| msg)
    }

    /// Queue a message, waiting for the audio thread to make room if needed.
    /// Only call this while something is driving [`Engine::process`].
    pub fn send(&mut self, msg: Msg) {
        let mut msg = msg;
        while let Err(back) = self.try_send(msg) {
            msg = back;
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
    }

    /// Queue a message for an engine this thread drives itself, pumping the
    /// engine to make room if the queue is full.
    pub fn send_while(&mut self, msg: Msg, engine: &mut Engine) {
        let mut msg = msg;
        while let Err(back) = self.try_send(msg) {
            msg = back;
            engine.pump();
        }
    }

    /// Free whatever the audio thread has finished with.
    pub fn collect_garbage(&mut self) {
        while self.garbage.pop().is_ok() {}
    }
}

impl Engine {
    pub fn new(sample_rate: f64) -> (Engine, EngineHandle) {
        let (tx, rx) = RingBuffer::new(MSG_CAPACITY);
        let (garbage_tx, garbage_rx) = RingBuffer::new(GARBAGE_CAPACITY);
        let (midi_tx, midi_rx) = RingBuffer::new(MIDI_IN_CAPACITY);
        let shared = Arc::new(Shared {
            position: AtomicU64::new(0f64.to_bits()),
            playing: AtomicBool::new(false),
            meters: (0..MAX_TRACKS)
                .map(|_| [AtomicU32::new(0), AtomicU32::new(0)])
                .collect(),
            cpu: AtomicU32::new(0),
            xruns: AtomicU32::new(0),
            leaked: AtomicU32::new(0),
            seeks: AtomicU32::new(0),
            input_latency: AtomicU32::new(0),
            output_latency: AtomicU32::new(0),
            period: AtomicU32::new(0),
            input_meters: std::array::from_fn(|_| AtomicU32::new(0)),
            latency: AtomicU32::new(0),
            threads: AtomicU32::new(1),
            counting: AtomicU32::new(0),
            blocks: BlockStats::new(),
            faults: (0..MAX_DEVICES).map(|_| AtomicU8::new(0)).collect(),
        });
        let mut tracks: Vec<Guarded<Option<Box<TrackRt>>>> =
            (0..MAX_TRACKS).map(|_| Guarded::new(None)).collect();
        *tracks[MASTER as usize].get_mut() = Some(TrackRt::new());
        let schedule = Schedule::new(vec![SchedEntry::new(MASTER, NO_SLOT)], 0);
        let engine = Engine {
            sample_rate,
            tracks,
            devices: (0..MAX_DEVICES).map(|_| Guarded::new(None)).collect(),
            pool: None,
            schedule: Some(Box::new(schedule)),
            rx,
            garbage: garbage_tx,
            shared: shared.clone(),
            map: Some(Box::new(TempoMap::default())),
            playing: false,
            position: 0.0,
            loop_enabled: false,
            loop_start: 0.0,
            loop_end: 4.0,
            metronome: false,
            flush_notes: false,
            chase: false,
            reapply: false,
            seeks: 0,
            click: Click::default(),
            inputs: (0..MAX_INPUTS).map(|_| vec![0.0; MAX_BLOCK]).collect(),
            input_count: 0,
            take: None,
            midi_rx,
            count: None,
            midi_out: None,
            heard_ns: 0,
        };
        (
            engine,
            EngineHandle {
                tx,
                garbage: garbage_rx,
                shared,
                sample_rate,
                midi_tx: Some(midi_tx),
            },
        )
    }

    pub fn sample_rate(&self) -> f64 {
        self.sample_rate
    }

    pub fn shared(&self) -> &Arc<Shared> {
        &self.shared
    }

    /// Process tracks on the threads of a pool as well as on the calling
    /// thread, or with `None` on the calling thread alone. For an engine not
    /// yet handed to an audio thread; one that has been takes [`Msg::SetPool`].
    pub fn set_pool(&mut self, pool: Option<Box<Pool>>) -> Option<Box<Pool>> {
        let threads = pool.as_ref().map_or(1, |pool| pool.threads());
        self.shared.threads.store(threads as u32, Relaxed);
        std::mem::replace(&mut self.pool, pool)
    }

    fn discard(&mut self, garbage: Garbage) {
        if let Err(PushError::Full(garbage)) = self.garbage.push(garbage) {
            // Freeing here would block the audio thread, so leak instead.
            std::mem::forget(garbage);
            self.shared.leaked.fetch_add(1, Relaxed);
        }
    }

    /// Apply every queued message. Called at the start of each [`process`](Self::process).
    pub fn pump(&mut self) {
        while let Ok(msg) = self.rx.pop() {
            self.apply(msg);
        }
        while let Ok((port, kind)) = self.midi_rx.pop() {
            self.midi_in(port, kind);
        }
    }

    fn apply(&mut self, msg: Msg) {
        match msg {
            Msg::InsertTrack { slot, track } => {
                if let Some(entry) = self.tracks.get_mut(slot as usize) {
                    if let Some(old) = entry.get_mut().replace(track) {
                        self.discard(Garbage::Track(old));
                    }
                } else {
                    self.discard(Garbage::Track(track));
                }
            }
            Msg::RemoveTrack { slot } => {
                if let Some(old) = self
                    .tracks
                    .get_mut(slot as usize)
                    .and_then(|t| t.get_mut().take())
                {
                    self.discard(Garbage::Track(old));
                }
            }
            Msg::SetSchedule(schedule) => {
                self.shared.latency.store(schedule.latency, Relaxed);
                if let Some(old) = self.schedule.replace(schedule) {
                    self.discard(Garbage::Schedule(old));
                }
            }
            Msg::SetMix {
                slot,
                gain,
                pan,
                mute,
                quiet,
            } => {
                if let Some(track) = self.track_mut(slot) {
                    track.gain = gain;
                    track.pan = pan;
                    track.mute = mute;
                    track.quiet = quiet;
                    if !track.started {
                        track.applied = track.target_gains();
                        track.applied_heard = if quiet { 0.0 } else { 1.0 };
                    }
                }
            }
            Msg::InsertDevice { slot, device } => {
                if let Some(entry) = self.devices.get_mut(slot as usize) {
                    self.shared.faults[slot as usize].store(0, Relaxed);
                    // A device put in place of another (one that was being
                    // made, or restarted) listens where that one did.
                    let key = entry.get_mut().as_mut().and_then(|old| old.key.take());
                    let outs = entry.get_mut().as_mut().and_then(|old| old.outs.take());
                    if let Some(old) = entry.get_mut().replace(DeviceSlot {
                        device,
                        bypass: false,
                        host: None,
                        key,
                        outs,
                        failed: false,
                        flagged: false,
                    }) {
                        self.discard(Garbage::Device(old.device));
                        if let Some(host) = old.host {
                            self.discard(Garbage::Host(host));
                        }
                    }
                } else {
                    self.discard(Garbage::Device(device));
                }
            }
            Msg::RemoveDevice { slot } => {
                if let Some(old) = self
                    .devices
                    .get_mut(slot as usize)
                    .and_then(|d| d.get_mut().take())
                {
                    self.discard(Garbage::Device(old.device));
                    if let Some(host) = old.host {
                        self.discard(Garbage::Host(host));
                    }
                    if let Some(key) = old.key {
                        self.discard(Garbage::Key(key));
                    }
                    if let Some(outs) = old.outs {
                        self.discard(Garbage::Outs(outs));
                    }
                }
            }
            Msg::SetKey { device, key } => {
                let old = match self.device_mut(device) {
                    Some(slot) => std::mem::replace(&mut slot.key, key),
                    None => key,
                };
                if let Some(old) = old {
                    self.discard(Garbage::Key(old));
                }
            }
            Msg::SetOutputs { device, outs } => {
                let old = match self.device_mut(device) {
                    Some(slot) => std::mem::replace(&mut slot.outs, outs),
                    None => outs,
                };
                if let Some(old) = old {
                    self.discard(Garbage::Outs(old));
                }
            }
            Msg::SetHost { device, path } => match self.device_mut(device) {
                Some(slot) => {
                    if let Some(old) = slot.host.replace(path) {
                        self.discard(Garbage::Host(old));
                    }
                }
                None => self.discard(Garbage::Host(path)),
            },
            Msg::SetDeviceLatency { device, frames } => {
                if let Some(host) = self.device_mut(device).and_then(|s| s.host.as_mut()) {
                    host.set_latency(frames);
                }
            }
            Msg::SetChain { track, chain } => match self.track_mut(track) {
                Some(t) => {
                    let old = std::mem::replace(&mut t.chain, chain);
                    self.discard(Garbage::Chain(old));
                }
                None => self.discard(Garbage::Chain(chain)),
            },
            Msg::SetParam {
                device,
                param,
                value,
            } => {
                if let Some(slot) = self.device_mut(device) {
                    slot.set_param(param, value);
                }
                self.reapply = true;
            }
            Msg::SetBypass { device, bypass } => {
                if let Some(slot) = self.device_mut(device) {
                    slot.bypass = bypass;
                }
            }
            Msg::SetClips { track, clips } => match self.track_mut(track) {
                Some(t) => {
                    let old = std::mem::replace(&mut t.clips, clips);
                    // Notes that were sounding may no longer have a note-off.
                    t.flush = true;
                    t.chase = true;
                    self.discard(Garbage::Clips(old));
                }
                None => self.discard(Garbage::Clips(clips)),
            },
            Msg::SetAutomation { track, automation } => match self.track_mut(track) {
                Some(t) => {
                    let old = std::mem::replace(&mut t.automation, automation);
                    self.discard(Garbage::Automation(old));
                }
                None => self.discard(Garbage::Automation(automation)),
            },
            Msg::SetTempoMap(map) => {
                if let Some(old) = self.map.replace(map) {
                    self.discard(Garbage::TempoMap(old));
                }
            }
            Msg::SetTempo(tempo) => {
                if let Some(map) = self.map.as_deref_mut() {
                    map.set_first_tempo(tempo);
                }
            }
            Msg::SetTimeSig { num, den } => {
                if let Some(map) = self.map.as_deref_mut() {
                    map.set_first_signature(num, den);
                }
            }
            Msg::SetLoop {
                enabled,
                start,
                end,
            } => {
                self.loop_enabled = enabled && end > start;
                self.loop_start = start;
                self.loop_end = end;
            }
            Msg::SetMetronome(on) => self.metronome = on,
            Msg::Play => {
                self.playing = true;
                self.chase = true;
                self.reapply = true;
                self.count = None;
            }
            Msg::CountIn {
                frames,
                every,
                clicks,
                per_bar,
            } => {
                self.playing = false;
                self.count = Some(Count {
                    frames,
                    every,
                    clicks,
                    per_bar: per_bar.max(1),
                    delay: self.schedule.as_ref().map_or(0, |s| s.latency as u64),
                    elapsed: 0,
                    next: 0,
                    started: false,
                });
            }
            Msg::Stop => {
                self.playing = false;
                self.flush_notes = true;
                self.count = None;
            }
            Msg::Seek(position) => {
                self.position = position.max(0.0);
                self.flush_notes = true;
                self.chase = true;
                self.reapply = true;
                self.seeks = self.seeks.wrapping_add(1);
            }
            Msg::Live { track, event } => {
                if let Some(t) = self.track_mut(track)
                    && t.live.len() < t.live.capacity()
                {
                    t.live.push(event);
                }
            }
            Msg::SetInput {
                track,
                first,
                channels,
                monitor,
                armed,
            } => {
                if let Some(t) = self.track_mut(track) {
                    t.input_first = first;
                    t.input_channels = channels;
                    t.monitor = monitor;
                    t.armed = armed;
                    if !t.takes_midi() {
                        release_held(t);
                    }
                }
            }
            Msg::SetTake(take) => {
                if let Some(old) = std::mem::replace(&mut self.take, take) {
                    old.shared.close(self.position);
                    self.discard(Garbage::Take(old));
                }
            }
            Msg::SetMidiInput {
                track,
                port,
                channel,
            } => {
                if let Some(t) = self.track_mut(track) {
                    if (t.midi_port, t.midi_channel) != (port, channel) {
                        release_held(t);
                    }
                    t.midi_port = port;
                    t.midi_channel = channel;
                }
            }
            Msg::MidiIn { port, kind } => self.midi_in(port, kind),
            Msg::SetMidiOutput {
                track,
                port,
                channel,
                form,
            } => {
                let Some(t) = self.track_mut(track) else {
                    return;
                };
                let old = std::mem::replace(&mut t.midi_out, port);
                let old_form = std::mem::replace(&mut t.midi_out_form, form);
                t.midi_out_channel = channel;
                t.sent.clear();
                // The notes it left sounding where it played before, or in
                // the form it played in before, end there.
                if old != 0
                    && (old != port || old_form != form)
                    && let Some(out) = self.midi_out.as_deref_mut()
                {
                    let _ = out.push(MidiOut {
                        at: 0,
                        port: old,
                        form: old_form,
                        kind: EventKind::AllNotesOff,
                    });
                }
            }
            Msg::SetMidiOut(out) => {
                if let Some(old) = std::mem::replace(&mut self.midi_out, out) {
                    self.discard(Garbage::MidiOut(old));
                }
            }
            Msg::SetPool(pool) => {
                if let Some(old) = self.set_pool(pool) {
                    self.discard(Garbage::Pool(old));
                }
            }
        }
    }

    /// Deliver a note from MIDI input to every track that takes it, and
    /// capture it for the take when recording.
    fn midi_in(&mut self, port: u32, kind: EventKind) {
        let Some(schedule) = self.schedule.take() else {
            return;
        };
        let position = self.position;
        let mut capture = self
            .take
            .as_deref_mut()
            .filter(|take| self.playing && take.captures_at(position));
        for entry in &schedule.entries {
            let Some(t) = self
                .tracks
                .get_mut(entry.slot as usize)
                .and_then(|t| t.get_mut().as_deref_mut())
            else {
                continue;
            };
            if !t.hears(port, &kind) {
                continue;
            }
            match kind {
                EventKind::NoteOn { key, .. } => t.held |= 1 << (key & 127),
                EventKind::NoteOff { key, .. } => t.held &= !(1 << (key & 127)),
                EventKind::AllNotesOff => t.held = 0,
                _ => {}
            }
            if t.live.len() < t.live.capacity() {
                t.live.push(kind);
            }
            if let Some(take) = capture.as_deref_mut() {
                take.shared.begin(self.position);
                let _ = take.midi.push(MidiCapture {
                    slot: entry.slot,
                    beat: self.position,
                    kind,
                    pass: take.pass,
                });
            }
        }
        self.schedule = Some(schedule);
    }

    /// Copy `n` frames of input, starting at frame `at`, out of an interleaved buffer.
    ///
    /// Each channel's level is metered here, whatever takes it, so that a
    /// signal can be seen arriving before a track is armed or monitored.
    fn load_input(&mut self, input: &[f32], channels: usize, at: usize, n: usize) {
        self.input_count = channels.min(MAX_INPUTS);
        let fall = (-(n as f32) / (self.sample_rate as f32 * METER_FALL_SECONDS)).exp();
        for (ch, buf) in self.inputs[..self.input_count].iter_mut().enumerate() {
            let mut peak = 0.0f32;
            for (i, s) in buf[..n].iter_mut().enumerate() {
                *s = input.get((at + i) * channels + ch).copied().unwrap_or(0.0);
                peak = peak.max(s.abs());
            }
            let meter = &self.shared.input_meters[ch];
            let held = f32::from_bits(meter.load(Relaxed)) * fall;
            meter.store(peak.max(held).to_bits(), Relaxed);
        }
        // Channels the device no longer has fall silent.
        for meter in &self.shared.input_meters[self.input_count..] {
            if meter.load(Relaxed) != 0 {
                meter.store(0, Relaxed);
            }
        }
    }

    /// Copy this block's input into the take, for every track it records.
    fn capture(&mut self, n: usize, start: f64) {
        let Self {
            take,
            inputs,
            input_count,
            playing,
            ..
        } = self;
        let Some(take) = take
            .as_deref_mut()
            .filter(|take| *playing && take.captures_at(start))
        else {
            return;
        };
        take.shared.begin(start);
        take.frames += n as u64;
        for cap in &mut take.audio {
            let Ok(mut chunk) = cap.ring.write_chunk(n * cap.channels) else {
                take.shared.add_dropped(n as u64);
                continue;
            };
            let (a, b) = chunk.as_mut_slices();
            for (i, s) in a.iter_mut().chain(b.iter_mut()).enumerate() {
                let ch = cap.first + i % cap.channels;
                *s = if ch < *input_count {
                    inputs[ch][i / cap.channels]
                } else {
                    0.0
                };
            }
            chunk.commit_all();
        }
    }

    fn track_mut(&mut self, slot: Slot) -> Option<&mut TrackRt> {
        self.tracks.get_mut(slot as usize)?.get_mut().as_deref_mut()
    }

    fn device_mut(&mut self, slot: Slot) -> Option<&mut DeviceSlot> {
        self.devices.get_mut(slot as usize)?.get_mut().as_mut()
    }

    /// Render the next `left.len()` frames with no input. `left` and `right`
    /// must be the same length.
    pub fn process(&mut self, left: &mut [f32], right: &mut [f32]) {
        self.process_input(&[], 0, left, right);
    }

    /// Render the next `left.len()` frames, with `input` holding as many
    /// frames of `channels` interleaved input channels.
    pub fn process_input(
        &mut self,
        input: &[f32],
        channels: usize,
        left: &mut [f32],
        right: &mut [f32],
    ) {
        let began = std::time::Instant::now();
        let callback_ns = crate::midi_out::clock_ns();
        self.pump();
        if let Some(pool) = &self.pool {
            // Fewer than it was given, if its workers were refused the
            // priority of this thread.
            self.shared.threads.store(pool.threads() as u32, Relaxed);
        }
        let total = left.len().min(right.len());
        let sr = self.sample_rate;
        let mut done = 0;
        while done < total {
            // A count-in that has run its course starts the song on this frame.
            if let Some(count) = self.count.as_mut()
                && !count.started
                && count.elapsed >= count.frames
            {
                count.started = true;
                self.playing = true;
                self.chase = true;
                self.reapply = true;
            }
            let mut n = (total - done).min(MAX_BLOCK);
            if let Some(count) = self.count.as_ref().filter(|c| !c.started) {
                n = n.min((count.frames - count.elapsed) as usize);
            }
            let start = self.position;
            let mut end = start;
            let mut wrap = false;
            if let Some(map) = self.map.as_deref().filter(|_| self.playing) {
                let t0 = map.seconds(start);
                // One tempo throughout: beats per frame, as plain arithmetic.
                let bpf = map.is_constant().then(|| map.first_tempo() / (60.0 * sr));
                let frames_to = |beat: f64| match bpf {
                    Some(bpf) => ((beat - start) / bpf).ceil() as usize,
                    None => ((map.seconds(beat) - t0) * sr).ceil() as usize,
                };
                if self.loop_enabled && start < self.loop_end {
                    let to_loop_end = frames_to(self.loop_end);
                    if to_loop_end <= n {
                        n = to_loop_end.max(1);
                        wrap = true;
                    }
                }
                // A punched take starts and stops capturing on the frame:
                // the block ends where it punches in or out.
                if let Some((from, to)) = self.take.as_ref().and_then(|t| t.punch) {
                    // On the frame: a point a rounding error off a frame is on it.
                    let frames_on = |beat: f64| {
                        let x = match bpf {
                            Some(bpf) => (beat - start) / bpf,
                            None => (map.seconds(beat) - t0) * sr,
                        };
                        if (x - x.round()).abs() < 1e-6 {
                            x.round() as usize
                        } else {
                            x.ceil() as usize
                        }
                    };
                    for edge in [from, to] {
                        if edge - start > PUNCH_EPS {
                            let frames = frames_on(edge).max(1);
                            if frames < n {
                                n = frames;
                                wrap = false;
                            }
                        }
                    }
                }
                end = match (wrap, bpf) {
                    (true, _) => self.loop_end,
                    (false, Some(bpf)) => start + n as f64 * bpf,
                    (false, None) => map.beat(t0 + n as f64 / sr),
                };
            }
            self.load_input(input, channels, done, n);
            self.capture(n, start);
            if self.midi_out.is_some() {
                // The block is heard after the plugins' delay and the
                // output's, and the MIDI sent with it goes as late.
                let late = self.schedule.as_ref().map_or(0, |s| s.latency) as f64 / sr
                    + self.shared.output_latency() as f64;
                self.heard_ns = callback_ns + ((done as f64 / sr + late) * 1e9) as u64;
            }
            self.segment(
                &mut left[done..done + n],
                &mut right[done..done + n],
                start,
                end,
            );
            done += n;
            if let Some(count) = self.count.as_mut() {
                count.elapsed += n as u64;
                if count.started && count.next >= count.clicks {
                    self.count = None;
                }
            }
            if wrap && let Some(take) = self.take.as_deref_mut().filter(|_| self.playing) {
                // A take goes round with the loop: where it did is kept, so
                // that each time round can be told from the others.
                take.pass += 1;
                let _ = take.wraps.push(take.frames);
            }
            if self.playing {
                self.position = if wrap { self.loop_start } else { end };
                self.flush_notes |= wrap;
                self.chase |= wrap;
            }
        }
        self.shared.position.store(self.position.to_bits(), Relaxed);
        self.shared.playing.store(self.playing, Relaxed);
        self.shared
            .counting
            .store(self.count.as_ref().map_or(0, Count::left), Relaxed);
        self.shared.seeks.store(self.seeks, Relaxed);
        let ns = u64::try_from(began.elapsed().as_nanos()).unwrap_or(u64::MAX);
        self.shared.blocks.record(ns, total);
    }

    /// Run the whole graph for one block covering beats `start..end`.
    fn segment(&mut self, out_l: &mut [f32], out_r: &mut [f32], start: f64, end: f64) {
        let n = out_l.len();
        let playing = self.playing;
        let flush = std::mem::take(&mut self.flush_notes);
        let Some(map) = self.map.take() else {
            return;
        };
        let seconds = map.seconds(start);
        let (sig_num, sig_den) = map.signature(start);
        let bar = map.bar_of(start);
        let block = Block {
            ctx: ProcessCtx {
                sample_rate: self.sample_rate as f32,
                tempo: map.tempo(start),
                sig_num,
                sig_den,
                playing,
                position: start,
                seconds,
                bar,
                bar_start: map.bar_start(bar),
            },
            n,
            start,
            end,
            map: &map,
            bpf: map
                .is_constant()
                .then(|| map.first_tempo() / (60.0 * self.sample_rate)),
            flush,
            chase: playing && std::mem::take(&mut self.chase),
            reapply: playing && std::mem::take(&mut self.reapply),
            meter_fall: (-(n as f32) / (self.sample_rate as f32 * METER_FALL_SECONDS)).exp(),
        };
        out_l.fill(0.0);
        out_r.fill(0.0);

        let Some(mut schedule) = self.schedule.take() else {
            self.map = Some(map);
            return;
        };
        for entry in schedule.entries.iter_mut() {
            if let Some(track) = self.track_mut(entry.slot) {
                track.buf[0][..n].fill(0.0);
                track.buf[1][..n].fill(0.0);
            }
            if flush {
                // What was on its way when playback stopped or moved is not
                // part of what comes next.
                entry.delay.clear();
                entry.sends.iter_mut().for_each(|send| send.delay.clear());
                entry.keys.iter_mut().for_each(|key| key.delay.clear());
                entry.outs.iter_mut().for_each(|out| out.delay.clear());
            }
            for key in &entry.keys {
                if let Some(buf) = self
                    .device_mut(key.device)
                    .and_then(|d| d.key.as_deref_mut())
                {
                    buf[0][..n].fill(0.0);
                    buf[1][..n].fill(0.0);
                }
            }
            // A device that does not run this block (bypassed, failed)
            // leaves its further pairs silent.
            for out in &entry.outs {
                if let Some(pair) = self
                    .device_mut(out.device)
                    .and_then(|d| d.outs.as_deref_mut())
                    .and_then(|outs| outs.get_mut(out.pair)?.as_mut())
                {
                    pair[0][..n].fill(0.0);
                    pair[1][..n].fill(0.0);
                }
            }
        }

        let mut first = 0;
        while first < schedule.entries.len() {
            let last = schedule.group_end(first);
            // The tracks of a group do not feed each other: each makes its
            // own sound, on whichever thread takes it. What they send on is
            // then added up here, in the order of the entries, so the sums
            // are the same however many threads ran.
            match self.pool.as_deref_mut() {
                Some(pool) if last - first > 1 && pool.threads() > 1 => {
                    let work = Work {
                        block: &block,
                        entries: &schedule.entries[first..last],
                        tracks: &self.tracks,
                        devices: &self.devices,
                        inputs: &self.inputs[..self.input_count],
                        shared: &self.shared,
                    };
                    pool.run(last - first, &|index| work.track(index));
                    for entry in schedule.entries[first..last].iter_mut() {
                        self.route(entry, &block, out_l, out_r);
                    }
                }
                // Alone, a track is sent on while its block is still at hand.
                _ => {
                    for entry in schedule.entries[first..last].iter_mut() {
                        Work {
                            block: &block,
                            entries: std::slice::from_ref(entry),
                            tracks: &self.tracks,
                            devices: &self.devices,
                            inputs: &self.inputs[..self.input_count],
                            shared: &self.shared,
                        }
                        .track(0);
                        self.route(entry, &block, out_l, out_r);
                    }
                }
            }
            first = last;
        }
        // The click belongs with what is heard, which is this far behind.
        let behind = schedule.latency as f64 / self.sample_rate;
        self.schedule = Some(schedule);

        // Where clicks start in this block: the metronome's while playing,
        // and a count-in's whether or not the metronome is on.
        let mut starts = [(usize::MAX, false); MAX_CLICKS];
        let mut count = 0;
        if playing && self.metronome {
            let from = seconds - behind;
            let to = map.seconds(end) - behind;
            self.metronome_clicks(n, &map, from, to, &mut starts, &mut count);
        }
        if let Some(counting) = self.count.as_mut() {
            counting.clicks(n, &mut starts, &mut count);
            starts[..count].sort_unstable_by_key(|s| s.0);
        }
        if (playing && self.metronome) || self.count.is_some() {
            self.click(out_l, out_r, &starts[..count]);
        } else {
            self.click.env = 0.0;
        }
        self.map = Some(map);
    }

    /// Send a processed track's block on: to its output and its sends, or
    /// out of the engine for the master.
    fn route(
        &mut self,
        entry: &mut SchedEntry,
        block: &Block,
        out_l: &mut [f32],
        out_r: &mut [f32],
    ) {
        let n = block.n;
        let Some(mut track) = self
            .tracks
            .get_mut(entry.slot as usize)
            .and_then(|t| t.get_mut().take())
        else {
            return;
        };
        let t = &mut *track;
        if t.midi_out != 0
            && let Some(out) = self.midi_out.as_deref_mut()
        {
            let ns_per_frame = 1e9 / self.sample_rate;
            let channel = t.midi_out_channel.checked_sub(1);
            for ev in t.sent.drain(..) {
                let message = MidiOut {
                    at: self.heard_ns + (ev.frame as f64 * ns_per_frame) as u64,
                    port: t.midi_out,
                    form: t.midi_out_form,
                    kind: crate::midi_out::on_channel(ev.kind, channel),
                };
                if out.push(message).is_err() {
                    crate::event::count_dropped();
                }
            }
        }
        if entry.taps_pre() {
            // Sends from before the fader ignore it and the pan, but not the
            // mute. The fader was left for now, so that they could be taken.
            let pre = if t.mute || t.quiet { 0.0 } else { 1.0 };
            let pre_from = if t.started { t.applied_pre } else { pre };
            t.applied_pre = pre;
            for send in entry.sends.iter_mut().filter(|send| send.pre) {
                if let Some(dst) = self
                    .tracks
                    .get_mut(send.target as usize)
                    .and_then(|t| t.get_mut().as_deref_mut())
                {
                    let src = [&t.buf[0][..n], &t.buf[1][..n]];
                    let [l, r] = &mut dst.buf;
                    send.delay.mix(
                        src,
                        [&mut l[..n], &mut r[..n]],
                        send.gain * pre_from,
                        send.gain * pre,
                    );
                }
            }
            for key in entry.keys.iter_mut().filter(|key| key.pre) {
                key_into(&mut self.devices, key, [&t.buf[0][..n], &t.buf[1][..n]]);
            }
            fader(t, entry.slot, block, &self.shared);
        }

        if entry.slot == MASTER {
            out_l.copy_from_slice(&t.buf[0][..n]);
            out_r.copy_from_slice(&t.buf[1][..n]);
        } else {
            // A track silenced by another's solo is not heard, moving there
            // smoothly, but its side-chains are still taken from it.
            let heard = if t.quiet { 0.0 } else { 1.0 };
            let heard_from = std::mem::replace(&mut t.applied_heard, heard);
            let src = [&t.buf[0][..n], &t.buf[1][..n]];
            if let Some(dst) = self
                .tracks
                .get_mut(entry.output as usize)
                .and_then(|t| t.get_mut().as_deref_mut())
            {
                let [l, r] = &mut dst.buf;
                entry
                    .delay
                    .mix(src, [&mut l[..n], &mut r[..n]], heard_from, heard);
            }
            for send in entry.sends.iter_mut().filter(|send| !send.pre) {
                if let Some(dst) = self
                    .tracks
                    .get_mut(send.target as usize)
                    .and_then(|t| t.get_mut().as_deref_mut())
                {
                    let [l, r] = &mut dst.buf;
                    send.delay.mix(
                        src,
                        [&mut l[..n], &mut r[..n]],
                        send.gain * heard_from,
                        send.gain * heard,
                    );
                }
            }
            for key in entry.keys.iter_mut().filter(|key| !key.pre) {
                key_into(&mut self.devices, key, src);
            }
            for out in entry.outs.iter_mut() {
                let (Some(pair), Some(dst)) = (
                    self.devices
                        .get_mut(out.device as usize)
                        .and_then(|d| d.get_mut().as_mut())
                        .and_then(|d| d.outs.as_deref())
                        .and_then(|outs| outs.get(out.pair)?.as_ref()),
                    self.tracks
                        .get_mut(out.target as usize)
                        .and_then(|t| t.get_mut().as_deref_mut()),
                ) else {
                    continue;
                };
                let [l, r] = &mut dst.buf;
                out.delay.mix(
                    [&pair[0][..n], &pair[1][..n]],
                    [&mut l[..n], &mut r[..n]],
                    1.0,
                    1.0,
                );
            }
        }
        *self.tracks[entry.slot as usize].get_mut() = Some(track);
    }

    /// Where the metronome clicks in a block of `n` frames, for the
    /// signature beats heard from `from` to `to` (in seconds), the first
    /// beat of each bar marked to be higher.
    fn metronome_clicks(
        &self,
        n: usize,
        map: &TempoMap,
        from: f64,
        to: f64,
        starts: &mut [(usize, bool)],
        count: &mut usize,
    ) {
        let sr = self.sample_rate;
        map.lines(map.beat(from), map.beat(to), |line| {
            if *count < starts.len() {
                let at = ((map.seconds(line.beat) - from) * sr).max(0.0) as usize;
                starts[*count] = (at.min(n - 1), line.index == 0);
                *count += 1;
            }
        });
    }

    /// Sound the clicks that start in this block, in order of their frames,
    /// and the ring of the one before.
    fn click(&mut self, out_l: &mut [f32], out_r: &mut [f32], starts: &[(usize, bool)]) {
        let n = out_l.len();
        let sr = self.sample_rate;
        let count = starts.len();
        let mut next = 0;
        let fall = (-1.0 / (sr as f32 * 0.02)).exp();
        for i in 0..n {
            while next < count && starts[next].0 == i {
                let accent = starts[next].1;
                self.click = Click {
                    phase: 0.0,
                    env: 1.0,
                    freq: if accent { 1760.0 } else { 1320.0 },
                };
                next += 1;
            }
            if self.click.env > 1e-4 {
                let s = (self.click.phase * std::f32::consts::TAU).sin() * self.click.env * 0.3;
                out_l[i] += s;
                out_r[i] += s;
                self.click.phase = (self.click.phase + self.click.freq / sr as f32).fract();
                self.click.env *= fall;
            }
        }
    }
}

/// Put a block of a track into the side-chain of a device that listens to it.
fn key_into(devices: &mut [Guarded<Option<DeviceSlot>>], key: &mut KeyRt, src: [&[f32]; 2]) {
    let n = src[0].len();
    if let Some([l, r]) = devices
        .get_mut(key.device as usize)
        .and_then(|d| d.get_mut().as_mut())
        .and_then(|d| d.key.as_deref_mut())
    {
        key.delay.mix(src, [&mut l[..n], &mut r[..n]], 1.0, 1.0);
    }
}

/// Most metronome clicks in one block: at 999 BPM in x/64 a block of
/// [`MAX_BLOCK`] frames at 8 kHz holds about 34.
const MAX_CLICKS: usize = 64;

/// What every track of a block shares.
struct Block<'a> {
    ctx: ProcessCtx,
    n: usize,
    start: f64,
    end: f64,
    map: &'a TempoMap,
    /// Beats per frame when the map has one tempo throughout: positions are
    /// then worked out exactly as they were before there were tempo maps.
    bpf: Option<f64>,
    flush: bool,
    chase: bool,
    reapply: bool,
    meter_fall: f32,
}

/// One group of tracks to process, and what they read while it is done.
struct Work<'a> {
    block: &'a Block<'a>,
    entries: &'a [SchedEntry],
    tracks: &'a [Guarded<Option<Box<TrackRt>>>],
    devices: &'a [Guarded<Option<DeviceSlot>>],
    inputs: &'a [Vec<f32>],
    shared: &'a Shared,
}

impl Work<'_> {
    /// Make one track's block: its clips and input, through its devices and
    /// its fader. What has been sent into it by the tracks that feed it is
    /// already in its buffer. Touches nothing but the track and its devices.
    fn track(&self, index: usize) {
        let entry = &self.entries[index];
        let Block {
            ref ctx,
            n,
            start,
            end,
            map,
            ..
        } = *self.block;
        let playing = ctx.playing;
        let sr = ctx.sample_rate as f64;
        let Some(mut claim) = self
            .tracks
            .get(entry.slot as usize)
            .and_then(Guarded::claim)
        else {
            return;
        };
        let Some(t) = claim.as_deref_mut() else {
            return;
        };
        // The track's own flags are used up here even when the whole
        // engine is flushing or chasing anyway; left set, they would
        // stop and restart the track's notes again one block later.
        let track_flush = std::mem::take(&mut t.flush);
        let flush = self.block.flush || track_flush;
        // Chasing waits for playback, as it does for the whole engine.
        let track_chase = playing && std::mem::take(&mut t.chase);
        let chase = self.block.chase || track_chase;

        t.events.clear();
        if flush {
            t.events.push(Event {
                frame: 0,
                kind: EventKind::AllNotesOff,
            });
            // A pedal held down or a wheel left bent when playback stopped
            // would stay that way for whatever is played next.
            for ctl in [Ctl::Cc(64), Ctl::Bend] {
                let kind = EventKind::Control {
                    ctl,
                    value: 0.0,
                    ch: 0,
                };
                t.events.push(Event { frame: 0, kind });
            }
        }
        if chase {
            // Start the notes that began before this position and are
            // still held at it, and put every controller where it was
            // last moved to, as if playback had run through them.
            let mut held = [0f32; 128];
            let mut controllers = [f64::NAN; 130];
            let mut program = None;
            for ev in t.clips.midi.iter().take_while(|ev| ev.beat < start) {
                match ev.kind {
                    EventKind::NoteOn { key, vel, .. } => held[(key & 127) as usize] = vel,
                    EventKind::NoteOff { key, .. } => held[(key & 127) as usize] = 0.0,
                    EventKind::Control { ctl, value, .. } => {
                        if let Some(index) = ctl_index(ctl) {
                            controllers[index] = value;
                        }
                    }
                    EventKind::Program { .. } => program = Some(ev.kind),
                    EventKind::NoteControl { .. } | EventKind::AllNotesOff => {}
                }
            }
            if let Some(kind) = program {
                t.events.push(Event { frame: 0, kind });
            }
            for (index, value) in controllers.into_iter().enumerate() {
                if !value.is_nan() {
                    let kind = EventKind::Control {
                        ctl: ctl_at(index),
                        value,
                        ch: 0,
                    };
                    t.events.push(Event { frame: 0, kind });
                }
            }
            for (key, vel) in held.into_iter().enumerate().filter(|(_, vel)| *vel > 0.0) {
                let kind = EventKind::NoteOn {
                    key: key as u8,
                    vel,
                    ch: 0,
                };
                t.events.push(Event { frame: 0, kind });
            }
        }
        for kind in t.live.drain(..) {
            t.events.push(Event { frame: 0, kind });
        }
        if playing {
            let first = t.clips.midi.partition_point(|e| e.beat < start);
            for ev in &t.clips.midi[first..] {
                if ev.beat >= end {
                    break;
                }
                let frame = match self.block.bpf {
                    Some(bpf) => ((ev.beat - start) / bpf) as usize,
                    None => ((map.seconds(ev.beat) - ctx.seconds) * sr) as usize,
                };
                t.events.push(Event {
                    frame: frame.min(n - 1) as u32,
                    kind: ev.kind,
                });
            }
            let [left, right] = &mut t.buf;
            mix_audio(
                &t.clips,
                &mut left[..n],
                &mut right[..n],
                (start, end),
                map,
                self.block.bpf,
                ctx,
            );
        }
        if t.monitor {
            add_input(self.inputs, t, n);
        }
        // What it plays goes to its MIDI output port as well, as it is
        // before its devices change it.
        if t.midi_out != 0 {
            t.sent.clear();
            let room = t.sent.capacity();
            t.sent
                .extend(t.events.as_slice().iter().take(room).copied());
        }

        if playing {
            for lane in t.automation.lanes.iter_mut() {
                let Some(value) = automation::value_at(&lane.points, start) else {
                    continue;
                };
                match lane.target {
                    AutoTarget::Volume => t.gain = crate::db_to_gain(value),
                    AutoTarget::Pan => t.pan = value as f32,
                    AutoTarget::Param { device, index } => {
                        if self.block.reapply || value != lane.last {
                            if let Some(mut dev) = self.device(device)
                                && let Some(dev) = dev.as_mut()
                            {
                                dev.set_param(index, value as f32);
                            }
                            lane.last = value;
                        }
                    }
                }
            }
        }

        let [left, right] = &mut t.buf;
        for &slot in t.chain.iter() {
            if let Some(mut dev) = self.device(slot)
                && let Some(dev) = dev.as_mut()
                && !dev.failed
            {
                // Taken out of the slot while the device runs on it.
                let key = dev.key.take();
                let mut outs = dev.outs.take();
                let mut io = Io {
                    left: &mut left[..n],
                    right: &mut right[..n],
                    events: &mut t.events,
                    sidechain: key.as_deref().map(|[l, r]| [&l[..n], &r[..n]]),
                    outputs: match outs.as_deref_mut() {
                        Some(outs) => outs.as_mut_slice(),
                        None => &mut [],
                    },
                };
                // A device that panics is passed over from then on (an
                // instrument falls silent, an effect lets its input through),
                // and one that puts out NaN or infinity is silenced for the
                // block: neither reaches the fader, the meters or the master.
                // The host's wet/dry mix and bypass fade go around it.
                let ok = dev.process(ctx, &mut io);
                dev.key = key;
                dev.outs = outs;
                if !ok {
                    dev.failed = true;
                    left[..n].fill(0.0);
                    right[..n].fill(0.0);
                    self.shared.set_fault(slot, guard::PANICKED);
                } else if !guard::finite(&left[..n]) || !guard::finite(&right[..n]) {
                    left[..n].fill(0.0);
                    right[..n].fill(0.0);
                    if !dev.flagged {
                        dev.flagged = true;
                        self.shared.set_fault(slot, guard::NOT_FINITE);
                    }
                }
            }
        }
        // A track with sends or side-chains from before its fader keeps
        // the fader for when they have been taken.
        if !entry.taps_pre() {
            fader(t, entry.slot, self.block, self.shared);
        }
    }

    fn device(&self, slot: Slot) -> Option<Claim<'_, Option<DeviceSlot>>> {
        self.devices.get(slot as usize)?.claim()
    }
}

/// Apply a track's fader, pan and mute to its block, moving smoothly from
/// where the last block left them, and measure what comes out.
fn fader(t: &mut TrackRt, slot: Slot, block: &Block, shared: &Shared) {
    let n = block.n;
    let target = t.target_gains();
    if !t.started {
        // Nothing has sounded yet, so there is nothing to ramp from.
        t.applied = target;
    }
    let [left, right] = &mut t.buf;
    for (ch, buf) in [&mut left[..n], &mut right[..n]].into_iter().enumerate() {
        let from = t.applied[ch];
        let step = (target[ch] - from) / n as f32;
        let mut peak = 0f32;
        if step.abs() < 1e-9 {
            for s in buf.iter_mut() {
                *s *= from;
                peak = peak.max(s.abs());
            }
        } else {
            for (i, s) in buf.iter_mut().enumerate() {
                *s *= from + step * (i + 1) as f32;
                peak = peak.max(s.abs());
            }
        }
        t.applied[ch] = target[ch];
        // A track silenced by a solo shows nothing, as it is heard.
        let peak = if t.quiet { 0.0 } else { peak };
        t.peak[ch] = peak.max(t.peak[ch] * block.meter_fall);
        if let Some(meter) = shared.meters.get(slot as usize) {
            meter[ch].store(t.peak[ch].to_bits(), Relaxed);
        }
    }
    t.started = true;
}

/// Where a controller is kept while chasing: the 128 control changes, then
/// the pitch wheel and pressure. Registered and assignable controllers are
/// settings more than performance, and are not chased.
fn ctl_index(ctl: Ctl) -> Option<usize> {
    match ctl {
        Ctl::Cc(number) => Some((number & 127) as usize),
        Ctl::Bend => Some(128),
        Ctl::Pressure => Some(129),
        Ctl::Registered(..) | Ctl::Assignable(..) => None,
    }
}

fn ctl_at(index: usize) -> Ctl {
    match index {
        128 => Ctl::Bend,
        129 => Ctl::Pressure,
        number => Ctl::Cc(number as u8),
    }
}

/// Add a track's input into its buffer, ahead of its devices. A mono input
/// goes to both sides.
fn add_input(inputs: &[Vec<f32>], t: &mut TrackRt, n: usize) {
    let Some(first) = inputs.get(t.input_first).filter(|_| t.input_channels > 0) else {
        return;
    };
    let second = match t.input_channels {
        2 => inputs.get(t.input_first + 1).unwrap_or(first),
        _ => first,
    };
    let [left, right] = &mut t.buf;
    for (d, s) in left[..n].iter_mut().zip(&first[..n]) {
        *d += s;
    }
    for (d, s) in right[..n].iter_mut().zip(&second[..n]) {
        *d += s;
    }
}

/// Queue a note-off for every key a track holds through MIDI input.
fn release_held(t: &mut TrackRt) {
    while t.held != 0 {
        let key = t.held.trailing_zeros() as u8;
        t.held &= !(1 << key);
        if t.live.len() < t.live.capacity() {
            t.live.push(EventKind::NoteOff { key, ch: 0 });
        }
    }
}

const DECLICK_SECONDS: f64 = 0.003;

/// Gain a fraction `x` of the way into a fade: a quarter sine, so that two
/// clips fading across each other keep their power.
fn fade_curve(x: f64) -> f32 {
    (x.clamp(0.0, 1.0) * std::f64::consts::FRAC_PI_2).sin() as f32
}

/// Add every audio region overlapping beats `start..end` into the block.
/// Regions keep to time: a region plays its file at its own rate from the
/// moment its start beat falls on, whatever the tempo does meanwhile.
fn mix_audio(
    clips: &ClipSet,
    left: &mut [f32],
    right: &mut [f32],
    (start, end): (f64, f64),
    map: &TempoMap,
    bpf: Option<f64>,
    ctx: &ProcessCtx,
) {
    if bpf.is_some() {
        return mix_audio_constant(clips, left, right, (start, end), ctx);
    }
    let n = left.len();
    let sr = ctx.sample_rate as f64;
    let t0 = ctx.seconds;
    for region in &clips.audio {
        if region.end <= start || region.start >= end {
            continue;
        }
        // The region's edges, in frames from the block's first frame.
        let (rs, re) = (map.seconds(region.start), map.seconds(region.end));
        let first = if rs > t0 {
            ((rs - t0) * sr).ceil() as usize
        } else {
            0
        };
        let last = (((re - t0) * sr).ceil() as usize).min(n);
        let src_rate = region.data.sample_rate as f64;
        // Source position, in source frames, of the block's first frame.
        let origin = (t0 - rs + region.offset) * src_rate;
        let step = src_rate / sr;
        // Sound still being made is played as far as it is there.
        let complete = region.data.complete();
        let frames = region.data.frames();
        let watched = region.hold.watched(complete);
        let hold_fade = DECLICK_SECONDS * src_rate;
        let [src_l, src_r] = &region.data.channels;
        // Fades, in frames. An edge cut into the middle of a recording gets
        // a few milliseconds of one even when none was asked for, or it clicks.
        let declick = DECLICK_SECONDS * sr;
        let fade_in = ((map.seconds(region.start + region.fade_in) - rs) * sr)
            .max(if region.declick_in { declick } else { 0.0 });
        let fade_out = ((re - map.seconds(region.end - region.fade_out)) * sr)
            .max(if region.declick_out { declick } else { 0.0 });
        let length = (re - rs) * sr;
        // Where in the region, in frames, the block's first frame is.
        let at = (t0 - rs) * sr;
        for i in first..last {
            let pos = origin + i as f64 * step;
            if pos < 0.0 {
                continue;
            }
            let index = pos as usize;
            if index + 1 >= frames {
                if !complete {
                    region.hold.starve();
                }
                break;
            }
            let frac = (pos - index as f64) as f32;
            let mut gain = region.gain;
            if watched {
                gain *= region.hold.gain(pos, frames, complete, hold_fade, fade_curve);
            }
            let from_start = at + i as f64;
            if from_start < fade_in {
                gain *= fade_curve(from_start / fade_in);
            }
            if length - from_start < fade_out {
                gain *= fade_curve((length - from_start) / fade_out);
            }
            left[i] += (src_l[index] + (src_l[index + 1] - src_l[index]) * frac) * gain;
            right[i] += (src_r[index] + (src_r[index + 1] - src_r[index]) * frac) * gain;
        }
    }
}

/// [`mix_audio`] for one tempo throughout, in beats per frame: the
/// arithmetic of before there were tempo maps, so that such songs render
/// the very same samples.
fn mix_audio_constant(
    clips: &ClipSet,
    left: &mut [f32],
    right: &mut [f32],
    (start, end): (f64, f64),
    ctx: &ProcessCtx,
) {
    let n = left.len();
    let sr = ctx.sample_rate as f64;
    let beats_per_frame = ctx.tempo / (60.0 * sr);
    for region in &clips.audio {
        if region.end <= start || region.start >= end {
            continue;
        }
        let first = if region.start > start {
            ((region.start - start) / beats_per_frame).ceil() as usize
        } else {
            0
        };
        let last = (((region.end - start) / beats_per_frame).ceil() as usize).min(n);
        let src_rate = region.data.sample_rate as f64;
        // Source position, in source frames, of the block's first frame.
        let origin = ((start - region.start) * 60.0 / ctx.tempo + region.offset) * src_rate;
        let step = src_rate / sr;
        // Sound still being made is played as far as it is there.
        let complete = region.data.complete();
        let frames = region.data.frames();
        let watched = region.hold.watched(complete);
        let hold_fade = DECLICK_SECONDS * src_rate;
        let [src_l, src_r] = &region.data.channels;
        let declick = DECLICK_SECONDS * sr;
        let fade_in =
            (region.fade_in / beats_per_frame).max(if region.declick_in { declick } else { 0.0 });
        let fade_out =
            (region.fade_out / beats_per_frame).max(if region.declick_out { declick } else { 0.0 });
        let length = (region.end - region.start) / beats_per_frame;
        let at = (start - region.start) / beats_per_frame;
        for i in first..last {
            let pos = origin + i as f64 * step;
            if pos < 0.0 {
                continue;
            }
            let index = pos as usize;
            if index + 1 >= frames {
                if !complete {
                    region.hold.starve();
                }
                break;
            }
            let frac = (pos - index as f64) as f32;
            let mut gain = region.gain;
            if watched {
                gain *= region.hold.gain(pos, frames, complete, hold_fade, fade_curve);
            }
            let from_start = at + i as f64;
            if from_start < fade_in {
                gain *= fade_curve(from_start / fade_in);
            }
            if length - from_start < fade_out {
                gain *= fade_curve((length - from_start) / fade_out);
            }
            left[i] += (src_l[index] + (src_l[index + 1] - src_l[index]) * frac) * gain;
            right[i] += (src_r[index] + (src_r[index + 1] - src_r[index]) * frac) * gain;
        }
    }
}
