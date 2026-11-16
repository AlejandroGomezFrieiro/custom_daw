# daw

A DAW built the way Neovim is built: a small kernel, and everything a user
touches written in a scripting language on top of it.

The kernel is Rust: a real-time audio engine, the project model with undo, and a
Lua host. The arrange view, mixer, piano roll, status line, every command and
every key mapping are Lua, using the same `daw` module your `init.lua` and your
extensions use. If the built-in behaviour is not what you want, you change it
with the calls it was written with.

This is an early version. It plays, edits, records and renders MIDI and audio
clips through built-in devices and through CLAP, LV2 and VST3 plugins, in a
terminal UI or a graphical one, and shows plugins' own editor windows. See
[What is missing](#what-is-missing) for what it does not do yet.

## Run it

The dev shell provides the Rust toolchain and the PipeWire libraries.

```sh
nix develop
cargo run -- -e 'dofile("examples/demo.lua")'       # open a demo song in the UI
cargo run -- --config examples/config                # the same UI with an example configuration
cargo run -- -l examples/demo.lua demo.wav           # no UI: build the song and render it
cargo run -p daw-gui -- -e 'dofile("examples/demo.lua")'   # the graphical frontend
cargo test                                           # the end-to-end suite
cargo run -- --output UR22 --input UR22              # open these audio devices (a part of the name is enough)
cargo run -- doctor                                  # check the audio, plugins and environment, and print a report
```

The audio devices are the system's default output and input until others are
chosen: with `:audio` (a list of every output, input and block size), with a
click on the engine indicator at the right of the window's transport bar, or
with `--output` and `--input`. A choice made in the program belongs to the
machine, not to a project: it is kept in `~/.local/state/daw/audio.json` and
opened at the next start; when a remembered device is not connected, the
default is opened instead and the program says so.

Every project opened or saved is remembered, newest first, twenty at most, in
`~/.local/state/daw/recent.json`; the list belongs to the machine, and a file
that is gone drops out of it. `:recent` chooses from it (`,fR`), `:recent 2`
opens the second, `:recent.clear` forgets them, and the window's File menu has
them under "Open recent", asking about unsaved changes as "Open" does. With
`daw.opt.reopen_last = true` a start with no project named opens the newest
one; if it will not open, that is a message and the program starts anyway.
Nothing is remembered under `--clean` or in a script. In Lua:
`daw.recent.list()` gives `{ path, name, time }` for each.

The suite hosts real plugins in all three formats. The dev shell provides them
(LSP Plugins and Surge XT, through `DAW_TEST_PLUGINS`); outside it those tests
are skipped.

`cargo test -p daw-gui` also drives the real window
(`crates/daw-gui/tests/window.rs`): each scenario starts Xvfb on a free display
from `:120` up, openbox and the window (with no session bus, so that nothing
reaches the desktop), makes pointer and key gestures with xdotool, and asks
the kernel what it holds afterwards. Menu entries and dialog buttons are found
by reading the screen: ImageMagick takes a picture of the window and tesseract
reads the words on it, so that a new entry in a menu moves nothing the tests
rely on. The tests need `Xvfb`, `openbox`, `xdotool`, ImageMagick and
`tesseract` (the dev shell has them), and the MP3 one `ffmpeg`. Without them
these tests say what is missing and pass. A failed scenario leaves
`failure.png` and the window's output under `target/tmp/window/<scenario>`.
`-- --ignored` runs the ones that are marked `#[ignore]`: how reliably the
screen is read (a measurement of several minutes), and known bugs, when there
are any.

The first start looks through every installed plugin, which can take several
seconds (bridged Windows plugins each start Wine). The result is cached in
`~/.cache/daw/plugins.json`; after that a plugin file is only loaded when it
changes or when one of its plugins is used. `--no-plugins` skips plugins
altogether.

`Space` plays, `?` finds a key: it lists every key of the focused view and the
global ones, typing part of a key or of what it does narrows the list, and
Enter runs the one chosen (`:help all` shows them as one page). `:` runs any
command by name, `:q` quits. As you type a command, a list above the command
line shows what it could become, with what each does: command names first,
then what the command takes (tracks by name for `:send`, devices for
`:device.add`, files for `:open`, `:import`, `:render`, `:write`, options
for `:set`). `Tab` and `Shift-Tab` (or `Ctrl-n` `Ctrl-p`) choose one into the
line, `Enter` runs the line, and on a directory goes into it. `:set zoom 4`,
`:set zoom=4` and `:set follow!` change options; `:open` opens a project or a
sound file. After an error the bottom line says how to read it whole (`,fn`
picks among the messages, `:messages` shows them all, newest at the bottom)
until you have. Stop halfway through a command and the keys
that can follow are listed.

New to it? There is a course of sixteen short lessons that runs inside the
program, in the manner of `vimtutor`: load `extensions/tutor` (see
[Extensions](#extensions)) and type `:tutor`. The same lessons are in
[docs/course](docs/course/README.md) for reading, with a one-page
[key reference](docs/course/keys.md).

## Keys

The keyboard works the way Neovim's does, on a timeline instead of a text. In
the arrange view a track is a line, a beat is a column and a clip is a word; in
the piano roll a pitch is a line and a note is a word. Everything below is an
ordinary mapping made in `runtime/lua/daw/defaults.lua` with the calls under
[Configure it](#configure-it), so any of it can be changed.

**Motions** move the cursor. A count repeats them: `3W` is three bars on.

| Keys | Arrange view | Piano roll |
| --- | --- | --- |
| `h` `l` | a grid step | a grid step |
| `j` `k` | next and previous track | a semitone down and up (`J` `K` an octave) |
| `w` `b` `e` | start of the next clip, start of this one, end of this one | the same for notes, at whatever pitch |
| `W` `B` | next and previous bar | the same |
| `0` `^` `$` | start of the project, first clip of the track, end of its last clip | start of the clip, first note, end of the clip |
| `gg` `G`, `5G` | first and last track, track 5 | highest and lowest note |
| `9\|`, `:9` | bar 9 | |
| `/name`, `n` `N`, `*` | find a clip or track by name; next, previous; the next clip named like this one | find a note by pitch name (`/c4`) |
| `ma`, `'a`, `''` | set mark `a`; go to it; go back to where the last jump came from | the same |
| `Ctrl-o` `Ctrl-i` | back and forward through the places jumped from | the same |
| `gP` | to the playhead | |

**Operators** act on what a motion covers, on a text object, or on a
selection. Typed twice they take whole lines: `dd` is a track, `3dd` three.

| Keys | Arrange view | Piano roll |
| --- | --- | --- |
| `d` | delete: `dw` up to the next clip, `d2W` two bars, `dd` the track | notes: `dw`, `d4l`, `dd` every note of the pitch |
| `y` | yank, for `p` | the same |
| `c` | change: empty the stretch, and open a fresh clip there for entering notes | delete, then enter notes |
| `>` `<` | move clips a grid step later or earlier (`>>` all of the track's) | the same for notes |
| `=` | snap clips and their notes to the grid | snap notes to the grid |
| `gc` | mute or unmute clips; `gcc` the track | |
| `gl` | loop it: `glic` loops the clip, `gl4W` four bars | the same |

**Text objects** name a region: `ic` the clip under the cursor, `ac` the clip
and the gap after it, `ib` this bar (`2ib` two), `il` the loop, `it` everything
on the track, `ie` the entire project. In the piano roll: `in` the note, `ib`
the bar, `ic` every note of the clip.

**Visual mode** selects first: `v` a stretch of time, stretched across tracks
with `j` and `k`; `V` whole tracks; in the piano roll `v` a stretch of time at
every pitch, `Ctrl-v` a rectangle, `V` whole pitches. Then an operator, or `x`
to delete, `~` to mute, `J` to join the clips, `Ctrl-a` and `Ctrl-x` to
transpose, `p` to replace it with the register. `o` goes to the other end, `gv`
selects the same again.

**Registers, repeating, macros.** `p` pastes after the clip or note under the
cursor (tracks: below), `P` right at the cursor (tracks: above); `3p` pastes
three times in a row, and `p` again carries on from the last. Pasted time
replaces what was there; `:lua daw.opt.ripple = true` makes deleting close the
gap and pasting push what follows along instead. `"a` before a command names a
register (`"ayy`, `"ap`), `"_` discards, `"0` holds the last yank, `:registers`
shows them. `.` repeats the last change, with a new count if one is given.
`qa` records keys into register `a` until the next `q`; `@a` plays them, `@@`
again, `5@a` five times, `@:` repeats the last command line.

**Insert mode** enters notes from the keyboard. `i` in the arrange view opens
the clip under the cursor for it, or a new one; in the piano roll `i` starts at
the cursor and `a` after the note under it. The middle row of the keyboard is
the white keys from C and the row above it the black ones (`a w s e d f t g y h
u j k`); each key enters a note and steps on. A capital stays in place, for
chords. `1` to `9` set how many grid steps a note is long, `Space` is a rest,
`Backspace` steps back and removes, `z` and `x` change octave, `[` and `]` the
velocity. The clip grows by a bar when the notes run past its end. `Esc`
returns to normal mode.

| Keys | Also in the arrange view |
| --- | --- |
| `x` `D` `C` `Y` | delete the clip; delete, change, yank to the end of the track |
| `o` `O`, `grn`, `Alt-j` `Alt-k` | add a track below or above; rename it; move it down or up |
| `M` `s` `r`, `+` `-`, `(` `)` | mute, solo, arm; volume; pan |
| `grv` `grp`, `grt` | type the volume (dB) or pan (`L30`, `R25`, `C`, -100 to 100), the tempo: a number, `+2` or `-3` to step from the value now, `=-6` for a value below zero |
| `I` `Alt-i`, `R` | next audio input, monitor the input; record or stop recording |
| `&` `S` `J` `~`, `grc` | repeat, split, join, mute the clip; rename it |
| `,cf`, `grC` | type the fade in and out of the audio clip under the cursor, in beats (`1 2`, or one length for both); choose the track's colour from the theme's hues (also in the mixer) |
| `H` `L`, `Alt-h` `Alt-l`, `Ctrl-a` `Ctrl-x` | move the clip; shorten and lengthen it; transpose it |
| `Enter`, `K` | edit the clip's notes in the piano roll; describe what is under the cursor |
| `a`, `ge`, `,d` `,m` `,p` | add a device; show the plugin's own window; show the device panel, the mixer, the piano roll |
| `A`, `,at` `,ax` | add a volume automation point at the cursor; turn the lane off or on (read or bypass), clear it |
| `,al`, `,aa` `,aA` | choose what to automate (volume, pan, any device parameter) and show its lane; show or hide the track's lanes as rows; show every track's lanes |
| `gs` `gp` `gL` `gm`, `Shift-Enter` | playhead to the start, to the cursor; loop on or off; metronome; play from the cursor |
| `gC` `gI`, `zt` | count a bar in before recording or not; punch recording on or off (on a selection, punch over it); show or hide the track's take lanes |
| `u` `Ctrl-r` | undo, redo, saying what: `undid Delete the clip` (each step is named by the key or command that made it) |
| `zi` `zo`, `zz` `zh` `zl`, `[g` `]g` | zoom; centre the cursor, scroll; finer or coarser grid |
| `Tab` `gt`, `Ctrl-w c`, `Ctrl-w o` | next view; close this panel; close every panel |
| `Ctrl-w +` `Ctrl-w -`, `Ctrl-w =` | taller or shorter tracks (in the mixer, piano roll or a panel below, that panel); track height back to automatic, fitting the tracks to the screen |
| `Ctrl-w <` `Ctrl-w >`, `Ctrl-w _` | narrower or wider side panel (in the arrange view, track headers); give the focused panel the whole screen, and again to put the others back |
| `ZZ` `ZQ` | save and quit; quit |

**Automation lanes as rows.** `,aa` shows a track's automation lanes as
rows under it, two lines each, and hides them again (`za`, `zM` and `zR`
fold groups, not lanes); `,al` chooses a lane to make or show, from volume,
pan and every parameter of the track's devices. A lane's header names what it
moves, its value at the cursor, and whether it is read or bypassed; its curve
and points (`◆`) are drawn along the timeline instead of over the clips. `j`
and `k` step onto lane rows as onto tracks. On a lane row `h` `l` and the
other motions move in time, `w` `b` go to the next and previous point, `A`
adds a point at the cursor at the curve's value there, `+` `-` raise and
lower the point under the cursor (a dB, 5% of pan, a hundredth of a
parameter's range), `c` or `=` types its value, `x` removes it, and `,at`
`,ax` bypass or clear that lane. In a selection (`v`) on a lane row `x` or `d`
remove the points in it, `H` `L` move them a grid step, `+` `-` raise or
lower them. Lanes for send levels are not there yet.

In the piano roll, `Enter` adds or removes a note, `+` `-` change its length,
`H` `L` move it, `Ctrl-a` `Ctrl-x` transpose it, `[` `]` change its velocity,
`gh` sounds the pitch, `Esc` goes back to the arrange view. In the device panel
`j` `k` choose a row, `h` `l` change a parameter, `c` or `=` types its value
in its own unit (a choice by name; `+2` `-3` step), `yy` `dd` `p` copy and move
devices, between tracks too, `Alt-j` `Alt-k` reorder the chain, and `s` `<`
`>` `w` `W` choose, step through, save and set the default preset, `f` finds
a parameter and `t` goes to the last touched one. `V` and `j` `k` select
several devices for `y` `d`; `:device.copy_to <track>` and
`:device.move_to <track>` take the selected one elsewhere. In the window,
dragging a device card by its name onto a track's header moves it there
(with `Ctrl`, copies it), and dragging it up or down the list reorders. The
mixer has `h` `l` for tracks, `j` `k` for volume, `grv` `grp` to type the
strip's volume and pan, and `dd` `yy` `p` for tracks.

## Pickers

A picker chooses one thing out of many by typing a few letters of it, as
Telescope does in Neovim. `,,` runs a command by name; the others are under
`,f` (`,` is the leader):

| Keys | Command | Lists | Enter |
| --- | --- | --- | --- |
| `,,` `,fc` | `pick.commands` | every command, with its key; a match in the name ranks above one in the description | runs it; `Ctrl-e` types it on the command line instead, for arguments |
| `?` `,fk` | `pick.keys` | every key of the focused view and the global ones, written as `Alt-h`, `,at`, `Ctrl-w o`, each tagged with where it works and whether it is a motion, operator, text object, or for a selection or insert mode | runs it |
| `,ft` | `pick.tracks` | tracks | moves the cursor to the track |
| `,fl` | `pick.clips` | every clip, with its track | goes to it |
| `,fa` | `pick.devices` | devices and plugins that can be added | adds it to the cursor's track |
| `,fd` | `pick.track_devices` | the devices on the track | shows it in the device panel; `Ctrl-e` opens the plugin's window |
| `,fm` | `pick.marks` | marks | goes to the mark |
| `,fr` | `pick.registers` | registers | pastes it at the cursor, or plays a macro |
| `,fn` | `pick.messages` | earlier messages, newest first | shows the whole message |
| `,ff` | `pick.files` | projects and audio files under the working directory | opens the project, or adds the audio at the cursor |
| `,fo` | `pick.options` | options and their values | switches a true/false option, or asks for a new value |
| `,fR` | `recent` | the recent projects, with where they are and when each was last opened | opens it |
| `,fp` | `pick` | every picker | opens it |
| `,f.` | `pick.resume` | the last picker, with what was typed | |

`a` in the arrange view and the device panel, and `:device.add` with no name,
choose the device in a picker too. It lists your favourites first (`Ctrl-f`
marks one, shown with `★`), then the devices you added last, then the rest.
Words starting with `@` filter: `@instrument` (or `@instr`) and `@effect`
(`@fx`), `@clap` `@lv2` `@vst3` `@builtin`, `@fav`, and `@` with the start of
a vendor's name (`@surge`); `Ctrl-t` steps between instruments, effects and
both. A match in a device's name ranks above one only in its vendor, the
whole name typed ranks first, and the device you chose for the same words
last time comes first. The window's "Add a device" box takes the same words,
lists the same way, and marks a favourite with the `☆` beside each line.
Favourites, recent devices and those choices are kept in
`~/.local/state/daw/devices.json`. Whether a plugin is an instrument comes
from what it declares (CLAP features, VST3 subcategories, LV2 classes),
kept in the scan cache. `:pick tracks` opens a picker by name, and
`:pick devices query=reverb` or `:pick.devices reverb` starts it with text
typed.

**In a picker** typing narrows the list; the best match is at the top and
selected, marked `▶`, with the letters that matched highlighted. `Ctrl-n`
`Ctrl-p`, `Ctrl-j` `Ctrl-k` or the arrows move, `PageUp` `PageDown` a page,
`Enter` chooses, `Esc` cancels, `Backspace` and `Ctrl-w` delete a character
and a word, `Ctrl-u` clears. The extra keys a picker has are listed along its
bottom, and a pane on the right shows more about the selected line when the
picker has one.

**Matching** is fuzzy, as in fzf: the letters typed must appear in the line in
that order, not necessarily together. `dfh` finds `Dragonfly Hall`. Lines rank
higher when the letters are consecutive, when they start words (after a
space, `/`, `:`, `.`, `_`, `-`, or at a capital inside a word), and when the
line is shorter. Words separated by a space must each match, in any order:
`hall drag`. Lower case matches either case; a word with a capital in it
matches case exactly.

**From Lua**:

```lua
daw.pick({
  title = "Tracks",
  items = { { text = "Bass", id = 3 }, { text = "Drums", id = 4 } },   -- or a function returning the list; an item may be a plain string
  format = function(item) return item.text end,   -- optional: the line shown and matched
  on_choose = function(item) daw.cursor.set_track(item.id) end,
  on_cancel = function() end,                     -- optional: Escape
})
```

`on_choose` gets the item itself, as it was given. Optional fields:

| Field | |
| --- | --- |
| `query` | text typed in already |
| `preview(item)` | lines for a pane beside the list: strings, or `{ text = ..., style = "Title" }` |
| `actions` | other keys: `{ ["<C-e>"] = function(item, query) end }`, or `{ fn = ..., desc = "edit", keep = true }` to list it at the bottom and leave the picker open |
| `multi` | `Tab` marks several; `on_choose_multi(items)` gets them (or `on_choose` is called for each) |
| `empty` | what to say when there is nothing to choose from |
| `primary(item)` | the part of the line that counts first: lines that match there rank above lines that match only elsewhere |
| `prompt`, `width`, `height` | |

`daw.pick.match(query, line)` returns the score and the positions that
matched, `daw.pick.filter(query, items, format)` the items that match, best
first. `daw.pick.state()` is the open picker's query, matches and selection.
`daw.pick.resume()` opens the last picker again.

**Adding a picker.** `daw.pick.sources` holds the pickers by name. Add a table
of the same fields with a `desc`, or a function returning one, and it opens
with `daw.pick("name")` and `:pick name`, and is listed by `,fp`:

```lua
daw.pick.sources.tempo = {
  desc = "Set the tempo from a list",
  title = "Tempo",
  items = function()
    return { { bpm = 90, text = "90 hip hop" }, { bpm = 124, text = "124 house" }, { bpm = 174, text = "174 drum and bass" } }
  end,
  on_choose = function(item) daw.project.tempo = item.bpm end,
  preview = function(item) return { "now " .. daw.project.tempo .. " bpm", "then " .. item.bpm .. " bpm" } end,
}
daw.keymap.set("<leader>fT", function() daw.pick("tempo") end, { desc = "Choose a tempo" })
```

`items` as a function is called each time the picker opens, so the list is
current. Several thousand items are fine: typing on narrows the last matches
rather than starting again, and only the lines on screen are drawn.

The graphical frontend shows a picker as it shows any floating view, through
`daw.frontend.float`, so the selected line is marked with `▶` and not only
with a colour.

## Configure it

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

[examples/config](examples/config) has a fuller configuration and two
extensions. [extensions/utau](extensions/utau) is a larger one: singing
synthesis with OpenUtau's engines, through ReaUtau's `reautau-engine`, with a
vocal editor and lyric sheet.

## The scripting interface

```lua
local daw = require("daw")   -- also the global `daw`
```

**Project, tracks, devices, clips.** Objects are handles: reading a field asks
the kernel, writing it tells the kernel. Volumes are in dB, positions and
lengths in beats, list positions count from 1.

```lua
daw.project.tempo = 112
local bass = daw.add_track({ name = "Bass", volume = -4 })
local synth = bass:add_device("synth", { wave = 2, cutoff = 500 })
synth:set("resonance", 0.3)
synth.bypass = false

local clip = bass:add_clip({ start = 0, length = 4 })
clip:add_note({ pitch = "A1", start = 0, length = 0.5, velocity = 100 })
clip:add_notes({ { pitch = 45, start = 1 }, { pitch = 48, start = 2 } })
-- An audio clip from a WAV, AIFF, FLAC, MP3 or Ogg Vorbis file, and its waveform.
local take = bass:add_clip({ start = 8, file = "take.flac" })
take:peaks(64)                 -- 64 { min, max } pairs, for drawing

local bus, echo = daw.add_track({ name = "Bus" }), daw.add_track({ name = "Echo" })
bass.output = bus              -- route into another track
bass:send(echo, -12)           -- and send some of it to a third, 12 dB down

daw.tracks()   bass:devices()   bass:clips()   clip:notes()   bass:clip_at(2)

-- One note at a time, named by its place among the clip's notes, which are
-- kept in the order they start. Nothing else crosses over, so this is what
-- an editor uses; `set_note` returns the note's place afterwards.
local note, at = clip:note_at("E2", 1.25)       -- the note sounding there
clip:set_note(at, { length = 2 })
clip:add_note({ pitch = "G2", start = 3, length = 1 })
clip:remove_note(1)
clip:notes({ from = 0, to = 4, low = "C2", high = "C3" })   -- a part of them, and their places
clip:edit_notes({ set = { { index = 1, start = 0.5 } }, remove = { 2 }, add = {} })  -- several as one edit
daw.project.save("song.json")   daw.project.load("song.json")
daw.render("mix.wav", { tail = 2 })
```

**Transport.**

```lua
daw.transport.play()   daw.transport.stop()   daw.transport.seek(8)
daw.transport.loop_start, daw.transport.loop_end = 0, 16
daw.transport.loop_enabled = true
bass:play_note("C2", 100, 200)     -- sound a note now, outside the timeline
daw.transport.record()             -- record armed tracks; see Input and recording
daw.transport.punch_start, daw.transport.punch_end = 16, 32   -- record only there
daw.transport.punch_enabled = true
daw.opt.count_in = 1               -- a bar counted before a take; transport.counting is what is left
```

**Automation.** `daw.lanes` shows lanes as rows of the arrange view:
`daw.lanes.open(track)`, `toggle`, `is_open`, `lines()` (also
`daw.groups.rows({ lanes = true })`: `{ track = id }` or `{ track = id, lane = id }`
for each row), `name(lane)`, `format(lane, value)`, `value_at(lane, beat)`;
`daw.cursor.lane_id()` is the lane row the cursor is on, `daw.cursor.line()`
its place among every row. Keys mapped with `view = "arrange.lane"` act on a
lane row ahead of the arrange view's own.
A lane moves a track's volume or pan, or one parameter of a
device on the track, along points of `{ beat, value }` in the target's own
units (dB, -1 to 1, the parameter's range), joined by straight lines and held
before the first point and after the last.

```lua
local fade = bass:automate("volume")            -- or "pan"; the existing lane if there is one
fade:add(0, -60)   fade:add(8, 0)               -- a point at a beat replaces any already there
synth:automate("cutoff"):set_points({ { 0, 200 }, { 16, 4000 }, { 16, 300 } })   -- two at a beat step
fade.enabled = false   fade:clear()   fade:remove()
fade:points()   fade:value_at(4)   bass:lanes()   bass:value_at("volume", 4)   synth:value_at("cutoff", 4)
```

While the transport plays, an enabled lane sets its target at the start of
every block, offline renders included, and wins over the fader or
`device:set`: those change the track's or device's own value, which is what
`track.volume` and `device.params` read. When playback stops the target stays
where the lane left it until it is set by hand or playback starts again;
turning a lane off or removing it puts the own value back. Removing a device
removes its lanes, and moving it to another track takes them along. Lanes are
saved with the project and undone like any edit, and report `lane.added`,
`lane.changed` and `lane.removed`.

**Commands, keys, events, options.**

```lua
daw.command(name, function(ctx) end, { desc = "..." })   -- ctx.args, ctx.count
-- What the arguments complete to on the command line: a completer's name for
-- every argument, a list of them by position, or a function returning strings
-- or { text = ..., desc = ... }. Completers: commands, tracks, devices,
-- track_devices, options, views, pickers, files, audio_files, projects; add
-- more to daw.commands.completers. daw.commands.complete(line) lists them.
daw.command("send.to", fn, { complete = { "tracks" } })
daw.command("mood", fn, { complete = function(text, info) return { "calm", "loud" } end })
daw.cmd("track.add", { "Bass", device = "synth" })
daw.keymap.set("<leader>x", "command and arguments", { view = "arrange", desc = "..." })
daw.keymap.set("gx", function(ctx) end)          -- ctx.count, ctx.register
daw.keymap.set("gz", fn, { mode = { "n", "x" } })    -- normal and visual mode; "i" is insert
daw.keymap.set("}", fn, { view = "arrange", motion = true })  -- a motion: also after operators and in visual mode

-- An operator gets a region: rows r0..r1, beats c0 up to c1, kind "char", "line" or "block".
-- Counts, text objects, visual mode, `.` and macros then work with it unasked.
daw.keymap.operator("gR", function(region, ctx)
  for _, id in ipairs(daw.edit.arrange.tracks(region)) do
    for _, clip in ipairs(daw.track(id):clips()) do
      if clip.start >= region.c0 and clip.start < region.c1 then clip.name = "take" end
    end
  end
end, { view = "arrange", desc = "Name clips `take`" })
daw.keymap.textobject("ip", function()               -- from the cursor to the playhead
  local row = daw.cursor.index()
  return { kind = "char", r0 = row, r1 = row, c0 = daw.cursor.beat, c1 = daw.transport.position }
end, { view = "arrange", desc = "Up to the playhead" })

daw.keymap.setreg(value, name)   daw.keymap.getreg(name)   daw.keymap.selection()
daw.keymap.feed("3jdd")          daw.keymap.normal("dic")  -- as typed; from inside a mapping
daw.edit.arrange.yank(region)    daw.edit.arrange.paste(value)   daw.edit.roll.delete(clip, region)
track:snapshot()                 daw.restore_track(snapshot, index)   -- with devices, clips, automation

-- A view of your own joins in by having a grid: where its cursor is, and how to move it.
view.grid = { get = function() return row, beat end, set = function(row, beat) end, step = function() return 1 end }

daw.on("track.added", function(event) end)    -- also track.changed, track.removed, track.moved,
                                              -- device.*, clip.*, lane.*, project.*, transport.*
daw.on("clip.*", fn)   daw.on("*", fn)   daw.emit("my.event", { any = "data" })

daw.opt.grid = 0.5                            -- see runtime/lua/daw/options.lua
daw.option.define("my_option", 42)
```

Change events are delivered when the current command or callback returns;
`daw.flush()` delivers them at once. Each command or key press is one undo step.
A handler may answer an edit with edits of its own, which join the same undo
step. Events from undo, redo, the undo tree or opening a project carry
`restored = true`: that state already holds whatever the handlers answered.

**Views.** A view is a table with a `render` function that draws into a cell
buffer. Errors in a view are shown in its place and do not affect the others.

```lua
daw.ui.view("clock", {
  render = function(self, buf, ctx)
    buf:fill(0, 0, buf.width, buf.height, " ", "StatusLine")
    buf:text(1, 0, daw.time.format(daw.transport.position), { fg = "#ff9e64", bold = true })
  end,
  on_key = function(self, key) end,           -- keys with no mapping
  on_mouse = function(self, event) end,
})
daw.ui.dock("clock", { side = "top", size = 1 })
daw.ui.toggle("mixer")   daw.ui.focus("arrange")   daw.ui.open("help", { title = "Keys" })
daw.ui.input({ prompt = "Name: " }, function(text) end)
daw.notify("message", "warn")
```

**Other.** `daw.defer(fn, ms)`, `daw.every(ms, fn)`, `daw.cancel(handle)`;
`daw.state.key = value` survives `:reload`; `project.meta` and `track.meta` are
saved with the project, for extension data; `daw.music.pitch("F#3")`,
`daw.music.degree("A4", "minor_pentatonic", 3)`; `daw.time.format(beats)`;
`daw.cursor` is the edit cursor; `daw.inspect(value)`; `daw.device_types()`
lists every device kind with its format and vendor. Notes may carry a `meta`
table too (`{ pitch = 60, start = 0, meta = { lyric = "la" } }`), which stays
with the note through edits. `daw.render` emits `render.before` and runs its
handlers before it starts.

**Helper programs.** An extension can run a program of its own and talk to it
over a Unix socket, in plain bytes: `daw.api.proc_spawn(argv, { env, cwd, log })`,
`proc_status(id)`, `proc_stop(id)` (asks it to finish, as Ctrl-C would, and
leaves it the time to), `proc_kill(id)`; `sock_listen(path)`, `sock_connect(path)`,
`sock_accept(id)`, `sock_read(id)` (`""` when nothing has arrived, nil once
closed), `sock_write(id, bytes)`, `sock_close(id)`. A device that takes data
from scripts answers `daw.api.device_call(device, method, bytes)`. A helper
is asked to finish when the program ends, however it ends.
`daw.json.encode(value, pretty)` and `daw.json.decode(text)` are for what an
extension keeps in files of its own.

Underneath, `daw.api` is a flat set of functions over plain data
(`daw.api.track_set(id, "volume", -6)`). The objects above are a thin Lua layer
over it in [objects.lua](runtime/lua/daw/objects.lua).

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
| `extensions/mixdiag` | the mix measured (LUFS, true peak, phase) and reported as findings to jump to |
| `extensions/undotree` | a window on the undo tree, named checkpoints, A/B listening |
| `extensions/rpp` | opening and writing REAPER projects |
| `extensions/tutor` | a course for first-time users, inside the program |
| `extensions/doctor` | a guided check of the real hardware (audio, MIDI, recording, plugins), with a written report: `:doctor`, `daw doctor` |
| `crates/daw-mcp` | a Model Context Protocol server in front of the control socket |

Each has a README of its own. Where a plugin needed something only the core
could give (measuring loudness quickly, a tree of undo states), that one
thing went into the core as an API function and the rest stayed outside.

## Extensions

An extension is a directory or a single file in `~/.config/daw/extensions`:

```
extensions/euclid/init.lua     run at startup
extensions/euclid/lua/         on the require path
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
anything that failed. Files in `~/.config/daw/lua/` shadow the built-in modules
of the same name, so any part of the runtime can be replaced.

**One interface, both frontends.** A view an extension registers with
`daw.ui.view` and draws in cells is usable from the graphical frontend with
no code of its own: it is offered under More in the window, opened with
`:view.window name`, and drawn there as the terminal draws it, with its keys
and its `on_mouse` (see "Views in windows" under
[The graphical frontend](#the-graphical-frontend)). A `title` field names it
in the menu, and `window = false` keeps it off. An extension that wants more
than cells in the window gives the view a `paint(g, ctx)` and a
`pointer(e)` as well: the window then paints it in pixels with
`daw.canvas`, and the terminal goes on drawing its `render`. The vocal
editor of extensions/utau does this. What an extension shows along the
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

## Scripts and other programs

`daw -l script.lua [args]` runs a script with no UI and exits, which makes the
DAW usable as a batch tool. A running instance listens on a Unix socket:

```sh
daw ctl eval 'daw.transport.position'
daw ctl cmd track.add Bass device=synth
daw ctl track_set 3 volume -6                 # any daw.api function
daw ctl keys 'ggm'
daw ctl eval 'daw.api.ui_snapshot(100, 30)'   # the screen as text
```

One JSON object per line: `{"id":1,"method":"eval","params":["..."]}`.
A connection can also be sent things: events it subscribed to, the state
a frontend draws (pushed when it changes, in parts), and the terminal
UI's screen. [docs/protocol.md](docs/protocol.md) is the whole protocol.

**An instance on another machine.** `daw attach` makes the terminal it
runs in a terminal of an instance that is already running: the same
screen, the same keys, beside the instance's own terminal if it has one
(`daw --headless` has none). `:detach` leaves and the instance runs on.
`daw ctl`, `daw attach` and `daw-gui` all reach an instance three ways:

```sh
daw attach                                   # this machine's socket
daw attach --socket /tmp/studio.sock         # another socket, such as one carried by SSH
daw attach --connect studio:7700 --token-file studio.token   # over the network
```

Over SSH needs nothing set up in the program and is encrypted:

```sh
ssh -N -L /tmp/studio.sock:/run/user/1000/daw.sock studio &
daw-gui --socket /tmp/studio.sock
```

Over the network the instance has to be started with `--listen-tcp
0.0.0.0:7700` (or `127.0.0.1:7700` for this machine alone). A connection
must show that it knows the token in `~/.local/state/daw/token` on the
instance's machine (made at the first start; copy it to the other
machine). The token is never sent, but the connection is not encrypted:
use it on a network you trust. What stays on the instance's machine: the
sound (it plays on its own sound device), plugin windows, and the files
that Open, Save and Import browse.

`daw doctor` is a script of its own kind: it runs the checks of
[extensions/doctor](extensions/doctor) that need nobody, with the sound device
open (unlike other scripts, which get the null backend unless told), and prints
the report. It takes the program's audio options, `--seconds`, `--plugin` and
`--only`, and finds the extension in the source tree beside the binary or in
`$DAW_HOME`.

## How it is put together

```
            ┌────────────── main thread ──────────────┐        ┌─ audio thread ─┐
 terminal ─▶│ keys ─▶ Lua runtime ─▶ daw.api          │  msgs  │                │
 socket   ─▶│         (views, keys,   │               │ ─────▶ │    Engine      │
            │          commands)      ▼               │        │ tracks,devices │
 terminal ◀─│ cell grid ◀── render   Session          │ ◀───── │ clips,transport│
            │                 project ─▶ sync ────────┼─ garbage, meters, position
            └─────────────────────────────────────────┘        └────────────────┘
```

| Crate | What it holds |
| --- | --- |
| `daw-engine` | The audio thread: tracks, routing, device chains, clip playback, transport, metronome. Built-in devices. cpal and null backends. No Lua, no UI. |
| `daw-core` | The project model, undo, the sync that drives the engine from the model, the Lua host and `daw.api`, the cell grid, the event loop, the control socket. |
| `daw-plugins` | CLAP, LV2 and VST3 hosting: scanning, the scan cache, and for each format a device for the audio thread and a controller for the main thread. |
| `daw-tui` | The terminal frontend and the `daw` binary. |
| `daw-gui` | The graphical frontend, written with Slint. A client of the control socket and nothing more. |
| `runtime/lua/daw` | Everything else. Compiled into the binary; `--runtime <dir>` loads it from disk instead. |

The rules the design rests on:

- **The project is plain data.** Tracks, devices and clips sit behind `Arc`, and
  edits copy on write. Undo is a tree of snapshots that share everything
  unchanged: undoing and then changing something starts a branch, and loses
  nothing.
- **One path to the engine.** `sync` diffs two snapshots and emits engine
  messages and change events. Edits, undo, loading and offline rendering all go
  through it, so the engine cannot disagree with the model.
- **The audio thread never allocates.** What it uses is built on the main
  thread and sent over a lock-free queue; what it is done with is sent back to
  be freed.
- **Several threads, one sound.** Tracks that do not feed each other are
  processed side by side on worker threads; what they send on is then added
  up on one thread in a fixed order. A render is the same file, byte for
  byte, on one thread or sixteen.
- **The screen is a grid of cells.** Lua draws into it and a frontend shows it.
  A frontend only needs to display cells and report input.
- **`daw.api` passes plain data only**, so it can be served over the socket as
  it is, and reloading Lua cannot leave anything dangling.

## Plugins

Installed CLAP, LV2 and VST3 plugins are devices like the built-in ones. Their
kinds are `clap:<id>`, `lv2:<uri>` and `vst3:<name>`; `:devices` lists them, and
`:device.add` takes any part of a kind or name (`:device.add dragonfly hall`).

```lua
local amp = guitar:add_device("lv2:urn:brummer:neuralrack")
local verb = guitar:add_device("clap:michaelwillis.dragonfly.hall")
for _, p in ipairs(verb:info().params) do print(p.key, p.name, p.min, p.max) end
verb:set("dry_level", 80)       -- by key, or by the name the plugin shows
```

- **Where they are found.** `~/.clap`, `~/.lv2`, `~/.vst3`, the Nix profiles and
  `/usr/lib`, or the directories in `CLAP_PATH`, `LV2_PATH` and `VST3_PATH`.
- **Parameters** are listed per instance, with keys made from their names. VST3
  values are normalized to 0..1; CLAP and LV2 use the plugin's own ranges.
- **State** is saved in the project file, restored on load, and carried over to
  offline renders and engine restarts. Parameters set through the project are
  applied on top of it.
- **Editors.** A plugin's own window opens with `device:open_editor()`, `ge` on
  a track, `e` or Enter in the device panel, or the `edit` button in the
  graphical frontend; `device.editor` is `"open"`, `"closed"` or nil. The
  windows belong to the kernel process, so they also work when the UI is a
  terminal. What is changed in an editor is read back: the project shows the
  plugin's value, and stops applying a value of its own for that parameter.
  A plugin added by hand (the device picker, `:device.add`, the window's
  "Add a device" box) opens its editor at once, as REAPER does: some
  instruments make no sound until it has been open. One added by a script,
  by loading a project, or with nobody at the program (`-l`, a kernel no
  window is watching) does not. `daw.opt.editor_on_add = false` turns it off.

  | Editor kind | How it is shown |
  | --- | --- |
  | CLAP, VST3 and LV2 editors for X11 (JUCE, DPF, VSTGUI, Xputty, …) | Embedded in a window of the host's, through XWayland on a Wayland desktop. |
  | LV2 editors in any toolkit that open their own window (`ui:showInterface`, and the older "external UI"): Gtk and Qt among them | They run in their own window. Gtk 3 and Qt ones are native Wayland windows when the toolkit is set up for it. |
  | LV2 editors that are a bare Gtk 2 or Gtk 3 widget | Put in a Gtk window, using the copy of Gtk the editor brings. |
  | CLAP editors that can only float | Left to make their own window, a native Wayland one if they can. |

  Editors are told the screen's scale (`Xft.dpi`, or `DAW_UI_SCALE=1.5`), so
  they are not tiny or blurred on a dense screen. A plugin's X11 mistakes do
  not end the program, and editors that cannot be resized say so to the window
  manager. Not shown: an LV2 editor that is a bare Qt widget with no way to
  show itself.
- **Presets.** A device's settings are saved under a name and loaded again,
  into the same kind of device in any project, as one undo step. `:preset`
  (`s` in the device panel) chooses one in a picker, the user's first and
  then the device's own; `:preset Warm` loads one by name or part of it;
  `:preset.next` and `:preset.prev` (`>` `<`) step through them;
  `:preset.save Warm` (`w`) saves the device as it is; `:preset.default`
  (`W`, or `Ctrl-s` in the picker) makes new devices of that kind added by
  hand start from the one loaded (`:preset.default none` stops that), and
  `:preset.delete` deletes one. In the window, a device's card shows its
  preset between `◀` and `▶`, and a click on the name opens a menu of them
  with "Save as a preset…". The device's own presets are those its format
  lists: CLAP preset discovery (Surge XT's patches, for one), `.vstpreset`
  files in `~/.vst3/presets/<vendor>/<plugin>`, `/usr/share/vst3/presets`,
  `$VST3_PRESET_PATH` and the plugin's bundle, LV2 presets known to lilv,
  and for the built-in devices the tables in `runtime/lua/daw/device_presets.lua`.
  Your presets are JSON files in `~/.local/share/daw/presets/<kind>/`
  (`daw.opt.presets_dir` puts them elsewhere) holding the plugin's state and
  every parameter's value; `defaults.json` beside them names the default of
  each kind. From Lua: `daw.fx.save(device, name)`, `daw.fx.load(device,
  name)`, `daw.fx.presets(device)`, `daw.fx.step(device, 1)`,
  `daw.fx.set_default(kind, name)`.
- **Plugins with hundreds of parameters.** `:param` (`f` in the device
  panel, or the "and N more parameters" line on the window's card) finds one
  by typing part of its name; Enter chooses it in the panel and shows it
  first on the card, which shows sixteen. The parameters chosen this way are
  kept with the device in the project (`Ctrl-x` in that picker stops
  showing one first). The parameter last moved, in the plugin's own window
  or here, is the *last touched*: the device panel goes to it when it moves
  in the plugin's window, the card shows it first, and `:param.last` (`t`)
  goes to it; `:param.last automate` shows its lane, `:param.last learn`
  binds a controller to it.
- **Each plugin runs in a process of its own**, a helper started from the
  same program. A plugin that crashes or hangs is lost alone: the session
  says which one and why, the track plays on (an effect that is gone is
  passed through, an instrument is silent), and `:device.restart` (`R` in
  the device panel, the Restart button in the window) starts it again with
  the state the project last had of it. Audio crosses in shared memory, and
  the audio thread waits for a plugin no longer than about a block lasts, so
  a slow plugin costs its own track a block and not everyone a dropout.
  One that answers no block for two seconds has hung: it is ended and
  reported like one that crashed, and `:device.restart` starts it again.
  A render waits for a plugin's block at most 20 seconds, once; after that
  the plugin is left out of the rest of the render, which says so.
  Every other request has a time limit: a plugin that hangs while it is
  made or saving its state is ended and reported instead of freezing the
  program. Plugin files are looked into in a process of their own too, and
  what is learnt is kept at once, so one that crashes there is only noted.
  A file that crashed or hung while it was looked into (or that was being
  looked into when the program itself was ended) is remembered with its
  modification time and passed over at later starts, with one line saying
  which, until the file changes or `:plugins.rescan` (every file) or
  `:plugins.rescan <name>` (files or plugins with that in their name) asks
  for it again.
  `--plugins-in-process` (or `DAW_PLUGIN_SANDBOX=0`) loads them into the
  program itself, which saves the crossing and gives up the protection.
- **Loading does not hold the program up.** When a project opens or a
  plugin is added, the device is there at once, marked `loading` (an
  instrument silent, an effect passing the sound through), while its helper
  makes it, four at a time. When it is ready it takes its place with its
  saved state and `device.ready` is sent. One that fails, or takes longer
  than 45 seconds, is `stopped` with the reason, like a plugin that crashed,
  and `:device.restart` tries again. A device that is loading or stopped
  keeps the state it was opened with: saving writes that back unchanged.
  Rendering waits for devices that are loading, and refuses, naming the
  device, when one could not be made. A device's `status` (in
  `device:get()` and the frontend's state) is `running`, `loading`,
  `stopped`, `offline` or `missing`. Scripts run with `-l` wait for each
  plugin as it is added unless they call `daw.api.load_apart(true)`.
- **A plugin that is not installed** stays in the project as it was: shown
  under its name (`missing`, "not installed"), with its saved state and
  parameter values, passed over in the chain, and written back unchanged
  when the project is saved. Opened where the plugin is installed, it is
  the plugin again.
- **Offline devices.** A device set offline is not made at all (no process,
  no sound) and is passed over; it keeps its state and parameters, and the
  flag is saved with the project. `o` in the device panel or
  `:device.offline` sets the selected device offline or back online, as do
  `device:set_offline(true)` and the plug button on a plugin's card in the
  window (an offline card says so and has an Online button). To open a project without its plugins: `daw --plugins-offline
  song.json`, `:edit song.json offline`, `daw.open(path, { plugins_offline =
  true })`, or the "(plugins offline)" entries of `:recover` (`:recover 1
  offline`). `:plugins.online` brings every offline device up, and
  `:plugins.offline` sets every plugin offline. Offline flags set this way
  are saved with the project like any other.
- **A plugin that could not be loaded is remembered.** One that failed or
  hung while a project was opening is noted beside the project's other
  state (`$XDG_STATE_HOME/daw/projects/`), not in the project file, and the
  next time the project is opened it is opened offline, with a message
  saying so; `:edit song.json online` opens it without holding any back.
  Once it loads it is forgotten.
- **Libraries a plugin needs.** A plugin built elsewhere expects the system
  to have the libraries it names. Where they are not on the loader's path
  (NixOS), they are looked for in the nix-ld directory, the system and user
  profiles, where the build found them (the dev shell says, in
  `DAW_PLUGIN_LIB_DIRS`) and the usual places of other systems, and loaded
  from there; `DAW_PLUGIN_LIBS` adds directories. The display's libraries
  (`libX11` and its relatives) are loaded ahead for every plugin, because a
  plugin's toolkit opens them by name when it makes its window: without
  them an editor is an empty black window.
- **Windows plugins through yabridge** draw and take the pointer in Wine,
  not here. If such an editor ignores clicks in part of the screen, or
  everywhere on one monitor, Wine's idea of the monitors is out of date: a
  Wine server that outlives a change of monitors or scaling keeps the old
  screen size and confines the pointer to it. `wineserver -k` (the one
  belonging to the Wine that yabridge uses) ends it, and the next plugin
  starts one that sees the screens as they are.

## Input and recording

**Devices.** The engine opens one output device and one input device. Which
ones is the machine's business, not the project's: chosen with `:audio`, the
engine indicator in the window, `--output`/`--input`, or from Lua, and kept
in `$XDG_STATE_HOME/daw/audio.json` for the next start. A remembered device
that is not connected is replaced by the system's default, with a message.

```lua
daw.audio.devices()      -- { outputs = { { name, id, channels, sample_rate, min_block, max_block }, ... }, inputs = {...}, output, input }
daw.audio.use({ input = "UR22" })                 -- by name, id or a part of the name; "default" for the system's
daw.audio.use({ output = "UR22mkII Stereo", buffer = 128 })   -- buffer 0: the device's own block size
daw.audio.levels()       -- the level arriving at each input channel, 0 to 1
daw.api.engine_get()     -- device, input_device, sample_rate, block, input_latency, output_latency (ms)
```

`:audio` lists the outputs, inputs and block sizes, with the sample rate,
block size and input and output latency at the top; `:audio.output <name>`,
`:audio.input <name>` and `:audio.buffer <frames>` do the same one at a time
(Tab completes the names). A name that matches nothing is refused with the
list of what there is. A part of a name finds the device with the most
channels that has it, so `UR22` opens a Steinberg UR22mkII's whole two-channel
input rather than one of the mono halves PipeWire can also offer.

With PipeWire, each device is a PipeWire node, opened by its node name: the
list leaves out the system's "default" entries, other programs' streams, and
sinks offered again as inputs. The block size is asked of PipeWire as the
node's latency and is a request: the graph may run another, which
`engine_get().block` reports.

**A track's input.** A track takes audio input from one channel or a pair of
neighbouring channels of the input device. The input is added to the track
ahead of its devices, so a guitar goes through the amp simulator on its track.

```lua
local gtr = daw.add_track({ name = "Guitar" })
gtr.input = "1/2"            -- or "1", "3", nil for none
gtr.monitor = true           -- hear it without arming
gtr.armed = true             -- record it
daw.transport.record()       -- recording on, and play
daw.transport.stop()         -- the take becomes a clip at the position recording began
daw.transport.recording = false

local keys = daw.add_track({ name = "Keys" })
keys.midi_input = { port = "Keystation 49", channel = 1 }   -- MIDI from one port (and channel); nil for all
```

`I` in the arrange view (or the header's input button in the window) lists
everything a track can take in, under three headings: audio (no audio input,
each channel and each neighbouring pair, named with the device:
`UR22mkII · 1`, `UR22mkII · 1/2`), MIDI (every port, or one) and MIDI channel
(every channel, or one). `daw.audio.choices(track)` is that list and
`daw.audio.choose(track, choice)` takes one; a choice that is saved but not
there now (a pair the device lacks, a port that is unplugged) is listed as
chosen and marked missing. `:track.input 1/2` and `:track.midi Keystation ch=1`
set them by name for scripts, and Tab completes both.

The header shows what the track takes in (`UR22mkII · 1/2`) and the level
arriving at its input, whether or not it is armed or monitored, so a guitar
can be seen arriving before anything else. `I` beside `M S R` in the terminal,
and the loudspeaker beside the input button in the window, switch monitoring;
`<A-i>` does too.

- **Monitoring.** A track's input is heard when the track is armed or its
  monitor switch is on. Arming always monitors, so what is recorded is what you
  hear. A track with no input ignores both.
- **What records.** While `daw.transport.recording` is on and the transport
  plays, every armed track with an input records its dry input (before its
  devices) to a WAV file, and every armed track without one plays and records
  MIDI input: from every port, or from the port (and channel) in its
  `midi_input`. Stopping or turning recording off ends the take, and seeking
  starts a new one. Its clips, audio and MIDI alike, are added as one undo
  step. Notes still held when it ends are cut off there.
- **Recording round the loop makes takes.** With the loop on, recording
  goes round it, and every time round becomes a take of one clip over the
  loop: the last is the one that plays, and the clip's name says which
  (`take 3 ‹3/3›`). What was played on the way into the loop is a clip of its
  own before it. The first time round counts if it began at the loop's start
  or before; the last if it got at least half way. With the loop off a take
  is one continuous clip. See [Takes](#takes).
- **Count-in.** `daw.opt.count_in` is how many bars the metronome counts
  before a take begun with the song stopped (0, the default, for none):
  `:countin 1`, `:countin off`, or `:countin` alone to turn it off and on;
  `gC` does the same. The record button, `R` and `daw.transport.record()`
  count in, and so does playing with record mode on; punching in by hand
  while playing does not. The clicks are at the tempo and in the signature
  at the playhead, a click on every beat of the signature and a higher one
  on each bar's first, whether or not the metronome is on, and heard as late
  as the song is. The playhead stays where it is while counting, and the
  song and the take start on the frame after the count, so what is recorded
  lines up exactly as without one. `daw.transport.counting` is the number of
  beats still to count (0 when none is under way); the status line reads
  `count 3` and so does the window's clock, with the record button blinking
  on the beats. Stop, or `Esc`, during the count calls it off: no take,
  nothing recorded, record mode off.
- **Punch in and out.** With `daw.transport.punch_enabled` on, a take is
  recorded only from `punch_start` to `punch_end` (beats) while the song
  plays on either side: capturing starts and stops on the frame at those
  points, and the clip made covers exactly the range (a note held across the
  punch out is cut there). Started inside the range, it records from the
  playhead to the punch out; started after it, it records nothing and says
  so. With the loop on as well, each time through the range is a take of one
  clip over it, as each time round the loop is without punching (the first
  time counts if it began at the punch in or before, the last if it got at
  least half way; a range reaching past the loop's end is cut there). `:punch`
  turns it on and off, `:punch 5 8` punches over bars 5 to 8 (as
  `:transport.loop` counts them), and `:punch selection` over the visual
  selection, or the loop when there is none; the first `:punch` with no range
  set does the same. `gI` toggles it, and on a selection punches over it. The
  range is saved with the project, like the loop, and is not undoable. It is
  red on the ruler of both frontends, under the loop in the window, where
  its ends are dragged like the loop's; the timeline's menu has the entries.
  There is no pre-roll: the song plays from wherever the playhead is.
- **Files** go in a `media` directory beside the project file. A project that
  has never been saved records into `~/.local/share/daw/recordings`; saving it
  links or copies those files into `media` beside it and points the clips
  there, leaving the originals for earlier undo steps.
- **Takes that end badly.** A take's WAV header is brought up to date and
  the file flushed to the disk every two seconds, so a file left by a crash
  or a power cut is a valid WAV of all but its last seconds. The take is in
  the safety copy from the moment it begins: after a crash, `:recover` puts it
  back as a clip where it began, on its track. Opening a project whose `media`
  directory holds takes that no clip refers to and that were written after
  the project was last saved says so, and `:recover` lists them to bring in
  (on the track they were recorded for), also after the project's folder
  has been moved. If a file cannot be written (the
  disk is full), recording stops, what was written is kept as a clip, and a
  message says why. Recording that starts with room on the disk for less
  than `daw.opt.record_warn_minutes` (30) minutes says how many are left.
- **MIDI input** comes from every ALSA sequencer port, which with PipeWire
  includes its MIDI devices, and from ports that appear later. `daw.midi.inputs()`
  lists them, `daw.midi.select({ "Keystation" })` keeps only some open (by id or
  part of a name, `nil` for all). A track's `midi_input` names its port by name,
  so it is found again when the keyboard is plugged in later or elsewhere.
  Notes held on a port that goes away are released. Ports are only opened with
  a real audio device; scripts on the null backend can play
  `daw.midi.note_on("C4", 100)` and `daw.midi.note_off("C4")`, or
  `daw.midi.inject({ type = "note_on", pitch = 60, velocity = 100, port = "Keys A" })`
  as if from a port. `:midi.inputs` and `:midi.select` do the same from the UI.
- **MIDI from other programs.** `daw.midi.open_port("Guitar")` makes a port of
  the program's own that others send to: PipeWire and the sequencer show it
  as `daw: Guitar`, it is listed among the inputs, and a track takes it by
  that name like any port. What arrives there is that port's, whoever sent
  it. `daw.midi.close_port("Guitar")` takes it away. The
  [vinput](extensions/vinput) extension feeds such a port from a guitar.
- **Sound files** are brought in with `:import take.mp3` (alone, it lists
  files to choose from; `daw.pick.file` is that list for extensions),
  `daw.import_audio(path, { track = ..., start = ... })`, or by naming the
  file where a project would be named on the command line. `:clip.import`
  puts one on the cursor track.
- **Latency.** cpal runs input and output as separate streams, joined by a
  ring that holds at most one input period plus one output block; when the
  clocks drift, the excess is dropped or the last frame repeated.
  `daw.api.engine_get()` reports `input_latency` (the system's capture delay
  plus that ring) and `output_latency`, in milliseconds, as the backend
  measures them. `--no-input` leaves the input closed.
- **A device that goes away.** When the audio device is lost (a USB
  interface unplugged, the sound server gone), the transport stops, a take
  being recorded is closed and kept, the program says which device was lost
  and goes on without sound, so editing, saving and rendering carry on.
  Every three seconds it looks for the device, and once it is back opens it
  again with the same sample rate, block size and input, saying so; the
  tracks keep their inputs. `:audio.reconnect` tries at once, and
  `daw.opt.audio_reconnect = false` leaves reopening to that command. The
  engine indicator reads `lost: UR22mkII` meanwhile, and
  `daw.api.engine_get().lost` names the device. A MIDI input that goes away
  and comes back is told of both times, with the tracks that take it; they
  take it again by its name.
- **Testing without hardware.** The null backend can generate input: input
  channel `n` carries a sine at `n` times the frequency, offered as the input
  device `test signal`; `test_midi` gives it MIDI ports to list.
  `daw.api.engine_restart({ backend = "null", test_input = { frequency = 440, level = -12, channels = 2 }, test_midi = { "Keys A" } })`.
  With `midi = true` the null backend opens the real MIDI ports all the same,
  for trying MIDI from hardware or another program with no sound. The
  `test` backend is the null backend with a pretend device that can be
  unplugged: `daw.api.audio_test_device({ fail_after = 100, back_after =
  2000 })` loses it 100 blocks into the next stream and brings it back two
  seconds later; `daw.api.midi_test_ports({ "Keys A" })` changes the MIDI
  ports the null backend lists.

## The graphical frontend

`daw-gui` is a separate program for working with the mouse: transport,
tracks with faders and meters, clips on a timeline, the devices of the
selected track, a mixer and a piano roll. It starts a kernel of its own
(`daw --headless`) and stops it on exit, or attaches to a running one:

```sh
daw-gui song.json                 # its own kernel; options are passed on to it
daw --headless --listen /tmp/daw.sock &
daw-gui --socket /tmp/daw.sock    # watch and drive a kernel that is already running
daw-gui --connect studio:7700 --token-file studio.token   # one on another machine
```

The window is sent what it draws when that changes, instead of asking for
it: an idle project costs nothing on the wire, and a change sends only the
part that changed (see [docs/protocol.md](docs/protocol.md)).

The window remembers how it was left, for the machine, in
`~/.local/state/daw/window.json`: its size, the timeline's zoom, the height
of the rows and of the piano roll, and whether the mixer shows. It writes it
when a value has stood for a second and when it closes, through
`daw.frontend.layout_get()` and `layout_set(table)` in the kernel, so a window
attached to a running kernel finds it too.

It keeps no project state. Thirty times a second it calls
`daw.frontend.state(revision)` over the socket, and everything the user does
goes back as commands, so it and a terminal UI or a script can drive the same
session at once.

The window is drawn on the processor (Slint's software renderer), which works
everywhere. `daw-gui --renderer gpu`, or `DAW_GUI_RENDERER=gpu`, draws it
with OpenGL on the graphics card instead: worth trying on a large screen,
where the processor has many pixels to fill while playing. It needs the
system's OpenGL driver (on NixOS, `hardware.graphics.enable`); where OpenGL
cannot start, the window says so in one line and draws on the processor. It
has not been tried on a real graphics card yet, so it is not the default.
Either way the window draws again only what has changed: the playhead, the
clock and the meters while playing, next to nothing at rest. The piano roll
and the timeline are handed only the notes, lines and points near what
shows, so a clip of thousands of notes opens and scrolls as fast as a short
one. Measured with the demo song in a 1500x960 window (software renderer,
on a busy machine): 1–2% of a core at rest, 17–42% playing, 9–21% scrolling,
25% playing with the piano roll open; maximised on a 3840x2160 screen, 2% at
rest and 48% playing.

It looks like a mixing desk rather than a web page. Surfaces are neutral
greys, and colour means something: blue is the selection, the edit cursor
and a lit switch; amber the playhead and the loop; green playing; red
recording and arming; orange mute; yellow solo. A track's own colour is on
its stripe, its clips, its notes and its name plate in the mixer, and
nowhere else. Words are in Inter and numbers that change (the clock, levels,
values) in JetBrains Mono; both fonts are built into the program
(`crates/daw-gui/ui/fonts`, under the SIL Open Font License), so the window
looks the same on any machine. Icons are Phosphor's (MIT,
`crates/daw-gui/ui/icons-LICENSE`).

Each track header has its number, its name, the input, monitor, `M`, `S`
and `R` switches (lit in their colours when on), a fader with its level in
dB and a pan knob, then what it takes in and goes through, and at its right
a meter for each side with a clip light on top. Rows show less as they get
shorter: at the shortest only the first line. Meters are coloured by level
(green to −18 dB, then yellow-green, yellow, orange, red from 0 dB), hold
their peak for a moment as a thin line, and light the clip light when a
level reaches 0 dB; it stays lit until it is clicked. The mixer has a strip
per track, with the master at the right: where it plays into, its devices
(a click on one picks it in the device panel), pan, a fader with a scale
beside its meters, the fader's level and the peak held, `M` `S` `R`, and
its name on its colour. The status line at the bottom says what the pointer
does wherever it is.

| Where | What the pointer does |
| --- | --- |
| Timeline | click puts the cursor and lets go of the chosen clips; double click makes an empty one-bar MIDI clip; drag across empty lanes selects a stretch of time on those tracks (then `Delete`, or right click to delete, copy, loop or mute it); a drag with the right button draws a box that chooses the clips it touches (Shift adds them, Ctrl turns them over); the middle button held pans; right click (on release, where the button was not dragged) for a new clip, paste or a new track |
| Clip | click chooses it; Ctrl and a click adds it to the chosen clips or takes it out; Shift and a click takes in the clips between it and the last one chosen (on one track by time, across tracks the rectangle). Dragging a chosen clip moves all of them, keeping their places, also across tracks; Ctrl drops copies; they move by whole grid steps, so a clip off the grid keeps its distance from it; Shift leaves the grid. Either edge trims the clip, and the same edge of every chosen clip: the start without moving what plays (an audio clip starts further into its file; a MIDI clip hides the notes before its new start, which come back when the edge is dragged out again); Alt and an edge slips what plays inside instead. On an audio clip the handles at the top corners drag its fades, drawn over it, and its top line drags its gain (Shift finely), which the waveform's height follows. Double click opens its notes; right click to rename, split at the pointer or at the edit cursor, glue the chosen clips, repeat, mute or delete. One gesture is one undo step. Two or more chosen clips are visual mode's selection, so `d`, `x`, `y`, `>`, `gc`, `J` (glue) and the rest act on them, `S` splits them at the cursor, `Esc` lets go; one clip chosen with a click is the clip under the cursor |
| Ruler | click puts the edit cursor and the playhead; a drag in its top half loops the stretch dragged over (in the bottom half it moves them to where it ends); drag the loop's edges to change it; double click turns the loop on or off. The punch range is the red line under the loop's band (grey while punching is off): drag its ends to move them, Shift off the grid; the timeline's menu sets it from the selection or the loop and turns it on and off. Bars are numbered by the tempo map; a flag marks each tempo change (`96`) and signature change (`6/8`): drag it to move it, double click it to type a value, right click it to remove it |
| Track header | click selects; double click renames; drag up or down to reorder, into a group when dropped among its tracks or under its header, out of it when dropped outside; drag the bottom edge to make the track taller or shorter (double click it for the height of the others; the height is kept with the track); press M, S or R and sweep across the others to set them all as the first was set; Shift on the fader moves it finely, double click puts it at 0 dB; right click (on release) for a colour, duplicate, bounce to audio, a new track below, delete |
| Piano roll | the mouse works as in REAPER's MIDI editor. Left button on empty grid: press where a note should start and drag as far as it should last (a click gives the note length shown in the toolbar, which drawing or stretching a note sets). Shift leaves the grid while drawing, moving or stretching; the magnet in the toolbar turns snapping off altogether. A click on a note chooses it, Shift or Ctrl click adds it or takes it out; dragging a note moves it and the others chosen (Ctrl drops copies), dragging either end changes where they all start or stop, and the status line shows the note's name, place and length meanwhile. The right button dragged, or the left with Ctrl, chooses the notes its box touches (Shift adds, Ctrl toggles); a right click removes a note, or on empty grid opens a menu (choose all, let go, delete, quantize, snap); a double click removes a note; Alt and a drag erases every note crossed. The keyboard sounds a key under a click or a drag, and a right drag over it chooses the notes in that range of pitches. The wheel scrolls, with Shift sideways; Ctrl and the wheel zoom in time and Alt the rows, where the pointer is; the middle button pans. `Ctrl-a` (in the window), `gA` chooses every note, `x` or `Delete` removes the chosen, `Esc` lets go. The strip underneath shows velocities, set by dragging across the bars (only the chosen notes, if any are chosen), or a controller chosen from its dropdown (pitch wheel, modulation, expression, pedal), drawn with the pointer held down and cleared with a right click. The toolbar holds the clip, the grid, snap, the note length, Quantize (`:notes.quantize`, the chosen notes or all), Step (`:notes.step_input`: with the transport stopped, notes played on a MIDI keyboard are entered at the cursor, chords together, and the cursor steps on), zoom, a window of its own and close. It also says how many notes are chosen and where. The ruler counts bars and beats; a click there moves the playhead. Notes of the track's other clips that sound at the same time show faintly behind |
| Recording | the record button starts a take on the armed tracks (the `R` on a track). A track's input button (the microphone; blue when an input is chosen, and what it takes in, such as `UR22mkII · 1/2`, is written under the fader) opens a menu of its audio inputs, MIDI ports and MIDI channels; a bar along its foot shows the level arriving there, armed or not, and the loudspeaker beside it turns monitoring on. With no audio input a track records MIDI. With no track armed the record button arms the selected one and says so. Press it again, or stop, to end the take; what is being recorded is drawn in red as it grows (punched, only over the punch range). With a count-in the clock reads `count 4`, `count 3`… and the button blinks on the beats until the take starts; the timeline's menu turns the count-in on and off |
| Take lanes | a track's menu, a clip's Takes menu or `zt` shows its takes as lanes under its clips. Drag across lane k: take k plays over that stretch (on the grid, Shift off it), the clips cut at its ends and pieces that then play the same take joined back, one undo step; a click on lane k gives the piece under the pointer take k; right click to hide them |
| Groups | a track's menu has "New group with this track…", "Move into a group…" and "Take out of its group". A group's members stand under it, a step in and in its colour, and sound through it; the triangle beside its name folds them away and brings them back |
| Routing | above the selected track's devices: "Output" chooses the track it plays into, "+ Send" a track its sound is sent to as well; each send has a level to drag, `pre` to take it ahead of the fader, and a cross to take it away |
| Templates | with the templates extension: a track's menu saves it (or, on a group, the whole group) and saves its devices as a chain; `Track` → "From a template…" makes one again, and "Add devices from a template…" puts a saved chain on the track |
| Mixer | drag a fader (0 dB sits at 72% of its travel) or turn the pan knob by dragging up and down, with Shift finely; double click for 0 dB or centre; the wheel nudges. A click on a device in a strip picks it in the device panel, a click on the clip light or the peak readout clears it |
| Devices | type part of a name to find a device or plugin, Enter or a click adds it (Esc lets go of the box); drag a parameter, wheel to nudge it, double click to put it back; the power button turns a device off and on, the arrows move it along the chain, the window button opens a plugin's own editor |
| Transport | back to the start, stop, play or pause, record, loop and metronome; drag or wheel over the tempo to change it, double click to type it; click the project's name for the file menu: new, open, open recent (a submenu, with "Clear the list" at its end), recover, save, save as, import, render, quit (a dot beside it means there are changes); Mixer, Automation and Piano roll show and hide those views, and More lists every other view the kernel has (the extensions' among them), each to open in a window of its own; click the engine indicator (`pipewire · UR22mkII · 48 kHz`) for a menu of output and input devices and block sizes, headed by the sample rate, block size and latencies |
| File | New, Open and Quit ask first when there are changes: save them (a project with no file yet is asked where it goes), don't, or stay. So does closing the window. Render… opens a dialog: the file, the range (the song, the loop, the selection, a region), WAV or FLAC (and MP3, Ogg or Opus when ffmpeg is installed: the sample size and dither give way to a quality of Low, Medium, High or Best), the sample size, the tail, normalizing, dither, mono, and a file per track; the render runs in the background with its progress and a Cancel in the status line. Open…, Save as…, Import and the render's `…` button show the desktop's own file dialog (see below) |
| Lanes as rows | a track's menu has Automation ▸ Show or hide the lanes as rows: each of its lanes is then a row of its own under its clips, always there to draw on (click adds a point, hold to draw, drag a point, right click removes it), while the clips above stay editable. A track with no lane yet gets one for its fader. The same menu sets the track's automation mode, as does the `A` flag on its header |
| Automation | with Automation on, each track shows one lane over the timeline, named at its left. Click adds a point, holding the button down draws a curve, drag moves a point, right click removes one; right click elsewhere clears the lane or turns it off. The header's last line chooses the lane: volume, pan, or a parameter. The small curve button beside a device's parameter gives that parameter a lane and shows it |
| Wheel | scrolls; with Shift sideways; with Ctrl it zooms in time where the pointer is, in the timeline and in the piano roll, and over the track headers makes every track taller or shorter; with Alt it makes the tracks (or the piano roll's rows) taller and shorter |
| Pages over the window | a picker's rows (commands, files, devices) take the pointer: a click selects a row, a double click or Enter chooses it, the wheel scrolls; a click outside closes the page; "Open in a window" at its top right moves the page into a window of its own, in its colours |
| Bands under the ruler | under the markers, a row for each extension that adds one: the sections of the song, the mix's findings. A click on an entry does what it stands for (goes to the section, to the finding); the status line says what |
| Zoom | the buttons in the corner of the timeline: `−` and `+` in time (`Ctrl -`, `Ctrl +`), `Fit` for the whole song (`Ctrl 0`), the arrows for the height of the tracks (`Ctrl ↑`, `Ctrl ↓`), from one line a track to tall ones. Waveforms are drawn again at the width they then have |
| Sound files | `Track` → "From a sound file…", or "Import a sound file…" in the timeline's menu, lists files to choose from (type to narrow, Enter walks into a directory): wav, aiff, flac, mp3 and ogg come in on a track of their own at the cursor. `:import path` does the same, and `daw-gui take.mp3` starts a project with the file |

When the window started its kernel, so that the kernel's disk is the
window's, files are chosen in the desktop's own dialog, asked for through
the XDG desktop portal (`org.freedesktop.portal.FileChooser` over D-Bus, with
no toolkit linked). It offers projects, sound files and all files, and starts
where a file was last chosen, else beside the project; the list picker starts
in the same place. The dialog does not stop the window. Without a portal (no
session bus, a bare window manager), with `daw.opt.native_dialogs = false`, or
when the window is attached to a kernel with `--socket` (which may be on
another machine), the kernel's list picker is used, as it always was. A
project chosen this way asks about unsaved changes like any other way of
opening one: `daw.frontend.act.leave(how, "open:" .. path)`.

Files can be dragged in from a file manager on X11: a sound file becomes a
track of its own, one for each file dropped together, with the clip at the
edit cursor; a project (`.json`) asks to open it, through the same question
about unsaved changes; anything else is named in the status line as not
taken. What a drop means is `daw.frontend.act.drop(paths, row, beat)`: with a
`row` (a place in the list of tracks) and a `beat` it puts the files one
after another on that track, at the beat on the grid; the window cannot say
where the pointer was, for winit 0.30 does not tell, so it passes neither.
Wayland sends the window no drops at all with this version of winit.

Every key still goes to the kernel's key mappings, so the window is also
driven exactly as the terminal UI is: the same modes, operators, registers
and macros, with the mode, the prompt, messages and half-typed keys in the
status line, the selection and both cursors drawn, the keys that can follow
listed, and help and other pages shown over the window. `Ctrl-z`, `Ctrl-y`,
`Ctrl-s` and `Delete` do what they do elsewhere. The piano roll and mixer are
the kernel's: opening one puts the keyboard in it.

What a gesture means is not decided in the window. It calls
`daw.frontend.act` in the kernel (`select_clip`, `select_clips_box`,
`drag_clips`, `trim_clips`, `set_fade`, `set_clip_gain`, `split_clips`,
`glue_clips`, `move_track`, `set_track_height`, `sweep_flag`, `select_range`,
`set_loop`, `set_loop_edge`, `ruler_click`, `float_pointer`, `add_note`,
`drag_notes`, `stretch_notes`, `select_notes_box`, `erase_notes`,
`draw_velocities`, `quantize_notes`, `set_velocity`, `set_param` and so on),
where beats
snap to the grid and the suite tests each one, so another frontend gets the
same behaviour by sending the same gestures. The clips chosen with the
pointer are kept there too (`daw.frontend.chosen_clips()`), and the state
marks each clip `selected`.

**Views in windows.** Any view of the terminal can be opened in a window of
its own, as it is: `:view.window undotree` (the focused view, or the page
floating over the others, without a name), More beside the view switch, or
"Open in a window" on a floating page. The kernel draws the view by itself
at the window's size, in cells of the bundled JetBrains Mono (their size is
measured on the font, so box-drawing characters join), with the theme's
colours in 24 bits whatever the terminal shows, and sends it as runs of text
of one style each. Under it a line shows a prompt being answered, a message,
or the view's keys. Keys typed there go to the view's mappings with the view
focused, a prompt it opens is answered there, and the pointer reaches its
`on_mouse` in cells, as from a terminal: down, up, drag, scroll. Closing the
view (`q`, `daw.ui.close()`) closes the window. It is drawn again only when
a redraw has been asked for and what it would show has changed, at most 30
times a second. The font has no braille, so curves in such a window are
drawn with line characters, as with `daw.opt.braille` off. A terminal
attached to the same kernel is not disturbed: the view is drawn on a grid of
its own (`daw.api.ui_view_snapshot(name, width, height)` gives the same as
rows of runs `{ x, w, text, fg, bg, attrs }`).

**Windows for extensions.** A view that paints can be shown in a window of
its own, so an extension brings its own editor to the graphical frontend
without the frontend knowing anything about it:

```lua
daw.ui.view("scope", {
  paint = function(self, g, ctx)                 -- pixels; ctx.width, ctx.height
    local c = daw.canvas.palette                 -- the window's colours, by name
    g:rect(0, 0, ctx.width, ctx.height, { fill = c.surface })
    g:text(12, 10, "hello", { color = c.text, size = 14, bold = true })
    g:poly({ 0, 80, 40, 60, 80, 90 }, { color = c.select, width = 2 })
    local part = g:sub(0, 100, ctx.width, 200)   -- drawn from its corner, cut at its edges
    g:mono(12, 40, "┌─ cells ─┐", { color = c.text, background = c.well })  -- a run of monospace cells
  end,
  pointer = function(self, e) end,               -- e.kind: down, up, move, double, wheel; e.x, e.y, e.button
})
daw.canvas.open("scope", { title = "Scope", width = 640, height = 360 })
```

The kernel paints the view at the window's size and the frontend draws the
rectangles, text and lines it is given. `daw.canvas.palette` holds the
window's colours under the names the window itself uses (`surface`, `lane`,
`panel`, `well`, `control`, `line_bar`, `text`, `text_2`, `text_3`,
`select`, `play`, `rec`, `mute`, `solo`, `warn`, `error`, the meter colours
and a keyboard's), and the editors of the extensions draw with it; keys go to the view's mappings as in
the terminal. The vocal editor of [extensions/utau](extensions/utau) is made
this way ([gui.lua](extensions/utau/lua/utau/gui.lua)): notes with lyrics,
the pitch that is drawn and the pitch that is sung, phonemes, a toolbar with
the singer, tools and grid. An extension with an editor of its own for some
clips adds a function to `daw.frontend.openers`, and a double click on such
a clip opens it there.

**Menu entries for extensions.** The right-click menus of clips, track
headers and the empty timeline take entries from `daw.frontend.menus`:

```lua
table.insert(daw.frontend.menus.clip, { label = "Open as notation", command = "notation.open", only = "midi" })
table.insert(daw.frontend.menus.timeline, { label = "New drum track", run = function(track, beat) end })
```

`command` is a command line, `run` a function given the clip or track and the
beat that was clicked; the cursor is put there first. `only` greys a clip's
entry out on clips that are not `"midi"` or `"audio"`. The timeline's entries
are also offered by the buttons that make a track, so an extension's kind of
track (a drum track) is one click away in an empty project.

**Bands under the ruler.** An extension adds a row of its own under the
ruler's markers with a function in `daw.frontend.bands` that returns the
band's entries:

```lua
table.insert(daw.frontend.bands, function()
  return { { beat = 0, length = 16, name = "Intro", command = "section.goto 1", hint = "click goes there" } }
end)
```

An entry with a `length` is drawn over its stretch, one without as a flag;
`color` (`#rrggbb`) lights it, `command` (a command line) or `run` (a
function given the entry) is what a click does, and `hint` is what the
status line says over it. A band with no entries takes no room. The bands
are asked again when the project, the cursor or the transport changes;
after a change of its own an extension calls `daw.frontend.refresh()`.
The sections and the mix's findings are shown this way.

## Built-in devices

| Kind | Parameters |
| --- | --- |
| `synth` | `wave` (sine, saw, square, triangle), `attack`, `decay`, `sustain`, `release`, `cutoff`, `resonance`, `gain` |
| `drums` | `gain`, `kick_tune`, `decay`. A synthesized kit on the General MIDI drum notes: kick (35, 36), rim (37), snare (38, 40), clap (39), closed, pedal and open hat (42, 44, 46; the closed and pedal hat cut the open one off), six toms (41 to 50), crashes, china and splash (49, 57, 52, 55), ride (51, 59), ride bell (53), tambourine (54), cowbell (56). |
| `sampler` | `gain`. One sound file per note, each with a level, pan, tuning and choke group. The kit is the device's state: text lines `note level pan tune group path`, set with `daw.api.device_set(id, "state", base64)`; the files are read off the audio thread. `extensions/drums` makes kits from folders. |
| `gain` | `gain` |
| `delay` | Echoes: `time` (ms), or `sync` to a note length at the tempo of the moment (`1/8.`, `1/4T`...), `feedback`, `mix` (the echoes' level; the dry stays at full level), `mode` (stereo or ping-pong), `low_cut` and `high_cut` on the repeats (off at the ends of their ranges), `width`. A new time glides there, like tape. |
| `chorus` | Doubles and widens a guitar or a pad: `rate` or `sync`, `depth`, `delay`, `feedback`, `spread` (the right side's LFO behind the left's), `mix`, `voices`. |
| `flanger` | The jet sweep: `rate` or `sync`, `depth`, `delay`, `feedback` (negative for the hollow sound), `spread`, `mix`. |
| `phaser` | `rate` or `sync`, `depth` (up to three octaves each way), `center`, `stages` (2 to 12), `feedback`, `spread`, `mix`. |
| `tremolo` | `mode` (tremolo, or auto-pan at equal power), `rate` or `sync`, `depth`, `shape` (sine, triangle, a softened square). Synced LFOs lock to the song's position while it plays. |
| `limiter` | The last device on the master: `ceiling` (default -1 dB), `gain` (drive into it), `release`, `true_peak` (on by default: the peaks between samples are held under the ceiling too, as a BS.1770 meter reads them, with 0.2 dB to spare). Looks 5 ms ahead, so nothing leaves it above the ceiling; the rest of the mix waits for it. `daw.params.read(l, "meters")` gives `gr` and `input` in dB. |
| `eq` | A parametric equaliser for shaping any track or bus: eight bands, each with `bN_on`, `bN_type` (low cut 12 or 24 dB/oct, low shelf, bell, high shelf, high cut 12 or 24, notch, band pass), `bN_freq`, `bN_gain`, `bN_q`, and `output`. Flat until a band is moved; settings glide without clicks. `daw.params.read(eq, "curve", n)` gives its response in dB at `n` frequencies from 20 Hz to 20 kHz on a log scale, for drawing. |
| `compressor` | Evens out a vocal, glues a drum bus, or (with `mix` below 100 %) compresses in parallel: `threshold`, `ratio` (the top of its range is a limit), `knee`, `attack`, `release`, `auto_release` (a fast release after short peaks, a slow one after sustained compression), `makeup`, `auto_makeup` (gives back half of what a 0 dB peak loses), `lookahead` (reported as latency), `detector_hp` (so the kick does not drive it), `detect` (peak or RMS), `mix`, `link`. `daw.params.read(c, "meters")` gives `gr`, `input` and `output` in dB; `"curve"` the static curve. |
| `reverb` | Room and plate sounds for vocals, drums and buses: an eight-line feedback delay network whose lines drift slowly so that it does not ring. `size`, `decay` (seconds to fall 60 dB), `predelay`, `damp_high` and `damp_low` (where the highs and lows start dying sooner; off at the ends of their ranges), `diffusion`, `early` (early reflections against the tail), `width`, `mix` (the dry stays at full level up to 50 %, the wet reaches full level there). |
| `utility` | Level and stereo fixes: `gain`, `pan` (a balance: the far side fades out), `width` (0 % is mono, 200 % twice as wide), `mono_below` (the sides taken out under this frequency; off at 20 Hz), `invert_l`, `invert_r`, `swap`, `dc` (a 5 Hz high-pass). |
| `saturation` | Warmth or grit on a bass, a drum bus or a vocal: `drive`, `curve` (tape: soft and symmetric; tube: biased, adds even harmonics; hard clip), `oversample` (2x or 4x, so the harmonics do not fold back as noise), `tone` (a high shelf after the curve), `mix`, `output`. Quiet audio passes at its own level; 31 samples late (0.65 ms at 48 kHz), reported as latency. |
| `meter` | Measures and passes the audio through untouched, for the master or any track: `daw.params.read(m, "meters")` gives `momentary`, `short_term` and `integrated` loudness (LUFS, EBU R 128 with its gates), `true_peak` (dBTP) and `sample_peak` held since `daw.params.read(m, "reset")` (or for 3 s with `hold`), `rms_l`, `rms_r` and `correlation` over 300 ms; `"spectrum", n` gives dB in `n` bands from 20 Hz to 20 kHz. Readings not taken yet are -200. |
| `tuner` | Tunes a guitar or a bass: `daw.params.read(t, "pitch")` gives `freq`, `note` (`E2`), `midi`, `cents` and `confidence`, from the last 85 ms (YIN); `reference` sets A4, `mute` silences the track while tuning. |
| `gate` | Cuts the spill between hits on a drum track, or the noise between phrases: `mode` (gate or expander), `threshold`, `range`, `ratio` (expander), `attack`, `hold`, `release`, `hysteresis`, `lookahead`, `detector_hp`, `detect`, `link`. The same meters as the compressor. |

In the device panel the equaliser draws its curve, the compressor, gate and limiter their gain reduction, the meter its loudness and the tuner a needle, under their names. `:eq` and `:tuner` show the track's equaliser or tuner (adding one if it has none), `:loudness` the master's meter; in the window each opens a window of its own (also from the track menu, and the timeline's for the meter), and in the equaliser's window a band's dot is dragged to move it, the wheel over it changes its Q, and a double click turns a band off, or on as a bell where the empty space was clicked.

`daw.params.presets(kind)` lists a device's starting points (vocal high-pass and presence, drum bus glue, plate, room and others, kept in [device_presets.lua](runtime/lua/daw/device_presets.lua)) and `daw.params.apply(device, name)` sets one. `daw.params.format(param, value)` shows a value in its unit (`2.5 kHz`, `-18.0 dB`, `4:1`, `1/8.`); frequencies, times and ratios move on a log scale from the keyboard and on sliders. One instance of each costs, on one core at 48 kHz (`bench/devices.lua`): reverb 1.0 %, saturation 0.7 % (2x; about twice that at 4x), limiter 0.5 %, chorus 0.3 %, meter 0.3 %, phaser 0.3 %, EQ with every band working 0.2 %, flanger 0.2 %, compressor 0.1 %, gate, delay, tremolo, utility and tuner under 0.1 %.

**Every device, built in or a plugin, has a wet/dry mix and an output gain**
from the host: two parameters after its own, `fx_wet` (Wet, 0 to 100 %)
and `fx_gain` (Output, -24 to +24 dB). The dry part is the device's input,
held back by the device's latency so that the two line up. They are set,
automated, learnt and kept in presets like any other parameter
(`daw.fx.set_wet(device, 50)`). The window's device card has both under the
preset; the terminal's device panel shows `wet 50%` on the device's line
when it is not 100 %, `h` `l` there change it, and both are the last rows of
the device. Bypassing a device or switching it on again, and any change of
the mix, fades over 5 ms instead of clicking; a bypassed device holds
nothing back.

New devices implement the `Device` trait in `daw-engine` and are added to the
registry in [devices/mod.rs](crates/daw-engine/src/devices/mod.rs).

## Mixing, MIDI and rendering in the core

**Threads.** Playback and renders use one thread per core (`daw.opt.threads =
4` or `:engine threads=4` for another number, 1 for the audio thread alone,
0 to leave it to the machine; `daw.render(path, { threads = 1 })` for one
render). `daw.api.engine_get().threads` says how many are in use. When the
audio thread runs with real-time priority the workers take the same
priority; if the system refuses them that, the engine stays on the audio
thread rather than make it wait for threads that anything may push aside.

**Fades.** An audio clip has `fade_in` and `fade_out`, in beats
(`clip.fade_in = 1`, `:clip.fade in=1 out=2`). `:clip.crossfade 1` runs a clip
on under the start of the next and fades the two across each other. An edge
that cuts into the middle of a recording gets three milliseconds of fade
whether asked for or not, so that splitting and cutting audio does not click.

**Tempo and time signature.** Both can change along the song. A tempo change
either holds until the next one or ramps to it, the tempo moving linearly in
time as REAPER's linear tempo points do; a time signature change starts a
new bar where it is, cutting short a bar it falls inside. `daw.project.tempo`
and the signature fields are the ones at the start, and a project with one
tempo and one signature saves as it always has. The engine follows the map
sample by sample: the playhead, the loop, MIDI clips, automation, the
metronome (the first beat of each bar accented, a click on each beat of the
signature, so six in a bar of 6/8), recording and renders. Plugins are told
the tempo, signature, bar and time at each block (CLAP transport, VST3
process context, LV2 `time:Position`, through the sandbox too).

```lua
daw.tempo.set(17, 96)                    -- 96 BPM from beat 17 on
daw.tempo.set(32, 120, { ramp = true })  -- ramp from 120 at beat 32 to the next change
daw.tempo.set_signature(9, 6, 8)         -- 6/8 from bar 9
daw.tempo.at(40)  daw.tempo.signature_at(40)  daw.tempo.points()  daw.tempo.remove(17)
daw.tempo.beats_to_seconds(16)  daw.tempo.seconds_to_beats(8)  daw.tempo.bar_of(33)
daw.time.format(33.5)                    -- "9.4.00": bar 9, fourth eighth
```

`:tempo 96` sets the tempo at the start, `:tempo 96 at 17` from bar 17 (or
`17.3`, bar and beat), `:tempo 96 here` from the cursor; `:tempo.ramp`
makes the change at or before the cursor ramp to the next (again to hold),
`:tempo.remove` removes it, `:tempo.list` lists the map, `:tempo.tap` (again
and again, in time) sets the tempo from taps; `:timesig 6/8` starts 6/8 at
the cursor's bar (`at 9` for bar 9), `:timesig.remove`. Each is one undo
step. Rulers number bars and draw bar and beat lines by the map; the
terminal's arrange ruler marks a tempo change `▾96` (`▾120>` for a ramp)
and a signature change `‖6/8`, and the window flags them on its ruler. The
status line and the window's transport show the tempo and signature at the
playhead.

Audio clips keep their length in seconds: changing the tempo neither
stretches nor cuts a recording, and its end beat follows from the map. What
an audio clip keeps of its start is its `timebase`: `"time"` (the default,
as REAPER's audio items) keeps its start at the same second, so the clip
moves in beats when the tempo before it changes; `"beats"` keeps it on its
beat (`clip.timebase = "beats"`). MIDI clips and automation stay on their
beats.

**Groups of tracks.** `daw.groups.make({ violins, violas, cellos }, "Strings")`
(`:track.group Strings` on the selected tracks, `,g`) makes a group: a track
the others belong to. The members play into it, so its fader, mute and
devices act on all of them; they stand under it, a step in and in its
colour; and `za` folds them away into it (`zM` folds every group, `zR` opens
them all). `:track.into Strings` moves a track in, `:track.ungroup` (`,G`)
takes one out or dissolves a group. Groups hold groups. A group is an
ordinary track marked in its `meta`, so it is saved, copied and undone like
any other, and `daw.groups.rows()` is the list of tracks that are drawn:
all but those folded away.

**Outputs and sends from the keyboard.** `:track.output Drum bus` (`,o` for
a list) plays the track into another, `:send Reverb -9` (`,s` for a list;
`pre=1` for ahead of the fader) sends its sound to one as well, and
`:send.remove Reverb` takes the send away.

**Sends before the fader.** `track:send(reverb, -6, { pre = true })` takes the
signal after the track's devices and before its fader and pan, so the send
keeps its level when the fader moves. Muting the track still silences it.

**Delay compensation.** A device that looks ahead says how late its output is
(CLAP, VST3 and LV2 plugins do; of the built-in devices the `limiter` does).
Every other path to the same place is held back by the difference, through
buses and sends, so that everything arrives together; a render leaves the
delay off the start of the file. `daw.api.engine_get().latency` is how far the
output is behind the transport, in milliseconds. A track's own clips are not
held back to match what is routed into it.

**MIDI, at the resolution of MIDI 2.0.** Besides notes, a MIDI clip holds
controller moves (`clip:controls()`, `clip:set_controls(...)`): control
changes, the pitch wheel, pressure, registered and assignable controllers,
program changes. Values are fractions, not seven-bit steps, and a move with a
`key` belongs to the note on that key alone: its own pitch bend, pressure or
controller, as MIDI 2.0 has them.

```lua
clip:set_controls({
  { start = 0, type = "cc", number = 64, value = 1 },         -- pedal down
  { start = 2, type = "bend", value = -0.5 },                 -- the wheel
  { start = 2, type = "bend", key = "E4", value = 1 / 48 },   -- one note, a semitone up
  { start = 4, type = "program", program = 12, bank = 258 },
})
track:midi({ type = "cc", number = 1, value = 0.3 })           -- now, to the track's devices
daw.on("midi.in", function(e) end)       -- everything that arrives at a port, for scripts; `e.port` names the port
daw.midi.ump({ type = "cc", number = 74, value = 1 })   -- as a MIDI 2.0 packet: two words
daw.midi.inject_ump({ 0x40903c00, 0xc0000000 })         -- and a packet, as if from a port
```

They are recorded with the notes, chased when playback starts in the middle,
kept through cutting, joining, copying and undo, and saved exactly. Where they
go: the built-in synth follows the wheel, the sustain pedal and a note's own
bend; CLAP plugins get a note's own controllers as note expressions and the
rest as MIDI 2.0 if they take it, else MIDI 1.0; VST3 plugins get note
expressions and poly pressure, and controllers through the parameters they
assign to them; LV2 plugins get MIDI 1.0, which has no per-note bend.

At the ports the program opens as a MIDI 2.0 client and reads Universal MIDI
Packets, so a MIDI 2.0 device arrives whole and a MIDI 1.0 device arrives as
the same events with less detail. That needs a kernel built with
`CONFIG_SND_SEQ_UMP`; without it the ports are MIDI 1.0, and what arrives is
widened by the specification's rules so that both read the same. There is no
MIDI output to hardware, no MIDI-CI, and no editor for controller moves yet.

**Recording offset.** What is played along to the song is heard late and
arrives late. Takes are moved earlier by what the audio system reports, plus
`daw.transport.record_offset` milliseconds for what it does not: record the
metronome through a loop-back cable, measure, and set it once in `init.lua`.

**Writing automation by moving things.** Each track has an automation mode
(`track.automation`, `:automation touch`, `,am` for the next in turn, the
`A` flag on its header in the window):

| Mode | While the song plays |
| --- | --- |
| `read` | the lanes play; moving a control writes nothing (the usual) |
| `touch` | a control writes while it is held or being moved, and when it is let go the lane takes over again, joined back to what it held |
| `latch` | a control writes from its first move until the song stops |
| `write` | everything the track's lanes move is written over from where the song starts playing, moved or not |
| `off` | the lanes are kept but do not play: the fader, the pan and the parameters are where they were set |

A control is a fader, a pan or a parameter, moved from the keyboard, a
frontend, a MIDI controller or a plugin's own window. What is written goes
into its lane at the playhead, over what the lane had there; a lane is made
if there is none. In the window a control is held for as long as the
pointer holds it (`daw.api.automation_hold`); anything else counts as held
for a little over half a second after its last move. `:lane.write` (`,aw`)
is a switch for the whole song: while it is on, every track that is not
writing in a way of its own latches. The terminal's track header shows `T`,
`L` or `W` in red while a track writes, and `-` when its automation is off.

**A control moved is one undo step.** A fader dragged in the window or a
knob turned on a controller sets its value many times a second; the moves
of one control that follow each other within a second are one step, so one
undo takes the whole sweep back. Commands and keys are a step each, as ever.

**Rendering.** `:render mix.flac` renders the song to a file, WAV or FLAC by
the file's extension (without a name, `<project>.wav` beside the project). It
runs on a thread of its own: the status line shows `rendering mix.flac 43% ·
Esc cancels`, `Esc` in normal mode or `:render.cancel` stops it, and a message
says when it is done. The render plays a snapshot of the project taken when it
starts, so editing meanwhile changes the project and not the file. The file
is written as `.mix.flac.part` beside the target and renamed when complete, so
a render that fails or is cancelled leaves nothing under the name. Formats
that need an encoder this program does not have (AAC, AIFF, WMA) are refused
by name before anything is rendered; `daw.api.render_formats()` lists what
can be written (`{ name, extensions, bits, lossy, available, why }`).

MP3 (`.mp3`), Ogg Vorbis (`.ogg`) and Opus (`.opus`) are made by `ffmpeg`,
when it is installed: no encoder for them is linked into the program. The
song is rendered to a hidden 32-bit float WAV beside the target (no dither;
at the sample rate asked for), and ffmpeg encodes that into a `.part` file
that is renamed when complete; the WAV is removed whether the encode succeeds,
fails or is cancelled. The encode runs on the render's thread too: the status
line says `encoding mix.mp3 61%` (and the window "Encoding") instead of
sitting at 100%, `Esc` or `:render.cancel` stops ffmpeg as well, and
`render.done`, `render.failed` or `render.cancelled` come once, for the final
file (`render.progress` and `render_status()` carry `stage`, `"rendering"` or
`"encoding"`). Opus holds only 48 kHz and the usual lower rates, so ffmpeg
resamples to 48 kHz; MP3 above 48 kHz is resampled to 48 kHz too. The project's
name is the file's title tag. `ffmpeg` is the program found on the PATH; set
`daw.opt.ffmpeg = "/path/to/ffmpeg"` to name another. Without it, or with an
ffmpeg built without the encoder, `:render mix.mp3` fails before anything is
rendered, saying so and naming the formats that need nothing (WAV and FLAC),
and `render_formats()` gives `available = false` and `why`; the window's
dialog then does not offer the format.

`quality=low|medium|high|best` (high by default) means the same in each
format; `bitrate=192` (kbit/s) takes its place when you want a number:

| quality | MP3 (LAME) | Ogg Vorbis | Opus |
|---|---|---|---|
| low | VBR `-q:a 6` (about 115 kbit/s) | `-q:a 3` | 64 kbit/s |
| medium | VBR `-q:a 4` (about 165) | `-q:a 5` | 96 kbit/s |
| high | VBR `-q:a 2` (about 190) | `-q:a 7` | 128 kbit/s |
| best | constant 320 kbit/s | `-q:a 9` | 192 kbit/s |

A bitrate is constant for MP3 and the target for Opus and Vorbis. `bits=` and
`dither=` do not apply to these formats. The command takes
(and `<Tab>` completes) `range=song|loop|selection`, or `start=` and `end=` in
beats; `tail=2` (seconds after the end, for reverbs; 1 by default);
`rate=44100`; `bits=16|24|32` (32 is float, WAV only; 24 by default);
`channels=mono|stereo` (mono mixes the sides at half level each);
`quality=high` or `bitrate=192` (MP3, Ogg and Opus); `dither=true`; `normalize=-1` (peak, dB); `loudness=-14` (integrated LUFS,
measured as BS.1770; with `normalize` too, the peak level is a ceiling);
`tracks=selected` or `tracks=3,5` for a stem of those tracks;
`master=false` to leave out the master's devices, fader and pan;
`stems=true` to write one file per track into a directory; `wait=true` to
render in the foreground. `:stems out format=flac master=false` renders stems
too. Normalizing renders the song once into a raw temporary file, measures it
and encodes from there.

`daw.render(path, opts)` takes the same as a table (`range`, `start`, `end`,
`tail`, `sample_rate` or `rate`, `bits`, `channels` (1, 2, "mono",
"stereo"), `quality`, `bitrate`, `ffmpeg`, `dither`, `normalize`, `loudness`, `tracks = { id, ... }`,
`master`, `threads`) and waits for the file, returning `{ path, frames,
seconds, sample_rate, peak, gain, loudness, format, bits, channels, ... }`;
with `background = true` it returns at once and the events follow:
`render.progress` (`{ path, fraction, seconds, stage }`, a few times a second),
then `render.done` (the table above), `render.failed` (`{ path, error }`) or
`render.cancelled`. `daw.render_status()` gives the running render (`{ path,
fraction, seconds, cancelling, stage, queued }`) and `daw.render_cancel()` stops it;
the window finds the same in `daw.frontend.state().modal.render`.
`daw.render_ranges.chorus = function() return 32, 48 end` adds a named range.
`daw.render_stems(dir, opts)` writes one file per track, which add up to the
mix. `:track.bounce` (`daw.bounce(track, { name = ... })`, which returns the
new track) renders a track with its devices to audio on a new track and mutes
the original. Stems and bounces go through `daw.render`, so `render.before` is
heard. Plugins are told when a render is offline and given a moment to
prepare before it starts: many load what a setting needs in the background,
and would otherwise still be silent when a fast render was over.

**Media files.** A saved project names the sound files inside its own folder
by a path relative to the project file, and files elsewhere by their full
path, so a project folder can be moved or copied whole. On opening, a file
that is not where the project says is looked for relative to the project
(the last steps of its old path), then by name in the project's folder tree
and in the directories where other missing files turned up. Files found
elsewhere make the project modified, so that saving keeps the new place.
What is still missing is reported in one message; its clips stay in the
project, silent, with `offline = true` in their state (`daw.clip(id).offline`,
and in `daw.frontend.state`), and both frontends write "offline" before their
names. Saving keeps the path a missing file was saved with. `:media.relink`
lists the missing files: choose one and then the file it is now (the rest
are then looked for beside it), or choose "Search a directory" and a
directory (`daw.pick.file({ directory = true })`); `:media.relink <dir>` and
`:media.relink <old> <new>` do the same from the command line, and
`:media.missing` lists them. `:media.collect` copies every file from outside
the project's folder into `media` beside it and points the clips at the
copies; the originals stay. `daw.opt.copy_imports = true` makes importing do
that from the start. In Lua: `daw.media.missing()`, `daw.media.list()`
(`{ path, missing, inside }`), `daw.media.relink(old, new)`,
`daw.media.search(dir)`, `daw.media.collect()`; each change is one undo step.
The `media.missing` event (`{ files, found }`) follows opening a project with
files missing or moved. Old projects with full paths open unchanged.

**Sample rates and waveforms.** A sound file at another rate than the
engine's (or than a render's) is converted once when it is loaded, with a
band-limited windowed-sinc resampler (`rubato`, 256 taps): nothing above the
new rate's Nyquist frequency folds back, and a tone keeps its level and
place. Changing the engine's rate converts again. Each file's waveform
overview is kept in `~/.cache/daw/peaks`, named after the file's path, size
and time of change, so that a long file drawn zoomed out after the first
time is drawn from the overview without being decoded.

**Long files are played from the disk.** A file whose decoded sound is
larger than `daw.opt.media_stream` megabytes (64: about three minutes of
stereo at 48 kHz) is not held in memory. It is decoded once, straight into
files in `~/.cache/daw/media` (and converted there, if its rate is not the
engine's), and those are mapped into memory: the engine reads them like any
other samples, the system brings the pages in from the disk and lets them go
again when memory is short, and the kernel asks for the next seconds ahead
of the playhead (and of the loop's start) so that the audio thread does not
wait for the disk. The decoded sound is kept between runs under the
identity of the file it came from, so an hour-long recording opens at once
the second time; the cache is kept within `daw.opt.media_cache` gigabytes
(16), the least recently used going first. `daw.media.list()` says of each
file whether it is `on_disk`. `daw.opt.media_stream = 0` holds every file in
memory, as before. Renders read the same files and are the same to the bit.

**Audio clip operations.** `:clip.reverse` plays the audio clip under the
cursor backwards, from a reversed copy of its part of the file in the
project's `media` folder (its fades change ends). `:clip.normalize -1` brings
its loudest sample to a level by setting its gain. `:clip.glue` joins it and
the audio clips touching or overlapping it on its track into one clip,
playing a new file of what they played together (gains, fades and overlaps,
without the track's devices). None changes the original file; each is one
undo step. In Lua: `daw.media.reverse(clip)`, `daw.media.normalize(clip,
level)`, `daw.media.glue(clip)` or `daw.media.glue({ a, b, c })`.

**Safety copies.** Every `daw.opt.autosave` seconds (60; 0 for none) a project
with unsaved changes is copied to `~/.local/state/daw/recovery`. The copy is
removed when the project is saved or closed with nothing unsaved. One left by a
session that ended badly is announced at the next start, and `:recover` opens
it under the name of the project it was a copy of. `:q` refuses to quit with
unsaved changes; `:q!` quits without them.

**A device that fails.** Each device's processing is guarded on the audio
thread. One that panics is marked failed and passed over from then on (an
instrument falls silent, an effect lets its input through): a
`device.stopped` event says so, as for a plugin whose helper crashed, the
device panel shows it as stopped, and `:device.restart` makes a new one.
Samples that come out of a device as NaN or infinity are replaced by silence
at its output, so they never reach a fader, a meter or the master; a
`device.invalid` event and a message say so once. A panic anywhere else in
the program writes a safety copy of unsaved work to the recovery directory
before the program ends, restores the terminal, and says where the copy is;
`:recover` offers it at the next start.

**What went wrong while playing.** `daw.api.engine_get()` (and
`daw.frontend.state()`, for the window and the status line) counts `xruns`,
`late_blocks` (blocks plugins did not deliver in time), `midi_dropped`
(MIDI events dropped because a queue was full), `record_dropped` (frames of
the take being recorded lost to a slow disk) and `devices_stopped`.
`:engine.status` prints them in one line. Decoded audio that neither the
project nor any undo step uses is let go when another project is opened and
every so often while editing, so a long session does not hold every file it
ever played.

**Saving.** A save writes a temporary file beside the project, flushes it to
the disk, renames it over the project and flushes the directory, so the file
on disk is always either the old project or the new one, whole. The file as
it was before the save is kept beside it as `song.json.bak`. A project that
will not open (cut short, or damaged) is not only an error: the message says
what can stand in for it, and `:recover` lists its newest safety copy and its
`.bak` first. Either opens under the damaged project's name, unsaved, so a
`:w` puts it back. Started with such a project on the command line, the
program starts anyway, with that message. A `.bak` names media relative to
the project, as the project does, so it opens with them.

**For scripts.** `daw.wait(ms)` lets time pass with timers firing and events
delivered, which `daw.api.sleep` does not; a script run with `-l` is otherwise
one long turn. `daw.api.project_shelve()` puts the open project aside whole
(undo tree, playhead, changed flag) and opens an empty one to work in;
`daw.api.project_unshelve()` closes that and brings the first back exactly as
it was, and `daw.api.project_shelved()` says whether one is aside. It is for
tools that need tracks of their own without touching the person's work (the
[doctor](extensions/doctor) does). `tests/*.lua` and `extensions/*/tests.lua`
are run by the suite, each given the suite's helpers.

## Takes

A clip can hold several versions of what it plays, of which one plays.
Recording round the loop makes them (see [Input and recording](#input-and-recording));
`:take.new` makes one by hand, keeping what the clip plays and carrying on
in a copy.

| Keys, command | |
| --- | --- |
| `]t` `[t`, `:take next`, `:take prev` | the clip's next take; the one before |
| `:take 2` | play the second |
| `:take.list` | choose from a list |
| `:take.new` | keep what the clip plays as a take and carry on in a copy of it |
| `:take.remove`, `:take.remove 1` | throw away the playing take, or the one numbered |
| `:take.keep` | throw away every take but the one that plays |
| `:take.explode` | every other take as a clip on a new track of its own |
| `zt`, `:take.lanes` | show the track's takes as lanes under its clips, or hide them |

**Comping**, choosing the best of each take: cut the clip where the choice
changes (`s`) and choose a take for each piece. Every piece keeps all the
takes, lined up, so a cut can be moved and a choice changed afterwards; a
start that is trimmed or slipped moves every take alike. With a stretch of
time selected, `:take 2` cuts at its ends and plays the second take there.
In the window the clip's menu has a Takes entry with all of this.

**Take lanes.** `zt` (or `:take.lanes`, the Takes entry of a clip's menu,
or the track's menu in the window) shows a track's takes as lanes under its
clips: lane k holds take k of every clip of the track that has takes, each
over the clip's own stretch of time, so the pieces of a comp line up into
lanes. What plays is lit, the rest dimmed; each piece shows its take's
waveform or notes and its name. After recording round the loop nothing
opens by itself, but `zt` shows every time round at once. In the window,
**swiping** comps: press on lane k and drag across a stretch of time, and on
release take k plays over exactly that stretch, the clips being cut at its
ends where needed, as one undo step; a click on lane k chooses take k for the
piece under the pointer. The ends land on the grid unless Shift is held, and
a drag shorter than a grid step is a click. Pieces side by side that then
play the same take are joined back into one where that is exact, so swiping
back and forth leaves no slivers: for sound, when every take is lined up
across the join (the same file and gain, the second piece starting in each
take where the first ends), the clips have the same name and mute and there
is no fade at the join; for notes, when the takes' names match and no note
is hidden past either piece's edge. A note cut in two by an earlier cut stays
two notes after the join, as it played. In the terminal the lanes are a line
each under the track, read-only: the playing take is lit and named, and
comping is `:take 2` over a selection. Which tracks show take lanes is kept
for the session, like automation lanes shown as rows, not in the project.

In scripts: `daw.takes.count(clip)`, `daw.takes.select(clip, n)`,
`daw.takes.step(clip, 1)`, `daw.takes.new(clip)`, `daw.takes.remove(clip, n)`,
`daw.takes.keep(clip)`, `daw.takes.explode(clip)`,
`daw.takes.comp(track, n, from, to)` (take n over beats `from` to `to`,
then the joining above), `daw.takes.choose_at(track, n, beat)`,
`daw.takes.join_pieces(track, from, to)`, `daw.takes.content(clip, n)`
(what take n plays: file, offset and gain, or notes), and
`daw.takes.show_lanes(track, on)`, `daw.takes.lane_count(track)`. The
window's gestures are `daw.frontend.act.take_lanes(track)`,
`act.comp(track, n, from, to, free)` and `act.take_click(track, n, beat)`;
`daw.frontend.take_preview(clip, n, points)` draws a take that is not
playing, from `daw.api.media_peaks(file, offset, seconds, points)`, the
waveform of any stretch of a file. They are kept in
`clip.meta.takes` (`runtime/lua/daw/takes.lua` says how); the files of takes
that are not playing count as the project's files, are moved into `media`
when it is first saved, and are found again when they go missing.

## Markers and regions

A marker is a named place in the song; a region is a named stretch. They
are on a second row of the ruler (a band of their own in the window), move
with the beats when the tempo changes, and are saved with the project.

| Keys, command | |
| --- | --- |
| `g'`, `:marker Chorus` | a marker at the cursor |
| `:region Verse` | a region over the selection, or over the loop |
| `]'` `['` | the next marker or region start; the one before (motions: `d]'`) |
| `g"`, `:marker.list` | all of them in a list; choosing one goes there |
| `:marker.goto 3`, `:marker.goto Chorus` | by number or by name |
| `:marker.rename Bridge`, `:marker.move`, `:marker.remove` | the one at the cursor |
| `:region.loop Verse` | loop a region |
| `:render out.wav range=Verse` | a region is a range to render |
| `:render.regions out` | every region to a file of its own, `01 Intro.wav` and so on |

In the window: right click on the timeline puts a marker there or makes a
region over the selection or the loop; a click on a marker goes to it, a
drag moves it, its menu renames or removes it and loops a region.
In scripts: `daw.markers.add(16, "Chorus")`, `daw.markers.add(0, "Intro", { length = 16 })`,
`daw.markers.list()`, `daw.markers.find("Chorus")`, `daw.markers.set(id, { beat = 24 })`,
`daw.markers.remove(id)`, `daw.markers.render_regions(dir, opts)`.

## MIDI controllers

A knob, fader or wheel of a MIDI controller can move a track's fader or
pan, or a parameter of a device.

| Command | |
| --- | --- |
| `:learn` | bind what was moved last (or the parameter under the device panel's cursor): then move the controller |
| `:learn volume`, `:learn pan`, `:learn cutoff` | the selected track's fader, pan, or a parameter by name |
| `:learn.list` | what is bound; choosing one takes it away |
| `:learn.remove 2`, `:learn.remove volume`, `:learn.clear` | take bindings away |

In the window, the plug beside a device's parameter learns it, and a
track's menu has the fader and the pan. The bindings belong to the project
and are saved with it. A move from the controller is a move like any
other: it writes automation when the track's mode says so, and a sweep is
one undo step. A control only takes hold of its target once it has reached
the target's value, instead of jumping it there (`daw.opt.learn_pickup =
false` for jumping). A binding is by controller number and channel; which
port a message came through is not told apart. In scripts:
`daw.learn.bind({ cc = 74, channel = 1 }, { track = t.id, target = "param", device = d.id, param = "cutoff" })`,
`daw.learn.bindings()`, `daw.learn.unbind(n)`, `daw.learn.start(target)`.

## What is missing

- Time stretching, clips that loop, and a tempo lane to draw the tempo as
  a curve (tempo changes are set by command, by script and on the window's
  ruler).
- Side-chain inputs and plugins with more than one stereo pair in or out.
- Pre-roll before a punch: the song plays from wherever the playhead is.
- Comping with the mouse in the terminal: its take lanes are to look at, and
  `:take 2` over a selection comps there.
- MIDI output to hardware, MIDI-CI, and an editor for controller moves.
- Groups that link faders without routing (VCA style); groups here are by routing into the group's track.
- Rendering to MP3, Ogg Vorbis or Opus without ffmpeg: there is no encoder
  for them in pure Rust of a quality worth shipping, and no C library is
  linked for them; they need ffmpeg installed (see Rendering). Nor does the
  file carry more than the title tag (no artist, album or cover).
- For instances on other machines: encryption of network connections
  (SSH does it today), hearing the instance's sound on the machine you sit
  at, sending it files from that machine, and a cursor and mode for each
  connection (every terminal and window of an instance shares one).
- Painted windows for the undo tree (a tree of nodes to click) and the mix
  report (meters and a spectrum as shapes): in the graphical frontend they
  are their terminal views in a window. What an extension draws on the
  terminal's arrange view shows in the window only as a band it adds too.
- Braille in windows of views drawn in cells: the bundled font has none, so
  curves there are drawn with line characters.
- Dropping files where the pointer is: the window cannot learn where a file
  from a file manager is dropped (winit 0.30 reports no position), and on
  Wayland it is told of no drops at all. The desktop's file dialogs are
  not shown for a kernel the window attached to with `--socket`.
- Devices written in Lua.
- The window's GPU renderer as the default: it is tried only on a software
  OpenGL (llvmpipe) so far, where it draws correctly but costs more than
  the software renderer.
- The window's position on the screen is not remembered, only its size: the window manager decides where it goes.
- A Nix package: for now the binary is built with `cargo` inside the dev shell.
