-- Stretching, pitch shifting and looping clips: `daw.stretch`.
--
-- An audio clip plays its file `clip.stretch` times as long (2 is half
-- speed) and `clip.pitch` semitones higher, each without changing the
-- other. The stretched sound is made once, apart, and played when it is
-- ready; until then the clip is silent and says so (`clip.stretching`).
-- `clip.offset` stays in seconds of the file, so a second of the clip is
-- `1 / stretch` seconds of the file (`M.file_seconds`).
--
-- A clip in the "stretch" timebase keeps its start and its length on their
-- beats when the tempo changes: its stretch follows, from the tempo its
-- sound is at (`clip.source_tempo`, which recordings know).
--
-- Any clip can loop (`clip.loop`): it repeats what it plays from
-- `clip.loop_start` (beats from its start, 0 or less) for
-- `clip.loop_length` beats, again and again to its end. Trimming its start
-- turns the loop round rather than running out of it; a cut gives both
-- pieces the same loop, each from where it begins.
local api = daw.api
local M = {}

local EPS = 1e-9

--- Seconds of an audio clip's file that `beats` beats of it from beat `at`
--- (its start when left out) play.
function M.file_seconds(c, beats, at)
  return daw.time.seconds(beats, at or c.start) / (c.stretch or 1)
end

--- What a clip plays from, once its start has moved `by` beats later
--- (earlier below 0) while what it plays stays where it is: `offset` for
--- sound; for a looped clip `loop_start` too, kept within one repeat, and
--- `shift`, how far its notes move (counted from the new start).
function M.moved(c, by)
  local out = { shift = -by }
  local turns = 0
  if c.loop and c.loop_length then
    local ls = (c.loop_start or 0) - by
    turns = math.floor(-ls / c.loop_length + EPS)
    out.loop_start = ls + turns * c.loop_length
    out.shift = out.shift + turns * c.loop_length
  end
  if c.kind == "audio" then
    out.offset = math.max(0, c.offset + M.file_seconds(c, by - turns * (c.loop_length or 0)))
  end
  return out
end

