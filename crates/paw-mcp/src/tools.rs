//! The tools: what each does. Arguments are checked against the tool's own
//! schema first (`check.rs`), then normalized here (note names, positions,
//! paths) and handed to the kernel side in `mcp.lua` as one call, so each tool
//! call is one kernel turn and, when it writes, one undo step. The answer is
//! given as text for a person or a model that reads prose, and as
//! `structuredContent` for a program.

use std::fmt::Write as _;
use std::path::{Component, Path, PathBuf};

use serde_json::{Map, Value, json};

use crate::audio::{self, Segments};
use crate::check::validate;
use crate::format::{self, items};
use crate::kernel::{CallError, Kernel};
use crate::music::{self, Meter, num};
use crate::schema::{BATCHABLE, ToolDef, defs};

const LUA: &str = include_str!("mcp.lua");

/// What the server lets a model do beyond the typed tools.
#[derive(Clone, Debug, Default)]
pub struct Policy {
    /// Offer `lua`, `run_command` and `send_keys`.
    pub allow_eval: bool,
    /// Let file-writing tools write anywhere, not only under `root`.
    pub allow_any_path: bool,
    /// Where relative paths start, and the only place files are written to
    /// unless `allow_any_path`.
    pub root: PathBuf,
}

pub struct Tools {
    pub kernel: Kernel,
    pub policy: Policy,
}

/// A failed tool call: the text the model gets back with `isError`.
#[derive(Debug)]
pub struct ToolError(pub String);

impl From<CallError> for ToolError {
    fn from(err: CallError) -> Self {
        ToolError(err.to_string())
    }
}

impl From<anyhow::Error> for ToolError {
    fn from(err: anyhow::Error) -> Self {
        ToolError(format!("{err:#}"))
    }
}

/// What a tool answers: prose, and the same as JSON.
pub struct Reply {
    pub text: String,
    pub data: Value,
}

pub type Outcome = Result<Reply, ToolError>;

fn err<T>(msg: impl Into<String>) -> Result<T, ToolError> {
    Err(ToolError(msg.into()))
}

/// Lists that Lua may hand over as an empty table, which is not an array
/// until it is made one.
const LISTS: [&str; 24] = [
    "tracks", "clips", "devices", "lanes", "sends", "notes", "markers", "params", "messages",
    "results", "findings", "published", "history", "redoable", "steps", "found", "param_info",
    "points", "removed", "skipped", "stems", "keys_used", "choices", "tempo_changes",
];

/// The data a result carries for a program: empty lists as lists, and where
/// there is a position or a pitch, how a musician writes it.
fn enrich(value: &mut Value, meter: Meter) {
    match value {
        Value::Array(list) => list.iter_mut().for_each(|v| enrich(v, meter)),
        Value::Object(map) => {
            for key in LISTS {
                if map.get(key).is_some_and(|v| v.as_object().is_some_and(Map::is_empty)) {
                    map.insert(key.into(), json!([]));
                }
            }
            let start = map.get("start").and_then(Value::as_f64);
            if let (Some(pitch), Some(start)) = (map.get("pitch").and_then(Value::as_u64), start)
                && map.contains_key("length")
            {
                map.insert("name".into(), json!(music::name(pitch.min(127) as u8)));
                map.insert("at".into(), json!(meter.format(start)));
            } else if matches!(map.get("kind").and_then(Value::as_str), Some("midi" | "audio"))
                && let Some(start) = start
            {
                map.insert("at".into(), json!(meter.format(start)));
            } else if map.contains_key("region")
                && let Some(beat) = map.get("beat").and_then(Value::as_f64)
            {
                map.insert("at".into(), json!(meter.format(beat)));
            }
            map.values_mut().for_each(|v| enrich(v, meter));
        }
        _ => {}
    }
}

/// The name of the undo step a call makes: `mcp: add_track Bass`.
fn undo_label(name: &str, a: &Map<String, Value>) -> String {
    let subject = ["name", "track", "clip", "device", "marker"]
        .iter()
        .find_map(|key| match a.get(*key) {
            Some(Value::String(s)) => Some(s.clone()),
            Some(Value::Number(n)) => Some(n.to_string()),
            _ => None,
        });
    match subject {
        Some(s) => format!("mcp: {name} {}", s.chars().take(40).collect::<String>()),
        None => format!("mcp: {name}"),
    }
}

fn as_map(value: &Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap_or_default()
}

impl Tools {
    pub fn list(&self) -> Vec<Value> {
        defs()
            .into_iter()
            .filter(|d| !d.escape || self.policy.allow_eval)
            .map(|d| {
                json!({
                    "name": d.name,
                    "title": d.title,
                    "description": d.description,
                    "inputSchema": d.schema,
                    "annotations": {
                        "title": d.title,
                        "readOnlyHint": d.read_only,
                        "destructiveHint": d.destructive,
                        "idempotentHint": d.read_only,
                        "openWorldHint": d.escape,
                    }
                })
            })
            .collect()
    }

    pub fn call(&mut self, name: &str, args: &Value) -> Outcome {
        let Some(def) = defs().into_iter().find(|d| d.name == name) else {
            let names: Vec<&str> = defs()
                .iter()
                .filter(|d| !d.escape || self.policy.allow_eval)
                .map(|d| d.name)
                .collect();
            return err(format!(
                "unknown tool `{name}`; the tools are: {}",
                names.join(", ")
            ));
        };
        if def.escape && !self.policy.allow_eval {
            return err(format!(
                "`{name}` is an escape hatch that runs arbitrary code in paw, and this server was started without --allow-eval. Use the typed tools, or ask the user to restart the server with --allow-eval."
            ));
        }
        let args = match args {
            Value::Object(map) => map.clone(),
            Value::Null => Map::new(),
            _ => return err("arguments must be an object"),
        };
        validate(&def.schema, &args)?;
        let notice = self.kernel.notice.take();
        let mut reply = self.dispatch(name, &args);
        // A kernel restarted under us is news whether the call worked or not.
        if let Some(notice) = notice.or_else(|| self.kernel.notice.take()) {
            match &mut reply {
                Ok(Reply { text, data }) => {
                    *text = format!("NOTE: {notice}\n{text}");
                    data["notice"] = json!(notice);
                }
                Err(ToolError(text)) => *text = format!("NOTE: {notice}\n{text}"),
            }
        }
        reply
    }

