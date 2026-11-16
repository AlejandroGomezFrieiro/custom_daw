-- VCAs (runtime/lua/daw/vca.lua): faders, mutes and solos over tracks that
-- are not routed to them, and groups whose faders move together. Loaded by
-- tests/suite.lua with its helpers.
local T = ...
local test, eq, near, fails, fresh, render = T.test, T.eq, T.near, T.fails, T.fresh, T.render
local api = daw.api

local function db(x) return 10 ^ (x / 20) end

--- A track holding a steady level of `level` for 8 beats (4 s at 120 BPM).
local function steady_track(name, level)
  local t = daw.add_track({ name = name })
  t:add_clip({ file = T.write_wav(T.scratch .. "/vca-" .. name .. ".wav", (function()
    local s = {}
    for i = 1, 4 * 48000 do s[i] = level end
    return s
  end)()), start = 0, length = 8 })
  return t
end

local function setup()
  fresh()
  daw.project.tempo = 120
  return steady_track("Kick", 0.5), steady_track("Snare", 0.25), steady_track("Pad", 0.125)
end

--- The loudest of both channels between two seconds of a render.
local function peak(from, to, opts)
  local info = render(opts or { tail = 0, bits = 16 })
  local l, r = T.channel_peaks(info, from, to)
  return math.max(l, r)
end

test("a VCA fader moves its members by as many dB without changing their own faders", function()
  local kick, snare, pad = setup()
  local drums = daw.vca.make({ kick }, "Drums")
  eq(daw.vca.is_vca(drums), true, "it is marked")
  eq(daw.vca.is_vca(kick), false, "and a track is not")
  eq(daw.groups.is_group(drums), false, "it is not a group")
  eq(daw.vca.members(drums)[1], kick.id, "the tracks under it are named")
  eq(daw.vca.of(kick)[1], drums.id, "and each knows its VCAs")
  local only = { tail = 0, bits = 16, tracks = { kick.id } }
  near(peak(0.2, 3, only), 0.5, 0.002, "at 0 dB the member is as it was")
  drums.volume = -6
  near(peak(0.2, 3, only), 0.5 * db(-6), 0.002, "6 dB down on the VCA")
  eq(kick.volume, 0, "the member's own fader is where it was")
  kick.volume = -6
  near(peak(0.2, 3, only), 0.5 * db(-12), 0.002, "its own fader adds to the VCA's")
  drums.volume = 6
  near(peak(0.2, 3, only), 0.5, 0.002, "and the VCA can raise it")
  near(peak(0.2, 3, { tail = 0, bits = 16, tracks = { snare.id } }), 0.25, 0.002, "tracks outside it are as they were")
  eq(api.track_get(kick.id).output, nil, "nothing is routed")
end)

test("a track in two VCAs has both their gains", function()
  local kick, snare = setup()
  local a, b = daw.vca.make({ kick, snare }, "A"), daw.vca.make({ kick }, "B")
  a.volume, b.volume = -6, -6
  near(peak(0.2, 3, { tail = 0, bits = 16, tracks = { kick.id } }), 0.5 * db(-12), 0.002, "they add in dB")
  near(peak(0.2, 3, { tail = 0, bits = 16, tracks = { snare.id } }), 0.25 * db(-6), 0.002, "a track in one has one")
  daw.vca.unassign(kick, a)
  near(peak(0.2, 3, { tail = 0, bits = 16, tracks = { kick.id } }), 0.5 * db(-6), 0.002, "taken out of one")
  daw.vca.unassign(kick)
  near(peak(0.2, 3, { tail = 0, bits = 16, tracks = { kick.id } }), 0.5, 0.002, "and out of all")
  fails(function() daw.vca.assign(a, b) end, "VCA", "a VCA cannot be under a VCA")
  fails(function() daw.vca.assign(kick, snare) end, "not a VCA", "and only a VCA takes tracks")
end)

