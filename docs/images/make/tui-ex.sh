#!/bin/sh
. "$(dirname "$0")/rig.sh"
rig_start 1280x800
term_start
rec_start tui-ex
cap ":%s/c4/d4/gc : the command line previews what it would do"
pause 0.8; key colon; pause 0.3
TYPE_DELAY=110 typ "%s/c4/d4/gc"; pause 1.3
cap "Enter asks about each match: y yes, n no, a all the rest"
key Return; pause 1.0
for k in y n y; do key $k; pause 0.55; done
key a; pause 1.2
key ctrl+w; key c; pause 0.8
cap "u undoes the whole line at once"
key u; pause 1.2
cap ":t2,t4 mute : a range of tracks"
key colon; pause 0.3
TYPE_DELAY=110 typ "t2,t4 mute"; pause 1.5; key Return; pause 1.0
cap ":t* unmute undoes it"
key colon; pause 0.3
TYPE_DELAY=110 typ "t* unmute"; pause 1.0; key Return; pause 1.0
rec_stop
