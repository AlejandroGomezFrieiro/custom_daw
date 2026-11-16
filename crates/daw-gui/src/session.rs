//! The session view (`ui/session.slint`): what it shows, from the state the
//! kernel pushes, and its gestures, passed on to `daw.frontend.act`.

use std::cell::RefCell;
use std::rc::Rc;

use serde_json::{Value, json};
use slint::{ModelRc, SharedString, VecModel};

use crate::{App, LaunchData, SessionColumn, SlotData, colour, number, rows, sync, text};

pub struct Session {
    columns: Rc<VecModel<SessionColumn>>,
    slots: Rc<VecModel<SlotData>>,
    launch: Rc<VecModel<LaunchData>>,
    scenes: Rc<VecModel<SharedString>>,
    /// The tracks' ids by column, for gestures that name a column.
    ids: Rc<RefCell<Vec<i32>>>,
}

impl Session {
    pub fn new(ui: &App) -> Self {
        let session = Self {
            columns: Rc::new(VecModel::default()),
            slots: Rc::new(VecModel::default()),
            launch: Rc::new(VecModel::default()),
            scenes: Rc::new(VecModel::default()),
            ids: Rc::new(RefCell::new(Vec::new())),
        };
        ui.set_session_columns(ModelRc::from(session.columns.clone()));
        ui.set_slots(ModelRc::from(session.slots.clone()));
        ui.set_launch(ModelRc::from(session.launch.clone()));
        ui.set_scenes(ModelRc::from(session.scenes.clone()));
        session
    }

    /// The tracks, their slots and the scenes, when the project has changed.
    pub fn project(&self, ui: &App, state: &Value) {
        // Every track but the master, which comes last and has no slots.
        let columns: Vec<SessionColumn> = rows(&state["tracks"])
            .iter()
            .filter(|t| !t["master"].as_bool().unwrap_or(false))
            .map(|t| SessionColumn {
                id: number(&t["id"]) as i32,
                name: text(&t["name"]),
                color: colour(&t["color"]),
            })
            .collect();
        *self.ids.borrow_mut() = columns.iter().map(|c| c.id).collect();
        sync(&self.columns, columns);
        let slots = rows(&state["slots"])
            .iter()
            .map(|s| SlotData {
                id: number(&s["id"]) as i32,
                column: number(&s["track"]) as i32,
                row: number(&s["row"]) as i32,
                name: text(&s["name"]),
                midi: s["midi"].as_bool().unwrap_or(false),
                muted: s["muted"].as_bool().unwrap_or(false),
                mode: text(&s["mode"]),
            })
            .collect();
        sync(&self.slots, slots);
        let project = &state["project"];
        sync(
            &self.scenes,
            rows(&project["scenes"]).iter().map(text).collect(),
        );
        ui.set_launch_quantize(text(&project["launch_quantize"]));
    }

    /// What each track plays from its slots, which moves as the song does.
    pub fn tick(&self, state: &Value) {
        let columns = self.ids.borrow().len();
        let launch = rows(&state["launch"])
            .iter()
            .take(columns)
            .map(|l| LaunchData {
                slot: l["slot"].as_i64().unwrap_or(-1) as i32,
                queued: l["queued"].as_i64().unwrap_or(-1) as i32,
                stopping: l["stopping"].as_bool().unwrap_or(false),
                back: l["back"].as_bool().unwrap_or(false),
                stopped: l["stopped"].as_bool().unwrap_or(false),
                // In steps a frame can show, so that a still loop is not redrawn.
                progress: (number(&l["progress"]) * 200.0).round() / 200.0,
                recording: l["recording"].as_i64().unwrap_or(-1) as i32,
            })
            .collect();
        sync(&self.launch, launch);
    }

    /// Whether the view shows, and the slot its cursor is on.
    pub fn modal(&self, ui: &App, modal: &Value) {
        ui.set_show_session(modal["session"].as_bool().unwrap_or(false));
        ui.set_slot_row(modal["slot_row"].as_i64().unwrap_or(-1) as i32);
        ui.set_capturing(modal["capturing"].as_bool().unwrap_or(false));
    }

    /// Pass the view's gestures on to the kernel.
    pub fn install(&self, ui: &App, pass: impl Fn(&str, Value) + Clone + 'static) {
        let all = |track: i32| if track < 0 { Value::Null } else { json!(track) };
        ui.on_slot_press({
            let pass = pass.clone();
            move |track, row, down| pass("press_slot", json!([track, row, down]))
        });
        ui.on_slot_choose({
            let pass = pass.clone();
            move |track, row| pass("choose_slot", json!([track, row]))
        });
        ui.on_slot_open({
            let pass = pass.clone();
            move |track, row| pass("open_slot", json!([track, row]))
        });
        ui.on_slot_move({
            let pass = pass.clone();
            move |clip, track, row, copy| pass("move_slot", json!([clip, track, row, copy]))
        });
        ui.on_clip_to_slot({
            let (pass, ids) = (pass.clone(), self.ids.clone());
            move |clip, column, row| {
                if let Some(track) = ids.borrow().get(column as usize) {
                    pass("clip_to_slot", json!([clip, track, row]))
                }
            }
        });
        ui.on_launch_scene({
            let pass = pass.clone();
            move |row| pass("scene", json!([row]))
        });
        ui.on_slot_stop({
            let pass = pass.clone();
            move |track| pass("stop_slots", json!([all(track)]))
        });
        ui.on_slot_record({
            let pass = pass.clone();
            move |track, row| pass("record_slot", json!([track, row]))
        });
        ui.on_slot_back(move |track| pass("back_to_timeline", json!([all(track)])));
    }
}
