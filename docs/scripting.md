# Scripting

## The scripting interface

```lua
local paw = require("paw")   -- also the global `paw`
```

**Project, tracks, devices, clips.** Objects are handles: reading a field asks
the kernel, writing it tells the kernel. Volumes are in dB, positions and
lengths in beats, list positions count from 1.

```lua
paw.project.tempo = 112
local bass = paw.add_track({ name = "Bass", volume = -4 })
local synth = bass:add_device("synth", { wave = 2, cutoff = 500 })
synth:set("resonance", 0.3)
synth.bypass = false

local clip = bass:add_clip({ start = 0, length = 4 })
clip:add_note({ pitch = "A1", start = 0, length = 0.5, velocity = 100 })
clip:add_notes({ { pitch = 45, start = 1 }, { pitch = 48, start = 2 } })
-- An audio clip from a WAV, AIFF, FLAC, MP3 or Ogg Vorbis file, and its waveform.
local take = bass:add_clip({ start = 8, file = "take.flac" })
take:peaks(64)                 -- 64 { min, max } pairs, for drawing

local bus, echo = paw.add_track({ name = "Bus" }), paw.add_track({ name = "Echo" })
bass.output = bus              -- route into another track
bass:send(echo, -12)           -- and send some of it to a third, 12 dB down

paw.tracks()   bass:devices()   bass:clips()   clip:notes()   bass:clip_at(2)

-- One note at a time, named by its place among the clip's notes, which are
-- kept in the order they start. Nothing else crosses over, so this is what
-- an editor uses; `set_note` returns the note's place afterwards.
local note, at = clip:note_at("E2", 1.25)       -- the note sounding there
clip:set_note(at, { length = 2 })
clip:add_note({ pitch = "G2", start = 3, length = 1 })
clip:remove_note(1)
clip:notes({ from = 0, to = 4, low = "C2", high = "C3" })   -- a part of them, and their places
clip:edit_notes({ set = { { index = 1, start = 0.5 } }, remove = { 2 }, add = {} })  -- several as one edit
paw.project.save("song.json")   paw.project.load("song.json")
paw.render("mix.wav", { tail = 2 })

-- MIDI files. `read` gives what is in one, in ticks (`ppq` to a beat):
-- { format, ppq, tracks = { { name, notes, controls } }, tempos, signatures, markers, skipped }.
paw.open("song.mid")                                   -- a new project of it, as :open does
paw.midifile.import("song.mid", { start = 16, tempo = true })   -- into this one; { track = t } as one clip
paw.midifile.export("out.mid", { clips = { clip.id } })         -- or { tracks = { ... } }, or the whole project
local file = paw.midifile.read("song.mid")             -- parse(bytes) and encode(file) work on bytes
```

**What extensions keep with notes.** A clip's notes belong to nobody: any
view or extension edits them, and nothing is asked. What an extension
knows about a note that MIDI cannot say (a lyric, a spelling) it keeps in
the note's `meta`, under a key of its own (`meta.lyric`, `meta.notation`),
and about the clip in `clip.meta`; the core carries it with the note
through moves, copies, undo and saving, and never reads it.

**A note's attribute: articulations.** A note may carry the attribute of
a MIDI 2.0 note-on, `note.attr = { type, data }` (nil for none): mostly an
articulation of the orchestral articulation profile (M2-123), where the
type is the classification (0x10 to 0x1F) and the data's top bits the
subclass and variation. Unlike `meta` it is MIDI, so the core keeps it and
plays it: through edits, copies and pastes, undo, project files, recording
from MIDI 2.0 input, and MIDI files (in a sequencer-specific event just
before the note, which other programs pass over). It reaches MIDI 2.0
ports, CLAP plugins that prefer MIDI 2.0 notes, and Lua devices; what
takes only MIDI 1.0 never sees it, unless the track's `attr_map` (below)
tells it in keyswitches.

```lua
clip:add_note({ pitch = "G4", start = 2, attr = paw.attr.m2("11.A") })   -- pizzicato
clip:set_note(at, { attr = false })            -- none; left out, a change keeps it
paw.attr.m2("11.A")          -- { type = 0x11, data = 0xA000 }; "10.23" with a variation
paw.attr.m2(note.attr)       -- "11.A", or nil for what is no articulation
paw.attr.m2("11.A", { direction = "up", string = 4, reset = true })
paw.attr.parts(note.attr)    -- { type, data, subclass, variation, direction, reset, string }
paw.attr.describe(note.attr) -- { code = "11.A", tag = "pz", name = "Pizzicato", class = ..., text = "Pizzicato (11.A)" }
bass:play_note("C2", 100, 200, paw.attr.m2("11.0"))   -- live, with what the map sends first
```

The piano roll writes the tag on a note long enough for it, the window
gives the note a chip, and `K` says what it is. Naming articulations per
instrument, choosing them and drawing them well is
the articulations extension's work; the core keeps only the numbers.

**What an instrument is told for an attribute: `track.attr_map`.** For an
instrument that takes only MIDI 1.0 (most samplers and libraries, any
hardware), a track's map turns its notes' attributes into what that
instrument understands. It is plain data; whatever knows the instrument
writes it (an articulations extension from its own files), and the project
keeps it and plays it with no extension loaded.

```lua
track.attr_map = {
  send = "change",                   -- only when a note's articulation differs from the one before; "every"
  default = { out = "ks=C1" },       -- notes with no attribute; or the code of an entry: default = "10.0"
  arts = { ["11.0"] = { out = "ks=D1" }, ["11.A"] = { out = "ks=E1 cc1=96", name = "pizz" } },
  by_type = { [0x13] = { out = "pc=12" } },   -- a whole classification, or another attribute type
  chase = { 1, 11 },                 -- controllers told again after a change
  attribute = true,                  -- notes keep their attribute as well (false: drop it, `attr` keeps one's)
  delay = 0,                         -- milliseconds every note plays early (below 0) or late; an entry's own `delay` wins
}
track.attr_map = nil                 -- none
```

