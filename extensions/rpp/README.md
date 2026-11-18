# rpp: a bridge to REAPER

Opens REAPER projects (`.rpp`) in paw, and writes the projects of paw as
`.rpp`. So work can move in both directions. Below is a reader and writer
of the file format, which scripts can use alone.

```lua
paw.ext.load("/path/to/paw/extensions/rpp")   -- or link it into ~/.config/paw/extensions
```

![A REAPER project opened with :rpp.import! and the list of what could not be carried over, then the project itself, and :w writes it back as .rpp](images/tui-rpp.gif)

## Try it

1. Type `:ext.load rpp`.
2. Type `:e song.rpp` with the path of a REAPER project. The tracks of the
   REAPER project appear in the arrange view.
3. Read the page that opens over them. It lists what paw could not bring
   across, by kind. If paw brought all of it, there is no page.
4. Type `:w copy.rpp`. The message tells how much paw wrote.
5. Open `copy.rpp` in REAPER. The tracks and the clips are there.

## How to

### How to open a REAPER project

Type `:e song.rpp`. The page that opens lists what paw could not bring
across, grouped by kind.

If the MIDI tracks are silent because their instrument stayed in REAPER,
type `:rpp.import song.rpp instrument=synth`. Each such track gets a
`synth`.

### How to add the tracks of a REAPER project to this project

Type `:rpp.import song.rpp merge=true`. The project keeps its own tempo
map.

### How to write a project for REAPER

Type `:w song.rpp`. The page that opens lists what paw could not write.

### How to edit a `.rpp` file from a script

```lua
local rpp = require("rpp")
local doc = rpp.read("song.rpp")
doc.project:set("TEMPO", 96, 4, 4, 0)
rpp.save(doc, "song.rpp")
```

Lines that you do not change keep their bytes.

## Reference

### Commands

| Command | Effect |
| --- | --- |
| `:rpp.import song.rpp` | replaces the project with the REAPER project. `merge=true` adds its tracks to the current project. `instrument=synth` gives a device of that kind to MIDI tracks whose instrument stayed behind, so you can hear them |
| `:rpp.export song.rpp` | writes the project as a REAPER project |
| `:edit song.rpp`, `:e song.rpp` | the same as `rpp.import`. Other files open as before |
| `:write song.rpp`, `:w song.rpp` | the same as `rpp.export`. Other files save as before |

After an import or an export, a page lists what paw could not bring
across, grouped by kind (plugins, takes, MIDI controllers, and other). The
message line tells how much came across. paw lists every item that it
drops.

```lua
local rpp = require("rpp")
local result = rpp.import("song.rpp", { instrument = "synth" })
print(result.report:text())            -- or result.report:data() as tables
rpp.export("out.rpp").report:empty()   -- true when paw wrote all of it
```

### The format

`rpp.parse(text)` gives a tree. `rpp.write(tree)` gives the text back.

- A tree with no changes writes the same bytes that it came from:
  indentation, quotes, number format, CRLF or LF.
- A changed or added line is written as REAPER writes it.
- The parser never fails. It keeps what does not fit (a `>` alone, a block
  that does not close) as it is.

```lua
local doc = rpp.read("song.rpp")
local project = doc.project                         -- the <REAPER_PROJECT block
project:getn("TEMPO")                               -- 120: the first argument as a number
project:set("TEMPO", 96, 4, 4, 0)                   -- replaces a line (or adds it)
for _, track in ipairs(project:blocks("TRACK")) do
  print(track:get("NAME"), track:child("VOLPAN"):argn(1))
  track:add(rpp.line("MUTESOLO", 1, 0, 0))
end
local fx = project:child("TRACK"):child("FXCHAIN"):child("VST")
fx:data_groups()                                    -- the base64 parts of the state of a plugin
rpp.save(doc, "song.rpp")
```

A node is `{ tokens = { name, args... }, children = {...} }`. Blocks have
children. Lines do not.

| Method | Effect |
| --- | --- |
| `name`, `arg(i)`, `argn(i)`, `set_args` | the tokens |
| `child(name)`, `all(name)`, `blocks(name)` | the children |
| `get(key, i)`, `getn(key, i)`, `set(key, ...)` | a line by its key |
| `add(node, index)`, `add_before(name, node)`, `remove`, `remove_all(name)` | add and remove nodes |
| `data()`, `data_groups()`, `set_data(groups, width)` | the base64 data of a block |
| `quoted(i...)` | always quotes these arguments, as REAPER does for paths |
| `walk(fn)` | calls `fn` on each node |

