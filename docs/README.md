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
- [How to record an audio take](how-to/record-an-audio-take.md)
- [How to record takes over a loop and comp them](how-to/record-takes-and-comp.md)
- [How to punch in over a part](how-to/punch-in-over-a-part.md)
- [How to set the recording offset](how-to/set-the-recording-offset.md)
- [How to record a performance from the session view](how-to/record-a-performance-from-the-session-view.md)
- [How to map a MIDI controller](how-to/map-a-midi-controller.md)
- [How to write a language server](how-to/write-a-language-server.md)
- [How to write a snippet](how-to/write-a-snippet.md)
- [How to write a completion source](how-to/write-a-completion-source.md)
- [How to write a device in Lua](how-to/write-a-device-in-lua.md)
- [How to fix a plugin editor that does not work](how-to/fix-a-plugin-editor.md)
- [How to open a project without its plugins](how-to/open-a-project-without-its-plugins.md)

## Reference

- [Keys, by idea](reference/keys.md): all the keys on one page, to keep near the keyboard
- [The terminal interface](terminal.md): keys, Ex, windows, text buffers, files, the quickfix list, the mouse, help, pickers, queries
- [The graphical frontend](window.md): each gesture of the graphical window
- [Configuration](configuration.md): `init.lua`, options, colors, the status line
- [Audio devices](reference/audio-devices.md): the input and output devices, PipeWire, latency, a lost device, test backends
- [Recording](reference/recording.md): track inputs, monitoring, count-in, punch, pre-roll, files, import
- [Takes](reference/takes.md): takes, comping, take lanes
- [MIDI](reference/midi.md): controller moves, the event list, MIDI input and output, MPE, MIDI files
- [Edit, mix and render](mixing.md): routes, automation, tempo, stretched clips, markers, MIDI controllers, export
- [Devices](reference/devices.md): the built-in devices, wet/dry and output gain, presets
- [Plugins](reference/plugins.md): formats, scan, editors, processes, status, offline devices
- [Lua devices](reference/lua-devices.md): the fields of a device in Lua, the block, MIDI, helpers, reload
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
- [About MIDI 2.0 in paw](explanation/about-midi-2.md): fractions, controllers for each note, ports, MPE
- [About the plugin sandbox](explanation/about-the-plugin-sandbox.md): one process for each plugin, and what it costs
