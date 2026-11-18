# How to write automation with the faders

This guide shows you how to record the moves of a fader or a parameter
while the song plays. For each mode, see
[Automation](../reference/automation.md).

1. Select the track.
2. Type `:automation touch`. The fader writes only while you move it.
3. Play the song.
4. Move the fader, the pan, or a parameter. Use the keyboard, the
   graphical window, a MIDI controller, or the editor of a plugin. The
   header shows `T` in red while the track writes.
5. Release the control. The lane controls it again.
6. Stop the song. Type `:automation read`. Later moves then write
   nothing.

If you want a control to keep its new value until the song stops, use
`:automation latch`.

To write on all tracks, type `:lane.write`. Each track that is in `read`
mode then latches. Type `:lane.write` again to stop.

To undo a sweep, press `u` one time. One sweep is one undo step.
