//! Turns the difference between two project snapshots into engine messages and
//! change events.
//!
//! This is the only place that tells the engine what the project looks like.
//! Edits, undo, loading a project and offline rendering all end up here, so
//! none of them can leave the engine out of step with the model.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use base64::Engine as _;
use daw_engine::midi_form::Form;
use base64::engine::general_purpose::STANDARD as BASE64;
use daw_engine::launch::{SlotClip, Slots};
use daw_engine::{
    AudioData, AudioRegion, AutoLane, AutoTarget, Automation, ClipSet, Controller, Delay,
    DiskStore, MASTER,
    KeyRt, MAX_BLOCK, MAX_DELAY, MAX_DEVICES, MAX_TRACKS, MidiEv, Msg, NO_SLOT, OutRt, ParamInfo,
    Registry, SchedEntry, Schedule, SendRt, Slot, TrackRt, db_to_gain,
};
use serde_json::{Value, json};

use crate::model::{
    Clip, ClipContent, Control, DeviceInst, Id, Lane, MASTER_ID, Note, Project, Target, Track,
};
use crate::peaks::{self, Summary};

/// A change notification for Lua: event name and payload.
pub type ModelEvent = (String, Value);

/// Where a track's signal goes, and how late it is when it leaves.
#[derive(Clone, Debug, PartialEq)]
struct Route {
    track: Id,
    output: Id,
    /// Target, gain, and whether it is taken before the fader.
    sends: Vec<(Id, f32, bool)>,
    /// Devices on other tracks that listen to this one: see [`Key`].
    keys: Vec<Key>,
    /// Further output pairs of this track's devices: see [`Out`].
    outs: Vec<Out>,
    /// Frames of latency of the track's own devices.
    latency: u32,
}

/// A side-chain, as the track it is taken from sees it.
#[derive(Clone, Debug, PartialEq)]
struct Key {
    /// The track the listening device is on, and the device.
    track: Id,
    device: Id,
    /// Taken before the fader.
    pre: bool,
    /// Frames of latency of the devices before it on its track, which the
    /// key waits for so that it lines up with what the device hears.
    before: u32,
}

/// One of a device's further output pairs, played into another track.
#[derive(Clone, Debug, PartialEq)]
struct Out {
    device: Id,
    /// 0 for the device's second pair.
    pair: usize,
    target: Id,
    /// Frames of latency of the track's devices up to this one, included:
    /// how late after the track's input the pair leaves.
    late: u32,
}

type Routing = Vec<Route>;

/// Which engine slot each track and device lives in.
pub struct Mapper {
    pub tracks: HashMap<Id, Slot>,
    pub devices: HashMap<Id, Slot>,
    free_tracks: Vec<Slot>,
    free_devices: Vec<Slot>,
    next_track: Slot,
    next_device: Slot,
    mix: HashMap<Id, (f32, f32, bool, bool)>,
    /// The fader lane each track has because of the VCAs it is in, as last
    /// sent: see [`vca_volume_lane`].
    vca_lanes: HashMap<Id, Vec<(f64, f64)>>,
    /// First input channel, channel count, monitoring and armed, as last sent.
    inputs: HashMap<Id, (usize, usize, bool, bool)>,
    /// The MIDI port's key and channel each track takes, as last sent.
    midi_inputs: HashMap<Id, (u32, u8)>,
    /// The same for the port each track sends to.
    midi_outputs: HashMap<Id, (u32, u8, Form)>,
    routing: Routing,
    /// Devices given a buffer for a side-chain.
    keyed: HashSet<Id>,
    /// Devices given buffers for further output pairs, and which.
    outs: HashMap<Id, Vec<usize>>,
    /// Frames by which the output is behind the transport, as last scheduled.
    pub latency: u32,
    /// Each track's MIDI clips as engine events, kept from one sync to the
    /// next so that an edit only compiles again the clips it changed.
    clip_events: HashMap<Id, Vec<CompiledClip>>,
    /// Each device's latency as last told to the host's dry signal.
    host_latency: HashMap<Id, u32>,
    /// Make devices whose factories can ([`DeviceFactory::starts_apart`])
    /// without waiting for them: each gets a stand-in, and its id is put
    /// in [`deferred`](Self::deferred) for the session to make it.
    ///
    /// [`DeviceFactory::starts_apart`]: daw_engine::DeviceFactory::starts_apart
    pub defer: bool,
    /// Devices given a stand-in since the session last looked.
    pub deferred: Vec<Id>,
}

impl Default for Mapper {
    fn default() -> Self {
        Self::new()
    }
}

impl Mapper {
    pub fn new() -> Self {
        Self {
            tracks: HashMap::from([(MASTER_ID, MASTER)]),
            devices: HashMap::new(),
            free_tracks: Vec::new(),
            free_devices: Vec::new(),
            next_track: MASTER + 1,
            next_device: 0,
            mix: HashMap::new(),
            vca_lanes: HashMap::new(),
            inputs: HashMap::new(),
            midi_inputs: HashMap::new(),
            midi_outputs: HashMap::new(),
            routing: Vec::new(),
            keyed: HashSet::new(),
            outs: HashMap::new(),
            latency: 0,
            clip_events: HashMap::new(),
            host_latency: HashMap::new(),
            defer: false,
            deferred: Vec::new(),
        }
    }

    fn alloc_track(&mut self) -> Option<Slot> {
        self.free_tracks.pop().or_else(|| {
            let slot = self.next_track;
            ((slot as usize) < MAX_TRACKS).then(|| {
                self.next_track += 1;
                slot
            })
        })
    }

    fn alloc_device(&mut self) -> Option<Slot> {
        self.free_devices.pop().or_else(|| {
            let slot = self.next_device;
            ((slot as usize) < MAX_DEVICES).then(|| {
                self.next_device += 1;
                slot
            })
        })
    }
}

/// Decoded audio files, loaded once and shared between clips.
#[derive(Default)]
pub struct AudioCache {
    files: HashMap<PathBuf, Option<Arc<AudioData>>>,
    summaries: HashMap<PathBuf, Arc<Summary>>,
    /// Recent answers to [`peaks`](Self::peaks), since views ask every frame.
    peaks: HashMap<PeaksKey, Arc<Vec<[f32; 3]>>>,
    /// Files at another rate than the engine's, converted, by file and rate.
    converted: HashMap<(PathBuf, u32), Arc<AudioData>>,
    /// Where waveform overviews are kept between runs (`peaks::Summary`),
    /// so that drawing a file need not decode it; nowhere when `None`.
    pub peak_dir: Option<PathBuf>,
    /// Where the decoded sound of long files is kept and played from,
    /// instead of memory; nowhere when `None`.
    pub store: Option<DiskStore>,
    /// Stretched and shifted versions of files, made apart: `stretched.rs`.
    pub renders: crate::stretched::Renders,
}

/// File, offset and length in seconds (as bits, to hash them), and points.
type PeaksKey = (PathBuf, u64, u64, usize);

impl AudioCache {
    /// A cache that keeps waveform overviews in `dir` between runs.
    pub fn with_peak_dir(dir: PathBuf) -> Self {
        Self {
            peak_dir: Some(dir),
            ..Self::default()
        }
    }

    /// Load a file, reporting why it could not be read.
    pub fn load(&mut self, path: &Path) -> anyhow::Result<Arc<AudioData>> {
        if let Some(Some(data)) = self.files.get(path) {
            return Ok(data.clone());
        }
        let loaded = AudioData::load_with(path, self.store.as_ref());
        self.files
            .insert(path.to_path_buf(), loaded.as_ref().ok().cloned());
        loaded
    }

    /// `n` (min, max) pairs covering `seconds` of a file from `offset`.
    pub fn peaks(
        &mut self,
        path: &Path,
        offset: f64,
        seconds: f64,
        n: usize,
    ) -> anyhow::Result<Arc<Vec<[f32; 3]>>> {
        let key = (path.to_path_buf(), offset.to_bits(), seconds.to_bits(), n);
        if let Some(peaks) = self.peaks.get(&key) {
            return Ok(peaks.clone());
        }
        let summary = self.summary(path)?;
        let rate = summary.sample_rate as f64;
        let from = offset * rate;
        let to = from + seconds * rate;
        let decoded = self.files.get(path).cloned().flatten();
        let peaks = match decoded {
            // Decoded already: exact to the sample.
            Some(data) => peaks::peaks(&data, &summary, from, to, n),
            None => match peaks::coarse(&summary, from, to, n) {
                // Zoomed out: the overview alone, without decoding the file.
                Some(peaks) => peaks,
                None => {
                    let data = self.load(path)?;
                    peaks::peaks(&data, &summary, from, to, n)
                }
            },
        };
        let peaks = Arc::new(peaks);
        // Zooming and editing leave old answers behind; a bound keeps them
        // from piling up without tracking which are still wanted.
        if self.peaks.len() >= 256 {
            self.peaks.clear();
        }
        self.peaks.insert(key, peaks.clone());
        Ok(peaks)
    }

