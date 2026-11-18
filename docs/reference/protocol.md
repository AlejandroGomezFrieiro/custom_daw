# The control protocol

A running paw is a server. Other programs (the window, `paw ctl`,
`paw attach`, the MCP server, your own scripts) connect to it, call into
it, and are told what happens in it. This page is the whole protocol,
version 3.

## Connecting

Messages are JSON objects, one per line, UTF-8, in both directions.

| Way in | Who may use it |
| --- | --- |
| A Unix socket, `$XDG_RUNTIME_DIR/paw.sock` unless `--listen <path>` names another (`--no-listen` for none) | whoever may open the file: you, on that machine |
| TCP inside TLS, when the instance is started with `--listen-tcp <host:port>` | whoever can reach the port and knows the token |

The token is 32 hexadecimal digits in `~/.local/state/paw/token`
(`--token-file <path>` for another place), made the first time it is needed
and readable by you alone. Copy it to the machines that may connect.

TCP is encrypted with TLS 1.3 (or 1.2), from the first byte; the lines
below go inside it. The instance makes a self-signed certificate the first
time it listens, keeps it in `~/.local/state/paw/tls/` and prints its
fingerprint (the SHA-256 of the certificate, in groups of four hexadecimal
digits) when it starts. There is no authority to vouch for it: a client
trusts the certificate the first time it connects to an address and holds
the instance to it afterwards, as SSH does with host keys. `paw`'s clients
remember it in `~/.local/state/paw/known_instances` (an address and a
fingerprint on each line), refuse a different one naming both, and take a
new one with `--accept-certificate`. A client of your own can do the same
with any TLS library: accept the certificate shown, compare its
fingerprint with the one remembered.

