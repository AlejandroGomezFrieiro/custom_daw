# How to map a MIDI controller

This guide shows you how to move faders and parameters with the knobs of a
MIDI controller. It assumes that paw runs with an audio device. Then the
MIDI ports are open (see [MIDI](../reference/midi.md#midi-input)). For each
command, see [MIDI controllers](../reference/learn.md).

## Map a parameter of a device

1. Open the device panel and move the cursor to the parameter.
2. Type `:learn`.
3. Turn the knob on the controller. The knob now moves the parameter.

In the graphical window, click the plug icon next to the parameter, then
turn the knob.

## Map the fader of a track

1. Select the track.
2. Type `:learn volume`. For the pan, type `:learn pan`.
3. Move the fader on the controller.

## Map the control that you moved last

1. Move the control in paw: a fader, or a parameter in the editor of a
   plugin.
2. Type `:learn`.
3. Move the control on the controller.

## Remove a mapping

1. Type `:learn.list`.
2. Select the mapping. paw removes it.

If the target does not move, turn the knob past the current value of the
target. paw waits until the control reaches the value.
To make the target jump immediately, set `paw.opt.learn_pickup = false` in
`init.lua`.

To record the moves as automation, set the automation mode of the track
first. See [How to write automation with the faders](write-automation-with-the-faders.md).