    /// Forget every file but those in `keep`, and what was worked out from
    /// them (converted copies, overviews, peaks). Files a clip in the engine
    /// or a running render still plays stay in memory until they let go.
    pub fn retain(&mut self, keep: &std::collections::HashSet<PathBuf>) {
        self.files.retain(|path, _| keep.contains(path));
        self.summaries.retain(|path, _| keep.contains(path));
        self.peaks.retain(|key, _| keep.contains(&key.0));
        self.converted.retain(|key, _| keep.contains(&key.0));
        self.renders.retain(Some(keep));
    }

    /// What a stretched or shifted clip plays, if it has been made; if not,
    /// it is queued to be made (see `stretched.rs`).
    pub fn stretched(
        &mut self,
        key: &crate::stretched::Key,
        warnings: &mut Vec<String>,
    ) -> Option<Arc<AudioData>> {
        let store = self.store.clone();
        if self.renders.known(key) {
            return self.renders.get(key, store.as_ref(), || None);
        }
        let source = self.get(&key.file, key.rate, warnings);
        self.renders.get(key, store.as_ref(), || source)
    }

    /// What the engine plays of a file at `rate`, if it has been loaded:
    /// the file's own samples or their conversion.
    pub fn playing(&self, path: &Path, rate: u32) -> Option<&Arc<AudioData>> {
        let data = self.files.get(path)?.as_ref()?;
        if data.sample_rate == rate {
            return Some(data);
        }
        self.converted
            .get(&(path.to_path_buf(), rate))
            .or(Some(data))
    }

    /// Whether a file that has been loaded is played from the disk.
    pub fn on_disk(&self, path: &Path) -> Option<bool> {
        Some(self.files.get(path)?.as_ref()?.on_disk())
    }

    /// Forget the decoded files, so that each is loaded again when it is
    /// next asked for. Whatever plays one keeps what it has.
    pub fn forget_loaded(&mut self) {
        self.files.clear();
        self.converted.clear();
        self.renders.retain(None);
    }

    /// How many files are held, decoded or known to be unreadable.
    pub fn len(&self) -> usize {
        self.files.len()
    }

    pub fn is_empty(&self) -> bool {
        self.files.is_empty()
    }

    /// A file's waveform overview: kept in memory, read from the peak
    /// directory when it was made before for the file as it is now, or made
    /// from the samples and kept there.
    fn summary(&mut self, path: &Path) -> anyhow::Result<Arc<Summary>> {
        if let Some(summary) = self.summaries.get(path) {
            return Ok(summary.clone());
        }
        let stored = self
            .peak_dir
            .as_deref()
            .and_then(|dir| peaks::stored(dir, path));
        let summary = match stored
            .as_ref()
            .and_then(|(cached, _)| Summary::read(cached))
        {
            Some(summary) => summary,
            None => {
                let summary = Summary::new(&*self.load(path)?);
                if let Some((cached, _)) = &stored {
                    // A cache that cannot be written only costs time.
                    let _ = summary.write(cached);
                }
                summary
            }
        };
        let summary = Arc::new(summary);
        self.summaries.insert(path.to_path_buf(), summary.clone());
        Ok(summary)
    }

    /// A file for playing at `rate`: converted when it is at another.
    fn get(
        &mut self,
        path: &Path,
        rate: u32,
        warnings: &mut Vec<String>,
    ) -> Option<Arc<AudioData>> {
        let data = self.get_native(path, warnings)?;
        if data.sample_rate == rate {
            return Some(data);
        }
        let key = (path.to_path_buf(), rate);
        if let Some(converted) = self.converted.get(&key) {
            return Some(converted.clone());
        }
        // A long file converted is as long: it goes where the file went.
        let kept = self.store.as_ref().and_then(|store| {
            Some((store, daw_engine::store_name(path, &rate.to_string())?))
        });
        if let Some((store, name)) = &kept
            && let Some(converted) = store.open(name)
        {
            let converted = Arc::new(converted);
            self.converted.insert(key, converted.clone());
            return Some(converted);
        }
        match crate::resample::convert_into(&data, rate, daw_engine::Sink::new(kept)) {
            Ok(converted) => {
                let converted = Arc::new(converted);
                self.converted.insert(key, converted.clone());
                Some(converted)
            }
            Err(err) => {
                warnings.push(format!("{}: {err:#}", path.display()));
                Some(data)
            }
        }
    }

    fn get_native(&mut self, path: &Path, warnings: &mut Vec<String>) -> Option<Arc<AudioData>> {
        if let Some(known) = self.files.get(path) {
            return known.clone();
        }
        // A file that is not there is reported once, with the others
        // missing, when the project is opened (session/media.rs).
        let missing = !path.exists();
        self.load(path)
            .map_err(|err| {
                if !missing {
                    warnings.push(format!("{err:#}"))
                }
            })
            .ok()
    }
}

/// What is kept on the main thread for a device the engine is running.
pub struct LiveDevice {
    /// The parameters of this instance, in the order the device numbers them.
    pub params: Arc<Vec<ParamInfo>>,
    /// The main-thread side of the device, for hosted plugins.
    pub controller: Option<Box<dyn Controller>>,
    /// Frames by which the device's output is behind its input.
    pub latency: u32,
    /// Why the device has stopped working, once it has (see
    /// [`Controller::health`]).
    pub stopped: Option<String>,
}

pub type LiveDevices = HashMap<Id, LiveDevice>;

pub struct SyncCtx<'a> {
    pub registry: &'a Registry,
    pub audio: &'a mut AudioCache,
    pub live: &'a mut LiveDevices,
    pub sample_rate: f32,
    pub warnings: &'a mut Vec<String>,
    /// The engine being built renders to a file, not to be heard as it plays.
    pub offline: bool,
}

