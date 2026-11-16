-- Tests of clip launching: clips in slots, launched on their boundary,
-- scenes, stopping, going back to the timeline, saving, undo, controllers,
-- the session view, and a performance captured into the timeline and
-- rendered. Loaded by tests/suite.lua with its helpers.
local T = ...
local test, eq, near, fails, fresh, render = T.test, T.eq, T.near, T.fails, T.fresh, T.render
local api = daw.api
local launcher = daw.launcher

local function start()
  fresh()
  api.engine_restart({ backend = "null" })
  daw.keymap.feed("<Esc><Esc>")
  while daw.ui.float do daw.ui.close() end
  daw.ui.focus("arrange")
end

--- Let the engine run until `check()` holds, for at most `ms`.
local function until_(check, ms, what)
  local deadline = api.now() + (ms or 10000)
  while not check() do
    if api.now() > deadline then error("waited in vain for " .. what, 2) end
    daw.wait(5)
  end
end

--- A synth track with a clip of one long note in a slot.
local function synth(name, row, pitch, bars)
  local t = daw.add_track({ name = name })
  t:add_device("synth", { attack = 0.001, release = 0.01 })
  local length = 4 * (bars or 1)
  local id = api.clip_add(t.id, {
    slot = row, length = length, notes = { { pitch = pitch or 57, start = 0, length = length } },
  })
  return t, id
end

local function state(track) return launcher.state()[track] or {} end

--- The first frame of a 16-bit WAV written by `daw.render` that is not silent.
local function first_sound(info)
  local data = T.read_file(info.path)
  local at = data:find("data", 1, true) + 8
  for i = at, #data - 1, 2 do
    local lo, hi = data:byte(i, i + 1)
    if lo ~= 0 or hi ~= 0 then return math.floor((i - at) / 4) end
  end
  return -1
end

-- The model ------------------------------------------------------------------

