-- A note's MIDI 2.0 attribute (an articulation) from the model to what
-- plays it, the track's attr_map that turns it into keyswitches for an
-- instrument that does not take it, plugins an extension adds, and the
-- names a plugin gives its keys. Loaded by tests/suite.lua with its helpers.
local T = ...
local test, eq, near, fails, fresh, render = T.test, T.eq, T.near, T.fails, T.fresh, T.render
local channel_peaks = T.channel_peaks
local api = daw.api

local PIZZ = { type = 0x11, data = 0xA000 }

local function same(a, b, what) eq(daw.inspect(a), daw.inspect(b), what) end

local dirs = 0

--- A Lua device from `text`, in a directory of its own.
local function lua_device(name, text)
  dirs = dirs + 1
  local dir = T.scratch .. "/attr-dev" .. dirs
  os.execute("mkdir -p '" .. dir .. "'")
  T.write_file(dir .. "/" .. name .. ".lua", text)
  daw.luadev.add_dir(dir)
  return "lua:" .. name
end

-- An instrument that shows what it is given: while a note sounds, the
-- left side is its attribute's type / 256 and the right its subclass / 16.
local SHOWS_ATTR = [[
local dsp = require("daw.dsp")
local dev = dsp.device { category = "instrument" }
local l, r = 0, 0
function dev.process(b)
  for i = 0, b.nevents - 1 do
    local e = b.events[i]
    if e.type == dsp.NOTE_ON then
      local a = dsp.attr(e)
      l, r = a and a.type / 256 or 0, a and math.floor(a.data / 4096) / 16 or 0
    elseif e.type == dsp.NOTE_OFF then
      l, r = 0, 0
    end
  end
  for i = 0, b.frames - 1 do b.left[i], b.right[i] = l, r end
end
return dev
]]

-- A keyswitched instrument as SFZ's `sw_last` has it: a key below 36
-- chooses what the notes after it play. While a note sounds the left side
-- is the key chosen when it started / 100; the right is how many
-- keyswitches it has been given / 100.
local KEYSWITCHED = [[
local dsp = require("daw.dsp")
local dev = dsp.device { category = "instrument" }
local chosen, playing, switches = 0, 0, 0
function dev.process(b)
  -- To the frame, so that where a note starts can be measured.
  local at = 0
  local function fill(to)
    for i = at, to - 1 do b.left[i], b.right[i] = playing / 100, switches / 100 end
    at = math.max(at, to)
  end
  for i = 0, b.nevents - 1 do
    local e = b.events[i]
    fill(e.frame)
    if e.type == dsp.NOTE_ON and e.key < 36 then
      chosen, switches = e.key, switches + 1
    elseif e.type == dsp.NOTE_ON then
      playing = chosen
    elseif e.type == dsp.NOTE_OFF and e.key >= 36 then
      playing = 0
    end
  end
  fill(b.frames)
end
return dev
]]

