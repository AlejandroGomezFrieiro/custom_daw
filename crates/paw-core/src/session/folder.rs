//! A project as a folder of files.
//!
//! ```text
//! song/
//! ├── project.toml            the tempo, the meter, the order of the tracks
//! ├── meta.json               the project's `meta`, when it has some
//! ├── screen.json             the tabs and windows it opens with
//! ├── .gitattributes          `*.midi2 diff=paw-midi2`
//! ├── master/                 the master track, as a track folder
//! ├── tracks/<name>/
//! │   ├── track.json          the track and its clips, without their notes
//! │   ├── devices.json        the chain and its parameters
//! │   ├── <n>-<kind>.state    a plugin's state, as the plugin gives it
//! │   ├── automation/<target>.json
//! │   └── clips/<name>.midi2  a MIDI 2.0 clip file (crate::clipfile)
//! ├── media/                  sound files
//! └── unused/                 files the project does not use any more
//! ```
//!
//! [`layout`] turns a project into the bytes of each file, [`commit`]
//! writes the files that changed and moves those the project no longer
//! uses to `unused/` at the same path, and [`read`] puts the project
//! together again. The JSON files are written with their keys in order, so
//! the same project gives the same bytes.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result, bail};
use base64::Engine as _;
use serde_json::{Map, Value, json};

use super::BASE64;
use crate::clipfile;
use crate::model::{Clip, ClipContent, Notes, Project, Target, Track};

/// The file that makes a folder a project.
pub const PROJECT_FILE: &str = "project.toml";
/// The version of the folder's format.
const VERSION: u32 = 2;
/// The folders and the files at the top of a project that paw writes, and
/// so may move to `unused/` when the project does not need them.
const MANAGED_DIRS: [&str; 2] = ["tracks", "master"];
const MANAGED_FILES: [&str; 2] = ["meta.json", "screen.json"];
const GITATTRIBUTES: &str = "*.midi2 diff=paw-midi2\n";

/// Whether a path names a project kept as a folder: a folder, its
/// `project.toml`, or a name with no extension that is not a file yet.
/// Anything else is a project in one JSON file.
pub fn is_folder_path(path: &Path) -> bool {
    path.file_name().is_some_and(|n| n == PROJECT_FILE)
        || path.is_dir()
        || (!path.exists() && path.extension().is_none())
}

/// The `project.toml` of a project folder named by itself or by that file.
pub fn project_file(path: &Path) -> PathBuf {
    if path.file_name().is_some_and(|n| n == PROJECT_FILE) {
        path.to_path_buf()
    } else {
        path.join(PROJECT_FILE)
    }
}

/// A name made of letters, digits, `-`, `_` and `.`, for a file or a
/// folder, that does not start with a dot.
pub fn file_name(name: &str) -> String {
    let safe: String = name
        .trim()
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '-' || c == '_' || c == '.' {
                c
            } else {
                '-'
            }
        })
        .collect();
    let safe = safe.trim_start_matches('.').to_string();
    if safe.is_empty() {
        "unnamed".into()
    } else {
        safe
    }
}

/// A name from `stem` not in `taken` (`riff`, `riff-2`, ...), now taken.
fn unique(taken: &mut BTreeSet<String>, stem: &str, ext: &str) -> String {
    let mut name = format!("{stem}{ext}");
    let mut n = 2;
    while taken.contains(&name.to_lowercase()) {
        name = format!("{stem}-{n}{ext}");
        n += 1;
    }
    taken.insert(name.to_lowercase());
    name
}

/// The files of a project, by their path in its folder.
#[derive(Default)]
pub struct Layout {
    pub files: BTreeMap<PathBuf, Vec<u8>>,
    /// The file each clip's notes are in, by clip id: a path in the folder,
    /// or a file outside it the clip refers to.
    pub clip_files: HashMap<u64, PathBuf>,
    /// The folder of each track, by track id.
    pub track_folders: HashMap<u64, PathBuf>,
}

fn pretty(value: &Value) -> Vec<u8> {
    let mut text = serde_json::to_string_pretty(value).unwrap_or_default();
    text.push('\n');
    text.into_bytes()
}

/// `value` as TOML, without the nulls TOML has no word for.
fn to_toml(value: &Value) -> Option<toml::Value> {
    Some(match value {
        Value::Null => return None,
        Value::Bool(b) => toml::Value::Boolean(*b),
        Value::Number(n) => match n.as_i64() {
            Some(i) => toml::Value::Integer(i),
            None => toml::Value::Float(n.as_f64()?),
        },
        Value::String(s) => toml::Value::String(s.clone()),
        Value::Array(list) => toml::Value::Array(list.iter().filter_map(to_toml).collect()),
        Value::Object(map) => toml::Value::Table(
            map.iter()
                .filter_map(|(k, v)| Some((k.clone(), to_toml(v)?)))
                .collect(),
        ),
    })
}

