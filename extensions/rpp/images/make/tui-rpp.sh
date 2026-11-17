#!/bin/sh
# A REAPER project opened in the terminal (the extension's own test
# project), and what paw could not bring over listed.
. "$MAKE/rig.sh"
SETUP="$TUI_DEMO paw.ext.load('extensions/rpp')"
rig_start
term_start
rec_start tui-rpp
cap ":rpp.import opens a REAPER project (:e song.rpp too), and lists what it could not bring"
pause 0.5; key colon; TYPE_DELAY=70 typ "rpp.import! extensions/rpp/fixtures/song.rpp"; pause 0.3; key Return; pause 2.6; key q; pause 1.2
cap ":w song.rpp writes it back as a REAPER project"
key colon; TYPE_DELAY=80 typ "w target/test-scratch/song.rpp"; key Return; pause 2.0
rec_stop
