# Extensions

## Core and plugins

Two things are kept apart, and the rule that separates them is short.

**The core** is what an extension could not add: the audio engine, the
project model, plugin hosting, the `paw.api` functions, and the runtime in
`runtime/lua/paw` that turns those into objects, commands, keys and views. It
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
| `extensions/articulations` | each note's articulation as its MIDI 2.0 attribute, named per instrument by `.art.toml` maps, sent as keyswitches to MIDI 1.0 instruments; maps made from SFZ, Decent Sampler, folders and Reaticulate banks |
| `extensions/drums` | drum tracks in one step, and a grid of the kit's pieces by name, in the terminal and a window |
| `extensions/templates` | a track, a group of tracks or a chain of devices saved under a name, to make again in any project |
| `extensions/vinput` | virtual inputs: a guitar heard as MIDI through gdi2m, as a port any track takes, set up in the terminal and a window |
| `extensions/midilsp` | MIDI LSP, the language server for music, plugged into `paw.lsp`: voice-leading diagnostics with fixes, the chords it hears, suggestions |
| `extensions/mixdiag` | the mix measured (LUFS, true peak, phase) and reported as findings to jump to |
| `extensions/undotree` | a window on the undo tree, named checkpoints, A/B listening |
| `extensions/projdiff` | what changed between two versions of a project (a file, a git revision, an undo state, a snapshot), and three-way merges of projects for git: `:Pdiff`, `:Pmerge`, `:Psnapshot` |
| `extensions/rpp` | opening and writing REAPER projects |
| `extensions/tutor` | a course for first-time users, inside the program |
| `extensions/doctor` | a guided check of the real hardware (audio, MIDI, recording, plugins), with a written report: `:doctor`, `paw doctor` |
| `crates/paw-mcp` | a Model Context Protocol server in front of the control socket |

