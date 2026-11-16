//! Stretched and pitch-shifted sound, made on worker threads and kept.
//!
//! A clip with a stretch or a pitch shift plays a version of its file made
//! for it (`stretch.rs`), at the engine's rate. Sync asks for it when it
//! builds the clip; the first time it is not there yet, so it is queued and
//! the clip is silent until it is ready, when the session builds the
//! clip's track again (`Session::poll_stretches`). A version is known by
//! its file and what was made of it (ratio, shift, mode, rate), kept in
//! memory, and in the disk store when it is large, so that it is made once
//! for every clip that plays it and found again in later runs.
//!
//! A version asked for is made only once it has been wanted for a moment,
//! so that a ratio typed or dragged through several values makes only the
//! last, and one that stops being wanted (the clip changed again, or went)
//! is dropped, its worker told to stop.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::Result;
use daw_engine::{AudioData, DiskStore, Sink};

use crate::model::{Clip, ClipContent};
use crate::peaks::Summary;
use crate::stretch::{self, Mode};

/// How long a version must be wanted before it is made.
pub const SETTLE: Duration = Duration::from_millis(150);

/// How many are made at the same time.
const AT_ONCE: usize = 2;

/// Versions no clip plays any more that are kept anyway, for undo.
const SPARE: usize = 8;

/// What a version is made of.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Key {
    pub file: PathBuf,
    /// The engine's rate, which the version is at.
    pub rate: u32,
    /// The ratio and the shift in semitones, as bits.
    ratio: u64,
    pitch: u64,
    pub mode: Mode,
}

impl Key {
    /// What `clip` plays at `rate`, if it is an audio clip stretched or shifted.
    pub fn of(clip: &Clip, rate: u32) -> Option<Self> {
        let ClipContent::Audio { file, .. } = &clip.content else {
            return None;
        };
        clip.is_stretched().then(|| Self {
            file: file.clone(),
            rate,
            ratio: clip.stretch.to_bits(),
            pitch: clip.pitch.to_bits(),
            mode: clip.stretch_mode,
        })
    }

    pub fn ratio(&self) -> f64 {
        f64::from_bits(self.ratio)
    }

    pub fn pitch(&self) -> f64 {
        f64::from_bits(self.pitch)
    }

    /// The name it is kept under in the disk store.
    fn store_name(&self) -> Option<String> {
        let what = format!(
            "x{}-{:016x}-{:016x}-{}",
            self.rate,
            self.ratio,
            self.pitch,
            self.mode.name()
        );
        daw_engine::store_name(&self.file, &what)
    }
}

/// A version made, with its waveform overview once one was asked for.
pub struct Ready {
    pub data: Arc<AudioData>,
    summary: Option<Arc<Summary>>,
}

impl Ready {
    pub fn summary(&mut self) -> Arc<Summary> {
        self.summary
            .get_or_insert_with(|| Arc::new(Summary::new(&self.data)))
            .clone()
    }
}

enum Job {
    /// Wanted since then, made from this.
    Waiting(Instant, Arc<AudioData>),
    Running(JoinHandle<Result<AudioData>>, Arc<AtomicBool>),
    Done(Ready),
    /// It could not be made; why was told once, as a warning.
    Failed,
}

/// Where a clip's version is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    /// Not stretched at all (it plays its file), or not asked for yet.
    Plain,
    Ready,
    /// Waiting or being made.
    Making,
    Failed,
}

#[derive(Default)]
pub struct Renders {
    jobs: HashMap<Key, Job>,
    /// Versions made, oldest first, for dropping the oldest unwanted ones.
    made: VecDeque<Key>,
    /// Why versions could not be made, not yet told.
    pub failures: Vec<String>,
    /// Versions made (or failed) since the session last looked, whose
    /// clips are to be built again.
    pub finished: Vec<Key>,
}

impl Renders {
    /// The version `key` names, if it is made; otherwise it is queued,
    /// to be made from `source`, which is asked for only then.
    pub fn get(
        &mut self,
        key: &Key,
        store: Option<&DiskStore>,
        source: impl FnOnce() -> Option<Arc<AudioData>>,
    ) -> Option<Arc<AudioData>> {
        match self.jobs.get(key) {
            Some(Job::Done(ready)) => return Some(ready.data.clone()),
            Some(_) => return None,
            None => {}
        }
        if let Some(store) = store
            && let Some(name) = key.store_name()
            && let Some(data) = store.open(&name)
        {
            let data = Arc::new(data);
            self.done(key.clone(), data.clone());
            return Some(data);
        }
        let source = source()?;
        self.jobs
            .insert(key.clone(), Job::Waiting(Instant::now(), source));
        None
    }

    fn done(&mut self, key: Key, data: Arc<AudioData>) {
        self.jobs.insert(
            key.clone(),
            Job::Done(Ready {
                data,
                summary: None,
            }),
        );
        self.made.push_back(key);
    }

    /// Whether `key` has been asked for (and not dropped since).
    pub fn known(&self, key: &Key) -> bool {
        self.jobs.contains_key(key)
    }

    /// The version made for `key`, with its overview for drawing.
    pub fn ready(&mut self, key: &Key) -> Option<&mut Ready> {
        match self.jobs.get_mut(key) {
            Some(Job::Done(ready)) => Some(ready),
            _ => None,
        }
    }

