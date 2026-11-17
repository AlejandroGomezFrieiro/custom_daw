{
  description = "paw, a personal audio workstation, with a small Rust kernel and everything else in Lua";

  inputs.nixpkgs.url = "nixpkgs";
  # What extensions/utau's engine is built against: the OpenUtau commit
  # ReaUtau pins (see extensions/utau/engine/README.md).
  inputs.openutau = {
    url = "github:openutau/OpenUtau/bc194b6fe4897427a73066390b286e11205fd10f";
    flake = false;
  };

  outputs = { self, nixpkgs, openutau }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});

      # The graphical frontend loads its windowing libraries at run time.
      # `libglvnd` is libGL and libEGL, which the window draws with; they find
      # the system's driver themselves (on NixOS in /run/opengl-driver), which
      # must match the machine and so is not named here. `fontconfig` also
      # finds a font for Japanese and the like.
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
      daw = pkgs: pkgs.rustPlatform.buildRustPackage (finalAttrs: {
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
          # fc-list is how the window finds a font for Japanese and the like.
          for bin in daw daw-gui daw-mcp; do
            wrapProgram $out/bin/$bin \
              --set-default DAW_HOME $out/share/daw \
              --suffix PATH : ${pkgs.lib.makeBinPath [ pkgs.ffmpeg-headless pkgs.fontconfig.bin ]}
          done
        '';
        # The fixup phase trims the binaries' library paths to what they are
        # linked against, which drops the window's: it opens those by name.
        # They are put back here, after it.
        postFixup = ''
          patchelf --add-rpath ${pkgs.lib.makeLibraryPath (guiLibs pkgs)} $out/bin/.daw-gui-wrapped
        '';
        # The extensions as packages, and the program with some of them:
        # `paw.withExtensions (exts: [ exts.utau ])`.
        passthru = {
          extensions = extensionsFor pkgs;
          withExtensions = pick: withExtensions pkgs finalAttrs.finalPackage (pick (extensionsFor pkgs));
        };
        meta = {
          description = "A hackable DAW with a small Rust kernel and everything else in Lua";
          license = with pkgs.lib.licenses; [ mit asl20 ];
          mainProgram = "daw";
          platforms = [ "x86_64-linux" "aarch64-linux" ];
        };
      });

      # Every extension as a package holding `share/daw/extensions/<name>`.
      # Most are Lua and nothing else; one with native parts (an engine to
      # build, a library) has a `nix/default.nix` of its own, given the
      # flake's inputs it asks for.
      extensionsFor = pkgs:
        let
          lib = pkgs.lib;
          dirs = lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./extensions);
          plain = name: pkgs.runCommand "paw-extension-${name}" { passthru.extensionName = name; } ''
            mkdir -p $out/share/daw/extensions
            cp -r ${./extensions + "/${name}"} $out/share/daw/extensions/${name}
          '';
          inputs = { inherit openutau; };
          own = name:
            let f = import (./extensions + "/${name}/nix");
            in pkgs.callPackage f (builtins.intersectAttrs (builtins.functionArgs f) inputs);
        in
        lib.mapAttrs (name: _:
          if builtins.pathExists (./extensions + "/${name}/nix/default.nix") then own name else plain name) dirs;

      # The program with extensions: each one is loaded at startup from its
      # package (`DAW_EXTENSIONS`), before the configuration, whatever the
      # configuration says.
      withExtensions = pkgs: base: exts: pkgs.symlinkJoin {
        name = "paw-with-${pkgs.lib.concatMapStringsSep "-" (e: e.extensionName) exts}";
        paths = [ base ] ++ exts;
        nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
        postBuild = ''
          for bin in daw daw-gui daw-mcp; do
            rm $out/bin/$bin
            makeWrapper ${base}/bin/$bin $out/bin/$bin \
              --prefix DAW_EXTENSIONS : ${pkgs.lib.concatMapStringsSep ":" (e: "${e}/share/daw/extensions/${e.extensionName}") exts}
          done
        '';
        passthru = { extensions = exts; };
        meta = base.meta // { mainProgram = "daw"; };
      };

      # One program of that build, by name.
      only = pkgs: name: pkgs.runCommand name { meta.mainProgram = name; } ''
        mkdir -p $out/bin
        ln -s ${daw pkgs}/bin/${name} $out/bin/${name}
      '';

      # paw that sings: the program with extensions/utau and its engine.
      pawUtau = pkgs: (daw pkgs).withExtensions (exts: [ exts.utau ]);
    in {
      packages = forAll (pkgs: {
        default = daw pkgs;
        daw = only pkgs "daw";
        daw-gui = only pkgs "daw-gui";
        daw-mcp = only pkgs "daw-mcp";
        paw-utau = pawUtau pkgs;
        utau-engine = (extensionsFor pkgs).utau.engine;
        # extensions/sampler's plugin and command, on their own.
        paw-sampler = (extensionsFor pkgs).sampler.engine;
      });

      apps = forAll (pkgs:
        nixpkgs.lib.genAttrs [ "daw" "daw-gui" "daw-mcp" ] (name: {
          type = "app";
          program = "${only pkgs name}/bin/${name}";
        }) // {
          default = { type = "app"; program = "${daw pkgs}/bin/daw"; };
          paw-utau = { type = "app"; program = "${pawUtau pkgs}/bin/daw"; };
        });

      # For a home-manager configuration:
      #   programs.paw = { enable = true; extensions = [ "utau" ]; };
      homeManagerModules.default = { config, lib, pkgs, ... }:
        let cfg = config.programs.paw;
        in {
          options.programs.paw = {
            enable = lib.mkEnableOption "paw, a personal audio workstation";
            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
              description = "The program, without extensions.";
            };
            extensions = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "utau" ];
              description = "Extensions to build in and load at startup, with whatever they need (utau: OpenUtau and its engine).";
            };
          };
          config = lib.mkIf cfg.enable {
            home.packages = [
              (if cfg.extensions == [ ] then cfg.package
               else cfg.package.withExtensions (exts: map (name: exts.${name}) cfg.extensions))
            ];
          };
        };

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [ cargo rustc clippy rustfmt rust-analyzer pkg-config rustPlatform.bindgenHook ffmpeg-headless sccache cargo-sweep ];
          # Every git worktree has a `target/` of its own, and cargo shares
          # nothing between them: each one compiles the same four hundred
          # crates again. sccache keeps what rustc made in one place, shared
          # by every checkout, with a ceiling on its size; it only caches
          # builds that are not incremental. `cargo sweep -t 14` clears what
          # no build has used for two weeks (tools/sweep.sh does every tree).
          RUSTC_WRAPPER = "sccache";
          SCCACHE_CACHE_SIZE = "40G";
          CARGO_INCREMENTAL = "0";
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
