-- Frames: when the screen is drawn while the song plays, and how much of
-- it (paw/ui.lua). Loaded by tests/suite.lua with its helpers.
local T = ...
local test, eq = T.test, T.eq
local api = paw.api

local function binary()
  local pipe = io.popen("readlink /proc/" .. api.env().pid .. "/exe")
  local path = pipe:read("*l")
  pipe:close()
  return path
end

test("frames: paw.opt.fps set in init.lua is the ceiling of the frame rate", function()
  local dir = T.scratch .. "/fps-config"
  os.execute("mkdir -p '" .. dir .. "/state'")
  T.write_file(dir .. "/init.lua", "paw.opt.fps = 12\n")
  T.write_file(dir .. "/show.lua", "print('FRAME_MS ' .. paw.ui.frame_ms())\n")
  local pipe = io.popen(string.format(
    "XDG_STATE_HOME='%s/state' XDG_DATA_HOME='%s/state' XDG_CACHE_HOME='%s/state' '%s' --config '%s' --no-plugins --no-listen --audio null -l '%s/show.lua' 2>&1",
    dir, dir, dir, binary(), dir, dir))
  local out = pipe:read("*a")
  pipe:close()
  local ms = tonumber(out:match("FRAME_MS ([%d%.]+)"))
  eq(ms and math.floor(ms + 0.5), 83, "1000 / 12 ms between frames, from init.lua: " .. out)
end)

test("frames: :set fps changes the frame rate at once", function()
  local was = paw.opt.fps
  T.after(function() paw.opt.fps = was end)
  paw.commands.exec("set fps=20")
  eq(paw.ui.frame_ms(), 50, "20 frames a second at most")
end)
