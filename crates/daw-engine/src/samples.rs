//! Where decoded sound is held: in memory, or in files that are read from
//! the disk as they are played.
//!
//! A long file decoded whole into memory costs 23 MB a minute. Past a size
//! (a [`DiskStore`]'s `limit`) the decoded samples are written to files in
//! the cache directory instead, one per channel, and mapped into memory: the
//! engine reads them as it reads any slice, and the system brings the pages
//! in from the disk and lets go of them again when memory is short. Whoever
//! drives the engine asks for the pages ahead of the playhead
//! ([`Samples::advise`]) so that the audio thread does not wait for the
//! disk. The files are kept between runs under the identity of the file
//! they were decoded from, so a long file is decoded once.

use std::fs::File;
use std::io::{BufWriter, Write};
use std::ops::{Deref, DerefMut};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};

use crate::clip::AudioData;

/// A file of samples mapped into memory, read-only.
struct Map {
    ptr: *mut libc::c_void,
    bytes: usize,
}

// Read-only memory that lives until the last reference goes.
unsafe impl Send for Map {}
unsafe impl Sync for Map {}

impl Map {
    fn open(path: &Path, frames: usize) -> std::io::Result<Arc<Self>> {
        let file = File::open(path)?;
        let bytes = frames * 4;
        if (file.metadata()?.len() as usize) < bytes || bytes == 0 {
            return Err(std::io::ErrorKind::UnexpectedEof.into());
        }
        // SAFETY: a private read-only mapping of a file this program wrote
        // and never changes afterwards; it is removed, not truncated, when
        // the cache is tidied, which leaves mappings of it whole.
        let ptr = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                bytes,
                libc::PROT_READ,
                libc::MAP_PRIVATE,
                file.as_raw_fd(),
                0,
            )
        };
        if ptr == libc::MAP_FAILED {
            return Err(std::io::Error::last_os_error());
        }
        Ok(Arc::new(Self { ptr, bytes }))
    }
}

impl Drop for Map {
    fn drop(&mut self) {
        // SAFETY: the mapping made in `open`, unmapped once.
        unsafe { libc::munmap(self.ptr, self.bytes) };
    }
}

/// One channel's samples.
#[derive(Clone)]
pub struct Samples(Kind);

#[derive(Clone)]
enum Kind {
    Memory(Vec<f32>),
    Disk(Arc<Map>),
}

impl Samples {
    /// Whether the samples are read from the disk as they are used.
    pub fn on_disk(&self) -> bool {
        matches!(self.0, Kind::Disk(_))
    }

    /// Ask for the samples `from..to` to be brought in from the disk now,
    /// ahead of their being read. Nothing for samples in memory.
    pub fn advise(&self, from: usize, to: usize) {
        let Kind::Disk(map) = &self.0 else {
            return;
        };
        const PAGE: usize = 4096;
        let start = (from * 4).min(map.bytes) / PAGE * PAGE;
        let end = (to * 4).min(map.bytes);
        if end > start {
            // SAFETY: a range inside the mapping, starting on a page.
            unsafe {
                libc::madvise(
                    map.ptr.cast::<u8>().add(start).cast(),
                    end - start,
                    libc::MADV_WILLNEED,
                )
            };
        }
    }
}

impl Deref for Samples {
    type Target = [f32];

    fn deref(&self) -> &[f32] {
        match &self.0 {
            Kind::Memory(samples) => samples,
            // SAFETY: the mapping is `bytes` long, page aligned, and holds
            // nothing but f32s written by `Sink`.
            Kind::Disk(map) => unsafe {
                std::slice::from_raw_parts(map.ptr.cast::<f32>(), map.bytes / 4)
            },
        }
    }
}

impl DerefMut for Samples {
    /// Samples on the disk are copied into memory to be changed.
    fn deref_mut(&mut self) -> &mut [f32] {
        if let Kind::Disk(_) = &self.0 {
            self.0 = Kind::Memory(self.to_vec());
        }
        match &mut self.0 {
            Kind::Memory(samples) => samples,
            Kind::Disk(_) => unreachable!(),
        }
    }
}

impl From<Vec<f32>> for Samples {
    fn from(samples: Vec<f32>) -> Self {
        Self(Kind::Memory(samples))
    }
}

impl<'a> IntoIterator for &'a Samples {
    type Item = &'a f32;
    type IntoIter = std::slice::Iter<'a, f32>;

    fn into_iter(self) -> Self::IntoIter {
        self.iter()
    }
}