    fn dispatch(&mut self, name: &str, a: &Map<String, Value>) -> Outcome {
        match name {
            "get_project" => self.get_project(),
            "get_track" => self.get_track(a),
            "get_clip" => self.get_clip(a),
            "get_device" => self.get_device(a),
            "find_devices" => self.find_devices(a),
            "get_status" => self.get_status(a),
            "find" => self.find(a),
            "diagnose" => self.diagnose(a),
            "batch" => self.batch(a),
            _ if BATCHABLE.contains(&name) => self.write(name, a),
            "transport" => self.transport(a),
            "undo" => self.undo(a),
            "project_file" => self.project_file(a),
            "render" => self.render(a),
            "analyze_audio" => self.analyze_audio(a),
            "lua" => self.escape("lua", json!({ "code": a["code"] })),
            "run_command" => self.escape("command", json!({ "line": a["line"] })),
            "send_keys" => self.escape("keys", json!({ "keys": a["keys"] })),
            _ => err(format!("unknown tool `{name}`")),
        }
    }

    // --- plumbing ------------------------------------------------------------

    /// Run one tool of the kernel side.
    pub fn lua(&mut self, tool: &str, args: Value) -> Result<Value, ToolError> {
        self.lua_as(tool, args, None)
    }

    /// Run one tool of the kernel side, naming the undo step it makes.
    fn lua_as(&mut self, tool: &str, args: Value, label: Option<&str>) -> Result<Value, ToolError> {
        let mut params = vec![json!(tool), args];
        params.extend(label.map(|l| json!(l)));
        Ok(self.kernel.eval(LUA, params)?)
    }

    fn meter(&mut self) -> Result<Meter, ToolError> {
        Ok(Meter::from_project(
            &self.kernel.call("project_get", json!([]))?,
        ))
    }

    /// The text with what paw said while the call ran, and the data in the
    /// shape a program wants.
    fn reply(mut text: String, r: &Value, meter: Meter) -> Reply {
        format::messages(&mut text, &r["messages"]);
        let mut data = r.clone();
        enrich(&mut data, meter);
        Reply { text, data }
    }

    // --- reading -------------------------------------------------------------

    fn get_project(&mut self) -> Outcome {
        let r = self.lua("project", json!({}))?;
        let meter = Meter::from_project(&r["project"]);
        Ok(Self::reply(format::project(&r["project"]), &r, meter))
    }

    fn get_track(&mut self, a: &Map<String, Value>) -> Outcome {
        let meter = self.meter()?;
        let r = self.lua("track", json!({ "track": a["track"] }))?;
        let mut out = String::new();
        format::track(&mut out, &r["track"], meter, true);
        Ok(Self::reply(out, &r, meter))
    }

    fn get_clip(&mut self, a: &Map<String, Value>) -> Outcome {
        let meter = self.meter()?;
        let mut filter = Map::new();
        for key in ["from", "to"] {
            if let Some(v) = a.get(key) {
                filter.insert(key.into(), json!(music::position(v, meter, key)?));
            }
        }
        if let Some(p) = a.get("pitches") {
            filter.insert("pitches".into(), json!(music::pitches(p)?));
        }
        let filter = (!filter.is_empty()).then_some(Value::Object(filter));
        let r = self.lua("clip", json!({ "clip": a["clip"], "filter": filter }))?;
        let mut out = String::new();
        format::clip(&mut out, &r["clip"], meter);
        Ok(Self::reply(out, &r, meter))
    }

    fn get_device(&mut self, a: &Map<String, Value>) -> Outcome {
        let r = self.lua(
            "device",
            json!({ "device": a["device"], "filter": a.get("filter") }),
        )?;
        let mut out = String::new();
        let d = &r["device"];
        format::device(&mut out, d, "", usize::MAX);
        if let Some(track) = d["track_name"].as_str() {
            let _ = writeln!(out, "on track \"{track}\"");
        }
        Ok(Self::reply(out, &r, Meter::default()))
    }

    fn find_devices(&mut self, a: &Map<String, Value>) -> Outcome {
        let r = self.lua("find_devices", Value::Object(a.clone()))?;
        let devices = items(&r["devices"]);
        let total = r["total"].as_u64().unwrap_or(0);
        let mut out = format!(
            "{} of {} device kinds match{}:\n",
            total,
            r["all"].as_u64().unwrap_or(0),
            if (devices.len() as u64) < total {
                format!(
                    " (showing {}; narrow the query or raise limit)",
                    devices.len()
                )
            } else {
                String::new()
            }
        );
        for d in devices {
            let mut extra: Vec<String> = Vec::new();
            for key in ["vendor", "category"] {
                if let Some(v) = d[key].as_str().filter(|v| !v.is_empty()) {
                    extra.push(v.to_string());
                }
            }
            let _ = writeln!(
                out,
                "  {} — {} ({}{}{}) · {} params",
                d["kind"].as_str().unwrap_or(""),
                d["name"].as_str().unwrap_or(""),
                d["format"].as_str().unwrap_or(""),
                if extra.is_empty() { "" } else { ", " },
                extra.join(", "),
                d["params"]
            );
            for p in items(&d["param_info"]) {
                let _ = writeln!(
                    out,
                    "      {} \"{}\" {} to {} (default {})",
                    p["key"].as_str().unwrap_or(""),
                    p["name"].as_str().unwrap_or(""),
                    num(p["min"].as_f64().unwrap_or(0.0)),
                    num(p["max"].as_f64().unwrap_or(0.0)),
                    num(p["default"].as_f64().unwrap_or(0.0))
                );
            }
        }
        Ok(Self::reply(out, &r, Meter::default()))
    }