/// Bring the engine from `old` to `new`.
pub fn sync(
    old: &Project,
    new: &Project,
    map: &mut Mapper,
    ctx: &mut SyncCtx,
    send: &mut dyn FnMut(Msg),
    events: &mut Vec<ModelEvent>,
) {
    let before = events.len();
    let mut emit = |name: &str, payload: Value| events.push((name.to_string(), payload));

    // A project's map is shared by its copies, so an unchanged map is the
    // very same one. One out of step with its fields (set directly rather
    // than through `set_tempo_map`) is built again from them.
    let current = new.tempo_is_current();
    let retimed = !Arc::ptr_eq(old.tempo_map(), new.tempo_map()) || !current;
    if retimed {
        let map = if current {
            (**new.tempo_map()).clone()
        } else {
            daw_engine::TempoMap::new(&new.tempo_points(), &new.sig_points())
        };
        send(Msg::SetTempoMap(Box::new(map)));
    }
    if retimed || old.name != new.name || old.meta != new.meta {
        emit("project.changed", json!({}));
    }
    // The same tracks in another order: nothing the engine needs to hear of,
    // but whoever draws the track list does.
    if old.tracks.len() == new.tracks.len()
        && old
            .tracks
            .iter()
            .zip(&new.tracks)
            .any(|(a, b)| a.id != b.id)
    {
        let order: Vec<Id> = new.tracks.iter().map(|t| t.id).collect();
        emit("track.moved", json!({ "order": order }));
    }

    let old_tracks: HashMap<Id, &Arc<Track>> = old.all_tracks().map(|t| (t.id, t)).collect();
    let old_devices: HashMap<Id, &Arc<DeviceInst>> = old
        .all_tracks()
        .flat_map(|t| &t.devices)
        .map(|d| (d.id, d))
        .collect();
    let mut clips_changed = false;
    let mut lanes_changed = false;
    // The schedule lists slots, so a track that gets one needs a new schedule.
    let mut new_slots = false;
    // Side-chains name device slots, so a device that gets one does too.
    let mut device_slots = false;
    let mut removals = Vec::new();

    for track in new.all_tracks() {
        let prev = old_tracks.get(&track.id).copied();
        // A track the engine had no room for is built whole once there is room.
        let fresh = !map.tracks.contains_key(&track.id);
        // Notes an attribute map moves by seconds land by the tempo map.
        let retimed_notes = retimed && track.attr_map.as_ref().is_some_and(|m| m.has_delay());
        if !fresh && prev.is_some_and(|p| Arc::ptr_eq(p, track)) && !retimed_notes {
            continue;
        }
        if fresh {
            let Some(slot) = map.alloc_track() else {
                if prev.is_none() {
                    ctx.warnings
                        .push(format!("too many tracks: `{}` will be silent", track.name));
                }
                continue;
            };
            map.tracks.insert(track.id, slot);
            new_slots = true;
            send(Msg::InsertTrack {
                slot,
                track: TrackRt::new(),
            });
        }
        match prev {
            None => emit("track.added", json!({ "id": track.id })),
            Some(p) if !Arc::ptr_eq(p, track) => emit("track.changed", json!({ "id": track.id })),
            Some(_) => {}
        }
        // From here on, a track that has only now got a slot counts as new.
        let prev = prev.filter(|_| !fresh);
        let Some(&slot) = map.tracks.get(&track.id) else {
            continue;
        };

        // Devices set offline or back online since: gone from the engine,
        // or made, and the chain sent again.
        let mut toggled = false;
        for device in &track.devices {
            match old_devices.get(&device.id).filter(|_| prev.is_some()) {
                Some(before) if before.offline != device.offline => {
                    toggled = true;
                    device_slots = true;
                    map.keyed.remove(&device.id);
                    map.outs.remove(&device.id);
                    if device.offline {
                        ctx.live.remove(&device.id);
                        if let Some(slot) = map.devices.remove(&device.id) {
                            removals.push(Msg::RemoveDevice { slot });
                            map.free_devices.push(slot);
                        }
                    } else {
                        add_device(device, map, ctx, send);
                    }
                    emit(
                        "device.changed",
                        json!({ "id": device.id, "track": track.id }),
                    );
                }
                None => {
                    add_device(device, map, ctx, send);
                    device_slots = true;
                    if !old_devices.contains_key(&device.id) {
                        emit(
                            "device.added",
                            json!({ "id": device.id, "track": track.id }),
                        );
                    }
                }
                Some(before) if !Arc::ptr_eq(before, device) => {
                    update_device(before, device, map, ctx, send);
                    emit(
                        "device.changed",
                        json!({ "id": device.id, "track": track.id }),
                    );
                }
                Some(_) => {}
            }
        }
        let same_chain = !toggled
            && prev.is_some_and(|p| {
                p.devices
                    .iter()
                    .map(|d| d.id)
                    .eq(track.devices.iter().map(|d| d.id))
            });
        if !same_chain {
            let chain: Box<[Slot]> = track
                .devices
                .iter()
                .filter_map(|d| map.devices.get(&d.id).copied())
                .collect();
            send(Msg::SetChain { track: slot, chain });
        }

        let same_clips = !retimed_notes
            && prev.is_some_and(|p| {
            p.attr_map == track.attr_map
                && p.clips.len() == track.clips.len()
                && p.clips
                    .iter()
                    .zip(&track.clips)
                    .all(|(a, b)| Arc::ptr_eq(a, b))
        });
        if !same_clips {
            clips_changed = true;
            send(Msg::SetClips {
                track: slot,
                clips: Box::new(build_clips(track, new.tempo_map(), map, ctx)),
            });
        }

        let same_slots = !(retimed_notes && !track.slots.is_empty())
            && prev.map_or(track.slots.is_empty(), |p| {
            p.attr_map == track.attr_map
                && p.slots.len() == track.slots.len()
                && p.slots
                    .iter()
                    .zip(&track.slots)
                    .all(|(a, b)| a.row == b.row && Arc::ptr_eq(&a.clip, &b.clip))
        });
        if !same_slots {
            send(Msg::SetSlots {
                track: slot,
                slots: Box::new(build_slots(track, new.tempo_map(), ctx)),
            });
            emit("slot.changed", json!({ "track": track.id }));
        }

        let same_lanes = prev.map_or(track.lanes.is_empty(), |p| {
            p.lanes.len() == track.lanes.len()
                && p.lanes
                    .iter()
                    .zip(&track.lanes)
                    .all(|(a, b)| Arc::ptr_eq(a, b))
        });
        // A lane's compiled form names device slots, so a new chain needs it rebuilt.
        if !same_lanes || (!same_chain && !track.lanes.is_empty()) {
            lanes_changed |= !same_lanes;
            send(Msg::SetAutomation {
                track: slot,
                automation: Box::new(build_automation(track, new, map, ctx)),
            });
        }
        if let Some(prev) = prev.filter(|_| !same_lanes) {
            release_targets(prev, track, map, ctx, send);
        }
    }

    let new_devices: HashSet<Id> = new
        .all_tracks()
        .flat_map(|t| &t.devices)
        .map(|d| d.id)
        .collect();
    for id in old_devices.keys().filter(|id| !new_devices.contains(id)) {
        ctx.live.remove(id);
        map.host_latency.remove(id);
        map.keyed.remove(id);
        map.outs.remove(id);
        if let Some(slot) = map.devices.remove(id) {
            removals.push(Msg::RemoveDevice { slot });
            map.free_devices.push(slot);
        }
        emit("device.removed", json!({ "id": id }));
    }

    // Only tracks that are not the very same in both snapshots can have
    // gained, lost or changed a clip or a lane.
    let new_tracks: HashMap<Id, &Arc<Track>> = new.all_tracks().map(|t| (t.id, t)).collect();
    let touched = |id: Id| match (old_tracks.get(&id), new_tracks.get(&id)) {
        (Some(a), Some(b)) => !Arc::ptr_eq(a, b),
        _ => true,
    };
    if clips_changed {
        item_events(
            "clip",
            (&old_tracks, &new_tracks),
            &touched,
            |t| &t.clips,
            |c| c.id,
            &mut emit,
        );
    }
    if lanes_changed {
        item_events(
            "lane",
            (&old_tracks, &new_tracks),
            &touched,
            |t| &t.lanes,
            |l| l.id,
            &mut emit,
        );
    }

    // A track the VCAs it is in have changed the fader lane of is told so,
    // and takes its own fader value back when it no longer has one.
    for track in new.all_tracks() {
        let Some(&slot) = map.tracks.get(&track.id) else {
            continue;
        };
        let lane = vca_volume_lane(track, new);
        if lane.as_ref() != map.vca_lanes.get(&track.id) {
            match lane {
                Some(points) => map.vca_lanes.insert(track.id, points),
                None => map.vca_lanes.remove(&track.id),
            };
            map.mix.remove(&track.id);
            send(Msg::SetAutomation {
                track: slot,
                automation: Box::new(build_automation(track, new, map, ctx)),
            });
        }
    }

    let soloed = soloed_tracks(new);
    let sounding = if soloed.is_empty() {
        HashSet::new()
    } else {
        solo_paths(new, &soloed)
    };
    for track in new.all_tracks() {
        let Some(&slot) = map.tracks.get(&track.id) else {
            continue;
        };
        let silenced = !soloed.is_empty() && track.id != MASTER_ID && !sounding.contains(&track.id);
        let vcas = vcas_of(track, new);
        let mix = (
            db_to_gain(track.volume + vcas.iter().map(|v| v.volume).sum::<f64>()),
            track.pan as f32,
            track.mute || vcas.iter().any(|v| v.mute),
            silenced,
        );
        if map.mix.get(&track.id) != Some(&mix) {
            map.mix.insert(track.id, mix);
            send(Msg::SetMix {
                slot,
                gain: mix.0,
                pan: mix.1,
                mute: mix.2,
                quiet: mix.3,
            });
        }
    }

    for track in new.all_tracks() {
        let Some(&slot) = map.tracks.get(&track.id) else {
            continue;
        };
        let (first, channels) = track.input_channels().unwrap_or((0, 0));
        // An armed track is always heard, so that what is recorded is what
        // the player hears; the monitor switch is for hearing it otherwise.
        let input = (first, channels, track.armed || track.monitor, track.armed);
        if map.inputs.get(&track.id) != Some(&input) {
            map.inputs.insert(track.id, input);
            send(Msg::SetInput {
                track: slot,
                first,
                channels,
                monitor: input.2,
                armed: track.armed,
            });
        }
        let midi = track.midi_input.as_ref().map_or((0, 0), |m| {
            (
                m.port.as_deref().map_or(0, daw_engine::midi::port_key),
                m.channel.unwrap_or(0),
            )
        });
        if map.midi_inputs.get(&track.id).copied().unwrap_or((0, 0)) != midi {
            map.midi_inputs.insert(track.id, midi);
            send(Msg::SetMidiInput {
                track: slot,
                port: midi.0,
                channel: midi.1,
            });
        }
        let out = track.midi_output.as_ref().map_or((0, 0, Form::Auto), |m| {
            (
                daw_engine::midi::port_key(&m.port),
                m.channel.unwrap_or(0),
                m.engine_form(),
            )
        });
        if map.midi_outputs.get(&track.id).copied().unwrap_or((0, 0, Form::Auto)) != out {
            map.midi_outputs.insert(track.id, out);
            send(Msg::SetMidiOutput {
                track: slot,
                port: out.0,
                channel: out.1,
                form: out.2,
            });
        }
    }

    // A device whose latency changed: its dry signal is held back to match.
    for (id, live) in ctx.live.iter() {
        if let Some(&slot) = map.devices.get(id)
            && map.host_latency.get(id) != Some(&live.latency)
        {
            map.host_latency.insert(*id, live.latency);
            send(Msg::SetDeviceLatency {
                device: slot,
                frames: live.latency,
            });
        }
    }
    let routing = routing_of(new, ctx.live);
    // Devices that listen to a side-chain get a buffer for it, before the
    // schedule that fills it; those that no longer do give theirs back.
    let keyed: HashSet<Id> = routing
        .iter()
        .flat_map(|r| &r.keys)
        .map(|k| k.device)
        .filter(|id| map.devices.contains_key(id))
        .collect();
    for id in keyed.difference(&map.keyed) {
        send(Msg::SetKey {
            device: map.devices[id],
            key: Some(daw_engine::key_buf()),
        });
    }
    for id in map.keyed.difference(&keyed) {
        if let Some(&device) = map.devices.get(id) {
            send(Msg::SetKey { device, key: None });
        }
    }
    map.keyed = keyed;
    // Likewise buffers for as many further output pairs as are routed.
    let mut outs: HashMap<Id, Vec<usize>> = HashMap::new();
    for out in routing.iter().flat_map(|r| &r.outs) {
        if map.devices.contains_key(&out.device) {
            let pairs = outs.entry(out.device).or_default();
            if !pairs.contains(&out.pair) {
                pairs.push(out.pair);
                pairs.sort_unstable();
            }
        }
    }
    for (id, pairs) in &outs {
        if map.outs.get(id) != Some(pairs) {
            send(Msg::SetOutputs {
                device: map.devices[id],
                outs: Some(daw_engine::out_bufs(pairs)),
            });
        }
    }
    for id in map.outs.keys().filter(|id| !outs.contains_key(id)) {
        if let Some(&device) = map.devices.get(id) {
            send(Msg::SetOutputs { device, outs: None });
        }
    }
    map.outs = outs;
    let routes_moved = device_slots
        && routing
            .iter()
            .any(|r| !r.keys.is_empty() || !r.outs.is_empty());
    if routing != map.routing || new_slots || routes_moved {
        let schedule = build_schedule(&routing, map);
        map.latency = schedule.latency;
        send(Msg::SetSchedule(Box::new(schedule)));
        map.routing = routing;
    }

    for id in old_tracks.keys().filter(|id| new.track(**id).is_none()) {
        map.clip_events.remove(id);
        if let Some(slot) = map.tracks.remove(id) {
            // Notes it left sounding on its MIDI output port end there.
            if map.midi_outputs.get(id).is_some_and(|(port, ..)| *port != 0) {
                removals.push(Msg::SetMidiOutput {
                    track: slot,
                    port: 0,
                    channel: 0,
                    form: Form::Auto,
                });
            }
            removals.push(Msg::RemoveTrack { slot });
            map.free_tracks.push(slot);
        }
        map.mix.remove(id);
        map.inputs.remove(id);
        map.midi_inputs.remove(id);
        map.midi_outputs.remove(id);
        emit("track.removed", json!({ "id": id }));
    }
    // Removals go last, once nothing in the schedule or a chain refers to them.
    removals.into_iter().for_each(&mut *send);

    if events.len() > before {
        events.push(("changed".to_string(), json!({})));
    }
}

