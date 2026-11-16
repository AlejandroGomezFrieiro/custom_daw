-- Marks the score keeps besides the notes: articulations on chords
-- (staccato, staccatissimo, tenuto, accent, marcato), and along the score
-- dynamics, hairpins, slurs, text and repeat signs. They are written in the
-- score (`notation.doc`: `event.art`, `score.marks`, `measure.repeat_start`
-- and `barline`) and played by its rendering (`notation.render`): staccato
-- shortens, tenuto and a slur hold, accents add loudness, dynamics set it
-- and hairpins ramp it. Text and repeat signs are written only.
--
-- A plain MIDI clip shown as notation shows what was kept with it before
-- scores were written (`meta.notation.marks`, `slurs`, `art` on notes);
-- writing one of these makes it a score clip, keeping them.
local util = daw.util
local view = require("notation")
local D = require("notation.doc")
local render = require("notation.render")

local M = {}
local EPS = 1e-6

M.DYNAMICS = render.DYNAMICS
M.ORDER = render.ORDER
M.ARTICULATIONS = render.ARTICULATIONS

--- The articulations a clip's note carried before it was written in a score.
function M.art_of(note)
  local own = note and note.meta and type(note.meta.notation) == "table" and note.meta.notation.art
  return type(own) == "table" and own or {}
end

