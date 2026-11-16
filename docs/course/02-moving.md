<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 2: Moving around, and why keys change meaning

*About ten minutes. In paw, with the tutor loaded: `:tutor 2`.*

In the arrange view a track is a line and time runs along it, a beat to a grid step. A clip on a track is like a word on a line. The keys that move the cursor are called motions, and they come in families: small steps, clips, bars, the ends of things, other tracks. A number typed first repeats a motion.

The same key can mean different things: in a different mode (normal, visual, insert), or in a different view (the arrange view, the piano roll, the mixer). The status line always says which mode you are in, and the view with the keyboard has a brighter frame or highlight.

## The idea

Motions: `h` `l` a grid step, `w` `b` `e` clips (next start, this start, this end), `W` `B` bars, `0` `^` `$` the start of the project, the first clip, the end of the last clip, `j` `k` tracks, `gg` `G` the first and last track, `5|` bar 5. A count goes in front: `4l`, `2W`, `3j`. Modes: NORMAL for moving and acting, VISUAL for selecting (`v`), INSERT for entering notes (`i`), PENDING while an operator waits for its motion. `<Esc>` returns to NORMAL.

## If you know Vim

`hjkl`, `w` `b` `e`, `W` `B`, `0` `^` `$`, `gg` `G`, counts and `|` are all here. Differences: `w` goes to clip starts (there is no WORD), `W` `B` are bars, `0` is the start of the project, `^` the first clip, `|` and `:5` take a bar number, not a column or a line.

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. The cursor is on the Bass track at the start. `l` moves it right one grid step (a beat), `h` left. Press `l` three times.
   - ✓ Three beats on: the clock at the top left of the arrange view says 1.4.00, bar 1 beat 4.
2. A number before a motion repeats it. Press `4l` to go four beats on.
   - *Hint:* Type the 4 and then the l. If you went elsewhere, `0` goes to the start and `3l` back to beat 3.
   - ✓ Beat 7, near the end of the clip `verse`.
3. `0` goes back to the start of the project. Press `0`.
   - ✓ Back at the start.
4. A clip is like a word: `w` jumps to the start of the next clip on the track. Press `w`.
   - ✓ On `chorus`, which starts at beat 12 (bar 4).
5. `e` goes to the end of the clip and `b` back to its start. Press `e`, then `b`.
   - ✓ `w` `b` `e`: next start, this start, this end.
6. `W` and `B` move by bars (four beats here). Press `2W` to go two bars on.
   - ✓ Bar 6 (beat 20).
7. `$` goes to the end of the track's last clip (and `^` to its first clip). Press `$`.
   - ✓ At the end of `outro`, where the song ends.
8. Tracks are lines: `G` goes to the last track and `gg` to the first. Press `G`.
   - ✓ On Pad, the last track. `3G` would go to track 3.
9. `5|` goes to bar 5 (typing `:5` and `<CR>` does the same). Press `5|`.
   - *Hint:* `|` is the bar key, usually shift and backslash.
   - ✓ Bar 5, where the pad comes in.
10. Now the same keys in another mode. Press `v`: the status line says VISUAL, and moving stretches a selection. Press `l` twice to stretch it.
   - ✓ In visual mode `l` still moves, but it also selects. Lesson 7 is about what to do with a selection.
11. `<Esc>` always brings you back to NORMAL. Press `<Esc>`.
   - ✓ NORMAL again.
12. And in another view: `<CR>` (Enter) on a clip opens it in the piano roll. Press `<CR>` on the pad clip.
   - *Hint:* The cursor must be on a clip: `5|` on the Pad track puts it there.
   - ✓ The piano roll has the keyboard now.
13. Here the rows are pitches, so `k` goes up a semitone instead of a track. Press `k` twice (you hear each pitch).
   - ✓ Same key, different view, different meaning: but still 'up'.
14. `<Esc>` leaves the piano roll. Then `gp` puts the playhead at the cursor and `<Space>` plays from there; `<Space>` again stops.
   - *Hint:* `<S-CR>` (shift and Enter) plays from the cursor in one go, where the terminal can tell it from Enter.
   - ✓ You played the song from bar 5, where the melody comes in.

## What you did

Motions by step, clip, bar and track, with counts; and the same keys meaning other things in visual mode and in the piano roll.

Previous: [First steps: the screen, playing, quitting](01-first-steps.md) · [All lessons](README.md) · Next: [Tracks, clips and notes](03-making.md)