    fn get_status(&mut self, a: &Map<String, Value>) -> Outcome {
        let r = self.lua("status", json!({ "messages": a.get("messages") }))?;
        let p = &r["project"];
        let meter = Meter::from_project(p);
        let e = &r["engine"];
        let mut out = format::project_header(p, meter);
        let _ = writeln!(
            out,
            "\nTransport: {}",
            format::transport(&r["transport"], meter)
        );
        let _ = writeln!(
            out,
            "Engine: {} backend, {} Hz, buffer {}, CPU {:.0}%, {} dropouts",
            e["backend"].as_str().unwrap_or("?"),
            e["sample_rate"],
            e["buffer_size"],
            e["cpu"].as_f64().unwrap_or(0.0) * 100.0,
            e["xruns"]
        );
        let _ = writeln!(out, "Kernel socket: {}", self.kernel.socket.display());
        if items(&r["messages"]).is_empty() {
            out.push_str("No messages.\n");
        } else {
            format::messages(&mut out, &r["messages"]);
        }
        let mut data = r.clone();
        enrich(&mut data, meter);
        data["socket"] = json!(self.kernel.socket.display().to_string());
        Ok(Reply { text: out, data })
    }

    fn find(&mut self, a: &Map<String, Value>) -> Outcome {
        let r = self.lua("find", Value::Object(a.clone()))?;
        let found = items(&r["found"]);
        let total = r["total"].as_u64().unwrap_or(0);
        let mut out = format!(
            "{total} match{}{}:\n",
            if total == 1 { "" } else { "es" },
            if (found.len() as u64) < total {
                format!(" (showing {}; raise limit or narrow the query)", found.len())
            } else {
                String::new()
            }
        );
        for n in found {
            let _ = writeln!(
                out,
                "  {} [id {}]: {}",
                n["kind"].as_str().unwrap_or(""),
                n["id"],
                n["text"].as_str().unwrap_or("")
            );
        }
        Ok(Self::reply(out, &r, self.meter()?))
    }

    fn diagnose(&mut self, a: &Map<String, Value>) -> Outcome {
        let r = self.lua("diagnose", Value::Object(a.clone()))?;
        let mut out = String::new();
        let findings = items(&r["findings"]);
        let c = &r["counts"];
        if findings.is_empty() {
            out.push_str("No problems found.\n");
        } else {
            let _ = writeln!(
                out,
                "{} error{}, {} warning{}, {} note{}:",
                c["error"],
                if c["error"] == 1 { "" } else { "s" },
                c["warning"],
                if c["warning"] == 1 { "" } else { "s" },
                c["info"],
                if c["info"] == 1 { "" } else { "s" }
            );
        }
        for f in findings {
            let _ = writeln!(
                out,
                "  [{}] {}: {}",
                f["severity"].as_str().unwrap_or(""),
                f["rule"].as_str().unwrap_or(""),
                f["message"].as_str().unwrap_or("")
            );
        }
        if let Some(m) = r["measure"].as_object() {
            let level = |key: &str| m.get(key).and_then(Value::as_f64).map(|v| num((v * 10.0).round() / 10.0));
            let _ = writeln!(
                out,
                "measured: {} LUFS integrated, true peak {} dBTP, sample peak {} dBFS",
                level("integrated").unwrap_or("?".into()),
                level("true_peak").unwrap_or("?".into()),
                level("sample_peak").unwrap_or("?".into())
            );
        }
        let published = items(&r["published"]);
        if !published.is_empty() {
            out.push_str("reported by other tools in paw:\n");
            for p in published {
                let _ = writeln!(
                    out,
                    "  [{}] {}{}",
                    p["severity"].as_str().unwrap_or(""),
                    p["source"]
                        .as_str()
                        .map(|s| format!("{s}: "))
                        .unwrap_or_default(),
                    p["message"].as_str().unwrap_or("")
                );
            }
        }
        Ok(Self::reply(out, &r, Meter::default()))
    }

    // --- writing -------------------------------------------------------------

    fn clip_args(&self, c: &Map<String, Value>, meter: Meter) -> Result<Value, ToolError> {
        let mut out = Map::new();
        if let Some(name) = c.get("name") {
            out.insert("name".into(), name.clone());
        }
        if let Some(start) = c.get("start") {
            out.insert(
                "start".into(),
                json!(music::position(start, meter, "start")?),
            );
        }
        if let Some(length) = c.get("length") {
            out.insert(
                "length".into(),
                json!(music::length(length, meter, "length")?),
            );
        }
        if let Some(notes) = c.get("notes") {
            out.insert("notes".into(), json!(music::notes(notes, meter)?));
        }
        if let Some(file) = c.get("file").and_then(Value::as_str) {
            let path = self.read_path(file);
            if !path.is_file() {
                return err(format!("no audio file at {}", path.display()));
            }
            if c.contains_key("notes") {
                return err("a clip has notes or a file, not both");
            }
            out.insert("file".into(), json!(path));
        }
        Ok(Value::Object(out))
    }

