# Narrowing to a group

<!-- tags: narrowing scope narrow -->

In a large project, you can narrow a tab to one group: the tab shows only
that group and the tracks inside it, at any depth. This is similar to a
subproject in REAPER. The module is `paw.scope`.

## Commands

| Keys, command | Effect |
| --- | --- |
| `:narrow Strings`, `zn` | Open a tab with the group and its tracks. `zn`: the group at the cursor, on its header or on one of its tracks. If the group has a tab, go to it. |
| `:widen`, `zw` | Close the narrowed tab and go to the tab that it came from. |
| `gt` | Go between the tabs, as for any tabs. |
| `:set scope_rest=mute` | Set what the rest of the song does (see below). |

## In a narrowed tab

- It is the same project, with one undo tree. Undo in any tab undoes an
  edit made in the narrowed tab.
- These see only the tracks of the group: the arrange view, the mixer, the
  device panel, the session view, `paw://tracks`, the pickers, the track
  motions (`gg`, `G`, `j`) and the Ex ranges. `t1` is the group, `t*` and
  `%` are its tracks, and `:g` and `:s` look only in them.
- The fold of the group is open.
- The status line shows `narrowed Strings`, and the tab has the name of the
  group.
- A track that you add goes into the group.
- Several groups can be open at the same time, each in its own tab.
- The graphical window shows the tab as the terminal does.

## The rest of the song

`paw.opt.scope_rest` sets what the rest of the song does while a narrowed
tab is in front. No value changes the project.

| Value | Effect |
| --- | --- |
| `play` | Default. The rest plays, as a reference. |
| `mute` | The rest is silent, as with a solo of the group. The tracks that the sound of the group goes through still play. The mutes and solos of the project do not change. |
| `frozen` | paw renders each part of the rest in the background (each full group, and each track outside a group), and plays the files, so that their devices rest. A part that you edit plays live until paw renders it again. paw releases the files when the tab is not in front. |

## Lua

| Function | Result |
| --- | --- |
| `paw.scope.narrow(group)` | Narrow to a group. |
| `paw.scope.widen()` | Close the narrowed tab. |
| `paw.scope.current()` | The scope of the current tab. |
| `paw.scope.tracks()` | The tracks that the current tab sees. |
| `paw.scope.contains(track)` | True if the current tab sees the track. |

A tab keeps its scope in its `scope` field. `paw.api.engine_audible(ids)`
and `paw.api.engine_hold(track, file)` give `mute` and `frozen` (see
[The audio engine](engine.md#scripts-and-the-engine)).
