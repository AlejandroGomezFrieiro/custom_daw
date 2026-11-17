-- The screen: views, the tabs and windows that arrange them (laid out by
-- paw/layout.lua), focus, messages and highlight groups.
--
-- A view is a table with a `render(self, buf, ctx)` function that draws into a
-- cell buffer. Everything on screen, including the built-in arrange view and
-- status line, is a view registered through `paw.ui.view`.
--
-- A view that also paints (`paint`, see `paw.canvas`) can show its pixels
-- in a terminal that shows images: its `render` keeps an area for them
-- with `buf:surface`, or the view sets `surface = true` to be all pixels.
local api = paw.api
local L = require("paw.layout")
local M = {
  Buf = require("paw.buf"),
  views = {},
  focused = "arrange",
  messages = {},   -- every message so far, oldest first
  message = nil,   -- the one on the command line now
  grabber = nil,   -- function that takes every key while set (prompts)
  float = nil,     -- the floating view, if one is open
  rects = {},      -- where each view was last drawn
}

-- The tabs, each a tree of windows (see paw/layout.lua for how a tree is
-- laid out), and the current one, whose tree is `M.layout`. The status line
-- and the command line are drawn along the bottom of every tab.
M.tabs = { { layout = L.default_tree() } }
M.tab = 1
M.layout = M.tabs[1].layout
M.bars = { { view = "status", size = 1 }, { view = "cmdline", size = 1 } }

-- Each seat has its own focus, floating view, prompt, tabs and windows,
-- and the view a held button went down in; a new one starts with the tabs
-- and windows of the instance's terminal.
paw.seats.keep("ui",
  function() return M.focused, M.float, M.grabber, M.rects, M.tabs, M.tab, M.pressed end,
  function(focused, float, grabber, rects, tabs, tab, pressed)
    M.focused, M.float, M.grabber, M.rects, M.pressed = focused, float, grabber, rects, pressed
    M.tabs, M.tab, M.layout = tabs, tab, tabs[tab].layout
  end,
  function(_, _, _, _, tabs, tab) return "arrange", nil, nil, {}, paw.seats.copy(tabs), tab, nil end)

--- Register a view, replacing any view of the same name.
---   paw.ui.view("clock", { render = function(self, buf) buf:text(0, 0, os.date()) end })
--- Optional fields: `focusable` (default true), `on_key(self, key)` for keys
--- with no mapping, `modal` (every key goes to `on_key`), `on_mouse(self, event)`,
--- `on_show(self)`, `on_hide(self)`. A view is a buffer type with one
--- buffer, named as the view or by `bufname`.
function M.view(name, def)
  def.name = name
  M.views[name] = def
  api.ui_redraw()
  return def
end

local function bar(name)
  for _, node in ipairs(M.bars) do
    if node.view == name then return node end
  end
end

--- Whether a view is currently on screen.
function M.visible(name)
  if M.float and M.float.name == name then return true end
  for _, rect in ipairs(M.arrange()) do
    if rect.name == name then return true end
  end
  return false
end

local function focusable(name)
  local view = M.views[name]
  return view and view.focusable ~= false
end

--- Show a view: in its window if it has one in this tab, else where it was
--- docked. A view has one window at a time: one on screen in another tab
--- moves here.
function M.show(name)
  local node = bar(name)
  if node then
    node.hidden = false
  elseif not L.reveal(name) then
    error("view `" .. name .. "` is not in the layout", 2)
  end
  api.ui_redraw()
end

--- Close a view's window, in every tab; it keeps its place for next time.
function M.hide(name)
  local node = bar(name)
  if node then
    node.hidden = true
  elseif L.conceal(name) then
    local view = M.views[name]
    if view and view.on_hide then view:on_hide() end
  end
  if M.focused == name then
    M.focus_next()
    -- The last window of the tab does not close: the arrange view takes
    -- the keyboard, or this view stays if it is the arrange view.
    if M.focused == name and not M.visible(name) then
      M.focus("arrange")
    end
  end
  api.ui_redraw()
end

function M.toggle(name)
  local win = L.find(M.layout, name)
  if (win and not win.hidden) or not (win or L.homes[name]) then
    -- The only window of the tab does not hide: the arrange view takes
    -- its place, as `Ctrl-w o` left no other to go to.
    local alone = win and focusable(name)
    for _, other in ipairs(win and L.windows(M.layout) or {}) do
      if other ~= win and focusable(other.view) then alone = false end
    end
    if alone and name ~= "arrange" and M.views.arrange then return L.show_in(win, "arrange") end
    return M.hide(name)
  end
  M.show(name)
  if focusable(name) then M.focus(name) end
end

--- Add a view to the layout along one side of the screen.
---   paw.ui.dock("clock", { side = "top", size = 5 })
--- `side` is "top", "bottom" (above the status line), "left" or "right" (beside
--- the arrange view). Without `size` the view shares the space left over.
--- Docking a view that is already in the layout moves it. Other tabs put
--- it in the same place when it is shown there.
function M.dock(name, opts)
  L.dock(name, opts or {})
  api.ui_redraw()
end

