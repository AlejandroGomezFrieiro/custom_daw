<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 7: Visual mode: select, then act

*About ten minutes. In paw, with the tutor loaded: `:tutor 7`.*

Sometimes it is easier to see what you are about to change before you change it. Visual mode turns that round: first select, with the motions you know, then press an operator, and it acts on the selection.

`v` selects a stretch of time (and `j` `k` stretch it across tracks), `V` whole tracks, and in the piano roll `<C-v>` a rectangle of pitches and time. The three tracks here have four one-bar clips each.

## The idea

In visual mode motions stretch the selection, `o` jumps to its other end, and an operator (`d` `y` `c` `>` `<` `gc` `gl`) or one of the selection keys acts on it: `x` delete, `p` replace it with the register, `~` mute, `J` join clips, `<C-a>` `<C-x>` transpose (with a count: `12<C-a>` an octave). `gv` selects the last selection again. `<Esc>` leaves without doing anything.

## If you know Vim

`v` `V` `<C-v>`, `o`, `gv` and operators on a selection are Vim's. A count typed in visual mode before `>` `<` or `<C-a>` is the amount, as in Vim. In the arrange view `v` stretched with `j` `k` is already a block of time on some tracks; `V` whole tracks are Vim's whole lines.

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. Press `v` to start selecting (the status line says VISUAL), then `W` to stretch the selection over the first bar.
   - ✓ The first bar of Drums is selected.
2. `j` stretches it down to the next track. Press `j`.
   - ✓ The first bar of Drums and Bass.
3. Now act on it: `x` deletes the selection. Press `x`.
   - ✓ Deleted from both tracks, and back in NORMAL.
4. Press `u` to undo it.
   - ✓ Back.
5. `V` selects whole tracks. Press `V`, `j` to take Drums and Bass, and `y` to yank (copy) them.
   - *Hint:* `<Esc>` leaves visual mode if it went wrong; then `gg` and start again.
   - ✓ Two tracks are in the register.
6. `G` goes to the last track and `p` pastes the tracks below it. Press `G`, then `p`.
   - ✓ Five tracks: copies of Drums and Bass at the bottom.
7. Press `u` to take the copies away again.
   - ✓ Three tracks.
8. `gv` selects what was selected last: the two tracks. Press `gv`, then `~` to mute them.
   - ✓ Drums and Bass are muted: their `M` flags are lit. On whole tracks `~` mutes the tracks; on a stretch of time, the clips in it.
9. Press `gv` and `~` again to unmute them.
   - ✓ `~` switches muting on and off.
10. In the piano roll too. Press `3G` to go to Keys and `<CR>` to open its first clip.
   - ✓ The A minor chord of `k1`.
11. `v` selects a stretch of time at every pitch. Press `v`, then `12<C-a>` to move everything that starts in it up an octave.
   - *Hint:* Type 1, 2, then Ctrl and a, while the status line still says VISUAL.
   - ✓ The chord is an octave higher. A count in visual mode is how much.
12. Press `<Esc>` to go back to the arrange view, and `<Space>` to listen; `<Space>` stops.
   - ✓ The first chord rings out an octave up.

## What you did

`v` and `V` with motions, then `x` `y` `~` or a count and `<C-a>`; `gv` to select again; the same in the piano roll.

Previous: [The same grammar on notes](06-grammar-notes.md) · [All lessons](README.md) · Next: [Yank, paste, registers and macros](08-registers.md)
