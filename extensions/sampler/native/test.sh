#!/bin/sh
# The sampler's tests through paw: builds the plugin (build.sh), then runs
# the suite's `sampler:` tests with only the plugin on the plugin path, so
# that those that play are not skipped. Writes under target/test-scratch.
#
#   extensions/sampler/native/test.sh            every sampler test
#   extensions/sampler/native/test.sh "words"    those whose name holds the words
here=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$here/../../.." && pwd)
# What tests/tools/env.sh sets up: everything under target/test-scratch.
SCRATCH=${DAW_TEST_SCRATCH:-$ROOT/target/test-scratch}
mkdir -p "$SCRATCH/xdg"
export XDG_CACHE_HOME=$SCRATCH/xdg/cache XDG_STATE_HOME=$SCRATCH/xdg/state
export XDG_DATA_HOME=$SCRATCH/xdg/data XDG_CONFIG_HOME=$SCRATCH/xdg/config
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/bus
BIN=${DAW_TEST_BIN:-$ROOT/target/release}
"$here/build.sh" > /dev/null 2>&1 || { echo "the sampler did not build"; exit 1; }
cd "$ROOT" || exit 1
out=$SCRATCH/sampler.out
CLAP_PATH=$ROOT/extensions/sampler/clap LV2_PATH=$SCRATCH/none VST3_PATH=$SCRATCH/none \
  "$BIN/daw" --clean --audio null -l tests/suite.lua "sampler: ${1:-}" > "$out" 2>&1
code=$?
grep -E "^(ok|skip|FAIL)" "$out"
grep -A8 "^FAIL" "$out"
tail -1 "$out"
exit $code
