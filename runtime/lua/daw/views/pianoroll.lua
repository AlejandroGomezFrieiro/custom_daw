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
  daw.emit("pianoroll.opened", { clip = clip.id })
end

--- Shown beside a view that has a clip open (the notation view), the roll
--- takes that clip, as the arrange view's clip is taken: the window that
--- had the keyboard says which.
function view:on_show()
  local other = daw.ui.views[daw.ui.focused]
  if not other or other == self or type(other.clip) ~= "function" then return end
  local clip = other:clip()
  if not clip or clip.kind ~= "midi" or clip.id == self.clip_id then return end
  self.clip_id, self.beat, self.scroll, self.top = clip.id, 0, 0, nil
  local notes = clip:notes()
  self.pitch = notes[1] and notes[1].pitch or 60
  clips.only()
end

--- The time this view shows, for windows bound in time (`timebind`): the
--- project's beat at the left edge, columns per beat, and beats shown.
--- The roll counts beats from the active clip's start.
function view:time_axis()
  local clip = self:clip()
  if not clip then return nil end
  return clip.start + self.scroll, daw.opt.note_zoom, self.geometry and self.geometry.span
end

function view:set_time_axis(left, zoom)
  local clip = self:clip()
  if not clip then return end
  -- As far left as the earliest clip edited starts, as the roll scrolls.
  local lo = clips.span()
  self.scroll = math.max(math.min(0, math.floor(lo or 0)), left - clip.start)
  if zoom and daw.opt.note_zoom ~= zoom then daw.opt.note_zoom = zoom end
end

