//! The device interface: anything that sits in a track's chain and makes or
//! changes sound. Built-in devices and hosted plugins both implement [`Device`].

use std::collections::BTreeMap;
use std::rc::Rc;
use std::sync::Arc;

use anyhow::Result;

use crate::event::EventBuf;

pub struct ProcessCtx {
    pub sample_rate: f32,
    pub tempo: f64,
    pub sig_num: u32,
    pub sig_den: u32,
    pub playing: bool,
    /// Project position, in beats, of the first frame of this block.
    pub position: f64,
    /// The same position in seconds from the start of the song.
    pub seconds: f64,
    /// The bar the block starts in, counting from 0, and where it starts
    /// in beats.
    pub bar: i64,
    pub bar_start: f64,
}

impl ProcessCtx {
    /// A context at the start of a song with one tempo and signature.
    pub fn at(sample_rate: f32, tempo: f64, sig_num: u32, sig_den: u32, playing: bool) -> Self {
        Self {
            sample_rate,
            tempo,
            sig_num,
            sig_den,
            playing,
            position: 0.0,
            seconds: 0.0,
            bar: 0,
            bar_start: 0.0,
        }
    }
}

/// What a device reads and writes for one block. Audio is processed in place.
pub struct Io<'a> {
    pub left: &'a mut [f32],
    pub right: &'a mut [f32],
    /// Events for this block, ordered by frame. A device may rewrite them for
    /// the devices after it.
    pub events: &'a mut EventBuf,
    /// The side-chain: another track's sound, as long as the block, for a
    /// device that listens to one ([`Ports::sidechain`]). None when nothing
    /// is connected; a compressor then listens to its own input.
    pub sidechain: Option<[&'a [f32]; 2]>,
    /// Where a device with more than one output pair puts the others: the
    /// second pair at index 0, up to the last that is routed somewhere
    /// (often none), and `None` for those that are not. Each channel holds
    /// at least a block; the device writes the first `left.len()` frames of
    /// the pairs it has, and leaves the rest silent. A device that can put
    /// a sound on its main pair or another (a drum kit) puts it on the other
    /// when that is routed.
    pub outputs: &'a mut [Option<[Vec<f32>; 2]>],
}

/// Most output pairs a device is heard on, its main one included.
pub const MAX_PAIRS: usize = 16;

/// The audio a device takes and gives besides its main stereo pair.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Ports {
    /// Whether it listens to a side-chain (see [`Io::sidechain`]).
    pub sidechain: bool,
    /// The names of its output pairs, the main one first, for a device
    /// with more than one (see [`Io::outputs`]); empty for one.
    pub outputs: Vec<String>,
}

/// Runs on the audio thread: implementations must not allocate, lock or block.
///
/// A device is created and dropped on the main thread, and only `process` and
/// `set_param` are called from the audio thread in between.
pub trait Device: Send {
    fn process(&mut self, ctx: &ProcessCtx, io: &mut Io);
    /// `index` is the position of the parameter in the device's parameter list.
    fn set_param(&mut self, index: u32, value: f32);
    /// Whether the device is at rest: given a block of silence (side-chain
    /// included) and no events, it would put out silence. The host may then
    /// leave it asleep, without calling `process`, until a block that is not
    /// silent or has events. Asked on the audio thread after each block and
    /// after parameter changes.
    ///
    /// A device that says so must also stay as it is through such a block
    /// when it is called (a built-in device returns at once), so that its
    /// sound is the very same whether the host calls it or not. A device
    /// that cannot tell (most plugins) says false, and is never put to sleep.
    fn resting(&self) -> bool {
        false
    }
}

/// Whether a buffer holds only silence (zeros, either sign).
#[inline]
pub fn silent(samples: &[f32]) -> bool {
    // Or-ing the bits without the sign, eight lanes at a time, vectorises;
    // an early exit would not.
    let mut acc = [0u32; 8];
    let mut chunks = samples.chunks_exact(8);
    for chunk in &mut chunks {
        for i in 0..8 {
            acc[i] |= chunk[i].to_bits() & 0x7fff_ffff;
        }
    }
    let mut any = acc.iter().fold(0, |a, b| a | b);
    for x in chunks.remainder() {
        any |= x.to_bits() & 0x7fff_ffff;
    }
    any == 0
}

/// Whether a block of a device's input is silence: both channels, the
/// side-chain if it has one, and no events.
pub fn quiet(io: &Io) -> bool {
    io.events.is_empty()
        && silent(io.left)
        && silent(io.right)
        && io.sidechain.is_none_or(|[l, r]| silent(l) && silent(r))
}

