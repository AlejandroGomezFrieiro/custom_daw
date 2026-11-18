-- A drawing buffer: a rectangle of the screen that a view draws into.
--
--   buf:text(x, y, text, style)        draw text, returns the columns it takes
--   buf:fill(x, y, w, h, char, style)  restyle an area; `char` overwrites it too
--   buf:sub(x, y, w, h)                a buffer for part of this one
--   buf:surface(x, y, w, h, name)      keep an area for a view's pixels
--   buf:strip(x, y, w, h, opts)        keep an area for pixels a function draws
--   buf:mark(role, x, y, w, h, props)  a role there: a fader, a button (paw/roles.lua)
--   buf:hit(x, y, w, h, action)        a region the pointer acts on
--   buf:plane(x, y, w, h, opts)        an area placing what is marked in it by a domain (beats, pitches)
--   buf:columns(widths, gap)           buffers side by side, a width each
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

--- The buffer that covers a whole screen of the given size.
function Buf.root(width, height)
  return new(0, 0, width, height, 0, 0, width, height)
end

--- Write `text` at column `x`, row `y` of this buffer in highlight group
--- `style`, clipped to the buffer. Returns the number of columns written.
function Buf:text(x, y, text, style)
  return grid_text(self.x + x, self.y + y, text, style, self.cx, self.cy, self.cw, self.ch)
end

--- Fill a `w` by `h` area at `x`, `y` with `char` in `style`, clipped.
function Buf:fill(x, y, w, h, char, style)
  grid_fill(self.x + x, self.y + y, w, h, char, style, self.cx, self.cy, self.cw, self.ch)
end

--- Keep an area for the pixels of a view that paints (`name`, by default
--- the view that paw draws), where the terminal shows images. Its `paint`
--- draws there at the cell size of the terminal, after paw draws the
--- screen. The cells stay blank. False where the terminal shows only cells.
--- Then the view draws them:
---   if buf:surface(0, 1, buf.width, buf.height - 1) then return end
function Buf:surface(x, y, w, h, name)
  return paw.ui.surface(self, x, y, w, h, name)
end

--- Keep an area for pixels that `opts.draw(g, px)` draws, where the
--- terminal shows images. `g` is a painter of `paw.canvas`. `px` is
--- `{ w, h, cell = { w, h }, fg, bg, view }`: the size of the strip, the
--- cell of the terminal in pixels, and its colors. For a strip that is
--- partly off its window, `view` is the part that shows (x, y, w, h). paw
--- calls it after it draws the screen. `opts.key` names the strip, and paw
--- keeps images by this name. For a view that can be in two windows, put
--- the id of the window in it. The default is the view and its window.
--- With `opts.under`, the cells that the view draws there stay above the
--- picture (its cursor, labels, the playhead). If not, they are blank.
--- False where there are no pixels (`paw.opt.graphics` off, a terminal
--- without images, tmux, or a terminal that cannot put text over an image).
--- Then the view draws cells there:
---   local pictured = plot:strip(0, 0, plot.width, plot.height, {
---     key = "curve:" .. win.id, under = true,
---     draw = function(g, px) paw.plot.curve(g, px, { ... }) end,
---   })
function Buf:strip(x, y, w, h, opts)
  return paw.ui.strip(self, x, y, w, h, opts)
end

--- Mark a role (paw/roles.lua) over an area. A terminal draws the cells of
--- the role there. A frontend that knows the role paints it as what it is.
--- `props.hit` makes it a hit region, and `props.bind` ties it to a live
--- value. Returns the buffer of the area.
---   buf:mark("fader", 4, 2, 3, 12, { at = 0.8, hit = { kind = "fader", track = id } })
function Buf:mark(role, x, y, w, h, props)
  return paw.roles.mark(self, role, x, y, w, h, props)
end

--- Make an area a hit region: a press, a move or the wheel there goes to
--- the view's gesture for `action.kind` (paw/roles.lua), in either frontend.
function Buf:hit(x, y, w, h, action)
  paw.roles.hit(self, x, y, w, h, action)
end

--- A plane over an area (paw/roles.lua, "Planes"). Each axis of the plane
--- has its own domain, `opts.x` and `opts.y` (`{ domain, from, per }`):
--- `per` is the cells for one unit of the domain, and `from` is the value at
--- the edge of the area. A terminal shows a mark on the cells it rounds to.
--- A window shows it at its exact position.
---   local roll = buf:plane(5, 2, 60, 20, { key = "roll", x = { domain = "beat", from = 0, per = 4 },
---     y = { domain = "pitch", from = 73, per = -1 }, hit = { kind = "grid" } })
---   roll:mark("note", 1.5, 60, 0.5, 1, { label = "C4" })
function Buf:plane(x, y, w, h, opts)
  return paw.roles.plane(self, x, y, w, h, opts)
end

--- Buffers side by side across this buffer, each with a width from the
--- left, with `gap` columns between them (0 by default). A width of "*"
--- takes the space that the others leave. paw does not make the buffers
--- that do not fit.
---   local name, body = buf:columns({ 12, "*" })
function Buf:columns(widths, gap)
  gap = gap or 0
  local fixed, flexible = 0, 0
  for _, w in ipairs(widths) do
    if w == "*" then flexible = flexible + 1 else fixed = fixed + w end
  end
  local rest = max(0, self.width - fixed - gap * (#widths - 1))
  local out, x = {}, 0
  for i, w in ipairs(widths) do
    if w == "*" then w = floor(rest / flexible) end
    if x >= self.width then break end
    out[i] = self:sub(x, 0, min(w, self.width - x), self.height)
    x = x + w + gap
  end
  return unpack(out, 1, #widths)
end

--- A buffer for the area `x`, `y`, `w` by `h` of this one, clipped to it.
function Buf:sub(x, y, w, h)
  x, y, w, h = floor(self.x + x), floor(self.y + y), max(0, floor(w)), max(0, floor(h))
  local cx, cy = max(x, self.cx), max(y, self.cy)
  local right, bottom = min(x + w, self.cx + self.cw), min(y + h, self.cy + self.ch)
  return new(x, y, w, h, cx, cy, max(0, right - cx), max(0, bottom - cy))
end

return Buf
