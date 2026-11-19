#!/bin/sh
# rounds.sh <tag> <rounds> <secs> <setup>...: interleaved rounds. In each
# round, each view (VIEWS, default "arrange mixer") and each size (SIZES,
# default 1500x960) runs every setup once, in an order that turns by one
# place each round. A setup is one of:
#   paw:<mode>       paw.sh with that mode (tui-pty, tui-xterm, tui-wez,
#                    gui-sw, gui-gpu)
#   reaper, reaper-weston, ardour, lmms
#                    daw.sh (reaper-weston: REAPER on weston and Xwayland)
# The label of a run is <tag>-<round>-<setup>-<view>-<size>, with ":" made
# "-" ("paw-gui-gpu"). If LOCK names a file, each run holds it with flock,
# so that two people or programs that measure on one machine take turns.
# Example:
#   REAPER=/path/to/reaper LOCK=/tmp/measure.lock \
#     bench/daws/rounds.sh cmp 3 20 paw:tui-pty paw:gui-gpu reaper ardour
D=$(cd "$(dirname "$0")" && pwd)
tag=$1 rounds=$2 secs=$3
shift 3 2>/dev/null || { echo "usage: rounds.sh <tag> <rounds> <secs> <setup>..." >&2; exit 2; }
setups="$*"
run() {
  if [ -n "$LOCK" ]; then flock "$LOCK" "$@"; else "$@"; fi
}
r=1
while [ "$r" -le "$rounds" ]; do
  for size in ${SIZES:-1500x960}; do
    w=${size%x*} h=${size#*x}
    for view in ${VIEWS:-arrange mixer}; do
      for s in $setups; do
        label=$tag-$r-$(echo "$s" | tr : -)-$view-$size
        case $s in
          paw:*) W=$w H=$h run sh "$D/paw.sh" "${s#paw:}" "$view" "$label" "$secs" ;;
          reaper-weston) SERVER=weston W_=$w H_=$h run sh "$D/daw.sh" reaper "$view" "$label" "$secs" ;;
          reaper|ardour|lmms) W_=$w H_=$h run sh "$D/daw.sh" "$s" "$view" "$label" "$secs" ;;
          *) echo "unknown setup $s" >&2 ;;
        esac
      done
    done
  done
  # The first setup goes last in the next round.
  set -- $setups
  first=$1; shift; setups="$* $first"
  r=$((r + 1))
done