Each has a README of its own, and the pictures in it are the extension's
too: `extensions/<name>/images`, made by the scenes in its `images/make`
(`docs/images/make/make.sh <name>`). Where a plugin needed something only the core
could give (measuring loudness quickly, a tree of undo states, data for a
device's every instance), that one thing went into the core as an API
function, general enough for any extension, and the rest stayed outside.
[Everything an extension can own](#everything-an-extension-can-own) shows
how far that goes: singing synthesis is an extension, engine included.

## Extensions

An extension is a directory or a single file in `~/.config/paw/extensions`:

```
extensions/euclid/init.lua      run at startup
extensions/euclid/manifest.lua  what it is and what it needs (optional)
extensions/euclid/lua/          on the require path
extensions/euclid/devices/      devices written in Lua (see Writing a device in Lua, in devices.md)
extensions/clock.lua            a one-file extension
```

The ones that come with the source are loaded the same way: link or copy one
into that directory, or name it in `init.lua`:

```lua
paw.ext.load("/path/to/paw/extensions/sections")
```

There is no separate plugin interface. An extension is Lua that calls
`paw.command`, `paw.keymap.set`, `paw.on` and `paw.ui.view` like any
configuration does. `:extensions` lists what loaded, with its version,
what it registered and the error for anything that failed. `:ext.load
notation` loads a bundled extension now (Tab completes their names);
`paw.ext.load` in `init.lua` keeps it. `:ext.unload notation` takes it
away again. A command of one that is not loaded says so instead of "no
command". Files in `~/.config/paw/lua/` shadow the built-in modules of the
same name, so any part of the runtime can be replaced.

**One interface, both frontends.** A view an extension registers with
`paw.ui.view` and draws in cells is usable from the graphical frontend with
no code of its own: it is offered under More in the window, opened with
`:view.window name`, and drawn there as the terminal draws it, with its keys
and its `on_mouse` (see "Views in windows" under
[The graphical frontend](window.md)). A `title` field names it
in the menu, and `window = false` keeps it off. An extension that wants more
than cells in the window gives the view a `paint(g, ctx)` and a
`pointer(e)` as well: the window then paints it in pixels with
`paw.canvas`, and the terminal goes on drawing its `render`. The vocal
editor of extensions/utau does this. When the painted view is a second view
beside the terminal's (as the undo tree's and the mix report's are, in
`paint.lua` beside `view.lua`), the terminal's view names it with `painted =
"name"` and the painted one has `window = false`: More then offers the
painted one under the terminal view's title, and `pointer` also gets
`hover` events, the pointer moving over the window with no button down, for
tips. Braille in a cell view, or in `g:mono`, is drawn as dots by the
window. What an extension shows along the
timeline in the terminal (a layer of the arrange view) goes into the
window's ruler as a band (`paw.frontend.bands`, under "Bands under the
ruler").

**Lua that runs away is stopped.** A key's handler, a command, an event
handler, a timer, a view's drawing or a request on the control socket
(`paw ctl`, the window, the MCP server) that runs for more than two seconds
without returning is stopped with an error that names it (`the key gZ (…)
ran for more than 2 s without returning, and was stopped`), and the program
carries on. `paw.opt.lua_limit` is the limit in milliseconds (0 for none).
Time spent waiting in the kernel (a render, a project being read, a plugin
being made, `paw.wait`) is not counted, and `paw.limit.unhurried(fn, ...)`
runs work that is known to be long without the clock.
Nothing watches the clock from inside Lua, so the limit costs nothing and
everything is compiled by LuaJIT, extensions included: a thread in the
kernel knows when the running call must have returned, and when that time
has passed it sets a hook from outside, which the bundled LuaJIT is built to
notice inside compiled loops (`LUAJIT_ENABLE_CHECKHOOK`, asked for in
`.cargo/config.toml`). A build without that flag says so in
`paw.api.limit_async` and falls back to a count hook, with code that is not
the runtime's own kept in LuaJIT's interpreter. `:lua` typed by hand
gets a minute, and scripts run with `-l` have no limit.

### Manifests and versions

An extension may say what it is in a `manifest.lua` beside its `init.lua`,
which returns a table; every bundled extension has one.

```lua
return {
  name = "euclid", version = "1.2.0",
  description = "Euclidean rhythms as clips",
  requires = { paw = "^1.0", sections = ">=0.1" },   -- the API, and other extensions
  provides = { "rhythms" },                         -- names others may require it by
}
```

`paw.api.version` is the version of the scripting interface (`1.0.0`): its
minor number goes up when something is added, its major one when something
is taken away or changed. `requires` names the versions an extension works
with: `paw` for the API, any other name for an extension (or a name one
`provides`). A requirement is `>=1.2`, `>1`, `<=2`, `<2.0`, `=1.2.3`, `^1.2`
(the same first number, at least 1.2), `~1.2` (the same first two), a bare
version (as `^`), `*` for any, or several separated by commas. Before an
extension runs, what it requires is loaded (from beside it, then from the
bundled ones) and every version checked; an extension whose requirements
are not met is not run, and `:extensions` and `:checkhealth extensions`
say why. `paw.ext.satisfies(version, want)` checks a version for scripts,
and `paw.ext.manifest(path, name)` reads one.

### What an extension owns

Whatever an extension registers while it loads is recorded as its own:
commands, keys and key groups, views, buffer types, kinds of text buffer,
kinds of track, picker sources, query fields, fields and views of `:s` and
`:g`, completers, status line components, grep sources, curve providers,
address schemes, completion sources, layers, health checks, hooks
(`paw.on`) and options. `:extensions` lists it, `paw.ext.provides(name)`
returns it, and a command or a key says whose it is (`spec.ext`,
`map.ext`), which `:help` uses.

`paw.ext.unload(name)` (`:ext.unload`) removes exactly that: each thing it
registered goes, and what it replaced (a key of the core it remapped, a
command it redefined) comes back. Its modules are forgotten, so loading it
again runs it afresh, and `ext.unloading` and `ext.unloaded` are emitted.
An extension that another loaded one requires is not unloaded. Two things
stay: options keep their defaults (a value set for one stays meaningful),
and the Lua devices and plugins it ships stay among the devices for the
session. `:reload` starts the whole runtime again and needs none of this.

### Health checks

`:checkhealth` runs the checks of the program and of the extensions and
shows what is well (OK), what may not be (WARN) and what is wrong (ERROR),
with advice under each, as Neovim's does; `:checkhealth audio ffmpeg` runs
those named. The core checks the program and its Lua (`paw`), the audio
engine and MIDI (`audio`), plugin hosting (`plugins`), `ffmpeg` for
compressed renders, pictures in the terminal (`terminal`), the fonts the
window falls back on (`fonts`) and the extensions with their versions and
requirements (`extensions`); utau checks its engine, and sampler its
plugin. An extension adds its own:

```lua
paw.health.register("euclid", function(h)
  h.ok("patterns loaded")
  if not paw.ext.loaded.sections then h.warn("no sections", { ":ext.load sections names them" }) end
end, { desc = "Euclidean rhythms" })
```

`h.ok`, `h.info`, `h.warn(text, advice)` and `h.error(text, advice)`
report; advice is a line or a list of them. A check that fails is shown as
an error of its own. `paw.health.run(name)` and `paw.health.check(names)`
return the results as data. `:doctor` (extensions/doctor) is the guided
check of the hardware that a person takes part in.

### API reference

[The Lua API reference](api.md) lists every public function of the `paw`
modules and of `paw.api` with what its comment in the source says, and is a
page of `:help` (`:help paw.ext.unload`). It is made by `tools/apidoc.lua`
(`paw --clean --no-plugins -l tools/apidoc.lua`), which also writes
`runtime/types/paw.lua`, a LuaLS meta file: point LuaLS's
`workspace.library` at `runtime/types` and editors complete `paw.*` in a
configuration or an extension, with the comments as documentation. A test
fails when a public function has no `---` comment over it or when either
file is out of date. [Scripting](scripting.md) has every event in one
table, under Events.

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
      paw.plot.curve(g, px, { points = points, from = left, pixels_per_beat = zoom * px.cell.w,
        lo = 0, hi = 1, color = paw.draw.track_colour(track) })
    end,
  })
  if not pictured then draw_the_curve_in_cells(plot) end
  draw_the_cursor_and_points(plot)       -- cells, over the picture or alone
end
```

`buf:strip(x, y, w, h, opts)` returns false where there are no pixels
(`paw.opt.graphics` off, a terminal that shows no images, tmux, `paw
attach` from such a terminal), and the view draws its cells there
instead. Under the text, the cells' backgrounds show where the picture
draws nothing; in a terminal that would let a coloured background hide the
picture (Konsole) the cells' backgrounds are painted into the picture,
except one that is a single run along one row (a cursor block, the note
under the cursor), which shows as cells; a cursor that moves over the
picture is best drawn as such a block or as a glyph (a line on the
cell's left edge), never as a column of blocks. `draw(g, px)` gets a
painter of `paw.canvas` (the same `g:rect`, `g:poly`, `g:text`, `g:cut`,
`g:layer` as `paint`) for the strip's pixels. A strip may reach past its
window (an audio clip scrolled half out of view): `px.w`, `px.h` are then
the whole strip's, drawn from its own corner, and `px.view` (`x`, `y`,
`w`, `h`) the part that shows; `paw.plot.span(px, step)` gives the
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

`paw.plot` draws what views show over time in strips, so that they look
alike: `paw.plot.curve(g, px, opts)` draws a curve's bar and beat lines
(from the tempo map, `paw.draw.bar_lines`), cut at each bar on a cell's
edge, the area under it and the line, sampled once a pixel with
`paw.curves.value_at`, and a small mark at each point. `opts`: `points`
(as `paw.curves` gives them), `from` (the beat at the left),
`pixels_per_beat`, `frac(value)` from 0 to 1 or `lo` and `hi`, `flat`,
`color`, `fill` (how opaque the area is), `width`, `top`, `bottom`,
`grid`, `beats`, `guides`, `markers`, `background`. It draws no
background unless given one, so that under the text the cells' own
show. It returns `x(beat)` and `y(value)` for the rest of the drawing.
`paw.plot.lines(w, from, pixels_per_beat, cell_w)` gives the bar and beat
lines alone. The curve editor's plot is drawn this way
(`paw.curves.editor.picture`), and so are the piano roll's controller
strip (the value held from each move, `shape = "hold"`) and the utau
editor's curve.

`paw.plot.bars(g, px, opts)` draws a bar from the bottom for each of
`opts.items`, `{ beat, value, color, bright }` (`value` 0 to 1), with
`from`, `pixels_per_beat`, `width`, `color`. `paw.plot.wave(g, px, opts)`
draws a waveform: `opts.peaks(n)` gives `n` `{ min, max, rms }` across the
whole strip (`api.clip_peaks`), drawn from lowest to highest around the
middle with the RMS as a brighter band inside (`rms`, false for none), a
column at full scale in `clipped` (red), on the scale of
`paw.opt.wave_scale`, in stretches of eight cells. The arrange view's audio
clips are drawn this way. Each has a twin in cells, for where there are no
pictures, with the same options and `zoom` (cells a beat) for
`pixels_per_beat`: `paw.plot.curve_cells(buf, opts)` (connected sextants,
`paw.opt.curve_glyphs`), `paw.plot.bars_cells(buf, opts)` (eighth blocks)
and `paw.plot.wave_cells(buf, opts)` (`paw.draw.waveform`).

### What a frontend does with strips

A frontend that draws the screen itself (the window, a remote terminal)
is given the grid of cells and its strips, each a `Surface` (crates/paw-
core/src/grid.rs; over `paw attach` the `surfaces` of `ui.grid`, see
crates/paw-core/src/remote.rs). To draw them as the terminal does:

- `key` names the strip. Keep what is made of it (images, textures) by
  key, and drop it when a frame has no strip of that key.
- `rect` is the cells the strip shows, on the screen. `whole` is the
  whole strip's size in cells when part of it is off its window ((0, 0)
  when all of it shows), `offset` the cells of it left of and above
  `rect`. `cell` is the cell size in pixels the drawing was made for.