fn from_toml(value: toml::Value) -> Value {
    match value {
        toml::Value::String(s) => Value::String(s),
        toml::Value::Integer(i) => json!(i),
        toml::Value::Float(f) => json!(f),
        toml::Value::Boolean(b) => Value::Bool(b),
        toml::Value::Datetime(d) => Value::String(d.to_string()),
        toml::Value::Array(list) => Value::Array(list.into_iter().map(from_toml).collect()),
        toml::Value::Table(map) => {
            Value::Object(map.into_iter().map(|(k, v)| (k, from_toml(v))).collect())
        }
    }
}

/// A lane's file name, from what it automates.
fn lane_stem(target: &Target, track: &Track) -> String {
    match target {
        Target::Volume => "volume".into(),
        Target::Pan => "pan".into(),
        Target::Param { device, param } => {
            let device = track
                .devices
                .iter()
                .position(|d| d.id == *device)
                .map(|i| {
                    let d = &track.devices[i];
                    format!("{}-{}", i + 1, d.name.as_deref().unwrap_or(&d.kind))
                })
                .unwrap_or_else(|| device.to_string());
            file_name(&format!("{device}-{param}"))
        }
    }
}

/// A clip as `track.json` holds it: everything but its notes, which are in
/// the file it names.
fn clip_entry(clip: &Clip, file: Option<&Path>) -> Result<Value> {
    let mut bare = clip.clone();
    if let ClipContent::Midi { notes, controls } = &mut bare.content {
        *notes = Notes::new();
        controls.clear();
    }
    // Where the notes are is the entry's `file`.
    bare.source = None;
    let mut value = serde_json::to_value(&bare)?;
    if let (Some(file), Some(content)) = (file, value.get_mut("content")) {
        *content = json!({ "kind": "midi", "file": file });
    }
    Ok(value)
}

struct Writer<'a> {
    layout: Layout,
    /// The file that holds each set of clip bytes already written: repeats
    /// of a part share one.
    written: HashMap<Vec<u8>, PathBuf>,
    dir: &'a Path,
}

impl Writer<'_> {
    fn track(&mut self, track: &Track, folder: &Path) -> Result<()> {
        self.layout
            .track_folders
            .insert(track.id, folder.to_path_buf());
        let mut taken = BTreeSet::new();
        let mut entry = track.clone();
        entry.devices = Vec::new();
        entry.clips = Vec::new();
        entry.lanes = Vec::new();
        entry.slots = Vec::new();
        let mut value = serde_json::to_value(&entry)?;
        let mut clips = Vec::new();
        for clip in &track.clips {
            clips.push(self.clip(clip, folder, &mut taken)?);
        }
        let mut slots = Vec::new();
        for slot in &track.slots {
            let mut s = serde_json::to_value(slot)?;
            s["clip"] = self.clip(&slot.clip, folder, &mut taken)?;
            slots.push(s);
        }
        let mut devices = Vec::new();
        let mut states = BTreeSet::new();
        for (i, device) in track.devices.iter().enumerate() {
            let mut d = serde_json::to_value(&**device)?;
            if let Some(state) = device.state.as_deref() {
                let bytes = BASE64
                    .decode(state)
                    .with_context(|| format!("the state of device {}", device.id))?;
                let name = unique(
                    &mut states,
                    &file_name(&format!("{}-{}", i + 1, device.kind)),
                    ".state",
                );
                let path = folder.join(&name);
                d.as_object_mut().map(|o| o.remove("state"));
                d["state_file"] = json!(name);
                self.layout.files.insert(path, bytes);
            }
            devices.push(d);
        }
        let mut lanes = Vec::new();
        let mut lane_names = BTreeSet::new();
        for lane in &track.lanes {
            let name = unique(&mut lane_names, &lane_stem(&lane.target, track), ".json");
            let rel = Path::new("automation").join(&name);
            self.layout
                .files
                .insert(folder.join(&rel), pretty(&serde_json::to_value(&**lane)?));
            lanes.push(json!(rel));
        }
        let map = value.as_object_mut().context("a track")?;
        for key in ["devices", "clips", "lanes", "slots"] {
            map.remove(key);
        }
        map.insert("clips".into(), Value::Array(clips));
        if !slots.is_empty() {
            map.insert("slots".into(), Value::Array(slots));
        }
        if !lanes.is_empty() {
            map.insert("lanes".into(), Value::Array(lanes));
        }
        self.layout
            .files
            .insert(folder.join("track.json"), pretty(&value));
        self.layout
            .files
            .insert(folder.join("devices.json"), pretty(&Value::Array(devices)));
        Ok(())
    }

    fn clip(&mut self, clip: &Clip, folder: &Path, taken: &mut BTreeSet<String>) -> Result<Value> {
        let ClipContent::Midi { notes, controls } = &clip.content else {
            return clip_entry(clip, None);
        };
        // A clip that refers to a file outside goes on referring to it.
        if let Some(source) = &clip.source {
            let file = outside_name(source, self.dir);
            self.layout.clip_files.insert(clip.id, source.clone());
            return clip_entry(clip, Some(&file));
        }
        let bytes = clipfile::encode(notes.iter(), controls, clip.length);
        let path = match self.written.get(&bytes) {
            Some(path) => path.clone(),
            None => {
                let stem = file_name(if clip.name.is_empty() {
                    "clip"
                } else {
                    &clip.name
                });
                let name = unique(taken, &stem, ".midi2");
                let path = folder.join("clips").join(name);
                self.written.insert(bytes.clone(), path.clone());
                self.layout.files.insert(path.clone(), bytes);
                path
            }
        };
        self.layout.clip_files.insert(clip.id, path.clone());
        clip_entry(clip, Some(&path))
    }
}

