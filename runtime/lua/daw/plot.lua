-- Plots of time in pixels: what a view draws in a strip (`buf:strip`) to
-- show a curve, so that every curve the program shows looks alike and is
-- sent to the terminal alike. A drawing is made with the painter of
-- `daw.canvas` (`g`), at the strip's size in pixels (`px`, as `buf:strip`
-- gives it), and is cut at the barlines (`g:cut`), snapped to whole
-- cells, so that an edit sends again only the bars it touched.
--
--   plot:strip(0, 0, plot.width, plot.height, { key = "lane:" .. win.id, under = true,
--     draw = function(g, px)
--       daw.plot.curve(g, px, { points = points, from = left, pixels_per_beat = zoom * px.cell.w,
--         lo = 0, hi = 1, color = daw.draw.track_colour(track) })
--     end })
--
-- The strip draws no background of its own unless asked (`background`):
-- under the text (`under`), the cells' own backgrounds show through, the
-- selection among them.
local M = {}

local floor, max, min = math.floor, math.max, math.min

local function palette() return require("daw.theme").palette end

--- A colour `#rrggbb` at `alpha` (0 to 1), as `#rrggbbaa`.
function M.alpha(colour, alpha)
  return colour:sub(1, 7) .. string.format("%02x", max(0, min(255, floor(alpha * 255 + 0.5))))
end

--- The bar and beat lines of a plot `w` pixels wide from the beat `from`
--- at `ppb` pixels a beat: `{ beat, x, bar }` each (`bar` the bar's number
--- for a bar), `x` in pixels from the left, and where the drawing may be
--- cut for each bar, `cut`, the nearest edge of a cell of `cell_w` pixels.
function M.lines(w, from, ppb, cell_w)
  local out = {}
  if ppb <= 0 then return out end
  for _, line in ipairs(daw.draw.bar_lines(from, w / ppb + 1)) do
    local x = (line.beat - from) * ppb
    if x >= 0 and x < w then
      out[#out + 1] = {
        beat = line.beat, x = x, bar = line.bar,
        cut = line.bar and cell_w and floor(x / cell_w + 0.5) * cell_w or nil,
      }
    end
  end
  return out
end

--- Draw a curve over time in a strip: its grid, the area under it, the
--- line, and its points. `px` is the strip's size as `buf:strip` gives it
--- (`w`, `h`, `cell`). `opts`:
---   points            `{ beat, value, shape, tension }` each, in order, as `daw.curves` has them
---   from              the beat at the left edge
---   pixels_per_beat   the zoom
---   frac              `frac(value)` from 0 (bottom) to 1 (top); else `lo` and `hi`
---   flat              the value shown when there are no points (else nothing is)
---   color             the line's colour, `#rrggbb` (the theme's `dim` by default):
---                     a track's own is `daw.draw.track_colour(track)`
---   fill              how opaque the area under the line is, 0 to 1 (0.16); false for none
---   width             the line's width in pixels (1.5)
---   top, bottom       pixels kept clear above 1 and below 0 (2 each)
---   grid              bars (and beats, when `beats`) as lines, true by default
---   beats             beat lines too (when beats are at least two cells apart, by default)
---   guides            faint lines at a quarter, half and three quarters (true)
---   markers           a small mark at each point (true)
---   background        a colour to fill the strip with first (none: the cells show)
--- Returns `x(beat)` and `y(value)`, where in the strip a beat and a value are.
function M.curve(g, px, opts)
  local P = palette()
  local W, H = px.w, px.h
  local cw = px.cell and px.cell.w or 8
  local from, ppb = opts.from or 0, opts.pixels_per_beat or cw
  local lo, hi = opts.lo or 0, opts.hi or 1
  local frac = opts.frac or function(v) return (v - lo) / ((hi - lo) ~= 0 and (hi - lo) or 1) end
  local top, bottom = opts.top or 2, opts.bottom or 2
  local function X(beat) return (beat - from) * ppb end
  local function Y(v) return top + (1 - max(0, min(1, frac(v)))) * (H - top - bottom) end
  if opts.background then g:rect(0, 0, W, H, { fill = opts.background }) end

  -- The grid, and where the drawing is cut: at each bar, on a cell's edge.
  local lines = M.lines(W, from, ppb, cw)
  local edges = { 0 }
  for _, line in ipairs(lines) do
    if line.cut and line.cut > edges[#edges] and line.cut < W then
      edges[#edges + 1] = line.cut
      g:cut(line.cut, 0, H)
    end
  end
  edges[#edges + 1] = W
  if opts.grid ~= false then
    local beats = opts.beats
    if beats == nil then beats = ppb >= 2 * cw end
    for _, line in ipairs(lines) do
      if line.bar or beats then
        g:rect(floor(line.x), 0, 1, H, { fill = line.bar and P.line_hi or P.line_beat })
      end
    end
  end
  if opts.guides ~= false then
    for i = 1, 3 do
      g:rect(0, floor(top + i * (H - top - bottom) / 4), W, 1, { fill = P.line })
    end
  end

  local points = opts.points or {}
  if #points == 0 and opts.flat == nil then return X, Y end
  local color = opts.color or P.dim
  local value_at = daw.curves.value_at
  local function value(beat) return value_at(points, beat) or opts.flat end

  -- The line and the area under it, one stretch between two cuts at a
  -- time, sampled once a pixel: a stretch changes only with its bar.
  local fill = opts.fill == nil and 0.16 or opts.fill
  for i = 1, #edges - 1 do
    local a, b = edges[i], edges[i + 1]
    local line = {}
    for x = a, b do
      line[#line + 1] = x
      line[#line + 1] = Y(value(from + x / ppb))
    end
    if fill and fill > 0 then
      local area = { a, H }
      for k = 1, #line do area[#area + 1] = line[k] end
      area[#area + 1] = b
      area[#area + 1] = H
      g:poly(area, { fill = M.alpha(color, fill) })
    end
    g:poly(line, { color = color, width = opts.width or 1.5 })
  end

  if opts.markers ~= false then
    for _, q in ipairs(points) do
      local x, y = X(q.beat), Y(q.value)
      if x >= -4 and x <= W + 4 then
        local shape = q.shape or "linear"
        g:rect(x - 2.5, y - 2.5, 5, 5, {
          fill = P.bright, stroke = color, width = 1, radius = shape == "smooth" and 2.5 or shape == "hold" and 0 or 1,
        })
      end
    end
  end
  return X, Y
end

return M
