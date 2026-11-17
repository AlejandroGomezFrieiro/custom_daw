# Articulations

Which way each note is played (sustain, staccato, pizzicato, a trill),
written on the note itself, and told to whatever plays the track: a
sampler that reads MIDI 2.0, or any MIDI 1.0 instrument through its
keyswitches, controllers or programs.

```lua
daw.ext.load("/path/to/daw/extensions/articulations")
```

## What is kept where

The articulation is the note's **MIDI 2.0 attribute** (`note.attr = { type,
data }`), a code of the MIDI 2.0 Note-On Orchestral Articulation Profile
(M2-123): `11.0` staccato, `11.A` pizzicato, `13.2` a whole-step trill. It
is MIDI: it is copied, moved, undone and saved with the note, and plays
with this extension unloaded. A part moved to another instrument keeps its
meaning, and an instrument that lacks the very articulation plays the
nearest the profile names (another variation, then the same family, then
sustain).

What the codes are called on one instrument, and how that instrument is
told, is a **map**: one `.art.toml` file per instrument. Binding a map to a
track keeps the binding in the track (`track.meta.articulations`) and hands
the core its **downgrade map** (`track.attr_map`), which sends each note's
keyswitch, controller or program before it to an instrument that does not
take the attribute. The core never reads the TOML.

(Until the core keeps `note.attr` and `track.attr_map` itself, the
extension keeps the attribute in `note.meta.art` and the downgrade map
with the binding, read and written the same way.)

## A map

```toml
# Violin section of VSCO 2 CE, played by a keyswitched SFZ.
format = 1
name = "Violin section"
match = ["sfz:Violin Section KS.sfz"]  # what instrument it is for
range = "G3-A7"                       # the roll shades outside it
comfortable = "G3-E7"                 # and lightly outside this
keyswitches = "C1-A1"                 # rows labelled with articulations
default = "sustain"                   # what a note with no articulation plays
send = "change"                       # keyswitch only when it changes ("every": before every note)
chase = [1, 11, 64]

[art]
sustain    = { m2 = "10.0", out = "ks=C1",  tag = "sus", name = "Sustain",   class = "long" }
staccato   = { m2 = "11.0", out = "ks=D1",  tag = "stc", name = "Staccato",  class = "short", mark = "staccato" }
pizzicato  = { m2 = "11.A", out = "ks=E1",  tag = "pz",  name = "Pizzicato", class = "short-light", text = "pizz.", range = "G3-E7" }
harmonics  = { m2 = "14.0", out = "ks=A1 cc1=96", tag = "hrm", name = "Harmonics", class = "long-light", text = "harm." }

[mod]
con-sord   = { m2 = "mute=straight", out = "cc20=127", off = "cc20=0", text = "con sord." }
```

The whole example is in `articulations/examples/violin-section.art.toml`.
One inline table, one line, per articulation, in the order the popover
numbers them. `out` is a line of events: `ks=D1` a keyswitch note
(`ks=D1:127` with a velocity), `hold=D1` held while the articulation lasts,
`cc32=40`, `pc=12` (`pc=12/258` with a bank), `ch=2` the note on another
channel, `bend=0.5`, `attr` the attribute alone. `class` is a colour:
Reaticulate's classes (`long`, `short`, `legato`, `fx`, `textured`, each
`-light` or `-dark`) or `#rrggbb`. `mark` (`staccato`, `staccatissimo`,
`accent`, `tenuto`, `marcato`) and `text` (`pizz.`) are what the score shows.
Keys are named as paw names them: middle C is C4, 60.

Maps are looked for, the first of an id winning, in
`~/.config/daw/articulations/**`, beside a library (`Violins.art.toml` next
to `Violins.sfz`), in `articulations/` inside any loaded extension, and in
`~/.local/share/daw/articulations/generated/`. A map's id is its path there
without `.art.toml` (`examples/violin-section`); `:art.map` takes an id, the
end of one, a name or a file.

## In the piano roll

With a map bound, the roll sets itself up: rows outside the range are dark
and those outside the comfortable range dimmer; the keyswitch rows are
named by their articulations on the keyboard edge; each note with an
articulation takes its colour and its tag (`stc`) in place of its pitch; a
band above the ruler, `art`, shows the articulation of the clip's top line in
time, with the pen at its right; `K` on a note says "Pizzicato (11.A), sent
as ks=E1", or which articulation the profile's fallback plays.

