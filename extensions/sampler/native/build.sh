#!/bin/sh
# Builds the sampler and puts it where the extension looks for it, as the
# Nix package does: ../clap/paw-sampler.clap and ../bin/paw-sampler.
#
#   extensions/sampler/native/build.sh        from the source tree
#
# The build goes into the source tree's target/sampler (or $CARGO_TARGET_DIR).
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
target=${CARGO_TARGET_DIR:-$root/target/sampler}
cd "$here" || exit 1
CARGO_TARGET_DIR=$target nix develop "$root" -c cargo build --release -j "${JOBS:-4}" || exit 1
mkdir -p "$here/../clap" "$here/../bin"
cp "$target/release/libpaw_sampler.so" "$here/../clap/paw-sampler.clap"
cp "$target/release/paw-sampler" "$here/../bin/paw-sampler"
echo "built $here/../clap/paw-sampler.clap"
