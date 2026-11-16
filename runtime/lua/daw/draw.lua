-- What views are drawn from: shades of a track's colour, the characters,
-- meters, sliders, small piano rolls and curves. Views and extensions share
-- these so that everything on screen looks like part of the same program.
--
--   local hue = daw.draw.track_hue(track, index)   -- highlight groups in the track's colour
--   local g = daw.draw.g                           -- the characters, ASCII under `daw.opt.ascii`
--   buf:text(0, 0, g.stripe, hue.fg)
--   daw.draw.meter(buf, x, y, width, peak)
--   daw.draw.slider(buf, x, y, width, fraction)
local api = daw.api
local theme = require("daw.theme")
local M = {}

local function rgb(hex)
  return tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
end

--- A colour between two: `t` 0 gives `a`, 1 gives `b`.
function M.mix(a, b, t)
  local r1, g1, b1 = rgb(a)
  local r2, g2, b2 = rgb(b)
  local function ch(x, y) return math.floor(x + (y - x) * t + 0.5) end
  return string.format("#%02x%02x%02x", ch(r1, r2), ch(g1, g2), ch(b1, b2))
end

-- Colours on terminals without 24-bit colour ----------------------------------

local cube = { 0, 95, 135, 175, 215, 255 }

local function nearest_level(v)
  local best, at = math.huge, 1
  for i, level in ipairs(cube) do
    if math.abs(level - v) < best then best, at = math.abs(level - v), i end
  end
  return at - 1
end

--- The nearest of the 256 colours to `#rrggbb`, from the 6x6x6 cube (16 to
--- 231) or the greys (232 to 255), a grey for any colour with little hue:
--- its index and the colour it stands for.
function M.nearest256(hex)
  local r, g, b = rgb(hex)
  local ri, gi, bi = nearest_level(r), nearest_level(g), nearest_level(b)
  local spread = math.max(r, g, b) - math.min(r, g, b)
  if spread > 28 and ri == gi and gi == bi then
    -- The nearest point is a grey, but the colour has a hue: take the
    -- nearest of the points around it that keeps one.
    local function around(v)
      local lo = 1
      for i, level in ipairs(cube) do if level <= v then lo = i end end
      return { lo - 1, math.min(5, lo) }
    end
    local best
    for _, a in ipairs(around(r)) do
      for _, b2 in ipairs(around(g)) do
        for _, c3 in ipairs(around(b)) do
          if not (a == b2 and b2 == c3) then
            local d = (cube[a + 1] - r) ^ 2 + (cube[b2 + 1] - g) ^ 2 + (cube[c3 + 1] - b) ^ 2
            if not best or d < best[1] then best = { d, a, b2, c3 } end
          end
        end
      end
    end
    if best then ri, gi, bi = best[2], best[3], best[4] end
  end
  local cr, cg, cb = cube[ri + 1], cube[gi + 1], cube[bi + 1]
  local index = 16 + 36 * ri + 6 * gi + bi
  local dist = (cr - r) ^ 2 + (cg - g) ^ 2 + (cb - b) ^ 2
  -- The greys run from 8 to 238 in steps of 10.
  local grey = math.floor(((r + g + b) / 3 - 8) / 10 + 0.5)
  grey = math.max(0, math.min(23, grey))
  local level = 8 + grey * 10
  local gdist = (level - r) ^ 2 + (level - g) ^ 2 + (level - b) ^ 2
  -- A colour with little hue in it is a grey: the cube's nearest point would
  -- give it a tint it does not have.
  if spread <= 28 or (gdist < dist and ri == gi and gi == bi) then return 232 + grey, string.format("#%02x%02x%02x", level, level, level) end
  return index, string.format("#%02x%02x%02x", cr, cg, cb)
end

--- Whether the terminal shows 24-bit colour: `daw.opt.termcolors` "true" or
--- "256", or with "auto" (the default) what the environment says: COLORTERM
--- of truecolor or 24bit, or a TERM that ends in -direct.
function M.truecolor()
  local want = tostring(daw.opt.termcolors or "auto")
  if want == "true" or want == "truecolor" or want == "24bit" then return true end
  if want == "256" then return false end
  local colorterm = (os.getenv("COLORTERM") or ""):lower()
  if colorterm == "truecolor" or colorterm == "24bit" then return true end
  return (os.getenv("TERM") or ""):match("%-direct$") ~= nil
