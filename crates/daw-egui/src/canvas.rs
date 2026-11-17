//! Views in windows of their own.
use crate::app::View;

#[derive(Default)]
pub struct Canvases {}

impl View {
    pub fn canvas_windows(&mut self, _ctx: &egui::Context) {}
}
