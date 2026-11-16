# Configuration

`~/.config/daw/init.lua` runs at startup. `:reload` runs it again without
touching the project or stopping audio.

```lua
daw.opt.zoom = 4
daw.opt.track_height = 2                      -- rows per track in the arrange view ("auto" by default)
daw.opt.header_width = 28                     -- also devices_width, mixer_height, pianoroll_height, <panel>_width/_height
daw.ui.hl("Playhead", { bg = "#ff5555" })     -- any colour group can be redefined

daw.command("track.synth", function(ctx)
  local track = daw.add_track({ name = ctx.args[1] or "Synth" })
  track:add_device("synth", { cutoff = tonumber(ctx.args.cutoff) or 1800 })
  daw.cursor.set_track(track)
end, { desc = "Add a synth track: `track.synth Lead cutoff=900`" })

daw.keymap.set("<leader>s", "track.synth", { desc = "Add a synth track" })

daw.on("project.saved", function(event) daw.notify("saved to " .. event.path) end)

daw.audio.use({ output = "UR22mkII Stereo", input = "UR22mkII", buffer = 128 })   -- devices; see Input and recording
```

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
(`daw.opt.track_height = "auto"`, or a number), and the headers are 26, 22,
18 or 12 columns wide by the screen's width (`daw.opt.header_width`). The
master is pinned to the bottom with both sides' levels in one row and a dB
scale. Docked panels (devices, mixer, piano roll and extensions' views) have
a one-row title bar with an amber mark when focused; a panel beside another
has a rule on its left. The mixer's strips have a name plate, the first
devices and sends when there is room, meters with the peak held, a fader with
0 dB marked, the pan and the chips. Below 80 columns the device panel floats
over the arrange view; below 60×16 the screen says it is too small.

The status line is in segments: the mode, a macro being recorded, the
transport and position, the time, tempo and signature, what is switched on
(`loop 3–5`, `click`, `rec`, `write`), the grid, the size of a visual
selection; on the right keys typed so far, the project (an amber dot when it
has unsaved changes), the engine, and its load with dropouts (`xrun 3`) when
there have been any. Each segment has the narrowest screen it is shown on, so
the line does not change shape as the width changes by a column; the
project's name is cut before anything else goes. The bottom line shows the
keys worth knowing first for the view and mode you are in, and gives way to
messages (`daw.opt.keybar = false` turns it off; `?` lists every key). A
project with no tracks says how to begin.

Colours are 24-bit when the terminal says it can show them (`COLORTERM` of
`truecolor` or `24bit`, or a `TERM` ending in `-direct`) and otherwise the
nearest of the 256 (`daw.opt.termcolors = "true"`, `"256"` or `"auto"`).
`daw.opt.ascii = true` draws with plain ASCII characters only, and
`daw.opt.braille = false` draws curves with lines instead of braille dots.

Views and extensions draw from the same pieces, in `daw.draw`: `hue(colour)`
and `track_hue(track)` give highlight groups in the shades of a colour, `g`
the characters (ASCII ones under `daw.opt.ascii`), `meter`, `vmeter`,
`stereo_meter`, `slider`, `pan` and `chips` draw controls, `hold` keeps a
peak for a while, `miniroll` and `waveform` make the small pictures inside
clips, `piano_key`, `beats` and `bar_lines` the edge, ruler and grid of a
roll, and `curve` a line of dots. `daw.ui.titlebar(buf, opts)` draws a
panel's title bar. An extension draws on the arrange view's timeline through
`daw.ui.views.arrange.layers` and asks for a second ruler row (as the
sections do) through `daw.ui.views.arrange.ruler2`. An extension's view gets
its own line of keys with `daw.ui.keybar.set("myview", "n", { { "<CR>", "open" } })`;
`daw.ui.keybar.check()` lists any key shown that nothing is mapped to. The
colours are in `runtime/lua/daw/theme.lua`.

[examples/config](../examples/config) has a fuller configuration and two
extensions. [extensions/utau](../extensions/utau) is a larger one: singing
synthesis with OpenUtau's engines, through ReaUtau's `reautau-engine`, with a
vocal editor and lyric sheet.
