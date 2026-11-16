-- Tests of controller learn, markers and regions, takes and loop recording,
-- automation modes, and long files played from the disk. Loaded by
-- tests/suite.lua with its helpers.
local T = ...
local test, eq, near, fails, fresh, render = T.test, T.eq, T.near, T.fails, T.fresh, T.render
local api = daw.api

local function start()
  fresh()
  api.engine_restart({ backend = "null" })
  daw.keymap.feed("<Esc><Esc>")
  while daw.ui.float do daw.ui.close() end
  daw.ui.focus("arrange")
end

local function with_input(fn)
  api.engine_restart({ backend = "null", test_input = { frequency = 440, level = -12, channels = 2 } })
  local ok, err = xpcall(fn, debug.traceback)
  api.engine_restart({ backend = "null" })
  if not ok then error(err, 0) end
end

--- A controller moved to `value` (0 to 1), as a turn of its own.
local function cc(number, value, channel)
  daw.midi.inject({ type = "cc", number = number, value = value, channel = channel or 1 })
  daw.flush()
  api.undo_checkpoint()
end

local function param(device, key)
  for _, p in ipairs(api.device_get(device).param_info) do
    if p.key == key then return p end
  end
end

-- Controller learn -------------------------------------------------------------

test("a controller learns what was moved last, and then moves it", function()
  start()
  local t = daw.add_track({ name = "Lead" })
  local d = t:add_device("synth")
  local p = param(d.id, "attack")
  api.device_set_param(d.id, "attack", p.min)
  daw.flush()
  eq(daw.learn.last.param, "attack", "the parameter moved last is known")
  daw.cmd("learn")
  eq(daw.learn.learning ~= nil, true, "waiting for the controller")
  cc(74, 0.5)
  eq(daw.learn.learning, nil, "its first move binds it")
  local b = daw.learn.bindings()[1]
  eq(b.source .. " " .. b.number .. " " .. b.channel .. " " .. b.param, "cc 74 1 attack", "the binding")
  eq(daw.learn.target_name(b), "Lead › " .. d.name .. " › " .. p.name, "in words")
  cc(74, 1)
  near(api.device_get(d.id).params.attack, p.max, 1e-6, "all the way up")
  cc(74, 0)
  near(api.device_get(d.id).params.attack, p.min, 1e-6, "and down")
  cc(74, 0.5, 2)
  near(api.device_get(d.id).params.attack, p.min, 1e-6, "another channel's controller is another controller")
  cc(75, 1)
  near(api.device_get(d.id).params.attack, p.min, 1e-6, "and so is another number")
end)

