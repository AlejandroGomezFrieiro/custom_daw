-- End-to-end tests, run with `daw --clean -l tests/suite.lua`.
-- Each test drives the public `daw` module and checks what comes out,
-- including rendered audio.
local daw = require("daw")
local api = daw.api

local tmp = os.getenv("TMPDIR") or "/tmp"
local scratch = tmp .. "/daw-test-" .. os.time() .. "-" .. math.floor(api.now() * 1000)
os.execute("mkdir -p '" .. scratch .. "'")

local tests, failed = {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function eq(got, want, what)
  if got ~= want then
    error(string.format("%s: got %s, want %s", what or "value", daw.inspect(got), daw.inspect(want)), 2)
  end
end

local function near(got, want, tolerance, what)
  if math.abs(got - want) > tolerance then
    error(string.format("%s: got %s, want %s ± %s", what or "value", got, want, tolerance), 2)
  end
end

local function fails(fn, pattern, what)
  local ok, err = pcall(fn)
  if ok then error((what or "call") .. " should have failed", 2) end
  if pattern and not tostring(err):find(pattern) then
    error(string.format("%s: error %q does not mention %q", what or "call", tostring(err), pattern), 2)
  end
end

local function fresh()
  daw.project.new()
  daw.transport.loop_enabled = false
  daw.flush()
end

local renders = 0
local function render(opts)
  renders = renders + 1
  return daw.render(scratch .. "/render" .. renders .. ".wav", opts)
end

--- A track with a synth holding one note for `beats`.
local function tone(name, beats, pitch)
  local track = daw.add_track({ name = name })
  track:add_device("synth", { attack = 0.001, release = 0.01 })
  track:add_clip({ start = 0, length = beats, notes = { { pitch = pitch or "A3", start = 0, length = beats } } })
  return track
end

--- Peak of each channel of a WAV file written by `daw.render` at 16 bits,
--- optionally only between two times in seconds.
local function channel_peaks(info, from, to)
  local file = assert(io.open(info.path, "rb"))
  local data = file:read("*a")
  file:close()
  local at = data:find("data", 1, true) + 8
  local first = at + math.floor((from or 0) * info.sample_rate) * 4
  local last = to and math.min(#data - 1, at + math.floor(to * info.sample_rate) * 4) or #data - 1
  local peaks = { 0, 0 }
  local ch = 1
  for i = first, last - 1, 2 do
    local lo, hi = data:byte(i, i + 1)
    local v = lo + hi * 256
    if v >= 32768 then v = v - 65536 end
    peaks[ch] = math.max(peaks[ch], math.abs(v) / 32768)
    ch = 3 - ch
  end
  return peaks[1], peaks[2]
end

--- Frequency of the left channel of a WAV file written by `daw.render` at 16
--- bits, between two times in seconds, from its rising zero crossings.
local function frequency(info, from, to)
  local file = assert(io.open(info.path, "rb"))
  local data = file:read("*a")
  file:close()
  local at = data:find("data", 1, true) + 8
  local first = at + math.floor(from * info.sample_rate) * 4
  local last = math.min(#data - 1, at + math.floor(to * info.sample_rate) * 4)
  local rises, before = 0, 0
  for i = first, last - 1, 4 do
    local lo, hi = data:byte(i, i + 1)
    local v = lo + hi * 256
    if v >= 32768 then v = v - 65536 end
    if before < 0 and v >= 0 then rises = rises + 1 end
    before = v
  end
  return rises / (to - from)
end

local fixtures = "tests/fixtures/"

local function read_file(path)
  local file = assert(io.open(path, "rb"))
  local data = file:read("*a")
  file:close()
  return data
end

local function write_file(path, data)
  local file = assert(io.open(path, "wb"))
  file:write(data)
  file:close()
end

-- Model ----------------------------------------------------------------------

test("tracks have properties that read back", function()
  fresh()
  local t = daw.add_track({ name = "Bass", volume = -3 })
  eq(t.name, "Bass", "name")
  eq(t.volume, -3, "volume")
  t.pan = 0.5
  t.mute = true
  eq(t.pan, 0.5, "pan")
  eq(t.mute, true, "mute")
  eq(#daw.tracks(), 1, "track count")
  eq(daw.track("Bass"), t, "lookup by name")
  eq(t.index, 1, "index")
  t.volume = 100
  eq(t.volume, 24, "volume is clamped")
end)

test("bad input is rejected with a useful message", function()
  fresh()
  local t = daw.add_track()
  fails(function() daw.add_track({ nmae = "typo" }) end, "nmae", "unknown option")
  fails(function() t:add_device("nope") end, "nope", "unknown device")
  fails(function() t:add_device("synth", { cutof = 1 }) end, "cutof", "unknown parameter")
  fails(function() t.colour = "red" end, "colour", "unknown field")
  fails(function() daw.master:remove() end, "master", "removing the master")
  fails(function() t:add_clip({ file = scratch .. "/missing.wav" }) end, "missing.wav", "missing file")
  fails(function() daw.track(999).name = "x" end, "999", "missing track")
end)

test("tracks insert at an index and move", function()
  fresh()
  local a, b = daw.add_track({ name = "a" }), daw.add_track({ name = "b" })
  local c = daw.add_track({ name = "c", index = 1 })
  eq(c.index, 1, "inserted first")
  eq(a.index, 2, "a pushed down")
  b:move(1)
  eq(b.index, 1, "moved first")
  eq(#daw.tracks(), 3, "count")
end)

test("devices keep parameters, clamp them and reorder", function()
  fresh()
  local t = daw.add_track()
  local synth = t:add_device("synth", { cutoff = 900 })
  local delay = t:add_device("delay")
  eq(synth.params.cutoff, 900, "given parameter")
  eq(synth.params.sustain, synth:info().params[4].default, "default parameter")
  synth:set("cutoff", 99999)
  eq(synth.params.cutoff, 20000, "clamped")
  eq(t:devices()[2], delay, "order")
  delay:move(1)
  eq(t:devices()[1], delay, "moved first")
  eq(t:device("synth"), synth, "lookup by kind")
  delay:remove()
  eq(#t:devices(), 1, "removed")
  eq(delay:exists(), false, "exists")
end)

test("clips hold notes, sorted, with names for pitches", function()
  fresh()
  local t = daw.add_track()
  local clip = t:add_clip({ start = 4, notes = { { pitch = "E4", start = 2 }, { pitch = "C4", start = 0 } } })
  eq(clip.length, 4, "length defaults to whole bars")
  local notes = clip:notes()
  eq(notes[1].pitch, 60, "sorted by start")
  eq(notes[2].pitch, 64, "name converted")
  eq(notes[1].velocity, 100, "default velocity")
  clip:add_note({ pitch = 67, start = 1, length = 0.5 })
  eq(#clip:notes(), 3, "note added")
  eq(clip:notes()[2].pitch, 67, "kept sorted")
  eq(t:clip_at(5), clip, "clip_at inside")
  eq(t:clip_at(8), nil, "clip_at outside")
  local copy = clip:duplicate()
  eq(copy.start, 8, "duplicate follows the original")
  eq(#copy:notes(), 3, "duplicate has the notes")
  eq(daw.project.length, 12, "project length")
end)

test("undo and redo step through edits", function()
  fresh()
  api.undo_checkpoint()
  local t = daw.add_track({ name = "one" })
  api.undo_checkpoint()
  t.name = "two"
  t:add_device("synth")
  api.undo_checkpoint()
  eq(daw.undo(), true, "undo")
  eq(t.name, "one", "rename undone")
  eq(#t:devices(), 0, "device undone with it")
  eq(daw.undo(), true, "undo again")
  eq(#daw.tracks(), 0, "track undone")
  eq(daw.redo(), true, "redo")
  eq(daw.redo(), true, "redo again")
  eq(t.name, "two", "redone")
  eq(daw.redo(), false, "nothing left to redo")
end)

test("events report what changed", function()
  fresh()
  local seen = {}
  -- (What changed, said again as addresses, is daw.address's business: tests/address.lua.)
  local handle = daw.on("*", function(payload, name)
    if name ~= "address.changed" then seen[#seen + 1] = name .. ":" .. tostring(payload.id or "") end
  end)
  local t = daw.add_track()
  local d = t:add_device("gain")
  daw.flush()
  eq(table.concat(seen, " "), string.format("track.added:%d device.added:%d changed:", t.id, d.id), "after adding")
  seen = {}
  t.volume = -3
  daw.flush()
  eq(table.concat(seen, " "), string.format("track.changed:%d changed:", t.id), "after a change")
  seen = {}
  api.undo_checkpoint()
  t.volume = -9
  daw.flush()
  seen = {}
  daw.undo()
  daw.flush()
  eq(seen[1], "track.changed:" .. t.id, "undo reports changes too")
  seen = {}
  daw.off(handle)
  t.volume = -4
  daw.flush()
  eq(#seen, 0, "no events after daw.off")

  local family = 0
  daw.on("track.*", function() family = family + 1 end)
  daw.emit("track.custom")
  daw.emit("other.custom")
  eq(family, 1, "family pattern")
end)

test("projects save and load", function()
  fresh()
  local t = daw.add_track({ name = "Keys", pan = -0.25 })
  t:add_device("synth", { wave = 2 })
  t:add_clip({ start = 2, notes = { { pitch = 72, start = 0.5, length = 0.25, velocity = 64 } } })
  daw.project.tempo = 97
  daw.project.meta = { my_extension = { answer = 42 } }
  daw.transport.loop_start, daw.transport.loop_end = 4, 12
  local path = daw.project.save(scratch .. "/song.json")
  fresh()
  eq(#daw.tracks(), 0, "new project is empty")
  daw.project.load(path)
  local loaded = daw.tracks()[1]
  eq(loaded.name, "Keys", "name")
  eq(loaded.pan, -0.25, "pan")
  eq(loaded:device("synth").params.wave, 2, "device parameter")
  local note = loaded:clips()[1]:notes()[1]
  eq(note.pitch .. "/" .. note.start .. "/" .. note.length .. "/" .. note.velocity, "72/0.5/0.25/64", "note")
  eq(daw.project.tempo, 97, "tempo")
  eq(daw.project.meta.my_extension.answer, 42, "extension data")
  eq(daw.transport.loop_end, 12, "loop")
  -- Ids handed out after loading must not collide with loaded ones.
  local another = daw.add_track()
  eq(another.id > loaded:clips()[1].id, true, "fresh ids")
end)

test("notes carry extension data through edits, undo and saving", function()
  fresh()
  local t = daw.add_track({ name = "Words" })
  local clip = t:add_clip({ start = 0, length = 4, notes = {
    { pitch = 60, start = 1, length = 1, meta = { lyric = "la", extra = { 1, 2 } } },
    { pitch = 62, start = 0, length = 1 },
  } })
  local notes = clip:notes()
  eq(notes[1].meta, nil, "a note without data has no meta")
  eq(notes[2].meta.lyric, "la", "the data is kept, and stays with its note when the list is sorted")
  api.undo_checkpoint()
  -- Changing a note the way the piano roll does keeps its data.
  notes[2].start = 2
  clip:set_notes(notes)
  eq(clip:notes()[2].meta.extra[2], 2, "kept when the note moves")
  daw.undo()
  eq(clip:notes()[2].start, 1, "undone")
  eq(clip:notes()[2].meta.lyric, "la", "and the data with it")
  local path = daw.project.save(scratch .. "/words.json")
  eq(read_file(path):find('"lyric": "la"', 1, true) ~= nil, true, "saved in the project file")
  fresh()
  daw.project.load(path)
  eq(daw.tracks()[1]:clips()[1]:notes()[2].meta.lyric, "la", "loaded")
end)

test("saving and loading keeps every number exactly", function()
  fresh()
  local t = daw.add_track({ pan = 0.123456789012345678 })
  -- Found by the fuzzer: these came back from a saved file one bit off.
  t:add_clip({ start = 1.3859882354736328, length = 3.9661864042282104,
    notes = { { pitch = 60, start = 0.15935707092285156, length = 1.9014935493469238 } } })
  local before = t:clips()[1]
  local note = before:notes()[1]
  daw.project.load(daw.project.save(scratch .. "/exact.json"))
  local after = daw.tracks()[1]:clips()[1]
  local loaded = after:notes()[1]
  eq(loaded.length, note.length, "note length")
  eq(loaded.start, note.start, "note start")
  eq(after.start, before.start, "clip start")
  eq(after.length, before.length, "clip length")
  eq(daw.tracks()[1].pan, t.pan, "pan")
end)

test("numbers that are not finite are refused, so that a save always loads", function()
  fresh()
  local nan, inf = 0 / 0, 1 / 0
  local t = daw.add_track()
  local synth = t:add_device("synth")
  fails(function() daw.add_track({ volume = nan }) end, "finite", "volume NaN")
  fails(function() daw.add_track({ pan = inf }) end, "finite", "pan infinite")
  fails(function() synth:set("cutoff", nan) end, "finite", "parameter NaN")
  fails(function() t:add_clip({ notes = { { pitch = 60, start = inf, length = 1 } } }) end, "finite", "note start")
  fails(function() t:add_clip({ notes = { { pitch = 60, start = 0, length = nan } } }) end, "length", "note length NaN")
  -- A note-off before its note-on would leave the note sounding.
  fails(function() t:add_clip({ notes = { { pitch = 60, start = 0, length = -1 } } }) end, "length", "negative length")
  fails(function() t:add_clip({ notes = { { pitch = 200, start = 0, length = 1 } } }) end, "127", "pitch 200")
  local clip = t:add_clip({ start = 0, length = 4 })
  fails(function() clip:set_notes({ { pitch = 60, start = 0, length = 0 } }) end, "length", "zero length")
  fails(function() t:add_clip({ file = "tests/fixtures/shape.wav", gain = nan }) end, "finite", "clip gain NaN")
  fails(function() t:add_clip({ file = "tests/fixtures/shape.wav", offset = -inf }) end, "offset", "clip offset")
  fails(function() api.note_on(t.id, 60, nan) end, "velocity", "live velocity NaN")
  fails(function() api.midi_inject({ type = "note_on", pitch = 60, velocity = inf }) end, "velocity", "MIDI velocity")
  daw.project.load(daw.project.save(scratch .. "/finite.json"))
  eq(#daw.tracks(), 1, "the project saved and loaded")
end)

test("note lists read and write the same through either path", function()
  fresh()
  local clip = daw.add_track():add_clip({ start = 0, length = 8 })
  local notes = { { pitch = 60, start = 0.5, length = 0.25 }, { pitch = 64, start = 0, length = 1.5, velocity = 7, extra = "ignored" } }
  api.clip_set_notes(clip.id, notes)
  local got = api.clip_notes(clip.id)
  eq(#got, 2, "count")
  eq(got[1].pitch .. "/" .. got[1].start .. "/" .. got[1].length .. "/" .. got[1].velocity, "64/0/1.5/7", "sorted, fields")
  eq(got[2].velocity, 100, "default velocity")
  eq(got[1].extra, nil, "unknown fields are not kept")
  api.clip_add_notes(clip.id, {})
  eq(#api.clip_notes(clip.id), 2, "adding nothing")
  -- Not plain note tables: the general path decides, with its own messages.
  fails(function() api.clip_set_notes(clip.id, { { pitch = "C4", start = 0, length = 1 } }) end, "u8", "a pitch name")
  fails(function() api.clip_set_notes(clip.id, { { pitch = 300, start = 0, length = 1 } }) end, "300", "pitch 300")
  fails(function() api.clip_set_notes(clip.id, { { pitch = 60, length = 1 } }) end, "start", "no start")
  fails(function() api.clip_set_notes(clip.id, { { pitch = 60.5, start = 0, length = 1 } }) end, nil, "a fractional pitch")
  fails(function() api.clip_set_notes(clip.id, "notes") end, nil, "not a table")
  api.clip_set_notes(clip.id, { [1] = { pitch = 1, start = 0, length = 1 }, x = 1 })
  eq(#api.clip_notes(clip.id), 1, "a list with another key goes through the general path")
end)

test("a device brought back by undo reads as loaded at once", function()
  fresh()
  local t = daw.add_track()
  api.undo_checkpoint()
  local synth = t:add_device("synth", { cutoff = 900 })
  api.undo_checkpoint()
  synth:remove()
  daw.flush()
  api.undo_checkpoint()
  daw.undo()
  -- No flush after the undo: found by the fuzzer.
  local view = api.device_get(synth.id)
  eq(view.missing, false, "not missing")
  eq(view.params.cutoff, 900, "its parameters")
end)

test("a refused edit leaves no undo step behind", function()
  fresh()
  local t = daw.add_track()
  api.undo_checkpoint()
  t.volume = -6
  api.undo_checkpoint()
  fails(function() api.track_set(t.id, "volume", "loud") end, "volume", "bad value")
  api.undo_checkpoint()
  daw.undo()
  eq(t.volume, 0, "one undo undoes the last edit that went through")
end)

test("a damaged project file is refused whole", function()
  fresh()
  local t = daw.add_track({ name = "kept" })
  t:add_device("synth")
  t:add_clip({ start = 0, length = 4, notes = { { pitch = 60, start = 0, length = 1 } } })
  local good = read_file(daw.project.save(scratch .. "/good.json"))
  local function load(text, pattern, what)
    write_file(scratch .. "/bad.json", text)
    fails(function() daw.project.load(scratch .. "/bad.json") end, pattern, what)
    eq(daw.tracks()[1].name, "kept", what .. ": the open project is untouched")
  end
  load(good:gsub('"tempo": 120.0', '"tempo": 0.0'), "tempo", "tempo 0, which made renders never end")
  load(good:gsub('"sig_den": 4', '"sig_den": 0'), "denominator", "time signature")
  load(good:gsub('"length": 4.0', '"length": -4.0', 1), "length", "negative clip length")
  load(good:gsub('"length": 1.0', '"length": -1.0', 1), "note", "negative note length")
  load(good:gsub('"volume": 0.0', '"volume": 1e300', 1), "volume", "volume out of range")
  local id = t.id
  -- The master track comes first in the file; the second output is the track's.
  local n = 0
  local looped = good:gsub('"output": null', function()
    n = n + 1
    if n == 2 then return '"output": ' .. id end
  end)
  load(looped, "routed", "a track routed into itself")
  local dup = good:gsub('"id": ' .. t:clips()[1].id, '"id": ' .. id, 1)
  load(dup, "twice", "two things with one id")
end)

test("levels are kept within range, so that nothing turns into infinity", function()
  fresh()
  local t = daw.add_track()
  local clip = t:add_clip({ start = 0, length = 1, file = "tests/fixtures/shape.wav", gain = 1e9 })
  eq(clip.gain, 24, "clip gain at add")
  clip.gain = -1e9
  eq(clip.gain, -120, "clip gain set")
  clip.gain = 1e9
  local bus = daw.add_track()
  api.track_set(t.id, "sends", { { target = bus.id, level = 1e9 } })
  eq(t.sends[1].level, 24, "send level")
  eq(render({ ["end"] = 1, tail = 0, bits = 32 }).nonfinite, 0, "the render is finite")
  -- Found by the fuzzer: a send level saved out of range made a file that does not load.
  daw.project.load(daw.project.save(scratch .. "/levels.json"))
  eq(#daw.tracks(), 2, "saved and loaded")
  -- Values in a file are kept within the device's range too.
  fresh()
  local g = daw.add_track()
  g:add_clip({ start = 0, length = 1, file = "tests/fixtures/shape.wav" })
  g:add_device("gain")
  local text = read_file(daw.project.save(scratch .. "/param.json")):gsub('"params": {}', '"params": { "gain": 1e300 }', 1)
  write_file(scratch .. "/param.json", text)
  daw.project.load(scratch .. "/param.json")
  local info = render({ ["end"] = 1, tail = 0, bits = 32 })
  eq(info.nonfinite, 0, "a parameter of 1e300 in a file")
  eq(info.peak > 0, true, "still sounds")
  local lane = g:automate("volume")
  lane:add(0, 0)
  text = read_file(daw.project.save(scratch .. "/lane.json")):gsub("%[%s*0%.0,%s*0%.0%s*%]", "[0.0, 1e300]", 1)
  write_file(scratch .. "/lane.json", text)
  fails(function() daw.project.load(scratch .. "/lane.json") end, "lane", "a volume point of 1e300")
end)

test("sends cannot make a loop either", function()
  fresh()
  local a, b, c = daw.add_track(), daw.add_track(), daw.add_track()
  a:send(b, -6)
  b:send(c, -6)
  fails(function() c:send(a, -6) end, "loop", "a loop through sends")
  fails(function() c.output = a end, "loop", "a loop through a send and an output")
end)

test("renders and engines refuse sizes and rates they cannot do", function()
  fresh()
  tone("t", 2)
  fails(function() render({ tail = 1e12 }) end, "WAV", "a tail no file can hold")
  fails(function() render({ ["end"] = 1e15 }) end, "WAV", "an end no file can hold")
  fails(function() render({ tail = 1 / 0 }) end, "finite", "an infinite tail")
  fails(function() render({ sample_rate = 0 }) end, "sample rate", "0 Hz")
  fails(function() render({ sample_rate = 4000000000 }) end, "sample rate", "4 GHz")
  fails(function() api.engine_restart({ backend = "null", sample_rate = 0 }) end, "sample rate", "engine at 0 Hz")
  fails(function() api.engine_restart({ backend = "null", buffer_size = 1000000000 }) end, "buffer", "a huge buffer")
  eq(render({ ["end"] = 2, tail = 0 }).peak > 0.01, true, "still renders")
end)

test("a track the engine had no room for sounds once there is room", function()
  fresh()
  local tracks = {}
  for i = 1, 1030 do tracks[i] = api.track_add({ name = "t" .. i }) end
  -- Sync without handing the warnings to the notifier, to read them here.
  api.events_take()
  local warnings = api.warnings()
  eq(#warnings > 0 and warnings[1]:find("too many tracks") ~= nil, true, "a warning for the tracks over the limit")
  for i = 1, 20 do api.track_remove(tracks[i]) end
  daw.flush()
  local last = daw.track(tracks[1030])
  last:add_device("synth")
  last:note_on(60, 100)
  api.sleep(100)
  local l = last:meter()
  last:note_off(60)
  eq(l > 0, true, "the last track plays")
  fresh()
end)

test("a render leaves denormal numbers working for Lua", function()
  fresh()
  tone("t", 1)
  render({ tail = 0 })
  eq(1e-310 * 0.5 > 0, true, "denormals are not flushed to zero on the main thread")
end)

-- Sound ----------------------------------------------------------------------

test("a note renders, and silence renders as silence", function()
  fresh()
  local t = tone("tone", 2)
  local info = render({ tail = 0.2 })
  eq(info.peak > 0.05, true, "audible")
  near(info.seconds, 1.2, 0.01, "length: 2 beats at 120 bpm plus the tail")
  t.mute = true
  eq(render().peak, 0, "muted")
  t.mute = false
  t:clips()[1].muted = true
  eq(render().peak, 0, "clip muted")
end)

test("playback that starts inside a note sounds that note", function()
  fresh()
  local t = tone("held", 8)
  eq(render({ start = 3, ["end"] = 4, tail = 0 }).peak > 0.05, true, "render from the middle of the note")
  eq(render({ start = 9, ["end"] = 10, tail = 0 }).peak < 0.001, true, "nothing after the note ends")
  -- The same in real time, and after jumping while playing.
  daw.project.tempo = 240
  daw.transport.seek(2)
  daw.transport.play()
  api.sleep(150)
  eq(select(1, t:meter()) > 0.01, true, "playing from inside the note")
  daw.transport.seek(40)
  api.sleep(1500)
  eq(select(1, t:meter()) < 0.005, true, "jumping past the note stops it")
  daw.transport.seek(4)
  api.sleep(150)
  eq(select(1, t:meter()) > 0.01, true, "jumping back into the note starts it")
  daw.transport.stop()
end)

test("the fader and pan do what they say", function()
  fresh()
  local t = tone("tone", 2)
  local unity = render().peak
  t.volume = -6
  near(render().peak / unity, 0.501, 0.01, "-6 dB halves the level")
  t.volume = 0
  t.pan = -1
  local left, right = channel_peaks(render({ bits = 16 }))
  eq(left > 0.05, true, "hard left has left")
  eq(right < 0.001, true, "hard left has no right")
  t.pan = 0
  left, right = channel_peaks(render({ bits = 16 }))
  near(left, right, 0.001, "centre is equal")
  near(left, unity, 0.005, "centre is unity gain")
end)

test("solo silences the others but not what a soloed track feeds", function()
  fresh()
  local a, b = tone("a", 2, "A3"), tone("b", 2, "E4")
  local bus = daw.add_track({ name = "bus" })
  a.output = bus
  local both = render().peak
  b.solo = true
  local only_b = render().peak
  eq(only_b < both * 0.8, true, "soloing b drops a")
  b.solo = false
  a.solo = true
  local only_a = render().peak
  eq(only_a > 0.05, true, "a is still heard through its bus")
  bus.mute = true
  a.solo = false
  near(render().peak, only_b, 0.01, "muting the bus mutes a")
end)

test("routing refuses loops and survives removing a bus", function()
  fresh()
  local a = tone("a", 2)
  local bus, bus2 = daw.add_track({ name = "bus" }), daw.add_track({ name = "bus2" })
  a.output = bus
  bus.output = bus2
  fails(function() bus2.output = a end, "loop", "output loop")
  fails(function() bus2:send(a, 0) end, "loop", "send loop")
  local before = render().peak
  bus.volume = -6
  near(render().peak / before, 0.501, 0.01, "bus fader applies")
  bus:remove()
  eq(a.output, nil, "falls back to the master")
  near(render().peak, before, 0.005, "still sounds")
end)

test("sends add signal to their target", function()
  fresh()
  local a = tone("a", 2)
  local fx = daw.add_track({ name = "fx" })
  local dry = render().peak
  a:send(fx, 0)
  near(render().peak / dry, 2, 0.02, "an equal send doubles the level")
end)

test("effects run in chain order and can be bypassed", function()
  fresh()
  local t = tone("tone", 1)
  local dry = render({ tail = 0 }).peak
  local gain = t:add_device("gain", { gain = -12 })
  near(render({ tail = 0 }).peak / dry, 0.251, 0.01, "gain device")
  gain.bypass = true
  near(render({ tail = 0 }).peak, dry, 0.005, "bypassed")
  gain:remove()
  local delay = t:add_device("delay", { time = 600, feedback = 0, mix = 1 })
  -- The note lasts one beat (0.5 s), so a 600 ms echo of it sounds from 0.6 to 1.1 s.
  local wet = render({ tail = 1, bits = 16 })
  near(channel_peaks(wet, 0.6, 1.1), dry, 0.02, "the echo is as loud as the note")
  eq(channel_peaks(wet, 0.52, 0.58) < 0.01, true, "silence between the note and its echo")
  delay.bypass = true
  eq(channel_peaks(render({ tail = 1, bits = 16 }), 0.7, 1.0) < 0.001, true, "no echo when bypassed")
end)

test("audio clips play back what was rendered", function()
  fresh()
  tone("tone", 2)
  local source = render({ tail = 0, bits = 24 })
  fresh()
  local t = daw.add_track({ name = "audio" })
  local clip = t:add_clip({ start = 1, file = source.path })
  eq(clip.kind, "audio", "kind")
  near(clip.length, 2, 0.01, "length follows the file")
  local out = render({ tail = 0 })
  near(out.peak, source.peak, 0.01, "same level")
  eq(daw.render(scratch .. "/gap.wav", { start = 0, ["end"] = 0.9, tail = 0 }).peak < 0.001, true, "silent before the clip")
  clip.gain = -6
  near(render({ tail = 0 }).peak / source.peak, 0.501, 0.02, "clip gain")
  -- A different sample rate must not change the pitch or length.
  near(render({ tail = 0, sample_rate = 44100 }).peak, source.peak * 0.501, 0.02, "resampled")
end)

test("audio clips load WAV, AIFF, FLAC, MP3 and Ogg Vorbis", function()
  -- Each fixture is 0.25 s of 440 Hz at 0.5 (-6 dB); the stereo ones are at
  -- 0.25 on the right. See tests/fixtures/make.sh. The lossy ones come back
  -- a few percent off.
  for _, f in ipairs({
    { "tone-mono-8k.wav", 0.5, 0.005 },
    { "tone-mono-11k.aiff", 0.5, 0.005 },
    { "tone-stereo-11k.flac", 0.25, 0.005 },
    { "tone-stereo-44k.mp3", 0.25, 0.05 },
    { "tone-stereo-48k.ogg", 0.25, 0.05 },
  }) do
    local name, right, tolerance = f[1], f[2], f[3]
    fresh()
    local clip = daw.add_track():add_clip({ start = 0, file = fixtures .. name })
    eq(clip.kind, "audio", name .. " kind")
    near(clip.length, 0.5, 0.001, name .. " length: 0.25 s at 120 bpm")
    -- Each file plays at its own rate whatever the engine runs at.
    for _, rate in ipairs({ 48000, 44100 }) do
      local out = render({ tail = 0, bits = 16, sample_rate = rate })
      near(out.seconds, 0.25, 0.002, name .. " renders for the clip's length")
      local l, r = channel_peaks(out, 0.02, 0.23)
      near(l, 0.5, tolerance, name .. " left level at " .. rate)
      near(r, right, tolerance, name .. " right level at " .. rate .. (right == 0.5 and ", mono on both sides" or ""))
      near(frequency(out, 0.02, 0.23), 440, 10, name .. " pitch at " .. rate)
    end
  end
end)

test("unreadable audio files say what is wrong", function()
  fresh()
  local t = daw.add_track()
  local function add(path) return function() t:add_clip({ start = 0, file = path }) end end
  write_file(scratch .. "/notes.wav", "a text file named like a sound\n")
  fails(add(scratch .. "/notes.wav"), "notes%.wav is not an audio file", "text")
  write_file(scratch .. "/cut.wav", read_file(fixtures .. "tone-mono-8k.wav"):sub(1, 3000))
  fails(add(scratch .. "/cut.wav"), "cut%.wav is truncated", "truncated WAV")
  write_file(scratch .. "/cut.mp3", read_file(fixtures .. "tone-stereo-44k.mp3"):sub(1, 1300))
  fails(add(scratch .. "/cut.mp3"), "cut%.mp3 is truncated", "truncated MP3")
  write_file(scratch .. "/cut.ogg", read_file(fixtures .. "tone-stereo-48k.ogg"):sub(1, 3000))
  fails(add(scratch .. "/cut.ogg"), "cut%.ogg is truncated", "truncated Ogg")
  fails(add(fixtures .. "tone-mono-48k.opus"), "opus uses an audio codec that is not supported", "Opus")
  eq(#t:clips(), 0, "no clips were added")
end)

test("audio clips report their waveform", function()
  fresh()
  local t = daw.add_track({ name = "shape" })
  -- 0.25 s in four equal parts: silence, a sine peaking at 0.5, one peaking at
  -- 0.75, and -0.25 held.
  local clip = t:add_clip({ start = 0, file = fixtures .. "shape.wav" })
  local function check(peaks, want, what)
    eq(#peaks, #want, what .. ": count")
    for i, p in ipairs(peaks) do
      near(p[1], want[i][1], 1e-4, what .. ": min " .. i)
      near(p[2], want[i][2], 1e-4, what .. ": max " .. i)
    end
  end
  local parts = { { 0, 0 }, { -0.5, 0.5 }, { -0.75, 0.75 }, { -0.25, -0.25 } }
  check(clip:peaks(4), parts, "whole file")
  local loud = clip:peaks(4)
  near(loud[1][3], 0, 1e-6, "silence has no loudness")
  near(loud[2][3], 0.5 / math.sqrt(2), 0.01, "a sine is as loud as its peak over the root of two")
  near(loud[4][3], 0.25, 1e-4, "a held level is as loud as it reaches")
  check(clip:peaks(8), { parts[1], parts[1], parts[2], parts[2], parts[3], parts[3], parts[4], parts[4] }, "finer")
  check(clip:peaks(1), { { -0.75, 0.75 } }, "one point")
  eq(#clip:peaks(5000), 5000, "more points than samples")

  -- The arrange view draws it under the name, over the rows a track has
  -- left, on a decibel scale: the louder part fills more of them.
  daw.opt.zoom, daw.opt.track_height = 8, 3
  daw.cursor.set_track(t)
  local text = table.concat(api.ui_snapshot(100, 30), "\n")
  daw.opt.zoom, daw.opt.track_height = 2, "auto"
  local rows = daw.draw.waveform(clip:peaks(8), 2)
  eq(rows[1]:find("▇", 1, true) ~= nil, true, "the loud parts reach well into the upper row: " .. rows[1])
  eq(rows[2]:find("█", 1, true) ~= nil, true, "over a full lower one: " .. rows[2])
  eq(rows[2]:sub(1, 1), " ", "silence draws nothing")
  -- A column for each part of the file: nothing, then -6, -2.5 and -12 dB,
  -- 3 dB to a level over the two rows under the clip's name.
  eq(text:find("▅▇▃", 1, true) ~= nil, true, "waveform on screen, its top row")
  eq(text:find("███", 1, true) ~= nil, true, "and the full row under it")

  -- Only the part the clip plays, and silence past the end of the file.
  clip.offset, clip.length = 0.0625, 0.25
  check(clip:peaks(2), { parts[2], parts[3] }, "offset and length")
  clip.offset = 0.1875
  check(clip:peaks(2), { parts[4], { 0, 0 } }, "past the end")
  daw.project.tempo = 60
  check(clip:peaks(2), { parts[4], { 0, 0 } }, "a slower tempo plays more of the file")
  daw.project.tempo = 120
  clip.gain = -6.0206
  check(clip:peaks(2), { { -0.125, -0.125 }, { 0, 0 } }, "clip gain")

  local flat = daw.frontend.peaks(clip.id)
  eq(#flat, 3 * daw.frontend.peak_points, "frontend peaks are flat: the reach each way and the loudness")
  eq(#daw.frontend.peaks(clip.id, 512), 3 * 512, "at as many points as the frontend draws")

  local state = daw.frontend.state(-1)
  eq(type(state.clips[1].waveform), "string", "frontend state says when the waveform changes")
  local before = state.clips[1].waveform
  clip.gain = 0
  eq(daw.frontend.state(-1).clips[1].waveform ~= before, true, "and it changes with the clip")
  fails(function() t:add_clip({ start = 2, length = 1 }):peaks(4) end, "only audio clips", "MIDI clip")
end)

test("drums respond to the General MIDI drum notes", function()
  fresh()
  local t = daw.add_track({ name = "drums" })
  t:add_device("drums")
  t:add_clip({ start = 0, length = 4, notes = { { pitch = 36, start = 0, length = 0.25 }, { pitch = 42, start = 1, length = 0.25 } } })
  eq(daw.render(scratch .. "/kick.wav", { start = 0, ["end"] = 0.5, tail = 0 }).peak > 0.1, true, "kick")
  eq(daw.render(scratch .. "/hat.wav", { start = 1, ["end"] = 1.2, tail = 0 }).peak > 0.02, true, "hat")
  eq(daw.render(scratch .. "/rest.wav", { start = 3, ["end"] = 4, tail = 0 }).peak < 0.001, true, "rest")
end)

-- Automation -----------------------------------------------------------------

local function db(x) return 10 ^ (x / 20) end

--- Left-channel peak 10 ms either side of `at` seconds, as a fraction of the
--- same window in `reference`.
local function relative(info, reference, at)
  return channel_peaks(info, at - 0.01, at + 0.01) / channel_peaks(reference, at - 0.01, at + 0.01)
end

test("lanes hold sorted points in their target's units", function()
  fresh()
  local t = daw.add_track()
  local lane = t:automate("volume")
  eq(t:automate("volume"), lane, "one lane per target")
  lane:add(8, 0)
  lane:add(0, -60)
  lane:add(8, -6)
  eq(daw.inspect(lane:points()), daw.inspect({ { 0, -60 }, { 8, -6 } }), "sorted, and a point at the same beat replaced")
  eq(lane:value_at(4), -33, "linear between points")
  eq(lane:value_at(-1) .. "/" .. lane:value_at(20), "-60/-6", "held outside them")
  lane:set_points({ { beat = 2, value = 100 } })
  eq(lane:points()[1][2], 24, "clamped to the fader's range")
  eq(t.volume, 0, "the track's own volume is untouched")
  eq(t:value_at("volume", 0), 24, "value_at reads the lane")
  lane.enabled = false
  eq(t:value_at("volume", 0), 0, "and the track's own value when the lane is off")
  local pan = t:automate("pan")
  pan:add(0, -5)
  eq(pan:points()[1][2], -1, "pan is clamped")
  eq(#t:lanes(), 2, "two lanes")
  local synth = t:add_device("synth")
  local cutoff = synth:automate("cutoff")
  cutoff:add(0, 1e9)
  eq(cutoff:points()[1][2], 20000, "parameters are clamped to their range")
  eq(synth:lane("cutoff"), cutoff, "found again by parameter")
  eq(cutoff.target .. "/" .. cutoff.device .. "/" .. cutoff.param, "param/" .. synth.id .. "/cutoff", "fields")
  fails(function() t:automate("width") end, "width", "unknown target")
  fails(function() daw.add_track():add_device("gain"):automate("nope") end, "nope", "unknown parameter")
  pan:clear()
  eq(#pan:points(), 0, "cleared")
  pan:remove()
  eq(pan:exists(), false, "removed")
  eq(t:lane("pan"), nil, "gone from the track")
end)

test("a volume lane fades a track in", function()
  fresh()
  local t = tone("tone", 8)
  local reference = render({ tail = 0, bits = 16 })
  t:automate("volume"):set_points({ { 0, -60 }, { 8, 0 } })
  local faded = render({ tail = 0, bits = 16 })
  -- 8 beats are 4 seconds, so the level rises 15 dB a second.
  near(relative(faded, reference, 0.5), db(-52.5), 0.002, "at 0.5 s")
  near(relative(faded, reference, 2), db(-30), 0.005, "at 2 s")
  near(relative(faded, reference, 3), db(-15), 0.02, "at 3 s")
  near(relative(faded, reference, 3.9), db(-1.5), 0.04, "at 3.9 s")
end)

test("pan automation moves the signal between channels", function()
  fresh()
  local t = tone("tone", 8)
  t:automate("pan"):set_points({ { 0, -1 }, { 8, 1 } })
  local info = render({ tail = 0, bits = 16 })
  local left, right = channel_peaks(info, 0.2, 0.3)
  eq(left > 0.05 and right < left * 0.2, true, "starts on the left")
  left, right = channel_peaks(info, 1.95, 2.05)
  near(left / right, 1, 0.05, "centred halfway")
  left, right = channel_peaks(info, 3.7, 3.8)
  eq(right > 0.05 and left < right * 0.2, true, "ends on the right")
end)

test("a device parameter lane changes the level at the right beats", function()
  fresh()
  local t = tone("tone", 8)
  local gain = t:add_device("gain")
  local reference = render({ tail = 0, bits = 16 })
  -- Two points on one beat make a step.
  local lane = gain:automate("gain")
  lane:set_points({ { 0, -12 }, { 4, -12 }, { 4, 0 }, { 5, 0 }, { 6, -60 } })
  local info = render({ tail = 0, bits = 16 })
  near(relative(info, reference, 1), db(-12), 0.01, "before the step")
  near(relative(info, reference, 2.25), 1, 0.03, "after the step")
  near(relative(info, reference, 2.75), db(-30), 0.01, "ramping down")
  eq(relative(info, reference, 3.5) < 0.002, true, "held at the last point")
  eq(gain.params.gain, 0, "the device's own value is untouched")
  eq(gain:value_at("gain", 5.5), -30, "value_at")
end)

test("a disabled lane does nothing", function()
  fresh()
  local t = tone("tone", 4)
  local reference = render({ tail = 0 }).peak
  local lane = t:automate("volume")
  lane:add(0, -60)
  eq(render({ tail = 0 }).peak < reference * 0.01, true, "on")
  lane.enabled = false
  near(render({ tail = 0 }).peak, reference, 0.005, "off")
  lane.enabled = true
  lane:clear()
  near(render({ tail = 0 }).peak, reference, 0.005, "a lane with no points does nothing either")
end)

test("lanes are undone, saved and loaded", function()
  fresh()
  local t = tone("tone", 8)
  local gain = t:add_device("gain")
  api.undo_checkpoint()
  local volume = t:automate("volume")
  volume:set_points({ { 0, -60 }, { 8, 0 } })
  api.undo_checkpoint()
  volume:add(4, -6)
  gain:automate("gain"):add(0, -20)
  api.undo_checkpoint()
  daw.flush()
  local seen = {}
  daw.on("lane.*", function(event, name) seen[#seen + 1] = name .. ":" .. event.id end)
  daw.undo()
  daw.flush()
  eq(#volume:points(), 2, "point undone")
  eq(gain:lane("gain"), nil, "lane undone")
  eq(seen[1], "lane.changed:" .. volume.id, "changes are reported")
  daw.undo()
  eq(volume:exists(), false, "lane gone")
  daw.redo()
  daw.redo()
  eq(#volume:points(), 3, "redone")
  volume.enabled = false
  local before = render({ tail = 0, bits = 16 })
  local path = daw.project.save(scratch .. "/lanes.json")
  fresh()
  daw.project.load(path)
  local loaded = daw.tracks()[1]
  eq(#loaded:lanes(), 2, "lanes are back")
  eq(daw.inspect(loaded:lane("volume"):points()), daw.inspect({ { 0, -60 }, { 4, -6 }, { 8, 0 } }), "with their points")
  eq(loaded:lane("volume").enabled, false, "and whether they are on")
  eq(loaded:device("gain"):lane("gain"):value_at(0), -20, "parameter lanes too")
  near(render({ tail = 0, bits = 16 }).peak, before.peak, 0.001, "and they sound the same")
end)

test("removing a device drops its lanes", function()
  fresh()
  local t = tone("tone", 4)
  local gain = t:add_device("gain")
  gain:automate("gain"):add(0, -60)
  t:automate("volume"):add(0, -6)
  eq(render({ tail = 0 }).peak < 0.01, true, "the lane applies")
  api.undo_checkpoint()
  gain:remove()
  eq(#t:lanes(), 1, "only the device's lane went")
  eq(t:lanes()[1].target, "volume", "the track's lane stays")
  eq(render({ tail = 0 }).peak > 0.05, true, "and nothing is left of it in the engine")
  daw.undo()
  eq(#t:lanes(), 2, "undo brings both back")
  eq(render({ tail = 0 }).peak < 0.01, true, "and the lane applies again")
end)

test("automation applies the same when playback starts in the middle", function()
  fresh()
  local t = tone("tone", 8)
  local gain = t:add_device("gain")
  local function both() return render({ tail = 0, bits = 16 }), render({ start = 4, ["end"] = 8, tail = 0, bits = 16 }) end
  -- The note starts over when playback starts inside it, so each render is
  -- measured against the same render without automation.
  local full_ref, middle_ref = both()
  t:automate("volume"):set_points({ { 0, -60 }, { 8, 0 } })
  gain:automate("gain"):set_points({ { 0, 0 }, { 5, 0 }, { 5, -24 } })
  local full, middle = both()
  -- Beat 4 is 2 s into the full render and the start of the other.
  for _, at in ipairs({ 0.01, 0.25, 0.75, 1.5 }) do
    local want = db(-30 + at * 15) * (at > 0.5 and db(-24) or 1)
    near(relative(middle, middle_ref, at) / want, 1, 0.05, "from the middle, at beat " .. 4 + at * 2)
    near(relative(middle, middle_ref, at) / relative(full, full_ref, 2 + at), 1, 0.03, "the same as from the start, at beat " .. 4 + at * 2)
  end
end)

-- Plugins --------------------------------------------------------------------
-- These need the plugins the dev shell provides (see DAW_TEST_PLUGINS) and are
-- skipped without them.

local function plugin_kind(format, pattern)
  for _, info in ipairs(daw.device_types()) do
    if info.format == format and info.name:find(pattern) then return info.kind end
  end
end

for _, format in ipairs({ "clap", "lv2", "vst3" }) do
  test(format .. " effects process audio, take parameters and keep their state", function()
    local kind = plugin_kind(format, "Limiter Stereo$")
    if not kind then return "skipped: test plugins not found" end
    fresh()
    local t = tone("tone", 2)
    local dry = render({ tail = 0.2 }).peak
    local fx = t:add_device(kind)
    local d = fx:get()
    eq(d.format, format, "format")
    eq(#d.param_info > 10, true, "the plugin lists its parameters")
    -- These plugins have windows of their own; built-in devices do not.
    -- (Opening one needs a display, so that is not done here.)
    eq(fx.editor, "closed", "the plugin offers an editor")
    eq(t:devices()[1].editor, nil, "a built-in device has none")
    fails(function() t:devices()[1]:open_editor() end, "no editor", "opening an editor that is not there")
    eq(render({ tail = 0.2 }).peak > dry * 0.3, true, "audio passes through")

    -- Turn the output gain all the way down, by whatever name the format gives it.
    local gain
    for _, p in ipairs(d.param_info) do
      if p.key == "output_gain" or p.key == "g_out" then gain = p end
    end
    eq(gain ~= nil, true, "found the output gain parameter")
    fx:set(gain.key, gain.min)
    eq(fx.params[gain.key], gain.min, "the value reads back")
    eq(render({ tail = 0.2 }).peak < dry * 0.05, true, "the parameter takes effect")
    fx.bypass = true
    near(render({ tail = 0.2 }).peak, dry, 0.01, "bypass")
    fx.bypass = false

    local path = daw.project.save(scratch .. "/" .. format .. ".json")
    fresh()
    daw.project.load(path)
    local loaded = daw.tracks()[1]:devices()[2]
    eq(loaded.kind, kind, "the plugin is back after loading")
    eq(loaded.params[gain.key], gain.min, "with its parameter")
    eq(render({ tail = 0.2 }).peak < dry * 0.05, true, "and it still takes effect")

    -- Playing in real time and removing a plugin while it runs must both be safe.
    daw.transport.play()
    api.sleep(150)
    loaded:remove()
    daw.flush()
    api.sleep(100)
    daw.transport.stop()
    eq(#daw.tracks()[1]:devices(), 1, "removed while playing")
    fails(function() daw.tracks()[1]:add_device(format .. ":no-such-plugin") end, "no%-such%-plugin", "unknown plugin")
  end)

  test(format .. " plugins run in a process of their own, and one that dies is lost alone", function()
    local kind = plugin_kind(format, "Limiter Stereo$")
    if not kind then return "skipped: test plugins not found" end
    fresh()
    local t = tone("tone", 2)
    local dry = render({ tail = 0.2 }).peak
    local fx = t:add_device(kind)
    local pid = tonumber((select(2, pcall(api.device_call, fx.id, "sandbox.pid"))))
    if not pid then return "skipped: plugins are hosted in-process here" end
    eq(pid ~= api.env().pid, true, "the plugin has a process of its own")
    local gain
    for _, p in ipairs(fx:get().param_info) do
      if p.key == "output_gain" or p.key == "g_out" then gain = p end
    end
    fx:set(gain.key, gain.min)
    daw.project.save(scratch .. "/" .. format .. "-crash.json")   -- the project now has the plugin's state
    local stopped = {}
    local handler = daw.on("device.stopped", function(e) stopped[#stopped + 1] = e end)
    daw.transport.play()
    api.sleep(100)
    os.execute("kill -KILL " .. pid)
    daw.wait(400)
    daw.transport.stop()
    daw.off(handler)
    eq(#stopped, 1, "its crash is told, once")
    eq(stopped[1].device .. " " .. stopped[1].reason, fx.id .. " it was killed", "with the device and what happened")
    eq(fx:get().stopped ~= nil, true, "the device says that it has stopped")
    eq(#t:devices(), 2, "and is still in the project")
    daw.transport.play()
    api.sleep(150)
    eq(select(1, t:meter()) > dry * 0.3, true, "the track plays on, an effect that is gone passed through")
    daw.transport.stop()
    fails(function() fx:open_editor() end, "not running", "asking a stopped plugin for something")
    fx:restart()
    eq(fx:get().stopped, nil, "started again, it is well")
    eq(fx.params[gain.key], gain.min, "with what the project had of it")
    eq(render({ tail = 0.2 }).peak < dry * 0.05, true, "and it works as it did")
    local again = tonumber(api.device_call(fx.id, "sandbox.pid"))
    eq(again ~= pid, true, "in a new process")
  end)

  test(format .. " parameters follow automation", function()
    local kind = plugin_kind(format, "Limiter Stereo$")
    if not kind then return "skipped: test plugins not found" end
    fresh()
    local t = tone("tone", 8)
    local fx = t:add_device(kind)
    local gain
    for _, p in ipairs(fx:get().param_info) do
      if p.key == "output_gain" or p.key == "g_out" then gain = p end
    end
    local base = fx.params[gain.key]
    fx:automate(gain.key):set_points({ { 4, base }, { 4, gain.min } })
    local info = render({ tail = 0, bits = 16 })
    eq(channel_peaks(info, 0.5, 1.5) > 0.05, true, "sounds before the step")
    eq(channel_peaks(info, 2.5, 3.5) < 0.005, true, "silent after it")
    eq(fx.params[gain.key], base, "the project keeps its own value")
  end)

  test(format .. " instruments play notes", function()
    local kind = plugin_kind(format, "^Surge XT$")
    if not kind then return "skipped: test plugins not found" end
    fresh()
    local t = daw.add_track({ name = "surge" })
    local synth = t:add_device(kind)
    eq(synth.format, format, "format")
    local clip = t:add_clip({ start = 0, length = 2, notes = { { pitch = "A3", start = 0, length = 1 } } })
    eq(render({ tail = 0.3 }).peak > 0.05, true, "a note sounds")
    clip.muted = true
    eq(render({ tail = 0.3 }).peak < 0.001, true, "no notes, no sound")
    -- Its state survives being saved and loaded.
    clip.muted = false
    local path = daw.project.save(scratch .. "/" .. format .. "-inst.json")
    fresh()
    daw.project.load(path)
    eq(render({ tail = 0.3 }).peak > 0.05, true, "sounds after loading")
  end)
end

-- Real time ------------------------------------------------------------------

test("the transport plays, seeks, loops and stops", function()
  fresh()
  local t = daw.add_track()
  t:add_device("synth")
  local notes = {}
  for beat = 0, 7 do notes[#notes + 1] = { pitch = "A3", start = beat, length = 1 } end
  t:add_clip({ start = 0, length = 8, notes = notes })
  daw.project.tempo = 240 -- four beats a second
  eq(daw.transport.playing, false, "starts stopped")
  daw.transport.seek(2)
  eq(daw.transport.position, 2, "seek is visible at once")
  daw.transport.play()
  api.sleep(300)
  local pos = daw.transport.position
  eq(pos > 2.6 and pos < 4.2, true, "advanced about 1.2 beats, got " .. pos)
  eq(select(1, t:meter()) > 0.01, true, "meter moves")
  daw.transport.loop_start, daw.transport.loop_end, daw.transport.loop_enabled = 0, 1, true
  daw.transport.seek(0)
  api.sleep(600)
  eq(daw.transport.position < 1, true, "stays inside the loop")
  daw.transport.stop()
  local stopped = daw.transport.position
  api.sleep(100)
  eq(daw.transport.position, stopped, "holds still when stopped")
end)

test("a lane wins over the fader while playing, and lets go when it is turned off", function()
  fresh()
  local t = tone("held", 64)
  daw.project.tempo = 240
  local lane = t:automate("volume")
  lane:add(0, -60)
  daw.transport.play()
  api.sleep(200)
  eq(select(1, t:meter()) < 0.003, true, "the lane holds the track down")
  t.volume = 6
  daw.flush()
  api.sleep(200)
  eq(select(1, t:meter()) < 0.003, true, "moving the fader does not override it")
  lane.enabled = false
  daw.flush()
  api.sleep(200)
  eq(select(1, t:meter()) > 0.05, true, "turning the lane off returns to the fader")
  daw.transport.stop()
end)

test("live notes sound without the transport", function()
  fresh()
  local t = daw.add_track()
  t:add_device("synth")
  t:note_on("C4", 110)
  api.sleep(120)
  eq(select(1, t:meter()) > 0.01, true, "note is sounding")
  t:note_off("C4")
  api.sleep(1600)
  eq(select(1, t:meter()) < 0.005, true, "note released and the meter fell back")
end)

-- Input and recording ----------------------------------------------------------
-- The null backend can generate input: channel n carries a sine at n times the
-- given frequency.

local function with_input(fn)
  api.engine_restart({ backend = "null", test_input = { frequency = 440, level = -12, channels = 2 } })
  local ok, err = xpcall(fn, debug.traceback)
  api.engine_restart({ backend = "null" })
  if not ok then error(err, 0) end
end

--- Peak and frequency (from rising zero crossings) of the left channel of a
--- 16-bit WAV file written by `daw.render`, between two times in seconds.
local function pitch_and_peak(info, from, to)
  local file = assert(io.open(info.path, "rb"))
  local data = file:read("*a")
  file:close()
  local at = data:find("data", 1, true) + 8
  local first, last = math.floor(from * info.sample_rate), math.floor(to * info.sample_rate)
  local peak, crossings, prev = 0, 0, 0
  for frame = first, last - 1 do
    local lo, hi = data:byte(at + frame * 4, at + frame * 4 + 1)
    if not hi then break end
    local v = lo + hi * 256
    if v >= 32768 then v = v - 65536 end
    if prev < 0 and v >= 0 then crossings = crossings + 1 end
    peak, prev = math.max(peak, math.abs(v) / 32768), v
  end
  return peak, crossings / ((last - first) / info.sample_rate)
end

local level = 10 ^ (-12 / 20) -- the test input's peak

test("input is heard through the track's devices when armed or monitored", function()
  with_input(function()
    fresh()
    local e = api.engine_get()
    eq(e.input_channels .. " " .. e.input_device, "2 test signal", "the engine reports its input")
    local t = daw.add_track({ name = "guitar" })
    t.input = 1
    eq(t.input, "1", "inputs read back as text")
    api.sleep(100)
    eq(select(1, t:meter()), 0, "not heard while neither armed nor monitored")
    t.monitor = true
    daw.flush()
    api.sleep(150)
    near(select(1, t:meter()), level, 0.01, "monitoring reaches the meter at the input's level")
    t:add_device("gain", { gain = -6 })
    daw.flush()
    api.sleep(600)
    near(select(1, t:meter()), level / 2, 0.01, "the input goes through the devices")
    t.input = "1/2"
    daw.flush()
    api.sleep(150)
    local left, right = t:meter()
    near(left, level / 2, 0.01, "a pair: left")
    near(right, level / 2, 0.01, "a pair: right")
    t.monitor = false
    t.armed = true
    daw.flush()
    api.sleep(150)
    near(select(1, t:meter()), level / 2, 0.01, "armed tracks are heard")
    t.armed = false
    daw.flush()
    api.sleep(1600)
    eq(select(1, t:meter()) < 0.005, true, "and not once disarmed")
    fails(function() t.input = "1/3" end, "1/3", "a pair must be neighbours")
    fails(function() daw.master.input = "1" end, "master", "the master has no input")
  end)
end)

test("recording the input makes a clip where recording began", function()
  with_input(function()
    fresh()
    daw.project.save(scratch .. "/rec.json")
    local mic = daw.add_track({ name = "mic" })
    mic.input, mic.armed = "2", true
    local idle = daw.add_track({ name = "idle" })
    idle.input = "1"
    local added = 0
    local handle = daw.on("clip.added", function() added = added + 1 end)
    daw.transport.seek(4)
    api.undo_checkpoint()
    daw.transport.record()
    eq(daw.transport.recording, true, "record mode")
    eq(daw.transport.take, 1, "a take is under way")
    api.sleep(1000)
    daw.transport.stop()
    local stopped = daw.transport.position
    daw.flush()
    daw.off(handle)
    eq(daw.transport.take, nil, "the take is over")
    eq(added, 1, "one clip.added event")
    eq(#idle:clips(), 0, "an unarmed track records nothing")
    local clips = mic:clips()
    eq(#clips, 1, "the armed track has a clip")
    local c = clips[1]:get()
    eq(c.kind, "audio", "kind")
    eq(c.start, 4, "it starts where recording began")
    near(c.start + c.length, stopped, 0.03, "it ends where recording stopped")
    eq(c.file:sub(1, #scratch + 7), scratch .. "/media/", "the file is beside the project")

    daw.transport.loop_enabled = false
    local info = render({ start = c.start, ["end"] = c.start + c.length, tail = 0, bits = 16 })
    local peak, freq = pitch_and_peak(info, 0.05, info.seconds - 0.05)
    near(peak, level, 0.01, "the recording has the input's level")
    near(freq, 880, 5, "and its pitch: input 2 carries twice the frequency")

    eq(daw.undo(), true, "undo")
    eq(#mic:clips(), 0, "undo removes the take")
    eq(mic.armed, true, "and nothing else")
    daw.redo()
    eq(#mic:clips(), 1, "redo brings it back")
  end)
end)

test("recordings of an unsaved project move beside it when it is saved", function()
  with_input(function()
    fresh()
    local t = daw.add_track({ name = "draft" })
    t.input, t.armed = "1", true
    daw.transport.record()
    api.sleep(300)
    daw.transport.stop()
    local before = t:clips()[1].file
    eq(before:find("/daw/recordings/", 1, true) ~= nil, true, "unsaved takes go to the data directory, got " .. before)
    daw.project.save(scratch .. "/later.json")
    local after = t:clips()[1].file
    eq(after, scratch .. "/media/" .. before:match("[^/]+$"), "saving brings the take beside the project")
    eq(io.open(after, "rb") ~= nil, true, "the file is there")
    os.remove(before)
    near(render({ tail = 0 }).peak, level, 0.01, "and still plays")
  end)
end)

test("MIDI input plays armed tracks and records into a clip", function()
  with_input(function()
    fresh()
    daw.project.save(scratch .. "/midi.json")
    local keys = daw.add_track({ name = "keys" })
    keys:add_device("synth", { attack = 0.001, release = 0.01 })
    keys.armed = true
    local other = daw.add_track({ name = "other" })
    other:add_device("synth")
    local mic = daw.add_track({ name = "mic" })
    mic.input, mic.armed = "1", true
    daw.flush()

    daw.midi.note_on("A3", 100)
    api.sleep(150)
    eq(select(1, keys:meter()) > 0.01, true, "an armed track plays the note")
    eq(select(1, other:meter()), 0, "an unarmed one does not")
    keys.armed = false
    daw.flush()
    api.sleep(1600)
    eq(select(1, keys:meter()) < 0.005, true, "disarming releases held notes")
    keys.armed = true

    daw.transport.seek(8)
    api.undo_checkpoint()
    daw.transport.record()
    api.sleep(250)
    local c4 = daw.transport.position
    daw.midi.note_on("C4", 90)
    api.sleep(500)
    local c4_off = daw.transport.position
    daw.midi.note_off("C4")
    api.sleep(100)
    local e4 = daw.transport.position
    daw.midi.inject({ type = "note_on", pitch = 64, velocity = 80, channel = 2 })
    api.sleep(250)
    daw.transport.stop()
    local stopped = daw.transport.position

    eq(#other:clips(), 0, "the unarmed track records nothing")
    local clip = keys:clips()[1]
    eq(clip.kind .. "@" .. clip.start, "midi@8", "a MIDI clip where recording began")
    near(clip.start + clip.length, stopped, 0.03, "ending where recording stopped")
    local notes = clip:notes()
    eq(#notes, 2, "two notes")
    eq(notes[1].pitch .. "/" .. notes[1].velocity, "60/90", "first note")
    near(notes[1].start, c4 - 8, 0.05, "first note's position")
    near(notes[1].length, c4_off - c4, 0.05, "first note's length")
    eq(notes[2].pitch .. "/" .. notes[2].velocity, "64/80", "second note")
    near(notes[2].start, e4 - 8, 0.05, "second note's position")
    near(notes[2].start + notes[2].length, clip.length, 0.001, "a note held at stop ends there")
    eq(#mic:clips() .. " " .. mic:clips()[1].kind, "1 audio", "the audio of the same take, and no notes there")
    local info = render({ start = clip.start + notes[1].start, ["end"] = clip.start + notes[1].start + 0.5, tail = 0 })
    eq(info.peak > 0.05, true, "the recorded notes play")

    daw.undo()
    eq(#keys:clips() + #mic:clips(), 0, "one undo step removes the whole take")
    fails(function() daw.midi.inject({ type = "note_on" }) end, "pitch", "a note needs a pitch")
  end)
end)

test("the status line shows recording", function()
  fresh()
  local function status()
    for _, line in ipairs(api.ui_snapshot(100, 30)) do
      if line:find("bpm", 1, true) then return line end
    end
  end
  eq(status():find("rec", 1, true), nil, "the rec flag shows only when it is on")
  daw.transport.recording = true
  eq(daw.transport.recording, true, "record mode can be set")
  eq(status():find("rec", 1, true) ~= nil, true, "and then it is there")
  daw.transport.play()
  eq(status():find("●", 1, true) ~= nil, true, "the transport shows it is recording")
  daw.transport.stop()
  daw.transport.recording = false
  eq(status():find("●", 1, true), nil, "and stops showing it")
end)

-- Commands and keys -----------------------------------------------------------

test("command lines parse into arguments", function()
  local name, args = daw.commands.parse('track.add "Lead Guitar" volume=-6 solo=true note="two words" plain')
  eq(name, "track.add", "name")
  eq(args[1], "Lead Guitar", "quoted positional")
  eq(args.volume, -6, "number")
  eq(args.solo, true, "boolean")
  eq(args.note, "two words", "quoted named")
  eq(args[2], "plain", "second positional")
  local _, raw = daw.commands.parse("lua  return 1 + 1 ")
  eq(raw[1], "return 1 + 1", "raw commands keep their text")
end)

test("custom commands, mappings and counts work", function()
  fresh()
  local got
  daw.command("test.echo", function(ctx) got = { ctx.args[1], ctx.args.loud, ctx.count } end, { desc = "test" })
  daw.cmd("test.echo", { "hi", loud = true })
  eq(got[1], "hi", "positional")
  eq(got[2], true, "named")
  daw.keymap.set("<leader>te", "test.echo mapped")
  daw.keymap.feed("3,te")
  eq(got[1], "mapped", "mapping ran the command")
  eq(got[3], 3, "count")
  fails(function() daw.cmd("no.such.command") end, "no.such.command", "unknown command")
end)

test("the default keys edit a project", function()
  fresh()
  daw.cursor.set_beat(0)
  daw.keymap.feed("oo")
  eq(#daw.tracks(), 2, "o adds tracks")
  eq(daw.cursor.index(), 2, "cursor follows")
  daw.keymap.feed("k")
  eq(daw.cursor.index(), 1, "k moves up")
  daw.keymap.feed("Ms")
  local t = daw.cursor.track()
  eq(t.mute and t.solo, true, "M and s toggle")
  daw.keymap.feed("3-")
  eq(t.volume, -3, "count with volume")
  daw.keymap.feed("4l:clip.add<CR>")
  local clip = t:clips()[1]
  eq(clip.start, 4, "clip at the cursor")
  daw.keymap.feed("&")
  eq(#t:clips(), 2, "& repeats the clip")
  daw.keymap.feed("0x")
  eq(#t:clips(), 2, "x off a clip does nothing")
  daw.keymap.feed("4lx")
  eq(#t:clips(), 1, "x removes the clip")
  daw.keymap.feed("ggdd")
  eq(#daw.tracks(), 1, "dd removes the track")
  daw.keymap.feed("O")
  eq(daw.cursor.index(), 1, "O adds a track above")
  eq(#daw.tracks(), 2, "O adds a track")
end)

test("the built-in commands do what their descriptions say", function()
  fresh()
  local run = daw.commands.exec
  daw.cursor.set_beat(0)
  run("track.add Lead device=synth")
  local t = daw.cursor.track()
  eq(t.name .. "/" .. t:devices()[1].kind, "Lead/synth", "track.add with a device")
  fails(function() run("track.add Broken device=nope") end, "nope", "track.add with a bad device")
  eq(#daw.tracks(), 1, "which leaves no track behind")
  daw.cursor.set_track(t)
  run('track.rename "Lead Guitar"')
  eq(t.name, "Lead Guitar", "track.rename")
  run("track.volume -6")
  run("track.volume by=2")
  eq(t.volume, -4, "track.volume sets and nudges")
  run("track.pan by=-0.3")
  eq(t.pan, -0.3, "track.pan")
  run("device.add dela")
  eq(t:devices()[2].kind, "delay", "device.add takes part of a name")
  run("device.set delay time=250 mix=0.5")
  eq(t:device("delay").params.time, 250, "device.set")

  run("clip.add length=8")
  local clip = t:clips()[1]
  clip:add_notes({ { pitch = 60, start = 1, length = 4 }, { pitch = 64, start = 6, length = 1 } })
  daw.cursor.set_beat(4)
  run("clip.split")
  local left, right = t:clips()[1], t:clips()[2]
  eq(left.length .. "+" .. right.length, "4+4", "clip.split lengths")
  eq(left:notes()[1].length, 3, "a note crossing the split is cut")
  eq(right:notes()[1].start, 2, "notes after the split keep their place")
  run("clip.move by=2")
  eq(right.start, 6, "clip.move")
  run("clip.resize by=-1")
  eq(right.length, 3, "clip.resize")
  run("clip.mute")
  eq(right.muted, true, "clip.mute")
  run("clip.duplicate")
  eq(#t:clips(), 3, "clip.duplicate")

  run("track.duplicate")
  local copy = daw.cursor.track()
  eq(copy.name, "Lead Guitar copy", "track.duplicate name")
  eq(copy.index, 2, "the copy follows the original")
  eq(#copy:clips() .. "/" .. #copy:devices(), "3/2", "with clips and devices")
  eq(copy:device("delay").params.time, 250, "and device parameters")
  run("track.add Bus")
  daw.cursor.set_track(t)
  run("track.output Bus")
  eq(t.output, daw.track("Bus").id, "track.output")
  run("track.move by=1")
  eq(t.index, 2, "track.move")

  run("tempo 140")
  eq(daw.project.tempo, 140, "tempo")
  run("transport.loop 2 3")
  local tr = daw.transport.get()
  eq(tr.loop_start .. "-" .. tr.loop_end .. " " .. tostring(tr.loop_enabled), "4-12 true", "transport.loop over bars")
  run("transport.seek 3")
  eq(daw.transport.position, 8, "transport.seek to a bar")
  run("grid 0.5")
  eq(daw.opt.grid, 0.5, "grid")
  run("zoom by=2")
  eq(daw.opt.zoom, 4, "zoom")
  daw.opt.grid, daw.opt.zoom = 1, 2

  local song = scratch .. "/commands.json"
  run("write " .. song)
  run("new")
  eq(#daw.tracks(), 0, "new")
  run("edit " .. song)
  eq(#daw.tracks(), 3, "write and edit round-trip")
  run("render " .. scratch .. "/commands.wav tail=0 bits=16")
  -- It renders in the background.
  for _ = 1, 500 do if not daw.render_status() then break end daw.wait(10) end
  eq(io.open(scratch .. "/commands.wav", "rb") ~= nil, true, "render wrote a file")
  eq(daw.cmd("lua", { "return 6 * 7" }), nil, "lua runs")
  fails(function() run("no.such") end, "no.such", "unknown command")
end)

test("automation is edited at the cursor, drawn and reported", function()
  fresh()
  local run = daw.commands.exec
  local t = tone("Lead", 8)
  daw.cursor.set_track(t)
  daw.cursor.set_beat(0)
  run("lane.add -60")
  daw.cursor.set_beat(8)
  run("lane.add 0")
  run("lane.add by=-3")
  eq(daw.inspect(t:lane("volume"):points()), daw.inspect({ { 0, -60 }, { 8, -3 } }), "lane.add sets and nudges")
  run("lane.add 0.5 target=pan")
  eq(t:lane("pan"):value_at(0), 0.5, "lane.add target=pan")
  run("lane.add 800 target=cutoff device=synth")
  eq(t:device("synth"):lane("cutoff"):value_at(0), 800, "lane.add for a device parameter")
  daw.keymap.feed(",at")
  eq(t:lane("volume").enabled, false, "<leader>at turns the lane off")

  daw.opt.track_height = 3
  local text = table.concat(api.ui_snapshot(100, 30), "\n")
  daw.opt.track_height = "auto"
  -- Past the clip the lane holds -3 dB: a line of dots near the top.
  eq(text:find("⠒⠒⠒", 1, true) ~= nil, true, "the volume curve is drawn")
  run("lane.toggle")
  local state = daw.frontend.state(-1)
  local lanes = state.tracks[1].lanes
  eq(#lanes, 3, "the frontend state lists the lanes")
  eq(lanes[1].target .. "/" .. tostring(lanes[1].enabled) .. "/" .. #lanes[1].points, "volume/true/2", "with their points")

  local copy = t:duplicate()
  eq(#copy:lanes(), 3, "a duplicated track keeps its automation")
  eq(copy:device("synth"):lane("cutoff"):value_at(0), 800, "on its own devices")
  daw.keymap.feed(",ax")
  eq(#t:lane("volume"):points(), 0, "<leader>ax clears the lane")
  run("lane.remove target=pan")
  eq(t:lane("pan"), nil, "lane.remove")
end)

test("the piano roll edits notes from the keyboard", function()
  fresh()
  daw.cursor.set_beat(0)
  daw.keymap.feed("o:clip.add<CR><CR>")
  eq(daw.ui.focused, "pianoroll", "Enter opens the clip")
  local clip = daw.cursor.track():clips()[1]
  daw.keymap.feed("<CR>4lk<CR>")
  local notes = clip:notes()
  eq(#notes, 2, "two notes")
  eq(notes[1].pitch .. "@" .. notes[1].start, "60@0", "first note")
  eq(notes[2].pitch .. "@" .. notes[2].start, "61@1", "second note, four 16ths later")
  daw.keymap.feed("<A-l><A-l>")
  eq(clip:notes()[2].length, 0.75, "Alt-l lengthens")
  daw.keymap.feed("x")
  eq(#clip:notes(), 1, "x removes")
  daw.keymap.feed("<C-w>c")
  eq(daw.ui.focused, "arrange", "<C-w>c returns to the arrange view")
end)

-- Modal editing ----------------------------------------------------------------

--- A track with a synth and three clips of four beats, a note on every beat.
local function three_clips()
  fresh()
  daw.keymap.feed("<Esc><Esc>")
  daw.ui.focus("arrange")
  local t = daw.add_track({ name = "T" })
  t:add_device("synth", { cutoff = 900 })
  for i, name in ipairs({ "a", "b", "c" }) do
    local notes = {}
    for beat = 0, 3 do notes[#notes + 1] = { pitch = 60 + beat, start = beat, length = 1 } end
    t:add_clip({ name = name, start = (i - 1) * 4, length = 4, notes = notes })
  end
  daw.cursor.set_track(t)
  daw.cursor.set_beat(0)
  daw.opt.grid, daw.opt.note_grid, daw.opt.ripple = 1, 0.25, false
  api.undo_checkpoint()
  return t
end

--- Where a track's clips are: "a@0+4 b@4+4".
local function layout(t)
  local out = {}
  for _, c in ipairs(api.clip_list(t.id)) do
    out[#out + 1] = string.format("%s@%g+%g%s", c.name, c.start, c.length, c.muted and "m" or "")
  end
  return table.concat(out, " ")
end

--- A clip's notes: "60@0+1 61@1+1".
local function melody(clip)
  local notes = clip:notes()
  table.sort(notes, function(a, b)
    if a.start ~= b.start then return a.start < b.start end
    return a.pitch < b.pitch
  end)
  for i, n in ipairs(notes) do notes[i] = string.format("%d@%g+%g", n.pitch, n.start, n.length) end
  return table.concat(notes, " ")
end

--- Type keys as one undo step.
local function keys(text)
  daw.keymap.feed(text)
  api.undo_checkpoint()
end

test("an operator takes a motion, a text object or a count", function()
  local t = three_clips()
  keys("dw")
  eq(layout(t), "b@4+4 c@8+4", "dw deletes up to the next clip")
  daw.undo()
  keys("ld2l")
  eq(layout(t), "a@0+1 a@3+1 b@4+4 c@8+4", "d2l cuts two beats out of a clip")
  eq(melody(t:clips()[1]) .. " | " .. melody(t:clips()[2]), "60@0+1 | 63@0+1", "the notes stay with their halves")
  eq(daw.cursor.beat, 1, "the cursor is where the gap starts")
  daw.undo()
  keys("d2ib")
  eq(layout(t), "c@8+4", "d2ib deletes two bars")
  daw.undo()
  keys("wd$")
  eq(layout(t), "a@0+4", "d$ deletes to the end of the track")
  daw.undo()
  keys("0dic")
  eq(layout(t), "b@4+4 c@8+4", "dic deletes the clip")
  keys("P")
  eq(layout(t), "a@0+4 b@4+4 c@8+4", "P puts it back at the cursor")
  eq(melody(t:clips()[1]), "60@0+1 61@1+1 62@2+1 63@3+1", "with its notes")
  keys("d3d")
  eq(#daw.tracks(), 0, "d3d takes whole tracks, as many as there are")
  daw.undo()
  keys("dx")
  eq(daw.keymap.mode .. layout(t), "na@0+4 b@4+4 c@8+4", "a key that is no motion calls the operator off")
  keys("d<Esc>l")
  eq(daw.cursor.beat, 1, "and so does Escape")
end)

test("yank and paste work on clips, stretches of time and whole tracks", function()
  local t = three_clips()
  keys("yicp")
  eq(layout(t), "a@0+4 a@4+4 c@8+4", "p puts the yanked clip after the one under the cursor, over what was there")
  eq(daw.cursor.beat, 4, "and the cursor on it")
  keys("p")
  eq(layout(t), "a@0+4 a@4+4 a@8+4", "p again carries on")
  keys("2p")
  eq(layout(t), "a@0+4 a@4+4 a@8+4 a@12+4 a@16+4", "a count pastes that many times")
  eq(daw.cursor.beat, 16, "the cursor is on the last copy")
  daw.undo() daw.undo() daw.undo()
  eq(layout(t), "a@0+4 b@4+4 c@8+4", "each paste is one undo step")

  -- A named register is not disturbed by what is deleted later.
  daw.cursor.set_beat(0)
  keys('"qyicwdic')
  eq(layout(t), "a@0+4 c@8+4", "b is gone")
  keys('"qP')
  eq(layout(t), "a@0+4 a@4+4 c@8+4", 'and "q still held a')
  keys('"_dicP')
  eq(layout(t), "a@0+4 b@4+4 c@8+4", 'deleting into "_ leaves the unnamed register alone')

  -- Whole tracks, with their devices, clips and automation.
  t:automate("volume"):set_points({ { 0, -12 }, { 4, 0 } })
  api.undo_checkpoint()
  keys("yyp")
  eq(#daw.tracks(), 2, "yyp duplicates the track")
  local copy = daw.cursor.track()
  eq(daw.cursor.index(), 2, "below, with the cursor on it")
  eq(layout(copy), layout(t), "with its clips")
  eq(copy:devices()[1].params.cutoff, 900, "its devices as they were set")
  eq(#copy:lane("volume"):points(), 2, "and its automation")
  keys("dd")
  eq(#daw.tracks(), 1, "dd removes it")
  keys("P")
  eq(daw.tracks()[1].id ~= t.id and layout(daw.tracks()[1]), layout(t), "P puts it back above")

  -- A stretch of time across tracks.
  daw.cursor.set_track(daw.tracks()[1])
  daw.cursor.set_beat(4)
  keys("vjWy")
  local value = daw.keymap.getreg()
  eq(value.kind .. value.length .. #value.rows, "range42", "v with j selects the same stretch on two tracks")
  keys("3Wk")
  keys("p")
  eq(layout(daw.tracks()[1]) .. " | " .. layout(daw.tracks()[2]), "a@0+4 b@4+4 c@8+4 b@16+4 | a@0+4 b@4+4 c@8+4 b@16+4", "and it is pasted on both")

  daw.opt.ripple = true
  daw.cursor.set_beat(0)
  keys("dic")
  eq(layout(daw.tracks()[1]), "b@0+4 c@4+4 b@12+4", "with ripple, deleting closes the gap")
  keys("P")
  eq(layout(daw.tracks()[1]), "a@0+4 b@4+4 c@8+4 b@16+4", "and pasting makes room")
  daw.opt.ripple = false
end)

test("visual mode selects time, tracks, and what a text object names", function()
  local t = three_clips()
  local other = daw.add_track({ name = "U" })
  other:add_clip({ name = "u", start = 0, length = 12 })
  api.undo_checkpoint()
  keys("v")
  local sel = daw.keymap.selection()
  eq(daw.keymap.mode .. sel.c0 .. "-" .. sel.c1, "x0-1", "v starts with one grid step")
  keys("WW")
  sel = daw.keymap.selection()
  eq(sel.c0 .. "-" .. sel.c1 .. " rows " .. sel.r0 .. "-" .. sel.r1, "0-8 rows 1-1", "motions stretch it")
  keys("j")
  eq(daw.keymap.selection().r1, 2, "onto other tracks too")
  keys("o")
  eq(daw.cursor.index() .. "@" .. daw.cursor.beat, "1@0", "o goes to the other end")
  keys("d")
  eq(daw.keymap.mode, "n", "an operator ends visual mode")
  eq(layout(t) .. " | " .. layout(other), "c@8+4 | u@8+4", "and acts on the selection")
  daw.undo()

  keys("gv")
  eq(daw.keymap.selection().c1, 8, "gv selects it again")
  keys("<Esc>wvic")
  sel = daw.keymap.selection()
  eq(sel.c0 .. "-" .. sel.c1, "4-8", "a text object becomes the selection")
  keys("~")
  eq(layout(t), "a@0+4 b@4+4m c@8+4", "~ mutes the selected clips")
  keys("gv~")
  eq(layout(t), "a@0+4 b@4+4 c@8+4", "and unmutes them")

  keys("0Vjgc")
  eq(tostring(t.mute) .. tostring(other.mute), "truetrue", "V selects whole tracks; gc mutes them")
  keys("gcc")
  eq(tostring(t.mute) .. tostring(other.mute), "falsetrue", "gcc is one track")
  keys("jgcck")

  keys("vee<C-a>")
  eq(melody(t:clips()[1]):sub(1, 6) .. melody(t:clips()[3]):sub(1, 6), "61@0+160@0+1", "<C-a> transposes the selected clips")
  keys("0veJ")
  eq(layout(t), "a@0+4 b@4+4 c@8+4", "J needs two clips")
  keys("veeeJ")
  eq(layout(t), "a@0+12", "J joins the selected clips")
  eq(#t:clips()[1]:notes(), 12, "with all their notes")
  keys("v")
  daw.ui.focus("mixer")
  eq(daw.keymap.mode, "n", "moving to another view ends visual mode")
  daw.ui.hide("mixer")
  daw.ui.focus("arrange")
end)

test("the other operators shift, quantize, loop and change", function()
  local t = three_clips()
  keys(">ic")
  eq(layout(t) .. " cursor " .. daw.cursor.beat, "a@1+4 b@4+4 c@8+4 cursor 1", "> moves the clip a grid step, and the cursor with it")
  keys("u")
  keys("3>>")
  eq(layout(t), "a@1+4 b@5+4 c@9+4", ">> moves every clip of the track")
  keys("<lt><lt>")
  eq(layout(t), "a@0+4 b@4+4 c@8+4", "<< moves them back")
  t:clips()[2].start = 4.4
  t:clips()[2]:set_notes({ { pitch = 60, start = 0.1, length = 0.5 } })
  api.undo_checkpoint()
  keys("==")
  eq(layout(t) .. " " .. melody(t:clips()[2]), "a@0+4 b@4+4 c@8+4 60@0+0.5", "== snaps clips and their notes to the grid")
  keys("wglic")
  eq(daw.transport.loop_start .. "-" .. daw.transport.loop_end .. tostring(daw.transport.loop_enabled), "4-8true", "gl loops what the motion covers")
  daw.transport.loop_enabled = false
  keys("cic")
  eq(daw.ui.focused .. daw.keymap.mode, "pianorolli", "c opens a fresh clip for entering notes")
  eq(layout(t), "a@0+4 b@4+4 c@8+4", "in place of the old one, under its name")
  eq(#t:clips()[2]:notes(), 0, "and empty")
  keys("<Esc>")
  daw.ui.focus("arrange")
  daw.cursor.set_beat(0)
  keys("J")
  eq(layout(t), "a@0+8 c@8+4", "J joins the clip with the next")
  keys("S")
  eq(layout(t), "a@0+8 c@8+4", "S at the start of a clip does nothing")
  keys("2lS")
  eq(layout(t), "a@0+2 a@2+6 c@8+4", "S splits at the cursor")
end)

test("the dot, macros, marks, jumps and search repeat and find things", function()
  local t = three_clips()
  keys("x")
  keys("w.")
  eq(layout(t), "c@8+4", ". repeats the last change")
  daw.undo() daw.undo()
  keys("0L")
  keys("3.")
  eq(layout(t), "a@4+4 b@4+4 c@8+4", "a count on . replaces the one it had")
  daw.undo() daw.undo()
  daw.cursor.set_beat(0)
  keys("j.")
  eq(layout(t), "a@1+4 b@4+4 c@8+4", "moving the cursor is not a change: . still repeats the one before")
  daw.undo()

  keys("0qqxwq")
  eq(layout(t) .. daw.keymap.getreg("q").keys, "b@4+4 c@8+4xw", "q records keys into a register")
  keys("2@q")
  eq(layout(t), "", "@ plays them, with a count")
  keys("@@")
  eq(layout(t) .. daw.keymap.mode, "n", "@@ plays the last one again, here with nothing left to delete")
  daw.undo() daw.undo()
  eq(layout(t), "a@0+4 b@4+4 c@8+4", "a macro is undone in one step")
  keys(":track.volume by=-2<CR>")
  keys("@:")
  eq(t.volume, -4, "@: runs the last command line again")

  daw.cursor.set_beat(0)
  local other = daw.add_track({ name = "Other" })
  other:add_clip({ name = "chorus", start = 16, length = 4 })
  api.undo_checkpoint()
  keys("WmaG$")
  eq(daw.cursor.index() .. "@" .. daw.cursor.beat, "2@20", "G and $ move")
  keys("'a")
  eq(daw.cursor.index() .. "@" .. daw.cursor.beat, "1@4", "'a returns to the mark")
  keys("''")
  eq(daw.cursor.index() .. "@" .. daw.cursor.beat, "2@20", "'' goes back")
  keys("gg0")
  keys("d'a")
  eq(layout(t), "b@4+4 c@8+4", "a mark is a motion for an operator")
  daw.undo()
  keys("/chor<CR>")
  eq(daw.cursor.index() .. "@" .. daw.cursor.beat, "2@16", "/ finds a clip by name")
  keys("<C-o>")
  eq(daw.cursor.index() .. "@" .. daw.cursor.beat, "1@0", "<C-o> goes back to where the search began")
  keys("/other<CR>")
  eq(daw.cursor.index(), 2, "/ finds a track by name")
  keys("9|")
  eq(daw.cursor.beat, 32, "N| goes to a bar")
  keys(":3<CR>")
  eq(daw.cursor.beat, 8, "and so does a number on the command line")
end)

test("half-typed commands show what can follow, and are counted right", function()
  three_clips()
  daw.opt.hint_delay = 0
  daw.keymap.feed("2d3")
  eq(daw.keymap.pending(), "2d3", "what was typed so far")
  eq(daw.keymap.mode, "o", "an operator is waiting")
  local hints, title = daw.keymap.hints()
  local found = {}
  for _, hint in ipairs(hints) do found[hint.key] = hint.desc end
  eq(found.w, "Start of the next clip", "motions are offered")
  eq(found.i, "+5 more", "and the start of text objects")
  eq(title, "Delete …", "under the operator's name")
  local screen = table.concat(api.ui_snapshot(100, 30), "\n")
  eq(screen:find("Delete …", 1, true) ~= nil and screen:find("PENDING", 1, true) ~= nil, true, "on screen")
  daw.keymap.feed("l")
  eq(daw.keymap.pending() .. daw.keymap.mode, "n", "done")
  eq(layout(daw.tracks()[1]), "b@6+2 c@8+4", "2d3l deleted six beats")
  daw.keymap.feed("g")
  hints = daw.keymap.hints()
  eq(hints ~= nil and #hints > 5, true, "a prefix lists its continuations")
  daw.keymap.feed("<Esc>")
  eq(daw.keymap.hints(), nil, "Escape clears them")
  daw.opt.hint_delay = 500
  -- An operator that fails leaves normal mode behind.
  daw.keymap.operator("gz", function() error("boom") end, { view = "arrange", desc = "Fails" })
  local messages = #daw.ui.messages
  daw.keymap.feed("gzl")
  eq(daw.keymap.mode .. daw.keymap.pending(), "n", "back to normal after an error")
  eq(daw.ui.messages[#daw.ui.messages].text:find("boom") ~= nil and #daw.ui.messages > messages, true, "which is reported")
  daw.keymap.del("gz", { view = "arrange" })
  daw.keymap.del("gz", { view = "arrange", mode = "x" })
end)

test("insert mode the keys way enters notes from the keyboard as from a piano", function()
  local t = three_clips()
  daw.opt.octave, daw.opt.velocity = 4, 100
  -- Insert mode draws notes unless asked for the keys (tests/drawinsert.lua):
  -- as `I` does in the piano roll, this once.
  daw.roll_draw.keys_once()
  daw.cursor.set_beat(16)
  keys("i")
  eq(daw.ui.focused .. daw.keymap.mode, "pianorolli", "i in the arrange view opens a new clip for typing")
  local clip = t:clips()[4]
  eq(clip.start .. "+" .. clip.length, "16+4", "at the cursor")
  local roll = daw.ui.views.pianoroll
  roll.length = nil
  keys("asd")
  eq(melody(clip), "60@0+0.25 62@0.25+0.25 64@0.5+0.25", "the home row is the white keys")
  keys("2w")
  eq(melody(clip):match("%S+$"), "61@0.75+0.5", "a digit sets the step; the row above is the black keys")
  keys("<Space>xa")
  eq(melody(clip):match("%S+$"), "72@1.75+0.5", "Space is a rest, x an octave up")
  keys("zADg")
  eq(melody(clip):match("60@2.25.*$"), "60@2.25+0.5 64@2.25+0.5 67@2.25+0.5", "capitals stay in place, for chords")
  keys("<BS>")
  eq(#clip:notes(), 5, "Backspace steps back and removes what was there")
  keys("8aa")
  eq(clip.length, 8, "the clip grows a bar when the notes run past its end")
  keys("<Esc>")
  eq(daw.keymap.mode, "n", "Escape returns to normal mode")
  local count = #clip:notes()
  keys("u")
  eq(#clip:notes(), count - 2, "undo takes the last notes back")
  keys("<Esc>")
  eq(daw.ui.focused, "pianoroll", "Escape in normal mode stays in the piano roll")
  keys("<C-w>p")
  eq(daw.ui.focused, "arrange", "Ctrl-w p goes back to the arrange view")
end)

test("the piano roll has the same grammar for notes", function()
  local t = three_clips()
  local clip = t:clips()[1]
  clip:set_notes({
    { pitch = 60, start = 0, length = 0.5 }, { pitch = 64, start = 0.5, length = 0.5 },
    { pitch = 67, start = 1, length = 1 }, { pitch = 72, start = 1, length = 1 },
    { pitch = 60, start = 2, length = 0.5 }, { pitch = 62, start = 3.1, length = 0.3 },
  })
  api.undo_checkpoint()
  keys("<CR>")
  local roll = daw.ui.views.pianoroll
  eq(roll.pitch .. "@" .. roll.beat, "60@0", "the roll opens on the first note")
  keys("w")
  eq(roll.pitch .. "@" .. roll.beat, "64@0.5", "w goes to the next note, whatever its pitch")
  keys("e")
  eq(roll.beat, 1, "e to where it ends")
  keys("b")
  eq(roll.pitch .. "@" .. roll.beat, "64@0.5", "b back to where it starts")
  keys("0dw")
  eq(melody(clip), "64@0.5+0.5 67@1+1 72@1+1 60@2+0.5 62@3.1+0.3", "dw deletes up to the next note")
  keys("u0d4l")
  eq(melody(clip), "67@1+1 72@1+1 60@2+0.5 62@3.1+0.3", "a stretch of time takes every pitch in it")
  keys("u")
  keys("wyinp")
  eq(melody(clip):match("64@1%S+"), "64@1+0.5", "yin and p repeat the note after itself")
  keys("u")
  eq(roll.pitch, 64, "the cursor is on the note that was repeated")
  keys("0<C-v>4kWd")
  eq(melody(clip), "60@0+0.5 72@1+1 60@2+0.5 62@3.1+0.3", "a block takes only the pitches it spans, E4 to G#4 here")
  keys("u")
  roll:set(60, 0)
  keys("Vd")
  eq(melody(clip), "64@0.5+0.5 67@1+1 72@1+1 62@3.1+0.3", "V and dd take whole pitches")
  keys("u")
  keys("$")
  eq(roll.beat, 4, "$ is the end of the clip")
  keys("0=ie")
  eq(melody(clip):match("%S+$"), "62@3+0.25", "= snaps notes to the grid")
  keys("0yibWP")
  eq(#clip:notes() .. " " .. melody(clip):match("60@4%S+"), "12 60@4+0.5", "a bar pasted at the next bar")
  eq(clip.length, 8, "and the clip grew to hold it")
  keys("0ggvee")
  keys("<C-a>")
  eq(melody(clip):sub(1, 21), "61@0+0.5 65@0.5+0.5 6", "<C-a> transposes the selected notes")
  keys("/c5<CR>")
  eq(roll.pitch .. "@" .. roll.beat, "72@1", "/ finds a note by its name")
  keys("glib")
  eq(daw.transport.loop_start .. "-" .. daw.transport.loop_end, "0-4", "gl loops the bar")
  daw.transport.loop_enabled = false
  keys("<C-w>c")
  eq(daw.ui.focused, "arrange", "<C-w>c closes the roll")
end)

test("devices are cut, yanked and pasted in the device panel", function()
  local t = three_clips()
  t:add_device("delay", { mix = 0.7 })
  local other = daw.add_track({ name = "U" })
  api.undo_checkpoint()
  daw.ui.focus("devices")
  local panel = daw.ui.views.devices
  panel.row = 1
  keys("yy")
  eq(daw.keymap.getreg().device.kind, "synth", "yy takes the device under the cursor")
  keys("p")
  local kinds = {}
  for i, d in ipairs(t:devices()) do kinds[i] = d.kind end
  eq(table.concat(kinds, " "), "synth synth delay", "p puts a copy after it")
  eq(t:devices()[2].params.cutoff, 900, "with its settings")
  keys("dd")
  eq(#t:devices(), 2, "dd cuts it")
  daw.cursor.set_track(other)
  keys("p")
  eq(other:devices()[1].params.cutoff, 900, "and p puts it on another track")
  daw.ui.hide("devices")
  daw.ui.focus("arrange")
end)

test("views draw without errors at several sizes", function()
  fresh()
  local t = tone("tone", 4)
  t:add_device("delay")
  for _, name in ipairs({ "mixer", "devices", "pianoroll" }) do daw.ui.show(name) end
  daw.ui.views.pianoroll:edit(t:clips()[1])
  for _, size in ipairs({ { 120, 40 }, { 80, 24 }, { 30, 8 }, { 4, 2 } }) do
    local rects = daw.ui.arrange(size[1], size[2])
    local total = 0
    for _, r in ipairs(rects) do
      eq(r.x >= 0 and r.y >= 0 and r.x + r.w <= size[1] and r.y + r.h <= size[2], true, r.name .. " fits the screen")
      -- A panel drawn over the others on a narrow screen is meant to overlap.
      if r.after ~= "box" then total = total + r.w * r.h end
    end
    eq(total <= size[1] * size[2], true, "views do not overlap")
  end
  for _, name in ipairs({ "mixer", "devices", "pianoroll" }) do daw.ui.hide(name) end
  daw.ui.focus("arrange")
end)

test("the screen draws what the project holds", function()
  fresh()
  local t = tone("Lead Synth", 4)
  t:add_device("delay")
  daw.cursor.set_track(t)
  local function screen(width, height) return table.concat(api.ui_snapshot(width, height), "\n") end
  local text = screen(100, 30)
  eq(text:find("Lead Synth", 1, true) ~= nil, true, "track name is on screen")
  eq(text:find("Master", 1, true) ~= nil, true, "master track is on screen")
  eq(text:find("120 bpm", 1, true) ~= nil, true, "status line shows the tempo")
  eq(text:find("render failed", 1, true), nil, "no view failed to draw")
  daw.ui.show("devices")
  daw.ui.show("mixer")
  daw.ui.views.pianoroll:edit(t:clips()[1])
  text = screen(140, 50)
  eq(text:find("cutoff", 1, true) ~= nil, true, "device panel lists parameters")
  eq(text:find("A3", 1, true) ~= nil, true, "piano roll shows note names")
  eq(text:find("traceback", 1, true), nil, "no view raised an error")
  -- Tiny screens must not raise either, and drawing garbage is collected safely.
  for _ = 1, 50 do screen(12, 4) end
  collectgarbage()
  collectgarbage()
  -- A broken view shows its error in place and leaves the others alone.
  daw.ui.view("status", { render = function() error("status is broken") end })
  text = screen(100, 30)
  eq(text:find("status is broken", 1, true) ~= nil, true, "the error is shown")
  eq(text:find("Lead Synth", 1, true) ~= nil, true, "other views still draw")
  package.loaded["daw.views.status"] = nil
  require("daw.views.status")
  for _, name in ipairs({ "mixer", "devices", "pianoroll" }) do daw.ui.hide(name) end
  daw.ui.focus("arrange")
end)

test("extensions load from a directory", function()
  local dir = scratch .. "/extensions"
  os.execute("mkdir -p '" .. dir .. "/hello/lua'")
  local function write(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
  end
  write(dir .. "/hello/lua/hello_lib.lua", "return { greeting = 'hi' }")
  write(dir .. "/hello/init.lua", "daw.command('hello', function() return require('hello_lib').greeting end)")
  write(dir .. "/single.lua", "daw.command('single', function() return 'one file' end)")
  write(dir .. "/broken.lua", "error('boom')")
  daw.ext.load_dir(dir)
  eq(daw.cmd("hello"), "hi", "directory extension with a module")
  eq(daw.cmd("single"), "one file", "single-file extension")
  eq(daw.ext.loaded.broken.ok, false, "a failing extension is recorded")
  eq(daw.ext.loaded.hello.ok, true, "and does not stop the others")
end)

-- Helper processes ------------------------------------------------------------

test("scripts run helper processes and talk to them over sockets", function()
  local log = scratch .. "/helper.log"
  local proc = api.proc_spawn({ "sh", "-c", "echo helper says hi; exit 3" }, { log = log })
  local deadline = api.now() + 5000
  while api.proc_status(proc).running and api.now() < deadline do api.sleep(5) end
  eq(api.proc_status(proc).code, 3, "exit code")
  eq(read_file(log):find("helper says hi", 1, true) ~= nil, true, "output goes to the log")
  api.proc_kill(proc)
  fails(function() api.proc_status(proc) end, "no process", "a process is forgotten once killed")

  local path = scratch .. "/sockets/helper.sock"
  local listener = api.sock_listen(path)
  eq(api.sock_accept(listener), nil, "nobody has connected yet")
  local client = api.sock_connect(path)
  local server = api.sock_accept(listener)
  eq(api.sock_read(server), "", "nothing has arrived yet")
  local chunk = string.rep("\0\1\2\255", 16384)
  local got, sent = {}, {}
  for _ = 1, 20 do
    api.sock_write(client, chunk)
    sent[#sent + 1] = chunk
    got[#got + 1] = api.sock_read(server)
  end
  local big = table.concat(sent)
  deadline = api.now() + 5000
  while #table.concat(got) < #big and api.now() < deadline do
    got[#got + 1] = api.sock_read(server)
  end
  eq(table.concat(got) == big, true, "bytes arrive unchanged, binary included")
  api.sock_close(client)
  eq(api.sock_read(server), nil, "nil once the other side closed")
  api.sock_close(server)
  api.sock_close(listener)
end)

-- Singing ---------------------------------------------------------------------
-- The `utau` device plays audio a script gives it; extensions/utau gets that
-- audio from reautau-engine. The tests that sing need the engine
-- (REAUTAU_ENGINE or reautau-engine on the PATH) and the voicebank below in
-- OpenUtau's folder, and are skipped without them.

local SINGER = os.getenv("REAUTAU_TEST_SINGER") or "Kitane sno act5 VCV"
local SYLLABLES = { "- あ", "- い", "- う", "- え", "- お" }

--- A sine of `freq` Hz lasting `seconds`, as the `put` call of the utau device takes it.
local function phrase(hash, start, freq, seconds)
  local ffi = require("ffi")
  local n = math.floor(seconds * 44100)
  local buf = ffi.new("float[?]", n)
  for i = 0, n - 1 do buf[i] = 0.5 * math.sin(2 * math.pi * freq * i / 44100) end
  return string.format("%s %.17g 44100 1 1\n", hash, start) .. ffi.string(buf, n * 4)
end

--- The pitch of the left channel of a 16-bit render between two times, by
--- autocorrelation: the shortest lag that correlates nearly as well as the best.
local function pitch(info, from, to)
  local data = read_file(info.path)
  local at = data:find("data", 1, true) + 8
  local rate = info.sample_rate
  local x = {}
  local first = at + math.floor(from * rate) * 4
  for i = 0, math.floor((to - from) * rate) - 1 do
    local lo, hi = data:byte(first + i * 4, first + i * 4 + 1)
    local v = lo + hi * 256
    if v >= 32768 then v = v - 65536 end
    x[i + 1] = v / 32768
  end
  local min_lag, max_lag = math.floor(rate / 1000), math.floor(rate / 60)
  local w = math.min(#x - max_lag - 1, 4096)
  local r = {}
  local best = 0
  for lag = min_lag, max_lag do
    local s, e1, e2 = 0, 0, 0
    for i = 1, w do
      local a, b = x[i], x[i + lag]
      s, e1, e2 = s + a * b, e1 + a * a, e2 + b * b
    end
    r[lag] = s / math.sqrt(e1 * e2 + 1e-12)
    best = math.max(best, r[lag])
  end
  for lag = min_lag + 1, max_lag - 1 do
    if r[lag] >= 0.9 * best and r[lag] >= r[lag - 1] and r[lag] >= r[lag + 1] then return rate / lag end
  end
end

local function midi_hz(note) return 440 * 2 ^ ((note - 69) / 12) end

test("the utau device plays the phrases it is given, in time", function()
  fresh()
  daw.project.tempo = 120
  local t = daw.add_track({ name = "Voice" })
  local voice = t:add_device("utau", { voice = 40 })
  t:add_clip({ start = 0, length = 8 })
  api.device_call(voice.id, "clear")
  api.device_call(voice.id, "put", phrase("11", 1.0, 330, 1.0))
  api.device_call(voice.id, "put", phrase("12", 2.5, 440, 0.5))
  eq(select(2, api.device_call(voice.id, "list"):gsub("\n", "")), 2, "two phrases")
  fails(function() api.device_call(voice.id, "put", "1 0 44100 1 1\n" .. "abc") end, "whole frames", "bad audio")
  fails(function() api.device_call(voice.id, "nothing") end, "no method", "unknown call")
  local info = render({ bits = 16, ["end"] = 8, tail = 0 })
  eq(channel_peaks(info, 0.1, 0.9) < 0.001, true, "silent before the first phrase")
  near(channel_peaks(info, 1.1, 1.9), 0.5, 0.02, "the first phrase plays at its time")
  near(frequency(info, 1.1, 1.9), 330, 5, "at its pitch")
  near(frequency(info, 2.55, 2.95), 440, 6, "the second at its own")
  eq(channel_peaks(info, 3.1, 3.9) < 0.001, true, "silent after")
  api.device_call(voice.id, "keep", "12")
  info = render({ bits = 16, ["end"] = 8, tail = 0 })
  eq(channel_peaks(info, 1.1, 1.9) < 0.001, true, "a phrase that is not kept is gone")
  -- In real time, too.
  daw.transport.seek(5)
  daw.transport.play()
  local loudest = 0
  local deadline = api.now() + 3000
  while daw.transport.position < 5.9 and api.now() < deadline do
    loudest = math.max(loudest, t:meter())
    api.sleep(5)
  end
  daw.transport.stop()
  eq(loudest > 0.2, true, "heard while playing")
  api.device_call(voice.id, "clear")
end)

local utau

local function load_utau()
  if not utau then
    daw.ext.load("extensions/utau")
    utau = require("utau")
  end
  if daw.opt.utau_openutau_dir == "" and not os.getenv("REAUTAU_OPENUTAU_DIR") then
    -- The suite may run with its own XDG_DATA_HOME; the voicebanks stay where they are.
    daw.opt.utau_openutau_dir = (os.getenv("HOME") or "") .. "/.local/share/OpenUtau"
  end
  return utau
end

--- A vocal track with a clip of `pitches`, a beat each, sung on SYLLABLES.
local function vocal(pitches)
  local track = daw.add_track({ name = "Vocal" })
  track:add_device("utau")
  local list = {}
  for i, p in ipairs(pitches) do
    list[i] = { pitch = p, start = i - 1, length = 1, meta = { lyric = SYLLABLES[(i - 1) % #SYLLABLES + 1] } }
  end
  local clip = track:add_clip({ start = 0, length = #pitches + 1, notes = list })
  return track, clip
end

--- Skip unless the engine runs and has the test voicebank.
local function need_singer()
  load_utau()
  if not utau.engine.find() then return "skipped: reautau-engine not found (set REAUTAU_ENGINE)" end
  utau.engine.start()
  if not utau.wait(function() return #utau.singers > 0 end, 60) then
    return "skipped: reautau-engine did not start: " .. tostring(utau.engine.reason)
  end
  if not utau.find_singer(SINGER) or utau.find_singer(SINGER).id ~= SINGER then
    return "skipped: voicebank " .. SINGER .. " is not installed"
  end
end

test("vocal tracks keep lyrics, properties and curves through undo and saving", function()
  fresh()
  load_utau()
  local notes = require("utau.notes")
  local track, clip = vocal({ 60, 62, 64 })
  local other = vocal({ 60 })
  daw.flush()
  local device = utau.device_of(track.id)
  local voice = api.device_get(device).params.voice
  eq(voice >= 1, true, "the device gets a voice of its own")
  eq(api.device_get(utau.device_of(other.id)).params.voice ~= voice, true, "each device its own")
  other:remove()
  utau.configure(track.id, { singer = "Someone", phonemizer = "Some.Phonemizer" })
  eq(utau.config(track.id).phonemizer, "Some.Phonemizer", "config")
  utau.configure(track.id, { singer = "Someone else" })
  eq(utau.config(track.id).phonemizer, nil, "a new singer starts from its own defaults")
  api.undo_checkpoint()
  notes.set_lyric(clip.id, 2, "ら")
  api.undo_checkpoint()
  notes.change_props(clip.id, function(p) p.vb = { 75, 175, 25, 10, 10, 0, 0, 0 }; return true end, { [1] = true })
  notes.bend(track.id, device, "pitd", 1.5, 50, 0.25)
  api.undo_checkpoint()
  eq(clip:notes()[2].meta.lyric, "ら", "lyric")
  eq(clip:notes()[1].meta.utau.vb[2], 175, "vibrato")
  eq(notes.curve_at(track.id, device, "pitd", 1.5), 50, "pitch bend")
  eq(notes.curve_at(track.id, device, "pitd", 1), 0, "only where it was bent")
  -- The engine sees all of it.
  local snap = utau.snapshot()
  eq(#snap.parts, 1, "one part")
  eq(snap.parts[1].notes[2].payload:find("ら", 1, true) ~= nil, true, "the lyric is in the payload")
  eq(snap.parts[1].notes[1].payload:find("vb", 1, true) ~= nil, true, "and the vibrato")
  local pitd
  for _, c in ipairs(snap.parts[1].curves) do
    if c.abbr == "pitd" then pitd = c end
  end
  local peak = 0
  for _, k in ipairs(pitd.knots) do peak = math.max(peak, k[2]) end
  eq(peak, 50, "and the curve")
  daw.undo()
  eq(notes.lane(track.id, device, "pitd"), nil, "undo takes the curve away")
  eq(clip:notes()[1].meta and clip:notes()[1].meta.utau, nil, "and the vibrato")
  eq(clip:notes()[2].meta.lyric, "ら", "but not the lyric before them")
  daw.undo()
  eq(clip:notes()[2].meta.lyric, "- い", "and then the lyric")
  daw.redo()
  daw.redo()
  local path = daw.project.save(scratch .. "/vocal.json")
  fresh()
  daw.project.load(path)
  track = daw.tracks()[1]
  device = utau.device_of(track.id)
  clip = track:clips()[1]
  eq(clip:notes()[2].meta.lyric, "ら", "the lyric is loaded")
  eq(clip:notes()[1].meta.utau.vb[1], 75, "the vibrato is loaded")
  eq(utau.config(track.id).singer, "Someone else", "the singer is loaded")
  eq(notes.lane(track.id, device, "pitd") ~= nil, true, "the curve is loaded")
  eq(notes.curve_at(track.id, device, "pitd", 1.5), 50, "with its points")
end)

test("lyrics are typed note by note, from text, and by batch edits", function()
  fresh()
  load_utau()
  local editor = require("utau.editor").editor
  local track, clip = vocal({ 60, 62, 64, 65 })
  daw.cursor.set_track(track)
  daw.cursor.set_beat(0)
  daw.ui.focus("arrange")
  daw.keymap.feed("<CR>")
  eq(daw.ui.focused, "utau", "Enter on a vocal clip opens the vocal editor")
  eq(editor.clip_id, clip.id, "on that clip")
  daw.keymap.feed("cka<Tab>ki<Tab>ku<Esc>")
  local function lyrics()
    local out = {}
    for i, n in ipairs(clip:notes()) do out[i] = n.meta and n.meta.lyric or "" end
    return table.concat(out, " ")
  end
  eq(lyrics(), "ka ki - う - え", "typing replaces the lyric, Tab keeps it and moves on, Esc drops it")
  daw.cmd("utau.lyrics", { "ra ri" })
  eq(lyrics(), "ka ki ra ri", "words fill the notes from the cursor on")
  daw.cmd("utau.batch", { "romaji_to_hiragana" })
  eq(lyrics(), "か き ら り", "a batch edit")
  daw.cmd("utau.batch", { "replace", find = "り", replace = "る" })
  eq(lyrics(), "か き ら る", "find and replace")
  daw.cmd("utau.preset", { "vib_pop" })
  eq(clip:notes()[1].meta.utau.vb[2], 150, "a tuning preset sets vibrato")
  daw.cmd("utau.preset", { "raspy" })
  local notes = require("utau.notes")
  eq(notes.curve_at(track.id, utau.device_of(track.id), "tenc", 1.5), 40, "and curves")
  local sheet = require("utau.lyrics")
  local text = sheet.sheet(clip.id)
  eq(text, "か き ら る", "the lyric sheet reads one line per phrase")
  eq(#sheet.tokens("きょうは", true), 3, "kana per note keeps small kana with the one before")
  daw.ui.hide("utau")
  daw.ui.focus("arrange")
end)

test("the vocal editor takes operators, and notes keep their lyrics", function()
  fresh()
  load_utau()
  local editor = require("utau.editor").editor
  local track, clip = vocal({ 60, 62, 64 })
  daw.cursor.set_track(track)
  daw.cursor.set_beat(0)
  daw.ui.focus("arrange")
  daw.keymap.feed("<Esc><CR>")
  local function sung()
    local notes = clip:notes()
    table.sort(notes, function(a, b) return a.start < b.start end)
    for i, n in ipairs(notes) do notes[i] = string.format("%s:%d@%g", n.meta and n.meta.lyric or "?", n.pitch, n.start) end
    return table.concat(notes, " ")
  end
  local first = clip:notes()[1].meta.lyric
  local before = sung()
  daw.keymap.feed("yin$P")
  eq(sung(), before .. " " .. first .. ":60@4", "a yanked note is pasted with its lyric")
  eq(clip.length, 5, "and the clip grows to hold it")
  daw.keymap.feed("0wdw")
  eq(#clip:notes(), 3, "dw deletes a note")
  daw.keymap.feed("0vWy")
  eq(#daw.keymap.getreg().notes, 2, "a selection yanks the notes in a bar")
  local second = clip:notes()[2]
  daw.keymap.feed("0/" .. second.meta.lyric .. "<CR>")
  eq(editor.pitch .. "@" .. editor.beat, second.pitch .. "@" .. second.start, "/ finds a note by its lyric")
  daw.keymap.feed("<Esc>")
  eq(daw.ui.focused, "utau", "Escape stays in the vocal editor")
  daw.keymap.feed("<C-w>p")
  eq(daw.ui.focused, "arrange", "Ctrl-w p goes back to the arrange view")
  daw.ui.hide("utau")
end)

test("the vocal editor paints itself in a window and is worked with the pointer", function()
  fresh()
  load_utau()
  local editor = require("utau.editor").editor
  local gui = require("utau.gui")
  local track, clip = vocal({ 60, 64 })
  -- Where a beat and a pitch are in the window (see utau/gui.lua).
  local function at(beat, pitch) return 64 + (beat - gui.scroll) * gui.zoom, 38 + 24 + (gui.top - pitch) * gui.row + gui.row / 2 end
  local function pointer(kind, beat, pitch, extra)
    local x, y = at(beat, pitch)
    daw.canvas.pointer("utau", daw.util.merge({ kind = kind, x = x, y = y, button = "left" }, extra or {}))
  end
  local function texts()
    local out = {}
    for _, op in ipairs(daw.canvas.paint("utau", 1100, 600).ops) do
      if op[1] == "t" then out[#out + 1] = op[4] end
    end
    return table.concat(out, "|")
  end

  daw.frontend.act.open_clip(clip.id)
  local windows = daw.frontend.state(-1).modal.windows
  eq(#windows .. " " .. (windows[1] and windows[1].name or ""), "1 utau", "a double click on a vocal clip opens the vocal editor's window")
  eq(daw.frontend.state(-1).modal.roll, nil, "and not the piano roll")
  local first = clip:notes()[1].meta.lyric
  eq(texts():find(first, 1, true) ~= nil, true, "the notes are painted with their lyrics")
  eq(texts():find("Notes", 1, true) ~= nil and texts():find("Pitch", 1, true) ~= nil, true, "with a toolbar")

  pointer("down", 2.1, 67)
  pointer("move", 2.9, 67)
  pointer("up", 2.9, 67)
  local notes = clip:notes()
  eq(#notes, 3, "a drag over empty space draws a note")
  eq(notes[3].pitch .. "@" .. notes[3].start .. "+" .. notes[3].length, "67@2+1", "on the grid, as long as the drag")

  pointer("down", 0.5, 60)
  pointer("move", 0.5, 62)
  pointer("up", 0.5, 62)
  local moved = clip:notes()[1]
  eq(moved.pitch .. "@" .. moved.start, "62@0", "a dragged note moves in time and pitch")
  eq(moved.meta.lyric, first, "and keeps its lyric")
  pointer("down", 1.97, 64)
  pointer("move", 1.45, 64)
  pointer("up", 1.45, 64)
  eq(clip:notes()[2].length, 0.5, "its right edge stretches it")

  pointer("double", 0.5, 62)
  eq(editor.entry ~= nil, true, "a double click starts typing the note's lyric")
  daw.keymap.feed("la<CR>")
  eq(clip:notes()[1].meta.lyric, "la", "which the keyboard finishes")

  -- The pitch tool, from its button in the toolbar.
  daw.canvas.paint("utau", 1100, 600)
  for _, b in ipairs(gui.buttons) do
    if b.label == "Pitch" then daw.canvas.pointer("utau", { kind = "down", x = b.x + 4, y = b.y + 4, button = "left" }) end
  end
  eq(gui.tool, "pitch", "a click on a toolbar button")
  pointer("down", 0.1, 62.3)
  pointer("move", 0.4, 62.6)
  pointer("move", 0.8, 62.2)
  pointer("up", 0.8, 62.2)
  local device = utau.device_of(track.id)
  local lane = require("utau.notes").lane(track.id, device, "pitd")
  eq(lane ~= nil and #api.lane_points(lane) >= 3, true, "the pitch tool draws how the pitch bends away from the note")
  pointer("down", 0.5, 62, { button = "right" })
  local flat = true
  for _, p in ipairs(api.lane_points(lane)) do
    if p[1] >= clip.start + 0.05 and p[1] <= clip.start + 0.95 and math.abs(p[2]) > 1 then flat = false end
  end
  eq(flat, true, "and a right click puts a note's pitch back")

  gui.tool = "notes"
  pointer("down", 2.5, 67, { button = "right" })
  eq(#clip:notes(), 2, "with the notes tool, a right click removes a note")
  local zoom = gui.zoom
  daw.canvas.pointer("utau", { kind = "wheel", x = 300, y = 300, dx = 0, dy = 60, ctrl = true })
  eq(gui.zoom > zoom, true, "the wheel with Ctrl zooms")
  daw.canvas.close("utau")
  eq(#daw.frontend.state(-1).modal.windows, 0, "closing the window")
  eq(daw.ui.focused, "arrange", "gives the keyboard back to the arrange view")
end)

test("the vocal editor shows notes, lyrics, phonemes, render state and the lyric sheet", function()
  fresh()
  load_utau()
  local editor = require("utau.editor").editor
  local track, clip = vocal({ 60, 64 })
  utau.configure(track.id, { singer = "Nobody" })
  editor:edit(clip.id)
  -- What the engine reports, as it would report it.
  utau.phonemes[clip.id] = { seq = 1, notes = { { { phoneme = "- あC4", alias = "", start = 0, stop = 480, flags = 0 } },
    { { phoneme = "xyz", alias = "", start = 480, stop = 960, flags = 1 } } } }
  utau.pitch[clip.id] = { step = 5, ticks = { [0] = 6000, [240] = 6000, [480] = 6390 } }
  daw.ui.show("utau_lyrics")
  local text = table.concat(api.ui_snapshot(120, 40), "\n")
  eq(text:find("Vocal  Nobody", 1, true) ~= nil, true, "the header names the track and singer")
  eq(table.concat(daw.ui.keybar.check(), ", "), "", "the keys the bottom line shows for it are all mapped")
  eq(text:find("C4   - あ", 1, true) ~= nil, true, "notes show their lyric on their row")
  -- The keyboard names the Cs and the cursor's pitch; E4 is four rows above C4.
  local lines = api.ui_snapshot(120, 40)
  for i, line in ipairs(lines) do
    if line:find("C4   - あ", 1, true) then
      eq(lines[i - 4]:find("│       - い", 1, true) ~= nil, true, "the second note too, four keys up")
    end
  end
  eq(text:find("phon - あC4  xyz", 1, true) ~= nil, true, "the phonemes are under the notes")
  eq(text:find("─", 1, true) ~= nil, true, "the sung pitch is drawn")
  eq(text:find("- あ - い", 1, true) ~= nil, true, "the lyric sheet")
  eq(text:find("traceback", 1, true), nil, "no view raised an error")
  daw.ui.hide("utau_lyrics")
  daw.ui.hide("utau")
  daw.ui.focus("arrange")
  utau.phonemes[clip.id], utau.pitch[clip.id] = nil, nil
end)

-- The vocal editor's window, worked as the pointer works it: `win.at(beat,
-- pitch)` is where a beat and a pitch are, `win.press(kind, x, y, extra)`
-- passes an event at a place of the window.
local function vocal_window(pitches)
  fresh()
  load_utau()
  local editor = require("utau.editor").editor
  local gui = require("utau.gui")
  local track, clip = vocal(pitches)
  daw.flush()
  daw.frontend.act.open_clip(clip.id)
  gui.tool, gui.curves, gui.inspector = "notes", true, true
  local win = { editor = editor, gui = gui, track = track, clip = clip }
  function win.paint() return daw.canvas.paint("utau", 1180, 620) end
  function win.at(beat, pitch)
    return 64 + (beat - gui.scroll) * gui.zoom, 38 + 24 + (gui.top - pitch) * gui.row + gui.row / 2
  end
  function win.press(kind, x, y, extra)
    daw.canvas.pointer("utau", daw.util.merge({ kind = kind, x = x, y = y, button = "left" }, extra or {}))
  end
  function win.note(kind, beat, pitch, extra)
    local x, y = win.at(beat, pitch)
    win.press(kind, x, y, extra)
  end
  --- Drag from one place to another, in a few steps.
  function win.drag(x0, y0, x1, y1, extra)
    win.press("down", x0, y0, extra)
    for i = 1, 4 do win.press("move", x0 + (x1 - x0) * i / 4, y0 + (y1 - y0) * i / 4, extra) end
    win.press("up", x1, y1, extra)
  end
  function win.button(label)
    win.paint()
    for _, b in ipairs(gui.buttons) do
      if b.label:sub(1, #label) == label then return win.press("down", b.x + 4, b.y + 4) end
    end
    error("no button " .. label)
  end
  function win.close()
    if editor.entry then editor:close_entry() end
    daw.canvas.close("utau")
    daw.ui.hide("utau")
    daw.ui.focus("arrange")
  end
  return win
end

local function shape_of(clip)
  local out = {}
  for i, n in ipairs(clip:notes()) do
    out[i] = string.format("%s:%d@%g+%g", n.meta and n.meta.lyric or "?", n.pitch, n.start, n.length)
  end
  return table.concat(out, " ")
end

test("the vocal editor's window selects several notes, and moves, stretches, copies and deletes them", function()
  local win = vocal_window({ 60, 62, 64, 65 })
  local editor, clip = win.editor, win.clip
  local x0, y0 = win.at(0.2, 66)
  local x1, y1 = win.at(2.5, 61)
  win.drag(x0, y0, x1, y1, { ctrl = true })
  eq(#editor:selected(), 2, "a box drawn with Ctrl over empty space selects the notes in it")
  win.note("down", 0.5, 60, { shift = true })
  win.note("up", 0.5, 60, { shift = true })
  eq(table.concat(editor:selected(), ","), "1,2,3", "Shift+click adds a note")
  win.paint()
  eq(win.gui.S.selected[1] and win.gui.S.selected[3] and not win.gui.S.selected[4], true, "selected notes are painted as such")
  local xa, ya = win.at(1.5, 62)
  local xb, yb = win.at(1.5, 63)
  win.drag(xa, ya, xb, yb)
  eq(shape_of(clip), "- あ:61@0+1 - い:63@1+1 - う:65@2+1 - え:65@3+1", "dragging one moves them all, with their lyrics")
  local xe, ye = win.at(1.98, 63)
  local xf = win.at(1.48, 63)
  win.drag(xe, ye, xf, ye)
  eq(shape_of(clip), "- あ:61@0+0.5 - い:63@1+0.5 - う:65@2+0.5 - え:65@3+1", "its right edge stretches them all")
  daw.keymap.feed("<C-c>")
  editor.beat = 5
  daw.keymap.feed("<C-v>")
  eq(#clip:notes(), 7, "Ctrl+C copies them and Ctrl+V pastes them at the cursor")
  eq(shape_of(clip):find("- あ:61@5+0.5 - い:63@6+0.5 - う:65@7+0.5", 1, true) ~= nil, true, "keeping pitches, lyrics and spacing")
  eq(#editor:selected(), 3, "the pasted notes are selected")
  daw.keymap.feed("x")
  eq(#clip:notes(), 4, "x removes the selection")
  daw.canvas.key("utau", "<C-a>")
  eq(#editor:selected(), 4, "Ctrl+A in its window selects every note")
  daw.keymap.feed("<Esc>")
  eq(#editor:selected() .. daw.ui.focused, "0utau", "Escape forgets the selection first")
  -- Visual mode in the keys is the same selection.
  editor.pitch, editor.beat = 61, 0
  daw.keymap.feed("vW")
  eq(#editor:selected(), 4, "a visual selection selects the notes in it")
  win.paint()
  eq(win.gui.S.selected[1] == true, true, "and the window shows them selected")
  daw.keymap.feed("<Esc>")
  win.close()
end)

test("the vocal editor selects a phrase, from the window and with a text object", function()
  local win = vocal_window({ 60, 62, 64, 65, 67 })
  local editor, clip = win.editor, win.clip
  require("utau.notes").set_lyric(clip.id, 3, "R")
  win.note("double", 0.5, 70)
  eq(table.concat(editor:selected(), ","), "1,2", "a double click on empty space selects the phrase there")
  win.note("double", 3.5, 70)
  eq(table.concat(editor:selected(), ","), "4,5", "a rest ends a phrase")
  daw.keymap.feed("<Esc>")
  editor.pitch, editor.beat = 60, 0
  daw.keymap.feed("yip")
  eq(#daw.keymap.getreg().notes, 2, "`ip` is the phrase at the cursor")
  win.close()
end)

test("the vocal editor draws and erases expression curves under the notes", function()
  local win = vocal_window({ 60, 62, 64 })
  local editor, track, clip = win.editor, win.track, win.clip
  local notes = require("utau.notes")
  local device = utau.device_of(track.id)
  win.paint()
  eq(win.gui.S.curve.info.key, "pitd", "the panel starts on the pitch")
  win.button("Dynamics")
  win.paint()
  eq(editor.curve .. " " .. win.gui.S.curve.info.key, "dyn dyn", "a tab chooses the curve")
  local S = win.gui.S.curve
  local function y_for(v) return S.top + (1 - (v - S.info.min) / (S.info.max - S.info.min)) * S.h end
  local xa = win.at(0.2, 60)
  local xb = win.at(2.6, 60)
  win.drag(xa, y_for(60), xb, y_for(60))
  local lane = notes.lane(track.id, device, "dyn")
  eq(lane ~= nil, true, "drawing makes the curve's lane on the device's parameter")
  near(notes.curve_at(track.id, device, "dyn", 1.5), 60, 3, "with the value drawn")
  near(notes.curve_at(track.id, device, "dyn", 2.9), 0, 1e-6, "and only where it was drawn")
  local xc, xd = win.at(1, 60), win.at(2, 60)
  win.drag(xc, y_for(0), xd, y_for(0), { button = "right" })
  near(notes.curve_at(track.id, device, "dyn", 1.5), 0, 1e-6, "a right drag puts it back to its default")
  near(notes.curve_at(track.id, device, "dyn", 0.5), 60, 3, "there only")
  -- A frontend may pass a right drag on as its press and its release only.
  win.press("down", win.at(0.25, 60), y_for(0), { button = "right" })
  win.press("up", win.at(0.45, 60), y_for(0), { button = "right" })
  near(notes.curve_at(track.id, device, "dyn", 0.35), 0, 1e-6, "a right drag is erased from its press to its release")
  near(notes.curve_at(track.id, device, "dyn", 0.6), 60, 3, "and no further")
  eq(notes.curve_at(track.id, device, "pitd", 1.5), 0, "other curves are left alone")
  -- In the terminal: the chosen curve under the notes, raised at the cursor.
  daw.ui.focus("utau")
  editor.curve, editor.beat, editor.pitch = "pitd", 2, 64
  daw.keymap.feed("]c]c")
  eq(editor.curve, "tenc", "]c shows the next curve")
  daw.keymap.feed("3}")
  eq(notes.curve_at(track.id, device, "tenc", clip.start + 2), 15, "} raises it at the cursor")
  local text = table.concat(api.ui_snapshot(120, 40), "\n")
  eq(text:find("tenc", 1, true) ~= nil and text:find("15", 1, true) ~= nil, true, "the terminal shows the curve and its value at the cursor")
  eq(text:find("⣀", 1, true) ~= nil or text:find("⠤", 1, true) ~= nil or text:find("⣿", 1, true) ~= nil or text:match("[\226][\160-\163]") ~= nil, true, "drawn in braille under the notes")
  daw.keymap.feed("=")
  eq(notes.curve_at(track.id, device, "tenc", clip.start + 2), 0, "= puts it back under the note")
  win.close()
end)

test("the vocal editor edits transition points and vibrato with the pointer", function()
  local win = vocal_window({ 60, 64, 62 })
  local editor, clip, gui = win.editor, win.clip, win.gui
  local shapes = require("utau.shapes")
  gui.tool = "pitch"
  gui.zoom = 240
  win.paint()
  local function handle(list, fn)
    for _, h in ipairs(gui.S[list]) do
      if fn(h) then return 64 + h.x, 62 + h.y end
    end
  end
  -- The second note's transition: two points by default, the first at the note before.
  local hx, hy = handle("pp_handles", function(h) return h.index == 2 and h.k == 2 end)
  eq(hx ~= nil, true, "each note shows its transition points")
  win.drag(hx, hy, hx + 30, hy - 9)
  local pp = clip:notes()[2].meta.utau.pp
  eq(pp ~= nil and #pp.pts, 2, "dragging a point gives the note a transition of its own")
  eq(pp.pts[2][1] > 60 and pp.pts[2][2] > 0, true, "the point went later and up")
  win.note("double", 1.3, 64.5)
  eq(#clip:notes()[2].meta.utau.pp.pts, 3, "a double click on a note adds a point")
  local added
  for _, p in ipairs(clip:notes()[2].meta.utau.pp.pts) do
    if p[1] > 100 then added = p end
  end
  near(added and added[2] or 0, 5, 0.6, "where the pointer is: half a semitone up is 5 tenths")
  win.paint()
  hx, hy = handle("pp_handles", function(h) return h.index == 2 and h.k == 2 end)
  win.press("down", hx, hy, { ctrl = true })
  win.press("up", hx, hy, { ctrl = true })
  eq(clip:notes()[2].meta.utau.pp.pts[2][3], 1, "Ctrl+click changes how the line leaves a point")
  win.press("down", hx, hy, { button = "right" })
  eq(#clip:notes()[2].meta.utau.pp.pts, 2, "a right click removes a point")
  -- Drawn pitch is measured from the middle of the note's row.
  local x0, y0 = win.at(0.4, 61)
  local x1 = win.at(0.7, 61)
  win.drag(x0, y0, x1, y0)
  local notes_ = require("utau.notes")
  near(notes_.curve_at(win.track.id, utau.device_of(win.track.id), "pitd", 0.55), 100, 6, "a line drawn a row above a note bends it up a semitone")
  -- Vibrato: Ctrl+click switches it on, its handles change it.
  win.note("down", 2.5, 62, { ctrl = true })
  win.note("up", 2.5, 62, { ctrl = true })
  eq(shapes.vb(clip:notes()[3]) ~= nil, true, "Ctrl+click a note switches its vibrato on")
  win.paint()
  hx, hy = handle("vb_handles", function(h) return h.which == "depth" end)
  eq(hx ~= nil, true, "its handles show")
  win.drag(hx, hy, hx, hy - gui.row / 2)
  near(shapes.vb(clip:notes()[3])[3], 75, 1, "the depth handle sets the depth")
  win.paint()
  hx, hy = handle("vb_handles", function(h) return h.which == "length" end)
  win.drag(hx, hy, hx - gui.zoom * 0.25, hy)
  near(shapes.vb(clip:notes()[3])[1], 100, 0.5, "the start handle the length")
  win.paint()
  hx, hy = handle("vb_handles", function(h) return h.which == "period" end)
  local before = shapes.vb(clip:notes()[3])[2]
  win.drag(hx, hy, hx + 20, hy)
  eq(shapes.vb(clip:notes()[3])[2] > before, true, "the period handle the period")
  for _, which in ipairs({ "in", "out", "shift", "drift" }) do
    eq(handle("vb_handles", function(h) return h.which == which end) ~= nil, true, "and there is a handle for " .. which)
  end
  win.note("down", 2.5, 62, { ctrl = true })
  win.note("up", 2.5, 62, { ctrl = true })
  eq(shapes.vb(clip:notes()[3]), nil, "Ctrl+click again switches it off")
  win.close()
end)

test("the vocal editor moves and replaces phonemes, in the window and with keys", function()
  local win = vocal_window({ 60, 62 })
  local editor, clip, gui = win.editor, win.clip, win.gui
  utau.phonemes[clip.id] = { seq = 1, notes = {
    { { phoneme = "- あ", alias = "", start = 0, stop = 480, flags = 0 } },
    { { phoneme = "a", alias = "", start = 400, stop = 480, flags = 0 }, { phoneme = "い", alias = "", start = 480, stop = 960, flags = 1 } },
  } }
  win.paint()
  local box
  for _, b in ipairs(gui.S.phoneme_boxes) do
    if b.note == 2 and b.k == 2 then box = b end
  end
  local y = gui.geo.ph_y + 15
  win.drag(64 + box.x0, y, 64 + box.x0 + gui.zoom * 0.25, y)
  local ph = clip:notes()[2].meta.utau.ph
  eq(ph and ph[1].index .. ":" .. ph[1].offset, "1:120", "dragging a phoneme's start sets its offset, in ticks")
  win.press("double", 64 + box.x0 + 20, y)
  eq(editor.entry and editor.entry.kind, "phoneme", "a double click types the phoneme")
  daw.keymap.feed("<C-u>xi<CR>")
  eq(clip:notes()[2].meta.utau.ph[1].phoneme, "xi", "which is then sung instead")
  win.press("down", 64 + box.x0 + 20, y, { button = "right" })
  eq(clip:notes()[2].meta.utau, nil, "a right click puts it back")
  -- The keys: ( and ) choose a phoneme, [ and ] move it, gr types it.
  daw.ui.focus("utau")
  editor.pitch, editor.beat, editor.ph = 62, 1, nil
  daw.keymap.feed(")")
  daw.keymap.feed(")")
  eq(editor.ph.note .. ":" .. editor.ph.k, "2:2", ") goes on to the next phoneme")
  daw.keymap.feed("2])")
  eq(clip:notes()[2].meta.utau.ph[1].offset, 10, "] starts it later")
  daw.keymap.feed("grya<CR>")
  eq(clip:notes()[2].meta.utau.ph[1].phoneme, "ya", "gr types the phoneme to sing")
  local text = table.concat(api.ui_snapshot(120, 40), "\n")
  eq(text:find("[a (!い)]", 1, true) ~= nil, true, "the chosen phoneme is marked in the terminal")
  daw.keymap.feed("gR")
  eq(clip:notes()[2].meta.utau, nil, "gR puts it back")
  daw.keymap.feed("(")
  eq(editor.ph.k, 1, "( goes back")
  utau.phonemes[clip.id] = nil
  win.close()
end)

test("the vocal editor's inspector sets properties of every selected note", function()
  local win = vocal_window({ 60, 62, 64 })
  local editor, clip, gui = win.editor, win.clip, win.gui
  utau.phonemizers = { { id = "OpenUtau.Plugin.Builtin.JapaneseVCVPhonemizer", name = "JA VCV", tag = "JA VCV" } }
  editor:select({ 1, 2 })
  win.paint()
  local function field(label)
    win.paint()
    for _, f in ipairs(gui.fields) do
      if f.field.label == label then return f.x + 10, f.y + 8 end
    end
    error("no field " .. label)
  end
  local fx, fy = field("Tuning")
  win.drag(fx, fy, fx + 20, fy)
  local n = clip:notes()
  eq((n[1].meta.utau or {}).tu .. " " .. (n[2].meta.utau or {}).tu, "20 20", "a value dragged goes to every selected note")
  eq(n[3].meta.utau, nil, "and no other")
  win.press("down", fx, fy)
  win.press("up", fx, fy)
  eq(editor.entry and editor.entry.kind, "field", "a click types the value")
  daw.keymap.feed("<C-u>-15<CR>")
  n = clip:notes()
  eq(n[1].meta.utau.tu .. " " .. n[2].meta.utau.tu, "-15 -15", "which goes to all of them")
  fx, fy = field("Vibrato")
  win.press("down", fx, fy)
  eq(require("utau.shapes").vb(clip:notes()[2]) ~= nil, true, "the vibrato switch")
  fx, fy = field("Depth")
  win.drag(fx, fy, fx + 10, fy)
  eq(clip:notes()[1].meta.utau.vb[3] .. " " .. clip:notes()[2].meta.utau.vb[3], "35 35", "and its numbers")
  fx, fy = field("Phonemizer")
  win.press("down", fx, fy)
  eq(gui.popup ~= nil, true, "the phonemizer opens a list")
  win.paint()
  win.press("down", gui.popup.left + 20, gui.popup.y + 6 + 20 + 5)
  eq(clip:notes()[1].meta.utau.po, "OpenUtau.Plugin.Builtin.JapaneseVCVPhonemizer", "a phonemizer for these notes")
  fx, fy = field("Velocity")
  win.drag(fx, fy, fx + 30, fy)
  local ex = clip:notes()[2].meta.utau.ex
  eq(ex and ex[1][1] .. "=" .. ex[1][2], "vel=130", "a per-note expression")
  fx, fy = field("Tuning")
  win.press("down", fx, fy, { button = "right" })
  eq(clip:notes()[1].meta.utau.tu, nil, "a right click puts a value back")
  fx, fy = field("Lyric")
  win.press("down", fx, fy)
  daw.keymap.feed("<C-u>")
  editor:entry_key("la li", true)
  daw.keymap.feed("<CR>")
  eq(clip:notes()[1].meta.lyric .. " " .. clip:notes()[2].meta.lyric, "la li", "several words go to the notes in order")
  -- The same from the command line.
  daw.cmd("utau.note", { tuning = "7", depth = "40" })
  eq(clip:notes()[1].meta.utau.tu .. " " .. clip:notes()[2].meta.utau.vb[3], "7 40", "`utau.note` sets them too")
  utau.phonemizers = {}
  win.close()
end)

test("the vocal editor plays notes as they are placed, follows the playhead, and plays from the cursor", function()
  local win = vocal_window({ 60, 62 })
  local editor, clip, gui = win.editor, win.clip, win.gui
  local audition = require("utau.audition")
  audition.last, audition.heard, audition.error = 0, {}, nil
  win.note("down", 2.1, 67)
  win.note("up", 2.1, 67)
  eq(#clip:notes(), 3, "a note placed")
  eq(audition.heard[#audition.heard], "tone", "is heard, as a tone without the engine")
  eq(audition.error, nil, "through the vocal device")
  clip.length = 64
  daw.keymap.feed("<Space>")
  eq(daw.transport.playing, true, "Space plays")
  near(daw.transport.position, clip.start + editor.beat, 1e-6, "from the cursor")
  daw.transport.seek(40)
  win.paint()
  eq(gui.scroll > 30, true, "the window follows the playhead")
  daw.keymap.feed("<Space>")
  eq(daw.transport.playing, false, "Space again stops")
  win.close()
end)

test("OpenUtau projects import as vocal tracks", function()
  fresh()
  load_utau()
  if not utau.engine.find() then return "skipped: reautau-engine not found (set REAUTAU_ENGINE)" end
  local ok, ids = pcall(require("utau.import").file, fixtures .. "vocal.ustx")
  eq(ok, true, "imported: " .. tostring(ids))
  local track = daw.track(ids[1])
  eq(track.name, "Imported vocal", "a vocal track per OpenUtau track")
  eq(utau.config(track.id).singer, "Kitane sno act5 VCV", "with its singer")
  eq(daw.project.tempo, 100, "the tempo")
  local clip = track:clips()[1]
  eq(clip.start .. "/" .. clip.length, "2/5", "a clip per part")
  local notes = clip:notes()
  eq(#notes, 3, "notes")
  eq(notes[2].meta.lyric .. "/" .. notes[2].start .. "/" .. notes[2].length .. "/" .. notes[2].pitch, "- い/1/2/64", "a note")
  eq(notes[1].meta.utau.tu, 15, "tuning")
  eq(notes[2].meta.utau.vb[1], 60, "vibrato")
  local n = require("utau.notes")
  eq(n.curve_at(track.id, utau.device_of(track.id), "dyn", 3), -60, "curves become lanes")
end)

test("a phrase with lyrics is sung at the notes' pitch, and offline renders wait for it", function()
  fresh()
  local why = need_singer()
  if why then return why end
  daw.project.tempo = 120
  local track, clip = vocal({ 57, 60, 64 })
  utau.configure(track.id, { singer = SINGER })
  -- Rendering waits until the singing is final, so no waiting here.
  local info = render({ bits = 16, tail = 0 })
  eq(utau.rendered(track.id), true, "the render waited for the engine")
  eq(channel_peaks(info, 0.1, 0.4) > 0.05, true, "the vocal is in the render")
  for i, note in ipairs({ 57, 60, 64 }) do
    local f = pitch(info, (i - 1) * 0.5 + 0.15, (i - 1) * 0.5 + 0.45)
    near(f or 0, midi_hz(note), midi_hz(note) * 0.03, "note " .. i .. " is sung at its pitch")
  end
  -- The same project renders the same audio.
  local again = render({ bits = 16, tail = 0 })
  eq(read_file(again.path) == read_file(info.path), true, "offline renders are deterministic")
  -- And it plays in real time.
  daw.transport.seek(0)
  daw.transport.play()
  local loudest, deadline = 0, api.now() + 3000
  while daw.transport.position < 1.5 and api.now() < deadline do
    loudest = math.max(loudest, track:meter())
    api.sleep(5)
  end
  daw.transport.stop()
  eq(loudest > 0.05, true, "heard while playing")
  require("utau.editor").editor:edit(clip.id)
  local text = table.concat(api.ui_snapshot(100, 30), "\n")
  eq(text:find("ready", 1, true) ~= nil, true, "the editor says the track is rendered")
  eq(text:find("- あ", 1, true) ~= nil, true, "and shows phonemes from the voicebank")
  daw.ui.hide("utau")
  daw.ui.focus("arrange")
end)

test("changing a lyric or a note sings it again", function()
  fresh()
  local why = need_singer()
  if why then return why end
  daw.project.tempo = 120
  local track, clip = vocal({ 60, 60 })
  local device = utau.device_of(track.id)
  utau.configure(track.id, { singer = SINGER })
  local function hashes()
    eq(utau.finish(120), true, "the engine finished")
    local out = {}
    for line in api.device_call(device, "list"):gmatch("[^\n]+") do out[#out + 1] = line:match("^%S+") end
    table.sort(out)
    return table.concat(out, " ")
  end
  local first = hashes()
  eq(first ~= "", true, "phrases are with the device")
  local notes = require("utau.notes")
  notes.set_lyric(clip.id, 2, "- お")
  daw.flush()
  local second = hashes()
  eq(second ~= first, true, "a new lyric is sung again")
  local list = clip:notes()
  list[2].pitch = 67
  clip:set_notes(list)
  daw.flush()
  eq(hashes() ~= second, true, "so is a new pitch")
  local info = render({ bits = 16, tail = 0 })
  near(pitch(info, 0.65, 0.95) or 0, midi_hz(67), midi_hz(67) * 0.03, "at the new pitch")
end)

-- More tests ----------------------------------------------------------------
--
-- An extension keeps its tests beside it in `extensions/<name>/tests.lua`, and
-- a feature of the runtime may keep them in `tests/<name>.lua`. Each such file
-- is a function of one table, the helpers above:
--
--   local T = ...
--   T.test("the widget counts", function() T.fresh() T.eq(1 + 1, 2, "sum") end)

-- What a test asks to have undone when it ends, passed or failed, so that
-- a failure does not leave a setting behind for the tests after it.
local cleanups = {}
local function after(fn) cleanups[#cleanups + 1] = fn end

local T = {
  test = test, after = after, eq = eq, near = near, fails = fails, fresh = fresh, render = render, tone = tone,
  scratch = scratch, read_file = read_file, write_file = write_file, frequency = frequency,
  channel_peaks = channel_peaks, three_clips = three_clips, layout = layout, melody = melody, keys = keys,
}
local files = {}
for _, entry in ipairs(api.read_dir("tests")) do
  if not entry.is_dir and entry.name:match("%.lua$") and entry.name ~= "suite.lua" then
    files[#files + 1] = "tests/" .. entry.name
  end
end
for _, entry in ipairs(api.read_dir("extensions")) do
  local path = "extensions/" .. entry.name .. "/tests.lua"
  if entry.is_dir and io.open(path) then files[#files + 1] = path end
end
for _, path in ipairs(files) do assert(loadfile(path))(T) end

-- Run ------------------------------------------------------------------------

local only = ...
for _, t in ipairs(tests) do
  if not only or t.name:find(only, 1, true) then
    local ok, err = xpcall(t.fn, debug.traceback)
    for i = #cleanups, 1, -1 do pcall(cleanups[i]) cleanups[i] = nil end
    if ok and type(err) == "string" then
      print("skip  " .. t.name .. " (" .. err .. ")")
    elseif ok then
      print("ok    " .. t.name)
    else
      failed = failed + 1
      print("FAIL  " .. t.name .. "\n      " .. tostring(err):gsub("\n", "\n      "))
    end
  end
end
os.execute("rm -rf '" .. scratch .. "'")
print(failed == 0 and "\nall passed" or ("\n" .. failed .. " failed"))
api.quit(failed == 0 and 0 or 1)
