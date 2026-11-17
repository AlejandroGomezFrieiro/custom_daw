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
| `j` `k` | next and previous track | a semitone down and up (`Ctrl-d` `Ctrl-u` an octave) |
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
| `g;` `g,`, `` `. ``, `'.`, `:changes` | back and forward through the places where the project was edited (`3g;` three edits back); the place of the last edit; list them | the same, each view keeping its own |
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
the bar, `ic` the notes that sound together at the cursor (`ac` with every
note that overlaps them), `ie` every note of the clip.

**Visual mode** selects first: `v` a stretch of time, stretched across tracks
with `j` and `k`; `V` whole tracks; in the piano roll `v` a stretch of time at
every pitch, `Ctrl-v` a rectangle, `V` whole pitches. Then an operator, or `x`
to delete, `~` to mute, `J` to join the clips, `Ctrl-a` and `Ctrl-x` (or `+` `-`) to
transpose (over whole tracks, `V`, they are the volume and `]` `[` the pan), `p` to replace it with the register. A selection takes in the note (or drum hit) under its far end, as Vim's takes in the character under the cursor. `o` goes to the other end, `gv`
selects the same again. `:` types a command for the selection: the line starts
with `'<,'>`, which names the last selection, as in Vim. A command may also take
bars in front: `:5,8notation.transpose 2`, `:5notation.dyn mf`; the Ex commands
(`:5,8d`, `:%s/c4/d4/g`, `:g/vel<20/d`) are in [Ex](#ex-ranges-s-and-g) below.

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
grid step longer and `h` shorter, `j` and `k` move it a semitone, `Ctrl-d` `Ctrl-u` (or `J` `K`)
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
normal mode, saying how many notes went in (`wrote 4 notes`), whether they
were drawn or typed; a note of no length is not written, and one drawn over a note
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
| `o` `O`, `grn`, `Alt-j` `Alt-k` | add a track below or above; rename it; move it down or up. `:track.new` chooses its kind from a list (a vocal track, a drum track: kinds extensions define), `:track.add vocal` names one; the header shows a kind's letter before the name, and `K` says what it is |
| `M` `s` `r`, `+` `-` (`Ctrl-a` `Ctrl-x` with a count), `]` `[` | mute, solo, arm; volume; pan |
| `grv` `grp`, `grt` | type the volume (dB) or pan (`L30`, `R25`, `C`, -100 to 100), the tempo: a number, `+2` or `-3` to step from the value now, `=-6` for a value below zero |
| `I` `Alt-i`, `R` | next audio input, monitor the input; record or stop recording |
| `&` `S` `J` `~`, `grc` | repeat, split, join, mute the clip; rename it |
| `gw` `gW` | put a warp marker on the audio clip at the cursor; take off the one nearest it |
| `,cf`, `grC` | type the fade in and out of the audio clip under the cursor, in beats (`1 2`, or one length for both); choose the track's colour from the theme's hues (also in the mixer) |
| `H` `L`, `Alt-h` `Alt-l`, `vic` `Ctrl-a` | move the clip; shorten and lengthen it; transpose it (on a selection `Ctrl-a` `Ctrl-x` are the clips' pitch) |
| `Enter`, `K` | edit the clip's notes in the piano roll; describe what is under the cursor |
| `a`, `ge`, `,d` `,m` `,p` | add a device (the list offers instruments first on a track with none, effects first otherwise); show the plugin's own window; show the device panel, the mixer, the piano roll |
| `A`, `,at` `,ax` | add a volume automation point at the cursor; turn the lane off or on (read or bypass), clear it |
| `,al`, `,aa` `,aA` | choose what to automate (volume, pan, any device parameter) and show its lane; show or hide the track's lanes as rows; show every track's lanes |
| `gs` `gp` `gL` `gm`, `Shift-Enter` | playhead to the start, to the cursor; loop on or off; metronome; play from the cursor |
| `gM` `gI`, `zt` `zT` | count a bar in before recording or not; punch recording on or off (on a selection, punch over it); show or hide the track's take lanes (see below for comping with the mouse), the tempo lane under the ruler |
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
and `k` step onto lane rows as onto tracks. With the lanes closed, the
track the cursor is on draws its volume curve in braille in the empty stretches
of its row, never over clips; the other tracks show an `A` in their header
and draw nothing, so that the notes stay readable. On a lane row `h` `l` and the
other motions move in time, `w` `b` go to the next and previous point, `A`
adds a point at the cursor at the curve's value there, `+` `-` raise and
lower the point under the cursor (a dB, 5% of pan, a hundredth of a
parameter's range; `Ctrl-a` `Ctrl-x` by the count), `c` or `=` types its
value, `x` removes it, `gc` (or `,at`) bypasses the lane and `,ax` clears it.
`>` `<` move points in time, with a motion or on a selection. In a selection
(`v`) on a lane row `x` or `d` remove the points in it, `H` `L` move them a
grid step, `+` `-` raise or lower them. Lanes for send levels are not there yet.

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
`gC` opens the curve of what the cursor is on: on a lane row (`Enter`
there too), on a parameter in the device panel (`Enter` too), on the
mixer's fader or pan, in the piano roll the controller its strip shows (`gX`
that of the note under the cursor alone).
The curve is a buffer named by its address, so `:vs daw://lane/3`, `:e
daw://tempo` or `:sp daw://clip/7/control/cc/74` show one, and `:setlocal
timebind` scrolls it with the arrange view. A window showing a lane that
the project no longer has (another project was opened) closes, or, when it
is the last, is left empty. It draws the curve in braille
dots over the bars and beats, the values in their unit along the left, each
point as `◆` (`■` where the stretch after it holds, `●` where it eases),
and along the bottom the point under the cursor or the curve's value there.

The cursor is a beat and a value. `h` `l` move a grid step, `j` `k` a step
of the value (`Ctrl-d` `Ctrl-u` ten), `w` `b` go to the next and previous point and
take its value, `0` `$` the first and last. `o` adds a point at the
cursor, `A` one on the curve there, `x` removes the point under the cursor,
`+` `-` raise and lower it (`Ctrl-a` `Ctrl-x` by the count), `c` or `=`
types its value. `~` gives the stretch after it the next shape (straight,
held, smooth) and `]` `[` bend a smooth one. `i` draws: from there each move
of the cursor (`h` `l` `j` `k` `J` `K`) puts a point where it lands, and `Esc` writes them over what was
there as one undo step (`a` starts from the curve's value instead of the
cursor's). Operators take motions and selections: `d` and `y` cut and copy
points and `p` puts them at the cursor, `>` `<` move them later and
earlier, `gs` smooths, `gS` thins out points
that add nothing, `gq` moves them onto the grid, and `g~` draws a wave over
the stretch (sine, triangle, saw, square, random or a ramp, from a menu).
While the wave is new, `Tab` goes from its shape to its rate to its depth,
`Ctrl-n` `Ctrl-p` change the one chosen, in the same undo step, and
`Ctrl-y` or `Esc` keep it; `:curve.generate sine rate=1 depth=0.5` makes one
by name. In a selection `x` deletes, `+` `-` raise and lower, `H` `L` move
the points a grid step, `~` shapes them. `zi` `zo` zoom, `[g` `]g` change
the window's grid. A lane has every shape; the tempo map ramps or holds; a
controller's moves hold, so a ramp or a wave drawn on one is written as a
move every sixteenth of a beat. With the mouse a click on a point chooses
it and a drag moves it (Shift off the grid), a press elsewhere adds a point
and a drag draws, the wheel scrolls (with Ctrl it zooms), and a right click
opens the point's menu (its shape, its value, removing it) or the curve's
(a wave, thinning, smoothing, quantizing). The graphical frontend shows the
curve in a pane, as here; `:curve.window` (`Ctrl-w f`) pops it out into a
window of its own.

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

<!-- tags: piano-roll -->
In the piano roll, `Enter` adds or removes a note, `+` `-` (and `Ctrl-a`
`Ctrl-x`, with a count) transpose it, `Alt-l` `Alt-h` change its length,
`H` `L` move it, `[` `]` change its velocity, `K` describes it,
`gh` sounds the pitch, `E` lists the clip's notes and controller moves to
change in place (the event list). `Esc` lets go of the notes chosen with the
pointer and stays; `Ctrl-w p` goes back to the arrange view. A note that
carries an articulation (its MIDI 2.0 attribute) shows a short tag of it
(`pz` for pizzicato) instead of its pitch, and `K` names it; keys that the
track's instrument names (a drum kit's drums, a sampler's keyswitches)
have their names on the keyboard, and `K` says them too.
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

<!-- tags: device-panel -->
The device panel is a grid of rows, a device's heading and then its
parameters. `j` `k` choose a row, `w` `b` go to the next device and back,
`e` to a device's last parameter, `gg` `G` the first and last row. `+` `-`
change the parameter a hundredth of its range (`10+`, `5 Ctrl-x`; on a
device's own row its wet mix), `c` or `=` types its value in its own unit (a
choice by name; `+2` `-3` step), `x` puts it back at its default, `Enter`
or `gC` opens its curve. On a device's row `c` chooses a preset, `x` removes
the device and `Enter` or `ge` shows its window; `[p` `]p` step through the
presets, `,w` saves one and `,W` makes it the default. The operators work on
rows: `dd` cuts a device (on a parameter, puts it back at its default), `yy`
yanks it, `p` `P` paste it after or before, between tracks too; over
parameters `y` yanks their settings and `p` puts them on the device under
the cursor, as `yj` then `p` on another synth copies two settings. `gcc`
bypasses the device, and `V` with any of these works on several devices or
parameters; `.` repeats. `Alt-j` `Alt-k` reorder the chain, `f` finds a
parameter and `t` goes to the last touched one, `gS` chooses the track the
device listens to as its side-chain, `O` where its further output pairs
play, `K` describes the device or parameter, `s` solos the track.
`:device.copy_to <track>` and
`:device.move_to <track>` take the selected one elsewhere. In the window,
dragging a device card by its name onto a track's header moves it there
(with `Ctrl`, copies it), and dragging it up or down the list reorders.

<!-- tags: mixer -->
The mixer is a grid too: `h` `l` go from strip to strip (`0` `$` the first
and last, `5|` the fifth) and `j` `k` along a strip's rows, top to bottom as
drawn: its devices (inserts), its sends, the fader, the pan, mute, solo, arm
and the input monitor (`gg` `G` the top and bottom, `w` `b` the next kind of
row). The row under the cursor is marked on the strip's left edge (a switch
is lit) and lit across the strip in a colour of its own, and named, with its value, on the right of the title bar. `+` `-`
change it: a dB on the fader or a send, a tenth of pan, a switch on or off,
an insert playing or bypassed; `6 Ctrl-x` is six dB down. `]` `[` pan the
strip from any row, `Enter` types the row's value (switches it, or shows an
insert's window), `x` clears it (0 dB, the middle, off; a send or insert
goes), `gC` opens the fader's or pan's curve, `K` describes. Operators work on
strips and rows: `dj` clears the fader and pan, `yj` then `p` on another
strip copies them, `gcc` mutes a strip (`gc2l` three), `dd` `yy` `p` cut,
yank and paste whole tracks. `V` over strips and `-` lowers every fader
selected, `.` again. `grv` `grp` type the strip's volume and pan. The scale left of the
first strip is the fader's, and true for every strip, whatever it holds above its fader (`+6` to `-48`, on the rows its cap takes: the
fader spends most of its travel on the top twenty decibels); the meters beside
the fader are linear from -60 to 0 and have the loudest of late in numbers
under them. VCAs (see
[Mixing](mixing.md)) have strips after the tracks: `,vn` makes one over the
selected tracks, `,va` puts them under one, `,vr` takes them out, `,vx` takes
one away, and `,vl` links the faders of a group.

