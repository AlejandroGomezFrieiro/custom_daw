# Configuration

`~/.config/paw/init.lua` runs at startup. `:reload` runs it again without
touching the project or stopping audio.

```lua
paw.opt.zoom = 4
paw.opt.track_height = 2                      -- rows per track in the arrange view ("auto" by default)
paw.opt.header_width = 28                     -- also devices_width, mixer_height, pianoroll_height, <panel>_width/_height
paw.ui.hl("Playhead", { bg = "#ff5555" })     -- any colour group can be redefined

paw.command("track.synth", function(ctx)
  local track = paw.add_track({ name = ctx.args[1] or "Synth" })
  track:add_device("synth", { cutoff = tonumber(ctx.args.cutoff) or 1800 })
  paw.cursor.set_track(track)
end, { desc = "Add a synth track: `track.synth Lead cutoff=900`" })

paw.keymap.set("<leader>s", "track.synth", { desc = "Add a synth track" })

paw.on("project.saved", function(event) paw.notify("saved to " .. event.path) end)

paw.audio.use({ output = "UR22mkII Stereo", input = "UR22mkII", buffer = 128 })   -- devices; see Input and recording
```

**Leaders.** `<leader>` in a key is `paw.opt.leader` (`,`): the keys that
mean the same in every view (`,m` the mixer, `,d` the devices).
`<localleader>` is `paw.opt.localleader` (a backslash, as in Vim): the leader
of what only one view has, such as the notation popovers (`\d` dynamics,
`\t` tempo). A key of one view may not sit on a global leader key;
`:lua =paw.keyrule.broken()` lists any that do. `:map` and the key hints show
both as typed.

**How it looks.** Content stays neutral and colour goes where attention
should: amber for focus, the playhead and keys to press; the mode's colour in
the mode pill and the cursor; red for recording and errors. Each track has a
colour, taken in turn from the theme's twelve (the window uses the same) or
set with `:track.color teal` (coral, orange, gold, lime, green, teal, sky,
blue, violet, purple, pink, sand, or `#rrggbb`), and what belongs to the track
is drawn in shades of it: its clips (a name row and a darker body with the
notes or waveform), its notes in the piano roll, its name plate in the mixer.
The clip under the cursor is lit in the full colour, and the cursor's track
has a brighter header and a tinted lane.

