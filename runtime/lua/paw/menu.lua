-- A menu at the pointer: what a right click opens in the terminal, as the
-- window's context menus. It floats over everything and takes the keys and
-- the pointer until an entry is chosen or it is let go.
--
--   daw.ui.menu({
--     { label = "Rename", run = function() ... end },
--     "-",
--     { label = "Colour", items = { { label = "Coral", run = ... }, ... } },
--     { label = "Mute", checked = true, run = ... },
--     { label = "Delete", keys = "x", enabled = false },
--   }, { x = 10, y = 4 })
--
-- `x` and `y` are where on the screen it opens (the pointer). Keys: `j` `k`
-- (or the arrows) move, Enter, Space or `l` choose or open a submenu, `h`
-- goes back out of one, Esc or `q` lets go. The pointer: a click chooses,
-- moving over an entry selects it (and opens its submenu), a click outside
-- lets go, the wheel moves.
local api = daw.api
local util = daw.util
local M = {}

-- The menus open, the first at the bottom: `{ items, x, y, selected, rect }`,
-- with what took the keys before.
local open = { levels = {}, grabber = nil }
daw.seats.keep("menu", function() return open end, function(o) open = o end,
  function() return { levels = {}, grabber = nil } end)

local function separator(item) return item == "-" or (type(item) == "table" and item.separator) end
local function usable(item)
  return not separator(item) and item.enabled ~= false and (item.run or item.items)
end

--- Whether a menu is open.
function M.is_open()
  return #open.levels > 0
end

local on_key

--- Let go of the menu, or of the submenus above level `keep`.
function M.close(keep)
  keep = keep or 0
  for i = #open.levels, keep + 1, -1 do open.levels[i] = nil end
  if #open.levels == 0 and daw.ui.grabber == on_key then
    daw.ui.grabber = open.grabber
    open.grabber = nil
  end
  api.ui_redraw()
end

local function first_usable(items, from, step)
  local n = #items
  for k = 0, n - 1 do
    local i = (from - 1 + k * step) % n + 1
    if usable(items[i]) then return i end
  end
end

