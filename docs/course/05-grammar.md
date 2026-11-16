<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 5: The grammar: operators, motions, text objects

*About ten minutes. In paw, with the tutor loaded: `:tutor 5`.*

This is the heart of paw. Most editing is a short sentence: an operator (what to do) followed by a motion or a text object (what to do it to). `d` is delete, `w` is "to the next clip", so `dw` deletes up to the next clip. `ic` is "the clip I am in", so `dic` deletes this clip. A count says how many: `d2W` deletes two bars. Typing the operator twice takes whole tracks: `dd`. And `.` repeats the last change wherever the cursor is now.

The Beat track has four clips: kick, snare, fill, crash. Bass plays under them.

## The idea

Operators: `d` delete, `y` yank (copy), `c` change, `>` `<` move later and earlier, `=` snap to the grid, `gc` mute, `gl` loop. Motions: every key from lesson 2. Text objects: `ic` the clip, `ac` the clip and the gap after it, `ib` the bar, `il` the loop, `it` everything on the track, `ie` the entire project. Learn a few of each and you know their products: six operators and ten motions are sixty commands.

## If you know Vim

This is Vim's grammar, unchanged: operator, count, motion or text object; the operator twice for whole lines (tracks); `.` with a new count. `gc` is commenting out, here muting. `gl` (loop) is new. `c` empties the stretch and opens a fresh clip in insert mode.

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. The cursor is at the start of `kick`. `d` is the delete operator and `w` the motion to the next clip: press `dw`.
   - *Hint:* After `d` the status line says PENDING: the operator waits for its motion. `<Esc>` cancels it.
   - ✓ `kick` is gone: `dw` deleted from the cursor to where `snare` starts.
2. Press `u` to bring it back.
   - ✓ All four clips again.
3. A text object names a thing instead of a movement: `ic` is the clip under the cursor. Press `w` to go to `snare`, then `dic`.
   - ✓ `dic`: delete in clip. A gap is left where `snare` was.
4. `.` repeats the last change. Press `w` to go to `fill`, then `.` to delete it too.
   - ✓ `.` did `dic` again, on the clip under the cursor now.
5. Undo both: press `u` twice.
   - ✓ Back to four clips.
6. A count goes with the motion: `d2W` deletes two bars from the cursor. Press `0`, then `d2W`.
   - ✓ Two bars of Beat deleted; Bass is untouched, since the operator works on the cursor's track.
7. Press `u` to undo that.
   - ✓ Restored.
8. Other operators take the same motions and objects. `gc` mutes: press `gcic` to mute `kick`.
   - ✓ `kick` is muted (greyed). `gcic` again would unmute it.
9. Press `w` to go to `snare` and `.` to mute it the same way.
   - ✓ `.` repeats any change: deleting, muting, moving.
10. Typed twice, an operator takes whole tracks: `dd` deletes a track. Press `j` to go to Bass, then `dd`.
   - ✓ The Bass track is gone, and it is in the register.
11. `p` puts what was deleted back after the cursor: for a track, below it. Press `p`.
   - ✓ Bass is back, with its synth and clip. Deleting is cutting.
12. `gl` is the loop operator. Go up to Beat with `k`, put the cursor on `snare` with `0` and `w`, then press `glic`.
   - ✓ The loop is the snare clip: the ruler shows it.
13. Unmute `snare` with `gcic`, and press `<Space>` to hear the loop; `<Space>` stops.
   - ✓ The snare bar and the bass, round and round.

## What you did

Operator plus motion (`dw`, `d2W`), operator plus text object (`dic`, `gcic`, `glic`), twice for tracks (`dd`), and `.` to repeat.

Previous: [The piano roll and entering notes](04-pianoroll.md) · [All lessons](README.md) · Next: [The same grammar on notes](06-grammar-notes.md)
