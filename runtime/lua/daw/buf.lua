-- A drawing buffer: a rectangle of the screen that a view draws into.
--
--   buf:text(x, y, text, style)        draw text, returns the columns it takes
--   buf:fill(x, y, w, h, char, style)  restyle an area; `char` overwrites it too
--   buf:sub(x, y, w, h)                a buffer for part of this one
--   buf.width, buf.height
--
-- Coordinates count cells from 0 at the buffer's top-left corner, and
-- anything drawn outside the buffer is clipped. A style is the name of a
-- highlight group, a table such as `{ fg = "#ff9e64", bold = true }`, or nil
-- to keep the colours already there.
local api = daw.api
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

function Buf:text(x, y, text, style)
  return grid_text(self.x + x, self.y + y, text, style, self.cx, self.cy, self.cw, self.ch)
end

function Buf:fill(x, y, w, h, char, style)
  grid_fill(self.x + x, self.y + y, w, h, char, style, self.cx, self.cy, self.cw, self.ch)
end

function Buf:sub(x, y, w, h)
  x, y, w, h = floor(self.x + x), floor(self.y + y), max(0, floor(w)), max(0, floor(h))
  local cx, cy = max(x, self.cx), max(y, self.cy)
  local right, bottom = min(x + w, self.cx + self.cw), min(y + h, self.cy + self.ch)
  return new(x, y, w, h, cx, cy, max(0, right - cx), max(0, bottom - cy))
end

return Buf