/// The main-thread side of a device that has one, such as a hosted plugin:
/// everything about it that is not processing audio.
pub trait Controller {
    /// This instance's parameters, for devices that only know them once
    /// they exist.
    fn params(&self) -> Vec<ParamInfo>;
    /// The current value of a parameter, by position in [`params`](Self::params).
    fn value(&self, index: usize) -> Option<f64>;
    /// Told whenever the host sets a parameter, alongside the change sent to
    /// the audio thread, for formats that keep a main-thread copy of the value.
    fn set_value(&mut self, _index: usize, _value: f64) {}
    /// Everything needed to bring a new instance back to this one's state.
    fn save_state(&mut self) -> Result<Option<Vec<u8>>>;
    fn load_state(&mut self, state: &[u8]) -> Result<()>;
    /// Whether the project says what the device's state is, as for a kit of
    /// samples set from a script: then a new state in the project (an edit,
    /// an undo) is loaded into the running device. A plugin's state is only
    /// read back from it, and is loaded only when the plugin is made.
    fn follows_state(&self) -> bool {
        false
    }
    /// Called regularly, for whatever the device needs done on the main thread.
    fn idle(&mut self) {}
    /// Parameters the device changed by itself since the last call, as
    /// (position in [`params`](Self::params), new value): what a user did in
    /// the device's own editor, or a preset it loaded.
    fn take_changes(&mut self) -> Vec<(usize, f64)> {
        Vec::new()
    }
    /// Whether the device has a window of its own to show.
    fn has_editor(&self) -> bool {
        false
    }
    fn editor_open(&self) -> bool {
        false
    }
    /// Show the device's own window, titled `title`.
    fn open_editor(&mut self, _title: &str) -> Result<()> {
        anyhow::bail!("this device has no editor")
    }
    fn close_editor(&mut self) {}
    /// Frames by which the device's output is behind its input, for devices
    /// that look ahead. The host holds everything else back to match. Asked
    /// again whenever the device is idled, since a setting can change it.
    fn latency(&self) -> u32 {
        0
    }
    /// Say that the device is about to render faster than real time, into
    /// a file: called once, on the main thread, before its first block. A
    /// plugin told this can do at once what it would otherwise leave to a
    /// background thread, and take its time over quality.
    fn set_offline(&mut self, _offline: bool) {}
    /// Why the device has stopped working, if it has: a plugin running in
    /// a process of its own that crashed, hung or was ended. Asked
    /// regularly; a device that is well says nothing.
    fn health(&mut self) -> Option<String> {
        None
    }
    /// Blocks the device did not deliver in time (a plugin in a helper
    /// process that was late), since it was made.
    fn late_blocks(&self) -> u64 {
        0
    }
    /// A request from a script, for devices that are fed from outside the
    /// timeline: `method` names it, `data` is whatever bytes it takes, and the
    /// answer is bytes too, so it can cross `paw.api` as plain strings.
    fn call(&mut self, method: &str, _data: &[u8]) -> Result<Vec<u8>> {
        anyhow::bail!("this device has no method `{method}`")
    }
    /// What it takes and gives besides its main stereo pair, as this
    /// instance has it.
    fn ports(&self) -> Ports {
        Ports::default()
    }
}

/// A new device, with its controller if it has one.
pub struct Instance {
    pub device: Box<dyn Device>,
    pub controller: Option<Box<dyn Controller>>,
}

impl Instance {
    pub fn simple(device: impl Device + 'static) -> Self {
        Self {
            device: Box::new(device),
            controller: None,
        }
    }
}

#[derive(Clone, Debug)]
pub struct ParamInfo {
    /// The identifier used in projects and scripts. Unique within a device.
    pub key: String,
    /// The name to show.
    pub name: String,
    pub min: f32,
    pub max: f32,
    pub default: f32,
    pub unit: String,
    /// Names for integer steps, for parameters that choose between options.
    pub choices: Vec<String>,
}

impl ParamInfo {
    pub fn new(name: &str, min: f32, max: f32, default: f32, unit: &str) -> Self {
        Self {
            key: name.into(),
            name: name.into(),
            min,
            max,
            default,
            unit: unit.into(),
            choices: Vec::new(),
        }
    }

    pub fn choice(name: &str, choices: &[&str], default: usize) -> Self {
        Self {
            max: (choices.len() - 1) as f32,
            choices: choices.iter().map(|s| s.to_string()).collect(),
            ..Self::new(name, 0.0, 0.0, default as f32, "")
        }
    }
}

