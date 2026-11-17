# utau: singing synthesis

Vocal tracks whose notes and lyrics are sung by OpenUtau's engines (classic
UTAU voicebanks, DiffSinger, ENUNU, Vogen, VOICEVOX), through ReaUtau's
`reautau-engine`, with the core of ReaUtau's vocal editor.

```lua
local vocal = daw.track_kinds.add("vocal", { name = "Vocal", ask = false })
require("utau").configure(vocal.id, { singer = "Kitane sno act5 VCV" })
vocal:add_clip({ start = 0, length = 4, notes = {
  { pitch = "A3", start = 0, length = 1, meta = { lyric = "- あ" } },
  { pitch = "C4", start = 1, length = 1, meta = { lyric = "- い" } },
} })
daw.render("vocal.wav")   -- waits until every phrase is sung at final quality
```

The extension owns everything it is made of, and the core has no singing in
it:

```
extensions/utau/
  init.lua, lua/utau/   the vocal editor, the commands, the talk with the engine
  devices/utau.lua      the device that plays what was sung (a device written in Lua)
  engine/               the engine's C# source, on OpenUtau.Core (engine/README.md)
  nix/                  how the engine and the extension are built and packaged
```

## Enable it

In a Nix configuration, take paw with the extension built in: the engine,
OpenUtau and the Lua come with it, nothing else to install.

```nix
# home-manager, with this repository's flake as `paw`:
imports = [ paw.homeManagerModules.default ];
programs.paw = { enable = true; extensions = [ "utau" ]; };

# or a package of your own:
paw.packages.${system}.default.withExtensions (exts: [ exts.utau ])
```

`nix run .#paw-utau` runs it from the source tree. The extension is loaded at
startup from the package, whatever `init.lua` says; plain `nix run .` has no
.NET in it.

What else it needs:

- **Voicebanks** installed for OpenUtau, in `~/.local/share/OpenUtau/Singers`.
  The engine reads that folder (`utau_openutau_dir` or
  `$REAUTAU_OPENUTAU_DIR` points elsewhere), and keeps its own data in
  `~/.local/share/ReaUtau/openutau-data` and its render cache (with the AI
  pitch takes) in `~/.cache/ReaUtau`. `:utau.install` writes singers into
  that OpenUtau folder, as OpenUtau itself does.

Without the engine the device and the editor still work; nothing is sung,
and an offline render says so.

## Working on it

Without Nix packaging: link the extension into `~/.config/daw/extensions/utau`
(or `daw.ext.load("/path/to/daw/extensions/utau")` in `init.lua`); its device
is Lua and needs no build. The engine is found through the `utau_engine`
option, `$REAUTAU_ENGINE`, `bin/reautau-engine` beside the extension (where
the package puts it), `reautau-engine` on the `PATH`, or a ReaUtau install
in `~/.config/REAPER/UserPlugins/reautau-engine/`. `nix build .#utau-engine`
builds the engine alone from `engine/` (see engine/README.md for building it
with `dotnet`); point `utau_engine` at `result/bin/reautau-engine` to try a
change. The device is reloaded when its file changes (`:device.reload`).

The tests are in `tests.lua`, run by the suite (`tests/tools/suite.sh only
utau`); those that sing need the engine and a voicebank and say they were
skipped without them.

## Using it

A vocal track is a kind of track (`daw.track_kinds`): `:track.add vocal
[singer]`, `<leader>v` (`:utau.track [singer]`) or `:track.new` adds one,
and the window offers "New vocal track" wherever it makes a track.
`<leader>V` (`:utau.singer`) chooses its singer from a list. The header
shows `V` before the track's name, `K` and the window's header say who
sings, and Enter on a clip of a vocal track opens the vocal editor instead
of the piano roll. Opened without the extension, a vocal track is an
ordinary MIDI track.

