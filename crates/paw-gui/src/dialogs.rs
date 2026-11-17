//! The window's dialogs: the question about unsaved changes, and the render
//! dialog. And how the desktop's file dialogs are asked for.

use std::path::Path;
use std::time::Instant;

use egui::{Align2, Color32, CornerRadius, Id, Order, Rect, Sense, Stroke, StrokeKind, Ui, pos2, vec2};
use serde_json::{Value, json};

use crate::app::{Purpose, View};
use crate::model::{rows, text};
use crate::portal;
use crate::theme::{T_BASE, T_SMALL, T_TITLE, medium, sans, semi, th};
use crate::widgets::{self, Look};

/// The layout last kept, the one seen now, and since when.
pub struct LayoutKeep {
    pub done: Option<Value>,
    pub seen: Option<Value>,
    pub since: Instant,
}

impl Default for LayoutKeep {
    fn default() -> Self {
        LayoutKeep { done: None, seen: None, since: Instant::now() }
    }
}

/// What the render dialog holds.
#[derive(Clone)]
pub struct Render {
    pub path: String,
    pub ranges: Vec<(String, String)>,
    pub range: usize,
    pub format: String,
    pub bits: i64,
    pub quality: String,
    pub tail: String,
    pub normalize: bool,
    pub dither: bool,
    pub mono: bool,
    pub stems: bool,
    pub tags_open: bool,
    /// Title, artist, album, track, year, genre, comment, cover.
    pub tags: [String; 8],
    pub lossy: [bool; 3],
}

const TAGS: [&str; 8] = ["title", "artist", "album", "track", "year", "genre", "comment", "cover"];

#[derive(Default)]
pub struct Dialogs {
    /// Leaving a project with changes: its name, and what was asked for.
    pub closing: Option<(String, String)>,
    pub render: Option<Render>,
    /// The window was told to close and is going.
    pub quitting: bool,
    pub layout: LayoutKeep,
    /// What the render dialog last chose, kept for the next time.
    kept: Option<Render>,
}

impl Dialogs {
    pub fn open(&self) -> bool {
        self.closing.is_some() || self.render.is_some()
    }

    pub fn render_path_chosen(&mut self, path: String) {
        if let Some(r) = &mut self.render {
            r.path = path;
        }
    }

    pub fn render_range(&mut self, at: usize) {
        if let Some(r) = &mut self.render {
            r.range = at;
        }
    }
}

/// The desktop's dialog for `purpose`, starting where `info` (from the
/// kernel's `paw.frontend.dialog_info`) says, or beside the render's path.
pub fn portal_ask(purpose: Purpose, info: &Value, render_path: &str, stems: bool) -> portal::Ask {
    let dir = text(&info["dir"]);
    let ask = |kind, title: &str, files: &str| portal::Ask {
        kind,
        title: title.to_string(),
        files: files.to_string(),
        dir: dir.clone(),
        name: String::new(),
    };
    match purpose {
        Purpose::Open => ask(portal::Kind::Open, "Open", "open"),
        Purpose::Import => ask(portal::Kind::Open, "Import a sound or MIDI file", "sound"),
        Purpose::SaveAs => portal::Ask { name: text(&info["name"]), ..ask(portal::Kind::Save, "Save the project as", "project") },
        Purpose::Render => {
            let endings = info["render"]
                .as_array()
                .map_or("wav,flac".to_string(), |l| l.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(","));
            let path = Path::new(render_path);
            let beside = path.parent().filter(|d| d.is_dir());
            portal::Ask {
                dir: beside.map_or(dir.clone(), |d| d.to_string_lossy().to_string()),
                name: path.file_name().map_or(String::new(), |n| n.to_string_lossy().to_string()),
                ..ask(
                    portal::Kind::Save,
                    if stems { "Name the folder for the stems" } else { "Render to" },
                    &format!("render:{endings}"),
                )
            }
        }
    }
}

