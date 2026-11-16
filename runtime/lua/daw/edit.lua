-- Editing by region: what the operators of the arrange view and the piano
-- roll do. A region comes from `daw.keymap` (a motion, a text object or a
-- visual selection) and has rows `r0` to `r1`, beats `c0` up to `c1`, and a
-- `kind`. Everything here is plain calls on `daw.api`, for use from
-- extensions and scripts as much as from key mappings.
--
-- In the arrange view rows are positions in the track list. "line" regions
-- are whole tracks; the other kinds are a stretch of time on some tracks,
-- and clips reaching across its ends are cut there. A region with `clips`
-- (a set of clip ids, from clips chosen with the pointer) is about those
-- clips alone, whole, and nothing else in its stretch.
--
-- In the piano roll rows are pitches and beats count from the start of the
-- clip. A "char" region is a stretch of time at every pitch, a "block" one
-- only between two pitches, a "line" one whole pitches. Notes belong to the
-- region they start in, and are never cut. Where the roll edits several
-- clips at once, `yank`, `delete`, `each` and `paste` take the list of them
-- (`daw.roll_clips.parts()`: `{ clip, offset }` each, beats counting from
-- the start of the first) in place of one clip; every note stays in its own.
local api = daw.api
local util = daw.util
local EPS = 1e-9

local A, R = {}, {}
local M = { arrange = A, roll = R }

-- Arrange ---------------------------------------------------------------------

