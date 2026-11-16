-- The page in pixels: a layout's measures engraved with a SMuFL font,
-- snapped to the pixel grid, as `daw.canvas` drawing operations.
--
--   style    the staff space in whole pixels (one of STEPS), the font's
--            engraving defaults turned into whole-pixel thicknesses, and
--            the colours: ink (the terminal's foreground, or the window's
--            text), staff lines part of the way to the paper, accents
--   systems  measures packed into systems across the width ("wrapped"), or
--            all of them in one endless system ("galley"); measure widths
--            in whole cell columns and system heights in whole cell rows,
--            so a frontend can cut the page at barlines into images that
--            sit on cells
--   ink      what is written, measure by measure, kept by what the measure
--            holds: an edit engraves again only the measures it changed,
--            and a cursor move none
--
-- Staff lines, stems, barlines and ledger lines are rectangles on whole
-- pixels; note heads, clefs, accidentals, flags, rests, dots, numbers and
-- dynamics are the font's glyphs; beams, ties and slurs are paths.
local model = require("notation.model")
local smufl = require("notation.smufl")

local floor, ceil, abs, max, min, sqrt = math.floor, math.ceil, math.abs, math.max, math.min, math.sqrt
local EPS = 1e-6

local E = {}

--- The staff spaces the page is drawn at, in pixels: zoom steps through these.
E.STEPS = { 6, 7, 8, 9, 10, 12, 14, 16, 18, 20, 24 }

local function round(v) return floor(v + 0.5) end

-- Colours ------------------------------------------------------------------------------------

local function rgb(hex)
  hex = tostring(hex or ""):gsub("^#", "")
  return tonumber(hex:sub(1, 2), 16) or 0, tonumber(hex:sub(3, 4), 16) or 0, tonumber(hex:sub(5, 6), 16) or 0
end

local function lightness(hex)
  local r, g, b = rgb(hex)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

--- `a` taken `t` of the way to `b`.
local function mix(a, b, t)
  local r1, g1, b1 = rgb(a)
  local r2, g2, b2 = rgb(b)
  return string.format("#%02x%02x%02x", round(r1 + (r2 - r1) * t), round(g1 + (g2 - g1) * t), round(b1 + (b2 - b1) * t))
end
E.mix = mix

-- Style --------------------------------------------------------------------------------------

--- What the page is drawn with. `o`: `space` (staff space in px), `cell`
--- (`{ w, h }`), `ink`, `paper`, `accent`, `font`, `whole_cells` (measure
--- widths and system heights in whole cells).
function E.style(o)
  local sp = o.space
  local font = smufl.font(o.font)
  local d = font.defaults
  -- Light ink on a dark page looks heavier than dark on light: thinner.
  local thin = lightness(o.ink) > lightness(o.paper) and 0.9 or 1
  local function px(v) return max(1, round(v * sp * thin)) end
  local st = {
    sp = sp, em = 4 * sp, font = font, cell = o.cell, whole = o.whole_cells,
    line = px(d.staffLineThickness), stem = px(d.stemThickness), ledger = px(d.legerLineThickness),
    ledger_ext = d.legerLineExtension * sp, beam = max(2, round(d.beamThickness * sp * thin)),
    beam_gap = max(1, round(d.beamSpacing * sp)), bar = px(d.thinBarlineThickness), thick = px(d.thickBarlineThickness),
    bar_gap = round(d.barlineSeparation * sp), dot_gap = d.repeatBarlineDotSeparation * sp,
    tie_end = d.tieEndpointThickness * sp, tie_mid = d.tieMidpointThickness * sp * thin,
    slur_end = d.slurEndpointThickness * sp, slur_mid = d.slurMidpointThickness * sp * thin,
    hairpin = max(1, d.hairpinThickness * sp * thin), bracket = px(d.tupletBracketThickness),
    ink = o.ink, paper = o.paper, accent = o.accent,
    staff = mix(o.ink, o.paper, 0.55), faint = mix(o.ink, o.paper, 0.45), muted = mix(o.ink, o.paper, 0.3),
  }
  st.key = table.concat({ sp, o.cell.w, o.cell.h, o.ink, o.paper, font.name, tostring(o.whole_cells) }, ":")
  return st
end

local function glyph(st, name) return st.font.glyphs[name] end
local function gwidth(st, name, scale)
  local g = glyph(st, name)
  return (g.bbox[3] - g.bbox[1]) * st.sp * (scale or 1)
end

-- Ink: drawing kept in coordinates of its own ------------------------------------------------

local Ink = {}
Ink.__index = Ink
local function ink() return setmetatable({ ops = {}, heads = {} }, Ink) end

