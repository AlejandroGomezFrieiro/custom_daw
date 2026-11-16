//! Operations on audio clips that make a new file: reverse and glue; and
//! normalize, which only sets the clip's gain. None touches the file a clip
//! played before, and each is one undo step.

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result, bail};
use daw_engine::AudioData;
use serde_json::{Value, json};

use super::{RenderOpts, Session, unique_path};
use crate::model::{Clip, ClipContent, Id, MASTER_ID};

impl Session {
    /// The file, offset and gain of an audio clip.
    fn audio_clip(&self, id: Id) -> Result<(Arc<Clip>, PathBuf, f64, f64)> {
        let clip = self
            .project
            .clip(id)
            .with_context(|| format!("no clip {id}"))?
            .clone();
        let ClipContent::Audio { file, offset, gain } = &clip.content else {
            bail!("clip {id} is a MIDI clip: this works on audio clips");
        };
        let (file, offset, gain) = (file.clone(), *offset, *gain);
        Ok((clip, file, offset, gain))
    }

    /// The samples an audio clip plays, from its offset for its length;
    /// silence past the end of the file.
    fn clip_samples(&mut self, id: Id) -> Result<(AudioData, Arc<Clip>, f64)> {
        let (clip, file, offset, gain) = self.audio_clip(id)?;
        let data = self.audio.load(&file)?;
        let rate = data.sample_rate as f64;
        let from = (offset * rate).round() as usize;
        // Its real extent in time, by the tempo map, in seconds of the file.
        let seconds = self
            .project
            .tempo_map()
            .seconds_between(clip.start, clip.start + clip.length)
            / clip.stretch;
        let frames = (seconds * rate).round() as usize;
        let take = |c: &[f32]| {
            let mut out: Vec<f32> = c.iter().skip(from).take(frames).copied().collect();
            out.resize(frames, 0.0);
            out
        };
        let part = AudioData {
            sample_rate: data.sample_rate,
            channels: [
                take(&data.channels[0]).into(),
                take(&data.channels[1]).into(),
            ],
        };
        Ok((part, clip, gain))
    }

    /// A new file in the project's media directory, named after a clip.
    fn new_media_file(&self, clip: &Clip, what: &str) -> Result<PathBuf> {
        let dir = self.media_dir();
        std::fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
        Ok(unique_path(
            &dir,
            &format!("{}-{what}", super::file_safe(&clip.name)),
        ))
    }

    /// Play an audio clip backwards: its part of the file, reversed, as a new
    /// file. Its fades change ends too.
    pub fn clip_reverse(&mut self, id: Id) -> Result<Value> {
        let (mut part, clip, _) = self.clip_samples(id)?;
        for channel in &mut part.channels {
            channel.reverse();
        }
        let path = self.new_media_file(&clip, "reversed")?;
        write_float(&path, &part)?;
        self.edit(|p| {
            let c = p.clip_mut(id).context("the clip went away")?;
            if let ClipContent::Audio { file, offset, .. } = &mut c.content {
                *file = path.clone();
                *offset = 0.0;
            }
            std::mem::swap(&mut c.fade_in, &mut c.fade_out);
            Ok(())
        })?;
        Ok(json!({ "file": path }))
    }

    /// Bring the loudest sample an audio clip plays to `level` dB, by its
    /// gain. Returns the new gain.
    pub fn clip_normalize(&mut self, id: Id, level: f64) -> Result<f64> {
        if !level.is_finite() || level > 0.0 {
            bail!("normalize to a level in dB at or below 0, such as -1");
        }
        let (part, _, _) = self.clip_samples(id)?;
        let peak = part
            .channels
            .iter()
            .flatten()
            .fold(0f32, |m, s| if s.is_finite() { m.max(s.abs()) } else { m });
        if peak <= 0.0 {
            bail!("clip {id} is silent: there is nothing to bring to a level");
        }
        let gain = (level - daw_engine::gain_to_db(peak)).clamp(-120.0, 24.0);
        self.edit(|p| {
            let c = p.clip_mut(id).context("the clip went away")?;
            if let ClipContent::Audio { gain: g, .. } = &mut c.content {
                *g = gain;
            }
            Ok(())
        })?;
        Ok(gain)
    }

