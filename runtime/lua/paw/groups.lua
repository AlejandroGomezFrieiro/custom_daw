-- Groups of tracks: a track that others belong to, as the strings of an
-- orchestra belong to "Strings". The members sound through the group (their
-- output is the group, so its fader, mute and devices act on all of them),
-- are drawn under it, a step in, and can be folded away into it.
--
--   local strings = paw.groups.make({ violins, violas, cellos }, "Strings")
--   paw.groups.fold(strings, true)
--   paw.groups.add(basses, strings)
--   paw.groups.remove(violas)
--
-- A group is an ordinary track marked in its `meta`, and each member names
-- its group in its own, so groups are saved, undone and copied with the
-- tracks. Groups may hold groups.
local api = paw.api
local M = {}
local util = paw.util
local volumes = {}

local function id_of(track) return type(track) == "table" and track.id or track end

local function meta(id)
  local ok, m = pcall(api.track_get, id, "meta")
  return ok and m or {}
end

local function set_meta(id, key, value)
  local m = meta(id)
  m[key] = value
  api.track_set(id, "meta", m)
end

--- True if a track is a group.
function M.is_group(track)
  return meta(id_of(track)).group_head == true
end

--- The group a track belongs to (its id), or nil.
function M.of(track)
  local group = meta(id_of(track)).group
  if group and pcall(api.track_get, group) and M.is_group(group) then return group end
end

