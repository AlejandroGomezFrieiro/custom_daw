# How to punch in over a part

This guide shows you how to record again over some bars, and keep the rest
of the take. It assumes that the track has an input and is armed. For each
rule, see [Recording](../reference/recording.md#punch-in-and-out).

1. Select the bars to record again in visual mode.
2. Press `gI`. The range shows red on the ruler.
3. To hear the song before the punch in, type `:preroll 2`.
4. Stop the song and press `R`. The song plays from two bars before the
   punch in.
5. Play. paw records only between the punch in and the punch out.
6. Stop the song. The new clip covers the range exactly.

To give the range by bar numbers, type `:punch 5 8`.

To record many takes of the range, also set the loop. Each time through
the range becomes a take (see
[How to record takes over a loop and comp them](record-takes-and-comp.md)).

To stop the punch, press `gI` again. paw keeps the range in the project for
the next time.
