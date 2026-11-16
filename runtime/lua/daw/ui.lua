-- The screen: views, the layout that arranges them, focus, messages and
-- highlight groups.
--
-- A view is a table with a `render(self, buf, ctx)` function that draws into a
-- cell buffer. Everything on screen, including the built-in arrange view and
-- status line, is a view registered through `daw.ui.view`.
local api = daw.api
local M = {
  Buf = require("daw.buf"),
  views = {},
  focused = "arrange",
  messages = {},   -- every message so far, oldest first
  message = nil,   -- the one on the command line now
  grabber = nil,   -- function that takes every key while set (prompts)
  float = nil,     -- the floating view, if one is open
  rects = {},      -- where each view was last drawn
}

-- Rows are stacked in a `v` node and columns in an `h` node. A child with a
-- `size` gets exactly that many cells; the rest share what is left.
-- A child's `weight` (default 1) is its share of what is left, and `min`
-- the fewest cells it is given while there are that many. A child with
-- `float_below = n` leaves the layout on screens narrower than `n` and is
-- drawn over the others instead, along the right edge.
M.layout = {
  dir = "v",
  { dir = "h", { view = "arrange" }, { view = "devices", size = 40, hidden = true, float_below = 80 } },
  { view = "pianoroll", hidden = true, weight = 2 },
  { view = "mixer", weight = 0.5, min = 14, hidden = true },
  { view = "status", size = 1 },
  { view = "cmdline", size = 1 },
}

--- Register a view, replacing any view of the same name.
---   daw.ui.view("clock", { render = function(self, buf) buf:text(0, 0, os.date()) end })
--- Optional fields: `focusable` (default true), `on_key(self, key)` for keys
--- with no mapping, `modal` (every key goes to `on_key`), `on_mouse(self, event)`,
--- `on_show(self)`, `on_hide(self)`.
function M.view(name, def)
  def.name = name
  M.views[name] = def
  api.ui_redraw()
  return def
end

local function find(node, name)
  if node.view == name then return node end
  for _, child in ipairs(node) do
    local found = find(child, name)
    if found then return found end
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

function M.show(name)
  local node = find(M.layout, name)
  if not node then error("view `" .. name .. "` is not in the layout", 2) end
  if node.hidden then
    node.hidden = false
    local view = M.views[name]
    if view and view.on_show then view:on_show() end
  end
  api.ui_redraw()
end

function M.hide(name)
  local node = find(M.layout, name)
  if node and not node.hidden then
    node.hidden = true
    local view = M.views[name]
    if view and view.on_hide then view:on_hide() end
  end
  if M.focused == name then M.focus_next() end
  api.ui_redraw()
end

function M.toggle(name)
  local node = find(M.layout, name)
  if node and node.hidden then
    M.show(name)
    if focusable(name) then M.focus(name) end
  else
    M.hide(name)
  end
end

