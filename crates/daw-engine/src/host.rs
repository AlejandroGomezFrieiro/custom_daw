//! What the host does around every device: a wet/dry mix with the dry signal
//! delayed by the device's latency, an output gain, and a short crossfade
//! when the device is bypassed or switched on again.
//!
//! The mix and the gain are parameters of the device as far as the rest of
//! the program is concerned: they come after the device's own, so they are
//! set, automated and saved like any other. Everything here is allocated on
//! the main thread; the audio thread only reads and writes the buffers.

use crate::device::ParamInfo;
use crate::{Device, Io, ProcessCtx};

/// The longest latency the dry signal is held back to match, in frames.
pub const MAX_LATENCY: usize = 16384;

/// Seconds over which the mix moves to a new setting, bypass included.
const FADE: f32 = 0.005;

/// Keys of the host's parameters, after the device's own.
pub const WET: &str = "fx_wet";
pub const GAIN: &str = "fx_gain";

/// The host's parameters: the wet share in percent and the output gain.
pub fn params() -> [ParamInfo; 2] {
    let mut wet = ParamInfo::new("Wet", 0.0, 100.0, 100.0, "%");
    wet.key = WET.into();
    let mut gain = ParamInfo::new("Output", -24.0, 24.0, 0.0, "dB");
    gain.key = GAIN.into();
    [wet, gain]
}

pub struct HostPath {
    /// The position of the first host parameter in the device's list.
    pub base: u32,
    wet: f32,
    gain: f32,
    wet_now: f32,
    gain_now: f32,
    latency: usize,
    ring: [Box<[f32]>; 2],
    pos: usize,
    dry: [Box<[f32]>; 2],
    /// Set once a block has been processed: before that, a setting is taken
    /// at once rather than faded to.
    started: bool,
}

impl HostPath {
    /// Made on the main thread, for a device with `base` parameters of its
    /// own, processing blocks of at most `max_block` frames.
    pub fn new(base: u32, latency: u32, max_block: usize) -> Self {
        let ring = || vec![0.0f32; MAX_LATENCY + 1].into_boxed_slice();
        let dry = || vec![0.0f32; max_block].into_boxed_slice();
        Self {
            base,
            wet: 1.0,
            gain: 1.0,
            wet_now: 1.0,
            gain_now: 1.0,
            latency: (latency as usize).min(MAX_LATENCY),
            ring: [ring(), ring()],
            pos: 0,
            dry: [dry(), dry()],
            started: false,
        }
    }

    /// Take a value for one of the host's parameters, by its position after
    /// the device's own. Returns false for a position that is not one.
    pub fn set_param(&mut self, index: u32, value: f32) -> bool {
        match index.checked_sub(self.base) {
            Some(0) => self.wet = (value / 100.0).clamp(0.0, 1.0),
            Some(1) => self.gain = crate::db_to_gain(value.clamp(-24.0, 24.0) as f64),
            _ => return false,
        }
        true
    }

    pub fn set_latency(&mut self, frames: u32) {
        self.latency = (frames as usize).min(MAX_LATENCY);
    }