| Keys | Vocal editor |
| --- | --- |
| `h` `j` `k` `l`, `<C-d>` `<C-u>` | move the cursor a grid step or a semitone, an octave |
| `w` `b`, `Tab` `S-Tab`, `0` `$`, `W` `B` | next and previous note, start and end of the clip, next and previous bar |
| `d` `y` `>` `<` `gl` with a motion, `in` `ib` `ic`, or a selection (`v` `V` `<C-v>`) | delete, yank, nudge or loop notes, as in the piano roll; the notes keep their lyrics and tuning |
| `p` `P` | paste after the note, or at the cursor |
| `/` | find a note by its lyric; `n` and `N` go on |
| `i` `x` | add a note, remove the note (`x` and `Del` remove the selected notes when there are some) |
| `c`, `Enter` | type the note's lyric: the first key replaces it, `Tab` keeps it and moves on to the next note, `S-Tab` to the previous one, `Enter` keeps it, `Esc` drops it. Pasting several words fills the notes from this one on |
| `+` `-` (`C-a` `C-x` with a count), `A-l` `A-h`, `H` `L` | up, down a semitone; lengthen, shorten; move: the selected notes, else the note under the cursor |
| `gA`, `ip` `ap` | select every note; the phrase as a text object (`yip`, `vap`) |
| `C-c`, `d` `x` | copy the selected notes (or the note), cut them; `p` `P` paste, keeping their pitches |
| `]c` `[c`, `:utau.curve <abbr>` | the curve shown under the notes: next, previous, by name |
| `}` `{` | raise or lower that curve at the cursor (the pitch by 10 cents, the others by a step of their own; a count multiplies) |
| `=`, `<leader>=` | put that curve back to its default under the note, in the whole clip |
| `(` `)` | choose the previous or next phoneme (shown in the phoneme row and the bottom line) |
| `[` `]` | that phoneme starts 5 ticks earlier or later |
| `gr`, `gR` | type the phoneme to sing instead of it; put it back as the voicebank has it |
| `~`, `:utau.note key=value ...` | vibrato on or off; set properties of the selected notes: `tuning`, `vibrato=on`, `length` `period` `depth` `in` `out` `shift` `drift` `vol_link`, `po` (phonemizer, `default` for the track's), `transition=default`, and any expression (`vel=120`) |
| `Space`, `gh` | play from the cursor or stop; hear the note under the cursor |
| `S`, `s`, `r` | choose the singer, show the lyric sheet, render again |
| `Esc`, `<C-w>p`, `<C-w>c` | forget the selection (the editor stays); back to the window before; close the editor |

The selection is one thing in both frontends: the notes inside a visual
selection while there is one, else the notes chosen with the pointer; every
key above that says "selected" works on it, and on the note under the cursor
when nothing is selected.

The editor shows each note's lyric, the phonemes the engine made of them in
the row underneath (red when the voicebank lacks one, orange when changed
here), the state of each phrase in the ruler (grey pending, yellow rendering,
blue draft, green final, red error), the pitch actually sung as a white line
across the rows (`▔`, `─` and `▁` for the upper, middle and lower third of a
semitone), the bends you drew as orange dots, and under the notes the chosen
curve in braille with its value at the cursor.

Notes are heard as they are placed or clicked: sung by the engine with the
track's voice when it is running and the track has a singer, else as a soft
tone (`daw.opt.utau_audition = false` turns it off).

The lyric sheet (`s`, `:utau.sheet`) shows the clip's lyrics one line per
phrase, with the note being sung highlighted; `c` retypes a line and the words
go to its notes in order, `K` splits Japanese into one kana per note.

| Command | |
| --- | --- |
| `utau.track [singer]`, `utau.voice` | add a vocal track; make the cursor track one |
| `utau.singer [name]`, `utau.phonemizer`, `utau.renderer`, `utau.resampler`, `utau.color` | the track's voice |
| `utau.edit`, `utau.sheet` | open the vocal editor, the lyric sheet |
| `utau.lyric <text>`, `utau.lyrics <words...>`, `utau.lyrics_file <path>` | lyrics of a note; of the notes from the cursor on; from a text file |
| `utau.vibrato`, `utau.tuning <cents>`, `utau.bend <cents>`, `utau.flatten` | per-note properties and pitch |
| `utau.batch [name]` | batch edits: `romaji_to_hiragana`, `kana_to_romaji`, `vcv_to_cv`, `remove_tone_suffix`, `remove_hint`, `dash_to_plus`, `lowercase`, `replace find=a replace=b`, `reset_pitch`, `clear_vibrato`, `vibrato_long`, `reset_exp`, `reset_phonemes`, `reset_po`, `reset_all`, `fix_overlap`, `fill_gaps`; `note=1` for the note under the cursor only |
| `utau.preset [name]` | tuning presets: breath at phrase starts, soft endings, swells, tension on high notes, overshoot and preparation on leaps, crisp consonants, vibrato styles, raspy, scream, growl, vocal fry, reset |
| `utau.import <file>` | an OpenUtau `.ustx`, UTAU `.ust`, VOCALOID `.vsqx`, Synthesizer V `.svp`, MIDI or MusicXML file as vocal tracks, read by OpenUtau's own code |
| `utau.render`, `utau.restart`, `utau.status` | render a track again, restart the engine, show what it is doing |

## In the graphical frontend

A double click on a clip of a vocal track opens the vocal editor in a window
of its own. It is painted by this extension (`lua/utau/gui.lua` and the
`gui_*.lua` panels beside it), through `daw.canvas`, and is the example of how
an extension makes a window.

| Where | With the pointer |
| --- | --- |
| Toolbar | the singer's name opens the list of singers; `Notes`, `Select` and `Pitch` choose the tool; `Curves` and `Inspector` show or hide those panels; then the grid and zoom |
| Ruler | click moves the playhead; the coloured line shows how far each phrase is rendered |
| Notes tool | drag on empty space draws a note; click a note selects it, Shift+click adds or takes it away, Ctrl+drag on empty space selects the notes in a box; drag a note to move the selection, its right edge to stretch it; double click types the lyric (Tab goes on to the next note), double click on empty space selects the phrase there; right click removes the note, or the selection it belongs to |
| Select tool | as the Notes tool, but a drag on empty space always draws a box |
| Pitch tool | draw over the notes to bend the pitch away from them (orange); right click a note to put its pitch back. Each note's transition points (green) are dragged; a double click on a note adds one, a right click removes one, Ctrl+click changes how the line leaves it (circle: ease in and out, diamond: straight, triangles: ease in, ease out). Ctrl+click a note switches its vibrato on or off; on the selected note its handles (start, fade in, fade out, depth, period, shift, drift) are dragged. The white line is the pitch that is sung |
| Phoneme row | drag a phoneme's start (the line on its left) to move it, Shift for single ticks; double click types the phoneme to sing instead; right click puts it back |
| Curve panel | the tabs choose the curve (a dot marks those with a lane); drag draws it, right drag puts it back to its default, double click puts it back under a note |
| Inspector | lyric, tuning, phonemizer, vibrato and its numbers, transition, per-note expressions, and the note's phonemes, for the selected notes (else the note under the cursor): drag a value sideways (Shift for small steps) or click it and type; right click puts it back; several words typed as the lyric go to the notes in order |
| Wheel | scrolls; with Shift sideways; with Ctrl it zooms; with Ctrl and Shift the rows grow or shrink |
| Keys | every key of the terminal editor; `Ctrl+V` pastes at the cursor here (in the terminal it selects a block) |

While the transport plays, the window and the terminal editor turn the page
to keep the playhead in sight.

## Tracks, files and the engine

| Command | |
| --- | --- |
| `utau.export <file> [all=1] [clip=1]` | the vocal track (every vocal track, the clip under the cursor) to OpenUtau's `.ustx`, UTAU's `.ust` or MIDI with lyrics (`.mid`), by the file's extension. A `.ust` holds one part: further parts go to `name-2.ust` and on |
| `utau.openutau` | write the vocal tracks to `<project>.ustx` beside the project file (`~/.local/share/daw/utau/openutau/` for a project not saved yet) and start OpenUtau on it: `daw.opt.utau_openutau`, else `$REAUTAU_OPENUTAU`, else `OpenUtau` |
| `utau.freeze`, `utau.unfreeze` | render the vocal track to audio on a track below it, "Vocal (frozen)", mute it and stop singing it; sing it again and remove the audio |
| `utau.singer_save <name>`, `utau.singer_preset [name]`, `utau.singer_delete <name>` | save the track's voice as a singer preset; give a track a preset (with no name, from a list); delete one |
| `utau.install <archive or folder>`, `utau.singers` | install a voicebank (zip, rar, 7z, uar, a folder), Vogen singer (`.vogeon`) or dependency package (`.oudep`); list the installed singers, and choose one for the track |
| `utau.harmony [3up\|3down\|5up\|4down\|6down\|8up\|8down] [key=Dm] [preset=name]`, `utau.double [take=2]` | a track under this one that sings a harmony in the key, or doubles it |
| `utau.ai_pitch [on\|off]` | AI pitch: the renderer's pitch model sings, and the drawn pitch is added on top |
| `utau.retake [new\|prev\|next\|info] [kind=timbre] [note=1] [whole=1]` | a new AI pitch (or timbre) take of the clip's phrases, or of the note under the editor's cursor; step back and forth between takes |
| `utau.timing [take]` | a timing take: the notes' onsets humanized by up to 18 ticks, the same for the same take; `0` takes it back |
| `utau.curve [abbr] [off=1]` | show a curve under the notes of the editor; one of the renderer's own (energy, voice colour blends, ...) is first given the lane of a device slot `x1` to `x8`; with no name, list them |
| `utau.unison <voices> [spacing= pitch= timing= level=]`, `utau.shift <semitones> [cents=]` | sing with several voices; sing higher or lower without moving the notes |

- **Export and import** go through the engine: `reautau-engine --export`
  builds the OpenUtau project from the same description the engine sings
  from and saves it with OpenUtau's writers; `--convert` reads it back with
  OpenUtau's readers. A `.ustx` comes back with the same notes, lyrics,
  note properties, singer and curves (to OpenUtau's whole-number grid).
  OpenUtau gives notes without pitch points its default ones.
- **Freezing** is the core's bounce (`daw.bounce`), after the engine has
  sung every phrase at final quality. The frozen track keeps its notes,
  curves and voice; the bounced file is in the project's media folder.
- **Singer presets** are JSON files in `~/.local/share/daw/utau/presets`
  (`daw.opt.utau_presets_dir`), in the shape of ReaUtau's, so presets from
  ReaUtau work here. A preset holds the singer, phonemizer, renderer,
  resampler, wavtool, voice colour, the engine's options (AI pitch, unison,
  shifts) and the value each curve holds where it has no lane; applying one
  replaces the track's voice whole.
- **Installing** runs `reautau-engine --install`, ReaUtau's installer, which
  finds the singer type and the file name encoding; a folder is copied into
  `Singers`. The singers go into OpenUtau's folder (`~/.local/share/OpenUtau`,
  or `utau_openutau_dir`), and the engine looks for singers again.
