#!/bin/sh
. "$(dirname "$0")/rig.sh"
rig_start 1280x800
gui_start
rec_start gui-pianoroll
cap "Double click a clip to open its notes"
pause 0.7
glide 560 300; pause 0.2; xdotool click --repeat 2 --delay 60 1; pause 1.5
# The roll: x = 64 + 80 a beat; C5 is at y 639, a semitone is 12 high.
cap "Drag on the grid to draw notes"
drag 70 591 128 591
drag 150 555 208 555
drag 230 531 288 531
drag 310 555 368 555
pause 0.5
cap "Drag a note to move it"
drag 340 555 340 519
pause 0.5
cap "Draw velocities under the notes"
stroke 70 765 300 715 620 760 900 720 1180 750
pause 0.8
cap "Right-drag draws a box around notes"
drag 70 543 218 602 3
pause 0.7
cap "Drag one of them and they all move"
drag 100 591 100 567
pause 0.9
shot gui-pianoroll.png
cap "Space plays"
xdotool key space; pause 4; xdotool key space; pause 0.5
rec_stop
