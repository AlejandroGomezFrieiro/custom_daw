-- Marks the score keeps besides the notes, and what they do to the
-- performance: articulations on notes (staccato shortens, tenuto holds,
-- accent and marcato make louder), dynamics and hairpins along the clip
-- (they set and ramp the loudness), slurs (legato), text and repeat signs
-- (written only).
--
-- Articulations are kept on each note, in `meta.notation.art`; the others
-- with the clip, in `meta.notation.marks` (`{ at, kind, value, to }`, in
-- written beats) and `meta.notation.slurs` (`{ from, to, staff }`). Setting
-- a mark changes the played notes at once, as one undoable edit, so the
-- piano roll shows and the engine plays what the score says.
local api = daw.api
local util = daw.util
local view = require("notation")

local M = {}
local EPS = 1e-6

M.DYNAMICS = { ppp = 25, pp = 38, p = 52, mp = 66, mf = 80, f = 96, ff = 112, fff = 124 }
M.ORDER = { "ppp", "pp", "p", "mp", "mf", "f", "ff", "fff" }
M.ARTICULATIONS = { staccato = true, accent = true, tenuto = true, marcato = true }
local ACCENT = { accent = 20, marcato = 30 }

local function clamp_vel(v) return math.max(1, math.min(127, math.floor(v + 0.5))) end

--- The articulations a note carries.
function M.art_of(note)
  local own = note and note.meta and type(note.meta.notation) == "table" and note.meta.notation.art
  return type(own) == "table" and own or {}
end

