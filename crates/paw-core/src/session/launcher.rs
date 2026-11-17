//! Clip launching: clips in tracks' slots, apart from the timeline, and
//! launching them while the song plays.
//!
//! A clip in a slot is a clip like any other (its notes are edited with the
//! same calls) kept in `Track::slots` with its row. Launching is a message
//! to the engine, which starts the clip on the next boundary of its
//! quantize to the frame (`paw_engine::launch`); what plays is read back
//! from the engine, never kept here, so it is not part of the project or
//! of undo. A render plays the timeline: a fresh engine has nothing launched.

use std::sync::Arc;

use anyhow::{Context, Result, bail};
use paw_engine::Msg;
use paw_engine::launch::{Launch, Target};
use serde::Deserialize;
use serde_json::{Value, json};

use super::{Session, de};
use crate::model::{Id, LaunchMode, Project, Quantize, SlotClip, Track};

/// One track's launch, from a script: `{ track =, slot = }` plays the clip
/// in a row, `{ track =, stop = true }` stops the track, and
/// `{ track =, arrangement = true }` has it play its timeline again.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LaunchOpts {
    pub track: Id,
    #[serde(default)]
    pub slot: Option<u32>,
    #[serde(default)]
    pub stop: bool,
    #[serde(default)]
    pub arrangement: bool,
    /// In place of the slot's or the project's.
    #[serde(default)]
    pub quantize: Option<Quantize>,
    #[serde(default)]
    pub legato: Option<bool>,
    /// The beat the clip's loop counts from, as if it had played since then.
    #[serde(default)]
    pub from: Option<f64>,
}

/// Put a clip in a track's row, in place of whatever was there.
pub(super) fn put_slot(track: &mut Track, slot: SlotClip) {
    match track.slots.binary_search_by_key(&slot.row, |s| s.row) {
        Ok(at) => track.slots[at] = slot,
        Err(at) => track.slots.insert(at, slot),
    }
}

/// The slot a clip is in, to change.
fn slot_mut(p: &mut Project, id: Id) -> Option<&mut SlotClip> {
    let (track, index) = p.find_slot_clip(id)?;
    Some(&mut p.track_mut(track)?.slots[index])
}

/// What a clip view says of the slot a clip is in.
pub(super) fn slot_json(slot: &SlotClip, view: &mut Value) {
    view["slot"] = json!(slot.row);
    view["quantize"] = json!(slot.quantize);
    view["mode"] = json!(slot.mode);
    view["legato"] = json!(slot.legato);
}

/// Change what is particular to a clip in a slot: `row`, `quantize`
/// (nil for the project's), `mode`, `legato`, or `track` (to the same row
/// of another track). False for the keys every clip has.
pub(super) fn set_slot_key(p: &mut Project, id: Id, key: &str, value: Value) -> Result<bool> {
    let (from, index) = p.find_slot_clip(id).context("not in a slot")?;
    match key {
        "quantize" => slot_mut(p, id).unwrap().quantize = de(key, value)?,
        "mode" => slot_mut(p, id).unwrap().mode = de::<LaunchMode>(key, value)?,
        "legato" => slot_mut(p, id).unwrap().legato = de(key, value)?,
        "row" | "track" => {
            let slot = p.track(from).unwrap().slots[index].clone();
            let (to, row) = if key == "row" {
                (from, de::<u32>(key, value)?)
            } else {
                (de::<Id>(key, value)?, slot.row)
            };
            if p.track(to).is_none() {
                bail!("no track {to}");
            }
            p.track_mut(from).unwrap().slots.remove(index);
            put_slot(p.track_mut(to).unwrap(), SlotClip { row, ..slot });
        }
        "start" => bail!("a clip in a slot starts at 0"),
        _ => return Ok(false),
    }
    Ok(true)
}

impl Session {
    /// The clips in a track's slots, in order of their rows, without their notes.
    pub fn slot_list(&self, track: Id) -> Result<Value> {
        let t = self
            .project
            .track(track)
            .with_context(|| format!("no track {track}"))?;
        Ok(Value::Array(
            t.slots
                .iter()
                .map(|s| {
                    let mut view = super::clip_json(&s.clip, track);
                    slot_json(s, &mut view);
                    view
                })
                .collect(),
        ))
    }