`rpp.format.quote` and `rpp.format.number` are the quotes and the number
format of REAPER. A token has no quotes, unless it is empty, holds a blank
or starts with a quote. Then it takes the first of `"`, `'` and `` ` `` that
it does not contain. The format has no escapes.

### What comes across

A REAPER project gives times in seconds. paw changes them to beats with the
tempo map of the project, and back.

| | REAPER → paw | paw → REAPER |
| --- | --- | --- |
| Tempo, time signature | The full tempo map: `TEMPO` and the `TEMPOENVEX` points. Square points become steps. Linear points become ramps (linear in time, as REAPER plays them), with their time signatures (packed as numerator + denominator × 65536). Other point shapes become ramps and are reported. When merged into an open project, the project keeps its own map | `TEMPO`, and `TEMPOENVEX` when the tempo or the signature changes along the song |
| Loop | Loop points (`SELECTION`) and the repeat switch (`LOOP`) | The same |
| Markers and regions | Into `project.meta.markers` and `project.meta.regions`: `{ id, name, beat, seconds, color }` and `{ id, name, start, length, seconds, color }`, in beats | From the same tables. Song sections (`project.meta.sections`) become regions, each to the start of the next |
| Tracks | Name, volume, pan, mute, solo, record arm, audio input and monitoring | The same |
| Folders | The children of a folder go into the folder track | A track that goes into the track above it (or into its folder) becomes a child of the folder. paw writes other routes into a track as a send from a track with its parent send off, and reports them |
| Sends | Receives (`AUXRECV`) become sends from the source track, at their level | Sends become receives, post-fader |
| Master | Volume, pan, mute, FX chain, volume and pan envelopes | The same |
| Audio items | A clip with the file (relative to the project folder, as REAPER finds it, also in the recording folder), position, length, start in the source (`SOFFS`, also the start of a section), item volume times take volume as the clip gain, mute. A looped item becomes one clip for each pass | Items with a `WAVE`, `FLAC`, `MP3` or `VORBIS` source. Paths under the folder of the project are relative to it |
| MIDI items | Notes from inline events and from `.mid` files, with velocity and channel (in `meta.channel` of the note), through the ticks per quarter note of the source. A source that ignores the project tempo runs at its own. Looped items repeat their source. Notes held over the item start begin at it, as REAPER plays them. Muted items stay muted | Inline events at 960 ticks per quarter note, channels from `meta.channel` |
| Automation | Volume and pan envelopes of tracks and the master, as lanes, on or off as in REAPER. Square points become steps | Volume and pan lanes |
| CLAP plugins | When installed here: the same plugin with the state that REAPER saved, which is the own state of the plugin | With their state |
| VST3 plugins | When installed here (found by name and vendor): the same plugin with its state, from the chunk of REAPER (paw checks the sizes first) | Only plugins that came from a REAPER project: paw keeps the header of REAPER for them, and puts the current state into it |
| LV2 plugins | When installed here: the same plugin with its control ports (`P` lines. The symbols of the ports are the parameter keys of paw) | With their control ports |
| Bypass | For each plugin, and a bypassed FX chain | For each plugin |
| Other plugins | VST2, JSFX, AU, DX, containers, and plugins that are not installed: a placeholder in `meta.rpp_placeholders` of the track (`name`, `format`, `position`, `reason`, and the text of REAPER for it), reported | Placeholders return into the chain at their places, as paw read them |

### What does not come across

paw lists these after each import or export.

- **REAPER → paw:**
  - tempo envelope points with shapes other than square and linear
  - inactive takes, fades, play rate (paw plays at 1x) and pitch shift
  - take pan, polarity and channel modes, take envelopes and stretch
    markers
  - MIDI controllers, pitch bend, aftertouch, program changes, sysex and
    text events, muted MIDI notes
  - envelopes other than the volume and pan of tracks and the master
    (width, mute, pre-FX, send envelopes, plugin parameter envelopes)
  - curve shapes other than linear and square (they become straight lines)
  - send modes other than post-fader (they become post-fader), send pan,
    send channel mapping, muted sends and MIDI-only sends
  - tracks whose master or parent send is off (in paw they play through
    their output), hardware outputs, frozen tracks
  - empty items, video, subprojects, other sources, media files that paw cannot find
  - LV2 state other than control ports, offline plugins, the volume of
    MIDI items
- **paw → REAPER:**
  - built-in devices (`synth`, `drums`, `gain`, `delay`) and other devices
    that are not plugins
  - VST3 plugins added in paw (paw does not know the id of REAPER for them)
  - LV2 state other than control ports, parameter automation of plugins,
    track colors
  - note attributes (MIDI 2.0 articulations: a REAPER project keeps MIDI
    1.0)
  - note times finer than 1/960 beat are rounded
- paw does not read the settings of a REAPER project that it has no place
  for (render settings, grid, view, metronome, project notes). It writes
  the defaults of REAPER for them.

### Tests

The suite runs `tests.lua`, with fixtures written by hand in `fixtures/`.
The tests cover:

- parse and rewrite
- an import, checked track by track and clip by clip
- MIDI times at three tempos, envelopes, the report
- an export, then an import, of a project made with the API
- plugins in all three formats
- a render of an imported project with audio and MIDI

The parser was checked on 24 project files saved by REAPER, up to 2.9 MB.
It gave the same bytes, and the same tokens after it wrote every line
again.

**Nobody opened the exported files in REAPER.** The tests read them back
with this parser. They compare each line key and its number of arguments
with projects that REAPER saved. All the keys occur in the files of REAPER,
except the pan envelope (`PANENV2`). No project here had one. paw writes it
as REAPER writes the volume envelope.

Two rules come from projects saved by REAPER 7.84, not from documentation:

- Volume envelope points are amplitudes in the file, also with
  `VOLTYPE 1`.
- Pan envelope points go from +1 (left) to -1 (right).
