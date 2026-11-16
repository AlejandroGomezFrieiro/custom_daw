#!/bin/sh
. "$(dirname "$0")/rig.sh"
rig_start 1280x800
gui_start
glide 48 284; xdotool click 1; pause 0.4
rec_start gui-mix
cap "Type a device's name to add it to the track"
pause 0.6
glide 1100 106; pause 0.2; xdotool click 1; pause 0.5
xdotool type --delay 170 "rev"; pause 0.9
xdotool key Return; pause 1.3
cap "Play, and open the mixer"
glide 181 21; pause 0.2; xdotool click 1; pause 0.8
glide 811 21; pause 0.2; xdotool click 1; pause 1.2
cap "Faders, pans, mute and solo for every track"
drag 108 633 108 606
pause 0.4
drag 254 637 254 645
pause 0.6
shot gui-mixer.png
glide 811 21; pause 0.2; xdotool click 1; pause 0.8
cap "Automation: show the lanes and draw with the pointer"
glide 905 21; pause 0.2; xdotool click 1; pause 1.2
stroke 250 185 400 150 560 182 720 146 876 176
pause 2.5
glide 149 21; xdotool click 1; pause 0.6
rec_stop
