//! MIDI output through the sequencer: what an engine's tracks send leaves
//! at the time it is stamped with, to a port of our own MIDI input that the
//! test listens to, and a track that stops ends its notes.
#![cfg(feature = "midi")]

use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use daw_engine::midi::{MidiInputs, MidiTarget, port_key};
use daw_engine::midi_out::{MidiOut, MidiOutputs, clock_ns};
use daw_engine::{
    ClipSet, Engine, EventKind, MASTER, MidiEv, Msg, NO_SLOT, SchedEntry, Schedule, TrackRt,
};

/// The inputs with a port of ours, `name`, and what arrives there, with
/// when it arrived. `None` where there is no sequencer, as on a build
/// machine.
fn listen(name: &str) -> Option<(MidiInputs, Receiver<(u64, EventKind)>)> {
    let (tx, rx) = channel();
    let sink = Arc::new(Mutex::new(MidiTarget {
        engine: None,
        tap: Some(Box::new(move |kind| {
            let _ = tx.send((clock_ns(), kind));
        })),
    }));
    let inputs = MidiInputs::start(sink).ok()?;
    inputs.open_port(name);
    Some((inputs, rx))
}

/// The outputs, once they list the port of our inputs.
fn outputs(name: &str) -> Option<MidiOutputs> {
    let outputs = MidiOutputs::start().ok()?;
    let deadline = Instant::now() + Duration::from_secs(4);
    while Instant::now() < deadline {
        if outputs.ports().iter().any(|p| p.name == format!("daw: {name}")) {
            return Some(outputs);
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("the outputs never listed our port");
}

/// Notes and controllers as they arrive, until `count` notes or a while.
fn collect(rx: &Receiver<(u64, EventKind)>, count: usize) -> Vec<(u64, EventKind)> {
    let mut got = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while got.len() < count {
        let left = deadline.saturating_duration_since(Instant::now());
        match rx.recv_timeout(left) {
            Ok(message) => got.push(message),
            Err(_) => break,
        }
    }
    got
}

#[test]
fn messages_leave_when_they_are_stamped_for() {
    let Some((_inputs, rx)) = listen("Loop A") else {
        eprintln!("skipped: no ALSA sequencer");
        return;
    };
    let outputs = outputs("Loop A").unwrap();
    let (mut tx, queue) = rtrb::RingBuffer::<MidiOut>::new(64);
    outputs.set_queue(queue);
    let port = port_key("daw: Loop A");
    let start = clock_ns() + 200_000_000;
    for (i, key) in [60u8, 64, 67].into_iter().enumerate() {
        let at = start + i as u64 * 150_000_000;
        for kind in [
            EventKind::NoteOn { key, vel: 0.8, ch: 4 },
            EventKind::NoteOff { key, ch: 4 },
        ] {
            let at = if matches!(kind, EventKind::NoteOff { .. }) { at + 50_000_000 } else { at };
            tx.push(MidiOut { at, port, kind }).unwrap();
        }
    }
    let got = collect(&rx, 6);
    let ons: Vec<(u64, u8, u8)> = got
        .iter()
        .filter_map(|(at, kind)| match kind {
            EventKind::NoteOn { key, ch, .. } => Some((*at, *key, *ch)),
            _ => None,
        })
        .collect();
    assert_eq!(
        ons.iter().map(|o| o.1).collect::<Vec<_>>(),
        [60, 64, 67],
        "the notes, in order"
    );
    assert!(ons.iter().all(|o| o.2 == 4), "on their channel");
    // A busy machine wakes the reader late, never the sequencer early.
    for (i, (at, ..)) in ons.iter().enumerate() {
        let want = start + i as u64 * 150_000_000;
        let early = want.saturating_sub(*at);
        let late = at.saturating_sub(want);
        assert!(early < 2_000_000, "note {i} came {early} ns early");
        assert!(late < 40_000_000, "note {i} came {late} ns late");
    }
}

#[test]
fn an_engine_sends_what_a_track_plays_and_ends_it_when_stopped() {
    let Some((_inputs, rx)) = listen("Loop B") else {
        eprintln!("skipped: no ALSA sequencer");
        return;
    };
    let outputs = outputs("Loop B").unwrap();
    let (mut engine, mut handle) = Engine::new(48000.0);
    outputs.set_queue(handle.midi_output());
    let send = |handle: &mut daw_engine::EngineHandle, engine: &mut Engine, msg| {
        handle.send_while(msg, engine)
    };
    send(&mut handle, &mut engine, Msg::InsertTrack { slot: 1, track: TrackRt::new() });
    // A held note from the first beat, and another on the second.
    let mut clips = ClipSet::default();
    clips.midi = vec![
        MidiEv { beat: 0.0, kind: EventKind::NoteOn { key: 50, vel: 0.5, ch: 0 } },
        MidiEv { beat: 1.0, kind: EventKind::NoteOn { key: 52, vel: 0.5, ch: 0 } },
    ];
    send(&mut handle, &mut engine, Msg::SetClips { track: 1, clips: Box::new(clips) });
    send(
        &mut handle,
        &mut engine,
        Msg::SetMidiOutput { track: 1, port: port_key("daw: Loop B"), channel: 10 },
    );
    let entries = vec![SchedEntry::new(1, MASTER), SchedEntry::new(MASTER, NO_SLOT)];
    send(&mut handle, &mut engine, Msg::SetSchedule(Box::new(Schedule::new(entries, 0))));
    send(&mut handle, &mut engine, Msg::SetTempo(120.0));
    send(&mut handle, &mut engine, Msg::Play);
    // Real time, a block at a time, for a little more than a beat.
    let (mut left, mut right) = (vec![0.0; 480], vec![0.0; 480]);
    let began = Instant::now();
    for block in 1..=70 {
        engine.process(&mut left, &mut right);
        let due = began + Duration::from_millis(10 * block);
        std::thread::sleep(due.saturating_duration_since(Instant::now()));
    }
    send(&mut handle, &mut engine, Msg::Stop);
    for _ in 0..3 {
        engine.process(&mut left, &mut right);
    }
    // The notes, then All Notes Off, the pedal and the wheel put back.
    let got = collect(&rx, 7);
    let notes: Vec<String> = got
        .iter()
        .filter_map(|(_, kind)| match kind {
            EventKind::NoteOn { key, ch, .. } => Some(format!("on {key} ch{ch}")),
            EventKind::NoteOff { key, ch } => Some(format!("off {key} ch{ch}")),
            _ => None,
        })
        .collect();
    assert_eq!(
        notes,
        ["on 50 ch9", "on 52 ch9", "off 50 ch9", "off 52 ch9"],
        "both notes on the track's channel, and ended when it stopped"
    );
    let ons: Vec<u64> = got
        .iter()
        .filter(|(_, kind)| matches!(kind, EventKind::NoteOn { .. }))
        .map(|(at, _)| *at)
        .collect();
    let apart = (ons[1] - ons[0]) as f64 / 1e6;
    assert!((apart - 500.0).abs() < 40.0, "a beat apart at 120 BPM: {apart} ms");
}
