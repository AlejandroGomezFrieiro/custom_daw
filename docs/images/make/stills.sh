#!/bin/sh
# The stills that are not taken on the way through a scene.
. "$(dirname "$0")/rig.sh"
rig_start 1280x800
gui_start
glide 48 284; xdotool click 1; pause 0.4
glide 181 21; xdotool click 1; pause 0.3
glide 700 600
pause 9.6
shot gui.png
glide 149 21; xdotool click 1; pause 0.5
app_stop
term_start
key j; pause 0.3; key w; pause 0.3; key Return; pause 1.2
for k in l l l l k k; do key $k; pause 0.15; done
pause 0.5
shot tui-pianoroll.png