`out` is events separated by spaces: `ks=D1` a keyswitch struck (`ks=D1:64`
with a velocity), `hold=D1` one held while the articulation lasts,
`cc32=40` (0 to 127), `pc=12` or `pc=12/258` with a bank, `bend=0.5`, `ch=2`
(the note goes out on channel 2, and so do its events: a multi-timbral
instrument), `attr` (this note keeps its attribute). Keys are named with C4
as 60. An entry may carry fields of its writer's beside `out`, kept as they
are. A note's articulation is found by its code, falling back as M2-123 says:
the subclass without its variation, the classification's `by_type` entry,
its subclass 0, then `"10.0"`; then `default`. The events go on the note's
own beat, ahead of it, which is the order a keyswitched sampler needs; where
playback starts or the loop goes back, the last change before it is sent
again first. A map that does not read is refused when it is set.

**Notes that sound on the beat.** A library whose staccato speaks slowly,
or whose legato starts with a transition, is played early by that much:
`arts["11.0"] = { out = "ks=D1", delay = -80 }` (milliseconds) moves those notes (their
start, their end, and the keyswitch before them) 80 ms earlier, so that
they can be written on the beat and still sound on it; `attr_map.delay`
is the same for every note whose entry has none. The kernel moves them
when it lays the track's events out, by the tempo map at each note, so
playing, an offline render, a bounce and a freeze all agree, and a tempo
change moves them again. A note moved before where playback starts (the
song's first beat, a seek, the loop's start after it goes round) starts
there, as a note already sounding does: as early as it can.
`paw.attr.delay_of(track, attr)` says how far a note is moved, for a
view to show. Notes played live are not moved: they cannot be earlier
than now.

**Transport.**

```lua
paw.transport.play()   paw.transport.stop()   paw.transport.seek(8)
paw.transport.loop_start, paw.transport.loop_end = 0, 16
paw.transport.loop_enabled = true
bass:play_note("C2", 100, 200)     -- sound a note now, outside the timeline
paw.transport.record()             -- record armed tracks; see Input and recording
paw.transport.punch_start, paw.transport.punch_end = 16, 32   -- record only there
paw.transport.punch_enabled = true
paw.opt.count_in = 1               -- a bar counted before a take; transport.counting is what is left
paw.opt.pre_roll = 2               -- play two bars (and paw.opt.pre_roll_seconds more) before a punch in
```

**The tempo lane.** `paw.tempolane` is the row under the ruler that draws the
tempo map: `show(on)`, `toggle()`, `shown()`, `range()` (the tempo at its bottom
and top), and the edits a gesture makes: `add(beat, bpm)`, `move(beat, to,
bpm)`, `remove(beat)`, `ramp(beat)` and `draw(points)`, each one undo step.
They change the map through `paw.tempo`, which reads and sets it: `at(beat)`,
`set(beat, bpm)`, `remove(beat)`, `points()`, `signatures()`,
`set_signature(bar, num, den)`.

