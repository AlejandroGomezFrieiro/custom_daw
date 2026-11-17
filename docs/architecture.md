# How it is put together

```
            ┌────────────── main thread ──────────────┐        ┌─ audio thread ─┐
 terminal ─▶│ keys ─▶ Lua runtime ─▶ daw.api          │  msgs  │                │
 socket   ─▶│         (views, keys,   │               │ ─────▶ │    Engine      │
            │          commands)      ▼               │        │ tracks,devices │
 terminal ◀─│ cell grid ◀── render   Session          │ ◀───── │ clips,transport│
            │                 project ─▶ sync ────────┼─ garbage, meters, position
            └─────────────────────────────────────────┘        └────────────────┘
```

| Crate | What it holds |
| --- | --- |
| `daw-engine` | The audio thread: tracks, routing, device chains, clip playback, transport, metronome. Built-in devices. cpal and null backends. No Lua, no UI. |
| `daw-core` | The project model, undo, the sync that drives the engine from the model, the Lua host and `daw.api`, the cell grid, the event loop, the control socket. |
| `daw-plugins` | CLAP, LV2 and VST3 hosting: scanning, the scan cache, and for each format a device for the audio thread and a controller for the main thread. |
| `daw-luadev` | Devices written in Lua: a script in a LuaJIT state of its own, run in a plugin helper process, and the directories scripts are found in. |
| `daw-tui` | The terminal frontend and the `daw` binary. |
| `daw-gui` | The graphical frontend, written with egui. A client of the control socket and nothing more. |
| `runtime/lua/daw` | Everything else. Compiled into the binary; `--runtime <dir>` loads it from disk instead. |

The rules the design rests on:

- **The project is plain data.** Tracks, devices and clips sit behind `Arc`, and
  edits copy on write. Undo is a tree of snapshots that share everything
  unchanged: undoing and then changing something starts a branch, and loses
  nothing.
- **One path to the engine.** `sync` diffs two snapshots and emits engine
  messages and change events. Edits, undo, loading and offline rendering all go
  through it, so the engine cannot disagree with the model.
- **The audio thread never allocates.** What it uses is built on the main
  thread and sent over a lock-free queue; what it is done with is sent back to
  be freed.
- **Several threads, one sound.** Tracks that do not feed each other are
  processed side by side on worker threads; what they send on is then added
  up on one thread in a fixed order. A render is the same file, byte for
  byte, on one thread or sixteen.
- **The screen is a grid of cells.** Lua draws into it and a frontend shows it.
  A frontend only needs to display cells and report input.
- **`daw.api` passes plain data only**, so it can be served over the socket as
  it is, and reloading Lua cannot leave anything dangling.
