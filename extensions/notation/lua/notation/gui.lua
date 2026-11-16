-- The staff in a window: the same measures as the terminal's, engraved in
-- pixels through `daw.canvas`. Every symbol is drawn here as path data,
-- so nothing depends on a music font being installed.
--
--   toolbar   the clip; the value to enter (whole to 32nd), dot, rest, the
--             accidental to enter with; zoom
--   staves    systems of measures down the window, as a page is laid out
--   info      what is under the cursor, or what the pointer does
--
-- A click on the staff puts a note of the chosen value there (or a rest
-- clears that stretch); drag a note to move it in time and up or down the
-- staff; right click removes it. The wheel scrolls, with Ctrl it zooms.
-- Every key of the terminal view works in the window too.
local api = daw.api
local util = daw.util
local model = require("notation.model")
local view = require("notation")

local c = require("daw.canvas").palette
local floor, sqrt, cos, sin, rad = math.floor, math.sqrt, math.cos, math.sin, math.rad
local EPS = 1e-6
local TOOLBAR, INFO = 44, 26

local gui = { scroll = 0, drag = nil, buttons = {}, heads = {}, accidental = nil, rest = false }
view.gui = gui
view.gui_zoom = 1.25

local function sp() return 10 * view.gui_zoom end

-- Drawing in path data ---------------------------------------------------------------------

local function fmt(v) return string.format("%.2f", v) end

