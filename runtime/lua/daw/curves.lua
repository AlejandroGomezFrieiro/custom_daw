-- `daw.curves`: every curve of the project read and written alike, by its
-- address. A curve is a list of points in project beats, each with the
-- shape of the stretch that leaves it:
--
--   { beat, value, shape = "linear" | "hold" | "smooth", tension = -1..1 }
--
-- What a curve can be, and its address (see `daw.address`):
--
--   daw://lane/9                               an automation lane
--   daw://track/3/device/5/param/cutoff        a device parameter (its lane,
--                                              made at the first edit)
--   daw://clip/7/control/cc/74                 a MIDI clip's controller moves;
--   daw://clip/7/control/bend                  `bend` and `pressure` too, and
--   daw://clip/7/control/pressure#key=60       one note's own (per-note
--                                              expression) with `#key=`
--   daw://tempo                                the tempo map
--
--   local c = daw.curves.target("daw://lane/9")
--   c.points()  c.write(points)  c.format(value)  c.lo, c.hi, c.step
--
-- `lo` and `hi` are what the drawing spans, `min` and `max` what a value
-- may be, `step` how far a key moves one, and a value is typed as
-- `value * scale` (a controller from 0 to 127, the wheel and pan in
-- percent).
--
-- Not every curve has every shape: a lane has all three, the tempo map
-- straight (a ramp) and held, a controller only held moves. A stretch of a
-- shape the curve does not have is written as the many short steps or
-- ramps it is played as. The tools (`thin`, `smooth`, `quantize`,
-- `generate`) take and give point lists, and edit nothing themselves.
local api = daw.api
local util = daw.util

local M = {}

-- How finely a shape a curve lacks is written out, in beats.
M.fine = 1 / 16