<!-- tags: session-view -->
`,l` shows the session view, the clip launcher: a column of slots under
each track and a scene for each row, launched with `<CR>` and `L`; its keys
are in [Live performance](live.md).

## Keys: one grammar

<!-- tags: key-rule -->
Every view keeps to one rule, so that a key learnt in one view means the
same in the next, as in Vim, where `j` is a line down in any buffer.
`tests/keys_constitution.lua` walks the mappings of every view, those of the
bundled extensions too, and fails on one that breaks the rule
(`:lua =daw.keyrule.broken()` runs the same check on your own mappings).
Buffers that are text (`:e daw://tracks`) keep Vim's own keys for text:
there `Ctrl-a` adds to the number under the cursor and `-` goes up to the
buffer above, as in oil.nvim; their motions and operators keep the rule.

| Keys | In every view |
| --- | --- |
| `h` `j` `k` `l` `w` `b` `e` `0` `^` `$` `gg` `G`, with counts | Only motions, so they work after an operator and in visual mode too. `h` `l` go along the view's columns and `j` `k` along its rows: in the mixer `h` `l` go from strip to strip and `j` `k` along a strip's rows (its devices, sends, fader, pan, mute, solo, arm, input); in the device panel `j` `k` go over the devices and their parameters, `w` `b` from device to device, `e` to a device's last parameter. |
| `+` `-`, `Ctrl-a` `Ctrl-x` | The main value of what is under the cursor up and down (see the table below). A count first is how much: `6 Ctrl-x` is 6 dB down on a fader, six semitones down on a note. On a selection, the value of all of it. |
| `]` `[` | The second value up and down. |
| `>` `<` | The time operators: later and earlier (`>>`, `>ic`, `3>` on a selection). Never pan. |
| `K` | Describe what is under the cursor. (`gK` is what the diagnostics and language servers say about it.) |
| `ge` | The plugin window of what is under the cursor (an insert in the mixer, a device in the panel), else the track's. |
| `gc` | Mute: an operator over clips and tracks (`gcc` the track), over strips in the mixer; a lane's automation off or on; a device bypassed (`gcc` in the panel). |
| `gC`, `Enter` | Open the curve of what is under the cursor: a lane row, a parameter, the mixer's fader or pan, the piano roll's strip (`gX` the note's own expression). |
| `Alt-h` `Alt-l`, `H` `L` | Shorter and longer; earlier and later: a clip, a note, a chord in the score. |
| `Esc` | Cancel: a count, an operator, a selection, insert mode, a suggestion, the chosen notes, a running check. It never leaves or closes a view. A second one says how to: `Ctrl-w p` goes back to the window before, `:q`, `ZZ` or `Ctrl-w c` close, as does the view's own key (`,m` `,d` `,p`, `q` on a page). Pickers, menus and floating lists are prompts, and close on `Esc`. |
| `s` `M` `r` | Solo, mute, arm the track: in the arrange view, the mixer, the session view (the column's track) and the device panel (its track). |
| `a` | Append: a device after the track's chain (arrange view, mixer, device panel), notes after the note (piano roll, score), a drawing from the curve (curve editor). |
| `A` | Automate the main value: a point at the cursor on the track's volume, the parameter, the lane. |
| `c` | Change what is under the cursor: an operator over clips and notes; on a lane point or a parameter, type its value; on a device, choose a preset. |
| `~` | Switch something of what is under the cursor: a clip's mute, the shape of a curve's stretch, a note's vibrato. |
| `]x` `[x` | The next and previous of a list: `]d` diagnostics, `]t` takes, `]p` presets, `]c` curves (vocal editor), `]'` markers, `]g` `[g` the grid. |
| `Ctrl-d` `Ctrl-u` | A big step along `j` `k`: four tracks, an octave (piano roll, score, vocal editor), ten steps of a curve. |

The main and second values, view by view:

| View, under the cursor | Main: `+` `-` `Ctrl-a` `Ctrl-x` | Second: `]` `[` |
| --- | --- | --- |
| Arrange view, a track (and `V` over tracks) | volume, a dB | pan, a tenth |
| Arrange view, a selection of clips (`v`, `Ctrl-v`) | the pitch of their notes, a semitone | |
| Arrange view, a lane row | the point's value | |
| Mixer | the row: the fader or a send in dB, the pan in tenths, a switch on (`+`) or off (`-`), an insert playing or bypassed | the strip's pan |
| Device panel | the parameter, a hundredth of its range; on a device's own row its wet mix | |
| Piano roll | the note's pitch, a semitone | its velocity, by 10 |
| Score (notation) | the note's pitch: sharpen, flatten | |
| Drum grid | the hit's velocity, by 16 | the same: a hit has no pitch |
| Curve editor | the point's value | the bend of the smooth stretch from it |
| Vocal editor | the note's pitch | when its phoneme starts |
| Virtual inputs | the setting; on or off on an input's row | |

Where the views used to differ, the rule chose:

- `K` is Vim's key for looking up what is under the cursor. The device's
  side-chain went to `gS` in the panel, because `gK` already shows the
  diagnostics in every view.
- An octave is `Ctrl-d` `Ctrl-u` (half a page in Vim), since `J` `K` are not
  motions: `K` describes, and `J` joins clips. In insert mode `J` `K` still
  move the note being drawn an octave.
- A note's `+` `-` are its pitch, with `Ctrl-a` `Ctrl-x`, as they were
  already; its length went to `Alt-h` `Alt-l`, which shorten and lengthen a
  clip.
- Counting in went from `gC` to `gM`, beside the metronome's `gm`, so that
  `gC` opens curves everywhere. `gc` no longer opens one.
- `gn` stays the piano roll's next edited clip, as Vim's `gn` goes to the
  next match. The curve editor's wave is `g~` (an operator; `~` looks like a
  wave), its shapes `~`, its own window `Ctrl-w f`. `gw` is only the warp
  marker.
- `b` is only a motion: the panel's bypass is `gc`, as `gc` comments a line
  out in Vim; the session's "back to the timeline" is `B` (`gB` every track).
- `e` is only a motion: a plugin's window is `ge` in every view; the session
  opens a slot's notes with `i`, as `i` enters notes in a clip.
- `s` is solo wherever there is a track. The session stops a track's clip
  with `S` (`gS` every clip); the curve editor's shapes are `~`; the panel's
  presets are `c` on a device (choose), `]p` `[p` (step), `,w` (save, as
  `:w` writes) and `,W` (the default).
- The score's system breaks are `zs` (a system starts here) and `zj` (join
  the bar to the system before), beside `zg` and `zp`, which also say how
  the page is laid out; `gS` keeps its meaning of the session and the panel.
