# About project files

A project holds hours of work. It must survive a crash during a save and
a move to a different disk. It must also survive a merge in version
control, and a second program that changes one of its files. This page tells why paw keeps a
project as a folder of files, and how it writes them. For the details,
see [Project files](../reference/project-files.md) and
[Media files and audio clips](../reference/media.md).

## A project is a folder of files

Most audio workstations keep a project in one file. REAPER writes one
text file, Ardour one XML file, and a project of Bitwig is one binary file.
Version control then sees one large file that changes at each save. Two
people who change two different tracks change the same file, and a merge
must take that file apart.

paw keeps a project as a folder. The settings that you can edit by hand
(the tempo, the meter, the order of the tracks) are in `project.toml`.
Each track has a folder of its own, with the name of the track. In it,
`track.json` holds the track and its clips, `devices.json` holds the
chain, and each clip has a file of its own. A file has a name that a
person can read, with the usual extension: `.toml`, `.json`, `.midi2`,
`.wav`. paw adds no extension of its own. So other programs and the
tools of the shell can read each file.

The rule is: each part that can be a file is a file, while a save and an
open stay fast. One change then changes one or two small files. A
`git diff` shows what changed in which track, and a merge of two changes
to two tracks needs no help.

A track folder has the name of the track, and it gets the new name when
you rename the track. A clip file has the name of the clip. Version
control then shows a rename as a rename, because the bytes of the files do
not change.

## MIDI clips are MIDI files

A MIDI clip is a MIDI 2.0 Clip File (`.midi2`), as the MIDI Association
specifies it. paw holds notes and controllers at the resolution of MIDI
2.0, and the clip file holds the same resolution. So a clip goes to its
file and back with no loss. Other programs that read MIDI 2.0 can read the
clips of a paw project without paw.

A clip file is binary. For `git diff`, `paw clip cat` prints a clip as
text, one note on each line. paw writes a `.gitattributes` file that
tells git to use it. `:checkhealth` tells you how to set git for this.

A Standard MIDI File (`.mid`) is MIDI 1.0. paw reads it and writes it
for exchange with other programs. MIDI 1.0 goes into MIDI 2.0 with no
loss. The other direction loses resolution: a value of 32 bits becomes a
value of 7 bits, and a controller of one note has no place. `:export`
tells you what it rounded and what it left out.

## The same bytes for the same project

paw writes the JSON files with the keys in order, and each number with
the fewest digits that read back exactly. So a save of a project that did
not change writes the same bytes, and one change gives a small diff.

paw compares each file with the file on the disk, and writes only the
files that changed. A save after one edit is then fast, even for a large
project. The time of each file that did not change stays the same.

## A save is all or nothing for each file

If a program writes over a file and the power fails during the write,
the file is half old and half new: it is damaged. paw writes each new file
next to its place and writes it to the disk. Then it renames it over the
old file. A rename is atomic on the file system. So after a crash, each
file is the complete old file or the complete new file. paw writes
`project.toml` last, so it never names a file that is not complete.

## paw never deletes your files

A save does not delete a file that the project no longer uses. It moves
the file to the `unused` folder of the project, at the same path. A clip
that you removed is in `unused/tracks/<track>/clips`. paw never empties
`unused`. You decide when to delete it.

When a file has the same bytes as a file that the save needs at a
different path, paw moves the file there. This is what happens when you
rename a track.

## Repeats share one file

When you copy a part, the two clips have the same notes. The project
writes their notes to one file, and both clips name it. When you change
one of the two, it gets a file of its own at the next save.

## Files from outside the folder

A clip or a sound file can come from a file outside
the project folder. An example is a library of loops. The project
names the file and keeps no copy, so many projects can use one library.

The first edit of such a clip makes a copy that is the project's own.
paw tells you this one time on the message line, and the copy remembers
the file that it came from. An undo of the edit returns to the file
outside. `:collect` copies every file from outside into the folder, for
a project that you send to another person.

A file that paw cannot find does not stop the project. Its clip stays,
empty and marked offline, and a save keeps its path.

## Relative paths

A project names the files in its folder by a path relative to the folder.
So you can move or copy the folder. If paw cannot find a sound file, it
looks for the file before it asks you. It looks in the folder of the
project, by the last parts of the old path, and next to other files that
it found.

## A project in one file

A path that ends in `.json` saves the project in one file. paw uses this
form for its safety copies and for the states of the undo history.
`extensions/projdiff` uses it to compare and merge two versions of a
project.

## Safety copies

A save protects the work that you saved. Safety copies protect the work
that you did not save. paw copies a changed project to a recovery folder
at intervals, and also when paw panics. A take writes its WAV header every
two seconds, so a power loss leaves a valid file. `:recover` brings all of
this back from one list.

## Why recordings of an unsaved project go elsewhere

A project with no folder has no `media` folder. paw records into a shared
recordings folder, and at the first save it links or copies the files into
`media` in the project folder. The original files stay, because earlier
undo steps can still use them.
