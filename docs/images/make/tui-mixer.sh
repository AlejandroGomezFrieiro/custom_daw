#!/bin/sh
. "$(dirname "$0")/rig.sh"
rig_start 1280x800
term_start
rec_start tui-mixer
cap ",m opens the mixer"
pause 0.8; key comma; pause 0.25; key m; pause 1.2
cap "h l pick a track · k j move its fader · M mutes"
for k in l k k k h h j j M M; do key $k; pause 0.4; done
pause 0.5
cap "Ctrl-w c closes a view"
key ctrl+w; pause 0.3; key c; pause 1.0
cap "a adds a device: type a few letters of its name"
key a; pause 1.2
TYPE_DELAY=200 typ "rev"; pause 1.0
shot tui-picker.png
key Return; pause 1.4
cap ",d opens the device panel: j k pick a parameter, h l change it"
key comma; pause 0.25; key d; pause 1.2
for k in j j j l l l j h h; do key $k; pause 0.4; done
pause 0.8
rec_stop
shot tui-devices.png