- `a` appends: it was already a device on a track and notes after a note,
  and is the same in the mixer and the panel.
- `A` was already "a point of automation at the cursor" in every view that
  had it.
- `Esc` stays, so that the keys typed after it land where they were going;
  the piano roll, drum grid, virtual inputs, vocal editor and doctor used to
  leave or close on it, and the mix report, undo tree and sections lists
  when in a window of their own.

### The old keys

`daw.opt.keys = "classic"` in `init.lua` (or `:set keys=classic`) brings back
the keys as they were before the rule, for a while; `:set keys=default`
takes them away again. What changed:

| View | Before | Now |
| --- | --- | --- |
| Arrange | `(` `)` pan | `[` `]` |
| Arrange | `Ctrl-a` `Ctrl-x` transpose the clip | volume; `vic` then `Ctrl-a` transposes |
| Everywhere | `gC` count a bar in | `gM` |
| Lane row | `gc` the curve | `gC` or `Enter`; `gc` switches the lane off or on |
| Mixer | `j` `k` the fader | `+` `-`; `j` `k` move along the strip |
| Mixer | `<` `>` pan | `[` `]` |
| Mixer | `gg` `G` first and last track | first and last row; `0` `$` first and last strip |
| Device panel | `h` `l`, `H` `L` the parameter | `+` `-`, with a count |
| Device panel | `b` bypass | `gc` |
| Device panel | `e`, `Enter` the plugin window | `ge`; `Enter` on a parameter opens its curve |
| Device panel | `s`, `<` `>`, `w`, `W` presets | `c` on a device, `[p` `]p`, `,w`, `,W`; `s` solos |
| Device panel | `K` side-chain | `gS` |
| Device panel | `gc` the curve | `gC`, `Enter` |
| Piano roll | `J` `K` an octave | `Ctrl-d` `Ctrl-u` |
| Piano roll | `+` `-` length | `Alt-l` `Alt-h`; `+` `-` the pitch |
| Piano roll | `gc` the strip's curve, `gC` the note's | `gC`, `gX` |
| Piano roll, drum grid, virtual inputs, vocal editor | `Esc` back to the arrange view | `Ctrl-w p`; `Esc` stays |
| Doctor | `Esc` closes the page when nothing runs | `q`; `Esc` stops a run |
| Curve editor | `J` `K` ten steps | `Ctrl-d` `Ctrl-u` |
| Curve editor | `s` shape, `<` `>` bend | `~`, `[` `]`; `<` `>` move points in time |
| Curve editor | `gn` a wave, `gw` its own window | `g~`, `Ctrl-w f` |
| Session | `s` `S` stop, `b` `B` back, `e` notes | `S` `gS`, `B` `gB`, `i`; `s` solos |
| Virtual inputs | `h` `l`, `H` `L` the setting | `+` `-`, with a count |
| Score | `+` `-` length, `Alt-h` `Alt-l` move the chord, `J` `K` octave, `ge` respell | `Alt-l` `Alt-h`, `H` `L`, `Ctrl-d` `Ctrl-u`, `g~`; `+` `-` sharpen and flatten |
| Vocal editor | `+` `-` length, `J` `K` octave, `Ctrl-a` select all, `Ctrl-x` cut, `gc` `gC` curves, `gA` phrase | `Alt-l` `Alt-h`, `Ctrl-d` `Ctrl-u`, `gA`, `d`, `]c` `[c`, `vap`; `+` `-` `Ctrl-a` `Ctrl-x` the pitch |
| Lyric sheet | `K` kana, `Esc` closes | `~`, `q` |

