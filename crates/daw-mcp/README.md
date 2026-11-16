# daw-mcp

A [Model Context Protocol](https://modelcontextprotocol.io) server for the DAW,
so that an assistant such as Claude can look at a session and work in it:
build a song, edit it, mix it, render it, and read the render's levels and
spectrum in place of listening.

It is a client of the kernel's control socket, like `daw ctl` and the
graphical frontend, and adds nothing to the kernel. Each tool call is sent as
one `eval` of [mcp.lua](src/mcp.lua) with the tool's arguments, so a call is
one kernel turn, every change goes through `daw.api`, and a call that writes is
exactly one undo step. A call that fails part-way is rolled back.

## Run it

```sh
nix develop -c cargo build --release -p daw-tui -p daw-mcp

# Attach to a DAW that is already running (the terminal UI listens on
# $XDG_RUNTIME_DIR/daw.sock by default; a headless kernel can too):
daw --headless --listen /tmp/daw.sock &
target/release/daw-mcp --socket /tmp/daw.sock

# Or let the server start a headless kernel of its own, stopped when the
# server exits. Everything after `--` goes to `daw`:
target/release/daw-mcp --spawn song.json -- --audio null
```

The server speaks MCP on stdin and stdout and logs to stderr. Without
`--socket` or `--spawn` it attaches where `daw ctl` would: `$DAW_SOCKET`, else
`$XDG_RUNTIME_DIR/daw.sock`. The connection is made when the first tool needs
it; if the kernel goes away, calls fail with a message saying so, and the
server connects again once a kernel is back. A kernel started with `--spawn`
that stops is started afresh on the next call, which then says the previous
session was lost.

With `--spawn` the `daw` binary is `--daw <path>`, else `$DAW_BIN`, else the one
beside `daw-mcp`, else `daw` on the path. The kernel uses your configuration
and extensions and the default audio device unless you pass `--clean` or
`--audio null` after `--`.

### In Claude Code

These are instructions for you to run; the server does not register itself.

```sh
# Attach to the DAW you have open:
claude mcp add daw -- /path/to/custom_daw/target/release/daw-mcp

# Or a private headless session, with the escape hatches on:
claude mcp add daw -- /path/to/custom_daw/target/release/daw-mcp --spawn --allow-eval -- --audio null
```

Add `--scope user` to have it in every project, or put the same in a
project's `.mcp.json`:

```json
{
  "mcpServers": {
    "daw": {
      "command": "/path/to/custom_daw/target/release/daw-mcp",
      "args": ["--spawn", "--", "--audio", "null"]
    }
  }
}
```

Claude Code starts the server in the project directory, so that is where
relative paths start and the only place it saves and renders to (see
`--root`).

### In Claude Desktop

Add the server to `claude_desktop_config.json` (Settings → Developer → Edit
Config) and restart Claude Desktop:

```json
{
  "mcpServers": {
    "daw": {
      "command": "/path/to/custom_daw/target/release/daw-mcp",
      "args": ["--root", "/home/you/music", "--socket", "/run/user/1000/daw.sock"]
    }
  }
}
```

Claude Desktop does not start servers in a directory of your choosing, so give
`--root`. Use the socket path of the running DAW (`echo $XDG_RUNTIME_DIR/daw.sock`),
or `"--spawn"` instead of `"--socket", ...`.

## Tools

Positions are beats (quarter notes) from the start as JSON numbers, or
`"bar.beat"` strings counting from 1 (`"5.1"`, `"2.3.50"`). Notes can be
written compactly, `"C4 2.5 1/8 90"` or `"C4+E4+G4 1:3 2"` (pitch or chord,
start in beats or `bar:beat` within the clip, length, velocity), or as objects.
Middle C is C4. Tracks can be named instead of numbered.

| Tool | What it does |
| --- | --- |
| `get_project` | The whole session: tempo, signature, length, transport, tracks with routing, sends, devices, clips (position, notes, range) and automation. |
| `get_track` | One track in full, with every device's parameter values and automation points. |
| `get_clip` | A clip's notes, or an audio clip's file, offset and gain. |
| `get_device` | A device's parameters with value, range, default, unit and choices; filterable for big plugins. |
| `find_devices` | Search the built-in devices and installed plugins that can be added. |
| `get_status` | Transport, audio engine, unsaved changes, recent DAW messages. |
| `add_track` | A track with its devices, clips and notes, routing and sends, in one call. |
| `set_track` | Name, volume, pan, mute, solo, colour, position, output, sends. |
| `add_clip` | A MIDI clip with all its notes, or an audio clip from a file. |
| `edit_clip` | Move, resize, rename, mute a clip; remove, transpose, rescale, replace or add notes. |
| `add_device` | An instrument or effect (by kind or search words) with parameter values. |
| `set_device` | Parameters (by key or name; choices by name), bypass, move in or between chains. |
| `automate` | Volume, pan or parameter automation points; create, clear, switch off, remove a lane. |
| `set_project` | Tempo, time signature, name. |
| `remove` | Tracks, clips, devices and automation lanes, any number in one call. |
| `transport` | Play, stop, seek, loop range and switch, metronome. Not undoable. |
| `undo` | Undo or redo one or more steps. |
| `project_file` | Save, open, new. Open and new refuse to drop unsaved changes unless `discard`. |
| `render` | Render to WAV and measure it: duration, peak, RMS, clipping, stereo, level per bar, octave-band spectrum and centroid. |
| `analyze_audio` | The same measurements for any WAV file. |
| `run_command` | Escape hatch: a `:` command line. Only with `--allow-eval`. |
| `send_keys` | Escape hatch: type keys in Neovim notation. Only with `--allow-eval`. |
| `eval_lua` | Escape hatch: run Lua in the kernel. Only with `--allow-eval`. |

Results are short text with every id the next call might need, and show the
state after the change, so a model does not need to read again. Errors from
the kernel or from checking the arguments come back as tool errors
(`isError`) with the message; only an unknown tool or a malformed request is a
protocol error.

The measurements are plain signal measurements (sample peak, RMS in dBFS, an
averaged 4096-point FFT summed into octave bands), not perceptual loudness:
RMS is not LUFS.

## Flags, and what an assistant can do

| Flag | Effect |
| --- | --- |
| `--socket <path>` | Attach to the kernel at this socket. |
| `--spawn [project] [-- daw options]` | Start a headless kernel, stop it on exit. |
| `--daw <path>` | The `daw` binary for `--spawn`. |
| `--root <dir>` | Where relative paths start and files may be written. Default: the current directory. |
| `--allow-eval` | Offer `run_command`, `send_keys` and `eval_lua`. |
| `--allow-any-path` | Let `render` and `project_file` save write outside `--root`. |
| `--timeout <secs>` | How long to wait for the kernel per call (default 600). |

**Without flags** an assistant can read the whole session and change it
through the typed tools only: tracks, clips, notes, devices and plugins
(adding a plugin loads it into the kernel process), parameters, routing,
automation, tempo and signature, transport, undo and redo. It can open any
project file and read any WAV or audio file the server's user can read (by
absolute path too), and open or start a project, which replaces the session
and clears undo, but only when there are no unsaved changes or when it passes
`discard`. It can write files only under `--root`: renders (overwriting a file
of the same name) and saved projects (`.json`, with a `media` directory beside
it when the project has recordings). It cannot run code, commands or keys, and
cannot quit the kernel. Paths are checked after resolving `..` and symbolic
links.

