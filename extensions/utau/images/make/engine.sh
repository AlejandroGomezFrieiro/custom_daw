#!/bin/sh
# Sourced by the utau scenes after rig.sh: finds the engine and the singer,
# or ends the scene saying what is missing (so `make.sh all` goes on).
#
# The engine is $REAUTAU_ENGINE, or `nix build .#utau-engine` linked as
# target/utau-engine or result. The singer (UTAU_SINGER, Kitane sno act5
# VCV unless set) is copied from OpenUtau's folder into the scratch
# directory and the engine pointed there: nothing the engine writes can
# land among your voicebanks, and its data and cache are the scene's too.
SINGER=${UTAU_SINGER:-Kitane sno act5 VCV}
SINGERS=${REAUTAU_OPENUTAU_DIR:-$HOME/.local/share/OpenUtau}/Singers
ENGINE=
for e in "$REAUTAU_ENGINE" "$ROOT/target/utau-engine/bin/reautau-engine" "$ROOT/result/bin/reautau-engine"; do
  if [ -n "$e" ] && [ -x "$e" ]; then ENGINE=$e; break; fi
done
if [ -z "$ENGINE" ] || [ ! -d "$SINGERS/$SINGER" ]; then
  echo "$(basename "$0" .sh): skipped: needs the engine (nix build .#utau-engine -o target/utau-engine) and the singer \"$SINGER\" in $SINGERS"
  exit 0
fi
OPENUTAU=$WORK/openutau
if [ ! -d "$OPENUTAU/Singers/$SINGER" ]; then
  mkdir -p "$OPENUTAU/Singers" && cp -r "$SINGERS/$SINGER" "$OPENUTAU/Singers/"
fi
export REAUTAU_ENGINE="$ENGINE" REAUTAU_OPENUTAU_DIR="$OPENUTAU"
# The engine's socket goes in the runtime directory, and a socket's path
# must be short.
XDG_RUNTIME_DIR=$(mktemp -d)
SOCK=$XDG_RUNTIME_DIR/k.sock
export XDG_RUNTIME_DIR
