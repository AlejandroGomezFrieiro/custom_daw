#!/bin/sh
. "$(dirname "$0")/rig.sh"
rig_start 1100x640
term_start
rec_start tui-help
cap ":help gU opens the manual where gU is described"
pause 0.8; key colon; pause 0.3
TYPE_DELAY=110 typ "help gU"; pause 0.6; key Return; pause 2.0
cap "/ searches; Ctrl-] looks up the word under the cursor"
key slash; TYPE_DELAY=90 typ ":normal"; key Return; pause 0.9
key ctrl+bracketright; pause 2.2
cap "Ctrl-t goes back"
key ctrl+t; pause 1.8
cap ":help takes keys, commands, options and sections"
key colon; pause 0.3
TYPE_DELAY=110 typ "help quickfix-list"; key Return; pause 2.2
rec_stop
