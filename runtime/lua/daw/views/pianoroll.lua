-- The piano roll: edit the notes of a MIDI clip, or of several at once (see
-- `daw.roll_clips`), with other tracks' notes shown behind them.
local api = daw.api
local util = daw.util
local music = daw.music
local clips = require("daw.roll_clips")
daw.roll_clips = clips

local KEYS = 5 -- columns for the note names on the left

local view = {
  clip_id = nil,  -- the active clip: where new notes go
  pitch = 60,     -- cursor row
  beat = 0,       -- cursor column, in beats from the start of the active clip
  top = 72,       -- pitch of the first row
  scroll = 0,     -- beat at the left edge
}
daw.seats.fields("pianoroll", view, { "clip_id", "pitch", "beat", "top", "scroll", "geometry", "length" },
  { pitch = 60, beat = 0, top = 72, scroll = 0 })

function view:clip()
  if self.clip_id and pcall(api.clip_get, self.clip_id) then return daw.clip(self.clip_id) end
  self.clip_id = nil
end

--- The clips being edited, the active one first: `{ id, clip, offset, ... }`
--- each (see `daw.roll_clips.parts`).
function view:parts() return clips.parts() end

--- Open a MIDI clip in the piano roll, alone.
function view:edit(clip)
  if clip.kind ~= "midi" then return daw.notify("only MIDI clips open in the piano roll", "warn") end
  self.clip_id, self.beat, self.scroll = clip.id, 0, 0
  clips.only()
  local notes = clip:notes()
  self.pitch = notes[1] and notes[1].pitch or 60
  self.top = nil
  daw.ui.focus("pianoroll")
end

