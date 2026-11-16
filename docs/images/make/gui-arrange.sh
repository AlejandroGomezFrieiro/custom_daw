#!/bin/sh
. "$(dirname "$0")/rig.sh"
rig_start 1280x800
gui_start
# The timeline: x = 240 + 20 a beat; rows from y 68, each 66 high, in the
# demo song's order: Drums, Bass, Keys, Lead, Reverb.
rec_start gui-arrange
cap "Drag a clip to move it"
pause 0.8
drag 520 300 600 300
pause 0.6
cap "Drag an edge to trim it"
drag 798 310 720 310
pause 0.6
cap "Ctrl-drag makes a copy"
xdotool keydown ctrl
drag 840 100 920 100
xdotool keyup ctrl
pause 0.7
cap "Double click an empty place for a new clip"
glide 290 300; pause 0.2; xdotool click --repeat 2 --delay 60 1
pause 1.3
cap "Right click for everything else"
rclick 600 240; pause 0.3; glide 680 400 20; pause 0.9
xdotool key Escape; pause 0.5
cap "Ctrl and the wheel zoom"
glide 560 240
xdotool keydown ctrl
for i in 1 2 3; do xdotool click 4; pause 0.25; done
pause 0.5
for i in 1 2 3; do xdotool click 5; pause 0.25; done
xdotool keyup ctrl
pause 0.5
cap "Play"
glide 181 21; pause 0.2; xdotool click 1; pause 4
glide 149 21; xdotool click 1; pause 0.6
rec_stop
