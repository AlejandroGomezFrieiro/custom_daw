# projdiff

What changed between two versions of a project, and merging two versions that
changed apart. A project is JSON in a stable form, so this works on what is in
it (tracks, devices, clips, notes, automation, the tempo map, markers) and not
on lines.

```lua
daw.ext.load("extensions/projdiff")   -- or put the directory in ~/.config/daw/extensions
```

## Seeing what changed

`:Pdiff` opens the changes as text with folds, in a window over the project:

```
base.json → now: 5 changes
▾ ~ track 1 "Lead" -> "Lead 2"
    ~ name: "Lead" -> "Lead 2"
  ▾ ~ clip 3 "riff"
    ▾ ~ notes +1 ~1
        + note 3 G4 at 2, 1 long, velocity 100
        ~ note 2 F4: pitch E4 -> F4
```

| Command | What it compares |
| --- | --- |
| `:Pdiff` | the project's file, as saved, with the project now |
| `:Pdiff HEAD~2` | that revision of the project's file in git, with the project now |
| `:Pdiff #7` | undo state 7 (the numbers of the undo tree) with the project now |
| `:Pdiff snap:name` | a snapshot with the project now |
| `:Pdiff other.json` | another project file with the project now |
| `:Pdiff a b` | the first with the second (any of the above; `now` is the project now) |
| `:Pdiff.qf …` | the same, as a quickfix list, one entry for each change |
| `:Psnapshot name` | keep the project as it is, to compare with later |
| `:Pmerge [file]` | settle the conflicts a merge left (see below) |
| `:Pgit` | how to set git up, with this machine's paths |

A snapshot is a checkpoint (see extensions/undotree): written beside the
project when it has a file, and so kept for good; kept for the session
when it has not.

In the window: `j` `k` move (`Ctrl-d` `Ctrl-u` by ten, `gg` `G` to the ends),
`za` `zo` `zc` open and close a fold (`Tab` too, and a click on its arrow),
`zR` `zM` open and close all, `]c` `[c` go to the next and previous change,
`Enter` closes the window and puts the cursor where the change is (the
track, the clip, the note, the parameter, the lane, the marker, the tempo
map), `Q` or `gq` sends every change to the quickfix list (`:copen`, `]q`),
`q` closes. A short diff opens unfolded; a long one folds what is deeper
than the tracks and clips.

Keys: `<leader>Pd` is `:Pdiff`, `<leader>Pm` is `:Pmerge`, `<leader>Ps`
asks for a snapshot's name.

What a diff names: tracks added, removed, renamed and moved; a track's fader,
pan, routing, sends and launcher slots; devices added and removed, their
parameters, bypass, offline state, side-chain and a plugin's saved state;
clips added, removed, moved, resized, renamed, and their fades, stretch and
audio file; the notes of a clip as a count (`notes +2 -1 ~3`) with a line for
each (30 of them, then "more"); controllers; automation lanes and their
points; the tempo and time signature and their changes; markers and regions;
the rest of the project's `meta`. Anything the model gains later shows as a
`field: old -> new` line without this extension being told.

## Git

Projects are text, so git keeps them, but a line diff of JSON says little
and a merge of two lines of it breaks. The extension has a script for git's
two hooks, run by paw itself without a window:

```
# .gitattributes
*.json diff=paw merge=paw          # or the names of your project files
```

```
# git config (in the repository), or ~/.gitconfig
[diff "paw"]
  textconv = daw --clean --no-plugins --no-listen --audio null -l /path/to/extensions/projdiff/git.lua textconv
[merge "paw"]
  name = paw project merge
  driver = daw --clean --no-plugins --no-listen --audio null -l /path/to/extensions/projdiff/git.lua merge %O %A %B %L %P
```

`:Pgit` prints these with the right path. After that `git diff`, `git log
-p` and `git show` print a project as a line for each track, device, clip,
note, lane point and marker, with a note's pitch named:

```
-    note id=1 length=1 start=0 velocity=100 pitch=60(C4)
+    note id=1 length=1 start=0 velocity=100 pitch=62(D4)
```

and `git merge` merges two branches of a project by what is in it. A merge
keeps both sides' changes when they are to different things: different tracks,
different clips, different notes of one clip, different parameters of one
device, tempo changes at different beats. Items both sides added under the
same id (a track, a clip, a note, a marker) are both kept; the second gets a
number nothing else has, and what points at it (outputs, sends, side-chains,
automation) follows.

What is left is a real conflict: the same value changed two ways, or changed
on one side and removed on the other. The merged project holds ours there,
loads and plays, and lists each conflict in `meta.merge_conflicts` (its
place, what it was, ours and theirs). git reports the file as conflicted and
paw says so when the project is opened. `:Pmerge` shows them:

| Keys | |
| --- | --- |
| `j` `k` | move between conflicts |
| `co` | take ours |
| `ct` | take theirs |
| `cb` | take what it was before both |
| `cO` `cT` | all of them, ours or theirs |
| `q` | close |

Each choice writes the file; a project open from that file (and not changed
since) is read again from it. When the last is settled, `git add` the file.

## From Lua

```lua
local pd = require("projdiff")
local from, to = pd.file("a.json"), pd.file("b.json")
local tree = pd.diff.diff(from.project, to.project)   -- { children, count }
pd.diff.lines(tree)                                    -- the text of the view
pd.diff.entries(tree)                                  -- { address, text } for daw.qf
pd.text.text(to.project)                               -- the text git shows
local merged, conflicts = pd.merge.files(base, ours, theirs)
pd.merge.resolve(merged, conflicts[1], "theirs")
daw.api.project_file_text(merged)                      -- the file's text, as paw writes it
```

`daw.api.undo_project(id)` (the core's) is a state of the undo tree as the
project file holds it; `pd.version("#7")` and `pd.version("snap:x")` turn the
words of `:Pdiff` into one.

## Notes

The project file is written the same every time (see "The file is the same
every time" in docs/mixing.md), so a diff of a file saved again is empty and
one change is a small diff. The project's name is taken from the file's name
the first time it is saved, so a copy saved under another name differs in
that one line.

The views are drawn in cells, like every extension's view that has no
painted twin, so the graphical frontend draws them as the terminal does
(docs/extensions.md, "One interface, both frontends").
