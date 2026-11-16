//! What a track plays back: note events and audio regions, laid out in beats.

use std::fmt::Display;
use std::fs::File;
use std::io::ErrorKind;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{Context, Result, bail};
use symphonia::core::codecs::audio::AudioDecoderOptions;
use symphonia::core::codecs::audio::well_known::{CODEC_ID_MP1, CODEC_ID_MP2, CODEC_ID_MP3};
use symphonia::core::errors::Error;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, TrackType};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;

use crate::event::EventKind;
use crate::samples::{DiskStore, Samples, Sink, store_name};

#[derive(Clone, Copy, Debug)]
pub struct MidiEv {
    /// Project position in beats.
    pub beat: f64,
    pub kind: EventKind,
}

/// Decoded audio, a run of samples per channel, always stereo: in memory,
/// or read from the disk as it is played (see [`crate::samples`]).
pub struct AudioData {
    pub sample_rate: u32,
    pub channels: [Samples; 2],
}

impl AudioData {
    pub fn frames(&self) -> usize {
        self.channels[0].len()
    }

    pub fn seconds(&self) -> f64 {
        self.frames() as f64 / self.sample_rate as f64
    }

    /// Whether all of the sound is there: false while it is still being
    /// made, when [`frames`](Self::frames) is how much of it is.
    pub fn complete(&self) -> bool {
        self.channels[0].complete()
    }

    /// How long the sound is once it is all there, in seconds.
    pub fn whole_seconds(&self) -> f64 {
        self.channels[0].whole_len() as f64 / self.sample_rate as f64
    }

    /// Decode a whole audio file: WAV, AIFF, FLAC, MP3 or Ogg Vorbis. Mono is
    /// copied to both channels; channels past the second are ignored.
    pub fn load(path: &Path) -> Result<Arc<Self>> {
        Self::load_with(path, None)
    }

    /// As [`load`](Self::load); a file whose decoded sound is larger than
    /// `store`'s limit is kept in the store and read from the disk as it is
    /// played, and one that was kept there before is not decoded again.
    pub fn load_with(path: &Path, store: Option<&DiskStore>) -> Result<Arc<Self>> {
        let kept = store.and_then(|store| Some((store, store_name(path, "src")?)));
        if let Some((store, name)) = &kept
            && let Some(data) = store.open(name)
        {
            return Ok(Arc::new(data));
        }
        let file = File::open(path).with_context(|| format!("opening {}", path.display()))?;
        decode(path, file, Sink::new(kept)).map(Arc::new)
    }

    /// Whether the samples are read from the disk as they are played.
    pub fn on_disk(&self) -> bool {
        self.channels[0].on_disk()
    }

    /// Ask for `from..to` seconds to be brought in from the disk now.
    pub fn advise(&self, from: f64, to: f64) {
        let rate = self.sample_rate as f64;
        let (from, to) = ((from.max(0.0) * rate) as usize, (to.max(0.0) * rate) as usize);
        for channel in &self.channels {
            channel.advise(from, to);
        }
    }

    /// Kept for callers from when only WAV could be read; the same as [`load`](Self::load).
    pub fn load_wav(path: &Path) -> Result<Arc<Self>> {
        Self::load(path)
    }
}

const READABLE: &str = "WAV, AIFF, FLAC, MP3 or Ogg Vorbis";

