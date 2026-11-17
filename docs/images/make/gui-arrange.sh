#!/bin/sh
# The arrange view with the mouse: a clip copied, trimmed, its menu, zoom,
# and the song playing.
. "$MAKE/rig.sh"
rig_start $GUI_SIZE
gui_start
# The timeline: x = 241 + 22 a beat; rows 90 high from y 70, in the demo
# song's order: Drums, Bass, Keys, Lead, Reverb.
rec_start gui-arrange
cap "Ctrl-drag copies a clip: the melody, over the first half too"
pause 0.5
xdotool keydown ctrl
drag 700 390 348 390
xdotool keyup ctrl
pause 0.6
cap "Drag a clip's edge to trim it"
drag 588 400 418 400
pause 0.6
cap "Right click for everything else"
rclick 330 390; glide 420 520 12; pause 0.7
xdotool key Escape; pause 0.5
cap "Ctrl and the wheel zoom"
glide 560 240
xdotool keydown ctrl
for i in 1 2; do xdotool click 4; pause 0.25; done
pause 0.3
for i in 1 2; do xdotool click 5; pause 0.25; done
xdotool keyup ctrl
pause 0.4
cap "Play"
glide 181 21; pause 0.2; xdotool click 1; pause 2.8
glide 149 21; xdotool click 1; pause 0.6
rec_stop