    /// Run the device on `io` with the mix, the gain and the bypass applied.
    /// False if the device panicked (see `guard`): then the buffers are
    /// not to be trusted.
    pub fn process(
        &mut self,
        device: &mut dyn Device,
        bypass: bool,
        ctx: &ProcessCtx,
        io: &mut Io,
    ) -> bool {
        let n = io.left.len().min(self.dry[0].len());
        // The input goes through the delay line always, so that the dry
        // signal is ready whenever the mix moves.
        // A bypassed device holds nothing back: the track's lining up
        // leaves it out (see the schedule).
        let delay = if bypass { 0 } else { self.latency };
        let len = self.ring[0].len();
        for (ch, input) in [&*io.left, &*io.right].into_iter().enumerate() {
            let (ring, dry) = (&mut self.ring[ch], &mut self.dry[ch]);
            for i in 0..n {
                let at = (self.pos + i) % len;
                ring[at] = input[i];
                dry[i] = ring[(at + len - delay) % len];
            }
        }
        self.pos = (self.pos + n) % len;

        let target = if bypass { 0.0 } else { self.wet };
        if !self.started {
            self.started = true;
            self.wet_now = target;
            self.gain_now = self.gain;
        }
        if self.wet_now == 0.0 && target == 0.0 {
            // Off, and faded out: only the dry signal.
            io.left[..n].copy_from_slice(&self.dry[0][..n]);
            io.right[..n].copy_from_slice(&self.dry[1][..n]);
            return true;
        }
        if !crate::guard::process(device, ctx, io) {
            return false;
        }
        if self.wet_now == 1.0 && target == 1.0 && self.gain_now == 1.0 && self.gain == 1.0 {
            return true;
        }
        let step = 1.0 / (FADE * ctx.sample_rate).max(1.0);
        let gain_step = (self.gain - self.gain_now) / n.max(1) as f32;
        let (mut wet, mut gain) = (self.wet_now, self.gain_now);
        for i in 0..n {
            wet = if wet < target {
                (wet + step).min(target)
            } else {
                (wet - step).max(target)
            };
            gain += gain_step;
            io.left[i] = self.dry[0][i] * (1.0 - wet) + io.left[i] * wet * gain;
            io.right[i] = self.dry[1][i] * (1.0 - wet) + io.right[i] * wet * gain;
        }
        self.wet_now = wet;
        self.gain_now = self.gain;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::EventBuf;

    /// Turns its input upside down, and holds it back `delay` frames.
    struct Invert {
        delay: Vec<f32>,
    }

    impl Device for Invert {
        fn process(&mut self, _: &ProcessCtx, io: &mut Io) {
            for buf in [&mut *io.left, &mut *io.right] {
                for s in buf.iter_mut() {
                    self.delay.push(-*s);
                    *s = self.delay.remove(0);
                }
            }
        }
        fn set_param(&mut self, _: u32, _: f32) {}
    }

    fn ctx() -> ProcessCtx {
        ProcessCtx {
            sample_rate: 48000.0,
            tempo: 120.0,
            sig_num: 4,
            sig_den: 4,
            playing: true,
            position: 0.0,
            seconds: 0.0,
            bar: 0,
            bar_start: 0.0,
        }
    }

    fn sine(i: usize) -> f32 {
        0.5 * (i as f32 * 2.0 * std::f32::consts::PI * 440.0 / 48000.0).sin()
    }

    /// Run `blocks` blocks of a sine through the path; `each` sets it up
    /// before each block. Returns the left channel.
    fn run(
        path: &mut HostPath,
        device: &mut Invert,
        blocks: usize,
        mut each: impl FnMut(usize, &mut HostPath) -> bool,
    ) -> Vec<f32> {
        let mut out = Vec::new();
        let mut events = EventBuf::with_capacity(16);
        for b in 0..blocks {
            let bypass = each(b, path);
            let mut left: Vec<f32> = (0..128).map(|i| sine(b * 128 + i)).collect();
            let mut right = left.clone();
            let mut io = Io {
                left: &mut left,
                right: &mut right,
                events: &mut events,
                sidechain: None,
            };
            path.process(device, bypass, &ctx(), &mut io);
            out.extend_from_slice(&left);
        }
        out
    }

    #[test]
    fn nothing_wet_is_the_input_exactly() {
        let mut path = HostPath::new(0, 0, 128);
        path.set_param(0, 0.0);
        let mut device = Invert {
            delay: vec![0.0; 1],
        };
        // Let the mix settle, then compare.
        let out = run(&mut path, &mut device, 20, |_, _| false);
        for (i, s) in out.iter().enumerate().skip(128 * 4) {
            assert_eq!(*s, sine(i), "frame {i}");
        }
    }

    #[test]
    fn all_wet_is_the_device_exactly() {
        let mut path = HostPath::new(0, 1, 128);
        let mut device = Invert {
            delay: vec![0.0; 1],
        };
        let out = run(&mut path, &mut device, 4, |_, _| false);
        for (i, s) in out.iter().enumerate().skip(1) {
            assert_eq!(*s, -sine(i - 1), "frame {i}");
        }
    }

    #[test]
    fn the_dry_signal_waits_for_the_device() {
        // Half and half of a device that delays by 30 frames and inverts:
        // with the dry signal held back as long, the two cancel.
        let mut path = HostPath::new(0, 30, 128);
        path.set_param(0, 50.0);
        let mut device = Invert {
            delay: vec![0.0; 30],
        };
        let out = run(&mut path, &mut device, 20, |_, _| false);
        for s in out.iter().skip(128 * 4) {
            assert!(s.abs() < 1e-6, "left over {s}");
        }
    }

    #[test]
    fn bypass_fades_instead_of_clicking() {
        let mut path = HostPath::new(0, 0, 128);
        let mut device = Invert {
            delay: vec![0.0; 0],
        };
        device.delay.clear();
        let out = run(&mut path, &mut device, 40, |b, _| (10..25).contains(&b));
        let step = out
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0, f32::max);
        // A sine of 0.5 at 440 Hz moves at most 0.029 a frame; a jump from
        // the inverted signal to the plain one would be up to 1.
        assert!(step < 0.04, "a step of {step}");
    }

    #[test]
    fn host_parameters_come_after_the_device_s_own() {
        let mut path = HostPath::new(3, 0, 128);
        assert!(!path.set_param(2, 50.0));
        assert!(path.set_param(3, 50.0));
        assert!(path.set_param(4, -6.0));
        assert!(!path.set_param(5, 0.0));
    }
}
