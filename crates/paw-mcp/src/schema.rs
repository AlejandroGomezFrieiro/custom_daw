//! What a model sees of each tool: its name, description and input schema.
//!
//! The schemas stay in the plain subset every client reads: `anyOf` for a
//! value that may be of two kinds (never a list of types, which some clients
//! read as the first only), arrays with one `items` schema (never
//! `prefixItems`), and a description on every property.

use serde_json::{Value, json};

/// Tools that change the project: each is one undo step, and any of them may
/// be a step of a `batch`.
pub const BATCHABLE: [&str; 12] = [
    "add_track",
    "set_track",
    "add_clip",
    "edit_clip",
    "add_device",
    "set_device",
    "automate",
    "set_project",
    "marker",
    "duplicate_clip",
    "repeat_bars",
    "remove",
];

const UNDO: &str =
    "Undoable: the whole call is one undo step, and a call that fails changes nothing.";

/// Either of two kinds of value, as `anyOf`.
fn either(first: Value, second: Value, description: String) -> Value {
    json!({ "anyOf": [first, second], "description": description })
}

fn number() -> Value {
    json!({"type": "number"})
}

fn text() -> Value {
    json!({"type": "string"})
}

fn integer() -> Value {
    json!({"type": "integer"})
}

fn track_ref(what: &str) -> Value {
    either(
        integer(),
        text(),
        format!("{what}: its id, its name (any unique part of it, ignoring case), or \"master\""),
    )
}

fn position(what: &str) -> Value {
    either(
        number(),
        text(),
        format!("{what}. A JSON number is beats (quarter notes) from the start, 0 being the start; a string counts bars and beats from 1: \"3.1\" or \"3:1\" or \"bar 3 beat 1\" is the downbeat of bar 3, \"2.3.50\" half a beat after beat 3 of bar 2"),
    )
}

fn length(what: &str) -> Value {
    either(
        number(),
        text(),
        format!("{what}: beats as a number (1 is a quarter note), \"2 bars\", or a note value such as \"1/8\", \"1/16\" or dotted \"1/4.\""),
    )
}

fn marker_ref(what: &str) -> Value {
    either(
        integer(),
        text(),
        format!("{what}: its id, or its name (get_project lists them)"),
    )
}

fn pitch(what: &str) -> Value {
    json!({
        "anyOf": [
            {"type": "string"},
            {"type": "integer", "minimum": 0, "maximum": 127}
        ],
        "description": format!("{what}: a note name (\"C4\", \"F#3\", \"Bb2\", middle C is C4) or a MIDI number"),
    })
}

fn pitches(what: &str) -> Value {
    json!({
        "type": "array",
        "items": pitch("A pitch"),
        "description": what,
    })
}

