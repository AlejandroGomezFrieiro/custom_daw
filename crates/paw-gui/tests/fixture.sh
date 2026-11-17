#!/bin/sh
# Make tests/fixture.json again: what a kernel with tests/fixture.lua tells
# a window (paw.frontend.state, the clip in the piano roll, the palette).
# Run from the checkout after a change to what the kernel tells.
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
bin=${PAW_TEST_BIN:-$root/target/release}
scratch=$(mktemp -d)
export XDG_CACHE_HOME=$scratch/cache XDG_STATE_HOME=$scratch/state XDG_DATA_HOME=$scratch/data XDG_CONFIG_HOME=$scratch/config
cd "$root" || exit 1
"$bin/paw" --headless --clean --no-plugins --audio null --listen "$scratch/sock" -e "dofile('$here/fixture.lua')" > "$scratch/out" 2>&1 &
kernel=$!
for _ in $(seq 100); do [ -S "$scratch/sock" ] && break; sleep 0.1; done
"$bin/paw" ctl --socket "$scratch/sock" eval "
local a = paw.tracks()[1]
local clip = paw.api.clip_list(a.id)[1].id
paw.frontend.act.open_clip(clip)
return paw.api.json_encode({
  state = paw.frontend.state(-1),
  clip = paw.frontend.clip(clip),
  palette = paw.canvas.palette,
}, true)" > "$here/fixture.json"
kill $kernel
rm -rf "$scratch"
