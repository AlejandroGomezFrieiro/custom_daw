#!/bin/sh
. "$(dirname "$0")/rig.sh"
SETUP="SCENE_BEATS = 4 dofile('docs/images/make/scene-melody.lua') daw.frontend.layout_set({ zoom = 20 })"
rig_start 1280x800
gui_start
# The clip opens docked in the piano roll; the score goes beside it.
glide 300 100; xdotool click --repeat 2 --delay 60 1; pause 1.2
typ ":vs notation"; key Return; pause 1.2
typ ":notation"; key Return; pause 1.8
glide 700 790 4; pause 0.3
shot gui-panes.png
rec_start gui-notation
cap "The piano roll and the score are panes of the window, side by side"
pause 1.6
# The score: bar 2 is empty, after the barline at x 966.
cap "i, then a click puts a note where the shadow note shows"
glide 1000 470; xdotool click 1; pause 0.4
key i; pause 0.4
glide 1004 466 6; pause 0.8
xdotool click 1; pause 0.8
glide 1050 452 8; pause 0.8; xdotool click 1; pause 0.8
glide 1100 440 8; pause 0.8; xdotool click 1; pause 0.8
key Escape; pause 0.3
glide 700 780 10
cap "The notes are in the piano roll too: written, and played"
pause 2.2
shot gui-notation.png
rec_stop
