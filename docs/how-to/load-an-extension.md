# How to load an extension

This guide shows you how to load an extension. The extension can be
bundled, your own, or in a Nix package. [Extensions](../reference/extensions.md)
lists the bundled extensions.

## A bundled extension, for this session

1. Type `:ext.load ` and the name, for example `:ext.load notation`. Tab
   completes the names.
2. To see what loaded, type `:extensions`.

If paw says that there is no bundled extension, set `PAW_HOME` to the
source tree of paw.

## A bundled extension, for each session

Do one of these:

- Add `paw.ext.load("/path/to/paw/extensions/notation")` to your `init.lua`.
- Link or copy the directory into `~/.config/paw/extensions`.

## An extension of your own

1. Make a directory in `~/.config/paw/extensions`, for example
   `~/.config/paw/extensions/euclid`.
2. Write its `init.lua`. paw runs it at startup.
3. To give it a version and requirements, write a `manifest.lua` beside
   `init.lua`. See [Manifests and
   versions](../reference/extensions.md#manifests-and-versions).
4. To run it again after a change, type `:reload`.

An extension with one file is also possible:
`~/.config/paw/extensions/clock.lua`.

## With Nix

To build paw with some extensions, use `withExtensions`:

```nix
paw.packages.${system}.default.withExtensions (exts: [ exts.utau ])
```

In home-manager, with the `homeManagerModules.default` of the flake:

```nix
programs.paw = { enable = true; extensions = [ "utau" ]; };
```

To try paw with utau without an install, type `nix run .#paw-utau` in the
source tree.

paw loads a packaged extension at each start, before your configuration.
`--clean` does not stop it.

## Unload an extension

1. Type `:ext.unload name`.
2. If paw refuses because devices of the extension are on tracks, remove
   the devices, or type `:ext.unload! name`.

**CAUTION:** After `:ext.unload!`, the devices of the extension stay on
their tracks until you remove them. A project saved with them opens
without them when the extension is not loaded.
