# paw-mcp

A [Model Context Protocol](https://modelcontextprotocol.io) server for paw,
so that an assistant such as Claude can look at a session and work in it:
build a song, edit it, mix it, render it, and read the render's levels and
spectrum in place of listening.

It is a client of the kernel's control socket, like `paw ctl` and the
graphical frontend, and adds nothing to the kernel. Each tool call is sent as
one `eval` of [mcp.lua](src/mcp.lua) with the tool's arguments, so a call is
one kernel turn, every change goes through `paw.api`, and a call that writes is
exactly one undo step. A call that fails part-way is rolled back.

## Run it

```sh
nix develop -c cargo build --release -p paw-tui -p paw-mcp

# Attach to a paw that is already running (the terminal UI listens on
# $XDG_RUNTIME_DIR/paw.sock by default; a headless kernel can too):
paw --headless --listen /tmp/paw.sock &
target/release/paw-mcp --socket /tmp/paw.sock

# Or let the server start a headless kernel of its own, stopped when the
# server exits. Everything after `--` goes to `paw`:
target/release/paw-mcp --spawn song.json -- --audio null
```

The server speaks MCP on stdin and stdout and logs to stderr. Without
`--socket` or `--spawn` it attaches where `paw ctl` would: `$PAW_SOCKET`, else
`$XDG_RUNTIME_DIR/paw.sock`. The connection is made when the first tool needs
it; if the kernel goes away, calls fail with a message saying so, and the
server connects again once a kernel is back. A kernel started with `--spawn`
that stops is started afresh on the next call, which then says the previous
session was lost.

With `--spawn` the `paw` binary is `--paw <path>`, else `$PAW_BIN`, else the one
beside `paw-mcp`, else `paw` on the path. The kernel uses your configuration
and extensions and the default audio device unless you pass `--clean` or
`--audio null` after `--`.

### In Claude Code

These are instructions for you to run; the server does not register itself.

```sh
# Attach to paw you have open:
claude mcp add paw -- /path/to/custom_daw/target/release/paw-mcp

# Or a private headless session, with the escape hatches on:
claude mcp add paw -- /path/to/custom_daw/target/release/paw-mcp --spawn --allow-eval -- --audio null
```

Add `--scope user` to have it in every project, or put the same in a
project's `.mcp.json`:

```json
{
  "mcpServers": {
    "paw": {
      "command": "/path/to/custom_daw/target/release/paw-mcp",
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
    "paw": {
      "command": "/path/to/custom_daw/target/release/paw-mcp",
      "args": ["--root", "/home/you/music", "--socket", "/run/user/1000/paw.sock"]
    }
  }
}
```

Claude Desktop does not start servers in a directory of your choosing, so give
`--root`. Use the socket path of the running paw (`echo $XDG_RUNTIME_DIR/paw.sock`),
or `"--spawn"` instead of `"--socket", ...`.

## Tools

Positions are beats (quarter notes) from the start as JSON numbers, or
strings counting bars and beats from 1: `"5.1"`, `"5:1"`, `"bar 5 beat 1"`,
`"2.3.50"`. Notes can be written compactly, `"C4 2.5 1/8 90"` or
`"C4+E4+G4 1:3 2"` (pitch or chord, start in beats or `bar:beat` within the
clip, length, velocity), or as objects. Middle C is C4. Tracks and markers
can be named instead of numbered.

| Tool | What it does |
| --- | --- |
| `get_project` | The whole session: tempo, signature, key, length, transport, markers and regions, tracks with routing, sends, devices, clips (position, notes, range) and automation. |
| `get_track` | One track in full, with every device's parameter values, automation points and the engine's live meter. |
| `get_clip` | A clip's notes with their ids (filterable by time and pitch), or an audio clip's file, offset and gain. |
| `get_device` | A device's parameters with value, range, default, unit and choices; filterable for big plugins. |
| `find_devices` | Search the built-in devices and installed plugins that can be added. |
| `get_status` | Transport, audio engine, unsaved changes, recent paw messages. |
| `find` | Tracks, clips, notes and the rest by a `paw.query` selector (`clip[name~=riff] > note[pitch>=c5]`). |
| `diagnose` | Empty tracks, silent MIDI tracks, empty clips, notes past their clip, missing plugins, orphan or muted sends, automation out of range; with `measure`, silence and clipping in a render. |
| `add_track` | A track with its devices, clips and notes, routing and sends, in one call. |
| `set_track` | Name, volume, pan, mute, solo, colour, position, output, sends. |
| `add_clip` | A MIDI clip with all its notes, or an audio clip from a file. |
| `edit_clip` | Move, resize, rename, mute a clip; remove notes, change single notes by id, transpose (semitones or scale degrees in the key), scale or set velocities, replace or add notes. |
| `duplicate_clip`, `repeat_bars` | Copy a clip; repeat a stretch of the song for arranging. |
| `add_device` | An instrument or effect (by kind or search words) with parameter values. |
| `set_device` | Parameters (by key or name; choices by name), bypass, move in or between chains. |
| `automate` | Volume, pan or parameter automation points; create, clear, switch off, remove a lane. |
| `set_project` | Tempo, time signature, key, name, tempo and signature changes. |
| `marker` | Markers and regions: add, rename, move, remove, list. |
| `remove` | Tracks, clips, devices, automation lanes and markers, any number in one call. |
| `batch` | Several of the writing tools as one named undo step, all or nothing. |
| `transport` | Play, stop, seek, loop range and switch (or loop a region), metronome. Not undoable. |
| `undo` | Undo or redo, saying what each step was; `list` shows the history. Fails when there is nothing to undo. |
| `project_file` | Save, open, new. Open and new refuse to drop unsaved changes unless `discard`. |
| `render` | Render to WAV, FLAC (MP3, Ogg, Opus with ffmpeg), a region, some tracks or stems, to a LUFS target; measure it: LUFS, true peak, and for WAV peak, RMS, clipping, stereo, level per bar, octave-band spectrum. |
| `analyze_audio` | The same measurements for any audio file (LUFS for any format, the rest for WAV). |
| `lua` | Escape hatch: run Lua in the kernel. Only with `--allow-eval`. |
| `run_command` | Escape hatch: a `:` command line. Only with `--allow-eval`. |
| `send_keys` | Escape hatch: type keys in Neovim notation. Only with `--allow-eval`. |

Every result is short text with every id the next call might need, and the
same as JSON in `structuredContent`; both show the state after the change, so
a model does not need to read again. Each failure comes back as a tool error
(`isError`) with the message and `{"error": ...}` as its structured content,
an unknown tool and `undo` with nothing to undo included; only a malformed
request is a protocol error. Every writing call is one undo step named
`mcp: <tool> <subject>`, and `batch` makes any number of them one step.

Tool schemas use `anyOf` for values of two kinds and plain arrays with one
`items` schema, since some clients read a list of types or `prefixItems`
wrongly (an automation point is `[position, value]`, a pitch a name or a
number).

The `lua` and `run_command` tools are annotated as destructive and open-world,
so that a client asks before running them. They are offered only with
`--allow-eval`, because they bypass the checks of the typed tools.

Loudness (integrated and short-term LUFS, loudness range, true peak) is the
kernel's own measurement (`paw.api.measure`). The rest are plain signal
measurements (sample peak, RMS in dBFS, an averaged 4096-point FFT summed into
octave bands).

## Flags, and what an assistant can do

| Flag | Effect |
| --- | --- |
| `--socket <path>` | Attach to the kernel at this socket. |
| `--spawn [project] [-- paw options]` | Start a headless kernel, stop it on exit. |
| `--paw <path>` | The `paw` binary for `--spawn`. |
| `--root <dir>` | Where relative paths start and files may be written. Default: the current directory. |
| `--allow-eval` | Offer `lua`, `run_command` and `send_keys`. |
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
kernel process with the user's rights: Lua with the whole `paw` interface and
LuaJIT's `io`, `os` and `ffi`, commands (which include `:lua`, `:w <path>` and
`:q`), and keys. Through them an assistant can read and write any file, start
programs, and quit paw; `--root` does not apply to them. Each call is one
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
- Unknown methods get `-32601`, requests without a tool name `-32602`,
  unparsable lines `-32700`. An unknown tool is a tool error.
