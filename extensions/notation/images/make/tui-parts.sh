#!/bin/sh
# The quartet's full score and the clarinet's part, engraved in the
# terminal: the score in orchestral order with its brackets, condensed,
# and the part written in B flat with a multi-measure rest and a cue.
. "$MAKE/rig.sh"
SETUP="dofile('extensions/notation/fixtures/quartet.lua') require('notation').space = 9"
rig_start
term_start
key ctrl+w o; pause 1.2
still tui-parts-score.png
key backslash P c; pause 1.5
shot x-tp-condensed.png
typ ":part Clarinet"; key Return; pause 1.5
shot x-tp-clarinet.png