test("a VCA's mute silences its members and its solo makes them the only sound", function()
  local kick, snare, pad = setup()
  local drums = daw.vca.make({ kick, snare }, "Drums")
  near(peak(0.2, 3), 0.875, 0.003, "all three sound")
  drums.mute = true
  near(peak(0.2, 3), 0.125, 0.002, "the pad alone while the VCA is muted")
  eq(kick.mute, false, "the members' own mutes are not touched")
  drums.mute = false
  drums.solo = true
  near(peak(0.2, 3), 0.75, 0.003, "its members alone while it is soloed")
  eq(kick.solo, false, "without their own solos being set")
  drums.solo = false
  pad.solo = true
  near(peak(0.2, 3), 0.125, 0.002, "a track's own solo still works")
  pad.solo = false
  near(peak(0.2, 3), 0.875, 0.003, "and all is as it was")
end)

test("a VCA's automation moves its members sample by sample, with their own lanes", function()
  local kick, snare = setup()
  local drums = daw.vca.make({ kick }, "Drums")
  -- At 120 BPM a beat is half a second: beat 2 is at 1 s, beat 6 at 3 s.
  drums:automate("volume"):set_points({ { 0, 0 }, { 4, -20 } })
  kick.volume = -6
  local only = { tail = 0, bits = 16, tracks = { kick.id } }
  local info = render(only)
  near(T.channel_peaks(info, 0.99, 1.01), 0.5 * db(-16) + 0.0, 0.004, "10 dB down half way, and 6 of its own")
  near(T.channel_peaks(info, 1.98, 2.0), 0.5 * db(-26), 0.004, "20 dB down at the end of the lane")
  near(T.channel_peaks(info, 3.5, 3.9), 0.5 * db(-26), 0.004, "held after it")
  -- The member's own lane adds to the VCA's: jumps and slopes included.
  kick.volume = 0
  kick:automate("volume"):set_points({ { 0, 0 }, { 8, -12 } })
  drums:lane("volume"):set_points({ { 0, -8 }, { 4, 0 }, { 4, -6 }, { 8, -6 } })
  info = render(only)
  near(T.channel_peaks(info, 0.99, 1.01), 0.5 * db(-3 - 4), 0.004, "beat 2: -3 and -4")
  near(T.channel_peaks(info, 1.98, 1.995), 0.5 * db(-6), 0.004, "just before the jump: -6 and 0")
  near(T.channel_peaks(info, 2.99, 3.01), 0.5 * db(-9 - 6), 0.004, "beat 6: -9 and -6")
  -- The VCA's lane off, its fader is what counts.
  drums:lane("volume").enabled = false
  drums.volume = -3
  info = render(only)
  near(T.channel_peaks(info, 0.99, 1.01), 0.5 * db(-3 - 3), 0.004, "a lane that is off leaves the fader")
  drums:lane("volume").enabled = true
  kick:lane("volume").enabled = false
  info = render(only)
  near(T.channel_peaks(info, 0.99, 1.01), 0.5 * db(-4), 0.004, "and the same for the member's lane")
  -- Taken out of the VCA, the lane the VCA made is gone.
  kick:lane("volume").enabled = true
  daw.vca.unassign(kick)
  info = render(only)
  near(T.channel_peaks(info, 0.99, 1.01), 0.5 * db(-3), 0.004, "out of the VCA the track has its own lane only")
end)

test("renders with VCA automation are the same on any number of threads", function()
  local kick, snare, pad = setup()
  local drums = daw.vca.make({ kick, snare }, "Drums")
  drums:automate("volume"):set_points({ { 0, 0 }, { 4, -20 }, { 8, -3 } })
  snare:automate("volume"):set_points({ { 0, -2 }, { 6, 0 } })
  local first
  for _, threads in ipairs({ 1, 2, 7 }) do
    local info = render({ tail = 0, bits = 32, threads = threads })
    local data = T.read_file(info.path)
    first = first or data
    eq(data == first, true, "the render on " .. threads .. " thread" .. (threads == 1 and "" or "s") .. " is the same bytes")
  end
end)

