# About the look of paw

<!-- tags: look -->

A screen of a DAW has much information: tracks, clips, notes, meters,
lanes. If all of it has strong colors, nothing is easy to see. paw keeps
the content neutral and puts color only where your attention must go.

## Color for attention

Amber is for focus: the focused panel, the playhead, and the keys to
press. The color of the mode is on the mode pill and on the cursor. So
the mode is visible where you look. Red is for recording and for errors,
and for nothing else. So a red mark is always important.

## The color of a track

Each track has a color, and paw draws what belongs to the track in shades
of that color. A clip has a name row and a darker body with its notes or
its waveform. The clip under the cursor shows in the full color. The track
of the cursor has a brighter header and a tinted lane. So you can see
which clips belong to which track, also in the piano roll and the mixer,
without a read of the names.

## Cells first

paw draws in cells first, because cells work in every terminal, through
SSH and tmux. A curve in sextant characters is a connected line with no
gaps. A waveform in cells shows the hits of a drum track. Pixels come in
addition, where the terminal can show images, and the same view draws the
same content in both. See [Pictures in the terminal](../reference/pictures.md).

## The same look in both frontends

The graphical window uses the same twelve track colors and the same
meaning for each color. A person who learns one frontend can read the
other.

## See also

- [The terminal screen](../reference/screen.md).
- [Options](../reference/options.md#screen).
