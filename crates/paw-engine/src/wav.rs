//! WAV output, stereo or mono.

use std::fs::File;
use std::io::BufWriter;
use std::path::Path;

use anyhow::Result;

pub struct Writer {
    inner: hound::WavWriter<BufWriter<File>>,
    /// Full scale for integer formats, or `None` when writing floats.
    scale: Option<f32>,
}

impl Writer {
    /// `bits` is 16 or 24 for integer PCM, or 32 for float.
    pub fn create(path: &Path, sample_rate: u32, bits: u16, float: bool) -> Result<Self> {
        Self::with_channels(path, sample_rate, bits, float, 2)
    }

    /// As [`create`](Self::create), with one channel or two.
    pub fn with_channels(
        path: &Path,
        sample_rate: u32,
        bits: u16,
        float: bool,
        channels: u16,
    ) -> Result<Self> {
        let sample_format = if float {
            hound::SampleFormat::Float
        } else {
            hound::SampleFormat::Int
        };
        let spec = hound::WavSpec {
            channels,
            sample_rate,
            bits_per_sample: bits,
            sample_format,
        };
        let scale = (!float).then(|| ((1i64 << (bits - 1)) - 1) as f32);
        Ok(Self {
            inner: hound::WavWriter::create(path, spec)?,
            scale,
        })
    }

    /// Write one sample. In stereo, samples alternate left, right.
    pub fn write(&mut self, sample: f32) -> Result<()> {
        match self.scale {
            Some(scale) => self
                .inner
                .write_sample((sample.clamp(-1.0, 1.0) * scale) as i32)?,
            None => self.inner.write_sample(sample)?,
        }
        Ok(())
    }

    pub fn finish(self) -> Result<()> {
        Ok(self.inner.finalize()?)
    }
}
