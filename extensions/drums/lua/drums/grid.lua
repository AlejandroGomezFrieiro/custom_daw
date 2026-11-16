-- The drum grid in the terminal: a clip of a drum track shown through its
-- drum map, one row per piece with its name, one column per step, each hit
-- drawn as tall as it is hard. It is a piano roll whose rows are the pieces
-- of the kit, and takes the same grammar: motions, counts, operators, text
-- objects, visual mode, registers and `.`.
local api = daw.api
local util = daw.util
local drums = require("drums")
local E = require("drums.edit")

local CW = 3      -- columns a step takes: a separator, then the hit
local HEAD = 2    -- the title, then the ruler
local EPS = 1e-6

local view = {
  clip_id = nil,
  row = 1,         -- cursor row, a place in `rows()`
  beat = 0,        -- cursor, in beats from the start of the clip
  step = nil,      -- beats a column is; daw.opt.drums_step until changed
  first = 1,       -- the row at the top of the screen
  scroll = 0,      -- the cell at the left edge
}

function view:clip()
  if self.clip_id and pcall(api.clip_get, self.clip_id) then return daw.clip(self.clip_id) end
  self.clip_id = nil
end

function view:track_id()
  local clip = self:clip()
  return clip and api.clip_get(clip.id).track
end

--- The rows the open clip is shown with.
function view:rows()
  local clip = self:clip()
  if not clip then return {} end
  return drums.rows(self:track_id(), clip)
end

function view:step_size()
  return self.step or daw.opt.drums_step
end

--- The piece under the cursor: `{ note, name }`.
function view:piece()
  return self:rows()[self.row]
end

--- Open a clip of a drum track in the grid, with the cursor on its first hit.
function view:edit(clip)
  if type(clip) == "number" then clip = daw.clip(clip) end
  if clip.kind ~= "midi" then return daw.notify("only MIDI clips open in the drum grid", "warn") end
  self.clip_id, self.beat, self.scroll, self.first = clip.id, 0, 0, 1
  self.row = 1
  local rows = drums.rows(clip:get().track, clip)
  local first = clip:notes()[1]
  if first then
    for i, row in ipairs(rows) do
      if row.note == first.pitch then self.row, self.beat = i, E.cell(first.start, self:step_size()) * self:step_size() end
    end
  end
  daw.ui.focus("drums")
end

local eighths = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

--- How a hit of some velocity is drawn: a bar as tall as it is hard.
function view.glyph(velocity)
  return daw.draw.g.eighths[util.clamp(math.ceil(velocity / 127 * 8), 1, 8)]
end

