# About the architecture

<!-- tags: architecture -->

paw has a small kernel in Rust and a runtime in Lua. The kernel holds the
project, the audio engine and the plugin hosts. The Lua runtime holds the
views, the keys and the commands. The frontends (the terminal and the
graphical window) show what Lua draws and send the input to the kernel. This
page tells how these parts connect and why. The diagram shows the two
threads and the data that moves between them.

```
            ┌────────────── main thread ──────────────┐        ┌─ audio thread ─┐
 terminal ─▶│ keys ─▶ Lua runtime ─▶ paw.api          │  msgs  │                │
 socket   ─▶│         (views, keys,   │               │ ─────▶ │    Engine      │
            │          commands)      ▼               │        │ tracks,devices │
 terminal ◀─│ cell grid ◀── render   Session          │ ◀───── │ clips,transport│
            │                 project ─▶ sync ────────┼─ garbage, meters, position
            └─────────────────────────────────────────┘        └────────────────┘
```

| Crate | What it holds |
| --- | --- |
| `paw-engine` | The audio thread: tracks, routing, device chains, clip playback, transport, metronome. Built-in devices. cpal and null backends. No Lua, no UI. |
| `paw-core` | The project model, undo, the sync that drives the engine from the model, the Lua host and `paw.api`, the cell grid, the event loop, the control socket. |
| `paw-plugins` | CLAP, LV2 and VST3 hosting: scanning, the scan cache, and for each format a device for the audio thread and a controller for the main thread. |
| `paw-luadev` | Devices written in Lua: a script in a LuaJIT state of its own, run in a plugin helper process, and the directories scripts are found in. |
| `paw-scene` | What every frontend shares of a view: the cells and their styles (the grid writes through it), and the scene, a view's drawing as nodes in cell units, kept by key, sent as patches, hit-tested and lowered to cells. No Lua, no UI. |
| `paw-tui` | The terminal frontend and the `paw` binary. |
| `paw-gui` | The graphical frontend, written with egui. A client of the control socket and nothing more. |
| `runtime/lua/paw` | Everything else. Compiled into the binary; `--runtime <dir>` loads it from disk instead. |

The design obeys these rules:

- **The project is plain data.** Tracks, devices and clips are behind `Arc`,
  and an edit makes a copy of only what it changes. Undo is a tree of
  snapshots that share all the unchanged parts. If you undo and then make a
  change, paw starts a new branch and keeps the old one.
- **One path to the engine.** `sync` compares two snapshots and sends engine
  messages and change events. Edits, undo, project loads and offline renders
  all go through `sync`. So the engine always agrees with the model.
- **The audio thread never allocates.** The main thread builds all that the
  audio thread uses and sends it through a lock-free queue. The audio thread
  sends back what it does not use, and the main thread frees it.
- **Many threads, one sound.** Worker threads process the tracks that do not
  feed each other at the same time. Then one thread adds their outputs in a
  fixed order. So a rendered file has the same bytes on one thread or on
  sixteen threads.
- **The screen is a grid of cells.** Lua draws into the grid and a frontend
  shows it. A frontend must only show cells and send the input. The
  graphical window gets the same drawing as scenes. A scene that is lowered
  to cells is the same grid.
- **`paw.api` passes plain data only.** So the socket can send the data
  as it is. When Lua loads again, no reference to old Lua data stays.
