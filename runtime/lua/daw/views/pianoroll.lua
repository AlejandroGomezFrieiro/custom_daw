-- The piano roll: edit the notes of one MIDI clip.
local api = daw.api
local util = daw.util
local music = daw.music

local KEYS = 5 -- columns for the note names on the left

local view = {
  clip_id = nil,
  pitch = 60,     -- cursor row
  beat = 0,       -- cursor column, in beats from the start of the clip
  top = 72,       -- pitch of the first row
  scroll = 0,     -- beat at the left edge
}
daw.seats.fields("pianoroll", view, { "clip_id", "pitch", "beat", "top", "scroll", "geometry", "length" },
  { pitch = 60, beat = 0, top = 72, scroll = 0 })

function view:clip()
  if self.clip_id and pcall(api.clip_get, self.clip_id) then return daw.clip(self.clip_id) end
  self.clip_id = nil
end

--- Open a MIDI clip in the piano roll.
function view:edit(clip)
  if clip.kind ~= "midi" then return daw.notify("only MIDI clips open in the piano roll", "warn") end
  self.clip_id, self.beat, self.scroll = clip.id, 0, 0
  local notes = clip:notes()
  self.pitch = notes[1] and notes[1].pitch or 60
  self.top = nil
  daw.ui.focus("pianoroll")
  daw.emit("pianoroll.opened", { clip = clip.id })
end

--- The time this view shows, for windows bound in time (`timebind`): the
--- project's beat at the left edge, columns per beat, and beats shown.
function view:time_axis()
  local clip = self:clip()
  if not clip then return nil end
  return clip.start + self.scroll, daw.opt.note_zoom, self.geometry and self.geometry.span
end

function view:set_time_axis(left, zoom)
  local clip = self:clip()
  if not clip then return end
  self.scroll = math.max(0, left - clip.start)
  if zoom and daw.opt.note_zoom ~= zoom then daw.opt.note_zoom = zoom end
end

--- The note under the cursor, with its index in the clip's note list.
function view:note_at(pitch, beat)
  local clip = self:clip()
  if not clip or pitch < 0 or pitch > 127 then return end
  return clip:note_at(pitch, beat)
end

local HEAD = 2 -- rows above the notes: the panel's title, then the ruler

-- Layers that modules draw over the roll, from back to front by `order`.
-- The clip's own notes are at 20: layers below that (other tracks' notes)
-- are drawn under them, the rest (diagnostics 30, a snippet's marks 40,
-- suggestions 50) over them, and the cursor last of all.
view.layers = {}

