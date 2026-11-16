//! The native half of the UTAU extension (`extensions/utau`).
//!
//! Singing is rendered by a separate engine process that the extension talks
//! to from Lua. What comes back is audio, one phrase at a time, each with its
//! place in the project in seconds. The `utau` device plays those phrases
//! where they belong while the transport runs, in real time and in offline
//! renders alike, and ignores the notes that reach it.
//!
//! Phrases are grouped into voices, numbered from 1; a device plays the voice
//! its `voice` parameter names. Scripts fill a voice through
//! `daw.api.device_call` on a device set to it (see [`Control::call`]).
//!
//! Every instance of the device, including the private ones an offline render
//! makes, sees the same voices: they are kept here on the main thread, and
//! each new version of a voice is sent to every instance over a queue of its
//! own. The other parameters are the singing curves; the device does nothing
//! with them, they are there so that automation lanes can draw them.

use std::cell::RefCell;
use std::collections::BTreeSet;
use std::fmt::Write as _;
use std::rc::Rc;
use std::sync::Arc;

use anyhow::{Context, Result, bail};
use daw_engine::{
    Controller, Device, DeviceFactory, DeviceInfo, Instance, Io, ParamInfo, ProcessCtx, Registry,
};
use rtrb::{Consumer, Producer, PushError, RingBuffer};

/// How many voices there can be, and so how many vocal tracks.
pub const MAX_VOICES: usize = 64;
/// Updates waiting for one device; more wait on the main thread.
const QUEUE: usize = 256;

/// The singing curves, in OpenUtau's units: `(abbr, name, min, max, default)`.
pub const CURVES: [(&str, &str, f32, f32, f32); 9] = [
    ("pitd", "Pitch deviation", -1200.0, 1200.0, 0.0),
    ("dyn", "Dynamics", -240.0, 120.0, 0.0),
    ("tenc", "Tension", -100.0, 100.0, 0.0),
    ("brec", "Breathiness", -100.0, 100.0, 0.0),
    ("genc", "Gender", -100.0, 100.0, 0.0),
    ("voic", "Voicing", 0.0, 100.0, 100.0),
    ("shfc", "Tone shift", -1200.0, 1200.0, 0.0),
    ("grwc", "Growl", 0.0, 100.0, 0.0),
    ("xsy", "Cross synthesis", 0.0, 100.0, 0.0),
];

/// Make the `utau` device available.
pub fn register(registry: &mut Registry) {
    registry.register(Rc::new(Factory {
        info: DeviceInfo {
            kind: "utau".into(),
            name: "UTAU voice".into(),
            category: "instrument".into(),
            format: "builtin".into(),
            vendor: String::new(),
            params: params(),
        },
    }));
}

/// Slots for curves of the renderer's own (DiffSinger's energy, voice
/// colour blends, ...), `x1` to `x8`: the extension says which expression
/// each one draws, and keeps values in that expression's units.
pub const EXTRA_CURVES: usize = 8;

fn params() -> Vec<ParamInfo> {
    let mut list = vec![ParamInfo::new("voice", 0.0, MAX_VOICES as f32, 0.0, "")];
    for (abbr, name, min, max, default) in CURVES {
        list.push(ParamInfo {
            name: name.into(),
            ..ParamInfo::new(abbr, min, max, default, "")
        });
    }
    for i in 1..=EXTRA_CURVES {
        list.push(ParamInfo {
            name: format!("Renderer curve {i}"),
            ..ParamInfo::new(&format!("x{i}"), -1200.0, 1200.0, 0.0, "")
        });
    }
    list
}

/// One rendered phrase: mono, or stereo when `right` is there.
#[derive(Clone)]
struct Phrase {
    hash: u64,
    /// Project time of the first sample, in seconds.
    start: f64,
    rate: f64,
    /// 0 for a quick draft, 1 for final quality.
    quality: u8,
    left: Arc<[f32]>,
    right: Option<Arc<[f32]>>,
}

impl Phrase {
    fn seconds(&self) -> f64 {
        self.left.len() as f64 / self.rate
    }
}

