# The terminal interface

## Keys

The keyboard works the way Neovim's does, on a timeline instead of a text. In
the arrange view a track is a line, a beat is a column and a clip is a word; in
the piano roll a pitch is a line and a note is a word. Everything below is an
ordinary mapping made in `runtime/lua/daw/defaults.lua` with the calls under
[Configure it](configuration.md), so any of it can be changed.

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
| `gw` `gW` | put a warp marker on the audio clip at the cursor; take off the one nearest it |
| `,cf`, `grC` | type the fade in and out of the audio clip under the cursor, in beats (`1 2`, or one length for both); choose the track's colour from the theme's hues (also in the mixer) |
| `H` `L`, `Alt-h` `Alt-l`, `Ctrl-a` `Ctrl-x` | move the clip; shorten and lengthen it; transpose it |
| `Enter`, `K` | edit the clip's notes in the piano roll; describe what is under the cursor |
| `a`, `ge`, `,d` `,m` `,p` | add a device; show the plugin's own window; show the device panel, the mixer, the piano roll |
| `A`, `,at` `,ax` | add a volume automation point at the cursor; turn the lane off or on (read or bypass), clear it |
| `,al`, `,aa` `,aA` | choose what to automate (volume, pan, any device parameter) and show its lane; show or hide the track's lanes as rows; show every track's lanes |
| `gs` `gp` `gL` `gm`, `Shift-Enter` | playhead to the start, to the cursor; loop on or off; metronome; play from the cursor |
| `gC` `gI`, `zt` `zT` | count a bar in before recording or not; punch recording on or off (on a selection, punch over it); show or hide the track's take lanes (see below for comping with the mouse), the tempo lane under the ruler |
| `:preroll 2`, `:tempo.move 9` | play two bars (`3s`: seconds) before the punch in when recording from a stop; move the tempo change at the cursor to bar 9 |
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

