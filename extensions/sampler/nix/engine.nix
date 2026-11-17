# paw-sampler: the sample player as a CLAP plugin (lib/clap/paw-sampler.clap)
# and its command (bin/paw-sampler), built from extensions/sampler/native.
{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "paw-sampler";
  version = "0.1.0";
  src = lib.cleanSource ../native;
  cargoLock.lockFile = ../native/Cargo.lock;
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
}
