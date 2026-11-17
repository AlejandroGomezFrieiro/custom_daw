//! paw-sampler: what the plugin knows, from the command line.
//!
//!   paw-sampler describe <instrument>        its range, keyswitches and articulations as JSON
//!   paw-sampler render <instrument> <out.wav> <note>...
//!                                            plays notes `key:start:length[:velocity[:m2]]`
//!                                            (seconds; velocity 1-127; m2 like 11.A)
//!   paw-sampler bench <instrument> [voices]  the cost of a voice
//!   paw-sampler fixtures <dir>               writes the test instruments (sines of known pitches)

use paw_sampler::audio::{Store, write_wav};
use paw_sampler::engine::{Engine, Program};
use paw_sampler::{describe, formats, m2, params};
use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("describe") if args.len() == 2 => describe(&args[1]),
        Some("render") if args.len() >= 3 => render(&args[1], &args[2], &args[3..]),
        Some("fixtures") if args.len() == 2 => paw_sampler::fixtures::write(Path::new(&args[1])).map_err(|e| e.to_string()),
        Some("bench") if args.len() >= 2 => bench(&args[1], args.get(2).and_then(|v| v.parse().ok()).unwrap_or(64)),
        _ => Err("usage: paw-sampler describe <instrument> | render <instrument> <out.wav> <key:start:length[:velocity[:m2]]>... | bench <instrument> [voices] | fixtures <dir>".into()),
    };
    if let Err(e) = result {
        eprintln!("paw-sampler: {e}");
        std::process::exit(1);
    }
}

fn load(path: &str) -> Result<Arc<Program>, String> {
    let instrument = formats::read(Path::new(path))?;
    Ok(Arc::new(Program::new(instrument, &mut Store::default())))
}

fn describe(path: &str) -> Result<(), String> {
    let program = load(path)?;
    let defaults: Vec<f64> = params::PARAMS.iter().map(|p| p.default).collect();
    let v = describe::describe(Some(&program), path, None, &defaults);
    println!("{}", serde_json::to_string_pretty(&v).unwrap());
    Ok(())
}

struct Note {
    key: u8,
    start: f64,
    end: f64,
    vel: f32,
    attr: Option<(u8, u16)>,
}

fn render(path: &str, out: &str, notes: &[String]) -> Result<(), String> {
    let program = load(path)?;
    let mut parsed = Vec::new();
    for n in notes {
        let f: Vec<&str> = n.split(':').collect();
        let num = |i: usize| f.get(i).and_then(|v| v.parse::<f64>().ok());
        let key = f.first().and_then(|k| formats::parse_key(k)).ok_or(format!("bad note `{n}`"))?;
        let start = num(1).ok_or(format!("bad note `{n}`"))?;
        let length = num(2).ok_or(format!("bad note `{n}`"))?;
        let attr = f.get(4).and_then(|c| m2::parse_code(c)).map(|c| ((c >> 16) as u8, c as u16));
        parsed.push(Note { key: key as u8, start, end: start + length, vel: num(3).unwrap_or(100.0) as f32 / 127.0, attr });
    }
    let rate = 48000.0;
    let mut engine = Engine::new(rate);
    engine.swap(Some(program));
    let last = parsed.iter().map(|n| n.end).fold(0.0, f64::max) + 2.0;
    let frames = (last * rate) as usize;
    let (mut left, mut right) = (vec![0.0f32; frames], vec![0.0f32; frames]);
    // Events in time order, offs before ons at the same frame.
    let mut events: Vec<(usize, bool, usize)> = Vec::new();
    for (i, n) in parsed.iter().enumerate() {
        events.push(((n.start * rate) as usize, true, i));
        events.push(((n.end * rate) as usize, false, i));
    }
    events.sort_by_key(|e| (e.0, e.1));
    let mut at = 0;
    for (frame, on, i) in events {
        let frame = frame.min(frames);
        engine.render(&mut left[at..frame], &mut right[at..frame]);
        at = frame;
        let n = &parsed[i];
        if on {
            engine.note_on(n.key, n.vel, 0, n.attr);
        } else {
            engine.note_off(n.key, 0);
        }
    }
    engine.render(&mut left[at..], &mut right[at..]);
    let mut interleaved = Vec::with_capacity(frames * 2);
    for i in 0..frames {
        interleaved.push(left[i]);
        interleaved.push(right[i]);
    }
    write_wav(Path::new(out), rate as u32, 2, &interleaved, None, None).map_err(|e| e.to_string())
}

/// Holds `voices` notes across the instrument's range and times a
/// quarter of a second of blocks, five times over; the best time counts,
/// as the least disturbed by whatever else the machine does.
fn bench(path: &str, voices: usize) -> Result<(), String> {
    let program = load(path)?;
    let (lo, hi) = program.instrument.range().ok_or("the instrument plays no key")?;
    let rate = 48000.0;
    let block = 256;
    let blocks = 47;
    for quality in [0.0, 1.0, 2.0] {
        let mut best = f64::MAX;
        let mut sounding = 0;
        for _ in 0..5 {
            let mut engine = Engine::new(rate);
            engine.swap(Some(program.clone()));
            let mut values: Vec<f64> = params::PARAMS.iter().map(|p| p.default).collect();
            values[1] = 256.0;
            values[9] = quality;
            engine.settings = params::settings(&values);
            let mut key = lo;
            while engine.voice_count() < voices as u32 {
                let before = engine.voice_count();
                engine.note_on(key, 0.8, (engine.voice_count() % 16) as u8, None);
                key = if key >= hi { lo } else { key + 1 };
                if engine.voice_count() == before && key == lo {
                    break;
                }
            }
            let (mut left, mut right) = (vec![0.0f32; block], vec![0.0f32; block]);
            let started = Instant::now();
            for _ in 0..blocks {
                left.fill(0.0);
                right.fill(0.0);
                engine.render(&mut left, &mut right);
            }
            best = best.min(started.elapsed().as_secs_f64());
            // Voices that ended meanwhile (a short sample) would make the rest look cheap.
            sounding = engine.voice_count();
        }
        let frames = (blocks * block) as f64;
        let per_voice_frame = best / frames / sounding.max(1) as f64 * 1e9;
        let load = best / (frames / rate) * 100.0;
        let name = params::to_text(&params::PARAMS[9], quality);
        println!(
            "{name}: {sounding} voices, {per_voice_frame:.1} ns per voice and frame, {load:.1} % of a core at 48 kHz ({:.2} % per voice)",
            load / sounding.max(1) as f64
        );
    }
    println!("loaded in {:.1} ms, {} samples, {} bytes", program.load_ms, program.samples.len(), program.memory());
    Ok(())
}
