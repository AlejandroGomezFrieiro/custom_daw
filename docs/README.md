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
- [About the key rule](explanation/about-the-key-rule.md): why a key means the same in every view
- [About seats](explanation/about-seats.md): many frontends on one instance, and a safe network connection
- [About the look of paw](explanation/about-the-look.md): color for attention, the color of a track, cells first
- [About the Nix build](explanation/about-the-nix-build.md): two layers, and why crane
- [About scenes: one view, two frontends](explanation/about-scenes.md): why the graphical window has no views of its own
