#!/bin/sh
. "$(dirname "$0")/rig.sh"
rig_start 1280x800
term_start
rec_start tui-help
cap ":help gU opens the manual where gU is described"
pause 0.8; key colon; pause 0.3
TYPE_DELAY=110 typ "help gU"; pause 0.6; key Return; pause 2.0
cap "Ctrl-] follows the link under the cursor"
for k in j j j; do key $k; pause 0.2; done
key ctrl+bracketright; pause 2.0
cap "Ctrl-t goes back"
key ctrl+t; pause 2.0
cap ":help takes keys, commands, options and sections"
key colon; pause 0.3
TYPE_DELAY=110 typ "help quickfix-list"; key Return; pause 2.2
rec_stop
