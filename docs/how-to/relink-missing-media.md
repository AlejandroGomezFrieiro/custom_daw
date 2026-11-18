# How to relink lost media

<!-- tags: relink-missing-media -->

This guide shows you how to find the sound files of a project after you
move them. For each command, see
[Media files and audio clips](../reference/media.md).

1. Open the project. A message lists the files that paw cannot find. Their clips show
   "offline".
2. Type `:media.relink`. paw lists these files.
3. Select a file, then select the file that it is now. paw looks for the
   other lost files next to it.
4. If paw still cannot find some files, type `:media.relink` again and select
   "Search a directory". Select the directory.
5. Save the project. The new paths go into the project file.

In the graphical window, select File → Sound files, then the entry that
finds the lost files.

To give a directory on the command line, type `:media.relink ~/samples`.

To keep a project complete for a move to another computer, type
`:media.collect`. paw copies each file from outside the project folder
into `media`, and the project uses the copies. To copy each new import,
set `paw.opt.copy_imports = true`.
