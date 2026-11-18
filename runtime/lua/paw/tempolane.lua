-- The tempo lane: the tempo map drawn as a curve in a row under the ruler, in
-- steps where a change holds and in slopes where it ramps. It is a way to
-- look at the map and to edit it with the pointer; every edit is one made to
-- `paw.tempo`, so the grid, the ruler and the clips that follow the tempo
-- follow the lane, and undo takes it back.
--
--   paw.tempolane.toggle()            -- show or hide the row
--   paw.tempolane.range()             -- the tempo at its bottom and its top
--   paw.tempolane.add(17, 96)         -- a change to 96 bpm at beat 17
--   paw.tempolane.move(17, 20, 100)   -- the change at beat 17 to beat 20, at 100 bpm
--   paw.tempolane.remove(20)
--   paw.tempolane.draw({ { 8, 120 }, { 9, 118 }, ... })  -- a stroke of the pencil
--
-- Whether the row is shown is kept for the session (it survives `:reload`),
-- not in the project, as for the automation lanes.
local api = paw.api
local M = {}

local shown = api.state_get("tempo_lane") == true

local function changed()
  api.ui_redraw()
  -- A graphical frontend draws it too.
  if paw.emit then paw.emit("lanes.changed", {}) end
end

--- Whether the row is shown.
function M.shown() return shown end

--- Show the row, or hide it (`on` false).
function M.show(on)
  shown = on ~= false
  api.state_set("tempo_lane", shown)
  changed()
end

--- Show the tempo lane, or hide it; returns whether it shows.
function M.toggle()
  M.show(not shown)
  return shown
end

--- The tempo at the bottom and at the top of the row: a little room round
--- the slowest and fastest tempo in the map, in tens of beats a minute, and
--- never less than 80 apart, centred, so that a steady song is not drawn as a wall.
function M.range()
  local lo, hi = math.huge, 0
  for _, p in ipairs(paw.tempo.points()) do
    lo, hi = math.min(lo, p.bpm), math.max(hi, p.bpm)
  end
  lo = math.max(0, math.floor((lo - 30) / 10) * 10)
  hi = math.ceil((hi + 30) / 10) * 10
  if hi - lo < 80 then
    local extra = (80 - (hi - lo)) / 2
    lo = math.max(0, lo - extra)
    hi = lo + 80
  end
  return lo, hi
end

--- Where a tempo is in the row, 0 at the bottom, 1 at the top.
function M.fraction(bpm)
  local lo, hi = M.range()
  return paw.util.clamp((bpm - lo) / (hi - lo), 0, 1)
end

--- The tempo at a height in the row (a fraction, 0 at the bottom), to a
--- whole beat a minute and never below 20.
function M.bpm(fraction)
  local lo, hi = M.range()
  return math.max(20, math.floor(lo + paw.util.clamp(fraction, 0, 1) * (hi - lo) + 0.5))
end

local function clamp_bpm(bpm) return math.max(1, math.min(999, bpm)) end

--- A tempo change at a beat, holding; one already there takes the tempo.
function M.add(beat, bpm)
  api.tempo_set(math.max(0, beat), clamp_bpm(bpm))
end

