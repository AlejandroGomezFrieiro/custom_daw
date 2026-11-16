//! The tools: what a model sees (names, descriptions, input schemas) and what
//! each does. Arguments are checked against the tool's own schema first, then
//! normalized here (note names, positions, paths) and handed to the kernel
//! side in `mcp.lua` as one call, so each tool call is one kernel turn and,
//! when it writes, one undo step.

use std::fmt::Write as _;
use std::path::{Component, Path, PathBuf};

use serde_json::{Map, Value, json};

use crate::audio::{self, Segments};
use crate::format::{self, items};
use crate::kernel::{CallError, Kernel};
use crate::music::{self, Meter, num};

const LUA: &str = include_str!("mcp.lua");

/// What the server lets a model do beyond the typed tools.
#[derive(Clone, Debug, Default)]
pub struct Policy {
    /// Offer `run_command`, `send_keys` and `eval_lua`.
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

type Outcome = Result<String, ToolError>;

fn err<T>(msg: impl Into<String>) -> Result<T, ToolError> {
    Err(ToolError(msg.into()))
}

// --- schemas -------------------------------------------------------------------

const UNDO: &str =
    "Undoable: the whole call is one undo step, and a call that fails changes nothing.";

fn track_ref(what: &str) -> Value {
    json!({
        "type": ["integer", "string"],
        "description": format!("{what}: its id, its name (any unique part of it, ignoring case), or \"master\""),
    })
}

fn position(what: &str) -> Value {
    json!({
        "type": ["number", "string"],
        "description": format!("{what}. A JSON number is beats (quarter notes) from the start, 0 being the start; a string is \"bar.beat\" counting from 1 (\"3.1\" is the downbeat of bar 3, \"2.3.50\" half a beat after beat 3 of bar 2)"),
    })
}

fn length(what: &str) -> Value {
    json!({
        "type": ["number", "string"],
        "description": format!("{what}: beats as a number (1 is a quarter note), \"2 bars\", or a note value such as \"1/8\", \"1/16\" or dotted \"1/4.\""),
    })
}

fn notes_schema(what: &str) -> Value {
    json!({
        "type": "array",
        "description": format!("{what}. Each note is a string \"pitch start [length] [velocity]\" such as \"C4 0 1 100\", \"E4 2.5 1/8\", \"G4 2:1 1/4 90\" or a chord \"C4+E4+G4 2 2\", or an object. In strings the start is beats from the clip's start (\"2.5\"), or bar:beat within the clip with a colon (\"1:3\" = beat 3 of the clip's first bar). Length defaults to 1 beat, velocity to 100. Middle C is C4 (MIDI 60)."),
        "items": {
            "anyOf": [
                {"type": "string", "description": "\"pitch start [length] [velocity]\""},
                {
                    "type": "object",
                    "properties": {
                        "pitch": {"type": ["string", "integer", "array"], "description": "Note name (\"C4\", \"F#3\", \"Bb2\"), MIDI number, or a chord (\"C4+E4+G4\" or a list)"},
                        "start": {"type": ["number", "string"], "description": "Beats from the clip's start, or \"bar.beat\" within the clip"},
                        "length": {"type": ["number", "string"], "description": "Beats, or a note value like \"1/8\". Default 1"},
                        "velocity": {"type": "integer", "minimum": 1, "maximum": 127, "description": "1 to 127, default 100"}
                    },
                    "required": ["pitch"],
                    "additionalProperties": false
                }
            ]
        }
    })
}

fn device_spec() -> Value {
    json!({
        "anyOf": [
            {"type": "string", "description": "A device kind or a search such as \"synth\" or \"dragonfly hall\""},
            {
                "type": "object",
                "properties": {
                    "kind": {"type": "string", "description": "Device kind (\"synth\", \"clap:...\") or words to search for; the first match is used, built-in devices first"},
                    "params": {"type": "object", "description": "Parameter values by key or name, e.g. {\"cutoff\": 800, \"wave\": \"saw\"}", "additionalProperties": {"type": ["number", "string"]}},
                    "bypass": {"type": "boolean", "description": "Start bypassed"}
                },
                "required": ["kind"],
                "additionalProperties": false
            }
        ]
    })
}

fn clip_spec() -> Value {
    json!({
        "type": "object",
        "properties": {
            "name": {"type": "string", "description": "Clip name"},
            "start": position("Where the clip starts on the timeline"),
            "length": length("Clip length; default whole bars covering the notes"),
            "notes": notes_schema("The clip's notes"),
            "file": {"type": "string", "description": "An audio file (WAV, AIFF, FLAC, MP3, Ogg) for an audio clip instead of notes"},
        },
        "additionalProperties": false
    })
}

fn obj(properties: Value, required: &[&str]) -> Value {
    json!({
        "type": "object",
        "properties": properties,
        "required": required,
        "additionalProperties": false,
    })
}

struct ToolDef {
    name: &'static str,
    title: &'static str,
    description: String,
    schema: Value,
    read_only: bool,
    destructive: bool,
    escape: bool,
}

fn defs() -> Vec<ToolDef> {
    let mut d = Vec::new();
    let mut add = |name, title, description: String, schema: Value, read_only, destructive| {
        d.push(ToolDef {
            name,
            title,
            description,
            schema,
            read_only,
            destructive,
            escape: false,
        })
    };

    // --- reading ---
    add("get_project", "Read the project",
        "The whole session in one call: name, file, tempo, time signature, length, transport, and every track with its id, volume, pan, routing and sends, devices (id, kind), clips (id, position, length, note count and range) and automation lanes. Start here; ids it shows are what the other tools take. Reads only.".into(),
        obj(json!({}), &[]), true, false);
    add("get_track", "Read a track in detail",
        "One track in full: settings, routing, sends, every device with its parameters' current values, every clip, and automation lanes with their points. Reads only.".into(),
        obj(json!({"track": track_ref("The track")}), &["track"]), true, false);
    add("get_clip", "Read a clip's notes",
        "A clip and all its notes (pitch, start and length in beats from the clip's start, velocity), or an audio clip's file, offset and gain. Reads only.".into(),
        obj(json!({"clip": {"type": "integer", "description": "Clip id"}}), &["clip"]), true, false);
    add("get_device", "Read a device's parameters",
        "A device's parameters: key, name, current value, range, default, unit, and the choices of switch-like ones. Plugins can have hundreds: pass `filter` to see only matching ones. Reads only.".into(),
        obj(json!({
            "device": {"type": "integer", "description": "Device id"},
            "filter": {"type": "string", "description": "Only parameters whose key or name contains this text"}
        }), &["device"]), true, false);
    add("find_devices", "Search addable devices",
        "Search the devices and plugins (CLAP, LV2, VST3) that can be added to a track: every word must appear in the kind, name, vendor, category or format. Built-in devices come first: synth (subtractive synth), drums (General MIDI drum kit: 36 kick, 38 snare, 39 clap, 40 snare 2, 42 closed hat, 44 pedal hat, 46 open hat), gain, delay. Use it before add_device when you want a particular plugin. Reads only.".into(),
        obj(json!({
            "query": {"type": "string", "description": "Words to look for, such as \"reverb\", \"eq\", \"surge\". Empty lists everything"},
            "format": {"type": "string", "enum": ["builtin", "clap", "lv2", "vst3"], "description": "Only this format"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 200, "description": "At most this many (default 25)"},
            "params": {"type": "boolean", "description": "Also list each match's parameters (default false)"}
        }), &[]), true, false);
    add("get_status", "Transport and messages",
        "Where the transport is (playing, position, loop, metronome), the audio engine (backend, sample rate, CPU, dropouts), whether the project has unsaved changes, and the DAW's recent messages, warnings and errors. Reads only.".into(),
        obj(json!({"messages": {"type": "integer", "minimum": 0, "maximum": 100, "description": "How many recent messages (default 10)"}}), &[]), true, false);

    // --- writing ---
    add(
        "add_track",
        "Add a track",
        format!(
            "Add a track, and in the same call its devices (instrument first, then effects), clips with their notes, routing and sends. A MIDI track needs an instrument device such as `synth` or `drums` to make sound. Returns the new track with every id. {UNDO}"
        ),
        obj(
            json!({
                "name": {"type": "string", "description": "Track name"},
                "volume": {"type": "number", "description": "Fader in dB, -120 to 24 (default 0)"},
                "pan": {"type": "number", "description": "-1 left to 1 right (default 0)"},
                "output": track_ref("Route the track's output into this track instead of the master (for buses)"),
                "index": {"type": "integer", "minimum": 1, "description": "Position in the track list, from 1 (default last)"},
                "color": {"type": "string", "description": "Colour as #rrggbb"},
                "devices": {"type": "array", "items": device_spec(), "description": "Devices to add in chain order"},
                "clips": {"type": "array", "items": clip_spec(), "description": "Clips to add"},
                "sends": {"type": "array", "items": {"type": "object", "properties": {"target": track_ref("Track to send to"), "level": {"type": "number", "description": "Send level in dB (default 0)"}}, "required": ["target"], "additionalProperties": false}, "description": "Sends to other tracks (for shared reverbs and the like)"}
            }),
            &[],
        ),
        false,
        false,
    );
    add(
        "set_track",
        "Change a track",
        format!(
            "Change a track's name, volume, pan, mute, solo, colour, position, output routing or sends. Only what is given changes. `sends` replaces the whole list (pass [] to remove all). Returns the track as it is afterwards. {UNDO}"
        ),
        obj(
            json!({
                "track": track_ref("The track"),
                "name": {"type": "string", "description": "New name"},
                "volume": {"type": "number", "description": "Fader in dB, -120 to 24"},
                "pan": {"type": "number", "description": "-1 left to 1 right"},
                "mute": {"type": "boolean", "description": "Mute"},
                "solo": {"type": "boolean", "description": "Solo"},
                "color": {"type": "string", "description": "Colour as #rrggbb"},
                "index": {"type": "integer", "minimum": 1, "description": "Move to this position in the track list, from 1"},
                "output": track_ref("Route into this track; \"master\" for the master"),
                "sends": {"type": "array", "items": {"type": "object", "properties": {"target": track_ref("Track to send to"), "level": {"type": "number", "description": "Send level in dB (default 0)"}}, "required": ["target"], "additionalProperties": false}, "description": "The complete list of sends"}
            }),
            &["track"],
        ),
        false,
        false,
    );
    add(
        "add_clip",
        "Add a clip with notes",
        format!(
            "Add a MIDI clip with all its notes in one call, or an audio clip from a file. Returns the clip's id and its notes. To change notes later use edit_clip. {UNDO}"
        ),
        {
            let mut schema = clip_spec();
            schema["properties"]["track"] = track_ref("The track to put it on");
            schema["required"] = json!(["track"]);
            schema
        },
        false,
        false,
    );
    add(
        "edit_clip",
        "Change a clip or its notes",
        format!(
            "Change a clip: move it (start, or another track), resize, rename, mute; and edit its notes: remove some (by pitch and/or time range, or all), transpose, scale velocities, replace them all (`notes`) or add more (`add_notes`). Applied in that order. Note positions are relative to the clip's start. Returns the clip with its notes. {UNDO}"
        ),
        obj(
            json!({
                "clip": {"type": "integer", "description": "Clip id"},
                "name": {"type": "string", "description": "New name"},
                "start": position("New start on the timeline"),
                "length": length("New length"),
                "muted": {"type": "boolean", "description": "Mute the clip"},
                "track": track_ref("Move the clip to this track"),
                "gain": {"type": "number", "description": "Audio clips: gain in dB"},
                "remove_notes": {
                    "type": "object",
                    "description": "Remove notes matching all that is given: pitches, and a range of starts [from, to) within the clip",
                    "properties": {
                        "all": {"type": "boolean", "description": "Remove every note"},
                        "pitches": {"type": "array", "items": {"type": ["string", "integer"]}, "description": "Only these pitches (\"C4\", 60)"},
                        "from": position("Only notes starting at or after this point in the clip"),
                        "to": position("Only notes starting before this point in the clip")
                    },
                    "additionalProperties": false
                },
                "transpose": {"type": "integer", "description": "Semitones to move every remaining note by"},
                "velocity": {"type": "number", "exclusiveMinimum": 0, "description": "Multiply every remaining note's velocity by this (0.5 halves it)"},
                "notes": notes_schema("Replace all the clip's notes with these"),
                "add_notes": notes_schema("Notes to add to the clip")
            }),
            &["clip"],
        ),
        false,
        false,
    );
    add(
        "add_device",
        "Add a device or plugin",
        format!(
            "Add an instrument or effect to the end of a track's chain (or at `index`), optionally with parameter values. `kind` is an exact kind or words to search (find_devices shows what there is). Returns the device's id and all its parameters with ranges. {UNDO}"
        ),
        obj(
            json!({
                "track": track_ref("The track"),
                "kind": {"type": "string", "description": "Device kind (\"synth\", \"drums\", \"gain\", \"delay\", \"clap:...\") or words to search for"},
                "params": {"type": "object", "additionalProperties": {"type": ["number", "string"]}, "description": "Parameter values by key or name; a switch-like parameter also takes its choice's name (\"wave\": \"saw\")"},
                "index": {"type": "integer", "minimum": 1, "description": "Position in the chain, from 1 (default last)"},
                "bypass": {"type": "boolean", "description": "Add it bypassed"}
            }),
            &["track", "kind"],
        ),
        false,
        false,
    );
    add(
        "set_device",
        "Change a device",
        format!(
            "Set a device's parameters, bypass it, or move it in its chain or to another track. Values outside a parameter's range are clamped; the result shows the values as they are now. {UNDO}"
        ),
        obj(
            json!({
                "device": {"type": "integer", "description": "Device id"},
                "params": {"type": "object", "additionalProperties": {"type": ["number", "string"]}, "description": "Parameter values by key or name, e.g. {\"cutoff\": 1200, \"resonance\": 0.4, \"wave\": \"square\"}"},
                "bypass": {"type": "boolean", "description": "Bypass (true) or enable (false)"},
                "track": track_ref("Move the device to this track"),
                "index": {"type": "integer", "minimum": 1, "description": "Move to this position in the chain, from 1"}
            }),
            &["device"],
        ),
        false,
        false,
    );
    add(
        "automate",
        "Automate volume, pan or a parameter",
        format!(
            "Write automation: a track's volume (dB) or pan (-1..1), or a device parameter (give `device` and `param`), as points joined by straight lines and held before the first and after the last. Creates the lane if needed. By default the points replace the lane's; mode \"add\" merges them (a point replaces one at the same beat). Two points at one beat make a step. Can also turn a lane off or remove it. While playing or rendering an enabled lane overrides the fader or parameter. {UNDO}"
        ),
        obj(
            json!({
                "track": track_ref("The track (for volume or pan; optional with `device`)"),
                "target": {"type": "string", "enum": ["volume", "pan"], "description": "What to automate on the track (default volume); ignored when `device` is given"},
                "device": {"type": "integer", "description": "Automate a parameter of this device instead"},
                "param": {"type": "string", "description": "The device parameter's key or name"},
                "points": {"type": "array", "items": {"type": "array", "prefixItems": [{"type": ["number", "string"]}, {"type": "number"}], "items": false, "minItems": 2, "maxItems": 2}, "description": "[position, value] pairs; position in beats (number) or \"bar.beat\" (string); value in the target's units"},
                "mode": {"type": "string", "enum": ["replace", "add"], "description": "Replace the lane's points (default) or add to them"},
                "clear": {"type": "boolean", "description": "Remove every point first"},
                "enabled": {"type": "boolean", "description": "Turn the lane on or off (off keeps its points but stops moving the target)"},
                "remove": {"type": "boolean", "description": "Remove the lane altogether"}
            }),
            &[],
        ),
        false,
        false,
    );
    add(
        "set_project",
        "Tempo, signature, name",
        format!(
            "Set the project's tempo (BPM, 1 to 999) and time signature (\"3/4\", \"6/8\") at the start, the changes along the song, or its name. `tempo_changes` and `signature_changes` replace every change after the start; a tempo change with `ramp` moves linearly (in time) to the next change's tempo; a signature change starts a new bar where it is. Audio clips keep their length in seconds when the tempo changes. {UNDO}"
        ),
        obj(
            json!({
                "tempo": {"type": "number", "minimum": 1, "maximum": 999, "description": "Beats per minute"},
                "signature": {"type": "string", "description": "Time signature such as \"4/4\", \"3/4\", \"6/8\""},
                "name": {"type": "string", "description": "Project name"},
                "tempo_changes": {"type": "array", "description": "Tempo changes after the start, replacing those there are: [{\"at\": \"9.1\" or beats, \"bpm\": 90, \"ramp\": false}]; [] for one tempo throughout", "items": {"type": "object", "properties": {"at": {"type": ["number", "string"], "description": "Where: beats, or \"bar.beat\""}, "bpm": {"type": "number", "description": "Beats per minute from there on"}, "ramp": {"type": "boolean", "description": "Move linearly to the next change's tempo"}}, "required": ["at", "bpm"]}},
                "signature_changes": {"type": "array", "description": "Time signature changes after the start, replacing those there are: [{\"at\": \"9\" or beats, \"signature\": \"6/8\"}]", "items": {"type": "object", "properties": {"at": {"type": ["number", "string"], "description": "Where the new bar starts: beats, or \"bar\""}, "signature": {"type": "string", "description": "Such as \"6/8\""}}, "required": ["at", "signature"]}}
            }),
            &[],
        ),
        false,
        false,
    );
    add(
        "remove",
        "Remove tracks, clips, devices, lanes",
        format!(
            "Remove any number of tracks, clips, devices and automation lanes in one call. Removing a track removes its clips and devices; tracks routed into it fall back to the master. {UNDO}"
        ),
        obj(
            json!({
                "tracks": {"type": "array", "items": {"type": ["integer", "string"]}, "description": "Tracks, by id or name"},
                "clips": {"type": "array", "items": {"type": "integer"}, "description": "Clip ids"},
                "devices": {"type": "array", "items": {"type": "integer"}, "description": "Device ids"},
                "automation": {"type": "array", "items": {"type": "integer"}, "description": "Automation lane ids"}
            }),
            &[],
        ),
        false,
        true,
    );

    // --- transport, history and files ---
    add("transport", "Play, stop, seek, loop",
        "Control playback: play, stop, move the playhead, set and toggle the loop, the metronome. Playback is heard on the DAW's audio device (nothing with the null backend); to check how something sounds, use render instead. Not part of undo.".into(),
        obj(json!({
            "action": {"type": "string", "enum": ["play", "stop"], "description": "Start or stop playback (after the other settings are applied)"},
            "position": position("Move the playhead here"),
            "loop": {"type": "boolean", "description": "Turn looping on or off"},
            "loop_start": position("Loop start"),
            "loop_end": position("Loop end"),
            "metronome": {"type": "boolean", "description": "Metronome on or off"}
        }), &[]), false, false);
    add("undo", "Undo or redo",
        "Undo the last change (or `steps` changes), or redo with redo=true. Every typed tool call that wrote is one step; so is anything a person did in the DAW meanwhile. Returns the project as it is afterwards.".into(),
        obj(json!({
            "steps": {"type": "integer", "minimum": 1, "maximum": 100, "description": "How many steps (default 1)"},
            "redo": {"type": "boolean", "description": "Redo instead of undo"}
        }), &[]), false, false);
    add("project_file", "Save, open, new",
        "Save the project (to its file, or to `path`), open a project file, or start a new empty one. Opening and new replace the session and clear undo; they refuse while there are unsaved changes unless discard=true. Paths are relative to the server's working directory; saving outside it is refused unless the server was started with --allow-any-path.".into(),
        obj(json!({
            "action": {"type": "string", "enum": ["save", "open", "new"], "description": "What to do"},
            "path": {"type": "string", "description": "Project file (.json). Required to open; optional to save"},
            "discard": {"type": "boolean", "description": "Open or start anew even though unsaved changes will be lost"}
        }), &["action"]), false, true);

    // --- listening ---
    add("render", "Render and measure",
        "Render the project (or a stretch of it) to a WAV file, faster than real time, and measure it: duration, peak and RMS per channel, clipping, stereo correlation and width, level per bar, and octave-band spectrum with its centroid. Use it to check a mix: silence, clipping, a part too loud or quiet, too much low end. The file is written under the server's working directory unless --allow-any-path. RMS is a signal level, not LUFS.".into(),
        obj(json!({
            "path": {"type": "string", "description": "WAV file to write (default render.wav); overwritten if it exists"},
            "start": position("Where to start (default the start)"),
            "end": position("Where to stop (default the end of the last clip)"),
            "tail": {"type": "number", "minimum": 0, "description": "Seconds to keep rendering after the end, for release and echoes (default 1)"},
            "bits": {"type": "integer", "enum": [16, 24, 32], "description": "16 or 24 bit PCM, or 32 bit float (default 24)"},
            "sample_rate": {"type": "integer", "minimum": 8000, "maximum": 192000, "description": "Sample rate (default the engine's)"},
            "max_segments": {"type": "integer", "minimum": 1, "maximum": 128, "description": "At most this many level-over-time pieces; bars are grouped to fit (default 32)"}
        }), &[]), false, false);
    add("analyze_audio", "Measure an audio file",
        "Measure any WAV file, such as an earlier render or a sample, the same way render does: duration, peak and RMS per channel, stereo, level over time and spectrum. Reads only.".into(),
        obj(json!({
            "path": {"type": "string", "description": "WAV file"},
            "segment_seconds": {"type": "number", "exclusiveMinimum": 0, "description": "Length of each level-over-time piece (default: the file split into about 16)"}
        }), &["path"]), true, false);

    // --- escape hatches ---
    let escape = |name, title, description: String, schema| ToolDef {
        name,
        title,
        description,
        schema,
        read_only: false,
        destructive: true,
        escape: true,
    };
    d.push(escape("run_command", "Escape hatch: run a DAW command",
        "ESCAPE HATCH, for what the typed tools do not cover: run a command line as typed after `:` in the DAW, such as `track.add Bass device=synth`, `tempo 96`, `commands` or `lua <code>`. Commands act on the DAW's cursor and selection. Returns the command's result and any messages it showed. One undo step; not rolled back on failure. It can run Lua and write files: only offered with --allow-eval.".into(),
        obj(json!({"line": {"type": "string", "description": "The command line, without the leading `:`"}}), &["line"])));
    d.push(escape("send_keys", "Escape hatch: type keys",
        "ESCAPE HATCH: type keys into the DAW as a person would, in Neovim notation (`ggdd`, `<Space>`, `<C-r>`, `:tempo 90<CR>`). Acts on the focused view and the cursor; the result gives the mode and focus afterwards, and any messages. One undo step per call. Only offered with --allow-eval.".into(),
        obj(json!({"keys": {"type": "string", "description": "Keys in Neovim notation"}}), &["keys"])));
    d.push(escape("eval_lua", "Escape hatch: run Lua in the DAW",
        "ESCAPE HATCH: run Lua inside the DAW with the whole `daw` scripting interface (daw.tracks(), daw.project, daw.api.*, ...) and return what it returns, as text. An expression is returned as is (`daw.project.tempo`); statements need `return`. This is arbitrary code in the DAW's process, with its file and network access: only offered with --allow-eval. One undo step; not rolled back on failure.".into(),
        obj(json!({"code": {"type": "string", "description": "Lua code"}}), &["code"])));
    d
}

/// Instructions for the model, sent with `initialize`.
pub const INSTRUCTIONS: &str = "\
This server drives a session of a DAW (digital audio workstation). Conventions:
- Ids: tracks, devices, clips and automation lanes have numeric ids; get_project lists them. Tracks can also be named. The master track is id 0 or \"master\".
- Time: a JSON number is beats (quarter notes) from the start, 0 being the start; a string \"bar.beat\" counts from 1 (\"5.1\" is bar 5). Note starts are relative to their clip; in the compact note strings (\"C4 2.5 1/8 90\") the start is beats, or bar:beat with a colon (\"1:3\"). Lengths may be beats, \"2 bars\" or a note value \"1/8\" (a whole note is 4 beats).
- Pitches: note names with octave, middle C = C4 = MIDI 60; sharps # and flats b; chords as \"C4+E4+G4\".
- Volumes and send levels in dB, pan -1..1. Device parameters in each parameter's own range (get_device).
- Sound: a MIDI track needs an instrument device (built-in `synth` or `drums`, or a plugin) to make sound.
- Every typed write is one undo step and is rolled back if it fails; results show the state afterwards, so there is no need to read again.
- To check what you made, render it: the result measures levels, level per bar and spectrum.";

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