end

--- A highlight definition as this terminal can show it: on one without
--- 24-bit colour, each `#rrggbb` becomes the nearest of the 256.
function M.term_def(def, truecolor)
  if truecolor or type(def) ~= "table" then return def end
  local out = {}
  for k, v in pairs(def) do
    if (k == "fg" or k == "bg") and type(v) == "string" and v:match("^#%x%x%x%x%x%x$") then
      out[k] = M.nearest256(v)
    else
      out[k] = v
    end
  end
  return out
end

-- Characters ------------------------------------------------------------------

-- A beat begins at a cell's left edge: that is where a clip or a note that
-- starts on it begins to be drawn. So the lines and ticks of a timeline are
-- characters that sit on that edge, not ones centred in the cell, which
-- would stand half a cell to the right of everything that starts there.
local unicode = {
  rule = "│", bar = "▏", beat = "▏", step = "▏", tick = "▏", cap = "▼", playhead = "▏",
  loop_in = "▕", loop_out = "▕", clip_start = "▏", punch_in = "▕", punch_out = "▕",
  meter_full = "━", meter_half = "╸", meter_off = "─", peak = "▔", upper = "▀", lower = "▄", full = "█",
  slider_on = "━", knob = "●", slider_off = "─", pan_rail = "─", pan_mark = "┃",
  fader = "━", fader_rail = "│", zero = "╪", point = "◆", open = "▾", closed = "▸",
  stripe = "▌", stripe_sel = "█", send = "↗", out = "→", chain = "›", sep = "│", dot = "·",
  play = "▶", stop = "■", rec = "●", modified = "●", bypass = "◌", on = "●", ellipsis = "…",
  cursor = "▶", warn = "!", error = "✗", hairline = "▏", strip_sep = "┃",
  tl = "╭", tr = "╮", bl = "╰", br = "╯", h = "─", v = "│", mark = "▌",
  eighths = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" },
}
local ascii = {
  rule = "|", bar = "|", beat = ":", step = ".", tick = ".", cap = "v", playhead = "|",
  loop_in = "[", loop_out = "]", clip_start = "|", punch_in = "{", punch_out = "}",
  meter_full = "=", meter_half = "-", meter_off = ".", peak = "-", upper = "'", lower = ".", full = ":",
  slider_on = "=", knob = "o", slider_off = "-", pan_rail = "-", pan_mark = "|",
  fader = "=", fader_rail = "|", zero = "+", point = "*", open = "v", closed = ">",
  stripe = "|", stripe_sel = "#", send = "^", out = ">", chain = ">", sep = "|", dot = ".",
  play = ">", stop = "#", rec = "*", modified = "*", bypass = "o", on = "*", ellipsis = "~",
  cursor = ">", warn = "!", error = "x", hairline = "|", strip_sep = "|",
  tl = "+", tr = "+", bl = "+", br = "+", h = "-", v = "|", mark = "|",
  eighths = { ".", ".", "-", "-", "=", "=", "#", "#" },
}

--- The characters views draw with, by what they are for. The same table
--- holds plain ASCII ones while `daw.opt.ascii` is on.
M.g = {}
M.glyphs = { unicode = unicode, ascii = ascii }

function M.use_glyphs()
  local from = daw.opt.ascii and ascii or unicode
  for k, v in pairs(from) do M.g[k] = v end
end

-- Shades of a colour ----------------------------------------------------------

local hues = {}
local stereo_groups = {}

