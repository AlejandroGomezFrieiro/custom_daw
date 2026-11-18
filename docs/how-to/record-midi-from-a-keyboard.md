# How to record MIDI from a keyboard

This guide shows you how to record notes that you play on a MIDI keyboard.
It assumes that the keyboard is connected to the computer. For each rule,
see [Recording](../reference/recording.md) and [MIDI](../reference/midi.md).

## Prepare the track

1. Press `o` to add a track.
2. Press `a` to add an instrument. Type a part of its name, for example
   `Synth`, and press `Enter`.
3. Press `I`. Type a part of the name of the keyboard, and press `Enter`.
   If you do not choose a port, the track takes MIDI from all the ports.
4. Press `r` to arm the track. Play some keys. You hear the instrument.

If the list does not show the keyboard, type `:midi.inputs`. The page
shows each MIDI port that paw finds, and if it is open.

## Record a take

1. Move the cursor to where the take starts. Press `gp` to move the
   playhead to the cursor.
2. Press `R`, and play.
3. Press `<Space>` to stop. The take is a new MIDI clip on the track.
4. To edit the notes, press `Enter` on the clip. The piano roll opens.

Each take is a new clip. If you record again over a clip, the new clip is
on top of the old clip.

## Merge a take into the clip

1. Record the new take over the clip, as above.
2. Keep the cursor in the bar of the two clips, and type `:j`. paw merges
   the clips of that bar into one clip, with the notes of both.

If the clips cover more than one bar, give the bars: `:5,8j` merges the
clips in bars 5 to 8.

## Record over a loop

1. Move the cursor to the first bar of the part. Type `gl4W` to loop four
   bars from the cursor.
2. Press `gp`, then press `R`.
3. Play the part again each time round the loop.
4. Press `<Space>` to stop. The clip over the loop has a take for each time
   round. The last take plays.

To choose among the takes, see
[How to record takes over a loop and comp them](record-takes-and-comp.md).
