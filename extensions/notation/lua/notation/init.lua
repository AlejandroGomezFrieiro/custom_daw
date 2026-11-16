-- The notation view's state and what it does to a clip: the cursor, the
-- value chosen for entering notes, and every edit, made through the clip's
-- per-note calls so that the piano roll, undo and everything else agree.
-- Drawing is in notation.tui (cells) and notation.gui (pixels); keys are in
-- notation.keys.
local api = daw.api
local util = daw.util
local model = require("notation.model")
local score = require("notation.score")

local EPS = 1e-6

daw.option.define("notation_grid", 0.25)   -- the smallest value written, in beats

local view = {
  clip_id = nil,
  beat = 0,          -- the cursor, in beats from the start of the clip
  step = 35,         -- the cursor's staff position, as a diatonic step (C4 is 35)
  value = 1,         -- the value chosen for entering notes: 4 whole ... 0.125 32nd
  dot = false,       -- and whether it is dotted
  first = 1,         -- the first measure on screen
  chord = nil,       -- notes entered at one place in insert mode: { beat, pitches }
  last = nil,        -- the last note entered in insert mode: { pitch, beat }
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

--- The options a clip is laid out with.
function view.layout_opts(c)
  local fifths = view.key()
  local own = view.own(c)
  return {
    length = c.length, offset = c.start, bars = view.bars(c.start, c.length), fifths = fifths,
    clef = view.track_clef(c.track), grid = daw.opt.notation_grid, tempo = view.tempo_at(c.start),
    settings = view.settings_of(c), tuplets = own.tuplets,
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
  local clip = self:clip()
  if not clip then return nil end
  local c = clip:get()
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
  local stamp = table.concat({ c.id, tostring(c.stamp), c.length, c.start, opts.fifths, opts.tempo, tostring(opts.clef),
    serial(view.own(c)), daw.opt.notation_grid, serial(opts.bars) }, ":")
  if self.cache and self.cache.stamp == stamp then return self.cache.layout, self.cache.notes end
  local notes = clip:notes()
  local layout = view.decorate(model.layout(notes, opts), clip)
  self.cache = { stamp = stamp, layout = layout, notes = notes }
  return layout, notes
end

-- The cursor ------------------------------------------------------------------------------

--- The value chosen, in beats, with its dot, and as a triplet when
--- entering in triplets.
function view:entry_length()
  return self.value * (self.dot and 1.5 or 1) * (self.triplets and 2 / 3 or 1)
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

-- Editing ---------------------------------------------------------------------------------

--- How a note at a pitch is spelled for its meta: kept with the note so a
--- sharpened note stays a sharp. Only read back while the pitch matches.
local function spelling_meta(meta, sp)
  local out = util.merge(meta or {}, {})
  out.notation = { letter = sp.letter, alter = sp.alter, pitch = sp.pitch }
  return out
end

--- Make room for the clip to reach `finish`, a bar at a time.
function view:grow(clip, finish)
  if finish > clip.length + EPS then
    local bar = daw.time.bar()
    clip.length = math.ceil((clip.start + finish - EPS) / bar) * bar - clip.start
  end
end

--- The score's chords on a staff: each `{ start, length, voice, notes }`,
--- with `notes` the places of the clip's notes it stands for.
function view:chords(staff, layout)
  layout = layout or self:layout()
  local out = {}
  if not layout then return out end
  for _, ev in ipairs(layout.score.events) do
    if not staff or ev.staff == staff then out[#out + 1] = ev end
  end
  return out
end

--- How loud a note put in at `beat` is: as loud as what is played around it.
function view:velocity_near(beat)
  local clip = self:clip()
  local sum, count = 0, 0
  for _, n in ipairs(clip and clip:notes({ from = beat - 2, to = beat + 2 }) or {}) do
    sum, count = sum + n.velocity, count + 1
  end
  if count == 0 then return daw.opt.velocity end
  return math.floor(sum / count + 0.5)
end

--- Put a note in as it is written, `length` long from `beat`, the way
--- notation programs do: on its staff, what is written as starting in that
--- stretch goes, and a chord still sounding when it starts is cut to end
--- there. `keep` is a set of pitches written at `beat` that stay (a chord
--- being built). `spell` is how to write it. The note goes in exactly on
--- the grid, as loud as the notes around it. Returns the note's place.
function view:place(pitch, beat, length, keep, spell)
  local clip = self:clip()
  if not clip then return end
  pitch = util.clamp(pitch, 0, 127)
  self:grow(clip, beat + length)
  local layout = self:layout()
  local staff = self:staff_of_pitch(pitch, layout)
  local notes = clip:notes()
  local remove, set = {}, {}
  for _, ev in ipairs(self:chords(staff, layout)) do
    local here = math.abs(ev.start - beat) < EPS
    if ev.start >= beat - EPS and ev.start < beat + length - EPS then
      for _, n in ipairs(ev.notes) do
        if not (here and keep and keep[n.pitch] and n.pitch ~= pitch) then remove[#remove + 1] = n.index end
      end
      for _, g in ipairs(ev.grace or {}) do remove[#remove + 1] = g.index end
    elseif ev.start < beat - EPS and ev.start + ev.length > beat + EPS then
      for _, n in ipairs(ev.notes) do
        local played = notes[n.index]
        if played.start + played.length > beat then set[#set + 1] = { index = n.index, length = math.max(0.01, beat - played.start) } end
      end
    end
  end
  local note = { pitch = pitch, start = beat, length = length, velocity = self:velocity_near(beat) }
  if spell then note.meta = spelling_meta(nil, spell) end
  clip:edit_notes({ remove = remove, set = set, add = { note } })
  daw.ui.poke()
  -- Where it is now among the clip's notes.
  local _, at = clip:notes({ from = beat - EPS, to = beat + EPS, low = pitch, high = pitch })
  return at[1]
end

--- Clear a stretch of one staff: a rest written there.
function view:rest(beat, length, staff)
  local clip = self:clip()
  if not clip then return end
  self:grow(clip, beat + length)
  local layout = self:layout()
  local notes = clip:notes()
  local remove, set = {}, {}
  for _, ev in ipairs(self:chords(staff, layout)) do
    if ev.start >= beat - EPS and ev.start < beat + length - EPS then
      for _, n in ipairs(ev.notes) do remove[#remove + 1] = n.index end
      for _, g in ipairs(ev.grace or {}) do remove[#remove + 1] = g.index end
    elseif ev.start < beat - EPS and ev.start + ev.length > beat + EPS then
      for _, n in ipairs(ev.notes) do
        local played = notes[n.index]
        if played.start + played.length > beat then set[#set + 1] = { index = n.index, length = math.max(0.01, beat - played.start) } end
      end
    end
  end
  if #remove > 0 or #set > 0 then clip:edit_notes({ remove = remove, set = set }) end
end

--- Change the note under the cursor with `fn(note, written)`, where `note`
--- is a copy to change. Returns whether there was one.
function view:change(fn)
  local clip = self:clip()
  local note, index, written = self:note()
  if not note then return false end
  local copy = util.merge(note, {})
  fn(copy, written)
  clip:set_note(index, { start = copy.start, length = copy.length, pitch = util.clamp(copy.pitch, 0, 127), velocity = copy.velocity, meta = copy.meta or {} })
  daw.ui.poke()
  return true
end

--- The score's chord under the cursor: the score event, and the written
--- event (the piece of it) the cursor is on.
function view:score_chord()
  local ev, written = self:event_at(self.beat, self.step)
  if ev and ev.source then return ev.source, ev, written end
end

--- The written span of a score event, ties included.
function view:span_of(source)
  return source.start, source.start + source.length
end

--- Change the written length of the chord under the cursor with
--- `fn(written length)`: the played lengths are scaled by as much, so a
--- note played detached stays detached. What it now reaches over on its
--- staff and voice gives way.
function view:relength(fn)
  local clip = self:clip()
  local source = self:score_chord()
  if not (clip and source) then return false end
  local old = source.length
  local length = math.max(daw.opt.notation_grid / 2, fn(old))
  local factor = length / old
  self:grow(clip, source.start + length)
  local notes = clip:notes()
  local set, remove, mine = {}, {}, {}
  for _, n in ipairs(source.notes) do
    mine[n.index] = true
    local played = notes[n.index]
    local exact = model.score.exact(played.start) and model.score.exact(played.start + played.length) and math.abs(n.offset) < EPS
    set[#set + 1] = { index = n.index, length = exact and length or math.max(0.01, played.length * factor) }
  end
  for _, ev in ipairs(self:chords(source.staff)) do
    if ev ~= source and ev.voice == source.voice and ev.start > source.start + EPS and ev.start < source.start + length - EPS then
      for _, n in ipairs(ev.notes) do
        if not mine[n.index] then remove[#remove + 1] = n.index end
      end
    end
  end
  clip:edit_notes({ set = set, remove = remove })
  self.beat = math.max(0, source.start)
  daw.ui.poke()
  return true
end

function view:lengthen(by) return self:relength(function(l) return l + by end) end

--- Lengthen (or with `by` below 0, shorten) every chord whose notes were
--- played in a region by `by` written beats, scaling the played lengths.
function view:relength_region(region, by)
  local clip = self:clip()
  local layout = self:layout()
  if not (clip and layout) then return end
  local notes = clip:notes()
  local set = {}
  for _, ev in ipairs(layout.score.events) do
    local first = notes[ev.notes[1].index]
    local inside = region.kind == "line" or (first.start >= region.c0 - 0.1 and first.start < region.c1)
    if inside then
      local length = math.max(daw.opt.notation_grid / 2, ev.length + by)
      for _, n in ipairs(ev.notes) do
        if region.kind ~= "block" or (n.pitch >= region.r0 and n.pitch <= region.r1) then
          set[#set + 1] = { index = n.index, length = math.max(0.01, notes[n.index].length * length / ev.length) }
        end
      end
    end
  end
  if #set > 0 then clip:edit_notes({ set = set }) end
end

--- Add or take away the dot of the chord under the cursor.
function view:toggle_dot()
  return self:relength(function(l)
    local base, dots = model.value_of(l)
    if base and dots > 0 then return base end
    return l * 1.5
  end)
end

--- Move the chord under the cursor by `by` beats as written: its played
--- notes (and grace notes) move by as much, keeping how they were strummed
--- and how loud.
function view:move_chord(by)
  local clip = self:clip()
  local source = self:score_chord()
  if not (clip and source) then return false end
  if source.start + by < -EPS then by = -source.start end
  local notes = clip:notes()
  local set = {}
  local function shift(list)
    for _, n in ipairs(list or {}) do
      local played = notes[n.index]
      set[#set + 1] = { index = n.index, start = math.max(0, played.start + by) }
    end
  end
  shift(source.notes)
  shift(source.grace)
  self:grow(clip, source.start + by + source.length)
  clip:edit_notes({ set = set })
  self.beat = math.max(0, self.beat + by)
  daw.ui.poke()
  return true
end

--- Delete the chord under the cursor: every note it stands for.
function view:delete_chord()
  local clip = self:clip()
  local source = self:score_chord()
  if not (clip and source) then return false end
  local remove = {}
  for _, n in ipairs(source.notes) do remove[#remove + 1] = n.index end
  for _, n in ipairs(source.grace or {}) do remove[#remove + 1] = n.index end
  clip:edit_notes({ remove = remove })
  return true
end

--- Make the played notes of a stretch of the clip exactly what is written:
--- each note starts at its written place and lasts its written length
--- (ties included). Grace notes are left as played. `from`, `to` in clip
--- beats; `low`, `high` pitches; all optional.
function view:quantize(from, to, low, high)
  local clip = self:clip()
  local layout = self:layout()
  if not (clip and layout) then return 0 end
  local set = {}
  local notes = clip:notes()
  for _, ev in ipairs(layout.score.events) do
    for _, n in ipairs(ev.notes) do
      local at = notes[n.index].start
      local inside = (not from or at >= from - EPS or ev.start >= from - EPS) and (not to or at < to - EPS)
      if inside and (not low or n.pitch >= low) and (not high or n.pitch <= high) then
        set[#set + 1] = { index = n.index, start = math.max(0, ev.start), length = ev.length }
      end
    end
  end
  if #set > 0 then clip:edit_notes({ set = set }) end
  return #set
end

--- What the user has said about notes: `fn(own, note)` changes a copy of
--- each note's `meta.notation`, kept with the note. One edit.
function view:override(indices, fn)
  local clip = self:clip()
  if not clip then return end
  local notes = clip:notes()
  local set = {}
  for _, index in ipairs(indices) do
    local note = notes[index]
    if note then
      local meta = util.merge(note.meta or {}, {})
      local own = type(meta.notation) == "table" and util.merge(meta.notation, {}) or {}
      fn(own, note)
      meta.notation = next(own) and own or nil
      set[#set + 1] = { index = index, meta = meta }
    end
  end
  if #set > 0 then clip:edit_notes({ set = set }) end
  daw.ui.poke()
end

--- The places of the notes of the chord under the cursor.
function view:chord_indices(with_grace)
  local source = self:score_chord()
  local out = {}
  if not source then return out end
  for _, n in ipairs(source.notes) do out[#out + 1] = n.index end
  if with_grace then
    for _, n in ipairs(source.grace or {}) do out[#out + 1] = n.index end
  end
  return out
end

--- The note under the cursor (or the chord, when the cursor is on none of
--- its notes) into the other voice of its staff.
function view:toggle_voice()
  local source = self:score_chord()
  if not source then return false end
  local to = source.voice == 2 and 1 or 2
  local _, index = self:note()
  self:override(index and { index } or self:chord_indices(true), function(own) own.voice = to end)
  return to
end

--- The chord under the cursor's notes onto the other staff of a grand staff.
function view:toggle_staff()
  local source = self:score_chord()
  local layout = self:layout()
  if not (source and #layout.staves == 2) then return false end
  local to = source.staff == 1 and 2 or 1
  self:override(self:chord_indices(true), function(own) own.staff = to end)
  return to
end

--- The chord under the cursor rolled up, down, or not marked.
function view:cycle_strum()
  local source = self:score_chord()
  if not source then return false end
  local next_mark = ({ [1] = "down", [-1] = "none" })[source.arpeggio or 0] or "up"
  if not source.arpeggio then
    -- Not marked now: was it marked off by the user?
    local clip = self:clip()
    local n = clip:notes()[source.notes[1].index]
    if n.meta and type(n.meta.notation) == "table" and n.meta.notation.strum == "none" then next_mark = nil end
  end
  self:override(self:chord_indices(), function(own) own.strum = next_mark end)
  return next_mark
end

--- The note under the cursor a grace note, or not.
function view:toggle_grace()
  local clip = self:clip()
  local note, index = self:note()
  local layout = self:layout()
  if not clip then return false end
  -- A grace note is under no cursor of its own: look for one before the chord.
  local source = self:score_chord()
  if source and source.grace then
    self:override({ source.grace[#source.grace].index }, function(own) own.grace = false end)
    return false
  end
  if not note then return false end
  self:override({ index }, function(own) own.grace = true end)
  return true
end

--- Break the beam before the chord under the cursor, or join it again.
function view:toggle_beam()
  local source = self:score_chord()
  if not source then return false end
  local clip = self:clip()
  local first = clip:notes()[source.notes[1].index]
  local broken = first.meta and type(first.meta.notation) == "table" and first.meta.notation.beam == "break"
  self:override(self:chord_indices(), function(own) own.beam = (not broken) and "break" or nil end)
  return not broken
end

--- The beat under the cursor in triplets (in 6/8, a duplet), or not.
function view:toggle_tuplet()
  local clip = self:clip()
  local layout = self:layout()
  if not (clip and layout) then return end
  local m = self:measure_at(self.beat, layout)
  local beats = model.score.beats_of({ start = m.start, num = m.meter.num, den = m.meter.den })
  local b
  for _, x in ipairs(beats) do
    if self.beat >= x.s - EPS and self.beat < x.e - EPS then b = x end
  end
  if not b then return end
  local on
  view.keep(clip, function(own)
    local list, found = {}, false
    for _, tp in ipairs(own.tuplets or {}) do
      if math.abs(tp.start - b.s) < EPS then found = true else list[#list + 1] = tp end
    end
    if not found then list[#list + 1] = { start = b.s, length = b.len, n = b.compound and 2 or 3 } end
    own.tuplets = #list > 0 and list or nil
    on = not found
  end)
  return on
end

--- Respell the note under the cursor: the next letter that can name its
--- pitch (G sharp, A flat), kept with the note.
function view:respell()
  return self:change(function(n, written)
    local options = {}
    for letter = 0, 6 do
      for alter = -2, 2 do
        local sp = model.spelled(letter, alter, n.pitch)
        if model.pitch_of(sp.step, alter) == n.pitch then options[#options + 1] = sp end
      end
    end
    table.sort(options, function(a, b)
      if math.abs(a.alter) ~= math.abs(b.alter) then return math.abs(a.alter) < math.abs(b.alter) end
      return a.step < b.step
    end)
    local pick = options[1]
    for i, sp in ipairs(options) do
      if sp.step == written.step and sp.alter == written.alter then pick = options[i % #options + 1] end
    end
    n.meta = spelling_meta(n.meta, pick)
    self.step = pick.step
  end)
end

--- Forget what the user said about the notes in a stretch (voices, hands,
--- graces, strums, beams), so the score follows the playing again. The
--- performance is left as it is; spellings stay.
function view:retranscribe(from, to, low, high)
  local clip = self:clip()
  if not clip then return 0 end
  local idx = {}
  for i, n in ipairs(clip:notes()) do
    if (not from or n.start >= from - 0.25) and (not to or n.start < to) and (not low or n.pitch >= low) and (not high or n.pitch <= high)
      and n.meta and type(n.meta.notation) == "table" then
      idx[#idx + 1] = i
    end
  end
  self:override(idx, function(own)
    for _, k in ipairs({ "voice", "staff", "grace", "strum", "chord", "beam" }) do own[k] = nil end
  end)
  if not from then view.keep(clip, function(own) own.tuplets = nil end) end
  return #idx
end

--- A semitone up (1) or down (-1), written as a sharp or a flat of the
--- same letter where that reads naturally.
function view:inflect(dir)
  local fifths = view.key()
  return self:change(function(n, written)
    n.pitch = n.pitch + dir
    local alter = written.alter + dir
    local sp = (math.abs(alter) <= 1) and model.spelled(written.letter, alter, n.pitch) or model.spell(n.pitch, fifths)
    n.meta = spelling_meta(n.meta, sp)
    self.step = sp.step
  end)
end

--- Up or down by lines and spaces, in the key.
function view:transpose_steps(steps)
  local fifths = view.key()
  return self:change(function(n, written)
    local step = written.step + steps
    n.pitch = model.key_pitch(step, fifths)
    if n.meta then n.meta.notation = nil end
    self.step = step
  end)
end

--- Up or down octaves, spelled as before.
function view:transpose_octaves(octaves)
  return self:change(function(n, written)
    n.pitch = n.pitch + 12 * octaves
    n.meta = spelling_meta(n.meta, model.spelled(written.letter, written.alter, n.pitch))
    self.step = written.step + 7 * octaves
  end)
end

function view:delete()
  local clip = self:clip()
  local note, index = self:note()
  if not note then return false end
  clip:remove_note(index)
  return true
end

--- Add a note of the chosen value at the cursor, or take away the one there.
function view:toggle_note()
  local clip = self:clip()
  if not clip then return end
  if self:delete() then return end
  local fifths = view.key()
  local pitch = model.key_pitch(self.step, fifths)
  self:place(pitch, self.beat, self:entry_length(), { [pitch] = true })
  self:audition(pitch)
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
  -- A chord being built keeps what was entered at this place already.
  if not (self.chord and math.abs(self.chord.beat - self.beat) < EPS) then self.chord = { beat = self.beat, pitches = {} } end
  self.chord.pitches[pitch] = true
  self:place(pitch, self.beat, self:entry_length(), self.chord.pitches)
  self:audition(pitch)
  self.last = { step = step, pitch = pitch, beat = self.beat }
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
  if not (self.chord and math.abs(self.chord.beat - last.beat) < EPS) then self.chord = { beat = last.beat, pitches = { [last.pitch] = true } } end
  self.chord.pitches[pitch] = true
  self:place(pitch, last.beat, self:entry_length(), self.chord.pitches)
  self:audition(pitch)
  self.last = { step = step, pitch = pitch, beat = last.beat }
  self:remember_chord()
  api.ui_redraw()
end

--- Enter the chord entered last again at the cursor, and step on.
function view:repeat_chord()
  local again = self.again
  if not (again and #again.pitches > 0) then return daw.notify("nothing entered yet to repeat", "warn") end
  local keep = {}
  for _, p in ipairs(again.pitches) do keep[p] = true end
  for _, p in ipairs(again.pitches) do self:place(p, self.beat, self:entry_length(), keep) end
  self.last = { step = again.step or self.step, pitch = again.pitches[#again.pitches], beat = self.beat }
  self.chord = nil
  self:step_on(1)
end

--- Hold the note just entered on by the chosen value (a tie where it
--- crosses a beat or a barline), and step on.
function view:tie_last()
  local clip = self:clip()
  local last = self.last
  if not (clip and last) then return end
  local notes, at = clip:notes({ from = last.beat - EPS, to = last.beat + EPS })
  local set = {}
  local finish
  for i, n in ipairs(notes) do
    if math.abs(n.start - last.beat) < EPS and (not self.chord or self.chord.pitches[n.pitch] or n.pitch == last.pitch) then
      finish = n.start + n.length + self:entry_length()
      set[#set + 1] = { index = at[i], length = n.length + self:entry_length() }
    end
  end
  if #set == 0 then return end
  self:grow(clip, finish)
  clip:edit_notes({ set = set })
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
  self:rest(self.beat, self:entry_length(), self:staff_of_step(self.step))
  self.chord = nil
  self:step_on(1)
end

--- Change the last note entered: `fn(note)` on a copy.
function view:change_last(fn)
  local clip = self:clip()
  local last = self.last
  if not (clip and last) then return end
  local notes, at = clip:notes({ from = last.beat - EPS, to = last.beat + EPS, low = last.pitch, high = last.pitch })
  if not notes[1] then return end
  local n = util.merge(notes[1], {})
  fn(n)
  clip:set_note(at[1], { pitch = util.clamp(n.pitch, 0, 127), meta = n.meta or {} })
  if self.chord then
    self.chord.pitches[last.pitch] = nil
    self.chord.pitches[n.pitch] = true
  end
  last.pitch = n.pitch
  self:audition(n.pitch)
end

--- Sharpen (1) or flatten (-1) the note just entered.
function view:inflect_last(dir)
  local fifths = view.key()
  self:change_last(function(n)
    local sp = model.spell(n.pitch, fifths)
    local want = n.meta and n.meta.notation
    if type(want) == "table" and want.pitch == n.pitch then sp = model.spelled(want.letter, want.alter, n.pitch) end
    n.pitch = n.pitch + dir
    local alter = sp.alter + dir
    n.meta = spelling_meta(n.meta, math.abs(alter) <= 1 and model.spelled(sp.letter, alter, n.pitch) or model.spell(n.pitch, fifths))
  end)
end

--- An octave up (1) or down (-1) for the note just entered.
function view:octave_last(dir)
  self:change_last(function(n)
    n.pitch = n.pitch + 12 * dir
    local want = n.meta and n.meta.notation
    if type(want) == "table" then want.pitch = n.pitch end
  end)
  if self.last then
    self.last.step = self.last.step + 7 * dir
    self.step = self.step + 7 * dir
  end
end

--- Step back and remove what starts there on the cursor's staff.
function view:backspace()
  local clip = self:clip()
  if not clip or self.beat <= 0 then return end
  self:step_on(-1)
  local layout = self:layout()
  local staff = self:staff_of_step(self.step, layout)
  local remove = {}
  for index, n in ipairs(clip:notes()) do
    if math.abs(n.start - self.beat) < EPS and self:staff_of_pitch(n.pitch, layout) == staff then remove[#remove + 1] = index end
  end
  if #remove > 0 then clip:edit_notes({ remove = remove }) end
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
  self.triplets, self.again = false, nil
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