--- Highlight groups in the shades of one colour (`#rrggbb`), made the first
--- time the colour is asked for:
---   fg                  the colour itself, on whatever is behind it
---   title, body         a clip's name row and the rows under it
---   title_cur, body_cur the same for the clip under the cursor (or chosen)
---   title_off, body_off the same for a muted clip
---   lane_sel            the background of the selected track's lane
---   note, note_soft, note_faint   notes, loud to quiet
---   pill                dark text on the colour
---   plate               a name plate: light text on a deep shade
function M.hue(colour)
  local known = hues[colour]
  if known then return known end
  if not (type(colour) == "string" and colour:match("^#%x%x%x%x%x%x$")) then return M.hue(theme.hues[1]) end
  local c, mix = theme.palette, M.mix
  local key = colour:sub(2)
  local dark = mix(colour, "#000000", 0.78)
  local defs = {
    fg = { fg = colour },
    title = { fg = mix(colour, "#ffffff", 0.85), bg = mix(c.bg, colour, 0.55), bold = true },
    body = { fg = mix(c.bg, colour, 0.75), bg = mix(c.bg, colour, 0.20) },
    title_cur = { fg = dark, bg = colour, bold = true },
    body_cur = { fg = mix(colour, "#ffffff", 0.25), bg = mix(c.bg, colour, 0.34) },
    title_off = { fg = c.dim, bg = mix(c.bg, colour, 0.10), italic = true },
    body_off = { fg = mix(c.bg, colour, 0.30), bg = mix(c.bg, colour, 0.06) },
    lane_sel = { fg = c.line_hi, bg = mix(c.bg, colour, 0.06) },
    note = { fg = dark, bg = colour },
    note_soft = { fg = dark, bg = mix(c.bg, colour, 0.82) },
    note_faint = { fg = dark, bg = mix(c.bg, colour, 0.6) },
    pill = { fg = dark, bg = colour, bold = true },
    plate = { fg = mix(colour, "#ffffff", 0.85), bg = mix(c.bg, colour, 0.55), bold = true },
  }
  local names = {}
  for name, def in pairs(defs) do
    names[name] = "Hue_" .. name .. "_" .. key
    daw.ui.hl(names[name], def)
  end
  hues[colour] = names
  return names
end

--- Forget the shades made so far: after the palette has changed.
function M.reset()
  hues = {}
  stereo_groups = {}
end