- **A harmony** is a copy of the track (voice, curves, lyrics and note
  properties), 3 dB quieter and panned 0.3 to one side, with the notes moved
  by scale degrees in the key: the project's key when the `musicops`
  extension has one set, else the key the melody is in
  (Krumhansl-Schmuckler). **A double** keeps the notes and moves each
  note's onset by up to 18 ticks and its tuning by up to 8 cents, the same
  each time for the same take.
- **AI pitch, retakes and the renderer's curves** are the engine's: the
  takes are kept in its cache across sessions. They are heard with
  DiffSinger and other renderers that have a pitch model or such curves; a
  classic UTAU voicebank sings the same with or without them.

## Where things are kept

Everything is ordinary project data, so it is saved, loaded and undone like
any other edit:

- **Notes** are the clip's notes. A note's lyric is `note.meta.lyric`; a note
  without one sings `daw.opt.utau_default_lyric` (`a`), and `R` is a rest.
- **Note properties** (tuning, vibrato, pitch transitions, phoneme overrides,
  expressions, phonemizer override) are `note.meta.utau`, in the shape
  `reautau-engine --convert` writes them (see `lua/utau/payload.lua`).
- **Curves** (pitch deviation `pitd`, dynamics `dyn`, tension, breathiness,
  gender, voicing, tone shift, growl, cross synthesis) are the parameters of
  the `utau` device (`lua:utau`): an automation lane on one is that curve,
  and a parameter set without a lane holds the curve at that value.
