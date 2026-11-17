//! The plugin's parameters: what adjusts any instrument to taste.

use crate::engine::{MAX_POLYPHONY, Settings};
use crate::interp::Quality;

pub struct Param {
    pub id: u32,
    /// The key in the state and in `describe`.
    pub key: &'static str,
    pub name: &'static str,
    pub min: f64,
    pub max: f64,
    pub default: f64,
    pub stepped: bool,
    pub unit: &'static str,
}

const fn param(id: u32, key: &'static str, name: &'static str, min: f64, max: f64, default: f64, stepped: bool, unit: &'static str) -> Param {
    Param { id, key, name, min, max, default, stepped, unit }
}

pub const PARAMS: &[Param] = &[
    param(0, "gain", "Gain", -60.0, 12.0, 0.0, false, "dB"),
    param(1, "polyphony", "Polyphony", 1.0, MAX_POLYPHONY as f64, 128.0, true, "voices"),
    param(2, "tune", "Tune", -100.0, 100.0, 0.0, false, "cents"),
    param(3, "transpose", "Transpose", -24.0, 24.0, 0.0, true, "semitones"),
    param(4, "attack", "Attack scale", 0.1, 10.0, 1.0, false, "×"),
    param(5, "release", "Release scale", 0.1, 10.0, 1.0, false, "×"),
    param(6, "velocity", "Velocity sensitivity", 0.0, 2.0, 1.0, false, "×"),
    param(7, "release_level", "Release trigger level", -60.0, 12.0, 0.0, false, "dB"),
    param(8, "cutoff", "Filter cutoff", -48.0, 48.0, 0.0, false, "semitones"),
    param(9, "quality", "Interpolation", 0.0, 2.0, 2.0, true, ""),
];

pub fn by_id(id: u32) -> Option<(usize, &'static Param)> {
    PARAMS.iter().enumerate().find(|(_, p)| p.id == id)
}

pub fn by_key(key: &str) -> Option<(usize, &'static Param)> {
    PARAMS.iter().enumerate().find(|(_, p)| p.key == key)
}

const QUALITIES: [&str; 3] = ["linear", "hermite", "sinc"];

pub fn to_text(p: &Param, value: f64) -> String {
    match p.key {
        "quality" => QUALITIES[(value.round() as usize).min(2)].to_string(),
        "polyphony" | "transpose" => format!("{} {}", value.round(), p.unit),
        _ => format!("{value:.2} {}", p.unit).trim().to_string(),
    }
}

pub fn from_text(p: &Param, text: &str) -> Option<f64> {
    let text = text.trim();
    if p.key == "quality" {
        return QUALITIES.iter().position(|q| *q == text).map(|i| i as f64);
    }
    let number = text.split_whitespace().next()?.parse::<f64>().ok()?;
    Some(number.clamp(p.min, p.max))
}

/// The engine's settings from the plugin's values, without allocating.
pub fn settings_from(values: &[std::sync::atomic::AtomicU64]) -> Settings {
    let mut v = [0.0f64; PARAMS.len()];
    for (slot, value) in v.iter_mut().zip(values) {
        *slot = f64::from_bits(value.load(std::sync::atomic::Ordering::Relaxed));
    }
    settings(&v)
}

/// The engine's settings from the parameters' values, in `PARAMS`' order.
pub fn settings(values: &[f64]) -> Settings {
    let db = |v: f64| 10f32.powf(v as f32 / 20.0);
    Settings {
        gain: db(values[0]),
        polyphony: values[1].round().clamp(1.0, MAX_POLYPHONY as f64) as usize,
        tune: values[2] as f32,
        transpose: values[3].round() as f32,
        attack_scale: values[4] as f32,
        release_scale: values[5] as f32,
        velocity: values[6] as f32,
        release_level: db(values[7]),
        cutoff: values[8] as f32 * 100.0,
        quality: match values[9].round() as i64 {
            0 => Quality::Linear,
            1 => Quality::Hermite,
            _ => Quality::Sinc,
        },
    }
}