fn add_device(device: &DeviceInst, map: &mut Mapper, ctx: &mut SyncCtx, send: &mut dyn FnMut(Msg)) {
    // Set offline: not made, and passed over in the chain.
    if device.offline {
        return;
    }
    let Some(factory) = ctx.registry.get(&device.kind) else {
        ctx.warnings.push(format!(
            "`{}` is not installed: it is passed over, and kept with its saved state",
            device.name.as_deref().unwrap_or(&device.kind)
        ));
        return;
    };
    if map.defer && !ctx.offline && factory.starts_apart() {
        let Some(slot) = map.alloc_device() else {
            ctx.warnings.push(format!(
                "too many devices: `{}` will be skipped",
                device.kind
            ));
            return;
        };
        // Until it is made: an instrument is silent, an effect passes
        // the sound through.
        let instrument = factory.info().category == "instrument";
        map.devices.insert(device.id, slot);
        map.deferred.push(device.id);
        send(Msg::InsertDevice {
            slot,
            device: Box::new(Standin { instrument }),
        });
        return;
    }
    let instance = match factory.create(ctx.sample_rate, MAX_BLOCK) {
        Ok(instance) => instance,
        Err(err) => {
            ctx.warnings
                .push(format!("could not load `{}`: {err:#}", device.kind));
            return;
        }
    };
    let Some(slot) = map.alloc_device() else {
        ctx.warnings.push(format!(
            "too many devices: `{}` will be skipped",
            device.kind
        ));
        return;
    };
    let mut controller = instance.controller;
    if let (Some(controller), true) = (controller.as_mut(), ctx.offline) {
        controller.set_offline(true);
    }
    if let (Some(controller), Some(state)) = (controller.as_mut(), &device.state) {
        let loaded = BASE64
            .decode(state)
            .map_err(anyhow::Error::from)
            .and_then(|bytes| controller.load_state(&bytes));
        if let Err(err) = loaded {
            ctx.warnings.push(format!(
                "could not restore the state of `{}`: {err:#}",
                device.kind
            ));
        }
    }
    if let Some(controller) = controller.as_mut() {
        deliver_posts(&device.kind, controller.as_mut(), ctx);
    }
    let mut params = match &controller {
        Some(controller) => controller.params(),
        None => factory.info().params.clone(),
    };
    // The host's wet/dry mix and gain come after the device's own.
    let own = params.len();
    params.extend(daw_engine::host::params());
    let params = Arc::new(params);
    let latency = match &controller {
        Some(controller) => controller.latency(),
        None => factory.latency(ctx.sample_rate),
    };
    map.devices.insert(device.id, slot);
    send(Msg::InsertDevice {
        slot,
        device: instance.device,
    });
    send(Msg::SetHost {
        device: slot,
        path: Box::new(daw_engine::host::HostPath::new(
            own as u32, latency, MAX_BLOCK,
        )),
    });
    for (index, param) in params.iter().enumerate() {
        if let Some(&value) = device.params.get(&param.key) {
            let value = param_value(param, value);
            send(Msg::SetParam {
                device: slot,
                param: index as u32,
                value: value as f32,
            });
            if let Some(controller) = controller.as_mut().filter(|_| index < own) {
                controller.set_value(index, value);
            }
        }
    }
    if device.bypass {
        send(Msg::SetBypass {
            device: slot,
            bypass: true,
        });
    }
    // A parameter can change how late the device is (a look-ahead): ask
    // again now that they are set, and hold the dry signal back to match.
    let latency = match &controller {
        Some(controller) => controller.latency(),
        None => latency,
    };
    send(Msg::SetDeviceLatency {
        device: slot,
        frames: latency,
    });
    ctx.live.insert(
        device.id,
        LiveDevice {
            params,
            controller,
            latency,
            stopped: None,
        },
    );
}

/// Give a device that was just made what scripts posted to its kind
/// ([`Registry::post`](daw_engine::Registry::post)), before its first block.
fn deliver_posts(kind: &str, controller: &mut dyn daw_engine::Controller, ctx: &mut SyncCtx) {
    for (topic, data) in ctx.registry.posts(kind) {
        if let Err(err) = controller.call(topic, data) {
            ctx.warnings
                .push(format!("`{kind}` did not take `{topic}`: {err:#}"));
        }
    }
}

/// Whether a device's parameter is one of the host's (see `daw_engine::host`):
/// the last two, by those keys.
pub fn is_host(params: &[ParamInfo], index: usize) -> bool {
    index + 2 >= params.len()
        && params
            .get(index)
            .is_some_and(|p| p.key == daw_engine::host::WET || p.key == daw_engine::host::GAIN)
}

/// What stands in the engine for a device that is still being made.
struct Standin {
    instrument: bool,
}