- **The kind** of a vocal track is `track.meta.kind = "vocal"`. A track
  with the device and no kind (made before kinds of track) is one too, and
  a project saved when the device was built into the program (kind `utau`)
  gets the Lua device.
- **The voice** (singer, phonemizer, renderer, resampler, wavtool, voice
  colour, other engine options) is `device.meta.utau`; so are which
  renderer curve each slot `x1` to `x8` draws (`curves`) and, for a frozen
  track, its audio track (`frozen`).
- **Curves follow their clip.** Move a vocal clip, on its track or to
  another vocal track, and the curves under it go with it; copy, duplicate
  or paste it and the copy gets a copy of them; delete it and they go
  (pasting it back brings them); split or trim it and they stay. This
  happens in the same undo step as the edit. A vocal clip carries its own id
  in `clip.meta.utau_clip`, which is how a copy knows its original.
- The device's `voice` parameter says which rendered audio it plays. The
  extension numbers the voices itself.

The rendered audio is not saved: the engine caches it, and a project that is
opened again is sung again from that cache.

## How it works

```
 Lua: extensions/utau                       reautau-engine (.NET, OpenUtau.Core)
   project ── snapshot/diff ── msgpack ─────▶ phonemize, render phrases
   editor  ◀── phonemes, sung pitch ────────
   phrase files, device_post("voice.N") ◀── PhraseAudio ─
          │
   devices/utau.lua (lua:utau) maps the files and plays each phrase at its time
```

