#!/bin/sh
. "$(dirname "$0")/rig.sh"
rig_start 1280x800
gui_start
rec_start gui-pianoroll
cap "Double click a clip to open its notes"
pause 0.7
glide 560 300; pause 0.2; xdotool click --repeat 2 --delay 60 1; pause 1.5
# The roll: x = 64 + 80 a beat; C5 is at y 563, a semitone is 12 high.
cap "Drag on the grid to draw notes"
drag 150 611 208 611
drag 230 635 288 635
drag 310 611 368 611
drag 390 635 448 635
pause 0.5
cap "Drag a note to move it"
drag 340 611 340 587
pause 0.5
cap "Draw velocities under the notes"
stroke 70 765 300 715 620 760 900 720 1180 750
pause 0.8
cap "Right-drag draws a box around notes"
drag 120 600 460 650 3
pause 0.7
cap "Drag one of them and they all move"
drag 180 611 180 587
pause 0.9
shot gui-pianoroll.png
cap "Space plays"
xdotool key space; pause 4; xdotool key space; pause 0.5
rec_stop