--- The note under the cursor in any of the clips edited, the active one's
--- first: the note (its start in the roll's beats), its place among its
--- clip's notes, and its part.
function view:note_at(pitch, beat)
  if not self:clip() or pitch < 0 or pitch > 127 then return end
  return clips.note_at(pitch, beat)
end

-- Layers ----------------------------------------------------------------------
--
-- What the roll draws over its grid, back to front by `order`: the context
-- (other tracks' notes, at -10), the clips' own notes ("notes", at 0), then
-- whatever extensions add (marks of a language server, a snippet,
-- suggestions); the selection and the cursor come last. A layer has
--   order    where it goes
--   marks    function(from, to) returning what to draw between two of the
--            roll's beats: `{ pitch, start, length, color = "#rrggbb",
--            fill = 0..1, edge = 0..1, style }` each. Both frontends draw
--            these: the window as rectangles (`fill` and `edge` are how
--            opaque the inside and the border are), the terminal as cells
--            in `style`, or a faint shade of `color`.
--   paint    function(view, L), optional: draws the layer in the terminal
--            instead of its marks. `L` has `roll` (the grid's buffer),
--            `x(beat)` and `row(pitch)` (cells, nil off screen), `from`,
--            `to`, `top`, `rows` and `zoom`.
view.layers = {}

--- Add a layer, replace the one of that name, or with nil take it away.
---   daw.ui.views.pianoroll.layer("lint", { order = 10, marks = function(from, to) ... end })
function view.layer(name, spec)
  for i, layer in ipairs(view.layers) do
    if layer.name == name then
      table.remove(view.layers, i)
      break
    end
  end
  if spec then
    view.layers[#view.layers + 1] = util.merge(spec, { name = name, order = spec.order or 0 })
    table.sort(view.layers, function(a, b) return a.order < b.order end)
  end
  api.ui_redraw()
end

--- The marks of every layer between two beats, for a frontend that draws
--- them itself: those under the notes and those over them, each in order.
function view.layer_marks(from, to)
  local under, over = {}, {}
  for _, layer in ipairs(view.layers) do
    if layer.marks then
      local ok, list = pcall(layer.marks, from, to)
      if not ok then
        daw.notify("the piano roll's layer `" .. layer.name .. "` failed: " .. tostring(list), "error")
      elseif type(list) == "table" then
        local into = layer.order < 0 and under or over
        for _, m in ipairs(list) do into[#into + 1] = m end
      end
    end
  end
  return under, over
end

--- Draw marks as cells: a faint shade of each one's colour unless it names a style.
local function paint_marks(L, marks)
  local g = daw.draw.g
  for _, m in ipairs(marks) do
    local row = L.row(m.pitch)
    if row then
      local x0 = math.floor((m.start - L.from) * L.zoom + 0.5)
      local x1 = math.floor((m.start + m.length - L.from) * L.zoom + 0.5)
      local style = m.style or daw.draw.hue(m.color).body
      L.roll:fill(x0, row, math.max(1, x1 - x0), 1, " ", style)
      if (m.edge or 0) > 0 then L.roll:text(x0, row, g.clip_start, style) end
    end
  end
end

-- Other tracks' notes, behind the clips' own. In the terminal each is a
-- dashed line on a faint shade of its track's colour, without a name: the
-- clips' own notes are solid and named.
view.layer("context", {
  order = -10,
  paint = function(_, L)
    local glyph = daw.opt.ascii and "-" or "╌"
    for _, n in ipairs(clips.context()) do
      local row = L.row(n.pitch)
      if row and n.start < L.to and n.start + n.length > L.from then
        local x0 = math.floor((n.start - L.from) * L.zoom + 0.5)
        local x1 = math.floor((n.start + n.length - L.from) * L.zoom + 0.5)
        L.roll:fill(x0, row, math.max(1, x1 - x0), 1, glyph, daw.draw.hue(n.color).body)
      end
    end
  end,
  marks = function(from, to)
    local out = {}
    for _, n in ipairs(clips.context()) do
      if n.start < to and n.start + n.length > from then
        out[#out + 1] = { pitch = n.pitch, start = n.start, length = n.length, color = n.color, fill = 0.22, edge = 0.5 }
      end
    end
    return out
  end,
})

-- The notes of the clips being edited.
view.layer("notes", {
  order = 0,
  paint = function(self, L)
    local g = daw.draw.g
    for i, part in ipairs(L.parts) do
      local hue = i == 1 and L.hue or daw.draw.track_hue(api.track_get(part.track))
      local chosen = {}
      for _, place in ipairs(daw.frontend.chosen_notes(part.id)) do chosen[place] = true end
      local shown, places = part.clip:notes({
        from = L.from - part.offset, to = L.to - part.offset, low = math.max(0, L.top - L.rows + 1), high = L.top,
      })
      for k, note in ipairs(shown) do
        local row = L.top - note.pitch
        local start = note.start + part.offset
        local x0 = math.floor((start - L.from) * L.zoom + 0.5)
        local x1 = math.floor((start + note.length - L.from) * L.zoom + 0.5)
        local nw = math.max(1, x1 - x0)
        local at_cursor = L.under_part and L.under_part.id == part.id and places[k] == L.under_place
        local style = at_cursor and "NoteCursor" or chosen[places[k]] and hue.title_cur or daw.draw.note_style(hue, note.velocity)
        L.roll:fill(x0, row, nw, 1, " ", style)
        L.roll:text(x0, row, g.clip_start)
        -- Long enough notes say which they are.
        if nw >= 4 then L.roll:text(x0 + 1, row, music.name(note.pitch):sub(1, nw - 1)) end
      end
    end
  end,
})

local HEAD = 2 -- rows above the notes: the panel's title, then the ruler

--- Rows for the velocity lane on a panel `h` rows tall.
function view.velocity_rows(h)
  return h >= 30 and 5 or h >= 16 and 3 or 0
end

function view:render(buf, ctx)
  local g = daw.draw.g
  local w, h = buf.width, buf.height
  local clip = self:clip()
  buf:fill(0, 0, w, h, " ", "Normal")
  if not clip then
    daw.ui.titlebar(buf, { name = "Piano roll", focused = ctx.focused })
    buf:text(2, 2, "No clip open.", "Empty")
    buf:text(2, 3, "Put the cursor on a MIDI clip in the arrange view and press", "Empty")
    buf:text(61, 3, "Enter", "EmptyKey")
    return
  end
  local c = clip:get()
  local track = api.track_get(c.track)
  local hue = daw.draw.track_hue(track)
  local parts = clips.parts()
  local lo, hi = clips.span()
  local zoom, grid = daw.opt.note_zoom, daw.opt.note_grid
  -- With room to spare, the notes' velocities get a few rows of their own.
  local vel = view.velocity_rows(h)
  local rows, tw = h - HEAD - vel, w - KEYS
  local span = tw / zoom

  -- Keep the cursor on screen.
  if not self.top then self.top = self.pitch + math.floor(rows / 2) end
  if self.pitch > self.top then self.top = self.pitch end
  if self.pitch <= self.top - rows then self.top = self.pitch + rows - 1 end
  self.top = util.clamp(self.top, rows - 1, 127)
  if self.beat < self.scroll then self.scroll = math.floor(self.beat) end
  if self.beat >= self.scroll + span - grid then self.scroll = math.ceil(self.beat - span + 1) end
  self.scroll = math.max(math.min(0, math.floor(lo)), self.scroll)
  self.geometry = { rows = rows, zoom = zoom }

  -- Title: the active clip in its track's colour, the track and how many
  -- clips are edited, where the cursor is and the chord sounding there; on
  -- the right what the keys will enter.
  local inserting = ctx.focused and daw.keymap.mode == "i"
  local grid_text = daw.ui.views.status.grid_text
  local right = string.format("grid %s  len %s  vel %d  oct %d", grid_text(grid), grid_text(self:step_length()),
    daw.opt.velocity, daw.opt.octave)
  local sounding, chord = clips.sounding(self.beat)
  local place = music.name(self.pitch) .. "  " .. daw.time.format(c.start + self.beat)
  daw.ui.titlebar(buf, {
    pill = { c.name, hue.pill }, focused = ctx.focused,
    name = #parts > 1 and string.format("%s  +%d clip%s", track.name, #parts - 1, #parts == 2 and "" or "s") or track.name,
    context = chord and place .. "  " .. chord or place,
    right = w >= 90 and right or nil,
  })
  if inserting then
    local text = string.format(" INS C%d  step %g  vel %d ", daw.opt.octave, self:step_length(), daw.opt.velocity)
    buf:text(math.max(0, w - api.str_width(text) - 1), 0, text, "RulerInsert")
  end

  -- Ruler: bars as the project counts them, beats in between.
  buf:fill(0, 1, w, 1, " ", "Ruler")
  local roll = buf:sub(KEYS, HEAD, tw, rows)
  local ruler = buf:sub(KEYS, 1, tw, 1)
  local lines = daw.draw.beats(ruler, self.scroll, span, zoom, c.start)
  -- Steps between the beats when zoomed in far enough to see them.
  -- They are the same on every row: one line of text, drawn row by row.
  local steps
  if zoom >= 8 and grid < 1 then
    local cells = {}
    for i = 1, tw do cells[i] = " " end
    for _, line in ipairs(lines) do
      for k = 1, math.floor(1 / grid + 0.5) - 1 do
        local x = line.x + math.floor(k * grid * zoom + 0.5)
        if x >= 0 and x < tw then cells[x + 1] = g.step end
      end
    end
    steps = table.concat(cells)
  end

  -- The keys that sound at the cursor, in any clip shown, are marked.
  local sounds = {}
  for _, pitch in ipairs(sounding) do sounds[pitch] = true end
  local start_x = math.floor((lo - self.scroll) * zoom + 0.5)
  local end_x = math.floor((hi - self.scroll) * zoom + 0.5)
  for row = 0, rows - 1 do
    local pitch = self.top - row
    daw.draw.piano_key(buf, row + HEAD, pitch, pitch == self.pitch, KEYS)
    if sounds[pitch] then buf:text(KEYS - 1, row + HEAD, "•", "PianoCursor") end
    roll:fill(0, row, tw, 1, " ", music.is_black(pitch) and "RollRowBlack" or "RollRow")
    if steps then roll:text(0, row, steps, music.is_black(pitch) and "RollStepBlack" or "RollStep") end
    for _, line in ipairs(lines) do roll:text(line.x, row, line.bar and g.bar or g.beat, line.bar and "RollBar" or "RollBeat") end
    if start_x > 0 then roll:fill(0, row, math.min(tw, start_x), 1, " ", "RollOutside") end
    if end_x < tw then roll:fill(math.max(0, end_x), row, tw, 1, " ", "RollOutside") end
  end

  -- The playhead is a thin line on the beat's left edge, under the notes:
  -- one that starts where it stands is drawn whole, from where it starts.
  local t = api.transport_get()
  local px = math.floor((t.position - c.start - self.scroll) * zoom + 0.5)
  local playing_here = px >= 0 and px < tw and t.position >= c.start + lo and t.position <= c.start + hi
  if playing_here then roll:fill(px, 0, 1, rows, g.playhead, "Playhead") end

  -- The layers, back to front. Only what is on screen crosses over from the core.
  local _, under_place, under_part = self:note_at(self.pitch, self.beat)
  local L = {
    roll = roll, from = self.scroll, to = self.scroll + span, top = self.top, rows = rows, zoom = zoom,
    parts = parts, hue = hue, under_place = under_place, under_part = under_part,
    x = function(beat)
      local x = math.floor((beat - self.scroll) * zoom + 0.5)
      return x >= 0 and x < tw and x or nil
    end,
    row = function(pitch)
      local row = self.top - pitch
      return row >= 0 and row < rows and row or nil
    end,
  }
  for _, layer in ipairs(view.layers) do
    if layer.paint then
      local ok, err = pcall(layer.paint, self, L)
      if not ok then daw.notify("the piano roll's layer `" .. layer.name .. "` failed: " .. tostring(err), "error") end
    elseif layer.marks then
      local ok, list = pcall(layer.marks, L.from, L.to)
      if ok and type(list) == "table" then paint_marks(L, list) end
    end
  end

  -- How hard each note on screen is played, along the bottom.
  if vel > 0 then
    local lane = buf:sub(KEYS, HEAD + rows, tw, vel)
    buf:fill(0, HEAD + rows, w, vel, " ", "VelocityLane")
    buf:text(1, HEAD + rows + vel - 1, "vel", "VelocityLane")
    for _, line in ipairs(lines) do
      if line.bar then lane:fill(line.x, 0, 1, vel, g.bar, "RollBar") end
    end
    for i, part in ipairs(parts) do
      local fg = i == 1 and hue.fg or daw.draw.track_hue(api.track_get(part.track)).fg
      local all, places = part.clip:notes({ from = self.scroll - part.offset, to = self.scroll + span - part.offset })
      for k, note in ipairs(all) do
        local x0 = math.floor((note.start + part.offset - self.scroll) * zoom + 0.5)
        local level = note.velocity / 127 * vel * 8
        local at_cursor = under_part and under_part.id == part.id and places[k] == under_place
        for row = 0, vel - 1 do
          local amount = level - (vel - 1 - row) * 8
          if amount >= 1 then lane:text(x0, row, g.eighths[math.min(8, math.floor(amount))], at_cursor and "Bright" or fg) end
        end
        if at_cursor then
          local text = tostring(note.velocity)
          lane:text(x0 + 1, 0, text, "Bright")
        end
      end
    end
  end

  -- The selection of visual mode: a stretch of time, a block, or whole pitches.
  local selection = ctx.focused and daw.keymap.selection()
  if selection then
    local x0 = math.max(0, math.floor((selection.c0 - self.scroll) * zoom + 0.5))
    local x1 = math.min(tw, math.floor((selection.c1 - self.scroll) * zoom + 0.5))
    local y0, y1 = math.max(0, self.top - selection.r1), math.min(rows - 1, self.top - selection.r0)
    if selection.kind == "line" then
      x0, x1 = 0, tw
    elseif selection.kind == "char" then
      y0, y1 = 0, rows - 1
    end
    if x1 > x0 and y1 >= y0 then roll:fill(x0, y0, x1 - x0, y1 - y0 + 1, nil, "Visual") end
  end

  local cx = math.floor((self.beat - self.scroll) * zoom + 0.5)
  local cw = math.max(1, math.floor(grid * zoom))
  if not under_place or selection or inserting then
    roll:fill(cx, self.top - self.pitch, cw, 1, nil, inserting and "InsertCursor" or "RollCursor")
  end

  if playing_here then ruler:text(px, 0, g.cap, "RulerPlayhead") end
end

--- Play the pitch under the cursor on the track of the clip it is in.
function view:audition(pitch)
  local part = clips.target(self.beat)
  if part then part.clip:track():play_note(pitch or self.pitch, daw.opt.velocity, 180) end
end

--- How far the cursor can go: the stretch of the clips edited.
function view:span()
  return clips.span()
end

function view:move(dbeat, dpitch)
  if not self:clip() then return end
  -- One step past the last is allowed, so that a selection can reach the end.
  local lo, hi = self:span()
  self.beat = util.clamp(self.beat + dbeat, lo, hi)
  local pitch = util.clamp(self.pitch + dpitch, 0, 127)
  if pitch ~= self.pitch then
    self.pitch = pitch
    self:audition()
  end
  api.ui_redraw()
end

--- Put the cursor somewhere without sounding the pitch; nil leaves that
--- part of it where it is. Unlike `move` it can sit right at the end of the
--- clip, where a selection or a deletion may need to reach.
function view:set(pitch, beat)
  if not self:clip() then return end
  if pitch then self.pitch = util.clamp(pitch, 0, 127) end
  if beat then self.beat = util.clamp(beat, self:span()) end
  api.ui_redraw()
end

--- The notes of the clips edited in the order they start, lower pitches
--- first within a chord, their starts in the roll's beats.
function view:ordered()
  if not self:clip() then return {} end
  -- One clip's are in the order the core keeps them in.
  return clips.notes()
end

--- Go to the next (`dir` 1) or previous (-1) note, wherever its pitch is.
function view:to_note(dir, count)
  local notes = self:ordered()
  for _ = 1, count or 1 do
    local found
    if dir > 0 then
      for _, n in ipairs(notes) do
        if n.start > self.beat + 1e-9 then
          found = n
          break
        end
      end
    else
      for i = #notes, 1, -1 do
        if notes[i].start < self.beat - 1e-9 then
          found = notes[i]
          break
        end
      end
    end
    if not found then
      -- Past the last note there is the end of the clips; before the first, their start.
      if dir > 0 then self:to_edge(-1) else self:set(nil, (self:span())) end
      return
    end
    self:set(found.pitch, found.start)
  end
end

--- Go to where the note under the cursor ends, or else the next one to end.
function view:to_note_end(count)
  for _ = 1, count or 1 do
    local best
    for _, n in ipairs(self:ordered()) do
      local finish = n.start + n.length
      if finish > self.beat + 1e-9 and (not best or finish < best.start + best.length) then best = n end
    end
    if not best then return end
    self:set(best.pitch, best.start + best.length)
  end
end

--- Go `n` bars on, or back with a negative `n`, to where a bar starts.
function view:to_bar(n)
  local clip = self:clip()
  if not clip then return end
  local at = clip.start + self.beat
  local bar = daw.time.bar_of(at)
  local to = n > 0 and bar + n or bar + n + (daw.tempo.is_bar_line(at) and 0 or 1)
  self:set(nil, daw.time.bar_start(math.max(1, to)) - clip.start)
end

--- Go to the first note (`dir` 1) or to the end of the clips (-1).
function view:to_edge(dir)
  if not self:clip() then return end
  local lo, hi = self:span()
  if dir < 0 then return self:set(nil, hi) end
  local first = self:ordered()[1]
  if first then self:set(first.pitch, first.start) else self:set(nil, lo) end
end

--- Go to the pitch of the highest (`dir` 1) or lowest (-1) note.
function view:to_extreme(dir)
  local best
  for _, n in ipairs(self:ordered()) do
    if not best or (n.pitch - best) * dir > 0 then best = n.pitch end
  end
  if best then self:set(best, nil) end
end

local last_paste  -- where the last paste left the cursor, and where it ended

--- Paste yanked notes `count` times one after another: after the note under
--- the cursor, or right at the cursor with `before`. Notes yanked from
--- clips that are edited now go back into them; the rest go into the clip
--- at the cursor.
function view:paste(value, before, count)
  local clip = self:clip()
  if not clip then return end
  local at = self.beat
  if not before then
    local edits = api.project_get().edits
    if last_paste and last_paste.clip == clip.id and last_paste.beat == at and last_paste.edits == edits then
      -- Pasting again right after a paste carries on where that one ended.
      at = last_paste.finish
    else
      local note = self:note_at(self.pitch, self.beat)
      if note then at = note.start + note.length end
    end
  end
  local start = at
  for _ = 1, count or 1 do
    start = at
    local parts = clips.parts()
    local finish = daw.edit.roll.paste(#parts > 1 and parts or clip, value, self.pitch, at, clips.target(at, parts))
    if not finish then return end
    at = finish
  end
  self:set(nil, start)
  last_paste = { clip = clip.id, beat = self.beat, finish = at, edits = api.project_get().edits }
end

-- Insert mode: notes entered from the keyboard, one step after another.

--- How long a note entered in insert mode is, and how far the cursor then moves.
function view:step_length()
  return self.length or daw.opt.note_grid
end

function view:set_step(length)
  self.length = length
  api.ui_redraw()
end

--- Move the cursor by whole steps, growing the clip it is in by a bar at a
--- time when it runs out.
function view:step(n)
  if not self:clip() then return end
  local lo = self:span()
  local to = math.max(lo, self.beat + n * self:step_length())
  local parts = clips.parts()
  local part = clips.target(self.beat, parts)
  -- Unless another of the clips edited is there already.
  local taken = false
  for _, other in ipairs(parts) do
    taken = taken or (other ~= part and to >= other.offset - 1e-9 and to < other.offset + other.length - 1e-9)
  end
  if to > part.offset + part.length - 1e-9 and not taken then
    part.clip.length = daw.time.bar_ceil(part.start + to - part.offset + 1e-9) - part.start
  end
  self:set(nil, to)
end

--- The places of the notes that start at the cursor in `clip` (`offset`
--- beats after the active clip), on one pitch or on any.
function view:starting_here(clip, pitch, offset)
  local beat = self.beat - (offset or 0)
  local notes, at = clip:notes({ from = beat - 1e-9, to = beat + 2e-9, low = pitch, high = pitch })
  local places = {}
  for i, n in ipairs(notes) do
    if math.abs(n.start - beat) < 1e-9 then places[#places + 1] = at[i] end
  end
  return places
end

--- Enter the note `semitone` above C of the current octave at the cursor,
--- then step on, or stay to add more notes to a chord.
function view:enter(semitone, advance)
  if not self:clip() then return end
  local part = clips.target(self.beat)
  local clip, beat = part.clip, self.beat - part.offset
  local pitch = util.clamp((daw.opt.octave + 1) * 12 + semitone, 0, 127)
  local length = self:step_length()
  if beat + length > part.length + 1e-9 then
    clip.length = daw.time.bar_ceil(part.start + beat + length - 1e-9) - part.start
  end
  -- A note of the same pitch that starts here is replaced.
  clip:edit_notes({
    remove = self:starting_here(clip, pitch, part.offset),
    add = { { pitch = pitch, start = beat, length = length, velocity = daw.opt.velocity } },
  })
  self.pitch = pitch
  clip:track():play_note(pitch, daw.opt.velocity, 180)
  daw.ui.poke()
  if advance then self:step(1) else api.ui_redraw() end
end

--- Step back and remove the notes that start there.
function view:backspace()
  if not self:clip() or self.beat <= self:span() then return end
  self:step(-1)
  local part = clips.target(self.beat)
  local places = self:starting_here(part.clip, nil, part.offset)
  if #places > 0 then part.clip:edit_notes({ remove = places }) end
end

function view:set_octave(delta)
  daw.opt.octave = util.clamp(daw.opt.octave + delta, -1, 9)
end

-- What modal editing works on: rows are pitches, which count upwards.
view.grid = {
  down = -1,
  get = function() return view.pitch, view.beat end,
  set = function(row, col) view:set(row, col) end,
  step = function() return daw.opt.note_grid end,
  -- Notes by the name of their pitch: `c` finds every C and C sharp, `c4` one key.
  search = function(text)
    local wanted, hits = text:lower(), {}
    for _, n in ipairs(view:ordered()) do
      if music.name(n.pitch):lower():find(wanted, 1, true) == 1 then hits[#hits + 1] = { row = n.pitch, col = n.start } end
    end
    return hits
  end,
}

--- Add a note at the cursor, or remove the one that is there.
function view:toggle_note()
  if not self:clip() then return end
  local _, place, part = self:note_at(self.pitch, self.beat)
  if place then
    part.clip:remove_note(place)
  else
    part = clips.target(self.beat)
    part.clip:add_note({ pitch = self.pitch, start = self.beat - part.offset, length = self.length or daw.opt.note_grid })
    self:audition()
  end
end

--- Change the note under the cursor with `fn(note)`, the note's start in
--- its own clip's beats, which it does not leave. Returns whether there was one.
function view:change(fn)
  local _, place, part = self:note_at(self.pitch, self.beat)
  if not place then return false end
  local note = part.clip:notes()[place]
  fn(note)
  part.clip:set_note(place, { start = note.start, length = note.length, pitch = note.pitch, velocity = note.velocity, meta = note.meta or {} })
  return true
end

function view:on_mouse(event)
  local g = self.geometry
  if not g or not self:clip() then return end
  if event.kind == "scroll_up" then self.top = math.min(127, self.top + 2) end
  if event.kind == "scroll_down" then self.top = math.max(g.rows - 1, self.top - 2) end
  local row = event.y - HEAD
  if event.kind == "down" and row >= 0 and row < g.rows and event.x >= KEYS then
    local grid = daw.opt.note_grid
    self.pitch = self.top - row
    self.beat = math.floor((self.scroll + (event.x - KEYS) / g.zoom) / grid) * grid
    if event.button == "left" then self:toggle_note() end
  elseif event.kind == "down" and row >= 0 and row < g.rows then
    self:audition(self.top - row)
  end
  -- Scrolling moves the window, so bring the cursor along with it.
  self.pitch = util.clamp(self.pitch, self.top - g.rows + 1, self.top)
  api.ui_redraw()
end

daw.ui.view("pianoroll", view)
return view
