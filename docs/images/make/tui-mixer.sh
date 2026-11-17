#!/bin/sh
. "$(dirname "$0")/rig.sh"
rig_start 1280x800
term_start
rec_start tui-mixer
cap ",m opens the mixer"
pause 0.8; key comma; pause 0.25; key m; pause 1.2
cap "h l pick a strip · + - move its fader · j k pick a row"
key h; pause 0.5
for k in plus plus plus plus minus minus; do key $k; pause 0.35; done
key j; pause 0.4
for k in plus plus plus; do key $k; pause 0.35; done
key k; pause 0.4
cap "gcc mutes the strip, again unmutes it"
TYPE_DELAY=200 typ "gcc"; pause 1.0; TYPE_DELAY=200 typ "gcc"; pause 0.6
cap "Ctrl-w c closes a view"
key ctrl+w; pause 0.3; key c; pause 1.0
cap "a adds a device: type a few letters of its name"
key a; pause 1.2
TYPE_DELAY=200 typ "rev"; pause 1.0
shot tui-picker.png
key Return; pause 1.4
cap ",d opens the device panel: j k pick a parameter, + - change it"
key comma; pause 0.25; key d; pause 1.2
for k in j j j plus plus plus plus j minus minus; do key $k; pause 0.4; done
pause 0.8
rec_stop
shot tui-devices.png
