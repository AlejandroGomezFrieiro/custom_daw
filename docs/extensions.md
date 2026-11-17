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
| `extensions/utau` | singing synthesis, a vocal editor |
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
could give (measuring loudness quickly, a tree of undo states), that one
thing went into the core as an API function and the rest stayed outside.

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
