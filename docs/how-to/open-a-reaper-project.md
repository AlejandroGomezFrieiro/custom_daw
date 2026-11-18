# How to open a REAPER project, and save one for REAPER

This guide shows you how to move a project between REAPER and paw. The
`rpp` extension reads and writes REAPER projects (`.rpp` files). For each
command, see the [rpp README](../../extensions/rpp/README.md).

## Load the extension

Type `:ext.load rpp`. To load it at each start, see
[How to load an extension](load-an-extension.md).

## Open a REAPER project

1. Type `:e song.rpp`, with the path of the REAPER project. The tracks
   and the clips appear in the arrange view.
2. If a page opens, read it. It lists what paw could not bring across,
   for example plugins that paw does not have. Press `q` to close it.
3. To keep the project, save it as a project of paw: `:w song.json`.

If the MIDI tracks are silent because their instrument stayed in REAPER,
type `:rpp.import song.rpp instrument=synth`. paw gives each of these
tracks a `synth`.

To add the tracks of a REAPER project to the open project, type
`:rpp.import song.rpp merge=true`.

## Save a project for REAPER

1. Type `:w song.rpp`. paw writes the project as a REAPER project.
2. A page lists what paw could not write, for example the built-in
   devices of paw. Press `q` to close it.
3. Open `song.rpp` in REAPER.

`:w song.rpp` does not change the project file of paw. The project stays
`song.json`.
