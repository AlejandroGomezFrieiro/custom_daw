# The paw manual

The manual has four kinds of page. Tutorials teach paw with lessons that you
do. How-to guides give the steps for one task. Reference pages describe each
part of paw. Explanation pages tell why paw works as it does. In paw,
`:help` shows the same pages under the same four headings, and a page for
each extension (`:help notation`).

## Tutorials

- [The course](tutorials/course/README.md): seventeen short lessons for your first days with paw, also inside paw as `:tutor`

## How-to guides

- [Run paw](running.md): install paw, build it from the source, its options, audio devices, other computers
- [How to run the graphical window against a kernel on another machine](how-to/run-the-window-against-a-remote-kernel.md)
- [How to run the graphical window without a graphics card](how-to/run-the-window-without-a-graphics-card.md)
- [How to give an extension an editor in the graphical window](how-to/add-an-editor-to-the-window.md)

## Reference

- [Keys, by idea](reference/keys.md): all the keys on one page, to keep near the keyboard
- [The terminal interface](terminal.md): keys, Ex, windows, text buffers, files, the quickfix list, the mouse, help, pickers, queries
- [The graphical window](reference/window.md): its command line, each gesture, the panes and the views in windows of their own
- [The graphical window in Lua](reference/window-lua.md): `paw.frontend.act`, menus, bands, panes, views that paint
- [Configuration](configuration.md): `init.lua`, options, colors, the status line
- [Input and recordings](recording.md): inputs, input monitors, takes
- [Edit, mix and render](mixing.md): routes, automation, tempo, stretched clips, markers, MIDI controllers, export
- [Plugins and built-in devices](devices.md): plugins, the sandbox, built-in devices, devices in Lua
- [Live performance](live.md): the session view, slots and scenes
- [Harmony, completion and snippets](harmony.md): keys and chords, snippets, completion, many clips in the piano roll
- [Language servers and diagnostics](lsp.md): language servers, addresses, diagnostics, MIDI LSP
- [Scripts](scripting.md): the `paw` module, `paw ctl`, scripts and other programs
- [Extensions](extensions.md): what is in the core, what an extension can add
- [Lua API reference](reference/api.md): each function, made from the code
- [The control protocol](reference/protocol.md): the messages of the socket, scenes, seats, files and sound
- [Limits: what paw does not do yet](reference/limits.md): what paw does not do, and the known limits of what it does

## Explanation

- [About the architecture](explanation/about-the-architecture.md): the crates, the threads, the kernel and its frontends
- [About scenes: one view, two frontends](explanation/about-scenes.md): why the graphical window has no views of its own