/// The phrases of one voice, sorted by start.
#[derive(Clone, Default)]
struct Voice {
    phrases: Vec<Phrase>,
    /// A short clip to play at once, transport or not (hearing a note as it
    /// is placed), numbered so that each is heard once.
    audition: Option<(u64, Phrase)>,
}

struct Update {
    slot: usize,
    voice: Arc<Voice>,
}

/// What the main thread keeps for one device instance.
struct Subscriber {
    updates: Producer<Update>,
    /// Voices the device replaced, to be freed here rather than on its thread.
    garbage: Consumer<Arc<Voice>>,
    /// Voices that changed and could not be sent yet because the queue was full.
    dirty: BTreeSet<usize>,
}

/// What a new device starts with: its queues, and every voice as it is now.
type Subscription = (Consumer<Update>, Producer<Arc<Voice>>, Box<[Arc<Voice>]>);

struct Store {
    voices: Vec<Arc<Voice>>,
    subscribers: Vec<Subscriber>,
    /// The number of the last clip given to `audition`.
    auditions: u64,
}

thread_local! {
    // Factories, controllers and every edit live on the main thread.
    static STORE: RefCell<Store> = RefCell::new(Store {
        voices: (0..MAX_VOICES).map(|_| Arc::new(Voice::default())).collect(),
        subscribers: Vec::new(),
        auditions: 0,
    });
}

impl Store {
    fn subscribe(&mut self) -> Subscription {
        let (updates, rx) = RingBuffer::new(QUEUE);
        let (garbage_tx, garbage) = RingBuffer::new(QUEUE * 2);
        self.subscribers.push(Subscriber {
            updates,
            garbage,
            dirty: BTreeSet::new(),
        });
        (rx, garbage_tx, self.voices.clone().into_boxed_slice())
    }

    fn set(&mut self, slot: usize, voice: Voice) {
        self.voices[slot] = Arc::new(voice);
        for subscriber in &mut self.subscribers {
            subscriber.dirty.insert(slot);
        }
        self.deliver();
    }

    /// Send what changed, free what came back, forget devices that are gone.
    fn deliver(&mut self) {
        for s in &mut self.subscribers {
            while s.garbage.pop().is_ok() {}
            while let Some(&slot) = s.dirty.first() {
                let update = Update {
                    slot,
                    voice: self.voices[slot].clone(),
                };
                if s.updates.push(update).is_err() {
                    break;
                }
                s.dirty.remove(&slot);
            }
        }
        self.subscribers
            .retain(|s| !s.updates.is_abandoned() || !s.garbage.is_empty());
    }
}

struct Factory {
    info: DeviceInfo,
}

impl DeviceFactory for Factory {
    fn info(&self) -> &DeviceInfo {
        &self.info
    }

    fn create(&self, sample_rate: f32, _max_block: usize) -> Result<Instance> {
        let (updates, garbage, voices, heard) = STORE.with(|s| {
            let mut store = s.borrow_mut();
            let (updates, garbage, voices) = store.subscribe();
            (updates, garbage, voices, store.auditions)
        });
        Ok(Instance {
            device: Box::new(Player {
                sample_rate: sample_rate as f64,
                voice: 0,
                voices,
                updates,
                garbage,
                // A new instance (an offline render's) hears only later clips.
                heard,
                audition_at: f64::INFINITY,
            }),
            controller: Some(Box::new(Control { voice: 0 })),
        })
    }
}

/// The audio-thread side: plays the phrases of its voice under the playhead.
struct Player {
    sample_rate: f64,
    /// 1-based; 0 plays nothing.
    voice: usize,
    voices: Box<[Arc<Voice>]>,
    updates: Consumer<Update>,
    garbage: Producer<Arc<Voice>>,
    /// The number of the audition clip being played or last played.
    heard: u64,
    /// Where in that clip it is, in the clip's frames.
    audition_at: f64,
}

