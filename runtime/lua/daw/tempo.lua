-- `daw.tempo`: the tempo map. Tempo and time signature can change along the
-- song; everything that turns beats into seconds or bars asks here.
--
--   daw.tempo.at(17)                       -- BPM at beat 17
--   daw.tempo.set(16, 96)                  -- 96 BPM from beat 16 on
--   daw.tempo.set(8, 120, { ramp = true }) -- from beat 8, ramp to the next point
--   daw.tempo.remove(16)
--   daw.tempo.points()                     -- { { beat, bpm, ramp }, ... }
--   daw.tempo.set_signature(9, 6, 8)       -- bar 9 and on in 6/8
--   daw.tempo.signature_at(33)             -- 6, 8
--   daw.tempo.beats_to_seconds(16)  daw.tempo.seconds_to_beats(8)
--   daw.tempo.bar_of(33)                   -- 9 (bars count from 1)
--
-- A ramp changes the tempo linearly in time, as REAPER's does. A signature
-- change starts a new bar where it is, cutting short a bar it falls inside.
-- `daw.project.tempo` is the tempo at the start.
local api = require("daw.api")

local M = {}

--- The tempo at a beat (the start if left out).
function M.at(beat) return api.tempo_at(beat or 0) end

--- Set the tempo from `beat` on. `opts.ramp`: ramp from here to the next
--- point's tempo instead of holding; left out, a point keeps what it had.
function M.set(beat, bpm, opts)
  api.tempo_set(beat, bpm, opts and opts.ramp)
end

--- Remove the tempo change at `beat`.
function M.remove(beat) api.tempo_remove(beat) end

--- Every tempo point, the start's first: { beat, bpm, ramp }.
function M.points() return api.tempo_points().tempos end

--- Every signature point, the start's first: { beat, bar, num, den }.
function M.signatures() return api.tempo_points().signatures end

--- The signature at a beat, as two numbers.
function M.signature_at(beat) return api.tempo_signature(beat or 0) end

--- Start bar `bar` (counting from 1) in `num`/`den`, up to the next change.
function M.set_signature(bar, num, den)
  api.signature_set(api.tempo_bar_start(bar - 1), num, den)
end

--- Remove the signature change that starts bar `bar`.
function M.remove_signature(bar) api.signature_remove(api.tempo_bar_start(bar - 1)) end

--- Replace the whole map: `set_points({ { beat = 0, bpm = 120 } }, { { beat = 0, num = 4, den = 4 } })`.
function M.set_points(tempos, signatures)
  api.tempo_set_points(tempos or M.points(), signatures or M.signatures())
end

M.beats_to_seconds = api.tempo_seconds
M.seconds_to_beats = api.tempo_beat

--- Seconds from beat `from` to beat `to`.
function M.seconds_between(from, to) return api.tempo_seconds(to) - api.tempo_seconds(from) end

--- The bar a beat is in, counting from 1.
function M.bar_of(beat) return api.tempo_bar_of(beat) + 1 end

--- Where bar `n` (counting from 1) starts, in beats.
function M.bar_start(n) return api.tempo_bar_start(n - 1) end

--- Whether a bar starts at this beat.
M.is_bar_line = api.tempo_is_bar_line

--- The bar and beat lines from one beat to another: { beat, bar, index },
--- `index` 0 on a bar line (bars count from 1).
function M.lines(from, to, limit) return api.tempo_lines(from, to, limit) end

--- What a tempo change reads as on a ruler: "96" or "120>" for a ramp.
function M.label(point)
  return string.format("%g", math.floor(point.bpm * 100 + 0.5) / 100) .. (point.ramp and ">" or "")
end