function view:render(buf, ctx)
  local w, h = buf.width, buf.height
  local clip = self:clip()
  local g = daw.draw.g
  buf:fill(0, 0, w, h, " ", "Normal")
  if not clip then
    daw.ui.titlebar(buf, { name = "Drum grid", focused = ctx.focused })
    buf:text(2, 2, "No clip open. Put the cursor on a clip of a drum track and press", "Empty")
    buf:text(67, 2, "Enter", "EmptyKey")
    buf:text(2, 4, ":drums.track", "EmptyKey")
    buf:text(15, 4, "makes a drum track;", "Empty")
    buf:text(35, 4, ":drums.map", "EmptyKey")
    buf:text(46, 4, "makes any track one.", "Empty")
    return
  end
  local c = clip:get()
  local track = api.track_get(c.track)
  local hue = daw.draw.track_hue(track)
  local rows = self:rows()
  local step = self:step_size()
  local info = drums.info(c.track)
  self.row = util.clamp(self.row, 1, math.max(1, #rows))

  -- The names on the left: as wide as the longest, within reason.
  local namew = 6
  for _, row in ipairs(rows) do namew = math.max(namew, api.str_width(row.name) + 2) end
  namew = math.min(namew, 16)
  local body = h - HEAD
  local cells = math.max(1, math.floor((w - namew) / CW))
  local total = math.max(1, math.ceil(c.length / step - EPS))

  -- Keep the cursor on screen.
  local cur = E.cell(self.beat, step)
  if cur < self.scroll then self.scroll = cur end
  if cur >= self.scroll + cells then self.scroll = cur - cells + 1 end
  self.scroll = math.max(0, self.scroll)
  if self.row < self.first then self.first = self.row end
  if self.row >= self.first + body then self.first = self.row - body + 1 end
  self.first = math.max(1, self.first)
  self.geometry = { namew = namew, cells = cells, body = body }

  -- Title: the clip in its track's colour, the piece and place under the cursor, the step.
  local piece = rows[self.row]
  local under = piece and E.hit(clip, piece.note, cur * step, step)
  local status = string.format("step %s  vel %d%s  %s", E.step_label(step),
    under and under.velocity or daw.opt.drums_velocity, under and "" or " new", info and info.map or "")
  daw.ui.titlebar(buf, {
    pill = { c.name, hue.pill }, name = track.name, focused = ctx.focused,
    context = string.format("%s  %s", piece and piece.name or "-", daw.time.format(c.start + self.beat)),
    right = status,
  })

  -- The ruler: bars as the project counts them, beats between as ticks, as in the roll.
  buf:fill(0, 1, w, 1, " ", "Ruler")
  local bar = daw.time.bar()
  for i = 0, cells - 1 do
    local cell = self.scroll + i
    if cell >= total then break end
    local pos = c.start + cell * step
    local cx = namew + i * CW
    local on_bar = math.abs(pos / bar - math.floor(pos / bar + 0.5)) < EPS
    local on_beat = math.abs(pos - math.floor(pos + 0.5)) < EPS
    if on_bar then
      buf:text(cx, 1, tostring(math.floor(pos / bar + 0.5) + 1), "RulerBar")
    elseif on_beat then
      buf:text(cx, 1, g.tick, "RulerTick")
    end
  end

  -- The rows: name, then a cell per step.
  local hits = E.cells(clip, step, self.scroll * step, (self.scroll + cells) * step)
  local selection = ctx.focused and daw.keymap.selection()
  for r = 0, body - 1 do
    local index = self.first + r
    local row = rows[index]
    local y = HEAD + r
    if not row then break end
    local on_row = index == self.row
    buf:fill(0, y, namew, 1, " ", on_row and "TrackHeaderSel" or "TrackHeader")
    buf:text(1, y, row.name, row.extra and "Faint" or on_row and hue.fg or nil)
    for i = 0, cells - 1 do
      local cell = self.scroll + i
      local cx = namew + i * CW
      if cell >= total then
        buf:fill(cx, y, w - cx, 1, " ", "RollOutside")
        break
      end
      local pos = cell * step
      local beat_no = math.floor((c.start + pos) + EPS)
      -- Every other beat a shade darker, so that a bar reads at a glance.
      local style = beat_no % 2 == 0 and "RollRow" or "RollRowBlack"
      buf:fill(cx, y, CW, 1, " ", style)
      local abs = c.start + pos
      if math.abs(abs / bar - math.floor(abs / bar + 0.5)) < EPS then
        buf:text(cx, y, g.bar, "RollBar")
      elseif math.abs(abs - math.floor(abs + 0.5)) < EPS then
        buf:text(cx, y, g.beat, "RollBeat")
      end
      local hit = hits[row.note] and hits[row.note][cell]
      if hit then
        local glyph = view.glyph(hit.velocity)
        buf:text(cx + 1, y, glyph .. (hit.off and "'" or glyph), hue.fg)
      else
        buf:text(cx + 1, y, g.dot, "Faint")
      end
      if selection then
        local in_time = selection.kind == "line" or (pos >= selection.c0 - EPS and pos < selection.c1 - EPS)
        local in_rows = selection.kind == "char" or (index >= selection.r0 and index <= selection.r1)
        if in_time and in_rows then buf:fill(cx + 1, y, CW - 1, 1, nil, "Visual") end
      end
      if on_row and cell == cur and not selection then
        buf:fill(cx + 1, y, CW - 1, 1, nil, hit and "NoteCursor" or "RollCursor")
      end
    end
  end

  -- The playhead.
  local t = api.transport_get()
  if t.position >= c.start and t.position < c.start + c.length then
    local i = E.cell(t.position - c.start, step) - self.scroll
    if i >= 0 and i < cells then
      local cx = namew + i * CW
      buf:text(cx, 1, g.cap, "RulerPlayhead")
      for r = 0, math.min(body, #rows - self.first + 1) - 1 do buf:fill(cx, HEAD + r, 1, 1, nil, "PlayheadShade") end
    end
  end
end

-- Moving --------------------------------------------------------------------

function view:set(row, beat)
  local clip = self:clip()
  if not clip then return end
  if row then self.row = util.clamp(row, 1, math.max(1, #self:rows())) end
  if beat then self.beat = util.clamp(beat, 0, clip.length) end
  api.ui_redraw()
end

function view:move(dsteps, drows)
  local clip = self:clip()
  if not clip then return end
  local step = self:step_size()
  -- One step past the last is allowed, so that a selection can reach the end.
  local to = (E.cell(self.beat, step) + dsteps) * step
  self:set(self.row + drows, util.clamp(to, 0, clip.length))
end

--- The next (`dir` 1) or previous (-1) hit on the cursor's row.
function view:to_hit(dir, count)
  local piece, clip = self:piece(), self:clip()
  if not (piece and clip) then return end
  local starts = {}
  for _, n in ipairs(clip:notes({ low = piece.note, high = piece.note })) do starts[#starts + 1] = n.start end
  for _ = 1, count or 1 do
    local found
    if dir > 0 then
      for _, s in ipairs(starts) do
        if s > self.beat + EPS then found = s break end
      end
    else
      for i = #starts, 1, -1 do
        if starts[i] < self.beat - EPS then found = starts[i] break end
      end
    end
    if not found then return end
    self:set(nil, E.cell(found, self:step_size()) * self:step_size())
  end
end

function view:to_bar(n)
  local clip = self:clip()
  if not clip then return end
  local bar = daw.time.bar()
  local at = (clip.start + self.beat) / bar
  local to = n > 0 and math.floor(at + EPS) + n or math.ceil(at - EPS) + n
  self:set(nil, to * bar - clip.start)
end

-- Changing ------------------------------------------------------------------

--- Put a hit in at the cursor or take it out; a new hit is heard.
function view:toggle()
  local clip, piece = self:clip(), self:piece()
  if not (clip and piece) then return end
  local step = self:step_size()
  local beat = E.cell(self.beat, step) * step
  if E.set(clip, piece.note, beat, step, nil, daw.opt.drums_velocity) then self:hear() end
end

function view:hear(note)
  local track, piece = self:track_id(), self:piece()
  if track and (note or piece) then drums.hear(track, note or piece.note) end
end

--- Harder (`by` > 0) or softer: the hit under the cursor.
function view:velocity(by)
  local clip, piece = self:clip(), self:piece()
  if not (clip and piece) then return end
  local step = self:step_size()
  local v = E.velocity(clip, piece.note, E.cell(self.beat, step) * step, step, by)
  if v then daw.notify(piece.name .. " velocity " .. v) end
end

function view:set_step(step)
  self.step = step
  -- The cursor stays on a step of the new grid.
  self.beat = E.cell(self.beat, step) * step
  daw.notify("step " .. E.step_label(step))
  api.ui_redraw()
end

-- What modal editing works on: rows are the pieces, counted downwards.
view.grid = {
  get = function() return view.row, view.beat end,
  set = function(row, col) view:set(row, col) end,
  step = function() return view:step_size() end,
  -- Pieces by name: `/snare` goes to the snare's row.
  search = function(text)
    local wanted, out = text:lower(), {}
    for i, row in ipairs(view:rows()) do
      if row.name:lower():find(wanted, 1, true) then out[#out + 1] = { row = i, col = view.beat } end
    end
    return out
  end,
}

function view:on_mouse(event)
  local g = self.geometry
  if not g or not self:clip() then return end
  if event.kind == "scroll_up" then self.first = math.max(1, self.first - 2) end
  if event.kind == "scroll_down" then self.first = self.first + 2 end
  local r = event.y - HEAD
  if event.kind == "down" and r >= 0 and r < g.body then
    local index = self.first + r
    if index > #self:rows() then return end
    self.row = index
    if event.x >= g.namew then
      local step = self:step_size()
      self.beat = (self.scroll + math.floor((event.x - g.namew) / CW)) * step
      if event.button == "left" then self:toggle() end
    else
      self:hear()
    end
  end
  api.ui_redraw()
end

daw.ui.view("drums", view)
daw.ui.dock("drums", { side = "bottom", hidden = true })

return view
