-- A plugin's saved state goes back into it, in each format: in a
-- snapshot, on a state lane in a render, and through undo and redo. After
-- a load the state is the truth: what the plugin tells of its parameters
-- then is not an edit. Loaded by tests/suite.lua with its helpers; needs
-- the dev shell's test plugins (`tests/tools/suite.sh plugins`).
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = paw.api

local function kind_of(format, pattern)
  for _, info in ipairs(paw.device_types()) do
    if info.format == format and info.name:find(pattern) then return info.kind end
  end
end

local function keys(text)
  paw.keymap.feed(text)
  api.undo_checkpoint()
end

--- Surge XT in each format that the test plugins have.
local function surges()
  local out = {}
  for _, format in ipairs({ "clap", "vst3", "lv2" }) do
    local kind = kind_of(format, "^Surge XT$")
    if kind then out[#out + 1] = kind end
  end
  return out
end

--- A track that holds A3 for `beats` through `kind`, with the cursor and
--- the device panel on the device.
local function instrument(kind, beats)
  local track = paw.add_track({ name = kind })
  -- A note for each four beats: a state load can end the notes that sound.
  local notes = {}
  for at = 0, beats - 1, 4 do notes[#notes + 1] = { pitch = "A3", start = at, length = 4 } end
  track:add_clip({ start = 0, length = beats, notes = notes })
  local d = track:add_device(kind)
  paw.flush()
  paw.cursor.set_track(track.id)
  paw.ui.focus("devices")
  paw.fx.select(d.id)
  api.undo_checkpoint()
  return d
end

--- The pitch of a render, from `from` to `to` seconds.
local function pitch(from, to)
  return T.frequency(T.render({ tail = 0, bits = 16 }), from or 0.5, to or 1.5)
end

local function has_param(d, key)
  for _, p in ipairs(api.device_get(d.id).param_info) do
    if p.key == key then return true end
  end
end

--- The octave of scene A as the plugin holds it, -3 to 3: as its
--- parameter tells (CLAP, VST3), else as its saved state does (Surge XT's
--- LV2 has no parameters).
local function octave(d)
  if has_param(d, "a_octave") then
    return math.floor(api.device_param(d.id, "a_octave").value * 6 - 3 + 0.5)
  end
  return tonumber(require("plugstate").slot(d.id, "octave").value)
end

--- Wait until the plugin's own state (not the project's) holds `want` as
--- the octave, or two seconds go by.
local function holds(d, want)
  paw.flush()
  for _ = 1, 100 do
    if octave(d) == want then return end
    api.wait(20)
  end
end

--- Wait until the plugin sleeps (its note ended and its tail went by), so
--- that a state reaches a plugin at rest. Three seconds at most.
local function rested()
  local before = api.engine_get().device_sleeps
  for _ = 1, 150 do
    api.sleep(20)
    if api.engine_get().device_sleeps > before + 10 then return end
  end
end

--- The parameters that the project itself sets for a device (not the
--- values that the plugin reports), as the current undo step holds them.
local function own(d)
  if not has_param(d, "a_volume") then return { a_volume = 0.75 } end
  for _, track in ipairs(api.undo_project().tracks) do
    for _, device in ipairs(track.devices or {}) do
      if device.id == d.id then return device.params or {} end
    end
  end
end

local touched = 0
paw.on("param.touched", function(e)
  if e.from == "editor" then touched = touched + 1 end
end)

test("a plugin takes a snapshot back at rest, and the echo of its values is no edit (each format)", function()
  local kinds = surges()
  if #kinds == 0 then return "skipped: Surge XT not found" end
  paw.ext.load("extensions/plugstate")
  for _, kind in ipairs(kinds) do
    fresh()
    local d = instrument(kind, 4)
    -- The project sets one parameter: the snapshots keep it.
    if has_param(d, "a_volume") then api.device_set_param(d.id, "a_volume", 0.75) end
    api.undo_checkpoint()
    keys("\\s")
    keys(":plugstate.load slot=octave 1<CR>")
    holds(d, 1)
    eq(octave(d), 1, kind .. ": an octave up")
    -- A preset of plugstate sets the state alone: the parameter again.
    if has_param(d, "a_volume") then api.device_set_param(d.id, "a_volume", 0.75) end
    api.undo_checkpoint()
    keys("\\s")
    T.near(pitch(), 440, 10, kind .. ": B plays an octave higher")
    T.near(own(d).a_volume, 0.75, 1e-6, kind .. ": the project's own parameter stays")
    local step = api.undo_current()
    touched = 0

    -- Back to A with the plugin at rest.
    rested()
    keys("[v")
    holds(d, 0)
    eq(octave(d), 0, kind .. ": A is back in the plugin")
    T.near(pitch(), 220, 6, kind .. ": A plays A3")
    eq(api.undo_current(), step + 1, kind .. ": one step for the recall")
    api.wait(300)
    T.near(own(d).a_volume or -1, 0.75, 1e-6, kind .. ": the echo of the state takes nothing from the project")

    rested()
    keys("u")
    holds(d, 1)
    eq(octave(d), 1, kind .. ": u gives B back to the plugin")
    T.near(pitch(), 440, 10, kind .. ": and B plays")
    eq(api.undo_current(), step, kind .. ": u goes back one step")

    keys("<C-r>")
    holds(d, 0)
    eq(octave(d), 0, kind .. ": <C-r> gives A again")
    T.near(pitch(), 220, 6, kind .. ": and A plays")
    eq(api.undo_current(), step + 1, kind .. ": <C-r> goes forward one step")
    api.wait(300)
    paw.flush()
    eq(api.undo_current(), step + 1, kind .. ": the echo makes no step of its own")
    eq(api.undo_pending(), false, kind .. ": nor an open one")
    eq(touched, 0, kind .. ": and no move of a parameter in the plugin's window")
    T.near(own(d).a_volume or -1, 0.75, 1e-6, kind .. ": the project's parameter is still there")
  end
end)

test("a state lane gives each format of a plugin its saved state at the point, in a render", function()
  local kinds = surges()
  if #kinds == 0 then return "skipped: Surge XT not found" end
  paw.ext.load("extensions/plugstate")
  local plugstate = require("plugstate")
  for _, kind in ipairs(kinds) do
    fresh()
    local d = instrument(kind, 8)
    keys("\\s")
    keys(":plugstate.load slot=octave 1<CR>")
    holds(d, 1)
    keys("\\s")
    rested()
    plugstate.lane_point(d.id, 0, plugstate.lane_snapshot(d.id, "A"))
    -- Before the next note: Surge XT takes a whole state on at the start
    -- of its next block, and ends the notes that sound then, also one
    -- that starts in that block.
    plugstate.lane_point(d.id, 3.5, plugstate.lane_snapshot(d.id, "B"))
    api.undo_checkpoint()
    local info = T.render({ tail = 0, bits = 16 })
    T.near(T.frequency(info, 0.25, 1.6), 220, 6, kind .. ": A before the point")
    T.near(T.frequency(info, 2.2, 3.8), 440, 10, kind .. ": B after it")
  end
end)
