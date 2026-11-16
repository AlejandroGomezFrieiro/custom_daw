#!/usr/bin/env bash
# Fetch Tracktion Engine (with its JUCE submodule) into third_party/, which git
# ignores, and build the te_bench driver in Release mode.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
te="$root/third_party/tracktion_engine"
build="$root/third_party/build-te_bench"

if [ ! -d "$te/modules/juce/modules" ]; then
  mkdir -p "$root/third_party"
  git clone --depth 1 --recurse-submodules --shallow-submodules \
    https://github.com/Tracktion/tracktion_engine.git "$te"
fi

if [ -z "${IN_NIX_SHELL:-}" ]; then
  nixpkgs="$(nix eval --raw --impure --expr '(builtins.getFlake "nixpkgs").outPath')"
  exec env NIX_PATH="nixpkgs=$nixpkgs" nix-shell "$here/shell.nix" --run "$0 $*"
fi

cmake -S "$here" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build "$build" --target te_bench
ls -l "$build"/te_bench_artefacts/Release/te_bench
