-- A score clip's notes belong to its score: what the piano roll (or any
-- other writer of notes) does to them is made a change of the score, by the
-- clip owners' hook (`daw.clips.owner`). Each change is one of two kinds:
--
--   written  a note's pitch (respelled by the key), a note added (it joins
--            a chord of the same start and length, else fills silence in
--            voice 1, else in voice 2 to 4), a note deleted (its chord loses
--            it, or is a rest), a note moved or made longer or shorter by
--            whole steps of the roll's grid (written there again, the
--            values as the metre has them)
--   feel     a nudge off the grid, a velocity: kept per note as its feel,
--            relative to what is written, so that it goes with the note
--            when the writing changes
--
-- Either way the notes end up where the roll put them: the feel takes up
-- what the writing does not say. One undo step, score and notes together.
--
-- A note the score makes up from a mark (a grace note's realisation) is
-- not quite written: a pitch or a delete there asks whether to write the
-- mark or change only this pass. Only the mark can take a pitch or a
-- delete, since a pass has no override of its own yet (a grace note plays
-- once; what a trill or an unfolded repeat makes is not rendered), so
-- "only this pass" is offered for a note's time, length and velocity.
local api = daw.api
local view = require("notation")
local model = require("notation.model")
local D = require("notation.doc")
local render = require("notation.render")

local M = {}
local EPS = 1e-6

--- Whether a change of time is whole steps of the roll's grid.
local function on_grid(x)
  local g = daw.opt.note_grid or 0.25
  local k = x / g
  return math.abs(x) > EPS and math.abs(k - math.floor(k + 0.5)) < 1e-6
end

--- A change as sets, removes and adds, by the places of the notes now.
local function normalize(change, notes)
  if not change.replace then return change.set or {}, change.remove or {}, change.add or {} end
  local place = {}
  for i, n in ipairs(notes) do
    local id = render.note_id(n)
    if id then place[id] = i end
  end
  local sets, removes, adds, seen = {}, {}, {}, {}
  for _, w in ipairs(change.replace) do
    local id = render.note_id(w)
    local i = id and place[id]
    if i and not seen[i] then
      seen[i] = true
      sets[#sets + 1] = { index = i, start = w.start, length = w.length, pitch = w.pitch, velocity = w.velocity }
    else
      adds[#adds + 1] = w
    end
  end
  for i in ipairs(notes) do
    if not seen[i] then removes[#removes + 1] = i end
  end
  return sets, removes, adds
end

--- Whether the score makes a note up from a mark, not just writes it: what
--- kind (`"grace"`), or nil.
function M.generated(sc, id)
  local _, ev = D.find_note(sc, id)
  if ev and ev.grace then return "grace" end
end

--- The same plan as feel only: what a pass can take (time, length, velocity).
local function pass_of(plan)
  local out = {}
  for _, p in ipairs(plan) do
    local q = {}
    for k, v in pairs(p) do q[k] = v end
    q.pitch, q.move = nil, nil
    out[#out + 1] = q
  end
  return out
end

--- What a change of a score clip's notes means, and how to make it.
function M.on_edit(c, change)
  local notes = api.clip_notes(c.id)
  local sets, removes, adds = normalize(change, notes)
  local plan, written, any = {}, false, false
  for _, s in ipairs(sets) do
    local before = notes[s.index]
    local id = before and render.note_id(before)
    if id then
      local p = { id = id, before = before, want = {
        start = s.start or before.start, length = s.length or before.length, pitch = s.pitch or before.pitch, velocity = s.velocity or before.velocity } }
      if p.want.pitch ~= before.pitch then p.pitch, written = true, true end
      p.dt = p.want.start - before.start
      p.dlen = p.want.length - before.length
      if on_grid(p.dt) or on_grid(p.dlen) then p.move, written = true, true end
      if p.pitch or math.abs(p.dt) > EPS or math.abs(p.dlen) > EPS or p.want.velocity ~= before.velocity then
        plan[#plan + 1] = p
        any = true
      end
    end
  end
  if #removes > 0 or #adds > 0 then written, any = true, true end
  -- Only what extensions keep on notes changed: written as asked.
  if not any then return nil end
  local function apply() return M.apply(c.id, plan, removes, adds, notes) end
  -- A pitch or a delete of a made-up note: the mark or only this pass?
  local sc, made = view.score_of(c), nil
  for _, p in ipairs(plan) do
    made = made or (p.pitch and M.generated(sc, p.id))
  end
  for _, i in ipairs(removes) do
    local id = notes[i] and render.note_id(notes[i])
    made = made or (id and M.generated(sc, id))
  end
  if made then
    local feel = #removes == 0 and #adds == 0
    return {
      kind = "ask", prompt = "A " .. made .. " note is made from its mark: [w]rite the mark, or only [t]his pass? ",
      cancel = "left as it was",
      choices = {
        w = { apply = apply },
        t = feel and { apply = function() return M.apply(c.id, pass_of(plan), removes, adds, notes) end,
          message = "only this pass: its time, length and velocity changed; a pitch has no override of a pass yet, write the mark for that" }
          or { message = "a delete has no override of a pass yet: [w]rite the mark" },
      },
    }
  end
  return { kind = written and "written" or "feel", apply = apply }
end

--- Make a planned change: the written part in the score, then each note's
--- feel set so that it plays where it was put. Returns the place of the
--- first note changed or added.
function M.apply(id, plan, removes, adds, notes)
  local clip = daw.clip(id)
  local sc = view.edit_score_of(clip:get())
  local fifths = view.key()
  local origin = D.origin(sc)
  sc.feel = sc.feel or {}
  local plain = {}
  if #plan > 0 then
    for _, r in ipairs(render.render(sc, { feel = false, written = true, unsorted = true })) do plain[r.meta.score.n] = r end
  end
  local wanted, first, moving = {}, nil, {}
  for _, p in ipairs(plan) do
    local note, ev, _, entry = D.find_note(sc, p.id)
    local was = plain[p.id]
    if note and was then
      first = first or p.id
      if p.pitch then
        local sp = model.spell(p.want.pitch, fifths)
        D.respell(sc, p.id, sp.letter, sp.alter, sp.octave)
        note = D.find_note(sc, p.id)
      end
      if p.move and not ev.grace then
        -- Taken out now and written again where it starts, as long as it
        -- is, once every moving note is out of the way.
        local w = was.written
        local staff = entry.staff
        if #sc.staves == 2 then staff = sc.staves[D.pitch(note) < 60 and 2 or 1].id end
        moving[#moving + 1] = {
          note = { id = p.id, step = note.step, alter = note.alter, octave = note.octave }, staff = staff,
          t = math.max(0, w.s + D.from_beats(on_grid(p.dt) and p.dt or 0)),
          len = math.max(D.from_beats(daw.opt.notation_grid / 2), w.len + D.from_beats(on_grid(p.dlen) and p.dlen or 0)),
        }
        for _, tied in ipairs(D.tied_on(sc, entry.staff, entry.voice, p.id)) do D.remove_note(sc, tied.note.id) end
        D.remove_note(sc, p.id)
      end
      wanted[p.id] = p.want
    end
  end
  for _, i in ipairs(removes) do
    local nid = render.note_id(notes[i])
    local note, entry
    if nid then
      local found, _, _, voice = D.find_note(sc, nid)
      note, entry = found, voice
    end
    if note then
      for _, tied in ipairs(D.tied_on(sc, entry.staff, entry.voice, nid)) do D.remove_note(sc, tied.note.id) end
      D.remove_note(sc, nid)
      sc.feel[nid] = nil
    end
  end
  table.sort(moving, function(a, b) return a.t < b.t end)
  for _, mv in ipairs(moving) do
    if not view.add_sounding(sc, mv.note, mv.t, mv.len, mv.staff) then
      daw.notify("no voice free there: the note is not written", "warn")
    end
  end
  local grid = D.from_beats(daw.opt.notation_grid)
  for _, n in ipairs(adds) do
    local pitch = daw.music.pitch(n.pitch)
    local t = D.from_beats(n.start) - origin
    local at = math.max(0, math.floor(t / grid + 0.5) * grid)
    local len = math.max(grid, math.floor(D.from_beats(n.length) / grid + 0.5) * grid)
    local staff = sc.staves[(#sc.staves == 2 and pitch < 60) and 2 or 1].id
    local nid = view.add_sounding(sc, D.spelled(model.spell(pitch, fifths)), at, len, staff)
    if nid then
      first = first or nid
      wanted[nid] = { start = n.start, length = n.length, pitch = pitch, velocity = n.velocity or daw.opt.velocity }
    else
      daw.notify("no voice free there: the note is not written", "warn")
    end
  end
  -- The feel: what the roll asked for, against what is written.
  local rendered = render.render(sc, { feel = false, unsorted = true, written = true })
  plain = {}
  for _, r in ipairs(rendered) do plain[r.meta.score.n] = r end
  for nid, want in pairs(wanted) do
    local r = plain[nid]
    if r then
      local fe = { dt = want.start - r.start, dlen = want.length - r.length, dvel = want.velocity - r.velocity }
      if math.abs(fe.dt) < 1e-9 then fe.dt = nil end
      if math.abs(fe.dlen) < 1e-9 then fe.dlen = nil end
      if fe.dvel == 0 then fe.dvel = nil end
      sc.feel[nid] = next(fe) and fe or nil
    end
  end
  sc.rev = D.token()
  view.commit(clip, sc, render.with_feel(rendered, sc.feel))
  daw.ui.poke()
  return first and render.last and render.last.places[first]
end

daw.clips.owner("notation", {
  claims = view.has_score,
  on_edit = M.on_edit,
})

view.owner = M
return M
