#!/usr/bin/env bash
# The reliability runs: the fuzzer over several seeds, the abuse cases, a soak.
#   nix develop -c bench/stress.sh [seeds] [steps] [soak minutes]
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
daw="$here/../target/release/daw"
seeds="${1:-20}"
steps="${2:-1500}"
minutes="${3:-3}"
export BENCH_TMP="${BENCH_TMP:-/tmp/daw-bench}"
mkdir -p "$BENCH_TMP/home"
export XDG_CACHE_HOME="$BENCH_TMP/home/cache" XDG_DATA_HOME="$BENCH_TMP/home/data" XDG_CONFIG_HOME="$BENCH_TMP/home/config"
failed=0

for seed in $(seq "$seeds"); do
  out=$(timeout 900 "$daw" --clean --no-plugins -l "$here/fuzz.lua" "$seed" "$steps" 2>&1)
  code=$?
  line=$(printf '%s\n' "$out" | grep '^{' | tail -1)
  if [ "$code" != 0 ] || [[ "$line" != *'"failed":false'* ]]; then
    failed=$((failed + 1))
    echo "fuzz seed $seed: exit $code"
    printf '%s\n' "$out" | tail -5
  else
    echo "$line"
  fi
done

"$here/abuse.sh" "$daw" 60 || failed=$((failed + 1))

timeout $((minutes * 60 + 120)) "$daw" --clean --no-plugins -l "$here/soak.lua" "$minutes" || failed=$((failed + 1))

echo "stress: $failed failed" >&2
[ "$failed" = 0 ]
