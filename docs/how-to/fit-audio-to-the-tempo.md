# How to fit audio to the tempo

This guide shows you how to make an audio loop or a recording play in time
with the song. For each command, see
[Stretched and looped clips](../reference/stretch.md).

## A loop at a known tempo

1. Put the loop on a track, and move the cursor to it.
2. Type `:clip.tempo 100`, with the tempo of the loop. The clip now plays
   at the tempo of the song, and follows each tempo change.
3. To repeat it, type `:clip.loop`, then drag the end of the clip out.

## A recording that is not in time

1. Move the cursor to the first beat in the recording, and press `gw` to
   put a warp marker there.
2. Do the same on each beat that is not in time.
3. Type `:clip.warp snap`. paw moves each marker to the grid, and
   stretches the sound between the markers.
4. To move one marker by hand, put the cursor on the beat and type
   `:clip.warp move`.

## A clip to a given length

1. Make a time selection over the bars to fill.
2. Type `:clip.stretch selection`.

If drums or speech sound smeared, type `:clip.stretch_mode percussive`.
For held or melodic sound, use `tonal`.

If a voice shifted in pitch sounds too small or too large, type
`:clip.formants on`.

In the graphical window, hold Alt and Shift, and drag the right edge of
the clip.