--- The colour of a track: its own if it has one, else one of the theme's
--- by its place in the track list.
function M.track_colour(track, index)
  if track.color and track.color:match("^#%x%x%x%x%x%x$") then return track.color end
  if track.master then return theme.palette.dim end
  -- A member of a group is in its group's colour, so a section reads as one.
  local group = track.id and daw.groups and daw.groups.of(track.id)
  if group then return M.track_colour(api.track_get(group)) end
  -- By its place in the list, which folding a group away does not change.
  return theme.hues[((track.index or index or 1) - 1) % #theme.hues + 1]
end

function M.track_hue(track, index)
  return M.hue(M.track_colour(track, index))
end

--- The shade of a note by how hard it is played.
function M.note_style(hue, velocity)
  if velocity >= 90 then return hue.note end
  if velocity >= 50 then return hue.note_soft end
  return hue.note_faint
end

-- Meters and controls ---------------------------------------------------------

local function meter_style(at)
  return at > 0.92 and "MeterHigh" or at > 0.75 and "MeterMid" or "MeterLow"
end

--- How far up a meter a linear peak reaches, from 0 to 1 over 60 dB.
function M.level(peak)
  local db = 20 * math.log10(math.max(peak, 1e-6))
  return daw.util.clamp((db + 60) / 60, 0, 1)
end

--- Where on a meter `width` cells long a level in dB falls, from 0.
function M.db_cell(db, width)
  return math.floor(daw.util.clamp((db + 60) / 60, 0, 1) * (width - 1) + 0.5)
end

--- A level meter `width` cells wide for a linear peak: a thin rail, lit
--- from the left, green then yellow then red. With `hold` (a linear peak),
--- the loudest of late is marked.
function M.meter(buf, x, y, width, peak, hold)
  local g = M.g
  local filled = M.level(peak) * width
  for cell = 0, width - 1 do
    local amount = filled - cell
    if amount >= 0.75 then
      buf:text(x + cell, y, g.meter_full, meter_style((cell + 1) / width))
    elseif amount >= 0.25 then
      buf:text(x + cell, y, g.meter_half, meter_style((cell + 1) / width))
    else
      buf:text(x + cell, y, g.meter_off, "MeterOff")
    end
  end
  if hold and hold > 1e-5 then
    local at = math.min(width - 1, math.floor(M.level(hold) * width))
    if at >= math.floor(filled) then buf:text(x + at, y, g.meter_half, "MeterPeak") end
  end
end

--- A level meter `height` cells tall, lit from the bottom, with the peak
--- held (`hold`, linear) marked by a line over its cell.
function M.vmeter(buf, x, y, height, peak, hold)
  local g = M.g
  local filled = M.level(peak) * height
  -- The unlit part in one go: most of a meter, most of the time.
  local lit = math.min(height, math.ceil(filled - 0.06))
  local off = height - math.max(0, lit)
  if off > 0 then buf:fill(x, y, 1, off, g.v, "MeterOff") end
  local hold_row = hold and hold > 1e-5 and math.min(height - 1, math.floor(M.level(hold) * height)) or nil
  for row = 0, height - 1 do
    local from_bottom = height - 1 - row
    local amount = filled - from_bottom
    local style = meter_style((from_bottom + 1) / height)
    if amount >= 1 then
      buf:text(x, y + row, g.full, style)
    elseif amount > 0.06 then
      buf:text(x, y + row, g.eighths[math.max(1, math.floor(amount * 8 + 0.5))], style)
    elseif hold_row == from_bottom then
      buf:text(x, y + row, g.peak, "MeterPeak")
    end
  end
end

--- Both sides of a stereo level in one row `width` cells wide: the left in
--- the upper half of each cell, the right in the lower.
function M.stereo_meter(buf, x, y, width, left, right)
  local g = M.g
  if daw.opt.ascii then
    M.meter(buf, x, y, width, math.max(left, right))
    return
  end
  local p = theme.palette
  local colours = { off = p.bg_hl, MeterLow = p.meter_low, MeterMid = p.meter_mid, MeterHigh = p.meter_high }
  local lf, rf = M.level(left) * width, M.level(right) * width
  for cell = 0, width - 1 do
    local style = meter_style((cell + 1) / width)
    local up = lf - cell >= 0.5 and style or "off"
    local down = rf - cell >= 0.5 and style or "off"
    local name = "MeterLR_" .. up .. "_" .. down
    if not stereo_groups[name] then
      stereo_groups[name] = true
      daw.ui.hl(name, { fg = colours[up], bg = colours[down] })
    end
    buf:text(x + cell, y, g.upper, name)
  end
end

--- Peaks held for a while, by key: `hold(key, peak)` gives the loudest of
--- the last two seconds, which falls back once that time has passed.
local held = {}
function M.hold(key, peak)
  local now = api.now()
  local h = held[key]
  if not h or peak >= h.peak or now - h.time > 2000 then
    h = { peak = peak, time = now }
    held[key] = h
  end
  return h.peak
end

--- A slider `width` cells wide with its knob `fraction` of the way along.
function M.slider(buf, x, y, width, fraction, on, off)
  local g = M.g
  local at = math.floor(daw.util.clamp(fraction, 0, 1) * (width - 1) + 0.5)
  if at > 0 then buf:text(x, y, string.rep(g.slider_on, at), on or "ParamBar") end
  buf:text(x + at, y, g.knob, on or "ParamBar")
  if at < width - 1 then buf:text(x + at + 1, y, string.rep(g.slider_off, width - 1 - at), off or "ParamBarOff") end
end

--- A pan from -1 to 1 as a bar `width` cells wide (odd is best): a rail
--- with a mark where the sound sits, `───┃───` in the middle.
function M.pan(buf, x, y, width, pan, style)
  local g = M.g
  local at = math.floor((daw.util.clamp(pan, -1, 1) + 1) / 2 * (width - 1) + 0.5)
  buf:text(x, y, string.rep(g.pan_rail, width), "FaderTrack")
  buf:text(x + at, y, g.pan_mark, style or (math.abs(pan) < 0.005 and "TrackInfo" or "Bright"))
end

--- Where a pan from -1 to 1 points, in a few cells: `L30`, `C`, `R100`.
function M.pan_text(pan)
  local amount = math.floor(math.abs(pan) * 100 + 0.5)
  if amount == 0 then return "C" end
  return (pan < 0 and "L" or "R") .. amount
end

--- A volume in dB as few cells as it can: `-4.0`, `-inf`, `+2.5`.
function M.db_text(db)
  if db <= -100 then return "-inf" end
  return string.format(db > 0.05 and "+%.1f" or "%.1f", db)
end

--- Small on/off marks side by side, each a letter on a cell of its own:
--- `chips(buf, x, y, { { "M", on, "Mute" }, ... }, gap)`. Returns the columns used.
function M.chips(buf, x, y, list, gap)
  gap = gap or 1
  local at = x
  for i, chip in ipairs(list) do
    at = at + buf:text(at, y, chip[1], chip[2] and chip[3] or "FlagOff")
    if i < #list then at = at + gap end
  end
  return at - x
end

-- Pictures inside clips -------------------------------------------------------

--- Notes as a small piano roll of `rows` text rows, each `width` columns:
--- two pitches' worth of height to a row, drawn with half blocks. `notes`
--- have `start`, `length` and `pitch`; a column covers `1 / zoom` beats from
--- `from`.
function M.miniroll(notes, width, rows, zoom, from)
  from = from or 0
  local g = M.g
  local low, high = 127, 0
  for _, n in ipairs(notes) do
    low, high = math.min(low, n.pitch), math.max(high, n.pitch)
  end
  local levels = rows * 2
  -- Spread a narrow range over at least an octave, so a few notes close
  -- together do not fill the clip from top to bottom.
  local span = math.max(high - low + 1, 1)
  if span > 1 and span < 12 then
    local pad = math.floor((12 - span) / 2)
    low, span = low - pad, 12
  end
  -- Which levels sound in each column.
  local lit = {}
  for col = 1, width do lit[col] = {} end
  for _, n in ipairs(notes) do
    local c0 = math.max(0, math.floor((n.start - from) * zoom + 1e-9))
    local c1 = math.min(width - 1, math.ceil((n.start + n.length - from) * zoom - 1e-9) - 1)
    -- A lone pitch sits in the middle, not at the bottom.
    local level = span == 1 and math.floor(levels / 2) or math.floor((n.pitch - low) / span * levels)
    for col = c0, math.max(c0, c1) do
      if lit[col + 1] then lit[col + 1][level] = true end
    end
  end
  local out = {}
  for row = 0, rows - 1 do
    local upper, lower = levels - 1 - 2 * row, levels - 2 - 2 * row
    local cells = {}
    for col = 1, width do
      local up, down = lit[col][upper], lit[col][lower]
      cells[col] = up and down and g.full or up and g.upper or down and g.lower or " "
    end
    out[row + 1] = table.concat(cells)
  end
  return out
end

--- Peaks (`{ min, max }` pairs from -1 to 1) as a waveform of `rows` text
--- rows that grows from the bottom, on a decibel scale so that quiet
--- material still shows.
function M.waveform(peaks, rows)
  local g = M.g
  local out = {}
  for row = 0, rows - 1 do
    local from_bottom = rows - 1 - row
    local cells = {}
    for i, p in ipairs(peaks) do
      local db = 20 * math.log10(math.max(-p[1], p[2], 1e-6))
      local level = daw.util.clamp((db + 48) / 48, 0, 1) * rows * 8 - from_bottom * 8
      cells[i] = level >= 8 and g.full or level >= 1 and g.eighths[math.floor(level)] or " "
    end
    out[row + 1] = table.concat(cells)
  end
  return out
end

local function utf8(code)
  if code < 0x800 then return string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64) end
  return string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
