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

-- Counting in and punching in ----------------------------------------------------

test("a count-in counts a bar before the take, which starts on the beat where the playhead was", function()
  with_input(function()
    fresh()
    daw.project.tempo = 120
    daw.project.save(T.scratch .. "/countin.json")
    local mic = daw.add_track({ name = "mic" })
    mic.input, mic.armed = "1", true
    daw.cmd("countin", { "1" })
    eq(daw.opt.count_in .. " " .. daw.transport.count_in, "1 1", "the option, and the kernel told of it")
    daw.transport.seek(4)
    daw.transport.record()
    eq(api.transport_get().counting, 4, "a bar of four beats to count")
    eq(daw.frontend.state(daw.frontend.revision).counting, 4, "the window is told")
    api.sleep(1000) -- half the bar
    local t = api.transport_get()
    eq(t.counting >= 1 and t.counting <= 3, true, "counting down: " .. t.counting)
    eq(t.position, 4, "the playhead waits where it was")
    eq(t.playing, true, "the transport is busy")
    daw.ui.focus("arrange")
    local text = table.concat(api.ui_snapshot(160, 20), "\n")
    eq(text:find("count %d") ~= nil, true, "the status line counts")
    api.sleep(1700) -- past the end of the bar
    t = api.transport_get()
    eq(t.counting, 0, "counted")
    eq(t.position > 4, true, "and then the song plays")
    daw.transport.stop()
    daw.flush()
    local played = daw.transport.position - 4
    local clips = mic:clips()
    eq(#clips, 1, "a take")
    local c = clips[1]:get()
    eq(c.start, 4, "on the beat where the playhead was")
    eq(c.offset, 0, "from the start of its file, as without a count")
    near(c.length, played, 0.05, "holding what was played after the count and nothing of it")
    -- Stopping, or Esc, while it counts calls the take off.
    daw.transport.seek(12)
    api.undo_checkpoint()
    local edits = daw.project.get().edits
    daw.transport.record()
    api.sleep(300)
    daw.transport.stop()
    daw.flush()
    eq(#mic:clips(), 1, "stopped during the count: no take")
    eq(daw.transport.recording, false, "and record mode is off")
    eq(daw.transport.position, 12, "the playhead stays")
    daw.transport.record()
    api.sleep(300)
    daw.keymap.feed("<Esc>")
    daw.flush()
    eq(daw.transport.playing, false, "Esc calls the count off")
    eq(#mic:clips(), 1, "with nothing recorded")
    eq(daw.project.get().edits, edits, "and nothing changed")
    -- Punching in by hand while playing is not counted.
    daw.transport.play()
    daw.wait(50)
    daw.transport.recording = true
    eq(api.transport_get().counting, 0, "punched in by hand: no count")
    daw.transport.stop()
    daw.cmd("countin", { "off" })
    eq(daw.transport.count_in, 0, "off")
    daw.cmd("countin")
    eq(daw.opt.count_in, 1, "toggled back to the last count")
    daw.opt.count_in = 0
  end)
end)

test("a punched take records from the punch in to the punch out while the song plays on", function()
  with_input(function()
    fresh()
    daw.project.tempo = 120
    local path = T.scratch .. "/punch.json"
    daw.project.save(path)
    local mic = daw.add_track({ name = "mic" })
    mic.input, mic.armed = "1", true
    daw.cmd("punch", { "2", "2" })
    local t = api.transport_get()
    eq(t.punch_start .. " " .. t.punch_end .. " " .. tostring(t.punch_enabled), "4 8 true", "bar 2, as the loop counts bars")
    daw.transport.seek(2)
    daw.transport.record()
    api.sleep(3600) -- from beat 2 to past beat 9
    eq(daw.transport.playing and daw.transport.position > 8, true, "the song plays on past the punch out")
    daw.transport.stop()
    daw.flush()
    local clips = mic:clips()
    eq(#clips, 1, "one clip")
    local c = clips[1]:get()
    eq(c.start .. "+" .. c.length, "4+4", "over the punch range exactly")
    eq(c.offset, 0, "from the start of its file")
    near(api.clip_source_length(c.id), 4, 0.001, "whose file holds the range and no more")
    near(render({ start = 4, ["end"] = 8, tail = 0 }).peak, 10 ^ (-12 / 20), 0.02, "it sounds over the range")
    eq(render({ start = 0, ["end"] = 4, tail = 0 }).peak < 1e-6, true, "and not before it")
    -- Started inside the range: at once, up to the punch out.
    clips[1]:remove()
    daw.transport.seek(6)
    daw.transport.record()
    api.sleep(1400)
    daw.transport.stop()
    daw.flush()
    c = mic:clips()[1]:get()
    eq(c.start .. "+" .. c.length, "6+2", "from the playhead to the punch out")
    -- Started after it: nothing, and it says so.
    mic:clips()[1]:remove()
    daw.transport.seek(9)
    daw.transport.record()
    daw.flush()
    eq(tostring(daw.ui.message and daw.ui.message.text):find("past the punch out") ~= nil, true, "it says so")
    api.sleep(200)
    daw.transport.stop()
    daw.flush()
    eq(#mic:clips(), 0, "and records nothing")
    -- Kept with the project, as the loop is.
    daw.project.save(path)
    daw.project.new()
    eq(daw.transport.punch_enabled, false, "a new project has none")
    daw.project.load(path)
    t = api.transport_get()
    eq(t.punch_start .. " " .. t.punch_end .. " " .. tostring(t.punch_enabled), "4 8 true", "loaded again")
    local s = daw.frontend.state(-1)
    eq(s.project.punch_start .. " " .. s.project.punch_end .. " " .. tostring(s.project.punch_enabled), "4 8 true", "and the window is told")
    -- Toggled, and drawn on the ruler.
    daw.cmd("punch")
    eq(daw.transport.punch_enabled, false, "toggled off")
    daw.cmd("punch")
    eq(daw.transport.punch_enabled, true, "and on")
    daw.ui.focus("arrange")
    local text = table.concat(api.ui_snapshot(160, 20), "\n")
    eq(text:find("punch 2", 1, true) ~= nil, true, "the status line says where")
    daw.frontend.act.set_punch_edge("end", 12.3)
    eq(daw.transport.punch_end, 12, "an edge dragged lands on the grid")
    daw.frontend.act.set_punch(16, 9.9)
    eq(daw.transport.punch_start .. " " .. daw.transport.punch_end, "10 16", "a range drawn")
    daw.transport.punch_enabled = false
  end)
end)

test("notes punched in are kept inside the range and cut at the punch out", function()
  start()
  daw.project.tempo = 120
  local keys = daw.add_track({ name = "keys" })
  keys:add_device("synth", { attack = 0.001, release = 0.01 })
  keys.armed = true
  daw.transport.punch_start, daw.transport.punch_end, daw.transport.punch_enabled = 4, 6, true
  daw.transport.seek(3)
  daw.transport.record()
  api.sleep(200)  -- beat 3.4, before the punch in
  daw.midi.inject({ type = "note_on", pitch = 60, velocity = 100 })
  api.sleep(200)
  daw.midi.inject({ type = "note_off", pitch = 60 })
  api.sleep(400)  -- beat 4.6, inside
  daw.midi.inject({ type = "note_on", pitch = 64, velocity = 90 })
  api.sleep(1100) -- beat 6.8, past the punch out, still held
  daw.midi.inject({ type = "note_off", pitch = 64 })
  api.sleep(200)
  daw.transport.stop()
  daw.flush()
  local clips = keys:clips()
  eq(#clips, 1, "one clip")
  local c = clips[1]:get()
  eq(c.kind .. " " .. c.start .. "+" .. c.length, "midi 4+2", "over the punch range")
  local notes = clips[1]:notes()
  eq(#notes, 1, "the note before the punch in is left out")
  eq(notes[1].pitch, 64, "the one inside is kept")
  near(notes[1].start, 0.6, 0.25, "where it was played")
  near(notes[1].start + notes[1].length, 2, 1e-9, "and cut at the punch out")
  daw.transport.punch_enabled = false
end)

test("punching with the loop on keeps every time through the punch range as a take", function()
  with_input(function()
    fresh()
    daw.project.tempo = 120
    daw.project.save(T.scratch .. "/punchloop.json")
    local mic = daw.add_track({ name = "mic" })
    mic.input, mic.armed = "1", true
    daw.transport.loop_start, daw.transport.loop_end, daw.transport.loop_enabled = 0, 4, true
    daw.transport.punch_start, daw.transport.punch_end, daw.transport.punch_enabled = 1, 3, true
    daw.transport.seek(0)
    daw.transport.record()
    api.sleep(5750) -- twice round the two-second loop, and through the range a third time
    daw.transport.stop()
    daw.flush()
    local clips = mic:clips()
    eq(#clips, 1, "one clip")
    local c = clips[1]:get()
    eq(c.start .. "+" .. c.length, "1+2", "over the punch range")
    eq(table.concat({ daw.takes.count(c.id) }, " "), "3 3", "a take each time through it, the last playing")
    local list = c.meta.takes.list
    near(list[1].offset, 0, 1e-6, "the first from the start of the file")
    near(list[2].offset, 1, 1e-4, "the second right after it: only the range was captured")
    near(c.offset, 2, 1e-4, "and the one playing after that")
    near(api.clip_source_length(c.id), 2, 0.001, "where the file ends")
    -- One step from comping: the takes as lanes.
    daw.cursor.set_track(mic)
    daw.cmd("take.lanes")
    eq(daw.takes.lane_count(mic.id), 3, "every pass shows at once")
    daw.takes.show_lanes(mic.id, false)
    daw.transport.loop_enabled, daw.transport.punch_enabled = false, false
  end)
end)

-- Take lanes and comping ------------------------------------------------------------

--- A track with an audio clip of eight beats whose three takes are three
--- stretches of one file, the third playing.
local function three_takes()
  local source = T.tone("source", 32)
  daw.project.tempo = 120
  local wav = render({ tail = 0, bits = 32 })
  source:remove()
  local t = daw.add_track({ name = "vox" })
  local clip = t:add_clip({ file = wav.path, start = 0, length = 8, offset = 8, meta = {
    takes = { active = 3, origin = 8, list = {
      { name = "vox.1", file = wav.path, offset = 0, gain = 0 },
      { name = "vox.2", file = wav.path, offset = 4, gain = -6 },
      { name = "vox.3" },
    } },
  } })
  return t, clip, wav
end

test("a drag across a take lane makes that take play over the stretch, as one undo step", function()
  start()
  local t, clip = three_takes()
  local act = daw.frontend.act
  eq(act.take_lanes(t.id), true, "the take lanes are shown")
  daw.flush()
  local s = daw.frontend.state(-1)
  eq(s.tracks[1].take_rows, 3, "three lanes under the clips")
  eq(s.clips[1].take_rows[2].name, "vox.2", "each take by name")
  api.undo_checkpoint()
  eq(act.comp(t.id, 1, 2.2, 5.9, false), 1, "one piece given take 1")
  api.undo_checkpoint()
  local clips = t:clips()
  local shape = {}
  for i, c in ipairs(clips) do shape[i] = c.start .. "+" .. c.length .. ":" .. select(2, daw.takes.count(c.id)) end
  eq(table.concat(shape, " "), "0+2:3 2+4:1 6+2:3", "cut on the grid at both ends, take 1 between")
  near(clips[2].offset, 1, 1e-9, "take 1 lined up: two beats into its stretch of the file")
  near(clips[3].offset, 8 + 3, 1e-9, "while take 3 plays on after it")
  daw.undo()
  eq(#t:clips(), 1, "one undo step undoes it all")
  daw.redo()
  -- Swiping back joins the pieces again.
  eq(act.comp(t.id, 3, 2, 6, false), 1, "take 3 back over the stretch")
  clips = t:clips()
  eq(#clips, 1, "the pieces are one clip again")
  eq(clips[1].start .. "+" .. clips[1].length .. " " .. clips[1].offset, "0+8 8", "the clip as it was")
  eq(daw.takes.count(clips[1].id), 3, "with every take")
  -- Two takes side by side, then one over both.
  act.comp(t.id, 1, 0, 4)
  act.comp(t.id, 2, 4, 8)
  eq(#t:clips(), 2, "two pieces")
  near(t:clips()[2].offset, 4 + 2, 1e-9, "take 2 lined up after the cut")
  act.comp(t.id, 2, 0, 8)
  eq(#t:clips(), 1, "one take over both: one clip")
  eq(select(2, daw.takes.count(t:clips()[1].id)), 2, "playing take 2")
  near(t:clips()[1].gain, -6, 1e-9, "with its gain")
  -- A click chooses the take of the piece under the pointer.
  act.comp(t.id, 3, 4, 8)
  eq(act.take_click(t.id, 3, 1) ~= nil, true, "a click on lane 3")
  eq(#t:clips(), 1, "which then carries straight on into its neighbour")
  eq(act.comp(t.id, 1, 3.3, 3.31, false), 1, "too short a drag is a click")
  eq(#t:clips(), 1, "the whole piece under it gets the take")
  eq(select(2, daw.takes.count(t:clips()[1].id)), 1, "take 1")
  -- Off the grid with Shift.
  act.comp(t.id, 2, 1.3, 2.7, true)
  local starts = {}
  for i, c in ipairs(t:clips()) do starts[i] = c.start end
  eq(table.concat(starts, " "), "0 1.3 2.7", "exactly where it was dragged")
  -- Clips without takes are left alone.
  local plain = t:add_clip({ file = clip.file, start = 10, length = 4 })
  eq(act.comp(t.id, 2, 9, 13), 0, "a clip without takes is not comped")
  eq(plain.start .. "+" .. plain.length, "10+4", "nor cut")
end)

test("the window draws other takes from their own files, and the terminal shows the lanes", function()
  start()
  local t, clip, wav = three_takes()
  local peaks = api.media_peaks(wav.path, 0, 1, 16)
  eq(#peaks, 16, "a waveform of a stretch of any file")
  eq(peaks[8][2] > 0.1, true, "with the sound in it")
  eq(#api.media_peaks(wav.path, 0, 0, 16), 0, "nothing of no time")
  fails(function() api.media_peaks(wav.path, 0, 1, 1e9) end, "at most", "too many points")
  -- What take 2 would play is what the clip plays once it is chosen.
  local preview = daw.frontend.take_preview(clip.id, 2, 64)
  eq(#preview, 64 * 3, "a point for each")
  daw.takes.select(clip.id, 2)
  local own = daw.frontend.peaks(clip.id, 64)
  local same = true
  for i = 1, #own do same = same and math.abs(own[i] - preview[i]) < 1e-6 end
  eq(same, true, "a take's picture is its sound, gain and all")
  -- MIDI takes give their notes.
  local keys = daw.add_track({ name = "keys" })
  local m = keys:add_clip({ start = 0, length = 4, notes = { { pitch = 60, start = 1, length = 1 } } })
  daw.takes.new(m.id)
  m:set_notes({ { pitch = 72, start = 0, length = 2 } })
  local flat = daw.frontend.take_preview(m.id, 1, 0)
  eq(table.concat(flat, " "), "1 1 60", "take 1's notes")
  -- The terminal: a row for each take under the track, the one that plays lit.
  daw.cursor.set_track(t)
  daw.keymap.feed("zt")
  eq(daw.takes.lanes_shown(t.id), true, "zt shows them")
  daw.ui.focus("arrange")
  local text = table.concat(api.ui_snapshot(160, 30), "\n")
  eq(text:find("take 3", 1, true) ~= nil, true, "a row for each take")
  eq(text:find("vox.1", 1, true) ~= nil, true, "named")
  daw.keymap.feed("zt")
  eq(daw.takes.lanes_shown(t.id), false, "and hides them")
end)

test("comping notes joins the pieces back exactly when the same take plays across them", function()
  start()
  local t = daw.add_track({ name = "comp" })
  local function beats(pitch)
    local notes = {}
    for i = 0, 7 do notes[i + 1] = { pitch = pitch, start = i, length = 1 } end
    return notes
  end
  local clip = t:add_clip({ start = 0, length = 8, notes = beats(60) })
  daw.takes.new(clip.id)
  clip:set_notes(beats(72))
  eq(daw.takes.comp(t.id, 1, 2, 4), 1, "take 1 over two beats")
  eq(#t:clips(), 3, "three pieces")
  eq(daw.takes.comp(t.id, 2, 0, 8), 3, "take 2 over the lot")
  local clips = t:clips()
  eq(#clips, 1, "one clip again")
  eq(#clips[1]:notes(), 8, "with every note")
  eq(clips[1]:notes()[3].pitch .. " " .. clips[1]:notes()[3].start, "72 2", "in its place")
  daw.takes.select(clips[1].id, 1)
  local notes = clips[1]:notes()
  eq(#notes .. " " .. notes[8].pitch .. " " .. notes[8].start, "8 60 7", "and the other take whole too")
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
