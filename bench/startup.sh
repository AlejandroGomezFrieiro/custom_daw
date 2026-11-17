#!/usr/bin/env bash
# Startup time: from exec to exit of a script that does nothing, median of N.
#   bench/startup.sh <paw binary> [te_bench binary] [runs]
# Prints JSON lines. Run inside `nix develop` for the plugin case: it reads
# PAW_TEST_PLUGINS (LSP Plugins and Surge XT) like the test suite does.
set -euo pipefail
paw="$1"
te="${2:-}"
runs="${3:-10}"
tmp="${BENCH_TMP:-/tmp/paw-bench}/startup"
rm -rf "$tmp"
mkdir -p "$tmp/cache" "$tmp/home"
echo 'paw.api.quit(0)' > "$tmp/empty.lua"

ms() { date +%s%N; }

# Median wall time, in ms, of running "$@" $runs times.
median() {
  local times=()
  for _ in $(seq "$runs"); do
    local t0 t1
    t0=$(ms)
    "$@" > /dev/null 2>&1
    t1=$(ms)
    times+=("$(( (t1 - t0) / 1000 ))")
  done
  printf '%s\n' "${times[@]}" | sort -n | awk '{a[NR]=$1} END {printf "%.1f", a[int((NR+1)/2)]/1000}'
}

export XDG_CACHE_HOME="$tmp/cache" XDG_DATA_HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home"

echo "{\"engine\":\"paw\",\"workload\":\"startup\",\"plugins\":\"none\",\"ms\":$(median "$paw" --clean --no-plugins -l "$tmp/empty.lua")}"

if [ -n "${PAW_TEST_PLUGINS:-}" ]; then
  paths() { local out=(); IFS=: read -ra dirs <<< "$PAW_TEST_PLUGINS"; for d in "${dirs[@]}"; do out+=("$d/$1"); done; (IFS=:; echo "${out[*]}"); }
  export CLAP_PATH="$(paths clap)" LV2_PATH="$(paths lv2)" VST3_PATH="$(paths vst3)"
  # Cold: an empty scan cache every time.
  cold() { rm -rf "$XDG_CACHE_HOME/paw"; "$paw" --clean -l "$tmp/empty.lua"; }
  echo "{\"engine\":\"paw\",\"workload\":\"startup\",\"plugins\":\"cold scan\",\"ms\":$(median cold)}"
  "$paw" --clean -l "$tmp/empty.lua" > /dev/null 2>&1
  echo "{\"engine\":\"paw\",\"workload\":\"startup\",\"plugins\":\"cached scan\",\"ms\":$(median "$paw" --clean -l "$tmp/empty.lua")}"
fi

if [ -n "$te" ]; then
  # Tracktion keeps its settings under $HOME/.config/te_bench.
  echo "{\"engine\":\"tracktion\",\"workload\":\"startup\",\"plugins\":\"none\",\"ms\":$(HOME="$tmp/home" median "$te" startup)}"
fi
