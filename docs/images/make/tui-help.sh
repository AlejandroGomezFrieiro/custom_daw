#!/bin/sh
# The manual inside: K on a clip, :help on a key, Ctrl-] and back.
. "$(dirname "$0")/rig.sh"
SETUP=$TUI_NOTATION
rig_start
term_start
key j w; pause 0.4
rec_start tui-help
cap "K on a clip says what it is"
pause 0.5; key K; pause 2.0
key Escape; pause 0.3
cap ":help opens the manual where a key is described"
key colon; TYPE_DELAY=110 typ "help g@"; pause 0.3; key Return; pause 2.0
cap "/ searches; Ctrl-] follows the link under the cursor; Ctrl-t goes back"
key slash; TYPE_DELAY=90 typ "listed in"; key Return; pause 0.5; keys 0.25 w w; pause 0.3
key ctrl+bracketright; pause 2.2
shot x-help2.png
key ctrl+t; pause 1.6
rec_stop