/// Where decoded sound that is too large for memory is kept.
#[derive(Clone, Debug)]
pub struct DiskStore {
    pub dir: PathBuf,
    /// Decoded sound of more than this many bytes goes to the disk.
    pub limit: u64,
}

/// What a kept file is known by: the identity of the file it was decoded
/// from (path, size, time of last change) and what was made of it.
pub fn store_name(file: &Path, what: &str) -> Option<String> {
    use std::os::unix::ffi::OsStrExt;
    let file = std::path::absolute(file).unwrap_or_else(|_| file.to_path_buf());
    let meta = std::fs::metadata(&file).ok().filter(|m| m.is_file())?;
    let modified = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_nanos());
    // FNV-1a over the identity: the same file as it was gives the same name.
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    let mut eat = |bytes: &[u8]| {
        for b in bytes {
            hash = (hash ^ *b as u64).wrapping_mul(0x100_0000_01b3);
        }
    };
    eat(file.as_os_str().as_bytes());
    eat(&meta.len().to_le_bytes());
    eat(&modified.to_le_bytes());
    Some(format!("{hash:016x}-{what}"))
}

impl DiskStore {
    fn path(&self, name: &str, part: &str) -> PathBuf {
        self.dir.join(format!("{name}.{part}"))
    }

    /// Sound kept under `name` by an earlier [`Sink`], if it is all there.
    pub fn open(&self, name: &str) -> Option<AudioData> {
        let meta_path = self.path(name, "meta");
        let meta = std::fs::read_to_string(&meta_path).ok()?;
        let mut fields = meta.split_whitespace().map(|f| f.parse::<u64>().ok());
        let (rate, frames, channels) = (fields.next()??, fields.next()??, fields.next()??);
        let left = Map::open(&self.path(name, "0"), frames as usize).ok()?;
        let right = match channels {
            1 => left.clone(),
            _ => Map::open(&self.path(name, "1"), frames as usize).ok()?,
        };
        // Used now: the last to be tidied away.
        if let Ok(file) = File::options().append(true).open(&meta_path) {
            let _ = file.set_modified(std::time::SystemTime::now());
        }
        Some(AudioData {
            sample_rate: rate as u32,
            channels: [Samples(Kind::Disk(left)), Samples(Kind::Disk(right))],
        })
    }

    /// Remove the sound used longest ago until what is kept is within
    /// `keep` bytes. Files in use stay readable by whoever has them open.
    pub fn tidy(&self, keep: u64) {
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            return;
        };
        // By name: the time it was last used, and its files with their sizes.
        let mut kept: std::collections::HashMap<String, (std::time::SystemTime, Vec<PathBuf>, u64)> =
            Default::default();
        for entry in entries.flatten() {
            let path = entry.path();
            let (Some(stem), Some(ext), Ok(meta)) = (
                path.file_stem().and_then(|s| s.to_str()),
                path.extension().and_then(|s| s.to_str()),
                entry.metadata(),
            ) else {
                continue;
            };
            // A writer's unfinished file, left by a run that ended badly.
            if ext.starts_with("tmp") {
                let old = meta
                    .modified()
                    .ok()
                    .and_then(|t| t.elapsed().ok())
                    .is_some_and(|age| age.as_secs() > 3600);
                if old {
                    let _ = std::fs::remove_file(&path);
                }
                continue;
            }
            let item = kept
                .entry(stem.to_string())
                .or_insert((std::time::UNIX_EPOCH, Vec::new(), 0));
            if ext == "meta" {
                item.0 = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
            }
            item.1.push(path);
            item.2 += meta.len();
        }
        let mut items: Vec<_> = kept.into_values().collect();
        items.sort_by_key(|(used, _, _)| std::cmp::Reverse(*used));
        let mut total = 0;
        for (_, files, size) in items {
            total += size;
            if total > keep {
                for file in files {
                    let _ = std::fs::remove_file(file);
                }
            }
        }
    }
}

/// Takes sound as it is decoded or converted and keeps it in memory, or,
/// once it has outgrown its store's limit, in the store's files.
pub struct Sink {
    left: Vec<f32>,
    right: Vec<f32>,
    /// Both channels have been the same so far (a mono file).
    mono: bool,
    frames: usize,
    store: Option<(DiskStore, String)>,
    spill: Option<Spill>,
}

struct Spill {
    files: [BufWriter<File>; 2],
    paths: [PathBuf; 2],
}

