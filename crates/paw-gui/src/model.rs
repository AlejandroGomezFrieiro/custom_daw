//! What the kernel says to draw (`paw.frontend.state`), read into plain
//! data, and the small sums the drawing makes on it: levels on a fader's
//! travel, decibels as words.

use egui::Color32;
use serde_json::Value;

use crate::theme::colour;

pub fn text(value: &Value) -> String {
    value.as_str().unwrap_or_default().to_string()
}

pub fn number(value: &Value) -> f32 {
    value.as_f64().unwrap_or(0.0) as f32
}

pub fn int(value: &Value) -> i64 {
    value.as_i64().or_else(|| value.as_f64().map(|v| v as i64)).unwrap_or(0)
}

pub fn flag(value: &Value) -> bool {
    value.as_bool().unwrap_or(false)
}

pub fn rows(value: &Value) -> &[Value] {
    value.as_array().map(Vec::as_slice).unwrap_or(&[])
}

/// A number of decibels as the window writes them, with a true minus sign.
pub fn decibels(db: f32) -> String {
    if db <= -60.0 {
        return "\u{2212}inf".into();
    }
    let text = format!("{:.1}", if db.abs() < 0.05 { 0.0 } else { db });
    text.replacen('-', "\u{2212}", 1)
}

/// A track, as the panels beside the timeline name it.
#[derive(Clone, Debug)]
pub struct Track {
    pub id: i64,
    pub name: String,
    pub color: Color32,
    pub master: bool,
    /// The lanes it shows as rows of their own under it, by id.
    pub lane_rows: Vec<i64>,
}

pub fn tracks(list: &Value) -> Vec<Track> {
    rows(list)
        .iter()
        .map(|t| Track {
            id: int(&t["id"]),
            name: text(&t["name"]),
            color: colour(&t["color"]),
            master: flag(&t["master"]),
            lane_rows: rows(&t["lane_rows"]).iter().filter_map(Value::as_i64).collect(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn decibels_are_written_with_a_minus_sign() {
        assert_eq!(decibels(-4.0), "\u{2212}4.0");
        assert_eq!(decibels(-0.01), "0.0");
        assert_eq!(decibels(3.5), "3.5");
        assert_eq!(decibels(-90.0), "\u{2212}inf");
    }

    #[test]
    fn a_track_says_the_lanes_it_shows_as_rows() {
        let tracks = tracks(&json!([{ "id": 1, "name": "A", "lane_rows": [7] }, { "id": 0, "name": "Master", "master": true }]));
        assert_eq!(tracks[0].lane_rows, [7]);
        assert!(tracks[1].master && tracks[1].lane_rows.is_empty());
    }
}
