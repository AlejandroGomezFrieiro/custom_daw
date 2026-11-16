//! Replacing one track's clips while playing must not disturb the others.

use daw_engine::{
    ClipSet, Engine, EngineHandle, EventKind, MASTER, MAX_BLOCK, Msg, NO_SLOT, Registry,
    SchedEntry, Schedule, Slot, TrackRt,
};

const SR: f64 = 48000.0;

fn send(handle: &mut EngineHandle, msg: Msg) {
    assert!(handle.try_send(msg).is_ok());
}

/// Two tracks with a synth each. Track 1 holds one long note; track 2 holds
/// `second` (a note, or nothing).
fn engine(second: bool) -> (Engine, EngineHandle) {
    let (engine, mut handle) = Engine::new(SR);
    let registry = Registry::with_builtins();
    for (slot, device) in [(1 as Slot, 0 as Slot), (2, 1)] {
        send(
            &mut handle,
            Msg::InsertTrack {
                slot,
                track: TrackRt::new(),
            },
        );
        let synth = registry
            .get("synth")
            .unwrap()
            .create(SR as f32, MAX_BLOCK)
            .unwrap()
            .device;
        send(
            &mut handle,
            Msg::InsertDevice {
                slot: device,
                device: synth,
            },
        );
        send(
            &mut handle,
            Msg::SetChain {
                track: slot,
                chain: Box::new([device]),
            },
        );
        let mut clips = ClipSet::default();
        if slot == 1 || second {
            clips.push_note(0.0, 64.0, 57 + slot as u8, 0.8);
        }
        clips.finish();
        send(
            &mut handle,
            Msg::SetClips {
                track: slot,
                clips: Box::new(clips),
            },
        );
    }
    let entry = |slot| SchedEntry::new(slot, MASTER);
    let entries = vec![entry(1), entry(2), SchedEntry::new(MASTER, NO_SLOT)];
    send(
        &mut handle,
        Msg::SetSchedule(Box::new(Schedule::new(entries, 0))),
    );
    send(&mut handle, Msg::Play);
    (engine, handle)
}

fn run(engine: &mut Engine, blocks: usize) -> Vec<f32> {
    let mut out = Vec::new();
    let (mut l, mut r) = (vec![0.0; 256], vec![0.0; 256]);
    for _ in 0..blocks {
        engine.process(&mut l, &mut r);
        out.extend_from_slice(&l);
    }
    out
}

#[test]
fn replacing_one_tracks_clips_leaves_the_others_playing() {
    let (mut reference, _keep) = engine(false);
    let expected = run(&mut reference, 400);

    let (mut edited, mut handle) = engine(false);
    let mut got = run(&mut edited, 100);
    // Track 2's clips are replaced (by the same nothing) three times while
    // track 1's note sounds. Track 1 must not be stopped and restarted.
    for _ in 0..3 {
        let mut empty = ClipSet::default();
        empty.finish();
        send(
            &mut handle,
            Msg::SetClips {
                track: 2,
                clips: Box::new(empty),
            },
        );
        got.extend(run(&mut edited, 100));
    }
    handle.collect_garbage();
    let worst = expected
        .iter()
        .zip(&got)
        .map(|(a, b)| (a - b).abs())
        .fold(0f32, f32::max);
    assert_eq!(
        worst, 0.0,
        "track 1 changed when only track 2's clips were replaced"
    );
}

#[test]
fn replacing_a_tracks_clips_stops_its_own_notes() {
    let (mut edited, mut handle) = engine(true);
    run(&mut edited, 50);
    assert!(handle.shared.meter(2).0 > 0.01, "track 2 sounds at first");
    let mut empty = ClipSet::default();
    empty.finish();
    send(
        &mut handle,
        Msg::SetClips {
            track: 2,
            clips: Box::new(empty),
        },
    );
    // Release (0.2 s) plus the meter's fall.
    run(&mut edited, 400);
    assert!(
        handle.shared.meter(2).0 < 1e-3,
        "the note on track 2 stopped with its clip"
    );
    assert!(handle.shared.meter(1).0 > 0.01, "track 1 plays on");
}

/// A track whose clips were just replaced must not stop and restart its
/// notes a block into playback: the note-on at the very start arrives once.
#[test]
fn a_note_at_the_start_is_started_once() {
    use daw_engine::{Device, Io, ProcessCtx};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU32, Ordering};

    struct Counter(Arc<AtomicU32>);
    impl Device for Counter {
        fn process(&mut self, _ctx: &ProcessCtx, io: &mut Io) {
            for event in io.events.as_slice() {
                if matches!(event.kind, EventKind::NoteOn { .. }) {
                    self.0.fetch_add(1, Ordering::Relaxed);
                }
            }
        }
        fn set_param(&mut self, _index: u32, _value: f32) {}
    }

    let (mut engine, mut handle) = Engine::new(48000.0);
    let count = Arc::new(AtomicU32::new(0));
    let mut clips = ClipSet::default();
    clips.push_note(0.0, 4.0, 60, 0.8);
    clips.finish();
    for msg in [
        Msg::InsertTrack {
            slot: 1,
            track: TrackRt::new(),
        },
        Msg::InsertDevice {
            slot: 0,
            device: Box::new(Counter(count.clone())),
        },
        Msg::SetChain {
            track: 1,
            chain: Box::new([0]),
        },
        Msg::SetClips {
            track: 1,
            clips: Box::new(clips),
        },
        Msg::SetSchedule(Box::new(Schedule::new(
            vec![SchedEntry::new(1, MASTER), SchedEntry::new(MASTER, NO_SLOT)],
            0,
        ))),
        Msg::Seek(0.0),
        Msg::Play,
    ] {
        send(&mut handle, msg);
    }
    let (mut left, mut right) = (vec![0.0f32; 256], vec![0.0f32; 256]);
    for _ in 0..8 {
        engine.process(&mut left, &mut right);
    }
    assert_eq!(count.load(Ordering::Relaxed), 1);
}