--- The tracks that belong to a group, in the order of the track list.
function M.members(group)
  group = id_of(group)
  local out = {}
  for _, id in ipairs(api.track_list()) do
    if M.of(id) == group then out[#out + 1] = id end
  end
  return out
end

--- How many groups a track is inside.
function M.depth(track)
  local depth, at = 0, M.of(track)
  while at and depth < 16 do
    depth, at = depth + 1, M.of(at)
  end
  return depth
end

--- True if the tracks of a group are folded and hidden.
function M.folded(group)
  return meta(id_of(group)).group_folded == true
end

--- True if a track is hidden: inside a folded group. Inside group `top`
--- (the group of a narrowed tab), only the groups inside it count. `top`
--- itself is open there.
function M.hidden(track, top)
  if top and id_of(track) == top then return false end
  local at, steps = M.of(track), 0
  while at and at ~= top and steps < 16 do
    if M.folded(at) then return true end
    at, steps = M.of(at), steps + 1
  end
  return false
end

--- The tracks that are drawn, in order: all but those folded away, and in
--- a narrowed tab only those of its group (`paw.scope`). Rows of the
--- arrange view and of a graphical frontend are places in this list.
--- With `{ lanes = true }`, every row: `{ track = id }` for a track and
--- `{ track = id, lane = id }` for an automation lane shown under it
--- (see `paw.lanes`).
function M.rows(opts)
  if opts and opts.lanes then return paw.lanes.lines() end
  local out, vcas = {}, {}
  local scope = paw.scope and paw.scope.current()
  for _, id in ipairs(paw.scope and paw.scope.tracks(scope) or api.track_list()) do
    if not M.hidden(id, scope) then
      -- VCAs come after the tracks they move.
      local list = paw.vca.is_vca(id) and vcas or out
      list[#list + 1] = id
    end
  end
  table.move(vcas, 1, #vcas, #out + 1, out)
  return out
end

local function position(id)
  for i, other in ipairs(api.track_list()) do
    if other == id then return i end
  end
end

--- Put a group's members right under it, in the order they are in.
local function gather(group)
  local at = position(group)
  for _, id in ipairs(M.members(group)) do
    local from = position(id)
    -- Moving a track from above the group shifts the group up by one.
    if from < at then
      api.track_move(id, at)
    else
      at = at + 1
      if from ~= at then api.track_move(id, at) end
    end
    -- A member that is a group brings its own members along.
    if M.is_group(id) then
      gather(id)
      at = position(id) + #M.members(id)
    else
      at = position(id)
    end
  end
end
M.gather = gather

--- Put a track into a group: it then sounds through the group, unless it
--- was sent somewhere of its own.
function M.add(track, group)
  track, group = id_of(track), id_of(group)
  if track == group or not M.is_group(group) then error("not a group", 2) end
  -- A group cannot go inside itself.
  local at = group
  while at do
    if at == track then error("a group cannot be put inside itself", 2) end
    at = M.of(at)
  end
  local t = api.track_get(track)
  local old = M.of(track)
  if t.output == nil or t.output == old then api.track_set(track, "output", group) end
  set_meta(track, "group", group)
  gather(group)
end

--- Remove a track from its group, up one level. It sounds where the group
--- sounds, and it is in the parent group of the group, if any. It moves out
--- of the rows of the group, unless `stay`.
function M.remove(track, stay)
  track = id_of(track)
  local group = M.of(track)
  if not group then return false end
  if api.track_get(track, "output") == group then api.track_set(track, "output", api.track_get(group, "output")) end
  set_meta(track, "group", M.of(group))
  -- Out of the group's block of rows: after its last member.
  local members = M.members(group)
  local last = position(members[#members] or group)
  if not stay and position(track) < last then api.track_move(track, last) end
  return true
end

--- A new group that contains `tracks` (ids or tracks), above the first of
--- them. Returns the track of the group.
function M.make(tracks, name)
  local ids = {}
  for i, track in ipairs(tracks or {}) do ids[i] = id_of(track) end
  local first
  for _, id in ipairs(ids) do
    local at = position(id)
    if at and (not first or at < first) then first = at end
  end
  local group = paw.add_track({ name = name or "Group", index = first })
  set_meta(group.id, "group_head", true)
  -- Tracks that were together in a group stay in it, one level down.
  local outer = ids[1] and M.of(ids[1])
  local same = outer ~= nil
  for _, id in ipairs(ids) do same = same and M.of(id) == outer end
  if same and outer then M.add(group.id, outer) end
  for _, id in ipairs(ids) do M.add(id, group.id) end
  return group
end

--- Undo a group: its members go up a level and the group, if it holds
--- nothing of its own (no clips, no devices), goes away.
function M.dissolve(group)
  group = id_of(group)
  if not M.is_group(group) then return false end
  local outer = M.of(group)
  for _, id in ipairs(M.members(group)) do
    if api.track_get(id, "output") == group then api.track_set(id, "output", api.track_get(group, "output")) end
    set_meta(id, "group", outer)
  end
  local t = api.track_get(group)
  if #t.clips == 0 and #t.devices == 0 then
    api.track_remove(group)
  else
    set_meta(group, "group_head", nil)
    set_meta(group, "group_folded", nil)
  end
  return true
end

--- Fold a group away, or open it: `on` nil flips it.
function M.fold(group, on)
  group = id_of(group)
  if not M.is_group(group) then return end
  if on == nil then on = not M.folded(group) end
  set_meta(group, "group_folded", on and true or nil)
  -- The cursor does not stay on a track that is out of sight.
  local cursor = paw.cursor.track_id()
  if cursor and M.hidden(cursor) then paw.cursor.set_track(group) end
end

--- Note the faders of a group's members: linked faders move by what they
--- have moved since.
local function note(group)
  for _, id in ipairs(M.members(group)) do volumes[id] = api.track_get(id, "volume") end
end

--- True if the faders of the members of a group are linked. When one moves,
--- the others move by the same number of dB. This is separate from the
--- routing, which a group also has.
function M.linked(group)
  return meta(id_of(group)).group_link == true
end

--- Link the faders of a group's members, or let them go: `on` nil flips it.
function M.link(group, on)
  group = id_of(group)
  if not M.is_group(group) then error("not a group", 2) end
  if on == nil then on = not M.linked(group) end
  set_meta(group, "group_link", on and true or nil)
  note(group)
end

paw.on("track.*", function(event, name)
  local group = event.id and M.of(event.id)
  if not group or not M.linked(group) then return end
  -- Undo, redo and opening a project restore every fader themselves.
  if event.restored or name == "track.added" then return note(group) end
  if name ~= "track.changed" then return end
  local now = api.track_get(event.id, "volume")
  local before = volumes[event.id]
  volumes[event.id] = now
  if before == nil or before == now then return end
  for _, id in ipairs(M.members(group)) do
    if id ~= event.id then
      local was = volumes[id] or api.track_get(id, "volume")
      volumes[id] = util.clamp(was + now - before, -120, 24)
      api.track_set(id, "volume", volumes[id])
    end
  end
end)

-- A group that is removed lets its members go: they keep sounding, on the
-- master, and stand at the top level.
paw.on("track.removed", function(event)
  if event.restored then return end
  for _, id in ipairs(api.track_list()) do
    local m = meta(id)
    if m.group == event.id then
      m.group = nil
      api.track_set(id, "meta", m)
    end
  end
end)

return M
