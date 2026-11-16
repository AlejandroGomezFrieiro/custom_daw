//! Stretched, shifted and looped clips: the fields that set them, the
//! versions of files made for them (`stretched.rs`) put in place as they
//! are made, and their waveforms.
//!
//! A clip's `stretch` is the ratio it plays its file at, whatever its
//! timebase: a clip in [`Timebase::Stretch`] has it set again whenever the
//! tempo changes (`Project::retime`), and its `source_tempo` says what its
//! sound's own tempo is, so that `stretch = source_tempo / tempo` at its
//! start. While a version is being made its clip is silent.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};

use super::{MAX_PEAKS, Session, de};
use crate::model::{Clip, ClipContent, Id, Project, Timebase};
use crate::peaks;
use crate::stretch::{PITCH_RANGE, RATIO_RANGE};
use crate::stretched::{Key, SETTLE, Status};

/// The clip fields set here rather than in `Session::clip_set`.
const FIELDS: [&str; 8] = [
    "stretch",
    "pitch",
    "stretch_mode",
    "source_tempo",
    "timebase",
    "loop",
    "loop_length",
    "loop_start",
];

/// Check how a new clip of `kind` is to play.
pub(super) fn check_playing(
    kind: &str,
    stretch: f64,
    pitch: f64,
    source_tempo: Option<f64>,
) -> Result<()> {
    if kind != "audio" && (stretch != 1.0 || pitch != 0.0) {
        bail!("only audio clips are stretched or shifted");
    }
    check_ratio(stretch)?;
    check_pitch(pitch)?;
    if let Some(bpm) = source_tempo {
        check_tempo(bpm)?;
    }
    Ok(())
}

fn check_ratio(ratio: f64) -> Result<f64> {
    let (lo, hi) = RATIO_RANGE;
    if !(lo..=hi).contains(&ratio) {
        bail!("a clip is stretched to between {lo} and {hi} times its length, not {ratio}");
    }
    Ok(ratio)
}

fn check_pitch(semitones: f64) -> Result<f64> {
    if !semitones.is_finite() || semitones.abs() > PITCH_RANGE {
        bail!("a clip is shifted by at most {PITCH_RANGE} semitones either way, not {semitones}");
    }
    Ok(semitones)
}

fn check_tempo(bpm: f64) -> Result<f64> {
    if !(1.0..=999.0).contains(&bpm) {
        bail!("a tempo is between 1 and 999, not {bpm}");
    }
    Ok(bpm)
}

/// The versions every stretched clip of `project` plays at `rate`.
fn wanted(project: &Project, rate: u32) -> HashSet<Key> {
    project
        .all_tracks()
        .flat_map(|t| t.clips.iter())
        .filter_map(|c| Key::of(c, rate))
        .collect()
}

impl Session {
    /// Set one of the [`FIELDS`] of a clip; `None` for any other field.
    pub(super) fn clip_set_playing(
        &mut self,
        id: Id,
        key: &str,
        value: &Value,
    ) -> Option<Result<()>> {
        FIELDS
            .contains(&key)
            .then(|| self.set_playing(id, key, value.clone()))
    }

    fn set_playing(&mut self, id: Id, key: &str, value: Value) -> Result<()> {
        let clip = self
            .project
            .clip(id)
            .with_context(|| format!("no clip {id}"))?
            .clone();
        let audio = matches!(clip.content, ClipContent::Audio { .. });
        if !audio && !key.starts_with("loop") {
            bail!("only audio clips have `{key}`");
        }
        let tempo = self.project.tempo_map().tempo(clip.start);
        // What a loop turned on repeats unless it was given a length: a
        // MIDI clip what it holds now, an audio clip its file from where
        // it starts playing it.
        let natural = match (key, &value) {
            ("loop", Value::Bool(true)) if clip.loop_length.is_none() => Some(if audio {
                self.clip_source_length(id)?
            } else {
                clip.length
            }),
            _ => None,
        };
        let number = |value: &Value| -> Result<Option<f64>> {
            match value {
                Value::Null => Ok(None),
                value => {
                    let n: f64 = de(key, value.clone())?;
                    if !n.is_finite() {
                        bail!("`{key}` is a number, not {n}");
                    }
                    Ok(Some(n))
                }
            }
        };
        self.edit(|p| {
            let c = p.clip_mut(id).expect("the clip was found");
            match key {
                "stretch" => {
                    c.stretch = check_ratio(number(&value)?.unwrap_or(1.0))?;
                    // Its sound's own tempo is as much faster as it is slowed.
                    if c.timebase == Some(Timebase::Stretch) {
                        c.source_tempo = Some(tempo * c.stretch);
                    }
                }
                "pitch" => c.pitch = check_pitch(number(&value)?.unwrap_or(0.0))?,
                "stretch_mode" => c.stretch_mode = de(key, value)?,
                "source_tempo" => match number(&value)? {
                    None => c.source_tempo = None,
                    Some(bpm) => {
                        let bpm = check_tempo(bpm)?;
                        if c.timebase == Some(Timebase::Stretch) {
                            c.stretch = check_ratio(bpm / tempo).context(
                                "the clip would be stretched too far to follow the tempo",
                            )?;
                        }
                        c.source_tempo = Some(bpm);
                    }
                },
                "timebase" => {
                    let timebase: Timebase = de(key, value)?;
                    if timebase == Timebase::Stretch && c.source_tempo.is_none() {
                        c.source_tempo = Some(tempo * c.stretch);
                    }
                    c.timebase = Some(timebase);
                }
                "loop" => {
                    let on: bool = de(key, value)?;
                    if on && c.loop_length.is_none() {
                        let Some(beats) = natural.filter(|l| *l > 1e-9) else {
                            bail!("the clip has nothing to repeat");
                        };
                        c.loop_length = Some(beats);
                    }
                    c.looped = on;
                }
                "loop_length" => match number(&value)? {
                    Some(beats) if beats <= 0.0 => bail!("a loop is longer than 0 beats"),
                    beats => c.loop_length = beats,
                },
                "loop_start" => c.loop_start = number(&value)?.unwrap_or(0.0),
                _ => unreachable!("one of FIELDS"),
            }
            Ok(())
        })
    }