fn decode(path: &Path, file: File, mut sink: Sink) -> Result<AudioData> {
    let name = path.display();
    let stream = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let probed = symphonia::default::get_probe().probe(
        &hint,
        stream,
        FormatOptions::default(),
        MetadataOptions::default(),
    );
    let mut format = match probed {
        Ok(format) => format,
        Err(Error::IoError(err)) if err.kind() == ErrorKind::UnexpectedEof => {
            bail!("{name} is truncated: it ends before its own headers say it should")
        }
        Err(Error::IoError(err)) => return Err(err).with_context(|| format!("reading {name}")),
        Err(Error::Unsupported(_)) => {
            bail!("{name} is not an audio file in a format that can be read ({READABLE})")
        }
        Err(err) => bail!("{name} cannot be read: {err}"),
    };
    let Some(track) = format.default_track(TrackType::Audio) else {
        bail!("{name} holds no audio");
    };
    let Some(params) = track.codec_params.as_ref().and_then(|p| p.audio()) else {
        bail!("{name} holds no audio");
    };
    // An MPEG audio length without a LAME header is guessed from the bitrate,
    // too roughly to show that the file is cut short.
    let mpeg = [CODEC_ID_MP1, CODEC_ID_MP2, CODEC_ID_MP3].contains(&params.codec);
    let expected = track.num_frames.filter(|_| !mpeg || track.delay.is_some());
    let track_id = track.id;
    let mut decoder = match symphonia::default::get_codecs()
        .make_audio_decoder(params, &AudioDecoderOptions::default())
    {
        Ok(decoder) => decoder,
        Err(Error::Unsupported(_)) => {
            bail!("{name} uses an audio codec that is not supported: convert it to {READABLE}")
        }
        Err(err) => bail!("{name} cannot be decoded: {err}"),
    };
    let mut sample_rate = params.sample_rate.unwrap_or(0);
    if let Some(frames) = expected {
        sink.reserve(frames as usize);
    }
    let mut planes: Vec<Vec<f32>> = Vec::new();
    let mut damaged = None;
    loop {
        let packet = match format.next_packet() {
            Ok(Some(packet)) => packet,
            Ok(None) => break,
            Err(Error::IoError(err)) if err.kind() == ErrorKind::UnexpectedEof => {
                bail!("{}", truncated(&name, sink.frames(), expected, sample_rate))
            }
            Err(Error::ResetRequired) => {
                bail!("{name} changes its audio format partway through, which is not supported")
            }
            Err(err) => bail!("{name} is damaged: {err}"),
        };
        if packet.track_id != track_id {
            continue;
        }
        let buffer = match decoder.decode(&packet) {
            Ok(buffer) => buffer,
            // One bad packet is a click at worst; keep going and only give up
            // if nothing at all decodes.
            Err(Error::DecodeError(err)) => {
                damaged.get_or_insert(err);
                continue;
            }
            Err(err) => bail!("{name} cannot be decoded: {err}"),
        };
        if buffer.frames() == 0 || buffer.num_planes() == 0 {
            continue;
        }
        sample_rate = buffer.spec().rate();
        buffer.copy_to_vecs_planar(&mut planes);
        sink.push(&planes[0], planes.get(1).map(Vec::as_slice))
            .with_context(|| format!("keeping the sound of {name}"))?;
    }
    if sink.frames() == 0 {
        match damaged {
            Some(err) => bail!("{name} is damaged and none of its audio decodes: {err}"),
            None => bail!("{name} holds no audio"),
        }
    }
    // A little slack for decoders that trim a few frames differently.
    if expected.is_some_and(|n| (sink.frames() as f64) < n as f64 * 0.98) {
        bail!("{}", truncated(&name, sink.frames(), expected, sample_rate));
    }
    if sample_rate == 0 {
        bail!("{name} does not say what its sample rate is");
    }
    sink.finish(sample_rate)
        .with_context(|| format!("keeping the sound of {name}"))
}

fn truncated(name: &dyn Display, frames: usize, expected: Option<u64>, rate: u32) -> String {
    let seconds = |n: f64| n / rate.max(1) as f64;
    let got = seconds(frames as f64);
    match expected {
        Some(n) => format!(
            "{name} is truncated: it holds {got:.2} s of audio but says it has {:.2} s",
            seconds(n as f64)
        ),
        None => format!("{name} is truncated: the audio stops after {got:.2} s"),
    }
}

