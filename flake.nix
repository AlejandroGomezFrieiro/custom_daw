{
  description = "daw: a hackable DAW with a small Rust kernel and everything else in Lua";

  inputs.nixpkgs.url = "nixpkgs";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in {
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [ cargo rustc clippy rustfmt rust-analyzer pkg-config rustPlatform.bindgenHook ];
          # What the window tests (`crates/daw-gui/tests/window.rs`) drive: a
          # private X server, a window manager, a pointer and key sender.
          packages = with pkgs; [ xvfb openbox xdotool imagemagick ];
          buildInputs = with pkgs; [ alsa-lib pipewire lilv lv2 serd sord sratom fontconfig ];
          # The graphical frontend loads its windowing libraries at run time.
          # Here they are on the path; `DAW_GUI_LIBS` is where its build
          # script finds them, to write into the binary, so that the binary
          # also runs from a shell that is not this one.
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (with pkgs; [
            wayland libxkbcommon fontconfig libx11 libxcursor libxi libxcb
          ]);
          DAW_GUI_LIBS = pkgs.lib.makeLibraryPath (with pkgs; [
            wayland libxkbcommon fontconfig libx11 libxcursor libxi libxcb
          ]);
          # Plugins built elsewhere open the display's libraries by name
          # when they make a window, and name others as needed. Nothing is
          # on the loader's path here, so the build writes down where these
          # are (`crates/daw-plugins/src/libs.rs`).
          DAW_PLUGIN_LIB_DIRS = pkgs.lib.makeLibraryPath (with pkgs; [
            libx11 libxext libxrender libxrandr libxinerama libxcursor libxcomposite
            libxfixes libxi libxcb libGL alsa-lib fontconfig freetype zlib curl
            stdenv.cc.cc.lib
          ]);
          # Plugins in all three formats for the test suite to host.
          DAW_TEST_PLUGINS = "${pkgs.lsp-plugins}/lib:${pkgs.surge-xt}/lib";
        };
      });
    };
}
