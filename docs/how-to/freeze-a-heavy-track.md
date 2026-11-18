# How to freeze a heavy track

This guide shows you how to stop a heavy instrument from using the CPU,
and continue to mix. For each rule, see
[Freezing](../reference/freezing.md).

1. Move the cursor to the track, or to the header of a group.
2. Type `:freeze`. paw renders the track and plays the file. The header
   shows `F`.
3. Continue to mix. The fader, pan, mute and sends of the track still
   work.
4. To change the notes or the devices, type `:unfreeze`. Edit, then type
   `:freeze` again.

If you edit a frozen track, paw asks if it must unfreeze the track. paw
keeps the edit if you answer no, and you hear it after `:unfreeze`.

If the sound has a long tail, add `tail=6` for six seconds after the end.

If you change the tempo, type `:unfreeze`, then `:freeze`. paw does not
render the file again by itself.

To freeze several tracks, give a range: `:t2,t4freeze`.

To also render the fader and the pan, use `:track.bounce` instead. It
makes a new audio track and mutes the original track.