--- Toggle an articulation on chords of the score, by their event ids (the
--- chord under the cursor's, a selection's): on for all unless all have it.
--- Returns whether it is on.
function M.toggle_art(kind, ids)
  if #ids == 0 then return nil end
  local on
  view:write(function(sc)
    local evs = {}
    for _, id in ipairs(ids) do
      local mi, _, _, _, ev = D.find(sc, id)
      if ev and ev.kind == "chord" then evs[#evs + 1] = { ev = ev, mi = mi } end
    end
    if #evs == 0 then return false end
    on = false
    for _, x in ipairs(evs) do
      if not (x.ev.art and x.ev.art[kind]) then on = true end
    end
    for _, x in ipairs(evs) do
      local art = util.merge(x.ev.art or {}, {})
      art[kind] = on or nil
      x.ev.art = next(art) and art or nil
      D.touch(sc, x.mi)
      M.played_as_marked(sc, x.ev)
    end
  end)
  return on
end

--- A note marked to be played short or long is played as marked: the
--- length of its feel (how much longer or shorter it was played than
--- written) goes. Its timing and loudness stay.
function M.played_as_marked(sc, ev)
  for _, n in ipairs(ev.notes or {}) do
    local fe = sc.feel and sc.feel[n.id]
    if fe then
      fe.dlen = nil
      sc.feel[n.id] = next(fe) and fe or nil
    end
  end
end

-- Marks along the score -----------------------------------------------------------------------

--- A place in the score for a beat of the clip: `{ measure, at }`.
function M.ref(sc, beat)
  local mi, at = view.where(sc, beat)
  D.ensure(sc, mi)
  return { measure = sc.measures[mi].id, at = D.ratio(at) }, mi
end

local KINDS = { dyn = "dynamic", cresc = "hairpin", dim = "hairpin", text = "text", slur = "slur" }

--- Put a mark at a beat of the open clip, replacing one of its kind there,
--- or take it away with `value` false: `{ at, kind = "dyn" | "cresc" |
--- "dim" | "text" | "repeat", value, to }`. (`clip` is the open clip.)
function M.put(_, mark)
  view:write(function(sc)
    if mark.kind == "repeat" then
      local mi, at = view.where(sc, mark.at)
      D.ensure(sc, mi)
      if mark.value == "start" or (mark.value == false and at == 0) then sc.measures[mi].repeat_start = mark.value and true or nil end
      local before = at == 0 and sc.measures[mi - 1] or nil
      if before and (mark.value == "end" or mark.value == false) then before.barline = mark.value and ":|" or nil end
      D.touch(sc, mi)
      if before then D.touch(sc, mi - 1) end
      return
    end
    local kind = KINDS[mark.kind]
    local ref, mi = M.ref(sc, mark.at)
    local list = {}
    local f = D.frame(sc)
    local t = render.at_of(sc, f, ref)
    for _, mk in ipairs(sc.marks or {}) do
      local same = mk.kind == kind and render.at_of(sc, f, mk.from) == t
      if not same then list[#list + 1] = mk end
    end
    if mark.value ~= false then
      local new = { id = D.id(sc, "k"), kind = kind, from = ref }
      if kind == "dynamic" or kind == "text" then new.value = mark.value end
      if kind == "hairpin" then new.value, new.to = mark.kind, M.ref(sc, mark.to) end
      list[#list + 1] = new
    end
    sc.marks = list
    D.touch(sc, mi)
  end)
  daw.ui.poke()
end

--- A slur over the notes written from `from` to `to` (clip beats) on a
--- staff (by its index), or none there if one starts there: the notes
--- under it are played legato. Returns whether there is one now.
function M.slur(_, from, to, staff)
  local on = false
  view:write(function(sc)
    local st = (sc.staves[staff or 1] or sc.staves[1]).id
    local ref, mi = M.ref(sc, from)
    local f = D.frame(sc)
    local t = render.at_of(sc, f, ref)
    local list, removed = {}, false
    for _, mk in ipairs(sc.marks or {}) do
      if mk.kind == "slur" and mk.staff == st and render.at_of(sc, f, mk.from) == t then removed = true else list[#list + 1] = mk end
    end
    if not removed then
      list[#list + 1] = { id = D.id(sc, "k"), kind = "slur", staff = st, from = ref, to = M.ref(sc, to) }
      on = true
      -- The notes under it are played legato, as marked.
      local s0, s1 = render.at_of(sc, f, ref), render.at_of(sc, f, M.ref(sc, to))
      D.each(sc, function(ev, _, staff, _, s)
        if staff == st and ev.kind == "chord" and s >= s0 and s < s1 then M.played_as_marked(sc, ev) end
      end)
    end
    sc.marks = list
    D.touch(sc, mi)
  end)
  return on
end

-- On the layout --------------------------------------------------------------------------------

local XML_WEDGE = { cresc = "crescendo", dim = "diminuendo" }

--- The marks of a clip as the layout draws them: `{ at, kind = "dyn" |
--- "cresc" | "dim" | "text" | "repeat", value, to }` in clip beats, and
--- slurs `{ from, to, staff }`; from its score, or what a MIDI clip kept.
local function marks_of(layout, c)
  local sc = layout.doc
  if not sc then
    local own = view.own(c)
    return own.marks or {}, own.slurs or {}
  end
  local f = D.frame(sc)
  local origin = D.origin(sc)
  local function beat(ref)
    local t = render.at_of(sc, f, ref)
    return t and (origin + t) / D.Q
  end
  local marks, slurs = {}, {}
  for _, mk in ipairs(sc.marks or {}) do
    local at = beat(mk.from)
    if at then
      if mk.kind == "dynamic" then
        marks[#marks + 1] = { at = at, kind = "dyn", value = mk.value }
      elseif mk.kind == "hairpin" then
        marks[#marks + 1] = { at = at, kind = mk.value == "dim" and "dim" or "cresc", to = beat(mk.to) or at }
      elseif mk.kind == "text" then
        marks[#marks + 1] = { at = at, kind = "text", value = mk.value }
      elseif mk.kind == "slur" then
        slurs[#slurs + 1] = { from = at, to = beat(mk.to) or at, staff = D.staff_index(sc, mk.staff) or 1 }
      end
    end
  end
  table.sort(marks, function(a, b) return a.at < b.at end)
  return marks, slurs
end

--- Put the marks on a layout's measures and events, for drawing and export:
--- `ev.art`, `ev.lyric`, `ev.slurs` ("start", "stop"), `m.marks`,
--- `m.directions` (MusicXML), `m.repeat_start`, `m.repeat_end`.
function M.decorate(layout, clip)
  local c = clip:get()
  local marks, slurs = marks_of(layout, c)
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
    if not layout.doc then
      -- Articulations and lyrics a MIDI clip's notes carry.
      for _, evs in ipairs(m.staves) do
        for _, ev in ipairs(evs) do
          if ev.kind == "note" and not ev.notes[1].tied then
            local art = {}
            for _, n in ipairs(ev.notes) do
              for k, v in pairs(M.art_of(n)) do art[k] = v end
              if not ev.lyric and n.meta and n.meta.lyric and n.meta.lyric ~= "" then ev.lyric = n.meta.lyric end
            end
            ev.art = next(art) and art or nil
          end
        end
      end
    end
  end
  -- Slurs: from the first note at or after their start to the last before
  -- their end. A score's measures are laid out once and kept, so what was
  -- put on their events before is taken off first.
  if layout.doc then
    for _, m in ipairs(layout.measures) do
      for _, evs in ipairs(m.staves) do
        for _, ev in ipairs(evs) do ev.slurs, ev.slur_to = nil, nil end
      end
    end
  end
  for _, sl in ipairs(slurs) do
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
