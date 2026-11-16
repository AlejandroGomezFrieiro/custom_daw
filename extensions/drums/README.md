# drums

A drum track made in one step, and a grid to program it on whose rows are
the pieces of the kit, by name: in the terminal and in a window.

```lua
daw.ext.load("/path/to/daw/extensions/drums")
```

`extensions/drums/demo.lua` is a song to try it with
(`daw -e 'dofile("extensions/drums/demo.lua")'`).

## What a drum track is

An ordinary track whose clips are ordinary MIDI clips, so playback,
rendering, the piano roll, undo and the `pattern` extension work on them
as on any other. What makes it a drum track is a **drum map** kept with the
track in the project (`track.meta.drums`): which notes are which pieces, in
which order, with what names. The grid shows a clip through that map,
whatever plays it: the built-in kit, a kit of your own samples, or a plugin
such as MT-PowerDrumKit.

| Command | Keys | What it does |
| --- | --- | --- |
| `drums.track [name] [map=] [kit=] [bars=]` | `,kn` | A new track below the cursor's with the built-in `drums` kit, the General MIDI map, a name and a colour, and a bar to program, open in the grid. With `kit=<folder>` it plays samples instead |
| `drums.map [name]` | `,km` | Make the track under the cursor a drum track, whatever its instrument, with a map; with no name, choose one. `drums.map off` makes it an ordinary track again |
| `drums.edit` | `Enter` | Open the clip under the cursor in the grid. `Enter` (`clip.edit`) does this by itself on a drum track's clips, and the piano roll on others |
| `drums.kit <folder>` | | Play the drum track (or a new one) from a folder of sound files, by their names |
| `drums.pad level= pan= tune= group= file=` | | Change the sample of the grid's row |
| `drums.beat [name]` | `gb` in the grid | Fill the clip with a beat to start from, in place of its notes |
| `drums.rename <name>` | | Rename the grid's row under the cursor |

In the window, the timeline's right-click menu has **New drum track**, a
track header's has **Drum map…**, and a clip's has **Open in the drum grid**
and **Drum beat to start from…**.

**A plugin kit.** Put MT-PowerDrumKit (or any kit that follows the General
MIDI map) on a track, then `:drums.map gm-kit` (toms and two crashes) or
`:drums.map gm`. Its clips now open in the grid.

## Maps

Maps are plain tables in `require("drums").maps`; an `init.lua` can add one
or change one:

```lua
local maps = require("drums").maps
maps.mykit = { label = "My kit", rows = { { note = 36, name = "Kick" }, { note = "E2", name = "Snare" } } }
maps.gm.rows[2].name = "Snare (top)"
daw.opt.drums_map = "mykit"          -- what new drum tracks get
```

| Map | Rows |
| --- | --- |
| `gm` | the pieces a beat needs: kick, snare, rim, clap, closed, pedal and open hat, high, mid and low tom, crash, ride, ride bell, cowbell, tambourine |
| `gm-kit` | a drum kit as a drummer sets one up: two snares, five toms, two crashes, splash, china, ride and bell |
| `gm-full` | every General MIDI percussion note, 35 to 81 |

A track keeps a copy of its rows, so a project opens the same wherever it
goes. A note the map does not name still gets a row, at the bottom, named
after General MIDI and drawn dimmer, so nothing in a clip is hidden.

## The grid in the terminal

One row per piece with its name, one column per step, each hit drawn as
tall as it is hard (`▁` to `█`), in the track's colour; beats are shaded in
turn and bars marked. The title says the piece and place under the cursor,
the step, and how hard the hit there is.

| Keys | |
| --- | --- |
| `h` `l`, `j` `k` | a step, a row; counts work |
| `w` `b` | the next and previous hit on the row |
| `W` `B`, `0` `$` `^` | bars; the start and end of the clip, the row's first hit |
| `gg` `G`, `5G` | the first and last row, row 5 |
| `/snare` | go to a piece by name |
| `Enter` | put a hit in, or take it out; a new hit is heard |
| `+` `-` (or `]` `[`) | harder and softer, by 16 (a count multiplies) |
| `]g` `[g` | coarser and finer steps; `T` triplets, or straight again |
| `&`, `3&` | repeat the bar the cursor is in to the end of the clip, or three times |
| `dd`, `x` | clear the row; remove the hit |
| `d` `y` `>` `<` | operators: delete, yank, move a step later or earlier |
| `gs` | swing: every other step later by `drums_swing` of a step (`50gs` half a step). Hits already swung are not moved again |
| `p` `P` | paste after or at the cursor; a block lands on the rows under the cursor |
| `gh`, `gp`, `gb` | hear the piece; playhead to the cursor; a beat to start from |
| `Esc` | back to the arrange view |

Text objects: `ih` the cell, `ir` the row, `ib` the bar on every row, `ic`
every hit. Visual mode: `v` a stretch of time on every row, `Ctrl-v` a
block, `V` whole rows; then `x`, `+` `-`, `gs`, `y`, `p`. Registers, counts,
`.` and macros work as everywhere.

## The grid in a window

The same editor, opened by a double click on a drum track's clip (never on
another track's), from the clip's menu, or with any of the commands above
when a graphical frontend is attached.

- Click a cell for a hit, click a hit to take it out; right click removes.
- Drag along a row: from an empty cell it paints hits, from a hit it
  erases, on that row only wherever the pointer wanders; the whole stroke is
  one undo step.
- The velocity lane under the grid shows how hard each hit of the selected
  row is; click or drag across it to set them.
- Click a row's name to hear the piece.
- The toolbar plays the clip round and round, sets the step (1/4 to 1/32,
  1/8 and 1/16 triplets), and the clip's length in bars.
- The ruler moves the playhead; the playhead moves across while it plays.
- The wheel scrolls the rows, with Shift sideways, with Ctrl it zooms.

Every key of the terminal grid works in the window.

## Kits

The built-in `drums` device plays the fifteen pieces of `gm` (and the rest
of `gm-kit`: second snare, floor toms, second crash, china, splash, second
ride), all synthesized. The closed and pedal hat cut the open hat off.

The built-in `sampler` device plays one sound file per note, each with a
level, a pan, a tuning, and a group: pads of the same group cut each other
off. `:drums.kit ~/samples/808` makes one from the files in a folder by
their names (`kick`, `BD`, `snare`, `hh closed`, `OpenHat`, `pedal hat`,
`tom lo`, `ride bell`, `cowbell`, `tamb`, ...); the hats share a group, and
files it does not recognise go on notes from 60 up. The grid's rows are
named after the files. The kit is the device's state, so it is saved in
the project, undone like any edit and heard in renders; the files are read
when the project opens, and `daw.api.device_call(id, "status")` says which
were found.

```lua
local kit = require("drums.kit")
kit.build(track, "~/samples/808")
kit.set_pad(kit.device(track), 38, { level = -3, pan = 0.2, tune = -1 })
kit.pads(kit.device(track))       -- { { note, file, level, pan, tune, group }, ... }
```

## Options

| Option | Default | |
| --- | --- | --- |
| `drums_map` | `"gm"` | the map new drum tracks get |
| `drums_step` | `0.25` | beats a column of the grid is |
| `drums_velocity` | `100` | how hard a new hit is |
| `drums_swing` | `0.33` | how far `gs` moves every other step, as part of a step |
