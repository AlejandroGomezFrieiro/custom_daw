# The singing engine

`paw-utau-engine`, the program that sings for extensions/utau: a host for
OpenUtau.Core (phonemizers, resamplers, DiffSinger and the other renderers)
that the extension talks to over a Unix socket (`lua/utau/proto.lua` on
this side, `PawUtau.Protocol` on that one).

- It began as the engine of an earlier project of the same author
  (openutau_reaper_editor, commit `4690898e`), MIT licensed (`LICENSE`), and
  is now the extension's own, changed with it.
- It is built against OpenUtau at `bc194b6fe4897427a73066390b286e11205fd10f`,
  which the top flake takes as its `openutau` input. OpenUtau is MIT licensed
  (its `LICENSE.txt`, kept in the build's source); the `libworldline.so` it
  ships is installed beside the engine.
- `nix/engine-deps.json` is the NuGet lock for that pair.

## Building it

`nix build .#utau-engine` builds it alone; `nix build .#paw-utau` builds
paw with the extension and this engine in it (see `../nix`). Without Nix,
with a .NET 10 SDK and OpenUtau checked out at the commit above in
`../third_party/OpenUtau`:

```
dotnet publish PawUtau.Engine -c Release -o out
```

and point the extension at it: `paw.opt.utau_engine = "/path/to/out/paw-utau-engine"`
or `PAW_UTAU_ENGINE=/path/to/out/paw-utau-engine`.
