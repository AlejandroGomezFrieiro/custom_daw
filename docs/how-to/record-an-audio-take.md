# How to record an audio take

This guide shows you how to record a guitar or a voice on a track. It
assumes that your audio interface is connected. For each rule, see
[Recording](../reference/recording.md).

1. If paw does not use your interface, type `:audio.input UR22`, with a
   part of the name of your interface.
2. Select the track, and press `I` in the arrange view.
3. Under audio, select the channel of your instrument, for example
   `UR22mkII · 1`. For a stereo source, select a pair.
4. Play your instrument. The track header shows the level at the input.
5. Press `r` to arm the track. You now hear the input through the devices
   of the track.
6. To get a count-in, type `:countin 1`.
7. Put the cursor where the take must start, and press `R`.
8. Play. Press `<Space>` to stop. The take is now a clip on the track.

To hear the input without a recording, press `<A-i>`. This switches the
monitor of the track.

If you record a MIDI keyboard, do not select an audio input. In the input
list, select the MIDI port and channel. A track with no audio input
records MIDI.

If the project is not saved, the files go to
`~/.local/share/paw/recordings`. When you save the project, paw links or
copies them into `media` next to the project file.

If the take is late against the song, set the recording offset (see
[How to set the recording offset](set-the-recording-offset.md)).
