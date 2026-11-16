# The control protocol

A running `daw` is a server. Other programs (the window, `daw ctl`,
`daw attach`, the MCP server, your own scripts) connect to it, call into
it, and are told what happens in it. This page is the whole protocol,
version 3.

## Connecting

Messages are JSON objects, one per line, UTF-8, in both directions.

| Way in | Who may use it |
| --- | --- |
| A Unix socket, `$XDG_RUNTIME_DIR/daw.sock` unless `--listen <path>` names another (`--no-listen` for none) | whoever may open the file: you, on that machine |
| TCP inside TLS, when the instance is started with `--listen-tcp <host:port>` | whoever can reach the port and knows the token |

The token is 32 hexadecimal digits in `~/.local/state/daw/token`
(`--token-file <path>` for another place), made the first time it is needed
and readable by you alone. Copy it to the machines that may connect.

TCP is encrypted with TLS 1.3 (or 1.2), from the first byte; the lines
below go inside it. The instance makes a self-signed certificate the first
time it listens, keeps it in `~/.local/state/daw/tls/` and prints its
fingerprint (the SHA-256 of the certificate, in groups of four hexadecimal
digits) when it starts. There is no authority to vouch for it: a client
trusts the certificate the first time it connects to an address and holds
the instance to it afterwards, as SSH does with host keys. `daw`'s clients
remember it in `~/.local/state/daw/known_instances` (an address and a
fingerprint on each line), refuse a different one naming both, and take a
new one with `--accept-certificate`. A client of your own can do the same
with any TLS library: accept the certificate shown, compare its
fingerprint with the one remembered.

