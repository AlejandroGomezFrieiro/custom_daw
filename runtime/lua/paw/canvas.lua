-- Drawing for graphical frontends: what the cell grid is to a terminal.
--
-- A view that has a `paint` function can be shown by a graphical frontend
-- in a window of its own, at any size, in pixels:
--
--   paw.ui.view("scope", {
--     paint = function(self, g, ctx)          -- ctx: width, height, focused
--       local c = paw.canvas.palette
--       g:rect(0, 0, ctx.width, ctx.height, { fill = c.surface })
--       g:text(12, 10, "hello", { color = c.text, size = 14, bold = true })
--       g:line(0, 40, ctx.width, 40, { color = c.line_bar })
--       g:poly({ 0, 80, 40, 60, 80, 90 }, { color = c.select, width = 2 })
--     end,
--     pointer = function(self, e) end,        -- e: kind, x, y, button, ctrl, shift, alt, dx, dy
--   })
--   paw.canvas.open("scope", { title = "Scope", width = 640, height = 360 })
--
-- `e.kind` is "down", "up", "move" (while a button is held), "hover" (the
-- pointer moving over the window with no button down), "double" or
-- "wheel".
--
-- The same view shows its pixels in a terminal that shows images when its
-- `render` keeps an area for them (`buf:surface`). `ctx.surface` is then
-- true, `ctx.cell` the terminal's cell size `{ w, h }` in pixels and
-- `ctx.fg`, `ctx.bg` its own colours (nil where it did not say), so that
-- the view can lay out in whole cells and leave out what the terminal's
-- own text shows (a toolbar). The pointer comes to `pointer` in pixels
-- there too. Keys go to the view as they do in the terminal: through the
-- key mappings made for it, or its `on_key`.
--
-- `g:sub(x, y, w, h)` gives a painter for part of the area: what is drawn
-- through it is placed from its corner and cut off at its edges, which is
-- how a view scrolls. Colours are `#rrggbb` or `#rrggbbaa`.
--
-- `paw.canvas.palette` is the window's palette, by the names the window's
-- own drawing uses (`Theme` in crates/paw-gui/src/theme.rs, which takes its
-- colours from here), so that a painted view looks like the rest of the
-- window: neutral surfaces, colour for state, and a track's hue only on
-- what is the track's.
--
-- A view with no `paint` is shown too: `paw.canvas.open_view(name)` opens
-- any view in a window, drawn cell by cell as the terminal draws it, in the
-- window's monospace font, with its keys and its `on_mouse` as in the
-- terminal. `g:mono` is the primitive that carries it: a run of text in
-- cells of that font, on a background of its own.
local api = paw.api
local band = bit.band
local M = {
  open_views = {},
  -- What a view was called when it was opened (`open`), for the pane or
  -- the window that shows it.
  titles = {},
  -- The size of a cell of the window's monospace font in pixels. A window
  -- measures it and says so with each paint; this is JetBrains Mono at
  -- 13 px until one has.
  cell = { w = 7.8, h = 17 },
}

M.palette = {
  -- Surfaces, from the back forward.
  surface = "#18191c", lane = "#1f2024", lane_alt = "#1c1d20", panel = "#26272b",
  panel_sel = "#313238", well = "#121315", divider = "#0f1012", card = "#2b2c31",
  card_line = "#3d3f46", control = "#34363c", control_hover = "#3e4047", control_press = "#2a2b30",
  -- Grid lines: half beats, beats, bars.
  line_sub = "#25262a", line_beat = "#2c2d32", line_bar = "#3b3d44",
  -- Text, by weight; and text on a coloured face.
  text = "#e4e5e8", text_2 = "#a1a3ab", text_3 = "#6b6e77", text_off = "#4a4c53", on_hue = "#121316",
  -- States: selection and focus, playhead and loop, playing, recording,
  -- mute, solo, warnings and errors.
  select = "#46b9fe", play = "#fec13a", play_on = "#4ade80", rec = "#ef4444",
  mute = "#f08a3c", solo = "#f2d24b", warn = "#f2c94c", error = "#ff5a4f",
  -- Meters, by position: to -18 dB, to -9, to -3, to 0, and over.
  meter_low = "#35c46a", meter_mid = "#a6d84a", meter_high = "#f2d24b", meter_hot = "#f59e3b",
  meter_clip = "#ff3b30", meter_well = "#0e0f11",
  -- A keyboard drawn beside a roll.
  key_white = "#d8d9dc", key_black = "#1c1d20", key_line = "#9a9ca3",
}
local c = M.palette

local Painter = {}
Painter.__index = Painter