test("a clip in a slot is kept apart from the timeline and edited like any clip", function()
  start()
  local t = daw.add_track({ name = "Keys" })
  local id = api.clip_add(t.id, { slot = 2, start = 8, length = 2, notes = { { pitch = 60, start = 0, length = 1 } } })
  eq(#api.clip_list(t.id), 0, "nothing on the timeline")
  local slots = api.slot_list(t.id)
  eq(#slots, 1, "one slot holds a clip")
  eq(slots[1].slot, 2, "in its row")
  eq(slots[1].start, 0, "starting at 0 whatever was asked")
  eq(api.clip_get(id).slot, 2, "a clip's view says where it is")
  daw.clip(id):set_notes({ { pitch = 64, start = 0, length = 0.5 } })
  eq(api.clip_notes(id)[1].pitch, 64, "its notes are set as any clip's")
  api.clip_set(id, "mode", "gate")
  api.clip_set(id, "quantize", "1/8")
  api.clip_set(id, "legato", true)
  local c = api.clip_get(id)
  eq(c.mode .. " " .. c.quantize .. " " .. tostring(c.legato), "gate 1/8 true", "how it launches")
  fails(function() api.clip_set(id, "quantize", "3 bars") end, "quantize", "an unknown quantize")
  fails(function() api.clip_set(id, "start", 4) end, "starts at 0", "a slot's clip has no place in time")
  api.clip_set(id, "row", 0)
  eq(api.slot_list(t.id)[1].slot, 0, "moved to another row")
  local other = daw.add_track({ name = "Other" })
  api.clip_set(id, "track", other.id)
  eq(#api.slot_list(t.id) .. #api.slot_list(other.id), "01", "to another track, in the same row")
  api.clip_remove(id)
  eq(#api.slot_list(other.id), 0, "and removed")
end)

test("a clip on the timeline is copied into a slot, and a track's copy keeps its slots", function()
  start()
  local t = daw.add_track({ name = "Bass" })
  local clip = t:add_clip({ start = 8, length = 4, notes = { { pitch = 40, start = 1, length = 1 } } })
  local copy = launcher.copy(clip.id, t.id, 1)
  eq(api.clip_get(copy).start, 0, "it starts at 0")
  eq(api.clip_notes(copy)[1].start, 1, "with the notes where they were in it")
  eq(#api.clip_list(t.id), 1, "the original stays")
  local snap = t:snapshot()
  local twin = daw.restore_track(snap)
  local slots = api.slot_list(twin.id)
  eq(#slots .. " " .. slots[1].slot .. " " .. #api.clip_list(twin.id), "1 1 1", "the copy of the track has the slot too")
end)

test("slots are saved, opened and undone with the project", function()
  start()
  local t = daw.add_track({ name = "Pad" })
  local id = api.clip_add(t.id, { slot = 3, length = 8, mode = "toggle", notes = { { pitch = 50, start = 0, length = 2 } } })
  launcher.set_quantize("1/4")
  launcher.set_scene_name(3, "Drop")
  api.undo_checkpoint()
  local path = T.scratch .. "/launcher.json"
  api.project_save(path)
  daw.project.new()
  api.project_load(path)
  local slot = api.slot_list(api.track_list()[1])[1]
  eq(slot.slot .. " " .. slot.length .. " " .. slot.mode, "3 8 toggle", "the slot comes back")
  eq(api.clip_notes(slot.id)[1].pitch, 50, "with its notes")
  eq(api.project_get().launch_quantize, "1/4", "and the project's quantize")
  eq(launcher.scene_name(3) .. " " .. launcher.scene_name(0), "Drop Scene 1", "and the scenes' names")
  eq(launcher.rows() >= 5, true, "a row more than the last that is used")
  api.clip_remove(slot.id)
  api.undo_checkpoint()
  eq(#api.slot_list(api.track_list()[1]), 0, "emptied")
  api.undo()
  eq(#api.slot_list(api.track_list()[1]), 1, "and back with undo")
  local _ = id
end)

-- Launching ------------------------------------------------------------------

test("a launch lands on the next bar and the timeline falls silent meanwhile", function()
  start()
  local t, id = synth("Lead", 0, 69)
  t:add_clip({ start = 0, length = 64, notes = { { pitch = 45, start = 0, length = 64 } } })
  daw.transport.seek(0)
  daw.transport.play()
  until_(function() return daw.transport.position > 0.5 end, 10000, "the song to play")
  launcher.launch(t.id, 0)
  until_(function() return state(t.id).queued == 0 or state(t.id).slot == 0 end, 5000, "the launch to be queued")
  local s = state(t.id)
  if s.queued then eq(s.at, 4, "queued for the next bar") end
  until_(function() return state(t.id).slot == 0 end, 10000, "the clip to start")
  eq(state(t.id).since, 4, "it began on the bar")
  eq(launcher.playing(t.id), 0, "the track plays the slot")
  near(state(t.id).length, 4, 1e-9, "its loop's length")
  launcher.stop(t.id)
  until_(function() return state(t.id).stopped end, 10000, "the track to stop")
  eq(state(t.id).since % 4, 0, "on a bar")
  launcher.back(t.id)
  until_(function() return launcher.playing(t.id) == "arrangement" end, 10000, "the timeline again")
  daw.transport.stop()
  local _ = id
end)

test("launching while stopped starts the song and the clip at once, and stopping the song ends it", function()
  start()
  local t = synth("Lead", 1)
  daw.transport.seek(2)
  launcher.launch(t.id, 1)
  eq(daw.transport.playing, true, "the song plays")
  until_(function() return state(t.id).slot == 1 end, 5000, "the clip to start")
  near(state(t.id).since, 2, 1e-9, "where the playhead was")
  daw.transport.stop()
  until_(function() return launcher.playing(t.id) == "arrangement" end, 5000, "the timeline again")
end)

test("a scene launches its row together and stops tracks with nothing in it", function()
  start()
  local a = synth("A", 0, 60)
  api.clip_add(a.id, { slot = 1, length = 4, notes = { { pitch = 62, start = 0, length = 1 } } })
  local b = synth("B", 0, 64)
  local c = synth("C", 1, 67)
  launcher.scene(0)
  until_(function() return state(a.id).slot == 0 and state(b.id).slot == 0 end, 5000, "the first scene")
  eq(state(a.id).since, state(b.id).since, "together")
  eq(launcher.playing(c.id), "arrangement", "a track without a clip in the row is left alone")
  launcher.scene(1)
  until_(function() return state(a.id).slot == 1 and state(c.id).slot == 1 end, 10000, "the second scene")
  eq(state(a.id).since, state(c.id).since, "together again")
  until_(function() return state(b.id).stopped end, 5000, "B to stop")
  eq(state(b.id).since, state(a.id).since, "on the same boundary")
  launcher.stop()
  until_(function() return state(a.id).stopped and state(c.id).stopped end, 10000, "every clip to stop")
  launcher.back()
  until_(function() return next(launcher.state()) == nil end, 10000, "every track back")
  daw.transport.stop()
end)

test("a toggle clip stops when pressed again and a gate clip when let go", function()
  start()
  local t, id = synth("Lead", 0)
  api.clip_set(id, "mode", "toggle")
  api.clip_set(id, "quantize", "off")
  launcher.press(t.id, 0)
  until_(function() return state(t.id).slot == 0 end, 5000, "the toggle to start")
  launcher.press(t.id, 0)
  until_(function() return state(t.id).stopped end, 5000, "the toggle to stop")
  api.clip_set(id, "mode", "gate")
  launcher.press(t.id, 0)
  until_(function() return state(t.id).slot == 0 end, 5000, "the gate to start")
  launcher.release(t.id, 0)
  until_(function() return state(t.id).stopped end, 5000, "the gate to stop")
  daw.transport.stop()
end)

test("a slot's quantize wins over the project's and a launch's over both", function()
  start()
  local t, id = synth("Lead", 0)
  launcher.set_quantize("4bars")
  api.clip_set(id, "quantize", "1/16")
  daw.transport.seek(1.1)
  daw.transport.play()
  launcher.launch(t.id, 0)
  until_(function() return state(t.id).slot == 0 end, 5000, "the clip to start")
  local since = state(t.id).since
  eq(since > 1.1 and since <= 1.5 and (since * 4) % 1 == 0, true, "on a sixteenth: " .. since)
  launcher.launch(t.id, 0, { quantize = "bar" })
  until_(function() return state(t.id).since ~= since end, 10000, "the clip to start again")
  eq(state(t.id).since % 4, 0, "on a bar")
  daw.transport.stop()
end)

-- Rendering and capturing ------------------------------------------------------

test("a render plays the timeline, not what is launched", function()
  start()
  local t = synth("Lead", 0, 69)
  launcher.launch(t.id, 0)
  until_(function() return state(t.id).slot == 0 end, 5000, "the clip to start")
  local info = render({ start = 0, ["end"] = 4, tail = 0, bits = 16 })
  local left = T.channel_peaks(info)
  eq(left, 0, "the track has nothing on its timeline")
  daw.transport.stop()
end)

test("a captured performance is written into the timeline on its boundaries and renders there", function()
  start()
  local t = synth("Lead", 0, 69)
  local b = synth("Bass", 0, 45)
  b:add_clip({ start = 0, length = 32, notes = { { pitch = 33, start = 0, length = 32 } } })
  launcher.capture(true)
  daw.transport.seek(0)
  daw.transport.play()
  until_(function() return daw.transport.position > 0.3 end, 10000, "the song to play")
  launcher.launch(t.id, 0)
  until_(function() return state(t.id).slot == 0 end, 10000, "the clip to start")
  launcher.stop(b.id)
  until_(function() return daw.transport.position > 9 end, 20000, "two bars of it")
  daw.transport.stop()
  launcher.capture(false)
  local clips = api.clip_list(t.id)
  eq(#clips, 1, "one clip for the stretch it played")
  eq(clips[1].start, 4, "from the bar it began on")
  eq(clips[1].loop, true, "looping as the slot did")
  near(clips[1].loop_length, 4, 1e-9, "every four beats")
  local bass = api.clip_list(b.id)
  eq(#bass, 2, "the stopped track's timeline is cleared while it was stopped")
  eq(bass[1].start .. " " .. bass[1].length, "0 8", "up to the bar it stopped on, the one after the lead began")
  eq(bass[2].start > 9, true, "and from where the song stopped")
  -- Rendered alone, the lead starts on the second bar, to the frame.
  local info = render({ start = 0, ["end"] = 8, tail = 0, bits = 16, tracks = { t.id } })
  local bar = 2 * info.sample_rate -- a bar at 120 BPM, in frames
  local first = first_sound(info)
  eq(first >= bar and first <= bar + 2, true, "the first sound at frame " .. first .. ", the bar at " .. bar)
  api.undo()
  eq(#api.clip_list(t.id), 0, "one undo takes the capture away")
end)
