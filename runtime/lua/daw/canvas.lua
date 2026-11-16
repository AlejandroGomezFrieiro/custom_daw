-- Drawing for graphical frontends: what the cell grid is to a terminal.
--
-- A view that has a `paint` function can be shown by a graphical frontend
-- in a window of its own, at any size, in pixels:
--
--   daw.ui.view("scope", {
--     paint = function(self, g, ctx)          -- ctx: width, height, focused
--       local c = daw.canvas.palette
--       g:rect(0, 0, ctx.width, ctx.height, { fill = c.surface })
--       g:text(12, 10, "hello", { color = c.text, size = 14, bold = true })
--       g:line(0, 40, ctx.width, 40, { color = c.line_bar })
--       g:poly({ 0, 80, 40, 60, 80, 90 }, { color = c.select, width = 2 })
--     end,
--     pointer = function(self, e) end,        -- e: kind, x, y, button, ctrl, shift, alt, dx, dy
--   })
--   daw.canvas.open("scope", { title = "Scope", width = 640, height = 360 })
--
-- `e.kind` is "down", "up", "move" (while a button is held), "double" or
-- "wheel". Keys go to the view as they do in the terminal: through the key
-- mappings made for it, or its `on_key`.
--
-- `g:sub(x, y, w, h)` gives a painter for part of the area: what is drawn
-- through it is placed from its corner and cut off at its edges, which is
-- how a view scrolls. Colours are `#rrggbb` or `#rrggbbaa`.
--
-- `daw.canvas.palette` is the window's palette, by the names the window's
-- own drawing uses (`Theme` in crates/daw-gui/ui/widgets.slint), so that a
-- painted view looks like the rest of the window: neutral surfaces, colour
-- for state, and a track's hue only on what is the track's.
local api = daw.api
local M = { open_views = {} }

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

--- Whether a point of the painter's own coordinates is inside it.
function Painter:contains(x, y)
  return x >= 0 and y >= 0 and x < self.width and y < self.height
end

M.Painter = Painter

--- Show a view that paints in a window of a graphical frontend, and give it
--- the keyboard. `opts`: `title`, `width`, `height` (what the window starts at).
function M.open(name, opts)
  local view = daw.ui.views[name]
  if not (view and view.paint) then error("no view `" .. tostring(name) .. "` that paints", 2) end
  M.open_views[name] = { title = opts and opts.title or name, width = opts and opts.width or 900, height = opts and opts.height or 520 }
  if daw.ui.focused ~= name and not daw.ui.float then
    daw.ui.focused = name
    daw.emit("view.focused", { view = name })
  end
  api.ui_redraw()
end

function M.close(name)
  if not M.open_views[name] then return end
  M.open_views[name] = nil
  local view = daw.ui.views[name]
  if view and view.on_close then view:on_close() end
  if daw.ui.focused == name then daw.ui.focus("arrange") end
  api.ui_redraw()
end

--- The windows that are open, for a frontend: `{ name, title, width, height }` each.
function M.windows()
  local out = {}
  for name, w in pairs(M.open_views) do
    if daw.ui.views[name] and daw.ui.views[name].paint then
      out[#out + 1] = { name = name, title = w.title, width = w.width, height = w.height }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- Paint a view at a size. Returns the drawing as a list of operations:
---   { "r", x, y, w, h, fill, stroke, stroke width, radius }
---   { "t", x, y, text, colour, size, bold (0 or 1), align, width }
---   { "p", path commands, stroke, stroke width, fill }
--- and the window's title, which a view may change as it goes.
function M.paint(name, width, height)
  local view = daw.ui.views[name]
  local window = M.open_views[name]
  if not (view and view.paint) then return nil end
  local ops = {}
  local g = painter(ops, 0, 0, width, height)
  local ok, err = xpcall(view.paint, debug.traceback, view, g, { width = width, height = height, focused = daw.ui.focused == name })
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
  return { title = window and window.title or name, ops = ops }
end

--- Pass a pointer event from a frontend to a view, which then has the keyboard.
function M.pointer(name, event)
  local view = daw.ui.views[name]
  if not view then return end
  if event.kind == "down" and daw.ui.focused ~= name and not daw.ui.float then
    if daw.keymap.mode == "x" then daw.keymap.set_mode("n") end
    daw.ui.focused = name
    daw.emit("view.focused", { view = name })
  end
  if view.pointer then view:pointer(event) end
  api.ui_redraw()
end

return M