impl Player {
    /// Play the voice's audition clip from where it got to.
    fn audition(&mut self, io: &mut Io) {
        let Some((id, clip)) = &self.voices[self.voice - 1].audition else {
            return;
        };
        if *id > self.heard {
            self.heard = *id;
            self.audition_at = 0.0;
        }
        if *id != self.heard || self.audition_at >= clip.left.len() as f64 {
            return;
        }
        let step = clip.rate / self.sample_rate;
        for i in 0..io.left.len() {
            let pos = self.audition_at + i as f64 * step;
            if pos >= clip.left.len() as f64 {
                break;
            }
            let l = sample(&clip.left, pos);
            let r = clip.right.as_ref().map_or(l, |right| sample(right, pos));
            io.left[i] += l;
            io.right[i] += r;
        }
        self.audition_at += io.left.len() as f64 * step;
    }
}

impl Device for Player {
    fn process(&mut self, ctx: &ProcessCtx, io: &mut Io) {
        while let Ok(update) = self.updates.pop() {
            let old = std::mem::replace(&mut self.voices[update.slot], update.voice);
            if let Err(PushError::Full(old)) = self.garbage.push(old) {
                // Freeing here could block, so leak instead.
                std::mem::forget(old);
            }
        }
        if self.voice == 0 {
            return;
        }
        self.audition(io);
        if !ctx.playing || ctx.tempo <= 0.0 {
            return;
        }
        let n = io.left.len();
        let t0 = ctx.seconds;
        let t1 = t0 + n as f64 / self.sample_rate;
        for phrase in &self.voices[self.voice - 1].phrases {
            if phrase.start >= t1 {
                break;
            }
            if phrase.start + phrase.seconds() <= t0 {
                continue;
            }
            let step = phrase.rate / self.sample_rate;
            let at = (t0 - phrase.start) * phrase.rate;
            // Only the frames that land inside the phrase, with room for interpolation.
            let first = ((-2.0 - at) / step).ceil().max(0.0) as usize;
            let last = (((phrase.left.len() as f64 + 2.0 - at) / step)
                .ceil()
                .max(0.0) as usize)
                .min(n);
            for i in first..last {
                let pos = at + i as f64 * step;
                let l = sample(&phrase.left, pos);
                let r = phrase.right.as_ref().map_or(l, |right| sample(right, pos));
                io.left[i] += l;
                io.right[i] += r;
            }
        }
    }

    fn set_param(&mut self, index: u32, value: f32) {
        if index == 0 {
            self.voice = (value.round().max(0.0) as usize).min(MAX_VOICES);
        }
    }
}

/// The signal at a fractional frame, by cubic Hermite interpolation; silence
/// outside the data.
fn sample(data: &[f32], pos: f64) -> f32 {
    let i = pos.floor();
    let t = (pos - i) as f32;
    let i = i as i64;
    let at = |k: i64| -> f32 {
        if k < 0 || k >= data.len() as i64 {
            0.0
        } else {
            data[k as usize]
        }
    };
    let (y0, y1, y2, y3) = (at(i - 1), at(i), at(i + 1), at(i + 2));
    let c1 = 0.5 * (y2 - y0);
    let c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3;
    let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2);
    ((c3 * t + c2) * t + c1) * t + y1
}

/// The main-thread side: how scripts give a voice its phrases.
struct Control {
    voice: usize,
}

impl Control {
    fn slot(&self) -> Result<usize> {
        if self.voice == 0 {
            bail!("the device has no voice: set its `voice` parameter first");
        }
        Ok(self.voice - 1)
    }

    fn edit(&self, f: impl FnOnce(&mut Voice) -> Result<bool>) -> Result<()> {
        let slot = self.slot()?;
        STORE.with(|s| {
            let mut store = s.borrow_mut();
            let mut voice = Voice::clone(&store.voices[slot]);
            if f(&mut voice)? {
                store.set(slot, voice);
            }
            Ok(())
        })
    }
}

impl Controller for Control {
    fn params(&self) -> Vec<ParamInfo> {
        params()
    }

    fn value(&self, _index: usize) -> Option<f64> {
        None
    }

    fn set_value(&mut self, index: usize, value: f64) {
        if index == 0 {
            self.voice = (value.round().max(0.0) as usize).min(MAX_VOICES);
        }
    }