--- The change at `beat` to another beat and tempo. The start's change
--- keeps its beat and changes its tempo.
function M.move(beat, to, bpm)
  local map = api.tempo_points()
  local index
  for i, p in ipairs(map.tempos) do
    if math.abs(p.beat - beat) < 1e-6 then index = i end
  end
  if not index then return false end
  local point = map.tempos[index]
  point.bpm = clamp_bpm(bpm or point.bpm)
  if index > 1 then
    table.remove(map.tempos, index)
    -- Not onto another change, and never to the start.
    local target = math.max(paw.opt.grid, to or point.beat)
    for i = #map.tempos, 1, -1 do
      if math.abs(map.tempos[i].beat - target) < 1e-6 then table.remove(map.tempos, i) end
    end
    point.beat = target
    map.tempos[#map.tempos + 1] = point
    table.sort(map.tempos, function(a, b) return a.beat < b.beat end)
  end
  api.tempo_set_points(map.tempos, map.signatures)
  return true
end

--- Take away the change at `beat`; the start's cannot be.
function M.remove(beat)
  for i, p in ipairs(paw.tempo.points()) do
    if i > 1 and math.abs(p.beat - beat) < 1e-6 then
      api.tempo_remove(p.beat)
      return true
    end
  end
  return false
end

--- Make the change at `beat` ramp to the next, or hold again.
function M.ramp(beat, on)
  for _, p in ipairs(paw.tempo.points()) do
    if math.abs(p.beat - beat) < 1e-6 then
      if on == nil then on = not p.ramp end
      api.tempo_set(p.beat, p.bpm, on)
      return on
    end
  end
end

--- A stroke of the pencil: `points` are `{ beat, bpm }` as they were drawn.
--- They replace the changes over the stretch drawn across (the start's
--- stays, with its tempo taken from the stroke if it reaches it), each a
--- slope to the next, at most one to `step` beats.
function M.draw(points, step)
  if #points == 0 then return end
  table.sort(points, function(a, b) return a[1] < b[1] end)
  step = step or math.max(0.5, paw.opt.grid)
  local from, to = math.max(0, points[1][1]), math.max(0, points[#points][1])
  local map = api.tempo_points()
  local out = {}
  for i, p in ipairs(map.tempos) do
    if i == 1 or p.beat < from - 1e-9 or p.beat > to + 1e-9 then out[#out + 1] = p end
  end
  local last
  for i, p in ipairs(points) do
    local beat = math.max(0, p[1])
    if not last or beat - last >= step - 1e-9 or i == #points then
      local bpm = clamp_bpm(p[2])
      local at
      for j, q in ipairs(out) do
        if math.abs(q.beat - beat) < 1e-6 then at = j end
      end
      if at == 1 then
        out[1].bpm = bpm
      elseif at then
        out[at].bpm = bpm
      else
        out[#out + 1] = { beat = beat, bpm = bpm, ramp = i < #points }
      end
      last = beat
    end
  end
  -- The stroke's last change holds: what comes after it was not drawn.
  for _, p in ipairs(out) do
    if math.abs(p.beat - last) < 1e-6 and p.beat > 0 then p.ramp = false end
  end
  table.sort(out, function(a, b) return a.beat < b.beat end)
  api.tempo_set_points(out, map.signatures)
end

--- Define the tempo lane's commands with `command`.
function M.commands(command)
  command("tempo.lane", function(ctx)
    local word = ctx.args[1]
    if word == "on" or word == "off" then
      M.show(word == "on")
    elseif word == nil then
      M.toggle()
    else
      return paw.notify("tempo.lane: `on`, `off`, or nothing to toggle", "warn")
    end
    paw.notify(shown and "tempo lane shown under the ruler" or "tempo lane hidden")
  end, {
    desc = "Show or hide the tempo curve under the ruler: `tempo.lane`, `tempo.lane on`, `tempo.lane off`",
    label = "Tempo lane",
    complete = function() return { "on", "off" } end,
  })

  command("tempo.move", function(ctx)
    local a = ctx.args
    local to = a[1]
    if not to then error("tempo.move: say where to, a bar (17) or a bar and beat (17.3)", 0) end
    local from = paw.tempo.point_at(a[2] and paw.tempo.place(a[2]) or paw.cursor.beat)
    if from.beat == 0 then error("the start's tempo does not move", 0) end
    local target = paw.tempo.place(to)
    M.move(from.beat, target, from.bpm)
    paw.notify(string.format("%g bpm moved to %s", from.bpm, paw.time.format(target)))
  end, {
    desc = "Move the tempo change at or before the cursor (or at a bar) to another bar: `tempo.move 17`, `tempo.move 17 9`",
    label = "Move a tempo change",
  })
end

return M