- The extension starts `reautau-engine --socket <path>` with `daw.api.proc_spawn`
  and listens on that socket with `daw.api.sock_listen`; the engine connects,
  as it does to ReaUtau's REAPER extension, and the two speak ReaUtau's
  protocol (`docs/protocol.md` in ReaUtau), written here in Lua
  (`lua/utau/proto.lua`, `msgpack.lua`). The extension takes the place of the
  REAPER extension: after every edit it compares the vocal tracks with what it
  last sent and sends the difference.
- Rendered phrases come back as audio with their place in seconds. The
  extension writes each to a file of 32-bit floats (in
  `~/.cache/daw/utau-voices/<pid>`, gone when paw ends) and posts the list of
  a voice's files to every `utau` device (`daw.api.device_post(kind,
  "voice.<n>", list)`, `lua/utau/voices.lua`). Each device maps the files
  (`dsp.map`) in its own process and plays the phrases of its voice under
  the playhead; the sound is kept once, in the files. Superseded phrases are
  dropped by ReaUtau's rule: an old phrase keeps playing until its
  replacement arrives.
- A device made later, an offline render's own among them, is given the
  same lists before its first block, so it plays the same phrases. Phrases
  are placed by whole frames of the song, so what is played live and what
  is rendered agree bit for bit (`tests.lua` checks it), and a block of 512
  frames with four phrases sounding costs about 16 µs of the 10.7 ms it
  lasts.
- `daw.render` emits `render.before`; the extension then waits until every
  phrase of every vocal track is final before rendering starts, so offline
  renders are deterministic.
- A device that crashes is stopped alone, like any device written in Lua,
  and `:device.restart` brings it back with its voice.
- The engine runs only while there is a vocal track or an editor command
  needs it, and stops with paw.
- Curves follow clips by answering each clip edit with lane edits in the
  same turn, so the core puts both in one undo step; changes the core marks
  `restored` (undo, redo, opening a project) are only noted
  (`lua/utau/follow.lua`).

## What is not ported

From ReaUtau, not (yet) here:

- The expression pad, and a panel for curves that only one renderer has.
- Tracing the sung pitch into pitch points.
- In the terminal: moving pitch points and vibrato with keys (they are dragged in the window), and an inspector panel (`:utau.note` and the bottom line stand in for it).
- Expression graphs and their macro lanes.
- Taking a track back from OpenUtau over OpenUtau's DAW protocol: `:utau.openutau` writes the file and starts OpenUtau, and `:utau.import` reads back what was saved there.
- Several parts in one clip: a clip is a part.
- Clips that loop or play at another rate.
- Tempo ramps in OpenUtau: the engine and `.ustx` export get a ramp as steps of a quarter beat, each as long as that stretch of the ramp, and an import away from the song's start keeps the song's own tempo map.
- Curves following a clip through a ripple delete (`daw.opt.ripple`): the pieces after the cut move without their curves.
- Curves going with part of a clip: yanking and pasting a stretch of time that cuts a clip pastes its notes without its curves.
