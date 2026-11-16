-- The tabs and windows of a seat (daw/layout.lua) as a graphical frontend
-- shows them: panes docked in its main area, laid out in pixels by the
-- rules the terminal lays them out by in cells.
--
-- A frontend says how big its main area is (`area`), and is told with each
-- state (`state`) where every window of the current tab goes, which has the
-- keyboard, the borders between them and the tabs. It draws the views it
-- has its own drawing for (`native`: the arrange view, the device panel,
-- the piano roll, the mixer, the session view) in their panes, and paints
-- every other through `paint`, which gives `daw.canvas` drawings: a view
-- that paints, at the pane's size, or any other cell by cell as the
-- terminal draws it. Pointer events in a pane come to `pointer`; a press
-- anywhere in one gives it the keyboard (`focus`). Keys need nothing: they
-- go to the key mappings with the focused window, as from the terminal.
local api = daw.api
local L = require("daw.layout")

local M = {
  -- Views a frontend draws in its own way.
  native = { arrange = true, devices = true, pianoroll = true, mixer = true, session = true },
  -- The least room, in pixels, a frontend's own drawing of a view needs.
  least = {
    arrange = { w = 320, h = 120 }, devices = { w = 260 }, pianoroll = { h = 200 },
    mixer = { h = 280 }, session = { h = 150 },
  },
  -- The height of the row of tabs along the top, when there is more than one.
  tabline = 28,
}

-- Each seat has its own area and windows: its size in pixels, the last
-- arrangement (for the borders dragged), and what each pane drawn in cells
-- drew last.
local area, last, cells = { w = 0, h = 0 }, nil, {}
daw.seats.keep("panes",
  function() return area, last, cells end,
  function(a, l, c) area, last, cells = a, l, c end,
  function() return { w = 0, h = 0 }, nil, {} end)

--- A copy of a tree with its sizes in pixels: a size along a row is in
--- columns, along a column in rows. `map` takes each copy back to its node.
local function in_pixels(node, across, map)
  local cell = daw.canvas.cell
  local unit = across == "h" and cell.w or cell.h
  local copy = { dir = node.dir, view = node.view, id = node.id, hidden = node.hidden, weight = node.weight }
  if node.size then copy.size = math.floor(node.size * unit + 0.5) end
  if node.min then copy.min = math.floor(node.min * unit + 0.5) end
  local least = node.view and M.least[node.view]
  local need = least and (across == "h" and least.w or least.h)
  if need then
    copy.min = math.max(copy.min or 0, need)
    if copy.size then copy.size = math.max(copy.size, need) end
  end
  map[copy] = node
  for i, child in ipairs(node) do copy[i] = in_pixels(child, node.dir == "h" and "h" or "v", map) end
  return copy
end

--- How a pane is drawn: by the frontend itself, painted, or in cells.
local function kind_of(name)
  if M.native[name] then return "native" end
  local view = daw.ui.views[name]
  return view and view.paint and "paint" or "cells"
end

--- What a pane is called: a painted view's title as it was opened, else
--- its buffer's.
local function title_of(win)
  local named = daw.canvas.titles[win.view]
  if named then return named end
  local buf = L.buf_of(win)
  return buf and L.title(buf) or win.view
end

--- The main area's size in pixels, from the frontend: once at the start
--- and whenever it changes. The first time a seat's window says it, the
--- device panel is shown: a window has the selected track's devices beside
--- the timeline unless they are closed.
function M.area(width, height)
  local started = area.started
  area = { w = math.max(0, math.floor(width)), h = math.max(0, math.floor(height)), started = started or width > 0 }
  if not started and area.w > 0 and not daw.ui.visible("devices") then daw.ui.show("devices") end
  api.ui_redraw()
end

--- The main area in cells, with the status line and the command line
--- under it as on a terminal: what the seat's screen is. Nil until the
--- frontend has said.
function M.cells()
  if area.w <= 0 or area.h <= 0 then return nil end
  local cell = daw.canvas.cell
  local bars = 0
  for _, node in ipairs(daw.ui.bars) do bars = bars + node.size end
  return { w = math.floor(area.w / cell.w), h = math.floor(area.h / cell.h) + bars }
end

