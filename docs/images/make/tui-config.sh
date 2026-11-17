#!/bin/sh
# Configuration is Lua: init.lua edited in Neovim above the program, and
# :reload running it again while the song plays.
. "$MAKE/rig.sh"
SETUP=$TUI_DEMO
HOME=$D CONFIG=$D/.config/daw
export HOME
EDIT=$CONFIG/init.lua
export EDIT
mkdir -p "$CONFIG"
printf -- '-- ~/.config/daw/init.lua\ndaw.opt.zoom = 2.75\n' > "$EDIT"
rig_start
term_start
# Neovim, in the pane above, has the keyboard; Ctrl-Shift and an arrow
# moves between the panes (WezTerm's keys, not the program's).
xdotool key ctrl+shift+Down; pause 0.4
rec_start tui-config
cap "Space plays; init.lua, above, is your configuration, in Lua"
pause 0.5; key space; pause 1.2
xdotool key ctrl+shift+Up; pause 0.5
cap "Add a colour and a key to it, and write it"
key G o; TYPE_DELAY=35 typ 'daw.ui.hl("Playhead", { bg = "#f38ba8" })'
key Return; TYPE_DELAY=35 typ 'daw.keymap.set("<leader>T", "track.add Strings device=synth")'
key Escape; key colon; typ "w"; key Return; pause 0.6
xdotool key ctrl+shift+Down; pause 0.4
cap ":reload runs it again without stopping the sound"
key colon; TYPE_DELAY=90 typ "reload"; key Return; pause 1.4
cap ",T, the new key, adds a track"
key comma T; pause 1.8
rec_stop
