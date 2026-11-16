-- From the written score to the notes the clip plays: one way, a pure
-- function of the score (`M.render`), and the clip's notes made so
-- (`M.apply`). Ties are one note; grace notes take a little time before
-- the beat (an acciaccatura) or on it (an appoggiatura); articulations
-- give the sounding length (90% of the written value unless marked:
-- staccato half, staccatissimo a quarter, tenuto and notes under a slur all
-- of it); the dynamic in force gives the velocity, hairpins ramp it to the
-- next dynamic, accents and marcatos add to it. Then the feel: what the
-- player did differently from the page, kept per note in `score.feel`
-- (`{ dt, dlen, dvel }` in beats and velocity, relative to what is written)
-- so that it goes with the note when the writing changes.
--
-- Every rendered note carries `meta.score = { e = event id, n = note id }`.
-- The rendering of each measure is kept by what it depends on (the
-- measure, the one before, those its ties reach), so an edit renders again
-- only the measures it changed.
local D = require("notation.doc")

local M = {}
local Q = D.Q

M.DYNAMICS = { ppp = 25, pp = 38, p = 52, mp = 66, mf = 80, f = 96, ff = 112, fff = 124 }
M.ORDER = { "ppp", "pp", "p", "mp", "mf", "f", "ff", "fff" }
M.ARTICULATIONS = { staccato = true, staccatissimo = true, accent = true, tenuto = true, marcato = true }
local GATE = { staccatissimo = 0.25, staccato = 0.5, tenuto = 1 }
local ACCENT = { accent = 20, marcato = 30 }
local GRACE = Q / 8   -- an acciaccatura sounds a 32nd before its note

M.stats = { measures = 0 }
local cache, cache_size = {}, 0

local function clamp_vel(v) return math.max(1, math.min(127, math.floor(v + 0.5))) end
local feel_on

--- Whether the chord before item `k` of a voice ties a note of `pitch` into it.
local function tied_into(seq, k, pitch)
  local j = k - 1
  while seq[j] and seq[j].ev.grace do j = j - 1 end
  local prev = seq[j]
  if not (prev and prev.ev.kind == "chord" and prev.e == seq[k].s) then return false end
  for _, n in ipairs(prev.ev.notes) do
    if n.tie and D.pitch(n) == pitch then return true end
  end
  return false
end

