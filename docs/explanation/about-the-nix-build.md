# About the Nix build

<!-- tags: crane nix-build -->

paw has more than five hundred Rust dependencies, LuaJIT among them. A
build that compiles all of them for each change of paw is slow. The flake
uses [crane](https://github.com/ipetkov/crane) to put the build in layers.

## Two layers

The first layer is the dependencies. crane compiles every crate that the
workspace depends on one time, into a derivation of its own
(`.#default.deps`). This derivation changes only when `Cargo.toml`,
`Cargo.lock` or `.cargo` change.

The second layer is paw's own crates. The programs and each check start
from the first layer and compile only these crates. A change to a crate or
to the Lua runtime compiles only these few crates again.

The extensions, the examples and the configuration are not in the Rust
build. The package copies them next to the programs. So a change to an
extension copies files and compiles nothing.

## Why crane

Two other tools can build a Rust workspace with Nix:

- crate2nix makes a derivation for each crate. Its cache is finer. But it
  needs a generated file that agrees with `Cargo.lock`. It also needs an
  override for each crate with a build script. LuaJIT, bindgen and the
  scripts that write library paths into the binaries are examples.
- naersk makes the same two layers as crane, with less work to keep it. But
  it has no checks.

crane gives the two layers and the checks (clippy, rustfmt, nextest) with
little work. The dependencies have no git sources, so no hash must be
written by hand.

## Why the tests do not run in the build

The Lua suite and the tests of the graphical window need an X server,
plugins and directories of their own. A build sandbox has none of these.
So `nix flake check` runs only the Rust tests that need none of them, and
the full tests run in the dev shell.

## See also

- [The Nix package](../reference/nix-package.md).
- [How to install paw with Nix](../how-to/install-paw.md).