--- A path from commands with coordinates in the painter's own space:
--- `{ "M", x, y, "C", x1, y1, x2, y2, x, y, "L", x, y, "Z" }`.
local function path(g, cmds, style)
  local ox, oy = g:origin_x(), g:origin_y()
  local out, i, axis = {}, 1, 0
  while i <= #cmds do
    local v = cmds[i]
    if type(v) == "string" then
      out[#out + 1] = v
      axis = 0
    else
      out[#out + 1] = fmt(v + (axis == 0 and ox or oy))
      axis = 1 - axis
    end
    i = i + 1
  end
  g.ops[#g.ops + 1] = { "p", table.concat(out, " "), style.stroke or "", style.width or 1, style.fill or "" }
end

--- An ellipse at `x, y`, turned by `angle` degrees.
local function ellipse(g, x, y, rx, ry, angle, fill)
  local k = 0.5523
  local a = rad(angle or 0)
  local ca, sa = cos(a), sin(a)
  local function pt(u, v) return x + u * ca - v * sa, y + u * sa + v * ca end
  local p = {}
  local function add(...)
    for _, v in ipairs({ ... }) do p[#p + 1] = v end
  end
  local x0, y0 = pt(rx, 0)
  add("M", x0, y0)
  local quads = {
    { rx, k * ry, k * rx, ry, 0, ry }, { -k * rx, ry, -rx, k * ry, -rx, 0 },
    { -rx, -k * ry, -k * rx, -ry, 0, -ry }, { k * rx, -ry, rx, -k * ry, rx, 0 },
  }
  for _, q in ipairs(quads) do
    local ax, ay = pt(q[1], q[2])
    local bx, by = pt(q[3], q[4])
    local cx2, cy2 = pt(q[5], q[6])
    add("C", ax, ay, bx, by, cx2, cy2)
  end
  add("Z")
  path(g, p, { fill = fill })
end

local function line(g, x0, y0, x1, y1, colour, width)
  path(g, { "M", x0, y0, "L", x1, y1 }, { stroke = colour, width = width })
end

local function quad(g, x0, y0, x1, y1, t, colour)
  path(g, { "M", x0, y0, "L", x1, y1, "L", x1, y1 + t, "L", x0, y0 + t, "Z" }, { fill = colour })
end

-- The symbols, drawn at a staff space `s` ----------------------------------------------------

local glyph = {}

function glyph.head(g, x, y, s, base, colour, bg)
  if base >= 4 then
    ellipse(g, x, y, 0.78 * s, 0.47 * s, 0, colour)
    ellipse(g, x, y, 0.34 * s, 0.3 * s, 55, bg)
  elseif base >= 2 then
    ellipse(g, x, y, 0.62 * s, 0.42 * s, -20, colour)
    ellipse(g, x, y, 0.5 * s, 0.2 * s, -32, bg)
  else
    ellipse(g, x, y, 0.62 * s, 0.42 * s, -20, colour)
  end
end

function glyph.sharp(g, x, y, s, colour)
  line(g, x - 0.22 * s, y - 1.25 * s, x - 0.22 * s, y + 1.35 * s, colour, 0.11 * s)
  line(g, x + 0.22 * s, y - 1.35 * s, x + 0.22 * s, y + 1.25 * s, colour, 0.11 * s)
  quad(g, x - 0.52 * s, y - 0.32 * s, x + 0.52 * s, y - 0.62 * s, 0.24 * s, colour)
  quad(g, x - 0.52 * s, y + 0.5 * s, x + 0.52 * s, y + 0.2 * s, 0.24 * s, colour)
end

function glyph.flat(g, x, y, s, colour)
  line(g, x - 0.3 * s, y - 1.75 * s, x - 0.3 * s, y + 0.55 * s, colour, 0.11 * s)
  path(g, { "M", x - 0.3 * s, y + 0.55 * s, "C", x + 0.35 * s, y + 0.1 * s, x + 0.75 * s, y - 0.25 * s, x + 0.4 * s, y - 0.45 * s,
    "C", x + 0.15 * s, y - 0.6 * s, x - 0.15 * s, y - 0.4 * s, x - 0.3 * s, y - 0.2 * s,
    "L", x - 0.3 * s, y + 0.1 * s, "C", x - 0.1 * s, y - 0.25 * s, x + 0.2 * s, y - 0.35 * s, x + 0.3 * s, y - 0.2 * s,
    "C", x + 0.4 * s, y - 0.0 * s, x + 0.1 * s, y + 0.25 * s, x - 0.3 * s, y + 0.55 * s, "Z" }, { fill = colour })
end

function glyph.natural(g, x, y, s, colour)
  line(g, x - 0.25 * s, y - 1.3 * s, x - 0.25 * s, y + 0.5 * s, colour, 0.11 * s)
  line(g, x + 0.25 * s, y - 0.5 * s, x + 0.25 * s, y + 1.3 * s, colour, 0.11 * s)
  quad(g, x - 0.25 * s, y - 0.32 * s, x + 0.25 * s, y - 0.5 * s, 0.22 * s, colour)
  quad(g, x - 0.25 * s, y + 0.42 * s, x + 0.25 * s, y + 0.24 * s, 0.22 * s, colour)
end

function glyph.accidental(g, alter, x, y, s, colour)
  if alter == 1 then
    glyph.sharp(g, x, y, s, colour)
  elseif alter == -1 then
    glyph.flat(g, x, y, s, colour)
  elseif alter == 0 then
    glyph.natural(g, x, y, s, colour)
  elseif alter == 2 then
    line(g, x - 0.35 * s, y - 0.35 * s, x + 0.35 * s, y + 0.35 * s, colour, 0.18 * s)
    line(g, x - 0.35 * s, y + 0.35 * s, x + 0.35 * s, y - 0.35 * s, colour, 0.18 * s)
  elseif alter == -2 then
    glyph.flat(g, x - 0.35 * s, y, s, colour)
    glyph.flat(g, x + 0.35 * s, y, s, colour)
  end
end

--- A treble clef with its curl round the G line at `y`.
function glyph.treble(g, x, y, s, colour)
  local pts = {
    "M", 0.15, 0.55,
    "C", -0.75, 0.45, -0.7, -0.75, 0.2, -0.8,
    "C", 1.15, -0.8, 1.25, 0.9, 0.2, 1.1,
    "C", -1.0, 1.25, -1.35, -0.2, -0.6, -1.0,
    "C", 0.0, -1.7, 0.85, -2.3, 0.75, -3.4,
    "C", 0.7, -4.4, 0.0, -4.5, -0.05, -3.6,
    "C", -0.15, -2.6, 0.35, 0.6, 0.45, 2.3,
    "C", 0.5, 3.1, -0.2, 3.3, -0.45, 2.75,
  }
  local cmds = {}
  local axis = 0
  for _, v in ipairs(pts) do
    if type(v) == "string" then
      cmds[#cmds + 1] = v
      axis = 0
    else
      cmds[#cmds + 1] = axis == 0 and x + v * s or y + v * s
      axis = 1 - axis
    end
  end
  path(g, cmds, { stroke = colour, width = 0.2 * s })
  ellipse(g, x - 0.3 * s, y + 2.6 * s, 0.28 * s, 0.28 * s, 0, colour)
end

--- A bass clef with its head on the F line at `y`.
function glyph.bass(g, x, y, s, colour)
  ellipse(g, x + 0.05 * s, y, 0.33 * s, 0.33 * s, 0, colour)
  path(g, { "M", x - 0.2 * s, y, "C", x - 0.2 * s, y - 1.0 * s, x + 1.5 * s, y - 1.25 * s, x + 1.65 * s, y - 0.15 * s,
    "C", x + 1.8 * s, y + 1.1 * s, x + 0.9 * s, y + 2.1 * s, x - 0.35 * s, y + 2.7 * s }, { stroke = colour, width = 0.24 * s })
  ellipse(g, x + 2.15 * s, y - 0.5 * s, 0.15 * s, 0.15 * s, 0, colour)
  ellipse(g, x + 2.15 * s, y + 0.5 * s, 0.15 * s, 0.15 * s, 0, colour)
end

--- A flag hanging from a stem's tip; `dir` 1 for a stem up.
function glyph.flag(g, x, y, s, dir, colour)
  local d = dir
  path(g, { "M", x, y, "C", x + 0.1 * s, y + d * 1.0 * s, x + 1.25 * s, y + d * 1.3 * s, x + 0.95 * s, y + d * 2.9 * s,
    "C", x + 1.05 * s, y + d * 1.8 * s, x + 0.35 * s, y + d * 1.55 * s, x, y + d * 1.1 * s, "Z" }, { fill = colour })
end

--- A rest of a value, centred across at `x`; `y` is where the middle line is.
function glyph.rest(g, base, x, y, s, colour)
  if base >= 4 then
    g:rect(x - 0.6 * s, y - 1.0 * s, 1.2 * s, 0.5 * s, { fill = colour })
  elseif base >= 2 then
    g:rect(x - 0.6 * s, y - 0.5 * s, 1.2 * s, 0.5 * s, { fill = colour })
  elseif base >= 1 then
    path(g, { "M", x - 0.25 * s, y - 1.5 * s, "L", x + 0.35 * s, y - 0.75 * s, "L", x - 0.15 * s, y - 0.1 * s, "L", x + 0.35 * s, y + 0.55 * s,
      "C", x - 0.2 * s, y + 0.3 * s, x - 0.45 * s, y + 0.8 * s, x + 0.05 * s, y + 1.4 * s }, { stroke = colour, width = 0.26 * s })
  else
    local n = model.flags(base)
    local top = y - 0.5 * s
    for i = 1, n do
      local yy = top + (i - 1) * 0.9 * s
      local xx = x + (i - 1) * -0.2 * s
      ellipse(g, xx - 0.3 * s, yy, 0.22 * s, 0.22 * s, 0, colour)
      path(g, { "M", xx - 0.4 * s, yy + 0.1 * s, "C", xx - 0.1 * s, yy + 0.35 * s, xx + 0.3 * s, yy + 0.2 * s, xx + 0.5 * s, yy - 0.15 * s }, { stroke = colour, width = 0.13 * s })
    end
    line(g, x + 0.5 * s, top - 0.15 * s, x - 0.1 * s - (n - 1) * 0.25 * s, top + (n * 0.9 + 0.9) * s, colour, 0.13 * s)
  end
end

view.glyph = glyph

-- Layout in pixels -------------------------------------------------------------------------

local SHARP_POS = { 8, 5, 9, 6, 3, 7, 4 }
local FLAT_POS = { 4, 7, 3, 6, 2, 5, 1 }

--- Systems of measures across a window `width` wide, with where each staff is.
function view:engrave(layout, width)
  local s = sp()
  model.space(layout, {
    lead = 1.6 * s, acc = 1.3 * s, grace = 1.4 * s, tail = 0.8 * s,
    unit = function(d) return s * (1.3 + 1.7 * sqrt(d / 0.25)) end,
  })
  local fifths = layout.fifths
  local staves = #layout.staves
  local left = 0.8 * s
  local function meter_changes(i)
    local before = layout.measures[i - 1]
    return i == 1 or (before and before.meter ~= layout.measures[i].meter)
  end
  view.meter_changes = meter_changes
  local function prefix(i) return left + 4.2 * s + math.abs(fifths) * 1.05 * s + (meter_changes(i) and 2.8 * s or 0.4 * s) end
  local systems, i = {}, 1
  local pad, gap, staff_h = 4.5 * s, 7 * s, 4 * s
  local tab = layout.tab
  local tab_gap, tab_line = 6 * s, 1.5 * s
  local height = pad * 2 + staves * staff_h + (staves - 1) * gap + (tab and (tab_gap + (tab.strings - 1) * tab_line) or 0)
  local y = TOOLBAR + 0.6 * s
  while i <= #layout.measures do
    local sys = { measures = {}, x0 = prefix(i), y = y, height = height }
    local x = sys.x0
    repeat
      local m = layout.measures[i]
      if #sys.measures > 0 and x + m.width > width - left then break end
      sys.measures[#sys.measures + 1] = { m = m, x = x }
      x = x + m.width
      i = i + 1
    until i > #layout.measures
    -- Every system but the last is spread to the full width, as on a page.
    if i <= #layout.measures and x < width - left then
      local used = x - sys.x0
      local factor = (width - left - sys.x0) / math.max(1, used)
      x = sys.x0
      for _, placed in ipairs(sys.measures) do
        local m = placed.m
        for _, slot in ipairs(m.slots) do slot.x = slot.x * factor end
        m.width = m.width * factor
        placed.x = x
        x = x + m.width
      end
    end
    sys.width = x
    -- Room above and below each staff for what reaches past it: notes on
    -- ledger lines and their stems.
    local above, below = {}, {}
    for st = 1, staves do above[st], below[st] = 8, 0 end
    for _, placed in ipairs(sys.measures) do
      for st = 1, staves do
        for _, ev in ipairs(placed.m.staves[st]) do
          for _, n in ipairs(ev.notes or {}) do
            local stem = ev.stem or 0
            above[st] = math.max(above[st], n.pos + (stem > 0 and 7 or 1))
            below[st] = math.min(below[st], n.pos - (stem < 0 and 7 or 1))
          end
        end
      end
    end
    local function over(st) return math.max(0, (above[st] - 8) / 2 * s) end
    local function under(st) return math.max(0, -below[st] / 2 * s) end
    sys.staff_top = {}
    local top = y + math.max(pad, over(1) + 2.2 * s)
    for st = 1, staves do
      if st > 1 then top = top + staff_h + math.max(gap, under(st - 1) + over(st) + 1.5 * s) end
      sys.staff_top[st] = top
    end
    local bottom = sys.staff_top[staves] + staff_h
    if tab then
      sys.tab_top, sys.tab_line = bottom + math.max(tab_gap, under(staves) + 2 * s), tab_line
      bottom = sys.tab_top + (tab.strings - 1) * tab_line
      sys.height = bottom + pad - y
    else
      sys.height = bottom + math.max(pad, under(staves) + 2 * s) - y
    end
    systems[#systems + 1] = sys
    y = y + sys.height
  end
  return { systems = systems, s = s, left = left, total = y }
end

--- The y of a staff position (0 the bottom line, 8 the top) on a staff.
local function y_of(sys, staff, pos, s) return sys.staff_top[staff] + (8 - pos) * s / 2 end

-- Painting -----------------------------------------------------------------------------------

local VALUE_BUTTONS = { 4, 2, 1, 0.5, 0.25, 0.125 }

local function button(g, x, w, label, on, action, draw)
  g:rect(x, 9, w, 26, { fill = on and c.select or c.control, radius = 5 })
  if draw then
    draw(x + w / 2, 22, on and c.surface or c.text)
  else
    g:text(x, 15, label, { color = on and c.surface or c.text, bold = on, align = "center", width = w })
  end
  gui.buttons[#gui.buttons + 1] = { x = x, y = 9, w = w, h = 26, action = action, label = label }
  return x + w + 5
end

function view:paint(g, ctx)
  local w, h = ctx.width, ctx.height
  gui.buttons, gui.heads = {}, {}
  g:rect(0, 0, w, h, { fill = c.surface })
  local clip = self:clip()
  if not clip then
    g:text(24, 24, "No clip is open as notation.", { color = c.text, size = 16, bold = true })
    g:text(24, 50, "Right click a MIDI clip and choose Open as notation, or put the cursor on one and type ,n.", { color = c.text_2 })
    return
  end
  local data = clip:get()
  local track = api.track_get(data.track)
  local colour = daw.draw.track_colour(track)
  local layout = self:layout()
  local eng = self:engrave(layout, w)
  gui.engraved, gui.size = eng, { w = w, h = h }
  local s = eng.s
  local fifths = layout.fifths
  local ink, faint = colour, c.text_2

  -- Keep the cursor's system in view.
  local view_h = h - TOOLBAR - INFO
  local playing = api.transport_get().playing
  local _, cursor_measure = self:measure_at(self:follow_beat(), layout)
  if playing then gui.follow = true end
  for _, sys in ipairs(eng.systems) do
    for _, placed in ipairs(sys.measures) do
      if placed.m.index == cursor_measure and gui.follow ~= false then
        if sys.y - TOOLBAR - gui.scroll < 0 then gui.scroll = sys.y - TOOLBAR - 0.6 * s end
        if sys.y + sys.height - TOOLBAR - gui.scroll > view_h then gui.scroll = sys.y + sys.height - TOOLBAR - view_h end
      end
    end
  end
  gui.scroll = util.clamp(gui.scroll, 0, math.max(0, eng.total - TOOLBAR - view_h + s))
  gui.follow = true
  local page = g:sub(0, -gui.scroll, w, h + gui.scroll + eng.total)

  local _, under_index, under_written = self:note()
  local t = api.transport_get()
  local selection = ctx.focused and daw.keymap.selection()

  for _, sys in ipairs(eng.systems) do
    if sys.y + sys.height - gui.scroll >= TOOLBAR and sys.y - gui.scroll <= h - INFO then
      local staves = #layout.staves
      local top_y, bottom_y = y_of(sys, 1, 8, s), y_of(sys, staves, 0, s)
      -- Staff lines and the system's left edge.
      for st, clef in ipairs(layout.staves) do
        for pos = 0, 8, 2 do
          local y = y_of(sys, st, pos, s)
          line(page, eng.left, y, sys.width, y, c.text_3, math.max(1, 0.1 * s))
        end
        local cx = eng.left + 1.6 * s
        if layout.names and layout.names[st] ~= "" then
          page:text(eng.left, y_of(sys, st, 8, s) - 2.6 * s, layout.names[st], { color = c.text_2, size = math.max(10, 1.1 * s) })
        end
        if clef == "bass" then
          glyph.bass(page, cx - 0.5 * s, y_of(sys, st, 6, s), s, ink)
        else
          glyph.treble(page, cx, y_of(sys, st, 2, s), s, ink)
          if clef == "treble8" then page:text(cx - 0.75 * s, y_of(sys, st, 0, s) + 2.3 * s, "8", { color = ink, size = 1.2 * s, bold = true }) end
        end
        local list = fifths > 0 and SHARP_POS or FLAT_POS
        for i = 1, math.abs(fifths) do
          local pos = list[i] - (clef == "bass" and 2 or 0)
          glyph.accidental(page, fifths > 0 and 1 or -1, eng.left + 4.2 * s + (i - 1) * 1.05 * s, y_of(sys, st, pos, s), s, ink)
        end
        local first = sys.measures[1].m
        if view.meter_changes(first.index) then
          local tx = eng.left + 4.6 * s + math.abs(fifths) * 1.05 * s
          local size = 2.1 * s
          page:text(tx, y_of(sys, st, 6, s) - size * 0.62, tostring(first.meter.num), { color = c.text, size = size, bold = true })
          page:text(tx, y_of(sys, st, 2, s) - size * 0.62, tostring(first.meter.den), { color = c.text, size = size, bold = true })
        end
      end
      line(page, eng.left, top_y, eng.left, bottom_y, c.text_2, math.max(1, 0.12 * s))
      if staves == 2 then
        -- A grand staff's bracket.
        page:rect(eng.left - 0.55 * s, top_y, 0.3 * s, bottom_y - top_y, { fill = c.text_2 })
      end

      for _, placed in ipairs(sys.measures) do
        local m, mx = placed.m, placed.x
        local function xt(beat) return mx + model.x_of(m, beat) end
        local bx = mx + m.width
        line(page, bx, top_y, bx, bottom_y, c.text_2, math.max(1, 0.12 * s))
        local tab = layout.tab
        if tab then
          local ty = function(i) return sys.tab_top + (i - 1) * sys.tab_line end
          if placed == sys.measures[1] then
            for i = 1, tab.strings do line(page, eng.left, ty(i), sys.width, ty(i), c.text_3, math.max(1, 0.1 * s)) end
            line(page, eng.left, ty(1), eng.left, ty(tab.strings), c.text_2, math.max(1, 0.12 * s))
            local mid = (ty(1) + ty(tab.strings)) / 2
            for k, letter in ipairs({ "T", "A", "B" }) do
              page:text(eng.left + 0.9 * s, mid + (k - 2.5) * 1.5 * s, letter, { color = ink, size = 1.4 * s, bold = true })
            end
          end
          line(page, bx, ty(1), bx, ty(tab.strings), c.text_2, math.max(1, 0.12 * s))
          for st2 = 1, #layout.staves do
            for _, ev in ipairs(m.staves[st2]) do
              if ev.kind == "note" then
                for _, n in ipairs(ev.notes) do
                  if n.string and not n.tied then
                    local label = tostring(n.fret)
                    local fw = (#label * 0.62 + 0.3) * 1.3 * s
                    local fx, fy = xt(ev.start), ty(n.string)
                    page:rect(fx - fw / 2, fy - 0.65 * s, fw, 1.3 * s, { fill = c.surface })
                    page:text(fx, fy - 0.8 * s, label, { color = ink, size = 1.3 * s, align = "center", width = fw + 4 })
                  end
                end
              end
            end
          end
        end
        page:text(mx + 0.2 * s, top_y - 3.4 * s, tostring(m.number), { color = c.text_3, size = math.max(9, 1.1 * s) })
        if placed ~= sys.measures[1] and view.meter_changes(m.index) then
          page:text(mx + 1.6 * s, top_y - 3.6 * s, m.meter.num .. "/" .. m.meter.den, { color = c.text, size = 1.4 * s, bold = true })
        end

        if selection and selection.c1 > m.start and selection.c0 < m.start + m.length then
          local x0 = selection.kind == "line" and mx or xt(math.max(selection.c0, m.start))
          local x1 = (selection.kind == "line" or selection.c1 >= m.start + m.length - EPS) and bx or xt(selection.c1)
          page:rect(x0, top_y - 2 * s, x1 - x0, bottom_y - top_y + 4 * s, { fill = c.select .. "33" })
        end

        for st in ipairs(layout.staves) do
          local evs = m.staves[st]
          local function Y(pos) return y_of(sys, st, pos, s) end
          -- Beams first decide where the stems end.
          local beams = {}
          for _, ev in ipairs(evs) do
            if ev.beam then
              local b = beams[ev.beam] or { dir = ev.stem, events = {} }
              b.events[#b.events + 1] = ev
              beams[ev.beam] = b
            end
          end
          local function stem_x(ev, dir)
            local hx = xt(ev.start)
            return dir > 0 and hx + 0.56 * s or hx - 0.56 * s
          end
          for _, b in pairs(beams) do
            local first, last = b.events[1], b.events[#b.events]
            local function far(ev) return b.dir > 0 and ev.notes[#ev.notes].pos or ev.notes[1].pos end
            local x0, x1 = stem_x(first, b.dir), stem_x(last, b.dir)
            local y0, y1 = Y(far(first)) - b.dir * 3.5 * s, Y(far(last)) - b.dir * 3.5 * s
            local slope = util.clamp(y1 - y0, -s, s)
            -- Every stem at least 2.75 spaces long.
            local shift = 0
            for _, ev in ipairs(b.events) do
              local xx = stem_x(ev, b.dir)
              local yb = y0 + slope * (xx - x0) / math.max(1, x1 - x0)
              local need = Y(far(ev)) - b.dir * 2.75 * s
              if b.dir > 0 then shift = math.max(shift, yb - need) else shift = math.min(shift, yb - need) end
            end
            -- And reaching the middle line.
            for _, ev in ipairs(b.events) do
              local xx = stem_x(ev, b.dir)
              local yb = y0 + slope * (xx - x0) / math.max(1, x1 - x0) - shift
              if b.dir > 0 and yb > Y(4) then shift = shift + (yb - Y(4)) end
              if b.dir < 0 and yb < Y(4) then shift = shift + (yb - Y(4)) end
            end
            b.y0, b.x0, b.x1, b.slope = y0 - shift, x0, x1, slope
            b.at = function(xx) return b.y0 + b.slope * (xx - b.x0) / math.max(1, b.x1 - b.x0) end
          end

          for ei, ev in ipairs(evs) do
            local ex = xt(ev.start)
            if ev.kind == "rest" then
              local rx = ev.whole and (mx + m.width / 2) or ex
              local sh = ev.shift or 0
              glyph.rest(page, ev.whole and 4 or ev.base, rx, Y(4 + sh), s, faint)
              if ev.dots > 0 and not ev.whole then ellipse(page, rx + 0.9 * s, Y(5 + sh), 0.17 * s, 0.17 * s, 0, faint) end
            else
              local shifted = {}
              for i, n in ipairs(ev.notes) do
                local prev = ev.notes[i - 1]
                shifted[i] = prev and n.step - prev.step == 1 and not shifted[i - 1] or false
              end
              local dir = ev.stem or 1
              -- Ledger lines.
              local lw = (ev.base and ev.base >= 4) and 1.25 * s or 1.05 * s
              local low, high = ev.notes[1].pos, ev.notes[#ev.notes].pos
              for p = -2, low, -2 do line(page, ex - lw, Y(p), ex + lw + (shifted[2] and 1.15 * s or 0), Y(p), c.text_2, math.max(1, 0.12 * s)) end
              for p = 10, high, 2 do line(page, ex - lw, Y(p), ex + lw + (shifted[#shifted] and 1.15 * s or 0), Y(p), c.text_2, math.max(1, 0.12 * s)) end
              local acc_n = 0
              for i, n in ipairs(ev.notes) do
                -- A second up from its neighbour goes on the other side of the stem.
                local hx = ex + (shifted[i] and (dir > 0 and 1.15 or -1.15) * s or 0)
                local cursor = ctx.focused and under_index == n.index and under_written and under_written.step == n.step
                  and ev.start <= self.beat + EPS and self.beat < ev.start + ev.length - EPS
                local dragged = gui.drag and gui.drag.index == n.index
                glyph.head(page, hx, Y(n.pos), s, ev.base or 1, (cursor and c.select) or (dragged and c.text_2) or ink, c.surface)
                gui.heads[#gui.heads + 1] = { x = hx, y = Y(n.pos) - gui.scroll, index = n.index, step = n.step, start = ev.start, staff = st }
                if n.acc then
                  acc_n = acc_n + 1
                  local ax = ex - (1.35 + (acc_n % 2 == 0 and 0.9 or 0)) * s - (shifted[i] and dir < 0 and 1.15 * s or 0)
                  if n.courtesy then
                    page:text(ax - 0.9 * s, Y(n.pos) - 0.9 * s, "(", { color = faint, size = 1.6 * s })
                    page:text(ax + 0.55 * s, Y(n.pos) - 0.9 * s, ")", { color = faint, size = 1.6 * s })
                  end
                  glyph.accidental(page, n.acc, ax, Y(n.pos), s, n.courtesy and faint or ink)
                end
                for d = 1, ev.dots do
                  local dy = n.pos % 2 == 0 and Y(n.pos + 1) or Y(n.pos)
                  ellipse(page, ex + (1.1 + 0.55 * (d - 1)) * s + ((shifted[i] or shifted[i + 1]) and dir > 0 and 1.15 * s or 0), dy, 0.17 * s, 0.17 * s, 0, ink)
                end
                if n.tied and ei == 1 and placed == sys.measures[1] then
                  -- A tie from the system before ends here.
                  local up = dir > 0 and 1 or -1
                  local x0, x1 = mx - 0.3 * s, ex - 0.75 * s
                  local y = Y(n.pos) + up * 0.55 * s
                  path(page, { "M", x0, y + up * 0.5 * s, "C", x0 + (x1 - x0) * 0.5, y + up * 0.75 * s, x1 - (x1 - x0) * 0.2, y + up * 0.5 * s, x1, y,
                    "C", x1 - (x1 - x0) * 0.2, y + up * 0.36 * s, x0 + (x1 - x0) * 0.5, y + up * 0.6 * s, x0, y + up * 0.5 * s, "Z" }, { fill = ink })
                end
                if n.tie then
                  local nxt = ev.next
                  local x1 = (nxt and nxt.measure == ev.measure) and xt(nxt.start) - 0.7 * s or (bx + 0.4 * s)
                  local x0 = ex + 0.75 * s + (ev.dots > 0 and 0.5 * s or 0)
                  local up = dir > 0 and 1 or -1
                  local y = Y(n.pos) + up * 0.55 * s
                  local bow = math.min(1.0, 0.25 + (x1 - x0) / s * 0.06) * s
                  path(page, { "M", x0, y, "C", x0 + (x1 - x0) * 0.25, y + up * bow, x1 - (x1 - x0) * 0.25, y + up * bow, x1, y,
                    "C", x1 - (x1 - x0) * 0.25, y + up * (bow - 0.16 * s), x0 + (x1 - x0) * 0.25, y + up * (bow - 0.16 * s), x0, y, "Z" }, { fill = ink })
                end
              end
              -- Grace notes, the arpeggio's wave and a staccato dot.
              local left = ex - 1.2 * s - (acc_n > 0 and (acc_n > 1 and 2.3 or 1.4) * s or 0)
              if ev.arpeggio then
                local y0, y1 = Y(high) - 0.6 * s, Y(low) + 0.6 * s
                local ax = left - 0.2 * s
                local pts = { "M", ax, y1 }
                local k, yy = 0, y1
                while yy > y0 do
                  yy = yy - 0.5 * s
                  k = k + 1
                  pts[#pts + 1] = "L"
                  pts[#pts + 1] = ax + (k % 2 == 1 and 0.3 or -0.3) * s
                  pts[#pts + 1] = yy
                end
                path(page, pts, { stroke = ink, width = 0.14 * s })
                local tipy = ev.arpeggio > 0 and yy or y1
                local d = ev.arpeggio > 0 and 1 or -1
                path(page, { "M", ax - 0.45 * s, tipy + d * 0.6 * s, "L", ax, tipy, "L", ax + 0.45 * s, tipy + d * 0.6 * s }, { stroke = ink, width = 0.14 * s })
                left = left - 1.2 * s
              end
              if ev.grace then
                local gs = 0.62 * s
                for gi = #ev.grace, 1, -1 do
                  local gn = ev.grace[gi]
                  local gx, gy = left, Y(gn.pos)
                  for p = -2, gn.pos, -2 do line(page, gx - 0.8 * gs, Y(p), gx + 0.8 * gs, Y(p), c.text_2, math.max(1, 0.1 * s)) end
                  for p = 10, gn.pos, 2 do line(page, gx - 0.8 * gs, Y(p), gx + 0.8 * gs, Y(p), c.text_2, math.max(1, 0.1 * s)) end
                  glyph.head(page, gx, gy, gs, 0.5, ink, c.surface)
                  local sx = gx + 0.56 * gs
                  line(page, sx, gy - 0.1 * gs, sx, gy - 3.2 * gs, ink, math.max(1, 0.1 * s))
                  glyph.flag(page, sx, gy - 3.2 * gs, gs, 1, ink)
                  line(page, sx - 0.6 * gs, gy - 1.4 * gs, sx + 0.9 * gs, gy - 2.6 * gs, ink, math.max(1, 0.1 * s))
                  if gn.acc then glyph.accidental(page, gn.acc, gx - 1.1 * gs, gy, gs, ink) end
                  left = left - 1.4 * s
                end
              end
              do
                -- Articulations on the side away from the stem, nearest first.
                local up = dir > 0
                local d = up and 1 or -1
                local sy = up and Y(low) + 1.1 * s or Y(high) - 1.1 * s
                if (up and low % 2 == 0 and low <= 8 and low >= 0) or (not up and high % 2 == 0 and high <= 8 and high >= 0) then sy = sy + d * 0.5 * s end
                local art = ev.art or {}
                if ev.staccato or art.staccato then
                  ellipse(page, ex, sy, 0.2 * s, 0.2 * s, 0, ink)
                  sy = sy + d * 0.9 * s
                end
                if art.tenuto then
                  line(page, ex - 0.6 * s, sy, ex + 0.6 * s, sy, ink, 0.18 * s)
                  sy = sy + d * 0.9 * s
                end
                if art.accent then
                  path(page, { "M", ex - 0.7 * s, sy - 0.35 * s, "L", ex + 0.7 * s, sy, "L", ex - 0.7 * s, sy + 0.35 * s }, { stroke = ink, width = 0.15 * s })
                  sy = sy + d * 1.0 * s
                end
                if art.marcato then
                  local tip = up and sy + 0.5 * s or sy - 0.5 * s
                  path(page, { "M", ex - 0.5 * s, tip - d * -0.0, "L", ex, tip - d * 1.0 * s, "L", ex + 0.5 * s, tip }, { stroke = ink, width = 0.2 * s })
                end
              end
              if ev.lyric and st == 1 then
                page:text(ex - 0.6 * s, Y(-2) + 3.2 * s, ev.lyric, { color = c.text, size = math.max(10, 1.3 * s) })
              end
              -- Stem, then a flag when nothing beams it.
              if ev.stem then
                local sx = stem_x(ev, dir)
                local base_y = dir > 0 and Y(low) - 0.15 * s or Y(high) + 0.15 * s
                local tip
                local b = ev.beam and beams[ev.beam]
                if b then
                  tip = b.at(sx)
                else
                  tip = dir > 0 and math.min(Y(high) - 3.5 * s, Y(4)) or math.max(Y(low) + 3.5 * s, Y(4))
                  if (ev.flags or 0) >= 2 then tip = tip - dir * (ev.flags - 1) * 0.6 * s end
                end
                line(page, sx, base_y, sx, tip, ink, math.max(1, 0.12 * s))
                if not b then
                  for f = 1, ev.flags or 0 do glyph.flag(page, sx, tip + dir * (f - 1) * 0.85 * s, s, dir, ink) end
                end
              end
            end
          end
          -- Slurs: a curve from the first note to the last, or to the end of the system.
          for _, ev in ipairs(evs) do
            if ev.slur_to and ev.notes then
              local last = ev.slur_to
              local x0 = xt(ev.start) + 0.3 * s
              local x1
              for _, placed2 in ipairs(sys.measures) do
                if placed2.m.index == last.measure then x1 = placed2.x + model.x_of(placed2.m, last.start) - 0.3 * s end
              end
              x1 = x1 or (sys.width - 0.5 * s)
              local above = (ev.stem or 1) < 0
              local d = above and -1 or 1
              local p0 = above and ev.notes[#ev.notes].pos or ev.notes[1].pos
              local p1 = last.notes and (above and last.notes[#last.notes].pos or last.notes[1].pos) or p0
              local y0, y1 = Y(p0) + d * 1.0 * s, Y(p1) + d * 1.0 * s
              local bow = math.min(2.2 * s, 0.6 * s + (x1 - x0) * 0.08)
              local yb = (above and math.min(y0, y1) or math.max(y0, y1)) + d * bow
              path(page, { "M", x0, y0, "C", x0 + (x1 - x0) * 0.25, yb, x1 - (x1 - x0) * 0.25, yb, x1, y1,
                "C", x1 - (x1 - x0) * 0.25, yb - d * 0.18 * s, x0 + (x1 - x0) * 0.25, yb - d * 0.18 * s, x0, y0, "Z" }, { fill = ink })
            end
          end
          -- Tuplets: a bracket and the number, on the stems' side.
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
            local up = tp.up >= 0
            local x0, x1 = xt(tp.events[1].start) - 0.7 * s, xt(tp.events[#tp.events].start) + 0.9 * s
            local edge = up and Y(10) or Y(-2)
            for _, ev in ipairs(tp.events) do
              for _, n in ipairs(ev.notes or {}) do
                if up then edge = math.min(edge, Y(n.pos) - 4.6 * s) else edge = math.max(edge, Y(n.pos) + 4.6 * s) end
              end
            end
            local hook = up and 0.6 * s or -0.6 * s
            local mid = (x0 + x1) / 2
            path(page, { "M", x0, edge + hook, "L", x0, edge, "L", mid - 0.7 * s, edge }, { stroke = faint, width = math.max(1, 0.1 * s) })
            path(page, { "M", mid + 0.7 * s, edge, "L", x1, edge, "L", x1, edge + hook }, { stroke = faint, width = math.max(1, 0.1 * s) })
            page:text(mid - 0.45 * s, edge - 0.8 * s, tostring(span.n), { color = ink, size = 1.5 * s, bold = true })
          end
          -- Beams: the first joins every note of the group, the others the
          -- notes short enough for them, with a stub where one stands alone.
          for _, b in pairs(beams) do
            local list = b.events
            local thick = 0.5 * s
            for level = 1, 3 do
              local off = (level - 1) * 0.8 * s * b.dir
              for i, ev in ipairs(list) do
                if (ev.flags or 0) >= level then
                  local xa = stem_x(ev, b.dir)
                  local nxt, prev = list[i + 1], list[i - 1]
                  local function draw(x0, x1)
                    local y0, y1 = b.at(x0) + off, b.at(x1) + off
                    if b.dir > 0 then quad(page, x0, y0, x1, y1, thick, ink) else quad(page, x0, y0 - thick, x1, y1 - thick, thick, ink) end
                  end
                  if nxt and (nxt.flags or 0) >= level then
                    draw(xa - 0.06 * s, stem_x(nxt, b.dir) + 0.06 * s)
                  elseif not (prev and (prev.flags or 0) >= level) then
                    if level == 1 then
                      draw(xa, xa + 0.06 * s)
                    elseif nxt then
                      draw(xa, xa + 1.1 * s)
                    else
                      draw(xa - 1.1 * s, xa)
                    end
                  end
                end
              end
            end
          end
        end

        -- Dynamics and hairpins under the first staff, text over it, repeat signs.
        for _, mk in ipairs(m.marks or {}) do
          local mxp = xt(mk.at)
          local under = y_of(sys, 1, 0, s) + 3.2 * s
          if mk.kind == "dyn" then
            page:text(mxp - 0.4 * s, under - 0.8 * s, mk.value, { color = ink, size = 1.8 * s, bold = true })
          elseif mk.kind == "cresc" or mk.kind == "dim" then
            local x1 = mk.to >= m.start + m.length - EPS and bx - 0.4 * s or xt(mk.to)
            local open, shut = mk.kind == "cresc" and x1 or mxp, mk.kind == "cresc" and mxp or x1
            line(page, shut, under, open, under - 0.6 * s, ink, math.max(1, 0.12 * s))
            line(page, shut, under, open, under + 0.6 * s, ink, math.max(1, 0.12 * s))
          elseif mk.kind == "text" then
            page:text(mxp, top_y - 2.6 * s, tostring(mk.value), { color = c.text, size = 1.4 * s, bold = true })
          end
        end
        if m.repeat_start or m.repeat_end then
          for st in ipairs(layout.staves) do
            local function dots(x)
              ellipse(page, x, y_of(sys, st, 3, s), 0.22 * s, 0.22 * s, 0, ink)
              ellipse(page, x, y_of(sys, st, 5, s), 0.22 * s, 0.22 * s, 0, ink)
            end
            if m.repeat_start then
              page:rect(mx, y_of(sys, st, 8, s), 0.45 * s, 4 * s, { fill = ink })
              line(page, mx + 0.8 * s, y_of(sys, st, 8, s), mx + 0.8 * s, y_of(sys, st, 0, s), ink, math.max(1, 0.12 * s))
              dots(mx + 1.3 * s)
            end
            if m.repeat_end then
              page:rect(bx - 0.45 * s, y_of(sys, st, 8, s), 0.45 * s, 4 * s, { fill = ink })
              line(page, bx - 0.8 * s, y_of(sys, st, 8, s), bx - 0.8 * s, y_of(sys, st, 0, s), ink, math.max(1, 0.12 * s))
              dots(bx - 1.3 * s)
            end
          end
        end

        -- The playhead.
        if t.position >= data.start + m.start - EPS and t.position < data.start + m.start + m.length - EPS then
          local px = xt(t.position - data.start)
          line(page, px, top_y - 2 * s, px, bottom_y + 2 * s, c.play, 2)
        end
        -- The cursor where nothing is written.
        if ctx.focused and self.beat >= m.start - EPS and (self.beat < m.start + m.length - EPS or (m.index == #layout.measures and self.beat <= m.start + m.length + EPS)) then
          local st = self:cursor_staff(layout)
          local pos = self.step - model.CLEF_BOTTOM[layout.staves[st]]
          local cx, cy = xt(self.beat), y_of(sys, st, pos, s)
          if not under_index then
            local insert = daw.keymap.mode == "i"
            for p = -2, pos, -2 do line(page, cx - 1.05 * s, y_of(sys, st, p, s), cx + 1.05 * s, y_of(sys, st, p, s), c.text_3, 1) end
            for p = 10, pos, 2 do line(page, cx - 1.05 * s, y_of(sys, st, p, s), cx + 1.05 * s, y_of(sys, st, p, s), c.text_3, 1) end
            ellipse(page, cx, cy, 0.62 * s, 0.42 * s, -20, (insert and c.play_on or c.select) .. "aa")
          end
          line(page, cx, top_y - 1.5 * s, cx, bottom_y + 1.5 * s, c.select .. "55", 1)
        end
      end
    end
  end

  -- A note being dragged, where it would land.
  local drag = gui.drag
  if drag and drag.moved and drag.to_beat then
    local placed_sys, placed_m
    for _, sys in ipairs(eng.systems) do
      for _, placed in ipairs(sys.measures) do
        local m = placed.m
        if drag.to_beat >= m.start - EPS and drag.to_beat < m.start + m.length - EPS then placed_sys, placed_m = sys, placed end
      end
    end
    if placed_m then
      local st = self:staff_of_step(drag.to_step, layout)
      local pos = drag.to_step - model.CLEF_BOTTOM[layout.staves[st]]
      local x = placed_m.x + model.x_of(placed_m.m, drag.to_beat)
      glyph.head(page, x, y_of(placed_sys, st, pos, s), s, 1, c.select .. "cc", c.surface)
    end
  end

  -- Toolbar, over whatever scrolled under it.
  g:rect(0, 0, w, TOOLBAR, { fill = c.panel })
  local name_w = #data.name * 7 + 22
  g:rect(10, 9, name_w, 26, { fill = colour, radius = 5 })
  g:text(21, 15, data.name, { color = c.surface, bold = true })
  local x = 10 + name_w + 12
  for _, v in ipairs(VALUE_BUTTONS) do
    x = button(g, x, 30, model.NAMES[v], self.value == v and not gui.rest, function()
      self:choose(v)
      gui.rest = false
    end, function(cx, cy, ink2)
      local ss = 5.2
      local hy = cy + 5
      glyph.head(g, cx - 2, hy, ss, v, ink2, self.value == v and not gui.rest and c.select or c.control)
      if v < 4 then line(g, cx - 2 + 0.56 * ss, hy - 0.15 * ss, cx - 2 + 0.56 * ss, hy - 3.3 * ss, ink2, 1.2) end
      for f = 1, model.flags(v) do glyph.flag(g, cx - 2 + 0.56 * ss, hy - 3.3 * ss + (f - 1) * 0.8 * ss, ss, 1, ink2) end
    end)
  end
  x = button(g, x + 4, 30, "dot", self.dot, function()
    self.dot = not self.dot
  end, function(cx, cy, ink2) ellipse(g, cx, cy, 2.6, 2.6, 0, ink2) end)
  x = button(g, x, 44, "rest", gui.rest, function() gui.rest = not gui.rest end)
  x = x + 8
  for _, a in ipairs({ { -1, "flat" }, { 0, "natural" }, { 1, "sharp" } }) do
    local on = gui.accidental == a[1]
    x = button(g, x, 30, a[2], on, function() gui.accidental = (gui.accidental ~= a[1]) and a[1] or nil end,
      function(cx, cy, ink2) glyph.accidental(g, a[1], cx, cy, 7, ink2) end)
  end
  -- Marks: on the chord under the cursor, or at the cursor.
  x = x + 8
  local marks = view.marks
  local function art_button(kind, draw)
    x = button(g, x, 28, kind, false, function() marks.toggle_art(kind, self:chord_indices()) end, draw)
  end
  art_button("staccato", function(cx, cy, ink2) ellipse(g, cx, cy, 2.4, 2.4, 0, ink2) end)
  art_button("accent", function(cx, cy, ink2) path(g, { "M", cx - 6, cy - 4, "L", cx + 6, cy, "L", cx - 6, cy + 4 }, { stroke = ink2, width = 1.6 }) end)
  art_button("tenuto", function(cx, cy, ink2) line(g, cx - 6, cy, cx + 6, cy, ink2, 2) end)
  x = button(g, x, 28, "slur", false, function() daw.cmd("notation.slur") end,
    function(cx, cy, ink2) path(g, { "M", cx - 8, cy + 3, "C", cx - 4, cy - 5, cx + 4, cy - 5, cx + 8, cy + 3 }, { stroke = ink2, width = 1.6 }) end)
  x = button(g, x, 28, "triplet", false, function() self:toggle_tuplet() end,
    function(cx, cy, ink2) g:text(cx - 4, cy - 8, "3", { color = ink2, bold = true, size = 13 }) end)
  x = button(g, x, 28, "voice", false, function() self:toggle_voice() end,
    function(cx, cy, ink2) g:text(cx - 8, cy - 7, "v2", { color = ink2, size = 12 }) end)
  x = x + 6
  for _, d in ipairs({ "p", "mf", "f" }) do
    x = button(g, x, 28, d, false, function() daw.cmd("notation.dyn", { d }) end)
  end
  x = button(g, x, 28, "cresc", false, function() daw.cmd("notation.cresc") end,
    function(cx, cy, ink2) path(g, { "M", cx + 8, cy - 4, "L", cx - 8, cy, "L", cx + 8, cy + 4 }, { stroke = ink2, width = 1.4 }) end)
  x = button(g, x, 28, "dim", false, function() daw.cmd("notation.dim") end,
    function(cx, cy, ink2) path(g, { "M", cx - 8, cy - 4, "L", cx + 8, cy, "L", cx - 8, cy + 4 }, { stroke = ink2, width = 1.4 }) end)
  local key_text = (fifths == 0 and "C") or (math.abs(fifths) .. (fifths > 0 and "♯" or "♭"))
  gui.key_text = key_text .. "  ·  " .. layout.meter.num .. "/" .. layout.meter.den .. "  ·  " .. track.name .. (view.raw_view() and "  ·  raw" or "")
  local right = w - 10
  right = right - 30
  button(g, right, 30, "+", false, function() view.gui_zoom = math.min(3, view.gui_zoom * 1.2) end)
  right = right - 35
  button(g, right, 30, "−", false, function() view.gui_zoom = math.max(0.5, view.gui_zoom / 1.2) end)

  -- What is under the cursor, or what the pointer does.
  local iy = h - INFO
  g:rect(0, iy, w, INFO, { fill = c.control })
  local info
  local note, _, written = self:note()
  if note then
    info = string.format("%s  played at %s, %.2f beats long, velocity %d", model.name(written), daw.time.format(data.start + note.start), note.length, note.velocity)
  elseif gui.rest then
    info = "rest: click the staff to clear a " .. model.NAMES[self.value] .. (self.dot and " dotted" or "") .. " there"
  else
    info = "click the staff to put a " .. (self.dot and "dotted " or "") .. model.NAMES[self.value] .. " there · drag a note to move it · right click removes it · Ctrl+wheel zooms"
  end
  g:text(12, iy + 6, info, { color = c.text_2, width = w - 260 })
  g:text(w - 12, iy + 6, gui.key_text or "", { color = c.text_2, align = "right", width = 240 })
end

-- The pointer ----------------------------------------------------------------------------------

--- What is at a point of the window: the system, staff, measure, the beat
--- (to the grid) and the staff step there.
function view:locate(x, y)
  local eng = gui.engraved
  local layout = self:layout()
  if not (eng and layout) then return nil end
  local s = eng.s
  y = y + gui.scroll
  for _, sys in ipairs(eng.systems) do
    if y >= sys.y and y < sys.y + sys.height then
      -- The nearer staff.
      local staff, best = 1, math.huge
      for st = 1, #layout.staves do
        local mid = y_of(sys, st, 4, s)
        if math.abs(y - mid) < best then staff, best = st, math.abs(y - mid) end
      end
      local pos = floor((y_of(sys, staff, 0, s) - y) / (s / 2) + 0.5)
      local step = model.CLEF_BOTTOM[layout.staves[staff]] + pos
      for _, placed in ipairs(sys.measures) do
        local m = placed.m
        if x >= placed.x and x < placed.x + m.width then
          local raw = model.t_of(m, x - placed.x)
          local grid = layout.grid
          -- A click just before a note's head means that note's time.
          local beat = floor((raw - m.start) / grid + 0.5) * grid + m.start
          beat = util.clamp(beat, m.start, m.start + m.length - grid)
          return { sys = sys, staff = staff, step = step, beat = beat, measure = m }
        end
      end
      return { sys = sys, staff = staff, step = step }
    end
  end
end

local function head_at(x, y)
  local s = sp()
  local best, dist
  for _, hd in ipairs(gui.heads) do
    local d = math.abs(hd.x - x) / (0.9 * s) + math.abs(hd.y - y) / (0.5 * s)
    if math.abs(hd.x - x) <= 0.9 * s and math.abs(hd.y - y) <= 0.5 * s and (not dist or d < dist) then best, dist = hd, d end
  end
  return best
end

function view:pointer(e)
  local clip = self:clip()
  if not clip or not gui.size then return end
  if e.kind == "wheel" then
    if e.ctrl then
      view.gui_zoom = util.clamp(view.gui_zoom * ((e.dy or 0) > 0 and 1.15 or 1 / 1.15), 0.5, 3)
    else
      gui.scroll = math.max(0, gui.scroll - (e.dy or 0))
      gui.follow = false
    end
    return
  end
  if e.kind == "down" and e.y < TOOLBAR then
    for _, b in ipairs(gui.buttons) do
      if e.x >= b.x and e.x < b.x + b.w and e.y >= b.y and e.y < b.y + b.h then return b.action() end
    end
    return
  end
  if e.kind == "down" and e.y < gui.size.h - INFO then
    local hd = head_at(e.x, e.y)
    local at = self:locate(e.x, e.y)
    if self.multi then
      -- Several tracks, to read: a click sounds a note and puts the cursor there.
      if hd then
        self:set(hd.step, math.max(0, hd.start))
        local layout = self:layout()
        local ok, track = pcall(daw.track, layout.tracks[hd.staff])
        local pitch
        for _, ev in ipairs(model.events(layout, hd.staff)) do
          for _, n in ipairs(ev.notes or {}) do
            if n.step == hd.step and math.abs(ev.start - hd.start) < EPS then pitch = n.pitch end
          end
        end
        if ok and track and pitch then track:play_note(pitch, daw.opt.velocity, 220) end
      elseif at and at.beat then
        self:set(at.step, at.beat)
      end
      return
    end
    if e.button == "right" then
      if hd then
        self:set(hd.step, math.max(0, hd.start))
        clip:remove_note(hd.index)
      end
      return
    end
    if hd and not gui.rest then
      self:set(hd.step, math.max(0, hd.start))
      local note = clip:notes()[hd.index]
      if note then self:audition(note.pitch) end
      gui.drag = { index = hd.index, from_step = hd.step, from_beat = at and at.beat or hd.start, start = hd.start, note = note, moved = false }
      return
    end
    if not (at and at.beat) then return end
    local length = self:entry_length()
    self.beat, self.step = math.max(0, at.beat), at.step
    if gui.rest then return self:rest(math.max(0, at.beat), length, at.staff) end
    local fifths = view.key()
    local pitch, spell
    if gui.accidental then
      pitch = model.pitch_of(at.step, gui.accidental)
      spell = model.spelled(at.step % 7, gui.accidental, pitch)
    else
      pitch = model.key_pitch(at.step, fifths)
    end
    if at.beat < 0 then return end
    self:place(pitch, at.beat, length, nil, spell)
    self:audition(pitch)
    return
  end
  local drag = gui.drag
  if not drag then return end
  if e.kind == "move" then
    local at = self:locate(e.x, e.y)
    if at and at.beat then
      drag.to_beat = math.max(0, drag.start + at.beat - drag.from_beat)
      drag.to_step = at.step
      drag.moved = drag.moved or at.step ~= drag.from_step or math.abs(at.beat - drag.from_beat) > EPS
    end
  elseif e.kind == "up" then
    gui.drag = nil
    if not (drag.moved and drag.to_beat and drag.note) then return end
    local fifths = view.key()
    local old = model.spell(drag.note.pitch, fifths)
    local want = drag.note.meta and drag.note.meta.notation
    if type(want) == "table" and want.pitch == drag.note.pitch then old = model.spelled(want.letter, want.alter, drag.note.pitch) end
    -- Up or down the staff keeps the note's distance from the key.
    local bend = old.alter - model.key_alter(old.letter, fifths)
    local pitch = util.clamp(model.key_pitch(drag.to_step, fifths) + bend, 0, 127)
    local start = drag.to_beat
    local meta = util.merge(drag.note.meta or {}, {})
    meta.notation = { letter = drag.to_step % 7, alter = model.key_alter(drag.to_step % 7, fifths) + bend, pitch = pitch }
    self:grow(clip, start + drag.note.length)
    clip:set_note(drag.index, { start = start, pitch = pitch, meta = meta })
    self:set(drag.to_step, start)
    if pitch ~= drag.note.pitch then self:audition(pitch) end
  end
end

--- Closing the window gives the keyboard back to the arrange view, and
--- leaving the view from the keyboard closes the window.
function view:on_close()
  gui.drag = nil
  daw.ui.hide("notation")
end

function view:on_hide()
  if daw.canvas and daw.canvas.open_views.notation then daw.canvas.close("notation") end
end

return gui
