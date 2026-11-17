//! The fixture instruments played by the engine and checked by ear: the
//! pitch of each note (every sample is a sine of known frequency), levels,
//! round robin order, keyswitches and attributes, release triggers, loops,
//! envelopes, choke groups.

use paw_sampler::audio::Store;
use paw_sampler::engine::{Engine, Program};
use paw_sampler::{fixtures, formats};
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

const RATE: f64 = 48000.0;

fn dir() -> &'static PathBuf {
    static DIR: OnceLock<PathBuf> = OnceLock::new();
    DIR.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("paw-sampler-golden-{}", std::process::id()));
        fixtures::write(&dir).unwrap();
        dir
    })
}

fn engine(name: &str) -> Engine {
    let instrument = formats::read(&dir().join(name)).unwrap();
    assert!(instrument.warnings.is_empty(), "{name}: {:?}", instrument.warnings);
    let program = Arc::new(Program::new(instrument, &mut Store::default()));
    let mut e = Engine::new(RATE);
    e.swap(Some(program));
    e
}

enum Ev {
    On(u8, u8),
    OnAttr(u8, u8, u8, u16),
    Off(u8),
    Cc(u8, u8),
}

/// Plays timed events (seconds) for `seconds`; the left channel.
fn play(e: &mut Engine, events: &[(f64, Ev)], seconds: f64) -> Vec<f32> {
    let frames = (seconds * RATE) as usize;
    let (mut left, mut right) = (vec![0.0f32; frames], vec![0.0f32; frames]);
    let mut at = 0;
    for (time, ev) in events {
        let frame = ((time * RATE) as usize).min(frames);
        // In blocks of 256, as a host would call it.
        while at < frame {
            let n = (frame - at).min(256);
            e.render(&mut left[at..at + n], &mut right[at..at + n]);
            at += n;
        }
        match *ev {
            Ev::On(key, vel) => e.note_on(key, vel as f32 / 127.0, 0, None),
            Ev::OnAttr(key, vel, t, data) => e.note_on(key, vel as f32 / 127.0, 0, Some((t, data))),
            Ev::Off(key) => e.note_off(key, 0),
            Ev::Cc(cc, v) => e.control(cc, v as f32 / 127.0),
        }
    }
    while at < frames {
        let n = (frames - at).min(256);
        e.render(&mut left[at..at + n], &mut right[at..at + n]);
        at += n;
    }
    left
}

fn window(x: &[f32], from: f64, to: f64) -> &[f32] {
    &x[(from * RATE) as usize..((to * RATE) as usize).min(x.len())]
}

/// The frequency of a sine by its upward zero crossings, interpolated.
fn frequency(x: &[f32]) -> f64 {
    let mut first = None;
    let mut last = 0.0;
    let mut count = 0;
    for i in 1..x.len() {
        if x[i - 1] < 0.0 && x[i] >= 0.0 {
            let t = (i - 1) as f64 + (-x[i - 1] / (x[i] - x[i - 1])) as f64;
            if first.is_none() {
                first = Some(t);
            } else {
                count += 1;
            }
            last = t;
        }
    }
    match first {
        Some(f) if count > 0 => count as f64 * RATE / (last - f),
        _ => 0.0,
    }
}

/// How strong one frequency is in a stretch (a single DFT bin).
fn strength(x: &[f32], freq: f64) -> f64 {
    let (mut re, mut im) = (0.0, 0.0);
    for (i, &v) in x.iter().enumerate() {
        let a = std::f64::consts::TAU * freq * i as f64 / RATE;
        re += v as f64 * a.cos();
        im += v as f64 * a.sin();
    }
    2.0 * (re * re + im * im).sqrt() / x.len() as f64
}

fn rms(x: &[f32]) -> f64 {
    (x.iter().map(|&v| v as f64 * v as f64).sum::<f64>() / x.len().max(1) as f64).sqrt()
}

