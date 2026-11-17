-- The notation view's state and what it does to a clip: the cursor, the
-- value chosen for entering notes, and every edit. The clip's MIDI is the
-- truth; the score is a view of it (`notation.midi`): transcribed from the
-- notes with what notation decided, kept on the notes and the clip. Every
-- edit changes that score (`notation.doc`) and is written back as MIDI
-- edits, one undo step. Drawing is in notation.tui (cells) and
-- notation.gui (pixels); keys are in notation.keys.
local api = daw.api
local util = daw.util
local model = require("notation.model")
local score = require("notation.score")
local D = require("notation.doc")
local L = require("notation.layout")
local midi = require("notation.midi")

local EPS = 1e-6

daw.option.define("notation_grid", 0.25)   -- the smallest value written, in beats

local view = {
  clip_id = nil,
  beat = 0,          -- the cursor, in beats from the start of the clip
  step = 35,         -- the cursor's staff position, as a diatonic step (C4 is 35)
  value = 1,         -- the value chosen for entering notes: 4 whole ... 0.125 32nd
  dot = false,       -- and whether it is dotted
  voice = 1,         -- the voice notes are entered in, on the cursor's staff
  first = 1,         -- the first measure on screen
  chord = nil,       -- notes entered at one place in insert mode: { beat, pitches }
  last = nil,        -- the last note entered in insert mode: { id, step, pitch, beat }
}

function view:clip()
  if self.clip_id and pcall(api.clip_get, self.clip_id) then return daw.clip(self.clip_id) end
  self.clip_id = nil
end

-- What the layout is made from ---------------------------------------------------------

--- The project's key as sharps or flats, from `project.meta.musicops`, where
--- the musicops extension keeps it (`{ root = "D", scale = "minor" }`).
function view.key()
  local meta = api.project_get().meta or {}
  local stored = type(meta.musicops) == "table" and meta.musicops or nil
  if stored and stored.root then return model.fifths_of(stored.root, stored.scale or "major"), stored end
  return 0, nil
end

--- The clef a track asks for, or nil to choose by the notes.
function view.track_clef(track_id)
  local ok, t = pcall(api.track_get, track_id)
  local meta = ok and t.meta and t.meta.notation
  return type(meta) == "table" and meta.clef or nil
end

-- Bars and the score layer's settings --------------------------------------------------

--- The time signature in force at a beat of the project: from the kernel's
--- signature map when it has one, else the project's signature.
function view.signature_at(beat)
  local t = daw.time
  local f = t.signature_at or t.sig_at or t.meter_at
  if f then
    local a, b = f(beat)
    if type(a) == "table" then return a.num or a[1], a.den or a[2] end
    if a and b then return a, b end
  end
  local p = api.project_get()
  return p.sig_num, p.sig_den
end

