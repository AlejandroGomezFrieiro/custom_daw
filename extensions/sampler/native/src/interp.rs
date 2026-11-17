//! Reading a sample between its frames.
//!
//! The default is a windowed sinc (16 taps, Kaiser window β = 8) from
//! tables of 256 phases, interpolated between phases. A voice that plays
//! a sample faster than its rate (pitched up) must also filter out what
//! would fold back, so there are tables for several cutoffs and a voice
//! picks the one for its speed: up to 4× the rate, beyond which the
//! highest table is used and some folding is heard. Cost per output frame:
//! 16 phase interpolations and 16 multiply-adds per channel. Linear and
//! 4-point Hermite are there as cheaper settings.

use std::sync::OnceLock;

pub const TAPS: usize = 16;
/// Taps before the frame being read (the rest are at and after it).
pub const BEFORE: usize = 7;
const PHASES: usize = 256;
/// The speeds the tables are made for; a voice uses the first at or above
/// its own.
const SPEEDS: [f32; 8] = [1.0, 1.19, 1.41, 1.68, 2.0, 2.52, 3.17, 4.0];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Quality {
    Linear,
    Hermite,
    Sinc,
}

pub struct Tables {
    /// Per speed, `(PHASES + 1) * TAPS` coefficients.
    tables: Vec<Box<[f32]>>,
}

pub fn tables() -> &'static Tables {
    static TABLES: OnceLock<Tables> = OnceLock::new();
    TABLES.get_or_init(Tables::new)
}

fn bessel_i0(x: f64) -> f64 {
    let mut sum = 1.0;
    let mut term = 1.0;
    let half = x / 2.0;
    for k in 1..50 {
        term *= (half / k as f64) * (half / k as f64);
        sum += term;
        if term < 1e-12 * sum {
            break;
        }
    }
    sum
}

impl Tables {
    fn new() -> Tables {
        let beta = 8.0;
        let half = TAPS as f64 / 2.0;
        let tables = SPEEDS
            .iter()
            .map(|&speed| {
                // A little under the source's Nyquist, lowered by the speed.
                let cutoff = 0.92 / speed as f64;
                let mut t = vec![0.0f32; (PHASES + 1) * TAPS];
                for phase in 0..=PHASES {
                    let frac = phase as f64 / PHASES as f64;
                    let mut row = [0.0f64; TAPS];
                    for (k, c) in row.iter_mut().enumerate() {
                        let x = k as f64 - BEFORE as f64 - frac;
                        let sinc = if x.abs() < 1e-9 {
                            1.0
                        } else {
                            (std::f64::consts::PI * cutoff * x).sin() / (std::f64::consts::PI * cutoff * x)
                        };
                        let w = (x / half).clamp(-1.0, 1.0);
                        let window = bessel_i0(beta * (1.0 - w * w).sqrt()) / bessel_i0(beta);
                        *c = cutoff * sinc * window;
                    }
                    let sum: f64 = row.iter().sum();
                    for k in 0..TAPS {
                        t[phase * TAPS + k] = (row[k] / sum) as f32;
                    }
                }
                t.into_boxed_slice()
            })
            .collect();
        Tables { tables }
    }

    /// The table for a voice playing at `speed` times the sample's rate.
    pub fn for_speed(&self, speed: f64) -> &[f32] {
        let i = SPEEDS.iter().position(|&s| s as f64 >= speed - 1e-6).unwrap_or(SPEEDS.len() - 1);
        &self.tables[i]
    }
}

/// The 16 coefficients for a position `frac` (0..1) after a frame.
#[inline(always)]
pub fn coefficients(table: &[f32], frac: f32, out: &mut [f32; TAPS]) {
    let p = frac * PHASES as f32;
    let i = (p as usize).min(PHASES - 1);
    let t = p - i as f32;
    let a = &table[i * TAPS..i * TAPS + TAPS];
    let b = &table[(i + 1) * TAPS..(i + 1) * TAPS + TAPS];
    for k in 0..TAPS {
        out[k] = a[k] + (b[k] - a[k]) * t;
    }
}

#[inline(always)]
pub fn hermite(y0: f32, y1: f32, y2: f32, y3: f32, t: f32) -> f32 {
    let c1 = 0.5 * (y2 - y0);
    let c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3;
    let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2);
    ((c3 * t + c2) * t + c1) * t + y1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_phase_passes_a_constant() {
        for speed in [1.0, 2.0, 4.0] {
            let table = tables().for_speed(speed);
            let mut c = [0.0; TAPS];
            for frac in [0.0, 0.3, 0.5, 0.999] {
                coefficients(table, frac, &mut c);
                let sum: f32 = c.iter().sum();
                assert!((sum - 1.0).abs() < 1e-4, "{speed} {frac}: {sum}");
            }
        }
    }

    #[test]
    fn a_phase_of_zero_reads_the_frame_itself() {
        let mut c = [0.0; TAPS];
        coefficients(tables().for_speed(1.0), 0.0, &mut c);
        assert!(c[BEFORE] > 0.9, "{c:?}");
    }
}
