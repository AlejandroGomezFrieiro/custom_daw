#!/bin/sh
# Run the Lua end-to-end suite on the release build.
#
#   tests/tools/suite.sh                  every test, without plugins
#   tests/tools/suite.sh plugins          with the dev shell's test plugins
#   tests/tools/suite.sh plugins "words"  only some tests, with the plugins
#                                         (PAW_PLUGIN_SANDBOX=0 loads them in-process)
#   tests/tools/suite.sh only "loop on"   the tests whose name holds the words
#
# Prints the tests that failed and the last line ("all passed" or "N failed");
# the whole output is in target/test-scratch/suite.out.
. "$(dirname "$0")/env.sh"
cd "$ROOT" || exit 1
out=$SCRATCH/suite.out
case "$1" in
  plugins)
    nix develop -c sh -c '
      export CLAP_PATH=$(echo $PAW_TEST_PLUGINS | sed "s#:#/clap:#g")/clap
      export LV2_PATH=$(echo $PAW_TEST_PLUGINS | sed "s#:#/lv2:#g")/lv2
      export VST3_PATH=$(echo $PAW_TEST_PLUGINS | sed "s#:#/vst3:#g")/vst3
      "$0" --clean -l tests/suite.lua ${1+"$1"}' "$BIN/paw" ${2:+"$2"} > "$out" 2>&1 ;;
  only)
    "$BIN/paw" --clean --no-plugins -l tests/suite.lua "$2" > "$out" 2>&1 ;;
  *)
    "$BIN/paw" --clean --no-plugins -l tests/suite.lua > "$out" 2>&1 ;;
esac
code=$?
grep -A8 "^FAIL" "$out"
tail -1 "$out"
exit $code
