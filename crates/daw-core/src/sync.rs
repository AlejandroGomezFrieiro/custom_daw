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
use base64::engine::general_purpose::STANDARD as BASE64;
use daw_engine::{
    AudioData, AudioRegion, AutoLane, AutoTarget, Automation, ClipSet, Controller, Delay,
    DiskStore, MASTER,
    MAX_BLOCK, MAX_DELAY, MAX_DEVICES, MAX_TRACKS, MidiEv, Msg, NO_SLOT, ParamInfo, Registry,
    SchedEntry, Schedule, SendRt, Slot, TrackRt, db_to_gain,
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
    /// Frames of latency of the track's own devices.
    latency: u32,
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
    mix: HashMap<Id, (f32, f32, bool)>,
    /// First input channel, channel count, monitoring and armed, as last sent.
    inputs: HashMap<Id, (usize, usize, bool, bool)>,
    /// The MIDI port's key and channel each track takes, as last sent.
    midi_inputs: HashMap<Id, (u32, u8)>,
    routing: Routing,
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
            inputs: HashMap::new(),
            midi_inputs: HashMap::new(),
            routing: Vec::new(),
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
    let mut removals = Vec::new();

    for track in new.all_tracks() {
        let prev = old_tracks.get(&track.id).copied();
        // A track the engine had no room for is built whole once there is room.
        let fresh = !map.tracks.contains_key(&track.id);
        if !fresh && prev.is_some_and(|p| Arc::ptr_eq(p, track)) {
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

        let same_clips = prev.is_some_and(|p| {
            p.clips.len() == track.clips.len()
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
                automation: Box::new(build_automation(track, map, ctx)),
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

    let any_solo = new.tracks.iter().any(|t| t.solo);
    let sounding = if any_solo {
        solo_paths(new)
    } else {
        HashSet::new()
    };
    for track in new.all_tracks() {
        let Some(&slot) = map.tracks.get(&track.id) else {
            continue;
        };
        let silenced = any_solo && track.id != MASTER_ID && !sounding.contains(&track.id);
        let mix = (
            db_to_gain(track.volume),
            track.pan as f32,
            track.mute || silenced,
        );
        if map.mix.get(&track.id) != Some(&mix) {
            map.mix.insert(track.id, mix);
            send(Msg::SetMix {
                slot,
                gain: mix.0,
                pan: mix.1,
                mute: mix.2,
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
    if routing != map.routing || new_slots {
        let schedule = build_schedule(&routing, map);
        map.latency = schedule.latency;
        send(Msg::SetSchedule(Box::new(schedule)));
        map.routing = routing;
    }

    for id in old_tracks.keys().filter(|id| new.track(**id).is_none()) {
        map.clip_events.remove(id);
        if let Some(slot) = map.tracks.remove(id) {
            removals.push(Msg::RemoveTrack { slot });
            map.free_tracks.push(slot);
        }
        map.mix.remove(id);
        map.inputs.remove(id);
        map.midi_inputs.remove(id);
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

/// One MIDI clip's notes and controller moves as engine events, sorted.
fn compile_clip(clip: &Clip, notes: &[Note], controls: &[Control]) -> Arc<[MidiEv]> {
    let mut set = ClipSet::default();
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
        set.push_note(clip.start + note.start, clip.start + end, note.pitch, vel);
    }
    set.finish();
    set.midi.into()
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
                if let Some(data) = ctx.audio.get(file, ctx.sample_rate as u32, ctx.warnings) {
                    let seconds = tempo.seconds_between(clip.start, clip.start + clip.length);
                    set.audio.push(AudioRegion {
                        start: clip.start,
                        end: clip.start + clip.length,
                        // An edge inside the recording is a cut.
                        declick_in: *offset > 1e-6,
                        declick_out: offset + seconds < data.seconds() - 1e-6,
                        data,
                        offset: *offset,
                        gain: db_to_gain(*gain),
                        fade_in: clip.fade_in,
                        fade_out: clip.fade_out,
                    });
                }
            }
        }
    }
    set.finish();
    map.clip_events.insert(track.id, kept);
    set
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

fn build_automation(track: &Track, map: &Mapper, ctx: &SyncCtx) -> Automation {
    let mut set = Automation::default();
    // A track whose automation is off keeps its lanes and plays none.
    let on = track.automation != crate::model::AutoMode::Off;
    for lane in track.lanes.iter().filter(|l| on && is_active(l)) {
        let mut range = None;
        let target = match &lane.target {
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
        let points: Vec<(f64, f64)> = match range {
            Some(param) => lane
                .points
                .iter()
                .map(|&(beat, v)| (beat, param_value(param, v)))
                .collect(),
            None => lane.points.clone(),
        };
        set.lanes.push(AutoLane::new(target, points));
    }
    set
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
fn solo_paths(project: &Project) -> HashSet<Id> {
    let by_id: HashMap<Id, &Track> = project.tracks.iter().map(|t| (t.id, &**t)).collect();
    let mut sounding = HashSet::new();
    // Soloed tracks, and every track their output passes through.
    for t in project.tracks.iter().filter(|t| t.solo) {
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
                beyond = known || next.solo;
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
            beyond |= n.solo;
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
    let latency = |t: &Track| -> u32 {
        t.devices
            .iter()
            .filter(|d| !d.bypass)
            .filter_map(|d| live.get(&d.id))
            .map(|l| l.latency.min(MAX_DELAY as u32))
            .sum()
    };
    project
        .all_tracks()
        .map(|t| Route {
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
    let mut feeders: HashMap<Id, Vec<usize>> = HashMap::new();
    for (index, route) in sources.iter().enumerate() {
        feeders.entry(route.output).or_default().push(index);
        for (target, ..) in &route.sends {
            feeders.entry(*target).or_default().push(index);
        }
    }
    fn visit(
        index: usize,
        sources: &[&Route],
        feeders: &HashMap<Id, Vec<usize>>,
        state: &mut [u8],
        order: &mut Vec<usize>,
    ) {
        if state[index] != 0 {
            return;
        }
        state[index] = 1;
        for &feeder in feeders
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
    // into it is. Feeders come first in the order, so one pass does it.
    let mut arrives: HashMap<Id, u32> = HashMap::new();
    let mut leaves: HashMap<Id, u32> = HashMap::new();
    let latest = |id: Id, leaves: &HashMap<Id, u32>| -> u32 {
        feeders
            .get(&id)
            .into_iter()
            .flatten()
            .filter_map(|&f| leaves.get(&sources[f].track))
            .copied()
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
    let wait = |from: Id, target: Id| -> Delay {
        let frames = arrives
            .get(&target)
            .copied()
            .unwrap_or(0)
            .saturating_sub(leaves[&from]);
        match frames {
            0 => Delay::default(),
            frames => Delay::new(frames as usize),
        }
    };
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
            })
        })
        .collect();
    entries.push(SchedEntry::new(MASTER, NO_SLOT));
    Schedule::new(entries, master_arrive + master_latency)
}