- `ops` is the drawing, in pixels from the whole strip's corner: the
  operations of `paw.canvas` (`r` rectangles, `p` paths, `t` text, `m`
  runs of cells, `g` music glyphs, `cut` where it may be cut into pieces,
  `layer` for what follows). Draw them through `paw_raster::Drawing`, or
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

The window (crates/paw-gui, on egui) does not get the grid: a view it
shows in a pane or in a window of its own comes as a scene
(crates/paw-scene; "Scenes" in [the protocol](protocol.md)), built by
`paw.ui.render_scene(name, w, h, cell, win)` from what the view writes
(each `buf:text` a run, each `buf:fill` a fill, kept by where they are) and
pushed as what changed of it. While the view is drawn for a scene,
`buf:strip` keeps each strip under the text (`paw.ui.pictures`) and
answers true, and the strip's `draw(g, px)`, at the window's cell size
(`px.view` what shows), is a picture of the scene, cut to the part that
shows. The window draws the cells' backgrounds first, then the pictures
under the text, then the text, in its own font; a view that paints is one
picture of the whole. So the curve editor and the vocal editor show their
curves in pixels in the window with nothing in crates/paw-gui knowing of
strips. Since the scene is made of the view's writes, a view must draw
only through the buffer it is given (`tests/scene_parity.lua` checks every
view's, the extensions' included, and that its scene lowered to cells is
its drawing).
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
`paw.api.device_call(device, method, data)` for one device, and
`paw.api.device_post(kind, topic, data)` for every device of a kind, those
there now and every one made later, an offline render's own among them,
before its first block. Large data goes as files the device maps with
`dsp.map(path)`, shared by every device that maps them. The utau device
gets the singing this way: the extension writes each phrase the engine
sends to a file and posts each voice's list of files; the devices play
them at their place, the same live and rendered, bit for bit.