/// A dimmed backdrop over the window that takes the pointer, and a card in
/// its middle `width` wide; `draw` fills the card and says how tall it was.
fn card(ui: &Ui, id: &str, screen: Rect, width: f32, draw: impl FnOnce(&mut Ui, Rect) -> f32) -> bool {
    let ctx = ui.ctx().clone();
    let height_id = Id::unique((id, "height"));
    let height: f32 = ctx.data(|d| d.get_temp(height_id)).unwrap_or(200.0);
    let rect = Rect::from_center_size(screen.center(), vec2(width.min(screen.width() - 40.0), height));
    let mut clicked_out = false;
    // An area takes the pointer over what it has laid out: the whole of it.
    egui::Area::new(Id::unique((id, "backdrop"))).order(Order::Middle).fixed_pos(screen.min).show(&ctx, |ui| {
        ui.expand_to_include_rect(screen);
        ui.painter().rect_filled(screen, CornerRadius::ZERO, Color32::from_black_alpha(0xaa));
        let response = ui.interact(screen, Id::unique((id, "backdrop-touch")), Sense::click());
        clicked_out = response.clicked() && !rect.contains(response.interact_pointer_pos().unwrap_or_default());
    });
    egui::Area::new(Id::unique((id, "card"))).order(Order::Foreground).fixed_pos(rect.min).show(&ctx, |ui| {
        ui.expand_to_include_rect(rect);
        let t = th();
        ui.painter().rect(rect, CornerRadius::same(6), t.card, Stroke::new(1.0, t.card_line), StrokeKind::Inside);
        ui.interact(rect, Id::unique((id, "card-touch")), Sense::click());
        let used = draw(ui, rect);
        ctx.data_mut(|d| d.insert_temp(height_id, used));
    });
    clicked_out
}

impl View {
    /// The dialog that is open, if one is.
    pub fn dialog(&mut self, ui: &mut Ui, screen: Rect) {
        if let Some((name, what)) = self.dialogs.closing.clone() {
            let mut choice = None;
            card(ui, "closing", screen, 460.0, |ui, rect| {
                let t = th();
                let mut y = rect.top() + 16.0;
                let title = format!("Save the changes to “{name}”?");
                let galley = ui.painter().layout(title, semi(T_TITLE), t.text, rect.width() - 32.0);
                ui.painter().galley(egui::pos2(rect.left() + 16.0, y), galley.clone(), t.text);
                y += galley.size().y + 12.0;
                let said = match what.as_str() {
                    "quit" => "They are lost if you quit without saving.",
                    "new" => "They are lost if you start a new project without saving.",
                    _ => "They are lost if you open another project without saving.",
                };
                let galley = ui.painter().layout(said.into(), sans(T_BASE), t.text_2, rect.width() - 32.0);
                ui.painter().galley(egui::pos2(rect.left() + 16.0, y), galley.clone(), t.text_2);
                y += galley.size().y + 12.0;
                let button = |ui: &mut Ui, x: f32, label: &str, look: Look| {
                    let w = widgets::button_width(ui, label, false, 28.0);
                    let r = Rect::from_min_size(pos2(x, y), vec2(w, 28.0));
                    (widgets::button(ui, r, Id::unique(("closing", label)), None, label, look).clicked(), w)
                };
                if button(ui, rect.left() + 16.0, "Don't save", Look::default()).0 {
                    choice = Some("discard");
                }
                let save_w = widgets::button_width(ui, "Save", false, 28.0);
                let save_x = rect.right() - 16.0 - save_w;
                if button(ui, save_x, "Save", Look::default().on(true)).0 {
                    choice = Some("save");
                }
                let cancel_w = widgets::button_width(ui, "Cancel", false, 28.0);
                if button(ui, save_x - 8.0 - cancel_w, "Cancel", Look::quiet()).0 {
                    choice = Some("cancel");
                }
                y + 28.0 + 16.0 - rect.top()
            });
            if ui.input(|i| i.key_pressed(egui::Key::Escape)) {
                choice = Some("cancel");
            }
            if let Some(choice) = choice {
                self.close_choice(choice);
            }
            return;
        }
        if self.dialogs.render.is_some() {
            self.render_dialog(ui, screen);
        }
    }