**`--allow-eval`** adds the escape hatches, which are arbitrary code in the
kernel process with the user's rights: Lua with the whole `daw` interface and
LuaJIT's `io`, `os` and `ffi`, commands (which include `:lua`, `:w <path>` and
`:q`), and keys. Through them an assistant can read and write any file, start
programs, and quit the DAW; `--root` does not apply to them. Each call is one
undo step for what it changes in the project, but is not rolled back on
failure.

**`--allow-any-path`** lets `render` and `project_file` save write anywhere the
user can.

## Protocol

JSON-RPC 2.0 over stdio, one message per line, implemented directly with
`serde_json`.

- `initialize` (answered with the revision asked for when it is one of
  `2024-11-05`, `2025-03-26`, `2025-06-18`, `2025-11-25`, otherwise
  `2025-11-25`), `notifications/initialized`, `ping`, `tools/list`,
  `tools/call`. Batches (an array of messages) are accepted.
- The `2026-07-28` revision, which has no handshake: requests carrying
  `_meta["io.modelcontextprotocol/protocolVersion"]` are served statelessly
  with `resultType: "complete"`, `server/discover` answers, and an
  unsupported revision gets error `-32022` with the supported list.
- Unknown methods get `-32601`, unknown tools and requests without a tool name
  `-32602`, unparsable lines `-32700`.
- Tool definitions carry `title` and `annotations` (read-only, destructive).
  Results are a single text block; there is no `structuredContent`.

No resources or prompts: everything a model would read as a resource is a
read-only tool here, which a model can call when it needs it.

`tests/protocol.rs` speaks the protocol to the server with a headless kernel
on the null backend: the handshake for each revision, the tool schemas, a song
built with the typed tools only, read back, rendered and measured, undo, a
rolled-back call, the argument errors, the escape hatches, and a kernel that
goes away and comes back. Run it with `nix develop -c cargo test -p daw-mcp`
(it builds `daw` if it is not built yet).

## Not done

- Calls run one at a time and to completion: a long render holds up `ping`,
  and `notifications/cancelled` is ignored. There are no progress
  notifications.
- No loudness in LUFS, true peak or loudness range: the kernel is getting a
  measurement of its own, which `render` could use once it exists.
- Only WAV files can be measured.
- No recording, MIDI input, audio inputs and monitoring, plugin editor
  windows, or the cursor, marks and selections in the typed tools; the escape
  hatches reach those.
- `unsaved changes` is tracked from saves made through this server or after
  it first ran in the kernel; the kernel itself only reports whether the
  project has any history.
- Tested with its own test client only, not with Claude Code or Claude Desktop
  themselves.
