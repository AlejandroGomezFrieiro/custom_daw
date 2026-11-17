-- The vocal editor's pitch and curves in pixels, where the terminal shows
-- pictures (`buf:strip`): under the notes, the line each note is sung on
-- (its transition from the note before and its vibrato, as the window's
-- Pitch tool draws them, plus the pitch curve) and the pitch the engine
-- sang; under the curve rows, the chosen curve through `daw.plot`. The
-- notes, lyrics, cursor and playhead stay cells, drawn over the pictures.
-- Each drawing is cut at the bars, so that an edit sends again only the
-- bars it touched.
local api = daw.api
local notes = require("utau.notes")
local shapes = require("utau.shapes")
local proto = require("utau.proto")

local M = {}

local floor = math.floor

local function palette() return require("daw.theme").palette end

--- Where the drawing `w` pixels wide may be cut, from the project beat
--- `from` at `ppb` pixels a beat: 0, each bar on a cell's edge, and `w`.
local function edges(g, w, h, from, ppb, cw)
  local out = { 0 }
  for _, line in ipairs(daw.plot.lines(w, from, ppb, cw)) do
    if line.cut and line.cut > out[#out] and line.cut < w then
      out[#out + 1] = line.cut
      g:cut(line.cut, 0, h)
    end
  end
  out[#out + 1] = w
  return out
end

--- Draw `value(x)`, a height in pixels or nil for none, once a pixel
--- across, as lines broken where it has none and at the cuts.
local function trace(g, cuts, value, style)
  for i = 1, #cuts - 1 do
    local line = {}
    for x = cuts[i], cuts[i + 1] do
      local y = value(x)
      if y then
        line[#line + 1] = x
        line[#line + 1] = y
      else
        if #line >= 4 then g:poly(line, style) end
        line = {}
      end
    end
    if #line >= 4 then g:poly(line, style) end
  end
end

--- The pitch a clip's notes are sung on, in semitones, at a beat of the
--- clip: the note's own, its transition from the note before (which may
--- begin before the note does), its vibrato and the pitch curve. A
--- function of beats that only go up, nil where no note sounds.
function M.written(list, tempo, pitd)
  local cache = {}
  local function shape_of(k)
    if not cache[k] then
      local note = list[k]
      cache[k] = { pts = shapes.points(note, list[k - 1]), vb = shapes.vb(note), dur = shapes.ms(note.length, tempo) }
    end
    return cache[k]
  end
  local over = notes.walker(list)
  return function(beat)
    local note, k = over(beat)
    local next_k = (k or 0) + 1
    local after = list[next_k]
    -- The next note's transition, once it has begun.
    if after then
      local s = shape_of(next_k)
      local ms = shapes.ms(beat - after.start, tempo)
      if s.pts[1] and ms >= s.pts[1][1] then note, k = after, next_k end
    end
    if not note or beat >= note.start + note.length then return nil end
    local s = shape_of(k)
    local ms = shapes.ms(beat - note.start, tempo)
    local semis = note.pitch + (shapes.transition_at(s.pts, ms) or 0)
    semis = semis + shapes.vibrato_at(s.vb, (beat - note.start) / note.length, s.dur) / 100
    return semis + (pitd and pitd(beat) or 0) / 100
  end
end

--- The roll's picture. `o`: `list` (the clip's notes), `clip`, `scroll`
--- (the beat of the clip at the left edge), `zoom` (cells a beat), `top`
--- (the pitch of the first row), `pitd` (the pitch curve's points, as
--- lanes give them, or nil), `sung` (the engine's pitch: `{ step, ticks }`).
function M.roll(g, px, o)
  local P = palette()
  local cw, ch = px.cell.w, px.cell.h
  local ppb = o.zoom * cw
  local function Y(semis) return (o.top - semis) * ch + ch / 2 end
  local cuts = edges(g, px.w, px.h, o.clip.start + o.scroll, ppb, cw)
  local pitd = o.pitd and #o.pitd > 0 and notes.sampler(o.pitd, 0) or nil
  local tempo = api.project_get().tempo
  local written = M.written(o.list, tempo, pitd and function(beat) return pitd(o.clip.start + beat) end)
  local length = o.clip.length
  trace(g, cuts, function(x)
    local beat = o.scroll + x / ppb
    if beat > length then return nil end
    local semis = written(beat)
    return semis and Y(semis)
  end, { color = P.orange, width = 1.5 })
  local sung = o.sung
  if not sung then return end
  -- The engine's pitch: a point every `step` ticks, broken where it is not
  -- voiced and at the cuts.
  local step = sung.step or 5
  local first = math.max(0, floor(o.scroll * proto.TICKS / step) * step)
  local last = (o.scroll + px.w / ppb) * proto.TICKS + step
  local cut, line, prev = 2, {}, nil
  local style = { color = "#ffffff", width = 1.5 }
  for tick = first, last, step do
    local cents = sung.ticks[tick]
    local x = (tick / proto.TICKS - o.scroll) * ppb
    while cuts[cut] and x > cuts[cut] do
      -- Across a cut: the line ends a point past it and starts again a
      -- point before it.
      if cents and prev then
        line[#line + 1], line[#line + 2] = x, Y(cents / 100)
        if #line >= 4 then g:poly(line, style) end
        line = { prev[1], prev[2] }
      end
      cut = cut + 1
    end
    if cents then
      line[#line + 1], line[#line + 2] = x, Y(cents / 100)
      prev = { x, Y(cents / 100) }
    else
      if #line >= 4 then g:poly(line, style) end
      line, prev = {}, nil
    end
  end
  if #line >= 4 then g:poly(line, style) end
end

--- The curve rows' picture: a curve of the vocal device. `o`: `info` (the
--- curve: `key`, `min`, `max`, `default`), `points` (its lane's, or none),
--- `constant` (the value with no points), `clip`, `scroll`, `zoom`.
function M.curve(g, px, o)
  local P = palette()
  local points = {}
  for i, p in ipairs(o.points or {}) do points[i] = { beat = p[1], value = p[2], shape = "linear", tension = 0 } end
  -- Up to the clip's end, as the notes go.
  local ppb = o.zoom * px.cell.w
  local w = math.min(px.w, floor((o.clip.length - o.scroll) * ppb + 0.5))
  if w <= 0 then return end
  local part = { w = w, h = px.h, cell = px.cell, fg = px.fg, bg = px.bg }
  g = g:sub(0, 0, w, px.h)
  local _, Y = daw.plot.curve(g, part, {
    points = points, from = o.clip.start + o.scroll, pixels_per_beat = ppb,
    lo = o.info.min, hi = o.info.max, flat = #points == 0 and o.constant or nil,
    color = P.green, guides = false, markers = false,
  })
  -- The default, as a line across.
  g:rect(0, floor(Y(o.info.default)), w, 1, { fill = daw.plot.alpha(P.dim, 0.6) })
end

return M