    /// Whether a tool of this name exists (an escape hatch exists, but may be off).
    pub fn exists(name: &str) -> bool {
        defs().iter().any(|d| d.name == name)
    }

    pub fn call(&mut self, name: &str, args: &Value) -> Outcome {
        let def = defs()
            .into_iter()
            .find(|d| d.name == name)
            .ok_or_else(|| ToolError(format!("unknown tool `{name}`")))?;
        if def.escape && !self.policy.allow_eval {
            return err(format!(
                "`{name}` is an escape hatch that runs arbitrary code in the DAW, and this server was started without --allow-eval. Use the typed tools, or ask the user to restart the server with --allow-eval."
            ));
        }
        let empty = Map::new();
        let args = match args {
            Value::Object(map) => map,
            Value::Null => &empty,
            _ => return err("arguments must be an object"),
        };
        validate(&def.schema, args)?;
        let notice = self.kernel.notice.take();
        let mut text = match name {
            "get_project" => self.get_project(),
            "get_track" => self.get_track(args),
            "get_clip" => self.get_clip(args),
            "get_device" => self.get_device(args),
            "find_devices" => self.find_devices(args),
            "get_status" => self.get_status(args),
            "add_track" => self.add_track(args),
            "set_track" => self.set_track(args),
            "add_clip" => self.add_clip(args),
            "edit_clip" => self.edit_clip(args),
            "add_device" => self.add_device(args),
            "set_device" => self.set_device(args),
            "automate" => self.automate(args),
            "set_project" => self.set_project(args),
            "remove" => self.remove(args),
            "transport" => self.transport(args),
            "undo" => self.undo(args),
            "project_file" => self.project_file(args),
            "render" => self.render(args),
            "analyze_audio" => self.analyze_audio(args),
            "run_command" => self.escape("command", json!({ "line": args["line"] })),
            "send_keys" => self.escape("keys", json!({ "keys": args["keys"] })),
            "eval_lua" => self.escape("lua", json!({ "code": args["code"] })),
            _ => err(format!("unknown tool `{name}`")),
        };
        // A kernel restarted under us is news whether the call worked or not.
        if let Some(notice) = notice.or_else(|| self.kernel.notice.take()) {
            match &mut text {
                Ok(t) | Err(ToolError(t)) => *t = format!("NOTE: {notice}\n{t}"),
            }
        }
        text
    }