    /// A tool's arguments in the kernel's units: positions and lengths in
    /// beats, pitches as numbers, paths made absolute.
    fn prepare(&self, name: &str, a: &Map<String, Value>, meter: Meter) -> Result<Value, ToolError> {
        let mut args = a.clone();
        let position = |key: &str, args: &mut Map<String, Value>| -> Result<(), ToolError> {
            if let Some(v) = a.get(key) {
                args.insert(key.into(), json!(music::position(v, meter, key)?));
            }
            Ok(())
        };
        match name {
            "add_track" => {
                if let Some(clips) = a.get("clips") {
                    let mut list = Vec::new();
                    for (i, c) in items(clips).iter().enumerate() {
                        let c = c
                            .as_object()
                            .ok_or_else(|| ToolError("each clip is an object".into()))?;
                        list.push(
                            self.clip_args(c, meter)
                                .map_err(|e| ToolError(format!("clip {}: {}", i + 1, e.0)))?,
                        );
                    }
                    args.insert("clips".into(), Value::Array(list));
                }
            }
            "add_clip" => {
                let mut clip = as_map(&self.clip_args(a, meter)?);
                clip.insert("track".into(), a["track"].clone());
                return Ok(Value::Object(clip));
            }
            "edit_clip" => {
                position("start", &mut args)?;
                if let Some(length) = a.get("length") {
                    args.insert(
                        "length".into(),
                        json!(music::length(length, meter, "length")?),
                    );
                }
                for key in ["notes", "add_notes"] {
                    if let Some(notes) = a.get(key) {
                        args.insert(key.into(), json!(music::notes(notes, meter)?));
                    }
                }
                for key in ["remove_notes", "set_velocity"] {
                    if let Some(Value::Object(r)) = a.get(key) {
                        let mut out = r.clone();
                        if let Some(p) = r.get("pitches") {
                            out.insert("pitches".into(), json!(music::pitches(p)?));
                        }
                        for key in ["from", "to"] {
                            if let Some(v) = r.get(key) {
                                out.insert(key.into(), json!(music::position(v, meter, key)?));
                            }
                        }
                        let selective = ["all", "ids", "pitches", "from", "to"]
                            .iter()
                            .any(|k| out.contains_key(*k));
                        if key == "remove_notes" && !selective {
                            return err("remove_notes needs `all`, `ids`, `pitches`, `from` or `to`");
                        }
                        args.insert(key.into(), Value::Object(out));
                    }
                }
                if let Some(Value::Array(list)) = a.get("edit_notes") {
                    let mut out = Vec::new();
                    for (i, e) in list.iter().enumerate() {
                        let mut e = as_map(e);
                        let note = |e: &mut Map<String, Value>| -> Result<(), anyhow::Error> {
                            if let Some(p) = e.get("pitch").cloned() {
                                let all = music::pitches(&p)?;
                                anyhow::ensure!(all.len() == 1, "a note has one pitch, not a chord");
                                e.insert("pitch".into(), json!(all[0]));
                            }
                            if let Some(v) = e.get("start").cloned() {
                                e.insert("start".into(), json!(music::note_start(&v, meter)?));
                            }
                            if let Some(v) = e.get("length").cloned() {
                                e.insert("length".into(), json!(music::length(&v, meter, "length")?));
                            }
                            Ok(())
                        };
                        note(&mut e).map_err(|x| ToolError(format!("edit_notes[{i}]: {x:#}")))?;
                        out.push(Value::Object(e));
                    }
                    args.insert("edit_notes".into(), Value::Array(out));
                }
            }
            "automate" => {
                if let Some(points) = a.get("points") {
                    let mut list = Vec::new();
                    for (i, p) in items(points).iter().enumerate() {
                        let pair = items(p);
                        if pair.len() != 2 {
                            return err(format!("point {}: write it as [position, value]", i + 1));
                        }
                        let beat = music::position(&pair[0], meter, "position")
                            .map_err(|e| ToolError(format!("point {}: {e:#}", i + 1)))?;
                        let value = pair[1].as_f64().ok_or_else(|| {
                            ToolError(format!("point {}: the value must be a number", i + 1))
                        })?;
                        list.push(json!([beat, value]));
                    }
                    args.insert("points".into(), Value::Array(list));
                }
                if a.contains_key("device")
                    && !a.contains_key("param")
                    && a.get("remove") != Some(&json!(true))
                {
                    return err(
                        "automating a device needs `param`, the parameter's key or name (get_device lists them)",
                    );
                }
            }
            "set_project" => {
                if let Some(sig) = a.get("signature").and_then(Value::as_str) {
                    let (n, d) = music::signature(sig)?;
                    args.remove("signature");
                    args.insert("sig_num".into(), json!(n));
                    args.insert("sig_den".into(), json!(d));
                }
                if let Some(list) = a.get("tempo_changes").and_then(Value::as_array) {
                    let mut out = Vec::new();
                    for c in list {
                        let at = music::position(&c["at"], meter, "tempo change position")?;
                        let ramp = c["ramp"].as_bool().unwrap_or(false);
                        out.push(json!({"beat": at, "bpm": c["bpm"], "ramp": ramp}));
                    }
                    args.insert("tempo_changes".into(), Value::Array(out));
                }
                if let Some(list) = a.get("signature_changes").and_then(Value::as_array) {
                    let mut out = Vec::new();
                    for c in list {
                        let at = music::position(&c["at"], meter, "signature change position")?;
                        let (n, d) = music::signature(c["signature"].as_str().unwrap_or(""))?;
                        out.push(json!({"beat": at, "num": n, "den": d}));
                    }
                    args.insert("signature_changes".into(), Value::Array(out));
                }
            }
            "marker" => {
                position("at", &mut args)?;
                if let Some(length) = a.get("length") {
                    args.insert(
                        "length".into(),
                        json!(music::length(length, meter, "length")?),
                    );
                }
            }
            "duplicate_clip" => position("at", &mut args)?,
            "repeat_bars" => {
                for key in ["from", "to", "at"] {
                    position(key, &mut args)?;
                }
            }
            "remove" => {
                if a.values().all(|v| items(v).is_empty()) {
                    return err("nothing to remove: give tracks, clips, devices, automation or markers");
                }
            }
            _ => {}
        }
        Ok(Value::Object(args))
    }