/// How a project names a file outside its folder: from the home folder as
/// `~/...` when it is there, else the absolute path.
fn outside_name(file: &Path, dir: &Path) -> PathBuf {
    if let Ok(rel) = file.strip_prefix(dir) {
        return rel.to_path_buf();
    }
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from)
        && let Ok(rel) = file.strip_prefix(&home)
    {
        return Path::new("~").join(rel);
    }
    file.to_path_buf()
}

/// A path as a project file gives it, made absolute: `~/` from the home
/// folder, a relative one from the project's folder.
pub fn resolve(file: &Path, dir: &Path) -> PathBuf {
    if let Ok(rel) = file.strip_prefix("~")
        && let Some(home) = std::env::var_os("HOME")
    {
        return PathBuf::from(home).join(rel);
    }
    if file.is_absolute() {
        file.to_path_buf()
    } else {
        tidy(&dir.join(file))
    }
}

fn tidy(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    out.push("..");
                }
            }
            other => out.push(other),
        }
    }
    out
}

/// The files of a project in the folder `dir`. Its media paths are already
/// as the folder names them (see `media::for_file`).
pub fn layout(
    project: &Project,
    transport: &Value,
    screen: Option<&Value>,
    dir: &Path,
) -> Result<Layout> {
    let mut w = Writer {
        layout: Layout::default(),
        written: HashMap::new(),
        dir,
    };
    let mut folders = BTreeSet::new();
    let mut order = Vec::new();
    for track in &project.tracks {
        let name = unique(&mut folders, &file_name(&track.name), "");
        w.track(track, &Path::new("tracks").join(&name))?;
        order.push(name);
    }
    w.track(&project.master, Path::new("master"))?;
    let mut bare = project.clone();
    bare.master = Arc::new(Track::new(0));
    bare.tracks = Vec::new();
    bare.meta = Map::new();
    let mut head = serde_json::to_value(&bare)?;
    let map = head.as_object_mut().context("a project")?;
    map.remove("master");
    map.remove("tracks");
    map.remove("meta");
    map.insert("version".into(), json!(VERSION));
    map.insert("tracks".into(), json!(order));
    map.insert("transport".into(), transport.clone());
    let head = to_toml(&head).context("a project")?;
    let mut text = toml::to_string_pretty(&head).context("writing project.toml")?;
    if !text.ends_with('\n') {
        text.push('\n');
    }
    w.layout
        .files
        .insert(PROJECT_FILE.into(), text.into_bytes());
    if !project.meta.is_empty() {
        w.layout.files.insert(
            "meta.json".into(),
            pretty(&Value::Object(project.meta.clone())),
        );
    }
    if let Some(screen) = screen {
        w.layout.files.insert("screen.json".into(), pretty(screen));
    }
    Ok(w.layout)
}

/// What a save did to the files.
#[derive(Debug, Default)]
pub struct Committed {
    /// Paths in the folder that were written, `project.toml` last.
    pub written: Vec<PathBuf>,
    /// Those that were the same already.
    pub unchanged: usize,
    /// Files moved in the folder, as a renamed track's are: (from, to).
    pub moved: Vec<(PathBuf, PathBuf)>,
    /// Files the project does not use any more, now in `unused/`.
    pub unused: Vec<PathBuf>,
}

/// Every file under the folders paw writes, by its path in the folder.
fn managed_files(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack: Vec<PathBuf> = MANAGED_DIRS.iter().map(PathBuf::from).collect();
    while let Some(rel) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(dir.join(&rel)) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = rel.join(entry.file_name());
            match entry.file_type() {
                Ok(t) if t.is_dir() => stack.push(path),
                Ok(_) => {
                    // A temporary file of a save cut short is not the user's.
                    if !path.to_string_lossy().ends_with(".paw-tmp") {
                        out.push(path);
                    }
                }
                Err(_) => {}
            }
        }
    }
    for name in MANAGED_FILES {
        if dir.join(name).is_file() {
            out.push(name.into());
        }
    }
    out.sort();
    out
}

fn tmp_of(path: &Path) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(".paw-tmp");
    PathBuf::from(name)
}

