# About project files

A project file holds hours of work. It must survive a crash during a save,
a move to a different disk, and a merge in version control. This page
tells how paw writes its project files for these cases. For the details,
see [Project files](../reference/project-files.md) and
[Media files and audio clips](../reference/media.md).

## A save is all or nothing

If a program writes over a file and the power fails during the write, the
file is half old and half new: it is damaged. paw writes a new file next
to the project, writes it to the disk, and then renames it over the
project. A rename is atomic on the file system. So after a crash, the file
is the old project or the new project, complete, never a mix. paw also
keeps the previous version as a `.bak` file, for the case where the new
version has a problem.

## The same bytes for the same project

paw writes the fields in a fixed order, the maps by key, and each number
with the fewest digits that read back exactly. So a save of a project that
did not change writes the same bytes, and one change gives a small diff.
Version control can then store projects efficiently, and
`extensions/projdiff` can show a diff and merge two versions of a project.

## Relative paths for media

A project names the files inside its folder by a relative path, so you can
move or copy the folder. When a file is missing, paw looks for it before
it asks you: in the folder of the project, by the last parts of its old
path, and next to other files that it found. A missing file does not stop
the project from opening: its clips stay, silent and marked offline, and a
save keeps the old path. So a project that you open on a computer without
the samples does not lose them.

## Safety copies

A save protects the work that you saved. Safety copies protect the work
that you did not save. paw copies a changed project to a recovery folder
at intervals, and also when paw panics. A take writes its WAV header every
two seconds, so a power loss leaves a valid file. `:recover` brings all of
this back from one list.

## Why recordings of an unsaved project go elsewhere

A project with no file has no `media` folder. paw records into a shared
recordings folder, and at the first save it links or copies the files into
`media` next to the project. The original files stay, because earlier undo
steps can still use them.
