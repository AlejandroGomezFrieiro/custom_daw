-- VCAs: a fader, a mute and a solo that belong to other tracks without
-- carrying their sound, as on a desk. Nothing is routed: the members play
-- where they played, each at its own fader, and the VCA moves them all.
--
--   local drums = paw.vca.make({ kick, snare, hats }, "Drums")
--   drums.volume = -3        -- every member 3 dB quieter than its own fader
--   drums.mute = true        -- and silent
--   paw.vca.assign(room, drums)
--   paw.vca.unassign(snare, drums)
--
-- A track may be in several VCAs; their gains add in dB. The VCA is a track
-- marked in its `meta`, which is how its fader can have automation lanes
-- like any other; each member names its VCAs in its own. Both are saved,
-- undone and copied with the tracks. The sync reads the marks: it folds the
-- VCAs' faders into each member's gain, and their lanes into the member's
-- own, so what is heard (and rendered) is the sum, sample by sample.
local api = paw.api
local M = {}

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

--- True if a track is a VCA.
function M.is_vca(track)
  return meta(id_of(track)).vca == true
end

--- The VCAs of a track (their ids), in the order in which paw put the track in them.
function M.of(track)
  local out = {}
  for _, id in ipairs(meta(id_of(track)).vcas or {}) do
    if M.is_vca(id) then out[#out + 1] = id end
  end
  return out
end

--- The tracks in a VCA, in the order of the track list.
function M.members(vca)
  vca = id_of(vca)
  local out = {}
  for _, id in ipairs(api.track_list()) do
    for _, v in ipairs(meta(id).vcas or {}) do
      if v == vca then out[#out + 1] = id end
    end
  end
  return out
end

--- Every VCA, in the order of the track list.
function M.list()
  local out = {}
  for _, id in ipairs(api.track_list()) do
    if M.is_vca(id) then out[#out + 1] = id end
  end
  return out
end

--- Put a track under a VCA.
function M.assign(track, vca)
  track, vca = id_of(track), id_of(vca)
  if not M.is_vca(vca) then error("not a VCA", 2) end
  if track == vca or M.is_vca(track) then error("a VCA cannot be put under a VCA", 2) end
  local list = meta(track).vcas or {}
  for _, v in ipairs(list) do
    if v == vca then return end
  end
  list[#list + 1] = vca
  set_meta(track, "vcas", list)
end

--- Take a track out of a VCA, or out of all of them without `vca`.
function M.unassign(track, vca)
  track = id_of(track)
  local list, keep = meta(track).vcas or {}, {}
  for _, v in ipairs(list) do
    if vca ~= nil and v ~= id_of(vca) then keep[#keep + 1] = v end
  end
  if #keep == #list then return false end
  set_meta(track, "vcas", #keep > 0 and keep or nil)
  return true
end

--- A new VCA over `tracks` (ids or tracks), after the last track. Returns
--- its track.
function M.make(tracks, name)
  local vca = paw.add_track({ name = name or "VCA" })
  set_meta(vca.id, "vca", true)
  for _, track in ipairs(tracks or {}) do M.assign(track, vca.id) end
  return vca
end

--- Take a VCA away: its tracks stay, at their own faders.
function M.dissolve(vca)
  vca = id_of(vca)
  if not M.is_vca(vca) then return false end
  for _, id in ipairs(M.members(vca)) do M.unassign(id, vca) end
  api.track_remove(vca)
  return true
end

-- A VCA that is removed (or restored) leaves its members' lists holding an id
-- that names nothing, which is ignored; they are tidied when it is removed.
paw.on("track.removed", function(event)
  if event.restored then return end
  for _, id in ipairs(api.track_list()) do
    local list = meta(id).vcas
    if list then
      for _, v in ipairs(list) do
        if v == event.id then M.unassign(id, v) end
      end
    end
  end
end)

return M
