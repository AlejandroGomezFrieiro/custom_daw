# Project files

<!-- tags: saving safety-copies recover autosave project-file project-folder midi2 collect on_external_change -->

A project is a folder of files. A project can also be one JSON file. This
page describes the files of a project, how paw saves them, keeps safety
copies and recovers work. For why paw saves this way, see
[About project files](../explanation/about-project-files.md). For the
steps, see [How to recover lost work](../how-to/recover-lost-work.md).

## The project folder

```text
song/
├── project.toml            name, tempo, meter, tempo map, order of the tracks, transport
├── meta.json               the data of extensions (`paw.project.meta`), if there is some
├── screen.json             the tabs and windows that the project opens with
├── .gitattributes          *.midi2 diff=paw-midi2
├── master/                 the master track, as a track folder
├── tracks/
│   └── Keys/               one folder for each track, with the name of the track
│       ├── track.json      the track and its clips, without the notes
│       ├── devices.json    the chain and its parameters
│       ├── 1-synth.state   the state of a plugin, as the plugin gives it
│       ├── automation/volume.json
│       └── clips/riff.midi2
├── media/take1.wav         sound files
└── unused/                 files that the project does not use now
```

- The project's file is `song/project.toml`. `:e song`, `:open song`
  and `paw song` open the folder.
- A track folder and a clip file have the name of the track and of the
  clip. Letters, digits, `-`, `_` and `.` stay; paw changes other
  characters to `-`. Two of the same name get `-2`, `-3`.
- An automation file has the name of what it automates: `volume.json`,
  `pan.json`, or the device and the parameter: `1-synth-wave.json`.
- The JSON files have their keys in alphabetical order.
- `track.json` names each clip file by its path in the folder. It names a
  file outside the folder by its full path, or from the home folder as
  `~/…`.
- Clips with the same notes, controller moves and length share one file.
- `.gitattributes` is written when the folder has none.

## Save

| Command | Effect |
| --- | --- |
| `:w song` | Save the project as the folder `song`. A name with no extension is a folder. |
| `:w song.json` | Save the project in one JSON file. |
| `:w` | In the piano roll: write the file of the clip. In the device panel: write the files of the chain. Also the `track.json` and `project.toml` if they changed. Elsewhere: write all the files. |
| `:wa`, `:wall` | Write all the files of the project. |
| `:ls` | Also list the files of the project. `+` marks a file that is different from the file on the disk. |

- paw writes only the files that are different from the files on the
  disk.
- paw writes each file next to its place, writes it to the disk, and
  renames it over the old file. It writes `project.toml` last.
- `:w` of a folder that has other files and no `project.toml` does not
  save: name a folder in it.
- A file that the project does not use now goes to `unused/` at the same
  path. A file that is there already stays, and the new one gets `-2`.
  paw never deletes a file from `unused/`.
- A file with the same bytes as a new file moves to the place of the new
  file (a renamed track).
- The project is saved when no file is different from the disk. An undo
  back to the saved state makes the files the same again.
- `:q` refuses to quit with changes that are not saved. `:q!` quits without
  them.

A project in one JSON file:

- paw keeps the file as it was before the save next to it, as
  `song.json.bak`.
- A `.bak` names media relative to the project, as the project does, so it
  opens with its media.

## MIDI clip files

A MIDI clip is a MIDI 2.0 Clip File (`SMF2CLIP`, M2-116-U).

- A beat has 61440 ticks. paw rounds the time of a note and of a
  controller move to a tick.
- Notes are MIDI 2.0 note-on and note-off messages with velocities of 16
  bits and their attribute. Controller moves are MIDI 2.0 messages with
  values of 32 bits.
- The `meta` of a note, its id (when the ids are not 1, 2, 3 in order),
  and the start of a note before the start of the clip are in Flex Data
  text that starts with `paw:`.
- End of Clip is at the length of the clip.
- paw also reads MIDI 1.0 messages in a clip file, and a file with a
  different number of ticks to a beat. It tells what it left out.
- paw keeps a velocity at 7 bits. A clip file from another program with
  velocities of 16 bits gets velocities of 7 bits in paw.

| Command or function | Effect |
| --- | --- |
| `paw clip cat riff.midi2` | Print the clip as text, one note or controller move on each line. |
| `:e riff.midi2`, `paw riff.midi2` | Open the clip alone, on a track with the synth, in the piano roll. `:w` writes it back to its file. |
| `:import riff.midi2` | Put the clip on the track of the cursor, at the cursor. The clip refers to the file. |
| `paw.api.midi2_read(path)` | `{ notes, controls, length, skipped }` of a clip file. |
| `paw.api.midi2_write(path, clip)` | Write `{ notes, controls, length }` as a clip file. |
| `paw.api.midi2_text(path)` | The text that `paw clip cat` prints. |

To show clip files as text in `git diff`, set the driver one time:

```sh
git config --global diff.paw-midi2.textconv "paw clip cat"
```

## Files outside the folder

- A clip from a clip file outside the folder refers to the file:
  `paw.clip(id).source` is its path. A save keeps the path and writes no
  copy.
- The first edit of the notes makes them the project's own, in the same
  undo step. paw says this one time:
  "riff is now this project's own copy (was ~/library/riff.midi2)".
  `paw.clip(id).origin` keeps the path, and `K` shows it.
- An undo of that edit makes the clip refer to the file again.
- A file that paw cannot find leaves the clip empty and offline. A save
  keeps its path.

| Command | Effect |
| --- | --- |
| `:collect` | Make every clip from outside the project's own, and copy every sound file from outside into `media`. The next save writes the clip files into the folder. |

## Changes from outside paw

paw watches the folders of a project folder, and the folders of the files
outside it that the project uses. A save of paw is not a change. Changes
close together (a `git checkout`) are one change. paw acts at the next
key, as `paw.opt.on_external_change` tells:

| Value | Effect |
| --- | --- |
| `"ask"` (default) | Ask: `y` reads the files again, another key keeps the version of paw. |
| `"reload"` | Read the files again when the project has no changes that are not saved. Else ask. |
| `"keep"` | Keep the version of paw, and say so. The next save writes over the files. |

- To read the files again is one undo step. The parts that did not change
  keep their plugins.

| Function | Effect |
| --- | --- |
| `paw.api.project_changed_files()` | The files that changed outside paw, not acted on yet. |
| `paw.api.project_reload()` | Read the project folder again, as one undo step. |
| `paw.api.project_keep_changes()` | Keep the version of paw. |
| `paw.api.project_files()` | Each file of a project folder: `{ path, modified, what, track, clip }`. |
| `paw.api.project_save_files(paths)` | Write these files, and the files that they name that are not on the disk. |

## A second paw on the same project

`paw song` when a paw on this computer has `song` open does not open a
second copy. The terminal joins the running paw as a new seat, as
`paw attach` does (see [About seats](../explanation/about-seats.md)). `:detach` leaves.

## The same file each time

paw writes a project in one file as JSON. The fields are in the order of the model,
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
