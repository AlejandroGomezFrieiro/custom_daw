-- The pointer in the arrange view: the window's gestures in cells. A press
-- finds what is under it (a clip and which part, a header's control, the
-- ruler's flags and edges, a lane's point), and the gesture calls
-- `paw.frontend.act` with beats, rows and values, as the window does. A
-- gesture that changes the project does so once, when the button is let
-- go, and is drawn over the view until then; one that moves a control or
-- a selection does so as it goes.
local api = paw.api
local util = paw.util
local mouse = paw.mouse
local menus = require("paw.mouse_menus")
local view = paw.ui.views.arrange
local A = paw.frontend.act

local function col(self, beat) return math.floor((beat - self.scroll) * self.geometry.zoom + 0.5) end
local function beat_at(self, tx) return mouse.beat(tx, self.scroll, self.geometry.zoom) end
local function grid_at(self, tx) return mouse.on_grid(tx, self.scroll, self.geometry.zoom, paw.opt.grid) end
local function cells(self, d) return d / self.geometry.zoom end

--- The clip of a track row under timeline column `tx`, and which part of it:
--- "start" or "end" (its first and last cells, when it is three cells or
--- more), "warp" with the marker's place, or "body".
local function clip_at(self, row, tx)
  local zoom = self.geometry.zoom
  local found, part, index
  for _, c in ipairs(api.clip_list(row.id)) do
    local x0 = col(self, c.start)
    local cw = math.max(1, col(self, c.start + c.length) - x0)
    if tx >= x0 and tx < x0 + cw then
      found, part, index = c, "body", nil
      for i, m in ipairs(c.warp or {}) do
        local nx = math.floor((m.beat - c.start) * zoom + 0.5)
        if nx > 0 and nx < cw and tx == x0 + nx then part, index = "warp", i end
      end
      if part == "body" then
        if cw >= 3 and tx == x0 then part = "start" elseif cw >= 2 and tx == x0 + cw - 1 then part = "end" end
      end
    end
  end
  return found, part, index
end