--- The notes written in items `first` to `last` of one voice's sequence
--- `seq` (`notation.doc.sequence`), as `{ pitch, s, len, e, n, art, staff,
--- voice }` with ticks from measure 1; tied notes are one.
local function measure_notes(seq, first, last, staff, v)
  local out = {}
  local graces = {}
  for k = first, last do
    local it = seq[k]
    local ev = it.ev
    if ev.grace and ev.kind == "chord" then
      graces[#graces + 1] = it
    elseif ev.kind == "chord" then
      local s, delay = it.s, 0
      -- Appoggiaturas on the beat, taking time from the note; acciaccaturas before it.
      local before = 0
      for _, g in ipairs(graces) do
        if g.ev.grace ~= "appoggiatura" then before = before + 1 end
      end
      local j = 0
      for _, g in ipairs(graces) do
        local gs, glen
        if g.ev.grace == "appoggiatura" then
          glen = math.min(D.ticks(g.ev.dur), math.floor((it.e - it.s) / 2))
          gs = s + delay
          delay = delay + glen
        else
          gs, glen = s - (before - j) * GRACE, GRACE
          j = j + 1
        end
        for _, n in ipairs(g.ev.notes) do
          out[#out + 1] = { pitch = D.pitch(n), s = gs, len = glen, e = g.ev.id, n = n.id, staff = staff, voice = v, grace = true }
        end
      end
      graces = {}
      for _, n in ipairs(ev.notes) do
        local pitch = D.pitch(n)
        if not tied_into(seq, k, pitch) then
          -- Follow the tie on, through the voice.
          local e, cur, at = it.e, n, k
          while cur.tie do
            local nxt = seq[at + 1]
            if not (nxt and nxt.ev.kind == "chord" and not nxt.ev.grace and nxt.s == e) then break end
            local found
            for _, o in ipairs(nxt.ev.notes) do
              if D.pitch(o) == pitch then found = o end
            end
            if not found then break end
            e, cur, at = nxt.e, found, at + 1
          end
          out[#out + 1] = { pitch = pitch, s = s + delay, len = e - s - delay, e = ev.id, n = n.id, art = ev.art, staff = staff, voice = v }
        end
      end
    else
      graces = {}
    end
  end
  return out
end

--- Where a mark's place is, in ticks from measure 1, or nil.
local function at_of(score, f, ref)
  if not ref then return nil end
  local mi = f.index[ref.measure]
  if not mi then return nil end
  if ref.event then
    local t = f.starts[mi]
    local m = score.measures[mi]
    for _, entry in ipairs(m.voices) do
      local x = t
      for _, ev in ipairs(entry.events) do
        if ev.id == ref.event then return x end
        x = x + D.length(ev)
      end
    end
    return nil
  end
  return f.starts[mi] + D.ticks(ref.at or { 0, 1 })
end
M.at_of = at_of

--- The loudness the dynamics and hairpins ask for at a place, by `marks`
--- resolved to ticks: `{ dyns = { { t, level } }, pins = { { s, e, kind } } }`.
local function level(resolved, t)
  local v
  for _, d in ipairs(resolved.dyns) do
    if d.t <= t then v = d.level end
  end
  for _, h in ipairs(resolved.pins) do
    if t >= h.s and t < h.e then
      local from = v or M.DYNAMICS.mf
      local to
      for _, d in ipairs(resolved.dyns) do
        if not to and d.t >= h.e then to = d.level end
      end
      to = to or (from + (h.kind == "cresc" and 24 or -24))
      local start_level
      for _, d in ipairs(resolved.dyns) do
        if d.t <= h.s then start_level = d.level end
      end
      from = start_level or M.DYNAMICS.mf
      return from + (to - from) * (t - h.s) / math.max(1, h.e - h.s)
    end
  end
  return v or M.DYNAMICS.mf
end

--- The marks of a score in ticks: dynamics, hairpins and slurs.
function M.resolve(score)
  local f = D.frame(score)
  local out = { dyns = {}, pins = {}, slurs = {} }
  for _, mk in ipairs(score.marks or {}) do
    local s = at_of(score, f, mk.from)
    if s then
      if mk.kind == "dynamic" and M.DYNAMICS[mk.value] then
        out.dyns[#out.dyns + 1] = { t = s, level = M.DYNAMICS[mk.value] }
      elseif mk.kind == "hairpin" then
        local e = at_of(score, f, mk.to)
        if e and e > s then out.pins[#out.pins + 1] = { s = s, e = e, kind = mk.value == "dim" and "dim" or "cresc" } end
      elseif mk.kind == "slur" then
        local e = at_of(score, f, mk.to)
        if e and e > s then out.slurs[#out.slurs + 1] = { s = s, e = e, staff = mk.staff } end
      end
    end
  end
  table.sort(out.dyns, function(a, b) return a.t < b.t end)
  return out
end

--- A rendered note with a feel on it. A feel the writing has since made
--- nonsense of is held in: a note starts at most half its written length
--- away from its place, and does not reach more than a 32nd past its
--- written end.
feel_on = function(r, fe, written)
  local dt = math.max(-written / 2, math.min(written / 2, fe.dt or 0))
  -- An articulation's length is the note's, whatever the feel.
  local dlen = r.articulated and 0 or (fe.dlen or 0)
  local length = math.max(1 / 64, math.min(r.length + dlen, written + 0.125 - dt))
  return { pitch = r.pitch, start = r.start + dt, length = length, velocity = clamp_vel(r.velocity + (fe.dvel or 0)),
    meta = r.meta, written = r.written, articulated = r.articulated }
end

--- What the score plays: notes `{ pitch, start, length, velocity, meta }`
--- in beats from the clip's start, in time order. `opts`: `feel` false
--- leaves out the player's feel, `gate` gives every note that share of its
--- written length, `written` puts on each note what it was made from
--- (`{ s, len, e, n, staff, voice, art, grace }`).
function M.render(score, opts)
  opts = opts or {}
  local f = D.frame(score)
  local origin = D.origin(score)
  local protos = {}
  for _, st in ipairs(score.staves) do
    for v = 1, 4 do
      local seq = D.sequence(score, st.id, v)
      if #seq > 0 then
        -- The events of each measure.
        local ranges = {}
        for k, it in ipairs(seq) do
          local r = ranges[it.mi]
          if r then r.last = k else ranges[it.mi] = { first = k, last = k } end
        end
        for mi, r in pairs(ranges) do
          local m = score.measures[mi]
          local prev = score.measures[mi - 1]
          -- How far this measure's ties reach.
          local reach, e = {}, r.last
          while seq[e] and seq[e].ev.notes and seq[e + 1] do
            local tied = false
            for _, n in ipairs(seq[e].ev.notes) do tied = tied or n.tie or false end
            if not tied then break end
            e = e + 1
            reach[#reach + 1] = score.measures[seq[e].mi].v
          end
          local key = table.concat({ st.id, v, m.id, tostring(m.v), tostring(prev and prev.v), f.starts[mi], table.concat(reach, ",") }, ":")
          local list = cache[key]
          if not list then
            list = measure_notes(seq, r.first, r.last, st.id, v)
            M.stats.measures = M.stats.measures + 1
            cache_size = cache_size + 1
            if cache_size > 20000 then cache, cache_size = {}, 0 end
            cache[key] = list
          end
          for _, p in ipairs(list) do protos[#protos + 1] = p end
        end
      end
    end
  end
  local marks = M.resolve(score)
  local gate = opts.gate or (score.style and score.style.gate) or 0.9
  local feel = opts.feel ~= false and score.feel or {}
  local out = {}
  for _, p in ipairs(protos) do
    local g = gate
    local art = p.art or {}
    for kind, x in pairs(GATE) do
      if art[kind] then g = math.min(g == gate and 1 or g, x) end
    end
    if not (art.staccato or art.staccatissimo) then
      for _, sl in ipairs(marks.slurs) do
        if p.s >= sl.s and p.s < sl.e and (not sl.staff or sl.staff == p.staff) then g = 1 end
      end
    end
    if art.tenuto then g = math.max(g, 1) end
    if opts.gate then g = opts.gate end
    local len = p.grace and p.len or p.len * g
    local vel = level(marks, p.s)
    for kind, add in pairs(ACCENT) do
      if art[kind] then vel = vel + add end
    end
    local fe = feel[p.n]
    local note = {
      pitch = p.pitch, start = (origin + p.s) / Q, length = len / Q, velocity = clamp_vel(vel),
      meta = { score = { e = p.e, n = p.n } }, written = opts.written and p or nil, articulated = g ~= gate or nil,
    }
    out[#out + 1] = fe and feel_on(note, fe, p.len / Q) or note
  end
  if not opts.unsorted then
    table.sort(out, function(a, b)
      if a.start ~= b.start then return a.start < b.start end
      return a.pitch < b.pitch
    end)
  end
  return out
end

--- What the score plays with the feel put on, from what it plays without:
--- the notes of `render(score, { feel = false, written = true })` moved
--- by each one's feel.
function M.with_feel(plain, feel)
  local out = {}
  for i, r in ipairs(plain) do
    local fe = feel and feel[r.meta.score.n]
    out[i] = fe and feel_on(r, fe, r.written and r.written.len / Q or r.length) or r
  end
  return out
end

--- The written note a clip's note plays, by its `meta.score`.
function M.note_id(n) return n.meta and type(n.meta.score) == "table" and n.meta.score.n or nil end

--- Make a clip's notes what the score plays (or `want`, its rendering
--- already made), changing only what differs: through `daw.api` itself,
--- below the clip owners' hook, as the owner.
function M.apply(id, score, want)
  local api = daw.api
  want = want or M.render(score, { unsorted = true })
  local have = api.clip_notes(id)
  local by, remove = {}, {}
  for i, n in ipairs(have) do
    local k = M.note_id(n)
    if k and not by[k] then by[k] = i else remove[#remove + 1] = i end
  end
  local set, add, after = {}, {}, {}
  for _, w in ipairs(want) do
    local k = w.meta.score.n
    local i = by[k]
    if i then
      by[k] = nil
      local n = have[i]
      local change = { index = i }
      local any = false
      for _, field in ipairs({ "start", "length" }) do
        if math.abs(n[field] - w[field]) > 1e-9 then change[field], any = w[field], true end
      end
      after[#after + 1] = { id = k, start = change.start or n.start, pitch = w.pitch, at = i }
      if n.pitch ~= w.pitch then change.pitch, any = w.pitch, true end
      if n.velocity ~= w.velocity then change.velocity, any = w.velocity, true end
      if n.meta.score.e ~= w.meta.score.e then
        local meta = daw.util.merge(n.meta, {})
        meta.score = w.meta.score
        change.meta, any = meta, true
      end
      if any then set[#set + 1] = change end
    else
      add[#add + 1] = { pitch = w.pitch, start = w.start, length = w.length, velocity = w.velocity, meta = w.meta }
      after[#after + 1] = { id = k, start = w.start, pitch = w.pitch, at = #have + #add }
    end
  end
  for _, i in pairs(by) do remove[#remove + 1] = i end
  if #set > 0 or #remove > 0 or #add > 0 then api.clip_notes_edit(id, { set = set, remove = remove, add = add }) end
  -- Where each note is now among the clip's, as the kernel orders them (by
  -- start and pitch, keeping their order otherwise), without asking.
  table.sort(after, function(a, b)
    if a.start ~= b.start then return a.start < b.start end
    if a.pitch ~= b.pitch then return a.pitch < b.pitch end
    return a.at < b.at
  end)
  local places = {}
  for i, x in ipairs(after) do places[x.id] = i end
  M.last = { key = id .. ":" .. tostring(score.rev), places = places, count = #after }
  return places
end

return M