--- Toggle an articulation on the chords under the cursor or in `indices`
--- (places of notes), applying it: staccato makes the played note half its
--- written length at most, tenuto its full written length, accent and
--- marcato louder by 20 and 30. Taking it away undoes what it did.
function M.toggle_art(kind, indices)
  local clip = view:clip()
  local layout = view:layout()
  if not (clip and layout) then return end
  local written = {}
  for _, ev in ipairs(layout.score.events) do
    for _, n in ipairs(ev.notes) do written[n.index] = ev end
  end
  local notes = clip:notes()
  local on = false
  for _, i in ipairs(indices) do
    if not M.art_of(notes[i])[kind] then on = true end
  end
  local set = {}
  for _, i in ipairs(indices) do
    local note = notes[i]
    local ev = written[i]
    if note and ev then
      local meta = util.merge(note.meta or {}, {})
      local own = type(meta.notation) == "table" and util.merge(meta.notation, {}) or {}
      local art = util.merge(own.art or {}, {})
      local had = art[kind]
      art[kind] = on or nil
      own.art = next(art) and art or nil
      meta.notation = next(own) and own or nil
      local change = { index = i, meta = meta }
      if on ~= (had or false) then
        if kind == "staccato" then
          change.length = on and math.min(note.length, ev.length * 0.5) or math.max(note.length, ev.length * 0.9)
        elseif kind == "tenuto" then
          change.length = on and ev.length or math.min(note.length, ev.length * 0.9)
        elseif ACCENT[kind] then
          change.velocity = clamp_vel(note.velocity + (on and ACCENT[kind] or -ACCENT[kind]))
        end
      end
      set[#set + 1] = change
    end
  end
  if #set > 0 then clip:edit_notes({ set = set }) end
  daw.ui.poke()
  return on
end

-- Marks along the clip -----------------------------------------------------------------------

function M.marks(clip)
  return util.merge(view.own(clip:get()).marks or {}, {})
end

local function sorted(list)
  table.sort(list, function(a, b) return a.at < b.at end)
  return list
end

--- The loudness the dynamics and hairpins ask for at a written beat, or nil
--- before the first dynamic.
function M.target(marks, t)
  local dyns, pins = {}, {}
  for _, mk in ipairs(marks) do
    if mk.kind == "dyn" and M.DYNAMICS[mk.value] then dyns[#dyns + 1] = mk end
    if mk.kind == "cresc" or mk.kind == "dim" then pins[#pins + 1] = mk end
  end
  sorted(dyns)
  local function level_at(x)
    local v
    for _, d in ipairs(dyns) do
      if d.at <= x + EPS then v = M.DYNAMICS[d.value] end
    end
    return v
  end
  for _, h in ipairs(pins) do
    if t >= h.at - EPS and t < h.to - EPS then
      local from = level_at(h.at) or M.DYNAMICS.mf
      local to
      for _, d in ipairs(dyns) do
        if not to and d.at >= h.to - EPS then to = M.DYNAMICS[d.value] end
      end
      to = to or (from + (h.kind == "cresc" and 24 or -24))
      return from + (to - from) * (t - h.at) / math.max(EPS, h.to - h.at)
    end
  end
  return level_at(t)
end

--- Make the played loudness follow the dynamics: each stretch between
--- marks is moved to its level, keeping how the notes differ from each
--- other (the player's accents stay), accents on top.
function M.apply(clip)
  local layout = view:layout()
  local marks = M.marks(clip)
  if not layout then return end
  local notes = clip:notes()
  local written = {}
  for _, ev in ipairs(layout.score.events) do
    for _, n in ipairs(ev.notes) do written[n.index] = ev.start end
    for _, n in ipairs(ev.grace or {}) do written[n.index] = ev.start end
  end
  -- Stretches: from one dynamic or hairpin edge to the next.
  local edges = {}
  for _, mk in ipairs(marks) do
    if mk.kind == "dyn" or mk.kind == "cresc" or mk.kind == "dim" then
      edges[#edges + 1] = mk.at
      if mk.to then edges[#edges + 1] = mk.to end
    end
  end
  table.sort(edges)
  if #edges == 0 then return end
  local function stretch(t)
    local k = 0
    for i, e in ipairs(edges) do
      if e <= t + EPS then k = i end
    end
    return k
  end
  -- How each note differs from the line through its stretch: the player's
  -- own accents, kept; the old level and ramp, replaced.
  local fit = {}
  local function accent_of(n)
    local a = 0
    local art = M.art_of(n)
    for kind, v in pairs(ACCENT) do
      if art[kind] then a = a + v end
    end
    return a
  end
  for i, n in ipairs(notes) do
    local t = written[i] or n.start
    local k = stretch(t)
    local f = fit[k] or { n = 0, sx = 0, sy = 0, sxx = 0, sxy = 0 }
    local y = n.velocity - accent_of(n)
    f.n, f.sx, f.sy, f.sxx, f.sxy = f.n + 1, f.sx + t, f.sy + y, f.sxx + t * t, f.sxy + t * y
    fit[k] = f
  end
  local function line_at(k, t)
    local f = fit[k]
    local mx, my = f.sx / f.n, f.sy / f.n
    local var = f.sxx / f.n - mx * mx
    local slope = var > 1e-6 and (f.sxy / f.n - mx * my) / var or 0
    return my + slope * (t - mx)
  end
  local set = {}
  for i, n in ipairs(notes) do
    local t = written[i] or n.start
    local target = M.target(marks, t)
    if target then
      local k = stretch(t)
      local accent = accent_of(n)
      local v = clamp_vel(target + (n.velocity - accent - line_at(k, t)) + accent)
      if v ~= n.velocity then set[#set + 1] = { index = i, velocity = v } end
    end
  end
  if #set > 0 then clip:edit_notes({ set = set }) end
end

--- Put a mark at a written beat (replacing one of its kind there), or take
--- it away with `value` false; then apply the dynamics.
function M.put(clip, mark)
  view.keep(clip, function(own)
    local list = {}
    for _, mk in ipairs(own.marks or {}) do
      local same = math.abs(mk.at - mark.at) < EPS and (mk.kind == mark.kind
        or (mk.kind == "dyn" and mark.kind == "dyn") or ((mk.kind == "cresc" or mk.kind == "dim") and (mark.kind == "cresc" or mark.kind == "dim")))
      if not same then list[#list + 1] = mk end
    end
    if mark.value ~= false then list[#list + 1] = mark end
    own.marks = #list > 0 and sorted(list) or nil
  end)
  M.apply(clip)
  daw.ui.poke()
end

--- A slur over the notes written from `from` to `to` on a staff (the
--- played notes are joined: each held to the next), or no slur there.
function M.slur(clip, from, to, staff)
  local removed = false
  view.keep(clip, function(own)
    local list = {}
    for _, sl in ipairs(own.slurs or {}) do
      if math.abs(sl.from - from) < EPS and sl.staff == staff then removed = true else list[#list + 1] = sl end
    end
    if not removed then list[#list + 1] = { from = from, to = to, staff = staff } end
    own.slurs = #list > 0 and list or nil
  end)
  if removed then return false end
  -- Legato: each played note under the slur reaches the next chord.
  local layout = view:layout()
  local notes = clip:notes()
  local chords = {}
  for _, ev in ipairs(layout.score.events) do
    if ev.staff == staff and ev.start >= from - EPS and ev.start <= to + EPS then chords[#chords + 1] = ev end
  end
  local set = {}
  for i = 1, #chords - 1 do
    local nxt = chords[i + 1]
    local first_next = math.huge
    for _, n in ipairs(nxt.notes) do first_next = math.min(first_next, notes[n.index].start) end
    for _, n in ipairs(chords[i].notes) do
      local p = notes[n.index]
      if p.start + p.length < first_next then set[#set + 1] = { index = n.index, length = first_next - p.start + 0.02 } end
    end
  end
  if #set > 0 then clip:edit_notes({ set = set }) end
  return true
end

-- On the layout --------------------------------------------------------------------------------

local XML_WEDGE = { cresc = "crescendo", dim = "diminuendo" }

--- Put the marks on a layout's measures and events, for drawing and export:
--- `ev.art`, `ev.lyric`, `ev.slurs` ("start", "stop"), `m.marks`,
--- `m.directions` (MusicXML), `m.repeat_start`, `m.repeat_end`.
function M.decorate(layout, clip)
  local c = clip:get()
  local own = view.own(c)
  local marks = own.marks or {}
  for _, m in ipairs(layout.measures) do
    m.marks, m.directions = {}, {}
    local e = m.start + m.length
    for _, mk in ipairs(marks) do
      if mk.at >= m.start - EPS and mk.at < e - EPS then
        m.marks[#m.marks + 1] = mk
        if mk.kind == "dyn" then
          m.directions[#m.directions + 1] = { start = mk.at, xml = "<dynamics><" .. mk.value .. "/></dynamics>" }
        elseif XML_WEDGE[mk.kind] then
          m.directions[#m.directions + 1] = { start = mk.at, xml = '<wedge type="' .. XML_WEDGE[mk.kind] .. '"/>' }
        elseif mk.kind == "text" then
          m.directions[#m.directions + 1] = { start = mk.at, xml = "<words>" .. tostring(mk.value):gsub("&", "&amp;"):gsub("<", "&lt;") .. "</words>" }
        end
        if mk.kind == "repeat" and mk.value == "start" then m.repeat_start = true end
      end
      if XML_WEDGE[mk.kind] and mk.to and mk.to > m.start + EPS and mk.to <= e + EPS then
        m.directions[#m.directions + 1] = { start = math.min(mk.to, e), xml = '<wedge type="stop"/>' }
      end
      if mk.kind == "repeat" and mk.value == "end" and math.abs(mk.at - e) < 1e-3 then m.repeat_end = true end
      if mk.kind == "repeat" and mk.value == "end" and mk.at >= m.start - EPS and mk.at < e - EPS and math.abs(mk.at - m.start) < 1e-3 then
        local before = layout.measures[m.index - 1]
        if before then before.repeat_end = true end
      end
    end
    for _, evs in ipairs(m.staves) do
      for _, ev in ipairs(evs) do
        if ev.kind == "note" and not ev.notes[1].tied then
          local art = {}
          for _, n in ipairs(ev.notes) do
            local own_n = n.meta and type(n.meta.notation) == "table" and n.meta.notation.art
            if type(own_n) == "table" then
              for k, v in pairs(own_n) do art[k] = v end
            end
            if not ev.lyric and n.meta and n.meta.lyric and n.meta.lyric ~= "" then ev.lyric = n.meta.lyric end
          end
          ev.art = next(art) and art or nil
        end
      end
    end
  end
  -- Slurs: from the first note at or after their start to the last before their end.
  for _, sl in ipairs(own.slurs or {}) do
    local first, last
    for _, m in ipairs(layout.measures) do
      for _, ev in ipairs(m.staves[sl.staff] or {}) do
        if ev.kind == "note" and not ev.notes[1].tied and ev.start >= sl.from - EPS and ev.start <= sl.to + EPS then
          first = first or ev
          last = ev
        end
      end
    end
    if first and last and first ~= last then
      first.slurs = first.slurs or {}
      table.insert(first.slurs, "start")
      last.slurs = last.slurs or {}
      table.insert(last.slurs, "stop")
      first.slur_to = last
    end
  end
end

table.insert(view.decorators, M.decorate)
view.marks = M
return M