--- Tempo and signature changes from one beat to another, for a ruler to
--- mark: { beat, text, kind = "tempo" | "signature" }, the start's left out.
function M.marks(from, to)
  local p, out = api.tempo_points(), {}
  for i, t in ipairs(p.tempos) do
    if i > 1 and t.beat >= from and t.beat < to then
      out[#out + 1] = { beat = t.beat, text = M.label(t), kind = "tempo" }
    end
  end
  for i, s in ipairs(p.signatures) do
    if i > 1 and s.beat >= from and s.beat < to then
      out[#out + 1] = { beat = s.beat, text = s.num .. "/" .. s.den, kind = "signature" }
    end
  end
  table.sort(out, function(a, b) return a.beat < b.beat end)
  return out
end

-- Commands ------------------------------------------------------------------

--- A place given to a command: a bar (`17`), a bar and beat (`17.3`), or
--- `cursor` / `here`; the cursor's beat when nothing is given.
function M.place(text)
  if text == nil or text == "cursor" or text == "here" then return daw.cursor.beat end
  local bar, beat = tostring(text):match("^(%d+)%.?(%d*)$")
  if not bar then error("a place is a bar (17), a bar and beat (17.3) or `cursor`, not " .. tostring(text), 0) end
  bar = tonumber(bar)
  if bar < 1 then error("bars count from 1", 0) end
  return api.tempo_from_bbt(bar - 1, math.max(0, (tonumber(beat) or 1) - 1))
end

--- The tempo point in effect at a beat.
function M.point_at(beat)
  local found
  for _, p in ipairs(M.points()) do
    if p.beat <= beat + 1e-9 then found = p end
  end
  return found
end

--- What a position reads as in commands' messages: "bar 9" or "9.2.50".
local function where(beat)
  if api.tempo_is_bar_line(beat) then return "bar " .. M.bar_of(beat) end
  return daw.time.format(beat)
end

--- "120 bpm 4/4 at bar 1; 90 bpm from bar 3, ramping; ..." for the whole map.
function M.describe()
  local parts = {}
  for _, p in ipairs(M.points()) do
    parts[#parts + 1] = string.format("%s: %g bpm%s", where(p.beat), p.bpm, p.ramp and ", ramping to the next" or "")
  end
  for _, s in ipairs(M.signatures()) do
    parts[#parts + 1] = string.format("bar %d: %d/%d", s.bar, s.num, s.den)
  end
  return parts
end

local taps = {}

--- Completion for a place: `at`, `here`, and the bars where something changes.
local function places(_, info)
  if info.words[#info.words] == "at" then
    local out = { "cursor" }
    for _, p in ipairs(M.points()) do out[#out + 1] = tostring(M.bar_of(p.beat)) end
    for _, sig in ipairs(M.signatures()) do out[#out + 1] = tostring(sig.bar) end
    return out
  end
  return { "at", "here" }
end

local SIGNATURES = { "4/4", "3/4", "6/8", "2/4", "5/4", "7/8", "12/8", "9/8" }

function M.commands(command)
  command("tempo", function(ctx)
    local a = ctx.args
    local bpm = tonumber(a[1])
    if a.by then bpm = daw.project.tempo + a.by end
    if not bpm then
      local beat = daw.cursor.beat
      return daw.notify(string.format("tempo is %g bpm at the start, %g at the cursor (%s)", daw.project.tempo, M.at(beat), where(beat)))
    end
    bpm = math.max(1, math.min(999, bpm))
    local at = a.at or (a[2] == "at" and (a[3] or "cursor")) or ((a[2] == "here" or a[2] == "cursor") and "cursor")
    if not at then
      daw.project.tempo = bpm
    else
      local beat = M.place(at)
      api.tempo_set(beat, bpm)
      daw.notify(string.format("%g bpm from %s", bpm, where(beat)))
    end
  end, {
    desc = "Show or set the tempo: `tempo 140` (at the start), `tempo 96 at 17` (bar 17), `tempo 96 here`, `tempo by=-1`",
    label = "Set the tempo",
    complete = function(text, info)
      if info.index == 1 then return { tostring(math.floor(M.at(daw.cursor.beat) + 0.5)) } end
      return places(text, info)
    end,
  })

  command("tempo.ramp", function(ctx)
    local a = ctx.args
    local beat = (a[1] or a.at) and M.place(a.at or (a[1] == "at" and a[2] or a[1])) or daw.cursor.beat
    local p = M.point_at(beat)
    local on = not p.ramp
    if a.off or a[1] == "off" then on = false end
    api.tempo_set(p.beat, p.bpm, on)
    daw.notify(string.format("%g bpm at %s %s", p.bpm, where(p.beat), on and "ramps to the next change" or "holds"))
  end, {
    desc = "Make the tempo change before the cursor ramp to the next one, or hold again: `tempo.ramp`, `tempo.ramp 9`",
    label = "Ramp the tempo",
    complete = function() return { "off", "at" } end,
  })

  command("tempo.remove", function(ctx)
    local a = ctx.args
    local beat = a[1] and M.place(a[1]) or daw.cursor.beat
    local p = M.point_at(beat)
    if p.beat == 0 then error("no tempo change at or before " .. where(beat) .. " but the start's", 0) end
    api.tempo_remove(p.beat)
    daw.notify("removed the tempo change at " .. where(p.beat))
  end, {
    desc = "Remove the tempo change at or before the cursor, or at a bar: `tempo.remove 17`",
    label = "Remove a tempo change",
    complete = function()
      local out = {}
      for i, p in ipairs(M.points()) do
        if i > 1 then out[#out + 1] = { text = tostring(M.bar_of(p.beat)), desc = string.format("%g bpm", p.bpm) } end
      end
      return out
    end,
  })

  command("tempo.list", function()
    local lines = M.describe()
    daw.notify(table.concat(lines, " · "))
    return lines
  end, { desc = "List the tempo and time signature changes" })

  command("tempo.tap", function()
    local now = api.now()
    if #taps > 0 and now - taps[#taps] > 2000 then taps = {} end
    taps[#taps + 1] = now
    while #taps > 8 do table.remove(taps, 1) end
    if #taps < 2 then return daw.notify("tap again in time") end
    local bpm = 60000 * (#taps - 1) / (taps[#taps] - taps[1])
    bpm = math.floor(math.max(1, math.min(999, bpm)) * 10 + 0.5) / 10
    local p = M.point_at(daw.cursor.beat)
    api.tempo_set(p.beat, bpm)
    daw.notify(string.format("tapped %g bpm at %s", bpm, where(p.beat)))
  end, { desc = "Tap in time, again and again, to set the tempo in effect at the cursor", label = "Tap the tempo" })

  command("timesig", function(ctx)
    local a = ctx.args
    local text = a[1]
    if text == nil then
      local num, den = M.signature_at(daw.cursor.beat)
      return daw.notify(string.format("%d/%d at %s", num, den, where(daw.cursor.beat)))
    end
    local num, den = tostring(text):match("^(%d+)/(%d+)$")
    if not num then error("write a time signature as 6/8", 0) end
    local at = a.at or (a[2] == "at" and a[3]) or a[2]
    local beat = at and M.place(at) or daw.time.bar_floor(daw.cursor.beat)
    api.signature_set(beat, tonumber(num), tonumber(den))
    daw.notify(string.format("%s/%s from %s", num, den, where(beat)))
  end, {
    desc = "Set the time signature from the cursor's bar on, or from a bar: `timesig 6/8`, `timesig 3/4 at 9`",
    label = "Set the time signature",
    complete = function(text, info)
      if info.index == 1 then return SIGNATURES end
      return places(text, info)
    end,
  })

  command("timesig.remove", function(ctx)
    local beat = ctx.args[1] and M.place(ctx.args[1]) or daw.cursor.beat
    local found
    for _, s in ipairs(M.signatures()) do
      if s.beat <= beat + 1e-9 then found = s end
    end
    if found.beat == 0 then error("no signature change at or before " .. where(beat) .. " but the start's", 0) end
    api.signature_remove(found.beat)
    daw.notify("removed the signature change at bar " .. found.bar)
  end, {
    desc = "Remove the time signature change at or before the cursor, or at a bar",
    label = "Remove a time signature change",
    complete = function()
      local out = {}
      for i, sig in ipairs(M.signatures()) do
        if i > 1 then out[#out + 1] = { text = tostring(sig.bar), desc = sig.num .. "/" .. sig.den } end
      end
      return out
    end,
  })
end

return M
