-- The how-to guides of the user guide for when something goes wrong, each
-- driven with the keys and commands that it gives (docs/how-to/fix-no-sound.md,
-- fix-crackles-and-dropouts.md, deal-with-a-plugin-that-crashes.md). Loaded
-- by tests/suite.lua with its helpers.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = paw.api

local function keys(text)
  paw.keymap.feed(text)
  api.undo_checkpoint()
  paw.flush()
end

local function start()
  fresh()
  paw.keymap.feed("<Esc><Esc>")
  while paw.ui.float do paw.ui.close() end
  paw.ui.focus("arrange")
end

--- The messages after the message `from` (the last one when the test began,
--- see `mark`), as one text. The list keeps the last 500 messages, so a
--- place in it moves; the message itself does not.
local function said(from)
  local out, seen = {}, from == nil
  for _, m in ipairs(paw.ui.messages) do
    if seen then out[#out + 1] = m.text end
    if m == from then seen = true end
  end
  return table.concat(out, "\n")
end

--- The last message now, for `said`.
local function mark()
  return paw.ui.messages[#paw.ui.messages]
end

local function wait_for(what, limit, fn)
  local deadline = api.now() + limit
  while not fn() do
    if api.now() > deadline then error("waited " .. limit .. " ms for " .. what, 2) end
    paw.wait(20)
  end
end

test("guide: fix no sound", function()
  start()
  local before = mark()
  keys(":engine<CR>")
  eq(said(before):find("^null: none") ~= nil, true, ":engine names the backend and the output device: " .. said(before))
  local lead = T.tone("Lead", 8)
  local keys_track = paw.add_track({ name = "Keys" })
  keys_track:add_clip({ start = 0, length = 8, notes = { { pitch = 64, start = 0, length = 8 } } })
  lead.mute = true
  keys_track.solo = true
  paw.flush()
  eq(T.render({ tail = 0 }).peak, 0, "nothing plays")
  keys(":t* unmute<CR>")
  keys(":t* unsolo<CR>")
  eq(lead.mute or keys_track.solo, false, ":t* unmute and :t* unsolo clear them")
  eq(T.render({ tail = 0 }).peak > 0, true, "the lead plays again")
  paw.ui.focus("arrange")
  paw.cursor.set_track(keys_track)
  lead.mute = true
  paw.flush()
  eq(T.render({ tail = 0 }).peak, 0, "a MIDI track with no instrument plays nothing")
  local header = table.concat(api.ui_snapshot(100, 30), "\n")
  eq(header:find("Synth", 1, true) ~= nil, true, "the header of the lead names its instrument")
  keys("aSynth<CR>")
  eq(T.render({ tail = 0 }).peak > 0, true, "a adds an instrument, and the notes play")
end)

test("guide: fix crackles and dropouts", function()
  start()
  local before = mark()
  keys(":engine.status<CR>")
  eq(said(before):find("xruns", 1, true) ~= nil, true, ":engine.status counts the xruns: " .. said(before))
  T.after(function() paw.audio.use({ buffer = 0 }) end)
  keys(":audio.buffer 1024<CR>")
  eq(api.engine_get().block, 1024, ":audio.buffer sets a larger block")
  T.after(function() paw.opt.threads = 0 end)
  keys(":engine threads=2<CR>")
  wait_for("the engine to use two threads", 3000, function() return api.engine_get().threads == 2 end)
  local heavy = T.tone("Heavy", 8)
  paw.ui.focus("arrange")
  paw.cursor.set_track(heavy)
  keys(":freeze<CR>")
  eq(said(before):find("frozen: Heavy", 1, true) ~= nil, true, ":freeze renders the heavy track")
end)

test("guide: deal with a plugin that crashes or hangs", function()
  start()
  -- A device in a process of its own stands for the plugin.
  local scripts = T.scratch .. "/guide-plugin"
  os.execute("mkdir -p '" .. scripts .. "'")
  T.write_file(scripts .. "/guide_fx.lua", "local dev = require('paw.dsp').device { name = 'Guide FX' }\n"
    .. "function dev.process(b) end\nreturn dev\n")
  paw.luadev.add_dir(scripts)
  local d = T.scratch .. "/guide-plugin"
  local lead = T.tone("Lead", 8)
  paw.ui.focus("arrange")
  paw.cursor.set_track(lead)
  keys("aGuide FX<CR>")
  local fx = lead:devices()[2]
  eq(fx.kind, "lua:guide_fx", "the effect is on the track")
  local before = mark()
  local pid = tonumber(api.device_call(fx.id, "sandbox.pid"))
  os.execute("kill -KILL " .. pid)
  wait_for("the crash to be told", 5000, function() return fx:get().stopped ~= nil end)
  eq(said(before):find("Guide FX on Lead stopped working: it was killed", 1, true) ~= nil, true, "a message names the device and why")
  eq(T.render({ tail = 0 }).peak > 0, true, "the track plays on without the effect")
  keys(",d")
  keys("w")
  keys("R")
  wait_for("the restart", 5000, function() return fx:get().stopped == nil end)
  eq(fx:get().status, "running", "R in the device panel starts it again")
  keys("o")
  eq(fx:get().offline, true, "o sets it offline")
  keys("o")
  eq(fx:get().offline, false, "and o again online")
  paw.ui.focus("arrange")
  keys(":w " .. d .. "/song.json<CR>")
  before = mark()
  keys(":edit " .. d .. "/song.json offline<CR>")
  eq(said(before):find("opened with every plugin offline", 1, true) ~= nil, true, ":edit song.json offline opens it with the plugins offline")
end)