--- Draw `paint(p)` as a layer of the roll, replacing one of the same name
--- (nil removes it). `p` holds `roll` and `ruler` (cell buffers), `clip`,
--- `x(beat)` (a column of the roll), `row(pitch)` (a row, nil when off
--- screen), `scroll`, `zoom`, `top`, `rows` and `hue`.
function view.layer(name, order, paint)
  for i = #view.layers, 1, -1 do
    if view.layers[i].name == name then table.remove(view.layers, i) end
  end
  if paint then view.layers[#view.layers + 1] = { name = name, order = order, paint = paint } end
  table.sort(view.layers, function(a, b) return a.order < b.order end)
  api.ui_redraw()
end

local function paint_layers(p, from, to)
  for _, layer in ipairs(view.layers) do
    if layer.order >= from and layer.order < to then layer.paint(p) end
  end
end

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
  -- Unless another window leads this one's time (`timebind`).
  if not ctx.follower then
    if self.beat < self.scroll then self.scroll = math.floor(self.beat) end
    if self.beat >= self.scroll + span - grid then self.scroll = math.ceil(self.beat - span + 1) end
  end
  self.scroll = math.max(0, self.scroll)
  self.geometry = { rows = rows, zoom = zoom, span = span }

  -- Title: the clip in its track's colour, the track, where the cursor is;
  -- on the right what the keys will enter.
  local inserting = ctx.focused and daw.keymap.mode == "i"
  local grid_text = daw.ui.views.status.grid_text
  local right = string.format("grid %s  len %s  vel %d  oct %d", grid_text(grid), grid_text(self:step_length()),
    daw.opt.velocity, daw.opt.octave)
  daw.ui.titlebar(buf, {
    pill = { c.name, hue.pill }, name = track.name, focused = ctx.focused,
    context = music.name(self.pitch) .. "  " .. daw.time.format(c.start + self.beat),
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

  local end_x = math.floor((c.length - self.scroll) * zoom + 0.5)
  for row = 0, rows - 1 do
    local pitch = self.top - row
    daw.draw.piano_key(buf, row + HEAD, pitch, pitch == self.pitch, KEYS)
    roll:fill(0, row, tw, 1, " ", music.is_black(pitch) and "RollRowBlack" or "RollRow")
    if steps then roll:text(0, row, steps, music.is_black(pitch) and "RollStepBlack" or "RollStep") end
    for _, line in ipairs(lines) do roll:text(line.x, row, line.bar and g.bar or g.beat, line.bar and "RollBar" or "RollBeat") end
    if end_x < tw then roll:fill(math.max(0, end_x), row, tw, 1, " ", "RollOutside") end
  end

  -- The playhead is a thin line on the beat's left edge, under the notes:
  -- one that starts where it stands is drawn whole, from where it starts.
  local t = api.transport_get()
  local px = math.floor((t.position - c.start - self.scroll) * zoom + 0.5)
  local playing_here = px >= 0 and px < tw and t.position >= c.start and t.position <= c.start + c.length
  if playing_here then roll:fill(px, 0, 1, rows, g.playhead, "Playhead") end

  local top = self.top
  local layer = {
    roll = roll, ruler = ruler, clip = clip, scroll = self.scroll, zoom = zoom, top = top, rows = rows, hue = hue,
    x = function(beat) return math.floor((beat - self.scroll) * zoom + 0.5) end,
    row = function(pitch)
      local row = top - pitch
      if row >= 0 and row < rows then return row end
    end,
  }
  paint_layers(layer, -math.huge, 20)

  -- Only what is on screen crosses over from the core.
  local under = self:note_at(self.pitch, self.beat)
  local chosen = {}
  for _, place in ipairs(daw.frontend.chosen_notes(c.id)) do chosen[place] = true end
  local shown, places = clip:notes({ from = self.scroll, to = self.scroll + span, low = math.max(0, self.top - rows + 1), high = self.top })
  for i, note in ipairs(shown) do
    local row = self.top - note.pitch
    local x0 = math.floor((note.start - self.scroll) * zoom + 0.5)
    local x1 = math.floor((note.start + note.length - self.scroll) * zoom + 0.5)
    local nw = math.max(1, x1 - x0)
    local at_cursor = under and note.pitch == under.pitch and note.start == under.start
    local style = at_cursor and "NoteCursor" or chosen[places and places[i]] and hue.title_cur or daw.draw.note_style(hue, note.velocity)
    roll:fill(x0, row, nw, 1, " ", style)
    roll:text(x0, row, g.clip_start)
    -- Long enough notes say which they are.
    if nw >= 4 then roll:text(x0 + 1, row, music.name(note.pitch):sub(1, nw - 1)) end
  end
  paint_layers(layer, 20, math.huge)

  -- How hard each note on screen is played, along the bottom.
  if vel > 0 then
    local lane = buf:sub(KEYS, HEAD + rows, tw, vel)
    buf:fill(0, HEAD + rows, w, vel, " ", "VelocityLane")
    buf:text(1, HEAD + rows + vel - 1, "vel", "VelocityLane")
    for _, line in ipairs(lines) do
      if line.bar then lane:fill(line.x, 0, 1, vel, g.bar, "RollBar") end
    end
    local all = clip:notes({ from = self.scroll, to = self.scroll + span })
    for _, note in ipairs(all) do
      local x0 = math.floor((note.start - self.scroll) * zoom + 0.5)
      local level = note.velocity / 127 * vel * 8
      local at_cursor = under and note.pitch == under.pitch and note.start == under.start
      for row = 0, vel - 1 do
        local amount = level - (vel - 1 - row) * 8
        if amount >= 1 then lane:text(x0, row, g.eighths[math.min(8, math.floor(amount))], at_cursor and "Bright" or hue.fg) end
      end
      if at_cursor then
        local text = tostring(note.velocity)
        lane:text(x0 + 1, 0, text, "Bright")
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
  if not under or selection or inserting then
    roll:fill(cx, self.top - self.pitch, cw, 1, nil, inserting and "InsertCursor" or "RollCursor")
  end

  if playing_here then ruler:text(px, 0, g.cap, "RulerPlayhead") end
end

--- Play the pitch under the cursor on the clip's track.
function view:audition(pitch)
  local clip = self:clip()
  if clip then clip:track():play_note(pitch or self.pitch, daw.opt.velocity, 180) end
end

function view:move(dbeat, dpitch)
  local clip = self:clip()
  if not clip then return end
  -- One step past the last is allowed, so that a selection can reach the end.
  self.beat = util.clamp(self.beat + dbeat, 0, clip.length)
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
  local clip = self:clip()
  if not clip then return end
  if pitch then self.pitch = util.clamp(pitch, 0, 127) end
  if beat then self.beat = util.clamp(beat, 0, clip.length) end
  api.ui_redraw()
end

--- The clip's notes in the order they start, lower pitches first within a chord.
function view:ordered()
  local clip = self:clip()
  -- Which is the order the core keeps them in.
  return clip and clip:notes() or {}
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
      -- Past the last note there is the end of the clip; before the first, its start.
      if dir > 0 then self:to_edge(-1) else self:set(nil, 0) end
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

--- Go to the first note (`dir` 1) or to the end of the clip (-1).
function view:to_edge(dir)
  local clip = self:clip()
  if not clip then return end
  if dir < 0 then return self:set(nil, clip.length) end
  local first = self:ordered()[1]
  if first then self:set(first.pitch, first.start) else self:set(nil, 0) end
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
--- the cursor, or right at the cursor with `before`.
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
    local finish = daw.edit.roll.paste(clip, value, self.pitch, at)
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

--- Move the cursor by whole steps, growing the clip by a bar at a time when
--- it runs out.
function view:step(n)
  local clip = self:clip()
  if not clip then return end
  local to = math.max(0, self.beat + n * self:step_length())
  if to > clip.length - 1e-9 then
    clip.length = daw.time.bar_ceil(clip.start + to + 1e-9) - clip.start
  end
  self:set(nil, to)
end

--- The places of the notes that start at the cursor, on one pitch or on any.
function view:starting_here(clip, pitch)
  local notes, at = clip:notes({ from = self.beat - 1e-9, to = self.beat + 2e-9, low = pitch, high = pitch })
  local places = {}
  for i, n in ipairs(notes) do
    if math.abs(n.start - self.beat) < 1e-9 then places[#places + 1] = at[i] end
  end
  return places
end

--- Enter the note `semitone` above C of the current octave at the cursor,
--- then step on, or stay to add more notes to a chord.
function view:enter(semitone, advance)
  local clip = self:clip()
  if not clip then return end
  local pitch = util.clamp((daw.opt.octave + 1) * 12 + semitone, 0, 127)
  local length = self:step_length()
  if self.beat + length > clip.length + 1e-9 then
    clip.length = daw.time.bar_ceil(clip.start + self.beat + length - 1e-9) - clip.start
  end
  -- A note of the same pitch that starts here is replaced.
  clip:edit_notes({
    remove = self:starting_here(clip, pitch),
    add = { { pitch = pitch, start = self.beat, length = length, velocity = daw.opt.velocity } },
  })
  self.pitch = pitch
  clip:track():play_note(pitch, daw.opt.velocity, 180)
  daw.ui.poke()
  if advance then self:step(1) else api.ui_redraw() end
end

--- Step back and remove the notes that start there.
function view:backspace()
  local clip = self:clip()
  if not clip or self.beat <= 0 then return end
  self:step(-1)
  local places = self:starting_here(clip)
  if #places > 0 then clip:edit_notes({ remove = places }) end
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
  local clip = self:clip()
  if not clip then return end
  local note, index = self:note_at(self.pitch, self.beat)
  if note then
    clip:remove_note(index)
  else
    clip:add_note({ pitch = self.pitch, start = self.beat, length = self.length or daw.opt.note_grid })
    self:audition()
  end
end

--- Change the note under the cursor with `fn(note)`. Returns whether there was one.
function view:change(fn)
  local clip = self:clip()
  local note, index = self:note_at(self.pitch, self.beat)
  if not note then return false end
  fn(note)
  clip:set_note(index, { start = note.start, length = note.length, pitch = note.pitch, velocity = note.velocity, meta = note.meta or {} })
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
