# How to add an audio track for a microphone or a guitar

<!-- tags: audio-track -->

This guide shows you how to add a track for a microphone or a guitar on
your audio interface. It also shows how to hear the input through paw. It
assumes that paw uses your interface as its input. If it does not, type
`:audio.input UR22`, with a part of the name of your interface.

1. In the arrange view, press `o` to add a track.
2. Press `grn`, type a name, for example `Guitar`, and press `Enter`.
3. Press `I`. The list of the inputs of the track opens.
4. Under audio, select the channel where the instrument is connected, for
   example `UR22mkII · 1`, and press `Enter`.
   For a stereo source, such as a keyboard with two outputs, select a pair: `UR22mkII · 1/2`.
5. Play or sing. The header of the track shows the level at the input.
6. Press `<A-i>` to switch the monitor on. You now hear the input through
   the devices of the track.

You can also type `:track.input 1` or `:track.input 1/2` in place of
steps 3 and 4.

**CAUTION:** Use headphones when you monitor a microphone. Speakers near
the microphone can make a loud feedback tone.

If the level is too low or touches the red, change the gain on the
interface. Do not change the fader of the track. The fader does not change what paw
records.

## Add an amp or an effect

1. Press `a`. The list of devices opens.
2. Type a part of the name, for example `reverb` or the name of an amp
   plugin, and press `Enter`.

paw records the input before the devices. So you can change the amp
after the recording.

## Record

Press `r` to arm the track, and `R` to record. For the full steps, see
[How to record an audio take](record-an-audio-take.md).

In the graphical window, the input button on the track header opens the
same list. The loudspeaker next to it switches the monitor.

## See also

- [Recording](../reference/recording.md#the-input-of-a-track): inputs, monitoring, arming.
- [How to lower the latency](lower-the-latency.md): when you hear the input late.
