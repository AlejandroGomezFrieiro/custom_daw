<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 4: The piano roll and entering notes

*About ten minutes. In paw, with the tutor loaded: `:tutor 4`.*

The piano roll shows the notes of one clip: a row per pitch, with the names on the left, and time running to the right in steps of a sixteenth note. In normal mode you move about and change single notes; in insert mode the keyboard is a piano and every key enters a note and steps on.

The clip `tune` has three notes in its second bar. You will add to it.

## The idea

Moving: `h` `l` a step, `j` `k` a semitone, `J` `K` an octave, `w` `b` notes, `0` `$` the start and end of the clip. Changing the note under the cursor: `<CR>` adds or removes, `+` `-` length, `H` `L` move it, `<C-a>` `<C-x>` pitch, `[` `]` velocity, `gh` hear the pitch. Insert mode (`i`, or `a` after the note): `a w s e d f t g y h u j k` are C up to the next C, a capital stays in place for a chord, `1`-`9` set the note length in steps, `<Space>` is a rest, `<BS>` takes back, `z` `x` change octave, `<Esc>` leaves.

## If you know Vim

`<C-a>` and `<C-x>` add and subtract, as on numbers in Vim; here they move a note's pitch. Insert mode does not insert text: each key is a note.

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. The cursor is on the clip `tune`. Press `<CR>` (Enter) to open it in the piano roll.
   - ✓ The piano roll. The cursor is on E4 at the start of the clip.
2. `j` and `k` move a semitone down and up (`J` `K` an octave), and you hear each pitch. Press `k` three times to reach G4.
   - *Hint:* Watch the title row of the piano roll: it shows the pitch under the cursor.
   - ✓ G4: the name is in the title row and highlighted on the left.
3. `<CR>` adds a note at the cursor (or removes the one there). Press `<CR>`.
   - ✓ A short G4: one step, a sixteenth.
4. `+` makes the note under the cursor a step longer, `-` shorter. Press `+` three times.
   - ✓ Now it lasts a beat.
5. `<C-a>` moves the note up a semitone and `<C-x>` down. Press `<C-a>` twice.
   - *Hint:* `<C-a>` is Ctrl and a. The cursor must be on the note.
   - ✓ A4 now, and the cursor went with it.
6. Go a beat on with `4l`, and press `i` to start entering notes there.
   - ✓ INSERT at beat 2. The title row shows the octave (C4), the step and the velocity.
7. Digits set how many steps long the next notes are. Press `4` (a beat), then type `gfd` for G, F and E.
   - *Hint:* `a` is C, `s` D, `d` E, `f` F, `g` G, `h` A, `j` B, `k` the C above. `<BS>` takes the last one back.
   - ✓ A G F E, running into the E D C that was there.
8. `<Space>` is a rest: it steps on without a note. Press `<Space>` four times to step past the notes already there.
   - ✓ At the end of the clip, which grew a bar to make room.
9. A capital letter enters a note and stays, for chords. Type `AD` (C and E, staying), then `g` (G, stepping on).
   - *Hint:* Shift and a, shift and d, then a small g.
   - ✓ A C major chord.
10. `z` goes down an octave and `x` up. Press `z`, then `a` for a low C.
   - ✓ C3 under the chord.
11. Press `<Esc>` twice (out of insert mode, out of the piano roll), then `gs` and `<Space>` to listen; `<Space>` stops.
   - ✓ Your tune, over the drums.

## What you did

You moved by pitch and time, added and changed a note in normal mode, and entered a line and a chord in insert mode.

Previous: [Tracks, clips and notes](03-making.md) · [All lessons](README.md) · Next: [The grammar: operators, motions, text objects](05-grammar.md)
