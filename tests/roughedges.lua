-- Tests of small things that read wrong or were left behind: what the views
-- draw over each other, and what is said. Loaded by tests/suite.lua with its
-- helpers.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = paw.api

local function start()
  fresh()
  api.engine_restart({ backend = "null" })
  paw.keymap.feed("<Esc><Esc>")
  while paw.ui.float do paw.ui.close() end
  paw.ui.focus("arrange")
end

test("the playhead over a take lane keeps the letters of the take's name", function()
  start()
  local zoom = paw.opt.zoom
  T.after(function() paw.opt.zoom = zoom end)
  paw.opt.zoom = 16
  local t = paw.add_track({ name = "Lead" })
  local clip = t:add_clip({ start = 0, length = 4, name = "Riff", notes = { { pitch = 60, start = 0, length = 1 } } })
  paw.takes.new(clip.id)
  paw.takes.show_lanes(t.id, true)
  api.undo_checkpoint()
  paw.cursor.set_track(t)
  -- Two columns in: on the "i" of each take's name.
  for _, beat in ipairs({ 2 / 16, 3 / 16, 7 / 16 }) do
    paw.transport.seek(beat)
    paw.flush()
    local text = table.concat(api.ui_snapshot(120, 20), "\n")
    eq(text:find("Riff 1", 1, true) ~= nil, true, "the first take's name whole, the playhead at " .. beat)
    eq(text:find("Riff 2", 1, true) ~= nil, true, "the second's, the playhead at " .. beat)
  end
end)
