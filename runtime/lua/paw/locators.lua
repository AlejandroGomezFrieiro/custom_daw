-- Where each view shows things with an address (daw/address.lua), so that
-- diagnostics, hover and fixes work on whatever is under the cursor in any
-- view, and `]d` `[d` go between what a view can show (see `daw.ui.locator`).
local api = daw.api
local A = daw.address
local views = daw.ui.views

local function rows()
  local out = {}
  for i, id in ipairs(api.track_list()) do out[id] = i end
  out[0] = #api.track_list() + 1
  return out
end

local function time_of(location)
  local t = location.selector and location.selector.time
  return t and t[1] or nil
end

-- The piano roll: notes and stretches of its clip.
local roll = views.pianoroll
daw.ui.locator("pianoroll", {
  at = function()
    local id = roll.clip_id
    if not id then return nil end
    local n = api.clip_note_at(id, roll.pitch, roll.beat)
    if n and n.id then return A.location(A.note(id, n.id)) end
    return A.location(A.clip(id), { time = { roll.beat, roll.beat }, pitch = { roll.pitch, roll.pitch } })
  end,
  position = function() return { roll.beat, 127 - roll.pitch } end,
  place = function(location, anywhere)
    local p = A.parse(location.uri)
    if not p or not p.clip or (p.kind ~= "clip" and p.kind ~= "note") then return nil end
    if p.clip ~= roll.clip_id then return anywhere and { 0 } or nil end
    local first
    local ids = p.kind == "note" and { p.note } or (location.selector and location.selector.notes) or {}
    for _, id in ipairs(ids) do
      local n = A.find_note(p.clip, id)
      if n and (not first or n.start < first.start or (n.start == first.start and n.pitch > first.pitch)) then first = n end
    end
    if first then return { first.start, 127 - first.pitch } end
    return { time_of(location) or 0, 0 }
  end,
  go = function(location)
    local p = A.parse(location.uri)
    if p.clip ~= roll.clip_id then roll:edit(daw.clip(p.clip)) end
    local at = daw.ui.locators.pianoroll.place(location)
    if at and at[2] and at[2] > 0 then roll:set(127 - at[2], at[1]) else roll:set(nil, at and at[1] or 0) end
  end,
})

-- The arrange view: clips, tracks and what is on them, stretches of time.
local function arrange_place(location)
  local p = A.parse(location.uri)
  if not p or p.kind == "render" or (p.kind == "project" and not time_of(location)) then return nil end
  local row = rows()
  if p.kind == "project" or p.kind == "tempo" or p.kind == "marker" then return { time_of(location) or 0, 0 } end
  if p.clip then
    local ok, c = pcall(api.clip_get, p.clip)
    if not ok then return nil end
    return { c.start + (time_of(location) or 0), row[c.track] or 0 }
  end
  local track = A.track_of(location.uri)
  if track and row[track] then return { time_of(location) or 0, row[track] } end
  return nil
end

daw.ui.locator("arrange", {
  at = function()
    local clip = daw.cursor.clip()
    if clip then return A.location(A.clip(clip.id), { time = { daw.cursor.beat - clip.start, daw.cursor.beat - clip.start } }) end
    local id = daw.cursor.track_id()
    return id and A.location(A.track(id), { time = { daw.cursor.beat, daw.cursor.beat } }) or nil
  end,
  position = function() return { daw.cursor.beat, rows()[daw.cursor.track_id() or 0] or 0 } end,
  place = arrange_place,
  go = function(location)
    local at = arrange_place(location)
    local track = A.track_of(location.uri)
    if not track then
      local p = A.parse(location.uri)
      local ok, c = p and p.clip and pcall(api.clip_get, p.clip)
      track = ok and c.track or nil
    end
    if track then daw.cursor.set_track(track) end
    if at then daw.cursor.set_beat(math.max(0, at[1])) end
  end,
})

-- The mixer: a strip for each track.
daw.ui.locator("mixer", {
  at = function()
    local id = daw.cursor.track_id()
    return id and A.location(A.track(id)) or nil
  end,
  position = function() return { rows()[daw.cursor.track_id() or 0] or 0 } end,
  place = function(location)
    local track = A.track_of(location.uri)
    local row = track and rows()[track]
    return row and { row } or nil
  end,
  go = function(location)
    local track = A.track_of(location.uri)
    if track then daw.cursor.set_track(track) end
  end,
})

-- The device panel: the devices of the cursor's track and their parameters.
local devices = views.devices
local function device_row(device, param)
  for i, row in ipairs(devices:rows()) do
    if row.device.id == device and not row.picture and ((param == nil and not row.param) or (row.param and row.param.key == param)) then return i end
  end
end
daw.ui.locator("devices", {
  at = function()
    local row = devices:rows()[devices.row or 1]
    if not row then
      local id = daw.cursor.track_id()
      return id and A.location(A.track(id)) or nil
    end
    if row.param then return A.location(A.param(row.device.id, row.param.key)) end
    return A.location(A.device(row.device.id))
  end,
  position = function() return { devices.row or 1 } end,
  place = function(location, anywhere)
    local p = A.parse(location.uri)
    if not p or (p.kind ~= "device" and p.kind ~= "param") then return nil end
    if anywhere then return { 0 } end
    if p.track ~= daw.cursor.track_id() then return nil end
    local i = device_row(p.device, p.param)
    return i and { i } or nil
  end,
  go = function(location)
    local p = A.parse(location.uri)
    if p.track ~= daw.cursor.track_id() then daw.cursor.set_track(p.track) end
    devices.row = device_row(p.device, p.param) or devices.row
    api.ui_redraw()
  end,
})

return true
