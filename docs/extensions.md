# Extensions

## Core and plugins

Two things are kept apart, and the rule that separates them is short.

**The core** is what an extension could not add: the audio engine, the
project model, plugin hosting, the `daw.api` functions, and the runtime in
`runtime/lua/daw` that turns those into objects, commands, keys and views. It
is compiled into the binary and is the same for everyone.

**A plugin** (an extension) is everything that can be written against that
interface. It lives in a directory of its own, is loaded only if asked for,
and can be deleted without the rest noticing. The core never requires one.

| In the core | Why it is there |
| --- | --- |
| Tracks, routing, sends before or after the fader, buses | the engine mixes |
| Clips, notes, controller moves, fades, automation lanes | the model, and what the engine plays |
| Delay compensation, the limiter and the other built-in devices | the engine runs them |
| CLAP, LV2 and VST3 hosting, plugin windows | native code, and the audio thread |
| MIDI 1.0 and 2.0 input, recording, the recording offset | ports and the audio thread |
| Rendering: stems, dither, normalizing | the engine, offline |
| Undo as a tree, safety copies and recovery | the model, and not losing work |
| Modal keys, the picker, the views | what everything else is driven with |

| Plugin | What it adds |
| --- | --- |
| `extensions/utau` | singing synthesis: vocal tracks, a vocal editor, the device that plays the singing and the engine that sings (see below) |
| `extensions/sections` | named sections of the song as text objects, and arranging by section |
| `extensions/musicops` | musical operators: humanize, strum, arpeggiate, scales |
| `extensions/pattern` | clips written as patterns of text, in the manner of TidalCycles |
| `extensions/notation` | a MIDI clip as staff notation, read and edited in the terminal and in a window |
| `extensions/drums` | drum tracks in one step, and a grid of the kit's pieces by name, in the terminal and a window |
| `extensions/templates` | a track, a group of tracks or a chain of devices saved under a name, to make again in any project |
| `extensions/vinput` | virtual inputs: a guitar heard as MIDI through gdi2m, as a port any track takes, set up in the terminal and a window |
| `extensions/midilsp` | MIDI LSP, the language server for music, plugged into `daw.lsp`: voice-leading diagnostics with fixes, the chords it hears, suggestions |
| `extensions/mixdiag` | the mix measured (LUFS, true peak, phase) and reported as findings to jump to |
| `extensions/undotree` | a window on the undo tree, named checkpoints, A/B listening |
| `extensions/rpp` | opening and writing REAPER projects |
| `extensions/tutor` | a course for first-time users, inside the program |
| `extensions/doctor` | a guided check of the real hardware (audio, MIDI, recording, plugins), with a written report: `:doctor`, `daw doctor` |
| `crates/daw-mcp` | a Model Context Protocol server in front of the control socket |

