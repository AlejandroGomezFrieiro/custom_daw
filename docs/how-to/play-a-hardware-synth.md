# How to play a hardware synth from a track

This guide shows you how to send the notes of a track to a synth on a MIDI
port. It assumes that paw runs with an audio device. For each form and
field, see [MIDI](../reference/midi.md#midi-output).

1. Connect the synth to the computer.
2. Select the track and press `I`.
3. Under MIDI out, select the port and the channel. Or type
   `:track.midi_out UM-ONE 2`.
4. Play the song. The synth plays the notes and controllers of the track,
   in time with the other tracks.

If the synth supports MPE, and you want the bends of each note, type
`:track.midi_out UM-ONE 2 mpe`.

If the synth supports MIDI 2.0, and the kernel has `CONFIG_SND_SEQ_UMP`,
paw sends MIDI 2.0 automatically.

To play a software synth that reads a MIDI port, make a port of paw:
`paw.midi.open_output("To Surge")`. Connect the synth to `paw out: To
Surge`, and select `To Surge` as the MIDI out of the track.

A render does not send MIDI. To keep the sound of the synth, record its
audio output on a track.