| Keys | What |
| --- | --- |
| `\a` | the articulation of the note under the cursor, or of the selection (visual mode): a list, numbered, each heard on those notes as the highlight rests on it; Enter writes it as `:art <name>`, Esc leaves no trace |
| `\A` | a modifier of the map (`con sord.`) over the note or the selection: its controllers at the start, `off` at the end |
| `\a` in insert mode | the pen: the articulation notes are entered with from now on |
| `ia` `aa` | the run of notes with the articulation under the cursor (`aa` with the gap after it): `dia`, `yaa`, `v` `ia` |

Notes entered with the keys, in insert mode or by a click take the pen.

## Commands

| Command | What |
| --- | --- |
| `:art name` | the note under the cursor; with a range, its notes: `:'<,'>art stc`, `:5,8art pizz`, `:%art sus`, `:g/art=pz/art arco`; `none` takes it away; alone, the popover |
| `:art.default name` | what the track's notes without one play |
| `:art.pen name` | the articulation new notes get (`none`) |
| `:art.mod name` | a modifier over the range or the note |
| `:art.map [name]`, `:art.unmap`, `:art.maps` | bind a map (alone: the one whose `match` names a device of the track, else a list), take it away, list them all |
| `:art.generate [library]` | make a map from an `.sfz`, a `.dspreset` or `.dslibrary`, a folder of samples named by articulation, or (alone) a device that describes its instrument, and bind it |
| `:art.import file.reabank` | each bank of a Reaticulate file a map of its own, in `~/.config/daw/articulations/reaticulate` |
| `:art.export reabank [file]` | the track's map as a Reaticulate bank |
| `:art.new name` | a map to fill in |
| `:art.from-keyswitches` | keyswitch notes and CC32 (UACC) moves of the clip into the articulations of the notes after them |
| `:art.check` | the problems of the bound tracks' notes, in the quickfix list |

The `art` field matches and sets a note's articulation in patterns:
`:g/art=pz/`, `:s/art=stc/art=spc/`.

## Diagnostics

A note outside the range (the map's, or its articulation's own) is a
warning with the fix "move it an octave"; a note on a keyswitch row is a
warning with the fix "make the keyswitches the articulation of the notes
after them"; an articulation the map does not have plays by the profile's
fallback, and says so, with fixes to make it that one or take it away; a
chord of two articulations on a keyswitched instrument is a warning, since
the last keyswitch wins.

## Made from a library

| Source | What is read |
| --- | --- |
| SFZ | `sw_last` (and `sw_down`, held), `sw_label`, `label_keyN`, `sw_lokey` `sw_hikey`, `sw_default`, the keys of each switch's regions; through `#define` and `#include` |
| Decent Sampler | `<midi><note>` whose bindings enable groups: the key, and the names of the groups it enables; the groups' samples' keys |
| A folder | its folders that hold samples are articulations, the notes in the files' names their ranges (VSCO 2 CE's layout); played by the attribute alone |
| A sampler device | what `device_call(id, "describe")` answers: its articulations, keyswitches and range |
| Reaticulate | every bank of a `.reabank`: names, colours, icons, program numbers, `chase`, outputs (`cc`, `note`, `note-hold`, `program`, `pitch`, channels) |

Names get their codes from the words libraries use, icons first (`trill
m2` and `trill M2` differ only by case): of the 1426 articulations of
Reaticulate's 218 factory banks, 1283 get one (90 %), 120 of them from the
icon alone. What is left is mostly what the profile makes a controller
(`sul pont`, `con sord`) or a library's own word; it gets a code of the
library's own (classification 1A and up), and two articulations of one code
get two variations of it, so that every articulation can be chosen.

## With notation

When the notation extension is loaded too, a note's articulation shows in
the score as its `mark` (a staccato dot), and a run of notes starts with
its `text` (`pizz.`), with `ord.` where the default comes back. Writing a
mark in the score (`g'` a staccato) or a technique (`\p pizz.`, `arco`)
sets the attribute of the notes when the track's map has an articulation
with that mark or text; `daw.opt.art_from_notation = false` stops it.

## Not done

The window shows the tags and colours on the notes and the shaded and named
rows (as marks of the roll's layer), but not the band, the keyboard labels
or a menu of its own; the keyswitch rows are labelled and shaded, not
folded away; the score draws an articulation's mark in the same ink as a
written one; a modifier writes its MIDI 1.0 controllers, not the profile's
registered controllers.
