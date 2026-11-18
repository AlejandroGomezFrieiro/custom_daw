# The paw manual

This is paw's manual, in four kinds of page: tutorials to learn paw by
doing, how-to guides for a task at hand, reference to look things up, and
explanation of why paw is as it is. In paw, `:help` shows the same pages
under the same headings; each extension has its own page besides
(`:help notation`).

## Tutorials

- [The course](tutorials/course/README.md): seventeen short lessons for the first days with paw, also inside paw as `:tutor`

## How-to guides

- [Running it](running.md): installing, building from source, options, audio devices, other machines

## Reference

- [Keys, by idea](reference/keys.md): every key on one page, to keep beside the keyboard
- [The terminal interface](terminal.md): keys, Ex, windows, text buffers, files, quickfix, the mouse, help, pickers, queries
- [The graphical frontend](window.md): every gesture of the window
- [Configuration](configuration.md): `init.lua`, options, the look, the status line
- [Input and recording](recording.md): inputs, monitoring, recording, takes
- [Editing, mixing and rendering](mixing.md): routing, automation, tempo, stretching, markers, MIDI controllers, export
- [Plugins and built-in devices](devices.md): plugins, the sandbox, built-in devices, devices in Lua
- [Live performance](live.md): the session view, slots and scenes
- [Harmony, completion and snippets](harmony.md): keys and chords, snippets, completion, several clips in the piano roll
- [Language servers and diagnostics](lsp.md): language servers, addresses, diagnostics, MIDI LSP
- [Scripting](scripting.md): the `paw` module, `paw ctl`, scripts and other programs
- [Extensions](extensions.md): what belongs in the core, what an extension can own
- [Lua API reference](reference/api.md): every function, made from the code
- [The control protocol](protocol.md): the socket's messages
- [What is missing](missing.md): what paw does not do yet

## Explanation

- [How it is put together](architecture.md): the crates, the threads, the kernel and its frontends