--- The ids of the tracks a region covers.
function A.tracks(region)
  local list, out = daw.groups.rows(), {}
  for row = math.max(1, region.r0), region.r1 do
    if list[row] then out[#out + 1] = list[row] end
  end
  return out
end

--- The part of a clip between two beats as a snapshot, or nil if there is none.
local function piece(c, notes, from, to)
  local a, b = math.max(c.start, from), math.min(c.start + c.length, to)
  if b - a <= EPS then return nil end
  local snap = { name = c.name, start = a, length = b - a, kind = c.kind, muted = c.muted }
  -- It plays as the clip does: stretched, shifted, looped from where it begins.
  local moved = daw.stretch.carry(c, snap, a - c.start)
  -- What extensions keep with a clip describes the whole of it, so it goes
  -- with a whole copy and not with a part.
  if a - c.start < EPS and c.start + c.length - b < EPS and c.meta and next(c.meta) then
    snap.meta = c.meta
  else
    -- Its takes are another matter: every piece keeps them, lined up.
    local takes = daw.takes.piece(c, a, b, c.loop and moved.shift)
    if takes then snap.meta = { takes = takes } end
  end
  if c.kind == "midi" and c.loop then
    -- A looped piece keeps everything it repeats, wherever it begins.
    snap.notes = {}
    for i, n in ipairs(notes) do snap.notes[i] = util.merge(n, { start = n.start + moved.shift }) end
    for _, move in ipairs(c.control_count > 0 and api.clip_controls(c.id) or {}) do
      snap.controls = snap.controls or {}
      snap.controls[#snap.controls + 1] = util.merge(move, { start = move.start + moved.shift })
    end
  elseif c.kind == "midi" then
    snap.notes = {}
    for _, n in ipairs(notes) do
      local start = c.start + n.start
      if start >= a - EPS and start < b - EPS then
        snap.notes[#snap.notes + 1] = util.merge(n, { start = start - a, length = math.min(n.length, b - start) })
      end
    end
    -- Controller moves go with the stretch they happen in.
    for _, move in ipairs(c.control_count > 0 and api.clip_controls(c.id) or {}) do
      local start = c.start + move.start
      if start >= a - EPS and start < b - EPS then
        snap.controls = snap.controls or {}
        snap.controls[#snap.controls + 1] = util.merge(move, { start = start - a })
      end
    end
  else
    snap.file, snap.gain = c.file, c.gain
    snap.offset = moved.offset
    -- A fade stays with the edge it belongs to; a new edge gets none.
    snap.fade_in = a - c.start < EPS and math.min(c.fade_in, b - a) or 0
    snap.fade_out = c.start + c.length - b < EPS and math.min(c.fade_out, b - a) or 0
  end
  return snap
end

local function notes_of(c)
  return c.kind == "midi" and api.clip_notes(c.id) or nil
end

--- What a track holds between two beats: clip snapshots that start counting
--- from `from`.
function A.copy(track, from, to)
  local out = {}
  for _, c in ipairs(api.clip_list(track)) do
    local p = piece(c, notes_of(c), from, to)
    if p then
      p.start = p.start - from
      out[#out + 1] = p
    end
  end
  return out
end

--- Empty a track between two beats, cutting the clips that reach across
--- either end. With `from` equal to `to` it only cuts there. With `only`,
--- a set of clip ids, the other clips are left alone.
function A.clear(track, from, to, only)
  for _, c in ipairs(api.clip_list(track)) do
    local finish = c.start + c.length
    if c.start < to - EPS and finish > from + EPS and (not only or only[c.id]) then
      local notes = notes_of(c)
      local left, right = piece(c, notes, c.start, from), piece(c, notes, to, finish)
      -- The clip itself stays as what is left of it, so its id lives on.
      local keep = left or right
      if not keep then
        api.clip_remove(c.id)
      else
        api.clip_set(c.id, "start", keep.start)
        api.clip_set(c.id, "length", keep.length)
        if keep.loop_start then api.clip_set(c.id, "loop_start", keep.loop_start) end
        if notes then
          api.clip_set_notes(c.id, keep.notes)
          if c.control_count > 0 then api.clip_set_controls(c.id, keep.controls or {}) end
        else
          api.clip_set(c.id, "offset", keep.offset)
          api.clip_set(c.id, "fade_in", keep.fade_in)
          api.clip_set(c.id, "fade_out", keep.fade_out)
        end
        -- What is left of the clip keeps its takes as its piece has them.
        if keep.meta and keep.meta.takes and keep.meta ~= c.meta then
          local meta = util.merge(c.meta, { takes = keep.meta.takes })
          api.clip_set(c.id, "meta", meta)
        end
        if left and right then daw.restore_clip(right, track) end
      end
    end
  end
end

--- Move every clip of a track that starts at or after `from`.
function A.ripple(track, from, by)
  for _, c in ipairs(api.clip_list(track)) do
    if c.start >= from - EPS then api.clip_set(c.id, "start", math.max(0, c.start + by)) end
  end
end

--- The clips of a track that start inside a region, or all of them for whole tracks.
local function starting_in(track, region)
  local out = {}
  for _, c in ipairs(api.clip_list(track)) do
    if region.clips then
      if region.clips[c.id] then out[#out + 1] = c end
    elseif region.kind == "line" or (c.start >= region.c0 - EPS and c.start < region.c1 - EPS) then
      out[#out + 1] = c
    end
  end
  return out
end

--- The clips of a track that reach into a region.
local function touching(track, region)
  local out = {}
  for _, c in ipairs(api.clip_list(track)) do
    if region.clips then
      if region.clips[c.id] then out[#out + 1] = c end
    elseif region.kind == "line" or (c.start < region.c1 - EPS and c.start + c.length > region.c0 + EPS) then
      out[#out + 1] = c
    end
  end
  return out
end

--- A region as a value for a register: whole tracks, or a stretch of time
--- with what each track holds in it.
function A.yank(region)
  if region.clips then
    -- Clips chosen one by one: each of them whole, where it is.
    local rows = {}
    for i, id in ipairs(A.tracks(region)) do
      rows[i] = {}
      for _, c in ipairs(starting_in(id, region)) do
        local p = piece(c, notes_of(c), c.start, c.start + c.length)
        p.start = p.start - region.c0
        rows[i][#rows[i] + 1] = p
      end
    end
    return { kind = "range", length = region.c1 - region.c0, rows = rows }
  end
  if region.kind == "line" then
    local tracks = {}
    for i, id in ipairs(A.tracks(region)) do tracks[i] = daw.track(id):snapshot() end
    return { kind = "tracks", tracks = tracks }
  end
  local rows = {}
  for i, id in ipairs(A.tracks(region)) do rows[i] = A.copy(id, region.c0, region.c1) end
  return { kind = "range", length = region.c1 - region.c0, rows = rows }
end

--- Remove a region and return what it held. Whole tracks go; a stretch of
--- time leaves a gap, or with `daw.opt.ripple` what follows moves up.
function A.delete(region)
  local value = A.yank(region)
  for _, id in ipairs(A.tracks(region)) do
    if region.clips then
      for _, c in ipairs(starting_in(id, region)) do api.clip_remove(c.id) end
    elseif region.kind == "line" then
      api.track_remove(id)
    else
      A.clear(id, region.c0, region.c1)
      if daw.opt.ripple then A.ripple(id, region.c1, region.c0 - region.c1) end
    end
  end
  return value
end

local last_paste  -- where the last paste left the cursor, and where it ended

--- Put a register's value at the cursor, `count` times one after another.
--- Tracks go below the cursor's track, or above it with `before`. A stretch
--- of time goes after the clip under the cursor, or right at the cursor with
--- `before`; it replaces what is there, or with `daw.opt.ripple` pushes it
--- along.
function A.paste(value, before, count)
  local cursor = daw.cursor
  if not value then return daw.notify("nothing to paste yet", "warn") end
  if value.kind == "tracks" then
    local at = (cursor.index() or 0) + (before and 0 or 1)
    local first
    for _ = 1, count or 1 do
      for _, snap in ipairs(value.tracks) do
        local track = daw.restore_track(snap, at)
        first, at = first or track, at + 1
      end
    end
    if first then cursor.set_track(first) end
    return
  elseif value.kind ~= "range" then
    return daw.notify("that register holds " .. value.kind .. ", which does not go on the timeline", "warn")
  end

  local row, at = cursor.index(), cursor.beat
  if not row then return daw.notify("no track to paste on", "warn") end
  if not before then
    local edits = api.project_get().edits
    if last_paste and last_paste.row == row and last_paste.beat == at and last_paste.edits == edits then
      -- Pasting again right after a paste carries on where that one ended.
      at = last_paste.finish
    else
      local clip = cursor.clip()
      if clip then at = clip.start + clip.length end
    end
  end
  local list, start = daw.groups.rows(), at
  for _ = 1, count or 1 do
    start = at
    for i, clips in ipairs(value.rows) do
      local track = list[row + i - 1]
      if track then
        if daw.opt.ripple then
          A.clear(track, at, at)
          A.ripple(track, at, value.length)
        else
          A.clear(track, at, at + value.length)
        end
        for _, snap in ipairs(clips) do daw.restore_clip(util.merge(snap, { start = at + snap.start }), track) end
      end
    end
    at = at + value.length
  end
  cursor.set_beat(start)
  last_paste = { row = row, beat = start, finish = at, edits = api.project_get().edits }
end

--- Move the clips that start in a region by `by` beats.
function A.shift(region, by)
  for _, id in ipairs(A.tracks(region)) do
    for _, c in ipairs(starting_in(id, region)) do api.clip_set(c.id, "start", math.max(0, c.start + by)) end
  end
end

--- Snap the clips that start in a region to the grid, and the notes in them
--- to the piano roll's.
function A.quantize(region)
  local grid, note_grid = daw.opt.grid, daw.opt.note_grid
  for _, id in ipairs(A.tracks(region)) do
    for _, c in ipairs(starting_in(id, region)) do
      api.clip_set(c.id, "start", util.round(c.start, grid))
      api.clip_set(c.id, "length", math.max(grid, util.round(c.length, grid)))
      if c.kind == "midi" then
        local notes = api.clip_notes(c.id)
        for _, n in ipairs(notes) do n.start = util.round(n.start, note_grid) end
        if not daw.clips.write(c.id, { replace = notes }) then api.clip_set_notes(c.id, notes) end
      end
    end
  end
end

--- Mute what a region covers, or unmute it if all of it is muted already:
--- whole tracks, or the clips reaching into a stretch of time.
function A.mute(region)
  local things, field = {}, "muted"
  for _, id in ipairs(A.tracks(region)) do
    if region.kind == "line" then
      things[#things + 1], field = daw.track(id), "mute"
    else
      for _, c in ipairs(touching(id, region)) do things[#things + 1] = daw.clip(c.id) end
    end
  end
  local all = #things > 0
  for _, thing in ipairs(things) do all = all and thing[field] end
  for _, thing in ipairs(things) do thing[field] = not all end
end

--- Move the notes of the MIDI clips reaching into a region up or down.
function A.transpose(region, semitones)
  for _, id in ipairs(A.tracks(region)) do
    for _, c in ipairs(touching(id, region)) do
      if c.kind == "midi" then
        local notes = api.clip_notes(c.id)
        for _, n in ipairs(notes) do n.pitch = util.clamp(n.pitch + semitones, 0, 127) end
        if not daw.clips.write(c.id, { replace = notes }) then api.clip_set_notes(c.id, notes) end
      end
    end
  end
end

--- Make one clip of the MIDI clips a track has between two beats (of those
--- in the set `only`, if given). Returns whether there was more than one
--- to join.
function A.join(track, from, to, only)
  local clips = touching(track, { c0 = from, c1 = to, clips = only })
  if #clips < 2 then return false end
  for _, c in ipairs(clips) do
    if c.kind ~= "midi" then error("only MIDI clips can be joined", 0) end
  end
  local first, last = clips[1], clips[#clips]
  local notes, controls = api.clip_notes(first.id), api.clip_controls(first.id)
  for i = 2, #clips do
    local by = clips[i].start - first.start
    for _, n in ipairs(api.clip_notes(clips[i].id)) do
      n.start = n.start + by
      notes[#notes + 1] = n
    end
    for _, move in ipairs(api.clip_controls(clips[i].id)) do
      move.start = move.start + by
      controls[#controls + 1] = move
    end
    api.clip_remove(clips[i].id)
  end
  api.clip_set(first.id, "length", last.start + last.length - first.start)
  api.clip_set_notes(first.id, notes)
  if #controls > 0 then api.clip_set_controls(first.id, controls) end
  return true
end

--- How far a region reaches in time: its own stretch, or for whole tracks
--- from the start to the end of their last clip.
function A.span(region)
  if region.kind ~= "line" then return region.c0, region.c1 end
  local finish = 0
  for _, id in ipairs(A.tracks(region)) do
    for _, c in ipairs(api.clip_list(id)) do finish = math.max(finish, c.start + c.length) end
  end
  return 0, finish
end

-- Piano roll ------------------------------------------------------------------

--- Whether a note belongs to a region.
function R.inside(note, region)
  local rows = note.pitch >= region.r0 and note.pitch <= region.r1
  local time = note.start >= region.c0 - EPS and note.start < region.c1 - EPS
  if region.kind == "line" then return rows end
  if region.kind == "block" then return rows and time end
  return time
end

--- The notes of a region and the place of each among the clip's notes.
--- Only the part of the clip the region covers is asked for.
function R.notes(clip, region)
  local range = {}
  if region.kind ~= "line" then range.from, range.to = region.c0 - 2 * EPS, region.c1 end
  if region.kind ~= "char" then range.low, range.high = util.clamp(region.r0, 0, 127), util.clamp(region.r1, 0, 127) end
  local notes, places = {}, {}
  local found, at = clip:notes(range)
  for i, n in ipairs(found) do
    if R.inside(n, region) then
      notes[#notes + 1], places[#places + 1] = n, at[i]
    end
  end
  return notes, places
end

--- One clip, or the clips the roll edits, as a list of `{ clip, offset }`;
--- and whether it is one clip alone.
local function parts_of(target)
  if target.id then return { { clip = target, offset = 0 } }, true end
  return target, #target <= 1
end

--- A region in the beats of a clip `offset` beats after the first.
local function shifted(region, offset)
  if offset == 0 or region.kind == "line" then return region end
  return util.merge(region, { c0 = region.c0 - offset, c1 = region.c1 - offset })
end

--- A region of a clip's notes as a value for a register. Taken from
--- several clips, each note says which it came from (`clip`).
function R.yank(target, region)
  local parts, single = parts_of(target)
  local notes = {}
  for _, part in ipairs(parts) do
    for _, n in ipairs((R.notes(part.clip, shifted(region, part.offset)))) do
      local start = n.start + part.offset
      -- Whole pitches keep their place in time; anything else counts from
      -- where the region starts.
      notes[#notes + 1] = util.merge(n, { start = region.kind == "line" and start or start - region.c0, clip = not single and part.clip.id or nil })
    end
  end
  if not single then
    table.sort(notes, function(a, b)
      if math.abs(a.start - b.start) > EPS then return a.start < b.start end
      return a.pitch < b.pitch
    end)
  end
  return { kind = "notes", shape = region.kind, top = region.r1, length = region.c1 - region.c0, notes = notes }
end

--- Remove a region's notes and return them.
function R.delete(target, region)
  local value = R.yank(target, region)
  for _, part in ipairs((parts_of(target))) do
    local _, places = R.notes(part.clip, shifted(region, part.offset))
    if #places > 0 then part.clip:edit_notes({ remove = places }) end
  end
  return value
end

--- Change the notes of a region with `fn(note)`, each note's start in its
--- own clip's beats.
function R.each(target, region, fn)
  for _, part in ipairs((parts_of(target))) do
    local notes, places = R.notes(part.clip, shifted(region, part.offset))
    local set = {}
    for i, n in ipairs(notes) do
      fn(n)
      set[i] = { index = places[i], start = n.start, length = n.length, pitch = n.pitch, velocity = n.velocity, meta = n.meta or {} }
    end
    if #set > 0 then part.clip:edit_notes({ set = set }) end
  end
end

--- Put notes into a clip, where notes already sounding where they land give
--- way, growing it to reach `finish` (its own beats).
local function put(clip, add, finish)
  local remove = {}
  for index, old in ipairs(clip:notes()) do
    for _, new in ipairs(add) do
      if old.pitch == new.pitch and old.start < new.start + new.length - EPS and old.start + old.length > new.start + EPS then
        remove[#remove + 1] = index
        break
      end
    end
  end
  if finish > clip.length + EPS then clip.length = math.ceil(finish / daw.opt.note_grid - EPS) * daw.opt.note_grid end
  if #add > 0 or #remove > 0 then clip:edit_notes({ remove = remove, add = add }) end
end

--- Put yanked notes into a clip at a beat. A stretch of time keeps its
--- pitches; a block or whole pitches go with their top at `pitch`. Notes
--- already sounding where the new ones land give way, and the clip grows if
--- they reach past its end. Returns the beat where the pasted stretch ends.
--- Given the clips the roll edits, notes yanked from one of them go back
--- into it and the rest into `into` (one of them; the first by default).
function R.paste(target, value, pitch, beat, into)
  if not value then return daw.notify("nothing to paste yet", "warn") end
  if value.kind ~= "notes" then
    return daw.notify("that register holds " .. value.kind .. ", not notes", "warn")
  end
  local parts, single = parts_of(target)
  into = not single and into or parts[1]
  local by_clip = {}
  for _, part in ipairs(parts) do by_clip[part.clip.id] = part end
  local adds, finish = {}, {}
  for _, n in ipairs(value.notes) do
    local part = not single and by_clip[n.clip] or into
    local note = util.merge(n, {})
    -- What is pasted is a note of its own, whatever it was copied from.
    note.clip, note.id = nil, nil
    if value.shape ~= "line" then note.start = beat + n.start end
    note.start = note.start - part.offset
    if value.shape ~= "char" then note.pitch = n.pitch + pitch - value.top end
    if note.pitch >= 0 and note.pitch <= 127 then
      adds[part] = adds[part] or {}
      table.insert(adds[part], note)
      finish[part] = math.max(finish[part] or 0, note.start + note.length)
    end
  end
  -- Room for the whole stretch that was yanked, not only the notes in it.
  if value.shape ~= "line" and adds[into] then finish[into] = math.max(finish[into], beat - into.offset + value.length) end
  for _, part in ipairs(parts) do
    if adds[part] then put(part.clip, adds[part], finish[part]) end
  end
  return value.shape == "line" and beat or beat + value.length
end

return M
