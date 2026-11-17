#!/bin/sh
# The score beside the piano roll, on the melody: a hairpin written in the
# score sets the velocities the roll shows; velocities drawn in the roll
# change the MIDI and leave the marks alone; g@ in the score plays the
# notes as the marks say again.
. "$MAKE/rig.sh"
SETUP="$GUI_DEMO daw.ext.load('extensions/notation')"
rig_start $GUI_SIZE
gui_start
# The melody docked in the piano roll, the score beside it, the roll zoomed
# out to the clip's four bars.
glide 700 390; xdotool click --repeat 2 --delay 60 1; pause 1.2
typ ":vs notation"; key Return; pause 1.0
typ ":notation"; key Return; pause 1.5
glide 300 550; xdotool keydown ctrl; xdotool click 5 click 5 click 5; xdotool keyup ctrl; pause 0.4
glide 1150 700; xdotool click 1; pause 0.3
glide 900 720 6
rec_start gui-notation
cap "The score and the piano roll are two panes on the same notes"
pause 1.2
cap "\\d mp<f in the score writes a hairpin; the roll's velocities follow"
keys 0.2 0 v W W; key backslash d; pause 0.3; TYPE_DELAY=150 typ "mp<f"; pause 1.2
shot x-gn1.png
key Return; pause 1.2
shot x-gn2.png
cap "Velocities drawn in the roll change the MIDI; the marks stay"
stroke 66 765 170 740 280 765 380 745 490 760
pause 0.8
shot x-gn3.png
cap "g@ in the score plays the notes as the marks say again"
glide 1150 700 8; xdotool click 1; pause 0.3
key g at i e; pause 1.4
shot x-gn4.png
key Return; pause 1.6
still gui-notation.png
rec_stop
