# Scripting

## The scripting interface

```lua
local daw = require("daw")   -- also the global `daw`
```

**Project, tracks, devices, clips.** Objects are handles: reading a field asks
the kernel, writing it tells the kernel. Volumes are in dB, positions and
lengths in beats, list positions count from 1.

```lua
daw.project.tempo = 112
local bass = daw.add_track({ name = "Bass", volume = -4 })
local synth = bass:add_device("synth", { wave = 2, cutoff = 500 })
synth:set("resonance", 0.3)
synth.bypass = false

local clip = bass:add_clip({ start = 0, length = 4 })
clip:add_note({ pitch = "A1", start = 0, length = 0.5, velocity = 100 })
clip:add_notes({ { pitch = 45, start = 1 }, { pitch = 48, start = 2 } })
-- An audio clip from a WAV, AIFF, FLAC, MP3 or Ogg Vorbis file, and its waveform.
local take = bass:add_clip({ start = 8, file = "take.flac" })
take:peaks(64)                 -- 64 { min, max } pairs, for drawing

local bus, echo = daw.add_track({ name = "Bus" }), daw.add_track({ name = "Echo" })
bass.output = bus              -- route into another track
bass:send(echo, -12)           -- and send some of it to a third, 12 dB down

daw.tracks()   bass:devices()   bass:clips()   clip:notes()   bass:clip_at(2)

-- One note at a time, named by its place among the clip's notes, which are
-- kept in the order they start. Nothing else crosses over, so this is what
-- an editor uses; `set_note` returns the note's place afterwards.
local note, at = clip:note_at("E2", 1.25)       -- the note sounding there
clip:set_note(at, { length = 2 })
clip:add_note({ pitch = "G2", start = 3, length = 1 })
clip:remove_note(1)
clip:notes({ from = 0, to = 4, low = "C2", high = "C3" })   -- a part of them, and their places
clip:edit_notes({ set = { { index = 1, start = 0.5 } }, remove = { 2 }, add = {} })  -- several as one edit
daw.project.save("song.json")   daw.project.load("song.json")
daw.render("mix.wav", { tail = 2 })
```

**Transport.**

```lua
daw.transport.play()   daw.transport.stop()   daw.transport.seek(8)
daw.transport.loop_start, daw.transport.loop_end = 0, 16
daw.transport.loop_enabled = true
bass:play_note("C2", 100, 200)     -- sound a note now, outside the timeline
daw.transport.record()             -- record armed tracks; see Input and recording
daw.transport.punch_start, daw.transport.punch_end = 16, 32   -- record only there
daw.transport.punch_enabled = true
daw.opt.count_in = 1               -- a bar counted before a take; transport.counting is what is left
daw.opt.pre_roll = 2               -- play two bars (and daw.opt.pre_roll_seconds more) before a punch in
```

**The tempo lane.** `daw.tempolane` is the row under the ruler that draws the
tempo map: `show(on)`, `toggle()`, `shown()`, `range()` (the tempo at its bottom
and top), and the edits a gesture makes, all through `daw.tempo`: `add(beat,
bpm)`, `move(beat, to, bpm)`, `remove(beat)`, `ramp(beat)` and `draw(points)`.