    /// Note on a clip's description that its version is still being made.
    pub(super) fn note_stretching(&self, clip: &Clip, view: &mut Value) {
        let key = Key::of(clip, self.handle.sample_rate as u32);
        if self.audio.renders.status(key.as_ref()) == Status::Making {
            view["stretching"] = json!(true);
        }
    }

    /// Start versions that have waited long enough, drop those no clip
    /// wants any more, and build again the tracks whose clips play one
    /// that has been made. Called regularly, from [`idle`](Self::idle).
    pub(super) fn poll_stretches(&mut self) {
        let renders = &self.audio.renders;
        if !renders.busy() && renders.finished.is_empty() {
            return;
        }
        let rate = self.handle.sample_rate as u32;
        let store = self.audio.store.clone();
        self.audio
            .renders
            .poll(&wanted(&self.project, rate), SETTLE, store.as_ref());
        self.warnings.append(&mut self.audio.renders.failures);
        let finished: HashSet<Key> = self.audio.renders.finished.drain(..).collect();
        if finished.is_empty() {
            return;
        }
        // The engine builds a clip again when its copy differs from the
        // one it last saw: those clips are made to differ.
        let touched = |c: &Arc<Clip>| Key::of(c, rate).is_some_and(|k| finished.contains(&k));
        let synced = &mut self.synced;
        for track in std::iter::once(&mut synced.master).chain(synced.tracks.iter_mut()) {
            if track.clips.iter().any(touched) {
                for clip in Arc::make_mut(track).clips.iter_mut() {
                    if touched(clip) {
                        *clip = Arc::new((**clip).clone());
                    }
                }
            }
        }
        self.dirty = true;
        self.flush();
    }

    /// Wait up to `limit` for every version `project`'s clips play at
    /// `rate`: for rendering, which needs them all.
    pub(super) fn await_stretches(
        &mut self,
        project: &Project,
        rate: u32,
        limit: Duration,
    ) -> Result<()> {
        let keys = wanted(project, rate);
        if keys.is_empty() {
            return Ok(());
        }
        for key in &keys {
            self.audio.stretched(key, &mut self.warnings);
        }
        let mut all = keys.clone();
        all.extend(wanted(&self.project, self.handle.sample_rate as u32));
        let store = self.audio.store.clone();
        let deadline = Instant::now() + limit;
        while self.audio.renders.making(&keys) {
            if Instant::now() > deadline {
                bail!("the stretched clips are still being made");
            }
            self.audio
                .renders
                .poll(&all, Duration::ZERO, store.as_ref());
            std::thread::sleep(Duration::from_millis(5));
        }
        self.warnings.append(&mut self.audio.renders.failures);
        Ok(())
    }

    /// An audio clip's waveform as [`clip_peaks`](Self::clip_peaks) gives
    /// it, before its gain: of the version it plays once that is made (of
    /// its file squeezed or spread in time until then), and repeated as a
    /// looped clip repeats.
    pub(super) fn playing_peaks(&mut self, clip: &Clip, n: usize) -> Result<Vec<[f32; 3]>> {
        let ClipContent::Audio { file, offset, .. } = &clip.content else {
            bail!("clip {} is not an audio clip", clip.id);
        };
        let map = self.project.tempo_map().clone();
        let seconds = map.seconds_between(clip.start, clip.start + clip.length);
        let key = Key::of(clip, self.handle.sample_rate as u32);
        let stretch = clip.stretch;
        let audio = &mut self.audio;
        // `seconds` of what plays from `from`, in seconds of what plays.
        let mut part = |from: f64, seconds: f64, n: usize| -> Result<Vec<[f32; 3]>> {
            if let Some(ready) = key.as_ref().and_then(|k| audio.renders.ready(k)) {
                let summary = ready.summary();
                let rate = ready.data.sample_rate as f64;
                return Ok(peaks::peaks(
                    &ready.data,
                    &summary,
                    from * rate,
                    (from + seconds) * rate,
                    n,
                ));
            }
            Ok(audio
                .peaks(file, (from / stretch).max(0.0), seconds / stretch, n)?
                .to_vec())
        };
        let begin = offset * stretch;
        let Some((from, beats)) = clip.repeat() else {
            return part(begin, seconds, n);
        };
        let period = map.seconds_between(clip.start, clip.start + beats);
        if period <= 1e-9 || seconds <= 0.0 || n == 0 {
            return Ok(Vec::new());
        }
        let lead = from * period / beats;
        let per = ((n as f64 * period / seconds).ceil() as usize).clamp(1, MAX_PEAKS);
        let one = part(begin + lead, period, per)?;
        if one.is_empty() {
            return Ok(Vec::new());
        }
        Ok((0..n)
            .map(|i| {
                let at = (i as f64 + 0.5) * seconds / n as f64;
                let phase = (at - lead).rem_euclid(period) / period;
                one[((phase * one.len() as f64) as usize).min(one.len() - 1)]
            })
            .collect())
    }
}