/// Run `f` on each item, on up to eight threads: flushes to the disk that
/// wait on each other less when they are asked for together.
fn in_parallel<T: Sync>(
    items: &[T],
    f: impl Fn(&T) -> std::io::Result<()> + Sync,
) -> std::io::Result<()> {
    let threads = std::thread::available_parallelism()
        .map_or(1, |n| n.get())
        .min(8);
    if items.len() < 8 || threads < 2 {
        return items.iter().try_for_each(&f);
    }
    let chunk = items.len().div_ceil(threads);
    std::thread::scope(|s| {
        let f = &f;
        let handles: Vec<_> = items
            .chunks(chunk)
            .map(|part| s.spawn(move || part.iter().try_for_each(f)))
            .collect();
        handles.into_iter().try_for_each(|h| {
            h.join()
                .unwrap_or_else(|_| Err(std::io::Error::other("a writer stopped")))
        })
    })
}

/// Flush directories' entries (the renames in them) to the disk.
fn sync_dirs(dirs: &BTreeSet<PathBuf>) {
    let list: Vec<&PathBuf> = dirs.iter().collect();
    let _ = in_parallel(&list, |d| {
        crate::safe::sync_dir(d);
        Ok(())
    });
}

/// A place in `unused/` for `rel` that nothing has yet.
fn unused_place(dir: &Path, rel: &Path) -> PathBuf {
    let base = Path::new("unused").join(rel);
    let mut place = base.clone();
    let mut n = 2;
    while dir.join(&place).exists() {
        let stem = base
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        let ext = base
            .extension()
            .map(|e| format!(".{}", e.to_string_lossy()))
            .unwrap_or_default();
        place = base.with_file_name(format!("{stem}-{n}{ext}"));
        n += 1;
    }
    place
}

/// Write the files of `layout` into `dir` that are not there already as
/// they are, the project file last, each written in full beside its place
/// and then renamed over it, so a crash leaves each file old or new. Files
/// paw wrote that the project does not use any more go to `unused/`, or are
/// moved to where a file of the same bytes is wanted (a renamed track).
pub fn commit(dir: &Path, layout: &Layout, only: Option<&BTreeSet<PathBuf>>) -> Result<Committed> {
    std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    let mut done = Committed::default();
    let before = managed_files(dir);
    let leaving: Vec<PathBuf> = if only.is_some() {
        Vec::new()
    } else {
        before
            .iter()
            .filter(|p| !layout.files.contains_key(*p))
            .cloned()
            .collect()
    };
    // Files that leave, by their bytes: one wanted elsewhere moves there.
    let mut by_bytes: HashMap<Vec<u8>, Vec<PathBuf>> = HashMap::new();
    for rel in &leaving {
        if let Ok(bytes) = std::fs::read(dir.join(rel)) {
            by_bytes.entry(bytes).or_default().push(rel.clone());
        }
    }
    let mut staged = Vec::new();
    let mut gone = BTreeSet::new();
    let wanted = |rel: &PathBuf| only.is_none_or(|o| o.contains(rel));
    for (rel, bytes) in layout.files.iter().filter(|(rel, _)| wanted(rel)) {
        let path = dir.join(rel);
        if std::fs::read(&path).is_ok_and(|old| &old == bytes) {
            done.unchanged += 1;
            continue;
        }
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating {}", parent.display()))?;
        }
        if !path.exists()
            && let Some(from) = by_bytes.get_mut(bytes).and_then(|list| list.pop())
        {
            std::fs::rename(dir.join(&from), &path)
                .with_context(|| format!("moving {} to {}", from.display(), rel.display()))?;
            gone.insert(from.clone());
            done.moved.push((from, rel.clone()));
            continue;
        }
        staged.push((rel.clone(), bytes));
    }
    // Each file in full on the disk beside its place before any is renamed.
    in_parallel(&staged, |(rel, bytes)| {
        use std::io::Write;
        let tmp = tmp_of(&dir.join(rel));
        let mut file = std::fs::File::create(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()
    })
    .context("writing the project's files")?;
    // The project file last, so that a project file is never newer than
    // what it names.
    let mut staged: Vec<PathBuf> = staged.into_iter().map(|(rel, _)| rel).collect();
    staged.sort_by_key(|rel| rel.as_os_str() == PROJECT_FILE);
    let mut touched_dirs = BTreeSet::new();
    for rel in &staged {
        let path = dir.join(rel);
        std::fs::rename(tmp_of(&path), &path)
            .with_context(|| format!("writing {}", path.display()))?;
        done.written.push(rel.clone());
        touched_dirs.extend(path.parent().map(Path::to_path_buf));
    }
    for (_, to) in &done.moved {
        touched_dirs.extend(dir.join(to).parent().map(Path::to_path_buf));
    }
    for rel in leaving.iter().filter(|r| !gone.contains(*r)) {
        let place = unused_place(dir, rel);
        if let Some(parent) = dir.join(&place).parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::rename(dir.join(rel), dir.join(&place))
            .with_context(|| format!("moving {} to {}", rel.display(), place.display()))?;
        done.unused.push(rel.clone());
        touched_dirs.extend(dir.join(&place).parent().map(Path::to_path_buf));
    }
    // Folders left empty by moves go; `rmdir` takes nothing that has a file.
    for rel in leaving.iter() {
        let mut parent = rel.parent();
        while let Some(p) = parent.filter(|p| !p.as_os_str().is_empty()) {
            if std::fs::remove_dir(dir.join(p)).is_err() {
                break;
            }
            parent = p.parent();
        }
    }
    if dir.join(".gitattributes").metadata().is_err() {
        std::fs::write(dir.join(".gitattributes"), GITATTRIBUTES)?;
        done.written.push(".gitattributes".into());
    }
    touched_dirs.insert(dir.to_path_buf());
    sync_dirs(&touched_dirs);
    Ok(done)
}

