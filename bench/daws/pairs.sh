#!/bin/sh
# pairs.sh <tag> <mode> <view> <n> <secs>: n interleaved runs of two builds
# of paw in one mode and view, the base first: BASEBIN and NEWBIN are the
# folders of their paw and paw-gui. Labels: <tag>-<i>-base-paw-<mode>-<view>
# and <tag>-<i>-new-paw-<mode>-<view>, at size W x H (default 1500x960). If
# LOCK names a file, each run holds it with flock.
# Example (a worktree of main built in /tmp/base):
#   BASEBIN=/tmp/base/target/release NEWBIN=target/release \
#     bench/daws/pairs.sh frames paw:gui-gpu arrange 5 15
D=$(cd "$(dirname "$0")" && pwd)
tag=$1 mode=${2#paw:} view=$3 n=$4 secs=$5
[ -n "$secs" ] && [ -n "$BASEBIN" ] && [ -n "$NEWBIN" ] || {
  echo "usage: BASEBIN=<dir> NEWBIN=<dir> pairs.sh <tag> <mode> <view> <n> <secs>" >&2; exit 2; }
size=${W:-1500}x${H:-960}
run() {
  if [ -n "$LOCK" ]; then flock "$LOCK" "$@"; else "$@"; fi
}
i=1
while [ "$i" -le "$n" ]; do
  BIN=$BASEBIN run sh "$D/paw.sh" "$mode" "$view" "$tag-$i-base-paw-$mode-$view-$size" "$secs"
  BIN=$NEWBIN run sh "$D/paw.sh" "$mode" "$view" "$tag-$i-new-paw-$mode-$view-$size" "$secs"
  i=$((i + 1))
done