pub struct AudioRegion {
    /// Project position in beats where the region starts and ends.
    pub start: f64,
    pub end: f64,
    pub data: Arc<AudioData>,
    /// Seconds into the source where playback starts.
    pub offset: f64,
    pub gain: f32,
    /// Beats over which the region comes in and goes out.
    pub fade_in: f64,
    pub fade_out: f64,
    /// The region starts, or ends, in the middle of its source, where a
    /// very short fade keeps the cut from clicking.
    pub declick_in: bool,
    pub declick_out: bool,
    /// Where the region stands with sound that is still being made.
    pub hold: Hold,
}

/// How a region plays sound that is still being made (a stretch played
/// while it is made): up to where the making has got, fading out just
/// before it, silent past it, and fading in again where it picks up once
/// more is there. Only the audio thread that plays the region touches it.
pub struct Hold(AtomicU64);

/// While the region has run out of sound.
const STARVED: f64 = f64::INFINITY;
/// While it plays as usual.
const PLAYING: f64 = f64::NEG_INFINITY;

impl Default for Hold {
    fn default() -> Self {
        Self(AtomicU64::new(PLAYING.to_bits()))
    }
}

impl Hold {
    fn get(&self) -> f64 {
        f64::from_bits(self.0.load(Ordering::Relaxed))
    }

    fn set(&self, at: f64) {
        self.0.store(at.to_bits(), Ordering::Relaxed);
    }

    /// Whether playing has to look at the hold: the sound is still being
    /// made, or the region is fading in again after it ran out.
    pub fn watched(&self, complete: bool) -> bool {
        !complete || self.get() != PLAYING
    }

    /// The region ran out of sound.
    pub fn starve(&self) {
        self.set(STARVED);
    }

    /// The gain at source frame `pos`, with `frames` frames there (all of
    /// them when `complete`); the fades are `fade` source frames long and
    /// shaped by `curve`.
    pub fn gain(
        &self,
        pos: f64,
        frames: usize,
        complete: bool,
        fade: f64,
        curve: fn(f64) -> f32,
    ) -> f32 {
        let mut from = self.get();
        if from == STARVED {
            // Picking up again here.
            from = pos;
            self.set(from);
        }
        let mut gain = 1.0;
        if pos >= from {
            if pos - from < fade {
                gain *= curve((pos - from) / fade);
            } else {
                self.set(PLAYING);
            }
        }
        let left = frames as f64 - 1.0 - pos;
        if !complete && left < fade {
            gain *= curve(left / fade);
        }
        gain
    }
}

/// Everything one track plays. Built on the main thread and handed to the
/// engine whole, so the audio thread only reads it.
#[derive(Default)]
pub struct ClipSet {
    /// Sorted by beat, with note-offs before note-ons on the same beat.
    pub midi: Vec<MidiEv>,
    pub audio: Vec<AudioRegion>,
}

impl ClipSet {
    pub fn push_note(&mut self, start: f64, end: f64, key: u8, vel: f32) {
        self.midi.push(MidiEv {
            beat: start,
            kind: EventKind::NoteOn { key, vel, ch: 0 },
        });
        self.midi.push(MidiEv {
            beat: end,
            kind: EventKind::NoteOff { key, ch: 0 },
        });
    }

    /// Add a controller move, a program change or any other event.
    pub fn push_event(&mut self, beat: f64, kind: EventKind) {
        self.midi.push(MidiEv { beat, kind });
    }

    /// Sort the events. Call once after the last push. On the same beat a
    /// note ends before a channel's controllers move, they move before a
    /// note starts, and a note's own controllers come after it has started.
    pub fn finish(&mut self) {
        let rank = |e: &MidiEv| match e.kind {
            EventKind::NoteOff { .. } | EventKind::AllNotesOff => 0u8,
            EventKind::Control { .. } | EventKind::Program { .. } => 1,
            EventKind::NoteOn { .. } => 2,
            EventKind::NoteControl { .. } => 3,
        };
        self.midi
            .sort_by(|a, b| a.beat.total_cmp(&b.beat).then(rank(a).cmp(&rank(b))));
    }
}
