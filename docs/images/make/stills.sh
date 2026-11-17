#!/bin/sh
# The stills that are not taken on the way through a scene: the window
# playing the song, its panes, and the keys' phrase in two voices engraved.
. "$(dirname "$0")/rig.sh"
SETUP="$GUI_DEMO daw.ext.load('extensions/notation')"
rig_start $GUI_SIZE
gui_start
glide 181 21; xdotool click 1; pause 0.4
glide 700 700
pause 9.6
shot gui.png
glide 149 21; xdotool click 1; pause 0.5
# The panes: the melody in the piano roll, its score beside it.
glide 700 390; xdotool click --repeat 2 --delay 60 1; pause 1.2
typ ":vs notation"; key Return; pause 1.0
typ ":notation"; key Return; pause 1.5
glide 300 550; xdotool keydown ctrl; xdotool click 5 click 5 click 5; xdotool keyup ctrl; pause 0.4
glide 700 790 6; pause 0.4
shot gui-panes.png
# The keys' phrase, in a score of its own over the whole window.
glide 1150 700; xdotool click 1; pause 0.3
typ ":only"; key Return; pause 0.6
ctl "daw.cursor.set_track(daw.tracks()[3]) daw.cursor.set_beat(17)"
typ ":notation"; key Return; pause 2.0
glide 700 790 6; pause 0.4
shot gui-notation.png
