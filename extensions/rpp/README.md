# rpp: a bridge to REAPER

Opens REAPER projects (`.rpp`) in paw and writes paw's projects out
as `.rpp`, so work can move both ways. Underneath is a reader and writer for
the file format itself, which scripts can use on their own.

```lua
paw.ext.load("/path/to/paw/extensions/rpp")   -- or link it into ~/.config/paw/extensions
```

![A REAPER project opened with :rpp.import! and the list of what could not be carried over, then the project itself and :w writing it back as .rpp](images/tui-rpp.gif)

| Command | What it does |
| --- | --- |
| `:rpp.import song.rpp` | Replace the project with the REAPER project. `merge=true` adds its tracks to the current project instead; `instrument=synth` gives a device of that kind to MIDI tracks whose instrument stayed behind, so they can be heard. |
| `:rpp.export song.rpp` | Write the project as a REAPER project. |
| `:edit song.rpp`, `:e song.rpp` | The same as `rpp.import`. Other files open as before. |
| `:write song.rpp`, `:w song.rpp` | The same as `rpp.export`. Other files save as before. |

After either direction a page lists what could not be carried over, grouped
by kind (plugins, takes, MIDI controllers, ...), and the message line says
how much came across. Nothing is dropped without being listed there.

```lua
local rpp = require("rpp")
local result = rpp.import("song.rpp", { instrument = "synth" })
print(result.report:text())            -- or result.report:data() as tables
rpp.export("out.rpp").report:empty()   -- true when everything was written
```

## The format

`rpp.parse(text)` gives a tree; `rpp.write(tree)` gives the text back. A tree
that was not changed writes the same bytes it was read from (indentation,
quoting, number formatting, CRLF or LF); a line that was changed or added is
written the way REAPER writes it.

```lua
local doc = rpp.read("song.rpp")
local project = doc.project                         -- the <REAPER_PROJECT block
project:getn("TEMPO")                               -- 120: first argument as a number
project:set("TEMPO", 96, 4, 4, 0)                   -- replace a line (or add it)
for _, track in ipairs(project:blocks("TRACK")) do
  print(track:get("NAME"), track:child("VOLPAN"):argn(1))
  track:add(rpp.line("MUTESOLO", 1, 0, 0))
end
local fx = project:child("TRACK"):child("FXCHAIN"):child("VST")
fx:data_groups()                                    -- the base64 parts of a plugin's state
rpp.save(doc, "song.rpp")
```