    /// A writing tool called alone: one undo step.
    fn write(&mut self, name: &str, a: &Map<String, Value>) -> Outcome {
        let meter = self.meter()?;
        let args = self.prepare(name, a, meter)?;
        let r = self.lua_as(name, args, Some(&undo_label(name, a)))?;
        Ok(self.show(name, &r, meter))
    }

    /// Several writing tools as one undo step.
    fn batch(&mut self, a: &Map<String, Value>) -> Outcome {
        let meter = self.meter()?;
        let steps = items(&a["steps"]);
        let mut ops = Vec::new();
        for (i, step) in steps.iter().enumerate() {
            let at = |e: ToolError| ToolError(format!("step {}: {}", i + 1, e.0));
            let tool = step["tool"].as_str().unwrap_or("");
            let def: ToolDef = defs()
                .into_iter()
                .find(|d| d.name == tool && BATCHABLE.contains(&tool))
                .ok_or_else(|| {
                    ToolError(format!(
                        "step {}: `{tool}` is not a tool a batch can run; they are {}",
                        i + 1,
                        BATCHABLE.join(", ")
                    ))
                })?;
            let args = as_map(&step["arguments"]);
            validate(&def.schema, &args).map_err(at)?;
            let prepared = self.prepare(tool, &args, meter).map_err(at)?;
            ops.push(json!({ "tool": tool, "args": prepared }));
        }
        let label = match a.get("label").and_then(Value::as_str) {
            Some(label) => format!("mcp: {label}"),
            None => format!("mcp: batch of {} steps", ops.len()),
        };
        let tools: Vec<String> = ops
            .iter()
            .map(|op| op["tool"].as_str().unwrap_or("").to_string())
            .collect();
        let r = self.lua_as("batch", json!({ "ops": ops }), Some(&label))?;
        let mut out = format!("Did {} steps as one undo step ({label}):\n", tools.len());
        let mut data = Vec::new();
        for (i, (tool, result)) in tools.iter().zip(items(&r["results"])).enumerate() {
            let shown = self.show(tool, result, meter);
            let _ = write!(
                out,
                "{}. {tool}: {}",
                i + 1,
                shown.text.trim_start_matches(['\n', ' '])
            );
            data.push(json!({ "tool": tool, "result": shown.data }));
        }
        format::messages(&mut out, &r["messages"]);
        Ok(Reply {
            text: out,
            data: json!({
                "label": label, "results": data, "edited": r["edited"], "messages": r["messages"],
            }),
        })
    }

    /// The answer of a writing tool, as text and as data.
    fn show(&self, name: &str, r: &Value, meter: Meter) -> Reply {
        let mut out = String::new();
        match name {
            "add_track" => {
                out.push_str("Added track:\n");
                format::track(&mut out, &r["track"], meter, false);
            }
            "set_track" => {
                out.push_str("Track now:\n");
                format::track(&mut out, &r["track"], meter, false);
            }
            "add_clip" => {
                out.push_str("Added clip ");
                format::clip(&mut out, &r["clip"], meter);
            }
            "edit_clip" => {
                let c = &r["clip"];
                out.push_str("Clip now: ");
                format::clip(&mut out, c, meter);
                if let Some(n) = c["removed_notes"].as_u64().filter(|n| *n > 0) {
                    let _ = writeln!(out, "({n} note{} removed)", if n == 1 { "" } else { "s" });
                }
                if let Some(n) = c["changed_notes"].as_u64().filter(|n| *n > 0) {
                    let _ = writeln!(out, "({n} note{} changed)", if n == 1 { "" } else { "s" });
                }
                let keys: Vec<&str> = items(&c["keys_used"]).iter().filter_map(Value::as_str).collect();
                if !keys.is_empty() {
                    let _ = writeln!(out, "(scale degrees counted in {})", keys.join(", "));
                }
                if c["notes"].is_null() && c["kind"] == "midi" {
                    out.push_str("(more than 64 notes: get_clip lists them)\n");
                }
            }
            "duplicate_clip" | "repeat_bars" => {
                let clips = items(&r["clips"]);
                let _ = writeln!(
                    out,
                    "Made {} cop{}:",
                    clips.len(),
                    if clips.len() == 1 { "y" } else { "ies" }
                );
                for c in clips {
                    let _ = writeln!(out, "  {}", format::clip_line(c, meter));
                }
                let skipped = items(&r["skipped"]);
                if !skipped.is_empty() {
                    let list: Vec<String> = skipped.iter().map(Value::to_string).collect();
                    let _ = writeln!(
                        out,
                        "Skipped clips that cross the stretch's edge: {}",
                        list.join(", ")
                    );
                }
            }
            "add_device" => {
                out.push_str("Added device:\n");
                format::device(&mut out, &r["device"], "", 48);
            }
            "set_device" => {
                out.push_str("Device now:\n");
                format::device(&mut out, &r["device"], "", 48);
            }
            "automate" => {
                if let Some(removed) = r["removed"].as_array() {
                    let _ = writeln!(
                        out,
                        "Removed {}",
                        removed
                            .iter()
                            .filter_map(Value::as_str)
                            .collect::<Vec<_>>()
                            .join(", ")
                    );
                } else {
                    let l = &r["lane"];
                    let _ = writeln!(
                        out,
                        "{} automation on track \"{}\" [id {}]{}:\n  {}",
                        if l["created"].as_bool() == Some(true) {
                            "New"
                        } else {
                            "Updated"
                        },
                        l["track_name"].as_str().unwrap_or(""),
                        l["track"],
                        l["device_name"]
                            .as_str()
                            .map(|n| format!(", device {n}"))
                            .unwrap_or_default(),
                        format::lane(l, meter)
                    );
                }
            }
            "set_project" => {
                let p = &r["project"];
                out = format::project_header(p, Meter::from_project(p));
                out.push('\n');
            }
            "marker" => {
                if let Some(removed) = r["removed"].as_array() {
                    let _ = writeln!(
                        out,
                        "Removed {}.",
                        removed
                            .iter()
                            .filter_map(Value::as_str)
                            .collect::<Vec<_>>()
                            .join(", ")
                    );
                } else if r["marker"].is_object() {
                    let _ = writeln!(out, "Marker: {}", format::marker_line(&r["marker"], meter));
                }
                let all = items(&r["markers"]);
                if all.is_empty() {
                    out.push_str("There are no markers or regions.\n");
                } else {
                    let _ = writeln!(out, "Markers and regions ({}):", all.len());
                    for m in all {
                        let _ = writeln!(out, "  {}", format::marker_line(m, meter));
                    }
                }
            }
            "remove" => {
                let removed: Vec<&str> = items(&r["removed"])
                    .iter()
                    .filter_map(Value::as_str)
                    .collect();
                out = format!("Removed {}.\n", removed.join(", "));
            }
            _ => {}
        }
        Self::reply(out, r, meter)
    }