test("a bound controller takes hold of a fader only when it reaches it", function()
  start()
  local t = daw.add_track({ name = "Bass" })
  daw.learn.bind({ cc = 7, channel = 1 }, { track = t.id, target = "volume" })
  t.volume = -27 -- the middle of the fader's travel
  daw.flush()
  cc(7, 0.9)
  eq(t.volume, -27, "far from the fader, it does not move it")
  cc(7, 0.8)
  eq(t.volume, -27, "nor on the way")
  cc(7, 0.4)
  near(t.volume, -60 + 66 * 0.4, 1e-6, "once it has passed the fader it has hold of it")
  cc(7, 0.2)
  near(t.volume, -60 + 66 * 0.2, 1e-6, "and moves it")
  cc(7, 0)
  eq(t.volume, -120, "the bottom is silence")
  t.volume = 0
  daw.flush()
  cc(7, 0.1)
  eq(t.volume, 0, "moved by hand since, the fader has to be caught again")
  daw.opt.learn_pickup = false
  cc(7, 0.5)
  near(t.volume, -27, 1e-6, "without pickup the fader jumps to the control")
  daw.opt.learn_pickup = true
  -- Pan, by a word; one binding per target.
  daw.cursor.set_track(t)
  daw.cmd("learn", { "pan" })
  cc(10, 0.5)
  cc(10, 1)
  eq(t.pan, 1, "pan hard right")
  cc(10, 64 / 127)
  eq(t.pan, 0, "the middle of a knob is the middle")
  daw.cmd("learn", { "pan" })
  cc(11, 0.3)
  eq(#daw.learn.bindings(), 2, "learning a target again replaces what moved it")
  daw.cmd("learn.remove", { "pan" })
  eq(#daw.learn.bindings(), 1, "a binding is taken away by what it moves")
  fails(function() daw.learn.bind({ cc = 200 }, { track = t.id, target = "volume" }) end, "0 to 127", "a bad controller number")
end)

test("a sweep of a control is one undo step, and bindings are saved with the project", function()
  start()
  local t = daw.add_track({ name = "Pad" })
  t.volume = -27
  api.undo_checkpoint()
  daw.learn.bind({ cc = 7 }, { track = t.id, target = "volume" })
  api.undo_checkpoint()
  for _, v in ipairs({ 0.5, 0.55, 0.6, 0.65, 0.7 }) do cc(7, v) end
  near(t.volume, -60 + 66 * 0.7, 1e-6, "swept up")
  daw.undo()
  eq(t.volume, -27, "one undo takes the whole sweep back")
  eq(#daw.learn.bindings(), 1, "and leaves the binding")
  daw.redo()
  near(t.volume, -60 + 66 * 0.7, 1e-6, "one redo brings it back")
  -- Two commands on the same fader are two steps.
  daw.cursor.set_track(t)
  daw.cmd("track.volume", { -3 })
  api.undo_checkpoint()
  daw.cmd("track.volume", { -9 })
  api.undo_checkpoint()
  daw.undo()
  eq(t.volume, -3, "commands are undone one at a time")
  local path = T.scratch .. "/learn.json"
  daw.project.save(path)
  daw.project.new()
  eq(#daw.learn.bindings(), 0, "a new project has none")
  daw.project.load(path)
  eq(#daw.learn.bindings(), 1, "they come back with the project")
  daw.cmd("learn.clear")
  eq(#daw.learn.bindings(), 0, "cleared")
end)

-- Markers and regions ------------------------------------------------------------

test("markers and regions are placed, found, moved and undone", function()
  start()
  local markers = daw.markers
  eq(#markers.list(), 0, "none to begin with")
  local chorus = markers.add(16, "Chorus")
  local intro = markers.add(0, "Intro", { length = 8 })
  markers.add(8, "")
  api.undo_checkpoint()
  local names = {}
  for i, m in ipairs(markers.list()) do names[i] = markers.label(m) .. "@" .. m.beat end
  eq(table.concat(names, " "), "Intro@0 2@8 Chorus@16", "in order of time; one without a name goes by its number")
  eq(markers.find("chorus").id, chorus.id, "found by name, whatever the case")
  eq(markers.find(1).id, intro.id, "by number")
  eq(markers.find("Cho").id, chorus.id, "by the start of a name")
  eq(#markers.regions(), 1, "one of them is a region")
  eq(markers.next(0).beat .. " " .. markers.prev(16).beat, "8 8", "the next and the one before")
  eq(markers.at(4).id, intro.id, "inside a region is at it")
  markers.set(chorus.id, { beat = 24, name = "Chorus 1" })
  eq(markers.find("Chorus 1").beat, 24, "moved and renamed")
  api.undo_checkpoint()
  daw.undo()
  eq(markers.find("Chorus").beat, 16, "undo puts it back")
  markers.remove(chorus.id)
  eq(#markers.list(), 2, "removed")
  fails(function() markers.add(-1, "x") end, "from 0 up", "a marker before the start")
  local path = T.scratch .. "/markers.json"
  daw.project.save(path)
  daw.project.new()
  eq(#markers.list(), 0, "a new project has none")
  daw.project.load(path)
  eq(#markers.list(), 2, "they are saved with the project")
end)

test("markers are reached by keys and commands and drawn on the ruler", function()
  start()
  local t = daw.add_track({ name = "T" })
  t:add_clip({ start = 0, length = 32 })
  daw.cursor.set_track(t)
  daw.cursor.set_beat(8)
  daw.cmd("marker", { "Verse" })
  daw.cursor.set_beat(16)
  T.keys("g'")
  eq(#daw.markers.list(), 2, "`g'` puts one at the cursor")
  daw.cursor.set_beat(0)
  T.keys("]'")
  eq(daw.cursor.beat, 8, "]' goes to the next")
  T.keys("]'")
  eq(daw.cursor.beat, 16, "and the next")
  T.keys("['")
  eq(daw.cursor.beat, 8, "[' goes back")
  daw.cmd("marker.goto", { "2" })
  eq(daw.cursor.beat, 16, "by number")
  daw.cmd("marker.rename", { "Chorus" })
  eq(daw.markers.find("Chorus").beat, 16, "named where the cursor is")
  -- A region over the loop, looped by name.
  daw.transport.loop_start, daw.transport.loop_end = 4, 12
  daw.cmd("region", { "Bridge" })
  local bridge = daw.markers.region("Bridge")
  eq(bridge.beat .. "+" .. bridge.length, "4+8", "a region over the loop")
  daw.transport.loop_start, daw.transport.loop_end, daw.transport.loop_enabled = 0, 4, false
  daw.cmd("region.loop", { "Bridge" })
  eq(daw.transport.loop_start .. " " .. daw.transport.loop_end .. " " .. tostring(daw.transport.loop_enabled), "4 12 true", "looped")
  daw.transport.loop_enabled = false
  local text = table.concat(api.ui_snapshot(120, 20), "\n")
  eq(text:find("▼Verse", 1, true) ~= nil, true, "a marker's name is on the ruler")
  eq(text:find("▏Bridge", 1, true) ~= nil, true, "and a region's")
  daw.cursor.set_beat(8)
  daw.cmd("marker.remove")
  eq(daw.markers.find("Verse"), nil, "removed at the cursor")
end)

test("a region is a range to render, and every region renders to its own file", function()
  fresh()
  T.tone("tone", 16)
  daw.project.tempo = 120
  daw.markers.add(2, "A", { length = 2 })
  daw.markers.add(8, "B", { length = 4 })
  local info = render({ range = "A", tail = 0 })
  near(info.seconds, 1, 0.01, "two beats at 120 are one second")
  local dir = T.scratch .. "/regions"
  local files = daw.markers.render_regions(dir, { tail = 0 })
  eq(#files, 2, "a file each")
  eq(files[1]:match("[^/]+$") .. " " .. files[2]:match("[^/]+$"), "01 A.wav 02 B.wav", "named after them, in order")
  eq(#T.read_file(files[2]) > #T.read_file(files[1]), true, "the longer region is the longer file")
  fails(function() render({ range = "nowhere" }) end, "no range", "a range that is not there")
end)

-- Takes and loop recording ---------------------------------------------------------

test("recording with the loop on goes round it and keeps every time round as a take", function()
  with_input(function()
    fresh()
    daw.project.tempo = 120
    daw.project.save(T.scratch .. "/takes.json")
    local mic = daw.add_track({ name = "mic" })
    mic.input, mic.armed = "1", true
    daw.transport.loop_start, daw.transport.loop_end, daw.transport.loop_enabled = 4, 6, true
    daw.transport.seek(4)
    api.undo_checkpoint()
    daw.transport.record()
    api.sleep(2750) -- twice round the second-long loop, and three quarters of a third time
    daw.transport.stop()
    daw.flush()
    eq(daw.transport.position >= 4 and daw.transport.position < 6, true, "the song went round the loop")
    local clips = mic:clips()
    eq(#clips, 1, "one clip")
    local c = clips[1]:get()
    eq(c.start .. "+" .. c.length, "4+2", "over the loop")
    local n, active = daw.takes.count(c.id)
    eq(n .. " " .. active, "3 3", "three takes, the last one playing")
    local list = c.meta.takes.list
    near(list[1].offset, 0, 0.02, "the first take is the start of the file")
    near(list[2].offset - list[1].offset, 1, 0.02, "the second a loop later")
    near(c.offset - list[2].offset, 1, 0.02, "and the one playing a loop after that")
    eq(list[1].file, c.file, "all in the one file")
    eq(#api.media_list(), 1, "which the project lists once")
    local zoom = daw.opt.zoom
    daw.opt.zoom = 16
    daw.ui.focus("arrange")
    local text = table.concat(api.ui_snapshot(160, 20), "\n")
    daw.opt.zoom = zoom
    eq(text:find("‹3/3›", 1, true) ~= nil, true, "the clip says which take plays")

    -- Choosing takes.
    local playing = c.offset
    eq(daw.takes.select(c.id, 1), list[1].name, "the first take by number")
    near(clips[1].offset, list[1].offset, 1e-9, "plays from where it was recorded")
    daw.cursor.set_track(mic)
    daw.cursor.set_beat(4.5)
    daw.cmd("take", { "next" })
    near(clips[1].offset, list[2].offset, 1e-9, "the next")
    daw.cmd("take", { "prev" })
    daw.cmd("take", { "prev" })
    near(clips[1].offset, playing, 1e-9, "round to the last")
    near(render({ start = 4, ["end"] = 6, tail = 0 }).peak, 10 ^ (-12 / 20), 0.02, "and it plays")

    -- Comping: a cut keeps the takes on both sides, lined up.
    daw.cursor.set_beat(5)
    daw.cmd("clip.split")
    clips = mic:clips()
    eq(#clips, 2, "cut in two")
    eq(daw.takes.count(clips[2].id), 3, "the right half has the takes too")
    daw.takes.select(clips[2].id, 1)
    near(clips[2].offset, list[1].offset + 0.5, 1e-6, "and its first take starts half a second in")
    near(clips[1].offset, playing, 1e-9, "while the left half plays what it played")
    -- Trimming a start moves every take with it.
    daw.frontend.act.trim_clips(clips[1].id, "start", 0.5, true)
    daw.takes.select(clips[1].id, 2)
    near(clips[1].offset, list[2].offset + 0.25, 1e-6, "a trimmed clip's takes are trimmed alike")

    -- Throwing takes away, and putting them on tracks.
    daw.takes.remove(clips[1].id)
    eq(table.concat({ daw.takes.count(clips[1].id) }, " "), "2 1", "the playing take removed, the one before plays")
    daw.takes.keep(clips[1].id)
    eq(daw.takes.of(clips[1].id), nil, "kept alone, the clip is a clip again")
    local tracks = daw.takes.explode(clips[2].id)
    eq(#tracks, 2, "the other takes on tracks of their own")
    eq(#tracks[1]:clips(), 1, "a clip each")
    near(tracks[2]:clips()[1].offset, playing + 0.5, 1e-6, "from where they were lined up")
  end)
end)

test("a take that never went round the loop is one clip, and a lead-in is a clip before the loop", function()
  with_input(function()
    fresh()
    daw.project.tempo = 120
    daw.project.save(T.scratch .. "/takes2.json")
    local mic = daw.add_track({ name = "mic" })
    mic.input, mic.armed = "1", true
    daw.transport.loop_start, daw.transport.loop_end, daw.transport.loop_enabled = 4, 8, true
    daw.transport.seek(4)
    daw.transport.record()
    api.sleep(700)
    daw.transport.stop()
    daw.flush()
    local clips = mic:clips()
    eq(#clips, 1, "one clip")
    eq(daw.takes.of(clips[1].id), nil, "without takes")
    clips[1]:remove()
    -- Starting a beat before the loop.
    daw.transport.loop_start, daw.transport.loop_end = 4, 6
    daw.transport.seek(3)
    daw.transport.record()
    api.sleep(2250) -- the lead-in, once round, and three quarters of a second time
    daw.transport.stop()
    daw.flush()
    clips = mic:clips()
    eq(#clips, 2, "a clip before the loop and one over it")
    local lead, loop = clips[1]:get(), clips[2]:get()
    eq(lead.start .. "+" .. lead.length, "3+1", "the lead-in up to the loop")
    eq(loop.start .. "+" .. loop.length, "4+2", "the loop")
    eq(daw.takes.count(loop.id), 2, "two takes")
    near(loop.meta.takes.list[1].offset, 0.5, 0.02, "the first begins where the lead-in ends")
  end)
end)

test("notes recorded round the loop are takes too", function()
  with_input(function()
    fresh()
    daw.project.tempo = 120
    local keys = daw.add_track({ name = "keys" })
    keys:add_device("synth", { attack = 0.001, release = 0.01 })
    keys.armed = true
    daw.transport.loop_start, daw.transport.loop_end, daw.transport.loop_enabled = 4, 6, true
    daw.transport.seek(4)
    daw.transport.record()
    api.sleep(200)
    daw.midi.inject({ type = "note_on", pitch = 60, velocity = 100 })
    api.sleep(200)
    daw.midi.inject({ type = "note_off", pitch = 60 })
    api.sleep(900) -- into the second time round
    daw.midi.inject({ type = "note_on", pitch = 64, velocity = 90 })
    api.sleep(200)
    daw.midi.inject({ type = "note_off", pitch = 64 })
    api.sleep(150)
    daw.transport.stop()
    daw.flush()
    local clips = keys:clips()
    eq(#clips, 1, "one clip")
    local c = clips[1]:get()
    eq(c.kind .. " " .. c.start .. "+" .. c.length, "midi 4+2", "over the loop")
    eq(table.concat({ daw.takes.count(c.id) }, " "), "2 2", "two takes, the second playing")
    eq(clips[1]:notes()[1].pitch, 64, "the second time round's note plays")
    near(clips[1]:notes()[1].start, 0.6, 0.25, "where it was played in the loop")
    daw.takes.select(c.id, 1)
    eq(clips[1]:notes()[1].pitch, 60, "the first take has the first note")
    near(clips[1]:notes()[1].start, 0.4, 0.25, "where it was played")
    -- A copy to change, with what was there kept.
    local n = daw.takes.new(c.id)
    eq(n, 3, "a third take")
    local list = clips[1]:notes()
    list[1].pitch = 72
    clips[1]:set_notes(list)
    daw.takes.step(c.id, -1)
    eq(clips[1]:notes()[1].pitch, 64, "the take before is as it was")
    daw.takes.step(c.id, 1)
    eq(clips[1]:notes()[1].pitch, 72, "and the copy holds the change")
    -- A cut gives each side the notes of its stretch, in every take.
    daw.cursor.set_track(keys)
    daw.cursor.set_beat(4.5)
    daw.cmd("clip.split")
    clips = keys:clips()
    daw.takes.select(clips[2].id, 1)
    eq(#clips[2]:notes(), 0, "take 1's note was before the cut")
    daw.takes.select(clips[2].id, 2)
    eq(clips[2]:notes()[1].pitch, 64, "take 2's is after it")
    near(clips[2]:notes()[1].start, 0.1, 0.25, "counted from the cut")
  end)
end)

-- Automation modes --------------------------------------------------------------

test("a track's automation mode says what moving a control writes", function()
  fresh()
  api.engine_restart({ backend = "null" })
  local t = T.tone("tone", 64)
  eq(t.automation, "read", "tracks read to begin with")
  fails(function() t.automation = "sideways" end, "automation", "a mode that is not one")
  -- Read: a move writes nothing.
  daw.transport.seek(0)
  daw.transport.play()
  daw.wait(60)
  t.volume = -6
  daw.wait(120)
  daw.transport.stop()
  eq(t:lane("volume"), nil, "in read mode a move writes nothing")
  -- Latch: from the first move until the song stops.
  t.automation = "latch"
  daw.transport.seek(0)
  daw.transport.play()
  daw.wait(100)
  t.volume = -12
  daw.wait(900)
  local late = daw.transport.position
  daw.wait(60)
  daw.transport.stop()
  daw.flush()
  local lane = t:lane("volume")
  eq(lane ~= nil, true, "in latch mode a move makes a lane")
  near(lane:value_at(late), -12, 0.001, "and holds until the song stops, long after the move")
  -- Touch: while it is moved, then the lane takes over again.
  lane:set_points({ { 0, -20 }, { 64, -20 } })
  t.automation = "touch"
  daw.transport.seek(0)
  daw.transport.play()
  daw.wait(100)
  local touched = daw.transport.position
  t.volume = -3
  daw.wait(250)
  local during = daw.transport.position
  daw.wait(1100) -- let go: no move for longer than the release time
  local after = daw.transport.position
  daw.transport.stop()
  daw.flush()
  near(lane:value_at(touched + 0.1), -3, 0.001, "written while it was touched")
  near(lane:value_at(during - 0.05), -3, 0.001, "held")
  near(lane:value_at(after), -20, 0.001, "and back on the lane once it was let go")
  near(lane:value_at(60), -20, 0.001, "the rest of the lane is as it was")
  -- Held by hand, it writes for as long as it is held.
  lane:set_points({ { 0, -20 }, { 64, -20 } })
  daw.transport.seek(0)
  daw.transport.play()
  daw.wait(60)
  api.automation_hold(t.id, "volume", nil, nil, true)
  t.volume = -9
  daw.wait(1100)
  local held = daw.transport.position
  daw.wait(60)
  api.automation_hold(t.id, "volume", nil, nil, false)
  daw.wait(300)
  local released = daw.transport.position
  daw.transport.stop()
  daw.flush()
  near(lane:value_at(held), -9, 0.001, "held under the hand, it keeps writing without a move")
  near(lane:value_at(released), -20, 0.001, "and is let go when the hand is")
  -- Write: everything the lanes move, moved or not.
  lane:set_points({ { 0, -20 }, { 2, -40 }, { 64, -20 } })
  t.volume = -1
  t.automation = "write"
  daw.transport.seek(0)
  daw.transport.play()
  daw.wait(1300)
  local written = daw.transport.position
  daw.transport.stop()
  daw.flush()
  near(lane:value_at(written - 0.2), -1, 0.001, "write mode writes the fader over the lane without a move")
  -- Off: the lanes stay and do not play.
  t.automation = "read"
  lane:set_points({ { 0, -60 }, { 64, -60 } })
  t.volume = 0
  local quiet = render({ tail = 0, start = 0, ["end"] = 4 }).peak
  t.automation = "off"
  local loud = render({ tail = 0, start = 0, ["end"] = 4 }).peak
  eq(loud > quiet * 100, true, "with automation off the fader is what counts")
  eq(#lane:points(), 2, "and the lane is kept")
  -- The command steps through the modes, and the header says which.
  daw.cursor.set_track(t)
  daw.cmd("automation", { "touch" })
  eq(t.automation, "touch", "set by command")
  daw.cmd("automation")
  eq(t.automation, "latch", "without a word, the next in turn")
  daw.cmd("automation", { "read", "all" })
  eq(t.automation, "read", "on every track")
  local path = T.scratch .. "/modes.json"
  t.automation = "touch"
  daw.project.save(path)
  daw.project.load(path)
  eq(daw.tracks()[1].automation, "touch", "the mode is saved with the project")
end)

-- Long files played from the disk ---------------------------------------------------

test("a long file is played from the disk, sample for sample as from memory", function()
  fresh()
  api.engine_restart({ backend = "null" })
  -- Twelve seconds of a tone: more than a megabyte decoded.
  T.tone("source", 24)
  daw.project.tempo = 120
  local wav = render({ tail = 0, bits = 16 })
  local was = api.media_store()
  local function song()
    daw.project.new()
    daw.project.tempo = 120
    local t = daw.add_track({ name = "long" })
    local clip = t:add_clip({ file = wav.path, start = 0 })
    return t, clip
  end
  api.media_store(0)
  local _, in_memory = song()
  local length = in_memory.length
  eq(api.media_list()[1].on_disk, false, "held in memory when the limit is off")
  local a = render({ tail = 0, bits = 16 })
  api.media_store(1)
  local t, clip = song()
  eq(api.media_list()[1].on_disk, true, "past the limit it is played from the disk")
  near(clip.length, length, 1e-6, "as long as ever")
  local b = render({ tail = 0, bits = 16 })
  eq(T.read_file(b.path) == T.read_file(a.path), true, "and renders the same bytes")
  eq(#clip:peaks(64), 64, "its waveform is drawn as any other's")
  -- It plays in real time, from the middle too.
  daw.transport.seek(12)
  daw.transport.play()
  daw.wait(250)
  local level = t:meter()
  daw.transport.stop()
  eq(level > 0.05, true, "heard while playing")
  -- Kept between runs: the next time it is not decoded again.
  local _, dir = api.media_store()
  local kept = 0
  for _, entry in ipairs(api.read_dir(dir)) do
    if entry.name:match("%.meta$") then kept = kept + 1 end
  end
  eq(kept >= 1, true, "the decoded sound is in the cache directory")
  api.media_store(0)
  api.media_store(1)
  song()
  eq(api.media_list()[1].on_disk, true, "and is found there again")
  -- At another rate than the engine's, the converted sound is kept the same way.
  api.engine_restart({ backend = "null", sample_rate = 44100 })
  local _, other = song()
  eq(api.media_list()[1].on_disk, true, "still from the disk at another rate")
  local c = render({ tail = 0, bits = 16 })
  near(c.peak, a.peak, 0.01, "and as loud")
  near(other.length, length, 0.01, "and as long")
  api.engine_restart({ backend = "null" })
  api.media_store(was)
end)

-- What the window is told, and what it asks for ---------------------------------------

test("the window is told of markers, takes, automation modes and lanes shown as rows", function()
  start()
  local t = daw.add_track({ name = "T" })
  local clip = t:add_clip({ start = 0, length = 4, notes = { { pitch = 60, start = 0, length = 1 } } })
  daw.takes.new(clip.id)
  daw.markers.add(8, "Verse")
  daw.markers.add(0, "", { length = 4 })
  t.automation = "latch"
  eq(daw.frontend.act.lane_rows(t.id), true, "the lanes are shown as rows")
  daw.flush()
  local s = daw.frontend.state(-1)
  eq(#s.project.markers, 2, "markers")
  eq(s.project.markers[1].name .. " " .. s.project.markers[1].length, "1 4", "a region without a name goes by its number")
  eq(s.project.markers[2].name .. " " .. s.project.markers[2].length, "Verse 0", "a marker has no length")
  eq(s.tracks[1].automation, "latch", "the track's automation mode")
  eq(#s.tracks[1].lane_rows, 1, "a track with no lanes got one for its fader, shown as a row")
  eq(s.clips[1].takes .. "/" .. s.clips[1].take, "2/2", "a clip's takes, and which plays")
  daw.frontend.act.hide_lane_rows(s.tracks[1].lane_rows[1])
  daw.flush()
  local again = daw.frontend.state(s.revision)
  eq(again.project ~= nil, true, "hiding the rows is news to the window")
  eq(#again.tracks[1].lane_rows, 0, "hidden")
  -- A control held under the pointer, as the window says it.
  t.automation = "touch"
  daw.transport.play()
  daw.wait(60)
  daw.frontend.act.hold(t.id, "volume", 0, "", true)
  daw.wait(900)
  local held = daw.transport.position
  daw.frontend.act.hold(t.id, "volume", 0, "", false)
  daw.wait(200)
  daw.transport.stop()
  daw.flush()
  near(t:lane("volume"):value_at(held - 0.2), t.volume, 0.001, "held, the fader is written without a move")
  daw.learn.start({ track = t.id, target = "pan" })
  eq(daw.frontend.state(daw.frontend.revision).modal.learning, "T › pan", "what is waiting for a controller")
  daw.learn.cancel()
end)

test("the window's render dialog renders a region, and leaving saves first when asked", function()
  fresh()
  api.engine_restart({ backend = "null" })
  T.tone("tone", 16)
  daw.project.tempo = 120
  local region = daw.markers.add(4, "Hook", { length = 4 })
  daw.transport.loop_start, daw.transport.loop_end = 0, 8
  local d = daw.frontend.render_dialog()
  local names = {}
  for i, r in ipairs(d.ranges) do names[i] = r.name end
  eq(table.concat(names, " "), "song loop region:" .. region.id, "what can be rendered")
  eq(d.path:match("[^/]+$"), "untitled.wav", "to a file named after the project")
  local out = T.scratch .. "/dialog"
  daw.frontend.act.render({ path = out .. ".wav", range = "region:" .. region.id, format = "flac", bits = 32, tail = 0 })
  local deadline = api.now() + 10000
  while daw.render_status() and api.now() < deadline do daw.wait(20) end
  eq(#T.read_file(out .. ".flac") > 1000, true, "the region was rendered, as the format chosen and not as the path was typed")
  fails(function() daw.frontend.act.render({ path = "", range = "song" }) end, "name a file", "no file named")
  -- Leaving: a project with a file is saved, and then left.
  local path = T.scratch .. "/leave.json"
  daw.project.save(path)
  daw.add_track({ name = "more" })
  daw.flush()
  api.undo_checkpoint()
  eq(daw.frontend.closing().modified, true, "there are changes to save")
  daw.frontend.act.leave("save", "new")
  eq(#daw.tracks(), 0, "a new project")
  daw.project.load(path)
  eq(#daw.tracks(), 2, "and the changes were saved first")
end)

test("a take chosen over a selected stretch plays there alone", function()
  start()
  local t = daw.add_track({ name = "comp" })
  local function beats(pitch)
    local notes = {}
    for i = 0, 7 do notes[i + 1] = { pitch = pitch, start = i, length = 1 } end
    return notes
  end
  local clip = t:add_clip({ start = 0, length = 8, notes = beats(60) })
  daw.takes.new(clip.id)
  clip:set_notes(beats(72)) -- the second take, the one playing, is an octave up
  daw.cursor.set_track(t)
  daw.cursor.set_beat(2)
  api.undo_checkpoint()
  T.keys("vll")
  local sel = daw.keymap.selection()
  daw.cmd("take", { "1" })
  api.undo_checkpoint()
  eq(daw.keymap.mode, "n", "back in normal mode")
  local clips = t:clips()
  eq(#clips, 3, "the clip is cut at both ends of the stretch")
  local function pitches(c)
    local out = {}
    for i, n in ipairs(c:notes()) do out[i] = n.pitch end
    return table.concat(out, " ")
  end
  eq(clips[2].start .. " " .. clips[2].start + clips[2].length, sel.c0 .. " " .. sel.c1, "the middle piece is the stretch")
  eq(pitches(clips[2]):find("72") == nil and #clips[2]:notes() > 0, true, "which plays the first take")
  eq(pitches(clips[1]):find("60") == nil and pitches(clips[3]):find("60") == nil, true, "while what is around it plays on as it did")
  eq(daw.takes.count(clips[1].id) .. " " .. daw.takes.count(clips[3].id), "2 2", "and every piece keeps both takes")
  daw.takes.select(clips[3].id, 1)
  eq(#clips[3]:notes(), clips[3].length, "lined up: the last piece's first take has a note a beat")
  api.undo_checkpoint()
  daw.undo()
  daw.undo()
  eq(#t:clips(), 1, "one undo for the choice of take, one for the cut and the comp")
end)