    /// The render dialog: what it starts from is asked for when it opens.
    pub fn open_render(&mut self) {
        let info = self.ask("return paw.frontend.render_dialog()", json!([]));
        if info.is_null() {
            return;
        }
        let has = |name: &str| info["formats"][name].as_bool().unwrap_or(false);
        let lossy = [has("mp3"), has("ogg"), has("opus")];
        // The lossy formats are offered when ffmpeg can make them.
        let kept = self.dialogs.kept.clone();
        let mut render = Render {
            path: text(&info["path"]),
            ranges: rows(&info["ranges"]).iter().map(|r| (text(&r["name"]), text(&r["label"]))).collect(),
            range: 0,
            format: "wav".into(),
            bits: 24,
            quality: "high".into(),
            tail: "1".into(),
            normalize: false,
            dither: false,
            mono: false,
            stems: false,
            tags_open: false,
            tags: TAGS.map(|name| text(&info["tags"][name])),
            lossy,
        };
        // The choices made the last time stay.
        if let Some(k) = kept {
            render = Render { format: k.format, bits: k.bits, quality: k.quality, tail: k.tail, normalize: k.normalize, dither: k.dither, mono: k.mono, stems: k.stems, tags_open: k.tags_open, ..render };
        }
        if !(matches!(render.format.as_str(), "wav" | "flac") || has(&render.format)) {
            render.format = "wav".into();
        }
        self.dialogs.render = Some(render);
    }

    fn start_render(&mut self) {
        let Some(r) = self.dialogs.render.take() else { return };
        self.dialogs.kept = Some(r.clone());
        let range = r.ranges.get(r.range).map_or("song".to_string(), |r| r.0.clone());
        let tail: f64 = r.tail.trim().parse().unwrap_or(1.0);
        let tags: serde_json::Map<String, Value> = TAGS.iter().zip(&r.tags).map(|(k, v)| (k.to_string(), json!(v))).collect();
        self.pass(
            "render",
            json!([{
                "path": r.path, "range": range, "format": r.format, "quality": r.quality,
                "bits": r.bits, "tail": tail.max(0.0), "normalize": if r.normalize { json!(-1.0) } else { Value::Null },
                "dither": r.dither, "mono": r.mono, "stems": r.stems, "tags": tags,
            }]),
        );
    }

