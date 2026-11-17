# paw-sampler: the sample player as a CLAP plugin (lib/clap/paw-sampler.clap)
# and its command (bin/paw-sampler), built from extensions/sampler/native.
# With crane, as paw itself is: its dependencies are built once, in a
# derivation of their own, and a change to the sampler's code compiles only
# the sampler.
{ lib, craneLib }:

let
  src = lib.cleanSource ../native;
  cargoVendorDir = craneLib.vendorCargoDeps { inherit src; };
  common = {
    inherit src cargoVendorDir;
    pname = "paw-sampler";
    version = "0.1.0";
    strictDeps = true;
    # As paw's own build (flake.nix): frame pointers, and short paths for
    # the crates in panic locations.
    RUSTFLAGS = "-Cforce-frame-pointers=yes --remap-path-prefix=${cargoVendorDir}/${builtins.hashString "sha256" "registry+https://github.com/rust-lang/crates.io-index"}=/cargo-vendor";
  };
in
craneLib.buildPackage (common // {
  cargoArtifacts = craneLib.buildDepsOnly common;
  postInstall = ''
    mkdir -p $out/lib/clap
    mv $out/lib/libpaw_sampler.so $out/lib/clap/paw-sampler.clap
    rm -f $out/lib/libpaw_sampler.rlib
  '';
  meta = {
    description = "paw's sample player: SFZ and Decent Sampler instruments as a CLAP plugin";
    license = with lib.licenses; [ mit asl20 ];
    mainProgram = "paw-sampler";
    platforms = lib.platforms.linux;
  };
})