fn near(got: f64, want: f64, tolerance: f64, what: &str) {
    assert!((got - want).abs() <= tolerance, "{what}: got {got:.2}, want {want:.2} ± {tolerance}");
}

#[test]
fn the_pitch_follows_the_key() {
    let mut e = engine("basic.sfz");
    let x = play(&mut e, &[(0.0, Ev::On(57, 127)), (0.3, Ev::Off(57)), (0.4, Ev::On(69, 127)), (0.7, Ev::Off(69)), (0.8, Ev::On(81, 127))], 1.1);
    near(frequency(window(&x, 0.05, 0.25)), 220.0, 0.5, "A3");
    near(frequency(window(&x, 0.45, 0.65)), 440.0, 0.5, "A4");
    near(frequency(window(&x, 0.85, 1.05)), 880.0, 1.0, "A5");
    // A sine of 0.5 at full velocity, unity gain, panned to the middle.
    near(rms(window(&x, 0.45, 0.65)), 0.5 / 2f64.sqrt(), 0.01, "level");
}

#[test]
fn a_sample_plays_from_its_own_key_and_loop() {
    let mut e = engine("smpl.sfz");
    // `pitch_keycenter=sample`: the file says A3, and it loops: held for a second, a quarter-second sample goes on.
    let x = play(&mut e, &[(0.0, Ev::On(69, 127)), (1.0, Ev::Off(69))], 1.2);
    near(frequency(window(&x, 0.1, 0.9)), 440.0, 0.5, "an octave above the file's key");
    near(rms(window(&x, 0.7, 0.9)), 0.5 / 2f64.sqrt(), 0.02, "still sounding in the loop");
}

#[test]
fn round_robins_play_in_turn() {
    let mut e = engine("rr.sfz");
    let mut events = Vec::new();
    for i in 0..6 {
        events.push((i as f64 * 0.2, Ev::On(69, 100)));
        events.push((i as f64 * 0.2 + 0.15, Ev::Off(69)));
    }
    let x = play(&mut e, &events, 1.2);
    let heard: Vec<i64> = (0..6).map(|i| frequency(window(&x, i as f64 * 0.2 + 0.02, i as f64 * 0.2 + 0.14)).round() as i64).collect();
    assert_eq!(heard.iter().map(|f| (f + 5) / 10 * 10).collect::<Vec<_>>(), vec![440, 550, 660, 440, 550, 660]);
}

#[test]
fn decent_sampler_round_robins_play_in_turn() {
    let mut e = engine("rr.dspreset");
    let mut events = Vec::new();
    for i in 0..4 {
        events.push((i as f64 * 0.2, Ev::On(69, 100)));
        events.push((i as f64 * 0.2 + 0.15, Ev::Off(69)));
    }
    let x = play(&mut e, &events, 0.8);
    let heard: Vec<i64> = (0..4).map(|i| (frequency(window(&x, i as f64 * 0.2 + 0.02, i as f64 * 0.2 + 0.14)) / 10.0).round() as i64 * 10).collect();
    assert_eq!(heard, vec![440, 550, 660, 440]);
}

fn keyswitches(name: &str) {
    let mut e = engine(name);
    let x = play(
        &mut e,
        &[
            (0.0, Ev::On(69, 100)),
            (0.2, Ev::Off(69)),
            // Staccato's keyswitch, then a note: it plays staccato, and so does the next.
            (0.3, Ev::On(25, 100)),
            (0.3, Ev::On(69, 100)),
            (0.31, Ev::Off(25)),
            (0.5, Ev::Off(69)),
            (0.6, Ev::On(69, 100)),
            (0.8, Ev::Off(69)),
            (0.9, Ev::On(24, 100)),
            (0.91, Ev::Off(24)),
            (1.0, Ev::On(69, 100)),
            (1.2, Ev::Off(69)),
        ],
        1.3,
    );
    near(frequency(window(&x, 0.02, 0.18)), 440.0, 1.0, "the default articulation");
    near(frequency(window(&x, 0.32, 0.48)), 660.0, 1.0, "a keyswitch at the same moment, before the note");
    near(frequency(window(&x, 0.62, 0.78)), 660.0, 1.0, "the keyswitch sticks");
    near(frequency(window(&x, 1.02, 1.18)), 440.0, 1.0, "back to sustain");
}

