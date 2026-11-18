//! The roles the window paints itself (runtime/lua/paw/roles/widgets.lua):
//! a scene's role node is a rectangle the view laid out in cells and the
//! props that say what it shows; here it becomes a widget drawn in that
//! rectangle, crisp at any size. Gestures on it go back to the kernel as
//! any pointer event over a scene does (crate::scene): the view's hit
//! regions say what they mean, in both frontends. A meter bound to a
//! track's (`bind`, `meter:<id>`) moves with `scene.live`, with no new
//! scene.

use egui::{Align2, Color32, CornerRadius, Id, Painter, Pos2, Rect, Sense, Stroke, StrokeKind, Ui, pos2, vec2};
use paw_scene::{Kind, Node};
use serde_json::Value;

use crate::theme::{T_SMALL, alpha, hex, mono_medium, semi, th};
use crate::widgets;

/// The roles this window paints: it says so when it watches scenes, and
/// is sent them without their cells.
pub const KNOWN: &[&str] = &["label", "button", "switch", "knob", "fader", "meter", "chip"];

fn text(props: &Value, key: &str) -> String {
    props[key].as_str().unwrap_or("").to_string()
}

fn number(props: &Value, key: &str) -> f32 {
    props[key].as_f64().unwrap_or(0.0) as f32
}

/// A colour named by the palette (`tone`), else `or`.
fn tone(props: &Value, or: Color32) -> Color32 {
    props["tone"].as_str().and_then(|t| th().named(t)).unwrap_or(or)
}

/// How far up a meter a linear level reaches, from 0 to 1 over 60 dB, as
/// the terminal's meters have it (`paw.draw.level`).
fn level(peak: f32) -> f32 {
    ((20.0 * peak.max(1e-6).log10() + 60.0) / 60.0).clamp(0.0, 1.0)
}

/// The text of a role, in a font that fits its row.
fn font_for(rect: Rect, bold: bool) -> egui::FontId {
    let size = (rect.height() * 0.68).clamp(8.0, T_SMALL + 1.0);
    if bold { semi(size) } else { crate::theme::sans(size) }
}

/// Paint a role node over `rect` (points), on a scene whose cells are
/// `row` points high, with the live values the kernel last sent; `id` is
/// its own in the window. False for a role this window does not know.
pub fn paint(ui: &Ui, painter: &Painter, id: Id, node: &Node, rect: Rect, row: f32, live: &Value) -> bool {
    let Kind::Role { role, props } = &node.kind else { return false };
    let t = th();
    // What it is called, for whoever reads the window without seeing it.
    if let Some(name) = props["label"].as_str() {
        let response = ui.interact(rect, id, Sense::hover());
        widgets::name(&response, name);
    }
    let under = ui.rect_contains_pointer(rect);
    match role.as_str() {
        "label" => {
            let align = match props["align"].as_str() {
                Some("right") => Align2::RIGHT_CENTER,
                Some("center") => Align2::CENTER_CENTER,
                _ => Align2::LEFT_CENTER,
            };
            let at = match align {
                Align2::RIGHT_CENTER => rect.right_center(),
                Align2::CENTER_CENTER => rect.center(),
                _ => rect.left_center(),
            };
            let size = (rect.height() * 0.7).clamp(8.0, T_SMALL + 1.0);
            painter.text(at, align, text(props, "text"), mono_medium(size), tone(props, t.text_2));
        }
        "button" => {
            let face = if under { t.control_hover } else { t.control };
            let shape = rect.shrink2(vec2(0.0, 1.0));
            painter.rect_filled(shape, CornerRadius::same(3), if props["on"] == true { t.select } else { face });
            let colour = if props["on"] == true { t.surface } else if props["off"] == true { t.text_3 } else { t.text };
            let font = font_for(rect, false);
            let shown = widgets::elide(ui, text(props, "text").trim(), font.clone(), shape.width() - 8.0);
            painter.text(pos2(shape.left() + 4.0, shape.center().y), Align2::LEFT_CENTER, shown, font, colour);
        }
        "switch" => {
            let on = props["on"] == true;
            let lit = tone(props, t.select);
            let side = rect.width().min(rect.height()).max(4.0);
            let shape = Rect::from_center_size(rect.center(), vec2(rect.width().max(side) - 1.0, rect.height() - 2.0));
            let face = if on { lit } else if under { t.control_hover } else { t.control };
            painter.rect_filled(shape, CornerRadius::same(3), face);
            let letter = text(props, "letter");
            painter.text(shape.center(), Align2::CENTER_CENTER, letter, semi((rect.height() * 0.6).clamp(8.0, T_SMALL)), if on { t.on_hue } else { t.text_2 });
        }
        "knob" => {
            // A pan: a rail across, the middle marked, a bar from the middle
            // to where the sound sits and a thumb there.
            let value = number(props, "value").clamp(-1.0, 1.0);
            let y = rect.center().y;
            let (left, right) = (rect.left() + 3.0, rect.right() - 3.0);
            let middle = (left + right) / 2.0;
            let at = middle + value * (right - left) / 2.0;
            painter.hline(left..=right, y, Stroke::new(2.0, t.well));
            painter.vline(middle, (y - 3.0)..=(y + 3.0), Stroke::new(1.0, t.text_3));
            painter.hline(middle.min(at)..=middle.max(at), y, Stroke::new(2.0, t.select));
            painter.circle_filled(pos2(at, y), (rect.height() * 0.28).clamp(3.0, 6.0), if under { t.bright } else { t.thumb });
        }
        "fader" => fader(painter, rect, props, under, row),
        "meter" => meter(painter, rect, props, node.bind.as_deref(), live),
        "chip" => {
            let colour = props["color"].as_str().and_then(hex).unwrap_or(t.control);
            painter.rect_filled(rect, CornerRadius::ZERO, colour);
            let font = font_for(rect, true);
            let mut left = rect.left() + 4.0;
            if let Some(n) = props["number"].as_i64() {
                let number = n.to_string();
                painter.text(pos2(left, rect.center().y), Align2::LEFT_CENTER, &number, font.clone(), alpha(t.on_hue, 0.6));
                left += widgets::text_width(ui, &number, font.clone()) + 4.0;
            }
            let shown = widgets::elide(ui, &text(props, "text"), font.clone(), rect.right() - 4.0 - left);
            painter.text(pos2((left + rect.right() - 4.0) / 2.0, rect.center().y), Align2::CENTER_CENTER, shown, font, t.on_hue);
            if props["selected"] == true {
                painter.rect_stroke(rect, CornerRadius::ZERO, Stroke::new(1.0, Color32::WHITE), StrokeKind::Inside);
            }
        }
        _ => return false,
    }
    true
}

