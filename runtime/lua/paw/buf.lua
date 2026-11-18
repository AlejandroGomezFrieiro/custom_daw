-- A drawing buffer: a rectangle of the screen that a view draws into.
--
--   buf:text(x, y, text, style)        draw text, returns the columns it takes
--   buf:fill(x, y, w, h, char, style)  restyle an area; `char` overwrites it too
--   buf:sub(x, y, w, h)                a buffer for part of this one
--   buf:surface(x, y, w, h, name)      keep an area for a view's pixels
--   buf:strip(x, y, w, h, opts)        keep an area for pixels a function draws
--   buf.width, buf.height
--
-- Coordinates count cells from 0 at the buffer's top-left corner, and
-- anything drawn outside the buffer is clipped. A style is the name of a
-- highlight group, a table such as `{ fg = "#ff9e64", bold = true }`, or nil
-- to keep the colours already there.
local api = paw.api
local grid_text, grid_fill = api.grid_text, api.grid_fill
local floor, max, min = math.floor, math.max, math.min

local Buf = {}
Buf.__index = Buf

local function new(x, y, width, height, cx, cy, cw, ch)
  return setmetatable({ x = x, y = y, width = width, height = height, cx = cx, cy = cy, cw = cw, ch = ch }, Buf)
end

--- The buffer covering a whole screen of the given size.
function Buf.root(width, height)
  return new(0, 0, width, height, 0, 0, width, height)
end

--- Write `text` at column `x`, row `y` of this buffer in highlight group
--- `style`, clipped to it; returns the columns written.
function Buf:text(x, y, text, style)
  return grid_text(self.x + x, self.y + y, text, style, self.cx, self.cy, self.cw, self.ch)
end

--- Fill a `w` by `h` area at `x`, `y` with `char` in `style`, clipped.
function Buf:fill(x, y, w, h, char, style)
  grid_fill(self.x + x, self.y + y, w, h, char, style, self.cx, self.cy, self.cw, self.ch)
end

--- Keep an area for the pixels of a view that paints (`name`, the view
--- being drawn by default), where the terminal shows images: its `paint`
--- draws there at the terminal's cell size, after the screen is drawn.
--- The cells are left blank. False where the terminal shows cells only,
--- for the view to draw them instead:
---   if buf:surface(0, 1, buf.width, buf.height - 1) then return end
function Buf:surface(x, y, w, h, name)
  return paw.ui.surface(self, x, y, w, h, name)
end

--- Keep an area for pixels drawn by `opts.draw(g, px)`, where the terminal
--- shows images: `g` a painter of `paw.canvas`, `px` `{ w, h, cell = { w,
--- h }, fg, bg, view }`, the strip's size and the terminal's cell in pixels and
--- its colours, and for a strip partly off its window the part that shows
--- (`view`: x, y, w, h). Called once the screen is drawn. `opts.key` names the
--- strip (images are kept by it: put the window's id in it for a view
--- that can be in two windows; the view and its window by default).
--- With `opts.under`, the cells the view draws there stay, above the
--- picture (its cursor, labels, the playhead); else they are left blank.
--- False where there are no pixels (`paw.opt.graphics` off, a terminal
--- without images, tmux, or one that cannot put text over an image under
--- it), for the view to draw cells there instead:
---   local pictured = plot:strip(0, 0, plot.width, plot.height, {
---     key = "curve:" .. win.id, under = true,
---     draw = function(g, px) paw.plot.curve(g, px, { ... }) end,
---   })
function Buf:strip(x, y, w, h, opts)
  return paw.ui.strip(self, x, y, w, h, opts)
end

--- A buffer for the area `x`, `y`, `w` by `h` of this one, clipped to it.
function Buf:sub(x, y, w, h)
  x, y, w, h = floor(self.x + x), floor(self.y + y), max(0, floor(w)), max(0, floor(h))
  local cx, cy = max(x, self.cx), max(y, self.cy)
  local right, bottom = min(x + w, self.cx + self.cw), min(y + h, self.cy + self.ch)
  return new(x, y, w, h, cx, cy, max(0, right - cx), max(0, bottom - cy))
end

return Buf