--- The tempo and signature flags on the ruler, where they are drawn.
local function ruler_marks(self)
  local out, mark_end = {}, -1
  for _, mark in ipairs(paw.tempo.marks(self.scroll, self.scroll + self.geometry.span)) do
    local x = col(self, mark.beat)
    if paw.tempo.is_bar_line(mark.beat) then x = x + #tostring(paw.time.bar_of(mark.beat)) end
    x = math.max(x, mark_end)
    local w = 1 + api.str_width(mark.text)
    out[#out + 1] = { x0 = x, x1 = x + w, mark = mark }
    mark_end = x + w + 1
  end
  return out
end

--- The marker or region whose name (or band) is under column `tx` of the
--- band under the ruler.
local function marker_at(self, tx)
  local list = paw.markers and paw.markers.list() or {}
  local width = self.geometry.layout.tw
  local band
  for i, m in ipairs(list) do
    local x = col(self, m.beat)
    local stop = width
    for j = i + 1, #list do
      local nx = col(self, list[j].beat)
      if nx > x then stop = math.min(stop, nx) break end
    end
    local w = 1 + api.str_width(paw.markers.label(m))
    if tx >= x and tx < math.min(stop, x + w) then return m end
    if m.length and tx >= x and tx < col(self, m.beat + m.length) then band = m end
  end
  return band
end

--- What is under the pointer at `x`, `y` of the view.
local function hit(self, x, y)
  local g = self.geometry
  local L = g.layout
  local out = { x = x, y = y, tx = x - g.hw, header = x < g.hw - 1, timeline = x >= g.hw }
  out.beat = beat_at(self, out.tx)
  local tempo_y = L.ruler_rows - L.tempo_rows
  if y == 0 then
    out.area = "ruler"
  elseif y < tempo_y then
    out.area = "markers"
  elseif y < L.ruler_rows then
    out.area, out.y0 = "tempo", tempo_y
  elseif y >= L.master.y then
    out.area = "master"
  else
    for _, row in ipairs(L.rows) do
      if y >= row.y and y < row.y + row.h then out.area, out.row = row.kind, row end
    end
    out.area = out.area or "below"
  end
  if out.area == "track" and out.timeline then out.clip, out.part, out.warp = clip_at(self, out.row, out.tx) end
  return out
end

--- The row of a drawn track (its place in `paw.groups.rows()`) at line `y`
--- of the view, the nearest one above or below when it is off the tracks.
local function row_index(self, y)
  local rows, best = self.geometry.layout.rows, nil
  for _, row in ipairs(rows) do
    if y >= row.y and y < row.y + row.h then return row.index end
    if row.y <= y then best = row.index end
  end
  return best or (rows[1] and rows[1].index) or 1
end

--- The line of the view where a drawn track's row is, if it is shown.
local function row_of(self, index)
  for _, row in ipairs(self.geometry.layout.rows) do
    if row.kind == "track" and row.index == index then return row end
  end
end

--- Where a gesture over the timeline is drawn: the view without its headers.
local function timeline(self, buf)
  local g = self.geometry
  return buf:sub(g.hw, 0, g.layout.tw, g.layout.master.y)
end

local function ghost(self, buf, row, start, length, text)
  local x0 = col(self, start)
  local w = math.max(1, col(self, start + length) - x0)
  local lanes = timeline(self, buf)
  lanes:fill(x0, row.y, w, row.h, nil, "MouseGhost")
  if text then lanes:text(x0 + 1, row.y, util.fit(text, math.max(0, w - 1)):gsub("%s+$", ""), "MouseGhost") end
end

local function box(buf, x0, y0, x1, y1)
  local g = paw.draw.g
  local l, r, t, b = math.min(x0, x1), math.max(x0, x1), math.min(y0, y1), math.max(y0, y1)
  buf:fill(l, t, r - l + 1, 1, g.h, "MouseBox")
  buf:fill(l, b, r - l + 1, 1, g.h, "MouseBox")
  buf:fill(l, t, 1, b - t + 1, g.v, "MouseBox")
  buf:fill(r, t, 1, b - t + 1, g.v, "MouseBox")
end

-- Clips ---------------------------------------------------------------------------

--- The clips a gesture on clip `id` moves: the chosen ones, if it is one.
local function grabbed(id)
  local ids = paw.frontend.chosen_clips()
  for _, other in ipairs(ids) do
    if other == id then return ids end
  end
  return { id }
end

local function among_chosen(id)
  local ids = paw.frontend.chosen_clips()
  for _, other in ipairs(ids) do
    if other == id then return #ids > 1 end
  end
  return false
end

--- A press on a clip: a click chooses it (Ctrl and Shift as the window),
--- a drag moves it and the chosen with it (Ctrl copies, Shift off the
--- grid), a drag of its first or last cell trims that edge (Alt slips what
--- plays inside, Alt and Shift on the end stretches it), a drag of a warp
--- marker moves it, a double click opens it.
local function press_clip(self, e, h)
  local c = h.clip
  if e.double then return A.open_clip(c.id) end
  local mode = mouse.mode(e)
  -- A plain press chooses at once, unless the clip is among the chosen:
  -- then a drag moves them all, and a click without one chooses it alone.
  local deferred = mode ~= "only" or among_chosen(c.id)
  if not deferred then A.select_clip(c.id, grid_at(self, h.tx), "only") end
  local free = mouse.has(e, "S")
  local function click() if deferred then A.select_clip(c.id, grid_at(self, h.tx), mode) end end
  if h.part == "warp" then
    local m = c.warp[h.warp]
    return mouse.grab(e, {
      arrange = function(v, buf)
        local d = mouse.gesture().d
        if d then timeline(v, buf):fill(col(v, m.beat) + d, h.row.y, 1, h.row.h, paw.draw.g.tick, "MouseGhost") end
      end,
      drag = function(d) mouse.gesture().d = d.dx end,
      up = function(u)
        if not u.moved then return click() end
        A.warp_move(c.id, h.warp, m.beat + cells(self, u.dx), free)
      end,
    })
  end
  local edge = (h.part == "start" or h.part == "end") and h.part or nil
  local copy, slip = mouse.has(e, "C"), mouse.has(e, "A")
  mouse.grab(e, {
    arrange = function(v, buf)
      local d = mouse.gesture().d
      if not d then return end
      local dbeat = cells(v, d.dx)
      if edge then
        local at = edge == "start" and c.start or c.start + c.length
        local to = free and math.max(0, at + dbeat) or math.max(0, paw.cursor.snap(at + dbeat))
        local a, b = c.start, c.start + c.length
        if edge == "start" then a = math.min(to, b - paw.opt.grid) else b = math.max(to, a + paw.opt.grid) end
        return ghost(v, buf, h.row, a, b - a, c.name)
      end
      local by = free and dbeat or util.round(dbeat, paw.opt.grid)
      local drows = row_index(v, d.y) - h.row.index
      local rows = {}
      for i, track in ipairs(paw.groups.rows()) do rows[track] = i end
      for _, id in ipairs(grabbed(c.id)) do
        local other = api.clip_get(id)
        local row = rows[other.track] and row_of(v, rows[other.track] + drows)
        if row then ghost(v, buf, row, math.max(0, other.start + by), other.length, other.name) end
      end
    end,
    drag = function(d)
      mouse.gesture().d = d
      local dbeat = cells(self, d.dx)
      local held = edge and (edge == "start" and c.start or c.start + c.length) or c.start
      mouse.hint(paw.time.format(math.max(0, held + dbeat)) .. (edge and "  trims the " .. edge or copy and "  copies" or "  moves"))
    end,
    up = function(u)
      if not u.moved then return click() end
      if edge then
        A.trim_clips(c.id, edge, cells(self, u.dx), free, slip)
      else
        A.drag_clips(c.id, cells(self, u.dx), row_index(self, u.y) - h.row.index, copy, free)
      end
    end,
  })
end

-- The empty timeline ------------------------------------------------------------------

--- A press where there is no clip: a click puts the cursor there and lets go
--- of the chosen clips, a drag selects that stretch of time on the tracks
--- it crosses, a double click makes a clip of a bar.
local function press_empty(self, e, h)
  local track = h.row.id
  if e.double then return A.add_clip(track, h.beat) end
  A.select(track, grid_at(self, h.tx))
  local row0, x0 = h.row.index, h.tx
  mouse.grab(e, {
    drag = function(d)
      if not d.moved then return end
      local tx = d.x - self.geometry.hw
      -- The cells from the press to the pointer, both taken in whole.
      local from, to = x0, tx
      if to >= from then to = to + 1 else from = from + 1 end
      A.select_range(row0, beat_at(self, from), row_index(self, d.y), beat_at(self, to))
    end,
  })
end

--- A drag with the right button: a box that chooses the clips it touches
--- (Shift adds, Ctrl turns over). Without moving it is a right click: the
--- menu of what is under it.
local function press_right(self, e, h)
  local row0, x0, y0 = h.row and h.row.index, h.tx, e.y
  local where = { x = e.x + (e.view_x or 0), y = e.y + (e.view_y or 0) }
  mouse.grab(e, {
    arrange = function(v, buf)
      local d = mouse.gesture().d
      if d and d.moved and row0 then box(buf, math.max(v.geometry.hw, x0 + v.geometry.hw), y0, math.max(v.geometry.hw, d.x), d.y) end
    end,
    drag = function(d) mouse.gesture().d = d end,
    up = function(u)
      if u.moved and row0 then
        local tx = u.x - self.geometry.hw
        local from, to = x0, tx
        if to >= from then to = to + 1 else from = from + 1 end
        local mode = mouse.has(u, "S") and "add" or mouse.has(u, "C") and "toggle" or nil
        A.select_clips_box(row0, beat_at(self, from), row_index(self, u.y), beat_at(self, to), mode)
        return
      end
      self:menu_at(h, where)
    end,
  })
end

--- The menu for what a right click was on, at `where` on the screen.
function view:menu_at(h, where)
  local items
  if h.area == "track" and h.timeline then
    if h.clip and h.part == "warp" then
      items = menus.warp(h.clip.id, h.warp)
    elseif h.clip then
      A.menu_target(h.clip.id, grid_at(self, h.tx))
      items = menus.clip(h.clip.id, grid_at(self, h.tx))
    else
      local sel = paw.keymap.mode == "x" and paw.keymap.selection()
      if sel and not sel.clips and sel.c0 and h.beat >= sel.c0 and h.beat < sel.c1
        and h.row.index >= sel.r0 and h.row.index <= sel.r1 then
        items = menus.selection()
      else
        A.select(h.row.id, grid_at(self, h.tx))
        items = menus.timeline(h.row.id, grid_at(self, h.tx))
      end
    end
  elseif h.area == "track" then
    A.select(h.row.id)
    items = menus.track(h.row.id)
  elseif h.area == "take" then
    items = menus.takes(h.row.id)
  elseif h.area == "lane" then
    items = menus.lane(h.row.lane.id)
  elseif h.area == "tempo" then
    items = menus.tempo_lane()
  end
  if items then paw.ui.menu(items, where) end
end

-- Headers ------------------------------------------------------------------------------

local function drag_value(e, get, set, per_cell, fine, target, track)
  local start = get()
  A.hold(track, target, 0, "", true)
  mouse.grab(e, {
    drag = function(d)
      local step = mouse.has(d, "S") and fine or per_cell
      set(start + d.dx * step)
    end,
    up = function() A.hold(track, target, 0, "", false) end,
    cancel = function() A.hold(track, target, 0, "", false) end,
  })
end

--- A press on a track's header: its M, S, R and I buttons (a press on one
--- swept across the others sets them all alike), the fold mark of a group,
--- the volume on the second line and the pan on the third (dragged
--- sideways; a double click puts them back), and anywhere else selects the
--- track, renames it on a double click, and drags it to another place.
local function press_header(self, e, h)
  local row, id = h.row, h.row.id
  local t = api.track_get(id)
  local hw = self.geometry.hw - 1
  local name_at = hw < 16 and 2 or 4
  if e.y == row.y then
    for field, x in pairs(self.flags) do
      if e.x == x then
        if field == "monitor" then return A.toggle(id, field) end
        local on = not t[field]
        A.set_flag(id, field, on)
        return mouse.grab(e, { drag = function(d) A.sweep_flag(row.index, row_index(self, d.y), field, on) end })
      end
    end
    if paw.groups.is_group(id) and e.x == name_at + paw.groups.depth(id) then return A.fold(id) end
  end
  if row.h >= 2 and e.y == row.y + 1 and e.x >= name_at then
    if e.double then return A.set_volume(id, 0) end
    A.select(id)
    return drag_value(e, function() return api.track_get(id).volume end, function(v) A.set_volume(id, v) end, 1, 0.1, "volume", id)
  end
  if row.h >= 3 and e.y == row.y + 2 and e.x >= name_at and e.x < name_at + 4 then
    if e.double then return A.set_pan(id, 0) end
    A.select(id)
    return drag_value(e, function() return api.track_get(id).pan or 0 end, function(v) A.set_pan(id, v) end, 0.05, 0.01, "pan", id)
  end
  if e.double then return A.track_command(id, "track.rename") end
  A.select(id)
  mouse.grab(e, {
    arrange = function(v, buf)
      local d = mouse.gesture().d
      if not (d and d.dy ~= 0) then return end
      local target = row_of(v, row_index(v, d.y))
      if target then buf:fill(0, target.y, v.geometry.hw - 1, 1, nil, "MouseGhost") end
    end,
    drag = function(d) mouse.gesture().d = d end,
    up = function(u)
      local to = row_index(self, u.y)
      if u.moved and to ~= row.index then A.move_track(id, to) end
    end,
  })
