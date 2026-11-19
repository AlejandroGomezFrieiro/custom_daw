# Sourced by the scripts beside it. Everything a test run writes goes under
# the checkout's own `target/test-scratch` (or $PAW_TEST_SCRATCH), never into
# the home directory, and the window is only ever shown on a private display.
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRATCH=${PAW_TEST_SCRATCH:-$ROOT/target/test-scratch}
mkdir -p "$SCRATCH/xdg" "$SCRATCH/shots"
export XDG_CACHE_HOME=$SCRATCH/xdg/cache XDG_STATE_HOME=$SCRATCH/xdg/state
export XDG_DATA_HOME=$SCRATCH/xdg/data XDG_CONFIG_HOME=$SCRATCH/xdg/config
# The window asks the desktop for its file dialogs over the session bus:
# a test must never reach the real desktop's, where a dialog would open
# in front of the person at the machine.
# Only tests/tools/live.sh keeps the bus, for the keyring, in a run that
# opens no window.
export DBUS_SESSION_BUS_ADDRESS="${PAW_TEST_BUS:-unix:path=/nonexistent/bus}"
# Checkouts tested side by side each need a display number of their own.
PAW_TEST_DISPLAY=${PAW_TEST_DISPLAY:-96}
BIN=${PAW_TEST_BIN:-$ROOT/target/release}
