-- Routes between tracks besides outputs and sends: side-chains, which a
-- device on one track takes from another (runtime/lua/daw/routes.lua).
local T = ...
local test, eq, near, fails, fresh, render = T.test, T.eq, T.near, T.fails, T.fresh, T.render
local api = daw.api

local function plugin_kind(format, pattern)
  for _, info in ipairs(daw.device_types()) do
    if info.format == format and info.name:find(pattern) then return info.kind end
  end
end

--- A pad holding one note for eight beats, and a kick hitting on beats 0,
--- 2, 4 and 6 for a quarter of a beat each, at 120 BPM: a beat is half a
--- second, so the kick sounds from 0 to 0.125 s, 1 to 1.125 s and so on.
local function pad_and_kick()
  fresh()
  daw.project.tempo = 120
  local pad = daw.add_track({ name = "Pad" })
  pad:add_device("synth", { attack = 0.001, release = 0.01, wave = 0 })
  pad:add_clip({ start = 0, length = 8, notes = { { pitch = "A3", start = 0, length = 8 } } })
  local kick = daw.add_track({ name = "Kick" })
  kick:add_device("synth", { attack = 0.0005, release = 0.005, wave = 1, gain = 6 })
  local hits = {}
  for beat = 0, 6, 2 do hits[#hits + 1] = { pitch = "A2", start = beat, length = 0.25, velocity = 127 } end
  kick:add_clip({ start = 0, length = 8, notes = hits })
  return pad, kick
end

--- The pad's level while the kick hits and between the hits, from a render
--- where the kick is muted: it keys from before its fader, so it is not
--- heard but still drives the side-chain.
local function levels()
  local info = render({ tail = 0, bits = 16 })
  local during = T.channel_peaks(info, 1.03, 1.11)
  local between = T.channel_peaks(info, 1.6, 1.9)
  return during, between
end

test("a compressor ducks a pad under a kick through its side-chain", function()
  local pad, kick = pad_and_kick()
  local comp = pad:add_device("compressor", { threshold = -10, ratio = 20, attack = 0.1, release = 20, knee = 0 })
  kick.mute = true
  local during, between = levels()
  eq(between > 0.05, true, "the pad sounds")
  near(during / between, 1, 0.1, "listening to its own quiet input the compressor leaves the pad alone")

  comp:set_sidechain(kick, { pre = true })
  comp:set({ threshold = -30, ratio = 50 })
  eq(comp.sidechain, kick.id, "the device names the track it listens to")
  eq(comp.sidechain_pre, true, "and that it takes it before the fader")
  during, between = levels()
  eq(during < between * 0.1, true, string.format("the pad ducks under the kick: %.3f against %.3f", during, between))

  comp:set("listen", 1)
  during, between = levels()
  eq(during > 0.05 and between < 0.002, true, string.format("listening plays the key alone: %.3f, then %.4f", during, between))

  comp:set("listen", 0)
  comp.sidechain_pre = false
  during, between = levels()
  near(during / between, 1, 0.1, "after the fader, a muted kick keys nothing")
  kick.mute = false
  kick.volume = -120
  during, between = levels()
  near(during / between, 1, 0.1, "nor does one faded out")
end)

test("a gate opens for the key, not for what it gates", function()
  local pad, kick = pad_and_kick()
  local gate = pad:add_device("gate", { threshold = -30, range = -80, attack = 0.1, hold = 0, release = 10 })
  kick.mute = true
  gate:set_sidechain(kick, { pre = true })
  local during, between = levels()
  eq(during > 0.05 and between < 0.002, true, string.format("open on the kick, shut between: %.3f, %.4f", during, between))
end)

test("a side-chain lines up with what the device hears, through latency on either side", function()
  fresh()
  daw.project.tempo = 120
  -- The pad's track plays the kick upside down, through a gate that
  -- listens to the kick: if the two meet at the master at the same time
  -- they cancel. The kick is late through a look-ahead limiter, and the
  -- devices before the gate are late through a compressor's look-ahead.
  local pad = daw.add_track({ name = "Pad" })
  pad:add_device("compressor", { lookahead = 3, threshold = 0 })
  local gate = pad:add_device("gate", { listen = 1 })
  pad:add_device("utility", { invert_l = 1, invert_r = 1 })
  local kick = daw.add_track({ name = "Kick" })
  kick:add_device("synth", { attack = 0.0005, release = 0.005, wave = 1 })
  kick:add_device("limiter", { ceiling = -3 })
  kick:add_clip({ start = 0, length = 4, notes = { { pitch = "A2", start = 1, length = 0.5 } } })
  gate:set_sidechain(kick)
  local info = render({ tail = 0.2, bits = 16 })
  eq(T.channel_peaks(info, 0, 2.2) < 1e-4, true, "the kick and its upside-down key cancel")
  gate.sidechain = nil
  info = render({ tail = 0.2, bits = 16 })
  eq(T.channel_peaks(info, 0.5, 1) > 0.05, true, "without the key the kick is heard")
end)

test("side-chains and the threads that process tracks: the same file, byte for byte", function()
  fresh()
  local bus = daw.add_track({ name = "bus" })
  bus:add_device("compressor", { threshold = -30, ratio = 8, attack = 1, release = 40, lookahead = 2 })
  local keys = {}
  for i = 1, 12 do
    local t = daw.add_track({ name = "voice " .. i, pan = (i - 6) / 8 })
    t:add_device("synth", { wave = i % 4, attack = 0.002, release = 0.05 })
    if i % 3 == 0 then t:add_device("limiter") end
    local notes = {}
    for step = 0, 15 do notes[#notes + 1] = { pitch = 36 + (i * 7 + step * 5) % 36, start = step * 0.5, length = 0.3 } end
    t:add_clip({ start = 0, length = 8, notes = notes })
    if i % 2 == 0 then t.output = bus end
    if i % 4 == 1 then t:send(bus, -6, { pre = true }) end
    keys[i] = t
  end
  -- Each odd voice ducks under the next one up, and the bus under voice 3.
  for i = 1, 11, 2 do
    local comp = keys[i]:add_device("compressor", { threshold = -30, ratio = 6, attack = 0.5, release = 30 })
    comp:set_sidechain(keys[i + 1], { pre = i % 4 == 1 })
  end
  bus:devices()[1]:set_sidechain(keys[3])
  daw.flush()
  local alone = render({ tail = 0.5, threads = 1 })
  eq(alone.peak > 0.05, true, "something sounds")
  local want = T.read_file(alone.path)
  for _, threads in ipairs({ 2, 5, 16 }) do
    local info = render({ tail = 0.5, threads = threads })
    eq(T.read_file(info.path) == want, true, "on " .. threads .. " threads the same file")
  end
end)

test("a side-chain that would make a loop is refused, in every combination with outputs and sends", function()
  fresh()
  local a, b, c = daw.add_track({ name = "A" }), daw.add_track({ name = "B" }), daw.add_track({ name = "C" })
  local on_a = a:add_device("compressor")
  local on_b = b:add_device("compressor")
  local on_c = c:add_device("gate")
  fails(function() on_a:set_sidechain(a) end, "its own track", "a device on its own track")
  fails(function() on_a.sidechain = 0 end, "master", "the master")
  fails(function() on_a.sidechain = 999 end, "no track", "a track that is not there")

  a.output = b
  fails(function() on_a:set_sidechain(b) end, "loop", "from the track its own plays into")
  a.output = nil
  a:send(b, -6)
  fails(function() on_a:set_sidechain(b) end, "loop", "from the track its own sends to")
  daw.frontend.act.remove_send(a.id, 1)

  on_b:set_sidechain(a)
  fails(function() b.output = a end, "loop", "an output into the track it listens to")
  fails(function() b:send(a, 0) end, "loop", "a send into the track it listens to")
  fails(function() on_a:set_sidechain(b) end, "loop", "listening back the other way")
  on_c:set_sidechain(b)
  fails(function() on_a:set_sidechain(c) end, "loop", "round three tracks")
  fails(function() c.output = a end, "loop", "an output round three tracks")
  fails(function() api.device_move(on_b.id, a.id, 1) end, "loop", "moving the device onto the track it listens to")
  eq(on_b:track().id, b.id, "which stays where it was")

  -- What the frontends offer leaves out what would be refused.
  local names = {}
  for _, source in ipairs(daw.routes.sidechain_sources(on_a.id)) do names[#names + 1] = source.name end
  eq(table.concat(names, " "), "", "A can listen to nothing: B and C both hear it")
  names = {}
  for _, target in ipairs(daw.frontend.routing(a.id).targets) do names[#names + 1] = target.name end
  eq(table.concat(names, " "), "Master B C", "but it can play into them")
  names = {}
  for _, source in ipairs(daw.routes.sidechain_sources(on_c.id)) do names[#names + 1] = source.name end
  eq(table.concat(names, " "), "A B", "C can listen to the others")
end)

test("removing the track a device listens to takes the side-chain away, and undo brings it back", function()
  fresh()
  local pad, kick = daw.add_track({ name = "Pad" }), daw.add_track({ name = "Kick" })
  local comp = pad:add_device("compressor")
  local on_master = daw.master:add_device("compressor")
  comp:set_sidechain(kick, { pre = true })
  on_master:set_sidechain(kick)
  eq(api.track_get(pad.id).listens[1], kick.id, "the track says what it listens to")
  api.undo_checkpoint()
  kick:remove()
  eq(comp.sidechain, nil, "the device listens to its own input again")
  eq(comp.sidechain_pre, false, "and forgets where it took it")
  eq(on_master.sidechain, nil, "so does one on the master")
  daw.undo()
  eq(comp.sidechain, kick.id, "undo puts the side-chain back")
  eq(comp.sidechain_pre, true, "as it was")
end)

test("side-chains are saved, loaded, copied with a track, and left out of templates", function()
  fresh()
  local pad, kick = daw.add_track({ name = "Pad" }), daw.add_track({ name = "Kick" })
  local comp = pad:add_device("compressor")
  pad:add_device("delay")
  comp:set_sidechain(kick, { pre = true })
  local path = T.scratch .. "/sidechain.json"
  daw.project.save(path)
  local text = T.read_file(path)
  eq(select(2, text:gsub('"sidechain"', "")), 1, "the one side-chain is written")
  daw.project.load(path)
  local loaded = daw.track("Pad"):devices()[1]
  eq(loaded.sidechain, daw.track("Kick").id, "and read back")
  eq(loaded.sidechain_pre, true, "with where it is taken")

  local copy = daw.track("Pad"):duplicate()
  eq(copy:devices()[1].sidechain, daw.track("Kick").id, "a copy of the track listens to the same track")
  local snap = daw.track("Pad"):snapshot()
  daw.track("Kick"):remove()
  local restored = daw.restore_track(snap)
  eq(restored:devices()[1].sidechain, nil, "a track restored after its key is gone listens to its own input")

  fresh()
  local plain = daw.add_track({ name = "Plain" })
  plain:add_device("compressor")
  daw.project.save(path)
  eq(T.read_file(path):find("sidechain", 1, true), nil, "a project without side-chains is written as before")
end)

test("the device panel and the window choose a device's side-chain", function()
  fresh()
  local pad, kick = daw.add_track({ name = "Pad" }), daw.add_track({ name = "Kick" })
  local _ = daw.add_track({ name = "Hats" })
  local comp = pad:add_device("compressor")
  pad:add_device("delay")
  daw.cursor.set_track(pad)
  daw.ui.focus("devices")
  daw.ui.views.devices.row = 1
  daw.commands.exec("device.sidechain Kick pre=1")
  eq(comp.sidechain .. " " .. tostring(comp.sidechain_pre), kick.id .. " true", ":device.sidechain sets it")
  daw.flush()
  local text = table.concat(api.ui_snapshot(140, 30), "\n")
  eq(text:find("key Kick pre", 1, true) ~= nil, true, "the device panel shows it:\n" .. text)
  daw.commands.exec("device.sidechain none")
  eq(comp.sidechain, nil, ":device.sidechain none takes it away")
  daw.keymap.feed("K")
  eq(daw.ui.float ~= nil, true, "K chooses from a list")
  while daw.ui.float do daw.ui.close() end
  daw.ui.focus("arrange")

  local state = daw.frontend.state(-1)
  local card = state.devices[1]
  eq(card.keyed, true, "the window knows the compressor can listen to a side-chain")
  eq(state.devices[2].keyed, false, "and the delay cannot")
  eq(card.sidechain, "", "it listens to nothing yet")
  local menu = daw.frontend.sidechain_menu(comp.id)
  local labels = {}
  for i, entry in ipairs(menu) do labels[i] = entry.label end
  eq(table.concat(labels, "|"), "None: its own input|Kick|Hats|Before the fader", "its menu lists the tracks it can hear")
  daw.frontend.act.choose_sidechain(comp.id, 3)
  eq(comp.sidechain, daw.track("Hats").id, "choosing one sets it")
  daw.frontend.act.choose_sidechain(comp.id, 4)
  eq(comp.sidechain_pre, true, "the last entry takes it before the fader")
  eq(daw.frontend.state(-1).devices[1].sidechain, "Hats pre", "which the card shows")
  eq(daw.frontend.sidechain_menu(comp.id)[3].checked, true, "and the menu ticks")
  daw.frontend.act.choose_sidechain(comp.id, 1)
  eq(comp.sidechain, nil, "None takes it away")
end)

-- Plugins with a side-chain input, in each format.
for _, format in ipairs({ "clap", "lv2", "vst3" }) do
  test(format .. " side-chain plugins hear the key", function()
    local kind = plugin_kind(format, "Sidechain Compressor Stereo$")
    if not kind then return "skipped: test plugins not found" end
    local pad, kick = pad_and_kick()
    local comp = pad:add_device(kind)
    eq(comp.ports.sidechain, true, "the plugin says it takes a side-chain")
    comp:set("Sidechain listen", 1)
    kick.mute = true
    comp:set_sidechain(kick, { pre = true })
    local during, between = levels()
    eq(during > 0.02 and between < 0.01, true, string.format("listening, it plays the kick: %.3f, then %.4f", during, between))
    comp.sidechain = nil
    during = levels()
    eq(during < 0.01, true, string.format("without a key it hears nothing: %.4f", during))
  end)
end
