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
- [How to record an audio take](how-to/record-an-audio-take.md)
- [How to record takes over a loop and comp them](how-to/record-takes-and-comp.md)
- [How to punch in over a part](how-to/punch-in-over-a-part.md)
- [How to set the recording offset](how-to/set-the-recording-offset.md)
- [How to render a song](how-to/render-a-song.md)
- [How to render stems](how-to/render-stems.md)
- [How to freeze a heavy track](how-to/freeze-a-heavy-track.md)
- [How to work on one group of a large project](how-to/work-on-one-group.md)
- [How to duck a track under the kick](how-to/duck-a-track-under-the-kick.md)
- [How to route the outputs of a drum plugin](how-to/route-the-outputs-of-a-drum-plugin.md)
- [How to write automation with the faders](how-to/write-automation-with-the-faders.md)
- [How to fit audio to the tempo](how-to/fit-audio-to-the-tempo.md)
- [How to play a hardware synth from a track](how-to/play-a-hardware-synth.md)
- [How to relink lost media](how-to/relink-missing-media.md)
- [How to recover lost work](how-to/recover-lost-work.md)
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
- [The graphical window](reference/window.md): its command line, each gesture, the panes and the views in windows of their own
- [The graphical window in Lua](reference/window-lua.md): `paw.frontend.act`, menus, bands, panes, views that paint
- [Configuration](configuration.md): `init.lua`, options, colors, the status line
- [Audio devices](reference/audio-devices.md): the input and output devices, PipeWire, latency, a lost device, test backends
- [Recording](reference/recording.md): track inputs, monitoring, count-in, punch, pre-roll, files, import
- [Takes](reference/takes.md): takes, comping, take lanes
- [MIDI](reference/midi.md): controller moves, the event list, MIDI input and output, MPE, MIDI files
- [The audio engine](reference/engine.md): threads, the state of the engine, delay compensation, failed devices
- [Tempo and time signatures](reference/tempo.md): the tempo map, its commands, the timebase of audio clips
- [Routing: groups, VCAs, sends and side-chains](reference/routing.md): groups, linked faders, VCAs, outputs, sends, side-chains, output pairs
- [Narrowed tabs](reference/narrowing.md): a tab of one group, the rest of the song
- [Frozen tracks](reference/freezing.md): frozen and held tracks
- [Automation](reference/automation.md): automation modes, writing with the controls
- [Stretched and looped clips](reference/stretch.md): stretch, pitch, warp markers, tempo, loops
- [Markers and regions](reference/markers.md): markers, regions, their keys and commands
- [Render](reference/render.md): `:render`, formats, tags, stems, bounce
- [Media files and audio clips](reference/media.md): paths, relink, sample rates, long files, fades, clip operations
- [Project files](reference/project-files.md): saves, the same file each time, safety copies, `:recover`
- [Devices](reference/devices.md): the built-in devices, wet/dry and output gain, presets
- [Plugins](reference/plugins.md): formats, scan, editors, processes, status, offline devices
- [Lua devices](reference/lua-devices.md): the fields of a device in Lua, the block, MIDI, helpers, reload
- [The session view](reference/session-view.md): slots, scenes, launch rules, keys and commands
- [MIDI controllers](reference/learn.md): bind knobs, faders and pads to controls
- [Harmony](reference/harmony.md): the chords and keys that paw reads, providers, theory functions, voicings, ranges
- [Snippets](reference/snippets.md): keys, the first set, the fields of a snippet
- [Completion](reference/completion.md): suggestions, their keys and options, the fields of a source
- [Several clips in the piano roll](reference/roll-clips.md): context notes, edit many clips, `paw.roll_clips`, layers
- [Language servers and diagnostics](reference/language-servers.md): keys, addresses, subjects, server configs, the protocol, MIDI LSP
- [Scripts](scripting.md): the `paw` module, `paw ctl`, scripts and other programs
- [Extensions](extensions.md): what is in the core, what an extension can add
- [Lua API reference](reference/api.md): each function, made from the code
- [The control protocol](reference/protocol.md): the messages of the socket, scenes, seats, files and sound
- [Limits: what paw does not do yet](reference/limits.md): what paw does not do, and the known limits of what it does

## Explanation

- [About the architecture](explanation/about-the-architecture.md): the crates, the threads, the kernel and its frontends
- [About scenes: one view, two frontends](explanation/about-scenes.md): why the graphical window has no views of its own
- [About the audio engine](explanation/about-the-audio-engine.md): many cores and one result, delay compensation, failed devices, long files
- [About time and tempo](explanation/about-time-and-tempo.md): the tempo map, and which clock each thing keeps
- [About groups and VCAs](explanation/about-groups-and-vcas.md): why groups and VCAs are usual tracks, narrowing, freezing
- [About time stretch](explanation/about-stretching.md): the two methods, formants, why paw stretches a file one time
- [About project files](explanation/about-project-files.md): saves, the same bytes, relative paths, safety copies
- [About the session view](explanation/about-the-session-view.md): why the engine times a launch, and why a render needs a capture
- [About language servers](explanation/about-language-servers.md): the four layers, addresses with ids, subjects, LSP
- [About the harmony reading](explanation/about-the-harmony-reading.md): how paw finds chords and keys, and why providers can replace it
- [About MIDI 2.0 in paw](explanation/about-midi-2.md): fractions, controllers for each note, ports, MPE
- [About the plugin sandbox](explanation/about-the-plugin-sandbox.md): one process for each plugin, and what it costs
