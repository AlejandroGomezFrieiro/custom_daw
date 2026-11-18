# How to record a performance from the session view

<!-- tags: capture -->

This guide shows you how to play clips live from the session view and keep
the performance on the timeline. It assumes that your tracks have clips in
their slots. For each key and command, see
[The session view](../reference/session-view.md).

1. Press `,l` to show the session view.
2. To set where launches start, type `:launch.quantize bar`.
3. Press `C` to start a capture.
4. Move to a slot and press `<CR>` to launch it. The song starts with the
   clip.
5. To change parts, launch other slots or press `L` to launch a full scene.
6. To silence a track, press `S`. To play its timeline again, press `B`.
7. Stop the song.

paw writes each clip that played to the timeline as a looped copy. The
parts where a track was silent become empty. One `u` removes the capture.

If you want to render the performance, render after the capture. A render
plays only the timeline.

## Record a new loop into a slot

1. Select a track with an input, and move to an empty slot.
2. Press `4R` to record four bars from the next boundary.
3. Play. At the end of the four bars, the take becomes the clip of the slot
   and plays immediately.
4. To stop the recording early, press `R` again.

## Launch slots from pads

1. In the session view, move to a slot.
2. Type `:learn` and press a pad on your controller.
3. To bind a pad to the scene of the row, type `:learn scene` and press the
   pad.

For other controls, see
[How to map a MIDI controller](map-a-midi-controller.md).
