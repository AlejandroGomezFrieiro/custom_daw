# Windows, buffers and tabs

<!-- tags: windows-buffers-and-tabs windows buffers tabs -->

The screen has the layout of Neovim.

- A **buffer** is a thing to show and edit. The views are buffers: the arrange view (`arrange`), the piano roll (`roll`), the mixer (`mixer`), the device panel (`devices`) and the session view (`session`). The event list, help and the view of an extension (`notation`, `drums`, `utau` and other) are buffers too.
- A **window** shows one buffer.
- A **tab** holds windows, split side by side and one above the other.

The status line and the bottom line stay along the bottom of every tab.

## The start

At the start there is one tab. It shows the arrange view, and the panels
open and close in their places (`,m`, `,d`, `,p`, `Enter` on a clip).

- `,p` with no clip open opens the piano roll on the clip under the cursor. If there is no clip there, it shows a message and changes nothing.
- `,m` in a window that shows only the mixer (after `Ctrl-w o`) puts the arrange view back in its place.
- `:view.focus` of a view that does not show puts it in the current window. So the focus is never on a view that is not visible.
- `:help` splits half of the screen, as Vim does for its help.

## Sizes

- Sometimes three or more panels are one above the other. Then the arrange view keeps a third of the rows (as `Ctrl-w =` gives it), and the notation view takes half or less.
- In a column, the arrange view keeps two fifths of the rows. The panels with a size of their own give rows last.
- In a panel whose height is an option (`mixer_height`), `Ctrl-w +` and `Ctrl-w -` change that option.

## Splits

`:vs roll` splits the window in two, side by side, and shows the piano roll
in the new half. `Ctrl-w h` and `Ctrl-w l` go between the two. Each window
takes its own keys, and a clip that you open shows in that window.

- A built-in view is one buffer, shown in one window at a time. If you show it in a different window, it moves there, with a message.
- A panel window closed with `Ctrl-w c` keeps its place. The panel returns there.
- New windows go to the right of and below the window that you split. `:set splitright!` and `:set splitbelow!` put them to the left and above.

## Keys and commands

| Keys or command | Effect |
| --- | --- |
| `:sp roll`, `:vs roll` | Split the window, one above the other or side by side, and show a buffer. Without a name, show the same buffer, as in Vim. A list edited as text shows in both windows. The new window of the arrange view shows the piano roll, and that of the roll the arrange view. Any other view (one window at a time) gives an empty window that says so. |
| `Ctrl-w s`, `Ctrl-w v` | The same as `:sp` and `:vs` without a name. |
| `:vnew`, `Ctrl-w n` | Open an empty window. |
| `:e roll`, `:b roll`, `:b 3` | Show a buffer in this window, by name or number. The name of a buffer or a view, or an address such as `paw://tracks`, comes before a file. Only a file asks about unsaved work: `:e song.json`, `:e song.mid`, `:e take.wav`. A folder shows as a [file buffer](file-manager.md). |
| `:bn`, `:bp` | Show the next or the previous buffer. |
| `:ls` | Lists the buffers. |
| `:bd roll` | Closes every window of a buffer. |
| `Ctrl-^`, `:b #` | Shows again what this window showed before (for example, from `paw://tracks` back to the arrange view). |
| `:close`, `Ctrl-w c` | Closes the window. |
| `:q`, `Ctrl-w q` | Closes the window. In the last window, quits (and asks about unsaved changes). |
| `:only`, `Ctrl-w o` | Closes every other window. |
| `Ctrl-w h` `Ctrl-w j` `Ctrl-w k` `Ctrl-w l` | Go to the window to the left, below, above, to the right. A count goes further. |
| `Ctrl-w w` `Ctrl-w W`, `Tab` | Go to the next and the previous window. |
| `Ctrl-w p` | Goes to the window that had the keyboard before. |
| `Ctrl-w H` `Ctrl-w J` `Ctrl-w K` `Ctrl-w L` | Move the window to the far left, bottom, top, right. |
| `Ctrl-w x` | Exchanges the window with the next. |
| `Ctrl-w r` `Ctrl-w R` | Rotate the windows of the row or column. |
| `Ctrl-w +` `Ctrl-w -` `Ctrl-w <` `Ctrl-w >` | Resize the window. A count goes further. In the device panel, `<` `>` change `devices_width`. |
| `Ctrl-w =` | Gives the windows equal sizes. |
| `Ctrl-w _` `Ctrl-w \|` | Gives the window the whole tab. Again: puts the other windows back. |
| `:resize 20`, `:resize +5`, `:vertical resize 40` | Set the height or the width of the window. |
| `:tabnew Mix`, `:tabnew mixer` | Makes a new tab named Mix, or a tab that shows the mixer. |
| `gt` `gT`, `:tabn 2` | Go to the next and the previous tab. Go to tab 2. |
| `Ctrl-w T` | Moves the window to a tab of its own. |
| `:tabclose` | Closes the tab. |
| `:tabs` | Lists the tabs and their windows. |
| `:narrow Strings`, `zn` | Makes a tab of the tracks of one group (`zn`: the group at the cursor). |
| `:widen`, `zw` | Closes the narrowed tab and returns. |
| `:view.open undotree` | Shows a view where it docks, else in a window split from this window (the More menu of the graphical window). |
| `:layout save edit`, `:layout edit` | Write the tabs and windows as layout `edit`. Put them back. |

With more than one tab, a tab line along the top gives their names. A click
on a tab goes to it. A click in a window gives it the keyboard (see
[The mouse](mouse.md)). The rule between two windows side by side is a
border to drag with the mouse. So is the top row of a window below a
different window, where a press that the window does not use drags the
border.

## Bound in time

`:setlocal timebind` in the arrange view and in the piano roll next to it
makes them show the same time at the same zoom. The window with the
keyboard leads, and the other window scrolls with it. While the song plays,
both follow the playhead. `:setlocal notimebind` removes the bind.

## Layouts

`:layout save edit` writes the tabs and windows to the state directory,
and `:layout edit` puts them back. A configuration can name its own
layouts, and start with one:

```lua
paw.layouts.edit = {
  { name = "Edit", layout = { dir = "h", "arrange", "roll" } },
  { name = "Mix", layout = "mixer" },
}
paw.opt.layout = "edit"
```

| Field | Effect |
| --- | --- |
| `dir = "h"` | Puts the windows side by side. |
| `dir = "v"` | Puts the windows one above the other. |
| `size` | The size of a window, in cells. |
| `weight` | The share of a window, 1 by default. |

Each terminal attached with `paw attach` has its own tabs and windows.

## Narrowed tabs

`:narrow Strings` (or `zn`) narrows a tab to a group. The tab starts with
the windows of the tab before it. Everything in it sees only the tracks of
that group. This includes the arrange view, the mixer, the device panel and
the session view. It also includes `paw://tracks`, the pickers, `:query`,
the motions and the Ex ranges.
`:widen` (`zw`) closes the tab and returns.

The status line shows `narrowed Strings`. Each tab has its own group. So
`gt` goes from the whole song to the strings and to the brass.
`paw://tracks` in a narrowed tab lists the tracks of the group, and `:w`
does not change the other tracks. `paw.opt.scope_rest` sets what the other
tracks do: play, mute, or play from frozen files. See
[Render](render.md).