/// A project folder read back.
pub struct Read {
    pub project: Project,
    pub transport: Value,
    pub screen: Option<Value>,
    /// The file each MIDI clip's notes were read from, by clip id.
    pub clip_files: HashMap<u64, PathBuf>,
    /// What could not be read, said once each.
    pub problems: Vec<String>,
}

fn read_json(path: &Path) -> Result<Value> {
    let text = std::fs::read(path).with_context(|| format!("reading {}", path.display()))?;
    serde_json::from_slice(&text).with_context(|| format!("parsing {}", path.display()))
}

/// The JSON of a track from its folder, its clips' files still to read:
/// (track, the files its MIDI clips name by the clips' place).
fn read_track(dir: &Path, folder: &Path, problems: &mut Vec<String>) -> Result<Value> {
    let base = dir.join(folder);
    let mut track = read_json(&base.join("track.json"))?;
    let devices = match read_json(&base.join("devices.json")) {
        Ok(Value::Array(list)) => list,
        Ok(_) => bail!("{}: devices.json is not a list", folder.display()),
        Err(e) if !base.join("devices.json").exists() => {
            let _ = e;
            Vec::new()
        }
        Err(e) => return Err(e),
    };
    let mut chain = Vec::new();
    for mut d in devices {
        if let Some(name) = d
            .get("state_file")
            .and_then(Value::as_str)
            .map(str::to_string)
        {
            let path = resolve(Path::new(&name), &base);
            match std::fs::read(&path) {
                Ok(bytes) => d["state"] = json!(BASE64.encode(bytes)),
                Err(e) => problems.push(format!("{}: {e}", path.display())),
            }
            d.as_object_mut().map(|o| o.remove("state_file"));
        }
        chain.push(d);
    }
    let mut lanes = Vec::new();
    if let Some(Value::Array(list)) = track.get("lanes") {
        for name in list {
            let Some(name) = name.as_str() else { continue };
            lanes.push(read_json(&resolve(Path::new(name), &base))?);
        }
    }
    let map = track.as_object_mut().context("a track")?;
    map.insert("devices".into(), Value::Array(chain));
    map.insert("lanes".into(), Value::Array(lanes));
    Ok(track)
}

/// Take the file a clip's entry names out of it, leaving an empty note
/// list to fill.
fn take_clip_file(clip: &mut Value, files: &mut Vec<(u64, PathBuf)>, dir: &Path) {
    let id = clip.get("id").and_then(Value::as_u64).unwrap_or(0);
    let Some(content) = clip.get_mut("content") else {
        return;
    };
    if content.get("kind").and_then(Value::as_str) != Some("midi") {
        return;
    }
    if let Some(file) = content.get("file").and_then(Value::as_str) {
        files.push((id, resolve(Path::new(file), dir)));
    }
    *content = json!({ "kind": "midi", "notes": [] });
}

