# The graphical frontend

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
part that changed (see [docs/protocol.md](protocol.md)).

The window remembers how it was left, for the machine, in
`~/.local/state/daw/window.json`: its size and, on X11, its position on the
screen, the timeline's zoom, the height of the rows, and whether the mixer
shows. It writes it
when a value has stood for a second and when it closes, through
`daw.frontend.layout_get()` and `layout_set(table)` in the kernel, so a window
attached to a running kernel finds it too.

The position is only kept and restored where a program can ask for it and set
it, which is X11. On Wayland the compositor decides where a window goes: a
program cannot say, so none is kept and the window opens where the compositor
puts it. A saved position that no screen shows any more (a monitor that is
gone) is not used: the window goes to the top left of the main screen.

It keeps no project state. The kernel sends it the state when it changes
(`frontend.watch`, at most thirty times a second), what it shows is drawn
from that, and everything the user does goes back as calls to
`daw.frontend.act` and as keys, so it and a terminal UI or a script can
drive the same session at once. Its menus are the kernel's too
(`daw.frontend.menu`, in `runtime/lua/daw/window_menus.lua` beside the
terminal's mouse menus): the window lays them out and says which entry was
chosen.

The window is written with [egui](https://github.com/emilk/egui) and drawn
with OpenGL (eframe's glow renderer), on whatever driver the system has: the
graphics card's, or Mesa's llvmpipe on the processor where there is none
(on NixOS the driver comes from `hardware.graphics.enable`). `daw-gui
--renderer software`, or `DAW_GUI_RENDERER=software`, asks Mesa for llvmpipe
even where a card is there; `--renderer gpu` is the default. Where OpenGL
cannot start at all, the window says so in one line. It draws a frame only
when something has changed: nothing at rest, and while playing at most 25
frames a second for the playhead, the clock and the meters. The piano roll
and the timeline are handed only the notes, lines and points near what
shows, so a clip of thousands of notes opens and scrolls as fast as a short
one. Measured with the demo song in a 1500x960 window on llvmpipe (no
graphics card, the worst case): 0% of a core at rest, about 125% playing
(a frame takes 4 ms of the window's own work; the rest is llvmpipe filling
pixels on its threads). On a graphics card the filling is the card's.

It looks like a mixing desk rather than a web page. Surfaces are neutral
greys, and colour means something: blue is the selection, the edit cursor
and a lit switch; amber the playhead and the loop; green playing; red
recording and arming; orange mute; yellow solo. A track's own colour is on
its stripe, its clips, its notes and its name plate in the mixer, and
nowhere else. Words are in Inter and numbers that change (the clock, levels,
values) in JetBrains Mono; both fonts are built into the program
(`crates/daw-gui/fonts`, under the SIL Open Font License), so the window
looks the same on any machine. Japanese, Chinese and Korean (a lyric such
as さくら) are drawn with the system's font for them, found through
fontconfig (Noto Sans CJK, Source Han Sans and the like); without one such
words show as boxes. Icons are Phosphor's (MIT,
`crates/daw-gui/fonts/Phosphor-LICENSE`).

Each track header has its number, its name, the input, monitor, `M`, `S`
and `R` switches (lit in their colours when on), a fader with its level in
dB and a pan knob, then what it takes in and goes through, and at its right
a meter for each side with a clip light on top. Rows show less as they get
shorter: at the shortest only the first line. Meters are coloured by level
(green to −18 dB, then yellow-green, yellow, orange, red from 0 dB), hold
their peak for a moment as a thin line, and light the clip light when a
level reaches 0 dB; it stays lit until it is clicked or the transport starts
playing again. The mixer has a strip
per track from its left edge, with the master at the right: where it plays
into (the master's own output), its devices
(a click on one picks it in the device panel), its sends with their levels,
pan, a fader with a scale (+6, 0, −6, −12, −24, −48, as in the terminal)
beside its meters, the fader's level and the peak held, `M` `S` `R`, and
its name on its colour. Every strip keeps rows for as many sends as the
track with most has, so the faders share a baseline. A VCA has a strip too, after the tracks, naming the
tracks under it; right-click a strip or a track's header to make a VCA with the
track, put it under one or take it out. The status line at the bottom says what the pointer
does wherever it is.

| Where | What the pointer does |
| --- | --- |
| Timeline | click puts the cursor and lets go of the chosen clips; double click makes an empty one-bar MIDI clip; drag across empty lanes selects a stretch of time on those tracks (then `Delete`, or right click to delete, copy, loop or mute it); a drag with the right button draws a box that chooses the clips it touches (Shift adds them, Ctrl turns them over); the middle button held pans; right click (on release, where the button was not dragged) for a new clip, paste or a new track |
| Clip | click chooses it; Ctrl and a click adds it to the chosen clips or takes it out; Shift and a click takes in the clips between it and the last one chosen (on one track by time, across tracks the rectangle). Dragging a chosen clip moves all of them, keeping their places, also across tracks; Ctrl drops copies; they move by whole grid steps, so a clip off the grid keeps its distance from it; Shift leaves the grid. Either edge trims the clip, and the same edge of every chosen clip: the start without moving what plays (an audio clip starts further into its file; a MIDI clip hides the notes before its new start, which come back when the edge is dragged out again); Alt and an edge slips what plays inside instead; Alt and Shift on the right edge of an audio clip stretches what it plays to end there (see [Stretching and looping clips](mixing.md#stretching-and-looping-clips)), and a looped clip dragged longer repeats. On an audio clip the handles at the top corners drag its fades, drawn over it, and its top line drags its gain (Shift finely), which the waveform's height follows. A double click on an audio clip's top band puts a warp marker there, a yellow line down the clip with a handle at the top: drag the handle to move it, on the grid (Shift off it), stretching the sound on either side of it; right click the handle to remove it. Double click elsewhere opens its notes; right click to rename, split at the pointer or at the edit cursor, glue the chosen clips, repeat, mute, stretch, shift, loop or delete. One gesture is one undo step. Two or more chosen clips are visual mode's selection, so `d`, `x`, `y`, `>`, `gc`, `J` (glue) and the rest act on them, `S` splits them at the cursor, `Esc` lets go; one clip chosen with a click is the clip under the cursor |
| Ruler | click puts the edit cursor and the playhead; a drag in its top half loops the stretch dragged over (in the bottom half it moves them to where it ends); drag the loop's edges to change it; double click turns the loop on or off. The punch range is the red line under the loop's band (grey while punching is off): drag its ends to move them, Shift off the grid; the timeline's menu sets it from the selection or the loop and turns it on and off. Bars are numbered by the tempo map; a flag marks each tempo change (`96`) and signature change (`6/8`): drag it to move it, double click it to type a value, right click it to remove it. The tempo lane, shown from the timeline's menu (or `zT`, `:tempo.lane`), is a row under the ruler that draws the tempo map as a curve: level where a change holds, sloping where it ramps; click to add a change at the height clicked, hold and draw to lay a curve of ramps (the pencil), drag a change to move it in time and tempo (the first only in tempo), double click it to make it ramp or hold, right click it to remove it. Its corner says the range |
| Track header | click selects; double click renames; drag up or down to reorder, into a group when dropped among its tracks or under its header, out of it when dropped outside; drag the bottom edge to make the track taller or shorter (double click it for the height of the others; the height is kept with the track); press M, S or R and sweep across the others to set them all as the first was set; Shift on the fader moves it finely, double click puts it at 0 dB; right click (on release) for a colour, duplicate, bounce to audio, a new track below, delete |
| Piano roll | the mouse works as in REAPER's MIDI editor. Left button on empty grid: press where a note should start and drag as far as it should last (a click gives the note length shown in the toolbar, which drawing or stretching a note sets). Shift leaves the grid while drawing, moving or stretching; the magnet in the toolbar turns snapping off altogether. A click on a note chooses it, Shift or Ctrl click adds it or takes it out; dragging a note moves it and the others chosen (Ctrl drops copies), dragging either end changes where they all start or stop, and the status line shows the note's name, place and length meanwhile. The right button dragged, or the left with Ctrl, chooses the notes its box touches (Shift adds, Ctrl toggles); a right click removes a note, or on empty grid opens a menu (choose all, let go, delete, quantize, snap); a double click removes a note; Alt and a drag erases every note crossed. The keyboard sounds a key under a click or a drag, and a right drag over it chooses the notes in that range of pitches. The wheel scrolls, with Shift sideways; Ctrl and the wheel zoom in time and Alt the rows, where the pointer is; the middle button pans. `Ctrl-a` (in the window), `gA` chooses every note, `x` or `Delete` removes the chosen, `Esc` lets go. The strip underneath shows velocities, set by dragging across the bars (only the chosen notes, if any are chosen), or a controller chosen from its dropdown (pitch wheel, modulation, expression, pedal), drawn with the pointer held down; a right drag draws a straight line of moves, a click on a move's head chooses it (Ctrl adds or takes it out), Ctrl and a drag chooses those in a box, dragging a chosen head moves them, `Delete` removes them, and a right click opens a menu (choose all, let go, delete, clear). List in the toolbar opens the event list, every note and move of the clip as rows to change in place (see Mixing). The toolbar holds the clip, the grid, snap, the note length, Quantize (`:notes.quantize`, the chosen notes or all), Step (`:notes.step_input`: with the transport stopped, notes played on a MIDI keyboard are entered at the cursor, chords together, and the cursor steps on), zoom, a window of its own and close. It also says how many notes are chosen and where. The ruler counts bars and beats; a click there moves the playhead. Over it a row names the chords that sound over every pitched track (`daw.opt.chords`: names, Roman numerals, both, or off; see [Harmony, completion and snippets](harmony.md)). An active snippet's notes are drawn in violet with a chip under them naming its current choice; the snippet picker's choice shows as violet ghosts. Notes of the track's other clips that sound at the same time show faintly behind, and those of other pitched tracks in their own colours (see the terminal's piano roll for which). A click on another track's note makes its clip the one edited (new notes go there), Ctrl and a click edits it too, or no longer: the roll then edits several clips at once, each clip's notes in its track's colour, and a click, a box, a drag, Delete, the velocity strip and the keys reach the notes of all of them, each note staying in its own clip, one undo step each. Selecting several clips in the timeline and double clicking one of them opens them all, that one active. Tracks in the toolbar opens the side panel: each track near the roll (a click shows or hides its notes) and under it its clips (a click on the name makes the clip active, on the box edits it too or no longer). A dot on the keyboard marks the keys sounding at the cursor; the toolbar names the chord when a harmony reader is loaded. A suggestion from a completion source (see [harmony.md](harmony.md)) shows as see-through ghost notes with a bright edge, under a row of chips: a numbered chip per alternative (a click shows it) and one saying what shows (a click accepts it, as `Tab` does; `Ctrl-l` takes its next note or chord, `Esc` dismisses). With a source loaded the toolbar has a Suggest switch for suggestions that come by themselves after a pause; `Ctrl-Space` asks at any time |
| Recording | the record button starts a take on the armed tracks (the `R` on a track). A track's input button (the microphone; blue when an input is chosen, and what it takes in, such as `UR22mkII · 1/2`, is written under the fader) opens a menu of its audio inputs, MIDI ports and MIDI channels; a bar along its foot shows the level arriving there, armed or not, and the loudspeaker beside it turns monitoring on. With no audio input a track records MIDI. With no track armed the record button arms the selected one and says so. Press it again, or stop, to end the take; what is being recorded is drawn in red as it grows (punched, only over the punch range). With a count-in the clock reads `count 4`, `count 3`… and the button blinks on the beats until the take starts; the timeline's menu turns the count-in on and off, and a pre-roll of two bars before a punch |
| Take lanes | a track's menu, a clip's Takes menu or `zt` shows its takes as lanes under its clips. Drag across lane k: take k plays over that stretch (on the grid, Shift off it), the clips cut at its ends and pieces that then play the same take joined back, one undo step; a click on lane k gives the piece under the pointer take k; right click to hide them. The terminal comps the same way with its mouse (see [the terminal](terminal.md)) |
| Groups | a track's menu has "New group with this track…", "Move into a group…" and "Take out of its group". A group's members stand under it, a step in and in its colour, and sound through it; the triangle beside its name folds them away and brings them back |
| Routing | above the selected track's devices: "Output" chooses the track it plays into, "+ Send" a track its sound is sent to as well; each send has a level to drag, `pre` to take it ahead of the fader, and a cross to take it away |
| Templates | with the templates extension: a track's menu saves it (or, on a group, the whole group) and saves its devices as a chain; `Track` → "From a template…" makes one again, and "Add devices from a template…" puts a saved chain on the track |
| Session | the Session button shows the clip launcher under the timeline: a slot's play mark launches it (let go stops a gate clip), a click chooses it, a double click opens its notes (an empty slot gets a new MIDI clip first), a drag moves it to another slot (Ctrl copies), a clip dragged from the timeline onto a slot is copied there, the dot of an empty slot records into it; scenes down the right launch their rows, and the bar along the top sets the quantize, captures, sends every track back and stops every clip. See [Live performance](live.md) |
| Mixer | drag a fader (0 dB sits at 72% of its travel) or turn the pan knob by dragging up and down, with Shift finely; double click for 0 dB or centre; the wheel nudges. A click on a device in a strip picks it in the device panel, a click on the clip light or the peak readout clears it. With the keyboard in the mixer, the row its cursor is on (an insert, the sends, the pan, the fader, mute, solo, arm) is outlined on its strip, as the device panel outlines its row |
| Devices | type part of a name to find a device or plugin, Enter or a click adds it (Esc lets go of the box); drag a parameter, wheel to nudge it, double click to put it back; the power button turns a device off and on, the arrows move it along the chain, the window button opens a plugin's own editor |
| Transport | back to the start, stop, play or pause, record, loop and metronome; drag or wheel over the tempo to change it, double click to type it; click the project's name for the file menu: new, open, open recent (a submenu, with "Clear the list" at its end), recover, save, save as, import, render, quit (a dot beside it means there are changes); Mixer, Automation and Piano roll show and hide those views, and More lists every other view the kernel has (the extensions' among them), each to open in a pane: where it docks, else split from the pane with the keyboard; click the engine indicator (`pipewire · UR22mkII · 48 kHz`) for a menu of output and input devices and block sizes, headed by the sample rate, block size and latencies |
| File | New, Open and Quit ask first when there are changes: save them (a project with no file yet is asked where it goes), don't, or stay. So does closing the window. Render… opens a dialog: the file, the range (the song, the loop, the selection, a region), WAV or FLAC (and MP3, Ogg or Opus when ffmpeg is installed: the sample size and dither give way to a quality of Low, Medium, High or Best), the sample size, the tail, normalizing, dither, mono, a file per track, and under Tags the title, artist, album, track, year, genre, comment and cover that the files carry (kept with the project); the render runs in the background with its progress and a Cancel in the status line. Open…, Save as…, Import and the render's `…` button show the desktop's own file dialog (see below) |
| Lanes as rows | a track's menu has Automation ▸ Show or hide the lanes as rows: each of its lanes is then a row of its own under its clips, always there to draw on (click adds a point, hold to draw, drag a point, right click removes it), while the clips above stay editable. A track with no lane yet gets one for its fader. The same menu sets the track's automation mode, as does the `A` flag on its header |
| Automation | with Automation on, each track shows one lane over the timeline, named at its left. Click adds a point, holding the button down draws a curve, drag moves a point, right click removes one; right click elsewhere clears the lane or turns it off. The header's last line chooses the lane: volume, pan, or a parameter. The small curve button beside a device's parameter gives that parameter a lane and shows it; a right click on the parameter's name offers to automate it (a lane with a point at its value, at the cursor) or to edit its curve in the curve editor, in a pane split from the one with the keyboard (see [the terminal interface](terminal.md)) |
| Wheel | scrolls; with Shift sideways; with Ctrl it zooms in time where the pointer is, in the timeline and in the piano roll, and over the track headers makes every track taller or shorter; with Alt it makes the tracks (or the piano roll's rows) taller and shorter |
| Pages over the window | a picker's rows (commands, files, devices) take the pointer: a click selects a row, a double click or Enter chooses it, the wheel scrolls; a click outside closes the page; "Open in a window" at its top right moves the page into a window of its own, in its colours |
| Bands under the ruler | under the markers, a row for each extension that adds one: the sections of the song, the mix's findings. A click on an entry does what it stands for (goes to the section, to the finding); the status line says what |
| Zoom | the buttons in the corner of the timeline: `−` and `+` in time (`Ctrl -`, `Ctrl +`), `Fit` for the whole song (`Ctrl 0`), the arrows for the height of the tracks (`Ctrl ↑`, `Ctrl ↓`), from one line a track to tall ones. Waveforms are drawn again at the width they then have |
| Sound files | `Track` → "From a sound file…", or "Import a sound or MIDI file…" in the timeline's menu, lists files to choose from (type to narrow, Enter walks into a directory): wav, aiff, flac, mp3 and ogg come in on a track of their own at the cursor. `:import path` does the same, and `daw-gui take.mp3` starts a project with the file |
| MIDI files | File → Open… opens a `.mid` as a new project, asking first about unsaved changes as for a project; File → Import… (and the timeline menu's import) brings its tracks in below the cursor's track at the cursor, leaving the tempo map alone. What comes of a file is in [Recording](recording.md) under MIDI files |

When the window started its kernel, so that the kernel's disk is the
window's, files are chosen in the desktop's own dialog, asked for through
the XDG desktop portal (`org.freedesktop.portal.FileChooser` over D-Bus, with
no toolkit linked). It offers projects, MIDI files, sound files and all files, and starts
where a file was last chosen, else beside the project; the list picker starts
in the same place. The dialog does not stop the window. Without a portal (no
session bus, a bare window manager), with `daw.opt.native_dialogs = false`, or
when the window is attached to a kernel with `--socket` or `--connect`
(which may be on another machine), the kernel's list picker is used, as it
always was; but Import still shows the desktop's dialog there, and sends
the sound file chosen to the kernel (see
[Running it](running.md#on-another-machine)). A
project chosen this way asks about unsaved changes like any other way of
opening one: `daw.frontend.act.leave(how, "open:" .. path)`.

Files can be dragged in from a file manager on X11: a sound file becomes a
track of its own, one for each file dropped together, with the clip at the
edit cursor; a MIDI file's tracks come in as `:import` brings them; a
project (`.json`) asks to open it, through the same question
about unsaved changes; anything else is named in the status line as not
taken. What a drop means is `daw.frontend.act.drop(paths, row, beat)`: with a
`row` (a place in the list of tracks) and a `beat` it puts the files one
after another on that track, at the beat on the grid; the window cannot say
where the pointer was, for winit 0.30 does not tell, so it passes neither.
Wayland sends the window no drops at all with this version of winit. On a
window attached to a kernel it did not start, the sound and MIDI files
dropped are sent to the kernel first, into its project's media folder;
nothing else is.

A window attached to a kernel (`--socket`, `--connect`) has a seat of its
own there: its own cursor, selection and mode, beside the kernel's
terminal and other windows. The engine menu's "Hear it on this machine"
(or `--listen-audio`) plays the kernel's sound through this machine's
device, a quarter of a second late or more.

Every key still goes to the kernel's key mappings, so the window is also
driven exactly as the terminal UI is: the same modes, operators, registers
and macros, with the mode and the view that has the keys (`NORMAL·mixer`),
the prompt, messages and half-typed keys in the status line, the selection
and both cursors drawn, the keys that can follow listed, and help and other
pages shown over the window. `:help` opens the manual in a docked pane, split off like the terminal's
(`gw` or `:textbuf.window` pops it out into a window of its own), drawn as the
terminal draws it and moved through with the same keys (see Help in [the
terminal interface](terminal.md)). The status line shows the keys worth knowing in
the view that has the keyboard (the terminal's key bar, `daw.opt.keybar`), the
quickfix count (`qf E1 W2`) in the colour of the worst entry, and, while a
command is typed, the list of what it could become, with each one's
description, above the line (Tab and Shift-Tab move through it, Up and Down
go through what was typed before). A message stays until the next key or a
change of mode, or for `message_time`. Pages such as the commands list are
drawn as wide as the window. `Ctrl-z`, `Ctrl-y`,
`Ctrl-s` and `Delete` do what they do elsewhere. The piano roll and mixer are
the kernel's: opening one puts the keyboard in it.

**Windows, buffers and tabs.** The window shows the kernel's tabs and
windows (see [Windows, buffers and tabs](terminal.md#windows-buffers-and-tabs))
as the terminal does: each window of the current tab is a pane of the main
area, between the transport bar and the status line, laid out by the same
rules, a size in cells taken as so many of the monospace font's cells in
pixels (and never less than what the window's own drawing of a view needs).
The arrange view, the device panel, the piano roll, the mixer and the
session view are drawn by the window itself in their panes; any other
buffer is drawn by the kernel at the pane's size, inset a little, under
the window's own title with buttons to pop it out and to close it: a view
that paints (the notation, the drum grid, the vocal editor, the undo tree)
as a picture, any other (a curve `daw://lane/3`, the quickfix list, a text
buffer `daw://tracks`, an empty window) cell by cell in the monospace font
as the terminal draws it, the title row the terminal gives it hidden under
the window's title. So `:vs daw://lane/3`,
`Enter` on a lane row, `:copen`, `:sp quickfix`, `:e daw://tracks`,
`Ctrl-w` and its keys, `:q`, `:only`, `:tabnew mixer`, `gt` and `:layout
edit` do in the window what they do in the terminal. A ring of the
selection's colour goes round the pane with the keyboard when there is
more than one; a press anywhere in a pane gives it the keyboard; the
borders between panes are dragged to share the room (a size of whole
cells is kept, as `Ctrl-w +` keeps it); with more than one tab a row of
them runs along the top, and a click on one goes to it. Every window
attached has tabs and windows of its own, and the first time a window
shows its main area the device panel is put beside the arrange view. The
kernel says where each pane goes in `daw.panes.state()`, told the main
area's size with `daw.panes.area(width, height)`; it paints a pane with
`daw.panes.paint(win, width, height)`, and takes the pointer in one with
`daw.panes.pointer(win, event)`, a press with `daw.panes.focus(win)`, a
border dragged with `daw.panes.border(i, x, y)` and a tab clicked with
`daw.panes.tab(i)` (runtime/lua/daw/panes.lua, tested in the suite).

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

**Views in windows.** Any view of the terminal can be popped out into a
window of its own on request: `:view.window undotree` (the focused view, or
the page floating over the others, without a name), `Ctrl-w f` in a curve
or a text buffer, the button on a painted pane's title, or "Open in a
window" on a floating page. The window opens over the middle of the main
window, the view inset under a title with a Dock button, and a status line
along its bottom as the main window's: the mode, then a prompt being typed,
a message, or the view's keys. A view docked in a pane leaves it while it is
in a window. The keyboard is the window's while it is in front. Closing the
window with its close button, the Dock button or `Ctrl-w d` (`:view.dock`)
puts the view back in the main window as a pane: where it was, else where
it docks, else in a window split from the one with the keyboard, which it
then has. `:q` or the view's own `q` close the view instead (`Esc` stays
in the view, as everywhere), and the keyboard goes back to the main window,
in the pane that had it before; so do keys typed in the main window
meanwhile. The kernel draws the view by itself
at the window's size, in cells of the bundled JetBrains Mono (their size is
measured on the font, so box-drawing characters join), with the theme's
colours in 24 bits whatever the terminal shows, and sends it as runs of text
of one style each. Under it a line shows a prompt being answered, a message,
or the view's keys. Keys typed there go to the view's mappings with the view
focused, a prompt it opens is answered there, and the pointer reaches its
`on_mouse` in cells, as from a terminal: down, up, drag, scroll. Closing the
view (`q`, `daw.ui.close()`) closes the window. It is drawn again only when
a redraw has been asked for and what it would show has changed, at most 30
times a second. The font has no braille, so the window draws each braille
character (U+2800 to U+28FF) itself, as small squares in the cell's two
columns and four rows of dots, and curves there are braille as in the
terminal (`daw.opt.braille` off draws lines instead). A view that has a
painted twin (`painted = "name"` on its table, as the undo tree and the mix
report have) is offered under More as the twin. A terminal
attached to the same kernel is not disturbed: the view is drawn on a grid of
its own (`daw.api.ui_view_snapshot(name, width, height)` gives the same as
rows of runs `{ x, w, text, fg, bg, attrs }`).

**Windows for extensions.** A view that paints is shown in a pane, or in a
window of its own, so an extension brings its own editor to the graphical
frontend without the frontend knowing anything about it:

```lua
daw.ui.view("scope", {
  paint = function(self, g, ctx)                 -- pixels; ctx.width, ctx.height
    local c = daw.canvas.palette                 -- the window's colours, by name
    g:rect(0, 0, ctx.width, ctx.height, { fill = c.surface })
    g:text(12, 10, "hello", { color = c.text, size = 14, bold = true })
    g:poly({ 0, 80, 40, 60, 80, 90 }, { color = c.select, width = 2 })
    local part = g:sub(0, 100, ctx.width, 200)   -- drawn from its corner, cut at its edges
    g:mono(12, 40, "┌─ cells ─┐", { color = c.text, background = c.well })  -- a run of monospace cells
    g:glyph(40, 60, 36, 0xE050, c.text, "Leland")  -- a music font's (SMuFL) glyph: origin, em in px, code point
    g:layer("caret")                             -- what follows moves over the page: a frontend may draw it apart
    g:cut(300, 0, 120)                           -- a barline: where a frontend may cut the page into images
  end,
  pointer = function(self, e) end,               -- e.kind: down, up, move (button held), hover, double, wheel; e.x, e.y, e.button
})
daw.ui.dock("scope", { side = "bottom", hidden = true })   -- where it docks
daw.canvas.open("scope", { title = "Scope", width = 640, height = 360 })
```

`daw.canvas.open` shows a view that docks (`daw.ui.dock`, or one with a
window in the layout already) in its pane, under the title given; a view
with no place in the layout, or `daw.canvas.open(name, { window = true })`,
in a window of its own that starts at the size given. The kernel paints the
view at the pane's or the window's size and the frontend makes the
rectangles, text, lines and music glyphs it is given into one image, with
the rasterizer the terminal uses ([crates/daw-raster](../crates/daw-raster)),
so the two show the same pixels. `g:glyph(x, y, size, codepoint, colour,
font)` draws a glyph of a SMuFL music font built in (Leland, Bravura,
Petaluma), `size` pixels to the em; `daw.api.smufl(font)` gives the font's
metadata (engraving defaults, glyph boxes and anchors, glyph names);
`daw.api.canvas_export(path, "pdf", pages)` writes drawings as a PDF (a
page for each `{ ops, width, height }`), `"svg"` or `"png"` the first, the
glyphs and text as outlines. A
view that also shows its pixels in the terminal keeps cells for them in
its `render` with `buf:surface(x, y, w, h)`, which is false where the
terminal shows only cells (see "Pictures" in [The terminal
interface](terminal.md)); `ctx.surface` then says the drawing goes there,
`ctx.cell` is the terminal's cell size, and `ctx.fg`, `ctx.bg` its
colours. A frontend that cannot draw a music font's glyphs is given each
as a path from the font's outline (`daw.canvas.glyph_outline`). `daw.canvas.palette` holds the
window's colours under the names the window itself uses (`surface`, `lane`,
`panel`, `well`, `control`, `line_bar`, `text`, `text_2`, `text_3`,
`select`, `play`, `rec`, `mute`, `solo`, `warn`, `error`, the meter colours
and a keyboard's), and the editors of the extensions draw with it; keys go to the view's mappings as in
the terminal. The vocal editor of [extensions/utau](../extensions/utau) is made
this way ([gui.lua](../extensions/utau/lua/utau/gui.lua)): notes with lyrics,
the pitch that is drawn and the pitch that is sung, phonemes, a toolbar with
the singer, tools and grid. An extension with an editor of its own for the
clips of a kind of track gives the kind an `editor` (see
[Everything an extension can own](extensions.md#everything-an-extension-can-own)),
and a double click on such a clip opens it there; for other clips it adds a
function to `daw.frontend.openers`. A kind of track is offered by the "+
Track" and "New track" menus, and the track header says what kind it is
before its devices ("Vocal track · Kitane  ·  UTAU voice").

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
