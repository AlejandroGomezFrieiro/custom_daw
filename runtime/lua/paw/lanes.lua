-- Automation lanes as rows of the arrange view: under a track whose lanes are
-- open, each of its lanes (volume, pan, a device's parameter) is a row of its
-- own, two lines high, that the cursor can stand on.
--
--   daw.lanes.open(track)             -- show the track's lanes as rows
--   daw.lanes.toggle(track)
--   daw.lanes.lines()                 -- every row: { track = id } or { track = id, lane = id }
--   daw.lanes.name(lane), daw.lanes.format(lane, value)
--
-- Which tracks have their lanes open is kept for the session (it survives
-- `:reload`), not in the project: opening lanes is not an edit to undo.
-- `daw.groups.rows({ lanes = true })` is `lines()`; the cursor is on a lane
-- when `daw.cursor.lane_id()` says so.
local api = daw.api
local M = {}

local open = {}
do
  local saved = api.state_get("lanes_open")
  for key, on in pairs(type(saved) == "table" and saved or {}) do
    if on then open[tonumber(key) or key] = true end
  end
end

local function save()
  local out = {}
  for id, on in pairs(open) do
    if on then out[tostring(id)] = true end
  end
  api.state_set("lanes_open", out)
  api.ui_redraw()
  -- A graphical frontend draws them too.
  if daw.emit then daw.emit("lanes.changed", {}) end
end

local function id_of(track) return type(track) == "table" and track.id or track end

--- Whether a track's lanes are shown as rows.
function M.is_open(track)
  return open[id_of(track)] == true
end

--- Show a track's lanes as rows, or hide them (`on` false).
function M.open(track, on)
  local id = id_of(track)
  open[id] = on ~= false or nil
  save()
end

function M.toggle(track)
  M.open(track, not M.is_open(track))
  return M.is_open(track)
end

--- Whether any track has its lanes open.
function M.any_open()
  return next(open) ~= nil
end

--- The lanes shown under a track: none when they are closed.
function M.shown(track)
  local id = id_of(track)
  if not open[id] then return {} end
  local ok, list = pcall(api.lane_list, id)
  return ok and list or {}
end

--- Every row of the arrange view in order: each track drawn, then its lanes
--- when they are open.
function M.lines()
  local out = {}
  for _, id in ipairs(daw.groups.rows()) do
    out[#out + 1] = { track = id }
    for _, lane in ipairs(M.shown(id)) do out[#out + 1] = { track = id, lane = lane.id } end
  end
  return out
end

--- The parameter a lane moves: its name, and the parameter's description
--- for a device's lane.
local function param_of(lane)
  if lane.target ~= "param" then return nil end
  local ok, d = pcall(api.device_get, lane.device)
  if not ok then return nil end
  for _, p in ipairs(d.param_info) do
    if p.key == lane.param then return p, d end
  end
end

--- What a lane moves, for its header: "Volume", "Pan", "Synth › cutoff".
--- The automation modes a track can be in (`track.automation`), in the
--- order `:automation` steps through them, and what each does.
M.modes = { "read", "touch", "latch", "write", "off" }
M.mode_text = {
  read = "the lanes play; moving a control writes nothing",
  touch = "a control writes while it is held or moved, then the lane takes over again",
  latch = "a control writes from its first move until the song stops",
  write = "everything the lanes move is written over while the song plays",
  off = "the lanes are kept but do not play",
}

function M.name(lane)
  if type(lane) == "number" then lane = api.lane_get(lane) end
  if lane.target == "volume" then return "Volume" end
  if lane.target == "pan" then return "Pan" end
  local p, d = param_of(lane)
  return (d and d.name or "?") .. " › " .. (p and p.name or tostring(lane.param))
end

--- A value of a lane as its target shows it: "-6.0 dB", "L30", "800 Hz".
function M.format(lane, value)
  if type(lane) == "number" then lane = api.lane_get(lane) end
  if lane.target == "volume" then return string.format("%.1f dB", value) end
  if lane.target == "pan" then return daw.draw.pan_text(value) end
  local p = param_of(lane)
  return p and daw.frontend.format_value(p, value) or string.format("%g", value)
end

--- How far `+` and `-` move a point: a dB, 5% of pan, one choice, or a
--- hundredth of the parameter's range.
function M.step(lane)
  if type(lane) == "number" then lane = api.lane_get(lane) end
  if lane.target == "volume" then return 1 end
  if lane.target == "pan" then return 0.05 end
  local p = param_of(lane)
  if p and #p.choices > 0 then return 1 end
  return (lane.max - lane.min) / 100
end

--- The parameter's description, for reading typed values.
M.param_of = param_of

--- What a lane's target is at a beat: the curve's value, or with no points
--- yet the target's own value.
function M.value_at(lane, beat)
  if type(lane) == "number" then lane = api.lane_get(lane) end
  local ok, v = pcall(api.lane_value_at, lane.id, beat)
  if ok and v then return v end
  if lane.target == "volume" or lane.target == "pan" then return api.track_get(lane.track)[lane.target] end
  local d = api.device_get(lane.device)
  return d.params[lane.param] or 0
end

--- The point at a beat, within `reach` beats: its index in the lane's
--- points, and the point { beat, value }.
function M.point_at(lane_id, beat, reach)
  local best, at
  for i, p in ipairs(api.lane_points(lane_id)) do
    local d = math.abs(p[1] - beat)
    if d <= (reach or 1e-9) and (not best or d < math.abs(best[1] - beat)) then best, at = p, i end
  end
  return at, best
end

--- Change the lane's points with `fn(points)`, which edits the list in place.
function M.edit(lane_id, fn)
  local points = api.lane_points(lane_id)
  fn(points)
  table.sort(points, function(a, b) return a[1] < b[1] end)
  api.lane_set_points(lane_id, points)
end

-- A track that goes away takes its open lanes with it.
daw.on("track.removed", function(event)
  if open[event.id] then
    open[event.id] = nil
    save()
  end
end)

return M