local function lane_target(lane_id, uri)
  local l = api.lane_get(lane_id)
  local p = daw.lanes.param_of(l)
  local t = {
    uri = uri, kind = "lane", lane = lane_id, track = l.track,
    shapes = { linear = true, hold = true, smooth = true },
    min = l.min, max = l.max, lo = l.min, hi = l.max, step = daw.lanes.step(l),
  }
  if l.target == "volume" then t.lo, t.hi = -60, 12 end
  if l.target == "pan" then t.scale = 100 end
  t.name = function() return daw.lanes.name(lane_id) end
  t.format = function(v) return daw.lanes.format(l, v) end
  t.param = p
  t.points = function()
    local shapes = {}
    for _, s in ipairs(api.lane_shapes(lane_id)) do shapes[s.beat] = s end
    local out = {}
    for i, q in ipairs(api.lane_points(lane_id)) do
      local s = shapes[q[1]]
      out[i] = { beat = q[1], value = q[2], shape = s and s.shape or "linear", tension = s and s.tension or 0 }
    end
    return out
  end
  t.write = function(points)
    local plain, shapes = {}, {}
    for i, q in ipairs(points) do
      plain[i] = { q.beat, util.clamp(q.value, t.min, t.max) }
      if q.shape and q.shape ~= "linear" then shapes[#shapes + 1] = { beat = q.beat, shape = q.shape, tension = q.tension or 0 } end
    end
    api.lane_set_points(lane_id, plain)
    -- Two points at one beat (a jump) shape the stretch that leaves the later.
    local seen, kept = {}, {}
    for i = #shapes, 1, -1 do
      if not seen[shapes[i].beat] then
        seen[shapes[i].beat] = true
        table.insert(kept, 1, shapes[i])
      end
    end
    api.lane_set_shapes(lane_id, kept)
  end
  return t
end

local function param_target(parts, uri)
  local found = daw.address.resolve(uri)
  if not found then return nil, uri .. " is gone" end
  local device = daw.device(parts.device)
  local lane = device:lane(parts.param)
  if lane then
    local t = lane_target(lane.id, uri)
    t.kind = "param"
    return t
  end
  -- No lane yet: the parameter's own value is the curve, flat, until the
  -- first edit makes one.
  local p = found.info
  local t = {
    uri = uri, kind = "param", track = parts.track, shapes = { linear = true, hold = true, smooth = true },
    min = p.min, max = p.max, lo = p.min, hi = p.max, param = p,
    step = #p.choices > 0 and 1 or (p.max - p.min) / 100,
  }
  t.name = function() return api.device_get(parts.device).name .. " › " .. p.name end
  t.format = function(v) return daw.frontend.format_value(p, v) end
  t.points = function() return {} end
  t.flat = function() return api.device_get(parts.device).params[parts.param] end
  t.write = function(points)
    if #points == 0 then return end
    lane_target(device:automate(parts.param).id, uri).write(points)
  end
  return t
end

local CONTROL_NAMES = { [1] = "Modulation", [2] = "Breath", [7] = "Volume", [10] = "Pan", [11] = "Expression", [64] = "Sustain pedal" }

local function control_target(parts, uri)
  local clip = api.clip_get(parts.clip)
  local kind, number = parts.control, parts.number
  if kind ~= "cc" and kind ~= "bend" and kind ~= "pressure" then return nil, "no controller `" .. tostring(kind) .. "`" end
  if kind == "cc" and not number then return nil, "a controller needs its number: daw://clip/" .. parts.clip .. "/control/cc/74" end
  local key = parts.fragment and tonumber(parts.fragment:match("^key=(%d+)$"))
  local bend = kind == "bend"
  local t = {
    uri = uri, kind = "control", clip = parts.clip, track = clip.track, key = key,
    shapes = { hold = true }, min = bend and -1 or 0, max = 1, lo = bend and -1 or 0, hi = 1,
    step = bend and 1 / 64 or 1 / 127, scale = bend and 100 or 127,
  }
  t.name = function()
    local what = bend and "Pitch wheel" or kind == "pressure" and "Pressure"
      or ("CC " .. number .. (CONTROL_NAMES[number] and " " .. CONTROL_NAMES[number] or ""))
    return what .. (key and " of " .. daw.music.name(key) or "") .. " · " .. api.clip_get(parts.clip).name
  end
  t.format = function(v)
    if bend then return string.format("%+d%%", math.floor(v * 100 + 0.5 * (v < 0 and -1 or 1))) end
    return tostring(math.floor(v * 127 + 0.5))
  end
  local function mine(c)
    return c.type == kind and (kind ~= "cc" or c.number == number) and c.key == key
  end
  t.points = function()
    local start = api.clip_get(parts.clip).start
    local out = {}
    for _, c in ipairs(api.clip_controls(parts.clip)) do
      if mine(c) then out[#out + 1] = { beat = start + c.start, value = c.value, shape = "hold", tension = 0 } end
    end
    return out
  end
  t.write = function(points)
    local start = api.clip_get(parts.clip).start
    local list = {}
    for _, c in ipairs(api.clip_controls(parts.clip)) do
      if not mine(c) then list[#list + 1] = c end
    end
    for _, q in ipairs(points) do
      list[#list + 1] = { start = q.beat - start, type = kind, number = kind == "cc" and number or nil, key = key, value = util.clamp(q.value, t.min, t.max) }
    end
    table.sort(list, function(a, b) return a.start < b.start end)
    api.clip_set_controls(parts.clip, list)
  end
  return t
end

local function tempo_target(uri)
  local t = {
    uri = uri, kind = "tempo", shapes = { linear = true, hold = true }, min = 1, max = 960, step = 1,
  }
  local lo, hi = math.huge, -math.huge
  for _, q in ipairs(daw.tempo.points()) do lo, hi = math.min(lo, q.bpm), math.max(hi, q.bpm) end
  t.lo = math.max(1, math.floor((lo - 30) / 10) * 10)
  t.hi = math.ceil((hi + 30) / 10) * 10
  t.name = function() return "Tempo" end
  t.format = function(v) return string.format("%g BPM", math.floor(v * 100 + 0.5) / 100) end
  t.points = function()
    local out = {}
    for i, q in ipairs(daw.tempo.points()) do
      out[i] = { beat = q.beat, value = q.bpm, shape = q.ramp and "linear" or "hold", tension = 0 }
    end
    return out
  end
  t.write = function(points)
    local tempos = {}
    for _, q in ipairs(points) do
      local last = tempos[#tempos]
      -- The map has one tempo at a beat.
      if last and math.abs(last.beat - q.beat) < 1e-9 then tempos[#tempos] = nil end
      tempos[#tempos + 1] = { beat = q.beat, bpm = util.clamp(q.value, t.min, t.max), ramp = q.shape == "linear" }
    end
    -- It starts at the start of the song.
    if #tempos == 0 then return end
    if tempos[1].beat > 1e-9 then table.insert(tempos, 1, { beat = 0, bpm = tempos[1].bpm }) end
    tempos[1].beat = 0
    daw.tempo.set_points(tempos, nil)
  end
  return t
end

-- Curves an extension makes of an address the core would read otherwise
-- (several controllers drawn as one, through curves of their own): by
-- name, `fn(uri, parts)` giving a target as above, or nil to leave it.
M.providers = {}

function M.provide(name, fn) M.providers[name] = fn end

--- The curve at an address, or nil and why not.
function M.target(uri)
  local parts = daw.address.parse(uri)
  if not parts then return nil, "not an address: " .. tostring(uri) end
  local ok, t, why = pcall(function()
    for _, fn in pairs(M.providers) do
      local made, err = fn(uri, parts)
      if made or err then return made, err end
    end
    if parts.kind == "lane" then return lane_target(parts.lane, uri) end
    if parts.kind == "param" then return param_target(parts, uri) end
    if parts.kind == "control" then return control_target(parts, uri) end
    if parts.kind == "tempo" then return tempo_target(uri) end
    return nil, uri .. " is not a curve"
  end)
  if not ok then return nil, uri .. " is gone" end
  if not t then return nil, why end
  t.scale = t.scale or 1
  t.has = function(shape) return t.shapes[shape] == true end
  -- Where a value sits between the bottom and the top of the drawing: on a
  -- log scale for a parameter that moves on one.
  t.frac = function(v)
    if t.param and t.param.min == t.lo and t.param.max == t.hi then return daw.params.fraction(t.param, v) end
    return (v - t.lo) / (t.hi - t.lo)
  end
  t.unfrac = function(f)
    if t.param and t.param.min == t.lo and t.param.max == t.hi then return daw.params.from_fraction(t.param, f) end
    return t.lo + util.clamp(f, 0, 1) * (t.hi - t.lo)
  end
  return t
end

--- Whether a text names a curve: an address `target` can read.
function M.is_curve(uri)
  local p = daw.address.parse(uri)
  return p ~= nil and (p.kind == "lane" or p.kind == "param" or p.kind == "control" or p.kind == "tempo")
end

-- Reading a curve ------------------------------------------------------------------

--- Where a stretch is `t` of the way from one point to the next, 0 to 1,
--- as the model plays it (crates/daw-core/src/model.rs, `smooth`).
function M.ease(shape, t, tension)
  if shape == "hold" then return t >= 1 and 1 or 0 end
  if shape == "smooth" then
    t = util.clamp(t, 0, 1)
    t = t ^ (4 ^ -util.clamp(tension or 0, -1, 1))
    return t * t * (3 - 2 * t)
  end
  return t
end

--- The value of a point list at a beat: the nearest point's before the
--- first and after the last, nil with no points.
function M.value_at(points, beat)
  local n = #points
  if n == 0 then return nil end
  if beat < points[1].beat then return points[1].value end
  for i = n, 1, -1 do
    local a = points[i]
    if a.beat <= beat then
      local b = points[i + 1]
      if not b or b.beat <= a.beat then return a.value end
      local t = (beat - a.beat) / (b.beat - a.beat)
      return a.value + (b.value - a.value) * M.ease(a.shape, t, a.tension)
    end
  end
  return points[n].value
end

--- A copy of a point.
function M.copy(q)
  return { beat = q.beat, value = q.value, shape = q.shape or "linear", tension = q.tension or 0 }
end

local function sorted(points)
  local order = {}
  for i, q in ipairs(points) do order[i] = { q = q, i = i } end
  table.sort(order, function(a, b)
    if a.q.beat ~= b.q.beat then return a.q.beat < b.q.beat end
    return a.i < b.i
  end)
  local out = {}
  for i, e in ipairs(order) do out[i] = e.q end
  return out
end
M.sorted = sorted

--- Points made fit for a curve: sorted, and every stretch of a shape it
--- does not have written out as short pieces of one it has.
function M.fit(t, points)
  points = sorted(points)
  local out = {}
  local plain = t.has("linear") and "linear" or "hold"
  for i, q in ipairs(points) do
    local shape = q.shape or "linear"
    local nxt = points[i + 1]
    if t.has(shape) or not nxt or nxt.beat - q.beat <= M.fine then
      out[#out + 1] = { beat = q.beat, value = q.value, shape = t.has(shape) and shape or plain, tension = q.tension or 0 }
    else
      local steps = math.max(1, math.floor((nxt.beat - q.beat) / M.fine + 0.5))
      for k = 0, steps - 1 do
        local f = k / steps
        out[#out + 1] = {
          beat = q.beat + (nxt.beat - q.beat) * f,
          value = q.value + (nxt.value - q.value) * M.ease(shape, f, q.tension),
          shape = plain, tension = 0,
        }
      end
    end
  end
  return out
end

--- Replace the points from beat `from` to beat `to` (both included) with
--- `new`, keeping the rest: what drawing over a stretch does.
function M.splice(points, from, to, new)
  local out = {}
  for _, q in ipairs(points) do
    if q.beat < from - 1e-9 or q.beat > to + 1e-9 then out[#out + 1] = q end
  end
  for _, q in ipairs(new) do out[#out + 1] = q end
  return sorted(out)
end

-- Tools -------------------------------------------------------------------------------

--- Fewer points for the same curve: a point goes when the curve without it
--- strays from it by less than `tolerance` (a fraction of the drawing's
--- height, through `frac`). Points that hold or ease stay.
function M.thin(points, tolerance, frac)
  frac = frac or function(v) return v end
  local n = #points
  if n <= 2 then return points end
  local keep = { [1] = true, [n] = true }
  for i, q in ipairs(points) do
    if q.shape ~= "linear" or (points[i - 1] and points[i - 1].shape ~= "linear") then keep[i] = true end
  end
  -- Douglas and Peucker's: split at the point that strays most until none does.
  local function split(a, b)
    local qa, qb = points[a], points[b]
    local worst, at = 0, nil
    for i = a + 1, b - 1 do
      local q = points[i]
      local t = qb.beat > qa.beat and (q.beat - qa.beat) / (qb.beat - qa.beat) or 0
      local line = frac(qa.value) + (frac(qb.value) - frac(qa.value)) * t
      local d = math.abs(frac(q.value) - line)
      if d > worst then worst, at = d, i end
    end
    if at and worst > tolerance then
      keep[at] = true
      split(a, at)
      split(at, b)
    end
  end
  local last = 1
  for i = 2, n do
    if keep[i] then
      split(last, i)
      last = i
    end
  end
  local out = {}
  for i, q in ipairs(points) do
    if keep[i] then out[#out + 1] = q end
  end
  return out
end

--- Softer moves: each value the mean of its own and its neighbours',
--- `times` over. The first and the last stay where they are.
function M.smooth(points, times)
  local out = {}
  for i, q in ipairs(points) do out[i] = M.copy(q) end
  for _ = 1, times or 1 do
    local before = {}
    for i, q in ipairs(out) do before[i] = q.value end
    for i = 2, #out - 1 do
      out[i].value = (before[i - 1] + 2 * before[i] + before[i + 1]) / 4
    end
  end
  return out
end

--- Points moved onto the grid; of two that land on one step the later stays.
function M.quantize(points, grid)
  local out, at = {}, {}
  for _, q in ipairs(points) do
    local c = M.copy(q)
    c.beat = math.max(0, util.round(q.beat, grid))
    local key = string.format("%.6f", c.beat)
    if at[key] then out[at[key]] = c else
      out[#out + 1] = c
      at[key] = #out
    end
  end
  return sorted(out)
end

--- What `generate` makes.
M.waves = { "sine", "triangle", "saw", "square", "random", "ramp" }

--- How fast a wave goes and how far it moves, as `rate` (the beats of one
--- cycle) and `depth` (a fraction of the drawing's height): the choices
--- stepped through after `gn`, each with what it reads as.
M.rates = { { 4, "1 bar" }, { 2, "1/2" }, { 1, "1/4" }, { 0.5, "1/8" }, { 0.25, "1/16" } }
M.depths = { { 0.25, "25%" }, { 0.5, "50%" }, { 0.75, "75%" }, { 1, "100%" } }

--- A wave from beat `from` to beat `to`: `opts.rate` beats a cycle,
--- `opts.depth` of the height, about `opts.centre` (a fraction, 0.5 when
--- left out), turned into values with `opts.unfrac`. `opts.seed` makes a
--- random one the same each time. Smooth shapes where `opts.smooth` (the
--- curve has them), else many points.
function M.generate(wave, from, to, opts)
  local rate, depth = opts.rate or 1, opts.depth or 0.5
  local centre = opts.centre or 0.5
  local unfrac = opts.unfrac or function(f) return f end
  local lo = util.clamp(centre - depth / 2, 0, 1)
  local hi = util.clamp(lo + depth, 0, 1)
  lo = hi - depth < 0 and 0 or hi - depth
  local out = {}
  local function add(beat, f, shape)
    if beat <= to + 1e-9 then out[#out + 1] = { beat = beat, value = unfrac(f), shape = shape or "linear", tension = 0 } end
  end
  if wave == "ramp" then
    add(from, lo)
    add(to, hi)
    return out
  end
  local cycles = math.max(1, math.ceil((to - from) / rate - 1e-9))
  local seed = opts.seed or 1
  local function random(k)
    local x = math.sin(seed * 12.9898 + k * 78.233) * 43758.5453
    return x - math.floor(x)
  end
  for k = 0, cycles - 1 do
    local b = from + k * rate
    if wave == "sine" then
      if opts.smooth then
        add(b, (lo + hi) / 2, "smooth")
        add(b + rate / 4, hi, "smooth")
        add(b + rate * 3 / 4, lo, "smooth")
      else
        for s = 0, 15 do add(b + rate * s / 16, lo + (hi - lo) * (0.5 + 0.5 * math.sin(2 * math.pi * s / 16))) end
      end
    elseif wave == "triangle" then
      add(b, lo)
      add(b + rate / 2, hi)
    elseif wave == "saw" then
      add(b, lo)
      add(b + rate * 63 / 64, hi, "hold")
    elseif wave == "square" then
      add(b, hi, "hold")
      add(b + rate / 2, lo, "hold")
    elseif wave == "random" then
      add(b, lo + (hi - lo) * random(k), "hold")
    end
  end
  -- The wave ends where it would be at the end.
  local last = out[#out]
  if wave ~= "random" and wave ~= "square" and last and last.beat < to - 1e-9 then
    local phase = ((to - from) % rate) / rate
    local f
    if wave == "sine" then f = 0.5 + 0.5 * math.sin(2 * math.pi * phase)
    elseif wave == "triangle" then f = phase < 0.5 and phase * 2 or 2 - phase * 2
    else f = phase end
    if phase < 1e-9 then f = wave == "sine" and 0.5 or 0 end
    add(to, lo + (hi - lo) * f)
  end
  return out
end

return M
