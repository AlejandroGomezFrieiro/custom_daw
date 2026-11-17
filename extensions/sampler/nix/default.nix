# extensions/sampler as a package: its Lua, with the plugin it plays
# through in `clap/` beside it, where the extension looks for it first.
# What `paw.withExtensions (exts: [ exts.sampler ])` puts in the program.
{ lib, runCommand, callPackage, craneLib }:

let
  engine = callPackage ./engine.nix { inherit craneLib; };
  # The extension as the program loads it: the plugin's source and the
  # packaging stay behind.
  lua = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.difference ../. (lib.fileset.unions [ ../native ../nix ]);
  };
in
runCommand "paw-extension-sampler" {
  passthru = {
    extensionName = "sampler";
    inherit engine;
  };
  meta = {
    description = "paw's sample player: SFZ and Decent Sampler instruments, articulations per note";
    license = with lib.licenses; [ mit asl20 ];
  };
} ''
  dir=$out/share/daw/extensions/sampler
  mkdir -p $out/share/daw/extensions
  cp -r ${lua} $dir
  chmod -R u+w $dir
  ln -s ${engine}/lib/clap $dir/clap
  mkdir -p $dir/bin
  ln -s ${engine}/bin/paw-sampler $dir/bin/paw-sampler
''
