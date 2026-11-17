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
app_stop
# The window's panes: the arrange view, the piano roll and the score of the melody.
SETUP="$GUI_DEMO daw.ext.load('extensions/notation')"
gui_start
glide 520 290; xdotool click --repeat 2 --delay 60 1; pause 1.2
typ ":vs notation"; key Return; pause 1.2
typ ":notation"; key Return; pause 2.0
glide 700 790 6; pause 0.4
shot gui-panes.png