test("a note's attribute survives edits, undo, copies, pastes and a save and load", function()
  fresh()
  local t = daw.add_track({ name = "Strings" })
  local clip = t:add_clip({ start = 0, length = 4, notes = { { pitch = "C4", start = 0, length = 1 } } })
  local at = clip:add_note({ pitch = "E4", start = 1, length = 1, attr = PIZZ })
  same(clip:notes()[at].attr, PIZZ, "added with it")
  eq(clip:notes()[1].attr, nil, "a note with none has none")
  api.undo_checkpoint()
  clip:set_note(at, { length = 2 })
  same(clip:notes()[at].attr, PIZZ, "a change that leaves it out keeps it")
  api.undo_checkpoint()
  clip:set_note(at, { attr = daw.attr.m2("10.2") })
  eq(daw.attr.m2(clip:notes()[at].attr), "10.2", "changed")
  api.undo_checkpoint()
  daw.undo()
  same(clip:notes()[at].attr, PIZZ, "undone")
  daw.redo()
  eq(daw.attr.m2(clip:notes()[at].attr), "10.2", "redone")
  clip:set_note(at, { attr = false })
  eq(clip:notes()[at].attr, nil, "taken away with false")
  clip:set_note(at, { attr = PIZZ })
  fails(function() clip:add_note({ pitch = 60, attr = { type = 300 } }) end, "attribute", "a type past 255")
  fails(function() clip:set_note(at, { attr = { data = 1 } }) end, "attribute", "no type")
  -- Through the workspace edits of addresses.
  local _, place = daw.address.find_note(clip.id, clip:notes()[at].id)
  eq(place, at, "the note has an address")
  assert(daw.address.edit({ { uri = daw.address.note(clip.id, clip:notes()[at].id), set = { attr = daw.attr.m2("11.5") } } }))
  eq(daw.attr.m2(clip:notes()[at].attr), "11.5", "set by its address")
  clip:set_note(at, { attr = PIZZ })

  -- Yanked and put in the roll, and copied with the clip.
  local value = daw.edit.roll.yank(clip, { kind = "char", c0 = 0, c1 = 4, r0 = 0, r1 = 127 })
  daw.edit.roll.paste(clip, value, 0, 4)
  same(clip:notes()[#clip:notes()].attr, PIZZ, "pasted with it")
  same(clip:duplicate():notes()[2].attr, PIZZ, "a copy of the clip keeps it")

  local path = T.scratch .. "/attr.json"
  daw.project.save(path)
  daw.project.load(path)
  local back = daw.track("Strings"):clips()[1]:notes()
  same(back[2].attr, PIZZ, "saved and loaded")
  eq(back[1].attr, nil, "a note saved with none loads with none")
end)

test("daw.attr names the articulations of M2-123 and reads their fields", function()
  same(daw.attr.m2("11.A"), PIZZ, "pizzicato")
  eq(daw.attr.m2(PIZZ), "11.A", "and back")
  same(daw.attr.m2("10.23"), { type = 0x10, data = 0x2300 }, "legato, its variation 3")
  same(daw.attr.m2("10.2.3"), { type = 0x10, data = 0x2300 }, "written with a dot too")
  eq(daw.attr.m2({ type = 0x10, data = 0x2300 }), "10.23", "and back")
  local p = daw.attr.parts(daw.attr.m2("11.A", { direction = "up", string = 4, reset = true }))
  eq(string.format("%X %d %d %s %d", p.subclass, p.variation, p.direction, tostring(p.reset), p.string), "A 0 2 true 4",
    "the fields of Figure 1")
  local said = daw.attr.describe(PIZZ)
  eq(said.tag .. " | " .. said.text .. " | " .. said.class, "pz | Pizzicato (11.A) | Staccatos and shorts", "described")
  eq(daw.attr.describe({ type = 0x1B, data = 0x3000 }).code, "1B.3", "a library's own")
  eq(daw.attr.describe({ type = 3, data = 512 * 2 }).name, "pitch 2.00", "a pitch in 7.9")
  eq(daw.attr.describe({ type = 2, data = 5 }).text, "attr 0x02 0x0005", "any other type")
  eq(daw.attr.describe(nil), nil, "none")
  eq(daw.attr.m2({ type = 3, data = 0 }), nil, "a pitch is no articulation")
  fails(function() daw.attr.m2("21.0") end, "code", "not a classification")
end)

test("a MIDI file keeps a note's attribute in an event other programs pass over", function()
  fresh()
  local t = daw.add_track({ name = "Violin" })
  t:add_clip({ start = 0, length = 4, notes = {
    { pitch = "G4", start = 0, length = 1, attr = PIZZ }, { pitch = "A4", start = 1, length = 1 },
  } })
  local path = T.scratch .. "/attr.mid"
  daw.midifile.export(path)
  local file = assert(daw.midifile.read(path))
  local notes = file.tracks[2].notes
  same(notes[1].attr, PIZZ, "read back from the file")
  eq(notes[2].attr, nil, "only on its note")
  eq(next(file.skipped), nil, "nothing passed over")
  fresh()
  daw.midifile.import(path, { start = 0 })
  same(daw.tracks()[1]:clips()[1]:notes()[1].attr, PIZZ, "imported onto the note")
end)

test("a recorded MIDI 2.0 note-on keeps its attribute", function()
  fresh()
  api.engine_restart({ backend = "null" })
  local keys = daw.add_track({ name = "keys" })
  keys.armed = true
  daw.flush()
  daw.transport.record_offset = 0
  daw.transport.record()
  api.sleep(150)
  -- Note on, channel 1, middle C, velocity 0xC000, type 0x11, data 0xA000.
  eq(daw.midi.inject_ump({ 0x40903c11, 0xc000a000 }), true, "a MIDI 2.0 note-on")
  api.sleep(150)
  daw.midi.inject_ump({ 0x40803c00, 0 })
  api.sleep(50)
  daw.transport.stop()
  local notes = keys:clips()[1]:notes()
  same(notes[1].attr, PIZZ, "on the note recorded")
end)

test("a Lua device is given each note's attribute", function()
  fresh()
  local kind = lua_device("shows_attr", SHOWS_ATTR)
  daw.project.tempo = 120
  local t = daw.add_track({ name = "shows" })
  t:add_device(kind)
  t:add_clip({ start = 0, length = 4, notes = {
    { pitch = "C4", start = 0, length = 1, attr = PIZZ }, { pitch = "D4", start = 2, length = 1 },
  } })
  local info = render({ tail = 0, bits = 16, ["end"] = 4 })
  local l, r = channel_peaks(info, 0.1, 0.4)
  near(l, 0x11 / 256, 2e-3, "its type")
  near(r, 0xA / 16, 2e-3, "its subclass")
  l = channel_peaks(info, 1.1, 1.4)
  near(l, 0, 1e-4, "a note with none has none")
end)

--- A track playing the keyswitched instrument a clip of notes with
--- articulations, its attribute map set to `map`.
local function keyswitched(map)
  fresh()
  local kind = lua_device("keyswitched", KEYSWITCHED)
  daw.project.tempo = 120
  local t = daw.add_track({ name = "Violins" })
  t:add_device(kind)
  t:add_clip({ start = 0, length = 8, notes = {
    { pitch = "C4", start = 0, length = 1 },
    { pitch = "D4", start = 1, length = 1, attr = daw.attr.m2("11.0") },
    { pitch = "E4", start = 2, length = 1, attr = daw.attr.m2("11.0") },
    -- Staccatissimo is not in the map: staccato (11.0) plays.
    { pitch = "F4", start = 3, length = 1, attr = daw.attr.m2("11.4") },
    { pitch = "G4", start = 4, length = 1, attr = PIZZ },
  } })
  t.attr_map = map
  return t
end

local MAP = { default = { out = "ks=C1" }, arts = { ["11.0"] = { out = "ks=D1" }, ["11.A"] = { out = "ks=E1" } } }

test("an attribute map sends a keyswitch ahead of its note, only when it changes", function()
  local t = keyswitched(MAP)
  eq(t.attr_map.arts["11.0"].out, "ks=D1", "the map reads back")
  local info = render({ tail = 0, bits = 16, ["end"] = 6 })
  -- Each note plays what its keyswitch chose, so the keyswitch came first,
  -- on the note's own frame.
  for i, key in ipairs({ 24, 26, 26, 26, 28 }) do
    local l = channel_peaks(info, (i - 1) * 0.5 + 0.05, (i - 1) * 0.5 + 0.4)
    near(l, key / 100, 2e-3, "note " .. i .. " plays keyswitch " .. key)
  end
  local _, r = channel_peaks(info, 2.6, 2.9)
  near(r, 3 / 100, 2e-3, "three keyswitches for three changes")
  t.attr_map = daw.util.merge(MAP, { send = "every" })
  _, r = channel_peaks(render({ tail = 0, bits = 16, ["end"] = 6 }), 2.6, 2.9)
  near(r, 5 / 100, 2e-3, "with send = every, one before every note")
  t.attr_map = nil
  eq(t.attr_map, nil, "a map taken away")
  _, r = channel_peaks(render({ tail = 0, bits = 16, ["end"] = 6 }), 2.6, 2.9)
  near(r, 0, 1e-4, "and nothing is sent")
end)

test("an attribute map's keyswitch is sent again where playback starts after it", function()
  keyswitched(MAP)
  -- From the middle of the third note: its keyswitch was sent a note
  -- before, at beat 1, and the note itself started at beat 2.
  local info = render({ tail = 0, bits = 16, start = 2.4, ["end"] = 4 })
  local l, r = channel_peaks(info, 0.01, 0.2)
  near(l, 26 / 100, 2e-3, "the note sounding plays staccato")
  near(r, 1 / 100, 2e-3, "told once, where it starts")
end)

test("the map the articulations extension writes plays: a default named by its code, variations, milliseconds", function()
  local t = keyswitched({ send = "change", chase = { 1, 11, 64 }, default = "10.0", delay = 0,
    arts = { ["10.0"] = { out = "ks=24" }, ["11.0"] = { out = "ks=D1:100", delay = 0 }, ["11.A2"] = { out = "ks=E1" } } })
  t:clips()[1]:set_note(5, { attr = daw.attr.m2("11.A2") })
  eq(daw.attr.m2(t:clips()[1]:notes()[5].attr), "11.A2", "a variation's code")
  local info = render({ tail = 0, bits = 16, ["end"] = 6 })
  for i, key in ipairs({ 24, 26, 26, 26, 28 }) do
    near(channel_peaks(info, (i - 1) * 0.5 + 0.05, (i - 1) * 0.5 + 0.4), key / 100, 2e-3, "note " .. i .. " plays " .. key)
  end
  t:clips()[1]:set_note(5, { attr = { type = 0, data = 0 } })
  eq(t:clips()[1]:notes()[5].attr, nil, "type 0 is none")
end)

test("an attribute map is checked, undone, saved and copied with its track", function()
  local t = keyswitched(MAP)
  fails(function() t.attr_map = { arts = { ["11.0"] = "ks=H9" } } end, "no such key", "a key there is not")
  fails(function() t.attr_map = { arts = { ["99.0"] = "ks=D1" } } end, "code", "a code there is not")
  fails(function() t.attr_map = { arts = { ["11.0"] = "loud" } } end, "loud", "an event there is not")
  fails(function() t.attr_map = { sned = "every" } end, "sned", "a field there is not")
  api.undo_checkpoint()
  t.attr_map = { send = "every", by_type = { [0x11] = { out = "hold=D1 cc32=40", name = "shorts" } }, chase = { 1 } }
  eq(t.attr_map.by_type["17"].name, "shorts", "a classification's entry, and what else it carries")
  api.undo_checkpoint()
  daw.undo()
  eq(t.attr_map.arts["11.A"].out, "ks=E1", "undone")
  daw.redo()
  local path = T.scratch .. "/attr-map.json"
  daw.project.save(path)
  daw.project.load(path)
  eq(daw.track("Violins").attr_map.by_type["17"].out, "hold=D1 cc32=40", "saved and loaded")
  eq(daw.track("Violins"):duplicate().attr_map ~= nil, true, "a copy of the track keeps it")
end)

--- The first time from `from` seconds on at which the left side of a
--- 16-bit render is above a tenth: where a note starts sounding.
local function onset(info, from)
  local data = T.read_file(info.path)
  local at = data:find("data", 1, true) + 8
  for i = at + math.floor(from * info.sample_rate) * 4, #data - 1, 4 do
    local lo, hi = data:byte(i, i + 1)
    local v = lo + hi * 256
    if v >= 32768 then v = v - 65536 end
    if v / 32768 > 0.1 then return (i - at) / 4 / info.sample_rate end
  end
end

-- Staccato speaks slowly in this library: its notes play a tenth of a
-- second early, its keyswitch with them, so that they sound on the beat.
local LATE = { default = { out = "ks=C1" }, arts = { ["11.0"] = { out = "ks=D1", delay = -100 } } }

--- The keyswitched instrument playing a plain note on beat 0 and a
--- staccato on beat 2, with LATE as the map.
local function delayed()
  fresh()
  local kind = lua_device("keyswitched", KEYSWITCHED)
  daw.project.tempo = 120
  local t = daw.add_track({ name = "Violins" })
  t:add_device(kind)
  t:add_clip({ start = 0, length = 4, notes = {
    { pitch = "C4", start = 0, length = 0.5 },
    { pitch = "D4", start = 2, length = 0.5, attr = daw.attr.m2("11.0") },
  } })
  t.attr_map = LATE
  return t
end

test("a delay in an attribute map plays its notes that much earlier, and the rest where they are", function()
  local t = delayed()
  eq(daw.attr.delay_of(t, daw.attr.m2("11.0")), -100, "the staccato's delay, in milliseconds")
  eq(daw.attr.delay_of(t, daw.attr.m2("11.4")), -100, "and what falls back to it")
  eq(daw.attr.delay_of(t, nil), 0, "a note with none is not moved")
  local info = render({ tail = 0, bits = 16, ["end"] = 4 })
  near(onset(info, 0), 0, 1e-3, "the plain note on its beat")
  near(onset(info, 0.5), 0.9, 2e-3, "the staccato a tenth of a second before its beat (1 s)")
  near(channel_peaks(info, 0.92, 0.98), 0.26, 2e-3, "with its keyswitch before it")
  -- At another tempo it is still a tenth of a second.
  daw.project.tempo = 60
  near(onset(render({ tail = 0, bits = 16, ["end"] = 4 }), 1), 1.9, 2e-3, "a tenth before 2 s at 60 bpm")
  daw.project.tempo = 120
  t.attr_map = daw.util.merge(LATE, { delay = 50 })
  near(onset(render({ tail = 0, bits = 16, ["end"] = 4 }), 0), 0.05, 2e-3, "the map's own delay for the rest")
  fails(function() t.attr_map = daw.util.merge(LATE, { delay = 5000 }) end, "delay", "milliseconds are checked")
end)

test("a note moved before where playback starts is started there", function()
  local t = delayed()
  -- From between where the staccato is played (0.9 s, beat 1.8) and its beat (2).
  local info = render({ tail = 0, bits = 16, start = 1.9, ["end"] = 4 })
  near(onset(info, 0), 0, 1e-3, "sounding from the start of the render")
  near(channel_peaks(info, 0.01, 0.04), 0.26, 2e-3, "as staccato")
  -- At the very start of the song.
  t:clips()[1]:set_note(1, { attr = daw.attr.m2("11.0") })
  info = render({ tail = 0, bits = 16, ["end"] = 4 })
  near(onset(info, 0), 0, 1e-3, "a note on the first beat cannot be earlier: it starts at once")
  near(channel_peaks(info, 0.01, 0.04), 0.26, 2e-3, "with its keyswitch")
end)

test("a delayed note plays as early live as it renders", function()
  local t = delayed()
  daw.flush()
  daw.transport.seek(0)
  daw.transport.play()
  -- The staccato's beat is 2; it should be heard from 1.8 on.
  local heard
  local deadline = api.now() + 10000
  while not heard and api.now() < deadline do
    local pos = daw.transport.position
    if pos > 1.2 and t:meter() > 0.2 then heard = pos end
    daw.wait(2)
  end
  daw.transport.stop()
  eq(heard ~= nil, true, "heard")
  eq(heard >= 1.75 and heard < 1.97, true, "heard before its beat, from about 1.8: " .. tostring(heard))
  -- Going round a loop, every time.
  daw.transport.loop_start, daw.transport.loop_end = 1, 3
  daw.transport.loop_enabled = true
  T.after(function() daw.transport.loop_enabled = false end)
  daw.transport.seek(1)
  daw.transport.play()
  local onsets, was = {}, false
  deadline = api.now() + 15000
  while #onsets < 3 and api.now() < deadline do
    local pos, on = daw.transport.position, t:meter() > 0.2
    -- (What the meter still shows from before is passed over.)
    if on and not was and pos > 1.5 then onsets[#onsets + 1] = pos end
    was = on
    daw.wait(2)
  end
  daw.transport.stop()
  eq(#onsets, 3, "heard three times round")
  for i, pos in ipairs(onsets) do
    eq(pos >= 1.75 and pos < 1.97, true, "round " .. i .. " before its beat: " .. tostring(pos))
  end
end)

test("a note played live with an attribute is preceded by what the map sends", function()
  local t = keyswitched(MAP)
  daw.flush()
  t:note_on("C5", 100, PIZZ)
  daw.flush()
  api.sleep(150)
  local l = t:meter()
  t:note_off("C5")
  near(l, 28 / 100, 0.02, "the pizzicato keyswitch, then the note")
end)

--- The test plugin built by `cargo test -p daw-plugins`, in a directory of
--- its own; nil when it has not been built.
local function stub_plugin()
  local built = "target/release/examples/libstub_clap.so"
  if not io.open(built) then return nil end
  local dir = T.scratch .. "/stub-plugin"
  os.execute("mkdir -p '" .. dir .. "' && cp '" .. built .. "' '" .. dir .. "/stub.clap'")
  return dir
end

local function has_kind(kind)
  for _, info in ipairs(daw.device_types()) do
    if info.kind == kind then return info end
  end
end

test("a plugin an extension ships is found once its directory is added, plays attributes and names its keys", function()
  fresh()
  local dir = stub_plugin()
  if not dir then return "skipped: `cargo test -p daw-plugins` builds the test plugin" end
  local kind = "clap:dev.paw.stub"
  eq(has_kind(kind), nil, "not found before")
  local found = daw.plugins.add_dir(dir, "stubs")
  eq(found.kinds[1], kind, "found in the directory")
  eq(has_kind(kind).from, "stubs", "listed as the extension's")
  daw.project.tempo = 120
  local t = daw.add_track({ name = "Stub" })
  t:add_device(kind)
  local clip = t:add_clip({ start = 0, length = 4, notes = {
    { pitch = "C4", start = 0, length = 1, attr = PIZZ }, { pitch = "D1", start = 2, length = 1 },
  } })
  local l, r = channel_peaks(render({ tail = 0, bits = 16, ["end"] = 2 }), 0.1, 0.4)
  near(l, 0x11 / 256, 2e-3, "the plugin took the note as MIDI 2.0, with its type")
  near(r, 0xA / 16, 2e-3, "and its data")
  eq(daw.plugins.key_names(t.id)[24], "Sustain", "the names it gives its keys")
  -- The piano roll writes them on its keys, and K says what is under the cursor.
  daw.ui.views.pianoroll:edit(clip)
  local roll = daw.ui.views.pianoroll
  roll.pitch, roll.beat, roll.top = 30, 2, 30
  local screen = table.concat(api.ui_snapshot(160, 50), "\n")
  eq(screen:find("Sus…", 1, true) ~= nil and screen:find("Sta…", 1, true) ~= nil, true, "the names on their keys")
  roll.pitch = 26
  local said = roll:describe()
  eq(said[3], "  the instrument calls this key Staccato", "K says so too")
end)

test("the piano roll writes a note's articulation on it, and K names it", function()
  fresh()
  local t = daw.add_track({ name = "Strings" })
  local clip = t:add_clip({ start = 0, length = 4, notes = { { pitch = "C4", start = 0, length = 2, attr = PIZZ } } })
  daw.ui.views.pianoroll:edit(clip)
  local roll = daw.ui.views.pianoroll
  roll.pitch, roll.beat = 60, 0
  local screen = table.concat(api.ui_snapshot(160, 50), "\n")
  eq(screen:find("pz", 1, true) ~= nil, true, "the tag on the note")
  local said = roll:describe()
  eq(said[3], "  articulation: Pizzicato (11.A)", "K")
  local _, over = roll:marks(clip.id)
  local chip
  for _, m in ipairs(over) do if m.label == "pz" then chip = m end end
  eq(chip and chip.tip, "Pizzicato (11.A)", "the window gets a chip with it")
end)

test("Ex matches and sets a note's articulation by its code", function()
  fresh()
  local t = daw.add_track({ name = "Strings" })
  local clip = t:add_clip({ start = 0, length = 4, notes = {
    { pitch = 60, start = 0, length = 1 }, { pitch = 62, start = 1, length = 1, attr = PIZZ },
  } })
  daw.cursor.set_track(t)
  daw.commands.exec("%s/attr=11.A/attr=11.0/g")
  eq(daw.attr.m2(clip:notes()[2].attr), "11.0", "the pizzicato made staccato")
  daw.commands.exec("%s/attr=none/attr=10.2/g")
  eq(daw.attr.m2(clip:notes()[1].attr), "10.2", "the note with none made legato")
  daw.commands.exec("%s/c4/attr=none/g")
  eq(clip:notes()[1].attr, nil, "and none again")
  fails(function() daw.commands.exec("%s/d4/attr=99.1/g") end, "99.1", "a code there is not")
end)