`--no-tls` (on the instance and on `paw`'s clients) speaks the lines in
the clear instead, for a network you trust: `eval` runs any Lua, so
whoever can change what is said can run anything on the instance's
machine. A client that speaks in the clear to a port that only takes TLS
is greeted with `{"event": "hello", "payload": {"version": 3, "error":
"…"}}` (after a second and a half of silence, or at once if it speaks
first) and its first request is answered with that error. SSH needs
nothing from this program either:

```sh
ssh -N -L /tmp/studio.sock:/run/user/1000/paw.sock studio &
paw attach --socket /tmp/studio.sock
paw-gui --socket /tmp/studio.sock
```

## Requests and replies

```json
{"id": 1, "method": "eval", "params": ["return paw.transport.position"]}
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
| `render` | path, options | `paw.render` |
| any `paw.api` function | its arguments | calls it: `track_add`, `transport_get`, … |
| `subscribe` | event names or patterns | events are pushed from now on; answers the list in force |
| `unsubscribe` | patterns, or nothing for all | stops them |
| `frontend.watch` | `{ "interval": ms, "seat": "own" or "instance" }` (33, `own`) | `frontend.state` events from now on, seen from a seat of the connection's own or the instance's |
| `frontend.unwatch` | | stops them |
| `scene.watch` | `{ "cell": { "w", "h" }, "live": bool }` | `scene.patch` events from now on (and `scene.live` with `live`), for the windows given an area; see "Scenes" |
| `scene.area` | window, width, height in cell units | how big a window is shown; 0 by 0 for one no longer shown |
| `scene.input` | window, a pointer event in cell units | the pointer over a window |
| `scene.blob` | a content key | a drawing sent by its key |
| `scene.unwatch` | | stops the patches |
| `ui.attach` | width, height in cells | this connection becomes a terminal: `ui.grid` events from now on |
| `ui.input` | one input event | typing and pointing in that terminal |
| `ui.detach` | | stops being a terminal |
| `file.begin` | `{ "name": "take.wav", "size": bytes }` | starts sending a file; answers its upload number |
| `file.chunk` | upload number, the next bytes in base64 | answers how many bytes have arrived |
| `file.end` | upload number | answers where the whole file is on the instance's machine |
| `file.abort` | upload number | throws away what arrived |
| `monitor.listen` | | `audio.frame` events from now on; answers `{ "rate", "channels", "format", "frame_ms" }` |
| `monitor.unlisten` | | stops them |

`paw ctl --json <method> [params...]` is for programs and agents that have a
shell: it prints one line of JSON, `{"ok": true, "result": ...}` or
`{"ok": false, "error": "..."}`, and exits with status 1 on an error,
whether the call failed, the method does not exist, or there is no instance
to talk to. Without `--json`, a result is printed as it is (a string as text,
anything else as indented JSON) and an error goes to stderr.

```sh
paw ctl --json eval 'return paw.project.tempo'     # {"ok":true,"result":120}
paw ctl --json track_get 99                        # {"ok":false,"error":"..."}
```

An extension adds methods of its own with
`paw.remote.methods["name"] = function(client, ...) return … end`.

Every request that runs Lua (all of the above but `hello`, `ui.*`,
`file.*` and `monitor.*`) has the time limit a key has,
`paw.opt.lua_limit` (2 seconds): one that runs longer is stopped and
answered with an error that says so, and the instance goes on. Waiting
in the kernel does not count (a render, opening a project). Code sent
with `eval` that knows it needs longer asks for it first:
`paw.limit.extend(60000)`.

An error is the message alone, as Lua or the kernel gave it, with no
stack: ``"no method `nonsense`"``, `"no clip 9"`, `"rpc:1: attempt to
perform arithmetic on a nil value"` (`rpc` is the code sent with `eval`).

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
(`transport.*`) or `*`. The events are the ones `paw.on` hears in Lua,
those of extensions included: `changed`, `project.loaded`,
`project.saved`, `track.added`, `track.changed`, `track.removed`,
`clip.add`, `clip.set`, `device.changed`, `device.stopped`,
`transport.play`, `transport.stop`, `transport.seek`, `transport.record`,
`transport.changed`, `midi.in`, `render.progress`, `render.done`,
`audio.lost`, `audio.restored`, and so on. An event whose payload cannot
be written as JSON is not sent.

**`frontend.watch`** is for programs that draw the project. Instead of
asking for `paw.frontend.state()` many times a second, the connection is
sent a `frontend.state` event at once, and after that only when something
it would draw has changed, at most once every `interval` milliseconds:

```json
{"event": "frontend.state", "payload": {
  "revision": 41, "playing": true, "position": 12.5, "time": "4.1.50",
  "levels": [0.31, 0.3, 0, 0], "cpu": 0.075, "modal": { "mode": "n" },
  "sections": { "tracks": [ … ], "clips": [ … ] }
}}
```

The payload is what moves on its own (the playhead, the meters, the
mode: everything `paw.frontend.state(known)` returns when the project has
not changed). `cpu` is the engine's load averaged over about a second, in
steps of 2.5% (`paw.audio.load`), so that an idle program is not heard
from each time a block took a little longer. `sections`, when present, holds the parts of the project
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

## Scenes

A graphical frontend shows the views it has no drawing of its own for (a
pane of its main area, a view in a window of its own) from their scenes
(crates/paw-scene): what a view draws, as nodes in **cell units** that
are kept by name, so that after the first time only what changed is sent.
The window draws them in its own font at its own resolution, and the
same scene lowered to cells is cell for cell what a terminal shows.

`scene.watch` starts it, with the size of the frontend's cell in pixels
(pictures are drawn for it, and its main area is laid out on it) and the
roles it paints itself (`roles`, a list of names); it answers the theme's
colours (`theme`, the palette by name, which a node's `tone` names) and
`roles_version`. A
window is named by a string: a window of the layout by its number
(`"3"`, as `paw.panes.state()` lists it), a view in a window of its own as
`"view:<name>"` (`paw.canvas.windows()`). Nothing is sent of a window
until `scene.area` says how big it is shown, in units, fractions allowed;
then its whole scene, and after every turn that changed it (and while
playing, at most thirty times a second) what changed:

```json
{"event": "scene.patch", "payload": {
  "win": "3", "rev": 12, "full": false, "cursor": [4, 2],
  "set": [{"k": "t0,1", "t": "run", "text": "count 1", "r": [0, 1, 7, 1], "s": {"fg": "#c9ced8"}}],
  "drop": ["t9,1"]
}}
```

`full` says to forget what was had of the window first. `size`, `root`
(the keys of the top nodes, in drawing order), `colors` (`[fg, bg]`, what
`default` stands for) and `cursor` (`[]` for none) come only when they
change. A node has its key `k`, its kind `t`, its rectangle `r` (x, y,
width, height in units of its parent), and as the kind needs: `text`
(`run`), `ch` (`fill`: the character it overwrites with; restyled only
without), `s` its style (`fg`, `bg` as `"#rrggbb"`, `"default"` or one of
256; `on` and `off`, the attributes it sets and clears: 1 bold, 2 dim, 4
italic, 8 underline, 16 reverse, 32 strike), `clip` (what it is cut to),
`kids`. Runs and fills are written in order onto cells, as the terminal
does; reverse and dim are resolved with the cells. A `picture` has
`ops` (see `paw.canvas.paint`, music glyphs as glyphs), drawn for `px`
pixels and scaled to its rectangle, under the cells' text with `under`
(their backgrounds under it); a drawing too big to send each time comes
as `blob`, a content key to ask `scene.blob` for once.

A `role` is a named element a view marked over its rectangle (`buf:mark`,
see [Roles](../scripting.md#roles)): `role` its name and `props` what it
shows, such as `{"role": "fader", "props": {"at": 0.81, "zero": 0.79,
"value": -2}}`. Its kids are its cells, which a frontend that does not
know the role draws; a frontend that said it paints the role is sent it
without them. The widget roles (`label`, `button`, `switch`, `knob`,
`fader`, `meter`, `peak`, `chip`) are the core's; an extension may add
more. A node with `bind` (`"meter:4"`) is moved by the live values below,
and its props that those give (a meter's `levels`, `hold` and `clipped`,
a peak's `hold` and `clipped`) are left out, so that a view playing sends
no new scene for them. A node with `hit`
is a hit region: a press, a move or the wheel there means what the view
says it does (`hit.kind` and the rest, its action).

A `plane` places its kids in a domain of its own (`buf:plane`): `x` and
`y`, each `{ "domain", "from", "per" }`, put the domain's `from` at its
edge and run `per` units for each unit of it (backwards when negative). A
kid's rectangle is in the domain, so a note of the piano roll is
`{"k": "roll/note:7:3", "t": "role", "role": "note", "r": [1.5, 60, 0.5, 1],
"props": {"label": "C4", "color": "#e0a050", "velocity": 90}}`, a half beat
from beat 1.5 on pitch 60, which a window paints there, between cells; its
cells, which the terminal rounds it to, are placed in the domain too. A
plane drawn over by something else and then marked again goes on in a
node of its own after that (`roll#2`), so that the order drawn is kept.
Runs and fills drawn after a role a frontend paints and over it are
painted over it again, as the terminal shows them (a tint, for a fill that
only restyles).

A menu the kernel opens (a right click on a pane drawn from its scene)
is told in `frontend.watch`'s `modal.menu`, how many it has opened; the
window shows `paw.frontend.menu("shown")` at the pointer, and says what was
chosen with `menu_choose("shown", {}, path)` or that it was let go with
`menu_dismiss`. `modal.hint` is what the pointer is over, or what its drag
will do, for the status line.

`scene.input` takes a pointer event as `paw.canvas.pointer` does (`kind`
down, up, move, hover, double or wheel, `button`, `ctrl`, `shift`,
`alt`, `dx`, `dy`), with `x` and `y` in units from the window's corner.
The kernel finds the hit region under it in the scene it sent
(`paw_scene::Scene::hit`) and gives the view's gesture for it the event in
units, as the terminal gives it one in cells; a drag begun there goes on
in units until it is let go. Off every region, the event goes to the view
as a terminal's would.

With `"live": true` the connection is also sent, while they change, the
values a frontend moves things by without a new scene:

```json
{"event": "scene.live", "payload": {"position": 12.5, "playing": true, "recording": false,
  "clock": "0:07.0", "cpu": 0.075, "meters": {"4": [0.31, 0.3], "0": [0.4, 0.38]},
  "peaks": {"4": 0.5, "0": 0.6}, "clips": {"4": true}, "inputs": {"4": 0}}}
```

`meters` are each track's sides by its id, the master's as `"0"`; `peaks`
the loudest of late of each, and `clips` the tracks whose clip light is
lit (a click on the peak puts it out, as `paw.draw.clear_peak` does).

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
size). A character two cells wide takes two. `"mouse": false` asks the
terminal to stop reporting the pointer and leave it to its own selection
(`paw.opt.mouse` off); without it, or `true`, it reports it.

A terminal that shows images says so with a third parameter of
`ui.attach`, `{"graphics": true, "cell": [10, 20], "pixel_mouse": true,
"fg": "#cdd6f4", "bg": "#1e1e2e"}` (its cell size in pixels, whether it
reports the pointer in pixels, its colours). It is then also sent the
surfaces views keep for their pixels:

```json
"surfaces": [{"name": "notation", "x": 0, "y": 3, "w": 80, "h": 30,
              "cell": [10, 20], "covered": [[4, 2, 20]], "ops": [...]}]
```

`covered` lists what covers part of it (column, row and columns, from
its corner), and `ops`, the drawing (see `paw.canvas.paint`), comes only
when it differs from the last one sent for that name: the far side makes
the pixels. Without the parameter the views draw in cells for it.

`ui.input` takes one of

```json
{"key": "<C-s>"}
{"paste": "text"}
{"resize": [100, 30]}
{"mouse": {"kind": "down", "button": "left", "x": 3, "y": 4, "mods": "C"}}
```

with keys in the notation key mappings use, mouse kinds `down`, `up`,
`drag`, `move`, `scroll_up`, `scroll_down`, `scroll_left`, `scroll_right`,
and `mods` any of `C`, `A`, `S`. A terminal that reports the pointer in
pixels adds `"px"` and `"py"`, from the screen's corner, and
`{"cell": [w, h]}` says a cell has another size (the font changed).

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
`paw.frontend.act.*`) happens in its seat. The instance's own seat is its
terminal's, if it has one, and that of every connection without a seat of
its own (`paw ctl`, scripts). A new seat starts at the instance's cursor,
with the instance's panels shown, in normal mode; it closes with its
connection. Edits from two seats are steps in the one undo history.
Options (`paw.opt`) are shared. In Lua, `paw.seats` says whose turn it is
(`paw.seats.current`); see runtime/lua/paw/seats.lua for how a module
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
{"id": 5, "method": "eval", "params": ["paw.commands.run('import', { ... })", "/home/me/songs/media/take.wav"]}
```

The name keeps only its last part; a name taken already gets `-2`, `-3`…
The file has its name only once it is whole; one that has not ended when
its connection closes is thrown away. `:upload <path>` typed in an
attached terminal sends the connection `{"event": "file.wanted",
"payload": {"path": "…", "import": true}}`, for its program to send that
file from its own disk; `paw attach` does.

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
listening; `paw attach` and `paw-gui` do, playing the frames through a
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

The crate `paw-proto` (with `serde_json`, `anyhow`, `base64` and
`rustls` on `ring`, no OpenSSL) is the client's side:
`Connection::unix(path)` or `Connection::tcp(address, token)` (TLS,
remembering the certificate in the state directory;
`Connection::tcp_with(address, token, &Wire::…)` chooses where, or the
clear), then `call(method, params)`, `notify(method, params)`, the
`events` channel, `send_file(path)` and `send_and_import(path)`.
`paw_proto::monitor` makes and reads `audio.frame` payloads, and the crate
`paw-listen` plays them (`Player::device()`, or `Player::file(path,
rate)` to write them to a WAV file). `paw_core::remote::apply` puts
`ui.grid` events into a grid of cells.