impl daw_engine::Device for Standin {
    fn process(&mut self, _ctx: &daw_engine::ProcessCtx, io: &mut daw_engine::Io) {
        if self.instrument {
            io.left.fill(0.0);
            io.right.fill(0.0);
        }
    }

    fn set_param(&mut self, _index: u32, _value: f32) {}
}

/// Put a device that was made apart (see [`Mapper::defer`]) in place of its
/// stand-in, its state already loaded, with the project's parameters and
/// bypass applied.
pub fn install(
    device: &DeviceInst,
    instance: daw_engine::Instance,
    map: &Mapper,
    ctx: &mut SyncCtx,
    send: &mut dyn FnMut(Msg),
) {
    let Some(&slot) = map.devices.get(&device.id) else {
        return;
    };
    let mut controller = instance.controller;
    if let Some(controller) = controller.as_mut() {
        deliver_posts(&device.kind, controller.as_mut(), ctx);
    }
    let mut params = match &controller {
        Some(controller) => controller.params(),
        None => ctx
            .registry
            .get(&device.kind)
            .map(|f| f.info().params.clone())
            .unwrap_or_default(),
    };
    // The host's wet/dry mix and gain come after the device's own.
    let own = params.len();
    params.extend(daw_engine::host::params());
    let params = Arc::new(params);
    let latency = controller.as_ref().map_or(0, |c| c.latency());
    send(Msg::InsertDevice {
        slot,
        device: instance.device,
    });
    send(Msg::SetHost {
        device: slot,
        path: Box::new(daw_engine::host::HostPath::new(
            own as u32, latency, MAX_BLOCK,
        )),
    });
    for (index, param) in params.iter().enumerate() {
        if let Some(&value) = device.params.get(&param.key) {
            let value = param_value(param, value);
            send(Msg::SetParam {
                device: slot,
                param: index as u32,
                value: value as f32,
            });
            if let Some(controller) = controller.as_mut().filter(|_| index < own) {
                controller.set_value(index, value);
            }
        }
    }
    if device.bypass {
        send(Msg::SetBypass {
            device: slot,
            bypass: true,
        });
    }
    // A parameter can change how late the device is (a look-ahead): ask
    // again now that they are set, and hold the dry signal back to match.
    let latency = match &controller {
        Some(controller) => controller.latency(),
        None => latency,
    };
    send(Msg::SetDeviceLatency {
        device: slot,
        frames: latency,
    });
    ctx.live.insert(
        device.id,
        LiveDevice {
            params,
            controller,
            latency,
            stopped: None,
        },
    );
}

fn update_device(
    before: &DeviceInst,
    device: &DeviceInst,
    map: &Mapper,
    ctx: &mut SyncCtx,
    send: &mut dyn FnMut(Msg),
) {
    let (Some(&slot), Some(live)) = (map.devices.get(&device.id), ctx.live.get_mut(&device.id))
    else {
        return;
    };
    // A preset was loaded, or that was undone: the state goes in first, and
    // the preset's parameters on top of it. What the preset leaves out is
    // what the state says, not the default.
    let preset = device.loaded != before.loaded;
    let with_state = preset && device.state.is_some() && live.controller.is_some();
    if with_state && let Some(controller) = live.controller.as_mut() {
        let loaded = BASE64
            .decode(device.state.as_deref().unwrap_or(""))
            .map_err(anyhow::Error::from)
            .and_then(|bytes| controller.load_state(&bytes));
        if let Err(err) = loaded {
            ctx.warnings.push(format!(
                "could not load the preset into `{}`: {err:#}",
                device.kind
            ));
        }
    }
    for (index, param) in live.params.iter().enumerate() {
        let value = device.params.get(&param.key).copied();
        if with_state && value.is_none() {
            continue;
        }
        if value != before.params.get(&param.key).copied() || (with_state && value.is_some()) {
            let value = param_value(param, value.unwrap_or(param.default as f64));
            send(Msg::SetParam {
                device: slot,
                param: index as u32,
                value: value as f32,
            });
            if let Some(controller) = live
                .controller
                .as_mut()
                .filter(|_| !is_host(&live.params, index))
            {
                controller.set_value(index, value);
            }
        }
    }
    if device.state != before.state
        && !with_state
        && let Some(controller) = live.controller.as_mut().filter(|c| c.follows_state())
    {
        let loaded = BASE64
            .decode(device.state.as_deref().unwrap_or(""))
            .map_err(anyhow::Error::from)
            .and_then(|bytes| controller.load_state(&bytes));
        if let Err(err) = loaded {
            ctx.warnings.push(format!(
                "could not load the state of `{}`: {err:#}",
                device.kind
            ));
        }
    }
    if device.bypass != before.bypass {
        send(Msg::SetBypass {
            device: slot,
            bypass: device.bypass,
        });
    }
}

/// One MIDI clip's notes and controller moves as engine events, sorted. A
/// looped clip plays what lies in its repeated stretch over and over, each
/// note cut at the end of its repeat.
fn compile_clip(clip: &Clip, notes: &[Note], controls: &[Control]) -> Arc<[MidiEv]> {
    let mut set = ClipSet::default();
    let Some((from, beats)) = clip.repeat() else {
        for control in controls
            .iter()
            .filter(|c| c.start >= 0.0 && c.start < clip.length)
        {
            set.push_event(clip.start + control.start, control.event(0));
        }
        for note in notes
            .iter()
            .filter(|n| n.start >= 0.0 && n.start < clip.length)
        {
            let end = (note.start + note.length).min(clip.length);
            let vel = note.velocity.clamp(1, 127) as f32 / 127.0;
            let (start, end) = (clip.start + note.start, clip.start + end);
            set.push_note_attr(start, end, note.pitch, vel, attr_of(note));
        }
        set.finish();
        return set.midi.into();
    };
    let inside = |at: f64| at >= from && at < from + beats;
    for (base, end) in repeats(from, beats, clip.length) {
        let place = |at: f64| base + (at - from);
        for control in controls.iter().filter(|c| inside(c.start)) {
            let at = place(control.start);
            if at >= 0.0 && at < clip.length {
                set.push_event(clip.start + at, control.event(0));
            }
        }
        for note in notes.iter().filter(|n| inside(n.start)) {
            let at = place(note.start);
            if at >= 0.0 && at < clip.length {
                let stop = (at + note.length).min(end);
                let vel = note.velocity.clamp(1, 127) as f32 / 127.0;
                let (start, stop) = (clip.start + at, clip.start + stop);
                set.push_note_attr(start, stop, note.pitch, vel, attr_of(note));
            }
        }
    }
    set.finish();
    set.midi.into()
}

/// A note's attribute as the engine has it.
fn attr_of(note: &Note) -> daw_engine::Attr {
    note.attr.map_or(daw_engine::Attr::NONE, Into::into)
}

/// Where each repeat of a looped clip begins and ends, from the clip's
/// start, for a repeated stretch beginning at `from` and `period` long, in
/// a clip `length` long: the first begins at or before 0, the last ends
/// at `length` or later. In beats for MIDI, in seconds for sound.
pub fn repeats(from: f64, period: f64, length: f64) -> impl Iterator<Item = (f64, f64)> {
    // The repeat the clip's start falls in.
    let first = from - period * (from / period).ceil();
    let count = if period > 0.0 {
        ((length - first) / period).ceil().max(0.0) as usize
    } else {
        0
    };
    (0..count).map(move |k| {
        let a = first + k as f64 * period;
        (a, first + (k + 1) as f64 * period)
    })
}

/// Whether sound repeated from `from` for `seconds` runs on from its end
/// into its start without a jump: the frame after its end is about the
/// frame at its start, as near as one frame is to the next around there.
fn joins_itself(data: &AudioData, from: f64, seconds: f64) -> bool {
    let rate = data.sample_rate as f64;
    let (a, b) = (
        (from * rate).round() as i64,
        ((from + seconds) * rate).round() as i64,
    );
    let at = |c: &[f32], i: i64| {
        usize::try_from(i)
            .ok()
            .and_then(|i| c.get(i))
            .copied()
            .unwrap_or(0.0)
    };
    data.channels.iter().all(|c| {
        let jump = (at(c, b) - at(c, a)).abs();
        let step = [a, b]
            .iter()
            .flat_map(|&i| {
                [
                    (at(c, i) - at(c, i - 1)).abs(),
                    (at(c, i + 1) - at(c, i)).abs(),
                ]
            })
            .fold(0.0, f32::max);
        jump <= 2.0 * step + 1e-4
    })
}

