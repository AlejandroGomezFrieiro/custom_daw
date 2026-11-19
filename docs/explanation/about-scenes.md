# About scenes: one view, two frontends
<!-- tags: one-view-two-frontends -->

paw has two frontends: the terminal and the graphical window. Many programs
with two interfaces have two copies of each view, and the two copies do not
agree after some time. paw has one copy. This page tells how, and why.

## The kernel holds everything

The window keeps no project state. The kernel holds the project, and it
also holds what each view shows and what each gesture means. The window
shows what the kernel sends, and it returns each key and each gesture to
the kernel.

So a gesture has one meaning in all frontends. A drag of a clip in the
window calls `paw.frontend.act.drag_clips` in the kernel. The kernel snaps
the beats to the grid, makes the undo step, and the suite tests the
function in Lua. A new frontend gets the same behavior when it sends the
same calls. The window, a terminal and a script can also control the same
project at the same time, each from its own seat.

The cost is a turn of the kernel for each gesture, also over a network.
For a fader or a note, that cost is small. A frontend that decided by
itself would be faster, but it would also be a second program to keep
correct.

## Pushed, not asked for

The kernel sends a frontend what changed, when it changes. The window does
not ask for the state many times a second. An idle project sends nothing,
and an idle window draws nothing. A change sends only the part that
changed. While the song plays, the values that move (the playhead, the clock,
the meters, the parameters that lanes move) come as small live messages.
The window moves its widgets with them.

The full description is in [The control
protocol](../reference/protocol.md).

The terminal works in the same way. While the song plays, only the
playhead, the meters and the status line change. The kernel keeps the
last frame of each terminal, and what was under each of these parts. For
a new frame, it draws only these parts again, with the values of now, on
the last frame. Then it sends only the cells that changed.

When no cell changed, the kernel sends nothing. So the cost of a frame is the cost of the parts
that move, not the cost of the whole view. A key or an edit draws the
whole screen at once, as before. `paw.opt.fps` is the most frames a
second, not a fixed rate.

## What a scene is

A view is written once, in Lua, as the terminal draws it: text in cells.
The kernel records what the view draws as a **scene**: a tree of nodes in
cell units, each with a name. The kernel keeps the scene for each window of
each frontend. After the first scene, it sends only the nodes that changed.

The terminal lowers the scene to its cells. The window draws the same scene
with its own fonts, at its own resolution, with crisp text and vector
pictures. A test (`tests/scene_parity.lua`) makes sure that, for each view,
the scene lowered to cells is the same as what the terminal shows.

So an extension's view works in both frontends with no code for the
window. A view that paints in pixels (the notation, the vocal editor) sends
its drawing in the scene as a picture. The window draws the picture, and a
terminal that shows images draws the same pixels with the same rasterizer.

## Roles: more than cells

Cells alone make a window that looks like a terminal. So a view can mark
a rectangle with a **role**: a fader, a meter, a switch, a note. The mark
has the data of the element (a fader's position, a note's pitch and
velocity) and the cells that show it in a terminal. A frontend that knows
the role paints it as a widget, for example a fader cap at any point along
its travel. A frontend that does not know the role draws its cells. The
terminal always draws the cells, so the terminal comes first and loses
nothing.

A mark can also be a **hit region**: what a press, a drag or the wheel on
it means. The view tells the meaning once, and the two frontends find the
region under the pointer in the same scene. The terminal sends whole cells,
and the window sends fractions of a cell. So a fader in the window moves
smoothly, but the gesture is the same Lua function.

A **plane** places its marks in a domain of its own: beats along and
pitches up, for the piano roll. A note is at its beat and pitch. The
terminal rounds it to cells, and the window paints it where it is, between
cells.

## The layout is the kernel's too

The tabs and windows of the screen are also the kernel's, one layout for
each seat. The terminal draws them in cells. The graphical window draws
the same tree in pixels, a pane for each window, and the kernel sends a
scene for each pane. So a split made with `Ctrl-w v` shows in both
frontends. A drag of a border, a click on a tab and the close button of a
pane go to `paw.panes`. That module calls the layout code that `Ctrl-w`
calls.

An earlier window had its own fixed panels. There, the arrange view was
always the main panel, and the other views opened around it. Now no view
is the home of the screen. A tab can show only the notation, or two piano
rolls. This is why a view keeps a state for each window: two windows of
one view are two scenes with two cursors.

The transport bar along the top of the window is not a scene. It is the
window's own drawing, with its buttons, the tempo and the load. Its clock
changes many times a second while the song plays. A scene of the bar
would come again each time, and the window would paint it whole. So the
window reads the clock from the state that the kernel pushes
(`frontend.watch`), and paints only the bar. The terminal shows the same
values in its status line.

## What is not yet a scene

Most views come from scenes. Among them are the arrange view, the mixer,
the piano roll, the device panel and the drum grid. The arrange view's timeline is a plane of beats along and the
view's lines down. Lines go down, not tracks, because a take lane and an
automation lane have heights of their own. Also, a drag of a clip goes
across all of them in one domain. The session view is still the window's
own drawing in egui, fed by `frontend.watch`.
[Limits](../reference/limits.md) has the current list.

## Why the window looks as it does

The window looks like a mixer console, not like a web page. The surfaces
are neutral, and a color always tells a state. Blue is the selection, red
is record, and the track's own color is only on what belongs to the track. When
color has one meaning, the eye finds the state of a project fast. The
colors are in [The graphical window](../reference/window.md#colors-and-fonts).

The fonts are in the program, so the window looks the same on all
machines. The window draws only when something changes, so it costs
nothing at rest, also on a machine without a graphics card.
