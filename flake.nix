{
  description = "daw: a hackable DAW with a small Rust kernel and everything else in Lua";

  inputs.nixpkgs.url = "nixpkgs";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});

      # The graphical frontend loads its windowing libraries at run time.
      # `libglvnd` is libGL and libEGL for `--renderer gpu`; they find the
      # system's driver themselves (on NixOS in /run/opengl-driver), which
      # must match the machine and so is not named here.
      guiLibs = pkgs: with pkgs; [
        wayland libxkbcommon fontconfig libx11 libxcursor libxi libxcb libglvnd
      ];
      # Plugins built elsewhere open the display's libraries by name when
      # they make a window, and name others as needed. Nothing is on the
      # loader's path on NixOS, so the build writes down where these are
      # (`crates/daw-plugins/src/libs.rs`).
      pluginLibs = pkgs: with pkgs; [
        libx11 libxext libxrender libxrandr libxinerama libxcursor libxcomposite
        libxfixes libxi libxcb libGL alsa-lib fontconfig freetype zlib curl
        stdenv.cc.cc.lib
      ];

      # The whole workspace in one build: `daw` (the terminal, `--headless`,
      # `ctl`), `daw-gui` and `daw-mcp`.
      daw = pkgs: pkgs.rustPlatform.buildRustPackage {
        pname = "daw";
        version = "0.1.0";
        # Only what the build reads, so that a change to the manual does not
        # rebuild the program. The runtime's Lua is compiled into the binary
        # (`include_dir!`); the extensions and examples are installed.
        src = pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions [
            ./Cargo.toml ./Cargo.lock ./.cargo ./crates ./runtime ./extensions ./examples ./config
          ];
        };
        cargoLock.lockFile = ./Cargo.lock;
        nativeBuildInputs = with pkgs; [ pkg-config rustPlatform.bindgenHook makeBinaryWrapper patchelf ];
        buildInputs = with pkgs; [ alsa-lib pipewire lilv lv2 serd sord sratom fontconfig ];
        # The window's build script writes where its libraries are into the
        # binary, so that it runs from any shell; so does the plugin host.
        DAW_GUI_LIBS = pkgs.lib.makeLibraryPath (guiLibs pkgs);
        DAW_PLUGIN_LIB_DIRS = pkgs.lib.makeLibraryPath (pluginLibs pkgs);
        # `.cargo/config.toml` sets this for LuaJIT; saying it here as well
        # makes it hold however cargo is set up in the build, because
        # without it `daw.limit` cannot stop a compiled loop.
        TARGET_CFLAGS = "-DLUAJIT_ENABLE_CHECKHOOK";
        # The tests drive a private X server, plugins and audio devices,
        # which a build sandbox has none of. They run in the dev shell.
        doCheck = false;
        postInstall = ''
          mkdir -p $out/share/daw
          cp -r extensions examples config $out/share/daw/
          # `DAW_HOME` is where `daw doctor` finds its script. ffmpeg is
          # there for MP3, Ogg and Opus export (no codec is linked into the
          # program); it goes last on the PATH, so that the user's own wins.
          for bin in daw daw-gui daw-mcp; do
            wrapProgram $out/bin/$bin \
              --set-default DAW_HOME $out/share/daw \
              --suffix PATH : ${pkgs.lib.makeBinPath [ pkgs.ffmpeg-headless ]}
          done
        '';
        # The fixup phase trims the binaries' library paths to what they are
        # linked against, which drops the window's: it opens those by name.
        # They are put back here, after it.
        postFixup = ''
          patchelf --add-rpath ${pkgs.lib.makeLibraryPath (guiLibs pkgs)} $out/bin/.daw-gui-wrapped
        '';
        meta = {
          description = "A hackable DAW with a small Rust kernel and everything else in Lua";
          license = with pkgs.lib.licenses; [ mit asl20 ];
          mainProgram = "daw";
          platforms = [ "x86_64-linux" "aarch64-linux" ];
        };
      };

      # One program of that build, by name.
      only = pkgs: name: pkgs.runCommand name { meta.mainProgram = name; } ''
        mkdir -p $out/bin
        ln -s ${daw pkgs}/bin/${name} $out/bin/${name}
      '';
    in {
      packages = forAll (pkgs: {
        default = daw pkgs;
        daw = only pkgs "daw";
        daw-gui = only pkgs "daw-gui";
        daw-mcp = only pkgs "daw-mcp";
      });

      apps = forAll (pkgs:
        nixpkgs.lib.genAttrs [ "daw" "daw-gui" "daw-mcp" ] (name: {
          type = "app";
          program = "${only pkgs name}/bin/${name}";
        }) // { default = { type = "app"; program = "${daw pkgs}/bin/daw"; }; });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [ cargo rustc clippy rustfmt rust-analyzer pkg-config rustPlatform.bindgenHook ffmpeg-headless ];
          # What the window tests (`crates/daw-gui/tests/window.rs`) drive: a
          # private X server, a window manager, a pointer and key sender, and
          # tesseract to find words on a screenshot.
          packages = with pkgs; [ xvfb openbox xdotool imagemagick tesseract ];
          buildInputs = with pkgs; [ alsa-lib pipewire lilv lv2 serd sord sratom fontconfig ];
          # The graphical frontend's libraries are on the path here;
          # `DAW_GUI_LIBS` is where its build script finds them, to write
          # into the binary, so that the binary also runs from a shell that
          # is not this one.
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (guiLibs pkgs);
          DAW_GUI_LIBS = pkgs.lib.makeLibraryPath (guiLibs pkgs);
          DAW_PLUGIN_LIB_DIRS = pkgs.lib.makeLibraryPath (pluginLibs pkgs);
          # Plugins in all three formats for the test suite to host.
          DAW_TEST_PLUGINS = "${pkgs.lsp-plugins}/lib:${pkgs.surge-xt}/lib";
        };
      });
    };
}
