-- MIDI output: a track sends what it plays to a port (crates/daw-engine/src/midi_out.rs).
-- Read back through a port of the program's own MIDI input, on the null
-- audio backend with the sequencer opened anyway.
local T = ...
local test, eq, near, fails, fresh = T.test, T.eq, T.near, T.fails, T.fresh
local api = daw.api

--- Wait, with the session looked after, until `ready()` or `ms` pass.
local function wait_for(ready, ms)
  local deadline = api.now() + (ms or 10000)
  while not ready() and api.now() < deadline do daw.wait(10) end
  return ready()
end

local function output_named(name)
  for _, port in ipairs(daw.midi.outputs()) do
    if port.name == name then return port end
  end
end

--- Run `fn` with the sequencer open and a port of ours, "Loop", that the
--- tracks can send to and the test hears from. Nil and the reason when the
--- sequencer cannot be opened here.
local function with_loop(fn)
  api.engine_restart({ backend = "null", midi = true })
  daw.midi.open_port("Loop")
  local ok, err
  if wait_for(function() return output_named("daw: Loop") end, 4000) then
    ok, err = xpcall(fn, debug.traceback)
  else
    ok, err = true, "skipped: no ALSA sequencer to send MIDI through"
  end
  daw.midi.close_port("Loop")
  api.engine_restart({ backend = "null" })
  if not ok then error(err, 0) end
  return err
end

test("a track sends its clip's notes to a MIDI port, on its channel, in order and in time", function()
  fresh()
  return with_loop(function()
    daw.project.tempo = 120
    local t = daw.add_track({ name = "Hardware" })
    t:add_clip({ start = 0, length = 8, notes = {
      { pitch = "C4", start = 0, length = 0.5 }, { pitch = "E4", start = 1, length = 0.5 },
      { pitch = "G4", start = 2, length = 0.5 }, { pitch = "C5", start = 3, length = 4 },
    } })
    t.midi_output = { port = "daw: Loop", channel = 3 }
    eq(t.midi_output.port .. " " .. t.midi_output.channel, "daw: Loop 3", "the track names its output")
    -- What comes back is recorded on a track that takes channel 3 of "Loop"
    -- alone: the notes are where they arrived, in beats.
    local keys = daw.add_track({ name = "Keys" })
    keys.midi_input = { port = "Loop", channel = 3 }
    keys.armed = true
    daw.transport.record_offset = 0
    daw.transport.record()
    wait_for(function() return daw.transport.position >= 8.2 end, 15000)
    daw.transport.stop()
    local clip = keys:clips()[1]
    eq(clip ~= nil, true, "what the track sent came back on its channel")
    local notes = clip:notes()
    table.sort(notes, function(a, b) return a.start < b.start end)
    local pitches = {}
    for i, n in ipairs(notes) do pitches[i] = n.pitch end
    eq(table.concat(pitches, " "), "60 64 67 72", "the notes, in their order")
    for i, n in ipairs(notes) do
      -- A block or two late, where a busy machine wakes the reader late.
      near(clip.start + n.start, i - 1, 0.12, "note " .. i .. " where it was played")
    end
    near(notes[3].length, 0.5, 0.12, "a note's end goes out in time too")
  end)
end)

test("MIDI output: a track's port and channel are checked, saved and taken away with it", function()
  fresh()
  local t = daw.add_track({ name = "Hardware" })
  fails(function() t.midi_output = { port = "x", channel = 17 } end, "1 to 16", "a channel past 16")
  fails(function() t.midi_output = { channel = 2 } end, nil, "no port")
  t.midi_output = "Some synth"
  eq(t.midi_output.port .. " " .. tostring(t.midi_output.channel), "Some synth nil", "a port by name, each message on its own channel")
  t.midi_output = { port = "Some synth", channel = 10 }
  local path = T.scratch .. "/midi_out.json"
  daw.project.save(path)
  daw.project.load(path)
  eq(daw.track("Hardware").midi_output.channel, 10, "saved and loaded")
  local copy = daw.track("Hardware"):duplicate()
  eq(copy.midi_output.port, "Some synth", "a copy sends where the original does")
  daw.track("Hardware").midi_output = "none"
  eq(daw.track("Hardware").midi_output, nil, "none takes it away")
  fresh()
  daw.add_track({ name = "Plain" })
  daw.project.save(path)
  eq(T.read_file(path):find("midi_output", 1, true), nil, "a project without it is written as before")
end)

test("the terminal and the window choose a track's MIDI output", function()
  fresh()
  return with_loop(function()
    daw.midi.open_output("To synth")
    eq(wait_for(function() return output_named("To synth") end, 4000) ~= nil, true, "a port of ours for others to read is listed")
    local t = daw.add_track({ name = "Hardware" })
    daw.cursor.set_track(t)
    daw.commands.exec("track.midi_out To synth 5")
    eq(t.midi_output.port .. " " .. t.midi_output.channel, "To synth 5", ":track.midi_out sets port and channel")
    daw.commands.exec("track.midi_out none")
    eq(t.midi_output, nil, ":track.midi_out none takes it away")
    local menu = daw.frontend.input_menu(t.id)
    local labels = {}
    for i, entry in ipairs(menu.midi_out) do labels[i] = entry.label end
    eq(labels[1], "None", "the input menu has the outputs, none first")
    local at
    for i, label in ipairs(labels) do if label == "To synth" then at = i end end
    eq(at ~= nil, true, "and our own port")
    daw.frontend.act.choose_input(t.id, "midi_out", at)
    eq(t.midi_output.port, "To synth", "choosing one sends there")
    daw.frontend.act.choose_input(t.id, "midi_out_channel", 3)
    eq(t.midi_output.channel, 2, "and on a channel")
    daw.frontend.act.choose_input(t.id, "midi_out", 1)
    eq(t.midi_output, nil, "None takes it away")
    daw.midi.close_output("To synth")
  end)
end)
