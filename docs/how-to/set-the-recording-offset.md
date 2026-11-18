# How to set the recording offset

This guide shows you how to make recordings align with the song. paw moves
each take earlier by the latency that the audio system reports. Some
latency is not reported, and the recording offset corrects it. For the
rule, see [Recording](../reference/recording.md#recording-offset).

1. Connect an output of your interface to an input with a cable.
2. Select a track and set its input to that input channel with `I`.
3. Enable the metronome, and record some bars of the metronome on the
   track.
4. Zoom in on the start of a bar. Measure the time from the bar line to
   the first click in the recording, in milliseconds.
5. In `init.lua`, set the offset to that time:

   ```lua
   paw.transport.record_offset = 4.5
   ```

6. Start paw again and record the metronome again. The clicks now start on
   the bar lines.

If the clicks are early, use a smaller value. The offset can be negative.
