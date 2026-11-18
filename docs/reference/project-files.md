# Project files

<!-- tags: saving safety-copies recover autosave project-file -->

A project is one JSON file, with a `media` folder next to it. This page
describes how paw saves a project, keeps safety copies and recovers work.
For why paw saves this way, see
[About project files](../explanation/about-project-files.md). For the
steps, see [How to recover lost work](../how-to/recover-lost-work.md).

## Save

- A save writes a temporary file next to the project and writes it to the
  disk. Then it gives the file the name of the project, and writes the
  directory to the disk. So the file on the disk is always the old project or the new
  project, complete.
- paw keeps the file as it was before the save next to it, as
  `song.json.bak`.
- A `.bak` names media relative to the project, as the project does, so it
  opens with its media.
- `:q` refuses to quit with changes that are not saved. `:q!` quits without
  them.

## The same file each time

paw writes a project as JSON. The fields are in the order of the model,
the maps are by key, and the numbers have the fewest digits that read
back exactly. So a save of a project with no change writes the same bytes, and
one change gives a small diff.

| Function | Result |
| --- | --- |
| `paw.api.project_file_text(file)` | The text of a project given as data, written the same way. It refuses a project that would not open. |
| `paw.api.undo_project(id)` | A state of the undo tree, as a project file holds it. |

`extensions/projdiff` uses both: a diff and a three-way merge of projects,
and the drivers for version control.

## Safety copies

| Option | Default | Effect |
| --- | --- | --- |
| `paw.opt.autosave` | `60` (`0` with `--clean`) | Seconds between safety copies. 0: no copies. |

- Every `paw.opt.autosave` seconds, paw copies a project with changes that
  are not saved to `~/.local/state/paw/recovery`.
- paw removes the copy when you save the project, or close it with no
  changes.
- A copy that a session left after a bad end shows at the next start.
  `:recover` opens it, with the name of the project that it is a copy of.
- A panic writes a safety copy before paw stops, and says where the copy
  is (see [The audio engine](engine.md#a-device-that-fails)).
- A take is in the safety copy from its start (see
  [Recording](recording.md#files)).

## Damaged projects

If a project does not open (it is cut short, or damaged), the message
tells what can replace it. `:recover` lists its newest safety copy and its
`.bak` first. Each opens with the name of the damaged project, not saved,
so `:w` puts it back. If you start paw with such a project on the command
line, paw starts, with that message.

## `:recover`

| Command | Effect |
| --- | --- |
| `:recover` | List the safety copies, the `.bak` files of a damaged project, and takes that no clip uses. Select one to open or add it. |
| `:recover 1` | Open entry 1. |
| `:recover 1 offline` | Open entry 1 with its plugins offline (see [Plugins](plugins.md#offline-devices)). |

## Scripts

| Function | Effect |
| --- | --- |
| `paw.api.project_shelve()` | Put the open project aside, complete (undo tree, playhead, changed flag), and open an empty project. |
| `paw.api.project_unshelve()` | Close that project and bring back the first project as it was. |
| `paw.api.project_shelved()` | True if a project is aside. |

The shelf is for tools that need their own tracks without a change to the
work of the person. The [doctor](../../extensions/doctor) extension uses
it.

The suite runs `tests/*.lua` and `extensions/*/tests.lua`, and gives each
the helpers of the suite.
