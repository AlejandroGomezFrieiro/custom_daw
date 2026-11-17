#!/bin/sh
# Templates: the keys track saved with its chain and levels, and made again
# under another name in the same song.
. "$MAKE/rig.sh"
SETUP="$TUI_DEMO daw.ext.load('extensions/templates')"
rig_start
term_start
rec_start tui-templates
cap ",Ts saves the track: its devices with their settings, levels and sends"
pause 0.5; key comma T s; pause 0.5; TYPE_DELAY=110 typ "Soft keys"; key Return; pause 1.0
cap ",Tl makes a template again, below the cursor's track: a part of its name will do"
keys 0.3 j j; key comma T l; pause 0.5; TYPE_DELAY=110 typ "soft"; pause 0.6; key Return; pause 1.2
cap ",d shows what it came with"
key comma d; pause 2.0
rec_stop