end

-- Lanes under the ruler and under the tracks -----------------------------------------------

--- A height in a row of `h` lines from line `top`, as a fraction (0 at the
--- bottom), for line `y`: the middle of the line, and past the row its ends.
local function fraction(y, top, h)
  return util.clamp(1 - (y - top + 0.5) / h, 0, 1)
end

--- The pencil over a lane: a click puts a point, a drag draws, a press on a
--- point drags it (its height by an eighth a line, Shift finer) and a right
--- click takes it away. `o` names what the lane is:
---   points()                 { beat, fraction } each
---   add(beat, fraction), draw(points), move(index, beat, fraction), remove(index), ramp(index)
local function press_lane(self, e, h, top, rows, o)
  local tx = h.tx
  local points = o.points()
  local index
  for i, p in ipairs(points) do
    if col(self, p[1]) == tx then
      local line = p[2] >= 0.5 and top or top + rows - 1
      if not index or line == e.y then index = i end
    end
  end
  if e.button == "right" then
    if index then return o.remove(index) end
    return mouse.grab(e, { up = function() self:menu_at(h, { x = e.x + (e.view_x or 0), y = e.y + (e.view_y or 0) }) end })
  end
  if index then
    if e.double and o.ramp then return o.ramp(index) end
    local p = points[index]
    return mouse.grab(e, {
      drag = function(d)
        local f = util.clamp(p[2] - d.dy * (mouse.has(d, "S") and 1 / 32 or 1 / 8), 0, 1)
        mouse.hint(o.say(p[1] + cells(self, d.dx), f))
      end,
      up = function(u)
        if not u.moved then return end
        o.move(index, p[1] + cells(self, u.dx), util.clamp(p[2] - u.dy * (mouse.has(u, "S") and 1 / 32 or 1 / 8), 0, 1))
      end,
    })
  end
  local stroke = { { grid_at(self, tx), fraction(e.y, top, rows) } }
  mouse.grab(e, {
    drag = function(d)
      stroke[#stroke + 1] = { beat_at(self, d.x - self.geometry.hw), fraction(d.y, top, rows) }
      mouse.hint(o.say(stroke[#stroke][1], stroke[#stroke][2]))
    end,
    up = function(u)
      if u.moved then return o.draw(stroke) end
      o.add(stroke[1][1], stroke[1][2])
    end,
  })
end

local function automation(row)
  local lane = row.lane.id
  return {
    points = function()
      local l = api.lane_get(lane)
      local lo, hi = paw.frontend.lane_span(l)
      local out = {}
      for i, p in ipairs(api.lane_points(lane)) do
        out[i] = { p[1], hi ~= lo and util.clamp((p[2] - lo) / (hi - lo), 0, 1) or 0.5 }
      end
      return out
    end,
    add = function(beat, f) A.add_point(lane, beat, f) end,
    draw = function(stroke) A.draw_lane(lane, stroke) end,
    move = function(i, beat, f) A.move_point(lane, i, beat, f) end,
    remove = function(i) A.remove_point(lane, i) end,
    say = function(beat, f)
      local l = api.lane_get(lane)
      local lo, hi = paw.frontend.lane_span(l)
      return paw.time.format(math.max(0, beat)) .. "  " .. paw.lanes.format(l, lo + f * (hi - lo))
    end,
  }
end

local tempo = {
  points = function()
    local out = {}
    for i, p in ipairs(paw.tempo.points()) do out[i] = { p.beat, paw.tempolane.fraction(p.bpm), p = p } end
    return out
  end,
  add = function(beat, f) A.tempo_point_add(beat, f) end,
  draw = function(stroke) A.tempo_draw(stroke) end,
  move = function(i, beat, f) A.tempo_point_move(paw.tempo.points()[i].beat, beat, f) end,
  remove = function(i) A.tempo_point_remove(paw.tempo.points()[i].beat) end,
  ramp = function(i) A.tempo_point_ramp(paw.tempo.points()[i].beat) end,
  say = function(beat, f) return paw.time.format(math.max(0, beat)) .. "  " .. paw.tempolane.bpm(f) .. " bpm" end,
}

-- The ruler and the band of markers ----------------------------------------------------

--- A press on the ruler: on a tempo or signature flag, drag it, double
--- click to type a value, right click for its menu; on an edge of the loop
--- or the punch range, drag it; elsewhere a click puts the cursor and the
--- playhead there, a drag loops what it crosses, a double click turns the
--- loop on or off.
local function press_ruler(self, e, h)
  local tx = h.tx
  local where = { x = e.x + (e.view_x or 0), y = e.y + (e.view_y or 0) }
  for _, m in ipairs(ruler_marks(self)) do
    if tx >= m.x0 and tx < m.x1 then
      local mark = m.mark
      if e.button == "right" then
        return mouse.grab(e, { up = function() paw.ui.menu(menus.tempo_mark(mark.kind, mark.beat), where) end })
      end
      if e.double then return A.tempo_mark("edit", mark.kind, mark.beat) end
      return mouse.grab(e, {
        drag = function(d) mouse.hint(paw.time.format(math.max(0, mark.beat + cells(self, d.dx)))) end,
        up = function(u)
          if u.moved then A.tempo_mark("move", mark.kind, mark.beat, mark.beat + cells(self, u.dx)) end
        end,
      })
    end
  end
  if e.button ~= "left" then return end
  local t = api.transport_get()
  local free = mouse.has(e, "S")
  local edges = {}
  if t.loop_enabled and t.loop_end > t.loop_start then
    edges[#edges + 1] = { col(self, t.loop_start) - 1, function(b) A.set_loop_edge("start", b) end }
    edges[#edges + 1] = { col(self, t.loop_end) - 1, function(b) A.set_loop_edge("end", b) end }
  end
  if t.punch_enabled and t.punch_end > t.punch_start then
    edges[#edges + 1] = { col(self, t.punch_start) - 1, function(b) A.set_punch_edge("start", b, free) end }
    edges[#edges + 1] = { col(self, t.punch_end) - 1, function(b) A.set_punch_edge("end", b, free) end }
  end
  for _, edge in ipairs(edges) do
    if tx == edge[1] then
      -- The mark sits in the cell before the edge, which is its right side.
      return mouse.grab(e, { drag = function(d) edge[2](beat_at(self, d.x - self.geometry.hw + 1)) end })
    end
  end
  local double = e.double
  local x0 = tx
  mouse.grab(e, {
    drag = function(d)
      if not d.moved then return end
      local from, to = x0, d.x - self.geometry.hw
      if to >= from then to = to + 1 else from = from + 1 end
      A.set_loop(beat_at(self, from), beat_at(self, to))
    end,
    up = function(u)
      if u.moved then return end
      if double then
        paw.transport.loop_enabled = not api.transport_get().loop_enabled
      else
        A.ruler_click(grid_at(self, x0))
      end
    end,
  })
end

--- A press in the band of markers: a click goes to one, a drag moves it, a
--- double click renames it, a right click opens its menu.
local function press_markers(self, e, h)
  local m = marker_at(self, h.tx)
  if not m then
    if e.button == "left" then A.ruler_click(grid_at(self, h.tx)) end
    return
  end
  local where = { x = e.x + (e.view_x or 0), y = e.y + (e.view_y or 0) }
  if e.button == "right" then
    return mouse.grab(e, { up = function() paw.ui.menu(menus.marker(m), where) end })
  end
  if e.double then return paw.commands.exec("marker.rename id=" .. m.id) end
  mouse.grab(e, {
    drag = function(d) mouse.hint(paw.time.format(math.max(0, m.beat + cells(self, d.dx)))) end,
    up = function(u)
      if not u.moved then return paw.commands.exec("marker.goto id=" .. m.id) end
      local to = m.beat + cells(self, u.dx)
      to = mouse.has(u, "S") and math.max(0, to) or math.max(0, paw.cursor.snap(to))
      paw.commands.exec(string.format("marker.set id=%d beat=%s", m.id, tostring(to)))
    end,
  })
end

-- Take lanes ---------------------------------------------------------------------------

--- A drag across a take lane, as the window's: the cells from where the
--- button went down to where it is now are marked, and on release that
--- take plays over them (`paw.frontend.act.comp`; a cell shorter than a
--- grid step is a click, which chooses the take for the piece under it).
local function press_take(self, e, h)
  local row = h.row
  if e.button == "right" then
    return mouse.grab(e, { up = function() self:menu_at(h, { x = e.x + (e.view_x or 0), y = e.y + (e.view_y or 0) }) end })
  end
  if not h.timeline then
    -- The label makes the take play wherever the track has it.
    local last = 0
    for _, clip in ipairs(api.clip_list(row.id)) do last = math.max(last, clip.start + clip.length) end
    paw.takes.comp(row.id, row.take, 0, last)
    return paw.cursor.set_track(row.id)
  end
  self.comp = { id = row.id, take = row.take, x0 = e.x, x1 = e.x }
  mouse.grab(e, {
    drag = function(d) if self.comp then self.comp.x1 = math.max(self.geometry.hw, d.x) end end,
    up = function(u)
      local comp, g = self.comp, self.geometry
      self.comp = nil
      if not comp then return end
      comp.x1 = math.max(g.hw, u.x)
      local from = self.scroll + (math.min(comp.x0, comp.x1) - g.hw) / g.zoom
      local to = self.scroll + (math.max(comp.x0, comp.x1) + 1 - g.hw) / g.zoom
      A.comp(comp.id, comp.take, from, to, mouse.has(u, "S"))
    end,
    cancel = function() self.comp = nil end,
  })
end

-- The wheel and the pointer going over -----------------------------------------------------

local function wheel(self, e, h)
  local step, sideways = mouse.wheel(e)
  local g = self.geometry
  if mouse.has(e, "C") and not sideways and h.timeline then
    -- Zoom in time, keeping the beat under the pointer where it is.
    local zoom = util.clamp(paw.opt.zoom * (step < 0 and math.sqrt(2) or 1 / math.sqrt(2)), 0.125, 64)
    local at = beat_at(self, h.tx)
    paw.opt.zoom = zoom
    self.scroll = math.max(0, at - h.tx / zoom)
  elseif (mouse.has(e, "C") or mouse.has(e, "A")) and not sideways then
    -- Taller or shorter tracks, from the height they have now.
    local now = tonumber(paw.opt.track_height) or g.th
    paw.opt.track_height = util.clamp(now - step, 1, 12)
  elseif sideways or mouse.has(e, "S") then
    self.scroll = math.max(0, self.scroll + step * paw.time.bar(self.scroll))
  else
    self.top = math.max(1, self.top + step)
  end
  api.ui_redraw()
end

local hints = {
  ruler = "ruler: click moves the playhead · drag loops · drag the loop's edges · double click turns the loop on or off",
  flag = "tempo flag: drag to move · double click to type a value · right click to remove",
  markers = "marker: click goes there · drag to move · double click renames · right click for more",
  tempo = "tempo lane: click adds a change · hold and draw a curve · drag a change to move it · double click makes it ramp or hold · right click one removes it",
  lane = "lane: click adds a point · hold to draw · drag a point · right click removes it",
  take = "take lane: drag across to play this take there · click a piece to choose it · right click to hide",
  empty = "click puts the cursor · drag selects time · right drag chooses clips · double click makes a clip · right click for more",
  edge = "drag the edge to trim (Alt slips, Alt+Shift stretches)",
  clip = "click chooses (Ctrl adds, Shift takes in) · drag moves (Ctrl copies) · double click opens · right click for more",
  warp = "warp marker: drag to move · right click to remove",
  header = "click selects · drag up or down to reorder · M S R I switch · drag the volume or pan sideways · right click for more",
}

local function hover(self, h)
  local text
  if h.area == "ruler" and h.timeline then
    text = hints.ruler
    for _, m in ipairs(ruler_marks(self)) do
      if h.tx >= m.x0 and h.tx < m.x1 then text = hints.flag end
    end
  elseif h.area == "markers" and h.timeline then
    local m = marker_at(self, h.tx)
    text = m and (paw.markers.label(m) .. " · " .. hints.markers) or nil
  elseif h.area == "tempo" and h.timeline then
    text = paw.time.format(h.beat) .. "  " .. string.format("%g bpm", paw.tempo.at(h.beat)) .. " · " .. hints.tempo
  elseif h.area == "lane" and h.timeline then
    text = paw.time.format(h.beat) .. " · " .. hints.lane
  elseif h.area == "take" then
    text = hints.take
  elseif h.area == "track" and h.timeline then
    local at = paw.time.format(h.beat)
    if h.clip then
      text = at .. "  " .. h.clip.name .. " · " .. (h.part == "warp" and hints.warp or (h.part == "start" or h.part == "end") and hints.edge or hints.clip)
    else
      text = at .. " · " .. hints.empty
    end
  elseif h.area == "track" and h.header then
    text = api.track_get(h.row.id).name .. " · " .. hints.header
  end
  mouse.hint(text)
end

function view:on_mouse(e)
  if not self.geometry then return end
  local h = hit(self, e.x, e.y)
  if e.kind == "move" then return hover(self, h) end
  if mouse.wheel(e) then return wheel(self, e, h) end
  if e.kind ~= "down" then return end
  if e.button == "middle" then
    -- The middle button held pans.
    local scroll, top = self.scroll, self.top
    return mouse.grab(e, {
      drag = function(d)
        self.scroll = math.max(0, scroll - cells(self, d.dx))
        self.top = math.max(1, top - d.dy)
      end,
    })
  end
  local area = h.area
  if area == "ruler" and h.timeline then return press_ruler(self, e, h) end
  if area == "markers" and h.timeline then return press_markers(self, e, h) end
  if area == "tempo" and h.timeline then return press_lane(self, e, h, h.y0, 2, tempo) end
  if area == "take" then return press_take(self, e, h) end
  if area == "lane" then
    if h.header then
      paw.cursor.set_track(h.row.id, h.row.lane.id)
      if e.button == "right" then
        return mouse.grab(e, { up = function() self:menu_at(h, { x = e.x + (e.view_x or 0), y = e.y + (e.view_y or 0) }) end })
      end
      return
    end
    if h.timeline then
      paw.cursor.set_track(h.row.id, h.row.lane.id)
      return press_lane(self, e, h, h.row.y, h.row.h, automation(h.row))
    end
  end
  if area == "tempo" and e.button == "right" then
    return mouse.grab(e, { up = function() self:menu_at(h, { x = e.x + (e.view_x or 0), y = e.y + (e.view_y or 0) }) end })
  end
  if area ~= "track" then return end
  if e.button == "right" then
    if h.header then
      return mouse.grab(e, { up = function() self:menu_at(h, { x = e.x + (e.view_x or 0), y = e.y + (e.view_y or 0) }) end })
    end
    return press_right(self, e, h)
  end
  if e.button ~= "left" then return end
  if h.header then return press_header(self, e, h) end
  if not h.timeline then return end
  if h.clip then return press_clip(self, e, h) end
  press_empty(self, e, h)
end

-- What a gesture under way draws over the view.
local render = view.render
function view:render(buf, ctx)
  render(self, buf, ctx)
  local g = mouse.gesture()
  if g and g.arrange and self.geometry then g.arrange(self, buf) end
end