--- Add a view to the layout along one side of the screen.
---   daw.ui.dock("clock", { side = "top", size = 5 })
--- `side` is "top", "bottom" (above the status line), "left" or "right" (beside
--- the arrange view). Without `size` the view shares the space left over.
--- Docking a view that is already in the layout moves it.
function M.dock(name, opts)
  opts = opts or {}
  local function remove(node)
    for i = #node, 1, -1 do
      if node[i].view == name then table.remove(node, i) else remove(node[i]) end
    end
  end
  remove(M.layout)
  local node = { view = name, size = opts.size, hidden = opts.hidden }
  local side = opts.side or "bottom"
  if side == "left" or side == "right" then
    local row = M.layout[1]
    for _, child in ipairs(M.layout) do
      if child.dir == "h" then row = child end
    end
    table.insert(row, side == "left" and 1 or #row + 1, node)
  elseif side == "top" then
    table.insert(M.layout, 1, node)
  else
    local at = #M.layout + 1
    for i, child in ipairs(M.layout) do
      if child.view == "status" then at = i end
    end
    table.insert(M.layout, at, node)
  end
  api.ui_redraw()
end

--- Give a view the keyboard, showing it first if it is hidden.
function M.focus(name)
  if not M.views[name] then error("no view `" .. tostring(name) .. "`", 2) end
  local node = find(M.layout, name)
  if node and node.hidden then M.show(name) end
  if M.focused ~= name then
    local old = M.focused
    M.focused = name
    daw.emit("view.focused", { view = name, old = old })
  end
  api.ui_redraw()
end

--- Focus the next (or with -1 the previous) view that takes the keyboard.
function M.focus_next(step)
  local names, at = {}, 0
  for _, rect in ipairs(M.arrange()) do
    if focusable(rect.name) then
      names[#names + 1] = rect.name
      if rect.name == M.focused then at = #names end
    end
  end
  if #names == 0 then return end
  M.focus(names[(at - 1 + (step or 1)) % #names + 1])
end

local function place(node, x, y, w, h, out, screen_w, after)
  if node.view then
    out[#out + 1] = { name = node.view, x = x, y = y, w = w, h = h, after = after }
    return
  end
  local vertical = node.dir ~= "h"
  local total = vertical and h or w
  local children, fixed = {}, 0
  for _, child in ipairs(node) do
    if not child.hidden then
      if child.float_below and screen_w < child.float_below and child.view then
        -- Too narrow to stand beside the others: drawn over them instead.
        out.floating = out.floating or {}
        out.floating[#out.floating + 1] = child
      else
        children[#children + 1] = child
        if child.size then fixed = fixed + child.size end
      end
    end
  end
  -- Shares of what is left, with a child below its `min` given that much
  -- and the rest shared again among the others.
  local spare = math.max(0, total - fixed)
  local sizes = {}
  for _ = 1, #children do
    local weights, left = 0, spare
    for i, child in ipairs(children) do
      if child.size then sizes[i] = child.size elseif sizes[i] then left = left - sizes[i] else weights = weights + (child.weight or 1) end
    end
    local grew, weight_seen = false, 0
    for i, child in ipairs(children) do
      if not child.size and not sizes[i] then
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
        if not child.size and not sizes[i] then
          local before = math.floor(left * weight_seen / weights)
          weight_seen = weight_seen + (child.weight or 1)
          sizes[i] = math.floor(left * weight_seen / weights) - before
        end
      end
      break
    end
  end
  local pos = 0
  for i, child in ipairs(children) do
    local size = math.max(0, math.min(sizes[i] or 0, total - pos))
    if vertical then
      place(child, x, y + pos, w, size, out, screen_w)
    else
      -- A view beside another has a rule along its left edge.
      place(child, x + pos, y, size, h, out, screen_w, i > 1 and "rule" or nil)
    end
    pos = pos + size
  end
end

--- Where each visible view goes on a screen of the current size.
function M.arrange(width, height)
  if not width then width, height = api.ui_size() end
  local out = {}
  place(M.layout, 0, 0, width, height, out, width)
  -- Panels that float on a narrow screen sit along the right edge, over the
  -- top part of the screen.
  for _, node in ipairs(out.floating or {}) do
    local w = math.min(node.size or 40, width - 4)
    out[#out + 1] = { name = node.view, x = width - w, y = 0, w = w, h = math.max(1, height - 2), after = "box" }
  end
  out.floating = nil
  return out
end

--- The smallest screen the program draws on; below it a notice says so.
M.min_width, M.min_height = 60, 16

-- Views drawn on a background of their own: the status line and the key line.
local backgrounds = { status = "StatusLine", cmdline = "KeyBar" }
M.backgrounds = backgrounds

local function draw(view, buf, ctx)
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

local function float_rect(width, height)
  local f = M.float
  local w = math.min(f.width or 72, width - 2)
  local h = math.min(f.height or 24, height - 2)
  return { name = f.name, x = math.floor((width - w) / 2), y = math.floor((height - h) / 2), w = w, h = h }
end

--- Draw a box around a buffer's edge and return a buffer for the inside.
function M.box(buf, title, style)
  local w, h = buf.width, buf.height
  style = style or "Border"
  local g = daw.draw.g
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
--- `right` (state, at the right end), `focused`. Focus shows as an amber
--- mark in the first column and a bright name.
---   local body = daw.ui.titlebar(buf, { name = "Mixer", context = "5 tracks", focused = ctx.focused })
function M.titlebar(buf, opts)
  local g = daw.draw.g
  local focused = opts.focused
  buf:fill(0, 0, buf.width, 1, " ", "TitleBar")
  buf:text(0, 0, g.mark, focused and "TitleBarMarkFocus" or "TitleBarMark")
  local x = 2
  local right = opts.right and tostring(opts.right) or ""
  local right_w = api.str_width(right)
  if opts.pill then
    -- A coloured label ahead of the name, such as a clip in its track's colour.
    x = x + buf:text(x, 0, " " .. tostring(opts.pill[1]) .. " ", opts.pill[2]) + 1
  end
  if opts.name then
    local room = math.max(1, buf.width - x - (right_w > 0 and right_w + 2 or 0))
    local name = tostring(opts.name)
    if api.str_width(name) > room then name = daw.util.fit(name, room) end
    x = x + buf:text(x, 0, name, focused and "TitleBarNameFocus" or "TitleBarName")
  end
  if opts.context and opts.context ~= "" then
    local room = buf.width - x - 2 - (right_w > 0 and right_w + 2 or 0)
    if room >= 4 then
      local text = tostring(opts.context)
      if api.str_width(text) > room then text = daw.util.fit(text, room) end
      x = x + 2 + buf:text(x + 2, 0, text, "TitleBar")
    end
  end
  if right_w > 0 and buf.width - right_w - 1 > x then buf:text(buf.width - right_w - 1, 0, right, "TitleBarFaint") end
  return buf:sub(0, 1, buf.width, buf.height - 1)
end

--- What is shown on a screen too small to draw on: the status line, the
--- command line, and in the middle how big the screen is and needs to be.
local function too_small(buf)
  local w, h = buf.width, buf.height
  local g = daw.draw.g
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

--- Draw the whole screen. Called by the kernel.
function M.render(buf)
  buf:fill(0, 0, buf.width, buf.height, " ", "Normal")
  if buf.width < M.min_width or buf.height < M.min_height then return too_small(buf) end
  M.rects = M.arrange(buf.width, buf.height)
  local g = daw.draw.g
  for _, r in ipairs(M.rects) do
    local view = M.views[r.name]
    if view and r.w > 0 and r.h > 0 then
      local area = buf:sub(r.x, r.y, r.w, r.h)
      if r.after == "rule" and r.w > 1 then
        -- A rule between this view and the one on its left.
        area:fill(0, 0, 1, r.h, g.rule, "Rule")
        r.x, r.w = r.x + 1, r.w - 1
        area = buf:sub(r.x, r.y, r.w, r.h)
      elseif r.after == "box" and r.w > 2 and r.h > 2 then
        local focused = M.focused == r.name
        area = M.box(area, nil, focused and "BorderFocus" or "Border")
        r.x, r.y, r.w, r.h = r.x + 1, r.y + 1, r.w - 2, r.h - 2
      end
      if backgrounds[r.name] then area:fill(0, 0, r.w, r.h, " ", backgrounds[r.name]) end
      draw(view, area, { focused = M.focused == r.name, x = r.x, y = r.y })
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
      local used = daw.draw.keys(footer, 1, 0, entries, r.w - 4, "FloatFooter")
      if used > 0 then
        footer:text(0, 0, " ", "FloatFooter")
        footer:text(used + 1, 0, " ", "FloatFooter")
      end
    end
  end
  M.draw_hints(buf)
  if M.draw_popup then M.draw_popup(buf) end
end

--- Draw one view by itself on a buffer of its own, as a window of a
--- graphical frontend shows it (see `daw.canvas.open_view`). Curves are
--- drawn without braille, which the window's font does not have.
function M.render_view(name, buf)
  local view = M.views[name]
  buf:fill(0, 0, buf.width, buf.height, " ", backgrounds[name] or "Normal")
  if not view then return end
  daw.draw.window = true
  draw(view, buf, { focused = M.focused == name, x = 0, y = 0, window = true })
  daw.draw.window = false
end

--- List the keys that can follow a half-typed command, in a box along the
--- bottom of the screen.
function M.draw_hints(buf)
  if not daw.opt.hints then return end
  local hints, title = daw.keymap.hints()
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
      inner:text(x + 2 + used, row, daw.util.fit(hint.desc, math.max(1, width - used - 3)), "Normal")
    end
  end
end

--- Open a view in a box floating over the others. It takes the keyboard
--- until `daw.ui.close()`.
---   daw.ui.open("help", { title = "Keys", width = 80, height = 30 })
function M.open(name, opts)
  if not M.views[name] then error("no view `" .. tostring(name) .. "`", 2) end
  opts = opts or {}
  M.float = { name = name, title = opts.title, width = opts.width, height = opts.height, back = M.float and M.float.back or M.focused }
  M.focused = name
  api.ui_redraw()
end

function M.close()
  if not M.float then
    -- A view drawn in a window of its own (`daw.canvas.open_view`) closes
    -- with it, as it would have closed floating.
    local window = daw.canvas.open_views[M.focused]
    if window and window.cells then daw.canvas.close(M.focused) end
    return
  end
  M.focused = M.float.back
  M.float = nil
  api.ui_redraw()
end

--- Route a mouse event to the view under the pointer, with coordinates
--- relative to that view.
function M.mouse(event)
  local target
  for _, r in ipairs(M.rects) do
    if event.x >= r.x and event.x < r.x + r.w and event.y >= r.y and event.y < r.y + r.h then target = r end
  end
  if M.float and (not target or target.name ~= M.float.name) then
    if event.kind == "down" then M.close() end
    return
  end
  if not target then return end
  local view = M.views[target.name]
  if not view then return end
  if event.kind == "down" and focusable(target.name) and not M.float then M.focus(target.name) end
  if view.on_mouse then
    view:on_mouse(daw.util.merge(event, { x = event.x - target.x, y = event.y - target.y }))
  end
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
  daw.defer(function()
    if M.message == message then
      M.message = nil
      api.ui_redraw()
    end
  end, daw.opt.message_time)
  api.ui_redraw()
end

-- Every group as it was defined, so that the colours can be made again for
-- a terminal that shows fewer of them (`daw.opt.termcolors`).
local defined = {}
local set_raw = api.hl_set
local truecolor = nil

local function set(name, def)
  defined[name] = def
  if truecolor == nil then truecolor = daw.draw.truecolor() end
  -- A window draws the group as defined, whatever the terminal shows.
  local shown = daw.draw.term_def(def, truecolor)
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

--- Set every group again: after `daw.opt.termcolors` has changed.
function M.recolour()
  truecolor = daw.draw.truecolor()
  for name, def in pairs(defined) do set(name, def) end
  api.ui_redraw()
end

daw.on("option.changed", function(event)
  if event.name == "termcolors" then M.recolour() end
  if event.name == "ascii" then daw.draw.use_glyphs() end
end)

--- Ask for a line of text on the command line.
---   daw.ui.input({ prompt = "Name: ", text = "Bass" }, function(text) ... end)
--- The callback is not called when the prompt is cancelled.
function M.input(opts, on_submit)
  require("daw.views.cmdline").open(opts, on_submit)
end

M.redraw = api.ui_redraw

-- Meters and the playhead move without anything changing in the project, so
-- redraw on a timer while playing and for a moment after any activity.
local active_until = 0

--- Keep the screen animating for a while, for instance after playing a note.
function M.poke(ms)
  active_until = math.max(active_until, api.now() + (ms or 1500))
end

function M.start_ticker()
  daw.every(1000 / daw.opt.fps, function()
    if api.ui_attached() and (api.transport_get().playing or api.now() < active_until) then api.ui_redraw() end
  end)
end

return M