**Kinds of track.** `paw.track_kinds.define(name, spec)` says what a kind
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
`paw.track_kinds.add(name, opts)`, `set(track, name, args)`, `clear(track)`,
`of(track)` and `describe(track)` are there for scripts.

**Plugins of its own.** An extension can bring a plugin built from its own
source. extensions/sampler is paw's sample player, a CLAP plugin written
in Rust in `native/` (its own Cargo workspace, so building paw never
compiles it); its package puts `paw-sampler.clap` in `clap/` beside the
extension, which adds that folder to the plugin scan. Scripts ask such a
plugin things by name as they ask a Lua device: `paw.api.device_call(device,
method, data)` reaches any method paw does not know itself through the
plugin's `dev.paw.call/1` extension (the sampler answers `describe`), and
`device_call(device, "preset.load", "file:<path>")` loads a file through
the plugin's preset-load.

**Programs of its own.** An extension can start a program and talk to it
over a socket or its standard input and output (see Helper programs in
[Scripting](scripting.md)). The utau engine is such a program, built from
the extension's own `engine/` source; `bin/` beside the extension is where
its package puts it, and where the extension looks first after the
`utau_engine` option and `$PAW_UTAU_ENGINE`.

**Plugins of its own.** An extension that builds a CLAP or VST3 plugin
(its Nix package puts it beside the extension) registers the directory
with `paw.plugins.add_dir(dir)`. Its plugins are found from then on, for
the session, as if they were installed: listed as the extension's
(`paw.plugins.from[kind]`), made in helper processes like any plugin, and
devices of theirs that a project held while they were missing are made.
`CLAP_PATH` and the like replace where plugins are looked for and are read
once at start; this adds to it.

**A renamed device.** `paw.api.device_alias(old, new)` makes devices of a
kind that was renamed as the new one: projects saved when the utau device
was built into the program get the Lua device.

**Packaging with Nix.** The flake makes every extension a package holding
`share/paw/extensions/<name>`. Most are their Lua copied; one with parts to
build has a `nix/default.nix` of its own, which is given the flake inputs
it asks for (utau's asks for `openutau`, the OpenUtau source its engine is
built against, pinned in the flake). One with a Rust workspace of its own
asks for `craneLib` and builds it as paw is built, its dependencies in a
derivation of their own (the sampler's `nix/engine.nix`). The program with
some of them:

```nix
paw.packages.${system}.default.withExtensions (exts: [ exts.utau ])
```

or, in home-manager, with the flake's `homeManagerModules.default`:

```nix
programs.paw = { enable = true; extensions = [ "utau" ]; };
```

The program's commands are wrapped to name the extensions' directories in
`$PAW_EXTENSIONS` (separated by `:`), and those are loaded at startup,
before the configuration and with `--clean` too: they are part of the
program. A configuration that loads the same extension from elsewhere gets
the packaged one. `nix run .#paw-utau` is paw that sings; plain `nix run .`
has no .NET in it.
