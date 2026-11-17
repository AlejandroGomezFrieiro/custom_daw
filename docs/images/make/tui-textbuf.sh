#!/bin/sh
. "$(dirname "$0")/rig.sh"
rig_start 1100x420
term_start
rec_start tui-textbuf
cap ":e daw://tracks lists the tracks as text, one a line"
pause 0.8; key colon; pause 0.3
TYPE_DELAY=80 typ "e daw://tracks"; pause 0.5; key Return; pause 1.6
cap "Edit it with Vim's own keys: cw renames a track"
key j; pause 0.4
TYPE_DELAY=200 typ "cw"; pause 0.4
TYPE_DELAY=110 typ "Bassline"; key Escape; pause 1.0
cap "3 Ctrl-x takes 3 dB off a volume"
key w; key w; pause 0.3
key 3; key ctrl+x; pause 1.2
cap ":w shows the plan; y applies it as one undo step"
key colon; pause 0.3; typ "w"; key Return; pause 2.0
key y; pause 2.2
rec_stop