    fn render_dialog(&mut self, ui: &mut Ui, screen: Rect) {
        let Some(mut r) = self.dialogs.render.take() else { return };
        let mut action = None;
        let mut range_at = None;
        let text_ids = &self.text_ids;
        let closed = card(ui, "render", screen, 580.0, |ui, rect| {
            let t = th();
            let left = rect.left() + 16.0;
            let label_w = 70.0;
            let mut y = rect.top() + 16.0;
            ui.painter().text(pos2(left, y), Align2::LEFT_TOP, "Render", semi(T_TITLE), t.text);
            y += 26.0;
            let label = |ui: &Ui, y: f32, text: &str| {
                ui.painter().text(pos2(left, y + 14.0), Align2::LEFT_CENTER, text, medium(T_BASE), t.text);
            };
            let field = |ui: &mut Ui, x: f32, y: f32, w: f32, value: &mut String, name: &str, hint: &str| -> egui::Response {
                let rect = Rect::from_min_size(pos2(x, y), vec2(w, 28.0));
                let edit = egui::TextEdit::singleline(value)
                    .id(Id::unique(("render-field", name)))
                    .hint_text(hint)
                    .font(sans(T_BASE))
                    .align(egui::Align2::LEFT_CENTER)
                    .margin(vec2(6.0, 4.0));
                text_ids.borrow_mut().push(Id::unique(("render-field", name)));
                ui.put(rect, edit)
            };
            let toggle = |ui: &mut Ui, x: &mut f32, y: f32, text: &str, on: bool, enabled: bool| -> bool {
                let w = widgets::button_width(ui, text, false, 28.0);
                let rect = Rect::from_min_size(pos2(*x, y), vec2(w, 28.0));
                *x += w + 8.0;
                widgets::button(ui, rect, Id::unique(("render-toggle", text)), None, text, Look::default().on(on).enabled(enabled)).clicked()
            };
            // Where to.
            label(ui, y, if r.stems { "Folder" } else { "File" });
            let file_w = rect.width() - 32.0 - label_w - 8.0 - 40.0;
            let response = field(ui, left + label_w + 8.0, y, file_w, &mut r.path, "path", "");
            if response.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) {
                action = Some("render");
            }
            let pick = Rect::from_min_size(pos2(left + label_w + 16.0 + file_w, y), vec2(32.0, 28.0));
            if widgets::button(ui, pick, Id::unique("render-pick"), None, "…", Look::default()).clicked() {
                action = Some("pick");
            }
            y += 38.0;
            // What.
            label(ui, y, "Range");
            let range_label = r.ranges.get(r.range).map_or("The whole song".to_string(), |r| r.1.clone()) + "  ▾";
            let w = widgets::button_width(ui, &range_label, false, 28.0);
            let range_rect = Rect::from_min_size(pos2(left + label_w + 8.0, y), vec2(w, 28.0));
            if widgets::button(ui, range_rect, Id::unique("render-range"), None, &range_label, Look::default()).clicked() {
                range_at = Some(range_rect.left_bottom() + vec2(0.0, 2.0));
            }
            y += 38.0;
            // How.
            label(ui, y, "Format");
            let mut x = left + label_w + 8.0;
            for (name, shown, has) in [("wav", "WAV", true), ("flac", "FLAC", true), ("mp3", "MP3", r.lossy[0]), ("ogg", "Ogg", r.lossy[1]), ("opus", "Opus", r.lossy[2])] {
                if has && toggle(ui, &mut x, y, shown, r.format == name, true) {
                    r.format = name.into();
                    if name == "flac" && r.bits == 32 {
                        r.bits = 24;
                    }
                }
            }
            x += 12.0;
            let pcm = matches!(r.format.as_str(), "wav" | "flac");
            if pcm {
                for (bits, shown) in [(16, "16 bit"), (24, "24 bit"), (32, "32 float")] {
                    if toggle(ui, &mut x, y, shown, r.bits == bits, bits != 32 || r.format != "flac") {
                        r.bits = bits;
                    }
                }
            } else {
                for (q, shown) in [("low", "Low"), ("medium", "Medium"), ("high", "High"), ("best", "Best")] {
                    if toggle(ui, &mut x, y, shown, r.quality == q, true) {
                        r.quality = q.into();
                    }
                }
            }
            y += 38.0;
            label(ui, y, "Tail");
            field(ui, left + label_w + 8.0, y, 60.0, &mut r.tail, "tail", "");
            widgets::text_in(
                ui,
                pos2(left + label_w + 76.0, y + 14.0),
                "seconds after the end, for reverbs and delays to ring out",
                sans(T_SMALL),
                t.text_3,
                rect.right() - 16.0 - (left + label_w + 76.0),
            );
            y += 38.0;
            let mut x = left + label_w + 8.0;
            if toggle(ui, &mut x, y, "Normalize to −1 dB", r.normalize, true) {
                r.normalize = !r.normalize;
            }
            if pcm && toggle(ui, &mut x, y, "Dither", r.dither, r.bits != 32) {
                r.dither = !r.dither;
            }
            if toggle(ui, &mut x, y, "Mono", r.mono, true) {
                r.mono = !r.mono;
            }
            if toggle(ui, &mut x, y, "A file per track", r.stems, true) {
                r.stems = !r.stems;
            }
            y += 38.0;
            let mut x = left + label_w + 8.0;
            if toggle(ui, &mut x, y, if r.tags_open { "Tags  ▾" } else { "Tags  ▸" }, r.tags_open, true) {
                r.tags_open = !r.tags_open;
            }
            widgets::text_in(ui, pos2(x, y + 14.0), "title, artist, album and more, kept with the project", sans(T_SMALL), t.text_3, rect.right() - 16.0 - x);
            y += 38.0;
            if r.tags_open {
                let full = rect.right() - 16.0;
                let tag_rows: [&[(usize, &str, f32, &str)]; 4] = [
                    &[(0, "Title", 0.0, "the project's name"), (1, "Artist", 0.0, "")],
                    &[(2, "Album", 0.0, ""), (3, "Track", 60.0, ""), (4, "Year", 70.0, "")],
                    &[(5, "Genre", 0.0, ""), (6, "Comment", 0.0, "")],
                    &[(7, "Cover", 0.0, "a PNG or JPEG file (not in a WAV)")],
                ];
                for row in tag_rows {
                    let mut x = left;
                    let fixed: f32 = row.iter().map(|(_, _, w, _)| *w).sum();
                    let labels: f32 = row.iter().skip(1).map(|(_, l, _, _)| widgets::text_width(ui, l, sans(T_BASE)) + 16.0).sum();
                    let flexible = row.iter().filter(|(_, _, w, _)| *w == 0.0).count().max(1) as f32;
                    let spare = (full - left - label_w - 8.0 - labels - fixed - 8.0 * row.len() as f32) / flexible;
                    for (n, (at, name, w, hint)) in row.iter().enumerate() {
                        if n == 0 {
                            label(ui, y, name);
                            x += label_w + 8.0;
                        } else {
                            ui.painter().text(pos2(x, y + 14.0), Align2::LEFT_CENTER, *name, sans(T_BASE), t.text_2);
                            x += widgets::text_width(ui, name, sans(T_BASE)) + 8.0;
                        }
                        let width = if *w > 0.0 { *w } else { spare.max(40.0) };
                        field(ui, x, y, width, &mut r.tags[*at], TAGS[*at], hint);
                        x += width + 8.0;
                    }
                    y += 38.0;
                }
            }
            // Go, or not.
            let render_w = widgets::button_width(ui, "Render", false, 28.0);
            let render_x = rect.right() - 16.0 - render_w;
            if widgets::button(ui, Rect::from_min_size(pos2(render_x, y), vec2(render_w, 28.0)), Id::unique("render-go"), None, "Render", Look::default().on(true)).clicked() {
                action = Some("render");
            }
            let cancel_w = widgets::button_width(ui, "Cancel", false, 28.0);
            if widgets::button(ui, Rect::from_min_size(pos2(render_x - 8.0 - cancel_w, y), vec2(cancel_w, 28.0)), Id::unique("render-cancel"), None, "Cancel", Look::quiet()).clicked() {
                action = Some("cancel");
            }
            y + 28.0 + 16.0 - rect.top()
        });
        let escape = ui.input(|i| i.key_pressed(egui::Key::Escape));
        let ranges = r.ranges.clone();
        let (path, stems, range) = (r.path.clone(), r.stems, r.range);
        self.dialogs.render = Some(r);
        if let Some(at) = range_at {
            let labels: Vec<&str> = ranges.iter().map(|r| r.1.as_str()).collect();
            self.open_local_menu("render-range", crate::menu::choices(&labels, Some(range)), at);
        }
        match action {
            Some("render") => self.start_render(),
            Some("pick") => {
                self.native(Purpose::Render, &path, stems);
            }
            Some("cancel") => self.dialogs.render = None,
            _ if (closed || escape) && self.menu.is_none() => self.dialogs.render = None,
            _ => {}
        }
    }
}