--- Where everything goes in the main area, for a frontend's state: `panes`,
--- each `{ win, view, kind ("native", "paint", "cells"), title, x, y, w, h,
--- focused }`; `borders`, each `{ dir ("h": a rule between panes side by
--- side, "v": one between panes one above another), x, y, length }`, by
--- their place in the list; `tabs`, each `{ title }`, and `tab`, the
--- current one; `top`, where the panes start under the row of tabs. Nil
--- until the frontend has said how big its area is.
function M.state()
  if area.w <= 0 or area.h <= 0 then return nil end
  local u = daw.ui
  local top = #u.tabs > 1 and M.tabline or 0
  local map = {}
  local root = in_pixels(u.layout, "v", map)
  local rects = u.place(root, 0, top, area.w, math.max(0, area.h - top))
  last = { rects = rects, map = map }
  local current = L.current()
  local out = { panes = {}, borders = {}, tabs = {}, tab = u.tab, top = top }
  for _, r in ipairs(rects) do
    local win = r.win and L.find_id(u.layout, r.win)
    if win then
      out.panes[#out.panes + 1] = {
        win = win.id, view = win.view, kind = kind_of(win.view), title = title_of(win),
        x = r.x, y = r.y, w = r.w, h = r.h,
        focused = win == current and u.focused == win.view and not daw.canvas.open_views[win.view],
      }
    end
  end
  for _, b in ipairs(rects.borders) do
    out.borders[#out.borders + 1] = { dir = b.dir, x = b.x, y = b.y, length = b.dir == "h" and b.h or b.w }
  end
  for _, t in ipairs(u.tabs) do out.tabs[#out.tabs + 1] = { title = L.tab_title(t) } end
  return out
end

local function window(id)
  local win = L.find_id(daw.ui.layout, id)
  if win and not win.hidden then return win end
end

--- Give a pane's window the keyboard, as a click in it does.
function M.focus(id)
  local win = window(id)
  if not win or daw.ui.float then return end
  local view = daw.ui.views[win.view]
  if not view or view.focusable == false then return end
  if L.current() ~= win or daw.ui.focused ~= win.view then
    if daw.keymap.mode == "x" then daw.keymap.set_mode("n") end
    L.enter(win)
  end
end

--- Paint a pane that the frontend does not draw itself, at its size: what
--- `daw.canvas.paint` gives (`opts` as there).
function M.paint(id, width, height, opts)
  local win = window(id)
  if not win then return nil end
  local view = daw.ui.views[win.view]
  if not view then return nil end
  if view.paint then return daw.canvas.paint(win.view, width, height, opts) end
  cells[id] = cells[id] or {}
  return daw.canvas.paint_cells(win.view, cells[id], width, height, opts or {}, win)
end

--- A pointer event in a pane, in pixels from its corner (as
--- `daw.canvas.pointer` takes them): a press gives it the keyboard first.
function M.pointer(id, event)
  local win = window(id)
  if not win then return end
  if event.kind == "down" then M.focus(id) end
  local view = daw.ui.views[win.view]
  if not view then return end
  if view.paint then
    if view.pointer then view:pointer(event) end
  else
    local e = daw.canvas.cell_event(cells[id] or {}, event, true)
    if e and view.on_mouse then
      local drawn = cells[id] or {}
      e.win, e.w, e.h = id, drawn.cols, drawn.rows
      daw.limit.named("the mouse", daw.mouse.to_view, view, e)
    end
  end
  api.ui_redraw()
end

--- A border of the last arrangement (by its place in `state().borders`)
--- dragged to `x, y`: the side that has a size keeps one, in whole cells.
function M.border(index, x, y)
  local b = last and last.rects.borders[index]
  if not b then return end
  local nodes = last.rects.nodes
  local a, z = nodes[b.a], nodes[b.b]
  if not (a and z) then return end
  local across = b.dir == "h"
  local start = across and a.x or a.y
  local finish = across and z.x + z.w or z.y + z.h
  local at = math.max(start + 1, math.min(across and x or y, finish - 1))
  local axis = across and "width" or "height"
  local cell = daw.canvas.cell
  local unit = across and cell.w or cell.h
  local first, second = last.map[b.a], last.map[b.b]
  if second.size and not first.size then
    L.set_size(second, axis, math.max(1, math.floor((finish - at) / unit + 0.5)))
  else
    L.set_size(first, axis, math.max(1, math.floor((at - start) / unit + 0.5)))
  end
  api.ui_redraw()
end

--- Close a pane's window, as `:close` in it would.
function M.close(id)
  local win = window(id)
  if win and not L.close(win) then daw.notify("the last window does not close", "warn") end
end

--- A click on tab `i` goes to it.
function M.tab(i)
  if not daw.ui.float then L.tab_go(i) end
end

return M