/// Read a project folder (`dir/project.toml`).
pub fn read(dir: &Path) -> Result<Read> {
    let head_path = dir.join(PROJECT_FILE);
    let text = std::fs::read_to_string(&head_path)
        .with_context(|| format!("reading {}", head_path.display()))?;
    let head: toml::Value =
        toml::from_str(&text).with_context(|| format!("parsing {}", head_path.display()))?;
    let mut head = from_toml(head);
    let map = head
        .as_object_mut()
        .context("project.toml is not a table")?;
    let version = map
        .remove("version")
        .and_then(|v| v.as_u64())
        .unwrap_or(VERSION as u64);
    if version > VERSION as u64 {
        bail!("{} was saved by a newer version", head_path.display());
    }
    let order: Vec<String> = match map.remove("tracks") {
        Some(v) => {
            serde_json::from_value(v).context("project.toml: tracks is a list of folder names")?
        }
        None => Vec::new(),
    };
    let transport = map.remove("transport").unwrap_or(Value::Null);
    let mut problems = Vec::new();
    let mut files = Vec::new();
    let mut tracks = Vec::new();
    let fix = |mut track: Value, files: &mut Vec<(u64, PathBuf)>| {
        if let Some(Value::Array(clips)) = track.get_mut("clips") {
            for clip in clips {
                take_clip_file(clip, files, dir);
            }
        }
        if let Some(Value::Array(slots)) = track.get_mut("slots") {
            for slot in slots {
                if let Some(clip) = slot.get_mut("clip") {
                    take_clip_file(clip, files, dir);
                }
            }
        }
        track
    };
    for name in &order {
        let folder = Path::new("tracks").join(name);
        let track = read_track(dir, &folder, &mut problems)
            .with_context(|| format!("reading the track {name}"))?;
        tracks.push(fix(track, &mut files));
    }
    let master = if dir.join("master/track.json").exists() {
        fix(
            read_track(dir, Path::new("master"), &mut problems)?,
            &mut files,
        )
    } else {
        serde_json::to_value(&*Project::default().master)?
    };
    map.insert("tracks".into(), Value::Array(tracks));
    map.insert("master".into(), master);
    let meta = match read_json(&dir.join("meta.json")) {
        Ok(v) => v,
        Err(_) if !dir.join("meta.json").exists() => json!({}),
        Err(e) => return Err(e),
    };
    map.insert("meta".into(), meta);
    let screen = read_json(&dir.join("screen.json")).ok();
    let mut project: Project =
        serde_json::from_value(head).with_context(|| format!("reading {}", dir.display()))?;
    // The clips' files, each once however many clips share it, on as many
    // threads as there are cores.
    let unique: Vec<PathBuf> = files
        .iter()
        .map(|(_, p)| p.clone())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let decoded = read_clips(&unique);
    let mut by_path: HashMap<&Path, &Result<clipfile::Clip>> = HashMap::new();
    for (path, clip) in unique.iter().zip(&decoded) {
        by_path.insert(path, clip);
    }
    let mut clip_files = HashMap::new();
    let mut contents: HashMap<u64, (Option<&clipfile::Clip>, PathBuf)> = HashMap::new();
    for (id, path) in &files {
        clip_files.insert(*id, path.clone());
        let read = match by_path.get(path.as_path()) {
            Some(Ok(clip)) => Some(clip),
            Some(Err(e)) => {
                problems.push(format!("{e:#}: the clip stays empty until it is there"));
                None
            }
            None => None,
        };
        contents.insert(*id, (read, path.clone()));
    }
    let tidy_dir = tidy(dir);
    let fill = |clip: &mut Arc<Clip>| {
        let Some((read, path)) = contents.get(&clip.id) else {
            return;
        };
        let clip = Arc::make_mut(clip);
        if let Some(read) = read
            && let ClipContent::Midi { notes, controls } = &mut clip.content
        {
            *notes = Notes::from(read.notes.clone());
            *controls = read.controls.clone();
        }
        // A file outside the folder, or one that is missing, stays where
        // the project said it is.
        if !path.starts_with(&tidy_dir) || read.is_none() {
            clip.source = Some(path.clone());
        }
    };
    for track in project
        .tracks
        .iter_mut()
        .chain(std::iter::once(&mut project.master))
    {
        let needs = track
            .clips
            .iter()
            .chain(track.slots.iter().map(|s| &s.clip))
            .any(|c| contents.contains_key(&c.id));
        if !needs {
            continue;
        }
        let track = Arc::make_mut(track);
        for clip in &mut track.clips {
            fill(clip);
        }
        for slot in &mut track.slots {
            fill(&mut slot.clip);
        }
    }
    Ok(Read {
        project,
        transport,
        screen,
        clip_files,
        problems,
    })
}

/// Read and decode clip files, in parallel.
fn read_clips(paths: &[PathBuf]) -> Vec<Result<clipfile::Clip>> {
    let one = |path: &PathBuf| -> Result<clipfile::Clip> {
        let bytes = std::fs::read(path).with_context(|| format!("reading {}", path.display()))?;
        clipfile::decode(&bytes)
    };
    let threads = std::thread::available_parallelism()
        .map_or(1, |n| n.get())
        .min(8);
    if paths.len() < 64 || threads < 2 {
        return paths.iter().map(one).collect();
    }
    let chunk = paths.len().div_ceil(threads);
    std::thread::scope(|s| {
        let handles: Vec<_> = paths
            .chunks(chunk)
            .map(|part| s.spawn(move || part.iter().map(one).collect::<Vec<_>>()))
            .collect();
        handles
            .into_iter()
            .flat_map(|h| h.join().unwrap_or_default())
            .collect()
    })
}

impl super::Session {
    /// The project's folder and its files as a save would write them now,
    /// or `None` for a project that is not kept in a folder.
    fn folder_layout(&mut self) -> Result<Option<(PathBuf, Layout)>> {
        let Some(file) = self.path.clone() else {
            return Ok(None);
        };
        if file.file_name().is_none_or(|n| n != PROJECT_FILE) {
            return Ok(None);
        }
        let dir = file.parent().map(Path::to_path_buf).unwrap_or_default();
        self.capture_states();
        let project = super::media::for_file(&self.project, &file);
        let transport = serde_json::to_value(&self.transport)?;
        let layout = layout(&project, &transport, self.screen.as_ref(), &dir)?;
        Ok(Some((dir, layout)))
    }