fn notes_schema(what: &str) -> Value {
    json!({
        "type": "array",
        "description": format!("{what}. Each note is a string \"pitch start [length] [velocity]\" such as \"C4 0 1 100\", \"E4 2.5 1/8\", \"G4 2:1 1/4 90\" or a chord \"C4+E4+G4 2 2\", or an object. In strings the start is beats from the clip's start (\"2.5\"), or bar:beat within the clip with a colon (\"1:3\" = beat 3 of the clip's first bar); in objects a string start is bar.beat (\"1.3\") or bar:beat. Length defaults to 1 beat, velocity to 100. Middle C is C4 (MIDI 60)."),
        "items": {
            "anyOf": [
                {"type": "string", "description": "\"pitch start [length] [velocity]\""},
                {
                    "type": "object",
                    "description": "A note as an object",
                    "properties": {
                        "pitch": {
                            "anyOf": [
                                {"type": "string"},
                                {"type": "integer", "minimum": 0, "maximum": 127},
                                {"type": "array", "items": pitch("A pitch of the chord")}
                            ],
                            "description": "A note name (\"C4\", \"F#3\", \"Bb2\"), a MIDI number 0 to 127, or a chord (\"C4+E4+G4\" or a list of those)"
                        },
                        "start": either(number(), text(), "Beats from the clip's start, or \"bar.beat\" within the clip".into()),
                        "length": either(number(), text(), "Beats, or a note value like \"1/8\". Default 1".into()),
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
                "description": "A device with its settings",
                "properties": {
                    "kind": {"type": "string", "description": "Device kind (\"synth\", \"clap:...\") or words to search for; the first match is used, built-in devices first"},
                    "params": params_schema("Parameter values by key or name, e.g. {\"cutoff\": 800, \"wave\": \"saw\"}"),
                    "bypass": {"type": "boolean", "description": "Start bypassed"}
                },
                "required": ["kind"],
                "additionalProperties": false
            }
        ],
        "description": "A device by kind, or an object with its kind and parameters",
    })
}

fn params_schema(description: &str) -> Value {
    json!({
        "type": "object",
        "description": description,
        "additionalProperties": {
            "anyOf": [{"type": "number"}, {"type": "string"}],
            "description": "A number, or the name of a choice"
        },
    })
}

fn clip_spec() -> Value {
    json!({
        "type": "object",
        "description": "A clip",
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

fn send_spec(description: &str) -> Value {
    json!({
        "type": "array",
        "description": description,
        "items": {
            "type": "object",
            "description": "A send",
            "properties": {
                "target": track_ref("Track to send to"),
                "level": {"type": "number", "description": "Send level in dB (default 0)"}
            },
            "required": ["target"],
            "additionalProperties": false
        }
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

pub struct ToolDef {
    pub name: &'static str,
    pub title: &'static str,
    pub description: String,
    pub schema: Value,
    pub read_only: bool,
    pub destructive: bool,
    /// Runs code of the model's choosing: offered only with `--allow-eval`.
    pub escape: bool,
}

/// The note-range filter of `get_clip`.
fn note_filter() -> Value {
    json!({
        "from": position("Only notes starting at or after this point in the clip"),
        "to": position("Only notes starting before this point in the clip"),
        "pitches": pitches("Only these pitches"),
    })
}

pub fn defs() -> Vec<ToolDef> {
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
        "The whole session in one call: name, file, tempo, time signature, key, length, transport, markers and regions, and every track with its id, volume, pan, routing and sends, devices (id, kind), clips (id, position, length, note count and range) and automation lanes. Start here; ids it shows are what the other tools take. The result is also given as structured JSON. Reads only.".into(),
        obj(json!({}), &[]), true, false);
    add("get_track", "Read a track in detail",
        "One track in full: settings, routing, sends, every device with its parameters' current values, every clip, automation lanes with their points, and the engine's live meter for the track (-120 dB when nothing is playing: use render to measure a track's level). Reads only.".into(),
        obj(json!({"track": track_ref("The track")}), &["track"]), true, false);
    add("get_clip", "Read a clip's notes",
        "A clip and its notes (id, pitch, start and length in beats from the clip's start, velocity), or an audio clip's file, offset and gain. Note ids are what edit_clip takes to change one note. Filter a big clip with `from`, `to` and `pitches`. Reads only.".into(),
        {
            let mut properties = note_filter();
            properties["clip"] = json!({"type": "integer", "description": "Clip id"});
            obj(properties, &["clip"])
        }, true, false);
    add("get_device", "Read a device's parameters",
        "A device's parameters: key, name, current value, range, default, unit, and the choices of switch-like ones. Every device also has fx_wet and fx_gain (the dry/wet mix and gain around it). Plugins can have hundreds of parameters: pass `filter` to see only matching ones. Reads only.".into(),
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
        "Where the transport is (playing, position, loop, metronome), the audio engine (backend, sample rate, CPU, dropouts), whether the project has unsaved changes, and paw's recent messages, warnings and errors. Reads only.".into(),
        obj(json!({"messages": {"type": "integer", "minimum": 0, "maximum": 100, "description": "How many recent messages (default 10)"}}), &[]), true, false);
    add("find", "Find tracks, clips, notes by a query",
        "Find things in the project with paw's query language, a CSS selector over the project tree. Kinds: track, group, clip, note, cc, device, lane, point, marker, region. Tests in brackets: `[name~=pizz]` (regex), `=`, `!=`, `<`, `>=`, `^=` (starts with), `$=`, `*=`; pitches as c4, c#4 or 60; `a > b` is a b right inside an a, `a b` one anywhere inside it, `,` joins queries. Examples: `note[pitch>=c5]`, `clip[name~=riff] > note[vel>100]`, `track:has(device[kind=synth])`, `clip:has(note[pitch=c#5])`, `track[mute]`. Returns each match's kind, id, track, clip and a one-line description. Reads only.".into(),
        obj(json!({
            "query": {"type": "string", "description": "The query, such as `clip[name~=riff] > note[pitch>=c5]`"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 500, "description": "At most this many matches (default 50)"}
        }), &["query"]), true, false);
    add("diagnose", "Check the project for problems",
        "Look for what makes a project not sound as meant: empty tracks, MIDI tracks with no (or a bypassed) instrument, which are silent, empty clips, notes that start after their clip ends, plugins that did not load, sends and outputs to tracks that are gone or muted, automation outside its range, clips on the master, a soloed track; and what other tools in paw have reported. With `measure` it also renders the song and flags a silent mix, clipping, an over-hot true peak and tracks that clip, and gives the loudness. Returns findings with a severity (error, warning, info), a rule name and the track, clip or device concerned. Reads only (the render is not written).".into(),
        obj(json!({
            "track": track_ref("Only this track (default every track and the master)"),
            "measure": {"type": "boolean", "description": "Also render and measure the whole song for clipping, silence and loudness (takes as long as a render; default false)"}
        }), &[]), true, false);

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
                "sends": send_spec("Sends to other tracks (for shared reverbs and the like)")
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
                "sends": send_spec("The complete list of sends")
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
            "Change a clip: move it (start, or another track), resize, rename, mute; and edit its notes. Notes are named by the ids get_clip shows: remove some (`remove_notes`, by ids and/or pitch and/or time range, or all), change single notes (`edit_notes`: new pitch, start, length or velocity by id), transpose (semitones, or `degrees` along the project's key so that a third up stays in key), scale velocities (`velocity` multiplies) or set them (`set_velocity`: an absolute value, over all notes or a pitch/time range), replace all notes (`notes`) or add more (`add_notes`). Applied in that order. Note positions are relative to the clip's start. Returns the clip with its notes. {UNDO}"
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
                    "description": "Remove notes matching all that is given: ids, pitches, and a range of starts [from, to) within the clip",
                    "properties": {
                        "all": {"type": "boolean", "description": "Remove every note"},
                        "ids": {"type": "array", "items": {"type": "integer"}, "description": "Only these notes, by id"},
                        "pitches": pitches("Only these pitches (\"C4\", 60)"),
                        "from": position("Only notes starting at or after this point in the clip"),
                        "to": position("Only notes starting before this point in the clip")
                    },
                    "additionalProperties": false
                },
                "edit_notes": {
                    "type": "array",
                    "description": "Change single notes, each named by its id; only what is given changes",
                    "items": {
                        "type": "object",
                        "description": "One note's changes",
                        "properties": {
                            "id": {"type": "integer", "description": "The note's id (from get_clip)"},
                            "pitch": pitch("New pitch"),
                            "start": position("New start, from the clip's start"),
                            "length": length("New length"),
                            "velocity": {"type": "integer", "minimum": 1, "maximum": 127, "description": "New velocity"}
                        },
                        "required": ["id"],
                        "additionalProperties": false
                    }
                },
                "transpose": {
                    "anyOf": [
                        {"type": "integer"},
                        {
                            "type": "object",
                            "description": "Transpose in semitones and/or scale degrees",
                            "properties": {
                                "semitones": {"type": "integer", "description": "Semitones to move every remaining note by"},
                                "degrees": {"type": "integer", "description": "Scale degrees to move by, in the key: 2 is a third up, -4 a fifth down; notes outside the key keep their distance from the scale note below them"},
                                "key": {"type": "string", "description": "The key for `degrees`, such as \"D minor\" (default the project's key, else the key paw reads from the music at each note)"}
                            },
                            "additionalProperties": false
                        }
                    ],
                    "description": "Semitones (an integer) to move every remaining note by, or an object for scale degrees in the key: {\"degrees\": 2}"
                },
                "velocity": {"type": "number", "exclusiveMinimum": 0, "description": "Multiply every remaining note's velocity by this (0.5 halves it)"},
                "set_velocity": {
                    "type": "object",
                    "description": "Set velocities to one value, for all notes or those in a pitch and time range",
                    "properties": {
                        "value": {"type": "integer", "minimum": 1, "maximum": 127, "description": "The velocity"},
                        "pitches": pitches("Only these pitches"),
                        "from": position("Only notes starting at or after this point in the clip"),
                        "to": position("Only notes starting before this point in the clip")
                    },
                    "required": ["value"],
                    "additionalProperties": false
                },
                "notes": notes_schema("Replace all the clip's notes with these"),
                "add_notes": notes_schema("Notes to add to the clip")
            }),
            &["clip"],
        ),
        false,
        false,
    );
    add(
        "duplicate_clip",
        "Copy a clip",
        format!(
            "Copy a clip, with its notes and settings: right after the original by default, or at `at`, on another `track`, `times` times in a row. Returns the copies. {UNDO}"
        ),
        obj(
            json!({
                "clip": {"type": "integer", "description": "Clip id"},
                "at": position("Where the first copy starts (default right after the original)"),
                "track": track_ref("Put the copies on this track (default the same)"),
                "times": {"type": "integer", "minimum": 1, "maximum": 64, "description": "How many copies, one after another (default 1)"},
                "gap": {"type": "number", "minimum": 0, "description": "Beats of space between copies (default none)"}
            }),
            &["clip"],
        ),
        false,
        false,
    );
    add(
        "repeat_bars",
        "Repeat a stretch of the song",
        format!(
            "Copy every clip that lies wholly between two points (all tracks, or `tracks`) to later in the song, `times` times in a row, for arranging: repeat bars 1 to 8 as 9 to 16. A clip that crosses a boundary is skipped and named in the result. {UNDO}"
        ),
        obj(
            json!({
                "from": position("Start of the stretch"),
                "to": position("End of the stretch (the first point after it)"),
                "at": position("Where the first copy of the stretch starts (default right after it)"),
                "times": {"type": "integer", "minimum": 1, "maximum": 64, "description": "How many repeats, one after another (default 1)"},
                "tracks": {"type": "array", "items": track_ref("A track"), "description": "Only the clips of these tracks (default all)"}
            }),
            &["from", "to"],
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
                "params": params_schema("Parameter values by key or name; a switch-like parameter also takes its choice's name (\"wave\": \"saw\")"),
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
                "params": params_schema("Parameter values by key or name, e.g. {\"cutoff\": 1200, \"resonance\": 0.4, \"wave\": \"square\"}"),
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
                "points": {
                    "type": "array",
                    "description": "Points as [position, value] pairs: the position in beats (a number) or \"bar.beat\" (a string), then the value (a number) in the target's units, e.g. [[0, -40], [\"5.1\", 0]]",
                    "items": {
                        "type": "array",
                        "description": "One point: [position, value]",
                        "minItems": 2,
                        "maxItems": 2,
                        "items": {
                            "anyOf": [{"type": "number"}, {"type": "string"}],
                            "description": "First the position (beats or \"bar.beat\"), then the value (a number)"
                        }
                    }
                },
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
        "Tempo, signature, key, name",
        format!(
            "Set the project's tempo (BPM, 1 to 999) and time signature (\"3/4\", \"6/8\") at the start, the changes along the song, its key (\"D minor\", used by diatonic transpose and shown by get_project; \"\" clears it) or its name. `tempo_changes` and `signature_changes` replace every change after the start; a tempo change with `ramp` moves linearly (in time) to the next change's tempo; a signature change starts a new bar where it is. Audio clips keep their length in seconds when the tempo changes. {UNDO}"
        ),
        obj(
            json!({
                "tempo": {"type": "number", "minimum": 1, "maximum": 999, "description": "Beats per minute"},
                "signature": {"type": "string", "description": "Time signature such as \"4/4\", \"3/4\", \"6/8\""},
                "key": {"type": "string", "description": "The key, such as \"D minor\", \"F# dorian\", \"Bb\"; an empty text clears it"},
                "name": {"type": "string", "description": "Project name"},
                "tempo_changes": {"type": "array", "description": "Tempo changes after the start, replacing those there are: [{\"at\": \"9.1\" or beats, \"bpm\": 90, \"ramp\": false}]; [] for one tempo throughout", "items": {"type": "object", "description": "A tempo change", "properties": {"at": position("Where"), "bpm": {"type": "number", "description": "Beats per minute from there on"}, "ramp": {"type": "boolean", "description": "Move linearly to the next change's tempo"}}, "required": ["at", "bpm"]}},
                "signature_changes": {"type": "array", "description": "Time signature changes after the start, replacing those there are: [{\"at\": \"9\" or beats, \"signature\": \"6/8\"}]", "items": {"type": "object", "description": "A signature change", "properties": {"at": position("Where the new bar starts"), "signature": {"type": "string", "description": "Such as \"6/8\""}}, "required": ["at", "signature"]}}
            }),
            &[],
        ),
        false,
        false,
    );
    add(
        "marker",
        "Markers and regions",
        format!(
            "Name places and stretches of the song: add a marker at a position (with `length` it is a region, a named stretch), rename, move (and resize) or remove one, or list them all. Regions can be rendered (`render` with `region`) and looped (`transport` with `loop_marker`). Markers move with the beats when the tempo changes. {UNDO}"
        ),
        obj(
            json!({
                "action": {"type": "string", "enum": ["add", "rename", "move", "remove", "list"], "description": "What to do"},
                "marker": marker_ref("The marker or region (rename, move, remove)"),
                "name": {"type": "string", "description": "Its name (add, rename)"},
                "at": position("Where it is (add), or where it moves to (move)"),
                "length": length("Makes it a region of this length (add), or resizes one (move)"),
                "color": {"type": "string", "description": "Colour as #rrggbb (add)"}
            }),
            &["action"],
        ),
        false,
        false,
    );
    add(
        "remove",
        "Remove tracks, clips, devices, lanes",
        format!(
            "Remove any number of tracks, clips, devices, automation lanes and markers in one call. Removing a track removes its clips and devices; tracks routed into it fall back to the master. {UNDO}"
        ),
        obj(
            json!({
                "tracks": {"type": "array", "items": track_ref("A track"), "description": "Tracks, by id or name"},
                "clips": {"type": "array", "items": {"type": "integer"}, "description": "Clip ids"},
                "devices": {"type": "array", "items": {"type": "integer"}, "description": "Device ids"},
                "automation": {"type": "array", "items": {"type": "integer"}, "description": "Automation lane ids"},
                "markers": {"type": "array", "items": marker_ref("A marker or region"), "description": "Markers and regions, by id or name"}
            }),
            &[],
        ),
        false,
        true,
    );
    add(
        "batch",
        "Several changes as one undo step",
        format!(
            "Run several of the writing tools (add_track, set_track, add_clip, edit_clip, duplicate_clip, repeat_bars, add_device, set_device, automate, set_project, marker, remove) in order as ONE undo step, named `mcp: <label>`: if any step fails, none of them is kept. A later step may name what an earlier one made by name (a track by its name), not by id, since ids are only known afterwards; positions in `bar.beat` are read with the time signature as it is when the batch starts. Returns every step's result. {UNDO}"
        ),
        obj(
            json!({
                "label": {"type": "string", "description": "What the batch does, shown by undo's history (\"verse drums\")"},
                "steps": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 100,
                    "description": "The steps, in order",
                    "items": {
                        "type": "object",
                        "description": "One step: a writing tool and its arguments",
                        "properties": {
                            "tool": {"type": "string", "enum": BATCHABLE, "description": "The tool"},
                            "arguments": {"type": "object", "description": "Its arguments, as when it is called alone"}
                        },
                        "required": ["tool", "arguments"],
                        "additionalProperties": false
                    }
                }
            }),
            &["steps"],
        ),
        false,
        true,
    );

    // --- transport, history and files ---
    add("transport", "Play, stop, seek, loop",
        "Control playback: play, stop, move the playhead, set and toggle the loop (by position, or `loop_marker` to loop a region, or a marker up to the next marker), the metronome. Playback is heard on paw's audio device (nothing with the null backend); to check how something sounds, use render instead. Not part of undo.".into(),
        obj(json!({
            "action": {"type": "string", "enum": ["play", "stop"], "description": "Start or stop playback (after the other settings are applied)"},
            "position": position("Move the playhead here"),
            "loop": {"type": "boolean", "description": "Turn looping on or off"},
            "loop_start": position("Loop start"),
            "loop_end": position("Loop end"),
            "loop_marker": marker_ref("Loop this region (or the stretch from this marker to the next), and turn looping on"),
            "metronome": {"type": "boolean", "description": "Metronome on or off"}
        }), &[]), false, false);
    add("undo", "Undo, redo, history",
        "Undo the last change (or `steps` changes), or redo with redo=true; the result says what each step was (\"mcp: add_track Bass\"; a change made by a person in paw says so). With nothing to undo it fails. With list=true it changes nothing and lists the history, newest first, and what redo would bring back. Every writing tool call is one named step, and so is a batch.".into(),
        obj(json!({
            "steps": {"type": "integer", "minimum": 1, "maximum": 100, "description": "How many steps (default 1)"},
            "redo": {"type": "boolean", "description": "Redo instead of undo"},
            "list": {"type": "boolean", "description": "List the history instead of undoing"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 200, "description": "With list: how many entries (default 20)"}
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
        "Render the project (or a stretch of it) to a file, faster than real time, and measure it: duration, loudness in LUFS (integrated, short-term maximum, loudness range) and true peak, and, for WAV, peak and RMS per channel, clipping, stereo correlation and width, level per bar, and octave-band spectrum. The format is the file's extension: wav, flac, and mp3, ogg or opus when ffmpeg is installed. Choose the stretch with `region` (a marker region by name), or `start` and `end`; only some tracks with `tracks` (they play through what they pass through to the master, as when soloed); every track on its own with `stems` (then `path` is a directory). `loudness` (LUFS) and `normalize` (peak dB) bring the file to a level. The file is written under the server's working directory unless --allow-any-path.".into(),
        obj(json!({
            "path": {"type": "string", "description": "File to write (default render.wav; with stems, the directory, default stems); overwritten if it exists"},
            "start": position("Where to start (default the start)"),
            "end": position("Where to stop (default the end of the last clip)"),
            "region": marker_ref("Render this region (a named stretch made with the marker tool); instead of start and end"),
            "tracks": {"type": "array", "items": track_ref("A track"), "description": "Only these tracks, with what they pass through"},
            "stems": {"type": "boolean", "description": "One file per track in the directory `path`, named after the track (the tracks that are not muted and have clips, or `tracks`)"},
            "format": {"type": "string", "enum": ["wav", "flac", "mp3", "ogg", "opus"], "description": "With stems: the files' format (default wav); otherwise the path's extension decides"},
            "tail": {"type": "number", "minimum": 0, "description": "Seconds to keep rendering after the end, for release and echoes (default 1)"},
            "bits": {"type": "integer", "enum": [16, 24, 32], "description": "16 or 24 bit PCM, or 32 bit float (default 24)"},
            "sample_rate": {"type": "integer", "minimum": 8000, "maximum": 192000, "description": "Sample rate (default the engine's)"},
            "loudness": {"type": "number", "minimum": -70, "maximum": 0, "description": "Bring the integrated loudness to this level in LUFS, such as -14"},
            "normalize": {"type": "number", "maximum": 0, "description": "Bring the loudest sample to this level in dB, such as -1; with loudness, a ceiling"},
            "quality": {"type": "string", "enum": ["low", "medium", "high", "best"], "description": "For mp3, ogg and opus (default high)"},
            "max_segments": {"type": "integer", "minimum": 1, "maximum": 128, "description": "At most this many level-over-time pieces; bars are grouped to fit (default 32)"}
        }), &[]), false, false);
    add("analyze_audio", "Measure an audio file",
        "Measure an audio file, such as an earlier render or a sample: loudness in LUFS and true peak (any format paw reads), and for WAV also duration, peak and RMS per channel, stereo, level over time and spectrum. Reads only.".into(),
        obj(json!({
            "path": {"type": "string", "description": "Audio file"},
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
    d.push(escape("lua", "Escape hatch: run Lua in paw",
        "ESCAPE HATCH: run Lua inside paw with the whole `paw` scripting interface (paw.tracks(), paw.project, paw.api.*, ...) and return what it returns, as text. Read the manual and the API reference as resources (paw://reference/api, paw://reference/lua/<module>) first. An expression is returned as is (`paw.project.tempo`); statements need `return`. This is arbitrary code in paw's process, with its file and network access, which the typed tools' checks do not cover: a client should ask the person before running it. Only offered with --allow-eval. One undo step; not rolled back on failure.".into(),
        obj(json!({"code": {"type": "string", "description": "Lua code"}}), &["code"])));
    d.push(escape("run_command", "Escape hatch: run a paw command",
        "ESCAPE HATCH, for what the typed tools do not cover: run a command line as typed after `:` in paw, such as `track.add Bass device=synth`, `tempo 96`, `commands` or `lua <code>`. Commands act on paw's cursor and selection. Returns the command's result and any messages it showed. One undo step; not rolled back on failure. It can run Lua and write files: a client should ask the person first. Only offered with --allow-eval.".into(),
        obj(json!({"line": {"type": "string", "description": "The command line, without the leading `:`"}}), &["line"])));
    d.push(escape("send_keys", "Escape hatch: type keys",
        "ESCAPE HATCH: type keys into paw as a person would, in Neovim notation (`ggdd`, `<Space>`, `<C-r>`, `:tempo 90<CR>`). Acts on the focused view and the cursor; the result gives the mode and focus afterwards, and any messages. One undo step per call. A client should ask the person first. Only offered with --allow-eval.".into(),
        obj(json!({"keys": {"type": "string", "description": "Keys in Neovim notation"}}), &["keys"])));
    d
}

/// Instructions for the model, sent with `initialize`.
pub const INSTRUCTIONS: &str = "\
This server drives a session of paw (a personal audio workstation). Conventions:
- Ids: tracks, devices, clips, notes, markers and automation lanes have numeric ids; get_project lists most (get_clip lists note ids). Tracks and markers can also be named. The master track is id 0 or \"master\".
- Results: every tool answers in text and in structuredContent (JSON); prefer the JSON when you read values back.
- Time: a JSON number is beats (quarter notes) from the start, 0 being the start. A string counts bars and beats from 1, in any of \"5.1\", \"5:1\", \"bar 5 beat 1\" (bar 5, beat 1). Note starts are relative to their clip; in the compact note strings (\"C4 2.5 1/8 90\") a bare number is beats and bar:beat takes a colon (\"1:3\"). Lengths may be beats, \"2 bars\" or a note value \"1/8\" (a whole note is 4 beats).
- Pitches: note names with octave, middle C = C4 = MIDI 60; sharps # and flats b; chords as \"C4+E4+G4\".
- Volumes and send levels in dB, pan -1..1. Device parameters in each parameter's own range (get_device).
- Sound: a MIDI track needs an instrument device (built-in `synth` or `drums`, or a plugin) to make sound. diagnose says what will not be heard.
- Every typed write is one undo step named `mcp: ...` and is rolled back if it fails; use batch for several as one step. Results show the state afterwards, so there is no need to read again. undo says what it undid, and lists the history.
- To check what you made, render it: the result measures loudness (LUFS), peaks, level per bar and spectrum.
- The manual and an API reference are resources: paw://help/<page>, paw://reference/api, paw://reference/lua/<module>.";