- Tool definitions carry `title` and `annotations` (read-only, destructive,
  open-world). Results are a text block and `structuredContent`.
- Resources: `resources/list`, `resources/templates/list`, `resources/read`.
  `paw://help/<page>` is a page of the manual (read from the kernel's docs),
  `paw://reference/api` every `paw.api` function with the comment above it in
  `crates/paw-core/src/api.rs`, and `paw://reference/lua/<module>` the
  documented functions of a module of `runtime/lua/paw`
  (`paw://reference/lua` lists them). The references are made from the source
  the server was built from. There are no prompts.

`tests/protocol.rs` speaks the protocol to the server with a headless kernel
on the null backend: the handshake for each revision, the tool schemas, a song
built with the typed tools only, read back, rendered and measured, undo, a
rolled-back call, the argument errors, the escape hatches, and a kernel that
goes away and comes back. Run it with `nix develop -c cargo test -p paw-mcp`
(it builds `paw` if it is not built yet).

## Not done

- Calls run one at a time and to completion: a long render holds up `ping`,
  and `notifications/cancelled` is ignored. There are no progress
  notifications.
- Level per bar, stereo and spectrum are measured on WAV files only; a FLAC
  or MP3 render gets the loudness numbers.
- A `batch` reads `bar.beat` positions with the time signature as it is when
  it starts, and its steps name earlier results by name, not by id.
- Note names are written with sharps (`A#4`).
- `get_track`'s meter is the engine's live peak: -120 dB when nothing plays.
  `diagnose` with `measure` finds the tracks that clip.
- No recording, MIDI input, audio inputs and monitoring, plugin editor
  windows, or the cursor, marks and selections in the typed tools; the escape
  hatches reach those.
- `unsaved changes` is tracked from saves made through this server or after
  it first ran in the kernel; the kernel itself only reports whether the
  project has any history.
- Tested with its own test client only, not with Claude Code or Claude Desktop
  themselves.