`--no-tls` (on the instance and on `daw`'s clients) speaks the lines in
the clear instead, for a network you trust: `eval` runs any Lua, so
whoever can change what is said can run anything on the instance's
machine. A client that speaks in the clear to a port that only takes TLS
is greeted with `{"event": "hello", "payload": {"version": 3, "error":
"…"}}` (after a second and a half of silence, or at once if it speaks
first) and its first request is answered with that error. SSH needs
nothing from this program either:

```sh
ssh -N -L /tmp/studio.sock:/run/user/1000/daw.sock studio &
daw attach --socket /tmp/studio.sock
daw-gui --socket /tmp/studio.sock
```

## Requests and replies

```json
{"id": 1, "method": "eval", "params": ["return daw.transport.position"]}
{"id": 1, "result": 3.5}
{"id": 2, "method": "nonsense", "params": []}
{"id": 2, "error": "no method `nonsense`"}
```

`id` is yours and comes back with the answer; requests on one connection
are answered in order. A request with `"id": null` is answered with
`"id": null`: send those when you do not care for the answer.

| Method | Parameters | Does |
| --- | --- | --- |
| `hello` | `{ "proof": "…" }` over TCP, `{}` otherwise | says who is there; answers `{ "version": 3, "client": n }` |
| `eval` | Lua source, then values for its `...` | runs it in the kernel and answers what it returns |
| `cmd` | a command line, as after `:` | runs the command |
| `keys` | keys, as typed: `"ggdd"`, `"<C-s>"` | types them |
| `render` | path, options | `daw.render` |
| any `daw.api` function | its arguments | calls it: `track_add`, `transport_get`, … |
| `subscribe` | event names or patterns | events are pushed from now on; answers the list in force |
| `unsubscribe` | patterns, or nothing for all | stops them |
| `frontend.watch` | `{ "interval": ms, "seat": "own" or "instance" }` (33, `own`) | `frontend.state` events from now on, seen from a seat of the connection's own or the instance's |
| `frontend.unwatch` | | stops them |
| `ui.attach` | width, height in cells | this connection becomes a terminal: `ui.grid` events from now on |
| `ui.input` | one input event | typing and pointing in that terminal |
| `ui.detach` | | stops being a terminal |
| `file.begin` | `{ "name": "take.wav", "size": bytes }` | starts sending a file; answers its upload number |
| `file.chunk` | upload number, the next bytes in base64 | answers how many bytes have arrived |
| `file.end` | upload number | answers where the whole file is on the instance's machine |
| `file.abort` | upload number | throws away what arrived |
| `monitor.listen` | | `audio.frame` events from now on; answers `{ "rate", "channels", "format", "frame_ms" }` |
| `monitor.unlisten` | | stops them |

An extension adds methods of its own with
`daw.remote.methods["name"] = function(client, ...) return … end`.

### `hello` and the token

Over TCP the kernel speaks first:

```json
{"event": "hello", "payload": {"version": 3, "nonce": "9f1c…"}}
```

and listens to nothing until the connection has answered with the proof
that it knows the token: the SHA-256, in hexadecimal, of the token, a
colon and the nonce.

```json
{"id": 1, "method": "hello", "params": [{"proof": "sha256(token + ':' + nonce)"}]}
{"id": 1, "result": {"version": 3, "client": 7}}
```

A wrong proof is answered with an error and the connection is closed. On
the Unix socket `hello` is optional and only tells you the version and
your connection's number.

A network connection has ten seconds and 4096 bytes to show the proof.
Any connection is closed when it lets 32 MB wait unread, and a request
may be 64 MB long.

## Events

What the kernel pushes has no `id`:

```json
{"event": "transport.play", "payload": {"position": 0}}
```

A connection is sent only what it asked for.

**`subscribe`** takes exact names (`track.added`), families
(`transport.*`) or `*`. The events are the ones `daw.on` hears in Lua,
those of extensions included: `changed`, `project.loaded`,
`project.saved`, `track.added`, `track.changed`, `track.removed`,
`clip.add`, `clip.set`, `device.changed`, `device.stopped`,
`transport.play`, `transport.stop`, `transport.seek`, `transport.record`,
`transport.changed`, `midi.in`, `render.progress`, `render.done`,
`audio.lost`, `audio.restored`, and so on. An event whose payload cannot
be written as JSON is not sent.

**`frontend.watch`** is for programs that draw the project. Instead of
asking for `daw.frontend.state()` many times a second, the connection is
sent a `frontend.state` event at once, and after that only when something
it would draw has changed, at most once every `interval` milliseconds:

```json
{"event": "frontend.state", "payload": {
  "revision": 41, "playing": true, "position": 12.5, "time": "4.1.50",
  "levels": [0.31, 0.3, 0, 0], "cpu": 0.07, "modal": { "mode": "n" },
  "sections": { "tracks": [ … ], "clips": [ … ] }
}}
```

The payload is what moves on its own (the playhead, the meters, the
mode: everything `daw.frontend.state(known)` returns when the project has
not changed). `sections`, when present, holds the parts of the project
that differ from what this connection was last sent, each whole:

| Section | Is |
| --- | --- |
| `project` | name, tempo, loop, markers, … (`state.project` without `lines`) |
| `lines` | the bar and beat lines (`state.project.lines`) |
| `tracks`, `clips`, `devices` | as in the state |
| `routing` | the selected track's, or `false` without one |
| `view` | `{ "selected": track id, "cursor": beat }` |
| `kinds` | the kinds of device there are; sent once |

An idle program sends nothing at all.

## A terminal somewhere else

`ui.attach` makes the connection a terminal of the instance, beside its
own if it has one: after every turn that changed the screen it is sent

```json
{"event": "ui.grid", "payload": {
  "w": 120, "h": 40, "full": false, "cursor": [14, 3],
  "runs": [[0, 0, " NORMAL ", "#101216", "#6aa9e9", 1], [8, 0, " 1.1.00", null, 236, 0]]
}}
```

A run is `[x, y, text, fg, bg, attrs]`: a stretch of cells of one style
on one row. Colours are `null` (the terminal's own), a number (one of
its 256) or `"#rrggbb"`; `attrs` adds 1 bold, 2 dim, 4 italic,
8 underline, 16 reverse, 32 strike. Only what changed is sent; `full`
says to clear the screen first (the first event, and after a change of
size). A character two cells wide takes two.

`ui.input` takes one of

```json
{"key": "<C-s>"}
{"paste": "text"}
{"resize": [100, 30]}
{"mouse": {"kind": "down", "button": "left", "x": 3, "y": 4, "mods": "C"}}
```

with keys in the notation key mappings use, mouse kinds `down`, `up`,
`drag`, `move`, `scroll_up`, `scroll_down`, `scroll_left`, `scroll_right`,
and `mods` any of `C`, `A`, `S`.

`:detach` (or `ui.detach`) lets a remote terminal go, answered with a
`ui.detached` event; the instance runs on. `:q` quits the instance for
everyone.

## Seats

The project is one; what each person sees and is in the middle of is
their own. A connection that attaches (`ui.attach`) or watches
(`frontend.watch`, unless it asks for `"seat": "instance"`) has a seat:
its own focused view and panels shown, edit cursor, mode, selection, keys
half typed, registers, marks, prompt and scroll, and a terminal drawn at
its own size. Every call that connection makes (`eval`, `cmd`, `keys`,
`daw.frontend.act.*`) happens in its seat. The instance's own seat is its
terminal's, if it has one, and that of every connection without a seat of
its own (`daw ctl`, scripts). A new seat starts at the instance's cursor,
with the instance's panels shown, in normal mode; it closes with its
connection. Edits from two seats are steps in the one undo history.
Options (`daw.opt`) are shared. In Lua, `daw.seats` says whose turn it is
(`daw.seats.current`); see runtime/lua/daw/seats.lua for how a module
keeps state of its own for each seat.

## Files

A client on another machine sends a file into the project's media folder
(beside a saved project, else a scratch folder) with `file.begin`, as
many `file.chunk` as it takes (1 MB each is right) and `file.end`, then
imports the path `file.end` answers like any other:

```json
{"id": 1, "method": "file.begin", "params": [{"name": "take.wav", "size": 2400044}]}
{"id": 1, "result": 1}
{"id": 2, "method": "file.chunk", "params": [1, "UklGRiw…"]}
{"id": 2, "result": 1048576}
…
{"id": 4, "method": "file.end", "params": [1]}
{"id": 4, "result": "/home/me/songs/media/take.wav"}
{"id": 5, "method": "eval", "params": ["daw.commands.run('import', { ... })", "/home/me/songs/media/take.wav"]}
```

The name keeps only its last part; a name taken already gets `-2`, `-3`…
The file has its name only once it is whole; one that has not ended when
its connection closes is thrown away. `:upload <path>` typed in an
attached terminal sends the connection `{"event": "file.wanted",
"payload": {"path": "…", "import": true}}`, for its program to send that
file from its own disk; `daw attach` does.

## Sound

`monitor.listen` sends the connection what the instance plays, as it
plays it:

```json
{"event": "audio.frame", "payload": {"seq": 41, "rate": 24000, "channels": 2, "pcm": "…"}}
```

Each frame is 20 ms of sound, left and right interleaved, as 16-bit
little-endian samples in base64, at half the engine's rate (a quarter at
88.2 kHz and above). That is about 770 kbit/s, a megabit with base64 and
JSON. `seq` counts from 1. The engine only makes the copy while someone
listens. `:listen` sends a terminal's or window's connection
`{"event": "monitor.toggle"}`, for its program to start or stop
listening; `daw attach` and `daw-gui` do, playing the frames through a
jitter buffer that waits for 200 ms and holds at most a second.

## What is not here

- Sound in compressed form: frames are plain 16-bit samples (no pure Rust
  Opus encoder is good enough to ship, and no C codec is linked), and
  nothing goes from the client to the instance (no recording from the
  client's microphone).
- Opening and saving projects on the client's disk: Open, Save and
  Render use the instance's.
- Plugin windows. They open on the instance's display.

## In Rust

The crate `daw-proto` (with `serde_json`, `anyhow`, `base64` and
`rustls` on `ring`, no OpenSSL) is the client's side:
`Connection::unix(path)` or `Connection::tcp(address, token)` (TLS,
remembering the certificate in the state directory;
`Connection::tcp_with(address, token, &Wire::…)` chooses where, or the
clear), then `call(method, params)`, `notify(method, params)`, the
`events` channel, `send_file(path)` and `send_and_import(path)`.
`daw_proto::monitor` makes and reads `audio.frame` payloads, and the crate
`daw-listen` plays them (`Player::device()`, or `Player::file(path,
rate)` to write them to a WAV file). `daw_core::remote::apply` puts
`ui.grid` events into a grid of cells.