--- The bars a stretch of the project covers, `{ start, num, den, number }`
--- with `start` in beats from `start`, where the signature changes along
--- the song.
function view.bars(start, length)
  local t = daw.time
  if not (t.signature_at or t.sig_at or t.meter_at) then
    local p = api.project_get()
    return model.even_bars(start, length, p.sig_num, p.sig_den)
  end
  local out, at, n = {}, 0, 1
  local finish = start + math.max(length, EPS)
  while at < finish - EPS and n < 100000 do
    local num, den = view.signature_at(at)
    local len = num * 4 / den
    if at + len > start + EPS then out[#out + 1] = { start = at - start, num = num, den = den, number = n } end
    at, n = at + len, n + 1
  end
  return out
end

--- The tempo at a beat, for the transcription's windows in milliseconds.
function view.tempo_at(beat)
  local f = daw.time.tempo_at
  if f then
    local ok, v = pcall(f, beat)
    if ok and tonumber(v) then return tonumber(v) end
  end
  return api.project_get().tempo
end

--- What the notation keeps with a clip: `{ settings, tuplets, marks }`.
function view.own(c)
  local meta = c and c.meta
  return type(meta) == "table" and type(meta.notation) == "table" and meta.notation or {}
end

--- The transcription's settings for a clip: the defaults under its own.
function view.settings_of(c)
  local set = score.settings(view.own(c).settings)
  set.grid = (view.own(c).settings or {}).grid or daw.opt.notation_grid
  return set
end

--- Keep something with the clip, under `meta.notation`: `fn(own)` changes
--- a copy, which is written back as one undoable edit.
function view.keep(clip, fn)
  local c = clip:get()
  local meta = util.merge(c.meta or {}, {})
  local own = type(meta.notation) == "table" and util.merge(meta.notation, {}) or {}
  fn(own)
  meta.notation = next(own) and own or nil
  clip.meta = meta
end

local function serial(v)
  if type(v) ~= "table" then return tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. serial(v[k]) end
  return "{" .. table.concat(out, ",") .. "}"
end

--- Whether the open clip is shown note for note, as played.
function view.raw_view()
  local clip = view:clip()
  return clip and view.settings_of(clip:get()).mode == "raw" or false
end

--- The options a clip is laid out with (`own` in place of what it keeps).
function view.layout_opts(c, own)
  local fifths = view.key()
  own = own or view.own(c)
  local settings = score.settings(own.settings)
  settings.grid = (own.settings or {}).grid or daw.opt.notation_grid
  -- The track's clef, else the staves the clip was written on in notation.
  local staves = type(own.staves) == "table" and own.staves or nil
  local clef = view.track_clef(c.track) or (staves and (#staves == 2 and "grand" or staves[1]))
  return {
    length = c.length, offset = c.start, bars = view.bars(c.start, c.length), fifths = fifths,
    clef = clef, grid = daw.opt.notation_grid, tempo = view.tempo_at(c.start),
    settings = settings, tuplets = own.tuplets,
  }
end

--- Marks the score keeps besides the notes, put on a layout's events:
--- filled in by the editor's features (dynamics, articulations, lyrics).
view.decorators = {}
function view.decorate(layout, clip)
  for _, fn in ipairs(view.decorators) do fn(layout, clip) end
  return layout
end

--- Several tracks as one system: the notes of each track's MIDI clips
--- over the open clip's stretch of the song, a staff (or two) each, all
--- spaced together. Read only.
function view:multi_layout(c, opts)
  local from, to = c.start, c.start + c.length
  local parts = {}
  for _, id in ipairs(self.multi) do
    local ok, track = pcall(daw.track, id)
    if ok and track then
      local notes = {}
      for _, other in ipairs(track:clips()) do
        local oc = other:get()
        if oc.kind == "midi" and oc.start < to and oc.start + oc.length > from then
          for _, n in ipairs(other:notes()) do
            local at = oc.start + n.start - from
            if n.start < oc.length and at >= 0 and at < c.length then
              notes[#notes + 1] = util.merge(n, { start = at })
            end
          end
        end
      end
      table.sort(notes, function(a, b) return a.start < b.start or (a.start == b.start and a.pitch < b.pitch) end)
      local t = track:get()
      local own = util.merge(opts, { clef = view.track_clef(id) })
      parts[#parts + 1] = { name = t.name, layout = model.layout(notes, own), track = id }
    end
  end
  if #parts == 0 then return nil end
  local out = setmetatable({ staves = {}, names = {}, tracks = {}, readonly = true }, { __index = parts[1].layout })
  out.measures = {}
  for i, m in ipairs(parts[1].layout.measures) do
    out.measures[i] = setmetatable({ staves = {} }, { __index = m })
  end
  for _, part in ipairs(parts) do
    for k, clef in ipairs(part.layout.staves) do
      out.staves[#out.staves + 1] = clef
      out.names[#out.staves] = k == 1 and part.name or ""
      out.tracks[#out.staves] = part.track
      for i, m in ipairs(part.layout.measures) do
        local evs = m.staves[k]
        for _, ev in ipairs(evs) do ev.staff = #out.staves end
        out.measures[i].staves[#out.staves] = evs
      end
    end
  end
  return out
end

--- Whether the view shows several tracks (and so cannot be edited).
function view:readonly()
  if self.multi then
    daw.notify("several tracks are shown, to read: :notation.tracks to edit this clip again", "warn")
    return true
  end
  return false
end

--- The layout of the open clip, made fresh when the clip or the project
--- has changed since the last one.
function view:layout()
  if not self.clip_id then return nil end
  local ok, c = pcall(api.clip_get, self.clip_id)
  if not ok then
    self.clip_id = nil
    return nil
  end
  local clip = daw.clip(c.id)
  local opts = view.layout_opts(c)
  if self.multi then
    local parts = { c.id, c.start, c.length, opts.fifths, tostring(opts.tempo), serial(opts.bars) }
    for _, id in ipairs(self.multi) do
      local ok, track = pcall(daw.track, id)
      if ok and track then
        for _, other in ipairs(track:clips()) do
          local oc = other:get()
          parts[#parts + 1] = oc.id .. "/" .. tostring(oc.stamp) .. "/" .. oc.start .. "/" .. tostring(view.track_clef(id))
        end
      end
    end
    local stamp = "multi:" .. table.concat(parts, ":")
    if self.cache and self.cache.stamp == stamp then return self.cache.layout, self.cache.notes end
    local layout = self:multi_layout(c, opts)
    self.cache = { stamp = stamp, layout = layout, notes = clip:notes() }
    return layout, self.cache.notes
  end
  -- Laid out from the score the clip's notes are written as.
  local sc = view.score_of(c)
  local stamp = table.concat({ tostring(sc), c.length, opts.fifths, daw.opt.notation_grid,
    tostring(opts.bars[1] and opts.bars[1].number), serial(view.track_meta(c.track)) }, ":")
  if self.cache and self.cache.stamp == stamp then return self.cache.layout end
  local layout = L.layout(sc, { length = c.length, fifths = opts.fifths, grid = daw.opt.notation_grid,
    number = opts.bars[1] and opts.bars[1].number })
  -- Each written note knows the note that plays it, by its place among the clip's.
  local place = {}
  for i, n in ipairs(view.notes_of(c)) do
    if n.id then place["n" .. n.id] = i end
  end
  layout.places = {}
  for _, m in ipairs(layout.measures) do
    for _, evs in ipairs(m.staves) do
      for _, ev in ipairs(evs) do
        for _, n in ipairs(ev.notes or {}) do
          n.index = place[n.head or n.id]
          layout.places[n.id] = n.index
        end
        for _, n in ipairs(ev.grace or {}) do n.index = place[n.id] end
      end
    end
  end
  view.decorate(layout, clip)
  self.cache = { stamp = stamp, layout = layout }
  return layout
end

-- The scores derived last, by clip.
local derived, derived_count = {}, 0

--- The score a clip's notes are written as (see `notation.midi`), to read:
--- it must not be changed. Kept until the clip, what notation keeps with
--- it, or the song's bars or key change.
function view.score_of(c)
  if not (c and c.kind == "midi") then return nil end
  local own = view.own(c)
  local old = type(c.meta) == "table" and type(c.meta.score) == "table" and c.meta.score or nil
  local opts = view.layout_opts(c, own)
  local key = table.concat({ c.id, tostring(c.stamp), tostring(c.note_count), c.length, c.start, opts.fifths, tostring(opts.tempo),
    tostring(opts.clef), serial(own), serial(opts.bars), daw.opt.notation_grid, old and tostring(old.rev) or "" }, ":")
  local hit = derived[c.id]
  if hit and hit.key == key then return hit.score end
  local notes = api.clip_notes(c.id)
  if old then
    -- Kept as a score the old way: read as the notes and marks it means.
    notes, own = midi.legacy_notes(c, notes)
    opts = view.layout_opts(c, own)
  end
  local sc = midi.derive(notes, own, opts)
  if derived_count > 8 then derived, derived_count = {}, 0 end
  derived[c.id], derived_count = { key = key, score = sc, notes = notes }, derived_count + 1
  return sc
end

--- The clip's notes as its score (`view.score_of`) was written from, to
--- read: they must not be changed.
function view.notes_of(c)
  view.score_of(c)
  local hit = derived[c.id]
  return hit and hit.notes or api.clip_notes(c.id)
end

--- What the track keeps for notation (its clef, its tablature).
function view.track_meta(track_id)
  local ok, t = pcall(api.track_get, track_id)
  return ok and t.meta and t.meta.notation or nil
end

-- The cursor ------------------------------------------------------------------------------

--- The tuplet notes are entered in, `{ actual, normal }`, or nil.
function view:entry_tuplet()
  return self.tuplet or (self.triplets and { 3, 2 }) or nil
end

--- The value chosen, in beats, with its dot, and as a tuplet's (a
--- triplet's) when entering in one.
function view:entry_length()
  local tp = self:entry_tuplet()
  return self.value * (self.dot and 1.5 or 1) * (tp and tp[2] / tp[1] or 1)
end

--- The beat the view keeps on screen: the playhead while playing in the
--- clip, the cursor otherwise.
function view:follow_beat()
  local clip = self:clip()
  local t = api.transport_get()
  if clip and t.playing then
    local at = t.position - clip.start
    if at >= 0 and at < clip.length then return at end
  end
  return self.beat
end

--- The measure a beat of the clip is in.
function view:measure_at(beat, layout)
  layout = layout or self:layout()
  if not layout then return nil end
  local list = layout.measures
  for i, m in ipairs(list) do
    if beat < m.start + m.length - EPS then return m, i end
  end
  return list[#list], #list
end

--- The staff a step is written on: the bass staff of a grand staff for
--- anything below middle C.
function view:staff_of_step(step, layout)
  layout = layout or self:layout()
  if layout and #layout.staves == 2 and step < 35 then return 2 end
  return 1
end

function view:staff_of_pitch(pitch, layout)
  layout = layout or self:layout()
  if layout and #layout.staves == 2 and pitch < 60 then return 2 end
  return 1
end

--- The written event under a place: the note (with the event it is in) at
--- `step` sounding at `beat`, or else the event there on the staff.
function view:event_at(beat, step)
  local layout = self:layout()
  if not layout then return nil end
  local m = self:measure_at(beat, layout)
  if not m then return nil end
  -- The note at that line or space, on whichever staff the hands put it.
  for st = 1, #layout.staves do
    for _, ev in ipairs(m.staves[st] or {}) do
      if beat >= ev.start - EPS and beat < ev.start + ev.length - EPS then
        for _, n in ipairs(ev.notes or {}) do
          if n.step == (step or self.step) then return ev, n end
        end
      end
    end
  end
  local staff = self:staff_of_step(step or self.step, layout)
  for _, ev in ipairs(m.staves[staff] or {}) do
    if beat >= ev.start - EPS and beat < ev.start + ev.length - EPS then
      for _, n in ipairs(ev.notes or {}) do
        if n.step == (step or self.step) then return ev, n end
      end
      return ev, nil
    end
  end
end

--- The staff the cursor is drawn on: its note's, or by its line.
function view:cursor_staff(layout)
  layout = layout or self:layout()
  local ev = self:event_at(self.beat, self.step)
  local _, written = self:event_at(self.beat, self.step)
  if written and ev then return ev.staff end
  return self:staff_of_step(self.step, layout)
end

--- The clip's note under the cursor: the note, its place, and how it is written.
function view:note()
  local _, written = self:event_at(self.beat, self.step)
  if not written then return nil end
  local clip = self:clip()
  local note = clip and clip:notes()[written.index]
  if note then return note, written.index, written end
end

--- The pitch the cursor stands for: the note's there, or the key's at that line or space.
function view:cursor_pitch()
  local note = self:note()
  if note then return note.pitch end
  return model.key_pitch(self.step, (view.key()))
end

--- Where a written note starts and how long it is written, ties included.
function view:written_span(index)
  local layout = self:layout()
  local start, finish
  for _, ev in ipairs(model.events(layout)) do
    for _, n in ipairs(ev.notes or {}) do
      if n.index == index then
        start = start and math.min(start, ev.start) or ev.start
        finish = finish and math.max(finish, ev.start + ev.length) or ev.start + ev.length
      end
    end
  end
  return start, finish
end

function view:set(step, beat)
  local clip = self:clip()
  if not clip then return end
  if step then self.step = util.clamp(step, 0, 74) end
  if beat then self.beat = util.clamp(beat, 0, clip.length) end
  api.ui_redraw()
end

--- Sound a pitch on the clip's track.
function view:audition(pitch)
  local clip = self:clip()
  if clip then clip:track():play_note(pitch or self:cursor_pitch(), daw.opt.velocity, 220) end
end

--- Move the cursor by beats and staff positions.
function view:move(dbeat, dstep)
  local clip = self:clip()
  if not clip then return end
  local was = self.step
  self:set(self.step + dstep, util.clamp(self.beat + dbeat, 0, clip.length))
  if self.step ~= was then self:audition() end
end

--- Every place something is written, in time order: starts of notes and rests.
function view:starts()
  local layout = self:layout()
  local out, seen = {}, {}
  for _, ev in ipairs(model.events(layout)) do
    local key = string.format("%.4f", ev.start)
    if ev.start >= -EPS and not seen[key] then
      seen[key] = true
      out[#out + 1] = ev
    end
  end
  return out
end

--- To the next (1) or previous (-1) note or rest.
function view:to_event(dir, count)
  for _ = 1, count or 1 do
    local found
    local list = self:starts()
    if dir > 0 then
      for _, ev in ipairs(list) do
        if ev.start > self.beat + EPS then
          found = ev
          break
        end
      end
    else
      for i = #list, 1, -1 do
        if list[i].start < self.beat - EPS then
          found = list[i]
          break
        end
      end
    end
    if not found then return end
    local step = self.step
    -- Onto the note there, if there is one, nearest the cursor's line.
    if found.notes then
      local best
      for _, n in ipairs(found.notes) do
        if not best or math.abs(n.step - self.step) < math.abs(best - self.step) then best = n.step end
      end
      step = best
    end
    self:set(step, math.max(0, found.start))
  end
end

--- To the end of the note under the cursor, or of the next to end.
function view:to_event_end()
  local best
  for _, ev in ipairs(model.events(self:layout())) do
    local finish = ev.start + ev.length
    if ev.kind == "note" and finish > self.beat + EPS and (not best or finish < best) then best = finish end
  end
  if best then self:set(nil, best) end
end

function view:to_bar(n)
  local layout = self:layout()
  if not layout then return end
  local _, i = self:measure_at(self.beat, layout)
  local m = layout.measures[i]
  local at = n > 0 and i + n or ((self.beat > m.start + EPS) and i + n + 1 or i + n)
  at = util.clamp(at, 1, #layout.measures + 1)
  local target = at > #layout.measures and (m.start + (#layout.measures - i + 1) * layout.meter.bar) or layout.measures[at].start
  self:set(nil, math.max(0, target))
end

--- To the highest (1) or lowest (-1) note's line.
function view:to_extreme(dir)
  local best
  for _, ev in ipairs(model.events(self:layout())) do
    for _, n in ipairs(ev.notes or {}) do
      if not best or (n.step - best) * dir > 0 then best = n.step end
    end
  end
  if best then self:set(best, nil) end
end

-- Writing ---------------------------------------------------------------------------------------

--- The open clip, to edit: nil while several tracks are shown.
function view:editable()
  if self:readonly() then return nil end
  return self:clip()
end

--- Write a change of a clip's score as MIDI: `before` is the score derived
--- from the clip, `sc` what an edit made of it (see `notation.midi`). The
--- clip grows to hold every measure with something written in it. One
--- undoable step with whatever else this turn changes.
function view.store(clip, before, sc)
  sc._frame = nil
  local c = clip:get()
  local named = midi.sync(clip.id, before, sc, view.own(c), view.track_clef(c.track))
  local f = D.frame(sc)
  local last = 0
  for i, m in ipairs(sc.measures) do
    for _, entry in ipairs(D.peek(m, "voices")) do
      if #entry.events > 0 then last = i end
    end
  end
  if last > 0 then
    local finish = (D.origin(sc) + f.starts[last] + f.lengths[last]) / D.Q
    if finish > clip:get().length + EPS then api.clip_set(clip.id, "length", finish) end
  end
  view.cache = nil
  -- New notes are named by their MIDI notes from now on.
  view.renamed = {}
  for id, k in pairs(named) do view.renamed[id] = "n" .. k end
  return named
end

--- The id a written note has now, after the last write named new notes.
function view.now_id(id) return view.renamed and view.renamed[id] or id end

--- Change the open clip's score with `fn(score, clip)` (unless several
--- tracks are shown), and write what changed as MIDI edits, one undo
--- step. `fn` returning false changes nothing.
function view:write(fn)
  local clip = self:editable()
  if not clip then return end
  -- A clip kept as a score the old way is kept as MIDI and notation data
  -- first, in the same step.
  if midi.migrate(clip.id) then self.cache = nil end
  local before = view.score_of(clip:get())
  local sc = D.copy(before, true)
  local ok, result = pcall(fn, sc, clip)
  if not ok then error(result, 0) end
  if result ~= false then view.store(clip, before, sc) end
  daw.ui.poke()
  return result
end

--- The measure and ticks into it of a beat of the clip.
local function where(sc, beat)
  return D.locate(sc, D.from_beats(beat) - D.origin(sc))
end
view.where = where

--- The id of the staff a pitch (or a step) is written on.
function view:staff_id(sc, pitch, step)
  local s = 1
  if #sc.staves == 2 then
    if step then s = step < 35 and 2 or 1 else s = pitch < 60 and 2 or 1 end
  end
  return sc.staves[s].id
end

--- A note spelled as the key has it, or as `sp` (a model spelling) says.
local function spelled(pitch, sp)
  return D.spelled(sp or model.spell(pitch, (view.key())))
end

--- The written event under the cursor and the note there, from the layout
--- (whose events name the score's: `source`, `mi`, `at`, `staff_id`), to
--- edit.
function view:here()
  if not self:editable() then return nil end
  local ev, n = self:event_at(self.beat, self.step)
  if ev and ev.source and ev.source.id ~= "" then return ev, n end
end

--- The events a chord's ties join, from it on: `{ { ev, mi, entry, at } }`.
local function chain(sc, eid)
  local mi, entry, _, at, ev = D.find(sc, eid)
  if not ev then return {} end
  local out = { { ev = ev, mi = mi, entry = entry, at = at } }
  local seq = D.sequence(sc, entry.staff, entry.voice)
  local k
  for i, it in ipairs(seq) do
    if it.ev == ev then k = i end
  end
  while k and seq[k + 1] do
    local cur, nxt = seq[k].ev, seq[k + 1].ev
    local tied = false
    if nxt.kind == "chord" and not nxt.grace then
      for _, n in ipairs(cur.notes or {}) do
        if n.tie then
          for _, o in ipairs(nxt.notes) do
            if D.pitch(o) == D.pitch(n) then tied = true end
          end
        end
      end
    end
    if not tied then break end
    local f = D.frame(sc)
    out[#out + 1] = { ev = nxt, mi = seq[k + 1].mi, entry = D.voice(sc.measures[seq[k + 1].mi], entry.staff, entry.voice), at = seq[k + 1].s - f.starts[seq[k + 1].mi] }
    k = k + 1
  end
  return out
end
view.chain = chain

--- The grace events just before an event of a voice.
local function graces_before(entry, ev)
  local out = {}
  for k, x in ipairs(entry.events) do
    if x == ev then
      local j = k - 1
      while entry.events[j] and entry.events[j].grace do
        table.insert(out, 1, entry.events[j])
        j = j - 1
      end
    end
  end
  return out
end

--- Silence where a chord and what its ties join were, its grace notes
--- gone with it. Returns what it was: `{ notes, art, arpeggio, beam, id,
--- staff, voice, mi, at, len, graces }`.
local function lift(sc, eid)
  local links = chain(sc, eid)
  if #links == 0 then return nil end
  local head = links[1]
  local f = D.frame(sc)
  local first = f.starts[head.mi] + head.at
  local last = links[#links]
  local was = { notes = head.ev.notes, art = head.ev.art, arpeggio = head.ev.arpeggio, beam = head.ev.beam, id = head.ev.id,
    orn = head.ev.orn, lyric = head.ev.lyric, lyrics = head.ev.lyrics,
    staff = head.entry.staff, voice = head.entry.voice, mi = head.mi, at = head.at,
    len = f.starts[last.mi] + last.at + D.length(last.ev) - first, graces = graces_before(head.entry, head.ev) }
  for _, g in ipairs(was.graces) do
    for k, x in ipairs(head.entry.events) do
      if x == g then table.remove(head.entry.events, k) break end
    end
  end
  for _, link in ipairs(links) do
    local ev = link.ev
    -- A rest of its own: the chord's id goes with the chord.
    ev.id, ev.kind, ev.notes, ev.art, ev.arpeggio, ev.beam, ev.stem = D.id(sc, "e"), "rest", nil, nil, nil, nil, nil
    ev.orn, ev.lyric, ev.lyrics = nil, nil, nil
    D.normalize(sc, link.mi, link.entry.staff, link.entry.voice)
    D.touch(sc, link.mi)
  end
  D.fix_ties(sc, was.staff, was.voice, math.max(1, head.mi - 1), head.mi)
  return was
end
view.lift = lift

--- Put a lifted chord back at a place (ticks from measure 1) with a length,
--- keeping its ids, marks and grace notes; what is there gives way.
local function drop(sc, was, t, len, staff, voice)
  local mi, at = D.locate(sc, math.max(0, t))
  local ev = D.put_chord(sc, mi, staff or was.staff, voice or was.voice, at, len, was.notes,
    { id = was.id, art = was.art, arpeggio = was.arpeggio, beam = was.beam, orn = was.orn, lyric = was.lyric, lyrics = was.lyrics })
  if #was.graces > 0 then
    local _, entry, k = D.find(sc, ev.id)
    for g = #was.graces, 1, -1 do table.insert(entry.events, k, was.graces[g]) end
  end
  D.fix_ties(sc, staff or was.staff, voice or was.voice, math.max(1, mi - 1), mi)
  return ev
end
view.drop = drop

--- Add a note to a chord and to what its ties join, tied on as they are.
local function join_chord(sc, eid, note)
  local links = chain(sc, eid)
  local pitch = D.pitch(note)
  for _, n in ipairs(links[1] and links[1].ev.notes or {}) do
    if D.pitch(n) == pitch then return n.id end
  end
  local id
  for k, link in ipairs(links) do
    local n = { id = (k == 1 and note.id) or D.id(sc, "n"), step = note.step, alter = note.alter, octave = note.octave, tie = k < #links or nil }
    id = id or n.id
    table.insert(link.ev.notes, n)
    table.sort(link.ev.notes, function(a, b) return D.pitch(a) < D.pitch(b) end)
    D.touch(sc, link.mi)
  end
  return id
end
view.join_chord = join_chord

view.join_chord = join_chord

--- The chord of a voice starting exactly at `at` ticks into measure `mi`.
local function chord_at(sc, mi, staff, v, at)
  local m = sc.measures[mi]
  local entry = m and D.voice(m, staff, v)
  local t = 0
  for _, ev in ipairs(entry and entry.events or {}) do
    if t == at and ev.kind == "chord" and not ev.grace then return ev end
    t = t + D.length(ev)
  end
end

--- Whether a voice is silent from `t` for `len` ticks (from measure 1).
local function silent(sc, staff, v, t, len)
  for _, it in ipairs(D.sequence(sc, staff, v)) do
    if it.ev.kind == "chord" and not it.ev.grace and it.s < t + len and it.e > t then return false end
  end
  return true
end

--- A note added by its sound, as the piano roll adds one: it joins a chord
--- of the same start and length, else fills silence in voice 1, else in
--- voice 2, 3 or 4, on the staff its pitch belongs to. Returns its id, or
--- nil when every voice is busy there.
function view.add_sounding(sc, note, t, len, staff)
  for v = 1, 4 do
    local mi, at = D.locate(sc, t)
    D.ensure(sc, mi)
    local ev = chord_at(sc, mi, staff, v, at)
    if ev then
      local links = chain(sc, ev.id)
      local f = D.frame(sc)
      local last = links[#links]
      local span = f.starts[last.mi] + last.at + D.length(last.ev) - (f.starts[mi] + at)
      if span == len then return join_chord(sc, ev.id, note) end
    end
  end
  for v = 1, 4 do
    if silent(sc, staff, v, t, len) then
      local mi, at = D.locate(sc, t)
      local ev = D.put_chord(sc, mi, staff, v, at, len, { note })
      D.fix_ties(sc, staff, v, math.max(1, mi - 1), mi)
      return ev.notes[1].id
    end
  end
end

--- A single staff whose clef the track leaves to the notes becomes a
--- grand staff when a note is entered more than three ledger lines outside
--- it (a bass under a melody, a melody over a bass).
function view:make_room(sc, pitch)
  if #sc.staves ~= 1 then return end
  local clip = self:clip()
  if not clip or view.track_clef(clip:get().track) then return end
  local clef = sc.staves[1].clef
  if (clef == "treble" and pitch < 53) or (clef == "bass" and pitch > 67) then
    local upper = clef == "treble" and sc.staves[1] or { id = D.id(sc, "s"), clef = "treble" }
    local lower = clef == "bass" and sc.staves[1] or { id = D.id(sc, "s"), clef = "bass" }
    sc.staves = { upper, lower }
    for i in ipairs(sc.measures) do D.touch(sc, i) end
  end
end

--- Write a note at the cursor's beat (or `beat`), `length` beats long, in
--- the entry voice on its staff: what was written there in that voice gives
--- way (in no other voice or staff). With `chord`, it joins the chord the
--- voice has starting there. Entering triplets makes or fills a tuplet.
--- Returns the note's id, or nil and why not.
function view:put(sc, note, beat, length, chord)
  local mi, at = where(sc, beat)
  D.ensure(sc, mi)
  self:make_room(sc, D.pitch(note))
  local staff = self:staff_id(sc, D.pitch(note))
  local v = self.voice or 1
  if chord then
    local ev = chord_at(sc, mi, staff, v, at)
    if ev then return join_chord(sc, ev.id, note) end
  end
  -- Entering that pushes: what comes later in the voice moves along first.
  if self.push and view.push_on then view.push_on(sc, staff, v, D.frame(sc).starts[mi] + at, D.from_beats(length)) end
  local tp = self:entry_tuplet()
  if tp then
    local value = D.from_beats(self.value * (self.dot and 1.5 or 1))
    local ev, why = D.put_tuplet_chord(sc, mi, staff, v, at, value, tp[1], tp[2], { note })
    if not ev then return nil, why end
    return ev.notes[1].id
  end
  local ev = D.put_chord(sc, mi, staff, v, at, D.from_beats(length), { note })
  D.fix_ties(sc, staff, v, math.max(1, mi - 1), mi)
  -- A grace note typed before there was a note here leads to this one.
  local grace = self.pending_grace
  if grace and math.abs(grace.beat - beat) < EPS then
    self.pending_grace = nil
    require("notation.operators").put_grace(sc, mi, staff, v, at, grace.kind, grace.sp)
  end
  return ev.notes[1].id
end

--- Silence a stretch of a voice of a staff (by its index), from `beat` for `length`.
function view:clear(sc, beat, length, staff_index, v)
  local staff = (sc.staves[staff_index or 1] or sc.staves[1]).id
  v = v or self.voice or 1
  local t, finish = D.from_beats(beat) - D.origin(sc), D.from_beats(beat + length) - D.origin(sc)
  while t < finish do
    local mi, at = D.locate(sc, t)
    D.ensure(sc, mi)
    local f = D.frame(sc)
    local b = math.min(f.lengths[mi], at + finish - t)
    D.splice(sc, mi, staff, v, at, b, nil)
    D.fix_ties(sc, staff, v, math.max(1, mi - 1), mi)
    t = t + (b - at)
  end
end

--- Make the room for the clip to reach `finish`, a bar at a time.
function view:grow(clip, finish)
  if finish > clip.length + EPS then
    local bar = daw.time.bar()
    clip.length = math.ceil((clip.start + finish - EPS) / bar) * bar - clip.start
  end
end

--- Put a note in as it is written, `length` long from `beat`, in the entry
--- voice: what is written there in that voice gives way. `keep` (a chord
--- being built) makes it join the chord there. `spell` is how to write it.
--- Returns the note's id.
function view:place(pitch, beat, length, keep, spell)
  local id
  self:write(function(sc)
    local why
    id, why = self:put(sc, spelled(util.clamp(pitch, 0, 127), spell), beat, length, keep)
    if not id then
      daw.notify(why or "nothing written", "warn")
      return false
    end
  end)
  return id and view.now_id(id)
end

--- Clear a stretch of one staff (by its index) in the entry voice: a rest written there.
function view:rest(beat, length, staff)
  self:write(function(sc)
    if self.push and view.push_on then
      view.push_on(sc, (sc.staves[staff or 1] or sc.staves[1]).id, self.voice or 1, D.from_beats(beat) - D.origin(sc), D.from_beats(length))
    end
    self:clear(sc, beat, length, staff)
  end)
end

--- Change the note under the cursor with `fn(score, note, written)`:
--- `note` is the score's, `written` the layout's. Returns whether there was one.
function view:change(fn)
  local _, n = self:here()
  if not n then return false end
  local id = n.head or n.id
  local done = false
  self:write(function(sc)
    local note = D.find_note(sc, id)
    if not note then return false end
    done = fn(sc, note, n) ~= false
    return done
  end)
  return done
end

--- Respell (and so repitch) a written note and what is tied on from it.
local function respell(sc, note, sp)
  D.respell(sc, note.id, sp.letter, sp.alter, sp.octave)
end

--- The score's chord under the cursor: the score event, and the written
--- event (the piece of it) the cursor is on.
function view:score_chord()
  local ev, written = self:here()
  if ev and ev.kind == "note" then return ev.source, ev, written end
end

--- Change the written length of the chord under the cursor, ties included,
--- with `fn(length in beats)`: it is written again from its start, and
--- what it now reaches over in its voice gives way.
function view:relength(fn)
  local source = self:score_chord()
  if not source then return false end
  return self:write(function(sc)
    local was = lift(sc, source.id)
    if not was then return false end
    local f = D.frame(sc)
    local t = f.starts[was.mi] + was.at
    local len = D.from_beats(math.max(daw.opt.notation_grid / 2, fn(was.len / D.Q)))
    drop(sc, was, t, len)
    self.beat = math.max(0, (D.origin(sc) + t) / D.Q)
  end) ~= false
end

function view:lengthen(by) return self:relength(function(l) return l + by end) end

--- Lengthen (or with `by` below 0, shorten) every chord of a region by `by` beats.
function view:relength_region(region, by)
  if not self:editable() then return end
  local layout = self:layout()
  if not layout then return end
  local ids = {}
  for _, ev in ipairs(model.events(layout)) do
    if ev.kind == "note" and ev.source and not ev.notes[1].tied then
      local inside = region.kind == "line" or (ev.start >= region.c0 - EPS and ev.start < region.c1 - EPS)
      if inside and region.kind == "block" then
        inside = false
        for _, n in ipairs(ev.notes) do inside = inside or (n.pitch >= region.r0 and n.pitch <= region.r1) end
      end
      if inside then ids[#ids + 1] = ev.source.id end
    end
  end
  if #ids == 0 then return end
  self:write(function(sc)
    -- From the last, so that one chord's new length does not take the next before it is changed.
    for k = #ids, 1, -1 do
      local was = lift(sc, ids[k])
      if was then
        local f = D.frame(sc)
        drop(sc, was, f.starts[was.mi] + was.at, math.max(D.from_beats(daw.opt.notation_grid / 2), was.len + D.from_beats(by)))
      end
    end
  end)
end

--- Add or take away the dot of the chord under the cursor.
function view:toggle_dot()
  local source = self:score_chord()
  if source and (source.dots or 0) > 0 then
    return self:relength(function() return D.ticks(source.dur) / D.Q end)
  end
  return self:relength(function(l)
    local base, dots = model.value_of(l)
    if base and dots > 0 then return base end
    return l * 1.5
  end)
end

--- Move the chord under the cursor by `by` beats as written: it is written
--- there (what is there in its voice gives way), with its grace notes and
--- its marks; its notes move by as much, however they were played.
function view:move_chord(by)
  local source = self:score_chord()
  if not source then return false end
  return self:write(function(sc)
    local was = lift(sc, source.id)
    if not was then return false end
    local f = D.frame(sc)
    local t = math.max(-D.origin(sc), f.starts[was.mi] + was.at + D.from_beats(by))
    t = math.max(0, t)
    drop(sc, was, t, was.len)
    self.beat = math.max(0, (D.origin(sc) + t) / D.Q)
  end) ~= false
end

--- Delete the chord under the cursor: a rest where it was.
function view:delete_chord()
  local source = self:score_chord()
  if not source then return false end
  return self:write(function(sc) return lift(sc, source.id) ~= nil end) ~= false
end

--- The clip's notes written from `from` to `to` (clip beats), `low` to
--- `high` (pitches), all optional: `{ { index, note, w } }`, `w` how each
--- is written (`notation.midi.written`), with the score.
local function written_in(clip, from, to, low, high)
  local sc = view.score_of(clip:get())
  local origin = D.origin(sc)
  local place = {}
  for i, n in ipairs(clip:notes()) do
    if n.id then place[n.id] = { index = i, note = n } end
  end
  local out = {}
  for id, w in pairs(midi.written(sc)) do
    local at = (origin + w.s) / D.Q
    local hit = place[midi.midi_id(id) or -1]
    if hit and (not from or at >= from - EPS) and (not to or at < to - EPS) and (not low or w.pitch >= low) and (not high or w.pitch <= high) then
      out[#out + 1] = { index = hit.index, note = hit.note, w = w, at = at }
    end
  end
  table.sort(out, function(a, b) return a.index < b.index end)
  return out, sc
end

--- Quantize to the notation: the notes written from `from` to `to` (clip
--- beats), `low` to `high` (pitches), all optional, made to start where
--- they are written and last as long, as marked (a staccato half). A MIDI
--- edit, one undo step. Returns how many notes changed.
function view:quantize(from, to, low, high)
  local clip = self:editable()
  if not clip then return 0 end
  local set = {}
  for _, x in ipairs(written_in(clip, from, to, low, high)) do
    local length = math.max(1 / 64, x.w.len / D.Q * (midi.gate(x.w.ev.art) or 1))
    if math.abs(x.note.start - x.at) > EPS or math.abs(x.note.length - length) > EPS then
      set[#set + 1] = { index = x.index, start = math.max(0, x.at), length = length }
    end
  end
  if #set > 0 then api.clip_notes_edit(clip.id, { set = set, remove = {}, add = {} }) end
  daw.ui.poke()
  return #set
end

--- Make the notes written from `from` to `to` (clip beats), `low` to `high`
--- (pitches), all optional, play as the marks along the clip say: the
--- dynamic's loudness, the hairpin's ramp, an accent's push, a staccato's
--- length. For MIDI that has drifted from them (the piano roll was used
--- since). A MIDI edit, one undo step. Returns how many notes changed.
function view:apply_marks(from, to, low, high)
  local clip = self:editable()
  if not clip then return 0 end
  local list, sc = written_in(clip, from, to, low, high)
  local res = midi.resolve(sc)
  local set = {}
  for _, x in ipairs(list) do
    local change = midi.marked(res, x.w, x.note)
    if change then
      change.index = x.index
      set[#set + 1] = change
    end
  end
  if #set > 0 then api.clip_notes_edit(clip.id, { set = set, remove = {}, add = {} }) end
  daw.ui.poke()
  return #set
end

--- Write again from the playing: forget what notation decided about the
--- notes written from `from` to `to` (clip beats; all of them without):
--- voices, hands, spellings, grace notes, chords, articulations, tuplets.
--- They are transcribed afresh from how they play; marks along the clip
--- stay. Returns how many notes were written again.
function view:retranscribe(from, to)
  local clip = self:editable()
  if not clip then return 0 end
  if midi.migrate(clip.id) then self.cache = nil end
  local set = {}
  local list = written_in(clip, from, to)
  for _, x in ipairs(list) do
    local own = x.note.meta and x.note.meta.notation
    if type(own) == "table" then
      local keep = { string = own.string }
      local meta = util.merge(x.note.meta, {})
      meta.notation = next(keep) and keep or nil
      set[#set + 1] = { index = x.index, meta = meta }
    end
  end
  if #set > 0 then api.clip_notes_edit(clip.id, { set = set, remove = {}, add = {} }) end
  -- The tuplets said there go too.
  local own = view.own(clip:get())
  if own.tuplets then
    view.keep(clip, function(mine)
      local kept = {}
      for _, tp in ipairs(mine.tuplets or {}) do
        if (from and tp.start + tp.length <= from + EPS) or (to and tp.start >= to - EPS) then kept[#kept + 1] = tp end
      end
      mine.tuplets = #kept > 0 and kept or nil
    end)
  end
  self.cache = nil
  daw.ui.poke()
  return #list
end

--- The ids of the notes of the chord under the cursor's events, or of a
--- selection: the events marks go on.
function view:chord_indices()
  local source = self:score_chord()
  return source and { source.id } or {}
end

--- The events of the notes of a region (the clip's notes there, by place).
function view:events_of(places)
  local layout = self:layout()
  local by = {}
  for _, m in ipairs(layout.measures) do
    for _, evs in ipairs(m.staves) do
      for _, ev in ipairs(evs) do
        for _, n in ipairs(ev.notes or {}) do
          if n.index and ev.source and not n.tied then by[n.index] = ev.source.id end
        end
      end
    end
  end
  local out, seen = {}, {}
  for _, p in ipairs(places) do
    local id = by[p]
    if id and not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  return out
end

--- The note under the cursor (or the chord, when the cursor is on none of
--- its notes) into the other voice of its staff, where that voice is silent
--- or has a chord of the same start and length to join; a rest is left
--- where it was. Returns the voice, or nil when it has no room.
function view:toggle_voice()
  local source, ev, n = self:score_chord()
  if not source then return false end
  local to = ev.voice == 1 and 2 or 1
  local moved = self:write(function(sc)
    local f = D.frame(sc)
    local links = chain(sc, source.id)
    local head, last = links[1], links[#links]
    if not head then return false end
    local staff = head.entry.staff
    local t = f.starts[head.mi] + head.at
    local len = f.starts[last.mi] + last.at + D.length(last.ev) - t
    local whole = not n or #source.notes == 1
    local notes = {}
    if whole then
      for _, x in ipairs(head.ev.notes) do notes[#notes + 1] = { id = x.id, step = x.step, alter = x.alter, octave = x.octave } end
    else
      local note = D.find_note(sc, n.head or n.id)
      notes[1] = { id = note.id, step = note.step, alter = note.alter, octave = note.octave }
    end
    -- Where it goes: a chord of the same start and length, or silence.
    local mi, at = D.locate(sc, t)
    local target = chord_at(sc, mi, staff, to, at)
    if target then
      local tl = chain(sc, target.id)
      local tlast = tl[#tl]
      if f.starts[tlast.mi] + tlast.at + D.length(tlast.ev) - t ~= len then target = nil end
    end
    if not target and not silent(sc, staff, to, t, len) then
      daw.notify("voice " .. to .. " has other notes there", "warn")
      return false
    end
    if whole then
      lift(sc, source.id)
    else
      for _, c in ipairs(D.tied_on(sc, staff, head.entry.voice, notes[1].id)) do D.remove_note(sc, c.note.id) end
      D.remove_note(sc, notes[1].id)
    end
    if target then
      for _, x in ipairs(notes) do join_chord(sc, target.id, x) end
    else
      drop(sc, { notes = notes, graces = {}, staff = staff, voice = to, id = whole and source.id or nil,
        art = whole and source.art or nil, arpeggio = whole and source.arpeggio or nil }, t, len, staff, to)
    end
  end)
  if moved == false then return nil end
  self.voice = to
  return to
end

--- The chord under the cursor onto the other staff of a grand staff, in
--- whichever voice is free there.
function view:toggle_staff()
  local source, ev = self:score_chord()
  local layout = self:layout()
  if not (source and #layout.staves == 2) then return false end
  local to = ev.staff == 1 and 2 or 1
  self:write(function(sc)
    local was = lift(sc, source.id)
    if not was then return false end
    local f = D.frame(sc)
    local t = f.starts[was.mi] + was.at
    local staff = sc.staves[to].id
    local first
    for _, note in ipairs(was.notes) do
      first = first or view.add_sounding(sc, { step = note.step, alter = note.alter, octave = note.octave }, t, was.len, staff)
    end
  end)
  return to
end

--- The chord under the cursor rolled up, down, or not marked.
function view:cycle_strum()
  local source = self:score_chord()
  if not source then return false end
  local next_mark = ({ up = "down", down = nil })[source.arpeggio or ""]
  if not source.arpeggio then next_mark = "up" end
  self:write(function(sc)
    local mi, _, _, _, ev = D.find(sc, source.id)
    if not ev then return false end
    ev.arpeggio = next_mark
    D.touch(sc, mi)
  end)
  return next_mark
end

--- The chord under the cursor a grace note of the next one (its written
--- time goes to the chord before it, or is a rest), or the chord's grace
--- notes not grace notes again (written before it, in the time of the
--- chord before). Returns whether it is now a grace note.
function view:toggle_grace()
  local source = self:score_chord()
  if not source then return false end
  local made = false
  self:write(function(sc)
    local mi, entry, k, at, ev = D.find(sc, source.id)
    if not ev then return false end
    local graces = graces_before(entry, ev)
    local f = D.frame(sc)
    if #graces > 0 then
      -- Back to notes, before the chord, in the time of what was before it.
      local value = D.ticks(graces[#graces].dur)
      for _, g in ipairs(graces) do
        for j, x in ipairs(entry.events) do
          if x == g then table.remove(entry.events, j) break end
        end
      end
      local t = f.starts[mi] + at - value * #graces
      for gi, g in ipairs(graces) do
        local gm, gat = D.locate(sc, math.max(0, t + (gi - 1) * value))
        D.put_chord(sc, gm, entry.staff, entry.voice, gat, value, g.notes)
      end
      return
    end
    -- A grace note of the next chord.
    local seq = D.sequence(sc, entry.staff, entry.voice)
    local here, nxt, before
    for i, it in ipairs(seq) do
      if it.ev == ev then here, nxt, before = it, seq[i + 1], seq[i - 1] end
    end
    if not (nxt and nxt.ev.kind == "chord") then return false end
    local len = here.e - here.s
    local grace = { id = D.id(sc, "e"), kind = "chord", grace = "acciaccatura", dur = { 1, 8 }, dots = 0, notes = ev.notes }
    ev.kind, ev.notes, ev.art, ev.arpeggio = "rest", nil, nil, nil
    local _, nentry, nk = D.find(sc, nxt.ev.id)
    table.insert(nentry.events, nk, grace)
    if before and before.ev.kind == "chord" and not before.ev.grace and before.e == here.s then
      local was = lift(sc, before.ev.id)
      drop(sc, was, before.s, before.e - before.s + len)
    else
      D.normalize(sc, mi, entry.staff, entry.voice)
    end
    D.touch(sc, mi)
    made = true
  end)
  return made
end

--- Break the beam before the chord under the cursor, or join it again.
function view:toggle_beam()
  local source = self:score_chord()
  if not source then return false end
  local broken = source.beam == "break"
  self:write(function(sc)
    local mi, _, _, _, ev = D.find(sc, source.id)
    if not ev then return false end
    ev.beam = (not broken) and "break" or nil
    D.touch(sc, mi)
  end)
  return not broken
end

--- The beat under the cursor in triplets (in 6/8, a duplet), in the voice
--- under the cursor (or the entry voice): its chords take the tuplet's
--- places in order, rests the places left. Or, on a tuplet, plain values
--- again: each chord where the nearest sixteenth puts it. Returns whether
--- the beat is a tuplet now.
function view:toggle_tuplet()
  if not self:editable() then return end
  local layout = self:layout()
  if not layout then return end
  local m = self:measure_at(self.beat, layout)
  local beats = model.score.beats_of({ start = m.start, num = m.meter.num, den = m.meter.den })
  local b
  for _, x in ipairs(beats) do
    if self.beat >= x.s - EPS and self.beat < x.e - EPS then b = x end
  end
  if not b then return end
  local ev = self:event_at(self.beat, self.step)
  local v = ev and ev.voice or self.voice or 1
  local staff_index = ev and ev.staff or self:staff_of_step(self.step, layout)
  local on
  self:write(function(sc)
    local staff = (sc.staves[staff_index] or sc.staves[1]).id
    local mi, a = where(sc, b.s)
    local blen = D.from_beats(b.len)
    local finish = a + blen
    local span = D.tuplet_at(sc, mi, staff, v, a)
    local chords = {}
    for _, it in ipairs(D.line(sc, mi, staff, v)) do
      if it.ev.kind == "chord" and not it.ev.grace and it.s < finish and it.e > a then
        if it.s < a or (it.e > finish and not (span and span.s == a)) then
          daw.notify("a note goes over the edge of the beat: shorten it first", "warn")
          return false
        end
        chords[#chords + 1] = it
      end
    end
    if #chords == 0 then
      daw.notify("no notes on this beat", "warn")
      return false
    end
    local function keep(it, extra)
      local out = { id = it.ev.id, kind = "chord", notes = it.ev.notes, art = it.ev.art, arpeggio = it.ev.arpeggio, beam = it.ev.beam }
      for _, n in ipairs(out.notes) do n.tie = nil end
      for k, x in pairs(extra) do out[k] = x end
      return out
    end
    if span and span.s == a then
      -- Plain again: each chord at the nearest sixteenth, in order.
      local step = D.Q / 4
      local places, last = {}, -1
      for i, it in ipairs(chords) do
        local p = math.max(last + 1, math.floor((it.s - a) / step + 0.5))
        places[i], last = p, p
      end
      D.splice(sc, mi, staff, v, span.s, span.e, nil)
      local units = math.floor(blen / step + 0.5)
      for i, it in ipairs(chords) do
        local p = math.min(places[i], units - 1)
        local q = places[i + 1] and math.min(places[i + 1], units) or units
        if q > p then
          D.put_chord(sc, mi, staff, v, a + p * step, (q - p) * step, it.ev.notes, { id = it.ev.id, art = it.ev.art, arpeggio = it.ev.arpeggio })
        end
      end
      on = false
    else
      local actual = b.compound and 2 or 3
      local normal = b.compound and 3 or 2
      if #chords > actual then
        daw.notify("more notes on the beat than the tuplet has places", "warn")
        return false
      end
      local value = blen / normal
      local tp = { id = D.id(sc, "t"), actual = actual, normal = normal }
      local evs = {}
      for k = 1, actual do
        local it = chords[k]
        evs[k] = it and keep(it, { dur = D.ratio(value), dots = 0, tuplet = tp })
          or { id = D.id(sc, "e"), kind = "rest", dur = D.ratio(value), dots = 0, tuplet = tp }
      end
      D.splice(sc, mi, staff, v, a, finish, evs)
      on = true
    end
    D.fix_ties(sc, staff, v, math.max(1, mi - 1), mi)
  end)
  return on
end

--- Respell the note under the cursor: the next letter that can name its pitch (G sharp, A flat).
function view:respell()
  return self:change(function(sc, note)
    local pitch = D.pitch(note)
    local options = {}
    for letter = 0, 6 do
      for alter = -2, 2 do
        local sp = model.spelled(letter, alter, pitch)
        if model.pitch_of(sp.step, alter) == pitch then options[#options + 1] = sp end
      end
    end
    table.sort(options, function(a, b)
      if math.abs(a.alter) ~= math.abs(b.alter) then return math.abs(a.alter) < math.abs(b.alter) end
      return a.step < b.step
    end)
    local pick = options[1]
    for i, sp in ipairs(options) do
      if sp.letter == note.step and sp.alter == note.alter then pick = options[i % #options + 1] end
    end
    respell(sc, note, pick)
    self.step = pick.step
  end)
end

--- A semitone up (1) or down (-1), written as a sharp or a flat of the
--- same letter where that reads naturally.
function view:inflect(dir)
  local fifths = view.key()
  return self:change(function(sc, note)
    local pitch = util.clamp(D.pitch(note) + dir, 0, 127)
    local alter = note.alter + dir
    local sp = math.abs(alter) <= 1 and model.spelled(note.step, alter, pitch) or model.spell(pitch, fifths)
    respell(sc, note, sp)
    self.step = sp.step
  end)
end

--- Up or down by lines and spaces, in the key.
function view:transpose_steps(steps)
  local fifths = view.key()
  return self:change(function(sc, note)
    local step = D.diatonic(note) + steps
    local pitch = model.key_pitch(step, fifths)
    if pitch < 0 or pitch > 127 then return false end
    respell(sc, note, model.spelled(step % 7, model.key_alter(step % 7, fifths), pitch))
    self.step = step
  end)
end

--- Up or down octaves, spelled as before.
function view:transpose_octaves(octaves)
  return self:change(function(sc, note)
    local pitch = D.pitch(note) + 12 * octaves
    if pitch < 0 or pitch > 127 then return false end
    local step = D.diatonic(note) + 7 * octaves
    respell(sc, note, model.spelled(note.step, note.alter, pitch))
    self.step = step
  end)
end

--- Delete the note under the cursor (and what its tie joins); a chord left
--- with none is a rest.
function view:delete()
  local _, n = self:here()
  if not n then return false end
  local id = n.head or n.id
  return self:write(function(sc)
    local note, _, _, entry = D.find_note(sc, id)
    if not note then return false end
    for _, c in ipairs(D.tied_on(sc, entry.staff, entry.voice, id)) do D.remove_note(sc, c.note.id) end
    D.remove_note(sc, id)
  end) ~= false
end

--- The voice notes are entered in from the cursor: the voice of the note
--- under it, or else the one chosen.
function view:cursor_voice()
  local ev, n = self:event_at(self.beat, self.step)
  return (ev and n and ev.voice) or self.voice or 1
end

--- Transpose the notes of chords of the score (by event id) by semitones,
--- respelled by the key, or with `steps` by steps of the key. Returns how
--- many notes moved.
function view:transpose_events(ids, by, steps)
  local fifths = view.key()
  local count = 0
  if #ids == 0 then return 0 end
  self:write(function(sc)
    for _, id in ipairs(ids) do
      local _, _, _, _, ev = D.find(sc, id)
      for _, note in ipairs(ev and ev.notes or {}) do
        if not note.tied then
          local sp
          if steps then
            local step = D.diatonic(note) + by
            sp = model.spelled(step % 7, model.key_alter(step % 7, fifths), model.key_pitch(step, fifths))
          else
            sp = model.spell(D.pitch(note) + by, fifths)
          end
          if sp.pitch >= 0 and sp.pitch <= 127 then
            respell(sc, note, sp)
            count = count + 1
          end
        end
      end
    end
    return count > 0
  end)
  return count
end

--- Add a note of the chosen value at the cursor, or take away the one there.
function view:toggle_note()
  local clip = self:clip()
  if not clip then return end
  if self:delete() then return end
  local fifths = view.key()
  local pitch = model.key_pitch(self.step, fifths)
  self:place(pitch, self.beat, self:entry_length(), false)
  self:audition(pitch)
end

--- Chords of the score (by id, the first first) made one: the first takes
--- the others' notes, and where they were is silence. Returns how many
--- notes the chord has.
function view:merge_chords(ids)
  if #ids < 2 then return nil end
  local count
  self:write(function(sc)
    local notes = {}
    for k = 2, #ids do
      local was = lift(sc, ids[k])
      for _, n in ipairs(was and was.notes or {}) do notes[#notes + 1] = n end
    end
    for _, n in ipairs(notes) do join_chord(sc, ids[1], { id = n.id, step = n.step, alter = n.alter, octave = n.octave }) end
    local _, _, _, _, ev = D.find(sc, ids[1])
    count = ev and #ev.notes
  end)
  return count
end

-- Insert mode -----------------------------------------------------------------------------

local LETTER_STEP = { c = 0, d = 1, e = 2, f = 3, g = 4, a = 5, b = 6 }

--- Enter a note by its letter at the cursor, in the octave nearest the
--- note before it, as the key alters it; then step on, or stay for a chord.
function view:enter(letter, advance)
  local clip = self:clip()
  if not clip then return end
  local fifths = view.key()
  local from = self.last and self.last.step or self.step
  local l = LETTER_STEP[letter]
  local step = math.floor(from / 7) * 7 + l
  if step - from > 3 then step = step - 7 elseif from - step > 3 then step = step + 7 end
  local pitch = model.key_pitch(step, fifths)
  local building = self.chord and math.abs(self.chord.beat - self.beat) < EPS
  if not building then self.chord = { beat = self.beat, pitches = {} } end
  self.chord.pitches[pitch] = true
  local id = self:place(pitch, self.beat, self:entry_length(), building)
  if not id then return end
  self:audition(pitch)
  self.last = { id = id, step = step, pitch = pitch, beat = self.beat }
  self.step = step
  self:remember_chord()
  if advance then
    self.chord = nil
    self:step_on(1)
  else
    api.ui_redraw()
  end
end

--- Keep the chord being entered, for `R` to enter again.
function view:remember_chord()
  if not self.chord then return end
  local pitches = {}
  for p in pairs(self.chord.pitches) do pitches[#pitches + 1] = p end
  table.sort(pitches)
  self.again = { pitches = pitches, step = self.last and self.last.step }
end

--- Add a note an interval above the note just entered, in the key, to its
--- chord: `interval` 2 a second, 3 a third ... 8 an octave.
function view:add_interval(interval)
  local clip = self:clip()
  local last = self.last
  if not (clip and last) then return end
  local fifths = view.key()
  local step = last.step + interval - 1
  local pitch = model.key_pitch(step, fifths)
  if pitch > 127 then return daw.notify("no note that high", "warn") end
  if not (self.chord and math.abs(self.chord.beat - last.beat) < EPS) then self.chord = { beat = last.beat, pitches = { [last.pitch] = true } } end
  self.chord.pitches[pitch] = true
  local id = self:place(pitch, last.beat, self:entry_length(), true)
  self:audition(pitch)
  self.last = { id = id, step = step, pitch = pitch, beat = last.beat }
  self:remember_chord()
  api.ui_redraw()
end

--- Enter the chord entered last again at the cursor, and step on.
function view:repeat_chord()
  local again = self.again
  if not (again and #again.pitches > 0) then return daw.notify("nothing entered yet to repeat", "warn") end
  local id
  self:write(function(sc)
    for k, p in ipairs(again.pitches) do id = self:put(sc, spelled(p), self.beat, self:entry_length(), k > 1) end
  end)
  self.last = { id = id and view.now_id(id), step = again.step or self.step, pitch = again.pitches[#again.pitches], beat = self.beat }
  self.chord = nil
  self:step_on(1)
end

--- Hold the chord just entered on by the chosen value, tied to a chord of
--- the same notes after it (over the barline if need be), and step on.
function view:tie_last()
  local last = self.last
  if not (self:clip() and last and last.id) then return end
  local finish
  self:write(function(sc)
    local note, ev, _, entry = D.find_note(sc, last.id)
    if not note then return false end
    local links = chain(sc, ev.id)
    local tail = links[#links]
    local f = D.frame(sc)
    local t = f.starts[tail.mi] + tail.at + D.length(tail.ev)
    local len = D.from_beats(self:entry_length())
    local mi, at = D.locate(sc, t)
    local notes = {}
    for i, n in ipairs(tail.ev.notes) do notes[i] = { step = n.step, alter = n.alter, octave = n.octave } end
    D.put_chord(sc, mi, entry.staff, entry.voice, at, len, notes)
    for _, n in ipairs(tail.ev.notes) do n.tie = true end
    D.touch(sc, tail.mi)
    D.fix_ties(sc, entry.staff, entry.voice, tail.mi, mi)
    finish = (D.origin(sc) + t + len) / D.Q
  end)
  if not finish then return end
  self.chord = nil
  self:set(nil, finish)
end

--- Move by the chosen value, growing the clip when it runs out.
function view:step_on(n)
  local clip = self:clip()
  if not clip then return end
  local to = math.max(0, self.beat + n * self:entry_length())
  self:grow(clip, to + (n > 0 and EPS or 0))
  self:set(nil, to)
end

--- A rest of the chosen value at the cursor, then on.
function view:enter_rest()
  self:rest(self.beat, self:entry_length(), self:staff_of_step(self.step), self.voice)
  self.chord = nil
  self:step_on(1)
end

--- Change the last note entered: `fn(note)` gives its new spelling.
function view:change_last(fn)
  local last = self.last
  if not (self:clip() and last and last.id) then return end
  local pitch
  self:write(function(sc)
    local note = D.find_note(sc, last.id)
    if not note then return false end
    local sp = fn(note)
    if not sp then return false end
    respell(sc, note, sp)
    pitch = sp.pitch
  end)
  if not pitch then return end
  if self.chord then
    self.chord.pitches[last.pitch] = nil
    self.chord.pitches[pitch] = true
  end
  last.pitch = pitch
  self:audition(pitch)
end

--- Sharpen (1) or flatten (-1) the note just entered.
function view:inflect_last(dir)
  local fifths = view.key()
  self:change_last(function(note)
    local pitch = util.clamp(D.pitch(note) + dir, 0, 127)
    local alter = note.alter + dir
    return math.abs(alter) <= 1 and model.spelled(note.step, alter, pitch) or model.spell(pitch, fifths)
  end)
end

--- An octave up (1) or down (-1) for the note just entered.
function view:octave_last(dir)
  self:change_last(function(note)
    local pitch = D.pitch(note) + 12 * dir
    if pitch < 0 or pitch > 127 then return nil end
    return model.spelled(note.step, note.alter, pitch)
  end)
  if self.last then
    self.last.step = self.last.step + 7 * dir
    self.step = self.step + 7 * dir
  end
end

--- Step back and remove what starts there in the entry voice of the cursor's staff.
function view:backspace()
  local clip = self:clip()
  if not clip or self.beat <= 0 then return end
  self:step_on(-1)
  local staff_index = self:staff_of_step(self.step)
  self:write(function(sc)
    local mi, at = where(sc, self.beat)
    local staff = (sc.staves[staff_index] or sc.staves[1]).id
    local ev = chord_at(sc, mi, staff, self.voice or 1, at)
    if not ev then return false end
    lift(sc, ev.id)
  end)
  self.chord, self.last = nil, nil
end

--- Choose the value for entering notes: 4 a whole note, 1 a quarter.
function view:choose(value)
  self.value = value
  api.ui_redraw()
end

-- Opening ---------------------------------------------------------------------------------

--- Open a MIDI clip as notation, in the terminal and in a window.
function view:edit(clip)
  if type(clip) == "number" then clip = daw.clip(clip) end
  if not clip then return daw.notify("no clip here", "warn") end
  if clip.kind ~= "midi" then return daw.notify("only MIDI clips can be shown as notation", "warn") end
  self.clip_id, self.beat, self.first, self.chord, self.last, self.cache, self.multi = clip.id, 0, 1, nil, nil, nil, nil
  self.triplets, self.tuplet, self.again, self.push, self.repitch, self.grace, self.pending_grace = false, nil, nil, nil, nil, nil, nil
  local layout = self:layout()
  local first = model.events(layout)[1]
  self.step = 35
  for _, ev in ipairs(model.events(layout)) do
    if ev.notes then
      first = ev
      break
    end
  end
  if first and first.notes then self.step = first.notes[#first.notes].step end
  if first then self.beat = math.max(0, first.notes and first.start or 0) end
  daw.ui.focus("notation")
  if daw.canvas then daw.canvas.open("notation", { title = "Notation", width = 1100, height = 560 }) end
end

--- The clip to open: the piano roll's when it has the keyboard, else the
--- one under the arrange cursor.
function view.target()
  local focused = daw.ui.focused
  if focused == "pianoroll" then
    local c = daw.ui.views.pianoroll:clip()
    if c then return c end
  end
  if focused == "notation" and view:clip() then return view:clip() end
  return daw.cursor.clip()
end

return view
