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
| `:delmarks a b c-e`, `:delmarks!` | remove marks, as in Vim (`:delm` for short; Tab completes the marks set); with the bang every lowercase mark | the same |
| `g'`, `g"`, `gx` | put a marker (a name on the ruler) at the cursor; choose one from a list; remove the one at the cursor, or right click its name under the ruler and choose Remove | |
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

**Insert mode** draws a note with the cursor. `i` in the arrange view opens
the clip under the cursor for it, or a new one; in the piano roll `i` starts at
the cursor, and `a` where the note under it ends (a grid step on, with no note
there). A note starts at the cursor's pitch, nothing long yet; `l` makes it a
grid step longer and `h` shorter, `j` and `k` move it a semitone, `J` and `K`
an octave (the arrows too), and a count goes first: `4l` is a beat at the
usual grid. The cursor stays at the note's end, so what shows is what will be
written: the note being drawn is in insert mode's green, the title says
`DRAW C4  2 steps · 0.5 beats  vel 100`, and so does the start of the key
line. Then, without leaving insert mode:

| Key | Keeps the note, and |
| --- | --- |
| `Enter` | draws the next where it ends, for a line played legato |
| `Space` | draws the next a step after it ends, a rest between (`3 Space` three steps) |
| `o` | draws another from the same start and as long, for a chord: then `k` up to its pitch |
| `Backspace` | takes back the note kept last, to draw it again |

`[` and `]` change the velocity. `Esc` writes what was drawn and returns to
normal mode; a note of no length is not written, and one drawn over a note
of the same pitch that starts there replaces it. The clip grows by whole
bars to hold what runs past its end. Nothing reaches the project until
insert mode ends, so the whole of it is one undo step, and `.` draws the same
shape again from the cursor, moved to its pitch, as Vim repeats an insert.
Where the roll edits several clips, the notes go into the active one (or the
one the note starts in, outside it), as notes added in normal mode do. With
a suggestion showing, its keys come first: `Esc` dismisses it and the next
leaves insert mode.