local function painter(ops, x, y, w, h)
  return setmetatable({ ops = ops, x = x, y = y, width = w, height = h }, Painter)
end

--- A painter for the rectangle `x, y, w, h` of this one.
function Painter:sub(x, y, w, h)
  local x0, y0 = math.max(self.x, self.x + x), math.max(self.y, self.y + y)
  local x1 = math.min(self.x + self.width, self.x + x + w)
  local y1 = math.min(self.y + self.height, self.y + y + h)
  local p = painter(self.ops, x0, y0, math.max(0, x1 - x0), math.max(0, y1 - y0))
  -- Where the part's own corner is, which may be outside what shows of it.
  p.ox, p.oy = self:origin_x() + x, self:origin_y() + y
  return p
end

function Painter:origin_x() return self.ox or self.x end
function Painter:origin_y() return self.oy or self.y end

--- A filled or outlined rectangle. `style`: `fill`, `stroke`, `width`, `radius`.
function Painter:rect(x, y, w, h, style)
  style = style or {}
  local x0, y0 = self:origin_x() + x, self:origin_y() + y
  local x1, y1 = math.min(x0 + w, self.x + self.width), math.min(y0 + h, self.y + self.height)
  x0, y0 = math.max(x0, self.x), math.max(y0, self.y)
  if x1 <= x0 or y1 <= y0 then return end
  self.ops[#self.ops + 1] = { "r", x0, y0, x1 - x0, y1 - y0, style.fill or "", style.stroke or "", style.width or 1, style.radius or 0 }
end

--- Text with its top left corner at `x, y`. `style`: `color`, `size`,
--- `bold`, `align` ("left", "center", "right") within `width`. Text that
--- starts outside the painter is left out; `width` cuts it short.
function Painter:text(x, y, text, style)
  style = style or {}
  local x0, y0 = self:origin_x() + x, self:origin_y() + y
  local size = style.size or 12
  if x0 < self.x - 0.5 or y0 < self.y - 0.5 or x0 >= self.x + self.width or y0 + size > self.y + self.height + 2 then return end
  -- How wide it may be before it meets the painter's edge: centred text has
  -- half of its width to each side of `x`, text aligned right ends there.
  local left, right = x0 - self.x, self.x + self.width - x0
  local room = style.align == "center" and 2 * math.min(left, right) or style.align == "right" and left or right
  room = math.min(style.width or 1e9, room)
  self.ops[#self.ops + 1] = { "t", x0, y0, tostring(text), style.color or c.text, size, style.bold and 1 or 0, style.align or "left", room }
end

--- Cut a segment to the painter's rectangle. Returns nil when it misses.
local function cut(self, x0, y0, x1, y1)
  local t0, t1 = 0, 1
  local dx, dy = x1 - x0, y1 - y0
  local function edge(p, q)
    if p == 0 then return q >= 0 end
    local r = q / p
    if p < 0 then
      if r > t1 then return false end
      if r > t0 then t0 = r end
    else
      if r < t0 then return false end
      if r < t1 then t1 = r end
    end
    return true
  end
  if edge(-dx, x0 - self.x) and edge(dx, self.x + self.width - x0) and edge(-dy, y0 - self.y) and edge(dy, self.y + self.height - y0) then
    return x0 + t0 * dx, y0 + t0 * dy, x0 + t1 * dx, y0 + t1 * dy
  end
end

--- A line through the points `{ x1, y1, x2, y2, ... }`. `style`: `color`,
--- `width`, and `fill` for a closed shape (which is not cut at the edges).
function Painter:poly(points, style)
  style = style or {}
  local ox, oy = self:origin_x(), self:origin_y()
  local parts, pen = {}, nil
  if style.fill then
    for i = 1, #points - 1, 2 do
      parts[#parts + 1] = string.format("%s %.1f %.1f", i == 1 and "M" or "L", ox + points[i], oy + points[i + 1])
    end
    parts[#parts + 1] = "Z"
  else
    for i = 1, #points - 3, 2 do
      local ax, ay, bx, by = cut(self, ox + points[i], oy + points[i + 1], ox + points[i + 2], oy + points[i + 3])
      if ax then
        if not pen or math.abs(pen[1] - ax) > 0.05 or math.abs(pen[2] - ay) > 0.05 then
          parts[#parts + 1] = string.format("M %.1f %.1f", ax, ay)
        end
        parts[#parts + 1] = string.format("L %.1f %.1f", bx, by)
        pen = { bx, by }
      end
    end
  end
  if #parts == 0 then return end
  self.ops[#self.ops + 1] = { "p", table.concat(parts, " "), style.color or "", style.width or 1, style.fill or "" }
end

function Painter:line(x0, y0, x1, y1, style)
  self:poly({ x0, y0, x1, y1 }, style)
end

--- Add a run of monospace cells to a drawing. The window's font has no
--- braille, so each braille character (U+2800 to U+28FF) is left blank in
--- the run and its dots are drawn as small rectangles over it: the bits of
--- the character's offset are the dots of a grid of 2 columns by 4 rows.
local DOT_ROW = { [0] = 0, 1, 2, 0, 1, 2, 3, 3 }
local DOT_COLUMN = { [0] = 0, 0, 0, 1, 1, 1, 0, 1 }
local function add_run(ops, x, y, w, h, chars, colour, background, attrs)
  local dots, sextants, shown, cell = {}, {}, {}, M.cell.w
  for i, ch in ipairs(chars) do
    local b1, b2, b3, b4 = ch:byte(1, 4)
    if b1 == 0xF0 and b2 == 0x9F and b3 and b3 >= 0xAC and b3 <= 0xAF and b4
        and (b3 - 0xAC) * 64 + (b4 - 0x80) <= 0x3B then
      -- A sextant (U+1FB00 to U+1FB3B): the font has none either.
      local n = (b3 - 0xAC) * 64 + (b4 - 0x80)
      local bits = n + 1
      if bits >= 21 then bits = bits + 1 end
      if bits >= 42 then bits = bits + 1 end
      shown[i] = " "
      sextants[#sextants + 1] = { i - 1, bits }
    elseif b1 == 0xE2 and b2 and b2 >= 0xA0 and b2 <= 0xA3 then
      local bits = (b2 - 0xA0) * 64 + (b3 - 0x80)
      shown[i] = " "
      if bits ~= 0 then dots[#dots + 1] = { i - 1, bits } end
    else
      shown[i] = ch
    end
  end
  local text = table.concat(shown)
  if (#dots == 0 and #sextants == 0) or text:find("[^ ]") or background ~= "" then
    ops[#ops + 1] = { "m", x, y, w, h, text, colour, background, attrs }
  end
  -- A sextant is up to six rectangles, a half cell wide and a third tall.
  for _, sx in ipairs(sextants) do
    for bit = 0, 5 do
      if band(sx[2], 2 ^ bit) ~= 0 then
        ops[#ops + 1] = { "r", x + (sx[1] + (bit % 2) / 2) * cell, y + math.floor(bit / 2) * h / 3, cell / 2, h / 3, colour, "", 1, 0 }
      end
    end
  end
  local dw, dh = math.max(1, cell * 0.24), math.max(1, h * 0.13)
  for _, dot in ipairs(dots) do
    for bit = 0, 7 do
      if band(dot[2], 2 ^ bit) ~= 0 then
        local cx = x + (dot[1] + (DOT_COLUMN[bit] + 0.5) / 2) * cell
        local cy = y + (DOT_ROW[bit] + 0.5) * h / 4
        ops[#ops + 1] = { "r", cx - dw / 2, cy - dh / 2, dw, dh, colour, "", 1, 0 }
      end
    end
  end
end

--- A run of text in the window's monospace font with its top left corner
--- at `x, y`, one character to a cell of `paw.canvas.cell`, `cells` of them
--- wide (the text's length by default). `style`: `color`, `background`,
--- `bold`, `italic`, `underline`, `strike`. Box-drawing and block
--- characters join from one cell to the next. Cut at the painter's edges by
--- whole cells.
function Painter:mono(x, y, text, style, cells)
  style = style or {}
  text = tostring(text)
  local cw, ch = M.cell.w, M.cell.h
  local x0, y0 = self:origin_x() + x, self:origin_y() + y
  if y0 < self.y - 0.5 or y0 + ch > self.y + self.height + 0.5 then return end
  local chars = {}
  for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = c end
  cells = cells or #chars
  -- Whole cells that fall outside are left out.
  local skip = math.max(0, math.ceil((self.x - x0) / cw - 1e-6))
  local room = math.floor((self.x + self.width - x0) / cw + 1e-6)
  local last = math.min(cells, room)
  if last <= skip then return end
  local attrs = (style.bold and 1 or 0) + (style.italic and 4 or 0) + (style.underline and 8 or 0) + (style.strike and 32 or 0)
  add_run(self.ops, x0 + skip * cw, y0, (last - skip) * cw, ch, { unpack(chars, skip + 1, math.min(#chars, last)) },
    style.color or c.text, style.background or "", attrs)
end

--- A glyph of a music font (SMuFL) with its origin at `x, y`: `size` is
--- the font's em in pixels (four staff spaces), `codepoint` the glyph's,
--- `colour` as for the rest, `font` the font's name (Leland when nil). Left
--- out when it is wholly outside the painter, by its em.
function Painter:glyph(x, y, size, codepoint, colour, font)
  local x0, y0 = self:origin_x() + x, self:origin_y() + y
  if x0 + size < self.x or x0 - size > self.x + self.width or y0 + size < self.y or y0 - size > self.y + self.height then return end
  self.ops[#self.ops + 1] = { "g", x0, y0, size, codepoint, colour or c.text, font or "Leland" }
end

--- Where a frontend that cuts the drawing into images may cut it: a
--- barline at `x`, across the band `y0` to `y1` (a system). Draws nothing.
function Painter:cut(x, y0, y1)
  local ox, oy = self:origin_x(), self:origin_y()
  self.ops[#self.ops + 1] = { "cut", ox + x, oy + y0, oy + y1 }
end

--- What follows, up to the next layer, is the layer `name` (the page's
--- "ink", or what moves over it: "selection", "caret", "ghost",
--- "diagnostic", "playhead"), so a frontend can keep the page and draw the
--- rest over it. Draws nothing.
function Painter:layer(name)
  self.ops[#self.ops + 1] = { "layer", name }
end

--- Whether a point of the painter's own coordinates is inside it.
function Painter:contains(x, y)
  return x >= 0 and y >= 0 and x < self.width and y < self.height
end

M.Painter = Painter

--- Show a view that paints in a graphical frontend and give it the
--- keyboard: docked, as the terminal shows it, when it has a place in the
--- layout (`paw.ui.dock`, or a window showing it); else, or with `window =
--- true`, in a window of its own. A view already in a window of its own
--- stays there. `opts`: `title`, `width`, `height` (what a window starts
--- at), `window`.
function M.open(name, opts)
  local view = paw.ui.views[name]
  if not (view and view.paint) then error("no view `" .. tostring(name) .. "` that paints", 2) end
  opts = opts or {}
  M.titles[name] = opts.title or M.titles[name]
  local L = paw.layout
  if not opts.window and not M.open_views[name] and (L.homes[name] or L.find(paw.ui.layout, name)) then
    paw.ui.focus(name)
    return
  end
  -- Taking the keyboard may have shown its place in the layout too.
  local back = M.open_views[name] and M.open_views[name].back
  back = M.leave(name) or back
  M.open_views[name] = { title = opts.title or view.title or name, width = opts.width or 900, height = opts.height or 520, back = back }
  if paw.ui.focused ~= name and not paw.ui.float then
    paw.ui.focused = name
    paw.emit("view.focused", { view = name })
  end
  api.ui_redraw()
end

--- Whether a graphical frontend shows a view: in a window of its own, or
--- docked where the seat's screen is a frontend's main area (one that has
--- said its size to `paw.panes`, or the instance's own with no terminal).
function M.shown(name)
  if M.open_views[name] then return true end
  return paw.ui.visible(name) and (paw.panes.cells() ~= nil or not api.ui_attached())
end

--- A view about to show in a window of its own leaves the layout, so as
--- not to show twice: its windows in the tabs close, keeping their place.
--- Returns the window that had the keyboard, to give it back to. A view a
--- frontend draws itself (the arrange view, the mixer...) stays where it is
--- as well: the window of its own is a second look at it.
function M.leave(name)
  local L = paw.layout
  local here, t = L.current(), L.tab()
  if paw.panes.native[name] then return here and here.id end
  -- Where the view had the keyboard, the window before it gets it back.
  local before = here and here.view == name and t.prev and L.find_id(t.layout, t.prev)
  L.conceal(name)
  -- A type with a buffer for each target: the windows of the tab showing
  -- the buffer the window of its own shows close, as a view's do.
  local def = L.types[name]
  local loose = def and def.window and def.window()
  if loose and loose.buf then
    for _, win in ipairs(L.windows(t.layout)) do
      if win.view == name and win.buf == loose.buf and win ~= loose then L.close(win) end
    end
  end
  for _, win in ipairs({ here, before, L.current() }) do
    if win and win.view ~= name and not win.hidden then return win.id end
  end
end

--- Give the keyboard back to the main window from a view in a window of
--- its own: to the window that had it before the view went there, else the
--- arrange view.
function M.back(name)
  local window = M.open_views[name]
  local L = paw.layout
  local win = window and window.back and L.find_id(paw.ui.layout, window.back)
  if win and not win.hidden then return L.enter(win) end
  paw.ui.focus("arrange")
end

--- Give a view in a window the keyboard, as a click in it does.
local function focus(name)
  if paw.ui.focused ~= name and not paw.ui.float then
    if paw.keymap.mode == "x" then paw.keymap.set_mode("n") end
    paw.ui.focused = name
    paw.emit("view.focused", { view = name })
  end
end

M.focus = focus

--- Show any view in a window of a graphical frontend (the focused one when
--- `name` is nil), and give it the keyboard. A view that paints is painted
--- (`M.open`); any other is drawn as the terminal draws it, in cells of the
--- window's monospace font, at whatever size the window has, with a line
--- under it for prompts, messages and its keys. A view floating over the
--- terminal's views moves into the window. `opts`: `title`, `width`,
--- `height` (in pixels).
---   paw.canvas.open_view("undotree")
function M.open_view(name, opts)
  name = name or paw.ui.focused
  local view = paw.ui.views[name]
  if not view then error("no view `" .. tostring(name) .. "`", 2) end
  if view.paint then return M.open(name, paw.util.merge(opts or {}, { window = true })) end
  opts = opts or {}
  local float = paw.ui.float and paw.ui.float.name == name and paw.ui.float
  if float then paw.ui.close() end
  local back = M.open_views[name] and M.open_views[name].back or M.leave(name)
  M.open_views[name] = {
    title = opts.title or (float and float.title) or view.title or name, cells = true, back = back,
    -- The float's size in cells, or a size that suits most views.
    width = opts.width or math.floor((float and float.width or 100) * M.cell.w + 0.5),
    height = opts.height or math.floor(((float and float.height or 32) + 1) * M.cell.h + 0.5),
  }
  if not float and view.on_show then view:on_show() end
  focus(name)
  api.ui_redraw()
end

-- Views not offered: parts of the screen, views the graphical frontend
-- shows in its own way, and pages that are opened with something to show.
-- `:view.window` still opens any of them.
local not_windows = {
  status = true, cmdline = true, arrange = true, mixer = true, pianoroll = true, devices = true,
  help = true, pager = true, pick = true,
}

--- The views a frontend can offer to open in a window: those that take the
--- keyboard, `{ name, title }` each, by title. A view keeps itself off the
--- list with `window = false`. A view with a painted twin (`painted = "name"`
--- of a view that has `paint`) is offered as that one.
function M.openable()
  local out = {}
  for name, view in pairs(paw.ui.views) do
    if view.focusable ~= false and view.window ~= false and not not_windows[name] then
      local twin = view.painted and paw.ui.views[view.painted]
      out[#out + 1] = { name = twin and view.painted or name, title = view.title or name }
    end
  end
  table.sort(out, function(a, b) return a.title:lower() < b.title:lower() end)
  return out
end

--- Close a view's window of its own; the keyboard goes back to the main
--- window, where it was before. A view docked in the layout instead
--- closes its window there, as `:close` would.
function M.close(name)
  if not M.open_views[name] then
    local win = paw.layout.find(paw.ui.layout, name)
    if win and not win.hidden then paw.layout.close(win) end
    return
  end
  if paw.ui.focused == name and not paw.ui.float then M.back(name) end
  M.open_views[name] = nil
  local view = paw.ui.views[name]
  if view and view.on_close then view:on_close() end
  api.ui_redraw()
end

--- Put a view in a window of its own back into the layout, with the
--- keyboard: where it was before it popped out, else where it docks, else
--- in a window split from the current one. What closing its window of its
--- own does; `Ctrl-w d` in it does the same.
function M.dock(name)
  name = name or paw.ui.focused
  if not M.open_views[name] then return end
  M.open_views[name] = nil
  local L = paw.layout
  if paw.panes.native[name] or L.reveal(name) then return paw.ui.focus(name) end
  -- A type with a buffer for each target shows the buffer it showed.
  local def = L.types[name]
  local loose = def and def.window and def.window()
  local win = L.split({ view = name, buf = loose and loose.buf or nil })
  if not win then L.show_in(L.current(), name, loose and loose.buf or nil) end
  focus(name)
  api.ui_redraw()
end

--- The windows that are open, for a frontend: `{ name, title, width, height, cells }`
--- each, `cells` for a view drawn as the terminal draws it.
function M.windows()
  local out = {}
  for name, w in pairs(M.open_views) do
    local view = paw.ui.views[name]
    if view and (view.paint or w.cells) then
      out[#out + 1] = { name = name, title = w.title, width = w.width, height = w.height, cells = w.cells or false }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- A view that draws cells, at a size in pixels: its snapshot
--- (`paw.api.ui_view_snapshot`) as runs of text, a run of one style each.
--- Drawn again only when a redraw has been asked for since, once a second
--- for what changes on its own (times), and on every call while playing;
--- `{ same = true }` when what it would draw is what it drew last.
--- `window` keeps what was drawn. With `win`, a window of the layout (a
--- pane of a frontend's main area), that window is drawn, and nothing
--- under it: the frontend's own status line shows prompts and messages;
--- without, the view in a window of its own, with a line under it for
--- them and the view's keys, unless the frontend draws a status line there
--- itself (`opts.status`).
function M.paint_cells(name, window, width, height, opts, win)
  local cell = M.cell
  window.cell = cell
  -- Nothing under the view in a pane, or in a window that has a status line
  -- of its own (`opts.status`).
  local bare = win ~= nil or opts.status == true
  window.bare = bare
  local cols, rows = math.max(1, math.floor(width / cell.w)), math.max(bare and 1 or 2, math.floor(height / cell.h))
  local redraws, now = api.ui_redraws(), api.now()
  if not opts.fresh and window.drawn == redraws and window.cols == cols and window.rows == rows
    and now - window.at < (api.transport_get().playing and 30 or 1000) then
    return { title = window.title, same = true }
  end
  local focused = paw.ui.focused == name
  paw.ui.view_win = win
  -- The strips the view keeps under its cells (`buf:strip`), drawn here
  -- between the cells' backgrounds and their text.
  paw.ui.pictures = {}
  local ok, snap = pcall(api.ui_view_snapshot, name, cols, bare and rows or rows - 1)
  local pictures = paw.ui.pictures
  paw.ui.view_win, paw.ui.pictures = nil, nil
  if not ok then error(snap, 0) end
  local ops = { { "r", 0, 0, width, height, snap.bg, "", 1, 0 } }
  local function add(lines, top, layer)
    for r, row in ipairs(lines) do
      local y = (top + r - 1) * cell.h
      for _, run in ipairs(row) do
        local back = run.bg == snap.bg and "" or run.bg
        if layer == "back" then
          if back ~= "" then ops[#ops + 1] = { "r", run.x * cell.w, y, run.w * cell.w, cell.h, back, "", 1, 0 } end
        -- Spaces on the window's own background need nothing drawn.
        elseif run.text:find("[^ ]") or (back ~= "" and layer ~= "text") or band(run.attrs, 8 + 32) ~= 0 then
          local chars = {}
          for ch in run.text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
          add_run(ops, run.x * cell.w, y, run.w * cell.w, cell.h, chars, run.fg, layer == "text" and "" or back, run.attrs)
        end
      end
    end
  end
  if #pictures == 0 then
    add(snap.rows, 0)
  else
    add(snap.rows, 0, "back")
    for _, p in ipairs(pictures) do
      local px = { w = p.whole_w * cell.w, h = p.whole_h * cell.h, cell = { w = cell.w, h = cell.h },
        view = { x = p.left * cell.w, y = p.top * cell.h, w = p.w * cell.w, h = p.h * cell.h } }
      local g = painter(ops, p.x * cell.w, p.y * cell.h, p.w * cell.w, p.h * cell.h)
      g.ox, g.oy = (p.x - p.left) * cell.w, (p.y - p.top) * cell.h
      local drawn, err = xpcall(p.draw, debug.traceback, g, px)
      if not drawn then api.log("a strip failed to draw: " .. tostring(err)) end
    end
    add(snap.rows, 0, "text")
  end
  local cursor = snap.cursor and { snap.cursor.x, snap.cursor.y }
  if focused and not bare then
    -- The line under the view: a prompt, a message, or the view's keys.
    local line = api.ui_view_snapshot("cmdline", cols, 1)
    add(line.rows, rows - 1)
    if line.cursor then cursor = { line.cursor.x, rows - 1 } end
  end
  if cursor then
    ops[#ops + 1] = { "r", cursor[1] * cell.w, cursor[2] * cell.h, 2, cell.h, snap.fg, "", 1, 0 }
  end
  local parts = {}
  for i, op in ipairs(ops) do parts[i] = table.concat(op, "\1") end
  local key = table.concat(parts, "\2")
  local same = key == window.key and not opts.fresh
  window.key, window.drawn, window.cols, window.rows, window.at = key, redraws, cols, rows, now
  if same then return { title = window.title, same = true } end
  return { title = window.title, ops = ops }
end

--- A music font's glyph as commands and numbers in staff spaces from its
--- origin, y down, from the fonts built into the kernel, or nil.
local outlines = {}
function M.glyph_outline(font, codepoint)
  if type(codepoint) ~= "number" then return nil end
  local key = (font or "") .. ":" .. codepoint
  if outlines[key] == nil then outlines[key] = api.smufl_outline(font, codepoint) or false end
  return outlines[key] or nil
end

--- A glyph op as a path, from its outline (`M.glyph_outline`), or nil
--- when there is none.
local function glyph_path(op)
  local outline = M.glyph_outline(op[7], op[5])
  if not outline then return nil end
  local x, y, scale = op[2], op[3], op[4] / 4
  local out, axis = {}, 0
  for i, v in ipairs(outline) do
    if type(v) == "string" then
      out[i] = v
      axis = 0
    else
      out[i] = string.format("%.1f", (axis == 0 and x or y) + v * scale)
      axis = 1 - axis
    end
  end
  return { "p", table.concat(out, " "), "", 1, op[6] }
end

--- What a frontend that does not draw glyphs is given: each glyph as a
--- path, and no markers.
local function without_glyphs(ops)
  local out = {}
  for _, op in ipairs(ops) do
    local kind = op[1]
    if kind == "g" then
      out[#out + 1] = glyph_path(op)
    elseif kind ~= "cut" and kind ~= "layer" then
      out[#out + 1] = op
    end
  end
  return out
end

--- The status line and the command line, as rows of runs at `y`: under a
--- view that paints in a window of its own, which the main window's would
--- otherwise be out of sight of (the mode, a prompt typed there, messages).
local function bars(ops, width, y)
  local cell = M.cell
  local cols = math.max(1, math.floor(width / cell.w))
  for i, name in ipairs({ "status", "cmdline" }) do
    local snap = api.ui_view_snapshot(name, cols, 1)
    local top = y + (i - 1) * cell.h
    ops[#ops + 1] = { "r", 0, top, width, cell.h, snap.bg, "", 1, 0 }
    for _, run in ipairs(snap.rows[1] or {}) do
      local chars = {}
      for ch in run.text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
      add_run(ops, run.x * cell.w, top, run.w * cell.w, cell.h, chars, run.fg, run.bg == snap.bg and "" or run.bg, run.attrs)
    end
    if snap.cursor then ops[#ops + 1] = { "r", snap.cursor.x * cell.w, top, 2, cell.h, snap.fg, "", 1, 0 } end
  end
end

--- Paint a view at a size. Returns the drawing as a list of operations:
---   { "r", x, y, w, h, fill, stroke, stroke width, radius }
---   { "t", x, y, text, colour, size, bold (0 or 1), align, width }
---   { "p", path commands, stroke, stroke width, fill }
---   { "m", x, y, w, h, text, colour, background, attributes }
---   { "g", x, y, size, codepoint, colour, font }   a music font's glyph
---   { "cut", x, y0, y1 }                           where a slice may end
---   { "layer", name }                              what follows is that layer
--- (attributes add up 1 bold, 4 italic, 8 underline, 32 strike), and the
--- window's title, which a view may change as it goes. `opts`: `cell`, the
--- size `{ w, h }` of a cell of the window's monospace font (or of the
--- terminal's, for a surface), `fresh` when the window has nothing yet,
--- `glyphs` when the frontend draws glyph ops itself (else they come as
--- paths, and the markers are left out), `surface` when the drawing goes
--- into a terminal's cells (the view leaves out what the terminal's own
--- bars show, and its background), `colors` `{ fg, bg }`, the terminal's,
--- and `bars` from a frontend that shows a view in a window of its own,
--- out of sight of its main window's bottom: the status line and the
--- command line are drawn under the view there. The view's `paint` is
--- given these in its context, as `cell`, `surface`, `fg` and `bg`. A view
--- that draws cells answers `{ same = true }` when nothing would change.
function M.paint(name, width, height, opts)
  local view = paw.ui.views[name]
  local window = M.open_views[name]
  opts = opts or {}
  -- A terminal's cell is the surface's own: the window's stays as it measured it.
  if opts.cell and (opts.cell.w or 0) > 0 and not opts.surface then M.cell = { w = opts.cell.w, h = opts.cell.h } end
  if view and not view.paint then
    if not (window and window.cells) then return nil end
    return M.paint_cells(name, window, width, height, opts)
  end
  if not view then return nil end
  local ops = {}
  -- In a window of its own the view has the two lines of the screen's
  -- bottom under it, when the frontend asks; a pane's frontend has them.
  local under = window and opts.bars and not opts.surface and 2 * M.cell.h or 0
  local full = height
  height = math.max(1, height - under)
  local g = painter(ops, 0, 0, width, height)
  local colors = opts.colors or {}
  local ok, err = xpcall(view.paint, debug.traceback, view, g, {
    width = width, height = height, focused = paw.ui.focused == name,
    cell = opts.surface and opts.cell or M.cell, surface = opts.surface or false, fg = colors.fg, bg = colors.bg,
  })
  if not ok then
    -- Show the failure where the view would have been.
    ops = {}
    g = painter(ops, 0, 0, width, height)
    g:rect(0, 0, width, height, { fill = c.surface })
    local row = 0
    for line in tostring(err):gmatch("[^\n]+") do
      g:text(12, 12 + row * 16, line:gsub("\t", "  "), { color = c.error })
      row = row + 1
    end
  end
  if under > 0 then bars(ops, width, full - under) end
  if not opts.glyphs then ops = without_glyphs(ops) end
  return { title = window and window.title or name, ops = ops }
end

--- The operations a function draws on a painter of `px.w` by `px.h`
--- pixels: what a strip shows (`buf:strip`). `draw(g, px)` is given the
--- painter and `px` itself; a failure is shown where it would have drawn.
---   local ops = paw.canvas.draw(function(g, px) g:rect(0, 0, px.w, 2, { fill = "#ffffff" }) end, { w = 80, h = 40 })
function M.draw(draw, px)
  local ops = {}
  local ok, err = xpcall(draw, debug.traceback, painter(ops, 0, 0, px.w, px.h), px)
  if not ok then
    ops = {}
    local g = painter(ops, 0, 0, px.w, px.h)
    local row = 0
    for line in tostring(err):gmatch("[^\n]+") do
      g:text(4 + (px.view and px.view.x or 0), 2 + (px.view and px.view.y or 0) + row * 14, line:gsub("\t", "  "), { color = c.error })
      row = row + 1
    end
  end
  return ops
end

--- A pointer event in pixels as the terminal gives it to a view's
--- `on_mouse`: in cells, `kind` down, up, drag or scroll_up and so on,
--- `button`, and `mods` ("C", "A", "S"). Nil for what the terminal has no
--- word for (the second click of a double one comes as down and up).
function M.cell_event(window, event, bare)
  local cell = window.cell or M.cell
  local kind = event.kind
  if kind == "move" then
    kind = "drag"
  elseif kind == "wheel" then
    local dx, dy = event.dx or 0, event.dy or 0
    if event.shift and dx == 0 then dx, dy = dy, 0 end
    if math.abs(dx) > math.abs(dy) then
      kind = dx > 0 and "scroll_left" or "scroll_right"
    else
      kind = dy > 0 and "scroll_up" or "scroll_down"
    end
  elseif kind ~= "down" and kind ~= "up" then
    return nil
  end
  -- A frontend says which button only when one goes down or up.
  local button = event.button or "left"
  if kind == "down" then window.button = button end
  if kind == "drag" then button = window.button or "left" end
  if kind:match("^scroll") then button = "" end
  local x, y = math.floor((event.x or 0) / cell.w), math.floor((event.y or 0) / cell.h)
  -- The line under the view is not the view's.
  if not (bare or window.bare) and window.rows and y >= window.rows - 1 and kind ~= "up" and kind ~= "drag" then return nil end
  local mods = (event.ctrl and "C" or "") .. (event.alt and "A" or "") .. (event.shift and "S" or "")
  return { kind = kind, x = x, y = y, button = button, mods = mods }
end

--- Pass a pointer event from a frontend to a view, which then has the
--- keyboard: to its `pointer` in pixels, or for a view in cells to its
--- `on_mouse` as the terminal would.
function M.pointer(name, event)
  local view = paw.ui.views[name]
  if not view then return end
  if event.kind == "down" then focus(name) end
  local window = M.open_views[name]
  if not view.paint and window and window.cells then
    local e = M.cell_event(window, event)
    if e and view.on_mouse then paw.limit.named("the mouse", paw.mouse.to_view, view, e) end
  elseif view.pointer then
    view:pointer(event)
  end
  api.ui_redraw()
end

--- Keys typed in a view's window: they go to the key mappings with that
--- view focused (or to a prompt that is open), as typed in the terminal.
--- A view may give keys a meaning of its own in its window, as other programs
--- do (`view.window_keys`, such as Ctrl-A for choosing every note), where
--- the terminal keeps the one rule of every view.
function M.key(name, keys)
  local view = paw.ui.views[name]
  if view then focus(name) end
  paw.keymap.feed(view and view.window_keys and view.window_keys[keys] or keys)
  api.ui_redraw()
end

return M
