#!/bin/sh
. "$(dirname "$0")/rig.sh"
rig_start 1280x800
term_start
shot tui.png
rec_start tui-arrange
cap "j k move between tracks · w b between clips"
pause 0.8
for k in j w k k w b; do key $k; pause 0.45; done
pause 0.5
cap "x deletes the clip · u undoes"
pause 0.6; key x; pause 1.1; key u; pause 1.0
cap "yic yanks the clip under the cursor · p pastes it after"
key j; pause 0.3; key j; pause 0.5
TYPE_DELAY=260 typ "yic"; pause 0.7; key p; pause 1.2
cap "M mutes the track · s solos it"
key M; pause 0.9; key M; pause 0.5; key s; pause 0.9; key s; pause 0.6
cap ": runs any command by name"
key colon; pause 0.4; TYPE_DELAY=70 typ "track.add Pads device=synth"; pause 0.8; key Return; pause 1.3
cap "Space plays"
key space; pause 4; key space; pause 0.8
rec_stop