fn bytes(samples: &[f32]) -> &[u8] {
    // SAFETY: any f32 is four plain bytes.
    unsafe { std::slice::from_raw_parts(samples.as_ptr().cast(), samples.len() * 4) }
}

impl Sink {
    /// A sink that keeps everything in memory.
    pub fn memory() -> Self {
        Self::new(None)
    }

    /// A sink that moves to `store`, under `name`, when it grows past the
    /// store's limit.
    pub fn new(store: Option<(&DiskStore, String)>) -> Self {
        Self {
            left: Vec::new(),
            right: Vec::new(),
            mono: true,
            frames: 0,
            store: store.map(|(store, name)| (store.clone(), name)),
            spill: None,
        }
    }

    /// Frames taken so far.
    pub fn frames(&self) -> usize {
        self.frames
    }

    /// Room for `frames` more, when that is known and stays in memory.
    pub fn reserve(&mut self, frames: usize) {
        let stays = self
            .store
            .as_ref()
            .is_none_or(|(store, _)| (frames as u64) * 8 <= store.limit);
        if stays && self.spill.is_none() {
            self.left.reserve(frames);
        }
    }

    /// Add frames: `right` is `None` where both channels are the same.
    pub fn push(&mut self, left: &[f32], right: Option<&[f32]>) -> Result<()> {
        let frames = right.map_or(left.len(), |r| r.len().min(left.len()));
        let left = &left[..frames];
        if right.is_some() && self.mono {
            // The first frames that differ: the right channel so far was the left.
            self.mono = false;
            match &mut self.spill {
                None => self.right = self.left.clone(),
                Some(spill) => {
                    spill.files[0].flush()?;
                    std::fs::copy(&spill.paths[0], &spill.paths[1])?;
                    let file = File::options().append(true).open(&spill.paths[1])?;
                    spill.files[1] = BufWriter::new(file);
                }
            }
        }
        self.frames += frames;
        match &mut self.spill {
            Some(spill) => {
                spill.files[0].write_all(bytes(left))?;
                if let (false, Some(right)) = (self.mono, right) {
                    spill.files[1].write_all(bytes(&right[..frames]))?;
                } else if !self.mono {
                    spill.files[1].write_all(bytes(left))?;
                }
            }
            None => {
                self.left.extend_from_slice(left);
                if !self.mono {
                    self.right.extend_from_slice(right.map_or(left, |r| &r[..frames]));
                }
            }
        }
        self.spill_if_large()
    }

    fn spill_if_large(&mut self) -> Result<()> {
        let Some((store, name)) = &self.store else {
            return Ok(());
        };
        if self.spill.is_some() || (self.frames as u64) * 8 <= store.limit {
            return Ok(());
        }
        let tmp = format!("tmp{}", std::process::id());
        let paths = [
            store.path(&format!("{name}.0"), &tmp),
            store.path(&format!("{name}.1"), &tmp),
        ];
        let begin = || -> std::io::Result<[BufWriter<File>; 2]> {
            std::fs::create_dir_all(&store.dir)?;
            let mut files = [
                BufWriter::new(File::create(&paths[0])?),
                BufWriter::new(File::create(&paths[1])?),
            ];
            files[0].write_all(bytes(&self.left))?;
            if !self.mono {
                files[1].write_all(bytes(&self.right))?;
            }
            Ok(files)
        };
        match begin() {
            Ok(files) => {
                self.left = Vec::new();
                self.right = Vec::new();
                self.spill = Some(Spill { files, paths });
            }
            // A cache that cannot be written (no room, no permission) only
            // costs memory: the sound stays where it is.
            Err(_) => {
                for path in &paths {
                    let _ = std::fs::remove_file(path);
                }
                self.store = None;
            }
        }
        Ok(())
    }

