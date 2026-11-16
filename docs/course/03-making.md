<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 3: Tracks, clips and notes

*About ten minutes. In paw, with the tutor loaded: `:tutor 3`.*

A track holds clips on the timeline and a chain of devices: an instrument that turns notes into sound, then effects. A clip holds notes (a MIDI clip) or a recording (an audio clip). A new track is silent until it has an instrument.

In this lesson you add a track, give it a name and a synth, enter a few notes from the computer keyboard, and listen. There is a drum beat to play along to.

## The idea

Small letters in normal mode act on what is under the cursor: `o` opens a new track below (as `o` opens a new line in Vim), `a` adds a device, `i` inserts notes, `x` deletes the clip, `&` repeats it. `u` undoes and `<C-r>` redoes, so nothing you try here can do lasting harm.

## If you know Vim

`o` `O` add a track below and above, like lines. `i` opens the clip under the cursor (or a new one) in the piano roll in insert mode; the keys of the middle row then enter notes rather than text. `grn` renames, as in Neovim's LSP keys.

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. `o` adds a track below the one the cursor is on. Press `o`.
   - ✓ A new, empty track, and the cursor is on it.
2. Name it: press `grn`, clear the old name with `<C-u>`, type `Bass` and press `<CR>`.
   - *Hint:* `grn` asks on the command line, with the old name filled in. `<C-u>` is Ctrl and u. `<Esc>` cancels.
   - ✓ The track is called Bass.
3. A track is silent until it has an instrument. Press `a`, type `synth` and press `<CR>`.
   - *Hint:* `a` opens a list of every device; typing narrows it, `<CR>` takes the top one.
   - ✓ Bass has a synth.
4. `i` makes a clip at the cursor and opens it for entering notes: insert mode. Press `i`.
   - ✓ INSERT: the piano roll is open, and the title row shows the octave, the step and the velocity.
5. The middle row of letters is a piano: `a` C, `s` D, `d` E, `f` F, `g` G. Press `4` (each note a beat long), then type `asdfg`.
   - *Hint:* Notes step on by themselves. If one went wrong, `<BS>` steps back and removes it.
   - ✓ Five notes, C to G. The clip grew a bar to make room for the last one.
6. Press `<Esc>` to leave insert mode, and `<Esc>` again to go back to the arrange view.
   - ✓ Back in the arrange view, in NORMAL mode.
7. Press `<Space>` to hear your notes with the drums, and `<Space>` to stop.
   - ✓ That is your bass line.
8. `&` repeats the clip right after itself. Press `&` twice.
   - *Hint:* The cursor has to be on the clip: `0` goes to the start.
   - ✓ Three copies, one after another.
9. `u` undoes the last change and `<C-r>` (Ctrl and r) redoes it. Press `u`, then `<C-r>`.
   - ✓ Undone and redone: every key that changes the project is one step to undo.
10. `x` deletes the clip under the cursor. Press `x`.
   - ✓ Deleted. (`u` would bring it back.)
11. Listen to what you made: `gs` to the start, `<Space>` to play, `<Space>` to stop.
   - ✓ A bass line on a track of your own.

## What you did

You made a track, gave it a name and an instrument, entered notes, repeated and deleted clips, and undid a change.

Previous: [Moving around, and why keys change meaning](02-moving.md) · [All lessons](README.md) · Next: [The piano roll and entering notes](04-pianoroll.md)
