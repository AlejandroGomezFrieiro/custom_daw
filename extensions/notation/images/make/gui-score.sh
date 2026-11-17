#!/bin/sh
# The quartet's score in the window: the clarinet's staff active, the
# others dimmed, and a block over three staves.
. "$MAKE/rig.sh"
SETUP="dofile('extensions/notation/fixtures/quartet.lua') paw.opt.score_dim = true"
rig_start $GUI_SIZE
gui_start
typ ":view.window notation"; key Return; pause 2
key bracketleft bracketleft; pause 0.2; key bracketright bracketright; pause 1
shot x-gs-active.png
keys 0.3 4 W; key ctrl+v; keys 0.4 ctrl+k ctrl+k W
pause 1.5
still gui-score-block.png