The arrange view has a rule between the track headers and the timeline, bar
numbers and beat ticks on the ruler, the loop as a band on the ruler and a
shade over the lanes, and a thin amber playhead. Headers show the M S R I
chips (mute, solo, arm, monitor) and, as rows allow, the level and volume,
the pan, devices and output (`→ Bus`), sends (`↗ Reverb -9`) and the input.
Tracks share the height there is, three to six rows each
(`paw.opt.track_height = "auto"`, or a number), and the headers are 26, 22,
18 or 12 columns wide by the screen's width (`paw.opt.header_width`). The
master is pinned to the bottom with both sides' levels in one row and a dB
scale. Docked panels (devices, mixer, piano roll and extensions' views) have
a one-row title bar, drawn inverted in amber when focused (the mode in the status line names the view too: `NORMAL·mixer`); a panel beside another
has a rule on its left. The mixer's strips have a name plate, the first
devices and sends when there is room, meters with the peak held, a fader with
0 dB marked, the pan and the chips. Below 80 columns the device panel floats
over the arrange view; below 60×16 the screen says it is too small.

The status line is in segments: the mode, a macro being recorded, the
transport and position, the time, tempo and signature, what is switched on
(`loop 3–5`, `click`, `rec`, `write`), the grid, the size of a visual
selection; on the right keys typed so far, the project (an amber dot when it
has unsaved changes), the engine, and its load with dropouts (`xrun 3`) when
there have been any ([The status line](#the-status-line) below says how to
change what is in it). Each segment has the narrowest screen it is shown on, so
the line does not change shape as the width changes by a column; the
project's name is cut before anything else goes. The bottom line shows the
keys worth knowing first for the view and mode you are in, and gives way to
messages (`paw.opt.keybar = false` turns it off; `?` lists every key). A
project with no tracks says how to begin.

Colours are 24-bit when the terminal says it can show them (`COLORTERM` of
`truecolor` or `24bit`, or a `TERM` ending in `-direct`) and otherwise the
nearest of the 256 (`paw.opt.termcolors = "true"`, `"256"` or `"auto"`).
`paw.opt.ascii = true` draws with plain ASCII characters only, and
`paw.opt.curve_glyphs` chooses how curves are drawn in cells: `"sextant"`
(the default: a connected line of sextant characters, two columns by three
rows a cell, with steep slopes filled so that it has no gaps), `"braille"`
(dots, two by four) or `"line"` (lines at three heights a row).
`paw.opt.braille = false` means `"line"`, and `paw.opt.ascii` wins over all.
`paw.opt.wave_scale` is how audio clips draw their sound in cells: `"linear"`
(the default, which shows hits) or `"db"` (which shows quiet sound).
`paw.opt.graphics = false` keeps views that paint to plain terminal cells; the
default shows pixels (the kitty graphics protocol) where the terminal can show
them. `:set graphics!` toggles it.

Views and extensions draw from the same pieces, in `paw.draw`: `hue(colour)`
and `track_hue(track)` give highlight groups in the shades of a colour, `g`
the characters (ASCII ones under `paw.opt.ascii`), `meter`, `vmeter`,
`stereo_meter`, `slider`, `pan` and `chips` draw controls, `hold` keeps a
peak for a while, `miniroll` and `waveform` make the small pictures inside
clips, `piano_key`, `beats` and `bar_lines` the edge, ruler and grid of a
roll, and `curve` a line of dots. `paw.ui.titlebar(buf, opts)` draws a
panel's title bar. An extension draws on the arrange view's timeline through
`paw.ui.views.arrange.layers` and asks for a second ruler row (as the
sections do) through `paw.ui.views.arrange.ruler2`. An extension's view gets
its own line of keys with `paw.ui.keybar.set("myview", "n", { { "<CR>", "open" } })`;
`paw.ui.keybar.check()` lists any key shown that nothing is mapped to. The
colours are in `runtime/lua/paw/theme.lua`.

[examples/config](../examples/config) has a fuller configuration and two
extensions. [extensions/utau](../extensions/utau) is a larger one: singing
synthesis with OpenUtau's engines, through ReaUtau's `reautau-engine`, with a
vocal editor and lyric sheet.

Devices written in Lua go in `~/.config/paw/devices/`, one `.lua` file each,
and are loaded again whenever they are saved: see
[Writing a device in Lua](devices.md#writing-a-device-in-lua).

## The status line

<!-- tags: statusline lualine -->
The status line is built as lualine builds Neovim's: six sections, `a b c`
from the left and `x y z` to the right edge, each a list of components, and
`paw.statusline.setup` in `init.lua` changes what you name. What you leave
out keeps its default, so the line that comes with the program is the
starting point:

```lua
paw.statusline.setup({
  sections = {
    a = { "mode" },
    b = { "take" },
    c = { "transport", "clock", "tempo", "flags", "cursor", "grid" },
    x = { "midi", "keys" },
    y = { "engine", "cpu" },
    z = { "project" },
  },
  separators = { component = "│", section = "│" },   -- "" for a space
  theme = "default",                                 -- "mono", or a table of highlight groups
  views = { pianoroll = { sections = { c = { "cursor", "grid" } } } },
})
```

The components that come with the program: `mode` (with the view that has
the keys), `macro`, `transport`, `clock`, `tempo` (and the metre where the
playhead is), `flags` (loop, click, punch, count-in, rec, write), `take`,
`render`, `diagnostics`, `qf`, `pointer` (what is under the mouse), `grid`,
`selection`, `cursor` (the track and clip under the cursor), `buffer` (the
text buffer with the keys), `keys` (what is typed so far), `project` (an
amber dot when it has unsaved changes), `engine`, `cpu` (and dropouts) and
`midi` (lit for a moment after MIDI comes in). A component is one of:

- a name: `"tempo"`;
- a function: `function(ctx) return "text" end`, which gives nothing (it has
  nothing to say now), a string, or a list of `{ text, group }` pieces;
- a table with either of those first and options after it: `{ "grid", min = 120 }`,
  `{ fn, rank = 2, style = "StatusDim", cond = function(ctx) return ... end,
  fmt = function(text) return text:upper() end }`.

`min` is the narrowest screen it is shown on and `rank` how late it is
dropped when the line is too long (a higher rank goes first, `0` never; the
project's name is cut before anything goes). `ctx` holds `width`, `mode`,
`view` (the view that has the keys), `focused` (for a winbar), `g` (the
characters, as `paw.draw.g`) and, read when asked for, `transport`,
`project` and `engine`, the same tables `paw.api.transport_get`,
`project_get` and `engine_get` give. An error in a component is not shown on
the line: `paw.statusline.line(120).errors` lists them. A component with
`key = function(ctx) return value end` is called again only when its key
changes (the project, engine and cpu components do this), so that a long
line costs what has changed.

An extension adds a component for scripts to name:
`paw.statusline.component("pulse", { fn = function(ctx) return "♥" end, min = 90, rank = 6 })`.

`views` gives sections to use while a view has the keys (the roll may show
its clip, the mixer nothing but the mode); `inactive_sections`, those to use
while a float (a picker, help, the plan of a write) has them. The other bars
take the same sections: `winbar` adds to the title bar of the window that
has the keys and `inactive_winbar` to the others; `tabline = { sections =
{ z = { ... } }, always = true }` puts sections at the right end of the row of
tabs, which is shown with one tab too when `always` is set (not yet in the
window). `theme` is `"default"`, `"mono"` (one colour for every mode) or a
table that gives a highlight group to the mode (`mode = { n = "...", i = "..." }`),
to each section (`c = "StatusDim"`) and to the separators (`sep`); define a
group with `paw.ui.hl`. `paw.statusline.reset()` goes back to what came with the
program. `:help statusline` has this page.

The graphical window shows the line it has always shown, until `setup` is
called: then the kernel tells it the line's pieces as `modal.statusline`
(`{ left, right }`, each a list of `{ text, group }`) and the window is
to draw those; see [Window](window.md).