test("VCAs are saved with the project and undone", function()
  local kick, snare = setup()
  api.undo_checkpoint()
  local drums = daw.vca.make({ kick, snare }, "Drums")
  api.undo_checkpoint()
  drums.volume = -9
  api.undo_checkpoint()
  daw.undo()
  eq(drums:get().volume, 0, "undoing the VCA's fader")
  daw.redo()
  near(peak(0.2, 3, { tail = 0, bits = 16, tracks = { kick.id } }), 0.5 * db(-9), 0.002, "redone, it sounds")
  drums:automate("volume"):set_points({ { 0, -9 }, { 4, -9 } })
  api.undo_checkpoint()

  local path = daw.project.save(T.scratch .. "/vca.json")
  daw.project.load(path)
  local loaded = daw.track("Drums")
  eq(daw.vca.is_vca(loaded), true, "the VCA comes back")
  eq(#daw.vca.members(loaded), 2, "with its members")
  eq(daw.vca.of(daw.track("Kick"))[1], loaded.id, "which know it")
  near(peak(0.2, 3, { tail = 0, bits = 16, tracks = { daw.track("Kick").id } }), 0.5 * db(-9), 0.002, "and sounds the same")

  api.undo_checkpoint()
  daw.vca.unassign(daw.track("Snare"), loaded)
  api.undo_checkpoint()
  eq(#daw.vca.members(loaded), 1, "a track taken out")
  daw.undo()
  eq(#daw.vca.members(loaded), 2, "is put back by undo")
  daw.vca.dissolve(loaded)
  eq(daw.track("Drums"), nil, "a dissolved VCA is gone")
  eq(#(daw.track("Kick"):get().meta.vcas or {}), 0, "and the tracks forget it")
  near(peak(0.2, 3, { tail = 0, bits = 16, tracks = { daw.track("Kick").id } }), 0.5, 0.002, "and are at their own faders")
  api.undo_checkpoint()
  daw.undo()
  eq(#daw.vca.members(daw.track("Drums")), 2, "undone, it holds them again")
end)

test("VCA commands put the selected tracks under a VCA and take them out", function()
  local kick, snare, pad = setup()
  daw.cursor.set_track(kick)
  daw.commands.exec("vca.make Drums")
  local drums = daw.track("Drums")
  eq(daw.vca.is_vca(drums), true, "vca.make makes a VCA")
  eq(daw.vca.members(drums)[1], kick.id, "over the cursor's track")
  eq(daw.cursor.track_id(), drums.id, "and leaves the cursor on it")
  daw.cursor.set_track(snare)
  daw.commands.exec("vca.assign drum")
  eq(#daw.vca.members(drums), 2, "vca.assign finds a VCA by part of its name")
  daw.commands.exec("vca.release drum")
  eq(#daw.vca.members(drums), 1, "vca.release takes the track out")
  daw.cursor.set_track(kick)
  daw.commands.exec("vca.release")
  eq(#daw.vca.members(drums), 0, "alone it takes the track out of all")
  daw.cursor.set_track(drums)
  daw.commands.exec("vca.dissolve")
  eq(daw.track("Drums"), nil, "vca.dissolve takes it away")
  daw.keymap.feed("<Esc>")
  daw.ui.focus("arrange")
  daw.cursor.set_track(pad)
  daw.keymap.feed(",vn")
  eq(require("daw.views.cmdline").state() ~= nil, true, "the key asks for a name")
  daw.keymap.feed("<C-u>Strings<CR>")
  eq(daw.vca.is_vca(daw.track("Strings")), true, ",vn makes a VCA")
  eq(daw.vca.of(pad)[1], daw.track("Strings").id, "over the cursor's track")
end)

test("VCAs are drawn after the tracks, in the arrange view's rows and the mixer's strips", function()
  local kick, snare, pad = setup()
  local drums = daw.vca.make({ kick }, "Drums")
  daw.add_track({ name = "Late" })
  local names = {}
  for i, id in ipairs(daw.groups.rows()) do names[i] = api.track_get(id).name end
  eq(table.concat(names, " "), "Kick Snare Pad Late Drums", "the VCA comes last however it was made")
  local state = daw.frontend.state(0)
  local by_name = {}
  for _, t in ipairs(state.tracks) do by_name[t.name] = t end
  eq(by_name.Drums.vca, true, "the window is told which track is a VCA")
  eq(by_name.Drums.vcas, "Kick", "and whom it moves")
  eq(by_name.Kick.vcas, "Drums", "a member, which VCAs move it")
  eq(by_name.Snare.vca, false, "other tracks are not")
  local shown = daw.ui.visible("mixer")
  if not shown then daw.ui.toggle("mixer") end
  local was = daw.opt.mixer_height
  daw.opt.mixer_height = 16
  daw.ui.focus("mixer")
  local screen = table.concat(api.ui_snapshot(120, 60), "\n")
  eq(screen:find("Drums", 1, true) ~= nil and screen:find("no tracks", 1, true) == nil, true, "the mixer draws the VCA's strip")
  eq(screen:find("vca Dru", 1, true) ~= nil, true, "and names a member's VCA\n" .. screen)
  daw.opt.mixer_height = was
  daw.ui.focus("arrange")
  if not shown then daw.ui.toggle("mixer") end
end)

test("the window's gestures make VCAs and assign tracks through commands", function()
  local kick, snare = setup()
  local act = daw.frontend.act
  act.track_command(kick.id, "vca.make Drums")
  local drums = daw.track("Drums")
  eq(daw.vca.members(drums)[1], kick.id, "the track menu makes a VCA over the track")
  act.track_command(snare.id, "vca.assign Drums")
  eq(#daw.vca.members(drums), 2, "and puts another under it")
  act.set_volume(drums.id, -4)
  eq(drums:get().volume, -4, "the VCA's strip moves its fader like any other")
  act.toggle(drums.id, "mute")
  eq(drums:get().mute, true, "and its mute")
  act.track_command(snare.id, "vca.release")
  eq(#daw.vca.members(drums), 1, "the menu takes a track out")
end)

test("linked faders move the members of a group together, in dB", function()
  fresh()
  local a, b, c = daw.add_track({ name = "A" }), daw.add_track({ name = "B" }), daw.add_track({ name = "C" })
  local group = daw.groups.make({ a, b }, "Pair")
  a.volume, b.volume = -3, -9
  daw.flush()
  a.volume = -6
  daw.flush()
  eq(b.volume, -9, "unlinked, a fader moves alone")
  daw.groups.link(group, true)
  eq(daw.groups.linked(group), true, "the link is a group's option")
  a.volume = -10
  daw.flush()
  near(b.volume, -13, 0.001, "linked, the others move by as many dB")
  eq(c.volume, 0, "tracks outside the group do not")
  eq(group.volume, 0, "nor does the group's own fader")
  b.volume = -3
  daw.flush()
  near(a.volume, 0, 0.001, "from any member")
  api.undo_checkpoint()
  a.volume = 24
  daw.flush()
  eq(b.volume <= 24, true, "a fader stops at its end")
  api.undo_checkpoint()
  daw.undo()
  daw.flush()
  near(a.volume, 0, 0.001, "undone, both go back at once")
  near(b.volume, -3, 0.001, "to what they were")
  api.undo_checkpoint()

  local path = daw.project.save(T.scratch .. "/linked.json")
  daw.project.load(path)
  daw.flush()
  eq(daw.groups.linked(daw.track("Pair")), true, "the link is saved")
  daw.track("A").volume = -5
  daw.flush()
  near(daw.track("B").volume, -8, 0.001, "and works when the project is opened")
  daw.groups.link(daw.track("Pair"), false)
  daw.track("A").volume = -6
  daw.flush()
  near(daw.track("B").volume, -8, 0.001, "until it is let go")
end)

test("track.group with no name asks for one", function()
  fresh()
  local a = daw.add_track({ name = "A" })
  daw.cursor.set_track(a)
  daw.commands.exec("track.group")
  eq(require("daw.views.cmdline").state() ~= nil, true, "the prompt opens")
  daw.keymap.feed("<C-u>Pair<CR>")
  eq(daw.groups.is_group(daw.track("Pair")), true, "and the answer names the group")
end)