    // --- transport, history and files ----------------------------------------

    fn transport(&mut self, a: &Map<String, Value>) -> Outcome {
        let meter = self.meter()?;
        let mut args = a.clone();
        for key in ["position", "loop_start", "loop_end"] {
            if let Some(v) = a.get(key) {
                args.insert(key.into(), json!(music::position(v, meter, key)?));
            }
        }
        let r = self.lua("transport", Value::Object(args))?;
        let out = format!("Transport: {}\n", format::transport(&r["transport"], meter));
        Ok(Self::reply(out, &r, meter))
    }

    fn undo(&mut self, a: &Map<String, Value>) -> Outcome {
        let r = self.lua("undo", Value::Object(a.clone()))?;
        let meter = Meter::default();
        if a.get("list") == Some(&json!(true)) {
            let mut out = String::new();
            let history = items(&r["history"]);
            if history.is_empty() {
                out.push_str("Nothing to undo: the history is empty.\n");
            } else {
                out.push_str("History, newest first (undo takes the first):\n");
                for h in history {
                    let _ = writeln!(out, "  {}", h["label"].as_str().unwrap_or(""));
                }
            }
            let redo = items(&r["redoable"]);
            if !redo.is_empty() {
                out.push_str("Redo would bring back, next first:\n");
                for h in redo {
                    let _ = writeln!(out, "  {}", h["label"].as_str().unwrap_or(""));
                }
            }
            return Ok(Self::reply(out, &r, meter));
        }
        let redo = a.get("redo") == Some(&json!(true));
        let steps = a.get("steps").and_then(Value::as_u64).unwrap_or(1);
        let done = r["done"].as_u64().unwrap_or(0);
        let (word, noun) = if redo { ("Redid", "redo") } else { ("Undid", "undo") };
        if done == 0 {
            return err(format!("Nothing to {noun}."));
        }
        let labels: Vec<&str> = items(&r["steps"]).iter().filter_map(Value::as_str).collect();
        let mut out = format!(
            "{word} {done} step{}: {}.\n",
            if done == 1 { "" } else { "s" },
            labels.join("; ")
        );
        if done < steps {
            let _ = writeln!(out, "(That was all there was to {noun}: you asked for {steps}.)");
        }
        out.push_str("get_project shows the project now.\n");
        Ok(Self::reply(out, &r, meter))
    }

    fn project_file(&mut self, a: &Map<String, Value>) -> Outcome {
        let action = a["action"].as_str().unwrap_or("");
        let mut args = json!({ "action": action, "discard": a.get("discard") });
        match action {
            "save" => {
                let path = match a.get("path").and_then(Value::as_str) {
                    Some(path) => self.output_path(path)?,
                    None => {
                        let p = self.kernel.call("project_get", json!([]))?;
                        match p["path"].as_str() {
                            Some(path) => self.write_path(path)?,
                            None => {
                                return err(
                                    "the project has never been saved: give a `path`, such as \"song.json\"",
                                );
                            }
                        }
                    }
                };
                args["path"] = json!(path);
            }
            "open" => {
                let path = a
                    .get("path")
                    .and_then(Value::as_str)
                    .ok_or_else(|| ToolError("open needs a `path`".into()))?;
                let path = self.read_path(path);
                if !path.is_file() {
                    return err(format!("no project file at {}", path.display()));
                }
                args["action"] = json!("load");
                args["path"] = json!(path);
            }
            _ => {}
        }
        let r = self.lua("file", args)?;
        let (out, meter) = match r["saved"].as_str() {
            Some(path) => (format!("Saved to {path}.\n"), Meter::default()),
            None => (
                format!(
                    "{}\n{}",
                    if action == "new" {
                        "Started a new project."
                    } else {
                        "Opened."
                    },
                    format::project(&r["project"])
                ),
                Meter::from_project(&r["project"]),
            ),
        };
        Ok(Self::reply(out, &r, meter))
    }

    // --- listening -----------------------------------------------------------

