# undotree

Neovim's undo tree for paw. No edit is lost by undoing and then changing
something: the change starts a new branch, and the old one stays where you can
go back to it. Any earlier state can be returned to, by walking the tree, by
stepping through time across branches, or by a time (`:earlier 2m`). States
can be named, named states can be written beside the project as checkpoints
and restored after reopening it, and two states can be compared by ear while
the song plays.

```lua
daw.ext.load("extensions/undotree")   -- or put the directory in ~/.config/daw/extensions
```

The tree itself is in the kernel, so `u` and `Ctrl-r` walk it whether or not
this extension is loaded; the extension is the interface to the rest of it.

## Keys

| Keys | What they do |
| --- | --- |
| `g-` `g+` | the state made before or after this one, whatever branch it is on (with a count: `5g-`) |
| `<leader>uu` | the undo tree window |
| `<leader>ua` | mark this state as A |
| `<leader>ub`, `\` | switch between A and where you were (B) |
| `<leader>uB` | forget A and B |
| `<leader>uc` | write a checkpoint (asks for a name) |
| `<leader>ul` | list checkpoints and restore one |
| `<leader>un` | name this state, for this session |
| `<leader>ud` | what the last step changed |

`u` and `Ctrl-r` are the built-in undo and redo: undo goes to the parent state,
redo to the child last visited. `\` is the option `undotree_ab_key`; set it
to another key, or `""` for none, before the extension loads.

In the undo tree window: `j` `k` move (`Ctrl-d` `Ctrl-u` by ten, `g` `G` to
the ends), `Enter` goes to the selected state and stays open, `u` `Ctrl-r`
undo and redo, `-` `+` step through time like `g-` `g+`, `a` marks the
selected state A, `b` switches A/B, `n` names the selected state, `c` writes a
checkpoint of the current state, `d` switches the right-hand side between
what the selected state's step changed and what differs from it to the
current state, `Space` plays and stops, `q` or `Esc` closes. A click on a row
selects it, and the wheel moves the selection.

In the graphical frontend the tree opens in a painted window of its own
(More ▸ Undo tree, or `:view.window undotree_paint`): a node for each state,
newest at the top, the branches drawn between them, the way back to the first
state and the current state lit. A click on a state goes there; resting the
pointer on one says what the step was, when, and which state it grew from;
the right-hand side shows what the chosen state changed. It takes the same
keys as the terminal's, and a name asked for with `n` or `c` is typed on its
last line. (`:view.window undotree`, or "Open in a window" on `<leader>uu`,
opens the terminal's view in cells instead.)

The terminal's tree draws newest at the top. `@` is the current state, `*` any other;
`│` carries a branch down to where it grew from, and `─┘` joins it there.
Each row shows the state's number, the time it was made, its name in quotes,
`[A]` `[B]`, `(saved)` for the state last saved, and what made it: the
description of the key or command, then the keys typed (`Delete the clip  x`,
`Add a track above  O`, `Set Keys volume`), or `a change` for changes made by
scripts, `opened` for the project as loaded.

## Commands

| Command | |
| --- | --- |
| `:undotree` | open or close the window |
| `:earlier 5`, `:earlier 30s`, `:earlier 2m`, `:earlier 1h`, `:earlier 1d` | back by a count of states or by a time, across branches |
| `:later …` | the same, forwards |
| `:undo.goto 12` | go to state 12 |
| `:undo.name verse` | name the current state, for this session only |
| `:undo.diff`, `:undo.diff 3`, `:undo.diff 3 7` | what the last step changed; from state 3 to now; from 3 to 7 |
| `:checkpoint before the bridge` | name the current state and write it beside the project |
| `:checkpoints` | list checkpoints; choosing one restores it |
| `:checkpoint.restore 2`, `:checkpoint.restore intro` | restore by number in the list or by name |
| `:checkpoint.delete 2` | delete a checkpoint file |
| `:ab.mark`, `:ab.mark 12` | mark the current state, or state 12, as A |
| `:ab.toggle` | switch between A and B |
| `:ab.clear` | forget A and B |

Time travel follows Vim: `:earlier 2m` goes to the newest state made at least
two minutes before the current state was, and stops at the oldest state;
`:later` goes to the newest state made by that time after it. A count steps
through states in the order they were made, like `g-` and `g+`. Vim's `f`
(file writes) is not supported.

## A/B

Mark one version A (`<leader>ua`), go on working or go somewhere else in the
tree, and press `\` to hear A; `\` again goes back to where you were, which is
B. Each switch first closes the open undo step, so B is exactly what you last
heard. Moving is an ordinary sync of one snapshot to the other, the same path
every edit and undo takes, so the transport does not stop or move, and only
what differs between the two versions is sent to the engine: a volume
change is a volume change, a different clip list replaces that track's clips,
and a device that is only in one version is added or removed (a plugin added
this way starts from its saved state, which may be heard). A and B are kept
from pruning while they are marked. Opening another project forgets them.

## Checkpoints on disk

`:checkpoint <name>` names the current state and writes it to a folder beside
the project file, named after it: `song.json` keeps its checkpoints in
`song.checkpoints/`. The folder is only made by the first checkpoint, so a
project that never uses them has none. Each checkpoint is one file,
`<milliseconds since 1970>-<name>.json` (the name percent-encoded, spaces as
`+`), holding the project as it was with its plugins' state; listing reads
only the folder. Two checkpoints may share a name; both are kept.

A project that has never been saved has no folder. `:checkpoint` then names
the state and remembers it, and the first save of the project writes every
checkpoint named so far (as each state was, even if you have moved on since).
Until then those names live only in this session.

Restoring a checkpoint does not throw history away: it is a new step below the
current state, named as the checkpoint, so `u` goes back to where you were.
Checkpoints are not undo history: after reopening a project the tree starts
again from the project as loaded, and the checkpoints are what is left of
earlier sessions.

## Pruning

The tree keeps at most 1000 states. When an edit takes it past that, the
oldest state is dropped that is not the root (the project as opened or made),
the current state, the state last saved, a named state, or A or B. Its
children hang from its parent instead, so undoing from them skips over it.
States share everything unchanged through `Arc`, so a state costs about what
its edit changed. When every state is protected the limit gives way rather
than drop one.

## API

In `daw.api`, plain data only:

| Function | |
| --- | --- |
| `undo_tree()` | `{ current, root, saved, limit, pending, states }`; each state is `{ id, parent, children, redo, time, label, keys, name, keep, current, saved }`, oldest first. `time` is seconds since 1970; `pending` says an edit is open; `redo` is the child redo goes to |
| `undo_current()` | the current state's id |
| `undo_goto(id)` | go to a state; false if there is none |
| `undo_step(n)` | `n` states later in the order they were made (earlier when negative); the id gone to, or nil |
| `undo_travel(seconds)` | to the newest state made that long after (before, when negative) the current one; the id, or nil |
| `undo_name(name, id)` | name a state, the current one by default; nil or `""` removes the name; returns the id |
| `undo_keep(id, keep)` | keep a state from pruning, or let it go again |
| `undo_diff(a, b)` | what differs from `a` to `b` (`b` defaults to the current state, `a` to `b`'s parent): `{ from, to, same, project, tracks, devices, clips, notes, lanes, items }`, each kind `{ added, removed, changed }`, `project` a list of fields, `items` lines such as `~ device synth on track Bass: cutoff` |
| `undo_label(text)`, `undo_keys(text)` | what makes the open step (the first label given wins) and the keys typed; the runtime sets them from the key's or command's description |
| `checkpoint_dir()` | the folder, or nil for a project with no file |
| `checkpoint_write(name, id)` | write a state (the current one by default) and name it; `{ file, name, time, state }` |
| `checkpoint_list()` | `{ file, name, time }` for each, oldest first |
| `checkpoint_restore(file)` | a path from the list or a file name in the folder; the new state's id |
| `checkpoint_delete(file)` | |

`daw.undo()` and `daw.redo()` are unchanged. `undo_checkpoint()` is the older
call that closes the open undo step; it is not about checkpoints on disk.

Notes are compared within clips present in both states: a note at the same
start and pitch with something else different counts as changed, one that
moved counts as removed and added. Notes of clips that were added or removed
are not counted, only the clips.

`require("undotree")` has the Lua side: `tree()`, `rows(tree)` (the drawing),
`go(id)`, `travel(dir, amount, count)`, `mark_a(id)`, `toggle()`,
`clear_ab()`, `checkpoint(name)`, `items()`, `restore(item)`, `choose()`.

## Not done

- The tree is not saved: closing the program or opening another project
  starts it again. Checkpoints are what lasts.
- Labels name the key or command by its description (a command's own
  `label` option, else its description up to the first example). Edits made
  by scripts, timers or the control socket without a command are labelled
  `a change`.
- Moving notes is counted as a removal and an addition, and notes inside added
  or removed clips are not counted.
- Comparing by ear switches the whole project. There is no A/B of one track
  alone, and no crossfade at the switch.
- Vim's `:earlier 1f` (by file writes) and `:undolist` are not there; the
  window does both jobs.
