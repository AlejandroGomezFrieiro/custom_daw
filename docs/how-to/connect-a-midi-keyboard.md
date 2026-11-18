# How to connect a MIDI keyboard

<!-- tags: midi-keyboard -->

This guide shows you how to play an instrument in paw from a MIDI
keyboard. It also shows how to check that paw sees the keyboard. It
assumes that paw runs with an audio device. paw opens the MIDI ports only with an audio
device, not with `--audio null`.

## Check that paw sees the keyboard

1. Connect the keyboard to the computer with its USB cable.
2. Type `:midi.inputs`. A window lists each MIDI port, for example
   `Keystation 49 MIDI 1`, with `open` next to it.
3. Press `Esc` to close the window.

If the keyboard is not in the list, type `:checkhealth audio`. If it says
"no MIDI inputs", connect the keyboard again, or start paw after you
connect it. paw finds ports that appear later, also while it runs.

## Play an instrument

1. Press `o` to add a track.
2. Press `a`, type `synth` and press `Enter`. You can also add a plugin
   (see [How to add a track with a virtual instrument](add-an-instrument-track.md)).
3. Press `r` to arm the track. A track plays the keyboard only when it is
   armed or when its monitor is on.
4. Play some keys. You hear the synth, and the meter of the track moves.

To hear the keyboard without a recording, press `<A-i>` in place of `r`.
This switches the monitor of the track on.

## Take one keyboard only

By default, a track plays the notes from all MIDI ports and all channels.

1. Select the track and press `I`. The list of the inputs opens.
2. Under MIDI, select the port of your keyboard and press `Enter`.
3. To take one channel only, press `I` again and select the channel.

You can also type `:track.midi Keystation ch=1`, with a part of the name
of the port.

To keep paw away from the other ports, type `:midi.select Keystation`.
paw then opens only the ports with that name.

To record what you play, see [How to record an audio take](record-an-audio-take.md).
The same steps record MIDI on a track that has no audio input.

To move faders and parameters with the knobs of the keyboard, see
[How to map a MIDI controller](map-a-midi-controller.md).

## See also

- [MIDI input](../reference/midi.md#midi-input): the ports, MIDI 2.0, ports that go away.
- [Recording](../reference/recording.md#the-input-of-a-track): the input of a track.