    fn save_state(&mut self) -> Result<Option<Vec<u8>>> {
        // The phrases are a cache of what the project describes, not state.
        Ok(None)
    }

    fn load_state(&mut self, _state: &[u8]) -> Result<()> {
        Ok(())
    }

    fn idle(&mut self) {
        STORE.with(|s| s.borrow_mut().deliver());
    }

    /// Methods, all on this device's voice:
    ///
    /// - `put`: a line `hash start rate channels quality` (start in project
    ///   seconds, quality 0 for a draft and 1 for final), a newline, then the
    ///   samples as little-endian 32-bit floats, interleaved when there are
    ///   two channels. Replaces a phrase with the same hash unless that one is
    ///   of better quality.
    /// - `keep`: hashes separated by spaces; every other phrase is dropped.
    /// - `audition`: a clip in the form `put` takes (its start is not used)
    ///   to play once, now, whether the transport runs or not.
    /// - `clear`: drop every phrase.
    /// - `list`: one line `hash start seconds quality` per phrase.
    fn call(&mut self, method: &str, data: &[u8]) -> Result<Vec<u8>> {
        match method {
            "put" => {
                let phrase = parse_phrase(data)?;
                self.edit(|voice| {
                    if let Some(old) = voice.phrases.iter().position(|p| p.hash == phrase.hash) {
                        if voice.phrases[old].quality > phrase.quality {
                            return Ok(false);
                        }
                        voice.phrases.remove(old);
                    }
                    voice.phrases.push(phrase);
                    voice.phrases.sort_by(|a, b| a.start.total_cmp(&b.start));
                    Ok(true)
                })?;
                Ok(Vec::new())
            }
            "audition" => {
                let clip = parse_phrase(data)?;
                let slot = self.slot()?;
                STORE.with(|s| {
                    let mut store = s.borrow_mut();
                    store.auditions += 1;
                    let mut voice = Voice::clone(&store.voices[slot]);
                    voice.audition = Some((store.auditions, clip));
                    store.set(slot, voice);
                });
                Ok(Vec::new())
            }
            "keep" => {
                let keep: Vec<u64> = std::str::from_utf8(data)?
                    .split_whitespace()
                    .map(|h| h.parse().with_context(|| format!("bad hash `{h}`")))
                    .collect::<Result<_>>()?;
                self.edit(|voice| {
                    let before = voice.phrases.len();
                    voice.phrases.retain(|p| keep.contains(&p.hash));
                    Ok(voice.phrases.len() != before)
                })?;
                Ok(Vec::new())
            }
            "clear" => {
                self.edit(|voice| {
                    let had = !voice.phrases.is_empty();
                    voice.phrases.clear();
                    Ok(had)
                })?;
                Ok(Vec::new())
            }
            "list" => {
                let slot = self.slot()?;
                let mut out = String::new();
                STORE.with(|s| {
                    for p in &s.borrow().voices[slot].phrases {
                        let _ =
                            writeln!(out, "{} {} {} {}", p.hash, p.start, p.seconds(), p.quality);
                    }
                });
                Ok(out.into_bytes())
            }
            _ => bail!("the utau device has no method `{method}`"),
        }
    }
}

