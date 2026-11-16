#!/bin/sh
# Drive the window on a private display and look at what it does.
#
#   SETUP='lua run in the kernel at start' tests/tools/gui.sh out.png step...
#
# Starts Xvfb, a window manager and `daw-gui --clean --no-plugins --audio
# null` (with examples/demo-song.lua unless SETUP says otherwise), runs the
# steps, takes a last screenshot and ends everything it started. A step is:
#
#   sleep 0.5            wait
#   shot name.png        a screenshot, into target/test-scratch/shots/
#   ctl <lua>            run Lua in the kernel and print what it returns
#   alive                say whether the window is still running
#   ps                   its CPU use
#   anything else        an xdotool command: "mousemove 700 300", "click 1",
#                        "mousedown 1", "mouseup 1", "key alt+F4", "type text"
#
# The screen is 1500x960 (SCREEN=WxH for another); the window's content
# starts near x=50 y=60, the timeline near x=290 y=127. Needs Xvfb, openbox,
# xdotool and ImageMagick: outside a shell that has them it runs itself
# again under `nix shell`.
. "$(dirname "$0")/env.sh"
if ! command -v xdotool >/dev/null || ! command -v openbox >/dev/null || ! command -v import >/dev/null; then
  exec nix shell nixpkgs#xdotool nixpkgs#imagemagick nixpkgs#openbox -c "$0" "$@"
fi
export DISPLAY=:$DAW_TEST_DISPLAY
unset WAYLAND_DISPLAY XAUTHORITY
Xvfb "$DISPLAY" -screen 0 "${SCREEN:-1500x960}x24" >/dev/null 2>&1 &
xvfb=$!
sleep 1
openbox >/dev/null 2>&1 &
wm=$!
sleep 0.7
cd "$ROOT" || exit 1
RUST_BACKTRACE=1 "$BIN/daw-gui" --clean --no-plugins --audio null \
  -e "${SETUP:-dofile('examples/demo-song.lua')}" > "$SCRATCH/gui.out" 2>&1 &
gui=$!
trap 'kill $gui 2>/dev/null; sleep 0.4; kill $wm $xvfb 2>/dev/null' EXIT INT TERM
sleep "${START:-4}"
xdotool search --name "paw –" windowmove 0 0 >/dev/null 2>&1
sleep 0.3
png=$1
shift
for step in "$@"; do
  case "$step" in
    sleep*) $step ;;
    shot*) import -window root "$SCRATCH/shots/${step#shot }" ;;
    ctl*) "$BIN/daw" ctl --socket "${XDG_RUNTIME_DIR:-/tmp}/daw-gui-$gui.sock" eval "${step#ctl }" ;;
    alive) kill -0 $gui 2>/dev/null && echo "window alive" || echo "window gone" ;;
    ps) ps -o pcpu,cputime,etime -p $gui ;;
    *) xdotool $step ;;
  esac
done
[ -n "$png" ] && import -window root "$SCRATCH/shots/$png"
grep -n "panicked\|daw_gui::\|^daw-gui:" "$SCRATCH/gui.out" | cut -c1-200 | head -12