#[test]
fn sfz_keyswitches_choose_the_articulation() {
    keyswitches("ks.sfz");
}

#[test]
fn decent_sampler_keyswitches_choose_the_articulation() {
    keyswitches("ks.dspreset");
}

fn attributes(name: &str) {
    let mut e = engine(name);
    let x = play(
        &mut e,
        &[
            // Staccato (M2-123 11.0) by attribute, on this note only.
            (0.0, Ev::OnAttr(69, 100, 0x11, 0x0000)),
            (0.2, Ev::Off(69)),
            (0.3, Ev::On(69, 100)),
            (0.5, Ev::Off(69)),
            // Spiccato (11.5) is not there: it falls back to staccato.
            (0.6, Ev::OnAttr(69, 100, 0x11, 0x5000)),
            (0.8, Ev::Off(69)),
            // A chord of two articulations: sustain on A4, staccato on E5.
            (0.9, Ev::OnAttr(69, 100, 0x10, 0x0000)),
            (0.9, Ev::OnAttr(76, 100, 0x11, 0x0000)),
            (1.2, Ev::Off(69)),
            (1.2, Ev::Off(76)),
        ],
        1.3,
    );
    near(frequency(window(&x, 0.02, 0.18)), 660.0, 1.0, "the attribute's articulation");
    near(frequency(window(&x, 0.32, 0.48)), 440.0, 1.0, "the next note plays the default");
    near(frequency(window(&x, 0.62, 0.78)), 660.0, 1.0, "spiccato falls back to staccato");
    let chord = window(&x, 0.95, 1.15);
    let e5_staccato = 660.0 * 2f64.powf(7.0 / 12.0);
    let e5_sustain = 440.0 * 2f64.powf(7.0 / 12.0);
    assert!(strength(chord, 440.0) > 0.2, "A4 sustains: {}", strength(chord, 440.0));
    assert!(strength(chord, e5_staccato) > 0.2, "E5 is staccato: {}", strength(chord, e5_staccato));
    assert!(strength(chord, e5_sustain) < 0.02, "and not sustain: {}", strength(chord, e5_sustain));
    assert!(strength(chord, 660.0) < 0.02, "A4 is not staccato: {}", strength(chord, 660.0));
}

#[test]
fn sfz_attributes_choose_the_articulation_per_note() {
    attributes("ks.sfz");
}

#[test]
fn decent_sampler_attributes_choose_the_articulation_per_note() {
    attributes("ks.dspreset");
}

#[test]
fn velocity_chooses_the_layer() {
    let mut e = engine("vel.sfz");
    let x = play(&mut e, &[(0.0, Ev::On(69, 40)), (0.2, Ev::Off(69)), (0.3, Ev::On(69, 100)), (0.5, Ev::Off(69))], 0.6);
    near(frequency(window(&x, 0.02, 0.18)), 440.0, 1.0, "soft");
    near(frequency(window(&x, 0.32, 0.48)), 660.0, 1.0, "loud");
    near(rms(window(&x, 0.02, 0.18)), rms(window(&x, 0.32, 0.48)), 0.01, "amp_veltrack=0: the same level");
}

#[test]
fn a_release_trigger_plays_after_the_note() {
    let mut e = engine("release.sfz");
    let x = play(&mut e, &[(0.0, Ev::On(69, 127)), (0.5, Ev::Off(69))], 1.0);
    near(frequency(window(&x, 0.1, 0.45)), 440.0, 1.0, "the note");
    near(frequency(window(&x, 0.55, 0.75)), 880.0, 1.0, "the release sample");
    assert!(rms(window(&x, 0.9, 1.0)) < 1e-4, "and then silence");
}

