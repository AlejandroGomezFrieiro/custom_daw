-- The drum grid in a graphical frontend: the terminal grid's view, painted
-- in pixels and worked with the pointer (see runtime/lua/paw/canvas.lua).
--
--   toolbar   the clip, play and loop the clip, the step (straight and
--             triplet), the clip's length in bars
--   ruler     bars and beats; a click moves the playhead
--   rows      a piece each: click its name to hear it; click a cell for a
--             hit, click a hit to take it out; drag along the row to paint
--             hits or erase them; right click removes
--   velocity  how hard each hit of the selected row is: click or drag
--
-- Every key of the terminal grid works in the window too.
local api = paw.api
local util = paw.util
local drums = require("drums")
local E = require("drums.edit")
local view = require("drums.grid")

local c = require("paw.canvas").palette
local TOOLBAR, RULER, NAMES, ROW, VEL, INFO = 40, 24, 132, 26, 72, 26
local EPS = 1e-6

-- What only the window keeps: how wide a step is, what is scrolled to, what
-- is being dragged, and where the buttons are.
local gui = { cellw = nil, scroll = 0, top = 0, drag = nil, buttons = {}, layout = nil }
view.gui = gui

local function mix(a, b, t) return paw.draw.mix(a, b, t) end

--- A button of the toolbar: drawn, and remembered for the pointer.
local function button(g, x, label, on, action, opts)
  local w = (opts and opts.width) or (api.str_width(label) * 7 + 18)
  g:rect(x, 9, w, 22, { fill = on and c.select or c.control, radius = 5 })
  g:text(x + w / 2, 13, label, { color = on and c.surface or (opts and opts.color) or c.text, bold = on, align = "center", width = w })
  gui.buttons[#gui.buttons + 1] = { x = x, y = 9, w = w, h = 22, action = action, label = label }
  return x + w + 6
end

--- Play the clip round and round from its start, or stop.
local function play_clip(clip)
  local t = paw.transport
  if api.transport_get().playing then return t.stop() end
  t.loop_start, t.loop_end, t.loop_enabled = clip.start, clip.start + clip.length, true
  t.seek(clip.start)
  t.play()
end

function view:paint(g, ctx)
  local w, h = ctx.width, ctx.height
  gui.buttons = {}
  g:rect(0, 0, w, h, { fill = c.surface })
  local clip = self:clip()
  if not clip then
    gui.layout = nil
    g:text(24, 24, "No drum clip is open.", { color = c.text, size = 16, bold = true })
    g:text(24, 50, "Double click a clip of a drum track. `:drums.track` makes one; `:drums.map` turns any track into one.", { color = c.text_2 })
    return
  end
  local data = clip:get()
  local track = api.track_get(data.track)
  local hue = paw.draw.track_colour(track)
  local rows = self:rows()
  local step = self:step_size()
  local total = math.max(1, math.ceil(data.length / step - EPS))
  local grid_w = w - NAMES
  local body_h = h - TOOLBAR - RULER - VEL - INFO
  -- Steps as wide as fits the clip, within reason; wider clips scroll.
  local cellw = gui.cellw or util.clamp(math.floor((grid_w - 8) / total), 14, 44)
  local visible_rows = math.max(1, math.floor(body_h / ROW))
  gui.top = util.clamp(gui.top, 0, math.max(0, #rows - visible_rows))
  gui.scroll = util.clamp(gui.scroll, 0, math.max(0, total * cellw - grid_w + 8))
  -- Keep the keyboard's cursor in view.
  if self.row - 1 < gui.top then gui.top = self.row - 1 end
  if self.row - 1 >= gui.top + visible_rows then gui.top = self.row - visible_rows end
  gui.layout = { cellw = cellw, total = total, rows = #rows, body_h = body_h, grid_w = grid_w, step = step }

  local function x_of(cell) return cell * cellw - gui.scroll end
  local function y_of(index) return (index - 1 - gui.top) * ROW end

  -- Toolbar.
  g:rect(0, 0, w, TOOLBAR, { fill = c.panel })
  local namew = api.str_width(data.name) * 7 + 22
  g:rect(10, 9, namew, 22, { fill = hue, radius = 5 })
  g:text(21, 13, data.name, { color = c.surface, bold = true })
  local x = 10 + namew + 10
  g:text(x, 13, track.name, { color = c.text_2 })
  x = x + api.str_width(track.name) * 7 + 14
  local playing = api.transport_get().playing
  x = button(g, x, playing and "■ stop" or "▶ play", playing, function() play_clip(clip) end)
  x = x + 10
  for _, s in ipairs({ { 1, "1/4" }, { 1 / 2, "1/8" }, { 1 / 4, "1/16" }, { 1 / 8, "1/32" } }) do
    x = button(g, x, s[2], math.abs(step - s[1]) < EPS, function() view:set_step(s[1]) end)
  end
  x = x + 6
  for _, s in ipairs({ { 1 / 3, "1/8T" }, { 1 / 6, "1/16T" } }) do
    x = button(g, x, s[2], math.abs(step - s[1]) < EPS, function() view:set_step(s[1]) end)
  end
  x = x + 10
  local bar = paw.time.bar()
  local bars = data.length / bar
  x = button(g, x, "−", false, function() E.set_bars(clip, math.max(1, math.ceil(bars - EPS) - 1)) end, { width = 24 })
  g:text(x + 2, 13, string.format(bars % 1 < EPS and "%d bar%s" or "%.2f bars", bars, bars == 1 and "" or "s"), { color = c.text })
  x = x + 62
  button(g, x, "+", false, function() E.set_bars(clip, math.floor(bars + EPS) + 1) end, { width = 24 })

  -- Ruler.
  local top = TOOLBAR
  g:rect(0, top, w, RULER, { fill = c.panel })
  local ruler = g:sub(NAMES, top, grid_w, RULER)
  local cells = g:sub(NAMES, top + RULER, grid_w, body_h)
  local names = g:sub(0, top + RULER, NAMES, body_h)
  for cell = 0, total - 1 do
    local cx = x_of(cell)
    if cx > grid_w then break end
    local pos = data.start + cell * step
    local on_bar = math.abs(pos / bar - math.floor(pos / bar + 0.5)) < EPS
    local on_beat = math.abs(pos - math.floor(pos + 0.5)) < EPS
    if on_bar then
      ruler:text(cx + 4, 4, tostring(math.floor(pos / bar + 0.5) + 1), { color = c.text, bold = true })
    elseif on_beat and cellw >= 14 then
      ruler:text(cx + 3, 5, "·" .. (math.floor(pos % bar + 0.5) + 1), { color = c.text_3, size = 11 })
    end
  end

  -- Rows: the name, then a cell per step.
  local hits = E.cells(clip, step, 0, data.length)
  local drag = gui.drag
  for index, row in ipairs(rows) do
    local y = y_of(index)
    if y >= body_h then break end
    if y > -ROW then
      local on_row = index == self.row
      names:rect(0, y, NAMES, ROW, { fill = on_row and c.control or c.panel })
      names:rect(0, y, 4, ROW, { fill = on_row and hue or c.panel })
      names:text(12, y + 6, row.name, { color = row.extra and c.text_3 or on_row and c.text or c.text, bold = on_row, width = NAMES - 48 })
      names:text(NAMES - 36, y + 7, tostring(row.note), { color = c.text_3, size = 10, align = "right", width = 28 })
      for cell = 0, total - 1 do
        local cx = x_of(cell)
        if cx > grid_w then break end
        if cx + cellw >= 0 then
          local pos = data.start + cell * step
          local beat_no = math.floor(pos + EPS)
          cells:rect(cx, y, cellw, ROW, { fill = beat_no % 2 == 0 and c.surface or c.well })
          local hit = hits[row.note] and hits[row.note][cell]
          local velocity = hit and hit.velocity
          -- What a drag is about to do shows before it is done.
          if drag and drag.row == index and drag.cells and drag.cells[cell] ~= nil then
            velocity = drag.cells[cell] and paw.opt.drums_velocity or nil
          end
          if drag and drag.mode == "velocity" and index == self.row and velocity and drag.values[cell] then
            velocity = drag.values[cell]
          end
          if velocity then
            local fill = mix(c.surface, hue, 0.3 + 0.7 * velocity / 127)
            cells:rect(cx + 2, y + 3, cellw - 4, ROW - 6, { fill = fill, radius = 3,
              stroke = (on_row and cell == E.cell(self.beat, step)) and c.text or nil, width = 2 })
            if hit and hit.off then cells:rect(cx + cellw - 6, y + 4, 3, 3, { fill = c.surface }) end
          else
            cells:rect(cx + cellw / 2 - 1, y + ROW / 2 - 1, 2, 2, { fill = c.line_bar })
            if on_row and cell == E.cell(self.beat, step) then
              cells:rect(cx + 2, y + 3, cellw - 4, ROW - 6, { stroke = c.select, radius = 3, width = 1.5 })
            end
          end
        end
      end
      cells:line(0, y + ROW, grid_w, y + ROW, { color = c.line_beat })
    end
  end
  -- Beat and bar lines over the cells.
  for cell = 0, total do
    local cx = x_of(cell)
    if cx > grid_w then break end
    local pos = data.start + cell * step
    if math.abs(pos / bar - math.floor(pos / bar + 0.5)) < EPS then
      cells:line(cx, 0, cx, body_h, { color = c.text_3, width = 1.5 })
    elseif math.abs(pos - math.floor(pos + 0.5)) < EPS then
      cells:line(cx, 0, cx, body_h, { color = c.line_bar })
    end
  end
  -- Past the end of the clip.
  local end_x = x_of(total)
  if end_x < grid_w then cells:rect(end_x, 0, grid_w - end_x, body_h, { fill = "#000000aa" }) end

  -- The playhead.
  local t = api.transport_get()
  if t.position >= data.start and t.position <= data.start + data.length then
    local px = (t.position - data.start) / step * cellw - gui.scroll
    cells:line(px, 0, px, body_h, { color = c.play, width = 1 })
    ruler:poly({ px - 4.5, RULER - 6, px + 4.5, RULER - 6, px, RULER }, { fill = c.play })
  end

  -- How hard each hit of the selected row is.
  local vy = TOOLBAR + RULER + body_h
  g:rect(0, vy, w, VEL, { fill = c.panel })
  local piece = rows[self.row]
  g:text(12, vy + 8, "velocity", { color = c.text_3, size = 11 })
  if piece then g:text(12, vy + 24, piece.name, { color = hue, bold = true, width = NAMES - 20 }) end
  local lane = g:sub(NAMES, vy, grid_w, VEL)
  for cell = 0, total - 1 do
    local cx = x_of(cell)
    if cx > grid_w then break end
    local hit = piece and hits[piece.note] and hits[piece.note][cell]
    local v = hit and hit.velocity
    if v and drag and drag.mode == "velocity" and drag.values[cell] then v = drag.values[cell] end
    if v then
      local bh = (VEL - 12) * v / 127
      lane:rect(cx + 3, VEL - 6 - bh, math.max(3, cellw - 6), bh, { fill = hue, radius = 2 })
    end
  end

  -- What the pointer does, or what is under the cursor.
  local iy = h - INFO
  g:rect(0, iy, w, INFO, { fill = c.control })
  local under = piece and E.hit(clip, piece.note, E.cell(self.beat, step) * step, step)
  local info = "click a cell for a hit · drag along a row paints, from a hit erases · right click removes · click a name to hear it · drag in the velocity lane"
  if under then
    info = string.format("%s  %s  velocity %d   ·   %s", piece.name, paw.time.format(data.start + under.start), under.velocity, info)
  end
  g:text(12, iy + 6, info, { color = c.text_2, width = w - 24 })
end

--- Where a point of the window is: "toolbar", "ruler", "names", "cells",
--- "velocity" or nil, with the row and the cell under it.
local function locate(e)
  local l = gui.layout
  if not l then return end
  if e.y < TOOLBAR then return "toolbar" end
  local cell = math.floor((e.x - NAMES + gui.scroll) / l.cellw)
  if cell < 0 or cell >= l.total then cell = nil end
  if e.y < TOOLBAR + RULER then return "ruler", nil, cell end
  local vy = TOOLBAR + RULER + l.body_h
  if e.y < vy then
    local row = math.floor((e.y - TOOLBAR - RULER) / ROW) + 1 + gui.top
    if row > l.rows then return end
    if e.x < NAMES then return "names", row end
    return "cells", row, cell
  end
  if e.y < vy + VEL and e.x >= NAMES then return "velocity", nil, cell end
end

local function velocity_at(e)
  local vy = TOOLBAR + RULER + gui.layout.body_h
  return drums.clamp_velocity((vy + VEL - 6 - e.y) / (VEL - 12) * 127)
end

--- Apply what a drag collected, as one edit.
local function finish(drag)
  local clip = view:clip()
  if not clip then return end
  local step = gui.layout.step
  if drag.mode == "paint" or drag.mode == "erase" then
    local piece = view:rows()[drag.row]
    if not piece then return end
    local add, remove, existing = {}, {}, {}
    for index, n in ipairs(clip:notes()) do
      if n.pitch == piece.note then
        local cell = E.cell(n.start, step)
        existing[cell] = true
        if drag.cells[cell] == false then remove[#remove + 1] = index end
      end
    end
    for cell, on in pairs(drag.cells) do
      if on and not existing[cell] and cell * step < clip.length - EPS then
        add[#add + 1] = { pitch = piece.note, start = cell * step, length = math.min(step, clip.length - cell * step), velocity = paw.opt.drums_velocity }
      end
    end
    if #add > 0 or #remove > 0 then clip:edit_notes({ add = add, remove = remove }) end
  elseif drag.mode == "velocity" then
    local piece = view:rows()[view.row]
    if not piece then return end
    local set = {}
    for index, n in ipairs(clip:notes()) do
      local v = n.pitch == piece.note and drag.values[E.cell(n.start, step)]
      if v and v ~= n.velocity then set[#set + 1] = { index = index, velocity = v } end
    end
    if #set > 0 then clip:edit_notes({ set = set }) end
  end
end

function view:pointer(e)
  local clip = self:clip()
  if not clip or not gui.layout then return end
  local l = gui.layout

  if e.kind == "wheel" then
    if e.ctrl then
      gui.cellw = util.clamp(l.cellw * (e.dy > 0 and 1.2 or 1 / 1.2), 8, 120)
    elseif e.shift then
      gui.scroll = math.max(0, gui.scroll - e.dy)
    else
      gui.top = math.max(0, gui.top - (e.dy > 0 and 1 or -1))
      gui.scroll = math.max(0, gui.scroll - (e.dx or 0))
    end
    return
  end

  local where, row, cell = locate(e)
  if e.kind == "down" or e.kind == "double" then
    gui.drag = nil
    if where == "toolbar" then
      for _, b in ipairs(gui.buttons) do
        if e.x >= b.x and e.x < b.x + b.w and e.y >= b.y and e.y < b.y + b.h then return b.action() end
      end
      return
    elseif where == "ruler" then
      local beat = math.max(0, (e.x - NAMES + gui.scroll) / l.cellw * l.step)
      return api.transport_seek(clip.start + math.floor(beat / l.step + 0.5) * l.step)
    elseif where == "names" then
      self.row = row
      return self:hear()
    elseif where == "cells" and cell then
      self.row, self.beat = row, cell * l.step
      local piece = self:rows()[row]
      local has = E.hit(clip, piece.note, cell * l.step, l.step) ~= nil
      local paint = e.button ~= "right" and not has
      gui.drag = { mode = paint and "paint" or "erase", row = row, cells = { [cell] = paint }, last = cell }
      if paint then self:hear() end
      return
    elseif where == "velocity" and cell then
      self.beat = cell * l.step
      gui.drag = { mode = "velocity", values = { [cell] = velocity_at(e) }, last = cell }
      return
    end
    return
  end

  local drag = gui.drag
  if not drag then return end
  if e.kind == "move" then
    if drag.mode == "velocity" then
      local at = math.floor((e.x - NAMES + gui.scroll) / l.cellw)
      if at >= 0 and at < l.total then
        -- Every cell crossed since the last move, so a quick stroke leaves no gaps.
        local from = drag.last or at
        for k = math.min(from, at), math.max(from, at) do drag.values[k] = velocity_at(e) end
        drag.last = at
      end
    else
      local at = math.floor((e.x - NAMES + gui.scroll) / l.cellw)
      if at >= 0 and at < l.total then
        local last = drag.last or at
        for k = math.min(last, at), math.max(last, at) do drag.cells[k] = drag.mode == "paint" end
        drag.last = at
        self.beat = at * l.step
      end
    end
  elseif e.kind == "up" then
    gui.drag = nil
    finish(drag)
  end
end

--- Open the window on the grid's clip.
function gui.open()
  local rows = #view:rows()
  local height = TOOLBAR + RULER + math.min(rows, 18) * ROW + VEL + INFO + 4
  gui.top, gui.scroll, gui.drag, gui.cellw = 0, 0, nil, nil
  paw.canvas.open("drums", { title = "Drum grid", width = 1040, height = height })
end

--- Closing the window puts the keyboard back in the arrange view, and
--- leaving the grid from the keyboard closes the window.
function view:on_close()
  gui.drag = nil
  paw.ui.hide("drums")
end

function view:on_hide()
  paw.canvas.close("drums")
end

return gui
