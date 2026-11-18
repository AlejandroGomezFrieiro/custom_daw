# The paw manual

The manual has four kinds of page. Tutorials teach paw with lessons that you
do. How-to guides give the steps for one task. Reference pages describe each
part of paw. Explanation pages tell why paw works as it does. In paw,
`:help` shows the same pages under the same four headings, and a page for
each extension (`:help notation`).

## Tutorials

- [The course](tutorials/course/README.md): seventeen short lessons for your first days with paw, also inside paw as `:tutor`

## How-to guides

- [How to install paw with Nix](how-to/install-paw.md): the package, without the dev shell
- [How to build and run paw from the source](how-to/build-paw-from-source.md): the dev shell, the demo song, the example configuration
- [How to choose the audio devices](how-to/choose-audio-devices.md): in paw, at the start, in `init.lua`
- [How to configure paw](how-to/configure-paw.md): `init.lua`, options, colors, commands, keys, events
- [How to change the status line](how-to/change-the-status-line.md): sections and components in `init.lua`
- [How to add a picker](how-to/add-a-picker.md): a list to choose from, with a key
- [How to work on paw from another computer](how-to/work-from-another-computer.md): attach over the network or SSH, send files, hear the sound
- [How to run the tests](how-to/run-the-tests.md): the Lua suite, the Rust tests, the tests of the graphical window
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
- [How to load an extension](how-to/load-an-extension.md): a bundled extension, your own, or one from Nix
- [How to drive paw from an agent](how-to/drive-paw-from-an-agent.md): let a coding agent or an assistant edit a project

## Reference

- [Keys, by idea](reference/keys.md): all the keys on one page, to keep near the keyboard
- [Motions, operators and modes](reference/grammar.md): the keys that the arrange view and the piano roll share
- [The key rule](reference/key-rule.md): the meaning of each key in every view, the leaders, the classic keys
- [The arrange view](reference/arrange-view.md): its keys, waveforms, lanes as rows, the tempo lane, take lanes
- [The piano roll](reference/piano-roll.md): its keys, insert mode, several clips, suggestions
- [The device panel](reference/device-panel.md): its keys
- [The mixer](reference/mixer-view.md): its strips and keys
- [The curve editor](reference/curve-editor.md): lanes, parameters, controllers and the tempo map as curves
- [The command line](reference/cmdline.md): completion, `:set`, unsaved work, messages
- [Ex commands](reference/ex.md): ranges, `:s` and `:g`
- [Windows, buffers and tabs](reference/windows.md): splits, tabs, layouts, narrowed tabs
- [Lists edited as text](reference/lists-edited-as-text.md): `paw://tracks`, `paw://sends`, devices, markers
- [The file manager](reference/file-manager.md): folders as text and as a tree
- [The quickfix list](reference/quickfix.md): Problems, location lists, `:cdo`
- [Pickers](reference/pickers.md): every picker, its keys, matching, audition, the Lua API
- [Search the text of the project](reference/grep.md): `:vimgrep`, `paw.grep`
- [Structural queries](reference/queries.md): `:select`, `:query`, `paw.query`
- [Help](reference/help.md): `:help`, tags, `:helpgrep`
- [The mouse](reference/mouse.md): each gesture in the terminal
- [The terminal screen](reference/screen.md): the parts of the screen, the bottom line, colors
- [Pictures in the terminal](reference/pictures.md): pixels in terminals that show images
- [The status line](reference/status-line.md): sections, components, `paw.statusline`
- [Options](reference/options.md): every option of `paw.opt`
- [The graphical window](reference/window.md): its command line, each gesture, the panes and the views in windows of their own
- [The graphical window in Lua](reference/window-lua.md): `paw.frontend.act`, menus, bands, panes, views that paint
- [The programs and their options](reference/programs.md): `paw`, `paw-gui`, `paw-mcp`, environment variables
- [Files that paw keeps](reference/state-files.md): configuration, state, cache, recent projects
- [The Nix package](reference/nix-package.md): the outputs of the flake and the checks
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
- [The Lua interface](reference/scripting.md): the `paw` module, its layers and units, and the pages below
- [Project objects in Lua](reference/lua-objects.md): tracks, devices, clips, notes, attributes, the transport, tempo, automation
- [Commands, keys and options in Lua](reference/lua-commands.md): `paw.command`, ranges, `paw.ex`, `paw.keymap`, `paw.option`
- [Views and buffers in Lua](reference/lua-views.md): views, roles, buffer types, text buffers, the pointer, curves, layers
- [Addresses, diagnostics and lists in Lua](reference/lua-addresses.md): `paw.address`, `paw.diagnostic`, `paw.qf`, `paw.lsp`, queries
- [Timers, programs and other modules in Lua](reference/lua-other.md): timers, helper programs, seats
- [Events](reference/events.md): every event and its payload
- [Scripts and `paw ctl`](reference/ctl.md): `paw -l`, `paw ctl`, `paw attach`, `paw doctor`
- [Extensions](reference/extensions.md): the bundled extensions, files, loading, manifests, what an extension owns, health checks
- [Pictures in the terminal](reference/pictures.md): strips, `paw.plot`, and what a frontend does with strips
- [Lua API reference](reference/api.md): each function, made from the code
- [The control protocol](reference/protocol.md): the messages of the socket, scenes, seats, files and sound
- [Limits: what paw does not do yet](reference/limits.md): what paw does not do, and the known limits of what it does

## Explanation

- [About the architecture](explanation/about-the-architecture.md): the crates, the threads, the kernel and its frontends
- [About the key rule](explanation/about-the-key-rule.md): why a key means the same in every view
- [About seats](explanation/about-seats.md): many frontends on one instance, and a safe network connection
- [About the look of paw](explanation/about-the-look.md): color for attention, the color of a track, cells first
- [About the Nix build](explanation/about-the-nix-build.md): two layers, and why crane
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
- [About the core and extensions](explanation/about-core-and-extensions.md): where the line is, why, and how far an extension goes
- [About MIDI as the truth](explanation/about-midi-as-the-truth.md): why the notes are the truth, and where extensions keep their data
- [About seats](explanation/about-seats.md): many people in one instance, and the state of each