/// The regions an audio clip plays: the part of `data` from `offset`
/// seconds, or, looped, its repeated stretch again and again. A fade in
/// belongs to the first repeat and a fade out to the last, each as long
/// as that repeat at most.
fn audio_regions(
    clip: &Clip,
    data: Arc<AudioData>,
    offset: f64,
    gain: f32,
    tempo: &daw_engine::TempoMap,
    out: &mut Vec<AudioRegion>,
) {
    let seconds = tempo.seconds_between(clip.start, clip.start + clip.length);
    let end = clip.start + clip.length;
    let Some((from, beats)) = clip.repeat() else {
        out.push(AudioRegion {
            start: clip.start,
            end,
            // An edge inside the recording is a cut.
            declick_in: offset > 1e-6,
            declick_out: offset + seconds < data.whole_seconds() - 1e-6,
            data,
            offset,
            gain,
            fade_in: clip.fade_in,
            fade_out: clip.fade_out,
            hold: Default::default(),
        });
        return;
    };
    // A repeat lasts as long in seconds as its beats do from the clip's start.
    let period = tempo.seconds_between(clip.start, clip.start + beats);
    if period <= 1e-9 {
        return;
    }
    let lead = from * period / beats;
    let begins = offset + lead;
    let joins = joins_itself(&data, begins, period);
    let t0 = tempo.seconds(clip.start);
    let first = out.len();
    for (a, b) in repeats(lead, period, seconds) {
        let (ra, rb) = (a.max(0.0), b.min(seconds));
        if rb - ra <= 1e-9 {
            continue;
        }
        let into = begins + (ra - a);
        let start = if ra <= 0.0 {
            clip.start
        } else {
            tempo.beat(t0 + ra)
        };
        let stop = if rb >= seconds {
            end
        } else {
            tempo.beat(t0 + rb)
        };
        out.push(AudioRegion {
            start,
            end: stop,
            declick_in: if ra <= 0.0 { into > 1e-6 } else { !joins },
            declick_out: if rb >= seconds {
                into + (rb - ra) < data.whole_seconds() - 1e-6
            } else {
                !joins
            },
            data: data.clone(),
            offset: into,
            gain,
            fade_in: 0.0,
            fade_out: 0.0,
            hold: Default::default(),
        });
    }
    if let Some(r) = out.get_mut(first) {
        r.fade_in = clip.fade_in.min(r.end - r.start);
    }
    if out.len() > first
        && let Some(r) = out.last_mut()
    {
        r.fade_out = clip.fade_out.min(r.end - r.start);
    }
}

/// Everything a track plays. A MIDI clip that is the very same as at the
/// last sync reuses its events; the track's events are those of its clips in
/// order, sorted again (stably, so the result is what sorting all the notes at
/// once gives, and nearly free when the clips follow each other in time).
fn build_clips(
    track: &Track,
    tempo: &daw_engine::TempoMap,
    map: &mut Mapper,
    ctx: &mut SyncCtx,
) -> ClipSet {
    let mut set = ClipSet::default();
    let cached = map.clip_events.remove(&track.id).unwrap_or_default();
    let mut by_ptr: Option<HashMap<*const Clip, &Arc<[MidiEv]>>> = None;
    let mut kept = Vec::new();
    for (i, clip) in track.clips.iter().enumerate().filter(|(_, c)| !c.muted) {
        match &clip.content {
            ClipContent::Midi { notes, controls } => {
                // Clips mostly stay where they were in the list; look there first.
                let reuse = match cached.get(i) {
                    Some((c, events)) if Arc::ptr_eq(c, clip) => Some(events.clone()),
                    _ => by_ptr
                        .get_or_insert_with(|| {
                            cached.iter().map(|(c, e)| (Arc::as_ptr(c), e)).collect()
                        })
                        .get(&Arc::as_ptr(clip))
                        .map(|e| (*e).clone()),
                };
                let events = reuse.unwrap_or_else(|| compile_clip(clip, notes, controls));
                set.midi.extend_from_slice(&events);
                kept.push((clip.clone(), events));
            }
            ClipContent::Audio { file, offset, gain } => {
                clip_audio(clip, (file, *offset, *gain), tempo, ctx, &mut set.audio)
            }
        }
    }
    set.finish();
    map.clip_events.insert(track.id, kept);
    downgrade(track, &mut set, tempo);
    set
}

/// What the track's attribute map sends, put among its events.
fn downgrade(track: &Track, set: &mut ClipSet, tempo: &daw_engine::TempoMap) {
    // A map is checked when it is set; one that no longer reads (from a
    // file edited by hand) plays as if there were none.
    if let Some(plan) = track.attr_map.as_ref().and_then(|m| m.plan().ok()) {
        crate::attr_map::downgrade(set, &plan, tempo);
    }
}

/// The regions an audio clip plays, once its sound is at hand.
fn clip_audio(
    clip: &Clip,
    (file, offset, gain): (&Path, f64, f64),
    tempo: &daw_engine::TempoMap,
    ctx: &mut SyncCtx,
    out: &mut Vec<AudioRegion>,
) {
    let rate = ctx.sample_rate as u32;
    // A stretched, warped or shifted clip plays a version made for it, in
    // which its file's moments are where its warp puts them (`warp.rs`); it
    // is silent until that is started, and then plays it as far as it is made.
    let warp = crate::warp::of(clip, tempo);
    let data = match crate::stretched::Key::of(clip, rate, tempo) {
        Some(key) => ctx.audio.stretched(&key, ctx.warnings),
        None => ctx.audio.get(file, rate, ctx.warnings),
    };
    if let Some(data) = data {
        let offset = warp.map_or(offset, |w| w.forward(offset));
        audio_regions(clip, data, offset, db_to_gain(gain), tempo, out);
    }
}

/// What a track's slots play, each clip laid out from its own start.
fn build_slots(track: &Track, tempo: &daw_engine::TempoMap, ctx: &mut SyncCtx) -> Slots {
    let mut rows: Vec<Option<SlotClip>> = Vec::new();
    for slot in track.slots.iter().filter(|s| !s.clip.muted) {
        let clip = &slot.clip;
        let mut clips = ClipSet::default();
        match &clip.content {
            ClipContent::Midi { notes, controls } => {
                clips.midi = compile_clip(clip, notes, controls).to_vec();
                downgrade(track, &mut clips, tempo);
            }
            ClipContent::Audio { file, offset, gain } => {
                clip_audio(clip, (file, *offset, *gain), tempo, ctx, &mut clips.audio)
            }
        }
        let row = slot.row as usize;
        if rows.len() <= row {
            rows.resize_with(row + 1, || None);
        }
        rows[row] = Some(SlotClip {
            clips,
            length: clip.length,
        });
    }
    Slots { rows }
}

/// A MIDI clip and its notes as engine events.
type CompiledClip = (Arc<Clip>, Arc<[MidiEv]>);

type TrackIndex<'a> = HashMap<Id, &'a Arc<Track>>;

/// Report the clips or lanes (`kind`) that the touched tracks gained, lost or
/// changed, as `<kind>.added`, `<kind>.removed` and `<kind>.changed`.
fn item_events<T>(
    kind: &str,
    (old, new): (&TrackIndex, &TrackIndex),
    touched: &dyn Fn(Id) -> bool,
    items: fn(&Track) -> &Vec<Arc<T>>,
    id_of: fn(&T) -> Id,
    emit: &mut dyn FnMut(&str, Value),
) {
    let changed: Vec<(&Arc<Track>, Option<&&Arc<Track>>)> = new
        .values()
        .filter(|t| touched(t.id))
        .map(|t| (*t, old.get(&t.id)))
        .collect();
    // The usual edit changes items in place: every touched track is still
    // there and holds the same ids in the same order. Then comparing pointers
    // pairwise is enough, with no index of every item.
    let in_place = old.keys().all(|id| new.contains_key(id))
        && changed.iter().all(|(t, was)| {
            was.is_some_and(|was| {
                items(was).len() == items(t).len()
                    && items(was)
                        .iter()
                        .zip(items(t))
                        .all(|(a, b)| id_of(a) == id_of(b))
            })
        });
    if in_place {
        for (t, was) in changed {
            let was = was.expect("checked above");
            for (a, b) in items(was).iter().zip(items(t)) {
                if !Arc::ptr_eq(a, b) {
                    emit(
                        &format!("{kind}.changed"),
                        json!({ "id": id_of(b), "track": t.id }),
                    );
                }
            }
        }
        return;
    }
    let index = |tracks: &TrackIndex| -> HashMap<Id, (Id, *const T)> {
        tracks
            .values()
            .filter(|t| touched(t.id))
            .flat_map(|t| {
                items(t)
                    .iter()
                    .map(move |c| (id_of(c), (t.id, Arc::as_ptr(c))))
            })
            .collect()
    };
    let (was, now) = (index(old), index(new));
    for (id, (track, ptr)) in &now {
        match was.get(id) {
            None => emit(
                &format!("{kind}.added"),
                json!({ "id": id, "track": track }),
            ),
            Some(prev) if prev != &(*track, *ptr) => emit(
                &format!("{kind}.changed"),
                json!({ "id": id, "track": track }),
            ),
            Some(_) => {}
        }
    }
    for (id, (track, _)) in was.iter().filter(|(id, _)| !now.contains_key(id)) {
        emit(
            &format!("{kind}.removed"),
            json!({ "id": id, "track": track }),
        );
    }
}