    fn render(&mut self, a: &Map<String, Value>) -> Outcome {
        let meter = self.meter()?;
        let stems = a.get("stems") == Some(&json!(true));
        if a.contains_key("region") && (a.contains_key("start") || a.contains_key("end")) {
            return err("give a `region` or `start` and `end`, not both");
        }
        if a.contains_key("format") && !stems {
            return err("`format` is for stems; for one file, its extension says the format");
        }
        let default = if stems { "stems" } else { "render.wav" };
        let path = self.output_path(a.get("path").and_then(Value::as_str).unwrap_or(default))?;
        let mut args = a.clone();
        args.insert("path".into(), json!(path));
        for key in ["start", "end"] {
            if let Some(v) = a.get(key) {
                args.insert(key.into(), json!(music::position(v, meter, key)?));
            }
        }
        args.remove("max_segments");
        let r = self.lua("render", Value::Object(args))?;
        let info = &r["render"];
        let (start, end) = (
            info["start"].as_f64().unwrap_or(0.0),
            info["end"].as_f64().unwrap_or(0.0),
        );
        let tail = num(a.get("tail").and_then(Value::as_f64).unwrap_or(1.0));
        let wav = |p: &Path| p.extension().is_some_and(|e| e.eq_ignore_ascii_case("wav"));
        let mut out = String::new();
        if stems {
            let files = items(&info["stems"]);
            let _ = writeln!(
                out,
                "Rendered {} stem{} of beats {} to {} (+{tail} s tail) into {}",
                files.len(),
                if files.len() == 1 { "" } else { "s" },
                format::at(start, meter),
                format::at(end, meter),
                path.display()
            );
            for f in files.iter().filter_map(Value::as_str) {
                let file = Path::new(f);
                let name = file.file_name().map_or(f.into(), |n| n.to_string_lossy());
                let levels = if wav(file) {
                    audio::read_wav(file).map(|w| audio::level_line(&w)).unwrap_or_else(|e| format!("{e:#}"))
                } else {
                    "not a WAV: levels are measured on WAV files".into()
                };
                let _ = writeln!(out, "  {name}: {levels}");
            }
        } else {
            let _ = writeln!(
                out,
                "Rendered beats {} to {} (+{tail} s tail) to {}",
                format::at(start, meter),
                format::at(end, meter),
                path.display()
            );
            if let Some(length) = info["project_length"].as_f64()
                && end > length + meter.bar()
            {
                let _ = writeln!(
                    out,
                    "Note: the end is {} beats after the last clip, so that part is silence.",
                    num(end - length)
                );
            }
            if let Some(line) = format::loudness(&r["loudness"]) {
                out.push_str(&line);
            }
            if wav(&path) {
                let audio = audio::read_wav(&path)?;
                let segments = Segments::Bars {
                    start_beat: start,
                    tempo: info["tempo"].as_f64().unwrap_or(120.0),
                    bar_beats: meter.bar(),
                    end_beat: end,
                };
                let max = a.get("max_segments").and_then(Value::as_u64).unwrap_or(32) as usize;
                out.push_str(&audio::analyze(&audio, segments, max)?);
            } else {
                out.push_str("(level per bar, stereo and spectrum are measured on WAV files; render a WAV to see them)\n");
            }
        }
        let mut reply = Self::reply(out, &r, meter);
        reply.data["path"] = json!(path.display().to_string());
        Ok(reply)
    }

    fn analyze_audio(&mut self, a: &Map<String, Value>) -> Outcome {
        let path = self.read_path(a["path"].as_str().unwrap_or(""));
        if !path.is_file() {
            return err(format!("no audio file at {}", path.display()));
        }
        let r = self.lua("analyze", json!({ "path": path }))?;
        let mut out = format!("{}: ", path.display());
        if path.extension().is_some_and(|e| e.eq_ignore_ascii_case("wav")) {
            let audio = audio::read_wav(&path)?;
            let seconds =
                audio.channels.first().map_or(0, Vec::len) as f64 / audio.sample_rate as f64;
            let piece = a
                .get("segment_seconds")
                .and_then(Value::as_f64)
                .unwrap_or_else(|| (seconds / 16.0).max(0.05));
            out.push_str(&audio::analyze(&audio, Segments::Seconds(piece), 128)?);
        } else {
            out.push('\n');
            out.push_str("(only WAV files are analysed for levels over time and spectrum)\n");
        }
        if let Some(line) = format::loudness(&r["loudness"]) {
            out.push_str(&line);
        }
        Ok(Self::reply(out, &r, Meter::default()))
    }

    fn escape(&mut self, tool: &str, args: Value) -> Outcome {
        let r = self.lua(tool, args)?;
        let mut out = String::new();
        match tool {
            "keys" => {
                let _ = writeln!(
                    out,
                    "Typed. Mode {}, focus {}{}",
                    r["mode"].as_str().unwrap_or("?"),
                    r["focused"].as_str().unwrap_or("?"),
                    r["pending"]
                        .as_str()
                        .filter(|p| !p.is_empty())
                        .map(|p| format!(", waiting for more after `{p}`"))
                        .unwrap_or_default()
                );
            }
            _ => match r["result"].as_str() {
                Some(text) if !text.is_empty() => {
                    let _ = writeln!(out, "{text}");
                }
                _ => out.push_str("Done (no result).\n"),
            },
        }
        if r["edited"].as_bool() == Some(true) {
            out.push_str("(the project changed: one undo step)\n");
        }
        Ok(Self::reply(out, &r, Meter::default()))
    }

    // --- paths ---------------------------------------------------------------

    /// A path to read from: relative ones start at the root.
    fn read_path(&self, raw: &str) -> PathBuf {
        normalize(&self.policy.root.join(raw))
    }