`I` enters notes the other way, the keyboard as a piano (`:set
roll_insert=keys` makes `i` and `a` do so too). The middle row of the
keyboard is the white keys from C and the row above it the black ones (`a w
s e d f t g y h u j k`); each key enters a note at once and steps on. A
capital stays in place, for chords. `1` to `9` set how many grid steps a
note is long, `Space` is a rest, `Backspace` steps back and removes, `z` and
`x` change octave, `[` and `]` the velocity. The clip grows by a bar when
the notes run past its end. `Esc` returns to normal mode. (`I` because Vim's
`gi`, insert where you last stopped, may be wanted for that, `R` records,
and Vim's `I`, insert at the start of the line, is `0i` here.)

**Suggestions.** With a completion source loaded (`extensions/continue`, a
language server), the piano roll can suggest what comes next: dashed ghost
notes in the track's colour, with a badge such as `1/3 continue: the bar
again` over them. They come by themselves after a pause in editing, never
while playing or recording, or with `Ctrl-Space`. `Tab` accepts all of it,
`Ctrl-l` its next note or chord, `Ctrl-n` `Ctrl-p` and `Alt-1` to `Alt-9`
show the other alternatives, `gh` plays it from a bar before, `Ctrl-e` or
`Esc` dismiss it; in insert mode the first `Esc` dismisses and the second
leaves insert mode. See [harmony.md](harmony.md).

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
| `Tab` `Ctrl-w w`, `Ctrl-w c`, `Ctrl-w o` | next window; close this window; close every other window (see Windows, buffers and tabs below) |
| `Ctrl-w +` `Ctrl-w -`, `Ctrl-w =` | taller or shorter window (in a panel whose height is an option, `mixer_height`, that option); windows of equal size. With the arrange view the only window: taller or shorter tracks, and track height back to automatic, fitting the tracks to the screen |
| `Ctrl-w <` `Ctrl-w >`, `Ctrl-w _` | narrower or wider window (the device panel's `devices_width`; with the arrange view alone, its track headers); give the window the whole tab, and again to put the others back |
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

**The curve editor.** Any curve can be edited in a window of its own: an
automation lane, a device parameter, a MIDI clip's controller (the pitch
wheel, pressure, any CC), one note's own expression, and the tempo map.
`gc` opens the curve of what the cursor is on: on a lane row (`Enter`
there too), on a parameter in the device panel, in the piano roll the
controller its strip shows (`gC` that of the note under the cursor alone).
The curve is a buffer named by its address, so `:vs daw://lane/3`, `:e
daw://tempo` or `:sp daw://clip/7/control/cc/74` show one, and `:setlocal
timebind` scrolls it with the arrange view. It draws the curve in braille
dots over the bars and beats, the values in their unit along the left, each
point as `◆` (`■` where the stretch after it holds, `●` where it eases),
and along the bottom the point under the cursor or the curve's value there.

The cursor is a beat and a value. `h` `l` move a grid step, `j` `k` a step
of the value (`J` `K` ten), `w` `b` go to the next and previous point and
take its value, `0` `$` the first and last. `o` adds a point at the
cursor, `A` one on the curve there, `x` removes the point under the cursor,
`+` `-` raise and lower it, `c` or `=` types its value. `s` gives the
stretch after it the next shape (straight, held, smooth) and `<` `>` bend a
smooth one. `i` draws: from there each move of the cursor (`h` `l` `j` `k`
`J` `K`) puts a point where it lands, and `Esc` writes them over what was
there as one undo step (`a` starts from the curve's value instead of the
cursor's). Operators take motions and selections: `d` and `y` cut and copy
points and `p` puts them at the cursor, `gs` smooths, `gS` thins out points
that add nothing, `gq` moves them onto the grid, and `gn` draws a wave over
the stretch (sine, triangle, saw, square, random or a ramp, from a menu).
While the wave is new, `Tab` goes from its shape to its rate to its depth,
`Ctrl-n` `Ctrl-p` change the one chosen, in the same undo step, and
`Ctrl-y` or `Esc` keep it; `:curve.generate sine rate=1 depth=0.5` makes one
by name. In a selection `x` deletes, `+` `-` raise and lower, `H` `L` move
the points a grid step, `s` shapes them. `zi` `zo` zoom, `[g` `]g` change
the window's grid. A lane has every shape; the tempo map ramps or holds; a
controller's moves hold, so a ramp or a wave drawn on one is written as a
move every sixteenth of a beat. With the mouse a click on a point chooses
it and a drag moves it (Shift off the grid), a press elsewhere adds a point
and a drag draws, the wheel scrolls (with Ctrl it zooms), and a right click
opens the point's menu (its shape, its value, removing it) or the curve's
(a wave, thinning, smoothing, quantizing). `:curve.window` (`gw`) shows the
curve in a window of its own in the graphical frontend.

In the device panel `A` automates the parameter under the cursor: it makes
its lane with a point at the value it has, at the arrange cursor's beat,
and shows the track's lanes with the cursor on the new one
(`:param.automate`). A right click on a parameter offers the same, and its
curve.

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
change in place (the event list), `Esc` goes back to the arrange view.
Over the ruler a row names the chords that sound, read over every pitched
track, with the key on the left (`daw.opt.chords`); `Ctrl-s` writes a
snippet such as the dominant of the next chord, and `Tab`, `Ctrl-n` step
through its choices (see [Harmony, completion and snippets](harmony.md)).

Behind the clip's notes the piano roll shows the notes of other tracks that
sound at the same time, so the harmony can be seen where it is written:
each a dashed line (`╌`) on a faint shade of its track's colour, without a
name, where the clip's own notes are solid and named. Drum tracks are left out. Which
tracks: `daw.opt.roll_context` (`"all"`, `"group"` for the tracks of the
clip's group, `"none"`, or a list of track ids), and `:roll.tracks` lists
them with their clips: `Enter` on a track shows or hides its notes. A dot on
the keyboard marks the keys that sound at the cursor, and the title names
the chord sounding there. The piano roll can edit several
clips at once (REAPER's editability follows selection). One is active: new
notes go there, its name is in the title, and the title says how many more
are edited. `ga` on another track's note makes its clip the active one (in
place of the old), `gE` edits that clip too or no longer, `gn` `gN` make the
next or previous clip edited active, `:roll.only` goes back to one clip, and
`Enter` on a clip in `:roll.tracks` adds it or takes it out (`Ctrl-a` there
makes it active). Opening several clips at once: select them in the arrange
view (`v` over them, or the pointer) and press `Enter`. Motions, operators,
visual mode, yank and paste, the keys on the note under the cursor and the
musicops operators then work on the notes of all of them; the cursor's
beats are the active clip's. A note moved stays in its own clip and stops at
its edges; notes yanked from several clips go back into them when pasted
while they are edited, else into the clip at the cursor; each command is one
undo step, however many clips it touched.

In the device panel
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
strip's volume and pan, and `dd` `yy` `p` for tracks. VCAs (see
[Mixing](mixing.md)) have strips after the tracks: `,vn` makes one over the
selected tracks, `,va` puts them under one, `,vr` takes them out, `,vx` takes
one away, and `,vl` links the faders of a group.

`,l` shows the session view, the clip launcher: a column of slots under
each track and a scene for each row, launched with `<CR>` and `L`; its keys
are in [Live performance](live.md).

## Windows, buffers and tabs

The screen is laid out as in Neovim. A **buffer** is something to show and
edit: the arrange view (`arrange`), the piano roll (`roll`), the mixer
(`mixer`), the device panel (`devices`), the session view (`session`), the
event list, help, an extension's view (`notation`, `drums`, `utau`, ...). A
**window** shows one buffer; a **tab** holds windows split side by side and
one above another. The status line and the bottom line stay along the
bottom of every tab. On start there is one tab and the screen is as it
always was: the arrange view, with the panels coming and going in their
places (`,m`, `,d`, `,p`, `Enter` on a clip).

`:vs roll` splits the window in two side by side and shows the piano roll in
the new half; `Ctrl-w h` and `Ctrl-w l` go between them, and each takes its
own keys. Opening a clip then shows it in that window. A built-in view is
one buffer, shown in one window at a time: showing it in another window
moves it there, with a message. A panel's window closed with `Ctrl-w c`
keeps its place, and the panel comes back there. New windows go right of
and below the one split (`:set splitright!` and `:set splitbelow!` put them
left and above).

| Keys or command | |
| --- | --- |
| `:sp roll`, `:vs roll` | split the window, one above the other or side by side, showing a buffer; an empty window without a name (`Ctrl-w s`, `Ctrl-w v`, `:vnew`, `Ctrl-w n`) |
| `:e roll`, `:b roll` `:b 3`, `:bn` `:bp` | show a buffer in this window, by name or number (a file that is not a buffer's name opens as `:open` does: `:e song.json`, `:e song.mid`, `:e take.wav`); the next and previous buffer |
| `:ls`, `:bd roll` | list the buffers; close every window of one |
| `:close` `Ctrl-w c`, `:q` `Ctrl-w q`, `:only` `Ctrl-w o` | close the window; close it, or in the last window quit (asking about unsaved changes as before); close every other window |
| `Ctrl-w h` `j` `k` `l`, `Ctrl-w w` `W`, `Ctrl-w p` | the window left, below, above, right (a count goes further); the next and previous window; the window that had the keyboard before |
| `Ctrl-w H` `J` `K` `L`, `Ctrl-w x`, `Ctrl-w r` `R` | move the window to the far left, bottom, top, right; exchange it with the next; rotate the windows of its row or column |
| `Ctrl-w +` `-` `<` `>`, `Ctrl-w =`, `Ctrl-w _` `\|` | resize (a count steps further); equal sizes; the whole tab and back |
| `:resize 20` `:resize +5`, `:vertical resize 40` | the window's height, its width |
| `:tabnew Mix`, `:tabnew mixer`, `gt` `gT`, `:tabn 2`, `Ctrl-w T` | a new tab named Mix, or showing the mixer; next and previous tab; tab 2; the window to a tab of its own |
| `:tabclose`, `:tabs` | close the tab; list the tabs and their windows |
| `:setlocal timebind` | bind this window's time to the other bound windows' |
| `:layout save edit`, `:layout edit` | keep the tabs and windows as they are; put them back |

With more than one tab a tab line along the top names them; a click on one
goes to it. A click in a window gives it the keyboard (see The mouse,
below). The rule between two windows side by side is a border to drag
with the mouse, and so is the top row of a window below another, where a
press the window does not hold itself drags the border.

**Bound in time.** `:setlocal timebind` in the arrange view and in the piano
roll beside it makes them show the same stretch of time at the same zoom:
the window with the keyboard leads, the other follows as it scrolls, and
while playing both follow the playhead. `:setlocal notimebind` lets go.

**Layouts.** `:layout save edit` writes the tabs and windows to the state
directory, and `:layout edit` puts them back. A configuration can name
layouts of its own, and start with one:

```lua
daw.layouts.edit = {
  { name = "Edit", layout = { dir = "h", "arrange", "roll" } },
  { name = "Mix", layout = "mixer" },
}
daw.opt.layout = "edit"
```

`dir = "h"` puts windows side by side, `dir = "v"` one above another, and a
window may have a `size` in cells or a `weight` (its share, 1 by default).
Every terminal attached with `daw attach` has tabs and windows of its own.

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
| Lanes as rows | click adds a point, hold and drag to draw, drag a point to move it, right click removes it; right click elsewhere to edit the curve, clear the lane, bypass it or hide the rows |
| Curve editor | click a point to choose it and drag to move it (Shift off the grid); press elsewhere to add a point, drag to draw; wheel scrolls, with Ctrl zooms; right click a point for its shape, value and removal, elsewhere for a wave, thinning, smoothing and quantizing |
| Take lanes | drag across lane k: take k plays there (see Comping with the mouse, above); click a piece to give it take k; click the label for the whole track; right click hides them |
| Piano roll | as REAPER's: press on empty grid where a note should start and drag as far as it should last (a click gives the roll's note length, which a drawn length becomes); click a note to choose it, Shift or Ctrl to add it or take it out; drag a note to move it and the chosen with it (Ctrl copies, Shift off the grid); drag its first or last cell to move where they start or stop; the right button dragged, or the left with Ctrl, chooses the notes in its box; right click removes a note (Ctrl and a right click offers the fixes the diagnostics have for it), on empty grid opens a menu (choose all, let go, delete, quantize, snap); double click removes a note; Alt and a drag erases every note crossed. With several clips edited, a note is chosen and moved in its own clip, a new one goes into the clip where it is drawn, and Ctrl and a click on another track's note shown behind edits its clip too (or no longer). The keyboard sounds a key under a click or a drag, and a right drag down it chooses the notes of those pitches. The strip under the notes takes the velocity drawn across it (only the chosen notes, if any are); a click on its name (`vel`) shows a controller there instead (the pitch wheel, modulation, expression, the pedal), drawn with the button held, a move's head (the top of its bar) clicked to choose it (Ctrl or Shift adds it) and dragged to move the chosen, Ctrl and a drag choosing those in a box, the right button dragged drawing a straight line and clicked opening its menu. A click on the ruler moves the playhead |
| Session view | click a slot to choose it; its play mark (`■`, `▶`) launches the clip, and letting go releases a gate or one-shot clip; double click opens a slot's notes, or makes a MIDI clip of a bar in an empty one; an empty slot's dot records a bar into it; drag a clip to another slot (Ctrl copies); right click opens the clip's menu; a scene's name launches its row; the bottom line stops a track, or every track under the scenes; the wheel scrolls the rows, with Shift the tracks |
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
(`SIGTERM`, `SIGHUP`). Under tmux the pointer reaches the program with
`set -g mouse on`; with it off tmux leaves the pointer to the terminal.
Another multiplexer passes it on when it passes the program's request for
it on to the terminal. Most terminals (WezTerm, kitty, foot,
xterm, Alacritty) keep a press with Shift held for their own selection of
text, so Shift and a drag still selects text on the screen; there Shift
does not reach the program, and `:set grid=…` or `:set note_snap!` is the
way off the grid. `:set mouse!` (`daw.opt.mouse = false`) stops the
reporting altogether, leaving the pointer to the terminal; the same again
takes it back.

## Pictures

A view that paints for the window (`paint`, see
[The graphical frontend](window.md)), such as the score of `:notation`,
shows the same pixels in a terminal that shows images. At start the
program asks the terminal what it is (XTVERSION), its colours (`OSC 10`
and `11`), the size of a cell in pixels, whether it draws images (the
kitty graphics protocol, sent through shared memory, a temporary file or
in the escape sequences themselves, whichever it takes), and whether it
reports the pointer in pixels (mode 1016). The log says what it found, in
a line that starts `terminal:`.

The picture is made in the program at the terminal's own cell size and
cut into pieces at its barlines, so that an edit sends again only the
bars it touched. The cells under it are left blank. A menu or a floating
view over part of it hides the pieces under it. What moves over the page
(the cursor, the note about to be entered, the playhead) is a picture of
its own above the page where the terminal is known to put images over
images well (kitty, Ghostty, and herdr, which answers as libghostty); in
any other terminal, WezTerm among them, it is drawn into the pieces it
crosses. Over a picture the pointer goes to the view in pixels where the
terminal reports them, else at the middle of the cell.

Where the terminal shows no images (tmux, which does not pass them on, a
terminal without the protocol, `daw attach` from one) the view draws in
cells as before. `:set graphics!` (`daw.opt.graphics = false`) keeps
cells everywhere; the same again takes the pictures back.

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
| `,ff` | `pick.files` | projects, audio and MIDI files under the working directory | opens the project, adds the audio at the cursor, or brings the MIDI file's tracks in there |
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
