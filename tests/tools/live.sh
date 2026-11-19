#!/bin/sh
# Run the live tests of a web API, with the plugins of the dev shell.
#
#   tests/tools/live.sh tone3000
#       the tests of TONE3000 with the sign-in of :plugstate.tone3000_login,
#       from the keyring, else from $XDG_STATE_HOME/paw/tone3000-session.json
#   TONE3000_TOKEN_FILE=<file> tests/tools/live.sh tone3000
#       the same with the token of a file of mode 600
#
# The tests go to the network, make a few requests and download one small
# model into their scratch cache. Everything else is as in suite.sh: a
# scratch HOME and XDG folders, no audio, no display. The output is in
# target/test-scratch/suite.out. See docs/how-to/sign-in-to-tone3000.md.
case "$1" in
  tone3000) ;;
  *) echo "usage: tests/tools/live.sh tone3000" >&2; exit 2 ;;
esac
# The sign-in is where paw keeps it for the person who runs this: find it
# before env.sh gives the tests scratch folders. The keyring needs the
# session bus; these tests open no window, so no dialog of the desktop opens.
if [ -z "${TONE3000_TOKEN_FILE:-}" ]; then
  state=${XDG_STATE_HOME:-$HOME/.local/state}
  export PAW_TEST_TONE3000_LIVE=1
  export PAW_TEST_TONE3000_SESSION_FILE="${PAW_TEST_TONE3000_SESSION_FILE:-$state/paw/tone3000-session.json}"
  if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v secret-tool >/dev/null 2>&1; then
    export PAW_TEST_TONE3000_KEYRING=1 PAW_TEST_BUS="$DBUS_SESSION_BUS_ADDRESS"
  fi
fi
exec "$(dirname "$0")/suite.sh" plugins "plugstate live:"