    /// Copy a clip, from the timeline or from another slot, into a track's
    /// row, in place of what was there. Returns the copy's id.
    pub fn clip_to_slot(&mut self, id: Id, track: Id, row: u32) -> Result<Id> {
        let clip = self
            .project
            .clip(id)
            .with_context(|| format!("no clip {id}"))?;
        let mut copy = (**clip).clone();
        copy.start = 0.0;
        copy.id = self.new_id();
        let copy_id = copy.id;
        self.edit(|p| {
            let t = p
                .track_mut(track)
                .with_context(|| format!("no track {track}"))?;
            put_slot(
                t,
                SlotClip {
                    row,
                    clip: Arc::new(copy),
                    quantize: None,
                    mode: LaunchMode::Trigger,
                    legato: false,
                },
            );
            Ok(copy_id)
        })
    }

    /// Launch, stop or send back to the arrangement: every track asked for
    /// on the boundary of its quantize, all timed together.
    pub fn launch(&mut self, asked: Vec<LaunchOpts>) -> Result<()> {
        // The engine must hold the slots as they are now.
        self.flush();
        let mut launches = Vec::with_capacity(asked.len());
        for opts in asked {
            let track = self
                .project
                .track(opts.track)
                .with_context(|| format!("no track {}", opts.track))?;
            let Some(&slot) = self.map.tracks.get(&opts.track) else {
                continue;
            };
            let target = match (opts.slot, opts.stop, opts.arrangement) {
                (Some(row), false, false) => Target::Slot(row),
                (None, true, false) => Target::Stop,
                (None, false, true) => Target::Arrangement,
                _ => bail!("a launch names one of `slot`, `stop` or `arrangement`"),
            };
            let clip = opts
                .slot
                .and_then(|row| track.slots.iter().find(|s| s.row == row));
            let quantize = opts
                .quantize
                .or(clip.and_then(|s| s.quantize))
                .unwrap_or(self.project.launch_quantize);
            launches.push(Launch {
                track: slot,
                target,
                quantize: quantize.engine(),
                legato: opts.legato.unwrap_or(clip.is_some_and(|s| s.legato)),
                from: opts.from,
            });
        }
        if !launches.is_empty() {
            self.handle.send(Msg::Launch(Box::new(launches)));
        }
        Ok(())
    }

    /// Every track back to the arrangement at once, with nothing queued:
    /// for a project just opened, whose tracks may sit where another's were.
    pub(super) fn launcher_reset(&mut self) {
        let launches: Vec<Launch> = self
            .project
            .tracks
            .iter()
            .filter_map(|t| self.map.tracks.get(&t.id))
            .map(|&track| Launch {
                track,
                target: Target::Arrangement,
                quantize: paw_engine::launch::Quantize::Off,
                legato: false,
                from: None,
            })
            .collect();
        if !launches.is_empty() {
            self.handle.send(Msg::Launch(Box::new(launches)));
        }
    }

    /// What each track plays, as the engine last said: `slot` (a row) or
    /// `stopped`, or neither for the arrangement; `phase` (beats into the
    /// slot's loop) and `length`; `since`, the beat it began on; and what is
    /// queued (`queued` is a row, `"stop"` or `"arrangement"`) with the beat
    /// it happens on (`at`).
    pub fn launcher_view(&self) -> Value {
        let name = |target: Target| match target {
            Target::Slot(row) => json!(row),
            Target::Stop => json!("stop"),
            Target::Arrangement => json!("arrangement"),
        };
        let mut out = Vec::new();
        for track in &self.project.tracks {
            let Some(state) = self
                .map
                .tracks
                .get(&track.id)
                .and_then(|&slot| self.handle.shared.launch(slot))
            else {
                continue;
            };
            let mut view = json!({ "track": track.id, "since": state.since });
            match state.playing {
                Target::Slot(row) => {
                    view["slot"] = json!(row);
                    view["phase"] = json!(state.phase);
                    if let Some(s) = track.slots.iter().find(|s| s.row == row) {
                        view["length"] = json!(s.clip.length);
                    }
                }
                Target::Stop => view["stopped"] = json!(true),
                Target::Arrangement => {}
            }
            if let Some((target, at)) = state.queued {
                view["queued"] = name(target);
                view["at"] = json!(at);
            }
            out.push(view);
        }
        Value::Array(out)
    }
}
