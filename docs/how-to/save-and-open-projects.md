# How to save, back up and open projects

This guide shows you how to save a project, keep copies of it, and open it
again. For each rule, see [Project files](../reference/project-files.md)
and [Files that paw keeps](../reference/state-files.md).

## Save a project

1. The first time, give the project a name and a place:
   `:w /home/ana/songs/demo/demo.json`. Use one folder for each song.
   Give the full path the first time. A name alone, for example
   `:w demo.json`, saves into the folder where you started paw.
2. After that, type `:w` to save. The status line shows the name of the
   project, and a mark when there is work that is not saved.
3. To save and quit, press `ZZ`.

paw puts the recordings of the project into the `media` folder next to
the project file. An imported sound file stays in its own folder. To
copy each import into `media` too, set `paw.opt.copy_imports = true`.

In the graphical window, choose File → Save, and File → Open recent.

## Open a project

- To open a project that you used recently, press `,fR`. Type a part of
  its name and press `Enter`.
- To open the second project in that list, type `:recent 2`.
- To open a project by its path, type `:e /home/ana/songs/demo/demo.json`.
- To open an example song or a practice project of the lessons, type
  `:example demo-song`. `Tab` completes the names.

If the open project has work that is not saved, paw does not open the
other project. Type `:w` to save the work first. To drop the work, type
`:e!` with the path. To open the project again as you saved it last, type
`:e!` alone.

## Where a name alone goes

When a project has a file, a name without a folder goes next to the
project. For example, `:w take2.json` and `:render mix.wav` put the files
in the folder of the song. Before the first save, a name alone goes to the
folder where you started paw.

- To see the folder, type `:pwd`.
- To use a different folder, type `:cd` and the folder, as in Vim:
  `:cd ~/songs/demo`. `:cd -` returns to the folder before it, and `:cd`
  alone goes to your home folder.

To open the last project each time paw starts, put this line in your
`init.lua`:

```lua
paw.opt.reopen_last = true
```

## Back up a project

paw keeps three kinds of copies for you:

- Each `:w` keeps the file as it was before, as `demo.json.bak`.
- Every 60 seconds, paw writes a safety copy of the work that is not
  saved. To make copies more often, type `:set autosave 30`.
- After a crash, `:recover` opens the safety copies. See
  [How to recover lost work](recover-lost-work.md).

To keep a backup on a different disk, copy the whole folder of the song.
The folder holds the project file and its `media` folder. If the project uses sound files
from other folders, type `:media.collect` first. paw then copies these
files into `media`.