    /// The files of a project kept in a folder, each with what it holds and
    /// whether it differs from the file on the disk: `{ path, modified,
    /// what, track, clip }`. Empty for a project in one file or none.
    pub fn project_files(&mut self) -> Result<Value> {
        let Some((dir, layout)) = self.folder_layout()? else {
            return Ok(json!([]));
        };
        let mut owner: HashMap<&Path, (u64, Option<u64>)> = HashMap::new();
        for (track, folder) in &layout.track_folders {
            owner.insert(folder.as_path(), (*track, None));
        }
        let clip_of: HashMap<&Path, u64> = layout
            .clip_files
            .iter()
            .map(|(id, p)| (p.as_path(), *id))
            .collect();
        let mut out = Vec::new();
        for (rel, bytes) in &layout.files {
            let modified = std::fs::read(dir.join(rel)).map_or(true, |old| &old != bytes);
            let track = rel
                .ancestors()
                .find_map(|a| owner.get(a).map(|o| o.0));
            let what = match rel.extension().and_then(|e| e.to_str()) {
                Some("midi2") => "clip",
                Some("state") => "state",
                Some("toml") => "project",
                _ if rel.starts_with("tracks") || rel.starts_with("master") => {
                    match rel.file_name().and_then(|n| n.to_str()) {
                        Some("track.json") => "track",
                        Some("devices.json") => "devices",
                        _ => "automation",
                    }
                }
                _ => match rel.file_name().and_then(|n| n.to_str()) {
                    Some("screen.json") => "screen",
                    _ => "meta",
                },
            };
            out.push(json!({
                "path": rel,
                "modified": modified,
                "what": what,
                "track": track,
                "clip": clip_of.get(rel.as_path()),
            }));
        }
        Ok(Value::Array(out))
    }

    /// Save some of the files of a project kept in a folder, by their path
    /// in it. The project counts as saved when no file differs any more.
    /// Returns the paths written.
    pub fn project_save_files(&mut self, paths: &[PathBuf]) -> Result<Vec<PathBuf>> {
        let Some(file) = self.path.clone().filter(|f| f.file_name().is_some_and(|n| n == PROJECT_FILE)) else {
            bail!("the project is not kept in a folder: `:w` saves all of it");
        };
        let mut only: BTreeSet<PathBuf> = paths.iter().cloned().collect();
        // A file written names others: those not on the disk yet go too,
        // so that everything the written files name is there.
        if let Some((dir, layout)) = self.folder_layout()? {
            loop {
                let more: Vec<PathBuf> = layout
                    .files
                    .keys()
                    .filter(|rel| !only.contains(*rel) && !dir.join(rel).exists())
                    .filter(|rel| {
                        only.iter().any(|o| {
                            o.as_os_str() == PROJECT_FILE
                                || (o.file_name().is_some_and(|n| n == "track.json")
                                    && o.parent().is_some_and(|f| rel.starts_with(f)))
                        })
                    })
                    .cloned()
                    .collect();
                if more.is_empty() {
                    break;
                }
                only.extend(more);
            }
        }
        let (_, done) = self.project_save_folder(&file, Some(&only))?;
        if let Some((dir, layout)) = self.folder_layout()?
            && layout
                .files
                .iter()
                .all(|(rel, bytes)| std::fs::read(dir.join(rel)).is_ok_and(|old| &old == bytes))
        {
            self.history.mark_saved(false);
        }
        Ok(done.written)
    }

    /// Open the project kept in a folder: `song`, or `song/project.toml`.
    pub(super) fn project_load_folder(&mut self, path: &Path) -> Result<()> {
        let file = std::path::absolute(project_file(path))?;
        let dir = file.parent().map(Path::to_path_buf).unwrap_or_default();
        let read = read(&dir)?;
        let mut project = read.project;
        project
            .validate()
            .with_context(|| format!("{} cannot be loaded", dir.display()))?;
        let transport: super::Transport = if read.transport.is_null() {
            super::Transport::default()
        } else {
            serde_json::from_value(read.transport).context("project.toml: transport")?
        };
        let moved = self.find_media(&mut project, &file);
        self.replace_project(project, transport, Some(file));
        self.screen = read.screen;
        for problem in read.problems {
            self.warnings.push(problem);
        }
        self.touched |= moved;
        Ok(())
    }

