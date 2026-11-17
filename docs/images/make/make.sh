#!/bin/sh
# Make every picture in docs/images again, from the release build:
#
#   cargo build --release && docs/images/make/make.sh [scene...]
#
# Each scene (tui-*.sh, gui-*.sh, stills.sh) drives the real program on a
# private X display with xdotool, as tests/tools/gui.sh does, and records
# the screen. Nothing touches your display, sound or MIDI devices. The
# positions the pointer goes to are for the demo song at the sizes the
# scenes set; a change to the window's layout means changing them.
HERE=$(cd "$(dirname "$0")" && pwd)
if ! command -v wezterm >/dev/null || ! command -v gifsicle >/dev/null || [ -z "$CURSORS" ]; then
  CURSORS=$(nix build nixpkgs#vanilla-dmz --no-link --print-out-paths)/share/icons
  export CURSORS
  exec nix shell nixpkgs#wezterm nixpkgs#gifsicle nixpkgs#bc nixpkgs#xdotool nixpkgs#openbox nixpkgs#imagemagick nixpkgs#ffmpeg-full -c "$0" "$@"
fi
ROOT=$(cd "$HERE/../../.." && pwd)
WORK=${WORK:-$ROOT/target/test-scratch/media}
export WORK
[ $# -eq 0 ] && set -- tui-arrange tui-pianoroll tui-mixer tui-notation tui-ex tui-textbuf tui-help gui-arrange gui-pianoroll gui-mix gui-notation stills
for scene in "$@"; do
  echo "$scene"
  "$HERE/$scene.sh" || exit 1
  if [ -f "$WORK/$scene.mkv" ]; then
    "$HERE/gif.sh" "$scene" && cp "$WORK/$scene.gif" "$HERE/../$scene.gif"
  fi
done
# The stills the scenes took on the way.
for still in gui.png gui-pianoroll.png gui-mixer.png gui-notation.png gui-panes.png tui.png tui-pianoroll.png tui-notation.png tui-devices.png tui-picker.png; do
  [ -f "$WORK/$still" ] && cp "$WORK/$still" "$HERE/../$still"
done
ls -la "$HERE/.."
