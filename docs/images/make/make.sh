#!/bin/sh
# Make every picture in docs/images again, from the release build:
#
#   cargo build --release && docs/images/make/make.sh [scene...]
#
# Each scene (tui-*.sh, gui-*.sh, stills.sh) drives the real program on a
# private X display (RIG_DISPLAY, 177 unless set) with xdotool, as
# tests/tools/gui.sh does, and records the screen; gif.py makes the GIF,
# with the caption and the keys typed in a bar under it. All of them start
# from examples/demo-song.lua. Nothing touches your display, sound or MIDI
# devices. The positions the pointer goes to are for the demo song at the
# sizes rig.sh sets; a change to the window's layout means changing them.
# NOCOPY=1 leaves the results in target/test-scratch/media.
HERE=$(cd "$(dirname "$0")" && pwd)
if ! command -v wezterm >/dev/null || ! command -v gifsicle >/dev/null || [ -z "$CURSORS" ]; then
  CURSORS=$(nix build nixpkgs#vanilla-dmz --no-link --print-out-paths)/share/icons
  export CURSORS
  exec nix shell nixpkgs#wezterm nixpkgs#gifsicle nixpkgs#bc nixpkgs#xdotool nixpkgs#openbox \
    nixpkgs#imagemagick nixpkgs#ffmpeg-full nixpkgs#python3 -c "$0" "$@"
fi
ROOT=$(cd "$HERE/../../.." && pwd)
WORK=${WORK:-$ROOT/target/test-scratch/media}
export WORK
GIFS="tui-arrange tui-pianoroll tui-notation tui-mixer tui-textbuf tui-help gui-arrange gui-pianoroll gui-notation gui-mix"
[ $# -eq 0 ] && set -- $GIFS stills
for scene in "$@"; do
  echo "$scene"
  rm -f "$WORK/$scene.mkv"
  "$HERE/$scene.sh" || exit 1
  if [ -f "$WORK/$scene.mkv" ]; then
    python3 "$HERE/gif.py" "$scene" || exit 1
    [ -z "$NOCOPY" ] && cp "$WORK/$scene.gif" "$HERE/../$scene.gif"
  fi
done
# The stills the scenes took on the way.
if [ -z "$NOCOPY" ]; then
  for still in gui.png gui-notation.png gui-panes.png tui.png tui-notation.png; do
    [ -f "$WORK/$still" ] && cp "$WORK/$still" "$HERE/../$still"
  done
fi
ls -la "$HERE/.."
