#!/bin/sh
# The quartet's full score and the clarinet's part in the window, on pages:
# the score in orchestral order, and the part written in B flat with a
# multi-measure rest and a cue.
. "$MAKE/rig.sh"
SETUP="dofile('extensions/notation/fixtures/quartet.lua')"
rig_start $GUI_SIZE
gui_start
typ ":view.window notation"; key Return; pause 2
key z p; pause 1.5
shot x-gp-score.png
typ ":part Clarinet"; key Return; pause 1.5
still gui-parts-clarinet.png