function Ink:rect(x, y, w, h, colour)
  if w <= 0 or h <= 0 then return end
  self.ops[#self.ops + 1] = { "r", x, y, w, h, colour, "", 1, 0 }
end

function Ink:glyph(st, x, y, name, colour, scale)
  local g = glyph(st, name)
  if not g then return end
  self.ops[#self.ops + 1] = { "g", x, y, st.em * (scale or 1), g.cp, colour, st.font.name }
end

function Ink:text(x, y, text, colour, size, bold, align, width)
  self.ops[#self.ops + 1] = { "t", x, y, tostring(text), colour, size, bold and 1 or 0, align or "left", width or 400 }
end

--- A path: `{ "M", x, y, "C", ..., "Z" }` kept as numbers until placed.
function Ink:path(cmds, stroke, width, fill)
  self.ops[#self.ops + 1] = { "P", cmds, stroke or "", width or 1, fill or "" }
end

local function fmt(v) return string.format("%.1f", v) end

--- Put ink into a drawing at `dx, dy`.
local function place(src, out, dx, dy)
  for _, op in ipairs(src) do
    local kind = op[1]
    if kind == "P" then
      local cmds, parts, axis = op[2], {}, 0
      for i, v in ipairs(cmds) do
        if type(v) == "string" then
          parts[i] = v
          axis = 0
        else
          parts[i] = fmt(v + (axis == 0 and dx or dy))
          axis = 1 - axis
        end
      end
      out[#out + 1] = { "p", table.concat(parts, " "), op[3], op[4], op[5] }
    else
      local o = { kind, op[2] + dx, op[3] + dy }
      for i = 4, #op do o[i] = op[i] end
      out[#out + 1] = o
    end
  end
end
E.place = place

-- Shapes ------------------------------------------------------------------------------------

--- A tie or slur from `x0, y0` to `x1, y1` bowing `bow` px towards `dir`
--- (1 down, -1 up), thicker in the middle. `inset` is how far in from the
--- ends the curve's control points are, as a part of its length: small for
--- a flat curve, a quarter for a round one.
local function arc(dst, x0, y0, x1, y1, bow, dir, thick_end, thick_mid, colour, inset)
  local dx, dy = x1 - x0, y1 - y0
  inset = inset or 0.25
  -- A cubic's middle is three quarters of the way to its control points.
  local outer, inner = (bow + thick_mid / 2) / 0.75, (bow - thick_mid / 2) / 0.75
  local e = thick_end / 2
  local ax, ay = x0 + dx * inset, y0 + dy * inset
  local bx, by = x0 + dx * (1 - inset), y0 + dy * (1 - inset)
  dst:path({ "M", x0, y0 + dir * e,
    "C", ax, ay + dir * outer, bx, by + dir * outer, x1, y1 + dir * e,
    "L", x1, y1 - dir * e,
    "C", bx, by + dir * inner, ax, ay + dir * inner, x0, y0 - dir * e, "Z" }, "", 1, colour)
end
E.arc = arc

--- The most a tie rises, in staff spaces.
E.TIE_HEIGHT = 0.6

--- A tie from `x0` to `x1` at `y`, towards `dir` (1 down): flat, close to
--- the heads, rising a little more the longer it is (Gould).
local function tie(dst, st, x0, x1, y, dir, colour)
  local s = st.sp
  local bow = min(E.TIE_HEIGHT, 0.3 + 0.02 * (x1 - x0) / s) * s
  arc(dst, x0, y, x1, y, bow, dir, st.tie_end, st.tie_mid, colour, 0.12)
end

--- Where the tie of a chord's `i`th note (from the lowest) goes: `dir` (1
--- below the heads, -1 above) and whether it lies outside the chord, over
--- or under the heads, or between them. A single note's tie and a chord's
--- outer ones are outside, on the side away from the stem (a stemless note
--- by where it sits on the staff); a chord's upper notes tie up, its lower
--- ones down.
local function tie_side(ev, i)
  local notes = ev.notes
  local away = ev.stem and (ev.stem > 0 and 1 or -1) or (notes[#notes].pos >= 4 and -1 or 1)
  local count = #notes
  if count == 1 then return away, true end
  if i == count then return -1, true end
  if i == 1 then return 1, true end
  if 2 * i - 1 == count then return away, false end
  return 2 * i > count and -1 or 1, false
end

--- A tie's ends for a head whose left edge is at `hx` (`hw` wide) and the
--- next head's left edge at `nx`, and its height: outside a chord over the
--- heads, inside it between them.
local function tie_ends(st, hw, hx, nx, y, dir, outside, dotted)
  local s = st.sp
  if outside then
    return dotted and hx + hw + 0.85 * s or hx + 0.7 * hw, nx and nx + 0.3 * hw, y + dir * 0.7 * s
  end
  return hx + hw + 0.15 * s + (dotted and 0.5 * s or 0), nx and nx - 0.15 * s, y + dir * 0.25 * s
end

-- Heads, accidentals and what else stands beside a head --------------------------------

--- Accidentals of a chord in columns: the highest nearest the notes, each
--- next one in the first column where it clears those above it by six
--- staff positions. Returns the column of each note (0 nearest).
local function accidental_columns(notes)
  local cols, placed = {}, {}
  for i = #notes, 1, -1 do
    local n = notes[i]
    if n.acc then
      local c = 0
      while true do
        local clash = false
        for _, q in ipairs(placed) do
          if q.col == c and abs(q.pos - n.pos) < 6 then clash = true end
        end
        if not clash then break end
        c = c + 1
      end
      cols[i] = c
      placed[#placed + 1] = { col = c, pos = n.pos }
    end
  end
  return cols
end

local ACC_GLYPH = { [1] = "accidentalSharp", [-1] = "accidentalFlat", [0] = "accidentalNatural", [2] = "accidentalDoubleSharp", [-2] = "accidentalDoubleFlat" }
local HEAD_GLYPH = function(base)
  if not base or base < 2 then return "noteheadBlack" end
  if base < 4 then return "noteheadHalf" end
  if base < 8 then return "noteheadWhole" end
  return "noteheadDoubleWhole"
end
local REST_GLYPH = { [4] = "restWhole", [2] = "restHalf", [1] = "restQuarter", [0.5] = "rest8th", [0.25] = "rest16th", [0.125] = "rest32nd" }
local FLAG_GLYPH = { "flag8th", "flag16th", "flag32nd", "flag64th" }
E.ACC_GLYPH, E.HEAD_GLYPH = ACC_GLYPH, HEAD_GLYPH
local DYN_GLYPH = { p = "dynamicPiano", mp = "dynamicMP", mf = "dynamicMF", f = "dynamicForte",
  pp = "dynamicPP", ff = "dynamicFF", ppp = "dynamicPPP", fff = "dynamicFFF" }

--- Between a head and its accidental, and between columns of accidentals,
--- in staff spaces.
local ACC_GAP, ACC_COLUMN_GAP = 0.2, 0.15

--- An accidental's width, its parentheses included.
local function acc_width(st, n)
  local w = gwidth(st, ACC_GLYPH[n.acc])
  if n.courtesy then w = w + gwidth(st, "accidentalParensLeft") + gwidth(st, "accidentalParensRight") end
  return w
end

--- A chord's accidentals placed left of its heads: for each note with one,
--- how far left of the heads' left edge its sign (parentheses included)
--- begins, each right-aligned in a column as wide as the column's widest;
--- and the room they all take, from the heads' edge (0 with none).
local function accidentals(st, notes)
  local cols = accidental_columns(notes)
  local widths = {}
  for i, n in ipairs(notes) do
    if n.acc then widths[cols[i] + 1] = max(widths[cols[i] + 1] or 0, acc_width(st, n)) end
  end
  if #widths == 0 then return {}, 0 end
  local edge, from = ACC_GAP * st.sp, {}
  for c, w in ipairs(widths) do
    from[c] = edge
    edge = edge + w + ACC_COLUMN_GAP * st.sp
  end
  local at = {}
  for i, n in ipairs(notes) do
    if n.acc then at[i] = from[cols[i] + 1] + acc_width(st, n) end
  end
  return at, edge - ACC_COLUMN_GAP * st.sp
end

--- Which of a chord's heads go on the other side of the stem (a second up
--- from its neighbour does), and whether any does.
local function seconds(ev)
  local shifted, any = {}, false
  for i, n in ipairs(ev.notes) do
    local prev = ev.notes[i - 1]
    shifted[i] = prev and n.step - prev.step == 1 and not shifted[i - 1] or false
    any = any or shifted[i]
  end
  return shifted, any
end

--- How far an event's writing reaches left and right of its time (the
--- middle of its heads), in px: accidentals, grace notes and the arpeggio
--- on the left; heads on the other side of the stem, dots and a flag on
--- the right. As `measure_ink` draws them.
local function room(st, ev)
  local s = st.sp
  if ev.kind == "rest" then
    if ev.whole then return 0, 0 end
    local rw = gwidth(st, REST_GLYPH[ev.base] or "rest16th")
    return rw / 2, rw / 2 + (ev.dots > 0 and 0.3 * s + gwidth(st, "augmentationDot") or 0)
  end
  local hw = gwidth(st, HEAD_GLYPH(ev.base))
  local dir = ev.stem or 1
  -- Most chords have no second and no accidental: nothing to place for those.
  local any, signs = false, false
  for i, n in ipairs(ev.notes) do
    if n.acc then signs = true end
    if i > 1 and n.step - ev.notes[i - 1].step == 1 then any = true end
  end
  local side = any and hw - st.stem or 0
  local acc = 0
  if signs then _, acc = accidentals(st, ev.notes) end
  local left = hw / 2 + (dir < 0 and side or 0) + acc
  local right = hw / 2 + (dir > 0 and side or 0)
  if ev.arpeggio or ev.grace then left = left + 0.4 * s end
  if ev.arpeggio then left = left + 1.1 * s end
  for _, gn in ipairs(ev.grace or {}) do
    left = left + 0.66 * gwidth(st, "noteheadBlack") + 0.5 * s
    if gn.acc then left = left + gwidth(st, ACC_GLYPH[gn.acc], 0.66) + 0.15 * s end
  end
  if ev.dots > 0 then right = right + (0.35 + 0.5 * (ev.dots - 1)) * s + gwidth(st, "augmentationDot") end
  if ev.stem and dir > 0 and not ev.beam and (ev.flags or 0) > 0 then
    right = max(right, hw / 2 - st.stem + gwidth(st, FLAG_GLYPH[min(4, ev.flags)] .. "Up"))
  end
  return left, right
end
E.room = room

-- Spacing ------------------------------------------------------------------------------------

--- A measure's spacing without touching the layout's measure: a proxy
--- carries `slots` and `width` (in px). What stands beside the heads gets
--- room only where the spacing of the values leaves too little, half a
--- space clear of the note before.
local function spaced(m, st, spread)
  local p = setmetatable({}, { __index = m })
  local s = st.sp
  model.space({ measures = { p } }, {
    lead = 1.5 * s, gap = 0.5 * s, tail = 0.9 * s,
    unit = function(d) return s * spread * (1.15 + 1.6 * sqrt(d / 0.25)) end,
    room = function(ev) return room(st, ev) end,
  })
  return p
end

--- Stretch a spaced measure to `width` px.
local function stretch(p, width)
  local f = width / max(1, p.width)
  local slots = {}
  for i, slot in ipairs(p.slots) do slots[i] = { t = slot.t, x = slot.x * f } end
  p.slots, p.width = slots, width
end

-- Systems ------------------------------------------------------------------------------------

local SHARP_POS = { 8, 5, 9, 6, 3, 7, 4 }
local FLAT_POS = { 4, 7, 3, 6, 2, 5, 1 }
E.SHARP_POS, E.FLAT_POS = SHARP_POS, FLAT_POS

local function meter_changes(layout, i)
  local before = layout.measures[i - 1]
  return i == 1 or (before and before.meter ~= layout.measures[i].meter)
end
E.meter_changes = meter_changes

local function time_width(st, meter)
  local w = 0
  for _, digits in ipairs({ tostring(meter.num), tostring(meter.den) }) do
    local dw = 0
    for ch in digits:gmatch("%d") do dw = dw + gwidth(st, "timeSig" .. ch) end
    w = max(w, dw)
  end
  return w
end

--- The width of what starts a system: clef, key signature, and the time
--- signature where it is written.
local function prefix_width(st, layout, i, left)
  local w = left + 0.6 * st.sp + gwidth(st, "gClef") + 0.8 * st.sp
  local fifths = layout.fifths
  if fifths ~= 0 then
    w = w + abs(fifths) * (gwidth(st, fifths > 0 and "accidentalSharp" or "accidentalFlat") + 0.12 * st.sp) + 0.6 * st.sp
  end
  if meter_changes(layout, i) then w = w + time_width(st, layout.measures[i].meter) + 0.8 * st.sp end
  return w
end

--- How far a measure's notes and stems reach above and below each staff,
--- in staff positions (8 the top line, 0 the bottom).
local function reach(m, staves)
  local above, below = {}, {}
  for st = 1, staves do above[st], below[st] = 8, 0 end
  for st = 1, staves do
    for _, ev in ipairs(m.staves[st] or {}) do
      for _, n in ipairs(ev.notes or {}) do
        local stem = ev.stem or 0
        above[st] = max(above[st], n.pos + (stem > 0 and 7 or 1))
        below[st] = min(below[st], n.pos - (stem < 0 and 7 or 1))
      end
      if ev.art then
        above[st], below[st] = max(above[st], 10), min(below[st], -2)
      end
    end
  end
  return above, below
end

--- Measures packed into systems. `o`: `width`, `top` (where the first
--- system starts), `galley`, `spread`. Returns `{ systems, total, left }`;
--- each system has `y`, `height`, `x0`, `width`, `staff_top[st]`, the tab
--- staff's `tab_top`, and `measures` (`{ m, p, x }`: the measure, its
--- spacing, where it starts).
function E.systems(layout, st, o)
  local s = st.sp
  local cw = st.whole and st.cell.w or 1
  local ch = st.whole and st.cell.h or 1
  local function cols(v) return ceil(v / cw - EPS) * cw end
  local function rows(v) return ceil(v / ch - EPS) * ch end
  local staves = #layout.staves
  -- Room at the left for a grand staff's brace.
  local left = cols(max(cw, (staves >= 2 and not layout.names and 1.8 or 0.8) * s))
  local width = o.width
  local spaced_of = {}
  for i, m in ipairs(layout.measures) do spaced_of[i] = spaced(m, st, o.spread or 1) end
  -- Measures packed into systems as they fit, the first of each system
  -- in `starts`.
  local n, starts, i = #layout.measures, {}, 1
  while i <= n do
    starts[#starts + 1] = i
    local x = cols(prefix_width(st, layout, i, left))
    repeat
      local p = spaced_of[i]
      if not o.galley and i > starts[#starts] and x + p.width > width - cw then break end
      x = x + p.width
      i = i + 1
    until i > n
  end
  -- A bar alone on the last system takes the last bar of the system before,
  -- when that one has bars to spare and the two fit.
  local k = #starts
  if not o.galley and k >= 2 and starts[k] == n and starts[k] - starts[k - 1] >= 3 then
    local x = cols(prefix_width(st, layout, n - 1, left)) + spaced_of[n - 1].width + spaced_of[n].width
    if x <= width - cw then starts[k] = n - 1 end
  end
  local systems = {}
  local y = o.top or 0
  local staff_h = 4 * s
  local tab = layout.tab
  for k, first in ipairs(starts) do
    local x0 = cols(prefix_width(st, layout, first, left))
    local sys = { measures = {}, x0 = x0, y = y, first = first }
    local x = x0
    for j = first, (starts[k + 1] or n + 1) - 1 do
      local p = spaced_of[j]
      sys.measures[#sys.measures + 1] = { m = layout.measures[j], p = p, x = x }
      x = x + p.width
    end
    -- Every system but the last is spread to the full width, as on a page;
    -- each barline on a whole cell column.
    local target = x
    if not o.galley and starts[k + 1] then target = width - cw end
    local factor = (target - x0) / max(1, x - x0)
    local at, natural = x0, x0
    for _, placed in ipairs(sys.measures) do
      natural = natural + placed.p.width * factor
      local right = max(at + cw, floor(natural / cw + 0.5) * cw)
      stretch(placed.p, right - at)
      placed.x = at
      at = right
    end
    sys.width = at
    -- Room above and below each staff for what reaches past it.
    local above, below = {}, {}
    for k = 1, staves do above[k], below[k] = 8, 0 end
    for _, placed in ipairs(sys.measures) do
      local a, b = reach(placed.m, staves)
      for k = 1, staves do above[k], below[k] = max(above[k], a[k]), min(below[k], b[k]) end
    end
    local function over(k) return max(0, (above[k] - 8) / 2 * s) end
    local function under(k) return max(0, -below[k] / 2 * s) end
    local names = layout.names and 1.4 * s or 0
    sys.staff_top = {}
    local top = round(y + max(2.5 * s, over(1) + 1.2 * s + names))
    for k = 1, staves do
      if k > 1 then top = round(top + staff_h + max(3.5 * s, under(k - 1) + over(k) + 1.2 * s + names)) end
      sys.staff_top[k] = top
    end
    local bottom = sys.staff_top[staves] + staff_h
    if tab then
      sys.tab_line = round(1.5 * s)
      sys.tab_top = round(bottom + max(3 * s, under(staves) + 1.5 * s))
      bottom = sys.tab_top + (tab.strings - 1) * sys.tab_line + s
    else
      bottom = bottom + max(2 * s, under(staves) + 1.2 * s)
    end
    -- Dynamics and hairpins go under the first staff.
    for _, placed in ipairs(sys.measures) do
      if placed.m.marks and #placed.m.marks > 0 then bottom = max(bottom, sys.staff_top[1] + staff_h + 4.5 * s) end
    end
    sys.height = rows(bottom - y)
    systems[#systems + 1] = sys
    y = y + sys.height
  end
  return { systems = systems, total = y, left = left, s = s, style = st }
end

--- The y of a staff position (0 the bottom line, 8 the top) on a staff,
--- at the middle of its line.
function E.y_of(st, sys, staff, pos)
  return sys.staff_top[staff] + (8 - pos) * st.sp / 2 + st.line / 2
end

-- A measure's ink ----------------------------------------------------------------------------

--- What a measure's ink depends on, as text: two measures that say the
--- same draw the same.
local function signature(m, placed, sys, layout)
  local parts = { floor(placed.p.width + 0.5), #layout.staves, tostring(layout.tab and layout.tab.strings),
    tostring(sys.tab_top and sys.tab_top - sys.y),
    tostring(m.repeat_start), tostring(m.repeat_end), m.meter.num, m.meter.den, m.start, m.number }
  for k = 1, #layout.staves do
    parts[#parts + 1] = "|" .. (sys.staff_top[k] - sys.y)
    for _, ev in ipairs(m.staves[k] or {}) do
      parts[#parts + 1] = table.concat({ ev.kind, ev.start, ev.length, tostring(ev.base), ev.dots, tostring(ev.stem),
        tostring(ev.flags), tostring(ev.beam and true), tostring(ev.whole), tostring(ev.shift), ev.voice,
        tostring(ev.arpeggio), tostring(ev.staccato), tostring(ev.lyric), tostring(ev.tuplet and ev.tuplet.n),
        tostring(ev.tuplet and ev.tuplet.s), tostring(ev.slur_to and ev.slur_to.start), tostring(ev.slur_to and ev.slur_to.measure) }, ",")
      if ev.art then
        for _, a in ipairs({ "staccato", "accent", "tenuto", "marcato" }) do
          if ev.art[a] then parts[#parts + 1] = a end
        end
      end
      for _, n in ipairs(ev.notes or {}) do
        parts[#parts + 1] = table.concat({ n.pos, n.id or n.index, tostring(n.acc), tostring(n.courtesy), tostring(n.tie),
          tostring(n.tied), tostring(n.string), tostring(n.fret), tostring(ev.next and ev.next.measure == ev.measure and ev.next.start) }, ".")
      end
      for _, n in ipairs(ev.grace or {}) do parts[#parts + 1] = "g" .. n.pos .. tostring(n.acc) end
    end
  end
  for _, mk in ipairs(m.marks or {}) do
    parts[#parts + 1] = table.concat({ mk.kind, tostring(mk.value), mk.at, tostring(mk.to) }, ",")
  end
  return table.concat(parts, ";")
end

--- Where a beam group's beams run: `y0` at `x0`, slope per px, direction.
--- The slope is at most a staff space over the group and comes in quarter
--- spaces; inside the staff the beam's middle sits on a line, or a
--- quarter space above or below one, never in the middle of a space.
local function beam_line(st, evs, stem_x, Y, dir)
  local s = st.sp
  local first, last = evs[1], evs[#evs]
  local function far(ev) return dir > 0 and ev.notes[#ev.notes].pos or ev.notes[1].pos end
  local x0, x1 = stem_x(first), stem_x(last)
  local span = max(1, x1 - x0)
  local rise = (Y(far(last)) - Y(far(first)))
  rise = max(-s, min(s, rise / 2))
  rise = round(rise / (s / 4)) * (s / 4)
  -- A group whose inner notes reach further than its ends lies flat.
  for k = 2, #evs - 1 do
    local p = far(evs[k])
    if (dir > 0 and p > max(far(first), far(last))) or (dir < 0 and p < min(far(first), far(last))) then rise = 0 end
  end
  local slope = rise / span
  -- Every stem at least three spaces (shorter with more beams), and the
  -- beam reaching the middle line.
  local levels = 1
  for _, ev in ipairs(evs) do levels = max(levels, ev.flags or 1) end
  local need = (3.0 + max(0, levels - 2) * 0.5) * s
  local y0 = dir > 0 and math.huge or -math.huge
  for _, ev in ipairs(evs) do
    local at = Y(far(ev)) - dir * need - slope * (stem_x(ev) - x0)
    if dir > 0 then y0 = min(y0, at) else y0 = max(y0, at) end
  end
  local mid = Y(4)
  for _, ev in ipairs(evs) do
    local yb = y0 + slope * (stem_x(ev) - x0)
    if dir > 0 and yb > mid then y0 = y0 - (yb - mid) end
    if dir < 0 and yb < mid then y0 = y0 + (mid - yb) end
  end
  -- The primary beam's middle on the quarter-space grid, avoiding mid-space.
  local centre = y0 + dir * st.beam / 2
  local top = Y(8) - st.line / 2
  local rel = (centre - top) / (s / 4)
  local q = round(rel)
  if q >= -1 and q <= 17 and q % 4 == 2 then q = q + (dir > 0 and -1 or 1) end
  local snapped = top + q * s / 4
  -- On a whole pixel, so that a flat beam's edges are sharp.
  y0 = round(y0 + (snapped - centre))
  return { x0 = x0, y0 = y0, slope = slope, dir = dir, at = function(x) return y0 + slope * (x - x0) end }
end

--- Engrave a measure's music in coordinates from its left edge and the
--- system's top. Ties that leave the measure and slurs are the system's.
local function measure_ink(st, layout, sys, placed)
  local m, p = placed.m, placed.p
  local s, out = st.sp, ink()
  local colour = st.ink
  local function xt(beat) return model.x_of(p, beat) end
  local w = p.width
  local sys_y = sys.y
  local nstaves = #layout.staves
  local function Ys(staff) return function(pos) return E.y_of(st, sys, staff, pos) - sys_y end end
  local top_y, bottom_y = Ys(1)(8) - st.line / 2, Ys(nstaves)(0) + st.line / 2
  -- Its stretch of the staff lines, and the barline at the end, on whole pixels.
  for staff = 1, nstaves do
    for pos = 0, 8, 2 do out:rect(0, round(Ys(staff)(pos) - st.line / 2), round(w), st.line, st.staff) end
  end
  if layout.tab and sys.tab_top then
    for i = 1, layout.tab.strings do out:rect(0, sys.tab_top - sys_y + (i - 1) * sys.tab_line, round(w), st.line, st.staff) end
  end
  local bx = round(w) - st.bar
  out:rect(bx, round(top_y), st.bar, round(bottom_y - top_y), colour)
  if layout.tab and sys.tab_top then
    local t0 = sys.tab_top - sys_y
    out:rect(bx, t0, st.bar, (layout.tab.strings - 1) * sys.tab_line + st.line, colour)
  end
  local head_w = gwidth(st, "noteheadBlack")
  local stem_up_x = round(glyph(st, "noteheadBlack").anchors.stemUpSE[1] * s)

  for staff = 1, nstaves do
    local evs = m.staves[staff] or {}
    local Y = Ys(staff)
    -- Heads are placed with their left edge on a whole pixel, centred on
    -- the event's time; stems hang from the font's anchors.
    local function head_x(ev) return round(xt(ev.start) - head_w / 2) end
    local function stem_x(ev, dir)
      local hx = head_x(ev)
      if dir > 0 then return hx + stem_up_x - st.stem end
      return hx
    end
    local beams = {}
    for _, ev in ipairs(evs) do
      if ev.beam then
        local b = beams[ev.beam] or { dir = ev.stem, events = {} }
        b.events[#b.events + 1] = ev
        beams[ev.beam] = b
      end
    end
    for _, b in pairs(beams) do
      b.line = beam_line(st, b.events, function(ev) return stem_x(ev, b.dir) + st.stem / 2 end, Y, b.dir)
    end

    for _, ev in ipairs(evs) do
      local ex = xt(ev.start)
      if ev.kind == "rest" then
        local rx = ev.whole and (w / 2) or ex
        local sh = ev.shift or 0
        local base = ev.whole and 4 or ev.base
        local name = REST_GLYPH[base] or "rest16th"
        local rw = gwidth(st, name)
        local pos = (base >= 4) and 6 or 4
        out:glyph(st, round(rx - rw / 2), round(Y(pos + sh)), name, colour)
        if ev.dots > 0 and not ev.whole then
          out:glyph(st, round(rx + rw / 2 + 0.3 * s), round(Y(5 + sh)), "augmentationDot", colour)
        end
      else
        local dir = ev.stem or 1
        local hname = HEAD_GLYPH(ev.base)
        local hw = gwidth(st, hname)
        local hx = round(ex - hw / 2)
        -- A second up from its neighbour goes on the other side of the stem.
        local shifted, any_shift = seconds(ev)
        local side = round(hw - st.stem)
        local low, high = ev.notes[1].pos, ev.notes[#ev.notes].pos
        -- Ledger lines.
        local ext = st.ledger_ext
        local lx0 = round(hx - ext - ((any_shift and dir < 0) and side or 0))
        local lx1 = round(hx + hw + ext + ((any_shift and dir > 0) and side or 0))
        for pos = -2, low, -2 do out:rect(lx0, round(Y(pos) - st.ledger / 2), lx1 - lx0, st.ledger, colour) end
        for pos = 10, high, 2 do out:rect(lx0, round(Y(pos) - st.ledger / 2), lx1 - lx0, st.ledger, colour) end
        local acc_at, acc_room = accidentals(st, ev.notes)
        local acc_left = hx - ((any_shift and dir < 0) and side or 0)
        for i, n in ipairs(ev.notes) do
          local nx = hx + (shifted[i] and (dir > 0 and side or -side) or 0)
          local ny = Y(n.pos)
          out:glyph(st, nx, ny, hname, colour)
          out.heads[#out.heads + 1] = { x = nx + hw / 2, y = ny, index = n.index, id = n.id, step = n.step, start = ev.start, staff = staff,
            base = ev.base, glyph = hname, gx = nx }
          if n.acc then
            local name = ACC_GLYPH[n.acc]
            local ax = acc_left - acc_at[i]
            if n.courtesy then
              local lw = gwidth(st, "accidentalParensLeft")
              out:glyph(st, round(ax), round(ny), "accidentalParensLeft", st.faint)
              out:glyph(st, round(ax + lw), round(ny), name, st.faint)
              out:glyph(st, round(ax + lw + gwidth(st, name)), round(ny), "accidentalParensRight", st.faint)
            else
              out:glyph(st, round(ax), round(ny), name, colour)
            end
          end
          for d = 1, ev.dots do
            local dy = n.pos % 2 == 0 and Y(n.pos + 1) or ny
            local dx = hx + hw + ((any_shift and dir > 0) and side or 0) + (0.35 + 0.5 * (d - 1)) * s
            out:glyph(st, round(dx), round(dy), "augmentationDot", colour)
          end
          if n.tie and ev.next and ev.next.measure == ev.measure then
            local tdir, outside = tie_side(ev, i)
            local x0, x1, y = tie_ends(st, hw, nx, round(xt(ev.next.start) - hw / 2), ny, tdir, outside, ev.dots > 0)
            tie(out, st, x0, x1, y, tdir, colour)
          end
        end
        -- Grace notes, the arpeggio and articulations.
        local left = acc_left - acc_room - 0.4 * s
        if ev.arpeggio then
          local y0, y1 = Y(high) - 0.6 * s, Y(low) + 0.6 * s
          local ax = left - 0.3 * s
          local pts = { "M", ax, y1 }
          local k, yy = 0, y1
          while yy > y0 do
            yy = yy - 0.5 * s
            k = k + 1
            pts[#pts + 1] = "L"
            pts[#pts + 1] = ax + (k % 2 == 1 and 0.3 or -0.3) * s
            pts[#pts + 1] = yy
          end
          out:path(pts, colour, max(1, 0.13 * s))
          local tipy = ev.arpeggio > 0 and yy or y1
          local d = ev.arpeggio > 0 and 1 or -1
          out:path({ "M", ax - 0.45 * s, tipy + d * 0.6 * s, "L", ax, tipy, "L", ax + 0.45 * s, tipy + d * 0.6 * s }, colour, max(1, 0.13 * s))
          left = left - 1.1 * s
        end
        if ev.grace then
          local scale = 0.66
          local gw = head_w * scale
          for gi = #ev.grace, 1, -1 do
            local gn = ev.grace[gi]
            local gx, gy = round(left - gw), Y(gn.pos)
            for pos = -2, gn.pos, -2 do out:rect(round(gx - 0.25 * s), round(Y(pos) - st.ledger / 2), round(gw + 0.5 * s), st.ledger, colour) end
            for pos = 10, gn.pos, 2 do out:rect(round(gx - 0.25 * s), round(Y(pos) - st.ledger / 2), round(gw + 0.5 * s), st.ledger, colour) end
            out:glyph(st, gx, gy, "noteheadBlack", colour, scale)
            local sx = gx + round(stem_up_x * scale) - st.stem
            local tip = round(gy - 2.5 * s)
            out:rect(sx, tip, st.stem, round(gy) - tip, colour)
            out:glyph(st, sx, tip, "flag8thUp", colour, scale)
            out:path({ "M", sx - 0.5 * s, gy - 0.9 * s, "L", sx + 0.8 * s, gy - 2.0 * s }, colour, max(1, 0.1 * s))
            left = gx - 0.5 * s
            if gn.acc then
              local name = ACC_GLYPH[gn.acc]
              local aw = gwidth(st, name, scale)
              out:glyph(st, round(gx - aw - 0.15 * s), round(gy), name, colour, scale)
              left = left - aw - 0.15 * s
            end
          end
        end
        do
          -- Articulations on the side away from the stem, nearest first,
          -- in the spaces.
          local up = dir > 0
          local d = up and 1 or -1
          local pos = up and low - 2 or high + 2
          if pos % 2 == 0 and pos >= 0 and pos <= 8 then pos = pos - d end
          local cx = hx + hw / 2
          local art = ev.art or {}
          local function mark(name)
            local gn = name .. (up and "Below" or "Above")
            local gw2 = gwidth(st, gn)
            out:glyph(st, round(cx - gw2 / 2), round(Y(pos)), gn, colour)
            pos = pos - d * 2
            if pos >= 0 and pos <= 8 and pos % 2 == 0 then pos = pos - d end
          end
          if ev.staccato or art.staccato then mark("articStaccato") end
          if art.tenuto then mark("articTenuto") end
          if art.accent then mark("articAccent") end
          if art.marcato then mark("articMarcato") end
        end
        if ev.lyric and staff == 1 then
          out:text(round(ex - 0.6 * s), round(Y(-2) + 2.6 * s), ev.lyric, st.ink, max(10, round(1.3 * s)))
        end
        -- Stem, then flags when nothing beams it.
        if ev.stem then
          local sx = stem_x(ev, dir)
          local anchor = dir > 0 and glyph(st, hname).anchors and glyph(st, hname).anchors.stemUpSE
          local base_y = dir > 0 and Y(low) - (anchor and anchor[2] or 0.16) * s or Y(high) + 0.17 * s
          local tip
          local b = ev.beam and beams[ev.beam]
          if b then
            tip = b.line.at(sx + st.stem / 2)
          else
            local len = 3.5 * s + ((ev.flags or 0) >= 2 and (ev.flags - 1) * 0.5 * s or 0)
            tip = dir > 0 and min(Y(high) - len, Y(4)) or max(Y(low) + len, Y(4))
          end
          local y0, y1 = round(min(base_y, tip)), round(max(base_y, tip))
          out:rect(sx, y0, st.stem, y1 - y0, colour)
          if not b and (ev.flags or 0) > 0 then
            local name = FLAG_GLYPH[min(4, ev.flags)] .. (dir > 0 and "Up" or "Down")
            out:glyph(st, sx, round(tip), name, colour)
          end
        end
      end
    end

    -- Tuplets. A group under one beam of its own has only its number, on
    -- the beam's side, past the beam's middle; any other has a bracket
    -- from its first head's left edge to its last head's right edge on the
    -- stems' side, clear of them, with the number in a gap in the middle.
    local tuplets = {}
    for _, ev in ipairs(evs) do
      if ev.tuplet then
        local tp = tuplets[ev.tuplet] or { events = {}, up = 0 }
        tp.events[#tp.events + 1] = ev
        if ev.kind == "note" then tp.up = tp.up + ((ev.stem or 1) > 0 and 1 or -1) end
        tuplets[ev.tuplet] = tp
      end
    end
    for span, tp in pairs(tuplets) do
      local first, last = tp.events[1], tp.events[#tp.events]
      local name = "tuplet" .. tostring(span.n)
      local nw = gwidth(st, name)
      local nh = glyph(st, name).bbox[4] * s
      local b = first.beam and beams[first.beam]
      if b and #b.events == #tp.events and last.beam == first.beam then
        local mid = (stem_x(first, b.dir) + stem_x(last, b.dir) + st.stem) / 2
        local edge = b.line.at(mid)
        local base = b.dir > 0 and edge - 0.4 * s or edge + 0.4 * s + nh
        out:glyph(st, round(mid - nw / 2), round(base), name, colour)
      else
        local up = tp.up >= 0
        local x0, x1 = head_x(first), head_x(last) + round(head_w)
        local edge = up and Y(10) or Y(-2)
        for _, ev in ipairs(tp.events) do
          for _, n in ipairs(ev.notes or {}) do
            if up then edge = min(edge, Y(n.pos) - 4.4 * s) else edge = max(edge, Y(n.pos) + 4.4 * s) end
          end
        end
        edge = round(edge)
        local hook = round(up and 0.5 * s or -0.5 * s)
        local mid = (x0 + x1) / 2
        local th = st.bracket
        out:rect(x0, min(edge, edge + hook), th, abs(hook), st.faint)
        out:rect(x0, edge, round(mid - nw / 2 - 0.3 * s) - x0, th, st.faint)
        out:rect(round(mid + nw / 2 + 0.3 * s), edge, x1 - round(mid + nw / 2 + 0.3 * s), th, st.faint)
        out:rect(x1 - th, min(edge, edge + hook), th, abs(hook), st.faint)
        out:glyph(st, round(mid - nw / 2), round(edge + nh / 2), name, colour)
      end
    end

    -- Beams: the first joins every note of the group, the others the
    -- notes short enough for them, with a stub where one stands alone.
    for _, b in pairs(beams) do
      local list, line = b.events, b.line
      local th = st.beam
      for level = 1, 4 do
        -- Beams a whole number of pixels apart, the font's gap between them.
        local off = (level - 1) * (th + st.beam_gap) * b.dir
        for i, ev in ipairs(list) do
          if (ev.flags or 0) >= level then
            local xa = stem_x(ev, b.dir)
            local nxt, prev = list[i + 1], list[i - 1]
            local function draw(x0, x1)
              local y0, y1 = line.at(x0) + off, line.at(x1) + off
              if b.dir < 0 then y0, y1 = y0 - th, y1 - th end
              out:path({ "M", x0, y0, "L", x1, y1, "L", x1, y1 + th, "L", x0, y0 + th, "Z" }, "", 1, colour)
            end
            if nxt and (nxt.flags or 0) >= level then
              draw(xa, stem_x(nxt, b.dir) + st.stem)
            elseif not (prev and (prev.flags or 0) >= level) and level > 1 then
              if nxt then draw(xa, xa + 1.1 * s) else draw(xa + st.stem - 1.1 * s, xa + st.stem) end
            end
          end
        end
      end
    end
  end

  -- Dynamics and hairpins under the first staff, text over it.
  local Y1 = Ys(1)
  for _, mk in ipairs(m.marks or {}) do
    local mxp = xt(mk.at)
    local under = Y1(0) + 3.0 * s
    if mk.kind == "dyn" then
      local name = DYN_GLYPH[mk.value]
      if name then
        out:glyph(st, round(mxp - head_w / 2), round(under + 0.5 * s), name, colour)
      else
        out:text(round(mxp), round(under - 0.8 * s), mk.value, colour, round(1.6 * s), true)
      end
    elseif mk.kind == "cresc" or mk.kind == "dim" then
      local x1 = mk.to >= m.start + m.length - EPS and w - 0.6 * s or xt(mk.to)
      local open, shut = mk.kind == "cresc" and x1 or mxp, mk.kind == "cresc" and mxp or x1
      out:path({ "M", open, under - 0.55 * s, "L", shut, under, "L", open, under + 0.55 * s }, colour, st.hairpin)
    elseif mk.kind == "text" then
      out:text(round(mxp), round(top_y - 3 * s), tostring(mk.value), st.ink, round(1.4 * s), true)
    end
  end
  if m.repeat_start or m.repeat_end then
    for staff = 1, nstaves do
      local Y = Ys(staff)
      local t0, t1 = round(Y(8) - st.line / 2), round(Y(0) + st.line / 2)
      local dot_w = gwidth(st, "repeatDot")
      if m.repeat_start then
        out:rect(0, t0, st.thick, t1 - t0, colour)
        out:rect(st.thick + st.bar_gap, t0, st.bar, t1 - t0, colour)
        local dx = round(st.thick + st.bar_gap + st.bar + st.dot_gap)
        out:glyph(st, dx, round(Y(5)), "repeatDot", colour)
        out:glyph(st, dx, round(Y(3)), "repeatDot", colour)
      end
      if m.repeat_end then
        local x = round(w) - st.thick
        out:rect(x, t0, st.thick, t1 - t0, colour)
        out:rect(x - st.bar_gap - st.bar, t0, st.bar, t1 - t0, colour)
        local dx = round(x - st.bar_gap - st.bar - st.dot_gap - dot_w)
        out:glyph(st, dx, round(Y(5)), "repeatDot", colour)
        out:glyph(st, dx, round(Y(3)), "repeatDot", colour)
      end
    end
  end

  -- Tablature: fret numbers on a patch that breaks the string line.
  local tab = layout.tab
  if tab and sys.tab_top then
    local function ty(i) return sys.tab_top - sys_y + (i - 1) * sys.tab_line end
    for k = 1, nstaves do
      for _, ev in ipairs(m.staves[k] or {}) do
        if ev.kind == "note" then
          for _, n in ipairs(ev.notes) do
            if n.string and not n.tied then
              local label = tostring(n.fret)
              local size = max(9, round(1.25 * s))
              local fw = round((#label * 0.62 + 0.25) * size)
              local fx, fy = xt(ev.start), ty(n.string)
              out:rect(round(fx - fw / 2), round(fy - size * 0.45), fw, round(size * 0.9), st.paper)
              out:text(round(fx), round(fy - size * 0.62), label, colour, size, false, "center", fw + 4)
            end
          end
        end
      end
    end
  end
  return out
end

--- A measure's ink, kept by its signature while the style holds.
function E.measure(cache, st, layout, sys, placed)
  local sig = signature(placed.m, placed, sys, layout)
  local hit = cache[sig]
  if hit then
    hit.used = cache.generation
    return hit
  end
  local made = measure_ink(st, layout, sys, placed)
  made.used = cache.generation
  cache[sig] = made
  cache.count = (cache.count or 0) + 1
  return made
end

--- Forget measures not used for a while.
function E.sweep(cache)
  if (cache.count or 0) < 400 then return end
  local keep = 0
  for k, v in pairs(cache) do
    if type(v) == "table" and v.used then
      if v.used < cache.generation - 2 then cache[k] = nil else keep = keep + 1 end
    end
  end
  cache.count = keep
end

-- What starts and spans a system -------------------------------------------------------------

--- The system's own ink, in coordinates from the page's left edge and the
--- system's top, as two parts: what starts it (staff lines up to the
--- first measure, the left barline and brace, clefs, key and time
--- signatures, names, the first measure's number), which the galley keeps
--- at the left; and what spans its measures (time signatures that change
--- inside it, ties across barlines, and slurs).
function E.system_ink(st, layout, sys, eng)
  local s, out, spans = st.sp, ink(), ink()
  local colour = st.ink
  local nstaves = #layout.staves
  local sy = sys.y
  local function Y(staff, pos) return E.y_of(st, sys, staff, pos) - sy end
  local left = eng.left
  local right = sys.measures[1].x
  local top_y, bottom_y = round(Y(1, 8) - st.line / 2), round(Y(nstaves, 0) + st.line / 2)
  for staff, clef in ipairs(layout.staves) do
    for pos = 0, 8, 2 do
      out:rect(left, round(Y(staff, pos) - st.line / 2), right - left, st.line, st.staff)
    end
    if layout.names and layout.names[staff] and layout.names[staff] ~= "" then
      out:text(left, round(Y(staff, 8) - 2.4 * s), layout.names[staff], st.faint, max(10, round(1.1 * s)))
    end
    local cx = round(left + 0.6 * s)
    if clef == "bass" then
      out:glyph(st, cx, round(Y(staff, 6)), "fClef", colour)
    elseif clef == "treble8" then
      out:glyph(st, cx, round(Y(staff, 2)), "gClef8vb", colour)
    else
      out:glyph(st, cx, round(Y(staff, 2)), "gClef", colour)
    end
    local x = cx + gwidth(st, "gClef") + 0.8 * s
    local fifths = layout.fifths
    if fifths ~= 0 then
      local list = fifths > 0 and SHARP_POS or FLAT_POS
      local name = fifths > 0 and "accidentalSharp" or "accidentalFlat"
      for i = 1, abs(fifths) do
        local pos = list[i] - (clef == "bass" and 2 or 0)
        out:glyph(st, round(x), round(Y(staff, pos)), name, colour)
        x = x + gwidth(st, name) + 0.12 * s
      end
      x = x + 0.6 * s
    end
    local first = sys.measures[1].m
    if meter_changes(layout, first.index) then
      local tw = time_width(st, first.meter)
      for k, digits in ipairs({ tostring(first.meter.num), tostring(first.meter.den) }) do
        local dw = 0
        for ch in digits:gmatch("%d") do dw = dw + gwidth(st, "timeSig" .. ch) end
        local dx = x + (tw - dw) / 2
        for ch in digits:gmatch("%d") do
          out:glyph(st, round(dx), round(Y(staff, k == 1 and 6 or 2)), "timeSig" .. ch, colour)
          dx = dx + gwidth(st, "timeSig" .. ch)
        end
      end
    end
  end
  out:rect(left, top_y, st.bar, bottom_y - top_y, colour)
  if nstaves >= 2 and not layout.names then
    -- A grand staff's brace.
    local h = bottom_y - top_y
    out:glyph(st, round(left - 0.4 * s - gwidth(st, "brace") * h / (4 * s)), bottom_y, "brace", colour, h / (4 * s))
  end
  local tab = layout.tab
  if tab and sys.tab_top then
    local t0 = sys.tab_top - sy
    for i = 1, tab.strings do out:rect(left, t0 + (i - 1) * sys.tab_line, right - left, st.line, st.staff) end
    out:rect(left, t0, st.bar, (tab.strings - 1) * sys.tab_line + st.line, colour)
    local mid = t0 + (tab.strings - 1) * sys.tab_line / 2
    for k, letter in ipairs({ "T", "A", "B" }) do
      out:text(round(left + 0.9 * s), round(mid + (k - 2.5) * 1.4 * s), letter, colour, round(1.3 * s), true)
    end
  end
  local first = sys.measures[1]
  -- The bar's number at the top of the system, over whatever reaches above the staff.
  out:text(round(left), 1, tostring(first.m.number), st.muted, max(9, round(1.0 * s)))
  -- Time signatures that change inside the system.
  for k = 2, #sys.measures do
    local placed = sys.measures[k]
    if meter_changes(layout, placed.m.index) then
      for staff = 1, nstaves do
        local dx = placed.x + 0.5 * s
        for row, digits in ipairs({ tostring(placed.m.meter.num), tostring(placed.m.meter.den) }) do
          local x = dx
          for ch in digits:gmatch("%d") do
            spans:glyph(st, round(x), round(Y(staff, row == 1 and 6 or 2)), "timeSig" .. ch, colour)
            x = x + gwidth(st, "timeSig" .. ch)
          end
        end
      end
    end
  end

  -- Ties that cross a barline, and slurs: they belong to two measures.
  local where = {}
  for _, placed in ipairs(sys.measures) do where[placed.m.index] = placed end
  for k, placed in ipairs(sys.measures) do
    local m = placed.m
    local function xt(beat) return placed.x + model.x_of(placed.p, beat) end
    for staff = 1, nstaves do
      for ei, ev in ipairs(m.staves[staff] or {}) do
        if ev.notes then
          local hw = gwidth(st, HEAD_GLYPH(ev.base))
          for i, n in ipairs(ev.notes) do
            local dir, outside = tie_side(ev, i)
            local hx = round(xt(ev.start) - hw / 2)
            if n.tie and ev.next and ev.next.measure ~= ev.measure then
              local target = where[ev.next.measure]
              local nx = target and round(target.x + model.x_of(target.p, ev.next.start) - hw / 2)
              local x0, x1, y = tie_ends(st, hw, hx, nx, Y(staff, n.pos), dir, outside, ev.dots > 0)
              tie(spans, st, x0, x1 or (sys.width + 0.3 * s), y, dir, colour)
            end
            if n.tied and k == 1 and ei == 1 then
              -- A tie from the system before ends here.
              local _, x1, y = tie_ends(st, hw, hx, hx, Y(staff, n.pos), dir, outside, false)
              tie(spans, st, placed.x - 0.4 * s, x1, y, dir, colour)
            end
          end
          if ev.slur_to then
            local last = ev.slur_to
            local x0 = xt(ev.start)
            local target = where[last.measure]
            local x1 = target and (target.x + model.x_of(target.p, last.start)) or (sys.width - 0.5 * s)
            local above = (ev.stem or 1) < 0
            local d = above and -1 or 1
            local p0 = above and ev.notes[#ev.notes].pos or ev.notes[1].pos
            local p1 = last.notes and (above and last.notes[#last.notes].pos or last.notes[1].pos) or p0
            local y0, y1 = Y(staff, p0) + d * 0.9 * s, Y(staff, p1) + d * 0.9 * s
            local bow = min(2.0 * s, 0.6 * s + (x1 - x0) * 0.08)
            arc(spans, x0, y0, x1, y1, bow, d, st.slur_end, st.slur_mid, colour)
          end
        end
      end
    end
  end
  return out, spans
end

return E