/// Turn display names into keys: lower case, words joined by `_`, and a
/// number appended where two names would otherwise collide.
pub fn assign_keys(params: &mut [ParamInfo]) {
    let mut seen: BTreeMap<String, u32> = BTreeMap::new();
    for param in params {
        let mut key = String::new();
        for ch in param.name.chars() {
            if ch.is_alphanumeric() {
                key.extend(ch.to_lowercase());
            } else if !key.ends_with('_') && !key.is_empty() {
                key.push('_');
            }
        }
        let key = key.trim_end_matches('_').to_string();
        let key = if key.is_empty() {
            "param".to_string()
        } else {
            key
        };
        let count = seen.entry(key.clone()).or_insert(0);
        *count += 1;
        param.key = if *count == 1 {
            key
        } else {
            format!("{key}_{count}")
        };
    }
}

#[derive(Clone, Debug, Default)]
pub struct DeviceInfo {
    /// The identifier used in projects and scripts, such as `synth` or
    /// `clap:org.surge-synth-team.surge-xt`.
    pub kind: String,
    pub name: String,
    /// `instrument` or `effect`.
    pub category: String,
    /// `builtin`, `clap`, `lv2` or `vst3`.
    pub format: String,
    pub vendor: String,
    /// Empty for devices whose parameters are only known per instance.
    pub params: Vec<ParamInfo>,
}

/// Creates device instances. Lives on the main thread.
pub trait DeviceFactory {
    fn info(&self) -> &DeviceInfo;
    /// The new device starts with every parameter at its default.
    fn create(&self, sample_rate: f32, max_block: usize) -> Result<Instance>;
    /// Frames of latency of a device that has no [`Controller`] to ask.
    fn latency(&self, _sample_rate: f32) -> u32 {
        0
    }
    /// The ports of a device that has no [`Controller`] to ask.
    fn ports(&self) -> Ports {
        Ports::default()
    }
    /// Whether [`start`](Self::start) makes this device without the main
    /// thread waiting for it: a plugin in a process of its own, which may
    /// take long or hang while it is made.
    fn starts_apart(&self) -> bool {
        false
    }
    /// Begin making a device, with `state` (as its controller saved it)
    /// loaded into it, and return at once; [`Starting::poll`] gives the
    /// result. None for factories that only make devices in [`create`].
    ///
    /// [`create`]: Self::create
    fn start(
        &self,
        _sample_rate: f32,
        _max_block: usize,
        _state: Option<Vec<u8>>,
    ) -> Option<Box<dyn Starting>> {
        None
    }
}

/// A device that is being made apart from the main thread (see
/// [`DeviceFactory::start`]). Dropping it gives up on the device.
pub trait Starting {
    /// The device once it is made, with its state loaded; why it could not
    /// be made; or None while that is not known yet. Asked on the main
    /// thread, and never blocks.
    fn poll(&mut self) -> Option<Result<Instance>>;
}

/// A [`DeviceFactory`] made from a descriptor and a constructor function.
pub struct FnFactory {
    pub info: DeviceInfo,
    pub make: fn(f32) -> Box<dyn Device>,
    /// Seconds by which the device's output is behind its input.
    pub latency: f32,
    /// The names of its output pairs, for a device with more than one.
    pub outputs: &'static [&'static str],
}

impl DeviceFactory for FnFactory {
    fn info(&self) -> &DeviceInfo {
        &self.info
    }

    fn create(&self, sample_rate: f32, _max_block: usize) -> Result<Instance> {
        Ok(Instance {
            device: (self.make)(sample_rate),
            controller: None,
        })
    }

    fn latency(&self, sample_rate: f32) -> u32 {
        (self.latency * sample_rate).round() as u32
    }

    fn ports(&self) -> Ports {
        Ports {
            outputs: self.outputs.iter().map(|s| s.to_string()).collect(),
            ..Ports::default()
        }
    }
}

/// Every device kind the session can instantiate, by kind name. It stays on
/// the main thread, like the factories in it.
/// Looks for plugins again and registers what it finds: see [`Registry::rescan`].
pub type Rescan = Rc<dyn Fn(&mut Registry, Option<&str>) -> Vec<String>>;

/// Looks for plugins in one more directory and registers what it finds
/// there: see [`Registry::add_dir`].
pub type AddDir = Rc<dyn Fn(&mut Registry, &std::path::Path) -> (Vec<String>, Vec<String>)>;

/// Stops looking for plugins in a directory added before: see
/// [`Registry::remove_dir`].
pub type RemoveDir = Rc<dyn Fn(&std::path::Path)>;

