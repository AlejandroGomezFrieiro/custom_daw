//! Menus at the pointer. Their entries are the kernel's
//! (`daw.frontend.menu`, runtime/lua/daw/window_menus.lua): the window shows
//! them and says which was chosen, by its place. A few belong to the window
//! alone (which lane a track shows, the piano roll's grid), built here.

use egui::{Align2, CornerRadius, Id, Order, Pos2, Rect, Sense, Stroke, StrokeKind, Ui, pos2, vec2};
use serde_json::{Value, json};

use crate::app::View;
use crate::model::{flag, rows, text};
use crate::theme::{T_BASE, T_SMALL, alpha, mono, sans, th};

/// An entry: a label, keys that do the same, greyed out or not, ticked or
/// not, a submenu; or a line between entries.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Item {
    pub label: String,
    pub keys: String,
    pub enabled: bool,
    pub checked: bool,
    pub separator: bool,
    /// What the window does itself for it: see `View::window_action`.
    pub window: Option<String>,
    pub items: Vec<Item>,
}

impl Item {
    pub fn new(label: impl Into<String>) -> Item {
        Item { label: label.into(), enabled: true, ..Item::default() }
    }
    pub fn checked(self, checked: bool) -> Item {
        Item { checked, ..self }
    }
}

/// The entries the kernel describes.
pub fn items(list: &Value) -> Vec<Item> {
    rows(list)
        .iter()
        .map(|i| Item {
            label: text(&i["label"]),
            keys: text(&i["keys"]),
            enabled: i["enabled"].as_bool().unwrap_or(true),
            checked: flag(&i["checked"]),
            separator: flag(&i["separator"]),
            window: i["window"].as_str().map(String::from),
            items: items(&i["items"]),
        })
        .collect()
}

/// Whose a menu is: the kernel's, built for `args`; or the window's, named.
#[derive(Clone, Debug)]
pub enum Source {
    Kernel { kind: String, args: Value },
    Window(String),
}

pub struct Menu {
    pub source: Source,
    pub items: Vec<Item>,
    pub at: Pos2,
    /// The submenus open, by place.
    pub open: Vec<usize>,
}

const ROW: f32 = 24.0;
const WIDTH_MIN: f32 = 160.0;

impl View {
    /// Open the kernel's menu `kind` for `args` at `at`.
    pub fn open_menu(&mut self, kind: &str, args: Value, at: Pos2) {
        let list = self.ask("return daw.frontend.menu(...)", json!([kind, args]));
        let items = items(&list);
        if items.is_empty() {
            return;
        }
        self.menu = Some(Menu { source: Source::Kernel { kind: kind.into(), args }, items, at, open: Vec::new() });
    }

    /// Open a menu of the window's own.
    pub fn open_local_menu(&mut self, name: &str, items: Vec<Item>, at: Pos2) {
        self.menu = Some(Menu { source: Source::Window(name.into()), items, at, open: Vec::new() });
    }