    /// Save the project as a folder, at `path` (the folder or its
    /// `project.toml`). With `only`, only those of its files (by their path
    /// in the folder), and the project does not count as saved.
    pub fn project_save_folder(
        &mut self,
        path: &Path,
        only: Option<&BTreeSet<PathBuf>>,
    ) -> Result<(PathBuf, Committed)> {
        let file = std::path::absolute(project_file(path))?;
        let dir = file.parent().map(Path::to_path_buf).unwrap_or_default();
        if only.is_none() {
            self.adopt_recordings(&file)?;
        }
        self.capture_states();
        // What is saved is everything up to here and nothing after.
        self.checkpoint();
        // A project that was never named takes its folder's name.
        let named = (self.project.name == Project::default().name)
            .then(|| dir.file_name().map(|s| s.to_string_lossy().into_owned()))
            .flatten()
            .filter(|name| !name.is_empty());
        let mut project = super::media::for_file(&self.project, &file);
        if let Some(name) = &named {
            project.name = name.clone();
        }
        let transport = serde_json::to_value(&self.transport)?;
        let layout = layout(&project, &transport, self.screen.as_ref(), &dir)?;
        let done = commit(&dir, &layout, only)?;
        self.path = Some(file.clone());
        if let Some(name) = named {
            // Not an edit to undo: the saved state is the named one.
            self.project.name = name.clone();
            self.checkpoint.name = name;
            self.history.set_current_snapshot(self.checkpoint.clone());
            self.dirty = true;
        }
        if only.is_none() {
            self.history.mark_saved(false);
        }
        self.remember_for_panic();
        self.events.push((
            "project.saved".into(),
            json!({
                "path": file,
                "written": done.written,
                "unused": done.unused,
                "moved": done.moved,
            }),
        ));
        Ok((file, done))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Clip, ClipContent, Note, Project, Track};

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "paw-folder-{name}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    fn clip(id: u64, name: &str, start: f64, seed: u64) -> Arc<Clip> {
        let notes: Vec<Note> = (0..12)
            .map(|i| Note {
                start: i as f64 / 3.0,
                length: 0.25,
                pitch: 48 + ((i * 7 + seed) % 24) as u8,
                velocity: 64 + ((i * 13 + seed) % 63) as u8,
                meta: Map::new(),
                id: i + 1,
                attr: None,
            })
            .collect();
        let value = json!({
            "id": id, "name": name, "start": start, "length": 4.0, "muted": false,
            "content": { "kind": "midi", "notes": [] },
        });
        let mut clip: Clip = serde_json::from_value(value).unwrap();
        clip.content = ClipContent::Midi {
            notes: Notes::from(notes),
            controls: Vec::new(),
        };
        Arc::new(clip)
    }

    fn project(tracks: u64, clips: u64) -> Project {
        let mut p = Project::default();
        let mut id = 1;
        for t in 0..tracks {
            let mut track = Track::new(id);
            id += 1;
            track.name = format!("T{t}");
            for c in 0..clips {
                track
                    .clips
                    .push(clip(id, &format!("c{c}"), c as f64 * 4.0, t * 31 + c));
                id += 1;
            }
            p.tracks.push(Arc::new(track));
        }
        p
    }

    fn notes_of(p: &Project) -> Vec<Vec<Note>> {
        p.all_tracks()
            .flat_map(|t| &t.clips)
            .map(|c| match &c.content {
                ClipContent::Midi { notes, .. } => notes.to_vec(),
                _ => Vec::new(),
            })
            .collect()
    }

    #[test]
    fn a_project_comes_back_from_its_folder() {
        let dir = scratch("round");
        let p = project(3, 4);
        let layout = layout(&p, &json!({}), None, &dir).unwrap();
        commit(&dir, &layout, None).unwrap();
        let read = read(&dir).unwrap();
        assert_eq!(read.project.tracks.len(), 3);
        let mut named = read.project.clone();
        named.name_notes(&Project::default());
        assert!(notes_of(&named) == notes_of(&p), "the notes differ");
        // The same project, the same bytes, and nothing written again.
        let again = super::layout(&read.project, &json!({}), None, &dir).unwrap();
        assert_eq!(again.files, layout.files);
        let done = commit(&dir, &again, None).unwrap();
        assert!(done.written.is_empty(), "{:?}", done.written);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `cargo test --release -p paw-core folder::tests::timing -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn timing() {
        let dir = scratch("timing");
        let p = project(100, 8);
        let layout = layout(&p, &json!({}), None, &dir).unwrap();
        commit(&dir, &layout, None).unwrap();
        let text = serde_json::to_string_pretty(&p).unwrap();
        let mut folder = Vec::new();
        let mut one = Vec::new();
        for _ in 0..15 {
            let t = std::time::Instant::now();
            let r = read(&dir).unwrap();
            folder.push(t.elapsed().as_secs_f64() * 1000.0);
            assert_eq!(r.project.tracks.len(), 100);
            let t = std::time::Instant::now();
            let q: Project = serde_json::from_str(&text).unwrap();
            one.push(t.elapsed().as_secs_f64() * 1000.0);
            assert_eq!(q.tracks.len(), 100);
        }
        folder.sort_by(f64::total_cmp);
        one.sort_by(f64::total_cmp);
        println!(
            "folder read: median {:.2} ms (min {:.2}, max {:.2}); one JSON parse: median {:.2} ms (min {:.2}, max {:.2})",
            folder[7], folder[0], folder[14], one[7], one[0], one[14]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