    // --- plumbing ------------------------------------------------------------

    /// Run one tool of the kernel side.
    fn lua(&mut self, tool: &str, args: Value) -> Result<Value, ToolError> {
        Ok(self.kernel.eval(LUA, vec![json!(tool), args])?)
    }

    fn meter(&mut self) -> Result<Meter, ToolError> {
        Ok(Meter::from_project(
            &self.kernel.call("project_get", json!([]))?,
        ))
    }

    fn finish(out: &mut String, result: &Value) {
        format::messages(out, &result["messages"]);
    }

    // --- reading -------------------------------------------------------------

    fn get_project(&mut self) -> Outcome {
        let r = self.lua("project", json!({}))?;
        let mut out = format::project(&r["project"]);
        Self::finish(&mut out, &r);
        Ok(out)
    }

    fn get_track(&mut self, a: &Map<String, Value>) -> Outcome {
        let meter = self.meter()?;
        let r = self.lua("track", json!({ "track": a["track"] }))?;
        let mut out = String::new();
        format::track(&mut out, &r["track"], meter, true);
        Ok(out)
    }

    fn get_clip(&mut self, a: &Map<String, Value>) -> Outcome {
        let meter = self.meter()?;
        let r = self.lua("clip", json!({ "clip": a["clip"] }))?;
        let mut out = String::new();
        format::clip(&mut out, &r["clip"], meter);
        Ok(out)
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
        Ok(out)
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
        Ok(out)
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
        Ok(out)
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

    fn add_track(&mut self, a: &Map<String, Value>) -> Outcome {
        let meter = self.meter()?;
        let mut args = a.clone();
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
        let r = self.lua("add_track", Value::Object(args))?;
        let mut out = String::from("Added track:\n");
        format::track(&mut out, &r["track"], meter, false);
        Self::finish(&mut out, &r);
        Ok(out)
    }

    fn set_track(&mut self, a: &Map<String, Value>) -> Outcome {
        let meter = self.meter()?;
        let r = self.lua("set_track", Value::Object(a.clone()))?;
        let mut out = String::from("Track now:\n");
        format::track(&mut out, &r["track"], meter, false);
        Self::finish(&mut out, &r);
        Ok(out)
    }

    fn add_clip(&mut self, a: &Map<String, Value>) -> Outcome {
        let meter = self.meter()?;
        let mut args = self.clip_args(a, meter)?;
        args["track"] = a["track"].clone();
        let r = self.lua("add_clip", args)?;
        let mut out = String::from("Added clip ");
        format::clip(&mut out, &r["clip"], meter);
        Self::finish(&mut out, &r);
        Ok(out)
    }

    fn edit_clip(&mut self, a: &Map<String, Value>) -> Outcome {
        let meter = self.meter()?;
        let mut args = a.clone();
        if let Some(start) = a.get("start") {
            args.insert(
                "start".into(),
                json!(music::position(start, meter, "start")?),
            );
        }
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
        if let Some(Value::Object(r)) = a.get("remove_notes") {
            let mut remove = Map::new();
            if let Some(all) = r.get("all") {
                remove.insert("all".into(), all.clone());
            }
            if let Some(pitches) = r.get("pitches") {
                remove.insert("pitches".into(), json!(music::pitches(pitches)?));
            }
            for key in ["from", "to"] {
                if let Some(v) = r.get(key) {
                    remove.insert(key.into(), json!(music::position(v, meter, key)?));
                }
            }
            if remove.is_empty() {
                return err("remove_notes needs `all`, `pitches`, `from` or `to`");
            }
            args.insert("remove_notes".into(), Value::Object(remove));
        }
        let r = self.lua("edit_clip", Value::Object(args))?;
        let c = &r["clip"];
        let mut out = String::from("Clip now: ");
        format::clip(&mut out, c, meter);
        if let Some(n) = c["removed_notes"].as_u64().filter(|n| *n > 0) {
            let _ = writeln!(out, "({n} notes removed)");
        }
        if c["notes"].is_null() && c["kind"] == "midi" {
            out.push_str("(more than 64 notes: get_clip lists them)\n");
        }
        Self::finish(&mut out, &r);
        Ok(out)
    }

    fn add_device(&mut self, a: &Map<String, Value>) -> Outcome {
        let r = self.lua("add_device", Value::Object(a.clone()))?;
        let mut out = String::from("Added device:\n");
        format::device(&mut out, &r["device"], "", 48);
        Self::finish(&mut out, &r);
        Ok(out)
    }

    fn set_device(&mut self, a: &Map<String, Value>) -> Outcome {
        let r = self.lua("set_device", Value::Object(a.clone()))?;
        let mut out = String::from("Device now:\n");
        format::device(&mut out, &r["device"], "", 48);
        Self::finish(&mut out, &r);
        Ok(out)
    }

    fn automate(&mut self, a: &Map<String, Value>) -> Outcome {
        let meter = self.meter()?;
        let mut args = a.clone();
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
        let r = self.lua("automate", Value::Object(args))?;
        let mut out = String::new();
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
        Self::finish(&mut out, &r);
        Ok(out)
    }

    fn set_project(&mut self, a: &Map<String, Value>) -> Outcome {
        let mut args = a.clone();
        if let Some(sig) = a.get("signature").and_then(Value::as_str) {
            let (n, d) = music::signature(sig)?;
            args.remove("signature");
            args.insert("sig_num".into(), json!(n));
            args.insert("sig_den".into(), json!(d));
        }
        // Positions are read with the signatures as they are now.
        let meter = self.meter()?;
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
        let r = self.lua("set_project", Value::Object(args))?;
        let p = &r["project"];
        let mut out = format::project_header(p, Meter::from_project(p));
        out.push('\n');
        Self::finish(&mut out, &r);
        Ok(out)
    }

    fn remove(&mut self, a: &Map<String, Value>) -> Outcome {
        if a.values().all(|v| items(v).is_empty()) {
            return err("nothing to remove: give tracks, clips, devices or automation");
        }
        let r = self.lua("remove", Value::Object(a.clone()))?;
        let removed: Vec<&str> = items(&r["removed"])
            .iter()
            .filter_map(Value::as_str)
            .collect();
        let mut out = format!("Removed {}.\n", removed.join(", "));
        Self::finish(&mut out, &r);
        Ok(out)
    }

    fn transport(&mut self, a: &Map<String, Value>) -> Outcome {
        let meter = self.meter()?;
        let mut args = a.clone();
        for key in ["position", "loop_start", "loop_end"] {
            if let Some(v) = a.get(key) {
                args.insert(key.into(), json!(music::position(v, meter, key)?));
            }
        }
        let r = self.lua("transport", Value::Object(args))?;
        let mut out = format!("Transport: {}\n", format::transport(&r["transport"], meter));
        Self::finish(&mut out, &r);
        Ok(out)
    }

    fn undo(&mut self, a: &Map<String, Value>) -> Outcome {
        let r = self.lua("undo", Value::Object(a.clone()))?;
        let redo = a.get("redo") == Some(&json!(true));
        let steps = a.get("steps").and_then(Value::as_u64).unwrap_or(1);
        let done = r["done"].as_u64().unwrap_or(0);
        let word = if redo { "Redid" } else { "Undid" };
        let mut out = if done == 0 {
            format!("Nothing to {}.\n", if redo { "redo" } else { "undo" })
        } else if done < steps {
            format!("{word} {done} step(s); there was no more history.\n")
        } else {
            format!("{word} {done} step(s). The project now:\n")
        };
        out.push_str(&format::project(&r["project"]));
        Self::finish(&mut out, &r);
        Ok(out)
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
        let mut out = match r["saved"].as_str() {
            Some(path) => format!("Saved to {path}.\n"),
            None => format!(
                "{}\n{}",
                if action == "new" {
                    "Started a new project."
                } else {
                    "Opened."
                },
                format::project(&r["project"])
            ),
        };
        Self::finish(&mut out, &r);
        Ok(out)
    }

    // --- listening -----------------------------------------------------------

    fn render(&mut self, a: &Map<String, Value>) -> Outcome {
        let meter = self.meter()?;
        let path = self.output_path(
            a.get("path")
                .and_then(Value::as_str)
                .unwrap_or("render.wav"),
        )?;
        let mut args = json!({ "path": path });
        for key in ["start", "end"] {
            if let Some(v) = a.get(key) {
                args[key] = json!(music::position(v, meter, key)?);
            }
        }
        for key in ["tail", "bits", "sample_rate"] {
            if let Some(v) = a.get(key) {
                args[key] = v.clone();
            }
        }
        let r = self.lua("render", args)?;
        let info = &r["render"];
        let mut out = format!(
            "Rendered beats {} to {} (+{} s tail) to {}\n",
            format::at(info["start"].as_f64().unwrap_or(0.0), meter),
            format::at(info["end"].as_f64().unwrap_or(0.0), meter),
            num(a.get("tail").and_then(Value::as_f64).unwrap_or(1.0)),
            path.display()
        );
        let audio = audio::read_wav(&path)?;
        let segments = Segments::Bars {
            start_beat: info["start"].as_f64().unwrap_or(0.0),
            tempo: info["tempo"].as_f64().unwrap_or(120.0),
            bar_beats: meter.bar(),
            end_beat: info["end"].as_f64().unwrap_or(0.0),
        };
        let max = a.get("max_segments").and_then(Value::as_u64).unwrap_or(32) as usize;
        out.push_str(&audio::analyze(&audio, segments, max)?);
        Self::finish(&mut out, &r);
        Ok(out)
    }

    fn analyze_audio(&mut self, a: &Map<String, Value>) -> Outcome {
        let path = self.read_path(a["path"].as_str().unwrap_or(""));
        let audio = audio::read_wav(&path)?;
        let seconds = audio.channels.first().map_or(0, Vec::len) as f64 / audio.sample_rate as f64;
        let piece = a
            .get("segment_seconds")
            .and_then(Value::as_f64)
            .unwrap_or_else(|| (seconds / 16.0).max(0.05));
        let mut out = format!("{}: ", path.display());
        out.push_str(&audio::analyze(&audio, Segments::Seconds(piece), 128)?);
        Ok(out)
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
        Self::finish(&mut out, &r);
        Ok(out)
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

// --- argument checking ----------------------------------------------------------

/// Check arguments against a tool's schema: known names, required ones, and
/// JSON types, so a model hears about a typo instead of having it ignored.
fn validate(schema: &Value, args: &Map<String, Value>) -> Result<(), ToolError> {
    check_object(schema, args, "")
}

fn check_object(schema: &Value, args: &Map<String, Value>, at: &str) -> Result<(), ToolError> {
    let props = schema["properties"]
        .as_object()
        .cloned()
        .unwrap_or_default();
    for key in args.keys() {
        if !props.contains_key(key) && schema["additionalProperties"] == json!(false) {
            let known: Vec<&String> = props.keys().collect();
            return err(format!(
                "unknown argument `{at}{key}`; the arguments are: {}",
                known
                    .iter()
                    .map(|k| k.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
    }
    for key in items(&schema["required"]) {
        let key = key.as_str().unwrap_or("");
        if args.get(key).is_none_or(Value::is_null) {
            return err(format!("missing required argument `{at}{key}`"));
        }
    }
    for (key, value) in args {
        if value.is_null() {
            continue;
        }
        let sub = props.get(key).or_else(|| {
            schema["additionalProperties"]
                .is_object()
                .then_some(&schema["additionalProperties"])
        });
        if let Some(sub) = sub {
            check_value(sub, value, &format!("{at}{key}"))?;
        }
    }
    Ok(())
}

fn type_ok(ty: &str, value: &Value) -> bool {
    match ty {
        "string" => value.is_string(),
        "number" => value.is_number(),
        "integer" => {
            value.is_i64() || value.is_u64() || value.as_f64().is_some_and(|f| f.fract() == 0.0)
        }
        "boolean" => value.is_boolean(),
        "array" => value.is_array(),
        "object" => value.is_object(),
        "null" => value.is_null(),
        _ => true,
    }
}

fn check_value(schema: &Value, value: &Value, at: &str) -> Result<(), ToolError> {
    if let Some(options) = schema["anyOf"].as_array() {
        if options.iter().any(|o| check_value(o, value, at).is_ok()) {
            return Ok(());
        }
        // Report against the option of the right type, if one is.
        if let Some(o) = options.iter().find(|o| match &o["type"] {
            Value::String(t) => type_ok(t, value),
            _ => false,
        }) {
            return check_value(o, value, at);
        }
        return err(format!("`{at}` has the wrong type"));
    }
    let types: Vec<&str> = match &schema["type"] {
        Value::String(t) => vec![t.as_str()],
        Value::Array(ts) => ts.iter().filter_map(Value::as_str).collect(),
        _ => vec![],
    };
    if !types.is_empty() && !types.iter().any(|t| type_ok(t, value)) {
        return err(format!(
            "`{at}` must be {}, not {}",
            types.join(" or "),
            match value {
                Value::String(s) => format!("the string \"{s}\""),
                other => other.to_string(),
            }
        ));
    }
    if let Some(allowed) = schema["enum"].as_array()
        && !allowed.contains(value)
    {
        return err(format!(
            "`{at}` must be one of {}",
            allowed
                .iter()
                .map(Value::to_string)
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    if let Some(n) = value.as_f64()
        && (schema["minimum"].as_f64().is_some_and(|m| n < m)
            || schema["maximum"].as_f64().is_some_and(|m| n > m)
            || schema["exclusiveMinimum"].as_f64().is_some_and(|m| n <= m))
    {
        let mut range = Vec::new();
        if let Some(m) = schema["minimum"].as_f64() {
            range.push(format!("at least {}", num(m)));
        }
        if let Some(m) = schema["exclusiveMinimum"].as_f64() {
            range.push(format!("above {}", num(m)));
        }
        if let Some(m) = schema["maximum"].as_f64() {
            range.push(format!("at most {}", num(m)));
        }
        return err(format!("`{at}` must be {}, not {n}", range.join(" and ")));
    }
    match value {
        Value::Object(map)
            if schema["properties"].is_object() || schema["additionalProperties"].is_object() =>
        {
            check_object(schema, map, &format!("{at}."))
        }
        Value::Array(list) if schema["items"].is_object() => {
            for (i, item) in list.iter().enumerate() {
                check_value(&schema["items"], item, &format!("{at}[{i}]"))?;
            }
            Ok(())
        }
        _ => Ok(()),
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
}