**Automation.** `daw.lanes` shows lanes as rows of the arrange view:
`daw.lanes.open(track)`, `toggle`, `is_open`, `lines()` (also
`daw.groups.rows({ lanes = true })`: `{ track = id }` or `{ track = id, lane = id }`
for each row), `name(lane)`, `format(lane, value)`, `value_at(lane, beat)`;
`daw.cursor.lane_id()` is the lane row the cursor is on, `daw.cursor.line()`
its place among every row. Keys mapped with `view = "arrange.lane"` act on a
lane row ahead of the arrange view's own.
A lane moves a track's volume or pan, or one parameter of a
device on the track, along points of `{ beat, value }` in the target's own
units (dB, -1 to 1, the parameter's range), joined by straight lines and held
before the first point and after the last.

```lua
local fade = bass:automate("volume")            -- or "pan"; the existing lane if there is one
fade:add(0, -60)   fade:add(8, 0)               -- a point at a beat replaces any already there
synth:automate("cutoff"):set_points({ { 0, 200 }, { 16, 4000 }, { 16, 300 } })   -- two at a beat step
fade.enabled = false   fade:clear()   fade:remove()
fade:points()   fade:value_at(4)   bass:lanes()   bass:value_at("volume", 4)   synth:value_at("cutoff", 4)
```

While the transport plays, an enabled lane sets its target at the start of
every block, offline renders included, and wins over the fader or
`device:set`: those change the track's or device's own value, which is what
`track.volume` and `device.params` read. When playback stops the target stays
where the lane left it until it is set by hand or playback starts again;
turning a lane off or removing it puts the own value back. Removing a device
removes its lanes, and moving it to another track takes them along. Lanes are
saved with the project and undone like any edit, and report `lane.added`,
`lane.changed` and `lane.removed`.

**Commands, keys, events, options.**

```lua
daw.command(name, function(ctx) end, { desc = "..." })   -- ctx.args, ctx.count
-- What the arguments complete to on the command line: a completer's name for
-- every argument, a list of them by position, or a function returning strings
-- or { text = ..., desc = ... }. Completers: commands, tracks, devices,
-- track_devices, options, views, pickers, files, audio_files, projects; add
-- more to daw.commands.completers. daw.commands.complete(line) lists them.
daw.command("send.to", fn, { complete = { "tracks" } })
daw.command("mood", fn, { complete = function(text, info) return { "calm", "loud" } end })
daw.cmd("track.add", { "Bass", device = "synth" })
daw.keymap.set("<leader>x", "command and arguments", { view = "arrange", desc = "..." })
daw.keymap.set("gx", function(ctx) end)          -- ctx.count, ctx.register
daw.keymap.set("gz", fn, { mode = { "n", "x" } })    -- normal and visual mode; "i" is insert
daw.keymap.set("}", fn, { view = "arrange", motion = true })  -- a motion: also after operators and in visual mode

-- An operator gets a region: rows r0..r1, beats c0 up to c1, kind "char", "line" or "block".
-- Counts, text objects, visual mode, `.` and macros then work with it unasked.
daw.keymap.operator("gR", function(region, ctx)
  for _, id in ipairs(daw.edit.arrange.tracks(region)) do
    for _, clip in ipairs(daw.track(id):clips()) do
      if clip.start >= region.c0 and clip.start < region.c1 then clip.name = "take" end
    end
  end
end, { view = "arrange", desc = "Name clips `take`" })
daw.keymap.textobject("ip", function()               -- from the cursor to the playhead
  local row = daw.cursor.index()
  return { kind = "char", r0 = row, r1 = row, c0 = daw.cursor.beat, c1 = daw.transport.position }
end, { view = "arrange", desc = "Up to the playhead" })

daw.keymap.setreg(value, name)   daw.keymap.getreg(name)   daw.keymap.selection()
daw.keymap.feed("3jdd")          daw.keymap.normal("dic")  -- as typed; from inside a mapping
daw.edit.arrange.yank(region)    daw.edit.arrange.paste(value)   daw.edit.roll.delete(clip, region)
track:snapshot()                 daw.restore_track(snapshot, index)   -- with devices, clips, automation
daw.roll_clips.parts()           daw.roll_clips.open(ids, active)     -- the clips the piano roll edits (docs/harmony.md)
daw.ui.views.pianoroll.layer("lint", 35, paint, marks)                -- draw in the piano roll, both frontends

-- A view of your own joins in by having a grid: where its cursor is, and how to move it.
view.grid = { get = function() return row, beat end, set = function(row, beat) end, step = function() return 1 end }

daw.on("track.added", function(event) end)    -- also track.changed, track.removed, track.moved,
                                              -- device.*, clip.*, lane.*, project.*, transport.*
daw.on("clip.*", fn)   daw.on("*", fn)   daw.emit("my.event", { any = "data" })

daw.opt.grid = 0.5                            -- see runtime/lua/daw/options.lua
daw.option.define("my_option", 42)
```

Change events are delivered when the current command or callback returns;
`daw.flush()` delivers them at once. Each command or key press is one undo step.
A handler may answer an edit with edits of its own, which join the same undo
step. Events from undo, redo, the undo tree or opening a project carry
`restored = true`: that state already holds whatever the handlers answered.

**Views.** A view is a table with a `render` function that draws into a cell
buffer. Errors in a view are shown in its place and do not affect the others.

```lua
daw.ui.view("clock", {
  render = function(self, buf, ctx)
    buf:fill(0, 0, buf.width, buf.height, " ", "StatusLine")
    buf:text(1, 0, daw.time.format(daw.transport.position), { fg = "#ff9e64", bold = true })
  end,
  on_key = function(self, key) end,           -- keys with no mapping
  on_mouse = function(self, event) end,
})
daw.ui.dock("clock", { side = "top", size = 1 })
daw.ui.toggle("mixer")   daw.ui.focus("arrange")   daw.ui.open("help", { title = "Keys" })
daw.ui.input({ prompt = "Name: " }, function(text) end)
daw.ui.menu({ { label = "Rename", run = function() end }, "-", { label = "Delete", keys = "x", run = function() end } }, { x = 10, y = 4 })
daw.notify("message", "warn")
```

A view's `on_mouse` gets the terminal's pointer in the view's own cells:
`kind` (`down`, `up`, `drag`, `move`, `scroll_up`, `scroll_down`,
`scroll_left`, `scroll_right`), `button`, `x`, `y`, `mods` (any of `C`, `A`,
`S`), `double` on the second press of a double click, and where the view is
(`view_x`, `view_y`, `w`, `h`). `daw.mouse.grab(event, { drag = fn, up = fn })`
on a press keeps the drags and the release for the view wherever the
pointer goes, with `dx`, `dy` from the press; `daw.mouse.hint(text)` says
on the status line what is under the pointer. See `runtime/lua/daw/mouse.lua`.

**Completion.** `daw.complete` shows suggestions as ghost notes in the piano
roll, from sources that extensions register; see "Writing a source" in
[harmony.md](harmony.md) for the context and the items.

```lua
daw.complete.register({ name = "mine", priority = 10, views = { "pianoroll" }, auto = true,
  complete = function(ctx, done) done({ { label = "a fifth up", notes = { { pitch = ctx.pitch + 7, start = ctx.at, length = 1 } } } }) end })
daw.complete.request("manual")    daw.complete.current()    -- { items, index, item, clip } or nil
daw.complete.select(1)            daw.complete.select(3, true)   daw.complete.accept()   daw.complete.accept(true)  -- next notes only
daw.complete.dismiss()            daw.complete.audition()   daw.complete.unregister("mine")
daw.complete.show(items, { keys = false })   -- ghost notes for a preview, from any module
daw.on("complete.changed", function(e) end)  -- e.shown
```

**The piano roll's layers.** What a module draws over the piano roll's grid
goes in a layer, so that several share it in a fixed order from back to
front: other tracks' notes (10), the clip's own notes (20), diagnostics (30),
an active snippet (40), suggestions (50), then the cursor. A layer paints in
the terminal with `paint(p)` and may tell the window what to draw with
`marks(clip)`; keys that hold while some state lasts go in a key scope,
which comes before the piano roll's own keys; the window's toolbar takes
switches.

```lua
local roll = daw.ui.views.pianoroll
roll.layer("lint", 30,
  function(p)                           -- p.roll, p.x(beat), p.row(pitch) (nil off screen), p.data, p.hue
    local row = p.row(60)
    if row then p.roll:text(p.x(4), row, "!", "Error") end
  end,
  function(clip)                        -- what the window draws: boxes, or chips that can be clicked
    return { { pitch = 60, start = 4, length = 1, fill = "#e06c75", alpha = 0.2, edge = "#e06c75" },
             { pitch = 61, start = 4, length = 0, badge = true, label = "parallel fifths", act = "my_fix", arg = 1 } }
  end)
roll:key_scope("pianoroll.lint", 30, function() return showing end)   -- then map keys in view "pianoroll.lint"
roll:tool("lint", function() return { label = "Lint", on = enabled, act = "toggle_lint", tip = "..." } end)
daw.ui.keybar.set("pianoroll.lint", "n", { { "<C-y>", "fix" } })     -- the key line while the scope is on
```

A chip's `act` names a `daw.frontend.act` function, called with the clip and
`arg`. A key scope that maps `<Esc>` gets it before insert or visual mode is
left. A failing layer is skipped, and the others are drawn.

**Other.** `daw.defer(fn, ms)`, `daw.every(ms, fn)`, `daw.cancel(handle)`;
`daw.state.key = value` survives `:reload`; `project.meta` and `track.meta` are
saved with the project, for extension data; `daw.music.pitch("F#3")`,
`daw.music.degree("A4", "minor_pentatonic", 3)`; `daw.time.format(beats)`;
`daw.harmony` is the chords and key that sound when (`daw.harmony.at(8)`,
`.next(8)`, `.key(8)`, providers with `.provide`), and `daw.snippet` writes
named music from them (`daw.snippet.add`, `.expand("dominant")`); both in
[Harmony, completion and snippets](harmony.md).
`:3snippet arp`: a number before a command's name is its count.
`daw.cursor` is the edit cursor; `daw.inspect(value)`; `daw.device_types()`
lists every device kind with its format and vendor. Notes may carry a `meta`
table too (`{ pitch = 60, start = 0, meta = { lyric = "la" } }`), which stays
with the note through edits. `daw.render` emits `render.before` and runs its
handlers before it starts.

**Helper programs.** An extension can run a program of its own and talk to it
over a Unix socket, in plain bytes: `daw.api.proc_spawn(argv, { env, cwd, log })`,
`proc_status(id)`, `proc_stop(id)` (asks it to finish, as Ctrl-C would, and
leaves it the time to), `proc_kill(id)`; `sock_listen(path)`, `sock_connect(path)`,
`sock_accept(id)`, `sock_read(id)` (`""` when nothing has arrived, nil once
closed), `sock_write(id, bytes)`, `sock_close(id)`. A device that takes data
from scripts answers `daw.api.device_call(device, method, bytes)`. A helper
is asked to finish when the program ends, however it ends. Started with
`{ pipe = true }`, a program is talked to over its standard input and
output instead (its errors still go to `log`): `proc_write(id, bytes)`,
`proc_read(id)` (`""` when nothing is waiting, nil once it closed its
output), `proc_close_input(id)`; a `proc.output` event (`{ id }`) says when
there is something to read, so nothing polls.

**Diagnostics and language servers.** `daw.diagnostic` is `vim.diagnostic`
for clips: `set(namespace, clip, list)` with each
`{ notes = { places }, at, length, severity, message, rule, source, fixes }`
(`severity` 1 to 4, or "error", "warning", "info", "hint"; a fix is
`{ title, edits = { { note, pitch | delete | start | length | velocity } } }`
or `{ title, apply = fn }`), `get(clip, { namespace, severity, note })`,
`count(clip)`, `reset(namespace, clip)`, `config({ virtual_text, signs,
underline, severity_sort })`, `actions(clip, place)`, `apply(d, fix)` (one
undo step), `goto_next()`, `goto_prev()`, `list()`; event
`diagnostic.changed`. `daw.lsp` is `vim.lsp`: `config(name, { cmd, framing,
attach, settings, init_options, restart })`, `enable(name, on)`,
`clients()`, `restart(name)`, `stop(name)`, `request(name, method, params,
function(err, result) end)`, `notify(name, method, params)`,
`daw.lsp.handlers[method] = function(client, params) end`, `hover(clip,
pitch, beat, cb)`, `complete(ctx, done)`, `attach(name, clip)` to keep a
clip open in a server, `settle()` for scripts; events `lsp.status`,
`lsp.analysis`. See [Language servers and diagnostics](lsp.md).

`daw.json.encode(value, pretty)` and `daw.json.decode(text)` are for what an
extension keeps in files of its own.

Underneath, `daw.api` is a flat set of functions over plain data
(`daw.api.track_set(id, "volume", -6)`). The objects above are a thin Lua layer
over it in [objects.lua](../runtime/lua/daw/objects.lua).

## Scripts and other programs

`daw -l script.lua [args]` runs a script with no UI and exits, which makes the
DAW usable as a batch tool. A running instance listens on a Unix socket:

```sh
daw ctl eval 'daw.transport.position'
daw ctl cmd track.add Bass device=synth
daw ctl track_set 3 volume -6                 # any daw.api function
daw ctl keys 'ggm'
daw ctl eval 'daw.api.ui_snapshot(100, 30)'   # the screen as text
```

One JSON object per line: `{"id":1,"method":"eval","params":["..."]}`.
A connection can also be sent things: events it subscribed to, the state
a frontend draws (pushed when it changes, in parts), and the terminal
UI's screen. [docs/protocol.md](protocol.md) is the whole protocol.

**An instance on another machine.** `daw attach` makes the terminal it
runs in a terminal of an instance that is already running, beside the
instance's own terminal if it has one (`daw --headless` has none), with a
seat of its own: its own cursor, mode, selection and keys, in the one
project. `:detach` leaves and the instance runs on.
`daw ctl`, `daw attach` and `daw-gui` all reach an instance three ways:

```sh
daw attach                                   # this machine's socket
daw attach --socket /tmp/studio.sock         # another socket, such as one carried by SSH
daw attach --connect studio:7700 --token-file studio.token   # over the network
```

Over the network the instance has to be started with `--listen-tcp
0.0.0.0:7700` (or `127.0.0.1:7700` for this machine alone); the
connection is encrypted (TLS) and has to show that it knows the token.
[Running it](running.md#on-another-machine) says how to set that up,
send files from the machine you sit at, and hear the instance there.

**State of each seat, for module authors.** Whatever a module keeps about
what a person is looking at or in the middle of (a cursor, a scroll, a
selection, a drag, what the pointer hovers, a prompt, a suggestion
shown, a snippet being filled in) belongs to a seat, not to the instance.
Keep it where you would anyway, in locals or in your view's table, and
name it once, next to where it is made:

```lua
local active, shown = nil, {}   -- module locals
daw.seats.keep("mymod",
  function() return active, shown end,              -- what there is now
  function(a, s) active, shown = a, s end,          -- put another seat's back
  function() return nil, {} end)                    -- what a new seat starts with

-- Fields of a table (a view's): the names, and what a new seat starts with.
daw.seats.fields("mymod.view", view, { "scroll", "hover", "drag" }, { scroll = 0 })
```

Code that reads them needs no change: when another seat's turn comes the
values are swapped in, and with one seat nothing moves. Keep in a seat only
what is about viewing; what is about the project (its notes, the shown
lanes that are saved with it, diagnostics of the project itself) stays
shared. A table you keep is swapped whole, so a new seat must get a new
one (`function() return {} end`, never a table made once outside it).
Timers run in the seat that started them; `daw.seats.current` says whose
turn it is, and `daw.seats.within(id, fn, ...)` runs something in another
seat. See runtime/lua/daw/seats.lua.

`daw doctor` is a script of its own kind: it runs the checks of
[extensions/doctor](../extensions/doctor) that need nobody, with the sound device
open (unlike other scripts, which get the null backend unless told), and prints
the report. It takes the program's audio options, `--seconds`, `--plugin` and
`--only`, and finds the extension in the source tree beside the binary or in
`$DAW_HOME`.