local function push(items, x, y)
  open.levels[#open.levels + 1] = { items = items, x = x, y = y, selected = first_usable(items, 1, 1) or 1 }
  api.ui_redraw()
end

--- Open a menu of `items` at `opts.x`, `opts.y` on the screen. See the top
--- of the file.
function M.open(items, opts)
  opts = opts or {}
  if #items == 0 then return end
  if #open.levels == 0 then open.grabber = daw.ui.grabber end
  open.levels = {}
  daw.ui.grabber = on_key
  push(items, opts.x or 0, opts.y or 0)
end

--- Choose entry `index` of level `at`: a submenu opens beside it, anything
--- else is done once every menu is let go.
local function choose(at, index)
  local level = open.levels[at]
  local item = level and level.items[index]
  if not (item and usable(item)) then return end
  level.selected = index
  M.close(at)
  if item.items then
    -- Beside its entry; before the menu has been drawn, near it.
    local r = level.rect or { x = level.x, y = level.y, w = 3 }
    return push(item.items, r.x + r.w - 1, r.y + index)
  end
  M.close(0)
  item.run()
end

on_key = function(key)
  local level = open.levels[#open.levels]
  if not level then return end
  local items = level.items
  if key == "j" or key == "<Down>" or key == "<C-n>" or key == "<Tab>" then
    level.selected = first_usable(items, level.selected % #items + 1, 1) or level.selected
  elseif key == "k" or key == "<Up>" or key == "<C-p>" or key == "<S-Tab>" then
    level.selected = first_usable(items, (level.selected - 2) % #items + 1, -1) or level.selected
  elseif key == "<CR>" or key == "<Space>" or key == "l" or key == "<Right>" then
    return choose(#open.levels, level.selected)
  elseif key == "h" or key == "<Left>" or key == "<BS>" then
    if #open.levels > 1 then return M.close(#open.levels - 1) end
  elseif key == "<Esc>" or key == "q" or key == "<C-c>" then
    return M.close(0)
  end
  api.ui_redraw()
end

--- Draw the menus over the screen. Called last by `daw.ui.render`.
function M.draw(buf)
  local g = daw.draw.g
  for _, level in ipairs(open.levels) do
    local items = level.items
    local label_w, keys_w = 0, 0
    for _, item in ipairs(items) do
      if not separator(item) then
        label_w = math.max(label_w, api.str_width(item.label) + (item.items and 2 or 0))
        if item.keys then keys_w = math.max(keys_w, api.str_width(item.keys)) end
      end
    end
    local w = math.min(buf.width, label_w + (keys_w > 0 and keys_w + 2 or 0) + 4 + 2)
    local h = math.min(buf.height, #items + 2)
    local x = util.clamp(level.x, 0, math.max(0, buf.width - w))
    -- A submenu that has no room to the right of its menu opens to the left.
    if level ~= open.levels[1] and level.x + w > buf.width then
      local parent = open.levels[1]
      for i, l in ipairs(open.levels) do if open.levels[i + 1] == level then parent = l end end
      if parent.rect then x = math.max(0, parent.rect.x - w + 1) end
    end
    local y = util.clamp(level.y, 0, math.max(0, buf.height - h))
    level.rect = { x = x, y = y, w = w, h = h }
    local inner = daw.ui.box(buf:sub(x, y, w, h), nil, "BorderFocus")
    inner:fill(0, 0, inner.width, inner.height, " ", "Pmenu")
    for i, item in ipairs(items) do
      local row = i - 1
      if row >= inner.height then break end
      if separator(item) then
        inner:fill(0, row, inner.width, 1, g.h, "Border")
      else
        local sel = i == level.selected
        local style = sel and "PmenuSel" or usable(item) and "Pmenu" or "PmenuDesc"
        inner:fill(0, row, inner.width, 1, " ", style)
        if item.checked then inner:text(0, row, g.on, style) end
        inner:text(2, row, util.fit(item.label, math.max(1, inner.width - 3)), style)
        if item.items then
          inner:text(inner.width - 1, row, g.closed, style)
        elseif item.keys then
          inner:text(inner.width - 1 - api.str_width(item.keys), row, item.keys, sel and "PmenuSelDesc" or "PmenuDesc")
        end
      end
    end
  end
end

--- The level and entry under a cell of the screen, the topmost first.
local function under(x, y)
  for at = #open.levels, 1, -1 do
    local r = open.levels[at].rect
    if r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      local index = y - r.y
      if index < 1 or index > #open.levels[at].items then index = nil end
      return at, index
    end
  end
end

-- The pointer goes to the menu first while one is open; anything outside
-- it lets it go.
daw.mouse.overlays[#daw.mouse.overlays + 1] = function(e)
  if #open.levels == 0 then return false end
  local at, index = under(e.x, e.y)
  local kind = e.kind
  if kind == "move" or kind == "drag" then
    if at and index then
      local level = open.levels[at]
      local item = level.items[index]
      local same = level.selected == index and (#open.levels == at or (#open.levels == at + 1 and item.items))
      if not same then
        if usable(item) then
          level.selected = index
          M.close(at)
          if item.items then choose(at, index) end
        end
        api.ui_redraw()
      end
    end
  elseif kind == "down" then
    if not at then
      M.close(0)
    elseif index then
      choose(at, index)
    end
  elseif at then
    local step = daw.mouse.wheel(e)
    if step then
      local level = open.levels[at]
      level.selected = first_usable(level.items, (level.selected - 1 + step) % #level.items + 1, step) or level.selected
      M.close(at)
    end
  end
  return true
end

daw.ui.menu = M.open
daw.ui.draw_menu = M.draw

return M
