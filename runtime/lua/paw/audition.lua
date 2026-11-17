-- `paw.audition`: hear something before choosing it, without the project or
-- its undo history keeping a trace. The pickers use it as their selection
-- moves (`audition` in `paw.pick`), and scripts can too:
--
--   paw.audition.try(function() paw.fx.load(device, "Plate") end)  -- an edit that can be taken back
--   paw.audition.phrase(track.id, notes, { length = 4, label = "loop bar 5" })
--   paw.audition.file("/samples/kick.wav")
--   paw.audition.stop()                       -- silence, and take the edit back
--
-- A trial (`try`) makes its edits as any others, so that they are heard and
-- seen; `revert` puts the project back exactly as it was, and `keep` makes
-- them one undo step. A phrase is played through a track as notes played
-- live, over and over until stopped, and is not played while the transport
-- runs: the song is what is heard then. A file is heard on its own over
-- everything else at `paw.opt.audition_level` dB.
local api = paw.api
local M = {}

paw.option.define("audition_level", -12) -- dB a sound file heard in a picker plays at
paw.option.define("audition_delay", 150) -- ms the selection rests on an item before it is heard

local EPS = 1e-9

-- What is heard now: `{ label, track, notes, length, key }` for a phrase.
local phrase
local timers, sounding = {}, {}
M.heard = {} -- the notes played lately, `{ track, pitch, velocity }`, newest last
-- Counts what was asked to be heard, so that a picker can tell whether an
-- item asked for anything: what came before is stopped when it did not.
M.asked = 0

paw.seats.keep("audition", function() return phrase end, function(p) phrase = p end, function() return nil end)

local function silence()
  for _, t in ipairs(timers) do paw.cancel(t) end
  timers = {}
  for key in pairs(sounding) do
    local track, pitch = key:match("^(%d+):(%d+)$")
    pcall(api.note_off, tonumber(track), tonumber(pitch))
  end
  sounding = {}
end

-- Trials -----------------------------------------------------------------------

--- Make the edits `fn` makes as a trial, in place of the last one: they are
--- heard and seen, and `revert` takes them back without a trace. Returns
--- what `fn` returns; an error takes the edits back and is raised.
function M.try(fn)
  M.revert()
  api.trial_begin()
  local result = { pcall(fn) }
  if not result[1] then
    M.revert()
    error(result[2], 0)
  end
  return unpack(result, 2, table.maxn(result))
end

--- Put the project back as it was before the trial, if there is one.
function M.revert()
  if api.trial_active() then api.trial_end(false) end
end

--- Keep the trial's edits as one undo step.
function M.keep()
  if api.trial_active() then api.trial_end(true) end
end

-- Phrases ----------------------------------------------------------------------

--- Milliseconds between two beats: at a phrase's own tempo when it has
--- one, else at the project's there.
local function ms_between(from, to, tempo)
  if tempo then return math.max(0, (to - from) * 60000 / tempo) end
  return math.max(0, (paw.time.to_seconds(to) - paw.time.to_seconds(from)) * 1000)
end

