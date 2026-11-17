#!/bin/sh
# The hardware check, on the null backend with a test signal and a stand-in
# MIDI port: none of the machine's own devices is opened or listed.
. "$MAKE/rig.sh"
SETUP="$TUI_DEMO daw.ext.load('extensions/doctor') daw.api.engine_restart({ backend = 'null', test_input = { frequency = 220, level = -12, channels = 2 }, test_midi = { 'Keys A' } })"
rig_start
term_start
rec_start tui-doctor
cap ":doctor opens the check of the sound system, MIDI, recording and plugins"
pause 0.5; key colon; TYPE_DELAY=110 typ "doctor"; key Return; pause 1.8
cap ":doctor unattended runs the checks that need nobody, and writes a report"
key colon; TYPE_DELAY=90 typ "doctor unattended"; key Return; pause 6.0
rec_stop