    /// The menu that is open, over everything; what is chosen is done.
    pub fn menu_popup(&mut self, ui: &mut Ui) {
        let Some(mut menu) = self.menu.take() else { return };
        let ctx = ui.ctx().clone();
        let screen = ctx.content_rect();
        // Behind it, a sheet that takes the pointer: a press outside lets
        // go of the menu and does nothing else.
        let sheet = egui::Area::new(Id::unique("menu-sheet")).order(Order::Foreground).fixed_pos(screen.min).show(&ctx, |ui| {
            ui.interact(screen, Id::unique("menu-sheet-touch"), Sense::click()).clicked()
                || ui.input(|i| i.pointer.secondary_clicked() || i.pointer.middle_down())
        });
        let mut chosen: Option<Vec<usize>> = None;
        let mut over_menu = false;
        let mut level_items = menu.items.clone();
        let mut at = menu.at;
        let mut path: Vec<usize> = Vec::new();
        let mut level = 0;
        loop {
            let width = level_width(ui, &level_items);
            let height = level_items.iter().map(|i| if i.separator { 9.0 } else { ROW }).sum::<f32>() + 8.0;
            // Kept on the screen.
            let x = at.x.min(screen.right() - width - 4.0).max(screen.left());
            let y = at.y.min(screen.bottom() - height - 4.0).max(screen.top());
            let rect = Rect::from_min_size(pos2(x, y), vec2(width, height));
            let mut next: Option<(usize, Pos2)> = None;
            egui::Area::new(Id::unique(("menu", level))).order(Order::Tooltip).fixed_pos(rect.min).show(&ctx, |ui| {
                let t = th();
                ui.painter().rect(rect, CornerRadius::same(6), t.card, Stroke::new(1.0, t.card_line), StrokeKind::Inside);
                let mut y = rect.top() + 4.0;
                for (i, item) in level_items.iter().enumerate() {
                    if item.separator {
                        ui.painter().hline((rect.left() + 8.0)..=(rect.right() - 8.0), y + 4.5, Stroke::new(1.0, t.card_line));
                        y += 9.0;
                        continue;
                    }
                    let row = Rect::from_min_size(pos2(rect.left() + 4.0, y), vec2(width - 8.0, ROW));
                    y += ROW;
                    let response = ui.interact(row, Id::unique(("menu-item", level, i)), Sense::click());
                    let open_here = menu.open.get(level) == Some(&i);
                    let lit = item.enabled && (response.hovered() || open_here);
                    if lit {
                        ui.painter().rect_filled(row, CornerRadius::same(3), alpha(t.select, 0.25));
                    }
                    let ink = if item.enabled { t.text } else { t.text_3 };
                    if item.checked {
                        ui.painter().text(pos2(row.left() + 6.0, row.center().y), Align2::LEFT_CENTER, "✓", sans(T_BASE), t.select);
                    }
                    ui.painter().text(pos2(row.left() + 24.0, row.center().y), Align2::LEFT_CENTER, &item.label, sans(T_BASE), ink);
                    if !item.items.is_empty() {
                        ui.painter().text(pos2(row.right() - 8.0, row.center().y), Align2::RIGHT_CENTER, "›", sans(T_BASE), t.text_2);
                    } else if !item.keys.is_empty() {
                        ui.painter().text(pos2(row.right() - 8.0, row.center().y), Align2::RIGHT_CENTER, &item.keys, mono(T_SMALL), t.text_3);
                    }
                    if response.hovered() && item.enabled {
                        if item.items.is_empty() {
                            if menu.open.len() > level {
                                menu.open.truncate(level);
                            }
                        } else if !open_here {
                            menu.open.truncate(level);
                            menu.open.push(i);
                        }
                    }
                    if item.enabled && !item.items.is_empty() && (open_here || response.hovered()) {
                        next = Some((i, pos2(rect.right() - 2.0, row.top() - 4.0)));
                    }
                    if response.clicked() && item.enabled && item.items.is_empty() {
                        let mut full = path.clone();
                        full.push(i);
                        chosen = Some(full);
                    }
                }
                over_menu |= ui.rect_contains_pointer(rect);
            });
            let Some((i, pos)) = next else { break };
            path.push(i);
            level_items = level_items[i].items.clone();
            at = pos;
            level += 1;
        }
        let pressed_outside = sheet.inner && !over_menu;
        let escape = ui.input(|i| i.key_pressed(egui::Key::Escape));
        if let Some(path) = chosen {
            self.choose(&menu, &path);
        } else if !(pressed_outside || escape) {
            self.menu = Some(menu);
        }
    }

    fn choose(&mut self, menu: &Menu, path: &[usize]) {
        let mut items = &menu.items;
        let mut item = None;
        for &at in path {
            item = items.get(at);
            items = match item {
                Some(i) => &i.items,
                None => return,
            };
        }
        let Some(item) = item.cloned() else { return };
        match &menu.source {
            Source::Kernel { kind, args } => {
                if let Some(what) = &item.window {
                    self.window_action(what);
                } else {
                    let places: Vec<usize> = path.iter().map(|p| p + 1).collect();
                    self.pass("menu_choose", json!([kind, args, places]));
                }
            }
            Source::Window(name) => self.local_choice(name, path),
        }
    }

    /// What an entry of one of the window's own menus does.
    fn local_choice(&mut self, name: &str, path: &[usize]) {
        let first = path.first().copied().unwrap_or(0);
        if let Some(track) = name.strip_prefix("lane:") {
            let track = track.parse().unwrap_or(0);
            self.show_lane(track, first);
        } else if name == "render-range" {
            self.dialogs.render_range(first);
        } else {
            self.roll_choice(name, first);
        }
    }
}

fn level_width(ui: &Ui, items: &[Item]) -> f32 {
    let widest = items
        .iter()
        .filter(|i| !i.separator)
        .map(|i| {
            let keys = if i.items.is_empty() && !i.keys.is_empty() {
                crate::widgets::text_width(ui, &i.keys, mono(T_SMALL)) + 24.0
            } else {
                16.0
            };
            crate::widgets::text_width(ui, &i.label, sans(T_BASE)) + keys
        })
        .fold(0.0, f32::max);
    (widest + 44.0).max(WIDTH_MIN)
}

/// A menu of plain choices, the one chosen ticked.
pub fn choices(labels: &[&str], checked: Option<usize>) -> Vec<Item> {
    labels.iter().enumerate().map(|(i, l)| Item::new(*l).checked(Some(i) == checked)).collect()
}