    /// A path to write to, refused outside the root unless allowed.
    fn write_path(&self, raw: &str) -> Result<PathBuf, ToolError> {
        if raw.trim().is_empty() {
            return err("the path is empty");
        }
        let path = self.read_path(raw);
        if self.policy.allow_any_path {
            return Ok(path);
        }
        let root = self
            .policy
            .root
            .canonicalize()
            .unwrap_or_else(|_| self.policy.root.clone());
        if !resolve_links(&path).starts_with(&root) {
            return err(format!(
                "refusing to write {}: it is outside the working directory {} (the server was not started with --allow-any-path). Use a relative path such as \"song.json\".",
                path.display(),
                root.display()
            ));
        }
        Ok(path)
    }

    /// [`write_path`](Self::write_path), with its directory made if needed.
    fn output_path(&self, raw: &str) -> Result<PathBuf, ToolError> {
        let path = self.write_path(raw)?;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)
                .map_err(|e| ToolError(format!("creating {}: {e}", dir.display())))?;
        }
        Ok(path)
    }
}

/// Remove `.` and `..` without touching the file system.
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

/// The path with every symbolic link in the part that exists resolved.
fn resolve_links(path: &Path) -> PathBuf {
    let mut rest = Vec::new();
    let mut base = path.to_path_buf();
    loop {
        if let Ok(real) = base.canonicalize() {
            let mut out = real;
            for part in rest.iter().rev() {
                out.push(part);
            }
            return out;
        }
        match (base.file_name(), base.parent()) {
            (Some(name), Some(parent)) => {
                rest.push(name.to_os_string());
                base = parent.to_path_buf();
            }
            _ => return path.to_path_buf(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arguments_are_checked() {
        let schema = &defs()
            .into_iter()
            .find(|d| d.name == "add_clip")
            .unwrap()
            .schema;
        let ok = json!({"track": "Bass", "start": "2.1", "notes": ["C4 0 1", {"pitch": "E4"}]});
        assert!(validate(schema, ok.as_object().unwrap()).is_ok());
        let typo = json!({"track": 1, "strat": 0});
        assert!(
            validate(schema, typo.as_object().unwrap())
                .unwrap_err()
                .0
                .contains("unknown argument `strat`")
        );
        let missing = json!({"start": 0});
        assert!(
            validate(schema, missing.as_object().unwrap())
                .unwrap_err()
                .0
                .contains("missing required argument `track`")
        );
        let wrong = json!({"track": 1, "notes": [{"pitch": "C4", "velocity": 300}]});
        assert!(
            validate(schema, wrong.as_object().unwrap())
                .unwrap_err()
                .0
                .contains("notes[0].velocity")
        );
    }

    #[test]
    fn paths_stay_inside_the_root() {
        let root = std::env::temp_dir().canonicalize().unwrap();
        let tools = Tools {
            kernel: Kernel::attach("/nonexistent".into(), std::time::Duration::from_secs(1)),
            policy: Policy {
                root: root.clone(),
                ..Policy::default()
            },
        };
        assert_eq!(tools.write_path("a/b.wav").unwrap(), root.join("a/b.wav"));
        assert!(tools.write_path("../x.wav").is_err());
        assert!(tools.write_path("/etc/x.json").is_err());
        assert!(tools.write_path("a/../../x.wav").is_err());
    }

    /// Walk every schema: nothing that some clients read wrongly.
    fn walk(schema: &Value, at: &str) {
        match schema {
            Value::Object(map) => {
                assert!(
                    !matches!(map.get("type"), Some(Value::Array(_))),
                    "{at}: a list of types; use anyOf"
                );
                assert!(!map.contains_key("prefixItems"), "{at}: prefixItems");
                assert_ne!(map.get("items"), Some(&json!(false)), "{at}: items: false");
                for (key, value) in map {
                    walk(value, &format!("{at}.{key}"));
                }
            }
            Value::Array(list) => list.iter().enumerate().for_each(|(i, v)| walk(v, &format!("{at}[{i}]"))),
            _ => {}
        }
    }

    #[test]
    fn schemas_use_only_what_every_client_reads() {
        for d in defs() {
            walk(&d.schema, d.name);
        }
        let find = |name: &str| defs().into_iter().find(|d| d.name == name).unwrap().schema;
        // The automation point is a pair whose items are numbers or strings.
        let points = &find("automate")["properties"]["points"]["items"];
        assert_eq!(points["type"], "array");
        assert_eq!(points["items"]["anyOf"][0]["type"], "number");
        // A pitch is a name or a MIDI number, never only an integer.
        let pitch = &find("add_clip")["properties"]["notes"]["items"]["anyOf"][1]["properties"]["pitch"];
        assert_eq!(pitch["anyOf"][0]["type"], "string");
        for name in BATCHABLE {
            assert!(defs().iter().any(|d| d.name == name), "{name}");
        }
    }

    #[test]
    fn data_names_what_a_musician_would() {
        let mut v = json!({
            "tracks": {},
            "clip": {"kind": "midi", "start": 8.0, "length": 4.0,
                     "notes": [{"id": 3, "pitch": 70, "start": 2.0, "length": 1.0, "velocity": 90}]},
            "marker": {"id": 1, "beat": 16.0, "region": true},
        });
        enrich(&mut v, Meter::default());
        assert_eq!(v["tracks"], json!([]));
        assert_eq!(v["clip"]["at"], "3.1");
        assert_eq!(v["clip"]["notes"][0]["name"], "A#4");
        assert_eq!(v["clip"]["notes"][0]["at"], "1.3");
        assert_eq!(v["marker"]["at"], "5.1");
    }

    #[test]
    fn an_undo_step_is_named_after_its_subject() {
        let a = json!({"name": "Bass", "volume": -3});
        assert_eq!(undo_label("add_track", a.as_object().unwrap()), "mcp: add_track Bass");
        let b = json!({"clip": 12});
        assert_eq!(undo_label("edit_clip", b.as_object().unwrap()), "mcp: edit_clip 12");
        assert_eq!(undo_label("set_project", &Map::new()), "mcp: set_project");
    }
}
