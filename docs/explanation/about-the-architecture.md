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
| `paw-engine` | The audio thread: tracks, routing, chains of devices, clip playback, the transport, the metronome. The built-in devices. The cpal and null backends. It has no Lua and no UI. |
| `paw-core` | The project model, undo, the sync that drives the engine from the model, the Lua host and `paw.api`, the grid of cells, the event loop, the control socket. |
| `paw-plugins` | The hosts of CLAP, LV2 and VST3 plugins: the scan, its cache, and for each format a device for the audio thread and a controller for the main thread. |
| `paw-luadev` | Devices written in Lua. Each is a script in its own LuaJIT state, in a helper process. Also the directories where paw finds the scripts. |
| `paw-scene` | What all frontends share of a view: the cells and their styles, and the scene. A scene is the drawing of a view as nodes in cell units. paw keeps nodes by key, sends patches, finds the node under the pointer, and lowers a scene to cells. It has no Lua and no UI. |
| `paw-raster` | Changes the drawings of views (the operations of `paw.canvas`) into pixels, with music fonts. Also the kitty graphics protocol that shows them in a terminal. |
| `paw-proto` | The client side of the control protocol, with TLS. A program that only talks to a kernel (the graphical window, a remote terminal) does not need the kernel to build. |
| `paw-listen` | Plays the sound of an instance on the machine where a terminal or a graphical window is attached. |
| `paw-tui` | The terminal frontend and the `paw` binary. |
| `paw-gui` | The graphical frontend, written with egui. It is a client of the control socket and nothing more. |
| `paw-mcp` | A Model Context Protocol server in front of the control socket. |
| `runtime/lua/paw` | All other parts. It is compiled into the binary. `--runtime <dir>` loads it from the disk. |

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
