# How to install paw with Nix

<!-- tags: installing-with-nix install -->

This guide shows you how to install paw from its flake. You need Linux with
Nix and flakes. You do not need NixOS or home-manager.

Do these steps in a checkout of paw's source. There, `.` is the flake.

1. To try paw before you install it, run `nix run .`.
   This starts the terminal interface, `paw`.
2. To try the graphical window, run `nix run .#paw-gui`.
3. To build the programs without an install, run `nix build`.
   The programs are in `./result/bin`: `paw`, `paw-gui` and `paw-mcp`.
4. To install the three programs in your profile, run `nix profile install .`.
5. Run `paw` from any shell.

The graphical window starts its own kernel, which is the `paw` program next
to it. You do not have to install anything more for it.

If the graphical window does not open on NixOS, set
`hardware.graphics.enable = true` in your system configuration. The window
uses the OpenGL driver of the system.

To remove the programs from your profile, run `nix profile remove paw`.

## See also

- [The Nix package](../reference/nix-package.md): the outputs of the flake and what each package holds.
- [How to build and run paw from the source](build-paw-from-source.md): the dev shell, for work on paw itself.
- [About the Nix build](../explanation/about-the-nix-build.md): why the build has two layers.
