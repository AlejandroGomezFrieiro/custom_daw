#!/bin/sh
# Run the suite N times with every core busy, to show up tests that depend
# on timing: tests/tools/loaded.sh 2
. "$(dirname "$0")/env.sh"
pids=""
for i in $(seq "${2:-40}"); do (while :; do :; done) & pids="$pids $!"; done
trap 'kill $pids 2>/dev/null' EXIT INT TERM
for run in $(seq "${1:-1}"); do
  printf 'run %s: ' "$run"
  "$(dirname "$0")/suite.sh" | tail -12
done