## Ex: ranges, `:s` and `:g`

The command line takes Vim's Ex commands, over time and tracks where Vim's
are over lines. A line is a range, then a command: `:5,8d` empties bars 5
to 8. Each line is one undo step, named after the line (`u` undoes
`:%s/c4/d4/g` at once), and goes into the history (`:` then `Up`).

**Ranges of time.** A bar is a number, a beat is `bar.beat` (`5.3`, the
signature's beats, from 1); both take in the whole of the last one, so
`:5,8` ends where bar 9 begins and `:5.3,5.4` is two beats.

| Range | |
| --- | --- |
| `5` `5,8` `5.3,6.1` | a bar, bars 5 to 8, from beat 3 of bar 5 to the end of beat 1 of bar 6 |
| `%` | the whole song, to the end of the bar its last clip ends in |
| `.` `$` | the bar the cursor is in; the last bar |
| `.+4` `$-1` `5.3+2` | four bars on, the bar before the last, two beats on (after a beat, offsets count beats) |
| `'a,'b` | from mark `a` up to mark `b`, exactly; `'a` alone is the bar it is in |
| `'<,'>` | the last selection of the focused view: its time, and in the arrange view its tracks, in the piano roll its pitches (a `Ctrl-v` or `V` selection), or the clips chosen with the pointer |

**Ranges of tracks** come first: `t2`, `t2,t4` (or `t2,4`), `t.` the
cursor's track, `t$` the last, `t*` every track, `t/Drums/` every track
whose name holds `Drums`, `t'<,'>` the tracks of the selection.

A time range alone covers every track, or, in the piano roll and the score,
the notes of the clips it edits; a track range alone covers whole tracks;
both together cover that time on those tracks: `:t2 5,8d` empties bars 5 to
8 of track 2. A range with no command goes there: `:$`, `:t3`, `:'a`. As
before, a number right before a command that takes no range is its count
(`:3snippet arp`), and a command an extension makes with a range gets one.

**Commands.** Without a range most take the cursor's bar (`.`), as Vim's
take the cursor's line; `:g` and `:v` take the whole song, the track
commands the cursor's track.

| Command | |
| --- | --- |
| `:5,8d`, `:5,8d!`, `:t2d` | empty bars 5 to 8 of every track, cutting clips at the edges; `d!` takes the time out and closes the gap; a track range alone deletes the tracks. What was there goes to the register (`:5,8d a` to register `a`), for `p`. In the piano roll: the notes |
| `:5,8y`, `:5,8y a` | yank them |
| `:5,8co 17`, `:5,8co! 17` | copy bars 5 to 8 to bar 17, over what is there; `co!` makes room. `:t2 co 4` copies track 2 below track 4 (`0` for the top) |
| `:5,8m 17`, `:5,8m! 17` | move them; `m!` closes the gap they leave and makes room where they go |
| `:5,8>`, `:5,8>>`, `:5,8< 3` | move the clips that start there a grid step later, two, three earlier; in the piano roll the notes, by its grid |
| `:5,8j` | join the MIDI clips on each track into one |
| `:5,8transpose 12`, `:%quantize`, `:%quantize 1/16` | move notes by semitones; snap them to the piano roll's grid, or to a note value or a number of beats |
| `:t2,t4 mute`, `:t* unmute`, `:t/Drums/ solo`, `:t* unsolo`, `mute!` `solo!` | mute and solo tracks; `!` switches each. `:5,8 mute` mutes the clips in bars 5 to 8 |
| `:t* volume -3`, `:t2 volume =-6`, `:t2 pan =-0.5` | step the volume of tracks down 3 dB, set it to -6 dB; pan from -1 (left) to 1 |
| `:5,8normal x`, `:t* normal gcc` | type keys at the start of each bar of the range (on each of its tracks), or with a track range at each track |
| `:%s/pattern/replacement/flags` | change what matches (below) |
| `:&`, `:&&` | the last `:s` again on a range, without and with its flags |
| `:g/pattern/command`, `:g!` or `:v` | run a command on every match, or every thing that does not match: `:g/vel<20/d`, `:g/name:Verse/mute`, `:g/c4/normal x`. With no command, `:g/vel<20/` puts the matches in the quickfix list, for `]q` and `:cdo` |

**Patterns** match notes, clips or tracks by what they are. Terms side by
side must all hold; `|` in a term is either; `!` before one is not.

| Term | Matches |
| --- | --- |
| `c4` `c#4` `bb3` `60` | notes on that key |
| `c` `f#` | notes on that key in any octave |
| `vel>100` `vel<=20` `vel=64` | by velocity |
| `len<1/8` `len>=2` | by length, as a note value or in beats |
| `beat=1` `beat>=3` | by where in its bar a note starts: 1 the downbeat, 2.5 the and of 2 |
| `name:Verse` `name=Verse` | clips whose name holds `Verse`, or is it (case does not count; a pattern has no spaces in a term) |
| `track:Bass` | things on tracks whose name holds `Bass`, or the tracks |
| `*` | everything: notes in the piano roll, clips in the arrange view |

The deepest field named says what is matched: `c4` matches notes,
`name:Verse` clips, `name:Verse c4` the C4s of clips named Verse, and
`track:Bass` alone tracks. Other characters than `/` can mark the pattern
off, as in Vim: `:%s#len<1/8#len=1/8#g`. An empty pattern is the last one.

**Replacements** set fields of what matched: `d4` (a key without an octave,
`d`, keeps the note's octave), `+12` or `-3` (semitones), `vel=90`,
`vel+10`, `len*2`, `len=1/16`, `name:Chorus` (the part of the name the
pattern found: `Verse 2` becomes `Chorus 2`), `name=Chorus` (the whole
name), several at once (`vel=90 len=1/8`). An empty replacement removes
what matched: `:%s/vel<10//g`.

**Flags.** As in Vim, without `g` only the first match in each bar changes,
a bar being Ex's line; `g` changes every match (`:set gdefault` turns this
round). `c` asks about each match in turn, lit in the view that shows it:
`y` yes, `n` no, `a` this and all the rest, `l` this and stop, `q` or `Esc`
stop. What was said yes to is made when the asking ends, as one undo step.
`n` only counts the matches.

**While you type**, the line shows what it would do, as Neovim's
`inccommand`: the range is shaded on the rulers and its tracks marked in
the headers, the matches are lit (clips in the arrange view, with how many
of their notes match), what a replacement would make of each note is drawn
as a ghost in the piano roll, and the right end of the command line counts
them ("12 notes match", "12 notes match, 4 change (g: all)") or says what is
wrong with the line. Nothing changes until `Enter`; `Esc` leaves everything
as it was. `Tab` completes command names after a range, marks after `'`,
track names after `t/`, and field names in a pattern.

## Windows, buffers and tabs

The screen is laid out as in Neovim. A **buffer** is something to show and
edit: the arrange view (`arrange`), the piano roll (`roll`), the mixer
(`mixer`), the device panel (`devices`), the session view (`session`), the
event list, help, an extension's view (`notation`, `drums`, `utau`, ...). A
**window** shows one buffer; a **tab** holds windows split side by side and
one above another. The status line and the bottom line stay along the
bottom of every tab. In insert mode a message goes at the right end of the
bottom line and the keys keep the rest. When three or more panels stack, the
arrange view keeps a third of the rows (as `Ctrl-w =` gives it) and the
notation view takes at most half; in a column the arrange view keeps two fifths
of the rows whatever else is stacked with it, the panels with a size of their
own giving way last. `:help` splits off half the screen, as Vim gives its help
half. `:view.focus` of a view that is not shown
puts it in the current window, so that focus is never on what is not drawn. On start there is one tab and the screen is as it
always was: the arrange view, with the panels coming and going in their
places (`,m`, `,d`, `,p`, `Enter` on a clip). `,p` with no clip open opens the piano roll on the clip under the cursor; with none there it says so and leaves the screen alone. `,m` in a window that is the mixer alone (after `Ctrl-w o`) brings the arrange view back in its place.

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
| `:sp roll`, `:vs roll` | split the window, one above the other or side by side, showing a buffer; without a name, the same buffer as in Vim: a list edited as text shows in both windows, the arrange view's new window shows the piano roll and the roll's the arrange view, and any other view (one window at a time) leaves an empty window that says so (`Ctrl-w s`, `Ctrl-w v`); `:vnew` and `Ctrl-w n` always open an empty one |
| `:e roll`, `:b roll` `:b 3`, `:bn` `:bp` | show a buffer in this window, by name or number (a buffer's or a view's name, or an address such as `daw://tracks`, is looked for before a file, and only a file is asked about unsaved work: `:e song.json`, `:e song.mid`, `:e take.wav`); the next and previous buffer |
| `:ls`, `:bd roll` | list the buffers; close every window of one |
| `:close` `Ctrl-w c`, `:q` `Ctrl-w q`, `:only` `Ctrl-w o` | close the window; close it, or in the last window quit (asking about unsaved changes as before); close every other window |
| `Ctrl-w h` `j` `k` `l`, `Ctrl-w w` `W`, `Ctrl-w p` | the window left, below, above, right (a count goes further); the next and previous window; the window that had the keyboard before |
| `Ctrl-w H` `J` `K` `L`, `Ctrl-w x`, `Ctrl-w r` `R` | move the window to the far left, bottom, top, right; exchange it with the next; rotate the windows of its row or column |
| `Ctrl-w +` `-` `<` `>`, `Ctrl-w =`, `Ctrl-w _` `\|` | resize (a count steps further); equal sizes; the whole tab and back |
| `:resize 20` `:resize +5`, `:vertical resize 40` | the window's height, its width |
| `:tabnew Mix`, `:tabnew mixer`, `gt` `gT`, `:tabn 2`, `Ctrl-w T` | a new tab named Mix, or showing the mixer; next and previous tab; tab 2; the window to a tab of its own |
| `:tabclose`, `:tabs` | close the tab; list the tabs and their windows |
| `:view.open undotree` | show a view where it docks, else in a window split from this one (the graphical frontend's More) |
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

## Lists edited as text

Some of the project can be edited as plain text, as oil.nvim edits a
directory: a buffer lists it one thing a line, you edit the lines with
Vim's keys, and `:w` makes the project what the lines say.

| Buffer | A line | |
| --- | --- | --- |
| `daw://tracks` | `Bass  vol -6.0  pan L10  M--  out Bus A  group  in Strings  color #ff9e64  ▸ Synth, EQ` | a track: its name, volume in dB, pan, flags (`M` muted, `S` soloed, `R` armed, `-` not), the track it plays into (the master without `out`), `group` on a group, the group it is in, its colour, its devices |
| `daw://sends` | `Drums  → Verb  -12.0 dB  post` | a send: the track it is from, the track it goes to, its level, `pre` or `post` the fader |
| `daw://track/2/devices` | `Comp  on  wet 80%  preset Glue` | the device chain of the second track (`master` for the master's): the device, `on` or `off` (bypassed), its wet share, the preset it was set to |
| `daw://markers` | `9.1  Chorus  to 13.1  color #9ece6a` | a marker at bar 9, beat 1; with `to`, a region that ends at bar 13 |

`:e daw://tracks` shows one in this window, `:vs daw://sends` beside it,
`:textbuf.open markers` below. Fields are two spaces apart and every field
but the first starts with its word, so they can come in any order and a
missing one has its plain value (0 dB, centre, not muted, the master, no
group, no colour). A name with two spaces in it is written in quotes.

Every key of the text works as in Vim: `h` `j` `k` `l`, `w` `b` `e` and
`W` `B` `E`, `0` `^` `$`, `f` `t` `F` `T` `;` `,`, `gg` `G`; the operators
`d` `c` `y` `gu` `gU` `g~` with every motion, counts and registers; `x` `X`
`s` `S` `C` `D` `Y` `r` `~` `J` `p` `P`; insert mode with `i` `a` `I` `A`
`o` `O` (`Tab` types the two spaces between fields); `v`, `V` and `Ctrl-v`
selections, with `I` and `A` typing on every line of a block; `u` and
`Ctrl-r` undo and redo the text, and `.` repeats the last change. `iw` `aw`
name a word, `if` the value of the field under the cursor (`cif` changes it)
and `af` the whole field. `Ctrl-a` and `Ctrl-x` add and take 1 (or the
count) from the number under or after the cursor, decimals kept: on a
volume it is a dB, on a marker's position a bar; on a selection, from each
line's number. `:s/vol -6/vol -9/g`, `:sort` (`!` the other way, `n` by
number, `i` ignoring case), `:d`, `:y`, `:m 0` and `:normal` take ranges of
lines: `:%s`, `:2,4d`, `:.,$sort`, and `:'<,'>` after `:` in a selection.
`:5` goes to line 5.

What an edit means:

| Edit | What `:w` does |
| --- | --- |
| a field changed (`cw` on a name, `Ctrl-a` on a volume, `rM` on the flags) | that field of that thing, and only it |
| `dd` | deletes the track, send, device or marker |
| `yyp`, `yyP` | copies it: a track with its devices, clips and automation, a device with its state |
| `ddp`, `:m`, `:sort` | moves it (tracks and devices are put in the order of the lines) |
| a line typed new (`o`) | makes one: `Lead  vol -12  ▸ synth` a track with a synth, `reverb` a device, `17.1  Bridge` a marker |

Each line carries, out of sight, the id of what it stands for, so that a
line renamed is a rename and a line moved is a move, not a deletion and a
new one. The gutter shows it: the line's place when it was read, `~` on a
line changed, `+` on a new line or a copy, `!` on a line that does not
read, whose reason the bottom line shows. The title says `[+]` while the
buffer has changes.

`:w` shows the plan in a float, as oil.nvim does: `rename Bass → Bassline`,
`Bassline: volume -6.0 → -3.0 dB`, `delete Pad (2 devices, 4 clips)`. `y`
or `Enter` applies it as one undo step, so one `u` in any other window takes
it all back; `n` or `Esc` goes back to the buffer. A line that does not read
stops the write and the cursor goes to it. `:w` on a buffer without changes
saves the project, as anywhere else. `:e!` throws the changes away and reads
the buffer again; `:q` will not close a window on a buffer with changes
(`:q!` will).

A buffer without changes follows the project: rename a track in the arrange
view and its line changes. A buffer with changes is marked `changed
elsewhere` once the project changes under it, and `:w` then refuses; `:w!`
applies your changes anyway, and only the fields your lines changed, so a
volume moved elsewhere in the meantime stays moved.

`Enter` on a track's line opens its devices (`daw://track/N/devices`), and
`-` there goes back up to the tracks; on a device `Enter` shows it in the
device panel, on a marker it puts the cursor there. The graphical frontend
shows a text buffer in a pane, as here; `:textbuf.window` (`Ctrl-w f`) pops it out
into a window of its own, where it is edited with the same keys.

## The quickfix list

As in Neovim, the quickfix list is one shared place for what is wrong, or
found, anywhere in the project. Each entry names where it is (a clip, a
note, a track, a lane's point, a device or its parameter, a bar), says
what it is about, and may carry a fix. The status line counts its entries
while it has some: `qf E2 W5`, and `qf 3/7 E2 W5` once you have gone to
one.

The program keeps one list, **Problems**, filled as things go wrong: the
diagnostics (those worse than a hint; `:set qf_diagnostics=error` keeps
only errors, `off` none), what language servers and the mix diagnostics
say among them; renders that go over full scale, are louder than
`render_loudest` (-9 LUFS) or fail; sound files that are not there;
plugins that stopped, put out invalid numbers or are not installed; and
plugin files a scan could not use. Each keeps its own place too: the
marks, `]d`, `:diagnostics`, the mix report and the messages stay as they
were. Extensions add to it (see [Scripting](scripting.md)).

| Keys or command | |
| --- | --- |
| `]q` `[q`, `]Q` `[Q` | the next and previous entry (a count goes further; the first `]q` goes to the first), the last and first; the view that shows it gets the keyboard and the cursor goes there |
| `:cnext` `:cprev` `:cfirst` `:clast`, `:cc 3` | the same; entry 3 (`:cc` alone the current one) |
| `:copen` `:copen 15`, `:cclose`, `:cwindow` | a window showing the list along the bottom, the whole width (`qf_height` rows); close it; open it when it has entries and close it when not |
| `j` `k` `gg` `G`, `Enter`, `,ca`, `q` | in the list's window: move, go to the entry, make its fix, close the window |
| `:colder` `:cnewer`, `:chistory` | the list before and after in the history (ten are kept), and all of them |
| `:cdiag`, `:cdiag error` | a list of the diagnostics (as `vim.diagnostic.setqflist`), or of the errors |
| `:cdo track.mute`, `:cfdo track.solo` | run a command on every entry, the cursor on each and its address the command's target; or once for each track the entries are on; all as one undo step |
| `:cfix`, `:cfix .` | make the fixes of every entry that has one, as one undo step; the current entry's |
| `:lopen` `:lnext` `]l` `[l` `:ldiag` ... | the same for the window's own location list: `:ldiag` lists what the window shows (the piano roll its clip, the mixer and device panel the track), `:lopen` shows it below the window |

The list is a buffer like any other: `:vs quickfix` shows it beside the
window, `:e quickfix` in it, and a layout keeps its window. The graphical
frontend docks it in a pane as here (`:copen`, More); `:qf.window` pops it
out into a window of its own.

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

## Help

The manual is inside the program, as Vim's is. `:help` opens its contents
in a window split off the one you are in; `:help` with a topic goes to the
place that topic is described:

| Topic | Goes to |
| --- | --- |
| `:help gU`, `:help Ctrl-w o`, `:help <C-w>o` | a key, written either way: its row in the key table (`course/keys.md`) when it has one |
| `:help :s`, `:help :helpgrep` | a command |
| `:help 'timebind'` | an option |
| `:help daw.qf`, `:help daw.qf.feed` | a Lua module or function |
| `:help daw://tracks` | an address |
| `:help key-rule`, `:help quickfix-list`, `:help motions` | a section of the manual |
| `:help terminal`, `:help course-5`, `:help notation`, `:help notation-keys` | a page: of the manual, a lesson of the course, an extension's (by its name), a section of one |

The pages are the manual (`docs/*.md`), the course (`docs/course/*.md`)
and every extension's `README.md` and `doc/*.md`, those in your
configuration and those bundled with the program, loaded or not; the page
of an extension that is not loaded says how to load it. They are read from
the source tree the program runs from, or from `$DAW_HOME`, where an
installed program keeps them.

A topic is found as Vim finds it: the tag itself first, then the tags that
start with it, those that hold it, and those that hold its letters in order
(`:help qflst`). `Tab` after `:help ` completes the tags in that order. A
tag is made for each heading (its words joined with `-`: "The quickfix
list" is `quickfix-list`; in an extension's page they start with its name,
in a lesson's with `course-5`), for each paragraph that starts in bold
("**Motions** move the cursor" is `motions`), and for each key, command,
option, Lua name and address written as code, at the place it is described
(a table's first column, the start of a list item) before the places it is
only named, and in the manual before the course and the extensions.

A page of help is a text buffer that cannot be changed: it moves, searches,
selects and yanks as any text (`j` `k`, `w`, `/`, `n`, `v`, `y`, `gg`), and
`:vs`, `:sp`, `Ctrl-w` and `:q` treat its window as any other. Headings
show their tag at the right (`*quickfix-list*`), as Vim's help does; code is
in its own colour, tables are laid out in columns.

| Keys or command | In help |
| --- | --- |
| `Ctrl-]`, `Enter`, a double click | follow the link under the cursor, or look up the key, command or word there |
| `Ctrl-t`, `Ctrl-o` | back to where the link was followed from (`Ctrl-o` goes back through every jump, across pages) |
| `K` | look up the word under the cursor (in any text buffer) |
| `-` | the contents |
| `:helpgrep stretch` | every line of help that holds the words in the quickfix list, and the first of them; `]q` `[q` go through them. Case counts only when the words have a capital |

The bottom line of each view ends with its topic (`:help terminal` in the
arrange view, `:help mixer` in the mixer). In the keys picker (`?`) and the
commands picker (`,,`), `Ctrl-]` opens the help of the key or command
chosen. The tutor's panel names its lesson's page (`:help course-5`). In
the graphical frontend help opens as a docked pane, with the same
keys (`gw` pops it out into a window of its own).

## Pickers

A picker chooses one thing out of many by typing a few letters of it, as
Telescope does in Neovim. `,,` runs a command by name; the others are under
`,f` (`,` is the leader):

| Keys | Command | Lists | Enter |
| --- | --- | --- | --- |
| `,,` `,fc` | `pick.commands` | every command, with its key; a match in the name ranks above one in the description, a name that is the word typed or starts with it above the rest (`arrange` finds `:arrange`); among equal matches the commands you have run from here come first, and those the focused view has keys of its own for | runs it; `Ctrl-e` types it on the command line instead, for arguments |
| `?` `,fk` | `pick.keys` | every key of the focused view and the global ones, written as `Alt-h`, `,at`, `Ctrl-w o`, each tagged with where it works and whether it is a motion, operator, text object, or for a selection or insert mode. The view's own keys come first, then the global ones; plain keys before operators, motions and the rest, short keys before long. Keys that do the same are one line (`Ctrl-z, u`). The columns are as wide as what they hold, and the right side shows the manual's section for the key chosen. Last come the keys of the other views, tagged `arrange view` and so on, so that `send` in the mixer finds the arrange view's `,s`; choosing one goes to that view | runs it |
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

**Pickers you can hear.** In the pickers of presets (`:preset`), devices
(`,fa`), files (`,ff`, and the file picker of `:import`), beats
(`:drums.beat`) and snippets (`Ctrl-s` in the piano roll), the item under
the selection is heard once the selection has rested on it for
`daw.opt.audition_delay` ms (150), as Telescope previews a file. The top of
the pane says what plays: `▶ Soft pad · loop bar 5`.

| Picker | What is heard |
| --- | --- |
| presets | the preset loaded into the device, with the track's own notes: the bar of its MIDI clip at the cursor (else the last bar before it with notes), over and over. A track without notes plays a built-in phrase in the song's key (a beat on a drum track). Moving on loads the next preset over the same loop |
| devices | the device added to the cursor's track, with the same phrase. A plugin is made apart, so the selection rests on it 600 ms first, and the pane says `… loading` until it plays |
| files | a sound file on its own, from its start, over everything else at `daw.opt.audition_level` dB (-12), with its outline drawn in the pane and the place it has got to; a MIDI file's first two bars, at its own tempo, through the cursor's track when it has an instrument, else through a synth (and a kit for its drums) added for the purpose |
| beats | the beat written into the clip, its first bar over and over |
| snippets | what the snippet would write, once, with what the other pitched tracks play over the same beats |

What is tried on the project is a trial: it is made, heard and seen like
any edit, and `Esc` puts everything back exactly as it was, with no undo
step and the project not marked modified. `Enter` on the item heard keeps
it, as the one undo step choosing it makes (the plugin that was loaded is
kept, not made again). Nothing plays a phrase while the transport runs: the
song is what you hear then, with the preset or device in it. `Ctrl-Space`
turns hearing off and on for that kind of picker, and it is remembered
until the program ends. What plays is marked with `♪` in the pane (and in
place of the cursor arrow on its row); the pane says so as soon as hearing is
turned on.

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
| `boost(item)` | a number (up to 120) added to the score of an item that matches: what is used often, what belongs to the focused view |
| `primary(item)` | the part of the line that counts first: lines that match there rank above lines that match only elsewhere |
| `audition(item)` | makes the item heard when the selection rests on it; returns the label the pane shows, or `{ label, loading = function, keep = function(item) }`: `keep` runs in place of `on_choose` when the item heard is chosen, its trial kept. `audition_key` names the setting `Ctrl-Space` keeps, `audition_default = false` starts it off, `audition_delay(item, ms)` rests longer on a slow item |
| `prompt`, `width`, `height` | |

`daw.pick.match(query, line)` returns the score and the positions that
matched, `daw.pick.filter(query, items, format)` the items that match, best
first. `daw.pick.state()` is the open picker's query, matches and selection.
`daw.pick.resume()` opens the last picker again.

**Hearing from Lua.** `daw.audition` is what the pickers use:

```lua
daw.audition.try(function() daw.fx.load(device, "Plate") end)   -- an edit that can be taken back
daw.audition.through(track.id)        -- play the track's bar at the cursor through it, over and over
daw.audition.phrase(track.id, { { pitch = 60, start = 0, length = 1, velocity = 100 } }, { length = 4 })
daw.audition.file("/samples/kick.wav")  -- heard on its own at daw.opt.audition_level
daw.audition.keep()                     -- the trial becomes one undo step
daw.audition.stop()                     -- silence, and the trial taken back
daw.audition.state()                    -- what plays: a phrase's notes, or a file's place and outline
```

Underneath, `api.trial_begin()` and `api.trial_end(keep)` bracket the
edits, and `api.preview_play(path)`, `api.preview_stop()`,
`api.preview_get()` and `api.preview_level(db)` drive the preview bus: a
voice in the engine added after the master, which is never recorded,
rendered or saved.

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
