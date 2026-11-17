#!/bin/sh
. "$(dirname "$0")/rig.sh"
SETUP=${X_SETUP:-"$GUI_DEMO daw.ext.load('extensions/notation')"}
rig_start $GUI_SIZE
gui_start
glide 988 21; xdotool click 1; pause 1.2
shot x-auto.png
glide 988 21; xdotool click 1; pause 0.6
glide 700 390; xdotool click --repeat 2 --delay 60 1; pause 1.5
glide 600 550; xdotool keydown ctrl; xdotool click 5; xdotool keyup ctrl; pause 0.6
shot x-roll1.png
glide 892 21; xdotool click 1; pause 1.2
shot x-mix.png