A node is `{ tokens = { name, args... }, children = {...} }` (blocks have
children, lines do not). Methods: `name`, `arg(i)`, `argn(i)`, `set_args`,
`child(name)`, `all(name)`, `blocks(name)`, `get(key, i)`, `getn(key, i)`,
`set(key, ...)`, `add(node, index)`, `add_before(name, node)`, `remove`,
`remove_all(name)`, `data()`, `data_groups()`, `set_data(groups, width)`,
`quoted(i...)` (always quote these arguments, as REAPER does for paths),
`walk(fn)`. `rpp.format.quote` and `rpp.format.number` are REAPER's quoting
and number writing. Quoting follows REAPER: a token is bare unless it is
empty, holds a blank or starts with a quote, and then takes the first of `"`,
`'` and `` ` `` that it does not contain; there are no escapes.

The parser never fails: what does not fit (a stray `>`, an unclosed block) is
kept as it is. It was checked byte for byte, and token for token after
rewriting every line, on 24 project files saved by REAPER on the machine it
was written on, up to 2.9 MB.

## What is carried over

Times in a REAPER project are seconds; here they become beats by the
project's tempo map, and back.

| | REAPER → paw | paw → REAPER |
| --- | --- | --- |
| Tempo, time signature | The whole tempo map: `TEMPO` and the `TEMPOENVEX` points, square ones as steps and linear ones as ramps (linear in time, as REAPER plays them), with their time signatures (packed as numerator + denominator × 65536). Other point shapes become ramps and are reported. Merged into an open project, the project keeps its own map. | `TEMPO`, and `TEMPOENVEX` when the tempo or signature changes along the song. |
| Loop | Loop points (`SELECTION`) and the repeat switch (`LOOP`). | The same. |
| Markers and regions | Into `project.meta.markers` and `project.meta.regions`: `{ id, name, beat, seconds, color }` and `{ id, name, start, length, seconds, color }`, in beats. | From the same tables. |
| Tracks | Name, volume, pan, mute, solo, record arm, audio input and monitoring. | The same. |
| Folders | A folder's children are routed into the folder track. | A track routed into the track above it (or into a folder it is already in) becomes a folder child; any other routing into a track is written as a send from a track whose parent send is off, and reported. |
| Sends | Receives (`AUXRECV`) become sends from the source track, at their level. | Sends become receives, post-fader. |
| Master | Volume, pan, mute, FX chain, volume and pan envelopes. | The same. |
| Audio items | A clip with the file (relative to the project folder, as REAPER finds it, also in the recording folder), position, length, start in source (`SOFFS`, also a section's start), item volume times take volume as the clip gain, mute. A looped item becomes one clip per pass. | Items with a `WAVE`, `FLAC`, `MP3` or `VORBIS` source; paths under the project's folder are written relative to it. |
| MIDI items | Notes from inline events and from `.mid` files, with velocity and channel (kept in the note's `meta.channel`), through the source's ticks per quarter note; a source that ignores the project tempo runs at its own. Looped items repeat their source; notes held over the item start begin at it, as REAPER plays them. Muted items stay muted. | Inline events at 960 ticks per quarter note, channels from `meta.channel`. |
| Automation | Track and master volume and pan envelopes as lanes, on or off as in REAPER; square points become steps. | Volume and pan lanes. |
| CLAP plugins | When installed here: the same plugin with REAPER's saved state, which is the plugin's own. | With their state. |
| VST3 plugins | When installed here (found by name and vendor): the same plugin with its state, taken out of REAPER's chunk (the sizes are checked first). | Only plugins that came from a REAPER project: REAPER's header for them is kept, and the current state goes into it. |
| LV2 plugins | When installed here: the same plugin with its control ports (`P` lines; the ports' symbols are paw's parameter keys). | With their control ports. |
| Bypass | Per plugin, and a bypassed FX chain. | Per plugin. |
| Other plugins | VST2, JSFX, AU, DX, containers, and plugins not installed: a placeholder in the track's `meta.rpp_placeholders` (`name`, `format`, `position`, `reason`, and REAPER's text for it), reported. | Placeholders go back into the chain at their places, as they were read. |

## What is not

Listed after each import or export:

- **REAPER → here:** tempo envelope point shapes other than square and linear; inactive
  takes; fades; play rate (played at 1x) and pitch shift; take pan, polarity
  and channel modes; take envelopes and stretch markers; MIDI controllers,
  pitch bend, aftertouch, program changes, sysex and text events; muted MIDI
  notes; envelopes other than track and master volume and pan (width, mute,
  pre-FX, send envelopes, plugin parameter envelopes); curve shapes other than
  linear and square (made straight lines); send modes other than post-fader
  (made post-fader), send pan, send channel mapping, muted and MIDI-only
  sends; tracks whose master/parent send is off (here they still play through
  their output); hardware outputs; frozen tracks; empty items, video,
  subprojects and other sources; missing media; LV2 state beyond control
  ports; offline plugins; the volume of MIDI items.
- **Here → REAPER:** built-in devices (`synth`, `drums`, `gain`, `delay`)
  and other non-plugin devices; VST3 plugins added here (REAPER's id for them
  is not known); LV2 state beyond control ports; parameter automation of
  plugins; track colours; note times finer than 1/960 beat are rounded.
- REAPER project settings paw has no place for (render settings, grid,
  view, metronome, project notes) are not read, and are written as REAPER's
  defaults.

## How it was checked

The tests (`tests.lua`, run by `tests/suite.lua`; fixtures written by hand
in `fixtures/`) cover parsing and rewriting, an import checked track by track
and clip by clip, MIDI timing at three tempos, envelopes, the report, an
export then import of a project built with the API, plugins in all three
formats, and a render of an imported project with audio and MIDI.

**Exported files were not opened in REAPER.** They are checked by reading
them back with this parser, and by comparing every line key and its number
of arguments with projects REAPER saved: all of them occur in REAPER's own
files except the pan envelope (`PANENV2`), which no project available here
had; it is written like REAPER's volume envelope. Two rules came from
projects saved by REAPER 7.84 rather than from documentation: volume envelope
points are amplitudes in the file even with `VOLTYPE 1`, and pan envelope
points run from +1 (left) to -1 (right).
