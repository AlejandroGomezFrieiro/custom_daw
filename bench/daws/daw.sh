#!/bin/sh
# daw.sh <daw> <view> <label> <secs>: another DAW (reaper, ardour, lmms)
# playing the demo song in a loop on its dummy audio device, and the CPU it
# and its display server use over <secs> seconds.
#
# The DAW runs in bubblewrap: a fresh HOME and XDG_CONFIG_HOME in a scratch
# folder, /home and /tmp hidden, no network, no session bus, no audio
# device. The display is private: Xvfb, or with SERVER=weston a headless
# weston on the graphics card with Xwayland (the "server" counted is then
# weston and Xwayland together). Views: arrange, mixer, roll (REAPER only:
# the built-in MIDI editor). Ardour and LMMS run at 1500x960 only.
#
# Environment:
#   REAPER   the reaper binary (required for reaper; REAPER is not free
#            software, so no default). It runs with -cfgfile and a
#            reaper.ini of its own: it never reads ~/.config/REAPER.
#   ARDOUR   the ardour9 binary (default: ardour9 from PATH)
#   LMMS     the lmms binary (default: lmms from PATH)
#   WESTON, XWAYLAND   the weston and Xwayland binaries for SERVER=weston
#   XDOTOOL  default xdotool; IMPORT (ImageMagick) for SHOT=1
#   W_, H_   the screen size (default 1500x960)
#   CORES    the cores to pin to (default 16-23)
#   OUT      where results and sandboxes go (default $BENCH_TMP/daws,
#            BENCH_TMP default /tmp/paw-bench)
#   SETTLE   seconds to wait for the DAW to start; SHOT=1 a screenshot
#
# Writes $OUT/results/<label>/cpu.txt: "<daw> pct rss_mb" for the DAW's
# whole process tree, "server pct 0", "procs n", "load <load1>".
D=$(cd "$(dirname "$0")" && pwd)
daw=$1 view=$2 label=$3 secs=$4
[ -n "$secs" ] || { echo "usage: daw.sh <reaper|ardour|lmms> <view> <label> <secs>" >&2; exit 2; }
WW=${W_:-1500} HH=${H_:-960}
CORES=${CORES:-16-23}
OUT=${OUT:-${BENCH_TMP:-/tmp/paw-bench}/daws}
XDO=${XDOTOOL:-xdotool}
out=$OUT/results/$label
S=$OUT/sb/$label
rm -rf "$out" "$S"; mkdir -p "$out" "$S/home" "$S/xdg" "$S/run"; chmod 700 "$S/run"
cp "$D/song.json" "$D/demo.mid" "$S/"

case $daw in
  reaper) [ -x "$REAPER" ] || { echo "set REAPER to the reaper binary" >&2; exit 2; } ;;
  ardour|lmms) ;;
  *) echo "unknown daw $daw" >&2; exit 2 ;;
esac

if [ "$SERVER" = weston ]; then
  # A short runtime folder: the socket's path must be short.
  WR=$(mktemp -d /tmp/paw-wl.XXXXXX); chmod 700 "$WR"
  printf '[core]\nxwayland=true\n[xwayland]\npath=%s\n' "${XWAYLAND:-$(command -v Xwayland)}" > "$WR/weston.ini"
  XDG_RUNTIME_DIR=$WR ${WESTON:-weston} --config="$WR/weston.ini" --backend=headless --renderer=gl \
    --width="$WW" --height="$HH" --socket=wl-daw$$ --idle-time=0 > "$out/weston.log" 2>&1 &
  xs=$!
  sleep 2
  n=$(grep -o "display :[0-9]*" "$out/weston.log" | head -1 | cut -d: -f2)
  [ -z "$n" ] && { echo "no Xwayland display" >&2; cat "$out/weston.log" >&2; kill $xs; exit 1; }
else
  n=$((170 + $$ % 9))
  Xvfb :$n -screen 0 "${WW}x${HH}x24" >/dev/null 2>&1 &
  xs=$!
  sleep 1
fi
taskset -cp "$CORES" $xs >/dev/null

case $daw in
  reaper)
    mkdir -p "$S/xdg/REAPER/Scripts"
    printf '[REAPER]\nlinux_audio_mode=2\nsplashscreen=0\nwnd_x=0\nwnd_y=0\nwnd_w=%s\nwnd_h=%s\nwnd_state=0\n[verchk]\nlastt=%s\n' "$WW" "$HH" "$(date +%s)" > "$S/xdg/REAPER/reaper.ini"
    python3 -I "$D/mk_reaper.py" "$S/song.json" "$S/xdg/REAPER/Scripts/__startup.lua" "$view"
    cmd="$REAPER -cfgfile $S/xdg/REAPER/reaper.ini -nosplash -newinst" ;;
  ardour)
    # The config of a first run (the dummy backend shown), and the session
    # script that builds the song.
    mkdir -p "$S/xdg/ardour9/scripts" "$S/sess"
    cp "$D/ardour-config.xml" "$S/xdg/ardour9/config"
    : > "$S/xdg/ardour9/.a9"
    sed 's/name        = "Paw Demo"/name        = "PawDemo"/' "$D/ardour_init.lua" > "$S/xdg/ardour9/scripts/paw_demo.lua"
    cmd="${ARDOUR:-ardour9} -a -n -N $S/sess/demo -T PawDemo" ;;
  lmms)
    python3 -I "$D/mk_lmms.py" "$S/song.json" "$S/demo.mmp" "$S/home" "$view"
    cmd="env QT_QPA_PLATFORM=xcb QT_XCB_GL_INTEGRATION=none ${LMMS:-lmms} --geometry 1500x960+0+0 $S/demo.mmp" ;;
