//! What the player says about an instrument (`describe`): its range,
//! keyswitches and articulations with their M2-123 codes, what it
//! labels, and what it could not read. The articulations extension makes
//! an `.art.toml` from this.

use crate::engine::Program;
use crate::m2;
use crate::model::{Instrument, Trigger};
use crate::params::{PARAMS, to_text};
use serde_json::{Value, json};

pub fn instrument(inst: &Instrument) -> Value {
    let range = inst.range().map_or(Value::Null, |(lo, hi)| json!([lo, hi]));
    let keyswitches: Vec<Value> = inst
        .articulations
        .iter()
        .filter_map(|a| a.keyswitch.map(|k| json!({ "pitch": k, "name": a.name })))
        .collect();
    let articulations: Vec<Value> = (0..inst.articulations.len())
        .map(|i| {
            let a = &inst.articulations[i];
            let (code, custom) = m2::code_of(&inst.articulations, i);
            let mut v = json!({ "name": a.name, "m2": m2::format_code(code) });
            if custom {
                v["custom"] = json!(true);
            }
            if let Some(k) = a.keyswitch {
                v["keyswitch"] = json!(k);
            }
            if inst.default_articulation == Some(i) {
                v["default"] = json!(true);
            }
            v
        })
        .collect();
    let labels = |l: &[(u8, String)]| -> Vec<Value> {
        l.iter().map(|(n, name)| json!({ "number": n, "name": name })).collect()
    };
    json!({
        "name": inst.name,
        "format": inst.format,
        "path": inst.path.to_string_lossy(),
        "range": range,
        "keyswitches": keyswitches,
        "articulations": articulations,
        "ccs": labels(&inst.cc_labels),
        "keys": labels(&inst.key_labels),
        "regions": inst.regions.len(),
        "round_robin": inst.regions.iter().map(|r| r.seq_length).max().unwrap_or(1),
        "release_triggers": inst.regions.iter().filter(|r| matches!(r.trigger, crate::model::Trigger::Release | crate::model::Trigger::ReleaseKey)).count(),
        "warnings": inst.warnings,
    })
}

/// The whole answer: the instrument as loaded (with its samples and how
/// long they took), or why there is none, and the parameters.
pub fn describe(program: Option<&Program>, path: &str, error: Option<&str>, values: &[f64]) -> Value {
    let mut v = match program {
        Some(p) => {
            let mut v = instrument(&p.instrument);
            v["samples"] = json!(p.samples.len());
            v["memory"] = json!(p.memory());
            v["load_ms"] = json!((p.load_ms * 10.0).round() / 10.0);
            delays(p, &mut v);
            v
        }
        None => json!({ "name": "", "format": "", "path": path, "range": Value::Null,
                         "keyswitches": [], "articulations": [], "warnings": [] }),
    };
    if let Some(e) = error {
        v["error"] = json!(e);
    }
    v["params"] = PARAMS
        .iter()
        .zip(values)
        .map(|(p, &value)| {
            json!({ "key": p.key, "name": p.name, "min": p.min, "max": p.max,
                    "default": p.default, "value": value, "text": to_text(p, value) })
        })
        .collect();
    v
}

/// The onset delay of the instrument's attack samples (`delay_ms`), and of
/// each articulation's, as the median over its regions: how much earlier
/// a note must start for its attack to land on the beat.
fn delays(p: &Program, v: &mut Value) {
    let inst = &p.instrument;
    let attack = |r: &crate::model::Region| matches!(r.trigger, Trigger::Attack | Trigger::First | Trigger::Legato);
    let median = |mut d: Vec<f64>| -> Option<f64> {
        if d.is_empty() {
            return None;
        }
        d.sort_by(f64::total_cmp);
        Some((d[d.len() / 2] * 10000.0).round() / 10.0)
    };
    let all: Vec<f64> = (0..inst.regions.len()).filter(|&i| attack(&inst.regions[i])).map(|i| p.onset(i)).collect();
    v["delay_ms"] = json!(median(all));
    for (a, art) in inst.articulations.iter().enumerate() {
        let state = (inst.default_switch & !art.mask) | art.values;
        let plays = |r: &crate::model::Region| {
            attack(r) && (r.switch_any == 0 || state & r.switch_any != 0) && state & r.switch_all == r.switch_all
        };
        let d: Vec<f64> = (0..inst.regions.len()).filter(|&i| plays(&inst.regions[i])).map(|i| p.onset(i)).collect();
        v["articulations"][a]["delay_ms"] = json!(median(d));
    }
}