local function remember(track, n)
  local heard = M.heard
  heard[#heard + 1] = { track = track, pitch = n.pitch, velocity = n.velocity }
  if #heard > 256 then table.remove(heard, 1) end
end

local function pass()
  local p = phrase
  if not p then return end
  local at, tempo = p.at, p.tempo
  for _, n in ipairs(p.notes) do
    local track = n.track or p.track
    local on = ms_between(at, at + n.start, tempo)
    local off = math.max(on + 20, ms_between(at, at + math.min(n.start + n.length, p.length), tempo) - 5)
    local key = track .. ":" .. n.pitch
    timers[#timers + 1] = paw.defer(function()
      if phrase ~= p then return end
      sounding[key] = true
      remember(track, n)
      pcall(api.note_on, track, n.pitch, n.velocity)
    end, on)
    timers[#timers + 1] = paw.defer(function()
      sounding[key] = nil
      pcall(api.note_off, track, n.pitch)
    end, off)
  end
  timers[#timers + 1] = paw.defer(function()
    if phrase ~= p then return end
    -- Each pass leaves its own timers behind: only the next pass's are kept.
    timers = {}
    if p.loop then pass() else phrase = nil end
  end, ms_between(at, at + p.length, tempo))
end

--- Play `notes` (`{ pitch, start, length, velocity }`, `start` in beats from
--- the phrase's start; a note's own `track` over the phrase's) through a
--- track, again every `opts.length` beats (or once with `loop = false`).
--- `opts.label` says what it is; a phrase with the same `opts.key` as the
--- one playing goes on without starting again, so that what changes is
--- only the sound. `opts.tempo` is its own tempo, else the project's at
--- `opts.at` (the cursor's). Nothing is played while the transport runs.
function M.phrase(track, notes, opts)
  M.asked = M.asked + 1
  opts = opts or {}
  local length = opts.length or 4
  if phrase and opts.key and phrase.key == opts.key and phrase.track == track then
    phrase.label = opts.label or phrase.label
    return phrase
  end
  silence()
  phrase = {
    track = track, notes = notes, length = length, label = opts.label, key = opts.key,
    loop = opts.loop ~= false, at = opts.at or paw.cursor.beat or 0, tempo = opts.tempo,
  }
  if api.transport_get().playing then
    phrase.silent = "the song is playing"
    return phrase
  end
  pass()
  return phrase
end

--- A bar of a pattern for a drum track, by General MIDI note.
local DRUMS = {
  { 36, 0, 110 }, { 42, 0, 80 }, { 42, 0.5, 70 }, { 38, 1, 105 }, { 42, 1, 80 }, { 42, 1.5, 70 },
  { 36, 2, 110 }, { 42, 2, 80 }, { 36, 2.5, 90 }, { 42, 2.5, 70 }, { 38, 3, 105 }, { 42, 3, 80 }, { 42, 3.5, 70 },
}

--- A phrase for a track with nothing to play: a bar of a beat for a drum
--- track; else the key's tonic chord held, then arpeggiated up and back,
--- in the track's range. `{ notes, length, label }`.
function M.builtin(track, at)
  at = at or paw.cursor.beat or 0
  local notes = {}
  if track and paw.harmony.is_drums(track) then
    for i, d in ipairs(DRUMS) do notes[i] = { pitch = d[1], start = d[2], length = 0.25, velocity = d[3] } end
    return { notes = notes, length = 4, label = "a built-in beat" }
  end
  local key = paw.harmony.key(at)
  local range = track and paw.harmony.range(track) or paw.harmony.default_range
  -- The tonic nearest the middle of the range, a third and a fifth above.
  local middle = math.floor((range.low + range.high) / 2)
  local root = middle - ((middle - key.root) % 12)
  if root + 7 > range.high then root = root - 12 end
  local chord = { root, paw.harmony.step(key, root, 2), paw.harmony.step(key, root, 4) }
  for _, pitch in ipairs(chord) do notes[#notes + 1] = { pitch = pitch, start = 0, length = 1.75, velocity = 90 } end
  local line = { chord[1], chord[2], chord[3], chord[1] + 12, chord[3], chord[2] }
  for i, pitch in ipairs(line) do
    notes[#notes + 1] = { pitch = pitch, start = 2 + (i - 1) / 3, length = 1 / 3, velocity = 85 }
  end
  return { notes = notes, length = 4, label = "a built-in phrase in " .. paw.harmony.key_name(key) }
end

--- What a track plays around the cursor, as a phrase: the bar of its MIDI
--- clip at the cursor, else the last bar before the cursor that has notes,
--- else the first that has any; `builtin` when it has none.
--- `{ notes, length, label, at }`.
function M.track_phrase(track)
  local cursor = paw.cursor.beat or 0
  local bars = {}
  for _, c in ipairs(track and api.clip_list(track) or {}) do
    if c.kind == "midi" and not c.muted then
      for _, n in ipairs(api.clip_notes(c.id)) do
        local s = c.start + n.start
        if n.start >= -EPS and n.start < c.length - EPS then
          local bar = paw.time.bar_floor(s + EPS)
          local list = bars[bar] or {}
          bars[bar] = list
          list[#list + 1] = { pitch = n.pitch, start = s - bar, length = n.length, velocity = n.velocity }
        end
      end
    end
  end
  local here = paw.time.bar_floor(cursor + EPS)
  local chosen = bars[here] and here
  if not chosen then
    local before, first
    for bar in pairs(bars) do
      if bar <= here and (not before or bar > before) then before = bar end
      if not first or bar < first then first = bar end
    end
    chosen = before or first
  end
  if not chosen then
    local b = M.builtin(track, cursor)
    b.at = cursor
    return b
  end
  local length = paw.time.bar(chosen)
  local notes = {}
  for _, n in ipairs(bars[chosen]) do
    if n.start < length - EPS then notes[#notes + 1] = n end
  end
  table.sort(notes, function(a, b) return a.start < b.start end)
  return { notes = notes, length = length, at = chosen, label = "loop bar " .. paw.time.bar_of(chosen) }
end

--- Whether a track has an instrument to play notes with.
function M.has_instrument(track)
  local category = {}
  for _, info in ipairs(paw.device_types()) do category[info.kind] = info.category end
  for _, id in ipairs(api.track_get(track).devices) do
    local ok, d = pcall(api.device_get, id)
    if ok and not d.bypass and category[d.kind] == "instrument" then return true end
  end
  return false
end

--- Play what a track plays around the cursor through it, over and over
--- (`track_phrase`), so that a sound tried on it is heard with its own
--- notes; the loop goes on while only the sound changes. Returns what is
--- heard, in words.
function M.through(track)
  M.asked = M.asked + 1
  if api.transport_get().playing then
    silence()
    phrase = nil
    return "with the song"
  end
  if not M.has_instrument(track) then
    silence()
    phrase = nil
    return "heard when the song plays"
  end
  local p = M.track_phrase(track)
  M.phrase(track, p.notes, { length = p.length, at = p.at, label = p.label, key = p.label .. "@" .. tostring(p.at) })
  return p.label
end

--- A track to play notes through: the cursor's when it has an instrument,
--- else one added as a trial (with the built-in synth, or drums) that
--- `revert` takes away. `drums` asks for a drum kit.
function M.player(drums)
  local track = paw.cursor.track_id()
  if track and M.has_instrument(track) and (not drums or paw.harmony.is_drums(track)) then return track end
  if not api.trial_active() then api.trial_begin() end
  local t = paw.add_track({ name = drums and "Audition drums" or "Audition" })
  t:add_device(drums and "drums" or "synth")
  return t.id
end

--- Play the first `bars` bars of a MIDI file (2 when nil), at its own tempo,
--- once: pitched parts through `player()`, its drums (channel 10) through
--- a kit. Returns the label.
function M.midi_file(path, bars)
  local file, why = paw.midifile.read(path)
  if not file then error(why, 0) end
  local ppq = file.ppq
  local sig = file.signatures[1] or { num = 4, den = 4 }
  local length = (bars or 2) * sig.num * 4 / sig.den
  local tempo = file.tempos[1] and file.tempos[1].bpm or 120
  local notes, has = {}, {}
  for _, track in ipairs(file.tracks) do
    for _, n in ipairs(track.notes) do
      local start = n.tick / ppq
      if start < length then
        local drum = n.channel == 9
        has[drum and "drums" or "notes"] = true
        notes[#notes + 1] = { pitch = n.pitch, start = start, length = math.max(n.length / ppq, 1 / 16), velocity = n.velocity, drum = drum }
      end
    end
  end
  if #notes == 0 then return "nothing in its first bars" end
  local pitched = has.notes and M.player(false)
  local kit = has.drums and M.player(true)
  for _, n in ipairs(notes) do n.track = n.drum and kit or pitched end
  M.phrase(pitched or kit, notes, { length = length, loop = false, tempo = tempo })
  return string.format("first %d bars at %g BPM", bars or 2, tempo)
end

-- Files ------------------------------------------------------------------------

--- Hear a sound file on its own, from its start, in place of whatever was.
function M.file(path)
  M.asked = M.asked + 1
  silence()
  phrase = nil
  api.preview_level(paw.opt.audition_level)
  api.preview_play(path)
end

paw.on("option.changed", function(e)
  if e.name == "audition_level" then pcall(api.preview_level, tonumber(e.value) or -12) end
end)

-- Stopping ---------------------------------------------------------------------

--- Stop what is heard (phrase and file), leaving a trial as it is.
function M.quiet()
  silence()
  phrase = nil
  api.preview_stop()
end

--- Stop what is heard and take a trial back.
function M.stop()
  M.quiet()
  M.revert()
end

--- What is heard now: `{ kind = "phrase", label, track, notes, length,
--- silent }`, `{ kind = "file", file, state, position, length, outline }`
--- or nil; `trial` is true while a trial's edits stand.
function M.state()
  local file = api.preview_get()
  local out
  if file then
    out = paw.util.merge(file, { kind = "file" })
  elseif phrase then
    out = { kind = "phrase", label = phrase.label, track = phrase.track, notes = phrase.notes, length = phrase.length, silent = phrase.silent }
  end
  if out then out.trial = api.trial_active() end
  return out
end

-- Drawing ----------------------------------------------------------------------

local BARS = { " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

--- A sound file's outline as `rows` lines `width` columns wide, the loudest
--- part of each column drawn up from the bottom, and the column the file
--- has got to, if `position` (seconds of `length`) is given.
function M.outline_lines(outline, width, rows, position, length)
  local out = {}
  if not outline or #outline == 0 or width < 1 then return out end
  local heights = {}
  for x = 1, width do
    local from = math.floor((x - 1) * #outline / width) + 1
    local to = math.max(from, math.floor(x * #outline / width))
    local peak = 0
    for i = from, to do peak = math.max(peak, outline[i] or 0) end
    -- Loudness as heard: decibels from -48 up to full scale.
    local db = peak > 0 and 20 * math.log10(peak) or -96
    heights[x] = math.max(0, math.min(1, (db + 48) / 48)) * rows * 8
  end
  local at = position and length and length > 0 and math.floor(position / length * width) + 1 or nil
  for row = rows, 1, -1 do
    local cells = {}
    for x = 1, width do
      local h = heights[x] - (row - 1) * 8
      cells[x] = BARS[math.max(0, math.min(8, math.floor(h + 0.5))) + 1]
    end
    out[#out + 1] = { text = table.concat(cells), at = at }
  end
  return out
end

return M
