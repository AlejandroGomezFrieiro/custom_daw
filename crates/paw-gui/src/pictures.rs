//! The pictures inside clips: a MIDI clip's notes as a small piano roll, an
//! audio clip's waveform. Each is white on clear, tinted when drawn, and
//! made again only when the clip's key (its notes' stamp, its waveform's)
//! says what it shows has changed.

use std::collections::HashMap;

use egui::{Color32, ColorImage, TextureHandle, TextureOptions};

/// A picture to tint: as opaque at each place as `alpha` says.
fn shade(width: usize, height: usize, alpha: impl Fn(usize, usize) -> u8) -> ColorImage {
    let mut pixels = Vec::with_capacity(width * height);
    for y in 0..height {
        for x in 0..width {
            let a = alpha(x, y);
            pixels.push(Color32::from_rgba_premultiplied(a, a, a, a));
        }
    }
    ColorImage { size: [width, height], source_size: egui::vec2(width as f32, height as f32), pixels }
}

/// A clip's notes as a small piano roll: `flat` is start, length and pitch
/// for each note, and the picture covers the clip's `length` beats.
pub fn notes_picture(flat: &[f32], length: f32) -> Option<ColorImage> {
    const HEIGHT: usize = 24;
    let notes: Vec<(f32, f32, f32)> = flat.chunks_exact(3).map(|n| (n[0], n[1], n[2])).collect();
    if notes.is_empty() || length <= 0.0 {
        return None;
    }
    let width = ((length * 12.0) as usize).clamp(16, 2048);
    let low = notes.iter().map(|n| n.2).fold(f32::MAX, f32::min);
    let high = notes.iter().map(|n| n.2).fold(f32::MIN, f32::max);
    // A few pitches fill the height; many share it, a row or two each.
    let span = (high - low + 1.0).max(6.0);
    let thick = ((HEIGHT as f32 / span).floor() as usize).clamp(2, 4);
    let mut lit = vec![false; width * HEIGHT];
    for (start, len, pitch) in notes {
        let x0 = ((start / length * width as f32) as usize).min(width - 1);
        let x1 = (((start + len) / length * width as f32).ceil() as usize).clamp(x0 + 1, width);
        // A hair off the end, so that notes that follow each other stay apart.
        let x1 = if x1 - x0 > 2 { x1 - 1 } else { x1 };
        let centre = (pitch - low + 0.5 + (span - (high - low + 1.0)) / 2.0) / span;
        let y0 = (((1.0 - centre) * HEIGHT as f32) as usize).min(HEIGHT - thick);
        for y in y0..y0 + thick {
            lit[y * width + x0..y * width + x1].fill(true);
        }
    }
    Some(shade(width, HEIGHT, |x, y| if lit[y * width + x] { 255 } else { 0 }))
}

/// An audio clip's waveform, a column for each (min, max, rms) of `peaks`:
/// how far the wave reaches each way, drawn lightly, and inside it how loud
/// it is, drawn solid, as a waveform looks in an audio editor.
pub fn wave_picture(peaks: &[f32]) -> Option<ColorImage> {
    const HEIGHT: usize = 64;
    let columns: Vec<(f32, f32, f32)> = peaks
        .chunks_exact(3)
        .map(|p| (p[0].clamp(-1.0, 1.0), p[1].clamp(-1.0, 1.0), p[2].clamp(0.0, 1.0)))
        .collect();
    if columns.is_empty() {
        return None;
    }
    let half = HEIGHT as f32 / 2.0;
    Some(shade(columns.len(), HEIGHT, |x, y| {
        let (low, high, rms) = columns[x];
        // Up from the middle is positive.
        let at = (half - (y as f32 + 0.5)) / half;
        if at.abs() <= rms.max(0.5 / half) {
            255
        } else if at <= high && at >= low {
            130
        } else {
            0
        }
    }))
}

/// `picture` with a notch at each of `at` (fractions of its width): where
/// a looped clip repeats, marked solid at the top and bottom and dotted
/// between, as REAPER and Ableton mark them.
pub fn notched(mut picture: ColorImage, at: &[f32]) -> ColorImage {
    let [width, height] = picture.size;
    if at.is_empty() || width < 2 {
        return picture;
    }
    let tick = (height / 6).max(2);
    for f in at {
        // Two columns, so that drawing the picture narrower keeps one.
        let x = ((f * width as f32).round() as usize).clamp(1, width - 1);
        for y in 0..height {
            let a = if y < tick || y >= height - tick {
                255
            } else if (y / 2) % 2 == 0 {
                150
            } else {
                continue;
            };
            picture.pixels[y * width + x - 1] = Color32::from_rgba_premultiplied(a, a, a, a);
            picture.pixels[y * width + x] = Color32::from_rgba_premultiplied(a, a, a, a);
        }
    }
    picture
}

/// How many points to ask for to draw a waveform `pixels` wide: the next
/// power of two, so that a small change of zoom does not fetch it again.
pub fn wave_points(pixels: f32) -> usize {
    (pixels.max(1.0) as usize).next_power_of_two().clamp(64, 4096)
}

/// The pictures made, by what they are of (a clip, or a clip's take), with
/// the key they were made for.
#[derive(Default)]
pub struct Pictures {
    made: HashMap<(i64, usize), (String, Option<TextureHandle>)>,
}

impl Pictures {
    /// The picture of `of`, made by `make` when `key` is not what it was
    /// made for.
    pub fn get(
        &mut self,
        ctx: &egui::Context,
        of: (i64, usize),
        key: &str,
        make: impl FnOnce() -> Option<ColorImage>,
    ) -> Option<TextureHandle> {
        if let Some((known, texture)) = self.made.get(&of)
            && known == key
        {
            return texture.clone();
        }
        let texture = make().map(|image| ctx.load_texture(format!("clip-{}-{}", of.0, of.1), image, TextureOptions::NEAREST));
        self.made.insert(of, (key.to_string(), texture.clone()));
        texture
    }

    /// Let go of the pictures of clips no longer there.
    pub fn keep(&mut self, alive: impl Fn(i64) -> bool) {
        self.made.retain(|(id, _), _| alive(*id));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notes_and_waves_are_drawn_and_repeats_notched() {
        let notes = notes_picture(&[0.0, 1.0, 60.0, 2.0, 1.0, 64.0], 4.0).unwrap();
        assert_eq!(notes.size, [48, 24], "twelve columns a beat");
        assert!(notes.pixels.iter().any(|p| p.a() == 255), "notes are lit");
        assert!(notes_picture(&[], 4.0).is_none(), "no notes, no picture");
        let wave = wave_picture(&[-0.5, 0.5, 0.25, -1.0, 1.0, 0.0]).unwrap();
        assert_eq!(wave.size, [2, 64]);
        assert_eq!(wave.pixels[32 * 2].a(), 255, "the body in the middle");
        assert_eq!(wave.pixels[2].a(), 0, "nothing past the reach");
        let notched = notched(wave_picture(&[0.0; 30]).unwrap(), &[0.5]);
        assert_eq!(notched.pixels[5].a(), 255, "a notch at the top");
        assert_eq!(wave_points(100.0), 128);
    }
}
