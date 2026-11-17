#!/bin/sh
. "$(dirname "$0")/rig.sh"
rig_start 1280x800
term_start
key j; pause 0.4
rec_start tui-pianoroll
cap "i makes a clip at the cursor and opens it; I makes the home row a piano"
pause 0.9; key i; pause 1.0; key Escape; pause 0.4; key I; pause 1.0
cap "a w s e d f t g y h u j k are C up to the next C"
pause 0.3
for k in a d g k h g d a; do key $k; pause 0.4; done
pause 0.6
cap "Esc goes back to normal mode · h j k l move over the notes"
key Escape; pause 0.6
for k in h h h k k j; do key $k; pause 0.3; done
pause 0.4
cap "Ctrl-v selects a block of notes · Ctrl-x and Ctrl-a transpose all of it"
key 0; key g; key g; pause 0.3; key ctrl+v; pause 0.3; key dollar; key G; pause 0.8
key ctrl+x; pause 0.7; key ctrl+x; pause 0.7; key ctrl+a; pause 1.0
key Escape; pause 0.4
cap "u undoes · Ctrl-r redoes"
key u; pause 1.0; key ctrl+r; pause 1.0
cap "Space plays what you wrote"
key space; pause 3.5; key space; pause 0.6
rec_stop