--- Move what a looped clip plays as `M.moved` says, in the project: its
--- offset or notes (and other takes' notes), and where its loop begins.
function M.move_content(id, by)
  local c = api.clip_get(id)
  local m = M.moved(c, by)
  if c.kind == "audio" then
    api.clip_set(id, "offset", m.offset)
  elseif math.abs(m.shift) > EPS then
    local notes = api.clip_notes(id)
    for _, n in ipairs(notes) do n.start = n.start + m.shift end
    api.clip_set_notes(id, notes)
    if c.control_count > 0 then
      local controls = api.clip_controls(id)
      for _, move in ipairs(controls) do move.start = move.start + m.shift end
      api.clip_set_controls(id, controls)
    end
    daw.takes.shift(id, m.shift)
  end
  if m.loop_start then api.clip_set(id, "loop_start", m.loop_start) end
end

--- Give `snap`, the snapshot of a piece of clip `c` that begins `by`
--- beats into it, what `c` plays with: its stretch, shift and timebase,
--- and its loop from where the piece begins. Returns `M.moved(c, by)`.
function M.carry(c, snap, by)
  local m = M.moved(c, by)
  if c.kind == "audio" then
    snap.timebase, snap.stretch, snap.pitch = c.timebase, c.stretch, c.pitch
    snap.stretch_mode, snap.source_tempo = c.stretch_mode, c.source_tempo
  end
  snap.loop, snap.loop_length = c.loop or nil, c.loop_length
  snap.loop_start = m.loop_start or c.loop_start
  return m
end

local function need_audio(c)
  if c.kind ~= "audio" then error("only audio clips are stretched or shifted", 3) end
end

--- Make what a clip plays `k` times as long: its length, fades and loop
--- with it, from its start. With `set`, its stretch too.
local function scale(c, k, set)
  if set then api.clip_set(c.id, "stretch", c.stretch * k) end
  local seconds = daw.time.seconds(c.length, c.start) * k
  local length = daw.time.to_beat(daw.time.to_seconds(c.start) + seconds) - c.start
  api.clip_set(c.id, "length", length)
  local ratio = length / c.length
  api.clip_set(c.id, "fade_in", math.min(c.fade_in * ratio, length))
  api.clip_set(c.id, "fade_out", math.min(c.fade_out * ratio, length))
  if c.loop_length then
    api.clip_set(c.id, "loop_length", c.loop_length * ratio)
    api.clip_set(c.id, "loop_start", (c.loop_start or 0) * ratio)
  end
end

--- Stretch an audio clip to play its file `ratio` times as long, keeping
--- what it plays: it grows or shrinks from its start by as much.
function M.set(id, ratio)
  local c = api.clip_get(id)
  need_audio(c)
  if math.abs(ratio - c.stretch) > EPS then scale(c, ratio / c.stretch, true) end
end

--- Stretch an audio clip so that what it plays now lasts `beats` beats.
function M.to(id, beats)
  local c = api.clip_get(id)
  need_audio(c)
  if beats <= 0 then error("a clip lasts more than 0 beats", 2) end
  local k = daw.time.seconds(beats, c.start) / daw.time.seconds(c.length, c.start)
  scale(c, k, true)
end

--- Stretch an audio clip over beats `from` to `to`: it starts at `from`
--- and lasts until `to`, playing what it plays now.
function M.fit(id, from, to)
  api.clip_set(id, "start", math.max(0, from))
  M.to(id, to - from)
end

--- Play an audio clip's file at its own speed again, at its own length.
function M.reset(id)
  M.set(id, 1)
end

--- Shift an audio clip's pitch to `semitones` (fractions allowed) above its file's.
function M.pitch(id, semitones)
  need_audio(api.clip_get(id))
  api.clip_set(id, "pitch", semitones)
end

--- Make an audio clip follow the tempo, its sound being at `bpm` (the tempo
--- at its start, for the clip as it is stretched now, when left out); with
--- `bpm` false it keeps its time again. Its length changes as its stretch
--- does, so that it plays what it played.
function M.follow(id, bpm)
  local c = api.clip_get(id)
  need_audio(c)
  if bpm == false then return api.clip_set(id, "timebase", "time") end
  api.clip_set(id, "timebase", "stretch")
  if bpm then
    api.clip_set(id, "source_tempo", bpm)
    local now = api.clip_get(id).stretch
    if math.abs(now - c.stretch) > EPS then scale(c, now / c.stretch, false) end
  end
end

--- Loop a clip (`on` true), or stop it looping (false); `beats`, when
--- given, is how much of it repeats.
function M.loop(id, on, beats)
  if beats then api.clip_set(id, "loop_length", beats) end
  api.clip_set(id, "loop", on)
end

--- Where a looped clip's repeats begin, in beats from its start, past the
--- first: where its notches are drawn. At most `limit` (256) of them.
function M.repeats(c, limit)
  local out = {}
  if not (c.loop and c.loop_length and c.loop_length > EPS) then return out end
  local at = (c.loop_start or 0) % c.loop_length
  if at < EPS then at = c.loop_length end
  while at < c.length - EPS and #out < (limit or 256) do
    out[#out + 1] = at
    at = at + c.loop_length
  end
  return out
end

--- A MIDI clip's `notes` as they sound, counted from its start: for a
--- looped clip those of its repeated stretch over and over, each cut at the
--- end of its repeat; at most `limit` of them.
function M.sounding(c, notes, limit)
  if not (c.loop and c.loop_length and c.loop_length > EPS) then return notes end
  local out, period, from = {}, c.loop_length, c.loop_start or 0
  local base = from % period
  base = base > EPS and base - period or 0
  while base < c.length - EPS and #out < (limit or math.huge) do
    for _, n in ipairs(notes) do
      if n.start >= from - EPS and n.start < from + period - EPS then
        local at = base + n.start - from
        if at >= -EPS and at < c.length - EPS and #out < (limit or math.huge) then
          local note = daw.util.merge(n, { start = at, length = math.min(n.length, base + period - at) })
          out[#out + 1] = note
        end
      end
    end
    base = base + period
  end
  table.sort(out, function(a, b) return a.start < b.start end)
  return out
end

--- A clip's stretch, shift and loop in a few characters, for its label:
--- "×1.5 +3st ⟳", and "stretching…" while its sound is being made; nil
--- for a plain clip.
function M.badge(c)
  local ascii = daw.opt.ascii
  local parts = {}
  if c.stretching then parts[#parts + 1] = ascii and "stretching~" or "stretching…" end
  if c.stretch and math.abs(c.stretch - 1) > EPS then
    parts[#parts + 1] = string.format(ascii and "x%.3g" or "×%.3g", c.stretch)
  end
  if c.pitch and math.abs(c.pitch) > EPS then
    parts[#parts + 1] = string.format("%+.3gst", c.pitch)
  end
  -- Following the tempo, and looping.
  if c.timebase == "stretch" then parts[#parts + 1] = ascii and "bpm" or "♩" end
  if c.loop then parts[#parts + 1] = ascii and "loop" or "⟳" end
  return #parts > 0 and table.concat(parts, " ") or nil
end

return M