**The tempo lane.** `zT` (or `:tempo.lane`) puts two rows under the ruler that
draw the tempo map as a curve: level where a change holds, sloping where it
ramps (`◢`; `◆` marks a change that holds). The header says the tempo at the
cursor. The map is changed by commands, each one undo step: `:tempo 96 at 17`
(or `here`) adds a change, `:tempo.ramp` makes the change before the cursor
ramp to the next, `:tempo.move 9` moves it to bar 9, `:tempo.remove` takes it
away. The lane is also drawn on with the mouse, here as in the window (see
[The mouse](#the-mouse)).

**Comping with the mouse.** `zt` shows a track's takes as lanes under its
clips, one row for each take. Drag across lane k with the left button, and
the cells from where you pressed to where you let go are marked; on release
take k plays over that stretch, as in the window: the clips are cut at its
ends on the grid (Shift leaves it), the pieces that then play the same take
are joined, and it is one undo step. A click without a drag (a cell shorter
than a grid step) gives the piece under it take k. A click on the lane's
label (`↳ take 2`) makes that take play wherever the track has it. The
release may be anywhere on the screen: a drag belongs to the view it began
in. `:take 2` over a selection does the same from the keyboard.

In the piano roll, `Enter` adds or removes a note, `+` `-` change its length,
`H` `L` move it, `Ctrl-a` `Ctrl-x` transpose it, `[` `]` change its velocity,
`gh` sounds the pitch, `E` lists the clip's notes and controller moves to
change in place (the event list), `Esc` goes back to the arrange view. In the device panel
`j` `k` choose a row, `h` `l` change a parameter, `c` or `=` types its value
in its own unit (a choice by name; `+2` `-3` step), `yy` `dd` `p` copy and move
devices, between tracks too, `Alt-j` `Alt-k` reorder the chain, and `s` `<`
`>` `w` `W` choose, step through, save and set the default preset, `f` finds
a parameter and `t` goes to the last touched one, `K` chooses the track the
device listens to as its side-chain, `O` where its further output pairs
play. `V` and `j` `k` select
several devices for `y` `d`; `:device.copy_to <track>` and
`:device.move_to <track>` take the selected one elsewhere. In the window,
dragging a device card by its name onto a track's header moves it there
(with `Ctrl`, copies it), and dragging it up or down the list reorders. The
mixer has `h` `l` for tracks, `j` `k` for volume, `grv` `grp` to type the
strip's volume and pan, and `dd` `yy` `p` for tracks.

## The mouse

The mouse does in the terminal what it does in the window (see
[What the pointer does](window.md)), in cells. Each gesture goes to the
function in the kernel the window's goes to (`daw.frontend.act`), so the two
mean the same by it, and the keys are as they were. A press gives the view
under the pointer the keyboard. A gesture that changes the project does so
when the button is let go, as one undo step, and is drawn where it will
land until then (in the timeline and the piano roll); one that moves a
control (a fader, a pan, a parameter, the loop) moves it as the pointer
goes. A cell stands for the grid step it falls in: a click puts things on
the step drawn there, and a drag to a cell takes that cell in. Shift leaves
the grid where the terminal passes it on (see below). Two presses on one
cell within 400 ms are a double click. Moving the pointer over something
says on the status line what it is and what a click there does.

| Where | What the pointer does |
| --- | --- |
| Timeline | click puts the cursor there and lets go of the chosen clips; drag across empty lanes selects that stretch of time on the tracks crossed; a drag with the right button draws a box that chooses the clips it touches (Shift adds, Ctrl turns over); double click makes a clip of a bar; right click opens the timeline's menu (new clip, paste, marker, region, punch, count-in, the tempo lane, new track), or on a selected stretch the selection's (delete, copy, loop, mute); the middle button held pans |
| Clip | click chooses it, Ctrl and a click adds it or takes it out, Shift and a click takes in the clips between it and the last chosen; drag moves it and the chosen with it, across tracks too (Ctrl drops copies, Shift leaves the grid); its first and last cells are its edges: drag one to trim it (Alt slips what plays inside, Alt and Shift on the end stretches the sound); a warp marker (the line down an audio clip) drags along it, its right click removes it; double click opens the notes; right click opens the clip's menu (edit, rename, split at the pointer or the cursor, glue, repeat, mute, takes, stretch and loop, warp markers, delete) |
| Track header | click selects the track; double click renames it; drag up or down to put it in another place; `M` `S` `R` `I` switch, and a press on `M`, `S` or `R` swept down sets the tracks it crosses alike; the volume on the second line drags sideways a decibel a cell, the pan on the third five percent a cell (Shift finer), and a double click puts either back; a group's `▾` folds it; right click opens the track's menu (rename, colour, duplicate, groups, automation mode, lanes, MIDI learn, bounce, delete) |
| Ruler | click puts the cursor and the playhead there; drag loops the cells it crosses; double click turns the loop on or off; the loop's edges and the punch range's (`▕`) drag; a tempo or signature flag (`▾96`, `‖6/8`) drags to move it, double click types its value, right click offers to change or remove it |
| Markers | in their row under the ruler: click goes to one, drag moves it, double click renames it, right click to rename, loop the region or remove it |
| Tempo lane (`zT`) | click adds a change at that height; hold and drag to draw the tempo; drag a change to move it (an eighth of the lane's range a line up or down, Shift finer); double click makes it ramp to the next or hold; right click removes it, elsewhere hides the lane |
| Lanes as rows | click adds a point, hold and drag to draw, drag a point to move it, right click removes it; right click elsewhere to clear the lane, bypass it or hide the rows |
| Take lanes | drag across lane k: take k plays there (see Comping with the mouse, above); click a piece to give it take k; click the label for the whole track; right click hides them |
| Piano roll | as REAPER's: press on empty grid where a note should start and drag as far as it should last (a click gives the roll's note length, which a drawn length becomes); click a note to choose it, Shift or Ctrl to add it or take it out; drag a note to move it and the chosen with it (Ctrl copies, Shift off the grid); drag its first or last cell to move where they start or stop; the right button dragged, or the left with Ctrl, chooses the notes in its box; right click removes a note (Ctrl and a right click offers the fixes the diagnostics have for it), on empty grid opens a menu (choose all, let go, delete, quantize, snap); double click removes a note; Alt and a drag erases every note crossed. The keyboard sounds a key under a click or a drag, and a right drag down it chooses the notes of those pitches. The strip under the notes takes the velocity drawn across it (only the chosen notes, if any are); a click on its name (`vel`) shows a controller there instead (the pitch wheel, modulation, expression, the pedal), drawn with the button held, a move's head (the top of its bar) clicked to choose it (Ctrl or Shift adds it) and dragged to move the chosen, Ctrl and a drag choosing those in a box, the right button dragged drawing a straight line and clicked opening its menu. A click on the ruler moves the playhead |
| Mixer | drag a fader up or down (Shift finer), the level under it sideways, the pan to where the pointer is; double click puts them back; `M` `S` `R` `I` switch; a click on a device picks it in the device panel; a send's level drags sideways; the wheel nudges the fader, with Shift goes to the next or previous track; right click opens the track's menu |
| Devices | click or drag a parameter's slider to where the pointer is (Shift drags it finely), double click puts it back; `on` / `off` bypasses the device; the wheel scrolls, with Ctrl it nudges the parameter under the pointer |
| Menus, pickers, the command line's list | click an entry to choose it (in a picker and the command line's list, the first click selects and a second chooses); the wheel scrolls; a click outside a menu lets it go. Pages such as `:messages` scroll with the wheel |
| Wheel | in the arrange view scrolls the tracks; with Shift (or sideways) in time; with Ctrl over the timeline zooms in time where the pointer is; with Ctrl or Alt over the headers makes the tracks taller or shorter. In the piano roll scrolls the pitches; with Shift in time; with Ctrl zooms |

A menu opens at the pointer and takes the keys while it is open: `j` `k`
move, `l` or Enter opens a submenu or chooses, `h` goes back out, `Esc` lets
go. An extension's entries (`daw.frontend.menus`) are in it as in the
window's. A script opens one with `daw.ui.menu(items, { x = x, y = y })`
(see `runtime/lua/daw/menu.lua`).

**The terminal and multiplexers.** The program asks the terminal to report
every press, release and move of the pointer, held or not (modes 1000, 1002
and 1003), in the SGR form (1006), which has no limit on columns, and gives
the terminal back when it ends, when it fails and when it is killed
(`SIGTERM`, `SIGHUP`). Under tmux, `set -g mouse on` passes the pointer on
to the program; a multiplexer that has no mouse support of its own (or has
it turned off) passes it on unchanged. Most terminals (WezTerm, kitty, foot,
xterm, Alacritty) keep a press with Shift held for their own selection of
text, so Shift and a drag still selects text on the screen; there Shift
does not reach the program, and `:set grid=…` or `:set note_snap!` is the
way off the grid. `:set mouse!` (`daw.opt.mouse = false`) stops the
reporting altogether, leaving the pointer to the terminal; the same again
takes it back.

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
