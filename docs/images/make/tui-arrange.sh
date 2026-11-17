#!/bin/sh
# The hero: the song playing while it is edited as a text is in Vim, a
# substitution previewed as it is typed, and the same clip read as a score.
. "$(dirname "$0")/rig.sh"
SETUP=$TUI_NOTATION
rig_start
term_start
shot tui.png
rec_start tui-arrange
cap "Space plays; j w move over tracks and clips as over lines and words"
pause 0.5; key space; pause 0.6
keys 0.4 j w
cap "3>ic moves the clip under the cursor three steps later; u undoes"
TYPE_DELAY=200 typ "3>ic"; pause 0.9; key u; pause 0.7
cap "Ex over notes, previewed as it is typed"
key colon; TYPE_DELAY=110 typ "%s/e5/g5/g"; pause 1.3; key Return; pause 0.8
cap ",n reads the same clip as a score"
key comma n; pause 3.0
rec_stop
