# Sourced by the scripts beside it. Everything a test run writes goes under
# the checkout's own `target/test-scratch` (or $DAW_TEST_SCRATCH), never into
# the home directory, and the window is only ever shown on a private display.
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRATCH=${DAW_TEST_SCRATCH:-$ROOT/target/test-scratch}
mkdir -p "$SCRATCH/xdg" "$SCRATCH/shots"
export XDG_CACHE_HOME=$SCRATCH/xdg/cache XDG_STATE_HOME=$SCRATCH/xdg/state
export XDG_DATA_HOME=$SCRATCH/xdg/data XDG_CONFIG_HOME=$SCRATCH/xdg/config
# Checkouts tested side by side each need a display number of their own.
DAW_TEST_DISPLAY=${DAW_TEST_DISPLAY:-96}
BIN=${DAW_TEST_BIN:-$ROOT/target/release}