fn parse_phrase(data: &[u8]) -> Result<Phrase> {
    let end = data
        .iter()
        .position(|b| *b == b'\n')
        .context("a phrase starts with a header line")?;
    let header = std::str::from_utf8(&data[..end])?;
    let fields: Vec<&str> = header.split_whitespace().collect();
    let [hash, start, rate, channels, quality] = fields[..] else {
        bail!("a phrase header is `hash start rate channels quality`, not `{header}`");
    };
    let rate: f64 = rate.parse().context("bad sample rate")?;
    let channels: usize = channels.parse().context("bad channel count")?;
    if !(1..=2).contains(&channels) || rate <= 0.0 {
        bail!("phrases are mono or stereo, at a positive sample rate");
    }
    let raw = &data[end + 1..];
    if !raw.len().is_multiple_of(4 * channels) {
        bail!("the samples do not fill whole frames");
    }
    let samples: Vec<f32> = raw
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect();
    let (left, right) = if channels == 2 {
        let left: Arc<[f32]> = samples.iter().step_by(2).copied().collect();
        let right: Arc<[f32]> = samples.iter().skip(1).step_by(2).copied().collect();
        (left, Some(right))
    } else {
        (Arc::from(samples), None)
    };
    Ok(Phrase {
        hash: hash.parse().context("bad hash")?,
        start: start.parse().context("bad start")?,
        rate,
        quality: quality.parse().context("bad quality")?,
        left,
        right,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use daw_engine::EventBuf;

    fn put(control: &mut dyn Controller, hash: u64, start: f64, quality: u8, samples: &[f32]) {
        let mut data = format!("{hash} {start} 1000 1 {quality}\n").into_bytes();
        for s in samples {
            data.extend_from_slice(&s.to_le_bytes());
        }
        control.call("put", &data).unwrap();
    }

    #[test]
    fn plays_phrases_where_they_belong() {
        let instance = Factory {
            info: DeviceInfo::default(),
        }
        .create(1000.0, 64)
        .unwrap();
        let (mut device, mut control) = (instance.device, instance.controller.unwrap());
        device.set_param(0, 7.0);
        control.set_value(0, 7.0);
        put(&mut *control, 1, 0.5, 0, &[1.0; 100]);
        // A draft never replaces final audio, but final replaces a draft.
        put(&mut *control, 1, 0.5, 1, &[0.5; 100]);
        put(&mut *control, 1, 0.5, 0, &[1.0; 100]);
        let listed = String::from_utf8(control.call("list", &[]).unwrap()).unwrap();
        assert_eq!(listed.trim(), "1 0.5 0.1 1");

        let mut events = EventBuf::with_capacity(0);
        let mut left = vec![0.0; 1000];
        let mut right = vec![0.0; 1000];
        let ctx = ProcessCtx::at(1000.0, 60.0, 4, 4, true);
        device.process(
            &ctx,
            &mut Io {
                left: &mut left,
                right: &mut right,
                events: &mut events,
                sidechain: None,
            },
        );
        assert_eq!(left[400], 0.0);
        assert_eq!(left[550], 0.5);
        assert_eq!(right[550], 0.5);
        assert_eq!(left[700], 0.0);

        control.call("keep", b"2 3").unwrap();
        assert!(control.call("list", &[]).unwrap().is_empty());
    }

    #[test]
    fn plays_an_audition_once_whether_playing_or_not() {
        let instance = Factory {
            info: DeviceInfo::default(),
        }
        .create(1000.0, 64)
        .unwrap();
        let (mut device, mut control) = (instance.device, instance.controller.unwrap());
        device.set_param(0, 9.0);
        control.set_value(0, 9.0);
        let mut data = b"0 0 1000 1 1\n".to_vec();
        for _ in 0..150 {
            data.extend_from_slice(&0.25f32.to_le_bytes());
        }
        control.call("audition", &data).unwrap();
        control.idle();
        let ctx = ProcessCtx::at(1000.0, 60.0, 4, 4, false);
        let mut events = EventBuf::with_capacity(0);
        let mut run = |device: &mut Box<dyn Device>| {
            let mut left = vec![0.0; 100];
            let mut right = vec![0.0; 100];
            device.process(
                &ctx,
                &mut Io {
                    left: &mut left,
                    right: &mut right,
                    events: &mut events,
                    sidechain: None,
                },
            );
            (left[10], left[60])
        };
        assert_eq!(run(&mut device), (0.25, 0.25), "heard while stopped");
        assert_eq!(run(&mut device), (0.25, 0.0), "to its end");
        assert_eq!(run(&mut device), (0.0, 0.0), "and once");
        // A device made afterwards, as an offline render makes one, does not play it.
        let mut later = Factory {
            info: DeviceInfo::default(),
        }
        .create(1000.0, 64)
        .unwrap()
        .device;
        later.set_param(0, 9.0);
        assert_eq!(run(&mut later), (0.0, 0.0), "a later instance stays quiet");
    }
}
