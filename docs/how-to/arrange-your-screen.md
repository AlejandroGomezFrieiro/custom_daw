# How to arrange your screen: windows, tabs and layouts

This guide shows you how to put the views that you need on the screen.
For example, you can write a score with only the notation on the screen.
You can also put two clips side by side in two piano rolls. The steps
are the same in the terminal and in the graphical window. For every key
and command, see [Windows, buffers and tabs](../reference/windows.md).

## Show a view in a window

Each window of the screen shows one view. To show a different view in
the window that has the keyboard, type `:e` and the name of the view:

- `:e mixer` shows the mixer.
- `:e roll://riff` shows the clip `riff` in the piano roll. A number
  also names a clip: `:e roll://7`.
- `:e notation://riff` shows the clip `riff` as notation (with the
  notation extension).
- `:e arrange` shows the arrange view.

To return to the view that the window showed before, press `Ctrl-^`.

## Put two views side by side

1. To put a view on the right of this window, type `:vs` and its name.
   For example, type `:vs roll://hook`.
2. To put a view below this window, type `:sp` and its name.
3. To go to the window on the left, press `Ctrl-w h`. `Ctrl-w j`,
   `Ctrl-w k` and `Ctrl-w l` go down, up and right.
4. To close the window that has the keyboard, press `Ctrl-w c`.

Every view can show in many windows. Each window has its own clip,
cursor and scroll. So you can edit two clips at the same time. You can
also see the notation and the piano roll of one clip. `Ctrl-w v` and
`Ctrl-w s` show the same view again, on the same clip.

## See the devices of two tracks

The device panel shows the devices of the track that the cursor is on.
To keep a panel on one track, pin it:

1. To put a panel for the track `Bass` on the right, type
   `:vs devices://Bass`. Its title says `pinned`.
2. Move the cursor to a different track. The other panel follows the
   cursor. The panel of `Bass` stays.
3. To pin the panel that has the keyboard to the track that it shows,
   press `\p`. Press `\p` again to make it follow the cursor.

The keys that you type in a pinned panel act on its track. For example,
`a` adds a device to `Bass`.

## Give one view the whole screen

- To close all the other windows, press `Ctrl-w o` (`:only`).
- To give the window the whole screen for some time, press `Ctrl-w |`.
  Press it again to put the other windows back.

The last window of a tab does not close. It continues to show its view,
for example the notation. To show something else in it, type `:e` and a
name.

## Use tabs

1. To open a new tab, type `:tabnew` and the name of a view. For
   example, type `:tabnew mixer`.
2. To go to the next tab or the previous tab, press `gt` or `gT`.
3. To close the tab, type `:tabclose`.
4. To move the tab, type `:tabmove` and a number. For example,
   `:tabmove 0` makes it the first tab.

A tab without a view shows the start page. The start page shows the
transport, the projects that you opened last, and what to type. To open a
project from the list, move to it with `j` and `k`, and press `Enter`.

## Start paw with your own layout

To start paw with only the notation, put this line in `init.lua`:

```lua
paw.ui.start_layout = "notation"
```

A start layout can also split the screen, or have tabs:

```lua
paw.ui.start_layout = { dir = "h", "notation", "roll" }
paw.ui.start_layout = { { name = "Write", layout = "notation" }, { name = "Mix", layout = "mixer" } }
```

## Keep the layout with the project

When you save a project with `:w`, paw keeps the tabs and windows in the
project file. When you open the project again, the screen is as it was.

You can use paw in a terminal and in the graphical window at the same
time. Each one is a seat: a place where you work. Each seat has its own
tabs and windows. The project keeps one layout for the graphical window
and one for the terminal. For example, keep the mixer in the window, and
only the notation in the terminal. When you open the project, each seat
gets its own layout. A seat without a layout in the project gets the
layout of the last save.

To keep the screen as it is when you open a project, type
`:set noproject_screen`.

To keep a layout for many projects, type `:layout save write`. To use
it again, type `:layout write`.

## In the graphical window

The graphical window shows the same tabs and windows as the terminal.

- To change the size of two windows, drag the border between them.
- To go to a tab, click it.
- To close a tab, click the close button on the tab, or click the tab
  with the middle button.
- To open a new tab, click `+` after the last tab.
- To move a tab, drag it along the row of tabs.
- To close a window, click the close button in its title.
