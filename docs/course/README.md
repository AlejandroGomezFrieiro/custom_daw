<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# The course

A course for the first days with the DAW, by doing. Each lesson takes about ten minutes, opens a small practice project of its own, and ends with something you made or changed and can hear. The same lessons run inside the DAW, where the tutor says what to do next and notices when you have done it:

```lua
daw.ext.load("extensions/tutor")   -- in ~/.config/daw/init.lua, or link the directory into ~/.config/daw/extensions
```

then `:tutor` in the DAW. These pages are made from the tutor's own lessons, so the two say the same. [keys.md](keys.md) is a page of keys to keep beside the keyboard.

| | Lesson | What it teaches |
| --- | --- | --- |
| 1 | [First steps: the screen, playing, quitting](01-first-steps.md) | You have played a song, moved the cursor, used the command line and seen where to find every key. |
| 2 | [Moving around, and why keys change meaning](02-moving.md) | Motions by step, clip, bar and track, with counts; and the same keys meaning other things in visual mode and in the piano roll. |
| 3 | [Tracks, clips and notes](03-making.md) | You made a track, gave it a name and an instrument, entered notes, repeated and deleted clips, and undid a change. |
| 4 | [The piano roll and entering notes](04-pianoroll.md) | You moved by pitch and time, added and changed a note in normal mode, and drew a line and a chord in insert mode. |
| 5 | [The grammar: operators, motions, text objects](05-grammar.md) | Operator plus motion (`dw`, `d2W`), operator plus text object (`dic`, `gcic`, `glic`), twice for tracks (`dd`), and `.` to repeat. |
| 6 | [The same grammar on notes](06-grammar-notes.md) | `dw`, `.`, `>in`, `yic` `p`, `cin`, `dd` and `/`: the grammar of lesson 5, on notes. |
| 7 | [Visual mode: select, then act](07-visual.md) | `v` and `V` with motions, then `x` `y` `~` or a count and `<C-a>`; `gv` to select again; the same in the piano roll. |
| 8 | [Yank, paste, registers and macros](08-registers.md) | `yic` and `p` with counts, named registers, `:registers`, `2u`, and a macro recorded with `qq` and played with `@q` and `@@`. |
| 9 | [Devices, parameters and plugins](09-devices.md) | The device panel, choosing and changing parameters, adding and bypassing a device, and where plugins' windows open. |
| 10 | [Mixing: faders, pan, buses, sends, automation](10-mixing.md) | The mixer's faders, pan, solo and mute; a bus with `:track.output`; a send; volume automation with `A`. |
| 11 | [Looping, marks and finding your way](11-loops.md) | `gL`, `glic` and `gl2W` for the loop, `gm` for the click, `/` to find, `ma` `'a` `''` to come and go. |
| 12 | [Recording audio and MIDI](12-recording.md) | `I` for the input, `r` to arm, `R` to record, `<Space>` to stop: an audio take and a MIDI take. |
| 13 | [Saving and rendering](13-saving.md) | `:w` to save, `[+]` for unsaved changes, `:render name.wav tail=2` to make a file, `:messages` for what was said. |
| 14 | [Finding any command or key](14-finding.md) | Key hints, `?`, `:commands`, Tab on the command line, `,,` and the `,f` pickers, and `K`. |
| 15 | [Making it your own: options, keys, commands](15-your-own.md) | An option, a mapping and a command, made live with `:lua`, and where to keep them. |
| 16 | [The bundled extensions](16-extensions.md) | pattern, musicops, sections, undotree, mixdiag, rpp and utau: each one thing. Their READMEs have the rest. |

Lessons 1 to 4 are the ground: the screen, moving, making tracks and notes. 5 to 8 are the grammar that the rest of the DAW is made of. 9 to 13 are the studio: devices, mixing, looping, recording, saving and rendering. 14 to 16 are about finding your own way: finding any key, making the DAW yours, and the extensions.