/// A parameter value as the device may be given it: within the parameter's
/// range, whatever a project file says. Devices are not asked to cope with
/// values they never declared (a gain of 1e300 dB is an infinite gain).
fn param_value(param: &ParamInfo, value: f64) -> f64 {
    let (min, max) = (param.min as f64, param.max as f64);
    if value.is_nan() {
        param.default as f64
    } else if min <= max {
        value.clamp(min, max)
    } else {
        value
    }
}

/// Whether a lane moves its target: it is on and has somewhere to take it.
pub fn is_active(lane: &Lane) -> bool {
    lane.enabled && !lane.points.is_empty()
}

fn build_automation(track: &Track, project: &Project, map: &Mapper, ctx: &SyncCtx) -> Automation {
    let mut set = Automation::default();
    // A track whose automation is off keeps its lanes and plays none.
    let on = track.automation != crate::model::AutoMode::Off;
    let vca = vca_volume_lane(track, project);
    if let Some(points) = &vca {
        set.lanes.push(AutoLane::new(AutoTarget::Volume, points.clone()));
    }
    for lane in track.lanes.iter().filter(|l| on && is_active(l)) {
        let mut range = None;
        let target = match &lane.target {
            // The fader's lane is already there when VCAs are involved.
            Target::Volume if vca.is_some() => continue,
            Target::Volume => AutoTarget::Volume,
            Target::Pan => AutoTarget::Pan,
            Target::Param { device, param } => {
                let (Some(&slot), Some(live)) = (map.devices.get(device), ctx.live.get(device))
                else {
                    continue;
                };
                let Some(index) = live.params.iter().position(|p| &p.key == param) else {
                    continue;
                };
                range = Some(&live.params[index]);
                AutoTarget::Param {
                    device: slot,
                    index: index as u32,
                }
            }
        };
        // Shaped stretches go to the engine as the straight pieces they are played as.
        let played = lane.played();
        let points: Vec<(f64, f64)> = match range {
            Some(param) => played
                .iter()
                .map(|&(beat, v)| (beat, param_value(param, v)))
                .collect(),
            None => played.into_owned(),
        };
        set.lanes.push(AutoLane::new(target, points));
    }
    set
}

/// Whether a track is a VCA: a fader, mute and solo that belong to other
/// tracks and carry no audio of their own. The runtime marks it in its meta.
fn is_vca(track: &Track) -> bool {
    track.meta.get("vca").and_then(|v| v.as_bool()) == Some(true)
}

/// The VCAs a track is assigned to (named in its meta) that exist.
fn vcas_of<'a>(track: &Track, project: &'a Project) -> Vec<&'a Track> {
    let Some(ids) = track.meta.get("vcas").and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    if is_vca(track) {
        return Vec::new();
    }
    project
        .tracks
        .iter()
        .filter(|t| is_vca(t) && ids.iter().any(|id| id.as_u64() == Some(t.id)))
        .map(|t| &**t)
        .collect()
}

/// A fader's lane on its own: its points in dB, or `None` where the fader
/// is still (or its automation is off).
fn fader_points(track: &Track) -> Option<&[(f64, f64)]> {
    if track.automation == crate::model::AutoMode::Off {
        return None;
    }
    track
        .lanes
        .iter()
        .find(|l| l.target == Target::Volume && is_active(l))
        .map(|l| l.points.as_slice())
}

/// The fader lane of a track that is in VCAs, when any lane is in play: the
/// sum in dB of its own fader and its VCAs' faders, each a lane or a fixed
/// value. Lanes are straight lines between points, so the sum is too, with
/// a point wherever one of them has one: the engine plays it as any lane,
/// sample by sample, and a render hears the same.
fn vca_volume_lane(track: &Track, project: &Project) -> Option<Vec<(f64, f64)>> {
    let vcas = vcas_of(track, project);
    if vcas.is_empty() {
        return None;
    }
    let all: Vec<&Track> = std::iter::once(track).chain(vcas).collect();
    let lanes: Vec<Option<&[(f64, f64)]>> = all.iter().map(|t| fader_points(t)).collect();
    if lanes.iter().all(|l| l.is_none()) {
        return None;
    }
    let mut beats: Vec<f64> = lanes
        .iter()
        .flatten()
        .flat_map(|l| l.iter().map(|p| p.0))
        .collect();
    beats.sort_by(f64::total_cmp);
    beats.dedup();
    let sum = |at: &dyn Fn(&[(f64, f64)]) -> f64| -> f64 {
        all.iter()
            .zip(&lanes)
            .map(|(t, l)| l.map_or(t.volume, at))
            .sum()
    };
    let mut out = Vec::new();
    for b in beats {
        // The value as a beat is reached, and as it is left (they differ at a jump).
        let before = sum(&|p| value_before(p, b));
        let after = sum(&|p| daw_engine::automation::value_at(p, b).unwrap_or(0.0));
        if before != after {
            out.push((b, before));
        }
        out.push((b, after));
    }
    Some(out)
}

/// A lane's value as `beat` is approached from before it.
fn value_before(points: &[(f64, f64)], beat: f64) -> f64 {
    let next = points.partition_point(|p| p.0 < beat);
    match (next.checked_sub(1).map(|i| points[i]), points.get(next)) {
        (None, Some(b)) => b.1,
        (Some(a), None) => a.1,
        (Some(a), Some(b)) => a.1 + (b.1 - a.1) * (beat - a.0) / (b.0 - a.0),
        (None, None) => 0.0,
    }
}

/// The tracks that count as soloed: those that are, and the members of a
/// soloed VCA.
fn soloed_tracks(project: &Project) -> HashSet<Id> {
    let mut out = HashSet::new();
    for t in project.all_tracks() {
        if (t.solo && !is_vca(t)) || vcas_of(t, project).iter().any(|v| v.solo) {
            out.insert(t.id);
        }
    }
    out
}

/// Put back the project's own value of anything a lane stopped automating,
/// since the engine otherwise keeps the last automated value.
fn release_targets(
    old: &Track,
    new: &Track,
    map: &mut Mapper,
    ctx: &mut SyncCtx,
    send: &mut dyn FnMut(Msg),
) {
    let active =
        |t: &Track, target: &Target| t.lanes.iter().any(|l| &l.target == target && is_active(l));
    for lane in old
        .lanes
        .iter()
        .filter(|l| is_active(l) && !active(new, &l.target))
    {
        match &lane.target {
            // Forget what the engine was last told, so that the mix is sent again.
            Target::Volume | Target::Pan => {
                map.mix.remove(&new.id);
            }
            Target::Param { device, param } => {
                let Some(inst) = new.devices.iter().find(|d| d.id == *device) else {
                    continue;
                };
                let (Some(&slot), Some(live)) = (map.devices.get(device), ctx.live.get_mut(device))
                else {
                    continue;
                };
                let Some(index) = live.params.iter().position(|p| &p.key == param) else {
                    continue;
                };
                let value = inst
                    .params
                    .get(param)
                    .copied()
                    .unwrap_or(live.params[index].default as f64);
                let value = param_value(&live.params[index], value);
                send(Msg::SetParam {
                    device: slot,
                    param: index as u32,
                    value: value as f32,
                });
                if let Some(controller) = live
                    .controller
                    .as_mut()
                    .filter(|_| !is_host(&live.params, index))
                {
                    controller.set_value(index, value);
                }
            }
        }
    }
}