end

local dots = { { 0x01, 0x02, 0x04, 0x40 }, { 0x08, 0x10, 0x20, 0x80 } }
local lines3 = { unicode = { "▁", "─", "▔" }, ascii = { "_", "-", "'" } }

--- Draw a curve as a thin dotted line over `rows` rows of a buffer, from
--- row `y` down: `value(i)` gives the height, from 0 at the bottom to 1 at
--- the top, at the `i`th of two points per column. Only the cells the line
--- passes through are touched. Braille dots unless `daw.opt.braille` is off
--- or `daw.opt.ascii` on; then lines at three heights a row.
function M.curve(buf, y, rows, value, style)
  if daw.opt.ascii or daw.opt.braille == false then
    local set = daw.opt.ascii and lines3.ascii or lines3.unicode
    for col = 0, buf.width - 1 do
      local v = value(col * 2)
      if v then
        local level = math.min(rows * 3 - 1, math.floor(daw.util.clamp(v, 0, 1) * rows * 3))
        buf:text(col, y + rows - 1 - math.floor(level / 3), set[level % 3 + 1], style)
      end
    end
    return
  end
  local steps = rows * 4
  for col = 0, buf.width - 1 do
    local cells = {}
    for side = 1, 2 do
      local v = value(col * 2 + side - 1)
      if v then
        local level = math.min(steps - 1, math.floor(daw.util.clamp(v, 0, 1) * steps))
        local row = rows - 1 - math.floor(level / 4)
        cells[row] = (cells[row] or 0) + dots[side][4 - level % 4]
      end
    end
    for row, bits in pairs(cells) do
      buf:text(col, y + row, utf8(0x2800 + bits), style)
    end
  end
