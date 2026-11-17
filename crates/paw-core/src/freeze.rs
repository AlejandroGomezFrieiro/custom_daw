//! Frozen tracks: a track rendered to a sound file, which the engine plays in
//! place of the track's clips and devices, so that they cost nothing while it
//! is frozen.
//!
//! A track is frozen when its meta holds `frozen.file` (the runtime's
//! `paw.freeze` writes it, so freezing is saved and undone with the track).
//! The file is what comes out of the track before its fader: its clips, its
//! devices, and every track whose sound reaches it through outputs (the
//! members of a group). The fader, pan, mute and sends stay live. While it is
//! frozen, its devices are held (bypassed in the engine, not in the model)
//! and the tracks that feed it are held and silent, as the file holds them.
//!
//! The session can hold further tracks the same way without touching the
//! project ([`Mapper::held_files`](crate::sync::Mapper)): what narrowing to a
//! group does to the rest of the song, when asked to.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Result, bail};
use serde_json::Value;

use crate::model::{Id, MASTER_ID, Project, Target, Track};

/// What the engine plays of a track.
#[derive(Clone, Debug, PartialEq)]
pub enum Played {
    /// Its clips through its devices.
    Live,
    /// This file, from the start of the song, with its devices held.
    Frozen(PathBuf),
    /// Nothing: its sound is in a frozen track it feeds.
    Held,
}

/// The sound file a track is frozen to, from its meta.
pub fn frozen_file(track: &Track) -> Option<PathBuf> {
    track
        .meta
        .get("frozen")
        .and_then(|f| f.get("file"))
        .and_then(Value::as_str)
        .filter(|f| !f.is_empty())
        .map(PathBuf::from)
}

/// Point a frozen track at another file (saving relative to the project,
/// relinking a moved one). Returns whether it changed.
pub fn map_frozen_file(
    track: &mut Track,
    f: &mut impl FnMut(&std::path::Path) -> Option<PathBuf>,
) -> bool {
    let Some(new) = frozen_file(track).and_then(|file| f(&file)) else {
        return false;
    };
    if let Some(Value::Object(frozen)) = track.meta.get_mut("frozen") {
        frozen.insert(
            "file".into(),
            Value::String(new.to_string_lossy().into_owned()),
        );
        return true;
    }
    false
}

/// The tracks whose outputs lead, one after another, into `id`.
fn feeders(project: &Project, id: Id) -> HashSet<Id> {
    let output: HashMap<Id, Option<Id>> = project.tracks.iter().map(|t| (t.id, t.output)).collect();
    let mut out = HashSet::new();
    for t in &project.tracks {
        let mut at = t.output;
        // Routing has no loops (the model refuses them); the bound is a guard.
        for _ in 0..64 {
            match at {
                Some(next) if next == id => {
                    out.insert(t.id);
                    break;
                }
                Some(next) if next != MASTER_ID => at = output.get(&next).copied().flatten(),
                _ => break,
            }
        }
    }
    out
}

/// What the engine plays of every track that is not live: frozen in the
/// project or in `extra`, or held inside a frozen track. A track frozen
/// inside another frozen track is held.
pub fn played(project: &Project, extra: &HashMap<Id, PathBuf>) -> HashMap<Id, Played> {
    let mut out = HashMap::new();
    let frozen: HashMap<Id, PathBuf> = project
        .tracks
        .iter()
        .filter_map(|t| {
            frozen_file(t)
                .or_else(|| extra.get(&t.id).cloned())
                .map(|f| (t.id, f))
        })
        .collect();
    if frozen.is_empty() {
        return out;
    }
    for (&id, file) in &frozen {
        out.entry(id)
            .or_insert_with(|| Played::Frozen(file.clone()));
        for fed in feeders(project, id) {
            out.insert(fed, Played::Held);
        }
    }
    out
}

/// Turn a copy of the project into what freezing `id` renders: the track
/// and the tracks that feed it, as they sound before its fader, with every
/// other track silent and the master's own processing left to the caller
/// (a render with `master = false`). The track itself plays live, even when
/// it is frozen now; tracks frozen inside it play their files.
pub fn alone(project: &mut Project, id: Id) -> Result<()> {
    if id == MASTER_ID {
        bail!("the master track cannot be frozen");
    }
    if project.track(id).is_none() {
        bail!("no track {id} to freeze");
    }
    let mut set = feeders(project, id);
    set.insert(id);
    let is_vca = |t: &Track| t.meta.get("vca").and_then(Value::as_bool) == Some(true);
    for track in project.tracks.iter_mut() {
        let wanted = set.contains(&track.id);
        // A VCA carries no sound, and muting it would mute its members.
        let mute = !wanted && !is_vca(track);
        if track.solo || (mute && !track.mute) {
            let t = Arc::make_mut(track);
            t.solo = false;
            t.mute |= mute;
        }
    }
    let track = project.track_mut(id).expect("checked above");
    // Before the fader: what the fader, pan, VCAs and sends do stays live.
    track.volume = 0.0;
    track.pan = 0.0;
    track.mute = false;
    track.output = None;
    track.sends.clear();
    track
        .lanes
        .retain(|l| !matches!(l.target, Target::Volume | Target::Pan));
    track.meta.remove("vcas");
    track.meta.remove("frozen");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Violins and cellos in Strings, which is frozen; drums apart.
    fn song() -> Project {
        let mut p = Project::default();
        let mut strings = Track::new(1);
        strings
            .meta
            .insert("frozen".into(), json!({ "file": "/m/strings.wav" }));
        strings.volume = -6.0;
        let mut violins = Track::new(2);
        violins.output = Some(1);
        let mut cellos = Track::new(3);
        cellos.output = Some(1);
        let drums = Track::new(4);
        p.tracks = [strings, violins, cellos, drums]
            .into_iter()
            .map(Arc::new)
            .collect();
        p
    }

    #[test]
    fn a_frozen_track_plays_its_file_and_what_feeds_it_is_held() {
        let played = played(&song(), &HashMap::new());
        assert_eq!(
            played.get(&1),
            Some(&Played::Frozen("/m/strings.wav".into()))
        );
        assert_eq!(played.get(&2), Some(&Played::Held));
        assert_eq!(played.get(&3), Some(&Played::Held));
        assert_eq!(played.get(&4), None);
        let extra = HashMap::from([(4, PathBuf::from("/m/drums.wav"))]);
        assert_eq!(
            super::played(&song(), &extra).get(&4),
            Some(&Played::Frozen("/m/drums.wav".into()))
        );
    }

    #[test]
    fn a_freeze_renders_the_track_alone_before_its_fader() {
        let mut p = song();
        alone(&mut p, 1).unwrap();
        let t = p.track(1).unwrap();
        assert_eq!((t.volume, t.mute, t.output), (0.0, false, None));
        assert!(frozen_file(t).is_none(), "the track itself plays live");
        assert!(
            !p.track(2).unwrap().mute && !p.track(3).unwrap().mute,
            "its members play"
        );
        assert!(p.track(4).unwrap().mute, "the rest is silent");
        assert!(alone(&mut p, MASTER_ID).is_err());
    }
}