--- Give a view the keyboard, showing it first if it is hidden: the window
--- it is in, going to its tab if that is another.
function M.focus(name)
  if not M.views[name] then error("no view `" .. tostring(name) .. "`", 2) end
  local win = L.reveal(name, true)
  if win then return L.enter(win) end
  if not (M.float and M.float.name == name) then
    -- A view with no window and no place of its own (its window showed a
    -- buffer since) goes into the current window, as `:b` would: focus is
    -- never given to a view that is not drawn.
    local cur = L.current()
    if not cur then error("no window to show `" .. name .. "` in", 2) end
    return L.show_in(cur, name)
  end
  if M.focused ~= name then
    local old = M.focused
    M.focused = name
    paw.emit("view.focused", { view = name, old = old })
  end
  api.ui_redraw()
end

--- Focus the next (or with -1 the previous) window that takes the keyboard.
function M.focus_next(step)
  local wins, at = {}, 0
  local cur = L.current()
  for _, rect in ipairs(M.arrange()) do
    if rect.win and focusable(rect.name) then
      wins[#wins + 1] = rect.win
      if cur and rect.win == cur.id and cur.view == M.focused then at = #wins end
    end
  end
  if #wins == 0 then return end
  local win = L.find_id(M.layout, wins[(at - 1 + (step or 1)) % #wins + 1])
  if win then L.enter(win) end
end

-- Sizes along a node: a child with a `size` gets that many cells, the rest
-- share what is left by weight, a child below its `min` given that much and
-- the rest shared again among the others. With no child left to share, the
-- last one takes what is left.
local function shares(children, total)
  local flexible
  for _, child in ipairs(children) do
    if not child.size then flexible = true end
  end
  local grow = not flexible and children[#children]
  local function size_of(child) return child ~= grow and child.size or nil end
  local fixed = 0
  for _, child in ipairs(children) do fixed = fixed + (size_of(child) or 0) end
  local spare = math.max(0, total - fixed)
  local sizes = {}
  for _ = 1, #children do
    local weights, left = 0, spare
    for i, child in ipairs(children) do
      if size_of(child) then sizes[i] = size_of(child) elseif sizes[i] then left = left - sizes[i] else weights = weights + (child.weight or 1) end
    end
    local grew, weight_seen = false, 0
    for i, child in ipairs(children) do
      if not size_of(child) and not sizes[i] then
        -- Round cumulatively, so the flexible children add up to exactly what is left.
        local before = math.floor(left * weight_seen / weights)
        weight_seen = weight_seen + (child.weight or 1)
        local size = math.floor(left * weight_seen / weights) - before
        if child.min and size < child.min then
          sizes[i], grew = math.min(child.min, spare), true
          break
        end
      end
    end
    if not grew then
      weight_seen = 0
      for i, child in ipairs(children) do
        if not size_of(child) and not sizes[i] then
          local before = math.floor(left * weight_seen / weights)
          weight_seen = weight_seen + (child.weight or 1)
          sizes[i] = math.floor(left * weight_seen / weights) - before
        end
      end
      break
    end
  end
  return sizes
end

--- Whether a node is, or holds, the window of a view.
local function holds(node, name)
  if node.view then return node.view == name end
  for _, win in ipairs(L.windows(node)) do
    if win.view == name then return true end
  end
  return false
end

-- Move `amount` cells between the children at `others`: a positive amount
-- goes to them in proportion to their sizes, a negative one is taken from
-- them in proportion to what each can spare (down to its `min`, else one).
-- Returns how many cells moved.
local function spread(children, sizes, others, amount)
  local room, sum = {}, 0
  for _, j in ipairs(others) do
    room[j] = amount > 0 and sizes[j] or math.max(0, sizes[j] - (children[j].min or 1))
    sum = sum + room[j]
  end
  local moved = amount > 0 and amount or math.min(-amount, sum)
  if sum == 0 or moved == 0 then return 0 end
  local seen, given = 0, 0
  for _, j in ipairs(others) do
    seen = seen + room[j]
    local upto = math.floor(moved * seen / sum)
    sizes[j] = sizes[j] + (amount > 0 and 1 or -1) * (upto - given)
    given = upto
  end
  return moved
end

-- Where views share a node, the weights and the sizes of the panels beside
-- the arrange view can leave it a sliver: in a column it keeps two fifths of
-- the height, taken first from the panels that share by weight and then from
-- those with a size of their own (down to their `min`, else one row). Where
-- three or more share it keeps a third of the room, as `Ctrl-w =` gives it,
-- and the notation view takes at most half.
local function limit_shares(children, sizes, total, vertical)
  local flexible = {}
  for i, child in ipairs(children) do
    if not child.size then flexible[#flexible + 1] = i end
  end
  local function others_of(i, list)
    local out = {}
    for _, j in ipairs(list) do
      if j ~= i then out[#out + 1] = j end
    end
    return out
  end
  if #flexible >= 3 then
    for _, i in ipairs(flexible) do
      local half = math.floor(total / 2)
      if holds(children[i], "notation") and sizes[i] > half then
        sizes[i] = sizes[i] - spread(children, sizes, others_of(i, flexible), sizes[i] - half)
      end
    end
    for _, i in ipairs(flexible) do
      local third = math.floor(total / 3)
      if holds(children[i], "arrange") and sizes[i] < third then
        sizes[i] = sizes[i] + spread(children, sizes, others_of(i, flexible), sizes[i] - third)
      end
    end
  end
  if not vertical or #children < 2 then return end
  for i, child in ipairs(children) do
    local want = math.floor(total * 2 / 5)
    if holds(child, "arrange") and sizes[i] < want then
      local all = {}
      for j in ipairs(children) do all[#all + 1] = j end
      local fixed = {}
      for _, j in ipairs(all) do
        if j ~= i and children[j].size then fixed[#fixed + 1] = j end
      end
      local need = want - sizes[i]
      need = need - spread(children, sizes, others_of(i, flexible), -need)
      if need > 0 then need = need - spread(children, sizes, fixed, -need) end
      sizes[i] = want - need
    end
  end
end

local function place(node, x, y, w, h, out, screen_w, after)
  out.nodes[node] = { x = x, y = y, w = w, h = h }
  if node.view then
    out[#out + 1] = { name = node.view, win = node.id, x = x, y = y, w = w, h = h, after = after }
    return
  end
  local vertical = node.dir ~= "h"
  local total = vertical and h or w
  local children = {}
  for _, child in ipairs(node) do
    if L.shown(child) then
      if child.float_below and screen_w < child.float_below and child.view then
        -- Too narrow to stand beside the others: drawn over them instead.
        out.floating[#out.floating + 1] = child
      else
        children[#children + 1] = child
      end
    end
  end
  local sizes = shares(children, total)
  limit_shares(children, sizes, total, vertical)
  local pos = 0
  for i, child in ipairs(children) do
    local size = math.max(0, math.min(sizes[i] or 0, total - pos))
    if vertical then
      if i > 1 then out.borders[#out.borders + 1] = { node = node, a = children[i - 1], b = child, dir = "v", x = x, y = y + pos, w = w } end
      -- A rule on this node's left edge is on each of its rows' too.
      place(child, x, y + pos, w, size, out, screen_w, after)
    else
      if i > 1 then out.borders[#out.borders + 1] = { node = node, a = children[i - 1], b = child, dir = "h", x = x + pos, y = y, h = h } end
      -- A view beside another has a rule along its left edge.
      place(child, x + pos, y, size, h, out, screen_w, (i > 1 or after) and "rule" or nil)
    end
    pos = pos + size
  end
end

--- Lay a tree of windows out over a rectangle, as `arrange` lays out a
--- tab's: in whatever unit its sizes are in (a graphical frontend's pixels).
function M.place(root, x, y, w, h)
  local out = { nodes = {}, borders = {}, floating = {} }
  place(root, x, y, w, h, out, math.huge)
  out.floating = nil
  return out
end

--- The size of the screen in cells: the terminal's, or for the seat of a
--- graphical frontend that has said how big its main area is, that area's
--- (`paw.panes`), so that a split there is measured on what it shows.
function M.size()
  local cells = paw.panes and paw.panes.cells()
  if cells then return cells.w, cells.h end
  return api.ui_size()
end

--- Where each visible view goes on a screen of the current size: a list of
--- `{ name, win, x, y, w, h }`, with the tab line along the top when there
--- is more than one tab. `.borders` holds the borders between windows and
--- `.nodes` where each node of the tree went, for resizing.
function M.arrange(width, height)
  if not width then width, height = M.size() end
  local out = { nodes = {}, borders = {}, floating = {} }
  local top = (#M.tabs > 1 or paw.statusline.tabline_always()) and 1 or 0
  local below = 0
  for _, node in ipairs(M.bars) do
    if not node.hidden then below = below + node.size end
  end
  local area = math.max(0, height - top - below)
  place(M.layout, 0, top, width, area, out, width)
  local y = top + area
  for _, node in ipairs(M.bars) do
    if not node.hidden then
      local h = math.max(0, math.min(node.size, height - y))
      out[#out + 1] = { name = node.view, x = 0, y = y, w = width, h = h }
      y = y + h
    end
  end
  -- Panels that float on a narrow screen sit along the right edge, over the
  -- top part of the screen.
  for _, node in ipairs(out.floating) do
    local w = math.min(node.size or 40, width - 4)
    out[#out + 1] = { name = node.view, win = node.id, x = width - w, y = top, w = w, h = math.max(1, height - top - 2), after = "box" }
  end
  out.floating = nil
  out.tabline = top > 0 and { y = 0, w = width } or nil
  return out
end

--- The smallest screen the program draws on; below it a notice says so.
M.min_width, M.min_height = 60, 16

-- Views drawn on a background of their own: the status line and the key line.
local backgrounds = { status = "StatusLine", cmdline = "KeyBar" }
M.backgrounds = backgrounds

local function draw_view(view, buf, ctx)
  M.drawing = view.name
  if view.surface == true and view.paint and buf:surface(0, 0, buf.width, buf.height) then return end
  if view.paint and not view.render then
    -- A view that only paints, on a terminal that shows no pictures.
    if not buf:surface(0, 0, buf.width, buf.height) then
      buf:text(1, 0, paw.util.fit((view.title or view.name) .. ": drawn in a graphical window, or a terminal that shows pictures", buf.width - 1), "Dim")
    end
    return
  end
  local ok, err = xpcall(view.render, debug.traceback, view, buf, ctx)
  if not ok then
    -- Show the failure where the view would have been.
    buf:fill(0, 0, buf.width, buf.height, " ", "Normal")
    local row = 0
    for line in tostring(err):gmatch("[^\n]+") do
      buf:text(0, row, line:gsub("\t", "  "), "Error")
      row = row + 1
    end
  end
end

--- Draw a view; the strips it kept are its own until it is done, and what
--- is drawn over them after (a menu, a float) covers them.
local function draw(view, buf, ctx)
  M.drawing_win = ctx and ctx.win
  draw_view(view, buf, ctx)
  M.drawing_win = nil
  if M.rects.surfaces then api.grid_surfaces_seal() end
end

local function float_rect(width, height)
  local f = M.float
  local w = math.min(f.width or 72, width - 2)
  local h = math.min(f.height or 24, height - 2)
  -- `top`: at the top of the screen, leaving what is below it in view.
  local y = f.top and 1 or math.floor((height - h) / 2)
  return { name = f.name, x = math.floor((width - w) / 2), y = y, w = w, h = h }
end

--- Draw a box around a buffer's edge and return a buffer for the inside.
function M.box(buf, title, style)
  local w, h = buf.width, buf.height
  style = style or "Border"
  local g = paw.draw.g
  buf:fill(0, 0, w, h, " ", "Normal")
  buf:text(0, 0, g.tl .. string.rep(g.h, w - 2) .. g.tr, style)
  for row = 1, h - 2 do
    buf:text(0, row, g.v, style)
    buf:text(w - 1, row, g.v, style)
  end
  buf:text(0, h - 1, g.bl .. string.rep(g.h, w - 2) .. g.br, style)
  if title then buf:text(2, 0, " " .. title .. " ", "Title") end
  return buf:sub(1, 1, w - 2, h - 2)
end

--- Draw a one-row title bar along the top of a docked panel and return a
--- buffer for the rest of it. `opts`: `name`, `pill` (`{ text, group }`,
--- drawn ahead of the name), `context` (after the name),
--- `right` (state, at the right end), `focused`. Focus shows as the whole
--- bar in the accent colour, inverted.
---   local body = paw.ui.titlebar(buf, { name = "Mixer", context = "5 tracks", focused = ctx.focused })
function M.titlebar(buf, opts)
  local g = paw.draw.g
  local focused = opts.focused
  local plain = focused and "TitleBarFocus" or "TitleBar"
  buf:fill(0, 0, buf.width, 1, " ", plain)
  buf:text(0, 0, g.mark, focused and "TitleBarMarkFocus" or "TitleBarMark")
  local x = 2
  local right = opts.right and tostring(opts.right) or ""
  -- What the winbar (`paw.statusline`) adds, at the end of the state.
  local winbar = paw.statusline and M.drawing and paw.statusline.winbar(M.drawing, focused)
  if winbar then right = right ~= "" and (winbar .. "  " .. right) or winbar end
  local right_w = api.str_width(right)
  if opts.pill then
    -- A coloured label ahead of the name, such as a clip in its track's colour.
    x = x + buf:text(x, 0, " " .. tostring(opts.pill[1]) .. " ", opts.pill[2]) + 1
  end
  if opts.name then
    local room = math.max(1, buf.width - x - (right_w > 0 and right_w + 2 or 0))
    local name = tostring(opts.name)
    if api.str_width(name) > room then name = paw.util.fit(name, room) end
    x = x + buf:text(x, 0, name, focused and "TitleBarNameFocus" or "TitleBarName")
  end
  if opts.context and opts.context ~= "" then
    local room = buf.width - x - 2 - (right_w > 0 and right_w + 2 or 0)
    if room >= 4 then
      local text = tostring(opts.context)
      if api.str_width(text) > room then text = paw.util.fit(text, room) end
      x = x + 2 + buf:text(x + 2, 0, text, plain)
    end
  end
  if right_w > 0 and buf.width - right_w - 1 > x then buf:text(buf.width - right_w - 1, 0, right, focused and "TitleBarFocus" or "TitleBarFaint") end
  return buf:sub(0, 1, buf.width, buf.height - 1)
end

--- What is shown on a screen too small to draw on: the status line, the
--- command line, and in the middle how big the screen is and needs to be.
local function too_small(buf)
  local w, h = buf.width, buf.height
  local g = paw.draw.g
  local lines = {
    "Terminal too small: " .. w .. (g.ellipsis == "…" and "×" or "x") .. h,
    "needs " .. M.min_width .. (g.ellipsis == "…" and "×" or "x") .. M.min_height,
  }
  local top = math.max(0, math.floor((h - 2 - #lines) / 2))
  for i, line in ipairs(lines) do
    local x = math.max(0, math.floor((w - api.str_width(line)) / 2))
    buf:text(x, top + i - 1, line, i == 1 and "TooSmallTitle" or "TooSmall")
  end
  M.rects = {}
  for i, name in ipairs({ "status", "cmdline" }) do
    local y = h - 3 + i
    local view = M.views[name]
    if view and y >= 0 then
      M.rects[#M.rects + 1] = { name = name, x = 0, y = y, w = w, h = 1 }
      buf:fill(0, y, w, 1, " ", backgrounds[name])
      draw(view, buf:sub(0, y, w, 1), { focused = false, x = 0, y = y })
    end
  end
end

--- Keep an area of a buffer for pixels: see `Buf:strip`. Where it is kept
--- is in `paw.ui.rects.surfaces`: `{ key, name, win, x, y, w, h, cell = {
--- w, h }, under, draw, paint }` each, in cells of the screen (`name` the
--- view that kept it, `win` the id of its window, `paint` for a view's
--- whole drawing, `buf:surface`).
function M.strip(buf, x, y, w, h, opts)
  opts = opts or {}
  if paw.opt.graphics == false then return false end
  if not M.screen then
    -- A view drawn in cells for a window (`paw.canvas.paint_cells`): the
    -- window draws the strip's picture with the cells, under their text.
    if not (M.pictures and opts.draw and opts.under) then return false end
    x, y, w, h = math.floor(buf.x + x), math.floor(buf.y + y), math.floor(w), math.floor(h)
    local x0, y0 = math.max(x, buf.cx), math.max(y, buf.cy)
    local x1, y1 = math.min(x + w, buf.cx + buf.cw), math.min(y + h, buf.cy + buf.ch)
    if x1 <= x0 or y1 <= y0 then return false end
    M.pictures[#M.pictures + 1] = { x = x0, y = y0, w = x1 - x0, h = y1 - y0, left = x0 - x, top = y0 - y,
      whole_w = w, whole_h = h, draw = opts.draw }
    return true
  end
  local caps = api.ui_caps()
  if not caps.pixels or (opts.under and not caps.under) then return false end
  local name = opts.view or M.drawing
  local win = M.drawing_win
  local key = opts.key or (tostring(name) .. "#" .. tostring(win and win.id or "float"))
  x, y, w, h = math.floor(buf.x + x), math.floor(buf.y + y), math.floor(w), math.floor(h)
  if opts.paint then
    -- A view's paint lays out what shows of it.
    local x0, y0 = math.max(x, buf.cx), math.max(y, buf.cy)
    x, y, w, h = x0, y0, math.min(x + w, buf.cx + buf.cw) - x0, math.min(y + h, buf.cy + buf.ch) - y0
  end
  local index = api.grid_surface(key, x, y, w, h, buf.cx, buf.cy, buf.cw, buf.ch, opts.under == true)
  if not index then return false end
  -- What shows of it inside the buffer.
  local x0, y0 = math.max(x, buf.cx), math.max(y, buf.cy)
  local x1, y1 = math.min(x + w, buf.cx + buf.cw), math.min(y + h, buf.cy + buf.ch)
  M.rects.surfaces = M.rects.surfaces or {}
  table.insert(M.rects.surfaces, {
    key = key, name = name, win = win and win.id, index = index, x = x0, y = y0, w = x1 - x0, h = y1 - y0,
    left = x0 - x, top = y0 - y, whole_w = w, whole_h = h,
    cell = caps.cell, under = opts.under == true, draw = opts.draw, paint = opts.paint,
  })
  return true
end

--- Keep an area of a buffer for a view's pixels: see `Buf:surface`. A
--- strip, kept for the view's window, whose drawing is the view's `paint`.
function M.surface(buf, x, y, w, h, name)
  name = name or M.drawing
  local view = M.views[name]
  if not (view and view.paint) then return false end
  return M.strip(buf, x, y, w, h, { view = name, paint = true })
end

--- Paint what the views kept strips for, once the screen is drawn.
local function paint_surfaces()
  local caps = api.ui_caps()
  for _, s in ipairs(M.rects.surfaces or {}) do
    local cw, ch = s.cell.w, s.cell.h
    local w, h = s.w * cw, s.h * ch
    local ops
    if s.draw then
      -- The whole strip, of which `view` shows: a strip partly off its
      -- window draws what shows and a piece's width either side of it.
      ops = paw.canvas.draw(s.draw, {
        w = s.whole_w * cw, h = s.whole_h * ch, cell = s.cell, fg = caps.fg, bg = caps.bg,
        view = { x = s.left * cw, y = s.top * ch, w = w, h = h },
      })
    else
      local drawing = paw.canvas.paint(s.name, w, h, {
        surface = true, glyphs = true, cell = s.cell, colors = { fg = caps.fg, bg = caps.bg },
      })
      ops = drawing and drawing.ops
    end
    api.grid_surface_ops(s.index, ops or {})
  end
end

--- Draw the whole screen. Called by the kernel.
function M.render(buf)
  M.screen = true
  M.render_screen(buf)
  M.screen = false
end

function M.render_screen(buf)
  buf:fill(0, 0, buf.width, buf.height, " ", "Normal")
  api.ui_mouse(paw.opt.mouse ~= false)
  if buf.width < M.min_width or buf.height < M.min_height then return too_small(buf) end
  local sizes_before = M.rects.sizes or {}
  M.rects = M.arrange(buf.width, buf.height)
  local g = paw.draw.g
  local current = L.current()
  -- A time bound window with the keyboard is drawn first, and the other
  -- time bound windows take its time before they are drawn.
  local lead, followers = L.time_lead()
  local order = {}
  for i, r in ipairs(M.rects) do order[i] = r end
  for i, r in ipairs(order) do
    if lead and r.win == lead.id and r.after ~= "box" then
      table.insert(order, 1, table.remove(order, i))
      break
    end
  end
  local sizes, resized = {}, {}
  for _, r in ipairs(order) do
    local view = M.views[r.name]
    if view and r.w > 0 and r.h > 0 then
      local win = r.win and L.find_id(M.layout, r.win)
      local focused = M.focused == r.name and (not win or win == current)
      local area = buf:sub(r.x, r.y, r.w, r.h)
      if r.after == "rule" and r.w > 1 then
        -- A rule between this view and the one on its left.
        area:fill(0, 0, 1, r.h, g.rule, "Rule")
        r.x, r.w = r.x + 1, r.w - 1
        area = buf:sub(r.x, r.y, r.w, r.h)
      elseif r.after == "box" and r.w > 2 and r.h > 2 then
        area = M.box(area, nil, focused and "BorderFocus" or "Border")
        r.x, r.y, r.w, r.h = r.x + 1, r.y + 1, r.w - 2, r.h - 2
      end
      if backgrounds[r.name] then area:fill(0, 0, r.w, r.h, " ", backgrounds[r.name]) end
      local follower = win and followers and followers[win.id]
      if follower then L.time_follow(lead, win) end
      if win and (r.w < L.min_width or r.h < (focusable(r.name) and 2 or 1)) then
        area:text(0, 0, paw.util.fit("too small", r.w), "TooSmall")
      else
        draw(view, area, { focused = focused, x = r.x, y = r.y, win = win, follower = follower or nil })
      end
      if win then
        sizes[win.id] = r.w .. "x" .. r.h
        if sizes_before[win.id] and sizes_before[win.id] ~= sizes[win.id] then resized[#resized + 1] = win.id end
      end
    end
  end
  M.rects.sizes = sizes
  if #resized > 0 then
    paw.defer(function()
      for _, id in ipairs(resized) do paw.emit("win.resized", { win = id }) end
    end)
  end
  if M.rects.tabline then
    -- The tabs along the top, the current one bright.
    local line = buf:sub(0, 0, buf.width, 1)
    line:fill(0, 0, buf.width, 1, " ", "TitleBar")
    local x, spans = 0, {}
    for i, t in ipairs(M.tabs) do
      local mine = i == M.tab
      local used = line:text(x, 0, (mine and g.mark or " ") .. i .. " " .. L.tab_title(t) .. " ", mine and "TitleBarNameFocus" or "TitleBarName")
      spans[i] = { x = x, w = used }
      x = x + used + 1
    end
    M.rects.tabline.spans = spans
    -- What the tab line's own sections hold goes at the right end.
    local right = paw.statusline.tabline(buf.width)
    local used = 0
    for _, piece in ipairs(right) do used = used + api.str_width(piece[1]) end
    local at = buf.width - used - 1
    if used > 0 and at > x then
      for _, piece in ipairs(right) do at = at + line:text(at, 0, piece[1], piece[2]) end
    end
  end
  if M.float and M.views[M.float.name] then
    local r = float_rect(buf.width, buf.height)
    local outer = buf:sub(r.x, r.y, r.w, r.h)
    local inner = M.box(outer, M.float.title, "BorderFocus")
    r.x, r.y, r.w, r.h = r.x + 1, r.y + 1, r.w - 2, r.h - 2
    M.rects[#M.rects + 1] = r
    draw(M.views[r.name], inner, { focused = true, x = r.x, y = r.y })
    -- The float's keys along its bottom border, as on the key line.
    local entries = M.keybar and M.keybar.lines[r.name] and M.keybar.entries() or {}
    if #entries > 0 and r.w > 12 then
      local footer = outer:sub(2, r.h + 1, r.w - 2, 1)
      local used = paw.draw.keys(footer, 1, 0, entries, r.w - 4, "FloatFooter")
      if used > 0 then
        footer:text(0, 0, " ", "FloatFooter")
        footer:text(used + 1, 0, " ", "FloatFooter")
      end
    end
  end
  M.draw_hints(buf)
  if M.draw_popup then M.draw_popup(buf) end
  if M.draw_menu then M.draw_menu(buf) end
  paint_surfaces()
end

--- Draw one view by itself on a buffer of its own, as a window of a
--- graphical frontend shows it (see `paw.canvas.open_view`), or a pane of
--- its main area shows a window of the layout (`M.view_win`, while it is
--- drawn). Braille is drawn there as dots (`paw.canvas`), as the font has none.
function M.render_view(name, buf)
  M.screen = false
  local view = M.views[name]
  buf:fill(0, 0, buf.width, buf.height, " ", backgrounds[name] or "Normal")
  if not view then return end
  local win = M.view_win
  local focused = M.focused == name
  if win then focused = focused and win == L.current() and not paw.canvas.open_views[name] end
  draw(view, buf, { focused = focused, x = 0, y = 0, win = win })
end

--- List the keys that can follow a half-typed command, in a box along the
--- bottom of the screen.
function M.draw_hints(buf)
  if not paw.opt.hints then return end
  local hints, title = paw.keymap.hints()
  if not hints then return end
  local width = 0
  for _, hint in ipairs(hints) do width = math.max(width, api.str_width(hint.key) + api.str_width(hint.desc) + 4) end
  width = math.min(width, buf.width - 2)
  local columns = math.max(1, math.floor((buf.width - 2) / width))
  local rows = math.min(math.ceil(#hints / columns), buf.height - 6)
  if rows < 1 then return end
  local inner = M.box(buf:sub(0, buf.height - 2 - rows - 2, buf.width, rows + 2), title, "BorderFocus")
  for i, hint in ipairs(hints) do
    local col, row = math.floor((i - 1) / rows), (i - 1) % rows
    if col < columns then
      local x = col * width
      local used = inner:text(x + 1, row, hint.key, "HintKey")
      inner:text(x + 2 + used, row, paw.util.fit(hint.desc, math.max(1, width - used - 3)), "Normal")
    end
  end
end

--- Open a view in a box floating over the others. It takes the keyboard
--- until `paw.ui.close()`.
---   paw.ui.open("help", { title = "Keys", width = 80, height = 30 })
function M.open(name, opts)
  if not M.views[name] then error("no view `" .. tostring(name) .. "`", 2) end
  opts = opts or {}
  M.float = { name = name, title = opts.title, width = opts.width, height = opts.height, top = opts.top, back = M.float and M.float.back or M.focused }
  M.focused = name
  api.ui_redraw()
end

function M.close()
  if not M.float then
    -- A view drawn in a window of its own (`paw.canvas.open_view`) closes
    -- with it, as it would have closed floating.
    if paw.canvas.open_views[M.focused] then paw.canvas.close(M.focused) end
    return
  end
  M.focused = M.float.back
  M.float = nil
  api.ui_redraw()
end

--- A border between two windows held from a press: it follows the pointer.
local function hold_border(event, border, only_moved)
  paw.mouse.grab(paw.util.merge(event, { view_x = 0, view_y = 0 }), {
    drag = function(d) L.drag_border(border, M.rects, d.x, d.y) end,
    up = function(u)
      if u.moved or not only_moved then L.drag_border(border, M.rects, u.x, u.y) end
    end,
  })
end

local function route(event)
  local tabline = M.rects.tabline
  if tabline and event.y == tabline.y and not M.float then
    -- A click on a tab goes to it.
    for i, span in ipairs(tabline.spans or {}) do
      if event.kind == "down" and event.x >= span.x and event.x < span.x + span.w then L.tab_go(i) end
    end
    return
  end
  local target
  for _, r in ipairs(M.rects) do
    if event.x >= r.x and event.x < r.x + r.w and event.y >= r.y and event.y < r.y + r.h then target = r end
  end
  -- The rule between two windows side by side is a border to drag; so is
  -- the top row of a window below another, which the window hears first.
  local border = event.kind == "down" and not M.float and L.border_at(M.rects, event.x, event.y)
  if border and (border.dir == "h" or not target) then return hold_border(event, border) end
  -- A drag and its release belong to the view the button went down in,
  -- wherever the pointer has gone since.
  if event.kind == "down" then
    M.pressed = target and target.name
  elseif (event.kind == "drag" or event.kind == "up") and M.pressed then
    for _, r in ipairs(M.rects) do
      if r.name == M.pressed then target = r end
    end
    if event.kind == "up" then M.pressed = nil end
  end
  if M.float and (not target or target.name ~= M.float.name) then
    if event.kind == "down" then M.close() end
    return
  end
  if not target then return end
  local view = M.views[target.name]
  if not view then return end
  if event.kind == "down" and focusable(target.name) and not M.float then
    local win = target.win and L.find_id(M.layout, target.win)
    if win then L.enter(win) else M.focus(target.name) end
  end
  if paw.mouse.to_surface(target, event) then return end
  if view.on_mouse then
    view:on_mouse(paw.util.merge(event, {
      x = event.x - target.x, y = event.y - target.y, view_x = target.x, view_y = target.y, w = target.w, h = target.h,
      win = target.win,
    }))
  end
  -- A press on a window's top row that the window did not hold drags the
  -- border above it.
  if border and not paw.mouse.gesture() then hold_border(event, border, true) end
end

--- Route a mouse event to the view under the pointer, with coordinates
--- relative to that view (and `view_x`, `view_y`, `w`, `h`, where the view
--- is), after what floats over the views and a gesture under way have had
--- it (`paw.mouse`).
function M.mouse(event)
  if paw.mouse.take(event) then return end
  route(event)
  paw.mouse.done(event)
end

--- Show a message. `level` is "info" (default), "warn" or "error".
function M.notify(text, level)
  text, level = tostring(text), level or "info"
  local message = { text = text, level = level, time = api.now() }
  M.messages[#M.messages + 1] = message
  if #M.messages > 500 then table.remove(M.messages, 1) end
  api.log(string.format("[%s] %s", level, text))
  -- Without a terminal the message also goes to stderr; a graphical
  -- frontend shows `M.message` like the command line does.
  if not api.ui_attached() then io.stderr:write(text, "\n") end
  M.message = message
  paw.defer(function()
    if M.message == message then
      M.message = nil
      api.ui_redraw()
    end
  end, paw.opt.message_time)
  api.ui_redraw()
end

-- Every group as it was defined, so that the colours can be made again for
-- a terminal that shows fewer of them (`paw.opt.termcolors`).
local defined = {}
local set_raw = api.hl_set
local truecolor = nil

local function set(name, def)
  defined[name] = def
  if truecolor == nil then truecolor = paw.draw.truecolor() end
  -- A window draws the group as defined, whatever the terminal shows.
  local shown = paw.draw.term_def(def, truecolor)
  set_raw(name, shown, shown ~= def and def or nil)
end
-- Groups set straight through the kernel's call get the same treatment.
api.hl_set = set

--- Define a highlight group: a table of `fg`, `bg`, `bold`, `dim`, `italic`,
--- `underline`, `reverse`, `strike`, or the name of a group to follow.
--- Colours are `#rrggbb`, or a number for one of the terminal's 256; on a
--- terminal without 24-bit colour each `#rrggbb` is shown as the nearest of
--- the 256.
function M.hl(name, def)
  set(name, def)
end

--- Define many highlight groups at once.
function M.theme(groups)
  for name, def in pairs(groups) do set(name, def) end
end

--- Set every group again: after `paw.opt.termcolors` has changed.
function M.recolour()
  truecolor = paw.draw.truecolor()
  for name, def in pairs(defined) do set(name, def) end
  api.ui_redraw()
end

paw.on("option.changed", function(event)
  if event.name == "termcolors" then M.recolour() end
  if event.name == "ascii" then paw.draw.use_glyphs() end
end)

--- Ask for a line of text on the command line.
---   paw.ui.input({ prompt = "Name: ", text = "Bass" }, function(text) ... end)
--- The callback is not called when the prompt is cancelled. Options are
--- the command line's (`paw.views.cmdline.open`): `complete`, `history`,
--- `on_change` (live preview), `anchor` (draw it beside what it is about),
--- `on_key`.
function M.input(opts, on_submit)
  require("paw.views.cmdline").open(opts, on_submit)
end

M.redraw = api.ui_redraw

-- Layers and locators ----------------------------------------------------------
--
-- What modules draw over a view (diagnostics, annotations, a suggestion),
-- each a layer of a part of it, drawn in order; and how a view says where
-- things with an address are (paw/address.lua). The piano roll has layers
-- of its own (`paw.ui.views.pianoroll.layer`).

M.layers = {}  -- view -> part -> { { name, order, paint } }

--- Draw `paint(ctx)` as a layer of a part of a view (`"arrange", "header"`),
--- replacing one of the same name (nil removes it). The view says what
--- `ctx` holds where it calls `paw.ui.paint`.
function M.layer(view, part, name, order, paint)
  M.layers[view] = M.layers[view] or {}
  local list = M.layers[view][part] or {}
  for i = #list, 1, -1 do
    if list[i].name == name then table.remove(list, i) end
  end
  if paint then list[#list + 1] = { name = name, order = order, paint = paint } end
  table.sort(list, function(a, b) return a.order < b.order end)
  M.layers[view][part] = list
  api.ui_redraw()
end

--- Draw the layers of a part of a view: views call this where the part is drawn.
function M.paint(view, part, ctx)
  local list = M.layers[view] and M.layers[view][part]
  if not list then return end
  for _, layer in ipairs(list) do layer.paint(ctx) end
end

M.locators = {}  -- view -> locator

--- Say how a view places locations (`{ uri, selector }`):
---   at()            the location under its cursor, or nil
---   position()      where its cursor is, as a list of numbers to sort by
---   place(location) where a location is in it, the same way, or nil when it does not show it
---   go(location)    put its cursor there
function M.locator(view, spec) M.locators[view] = spec end

--- The location under the cursor of the focused view (or `view`).
function M.location(view)
  local loc = M.locators[view or M.focused]
  return loc and loc.at() or nil
end

--- Go to a location in the view that shows it best (the piano roll for
--- notes, the device panel for devices and parameters, the arrange view for
--- tracks and time), focusing it.
function M.go(location)
  for _, name in ipairs({ "pianoroll", "devices", "arrange", "mixer" }) do
    local loc = M.locators[name]
    if loc and loc.place(location, true) then
      if not M.visible(name) then M.show(name) end
      M.focus(name)
      return loc.go(location)
    end
  end
end

-- Meters and the playhead move without anything changing in the project, so
-- redraw on a timer while playing and for a moment after any activity.
local active_until = 0

--- Keep the screen animating for a while, for instance after playing a note.
function M.poke(ms)
  active_until = math.max(active_until, api.now() + (ms or 1500))
end

function M.start_ticker()
  paw.every(1000 / paw.opt.fps, function()
    if api.ui_attached() and (api.transport_get().playing or api.now() < active_until) then api.ui_redraw() end
  end)
end

return M