#[test]
fn the_sustain_pedal_holds_notes_and_their_release_triggers() {
    let mut e = engine("release.sfz");
    let x = play(&mut e, &[(0.0, Ev::Cc(64, 127)), (0.0, Ev::On(69, 127)), (0.2, Ev::Off(69)), (0.5, Ev::Cc(64, 0))], 1.0);
    near(frequency(window(&x, 0.25, 0.45)), 440.0, 1.0, "held by the pedal");
    near(frequency(window(&x, 0.55, 0.75)), 880.0, 1.0, "released with the pedal");
}

#[test]
fn a_loop_joins_without_a_click() {
    let mut e = engine("loop.sfz");
    let x = play(&mut e, &[(0.0, Ev::On(69, 127)), (2.0, Ev::Off(69))], 2.1);
    near(frequency(window(&x, 0.5, 1.9)), 480.0, 0.2, "the loop's pitch");
    near(rms(window(&x, 1.5, 1.9)), 0.5 / 2f64.sqrt(), 0.01, "five times the sample's length, still sounding");
    // The biggest step from one frame to the next is the sine's own.
    let steepest = 0.5 * std::f64::consts::TAU * 480.0 / RATE;
    let worst = window(&x, 0.05, 1.95).windows(2).map(|w| (w[1] - w[0]).abs() as f64).fold(0.0, f64::max);
    assert!(worst < steepest * 1.05, "a step of {worst} at the loop (a sine of this level steps {steepest})");
}

#[test]
fn the_envelope_rises_and_falls() {
    let mut e = engine("envelope.sfz");
    let x = play(&mut e, &[(0.0, Ev::On(69, 127)), (1.0, Ev::Off(69))], 1.6);
    let (a, b, c) = (rms(window(&x, 0.0, 0.1)), rms(window(&x, 0.3, 0.4)), rms(window(&x, 0.6, 0.9)));
    assert!(a < b && b < c, "attack: {a} {b} {c}");
    near(c, 1.0 / 2f64.sqrt(), 0.01, "full after the attack");
    let (d, f) = (rms(window(&x, 1.0, 1.1)), rms(window(&x, 1.2, 1.29)));
    assert!(d > f && f > 0.0, "release: {d} {f}");
    assert!(rms(window(&x, 1.31, 1.6)) < 1e-5, "silent once the release ends");
    near(frequency(window(&x, 0.6, 0.9)), 440.0, 0.5, "*sine plays the key");
}

#[test]
fn a_choke_group_stops_another() {
    let mut e = engine("choke.sfz");
    let x = play(&mut e, &[(0.0, Ev::On(69, 127)), (0.3, Ev::On(71, 127)), (0.6, Ev::Off(71)), (0.6, Ev::Off(69))], 0.7);
    near(frequency(window(&x, 0.05, 0.25)), 440.0, 1.0, "the open hat");
    let after = window(&x, 0.32, 0.55);
    assert!(strength(after, 440.0) < 0.01, "choked: {}", strength(after, 440.0));
    near(frequency(after), 660.0, 1.0, "the closed hat");
}

#[test]
fn polyphony_is_limited_and_voices_are_stolen() {
    let mut e = engine("basic.sfz");
    let mut values: Vec<f64> = paw_sampler::params::PARAMS.iter().map(|p| p.default).collect();
    values[1] = 4.0;
    e.settings = paw_sampler::params::settings(&values);
    let events: Vec<(f64, Ev)> = (0..8).map(|i| (i as f64 * 0.01, Ev::On(60 + i, 100))).collect();
    play(&mut e, &events, 0.2);
    assert_eq!(e.voice_count(), 4);
}

#[test]
fn renders_repeat_exactly() {
    let run = || {
        let mut e = engine("rr.sfz");
        play(&mut e, &[(0.0, Ev::On(69, 100)), (0.1, Ev::Off(69)), (0.2, Ev::On(69, 90)), (0.3, Ev::Off(69))], 0.5)
    };
    assert_eq!(run(), run());
}