    /// The sound, at `sample_rate`.
    pub fn finish(mut self, sample_rate: u32) -> Result<AudioData> {
        let (Some(mut spill), Some((store, name))) = (self.spill.take(), self.store.take()) else {
            let left = std::mem::take(&mut self.left);
            let right = if self.mono {
                left.clone()
            } else {
                std::mem::take(&mut self.right)
            };
            return Ok(AudioData {
                sample_rate,
                channels: [left.into(), right.into()],
            });
        };
        for file in &mut spill.files {
            file.flush()?;
        }
        drop(spill.files);
        let finals = [store.path(&name, "0"), store.path(&name, "1")];
        std::fs::rename(&spill.paths[0], &finals[0])?;
        if self.mono {
            let _ = std::fs::remove_file(&spill.paths[1]);
        } else {
            std::fs::rename(&spill.paths[1], &finals[1])?;
        }
        // The description is written last: without it the files are not used.
        let meta = store.path(&name, "meta");
        let tmp = store.path(&name, &format!("tmp{}", std::process::id()));
        std::fs::write(
            &tmp,
            format!(
                "{sample_rate} {} {}\n",
                self.frames,
                if self.mono { 1 } else { 2 }
            ),
        )?;
        std::fs::rename(&tmp, &meta)?;
        store
            .open(&name)
            .with_context(|| format!("reading back {}", finals[0].display()))
    }
}

impl Drop for Sink {
    fn drop(&mut self) {
        // Given up half way: nothing is left behind.
        if let Some(spill) = self.spill.take() {
            drop(spill.files);
            for path in &spill.paths {
                let _ = std::fs::remove_file(path);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store(name: &str, limit: u64) -> DiskStore {
        let dir = std::env::temp_dir().join(format!("daw-samples-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        DiskStore { dir, limit }
    }

    #[test]
    fn sound_past_the_limit_goes_to_the_disk_and_reads_the_same() {
        let store = store("spill", 4000);
        let left: Vec<f32> = (0..3000).map(|i| i as f32 * 0.001).collect();
        let right: Vec<f32> = left.iter().map(|s| -s).collect();
        let mut sink = Sink::new(Some((&store, "a-src".into())));
        // Mono to begin with, then two channels, in pieces.
        sink.push(&left[..100], None).unwrap();
        for chunk in 1..30 {
            let range = chunk * 100..(chunk + 1) * 100;
            sink.push(&left[range.clone()], Some(&right[range])).unwrap();
        }
        let data = sink.finish(48_000).unwrap();
        assert!(data.on_disk(), "24 kB of sound against a limit of 4 kB");
        assert_eq!(&data.channels[0][..], &left[..]);
        assert_eq!(&data.channels[1][..100], &left[..100], "mono while it was mono");
        assert_eq!(&data.channels[1][100..], &right[100..]);
        // Kept: found again without the sink.
        let again = store.open("a-src").expect("kept under its name");
        assert_eq!(again.sample_rate, 48_000);
        assert_eq!(&again.channels[1][..], &data.channels[1][..]);
        // Changing it copies it into memory and leaves the file alone.
        let mut copy = again.channels[0].clone();
        copy[0] = 9.0;
        assert!(!copy.on_disk());
        assert_eq!(store.open("a-src").unwrap().channels[0][0], 0.0);
        let _ = std::fs::remove_dir_all(&store.dir);
    }

    #[test]
    fn small_sound_stays_in_memory_and_mono_is_both_channels() {
        let store = store("small", 1 << 20);
        let mut sink = Sink::new(Some((&store, "b-src".into())));
        sink.push(&[0.5; 64], None).unwrap();
        let data = sink.finish(44_100).unwrap();
        assert!(!data.on_disk());
        assert_eq!(data.channels[1].len(), 64);
        assert!(store.open("b-src").is_none(), "nothing was kept");
        assert!(!store.dir.exists(), "not even the directory");
    }

    #[test]
    fn tidying_removes_what_was_used_longest_ago() {
        let store = store("tidy", 100);
        for name in ["old-src", "new-src"] {
            let mut sink = Sink::new(Some((&store, name.into())));
            sink.push(&[0.25; 1000], Some(&[0.5; 1000])).unwrap();
            sink.finish(48_000).unwrap();
            std::thread::sleep(std::time::Duration::from_millis(30));
        }
        // Each is 8 kB and a few bytes: room for one.
        store.tidy(9_000);
        assert!(store.open("new-src").is_some(), "the newer one stays");
        assert!(store.open("old-src").is_none(), "the older one went");
        let _ = std::fs::remove_dir_all(&store.dir);
    }

    #[test]
    fn a_store_that_cannot_be_written_leaves_the_sound_in_memory() {
        let store = DiskStore {
            dir: PathBuf::from("/proc/daw-no-such-place"),
            limit: 100,
        };
        let mut sink = Sink::new(Some((&store, "c-src".into())));
        sink.push(&[0.5; 1000], None).unwrap();
        let data = sink.finish(48_000).unwrap();
        assert!(!data.on_disk());
        assert_eq!(data.channels[0].len(), 1000);
    }
}
