#!/bin/sh
. "$(dirname "$0")/rig.sh"
SETUP=${X_SETUP:-$NOTATION}
rig_start
term_start
key j w comma n; pause 3
shot x-notation.png
ctl "return daw.opt.zoom"
key z i; pause 2
shot x-notation2.png