    /// Join audio clips of one track into one clip playing a new file: what
    /// they play together, with their gains, fades and overlaps, and without
    /// the track's devices, fader or pan. With one clip, it and every audio
    /// clip on its track that touches or overlaps it, one after another.
    pub fn clip_glue(&mut self, ids: &[Id]) -> Result<Value> {
        let first = *ids.first().context("no clips to glue")?;
        let (track, _) = self
            .project
            .find_clip(first)
            .with_context(|| format!("no clip {first}"))?;
        let clips: Vec<Arc<Clip>> = self
            .project
            .track(track)
            .context("no such track")?
            .clips
            .clone();
        let audio = |c: &Clip| matches!(c.content, ClipContent::Audio { .. });
        let mut chosen: Vec<Id> = ids.to_vec();
        if ids.len() == 1 {
            // Grow the run both ways while a clip touches or overlaps it.
            let (mut lo, mut hi) = {
                let c = clips.iter().find(|c| c.id == first).context("no clip")?;
                (c.start, c.start + c.length)
            };
            loop {
                let before = chosen.len();
                for c in &clips {
                    if audio(c)
                        && !chosen.contains(&c.id)
                        && c.start <= hi + 1e-9
                        && c.start + c.length >= lo - 1e-9
                    {
                        chosen.push(c.id);
                        lo = lo.min(c.start);
                        hi = hi.max(c.start + c.length);
                    }
                }
                if chosen.len() == before {
                    break;
                }
            }
        }
        for id in &chosen {
            let c = clips
                .iter()
                .find(|c| c.id == *id)
                .with_context(|| format!("clip {id} is not on the same track as clip {first}"))?;
            if !audio(c) {
                bail!("clip {id} is a MIDI clip: only audio clips are glued");
            }
        }
        if chosen.len() < 2 {
            bail!("nothing to glue: no other audio clip touches clip {first}");
        }
        let start = clips
            .iter()
            .filter(|c| chosen.contains(&c.id))
            .map(|c| c.start)
            .fold(f64::INFINITY, f64::min);
        let end = clips
            .iter()
            .filter(|c| chosen.contains(&c.id))
            .map(|c| c.start + c.length)
            .fold(f64::NEG_INFINITY, f64::max);

        // A project of these clips alone on a bare track, straight to a bare master.
        self.capture_states();
        let mut project = self.project.clone();
        project.tracks.retain(|t| t.id == track);
        if track == MASTER_ID {
            bail!("clips on the master track cannot be glued");
        }
        {
            let t = Arc::make_mut(&mut project.tracks[0]);
            t.clips.retain(|c| chosen.contains(&c.id));
            t.devices.clear();
            t.lanes.clear();
            t.sends.clear();
            (t.volume, t.pan, t.mute, t.solo, t.output) = (0.0, 0.0, false, false, None);
            t.input = None;
        }
        let first_clip = clips
            .iter()
            .find(|c| c.id == first)
            .context("no clip")?
            .clone();
        let path = self.new_media_file(&first_clip, "glued")?;
        let opts = RenderOpts {
            start,
            end: Some(end),
            tail: 0.0,
            bits: 32,
            master: false,
            ..RenderOpts::default()
        };
        self.render_snapshot(project, &path, &opts)?;
        self.render_wait()?;

        let glued = Arc::new(Clip {
            timebase: None,
            stretch: 1.0,
            pitch: 0.0,
            stretch_mode: Default::default(),
            source_tempo: None,
            looped: false,
            loop_length: None,
            loop_start: 0.0,
            id: self.new_id(),
            name: first_clip.name.clone(),
            start,
            length: end - start,
            muted: false,
            content: ClipContent::Audio {
                file: path.clone(),
                offset: 0.0,
                gain: 0.0,
            },
            fade_in: 0.0,
            fade_out: 0.0,
            meta: first_clip.meta.clone(),
        });
        let id = glued.id;
        self.edit(|p| {
            let t = p.track_mut(track).context("the track went away")?;
            let at = t
                .clips
                .iter()
                .position(|c| chosen.contains(&c.id))
                .unwrap_or(t.clips.len());
            t.clips.retain(|c| !chosen.contains(&c.id));
            t.clips.insert(at.min(t.clips.len()), glued);
            Ok(())
        })?;
        Ok(json!({ "id": id, "file": path, "glued": chosen.len() }))
    }
}

/// Write stereo samples as a 32-bit float WAV file.
fn write_float(path: &std::path::Path, data: &AudioData) -> Result<()> {
    let mut w = daw_engine::wav::Writer::create(path, data.sample_rate, 32, true)
        .with_context(|| format!("creating {}", path.display()))?;
    for (l, r) in data.channels[0].iter().zip(&data.channels[1]) {
        w.write(*l)?;
        w.write(*r)?;
    }
    w.finish()
}
