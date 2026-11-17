# The singing engine

`reautau-engine`, the program that sings for extensions/utau: a host for
OpenUtau.Core (phonemizers, resamplers, DiffSinger and the other renderers)
that the extension talks to over a Unix socket, in ReaUtau's protocol
(`lua/utau/proto.lua` on this side, `ReaUtau.Protocol` on that one).

It is ReaUtau's engine, copied here so that it can be changed with the
extension:

- from `projects/reautau/engine` (`ReaUtau.Engine`, `ReaUtau.Protocol`) of
  openutau_reaper_editor, commit `4690898e4ebdec087f2efebab016298254aba3b6`
  (9 November 2026), MIT licensed by Alejandro Gomez Frieiro (`LICENSE`);
- built against OpenUtau at `bc194b6fe4897427a73066390b286e11205fd10f`, the
  commit ReaUtau pins, which the top flake takes as its `openutau` input.
  OpenUtau is MIT licensed (its `LICENSE.txt`, kept in the build's source);
  the `libworldline.so` it ships is installed beside the engine as ReaUtau
  does;
- `nix/engine-deps.json` is ReaUtau's NuGet lock for that pair.

Left behind: ReaUtau's test projects, which read test data from elsewhere
in that repository, and its spike.

## Building it

`nix build .#utau-engine` builds it alone; `nix build .#paw-utau` builds
paw with the extension and this engine in it (see `../nix`). Without Nix,
with a .NET 10 SDK and OpenUtau checked out at the commit above in
`../third_party/OpenUtau`:

```
dotnet publish ReaUtau.Engine -c Release -o out
```

and point the extension at it: `daw.opt.utau_engine = "/path/to/out/reautau-engine"`
or `REAUTAU_ENGINE=/path/to/out/reautau-engine`.
