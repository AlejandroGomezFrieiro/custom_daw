# The control protocol

A running `daw` is a server. Other programs (the window, `daw ctl`,
`daw attach`, the MCP server, your own scripts) connect to it, call into
it, and are told what happens in it. This page is the whole protocol,
version 2.

## Connecting

Messages are JSON objects, one per line, UTF-8, in both directions.

| Way in | Who may use it |
| --- | --- |
| A Unix socket, `$XDG_RUNTIME_DIR/daw.sock` unless `--listen <path>` names another (`--no-listen` for none) | whoever may open the file: you, on that machine |
| TCP, when the instance is started with `--listen-tcp <host:port>` | whoever can reach the port and knows the token |

The token is 32 hexadecimal digits in `~/.local/state/daw/token`
(`--token-file <path>` for another place), made the first time it is needed
and readable by you alone. Copy it to the machines that may connect.

TCP is **not encrypted**. The token itself never crosses the wire (see
`hello`), but everything said afterwards can be read, and changed, by
whoever sits between the two machines: `eval` runs any Lua, so that is
the machine. Use `--listen-tcp` on a network you trust (`127.0.0.1:7700` is
this machine only; `0.0.0.0:7700` is every network the machine is on), and
for anything else leave it off and carry the Unix socket through SSH,
which needs nothing from this program:

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
| `hello` | `{ "proof": "…" }` over TCP, `{}` otherwise | says who is there; answers `{ "version": 2, "client": n }` |
| `eval` | Lua source, then values for its `...` | runs it in the kernel and answers what it returns |
| `cmd` | a command line, as after `:` | runs the command |
| `keys` | keys, as typed: `"ggdd"`, `"<C-s>"` | types them |
| `render` | path, options | `daw.render` |
| any `daw.api` function | its arguments | calls it: `track_add`, `transport_get`, … |
| `subscribe` | event names or patterns | events are pushed from now on; answers the list in force |
| `unsubscribe` | patterns, or nothing for all | stops them |
| `frontend.watch` | `{ "interval": ms }` (33) | `frontend.state` events from now on |
| `frontend.unwatch` | | stops them |
| `ui.attach` | width, height in cells | this connection becomes a terminal: `ui.grid` events from now on |
| `ui.input` | one input event | typing and pointing in that terminal |
| `ui.detach` | | stops being a terminal |

An extension adds methods of its own with
`daw.remote.methods["name"] = function(client, ...) return … end`.

### `hello` and the token

Over TCP the kernel speaks first:

```json
{"event": "hello", "payload": {"version": 2, "nonce": "9f1c…"}}
```

and listens to nothing until the connection has answered with the proof
that it knows the token: the SHA-256, in hexadecimal, of the token, a
colon and the nonce.

```json
{"id": 1, "method": "hello", "params": [{"proof": "sha256(token + ':' + nonce)"}]}
{"id": 1, "result": {"version": 2, "client": 7}}
```

A wrong proof is answered with an error and the connection is closed. On
the Unix socket `hello` is optional and only tells you the version and
your connection's number.

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

Every terminal of an instance shows the same screen, as wide and tall as
whichever was sized last, and types into the same session: it is one
instance seen from several places, not one each. `:detach` (or
`ui.detach`) lets a remote terminal go, answered with a `ui.detached`
event; the instance runs on. `:q` quits the instance for everyone.

## What is not here

- Encryption on TCP: see above.
- A cursor, mode and selection for each connection: every frontend
  shares one.
- Sound. A remote instance plays on its own machine's sound device.
  PipeWire can carry that to another machine by itself.
- Files from the client's disk. Open, save, import and render browse
  the instance's own disk.
- Plugin windows. They open on the instance's display.

## In Rust

The crate `daw-proto` (no dependencies but `serde_json` and `anyhow`) is
the client's side: `Connection::unix(path)` or `Connection::tcp(address,
token)`, then `call(method, params)`, `notify(method, params)` and the
`events` channel. `daw_core::remote::apply` puts `ui.grid` events into
a grid of cells.
