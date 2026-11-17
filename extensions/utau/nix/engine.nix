# reautau-engine: the .NET program that sings, hosting OpenUtau.Core. Its
# source is extensions/utau/engine (from ReaUtau, see engine/README.md);
# OpenUtau is the flake's `openutau` input, pinned to the commit ReaUtau
# builds against. Modelled on ReaUtau's own nix/engine.nix.
#
# After changing a package reference, write the NuGet lock again:
#   nix build .#utau-engine.fetch-deps && ./result extensions/utau/engine/nix/engine-deps.json
{ lib
, stdenv
, buildDotnetModule
, dotnetCorePackages
, autoPatchelfHook
, runCommand
, fontconfig
, portaudio
, zlib
, openutau   # OpenUtau's source tree
}:

let
  # The engine's projects name OpenUtau's as ../../third_party/OpenUtau, as
  # in ReaUtau's tree: the same layout, made of the two sources.
  src = runCommand "utau-engine-source" { } ''
    mkdir -p $out/third_party
    cp -r ${lib.cleanSource ../engine} $out/engine
    cp -r ${openutau} $out/third_party/OpenUtau
    chmod -R u+w $out
  '';
in
buildDotnetModule {
  pname = "reautau-engine";
  version = "0.1.0";
  inherit src;
  sourceRoot = "${src.name}/engine";
  # OpenUtau's projects are built too, beside the source root.
  postUnpack = "chmod -R u+w ${src.name}";

  dotnet-sdk = dotnetCorePackages.sdk_10_0;
  dotnet-runtime = dotnetCorePackages.runtime_10_0;

  projectFile = "ReaUtau.Engine/ReaUtau.Engine.csproj";
  nugetDeps = ../engine/nix/engine-deps.json;

  # OpenUtau's projects race on *.deps.json when built in parallel.
  enableParallelBuilding = false;

  executables = [ "reautau-engine" ];
  dotnetInstallFlags = [ "-p:PublishReadyToRun=false" ];

  # GPU execution providers are optional and loaded only if there; the
  # engine runs ONNX models on the CPU.
  autoPatchelfIgnoreMissingDeps = [ "libcublas*.so*" "libcudart*.so*" "libcudnn*.so*" "libcurand*.so*" "libcufft*.so*" "libnvinfer*.so*" "libnvonnxparser*.so*" ];

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib zlib ];
  runtimeDeps = [ stdenv.cc.cc.lib zlib fontconfig portaudio ];

  # OpenUtau.Core brings SDL3 for playback, which the engine never uses.
  preFixup = "rm -f $out/lib/reautau-engine/libSDL3*.so*";

  postInstall = ''
    # OpenUtau's own build of worldline, which its code is built against.
    wl=../third_party/OpenUtau/runtimes/${if stdenv.hostPlatform.isAarch64 then "linux-arm64" else "linux-x64"}/native/libworldline.so
    install -Dm755 $wl $out/lib/reautau-engine/libworldline.so
  '';

  meta = {
    description = "The singing engine of paw's utau extension (OpenUtau.Core, from ReaUtau)";
    license = lib.licenses.mit;
    mainProgram = "reautau-engine";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
