<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 6: The same grammar on notes

*About ten minutes. In the DAW, with the tutor loaded: `:tutor 6`.*

Everything from the last lesson works in the piano roll, with notes in place of clips and pitches in place of tracks. `w` goes to the next note, so `dw` deletes up to it; `in` is the note under the cursor, `ic` every note of the clip; `dd` deletes a whole row, which here is every note of one pitch; `.` repeats; `y` and `p` copy.

The clip `riff` is open in the piano roll: C D E G E D C, a beat each.

## The idea

Learn the grammar once, use it everywhere: the operators are the same (`d` `y` `c` `>` `<` `=` `gl`), the motions are the same keys (`w` `b` `e` `0` `$` `W` `B`, `j` `k` by pitch), and the text objects are `in` (note), `ib` (bar) and `ic` (the whole clip). A note belongs to the stretch it starts in, so `dw` from the middle of a gap deletes nothing.

## If you know Vim

`in` stands where `iw` would. `dd` takes a whole row, which is a pitch. `/d4` searches for a pitch by name, `n` goes on to the next.

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. The cursor is on the first note. `w` goes to the next note, wherever its pitch is. Press `w` twice.
   - ✓ On E4, the third note.
2. `dw` deletes from the cursor up to the next note. Press `dw`.
   - ✓ E4 is gone; the cursor stays in the gap.
3. Press `w` to go to G4, and `.` to delete it the same way.
   - *Hint:* From inside a gap `dw` reaches the next note's start, and a note belongs to where it starts, so nothing goes. Go onto a note first.
   - ✓ `.` repeated `dw` from the new place.
4. Press `u` twice to have both notes back.
   - ✓ The riff is whole again.
5. `in` is the note under the cursor. `>in` moves it a step later, and the cursor goes with it. Press `>in`, then `.`.
   - *Hint:* The cursor must be on G4 (beat 4). `u` takes back a move that went wrong.
   - ✓ G4 is two steps late now: a little push before the beat.
6. `yic` yanks every note of the clip. Then `$` goes to the end of the clip and `p` pastes them there. Press `yic`, `$`, `p`.
   - ✓ The riff twice, and the clip grew to hold it.
7. `c` changes: `cin` deletes the note under the cursor and starts insert mode in its place. Press `^` (the first note), `cin`, then `7k` and `4l`, and `<Esc>`.
   - *Hint:* `7k` moves the new note up to G, `4l` makes it a beat long.
   - ✓ The riff starts on G now.
8. `/` searches: `/d4` and `<CR>` go to the next D4. Then `dd` deletes every note of that pitch. Press `/d4`, `<CR>`, `dd`.
   - ✓ No D4 left anywhere in the clip.
9. Press `<Esc>` to go back to the arrange view and `<Space>` to listen; `<Space>` stops.
   - ✓ Your changed riff.

## What you did

`dw`, `.`, `>in`, `yic` `p`, `cin`, `dd` and `/`: the grammar of lesson 5, on notes.

Previous: [The grammar: operators, motions, text objects](05-grammar.md) · [All lessons](README.md) · Next: [Visual mode: select, then act](07-visual.md)
