//! Views in windows of their own: an extension's editor drawn by its Lua
//! in the kernel as rectangles, text, lines and music glyphs, or any view
//! drawn in cells as the terminal draws it; shown from its scene
//! (crate::scene), with the pointer and the keyboard passed back to it. See
//! `paw.canvas`.

use std::collections::HashSet;

use egui::{CornerRadius, Id, Rect, Stroke, ViewportBuilder, ViewportId, pos2, vec2};
use serde_json::{Value, json};

use crate::app::View;
use crate::model::{flag, number, rows, text};
use crate::theme::{T_MICRO, T_SMALL, mode_colour, sans, semi, th};
use crate::widgets::{self, Look};

/// The view is drawn under a title, inset from the edges, over a status line.
const HEADING_H: f32 = 28.0;
const STATUS_H: f32 = 22.0;
const PAD: f32 = 6.0;

#[derive(Default)]
pub struct Canvases {
    /// The views shown in windows of their own, by name.
    open: HashSet<String>,
}

impl View {
    /// Open and close the windows the kernel lists, and draw each.
    pub fn canvas_windows(&mut self, ctx: &egui::Context) {
        let windows: Vec<Value> = rows(&self.s.modal["windows"]).to_vec();
        let names: Vec<String> = windows.iter().map(|w| text(&w["name"])).collect();
        let gone = self.canvases.open.iter().any(|n| !names.contains(n));
        self.canvases.open.retain(|name| names.contains(name));
        if gone {
            // The keyboard comes back to the main window.
            ctx.send_viewport_cmd_to(ViewportId::ROOT, egui::ViewportCommand::Focus);
        }
        let main = ctx.input(|i| i.viewport().outer_rect);
        for w in windows {
            let name = text(&w["name"]);
            let cells = flag(&w["cells"]);
            let size = vec2(number(&w["width"]) + 2.0 * PAD, number(&w["height"]) + HEADING_H + STATUS_H + PAD * 2.0);
            let mut builder = ViewportBuilder::default().with_title(text(&w["title"])).with_min_inner_size([480.0, 280.0]);
            if self.canvases.open.insert(name.clone()) {
                builder = builder.with_inner_size(size);
                // Over the middle of the main window.
                if let Some(main) = main {
                    builder = builder.with_position(main.center() - size / 2.0);
                }
            }
            let id = ViewportId::from_hash_of(("canvas", name.as_str()));
            let title = text(&w["title"]);
            ctx.show_viewport_immediate(id, builder, |ctx, _| {
                egui::CentralPanel::default().frame(egui::Frame::NONE).show(ctx, |ui| self.canvas_window(ui, &name, &title, cells));
                if ctx.input(|i| i.viewport().close_requested()) {
                    // Closing the window puts the view back in the main
                    // window, as `Ctrl-w d` does.
                    self.eval("paw.canvas.dock(...)", json!([name]));
                }
            });
        }
    }

    fn canvas_window(&mut self, ui: &mut egui::Ui, name: &str, title: &str, cells: bool) {
        let t = th();
        let full = ui.max_rect();
        ui.painter().rect_filled(full, CornerRadius::ZERO, t.surface);
        // A view drawn in cells draws a title row of its own, hidden under
        // the window's title; it needs no inset above.
        let (_, cell_h) = self.scenes.cell();
        let under = if cells { cell_h } else { 0.0 };
        let pad_top = if cells { 0.0 } else { PAD };
        let view = Rect::from_min_max(pos2(full.left() + PAD, full.top() + HEADING_H + pad_top - under), pos2(full.right() - PAD, full.bottom() - STATUS_H - PAD));
        let shown = Rect::from_min_max(pos2(view.left(), full.top() + HEADING_H), view.max);
        self.scene(ui, &format!("view:{name}"), view, shown);
        // Keys typed here are the view's.
        let events = ui.input(|i| i.events.clone());
        for keys in self.keys.notations(&events) {
            self.eval("paw.canvas.key(...)", json!([name, keys]));
            self.repaint = true;
        }
        // The title, over the top of the view, with a way back as a pane.
        let heading = Rect::from_min_size(full.min, vec2(full.width(), HEADING_H));
        ui.painter().rect_filled(heading, CornerRadius::ZERO, t.panel_sel);
        widgets::text_in(ui, pos2(heading.left() + 10.0, heading.center().y), title, semi(T_SMALL), t.text, heading.width() - 100.0);
        let dock = Rect::from_min_size(pos2(heading.right() - 70.0, heading.top() + 4.0), vec2(64.0, 20.0));
        let response = widgets::button(ui, dock, Id::unique(("dock", name)), None, "Dock", Look::quiet());
        widgets::hint_on(&response, "back into the main window, as a pane (Ctrl-w d)");
        if response.clicked() {
            self.eval("paw.canvas.dock(...)", json!([name]));
        }
        ui.painter().hline(heading.x_range(), heading.bottom() - 0.5, Stroke::new(1.0, t.divider));
        // The status line: the main window's mode, then the prompt being
        // typed, else the last message, else the view's keys.
        let status = Rect::from_min_max(pos2(full.left(), full.bottom() - STATUS_H), full.max);
        ui.painter().rect_filled(status, CornerRadius::ZERO, t.panel);
        ui.painter().hline(status.x_range(), status.top() + 0.5, Stroke::new(1.0, t.divider));
        let modal = &self.s.modal;
        let mode = text(&modal["mode"]);
        let mode_name = match modal["focused"].as_str() {
            Some(view) if !view.is_empty() => format!("{}·{view}", text(&modal["name"])),
            _ => text(&modal["name"]),
        };
        let w = widgets::text_width(ui, &mode_name, semi(T_MICRO)) + 12.0;
        let chip = Rect::from_min_size(pos2(status.left() + 4.0, status.center().y - 8.0), vec2(w, 16.0));
        ui.painter().rect_filled(chip, CornerRadius::same(3), mode_colour(&mode));
        ui.painter().text(chip.center(), egui::Align2::CENTER_CENTER, &mode_name, semi(T_MICRO), t.on_hue);
        let prompt = &modal["prompt"];
        let (line, colour) = if prompt.is_object() && prompt["anchored"] != true {
            (format!("{}{}▏{}", text(&prompt["prompt"]), text(&prompt["before"]), text(&prompt["after"])), t.text)
        } else if let Some((message, level)) = self.status_message() {
            (message, match level { 2 => t.error, 1 => t.warn, _ => t.text })
        } else {
            let keys: Vec<String> = rows(&modal["keys"]).iter().map(|k| format!("{} {}", text(&k["key"]), text(&k["desc"]))).collect();
            (keys.join("   "), t.text_2)
        };
        widgets::text_in(ui, pos2(chip.right() + 10.0, status.center().y), &line, sans(T_SMALL), colour, status.right() - chip.right() - 20.0);
        self.menu_popup(ui);
    }
}