    pub fn status(&self, key: Option<&Key>) -> Status {
        match key.and_then(|k| self.jobs.get(k)) {
            None => Status::Plain,
            Some(Job::Done(_)) => Status::Ready,
            Some(Job::Failed) => Status::Failed,
            Some(_) => Status::Making,
        }
    }

    /// Whether anything is waiting or being made.
    pub fn busy(&self) -> bool {
        self.jobs
            .values()
            .any(|job| matches!(job, Job::Waiting(..) | Job::Running(..)))
    }

    /// Whether any of `keys` is still waiting or being made.
    pub fn making(&self, keys: &HashSet<Key>) -> bool {
        keys.iter()
            .any(|k| matches!(self.jobs.get(k), Some(Job::Waiting(..) | Job::Running(..))))
    }

    /// Drop what is not in `wanted`, start what has waited `settle`, and
    /// take in what has been made, noting it in `finished`. `store` keeps
    /// what is large.
    pub fn poll(&mut self, wanted: &HashSet<Key>, settle: Duration, store: Option<&DiskStore>) {
        let finished = &mut self.finished;
        self.jobs.retain(|key, job| match job {
            Job::Waiting(..) => wanted.contains(key),
            Job::Running(_, cancel) => {
                if !wanted.contains(key) {
                    // It stops at its next look; its result is dropped then.
                    cancel.store(true, Ordering::Relaxed);
                }
                true
            }
            Job::Done(_) | Job::Failed => true,
        });
        let ended: Vec<Key> = self
            .jobs
            .iter()
            .filter(|(_, job)| matches!(job, Job::Running(thread, _) if thread.is_finished()))
            .map(|(key, _)| key.clone())
            .collect();
        for key in ended {
            let Some(Job::Running(thread, cancel)) = self.jobs.remove(&key) else {
                continue;
            };
            let result = thread
                .join()
                .unwrap_or_else(|_| Err(anyhow::anyhow!("the stretch stopped unexpectedly")));
            if cancel.load(Ordering::Relaxed) {
                // Wanted again since it was told to stop: its clips are
                // built again, which asks for it anew.
                if wanted.contains(&key) {
                    finished.push(key);
                }
                continue;
            }
            match result {
                Ok(data) => {
                    finished.push(key.clone());
                    self.jobs.insert(
                        key.clone(),
                        Job::Done(Ready {
                            data: Arc::new(data),
                            summary: None,
                        }),
                    );
                    self.made.push_back(key);
                }
                Err(err) => {
                    let why = format!("stretching {}: {err:#}", key.file.display());
                    self.failures.push(why);
                    self.jobs.insert(key.clone(), Job::Failed);
                    finished.push(key);
                }
            }
        }
        let running = self
            .jobs
            .values()
            .filter(|job| matches!(job, Job::Running(..)))
            .count();
        let now = Instant::now();
        let mut due: Vec<(Instant, Key)> = self
            .jobs
            .iter()
            .filter_map(|(key, job)| match job {
                Job::Waiting(since, _) if now.duration_since(*since) >= settle => {
                    Some((*since, key.clone()))
                }
                _ => None,
            })
            .collect();
        due.sort_by_key(|(since, _)| *since);
        for (_, key) in due.into_iter().take(AT_ONCE.saturating_sub(running)) {
            let Some(Job::Waiting(_, source)) = self.jobs.remove(&key) else {
                continue;
            };
            let cancel = Arc::new(AtomicBool::new(false));
            let kept = store.and_then(|s| Some((s.clone(), key.store_name()?)));
            let (k, stop) = (key.clone(), cancel.clone());
            let thread = std::thread::Builder::new()
                .name("stretch".into())
                .spawn(move || {
                    let sink = Sink::new(kept.as_ref().map(|(s, n)| (s, n.clone())));
                    stretch::render(&source, k.ratio(), k.pitch(), k.mode, sink, &stop)
                });
            match thread {
                Ok(thread) => {
                    self.jobs.insert(key, Job::Running(thread, cancel));
                }
                Err(err) => {
                    let why = format!("starting a stretch: {err}");
                    self.failures.push(why);
                    self.jobs.insert(key, Job::Failed);
                }
            }
        }
        // Versions no clip plays any more, past a few kept for undo.
        let unwanted: Vec<Key> = self
            .made
            .iter()
            .filter(|k| !wanted.contains(k))
            .cloned()
            .collect();
        if unwanted.len() > SPARE {
            for key in &unwanted[..unwanted.len() - SPARE] {
                self.jobs.remove(key);
            }
            let jobs = &self.jobs;
            self.made.retain(|k| jobs.contains_key(k));
        }
    }

    /// Forget what was made from files not in `keep`, and everything when
    /// `keep` is `None`.
    pub fn retain(&mut self, keep: Option<&HashSet<PathBuf>>) {
        // One being made stops at its next look, and is dropped once it has.
        for (key, job) in &self.jobs {
            if let Job::Running(_, cancel) = job
                && !keep.is_some_and(|k| k.contains(&key.file))
            {
                cancel.store(true, Ordering::Relaxed);
            }
        }
        self.jobs.retain(|key, job| {
            matches!(job, Job::Running(..)) || keep.is_some_and(|k| k.contains(&key.file))
        });
        let jobs = &self.jobs;
        self.made.retain(|k| jobs.contains_key(k));
    }
}
