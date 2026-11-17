#!/bin/sh
# Make tests/fixture.json again: what a kernel with tests/fixture.lua tells
# a window (daw.frontend.state, the clip in the piano roll, the palette).
# Run from the checkout after a change to what the kernel tells.
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
bin=${DAW_TEST_BIN:-$root/target/release}
scratch=$(mktemp -d)
export XDG_CACHE_HOME=$scratch/cache XDG_STATE_HOME=$scratch/state XDG_DATA_HOME=$scratch/data XDG_CONFIG_HOME=$scratch/config
cd "$root" || exit 1
"$bin/daw" --headless --clean --no-plugins --audio null --listen "$scratch/sock" -e "dofile('$here/fixture.lua')" > "$scratch/out" 2>&1 &
kernel=$!
for _ in $(seq 100); do [ -S "$scratch/sock" ] && break; sleep 0.1; done
"$bin/daw" ctl --socket "$scratch/sock" eval "
local a = daw.tracks()[1]
local clip = daw.api.clip_list(a.id)[1].id
daw.frontend.act.open_clip(clip)
return daw.api.json_encode({
  state = daw.frontend.state(-1),
  clip = daw.frontend.clip(clip),
  palette = daw.canvas.palette,
}, true)" > "$here/fixture.json"
kill $kernel
rm -rf "$scratch"
