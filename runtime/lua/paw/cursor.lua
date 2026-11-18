-- The edit cursor: a track and a position in beats. Commands act on it and
-- views draw it. It survives a reload.
local api = paw.api
local M = { beat = 0 }

local track_id
local lane_id    -- the automation lane row the cursor is on, if any
do
  local saved = api.state_get("cursor")
  if saved then track_id, M.beat, lane_id = saved.track, saved.beat or 0, saved.lane end
end

-- Each seat has a cursor of its own, starting where the instance's is.
paw.seats.keep("cursor",
  function() return track_id, M.beat, lane_id end,
  function(track, beat, lane) track_id, M.beat, lane_id = track, beat, lane end,
  function(track, beat, lane) return track, beat or 0, lane end)

local function save()
  -- The instance's own is the one that outlives a reload.
  if paw.seats.current == 0 then api.state_set("cursor", { track = track_id, beat = M.beat, lane = lane_id }) end
  paw.emit("cursor.changed", { track = track_id, beat = M.beat, lane = lane_id })
  api.ui_redraw()
end

--- Id of the track the cursor is on, falling back to the first track when
--- that track is gone. Nil when the project has no tracks.
function M.track_id()
  if track_id and pcall(api.track_get, track_id) and track_id ~= 0 then return track_id end
  track_id = api.track_list()[1]
  return track_id
end

--- The track the cursor is on, as a `paw.Track`, or nil.
function M.track()
  local id = M.track_id()
  return id and paw.track(id) or nil
end

--- 1-based position of the cursor track in the track list.
function M.index()
  local id = M.track_id()
  for i, other in ipairs(api.track_list()) do
    if other == id then return i end
  end
end

--- 1-based row of the cursor track among the tracks that are drawn: the
--- same as `index` until a group is folded.
function M.row()
  local id = M.track_id()
  for i, other in ipairs(paw.groups.rows()) do
    if other == id then return i end
  end
end

--- The automation lane row the cursor is on: a lane of the cursor track
--- shown as a row (see `paw.lanes`), or nil when it is on the track itself.
function M.lane_id()
  if not lane_id then return nil end
  local id = M.track_id()
  for _, lane in ipairs(id and paw.lanes.shown(id) or {}) do
    if lane.id == lane_id then return lane_id end
  end
end

--- 1-based row of the cursor among every row drawn, lanes included.
function M.line()
  local id, lane = M.track_id(), M.lane_id()
  for i, line in ipairs(paw.groups.rows({ lanes = true })) do
    if line.track == id and line.lane == lane then return i end
  end
end

--- Put the cursor on a track, or with `lane` on one of its lane rows.
function M.set_track(track, lane)
  track_id = type(track) == "table" and track.id or track
  lane_id = lane
  save()
end

--- Move by rows. In normal mode the rows of open automation lanes count;
--- after an operator or in a selection only tracks do, as for `dj`.
function M.move_track(delta)
  if paw.lanes.any_open() and paw.keymap.mode == "n" then
    local lines = paw.groups.rows({ lanes = true })
    if #lines == 0 then return end
    local to = lines[paw.util.clamp((M.line() or 1) + delta, 1, #lines)]
    return M.set_track(to.track, to.lane)
  end
  local list = paw.groups.rows()
  if #list == 0 then return end
  M.set_track(list[paw.util.clamp((M.row() or 1) + delta, 1, #list)])
end

--- Put the cursor at a beat (not before 0).
function M.set_beat(beat)
  M.beat = math.max(0, beat)
  save()
end

-- Another project starts at its start, on its first track.
paw.on("project.loaded", function()
  track_id, lane_id, M.beat = nil, nil, 0
  save()
end)

--- Round a position to the arrange grid.
function M.snap(beat)
  return paw.util.round(beat, paw.opt.grid)
end

--- The clip under the cursor, if any.
function M.clip()
  local track = M.track()
  return track and track:clip_at(M.beat) or nil
end

return M