--- The note under the cursor in any of the clips edited, the active one's
--- first: the note (its start in the roll's beats), its place among its
--- clip's notes, and its part.
function view:note_at(pitch, beat)
  if not self:clip() or pitch < 0 or pitch > 127 then return end
  return clips.note_at(pitch, beat)
end

--- Rows above the notes on a panel `h` rows tall: the panel's title, the
--- chord symbols when `daw.opt.chords` asks for them and there is room,
--- then the ruler.
function view.head_rows(h)
  return (daw.opt.chords and h >= 12) and 3 or 2
end
-- Switches a module adds to the window's piano roll toolbar: `fn()`
-- returns `{ label, on, tip, act }` (`act` names the `daw.frontend.act`
-- function a click calls, given the clip), or nil to show none for now.
view.tools = {}

function view:tool(name, fn)
  for i = #self.tools, 1, -1 do
    if self.tools[i].name == name then table.remove(self.tools, i) end
  end
  if fn then self.tools[#self.tools + 1] = { name = name, fn = fn } end
end

function view:toolbar()
  local out = {}
  for _, tool in ipairs(self.tools) do
    local ok, t = pcall(tool.fn)
    if ok and type(t) == "table" then out[#out + 1] = t end
  end
  return out
end

-- Keys that hold for a while: a module whose state takes keys of its own
-- (a suggestion showing, a snippet being filled in) names a scope of
-- mappings and says when it is on; while it is, its keys come before the
-- piano roll's, earlier entries first (`daw.keymap` looks here through
-- `subscope`).
--
--   daw.ui.views.pianoroll:key_scope("pianoroll.complete", 50, function() return shown ~= nil end)
view.key_scopes = {}

function view:key_scope(name, order, active)
  for i = #self.key_scopes, 1, -1 do
    if self.key_scopes[i].name == name then table.remove(self.key_scopes, i) end
  end
  if not active then return end
  self.key_scopes[#self.key_scopes + 1] = { name = name, order = order, active = active }
  table.sort(self.key_scopes, function(a, b) return a.order < b.order end)
end

function view:subscope()
  local out = {}
  for _, scope in ipairs(self.key_scopes) do
    local ok, on = pcall(scope.active)
    if ok and on then out[#out + 1] = scope.name end
  end
  return #out > 0 and out or nil
end

-- Layers that modules draw over the roll, from back to front by `order`:
-- other tracks' notes ("context", 10), the notes of the clips edited
-- ("notes", 20), diagnostics 30, the notes insert mode is drawing
-- ("draw", 35), a snippet's marks 40, suggestions 50; the
-- selection and the cursor last of all.
view.layers = {}
local NOTES = 20

--- Draw `paint(p)` as a layer of the roll, replacing one of the same name
--- (nil removes it). `p` holds `roll` and `ruler` (cell buffers), `clip`
--- (the active one), `data` (its fields), `parts` (every clip edited, see
--- `daw.roll_clips`), `x(beat)` (a column of the roll), `row(pitch)` (a
--- row, nil when off screen), `scroll`, `from` and `to` (the beats that
--- show), `zoom`, `top`, `rows`, `width`, `focused` and `hue`. Beats are the
--- roll's: the active clip's.
---
--- `marks(clip_id)`, if given, lists what the window draws for the layer:
--- `{ pitch, start, length }` in the clip's beats, with `fill` (`#rrggbb`),
--- `alpha` (0 to 1), `edge` (a border colour), `label`; `badge = true` for
--- a chip with the label on the row of `pitch`, as wide as its text, `slot`
--- putting chips side by side (in steps of 20 px; a chip with a longer
--- label takes the last slot); `act` and `arg` for what a click on it does,
--- the name of a `daw.frontend.act` function given the clip and `arg`, and
--- `tip` for what the pointer on it says. A failing layer is skipped.
function view.layer(name, order, paint, marks)
  for i = #view.layers, 1, -1 do
    if view.layers[i].name == name then table.remove(view.layers, i) end
  end
  if paint or marks then view.layers[#view.layers + 1] = { name = name, order = order, paint = paint, marks = marks } end
  table.sort(view.layers, function(a, b) return a.order < b.order end)
  api.ui_redraw()
end

local function paint_layers(p, from, to)
  for _, layer in ipairs(view.layers) do
    if layer.paint and layer.order >= from and layer.order < to then
      local ok, err = pcall(layer.paint, p)
      if not ok then api.log("piano roll layer " .. layer.name .. ": " .. tostring(err)) end
    end
  end
end

--- What the window draws of the layers for `clip_id`: those behind the
--- clip's notes and those in front of them.
function view:marks(clip_id)
  local under, over = {}, {}
  for _, layer in ipairs(self.layers) do
    if layer.marks then
      local ok, list = pcall(layer.marks, clip_id)
      if ok and type(list) == "table" then
        local into = layer.order < NOTES and under or over
        for _, mark in ipairs(list) do into[#into + 1] = mark end
      elseif not ok then
        api.log("piano roll layer " .. layer.name .. ": " .. tostring(list))
      end
    end
  end
  return under, over
end

-- Other tracks' notes, behind the clips' own. In the terminal each is a
-- dashed line on a faint shade of its track's colour, without a name: the
-- clips' own notes are solid and named. The window is handed them with the
-- clip (`daw.frontend.clip`), not with every look at the layers: there may
-- be thousands, and they change only with the project.
view.layer("context", 10, function(L)
  local glyph = daw.opt.ascii and "-" or "╌"
  for _, n in ipairs(clips.context()) do
    local row = L.row(n.pitch)
    if row and n.start < L.to and n.start + n.length > L.from then
      local x0 = math.floor((n.start - L.from) * L.zoom + 0.5)
      local x1 = math.floor((n.start + n.length - L.from) * L.zoom + 0.5)
      L.roll:fill(x0, row, math.max(1, x1 - x0), 1, glyph, daw.draw.hue(n.color).body)
    end
  end
end)

-- The notes of the clips being edited.
view.layer("notes", 20, function(L)
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
        -- Long enough notes say which they are, or the articulation
        -- (MIDI 2.0 attribute) they carry.
        if nw >= 4 then
          local said = note.attr and daw.attr.describe(note.attr)
          L.roll:text(x0 + 1, row, (said and said.tag or music.name(note.pitch)):sub(1, nw - 1))
        end
      end
    end
  end)

-- The window draws notes itself: an attribute is a chip at a note's start.
view.layer("attr", 25, nil, function(clip_id)
  local out, fill = {}, nil
  for _, n in ipairs(api.clip_notes(clip_id)) do
    local said = n.attr and daw.attr.describe(n.attr)
    if said then
      fill = fill or daw.draw.track_colour(api.track_get(api.clip_get(clip_id).track))
      out[#out + 1] = { pitch = n.pitch, start = n.start, length = n.length, badge = true, label = said.tag, tip = said.text,
        fill = fill, alpha = 0.9 }
    end
  end
  return out
end)

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
    local lead = "Put the cursor on a MIDI clip in the arrange view and press "
    buf:text(2, 3, lead, "Empty")
    buf:text(2 + #lead, 3, "Enter", "EmptyKey")
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
  local head = view.head_rows(h)
  self.head = head
  local rows, tw = h - head - vel, w - KEYS
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
  self.scroll = math.max(math.min(0, math.floor(lo)), self.scroll)
  self.geometry = { rows = rows, zoom = zoom, keys = KEYS, head = head, vel = vel, span = span }

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
    local text = " " .. daw.roll_draw.label() .. " "
    buf:text(math.max(0, w - api.str_width(text) - 1), 0, text, "RulerInsert")
  end

  -- Ruler: bars as the project counts them, beats in between; above it
  -- the chords that sound, read over every pitched track, and the key.
  buf:fill(0, head - 1, w, 1, " ", "Ruler")
  local roll = buf:sub(KEYS, head, tw, rows)
  local ruler = buf:sub(KEYS, head - 1, tw, 1)
  if head == 3 then
    buf:fill(0, 1, w, 1, " ", "Ruler")
    local key = daw.harmony.key(c.start + self.scroll)
    buf:text(0, 1, (key.name:gsub(" major", ""):gsub(" minor", "m")):sub(1, KEYS - 1), "RulerChordEdge")
    daw.harmony.draw(buf:sub(KEYS, 1, tw, 1), self.scroll, span, zoom, c.start)
  end
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

  -- What the track's instrument calls its keys (a drum, a keyswitch) is
  -- written on them.
  local key_names = daw.plugins.key_names(c.track)
  -- The keys that sound at the cursor, in any clip shown, are marked.
  local sounds = {}
  for _, pitch in ipairs(sounding) do sounds[pitch] = true end
  local start_x = math.floor((lo - self.scroll) * zoom + 0.5)
  local end_x = math.floor((hi - self.scroll) * zoom + 0.5)
  for row = 0, rows - 1 do
    local pitch = self.top - row
    daw.draw.piano_key(buf, row + head, pitch, pitch == self.pitch, KEYS, key_names[pitch])
    if sounds[pitch] then buf:text(KEYS - 1, row + head, "•", "PianoCursor") end
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
    roll = roll, ruler = ruler, clip = clip, data = c, scroll = self.scroll, from = self.scroll, to = self.scroll + span,
    top = self.top, rows = rows, zoom = zoom, width = tw, focused = ctx.focused, parts = parts, hue = hue,
    under_place = under_place, under_part = under_part,
    x = function(beat) return math.floor((beat - self.scroll) * zoom + 0.5) end,
    row = function(pitch)
      local row = self.top - pitch
      return row >= 0 and row < rows and row or nil
    end,
  }
  paint_layers(L, -math.huge, math.huge)

  -- How hard each note on screen is played, along the bottom.
  if vel > 0 then
    local lane = buf:sub(KEYS, head + rows, tw, vel)
    buf:fill(0, head + rows, w, vel, " ", "VelocityLane")
    buf:text(1, head + rows + vel - 1, "vel", "VelocityLane")
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
  -- A selection takes in the note under its far end, as Vim's takes in the
  -- character under the cursor.
  extent = function(row, col)
    local note = view:note_at(row, col)
    if note then return note.start + note.length end
  end,
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

--- What `K` shows before the track: the note under the cursor.
function view:describe()
  local note, _, part = self:note_at(self.pitch, self.beat)
  if not note then return nil end
  local lines = {
    { text = "Note  " .. music.name(note.pitch), style = "Title" },
    string.format("  from beat %g, %g beats long, velocity %d", note.start, note.length, note.velocity),
  }
  local said = note.attr and daw.attr.describe(note.attr)
  if said then lines[#lines + 1] = "  articulation: " .. said.text end
  local key = daw.plugins.key_names(part.track)[note.pitch]
  if key then lines[#lines + 1] = "  the instrument calls this key " .. key end
  lines[#lines + 1] = ""
  return lines
end

--- Change the note under the cursor with `fn(note)`, the note's start in
--- its own clip's beats, which it does not leave. Returns whether there was one.
function view:change(fn)
  local _, place, part = self:note_at(self.pitch, self.beat)
  if not place then return false end
  local note = part.clip:notes()[place]
  fn(note)
  part.clip:set_note(place, {
    start = note.start, length = note.length, pitch = note.pitch, velocity = note.velocity, meta = note.meta or {},
    attr = note.attr or false,
  })
  return true
end

daw.ui.view("pianoroll", view)
-- Insert mode's drawing, which draws on the roll as one of its layers.
daw.roll_draw = require("daw.roll_draw")
return view