**Automation.** `paw.lanes` shows lanes as rows of the arrange view:
`paw.lanes.open(track)`, `toggle`, `is_open`, `lines()` (also
`paw.groups.rows({ lanes = true })`: `{ track = id }` or `{ track = id, lane = id }`
for each row), `name(lane)`, `format(lane, value)`, `value_at(lane, beat)`;
`paw.cursor.lane_id()` is the lane row the cursor is on, `paw.cursor.line()`
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
paw.command(name, function(ctx) end, { desc = "..." })   -- ctx.args, ctx.count
-- What the arguments complete to on the command line: a completer's name for
-- every argument, a list of them by position, or a function returning strings
-- or { text = ..., desc = ... }. Completers: commands, tracks, devices,
-- track_devices, options, views, pickers, files, audio_files (sound and MIDI
-- files), projects, openable (projects, MIDI and sound files); add
-- more to paw.commands.completers. paw.commands.complete(line) lists them.
paw.command("send.to", fn, { complete = { "tracks" } })
paw.command("mood", fn, { complete = function(text, info) return { "calm", "loud" } end })
-- Ranges, as in Vim. `:'<,'>name` runs a command on the last selection made
-- in the focused view (`:` in visual mode starts the prompt with it):
-- ctx.range is { selection = true, region = <as an operator gets it> }, and
-- paw.keymap.selection() returns that region while the command runs, so a
-- command that works on the selection takes the range unasked. `:5,8name`
-- (or `:5name`, `:%name`, `:'a,'bname`, `:.+4name`; docs/terminal.md, "Ex")
-- gives time, to commands made with `range = true` only: ctx.range is
-- { bars = { 5, 8 }, from, to }, beats of the song, `to` not included.
-- `:t2,t4name` (`t*`, `t/Drums/`) adds tracks = { ids }; a command without
-- `range = true` given only tracks runs once at each, the cursor on it.
-- With `:g/pattern/name` it gets ctx.range = { items = <the matches> }.
paw.command("bars.color", function(ctx) local r = ctx.range end, { range = true })
paw.commands.exec("5,8bars.color red")   -- as typed after `:`; paw.commands.range(line) splits it off
-- What a range holds: notes, clips or tracks ("note", "clip", "track"), each
-- { kind, track, clip, note, place, at } (`at` in beats of the song). A time
-- range alone holds every track's, or the notes of the clips the focused view
-- edits (the piano roll's).
paw.command("vel.half", function(ctx)
  local changes = {}
  for i, item in ipairs(paw.ex.items(ctx.range, "note")) do
    changes[i] = { item = item, change = { velocity = math.floor(item.note.velocity / 2) } }
  end
  paw.ex.apply(changes)                  -- one edit per clip; paw.ex.apply(nil, items) removes
end, { range = true, desc = "Halve the velocity of the notes in a range" })
-- A field for :s and :g patterns: `:%s/lyric:la/lyric=lu/g`. `level` is what it
-- belongs to ("note", "clip", "track"); `type` "number", "beats" (takes `1/8`),
-- "pitch" or "text"; `set` writes into `change`, as paw.api keeps the thing.
paw.ex.field("lyric", { level = "note", type = "text", desc = "the sung syllable",
  get = function(item) return item.note.meta and item.note.meta.lyric end,
  set = function(item, value, change) change.meta = paw.util.merge(item.note.meta or {}, { lyric = value }) end })
-- A view of your own whose beats are not the song's, or that edits some clips:
paw.ex.view("myview", { song = function(col) return clip_start + col end,
  clips = function() return { clip_id } end, track = function() return track_id end,
  go = function(beat) end })                -- put the cursor at a beat of the song
paw.cmd("track.add", { "Bass", device = "synth" })
paw.keymap.set("<leader>x", "command and arguments", { view = "arrange", desc = "..." })
paw.keymap.set("gx", function(ctx) end)          -- ctx.count, ctx.register
paw.keymap.set("<localleader>x", fn, { view = "myview" })  -- a view's own leader (a backslash); never `<leader>` for one view's keys
paw.keymap.set("gz", fn, { mode = { "n", "x" } })    -- normal and visual mode; "i" is insert
paw.keymap.set("}", fn, { view = "arrange", motion = true })  -- a motion: also after operators and in visual mode

-- An operator gets a region: rows r0..r1, beats c0 up to c1, kind "char", "line" or "block".
-- Counts, text objects, visual mode, `.` and macros then work with it unasked.
paw.keymap.operator("gR", function(region, ctx)
  for _, id in ipairs(paw.edit.arrange.tracks(region)) do
    for _, clip in ipairs(paw.track(id):clips()) do
      if clip.start >= region.c0 and clip.start < region.c1 then clip.name = "take" end
    end
  end
end, { view = "arrange", desc = "Name clips `take`" })
paw.keymap.textobject("ip", function()               -- from the cursor to the playhead
  local row = paw.cursor.index()
  return { kind = "char", r0 = row, r1 = row, c0 = paw.cursor.beat, c1 = paw.transport.position }
end, { view = "arrange", desc = "Up to the playhead" })

paw.keymap.setreg(value, name)   paw.keymap.getreg(name)   paw.keymap.selection()
paw.keymap.group("<leader>x", "mix checks")      -- the name the key hints give a prefix: `+mix checks`
paw.keymap.last_selection()      -- the selection open now, or the one visual mode last closed: '<,'>
paw.keymap.with_selection(region, fn, ...)   -- run fn with region as the selection, as :'<,'> does
paw.keymap.feed("3jdd")          paw.keymap.normal("dic")  -- as typed; from inside a mapping
paw.edit.arrange.yank(region)    paw.edit.arrange.paste(value)   paw.edit.roll.delete(clip, region)
track:snapshot()                 paw.restore_track(snapshot, index)   -- with devices, clips, automation
paw.roll_clips.parts()           paw.roll_clips.open(ids, active)     -- the clips the piano roll edits (docs/harmony.md)
paw.ui.views.pianoroll.layer("lint", 35, paint, marks)                -- draw in the piano roll, both frontends

-- A view of your own joins in by having a grid: where its cursor is, and how to move it.
view.grid = { get = function() return row, beat end, set = function(row, beat) end, step = function() return 1 end }
-- Optional: where the thing under the cursor ends (a note), so that a selection takes it in.
view.grid.extent = function(row, beat) return beat + 1 end

paw.on("track.added", function(event) end)    -- also track.changed, track.removed, track.moved,
                                              -- device.*, clip.*, lane.*, project.*, transport.*
paw.on("clip.*", fn)   paw.on("*", fn)   paw.emit("my.event", { any = "data" })

paw.opt.grid = 0.5                            -- see runtime/lua/paw/options.lua
paw.option.define("my_option", 42)
paw.option.define("lanes", 4, { min = 1, max = 16, integer = true })
paw.option.define("look", "plain", { values = { "plain", "fancy" } })
```

An option with a default takes values of the default's type, and the
runtime's numbers stay in a range (`grid` from 1/128 to 64 beats,
`velocity` 1 to 127): `paw.opt.grid = "abc"` is an error that says what
`grid` takes, and `:set grid=abc` says it and leaves `grid` as it was.
`paw.option.define`'s third argument says more: `min`, `max`, `integer`,
`values` (the only strings or booleans it takes) and `type` (a list of
types, for an option such as `track_height` that is a number or `"auto"`).
`paw.option.check(name, value)` asks without setting. An option nobody
defined takes anything.

Change events are delivered when the current command or callback returns;
`paw.flush()` delivers them at once. Each command or key press is one undo step.
A handler may answer an edit with edits of its own, which join the same undo
step. Events from undo, redo, the undo tree or opening a project carry
`restored = true`: that state already holds whatever the handlers answered.

**Views.** A view is a table with a `render` function that draws into a cell
buffer. Errors in a view are shown in its place and do not affect the others.

```lua
paw.ui.view("clock", {
  render = function(self, buf, ctx)
    buf:fill(0, 0, buf.width, buf.height, " ", "StatusLine")
    buf:text(1, 0, paw.time.format(paw.transport.position), { fg = "#ff9e64", bold = true })
  end,
  on_key = function(self, key) end,           -- keys with no mapping
  on_mouse = function(self, event) end,
})
paw.ui.dock("clock", { side = "top", size = 1 })
paw.ui.toggle("mixer")   paw.ui.focus("arrange")   paw.ui.open("help", { title = "Keys" })
paw.ui.input({ prompt = "Name: " }, function(text) end)
paw.ui.menu({ { label = "Rename", run = function() end }, "-", { label = "Delete", keys = "x", run = function() end } }, { x = 10, y = 4 })
paw.notify("message", "warn")
```

Where the terminal shows pictures, a view can keep a rectangle of its
buffer for pixels under its cells, and draw cells there only when it
cannot (`paw.opt.graphics` off, tmux, a terminal without images):

```lua
local pictured = buf:strip(0, 1, buf.width, buf.height - 1, { key = "level", under = true,
  draw = function(g, px) paw.plot.curve(g, px, { points = points, from = 0, pixels_per_beat = 4 * px.cell.w }) end })
if not pictured then draw_it_in_cells() end
```

[Extensions](extensions.md) says more ("Pictures in the terminal").

<a id="roles"></a>**Roles.** A view written once is shown by every
frontend: the terminal draws its cells, and the window draws the same
layout in its own font. Where something is a control (a fader, a switch,
a button), the view marks it as a role over its rectangle, with what it
shows as props; the terminal draws the role's cells, as the view would
have, and the window paints it as a widget. The pointer works through hit
regions: a press, a move or the wheel on one goes to the view's gesture
for its kind, from the terminal in whole cells and from the window in
fractions of one (`e.fine`), the same function either way.

```lua
paw.ui.role("hit", {                                -- an extension's own role
  props = { velocity = "number 0..127" },
  cells = function(buf, p) buf:text(0, 0, p.velocity > 90 and "█" or "▄", "Title") end,
})
paw.ui.view("pads", {
  render = function(self, buf, ctx)
    buf:mark("hit", 2, 1, 2, 1, { velocity = 100, hit = { kind = "pad", n = 1 } })
    buf:mark("fader", 6, 1, 3, 8, { at = 0.7, zero = 0.8, hit = { kind = "level" } })
    buf:mark("meter", 10, 1, 2, 8, { levels = { l, r }, bind = "meter:" .. track })
    buf:mark("button", 0, 9, 6, 1, { text = "play", hit = { cmd = "play" } })
    buf:hit(0, 0, buf.width, 1, { kind = "title", hint = "the pads" })
    local left, right = buf:columns({ 12, "*" }, 1)   -- buffers side by side
  end,
  gestures = {
    pad = function(self, e)                           -- e.hit, e.rect, e.x, e.y, e.kind, e.button
      if e.kind == "down" then paw.mouse.grab(e, { drag = function(d) end, up = function(u) end }) end
    end,
  },
})
```

The widget roles are `label` (`text`, `align`), `button` (`text`, `on`),
`switch` (`letter`, `on`, `style`, `tone`), `knob` (`value` -1 to 1),
`fader` (`at` and `zero`, 0 to 1 along its travel), `meter` (`levels`,
`hold`) and `chip` (`text`, `style`, `color`); `style` is how the terminal
draws it, `tone` a colour of the window's palette by name, `label` what it
is called to a screen reader. A hit region's action may instead say what a
click does by itself, `keys` to type or `cmd` to run, and `hint` what the
status line says of it. A gesture returns false to leave the event to the
view's `on_mouse`. `paw.ui.roles` lists the roles with their props; the
mixer (`runtime/lua/paw/views/mixer.lua`) is built of them.

**Buffers, windows and tabs.** A view is a buffer type with one buffer,
shown in one window at a time (see Windows, buffers and tabs in
[the terminal interface](terminal.md)). `paw.buftype` makes a type that has
a buffer for each target, any number of windows showing each:

```lua
paw.buftype("notes", {
  create = function(target, buf) return { text = "notes on " .. target } end,  -- the buffer's state
  render = function(win, canvas, ctx)        -- ctx.buf is the buffer, win.state the window's own
    canvas:text(0, 0, ctx.buf.state.text, ctx.focused and "Title" or "Normal")
  end,
  on_key = function(win, key) end,           -- keys with no mapping
  on_mouse = function(win, event) end,
  title = function(buf) return "Notes" end,
  -- For `timebind`: the beat at the left edge, columns per beat, beats shown.
  time = { get = function(win) end, set = function(win, left, zoom) end },
  claims = function(name) end,               -- whether `:vs <name>` names one of its targets by its form
  window = function() end,                   -- the window to draw with none in the tabs (a graphical frontend's)
})
paw.keymap.set("x", function() end, { view = "notes" })   -- keys of its windows
```

`:vs notes://verse` then shows buffer `notes://verse`. `paw.buf`: `list()`,
`get(name)`, `create(type, target)`, `delete(name)`, `current()`, `of(win)`.
`paw.win`: `current()`, `list()` (the tab's windows on screen, each with
`id`, `view`, `opts`, `state`), `split({ vertical, view })`, `close(win)`,
`only()`, `show(win, name)`, `enter(win)`, `resize(win, "height" or "width",
n, relative)`, `equalize()`, `maximize()`, `option(win, name, value)`.
`paw.tab`: `list()`, `current()`, `new(name, buffer)`, `go(i)`, `close(i)`.
`paw.layout.capture()` and `paw.layout.restore(data)` give and take the tabs
and windows as plain data; `paw.layouts.name = {...}` names a layout for
`:layout name`. Events: `win.enter`, `win.leave`, `win.resized` (`{ win }`),
`buf.enter`, `buf.leave` (`{ buf, name }`), `tab.enter` (`{ tab }`), and
`view.focused` as before. A view keeps a window of its own size and
time with `view:time_axis()` and `view:set_time_axis(left, zoom)`, as the
arrange view and the piano roll do; a window that follows another is drawn
with `ctx.follower`.

**Text buffers.** `paw.textbuf.kind` adds a listing edited as text, as
`paw://tracks` is (see Lists edited as text in [the terminal
interface](terminal.md)). The kind reads the project into items, writes
each as cells, reads a line back into fields, and turns what changed into a
plan; the text core does the editing, the hidden ids, the diff, the float
that shows the plan and the one undo step it is applied as.

```lua
paw.textbuf.kind("clips", {
  pattern = "^paw://track/(%d+)/clips$",   -- the names it takes; captures are ctx.args
  title = function(ctx) return "Clips of track " .. ctx.args[1] end,
  read = function(ctx)                      -- one item a line, each with an id
    local out = {}
    for i, clip in ipairs(paw.api.clip_list(paw.api.track_list()[tonumber(ctx.args[1])])) do
      out[i] = { id = clip.id, clip = clip }
    end
    return out
  end,
  format = function(item)                   -- the cells, laid out in columns two spaces apart
    return { paw.textbuf.quote(item.clip.name), "at " .. item.clip.start }
  end,
  parse = function(text)                    -- the fields of a line, or nil and what is wrong
    local cells = paw.textbuf.cells(text)
    local at = cells[2] and tonumber(cells[2].text:match("^at (%S+)$"))
    if not at then return nil, "a clip is a name and `at` a beat" end
    return { name = paw.textbuf.unquote(cells[1].text), start = at }
  end,
  plan = function(changes, ctx)             -- steps: { text, run(state) }, or an error
    local steps = {}
    for _, e in ipairs(changes.changed) do
      steps[#steps + 1] = { text = "move " .. e.fields.name .. " to " .. e.fields.start,
        run = function() paw.api.clip_set(e.id, "start", e.fields.start) end }
    end
    for _, d in ipairs(changes.deleted) do
      steps[#steps + 1] = { text = "delete " .. d.base.name, run = function() paw.api.clip_remove(d.id) end }
    end
    return steps
  end,
  keywords = { at = true },                 -- words drawn dim ahead of a value; `if` skips them
  open = function(ctx, line, text) end,     -- Enter on a line
  parent = function(ctx) return "paw://tracks" end,  -- `-`
})
```

`:e paw://track/1/clips` then lists them. `changes` holds `changed` (each
with `id`, `fields`, `base`, the fields the line was read as, and `keys`,
those that differ), `deleted` (`id`, `base`), `copied` (`copy_of`, `fields`),
`added` (`fields`), `lines` (every line that reads, in order, with `place`)
and `moves` (the lines that moved, with `from` and `place`). A step's `run`
gets a table it shares with the other steps (`state.made[line]` holds what
an earlier step made for a line); `quiet = true` keeps a step off the list
shown. Plans are checked before anything runs: an error raised in `plan`
stops the write with its message. If a step fails anyway, what the steps
before it did is undone (a step that changes something outside the project,
as the file manager's do, puts a function that takes it back on
`state.undo`, and those run, last first). `paw.textbuf.open(name, opts)` shows a buffer
(`here`, `vertical`, `window`), `paw.textbuf.buf()` is the current one, and
its `state.text.lines` its lines (`{ text, id }`). The file manager is such a
kind (`paw/views/files.lua`): `paw.files.open(folder, { tree = true })`,
`paw.files.sound_info(path)`; `paw.api.fs_stat`, `fs_sound`, `fs_move`,
`fs_copy`, `fs_trash` and the rest of the `fs_` functions are what it is
made from.

**The status line.** `paw.statusline.setup` and `paw.statusline.component`
change and extend the line, a winbar and the tab line (see The status line
in [Configuration](configuration.md#the-status-line)).

**Help.** An extension ships help by having it: its `README.md`, and any
`doc/*.md` beside it, are pages of `:help` (see Help in [the terminal
interface](terminal.md)), whether it is loaded or not. The page's title is
tagged with the extension's name (`doc/more.md` with `name-more`), each
heading with the name and the heading's words (`## Keys` in notation's
README is `notation-keys`), and each key, command (`:name.open`), option and
Lua name written as code where it is described: in a table's first column
or at the start of a list item. `<!-- tags: name-popovers name-hover -->`
on a line of its own names the place it stands with more tags, out of
sight on GitHub. Any other Markdown file is added with
`paw.help.add(path, { tag, ext, dir })`; `paw.help.open(topic)`,
`paw.help.find(topic, limit)` (the tags, best first),
`paw.help.lookup(topic)`, `paw.help.grep(words)` and `paw.help.index()`
(every page and tag) are what `:help` and `:helpgrep` use, and a view's
`help` field names its topic for the bottom line. `paw.markdown.parse(text)`
and `paw.markdown.render(blocks, { width })` make Markdown into lines of
text with their styles, links and code.

A text buffer's kind may also set `readonly` (what to say when a change is
tried: the text then cannot be changed, as help's), `gutter = false` (no
line numbers), `static` (not read again when the project changes) and
`paint(canvas, x, y, text, kind, width, row, buf)` to draw a line itself.

A view's `on_mouse` gets the terminal's pointer in the view's own cells:
`kind` (`down`, `up`, `drag`, `move`, `scroll_up`, `scroll_down`,
`scroll_left`, `scroll_right`), `button`, `x`, `y`, `mods` (any of `C`, `A`,
`S`), `double` on the second press of a double click, and where the view is
(`view_x`, `view_y`, `w`, `h`). `paw.mouse.grab(event, { drag = fn, up = fn })`
on a press keeps the drags and the release for the view wherever the
pointer goes, with `dx`, `dy` from the press; `paw.mouse.hint(text)` says
on the status line what is under the pointer. See `runtime/lua/paw/mouse.lua`.

**Curves.** `paw.curves` reads and writes every curve alike by its
address (`paw://lane/9`, `paw://track/3/device/5/param/cutoff`,
`paw://clip/7/control/cc/74`, `paw://clip/7/control/bend#key=60`,
`paw://tempo`), as points `{ beat, value, shape, tension }` in project
beats; the curve editor (see [the terminal interface](terminal.md)) is a
buffer type named `curve` built on it.

```lua
local c = paw.curves.target("paw://lane/9")    -- nil and why for anything else
c.points()   c.write(points)   c.format(-6)     -- "-6.0 dB"
c.lo, c.hi, c.min, c.max, c.step, c.has("smooth")
paw.curves.thin(points, 0.01, c.frac)   paw.curves.smooth(points, 2)   paw.curves.quantize(points, 0.25)
paw.curves.generate("sine", 0, 8, { rate = 1, depth = 0.5, unfrac = c.unfrac })
paw.curves.editor.open("paw://tempo", { vertical = true })
```

An extension makes a curve of its own of an address with
`paw.curves.provide(name, fn)`: `fn(uri, parts)` returns a target with
the fields above (`points`, `write`, `name`, `format`, `lo`, `hi`, ...),
or nil to leave the address to the others. extensions/articulations draws
several controllers as one this way
(`paw://clip/7/control/cc/1#linked=dynamics`).

**Completion.** `paw.complete` shows suggestions as ghost notes in the piano
roll, from sources that extensions register; see "Writing a source" in
[harmony.md](harmony.md) for the context and the items.

```lua
paw.complete.register({ name = "mine", priority = 10, views = { "pianoroll" }, auto = true,
  complete = function(ctx, done) done({ { label = "a fifth up", notes = { { pitch = ctx.pitch + 7, start = ctx.at, length = 1 } } } }) end })
paw.complete.request("manual")    paw.complete.current()    -- { items, index, item, clip } or nil
paw.complete.select(1)            paw.complete.select(3, true)   paw.complete.accept()   paw.complete.accept(true)  -- next notes only
paw.complete.dismiss()            paw.complete.audition()   paw.complete.unregister("mine")
paw.complete.show(items, { keys = false })   -- ghost notes for a preview, from any module
paw.on("complete.changed", function(e) end)  -- e.shown
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
local roll = paw.ui.views.pianoroll
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
paw.ui.keybar.set("pianoroll.lint", "n", { { "<C-y>", "fix" } })     -- the key line while the scope is on
```

A fifth argument, `{ lane, title, keys }`, adds more for a clip the layer
knows: `lane(p)` draws on the velocity lane (`p.lane`, `p.vel` rows),
`title(clip)` and `keys(clip)` return what the roll's title says of the clip
and a line on what its keys do to it.

A chip's `act` names a `paw.frontend.act` function, called with the clip and
`arg`. A key scope that maps `<Esc>` gets it before insert or visual mode is
left. A failing layer is skipped, and the others are drawn.

An instrument whose keys mean more than pitches (keyswitches, a playable
range) says so with four more hooks, each by name, nil taking one away:

```lua
roll.rows("mine", function(pitch, track)       -- the keyboard edge and the row's shade
  if pitch < 55 then return { shade = "RollOutside" } end
  if pitch == 24 then return { label = "sus", style = "PianoC" } end
end)
roll.band("mine", 10, {                         -- a row of its own above the ruler
  title = "art", active = function(clip) return true end,
  paint = function(buf, b) buf:text(b.x(0), 0, "│sus") end,   -- b.x(beat), b.from, b.to, b.width, b.clip
})
roll.describer("mine", function(note, part) return { "  played as  sustain" } end)   -- lines K adds for a note
roll.entering("mine", function(note, clip) note.velocity = 90 end)   -- a note the keys, insert mode or a click enter
```

extensions/articulations uses all four.

**Other.** `paw.defer(fn, ms)`, `paw.every(ms, fn)`, `paw.cancel(handle)`;
`paw.state.key = value` survives `:reload`; `project.meta` and `track.meta` are
saved with the project, for extension data; `paw.music.pitch("F#3")`,
`paw.music.degree("A4", "minor_pentatonic", 3)`; `paw.time.format(beats)`;
`paw.harmony` is the chords and key that sound when (`paw.harmony.at(8)`,
`.next(8)`, `.key(8)`, providers with `.provide`), and `paw.snippet` writes
named music from them (`paw.snippet.add`, `.expand("dominant")`); both in
[Harmony, completion and snippets](harmony.md).
`:3snippet arp`: a number before a command's name is its count.
`paw.cursor` is the edit cursor; `paw.inspect(value)`; `paw.device_types()`
lists every device kind with its format and vendor. Notes may carry a `meta`
table too (`{ pitch = 60, start = 0, meta = { lyric = "la" } }`), which stays
with the note through edits. `paw.render` emits `render.before` and runs its
handlers before it starts.

**Helper programs.** An extension can run a program of its own and talk to it
over a Unix socket, in plain bytes: `paw.api.proc_spawn(argv, { env, cwd, log })`,
`proc_status(id)`, `proc_stop(id)` (asks it to finish, as Ctrl-C would, and
leaves it the time to), `proc_kill(id)`; `sock_listen(path)`, `sock_connect(path)`,
`sock_accept(id)`, `sock_read(id)` (`""` when nothing has arrived, nil once
closed), `sock_write(id, bytes)`, `sock_close(id)`. A device that takes data
from scripts answers `paw.api.device_call(device, method, bytes)`; a device
written in Lua answers with its `dev.call` (see
[Writing a device in Lua](devices.md#writing-a-device-in-lua)).
`paw.api.device_post(kind, topic, bytes)` gives data to every device of a
kind at once: those there now, and every one made later, an offline
render's own among them, before its first block. `paw.track_kinds`
defines kinds of track, and `paw.api.device_alias(old, new)` keeps a
renamed device kind working: see
[Everything an extension can own](extensions.md#everything-an-extension-can-own).
A helper
is asked to finish when the program ends, however it ends. Started with
`{ pipe = true }`, a program is talked to over its standard input and
output instead (its errors still go to `log`): `proc_write(id, bytes)`,
`proc_read(id)` (`""` when nothing is waiting, nil once it closed its
output), `proc_close_input(id)`; a `proc.output` event (`{ id }`) says when
there is something to read, so nothing polls.

**Addresses.** `paw.address` names everything with a URI built from ids:

| URI | What |
| --- | --- |
| `paw://project` | the project |
| `paw://track/12` | a track; `paw://track/0` is the master |
| `paw://track/12/device/3` | a device on it |
| `paw://track/12/device/3/param/cutoff` | one of the device's parameters |
| `paw://track/12/send/5` | its send to track 5 |
| `paw://clip/7` | a clip |
| `paw://clip/7/note/41` | a note, by its own id (`note.id`), which it keeps through every edit |
| `paw://clip/7/control/cc/74` | a clip's moves of one controller |
| `paw://lane/9` | an automation lane |
| `paw://tempo`, `paw://marker/5` | the tempo map, a marker |
| `paw://render/<path, %-encoded>` | a rendered file |
| `paw://<kind>/...` | a kind an extension adds with `paw.address.scheme(kind, { resolve, children, parent, edit })` |

`of(object)`, `resolve(uri)` (what `paw.api` has of it; a note says its
`place`), `parent(uri)`, `children(uri)`, `within(uri, ancestor)`,
`track_of(uri)`, `matches(pattern, uri)` (`*` one level, `**` any),
constructors (`track(id)`, `device(id)`, `param(device, key)`, `clip(id)`,
`note(clip, id)`, `render(path)`, ...), `renders` (what was rendered, by
path), and `edit(changes, label)`: a workspace edit, each change
`{ uri, set = { ... } }`, `{ uri, insert = { ... } }` or `{ uri, delete = true }`,
all checked first and made as one undo step (nil and why when not).
`address.changed { uris, revision }` follows every edit.

**Diagnostics, labels and language servers.** `paw.diagnostic` is
`vim.diagnostic` over locations (`{ uri, selector }`, selector
`{ time, notes, pitch, seconds, value }`): `set(namespace, document, list)`
with each `{ location, severity, message, rule, source, fixes }` (`severity`
1 to 4, or "error", "warning", "info", "hint"; a fix is
`{ title, edit = { changes } }` or `{ title, apply = fn }`; a clip as the
document with `{ notes = { places }, at, length, fixes = { { title, edits } } }`
is the older form), `get(target, { namespace, severity, note, kind,
document })` (target a clip id or an address), `count`, `worst(uri)`,
`kind(d)`, `about(d, uri)`, `where(d)`, `reset(namespace, document)`,
`config({ virtual_text, signs, underline, severity_sort })`,
`actions(target, place)`, `apply(d, fix)`, `jump(dir)`, `list()`,
`setqflist({ target, severity, title, open })` and `setloclist(...)`; event
`diagnostic.changed`.

**The quickfix list.** `paw.qf` is Neovim's quickfix and location lists,
over addresses. An entry is `{ address, selector, text, level, source,
fix }`: `address` a `paw://` address (or a location), `level` "error",
"warning", "info", "hint" or none, `fix` `{ title, edit = { changes } }`,
`{ title, apply = function(entry) end }` or a command line run with the
cursor on the entry. `set(entries, { title, win, current })` puts a list in
the history (ten are kept) and makes it current; a list of the same title
is replaced where it is. `win` (a window's number, or true for the current
window) makes it that window's location list. `feed(source, entries)`
replaces what a source says in the Problems list, the one the program
keeps; `source(name, fn)` with `changed(name)` asks `fn` for them only
when the list is next looked at. `current(stack)`, `stack()`,
`loc_stack(win)`, `fed(source)`, `count(list)`, `jump(n)`, `step(n)`,
`first()`, `last()`, `older(n)`, `newer(n)`, `go(entry)`, `where(entry)`,
`cdo(line, { per_track })`, `fix(entries)`, `diagnostics(opts)`,
`open({ loc, height })`, `close(loc)`. A command run by `:cdo` gets the
entry's address as `ctx.target` and its location as `ctx.location`. Event
`qf.changed { title }`; the program also hears `plugins.scanned { notes,
name }`, what a plugin scan could not use.

```lua
paw.qf.feed("tuning", { { address = "paw://clip/4", text = "out of tune", level = "warning",
  fix = { title = "Tune it", apply = function(e) ... end } } })
paw.qf.set({ { address = paw.address.track(3), text = "too quiet" } }, { title = "Levels" })
``` `paw.annotation` keeps labels the same way:
`set(namespace, document, { { location, label, kind } })`, `get(uri)`,
`reset`. `paw.lsp` is `vim.lsp`: `config(name, { cmd | server, kind,
framing, adapter, attach = { subjects, where }, settings, init_options,
restart, timeout_ms, accepts, input, diagnostic })`, `enable(name, on)`,
`clients()`, `restart(name)`, `stop(name)`, `request(name, method, params,
function(err, result) end)`, `notify(name, method, params)`,
`paw.lsp.handlers[method] = function(client, params) end`,
`subject(name, { targets, build, key, depends, language })`,
`adapter(name, spec)`, `hover_at(location, cb)`, `actions_at(location, cb)`,
`show_hover()`, `code_actions()`, `hover(clip, pitch, beat, cb)`,
`complete(ctx, done)`, `attach(name, address)` to keep a subject open,
`settle()` for scripts; events `lsp.status`, `lsp.analysis`. See
[Language servers and diagnostics](lsp.md).

**Searching.** `paw.query(q)` finds nodes of the project's tree by a
query (`"clip[name~=pizz] > note[pitch>=C5]"`, or a table of steps) and
`paw.query.select(q)` chooses them; `paw.query.field(kind, name, get)` adds
a field. `paw.grep.search(pattern, { mode, fields })` finds the project's
text, and `paw.grep.source(name, function(add) end)` adds text to it.
`paw.regex.compile(text)` makes a regular expression of the common kind
(`re:find(s)`). Each is in [the terminal interface](terminal.md),
"Structural queries" and "Searching the project's text".

**Layers and locators.** What modules draw over a view goes in layers:
`paw.ui.views.pianoroll.layer(name, order, paint)` draws over the roll in
order (below 20 under the clip's notes, above them over them; diagnostics
are 30), `paint(p)` getting the roll's and the ruler's cells, the clip,
`p.x(beat)` and `p.row(pitch)`; `paw.ui.views.arrange.layers[name] =
function(view, layer)` draws on the timeline and its ruler;
`paw.ui.layer(view, part, name, order, paint)` draws on a part of a view
where it calls `paw.ui.paint(view, part, ctx)`: the arrange view's
`header` and `clip`, the mixer's `strip` and `strip_foot`, the device
panel's `device` and `param`. `paw.ui.locator(view, { at, position, place,
go })` says how a view places locations: what is under its cursor, where
its cursor is, where a location is in it, and how to go there;
`paw.ui.location()` and `paw.ui.go(location)` use them.
`paw.json.encode(value, pretty)` and `paw.json.decode(text)` are for what an
extension keeps in files of its own.

Underneath, `paw.api` is a flat set of functions over plain data
(`paw.api.track_set(id, "volume", -6)`). The objects above are a thin Lua layer
over it in [objects.lua](../runtime/lua/paw/objects.lua).

## Scripts and other programs

`paw -l script.lua [args]` runs a script with no UI and exits, which makes the
paw usable as a batch tool. A running instance listens on a Unix socket:

```sh
paw ctl eval 'paw.transport.position'
paw ctl cmd track.add Bass device=synth
paw ctl track_set 3 volume -6                 # any paw.api function
paw ctl keys 'ggm'
paw ctl eval 'paw.api.ui_snapshot(100, 30)'   # the screen as text
```

One JSON object per line: `{"id":1,"method":"eval","params":["..."]}`.
A connection can also be sent things: events it subscribed to, the state
a frontend draws (pushed when it changes, in parts), and the terminal
UI's screen. [docs/protocol.md](protocol.md) is the whole protocol.

**Driving paw from an agent.** An agent with a shell (Claude Code, pi, a
script of your own) has the best tools already: `paw ctl --json` and Lua.
`--json` makes every answer one line, `{"ok": true, "result": ...}` or
`{"ok": false, "error": "..."}` with exit status 1, so nothing needs parsing
from prose:

```sh
paw ctl --json eval 'return paw.api.project_get()'
paw ctl --json eval 'return paw.query("clip[name~=riff] > note[pitch>=c5]")'
paw ctl --json track_add '{"name": "Bass"}'     # any paw.api function, JSON arguments
```

A good order of work: read the state (`project_get`, `track_list`,
`clip_notes`: notes carry ids, which stay with them through every edit);
change it in Lua, one `eval` per step of the work (an `eval` is one undo
step, `paw.api.undo_label("agent: verse drums")` names it); `paw.render` and
`paw.api.measure` to check by numbers (loudness, true peak, clipping, level per
track) in place of listening; `paw.markers` for sections; `paw.harmony.key()`
and `paw.harmony.step(key, pitch, n)` to move notes along the key. The
reference for all of it is `paw.help` (`:help`), this manual, and the
doc comments above each function: `paw-mcp`'s resources
(`paw://reference/api`, `paw://reference/lua/<module>`) print them.

An assistant without a shell (a chat application) uses `paw-mcp`, a Model
Context Protocol server that offers the same work as typed tools: results as
JSON, per-note edits by id, markers, render options, `diagnose`, `batch`
(several changes as one named undo step), and the manual and the API
reference as resources. See [crates/paw-mcp/README.md](../crates/paw-mcp/README.md).

**An instance on another machine.** `paw attach` makes the terminal it
runs in a terminal of an instance that is already running, beside the
instance's own terminal if it has one (`paw --headless` has none), with a
seat of its own: its own cursor, mode, selection and keys, in the one
project. `:detach` leaves and the instance runs on.
`paw ctl`, `paw attach` and `paw-gui` all reach an instance three ways:

```sh
paw attach                                   # this machine's socket
paw attach --socket /tmp/studio.sock         # another socket, such as one carried by SSH
paw attach --connect studio:7700 --token-file studio.token   # over the network
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
paw.seats.keep("mymod",
  function() return active, shown end,              -- what there is now
  function(a, s) active, shown = a, s end,          -- put another seat's back
  function() return nil, {} end)                    -- what a new seat starts with

-- Fields of a table (a view's): the names, and what a new seat starts with.
paw.seats.fields("mymod.view", view, { "scroll", "hover", "drag" }, { scroll = 0 })
```

Code that reads them needs no change: when another seat's turn comes the
values are swapped in, and with one seat nothing moves. Keep in a seat only
what is about viewing; what is about the project (its notes, the shown
lanes that are saved with it, diagnostics of the project itself) stays
shared. A table you keep is swapped whole, so a new seat must get a new
one (`function() return {} end`, never a table made once outside it).
Timers run in the seat that started them; `paw.seats.current` says whose
turn it is, and `paw.seats.within(id, fn, ...)` runs something in another
seat. See runtime/lua/paw/seats.lua.

`paw doctor` is a script of its own kind: it runs the checks of
[extensions/doctor](../extensions/doctor) that need nobody, with the sound device
open (unlike other scripts, which get the null backend unless told), and prints
the report. It takes the program's audio options, `--seconds`, `--plugin` and
`--only`, and finds the extension in the source tree beside the binary or in
`$PAW_HOME`.
