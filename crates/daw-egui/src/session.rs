//! The session view.
use egui::{Pos2, Rect, Ui};
use serde_json::Value;

use crate::app::View;

#[derive(Default)]
pub struct Session {}

impl Session {
    pub fn tick(&mut self, _state: &Value) {}
    pub fn slot_at(&self, _pos: Pos2) -> Option<(i64, i64)> {
        None
    }
}

impl View {
    pub fn draw_session(&mut self, _ui: &mut Ui, _rect: Rect) {}
}