/// A fader: a rail down the middle, 0 dB marked, a cap with a line across
/// it where the level is, at the place the terminal's cap is for it.
fn fader(painter: &Painter, rect: Rect, props: &Value, under: bool, row: f32) {
    let t = th();
    let rows = (rect.height() / row.max(1.0)).round().max(1.0);
    let row_h = rect.height() / rows;
    // The middle of the row the cap is on, as a place along the travel.
    let y_of = |f: f32| rect.bottom() - row_h * (0.5 + f.clamp(0.0, 1.0) * (rows - 1.0));
    let x = rect.center().x;
    painter.vline(x, (rect.top() + row_h * 0.5)..=(rect.bottom() - row_h * 0.5), Stroke::new(3.0, t.well));
    if props.get("zero").is_some_and(Value::is_number) {
        let y = y_of(number(props, "zero"));
        painter.hline((rect.left() + 2.0)..=(rect.right() - 2.0), y, Stroke::new(1.0, t.text_3));
    }
    let y = y_of(number(props, "at"));
    let cap = Rect::from_center_size(pos2(x, y), vec2(rect.width() - 2.0, (row_h * 0.9).clamp(8.0, 16.0)));
    let face = if props["selected"] == true || under { t.bright } else { t.thumb };
    painter.rect_filled(cap, CornerRadius::same(2), face);
    painter.hline((cap.left() + 2.0)..=(cap.right() - 2.0), y, Stroke::new(1.0, t.surface));
}

/// Level meters, a column each, lit from the bottom in the meter colours
/// by where they reach, with the loudest of late a line: the live levels
/// when the meter is bound to a track's, else those it was drawn with.
fn meter(painter: &Painter, rect: Rect, props: &Value, bind: Option<&str>, live: &Value) {
    let t = th();
    let bound = bind.and_then(|b| b.strip_prefix("meter:")).map(|track| &live["meters"][track]).filter(|v| v.is_array());
    let levels = bound.unwrap_or(&props["levels"]);
    let mut levels: Vec<f32> = levels.as_array().map(|l| l.iter().map(|v| v.as_f64().unwrap_or(0.0) as f32).collect()).unwrap_or_default();
    if levels.is_empty() {
        // Bound, before the first live values: both sides, silent.
        levels = vec![0.0; 2];
    }
    let n = levels.len().max(1) as f32;
    let gap = 1.0;
    let w = ((rect.width() - gap * (n - 1.0)) / n).max(1.0);
    let hold = number(props, "hold");
    for (i, peak) in levels.iter().enumerate() {
        let column = Rect::from_min_size(pos2(rect.left() + i as f32 * (w + gap), rect.top()), vec2(w, rect.height()));
        painter.rect_filled(column, CornerRadius::ZERO, t.meter_well);
        let top = column.bottom() - column.height() * level(*peak);
        // In bands by level: to -18 dB, to -9, to -3, to 0.
        let mut from = column.bottom();
        for (db, colour) in [(-18.0f32, t.meter_low), (-9.0, t.meter_mid), (-3.0, t.meter_high), (0.0, t.meter_hot)] {
            let to = (column.bottom() - column.height() * (db + 60.0) / 60.0).max(top);
            if to < from {
                painter.rect_filled(Rect::from_min_max(pos2(column.left(), to), pos2(column.right(), from)), CornerRadius::ZERO, colour);
            }
            from = to;
            if to <= top {
                break;
            }
        }
        if *peak >= 1.0 {
            painter.rect_filled(Rect::from_min_size(column.min, vec2(w, 3.0)), CornerRadius::ZERO, t.meter_clip);
        }
        if hold > 1e-5 {
            let y = column.bottom() - column.height() * level(hold);
            painter.hline(column.x_range(), y, Stroke::new(1.0, if hold >= 1.0 { t.meter_clip } else { t.text_2 }));
        }
    }
}

/// Where a role node is in points, for a scene drawn from `at` with cells
/// `cell` big: its rectangle in units (left, top, right, bottom).
pub fn rect_of(units: [f64; 4], at: Pos2, cell: (f32, f32)) -> Rect {
    Rect::from_min_max(
        pos2(at.x + units[0] as f32 * cell.0, at.y + units[1] as f32 * cell.1),
        pos2(at.x + units[2] as f32 * cell.0, at.y + units[3] as f32 * cell.1),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_meter_reaches_as_far_as_the_terminals_does() {
        assert_eq!(level(1.0), 1.0);
        assert!((level(0.001) - 0.0).abs() < 1e-6, "-60 dB is the bottom");
        assert!((level(0.1) - 2.0 / 3.0).abs() < 1e-4, "-20 dB two thirds up");
    }
}
