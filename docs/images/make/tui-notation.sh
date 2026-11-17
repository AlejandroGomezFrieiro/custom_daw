#!/bin/sh
. "$(dirname "$0")/rig.sh"
SETUP="dofile('docs/images/make/scene-melody.lua')"
rig_start 1100x640
term_start
rec_start tui-notation
cap ",n shows the clip as staff notation, engraved in the terminal"
pause 0.8; key comma; pause 0.25; key n; pause 2.0
for k in z i z i z i z i z i; do key $k; pause 0.2; done
pause 0.8
cap "i enters notes: 5 is a quarter, then c e g type them in"
for k in W W W W; do key $k; pause 0.2; done
key i; pause 0.6; key 5; pause 0.3
for k in c e g; do key $k; pause 0.35; done
key 4; pause 0.3
for k in a g e; do key $k; pause 0.3; done
key Escape; pause 0.8
cap ",d writes a dynamic: mf, heard before it is written"
key h; key h; pause 0.4
key comma; pause 0.25; key d; pause 0.5
typ "mf"; pause 1.1; key Return; pause 1.0
cap ",t writes a tempo: Allegro q=132"
key comma; pause 0.25; key t; pause 0.5
TYPE_DELAY=55 typ "Allegro q=132"; pause 0.9; key Return; pause 1.0
cap "v selects notes; ,d mp<f makes a hairpin over them"
key 0; pause 0.3; key v; for k in l l l l; do key $k; pause 0.2; done
key comma; pause 0.25; key d; pause 0.5
TYPE_DELAY=90 typ "mp<f"; pause 1.1
shot tui-notation.png
key Return; pause 1.0
cap "Space plays what is written"
key space; pause 2.5; key space; pause 0.4
rec_stop
