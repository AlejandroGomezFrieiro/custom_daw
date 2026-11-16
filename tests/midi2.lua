-- MIDI 2.0 on the way out (crates/daw-engine/src/midi_form.rs): the form a
-- route sends in where the port takes no MIDI 2.0, heard back through a
-- port of the program's own MIDI input; and the editor for controller
-- moves, in the piano roll's strip and in the event list.
local T = ...
local test, eq, near, fails, fresh = T.test, T.eq, T.near, T.fails, T.fresh
local api = daw.api
local A = daw.frontend.act

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

--- Run `fn(heard)` with the sequencer open and a port of ours, "Loop", that
--- tracks send to; `heard` fills with what arrives there. Nil and the
--- reason when the sequencer cannot be opened here.
local function with_loop(fn)
  api.engine_restart({ backend = "null", midi = true })
  daw.midi.open_port("Loop")
  local heard = {}
  local handler = daw.on("midi.in", function(event)
    if event.port == "Loop" then heard[#heard + 1] = event end
  end)
  local ok, err
  if wait_for(function() return output_named("daw: Loop") end, 4000) then
    ok, err = xpcall(fn, debug.traceback, heard)
  else
    ok, err = true, "skipped: no ALSA sequencer to send MIDI through"
  end
  daw.off(handler)
  daw.midi.close_port("Loop")
  api.engine_restart({ backend = "null" })
  if not ok then error(err, 0) end
  return err
end

test("a MIDI output's form is checked, saved, undone and copied with the track", function()
  fresh()
  local t = daw.add_track({ name = "Hardware" })
  fails(function() t.midi_output = { port = "Synth", form = "midi3" } end, "unknown variant", "a form there is not")
  fails(function() t.midi_output = { port = "Synth", form = "mpe", members = 16 } end, "1 to 15", "a zone too wide")
  t.midi_output = { port = "Synth", channel = 2 }
  eq(t.midi_output.form, nil, "auto unless said: MIDI 2.0 where the port takes it, else plain")
  api.undo_checkpoint()
  t.midi_output = { port = "Synth", form = "mpe", members = 7 }
  api.undo_checkpoint()
  eq(daw.routes.midi_out_text(t:get()), "Synth · MPE", "said in words")
  daw.undo()
  eq(t.midi_output.form, nil, "undo takes the form back")
  daw.redo()
  eq(t.midi_output.form .. " " .. t.midi_output.members, "mpe 7", "redo brings it again")
  local path = T.scratch .. "/midi2.json"
  daw.project.save(path)
  daw.project.load(path)
  eq(daw.track("Hardware").midi_output.form, "mpe", "saved and loaded")
  eq(daw.track("Hardware"):duplicate().midi_output.members, 7, "a copy sends as the original does")
  -- Choosing another port keeps the form.
  daw.routes.set_midi_out(daw.track("Hardware").id, "Other", 3)
  eq(daw.track("Hardware").midi_output.form, "mpe", "the form stays with the route")
  fails(function() daw.routes.set_midi_out(daw.track("Hardware").id, "Other", 3, "loud") end, "auto, plain, mpe or cc14")
end)

test("the terminal and the window choose the form a track's MIDI output sends in", function()
  fresh()
  local t = daw.add_track({ name = "Hardware" })
  daw.cursor.set_track(t)
  daw.commands.exec("track.midi_out Some synth 5 mpe")
  eq(t.midi_output.port .. " " .. t.midi_output.channel .. " " .. t.midi_output.form, "Some synth 5 mpe",
    ":track.midi_out takes a form after the port and channel")
  daw.commands.exec("track.midi_out Some synth cc14")
  eq(t.midi_output.form .. " " .. tostring(t.midi_output.channel), "cc14 nil", "or alone")
  local menu = daw.frontend.input_menu(t.id)
  local labels, checked = {}, nil
  for i, entry in ipairs(menu.midi_out_form) do
    labels[i] = entry.label
    if entry.checked then checked = i end
  end
  eq(#labels, 4, "the window's input menu lists the forms")
  eq(labels[checked], "MIDI 1.0 with 14-bit controllers", "the one chosen is checked")
  A.choose_input(t.id, "midi_out_form", 3)
  eq(t.midi_output.form, "mpe", "choosing one sets it")
  eq(t.midi_output.port, "Some synth", "and keeps the port")
  A.choose_input(t.id, "midi_out_channel", 4)
  eq(t.midi_output.form .. " " .. t.midi_output.channel, "mpe 3", "choosing a channel keeps the form")
  A.choose_input(t.id, "midi_out_form", 1)
  eq(t.midi_output.form, nil, "and back to MIDI 2.0 where the port takes it, which goes unsaid")
end)

test("a route in MPE plays each note of a chord on a channel of its own, bent there alone", function()
  fresh()
  return with_loop(function(heard)
    daw.project.tempo = 120
    local t = daw.add_track({ name = "Hardware" })
    local clip = t:add_clip({ start = 0, length = 4, notes = {
      { pitch = "C4", start = 0, length = 2 }, { pitch = "E4", start = 0, length = 2 }, { pitch = "G4", start = 0, length = 2 },
    } })
    -- The E a semitone up, half a beat in.
    clip:set_controls({ { start = 0.5, type = "bend", key = "E4", value = 1 / 48 } })
    t.midi_output = { port = "daw: Loop", form = "mpe", members = 4 }
    daw.transport.play()
    local function ons()
      local out = {}
      for _, e in ipairs(heard) do
        if e.type == "note_on" then out[e.pitch] = e.channel end
      end
      return out
    end
    wait_for(function()
      for _, e in ipairs(heard) do
        if e.type == "bend" and e.value > 0 then return true end
      end
    end, 8000)
    daw.transport.stop()
    local on = ons()
    eq(string.format("%s %s %s", on[60], on[64], on[67]), "2 3 4", "the chord on member channels 2, 3 and 4")
    local bend
    for _, e in ipairs(heard) do
      if e.type == "bend" and e.value > 0 then bend = e end
    end
    eq(bend and bend.channel, on[64], "the E's own bend is its channel's pitch bend")
    near(bend.value * 48, 1, 0.01, "a semitone, over the zone's 48")
    local announced = false
    for _, e in ipairs(heard) do
      if e.type == "cc" and e.number == 6 and e.channel == 1 then announced = math.floor(e.value * 127 + 0.5) == 4 end
    end
    eq(announced, true, "the zone was announced on channel 1, with its four member channels")
    wait_for(function()
      local offs = 0
      for _, e in ipairs(heard) do if e.type == "note_off" then offs = offs + 1 end end
      return offs >= 3
    end, 4000)
    local offs = {}
    for _, e in ipairs(heard) do
      if e.type == "note_off" then offs[e.pitch] = e.channel end
    end
    eq(string.format("%s %s %s", offs[60], offs[64], offs[67]), "2 3 4", "stopping ends each note on its channel")
  end)
end)

test("a route with 14-bit controllers sends the fine part of control changes below 32", function()
  fresh()
  return with_loop(function(heard)
    daw.project.tempo = 120
    local t = daw.add_track({ name = "Hardware" })
    local clip = t:add_clip({ start = 0, length = 2, notes = {} })
    -- Halfway, and one fourteen-bit step past it.
    clip:set_controls({ { start = 0.25, type = "cc", number = 1, value = (8192 + 1) / 16383 } })
    t.midi_output = { port = "daw: Loop", channel = 3, form = "cc14" }
    daw.transport.play()
    wait_for(function()
      for _, e in ipairs(heard) do if e.type == "cc" and e.number == 33 then return true end end
    end, 8000)
    daw.transport.stop()
    local coarse, fine
    for _, e in ipairs(heard) do
      if e.type == "cc" and e.number == 1 then coarse = e end
      if e.type == "cc" and e.number == 33 then fine = e end
    end
    eq(coarse and coarse.channel, 3, "the coarse part on its channel")
    eq(fine and fine.channel, 3, "and the fine part, on 33")
    eq(math.floor(coarse.value * 127 + 0.5) * 128 + math.floor(fine.value * 127 + 0.5), 8193,
      "together the fourteen bits")
  end)
end)