Each has a README of its own, and the pictures in it are the extension's
too: `extensions/<name>/images`, made by the scenes in its `images/make`
(`docs/images/make/make.sh <name>`). Where a plugin needed something only the core
could give (measuring loudness quickly, a tree of undo states, data for a
device's every instance), that one thing went into the core as an API
function, general enough for any extension, and the rest stayed outside.
[Everything an extension can own](#everything-an-extension-can-own) shows
how far that goes: singing synthesis is an extension, engine included.

## Extensions

An extension is a directory or a single file in `~/.config/daw/extensions`:

```
extensions/euclid/init.lua     run at startup
extensions/euclid/lua/         on the require path
extensions/euclid/devices/     devices written in Lua (see Writing a device in Lua, in devices.md)
extensions/clock.lua           a one-file extension
```

The ones that come with the source are loaded the same way: link or copy one
into that directory, or name it in `init.lua`:

```lua
daw.ext.load("/path/to/daw/extensions/sections")
```

There is no separate plugin interface. An extension is Lua that calls
`daw.command`, `daw.keymap.set`, `daw.on` and `daw.ui.view` like any
configuration does. `:extensions` lists what loaded, with the error for
anything that failed. `:ext.load notation` loads a bundled extension now
(Tab completes their names); `daw.ext.load` in `init.lua` keeps it. A
command of one that is not loaded says so instead of "no command". Files in `~/.config/daw/lua/` shadow the built-in modules
of the same name, so any part of the runtime can be replaced.

**One interface, both frontends.** A view an extension registers with
`daw.ui.view` and draws in cells is usable from the graphical frontend with
no code of its own: it is offered under More in the window, opened with
`:view.window name`, and drawn there as the terminal draws it, with its keys
and its `on_mouse` (see "Views in windows" under
[The graphical frontend](window.md)). A `title` field names it
in the menu, and `window = false` keeps it off. An extension that wants more
than cells in the window gives the view a `paint(g, ctx)` and a
`pointer(e)` as well: the window then paints it in pixels with
`daw.canvas`, and the terminal goes on drawing its `render`. The vocal
editor of extensions/utau does this. When the painted view is a second view
beside the terminal's (as the undo tree's and the mix report's are, in
`paint.lua` beside `view.lua`), the terminal's view names it with `painted =
"name"` and the painted one has `window = false`: More then offers the
painted one under the terminal view's title, and `pointer` also gets
`hover` events, the pointer moving over the window with no button down, for
tips. Braille in a cell view, or in `g:mono`, is drawn as dots by the
window. What an extension shows along the
timeline in the terminal (a layer of the arrange view) goes into the
window's ruler as a band (`daw.frontend.bands`, under "Bands under the
ruler").

**Lua that runs away is stopped.** A key's handler, a command, an event
handler, a timer or a view's drawing that runs for more than two seconds
without returning is stopped with an error that names it (`the key gZ (…)
ran for more than 2 s without returning, and was stopped`), and the program
carries on. `daw.opt.lua_limit` is the limit in milliseconds (0 for none).
Time spent waiting in the kernel (a render, a project being read, a plugin
being made, `daw.wait`) is not counted, and `daw.limit.unhurried(fn, ...)`
runs work that is known to be long without the clock.
Nothing watches the clock from inside Lua, so the limit costs nothing and
everything is compiled by LuaJIT, extensions included: a thread in the
kernel knows when the running call must have returned, and when that time
has passed it sets a hook from outside, which the bundled LuaJIT is built to
notice inside compiled loops (`LUAJIT_ENABLE_CHECKHOOK`, asked for in
`.cargo/config.toml`). A build without that flag says so in
`daw.api.limit_async` and falls back to a count hook, with code that is not
the runtime's own kept in LuaJIT's interpreter. `:lua` typed by hand
gets a minute, and scripts run with `-l` have no limit.

## Pictures in the terminal

A view that draws cells can show part of itself in pixels where the
terminal shows images (see "Pictures" in [The terminal
interface](terminal.md)): in its `render` it keeps a **strip** of cells
and says how to draw it, and draws its cells as it would anyway.

```lua
render = function(self, buf, ctx)
  local plot = buf:sub(10, 2, buf.width - 10, buf.height - 3)
  plot:fill(0, 0, plot.width, plot.height, " ", "Lane")
  local pictured = plot:strip(0, 0, plot.width, plot.height, {
    key = "mylane:" .. ctx.win.id,       -- what the strip is: one for each window
    under = true,                         -- the cells drawn here stay, above the picture
    draw = function(g, px)                -- after the screen is drawn; px: w, h, cell = { w, h }, fg, bg
      daw.plot.curve(g, px, { points = points, from = left, pixels_per_beat = zoom * px.cell.w,
        lo = 0, hi = 1, color = daw.draw.track_colour(track) })
    end,
  })
  if not pictured then draw_the_curve_in_cells(plot) end
  draw_the_cursor_and_points(plot)       -- cells, over the picture or alone
end
```

`buf:strip(x, y, w, h, opts)` returns false where there are no pixels
(`daw.opt.graphics` off, a terminal that shows no images, tmux, `daw
attach` from such a terminal), and the view draws its cells there
instead. Under the text, the cells' backgrounds show where the picture
draws nothing; in a terminal that would let a coloured background hide the
picture (Konsole) the cells' backgrounds are painted into the picture,
except one that is a single run along one row (a cursor block, the note
under the cursor), which shows as cells; a cursor that moves over the
picture is best drawn as such a block or as a glyph (a line on the
cell's left edge), never as a column of blocks. `draw(g, px)` gets a
painter of `daw.canvas` (the same `g:rect`, `g:poly`, `g:text`, `g:cut`,
`g:layer` as `paint`) for the strip's pixels. A strip may reach past its
window (an audio clip scrolled half out of view): `px.w`, `px.h` are then
the whole strip's, drawn from its own corner, and `px.view` (`x`, `y`,
`w`, `h`) the part that shows; `daw.plot.span(px, step)` gives the
stretch worth drawing, in whole steps from the strip's left, so that a
stretch drawn before is drawn the same after a scroll and its pieces are
placed again rather than sent. A strip over the text (no `under`) has its cells left
blank. Strips are kept by `key`, which names the images the terminal
holds: the view and its window when none is given, and a view with more
than one strip names each. The pixels are made in the frontend, cut into
pieces at the drawing's `g:cut` marks and kept by the hash of their
pixels, so a strip that draws the same again sends nothing, and an edit
sends again only the pieces it touched. `buf:surface(x, y, w, h)` is the
same, over the text, for a view's whole `paint`.

`daw.plot` draws what views show over time in strips, so that they look
alike: `daw.plot.curve(g, px, opts)` draws a curve's bar and beat lines
(from the tempo map, `daw.draw.bar_lines`), cut at each bar on a cell's
edge, the area under it and the line, sampled once a pixel with
`daw.curves.value_at`, and a small mark at each point. `opts`: `points`
(as `daw.curves` gives them), `from` (the beat at the left),
`pixels_per_beat`, `frac(value)` from 0 to 1 or `lo` and `hi`, `flat`,
`color`, `fill` (how opaque the area is), `width`, `top`, `bottom`,
`grid`, `beats`, `guides`, `markers`, `background`. It draws no
background unless given one, so that under the text the cells' own
show. It returns `x(beat)` and `y(value)` for the rest of the drawing.
`daw.plot.lines(w, from, pixels_per_beat, cell_w)` gives the bar and beat
lines alone. The curve editor's plot is drawn this way
(`daw.curves.editor.picture`), and so are the piano roll's controller
strip (the value held from each move, `shape = "hold"`) and the utau
editor's curve.

`daw.plot.bars(g, px, opts)` draws a bar from the bottom for each of
`opts.items`, `{ beat, value, color, bright }` (`value` 0 to 1), with
`from`, `pixels_per_beat`, `width`, `color`. `daw.plot.wave(g, px, opts)`
draws a waveform: `opts.peaks(n)` gives `n` `{ min, max, rms }` across the
whole strip (`api.clip_peaks`), drawn from lowest to highest around the
middle with the RMS as a brighter band inside (`rms`, false for none), a
column at full scale in `clipped` (red), on the scale of
`daw.opt.wave_scale`, in stretches of eight cells. The arrange view's audio
clips are drawn this way. Each has a twin in cells, for where there are no
pictures, with the same options and `zoom` (cells a beat) for
`pixels_per_beat`: `daw.plot.curve_cells(buf, opts)` (connected sextants,
`daw.opt.curve_glyphs`), `daw.plot.bars_cells(buf, opts)` (eighth blocks)
and `daw.plot.wave_cells(buf, opts)` (`daw.draw.waveform`).

### What a frontend does with strips

A frontend that draws the screen itself (the window, a remote terminal)
is given the grid of cells and its strips, each a `Surface` (crates/daw-
core/src/grid.rs; over `daw attach` the `surfaces` of `ui.grid`, see
crates/daw-core/src/remote.rs). To draw them as the terminal does:

- `key` names the strip. Keep what is made of it (images, textures) by
  key, and drop it when a frame has no strip of that key.
- `rect` is the cells the strip shows, on the screen. `whole` is the
  whole strip's size in cells when part of it is off its window ((0, 0)
  when all of it shows), `offset` the cells of it left of and above
  `rect`. `cell` is the cell size in pixels the drawing was made for.
- `ops` is the drawing, in pixels from the whole strip's corner: the
  operations of `daw.canvas` (`r` rectangles, `p` paths, `t` text, `m`
  runs of cells, `g` music glyphs, `cut` where it may be cut into pieces,
  `layer` for what follows). Draw them through `daw_raster::Drawing`, or
  with the frontend's own painter, scaled by its cell size over `cell`,
  translated by `-offset * cell` and clipped to `rect`.
- `under` false: the strip's cells are blank, and the picture is drawn
  over everything in `rect`. `under` true: draw the picture after the
  cells' backgrounds and before their text, so that the view's own
  characters (its cursor, points, labels, the playhead) are over it and
  the cells' backgrounds show where it draws nothing.
- `covered` (a flag a cell, row by row; `covered_runs` over the wire)
  marks cells drawn over the strip later (a menu, a floating view): leave
  the picture out of them.
- A frontend that paints its pictures in pieces (the terminal does, by
  the kitty protocol) cuts the whole strip at the `cut` marks and keeps
  each piece by the hash of the operations that reach into it
  (`Drawing::piece_key`), so that an unchanged piece, or one scrolled to
  another place, is not made again.

The window (crates/daw-gui, on egui) does not get the grid: a view it
shows in a pane or in a window of its own as the terminal draws it comes
as one drawing from `daw.canvas.paint_cells`, which the window makes into
an image with the same rasterizer (`panes::raster`, through
`daw_raster::Drawing::paint_scaled`) and shows as a texture. That drawing
already holds the strips: while the view is drawn for the window,
`buf:strip` keeps each strip under the text (`daw.ui.pictures`) and
answers true, and `paint_cells` puts the cells' backgrounds first, then
each strip's `draw(g, px)` at the window's cell size (a painter clipped to
the strip, from the whole strip's corner, `px.view` what shows), then the
cells' text. So the curve editor and the vocal editor show their curves
in pixels in the window with nothing in crates/daw-gui knowing of strips.
A view the window draws natively (the arrange view, the piano roll, the
mixer) draws its own curves and waveforms with egui's painter and has no
strips; were one to move to cells, it would get them the same way.

## Everything an extension can own

extensions/utau is the example of how far an extension goes. Singing is not
in the program: the extension brings the vocal editor, the kind of track,
the device that plays what was sung, and the engine that sings, and a Nix
configuration that names it gets all of them.

```
extensions/utau/
  init.lua, lua/utau/   the editor, the commands, the talk with the engine
  devices/utau.lua      the device that plays the singing (Lua, in its own process)
  engine/               the engine's C# source, on OpenUtau.Core
  nix/                  how the engine and the extension are built and packaged
```

What the core gives it, which any extension can use the same way:

**Devices written in Lua.** `devices/` holds devices (see
[Writing a device in Lua](devices.md#writing-a-device-in-lua)). Each runs
in a helper process with a LuaJIT state of its own, so one that fails or
crashes stops alone. Scripts in the session talk to a device's `dev.call`:
`daw.api.device_call(device, method, data)` for one device, and
`daw.api.device_post(kind, topic, data)` for every device of a kind, those
there now and every one made later, an offline render's own among them,
before its first block. Large data goes as files the device maps with
`dsp.map(path)`, shared by every device that maps them. The utau device
gets the singing this way: the extension writes each phrase the engine
sends to a file and posts each voice's list of files; the devices play
them at their place, the same live and rendered, bit for bit.

**Kinds of track.** `daw.track_kinds.define(name, spec)` says what a kind
of track is: `title`, `letter` (shown in the track header before the name),
`create(track, args)` (what makes an ordinary track this kind: devices, a
question), `editor(clip)` (what Enter, a double click and `:clip.edit` open
for its clips; true when it opened one), `describe(track)` (a few words for
`K` and the window's track header), and `is(track)` (a track that is of the
kind without saying so). From then on `:track.add <name> [words]`,
`:track.new` (a list of every kind), the window's buttons and menus that
make a track, the header, `K` and `:clip.edit` know it. The kind is kept in
the track's `meta.kind`, saved with the project; opened without the
extension, the track is an ordinary one and `K` says which kind it was.
Vocal tracks (utau) and drum tracks (drums) are kinds.
`daw.track_kinds.add(name, opts)`, `set(track, name, args)`, `clear(track)`,
`of(track)` and `describe(track)` are there for scripts.

**Plugins of its own.** An extension can bring a plugin built from its own
source. extensions/sampler is paw's sample player, a CLAP plugin written
in Rust in `native/` (its own Cargo workspace, so building paw never
compiles it); its package puts `paw-sampler.clap` in `clap/` beside the
extension, which adds that folder to the plugin scan. Scripts ask such a
plugin things by name as they ask a Lua device: `daw.api.device_call(device,
method, data)` reaches any method paw does not know itself through the
plugin's `dev.paw.call/1` extension (the sampler answers `describe`), and
`device_call(device, "preset.load", "file:<path>")` loads a file through
the plugin's preset-load.

**Programs of its own.** An extension can start a program and talk to it
over a socket or its standard input and output (see Helper programs in
[Scripting](scripting.md)). The utau engine is such a program, built from
the extension's own `engine/` source; `bin/` beside the extension is where
its package puts it, and where the extension looks first after the
`utau_engine` option and `$REAUTAU_ENGINE`.

**A renamed device.** `daw.api.device_alias(old, new)` makes devices of a
kind that was renamed as the new one: projects saved when the utau device
was built into the program get the Lua device.

**Packaging with Nix.** The flake makes every extension a package holding
`share/daw/extensions/<name>`. Most are their Lua copied; one with parts to
build has a `nix/default.nix` of its own, which is given the flake inputs
it asks for (utau's asks for `openutau`, the OpenUtau source its engine is
built against, pinned in the flake). The program with some of them:

```nix
paw.packages.${system}.default.withExtensions (exts: [ exts.utau ])
```

or, in home-manager, with the flake's `homeManagerModules.default`:

```nix
programs.paw = { enable = true; extensions = [ "utau" ]; };
```

The program's commands are wrapped to name the extensions' directories in
`$DAW_EXTENSIONS` (separated by `:`), and those are loaded at startup,
before the configuration and with `--clean` too: they are part of the
program. A configuration that loads the same extension from elsewhere gets
the packaged one. `nix run .#paw-utau` is paw that sings; plain `nix run .`
has no .NET in it.