end

-- Piano rolls -----------------------------------------------------------------

--- One row of a keyboard on its side, `width` cells wide, for the left edge
--- of a piano roll: black keys are short, the Cs are named, and so is the
--- pitch the cursor is on.
function M.piano_key(buf, row, pitch, cursor, width)
  local music = daw.music
  local step = pitch % 12
  if music.is_black(pitch) then
    buf:fill(0, row, width - 2, 1, " ", "PianoBlack")
    buf:fill(width - 2, row, 2, 1, " ", "PianoWhite")
  else
    -- Two white keys with no black one between them get a line instead.
    buf:fill(0, row, width, 1, (step == 0 or step == 5) and (daw.opt.ascii and "_" or "▁") or " ", "PianoWhite")
    if step == 0 then buf:text(1, row, music.name(pitch), "PianoC") end
  end
  if cursor then buf:text(0, row, daw.util.fit(music.name(pitch), width - 1) .. " ", "PianoCursor") end
end

--- The bars and beats from `from` for `span` beats, as the project counts
--- them: `{ beat = b, bar = n }` for a bar line (n from 1) and `{ beat = b }`
--- for a beat inside a bar. Bar lines come from `daw.time.bar_start`, so a
--- change of time signature moves them.
function M.bar_lines(from, span)
  -- From the tempo map: bars, and the beats of the signature in each.
  local out = {}
  for _, line in ipairs(daw.tempo.lines(from - 1e-9, from + span + 1e-9)) do
    out[#out + 1] = line.index == 0 and { beat = line.beat, bar = line.bar } or { beat = line.beat }
  end
  return out
end

--- Number a ruler above a roll that shows `span` beats from `scroll` at
--- `zoom` columns a beat: bars as the project counts them (`origin` is the
--- project beat of the roll's beat 0), beats in between as ticks. Returns
--- where the lines go, as `{ x, bar }`, for the rows underneath.
function M.beats(ruler, scroll, span, zoom, origin)
  local g = M.g
  local lines = {}
  local every = math.max(1, math.ceil(4 / (daw.time.bar(origin + scroll) * zoom)))
  local free = 0
  for _, line in ipairs(M.bar_lines(origin + scroll, span)) do
    local at = math.floor((line.beat - origin - scroll) * zoom + 0.5)
    lines[#lines + 1] = { x = at, bar = line.bar ~= nil, beat = line.beat - origin }
    if line.bar then
      if (line.bar - 1) % every == 0 and at >= free then free = at + ruler:text(at, 0, tostring(line.bar), "RulerBar") + 1 end
    elseif zoom >= 2 and at >= free then
      ruler:text(at, 0, g.tick, "RulerTick")
    end
  end
  return lines
end

--- A row of keys and what they do, for a line of hints: `{ { "o", "new track" }, ... }`,
--- joined by a faint dot. `? keys` always comes last when it is in the list.
--- Returns the columns used; entries that do not fit are left out.
function M.keys(buf, x, y, entries, width, groups)
  local g = M.g
  local key, text, sep_style = "KeyBarKey", "KeyBarText", "KeyBarSep"
  if groups == "FloatFooter" then key, text, sep_style = "FooterKey", "FooterText", "FooterSep" end
  local list, last = {}, nil
  for _, entry in ipairs(entries) do
    if entry[1] == "?" then last = entry else list[#list + 1] = entry end
  end
  local room = width
  if last then room = room - api.str_width(last[1]) - api.str_width(last[2]) - 4 end
  local at = x
  local sep = " " .. g.dot .. " "
  local function put(entry)
    if at > x then at = at + buf:text(at, y, sep, sep_style) end
    at = at + buf:text(at, y, entry[1], key)
    at = at + buf:text(at, y, " " .. entry[2], text)
  end
  for _, entry in ipairs(list) do
    local need = api.str_width(entry[1]) + api.str_width(entry[2]) + 1 + (at > x and 3 or 0)
    if at + need > x + room then break end
    put(entry)
  end
  if last then put(last) end
  return at - x
end

M.use_glyphs()

return M