esac

setsid taskset -c "$CORES" bwrap --ro-bind /nix /nix --ro-bind /etc /etc --ro-bind /bin /bin --ro-bind /usr /usr \
  --ro-bind /run/current-system /run/current-system --proc /proc --dev /dev --tmpfs /tmp --tmpfs /home \
  --bind "$S" "$S" --bind "$out" "$out" --setenv DEMO_MID "$S/demo.mid" \
  --ro-bind /tmp/.X11-unix/X$n /tmp/.X11-unix/X$n \
  --setenv HOME "$S/home" --setenv XDG_CONFIG_HOME "$S/xdg" --setenv XDG_RUNTIME_DIR "$S/run" \
  --setenv DISPLAY :$n --setenv DAW_OUT "$out" --setenv DAW_VIEW "$view" --unsetenv WAYLAND_DISPLAY --unsetenv XAUTHORITY \
  --unsetenv SSH_AUTH_SOCK --unsetenv DBUS_SESSION_BUS_ADDRESS \
  --unshare-ipc --unshare-net --unshare-uts --die-with-parent \
  $cmd > "$out/stdout" 2> "$out/stderr" &
app=$!
x() { DISPLAY=:$n $XDO "$@"; }
case $daw in
  reaper)
    sleep "${SETTLE:-12}"
    # Close the evaluation notice ("Still Evaluating").
    x mousemove $((WW / 2 - 262)) $((HH / 2 - 85)) click 1; sleep 2
    # The MIDI editor, over the main window and as large.
    if [ "$view" = roll ]; then
      for w in $(x search --name "MIDI take"); do x windowmap $w; x windowraise $w; x windowmove $w 0 0; x windowsize $w $WW $HH; done
      sleep 2
    fi ;;
  ardour)
    # The audio system: None (Dummy), Start; then the window to the
    # screen's size, and loop playback (l), or the mixer too (Mix).
    sleep "${SETTLE:-8}"
    x mousemove 760 300 click 1; sleep 1; x mousemove 740 348 click 1; sleep 1; x mousemove 950 653 click 1
    sleep 15
    w=$(x search --onlyvisible --name "demo" | head -1)
    x windowmove $w 0 0; x windowsize $w 1500 960; sleep 1
    x mousemove 900 640 click 1; x key l
    [ "$view" = mixer ] && x mousemove 1479 79 click 1
    sleep 4 ;;
  lmms)
    # Play the song (Space), which loops between the loop points.
    sleep "${SETTLE:-15}"
    x key space; [ "$view" = mixer ] && x mousemove 134 71 click 1; sleep 4 ;;
esac

# Every process under bubblewrap, and the display server's processes.
tree() { echo $1; for c in $(cat /proc/$1/task/*/children 2>/dev/null); do tree $c; done; }
pids=$(tree $app)
t() { s=0; for p in "$@"; do v=$(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null || echo 0); s=$((s + v)); done; echo $s; }
a=$(t $pids); xps=$(tree $xs); ax=$(t $xps); s0=$(date +%s.%N)
sleep "$secs"
b=$(t $pids); bx=$(t $xps); s1=$(date +%s.%N)
rss=0; for p in $pids; do r=$(awk '/VmRSS/{print int($2/1024)}' /proc/$p/status 2>/dev/null); rss=$((rss + ${r:-0})); done
tick=$(getconf CLK_TCK)
{
  echo "$daw $a $b $s0 $s1 $tick $rss" | awk '{printf "%s %.1f %d\n", $1, ($3-$2)/$6/($5-$4)*100, $7}'
  echo "server $ax $bx $s0 $s1 $tick 0" | awk '{printf "%s %.1f %d\n", $1, ($3-$2)/$6/($5-$4)*100, $7}'
  echo "procs $(echo $pids | wc -w)"
  echo "load $(cut -d' ' -f1 /proc/loadavg)"
} > "$out/cpu.txt"
[ -n "$SHOT" ] && DISPLAY=:$n ${IMPORT:-import} -window root "$out/shot.png" 2>/dev/null

kill -- -$app 2>/dev/null; sleep 1; kill -9 -- -$app 2>/dev/null
kill $xps 2>/dev/null
sleep 0.5
[ -n "$WR" ] && rm -rf "$WR"
echo "== $label: $(tr '\n' ' ' < "$out/cpu.txt") $(head -1 "$out/started" 2>/dev/null)"
