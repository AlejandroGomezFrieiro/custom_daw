#!/usr/bin/env bash
# Run Vale on paw's documentation with the project's styles:
#
#   tools/vale.sh                      every page (docs/, READMEs)
#   tools/vale.sh docs/how-to/*.md     some pages
#   tools/vale.sh --minAlertLevel=suggestion docs/README.md
#
# The style packages come from Nix ($PAW_VALE_STYLES, set by the dev shell);
# the project's own (STE) and its vocabulary are in .vale/styles. Vale takes
# one styles folder, so this joins the two in target/vale-styles.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [ -z "${PAW_VALE_STYLES:-}" ]; then
  echo "tools/vale.sh: run it in the dev shell (nix develop), which sets PAW_VALE_STYLES" >&2
  exit 2
fi
styles=target/vale-styles
rm -rf "$styles"
mkdir -p "$styles"
for d in "$PAW_VALE_STYLES"/* .vale/styles/*; do ln -s "$(realpath "$d")" "$styles/$(basename "$d")"; done
export VALE_STYLES_PATH="$root/$styles"
files=()
opts=()
for a in "$@"; do
  case "$a" in -*) opts+=("$a") ;; *) files+=("$a") ;; esac
done
if [ ${#files[@]} -eq 0 ]; then
  files=(README.md docs crates/*/README.md extensions/*/README.md)
fi
exec vale --config "$root/.vale.ini" "${opts[@]}" "${files[@]}"