/// With some track soloed, a track still sounds if it is soloed itself, feeds a
/// soloed track, or carries a soloed track's signal on to the master. The
/// tracks that still sound, found in one pass over the outputs.
fn solo_paths(project: &Project, soloed: &HashSet<Id>) -> HashSet<Id> {
    let by_id: HashMap<Id, &Track> = project.tracks.iter().map(|t| (t.id, &**t)).collect();
    let mut sounding = HashSet::new();
    // Soloed tracks, and every track their output passes through.
    for t in project.tracks.iter().filter(|t| soloed.contains(&t.id)) {
        sounding.insert(t.id);
        let mut at = t.output;
        let mut steps = 0;
        while let Some(next) = at.and_then(|id| by_id.get(&id)) {
            if steps > by_id.len() {
                break;
            }
            sounding.insert(next.id);
            steps += 1;
            at = next.output;
        }
    }
    // Tracks whose output reaches a soloed track. `feeds` remembers the
    // answer for every track walked through, so each is walked once.
    let mut feeds: HashMap<Id, bool> = HashMap::new();
    for t in &project.tracks {
        let mut path: Vec<&Track> = Vec::new();
        let mut beyond = false;
        let mut at = t.output;
        while let Some(&next) = at.and_then(|id| by_id.get(&id)) {
            if let Some(&known) = feeds.get(&next.id) {
                beyond = known || soloed.contains(&next.id);
                break;
            }
            if path.len() > by_id.len() {
                break;
            }
            path.push(next);
            at = next.output;
        }
        for n in path.iter().rev() {
            feeds.insert(n.id, beyond);
            beyond |= soloed.contains(&n.id);
        }
        feeds.insert(t.id, beyond);
        if beyond {
            sounding.insert(t.id);
        }
    }
    sounding
}

fn routing_of(project: &Project, live: &LiveDevices) -> Routing {
    let ids: HashSet<Id> = project.all_tracks().map(|t| t.id).collect();
    let exists = |id: Id| ids.contains(&id);
    // A device that is bypassed is not run, so it holds nothing back.
    let device_latency = |d: &DeviceInst| -> u32 {
        if d.bypass {
            return 0;
        }
        live.get(&d.id)
            .map_or(0, |l| l.latency.min(MAX_DELAY as u32))
    };
    let latency = |t: &Track| -> u32 { t.devices.iter().map(|d| device_latency(d)).sum() };
    // Side-chains, by the track they are taken from. The master feeds
    // nothing, so it keys nothing.
    let mut keys: HashMap<Id, Vec<Key>> = HashMap::new();
    for t in project.all_tracks() {
        let mut before = 0;
        for d in &t.devices {
            if let Some(source) = d
                .sidechain
                .filter(|s| exists(*s) && *s != t.id && *s != MASTER_ID)
            {
                keys.entry(source).or_default().push(Key {
                    track: t.id,
                    device: d.id,
                    pre: d.sidechain_pre,
                    before,
                });
            }
            before += device_latency(d);
        }
    }
    // Further output pairs, by the track whose devices they come from. The
    // master feeds nothing, so its devices' pairs go nowhere.
    let outs_of = |t: &Track| -> Vec<Out> {
        let mut late = 0;
        let mut outs = Vec::new();
        for d in &t.devices {
            late += device_latency(d);
            for (&pair, &target) in &d.outputs {
                if t.id != MASTER_ID && pair >= 2 && exists(target) && target != t.id {
                    outs.push(Out {
                        device: d.id,
                        pair: pair as usize - 2,
                        target,
                        late,
                    });
                }
            }
        }
        outs
    };
    project
        .all_tracks()
        .map(|t| Route {
            keys: keys.remove(&t.id).unwrap_or_default(),
            outs: outs_of(t),
            track: t.id,
            output: t
                .output
                .filter(|id| exists(*id) && *id != t.id)
                .unwrap_or(MASTER_ID),
            sends: t
                .sends
                .iter()
                .filter(|s| exists(s.target) && s.target != t.id)
                .map(|s| (s.target, db_to_gain(s.level), s.pre))
                .collect(),
            latency: latency(t),
        })
        .collect()
}

/// Order tracks so that each one runs after everything that feeds it, and
/// hold each connection back until the slowest signal reaching the same
/// place has arrived.
fn build_schedule(routing: &Routing, map: &Mapper) -> Schedule {
    // The master is in the routing for its latency, not as a source.
    let sources: Vec<&Route> = routing.iter().filter(|r| r.track != MASTER_ID).collect();
    // What feeds each track: the source, and how many frames earlier than
    // its output the place it arrives at is (a side-chain arrives at a
    // device, after the devices before it).
    let mut feeders: HashMap<Id, Vec<(usize, u32)>> = HashMap::new();
    for (index, route) in sources.iter().enumerate() {
        feeders.entry(route.output).or_default().push((index, 0));
        for (target, ..) in &route.sends {
            feeders.entry(*target).or_default().push((index, 0));
        }
        for key in &route.keys {
            feeders
                .entry(key.track)
                .or_default()
                .push((index, key.before));
        }
        for out in &route.outs {
            feeders
                .entry(out.target)
                .or_default()
                .push((index, route.latency.saturating_sub(out.late)));
        }
    }
    fn visit(
        index: usize,
        sources: &[&Route],
        feeders: &HashMap<Id, Vec<(usize, u32)>>,
        state: &mut [u8],
        order: &mut Vec<usize>,
    ) {
        if state[index] != 0 {
            return;
        }
        state[index] = 1;
        for &(feeder, _) in feeders
            .get(&sources[index].track)
            .map(Vec::as_slice)
            .unwrap_or(&[])
        {
            visit(feeder, sources, feeders, state, order);
        }
        order.push(index);
    }
    let mut state = vec![0u8; sources.len()];
    let mut order = Vec::with_capacity(sources.len());
    for index in 0..sources.len() {
        visit(index, &sources, &feeders, &mut state, &mut order);
    }

    // How late each track's output is, and how late the latest signal fed
    // into it is. Feeders come first in the order, so one pass does it. A
    // side-chain that would arrive late at its device holds back the
    // track the device is on instead.
    let mut arrives: HashMap<Id, u32> = HashMap::new();
    let mut leaves: HashMap<Id, u32> = HashMap::new();
    let latest = |id: Id, leaves: &HashMap<Id, u32>| -> u32 {
        feeders
            .get(&id)
            .into_iter()
            .flatten()
            .filter_map(|&(f, early)| {
                leaves
                    .get(&sources[f].track)
                    .map(|l| l.saturating_sub(early))
            })
            .max()
            .unwrap_or(0)
    };
    for &index in &order {
        let route = sources[index];
        let arrive = latest(route.track, &leaves);
        arrives.insert(route.track, arrive);
        leaves.insert(route.track, arrive + route.latency);
    }
    let master_arrive = latest(MASTER_ID, &leaves);
    arrives.insert(MASTER_ID, master_arrive);
    let master_latency = routing
        .iter()
        .find(|r| r.track == MASTER_ID)
        .map_or(0, |r| r.latency);

    let slot = |id: &Id| map.tracks.get(id).copied();
    // What a connection into `target` waits: until the latest one gets there.
    let wait_for = |from: Id, target: Id, early: u32| -> Delay {
        let frames = (arrives.get(&target).copied().unwrap_or(0) + early)
            .saturating_sub(leaves[&from]);
        match frames {
            0 => Delay::default(),
            frames => Delay::new(frames as usize),
        }
    };
    let wait = |from: Id, target: Id| wait_for(from, target, 0);
    let mut entries: Vec<SchedEntry> = order
        .into_iter()
        .filter_map(|index| {
            let route = sources[index];
            let output = if slot(&route.output).is_some() {
                route.output
            } else {
                MASTER_ID
            };
            Some(SchedEntry {
                slot: slot(&route.track)?,
                output: slot(&output).unwrap_or(MASTER),
                delay: wait(route.track, output),
                sends: route
                    .sends
                    .iter()
                    .filter_map(|(target, gain, pre)| {
                        Some(SendRt {
                            target: slot(target)?,
                            gain: *gain,
                            pre: *pre,
                            delay: wait(route.track, *target),
                        })
                    })
                    .collect(),
                keys: route
                    .keys
                    .iter()
                    .filter_map(|key| {
                        Some(KeyRt {
                            device: *map.devices.get(&key.device)?,
                            track: slot(&key.track)?,
                            pre: key.pre,
                            delay: wait_for(route.track, key.track, key.before),
                        })
                    })
                    .collect(),
                outs: route
                    .outs
                    .iter()
                    .filter_map(|out| {
                        Some(OutRt {
                            device: *map.devices.get(&out.device)?,
                            pair: out.pair,
                            target: slot(&out.target)?,
                            delay: wait_for(
                                route.track,
                                out.target,
                                route.latency.saturating_sub(out.late),
                            ),
                        })
                    })
                    .collect(),
            })
        })
        .collect();
    entries.push(SchedEntry::new(MASTER, NO_SLOT));
    Schedule::new(entries, master_arrive + master_latency)
}