#[derive(Default, Clone)]
pub struct Registry {
    factories: BTreeMap<String, Rc<dyn DeviceFactory>>,
    rescan: Option<Rescan>,
    add_dir: Option<AddDir>,
    remove_dir: Option<RemoveDir>,
    /// What scripts posted to every device of a kind: by kind, each topic
    /// with its latest data, in the order the topics were first posted.
    posts: BTreeMap<String, Vec<(String, Arc<[u8]>)>>,
    /// Kinds that were renamed, and what they are called now.
    aliases: BTreeMap<String, String>,
}

impl Registry {
    pub fn with_builtins() -> Self {
        let mut registry = Self::default();
        crate::devices::register(&mut registry);
        registry
    }

    pub fn register(&mut self, factory: Rc<dyn DeviceFactory>) {
        self.factories.insert(factory.info().kind.clone(), factory);
    }

    /// Make no more devices of `kind` (an extension that brought it was
    /// taken away); devices already made go on. Returns whether it was there.
    pub fn unregister(&mut self, kind: &str) -> bool {
        self.factories.remove(kind).is_some()
    }

    /// Say how to stop looking in a directory added with [`Registry::add_dir`].
    pub fn set_remove_dir(&mut self, remove_dir: RemoveDir) {
        self.remove_dir = Some(remove_dir);
    }

    /// Look in `dir` no more (later rescans leave it out), and make no more
    /// devices of `kinds`, those found there.
    pub fn remove_dir(&mut self, dir: &std::path::Path, kinds: &[String]) {
        if let Some(remove_dir) = self.remove_dir.clone() {
            remove_dir(dir);
        }
        for kind in kinds {
            self.unregister(kind);
        }
    }

    /// Say how to look for plugins again (the program that found them knows).
    pub fn set_rescan(&mut self, rescan: Rescan) {
        self.rescan = Some(rescan);
    }

    /// Say how to look for plugins in a directory of one's choosing.
    pub fn set_add_dir(&mut self, add_dir: AddDir) {
        self.add_dir = Some(add_dir);
    }

    /// Look for plugins in `dir` too from now on, and register those in it:
    /// the device kinds found there, and notes on what could not be used.
    /// `None` when there is nothing to do it with.
    pub fn add_dir(&mut self, dir: &std::path::Path) -> Option<(Vec<String>, Vec<String>)> {
        let add_dir = self.add_dir.clone()?;
        Some(add_dir(self, dir))
    }

    /// Look into plugin files again: all of them, or those `name` matches.
    /// `None` when there is nothing to do it with. The answer is notes on
    /// what could not be used.
    pub fn rescan(&mut self, name: Option<&str>) -> Option<Vec<String>> {
        let rescan = self.rescan.clone()?;
        Some(rescan(self, name))
    }

    pub fn get(&self, kind: &str) -> Option<&Rc<dyn DeviceFactory>> {
        self.factories.get(kind).or_else(|| {
            self.aliases
                .get(kind)
                .and_then(|now| self.factories.get(now))
        })
    }

    /// Make devices of `old`, a kind that was renamed, as `new`: projects
    /// saved before the rename keep working.
    pub fn alias(&mut self, old: &str, new: &str) {
        self.aliases.insert(old.to_string(), new.to_string());
    }

    /// What a kind is called now: itself, unless it was renamed.
    pub fn resolve<'a>(&'a self, kind: &'a str) -> &'a str {
        match self.aliases.get(kind) {
            Some(now) if !self.factories.contains_key(kind) => now,
            _ => kind,
        }
    }

    pub fn iter(&self) -> impl Iterator<Item = &Rc<dyn DeviceFactory>> {
        self.factories.values()
    }

    /// Keep `data` as the latest under `topic` for devices of `kind`, to be
    /// given to every one made from now on (a render's included) through
    /// [`Controller::call`] before its first block; `None` forgets the topic.
    pub fn post(&mut self, kind: &str, topic: &str, data: Option<Arc<[u8]>>) {
        let posts = self.posts.entry(kind.to_string()).or_default();
        match (posts.iter().position(|(t, _)| t == topic), data) {
            (Some(at), Some(data)) => posts[at].1 = data,
            (None, Some(data)) => posts.push((topic.to_string(), data)),
            (Some(at), None) => {
                posts.remove(at);
            }
            (None, None) => {}
        }
    }

    /// What is posted to devices of `kind`: each topic and its latest data.
    pub fn posts(&self, kind: &str) -> &[(String, Arc<[u8]>)] {
        self.posts
            .get(self.resolve(kind))
            .map_or(&[], Vec::as_slice)
    }
}
