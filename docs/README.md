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
- [How to record a performance from the session view](how-to/record-a-performance-from-the-session-view.md)
- [How to map a MIDI controller](how-to/map-a-midi-controller.md)
- [How to write a language server](how-to/write-a-language-server.md)
- [How to write a snippet](how-to/write-a-snippet.md)
- [How to write a completion source](how-to/write-a-completion-source.md)

## Reference

- [Keys, by idea](reference/keys.md): all the keys on one page, to keep near the keyboard
- [The terminal interface](terminal.md): keys, Ex, windows, text buffers, files, the quickfix list, the mouse, help, pickers, queries
- [The graphical frontend](window.md): each gesture of the graphical window
- [Configuration](configuration.md): `init.lua`, options, colors, the status line
- [Input and recordings](recording.md): inputs, input monitors, takes
- [Edit, mix and render](mixing.md): routes, automation, tempo, stretched clips, markers, MIDI controllers, export
- [Plugins and built-in devices](devices.md): plugins, the sandbox, built-in devices, devices in Lua
- [The session view](reference/session-view.md): slots, scenes, launch rules, keys and commands
- [MIDI controllers](reference/learn.md): bind knobs, faders and pads to controls
- [Harmony](reference/harmony.md): the chords and keys that paw reads, providers, theory functions, voicings, ranges
- [Snippets](reference/snippets.md): keys, the starting set, the fields of a snippet
- [Completion](reference/completion.md): suggestions, their keys and options, the fields of a source
- [Several clips in the piano roll](reference/roll-clips.md): context notes, edit many clips, `paw.roll_clips`, layers
- [Language servers and diagnostics](reference/language-servers.md): keys, addresses, subjects, server configs, the protocol, MIDI LSP
- [Scripts](scripting.md): the `paw` module, `paw ctl`, scripts and other programs
- [Extensions](extensions.md): what is in the core, what an extension can add
- [Lua API reference](reference/api.md): each function, made from the code
- [The control protocol](reference/protocol.md): the messages of the socket
- [Limits: what paw does not do yet](reference/limits.md): what paw does not do, and the known limits of what it does

## Explanation

- [About the architecture](explanation/about-the-architecture.md): the crates, the threads, the kernel and its frontends
- [About the session view](explanation/about-the-session-view.md): why the engine times a launch, and why a render needs a capture
- [About language servers](explanation/about-language-servers.md): the four layers, addresses with ids, subjects, LSP
- [About the harmony reading](explanation/about-the-harmony-reading.md): how paw finds chords and keys, and why providers can replace it
