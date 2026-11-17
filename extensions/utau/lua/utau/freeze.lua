-- Freezing a vocal track: its singing rendered to audio, so the engine can
-- stop working on it.
--
-- Freezing is the core's bounce (`paw.bounce`): the track is rendered with
-- its devices, after the engine has sung every phrase at final quality, onto
-- an audio track right below it, "<name> (frozen)", and the vocal track is
-- muted. The vocal track keeps its notes, lyrics, curves and voice, and is
-- marked frozen (`device.meta.utau.frozen` holds the audio track's id): the
-- engine no longer sings it. Unfreezing removes the audio track, unmutes the
-- vocal track and lets the engine sing it again, from its render cache.
local api = paw.api
local utau = require("utau")

local M = {}

local function exists(id) return id and pcall(api.track_get, id) end

--- Freeze a vocal track. Returns the audio track.
function M.freeze(track_id)
  if not utau.device_of(track_id) then error("not a vocal track", 0) end
  if utau.frozen(track_id) then error("the track is frozen already", 0) end
  local track = paw.track(track_id)
  local was_muted = track.mute
  -- Muted, the track would render silent: it plays for the bounce.
  track.mute = false
  paw.flush()
  local ok, why = utau.finish(paw.opt.utau_render_timeout)
  if not ok then
    track.mute = was_muted
    error("the singing is not finished: " .. tostring(why), 0)
  end
  local bounced = paw.bounce(track, { name = track.name .. " (frozen)" })
  if not bounced then
    track.mute = was_muted
    error("nothing on the track to freeze", 0)
  end
  utau.configure(track_id, { frozen = { track = bounced.id, muted = was_muted or nil } })
  utau.voices.clear(utau.device_of(track_id))
  utau.received[tostring(track_id)] = nil
  utau.layouts[tostring(track_id)] = nil
  -- The engine forgets the track now, and sings it whole when it is back.
  utau.sync()
  return bounced
end

--- Unfreeze a vocal track: the audio track goes, and the engine sings it again.
function M.unfreeze(track_id)
  local frozen = utau.config(track_id).frozen
  if not frozen then error("the track is not frozen", 0) end
  if type(frozen) == "table" and exists(frozen.track) then api.track_remove(frozen.track) end
  utau.configure(track_id, { frozen = false })
  paw.track(track_id).mute = type(frozen) == "table" and frozen.muted or false
  utau.sync()
end

--- The audio track a frozen vocal track was rendered to, if it is still there.
function M.audio(track_id)
  local frozen = utau.config(track_id).frozen
  if type(frozen) == "table" and exists(frozen.track) then return frozen.track end
end

return M
