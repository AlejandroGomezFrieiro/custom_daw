#!/bin/sh
# The piano roll: the melody's open last bar drawn with the cursor and
# typed on the home row, then selected and taken up an octave.
. "$(dirname "$0")/rig.sh"
SETUP=$TUI_DEMO
rig_start
term_start
key j w; pause 0.4
rec_start tui-pianoroll
cap "Enter opens the clip under the cursor in the piano roll"
pause 0.6; key Return; pause 1.0
keys 0.25 W W W
cap "i draws a note with the cursor: 8l makes it eight steps long"
key i; pause 0.3; keys 0.2 8 l; pause 0.5; key Escape; pause 0.9
cap "I makes the home row a piano: 4 a quarter, then j is B, y G sharp"
key I; pause 0.4; keys 0.4 4 j y; key Escape; pause 1.0
cap "vib selects the bar; Ctrl-a takes it up a semitone; gv Ctrl-x back down"
keys 0.25 b v i b; pause 0.4; key ctrl+a; pause 1.0
keys 0.25 g v; key ctrl+x; pause 1.4
rec_stop
