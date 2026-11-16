<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 14: Finding any command or key

*About ten minutes. In the DAW, with the tutor loaded: `:tutor 14`.*

Nobody remembers every key. The DAW tells you what you can do at every point: stop half way through a key sequence and it lists what can follow; `?` lists every key of the view you are in; `:` runs any command by name, with Tab to complete it; and pickers find a command, a key, a track or a clip from a few letters of its name.

Every key is a command with a name, so whatever you can do with a key you can also type, and whatever you find by name you can map to a key of your own.

## The idea

Key hints appear when you pause after the start of a sequence (`g`, `,`, `d`, `"`). `?` is the list of keys for the focused view. `:commands` lists every command with what it does. `,,` (or `,fc`) picks a command, `,fk` a key, `,ft` a track, `,fl` a clip, `,fa` a device, `,fm` a mark, `,fr` a register, `,fp` any picker. In a picker, typing narrows the list (letters in order, not necessarily together), `<C-n>` `<C-p>` move, `<CR>` chooses, `<Esc>` cancels. `K` describes the clip and track under the cursor.

## If you know Vim

Hints are which-key's, built in. The pickers are Telescope's way: fuzzy, with `<C-n>` `<C-p>`. `:` completes with Tab and keeps a history (`<Up>`).

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. Press `g` and wait: after half a second a box lists every key that can follow `g`. Then press `<Esc>` to drop it.
   - *Hint:* Wait without pressing anything until the box appears.
   - ✓ Any half-typed command shows what can come next: try `,` or `d` or `"` some time.
2. `:commands` lists every command and what it does. Type `:commands` and `<CR>`, look, and `q` to close it.
   - ✓ Every key you have learned runs one of those commands.
3. Tab completes command names. Press `j` to go to Bass, type `:track.vol`, press `<Tab>` (it becomes `track.volume`), then `<Space>`, `-6` and `<CR>`.
   - ✓ Bass is at -6 dB: `track.volume` is the command behind `+` and `-`.
4. `,,` opens a picker of every command: type a few letters and `<CR>` runs the one on top. Press `,,`, type `metro` and `<CR>`.
   - ✓ The metronome is on: you ran `transport.metronome` without knowing its name or its key.
5. `,fk` finds a key by what it does. Press `,fk`, type `loop` to see every key about looping, then `<Esc>`.
   - ✓ `gL`, `gl`, `il`: and `<CR>` would have typed the key for you.
6. `,ft` goes to a track by name. Press `,ft`, type `dr` and `<CR>`.
   - ✓ On Drums. `,fl` does the same for clips.
7. `K` describes what is under the cursor: the clip, the track, its devices. Press `K`, then `q` to close.
   - ✓ `K` is the quickest way to see a track's devices, sends and automation.
8. Listen with the click: `<Space>`, then `<Space>` to stop and `gm` to switch the click off.
   - ✓ The quieter bass, with the click you found by name.

## What you did

Key hints, `?`, `:commands`, Tab on the command line, `,,` and the `,f` pickers, and `K`.

Previous: [Saving and rendering](13-saving.md) · [All lessons](README.md) · Next: [Making it your own: options, keys, commands](15-your-own.md)
