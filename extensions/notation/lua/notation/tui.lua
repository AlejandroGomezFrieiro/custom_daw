-- The staff in the terminal: one row for each line and space, a note head
-- in one cell, its stem above or below it in the same column, beams along
-- the stems' ends, measures packed into as many systems as the panel has
-- room for, from the first measure scrolled to.
local api = daw.api
local util = daw.util
local model = require("notation.model")
local view = require("notation")

local floor = math.floor
local EPS = 1e-6

view.zoom = 1   -- how wide the terminal spaces notes: 1 is a sixteenth in two columns

-- Characters: what a note head, a rest or an accidental looks like in a cell.
local ACC = { [1] = "♯", [-1] = "♭", [0] = "♮", [2] = "x", [-2] = "♭" }
local REST = { [1] = "ζ", [0.5] = "γ", [0.25] = "ɣ", [0.125] = "ɣ" }
local CLEF = { treble = { "G", 2 }, bass = { "F", 6 }, treble8 = { "G", 2 } }
-- Where a key signature's sharps and flats go on the treble staff, in order;
-- the bass staff has them two steps lower.
local SHARP_POS = { 8, 5, 9, 6, 3, 7, 4 }
local FLAT_POS = { 4, 7, 3, 6, 2, 5, 1 }

local function key_positions(fifths, clef)
  local out = {}
  local list = fifths > 0 and SHARP_POS or FLAT_POS
  for i = 1, math.abs(fifths) do out[i] = list[i] - (clef == "bass" and 2 or 0) end
  return out
end
view.key_positions = key_positions

--- Whether a chord has a head at a staff position (where its stem is not drawn).
local function has_head(ev, pos)
  for _, n in ipairs(ev.notes) do
    if n.pos == pos then return true end
  end
  return false
end

local function unit(d)
  return math.max(2, floor(2 * view.zoom * math.sqrt(d / 0.25) + 0.5))
end

--- How the panel is divided: staves per system, rows above and below each
--- staff, and how many systems fit.
local function rows_for(height, staves, extra)
  local best
  extra = extra or 0
  for margin = 4, 1, -1 do
    local per = staves * (9 + 2 * margin) + extra
    -- The last system may lose a little of the room under it.
    local systems = floor((height + margin - 1) / per)
    -- More systems win; between as many, more room above and below.
    if systems >= 1 and (not best or systems > best[3]) and (margin >= 3 or not best) then best = { margin, per, systems } end
  end
  if best then return best[1], best[2], best[3] end
  return 1, staves * 11 + extra, 1
end

--- Measures from `first` packed into systems `width` wide.
local function pack(layout, first, width, systems, prefix)
  local out = {}
  local i = first
  for _ = 1, systems do
    if i > #layout.measures then break end
    local row = { measures = {}, prefix = prefix(i) }
    local x = row.prefix
    repeat
      local m = layout.measures[i]
      if #row.measures > 0 and x + m.width + 1 > width then break end
      row.measures[#row.measures + 1] = { m = m, x = x }
      x = x + m.width + 1
      i = i + 1
    until i > #layout.measures
    row.width = x
    out[#out + 1] = row
  end
  return out, i - 1
end

function view:render(buf, ctx)
  local w, h = buf.width, buf.height
  local clip = self:clip()
  buf:fill(0, 0, w, h, " ", "Normal")
  if not clip then
    daw.ui.titlebar(buf, { name = "Notation", focused = ctx.focused })
    local x = 2 + buf:text(2, 2, "No clip open. Put the cursor on a MIDI clip in the arrange view and press", "Empty")
    x = x + 1 + buf:text(x + 1, 2, daw.ui.keybar.show("<leader>n"), "EmptyKey")
    buf:text(x + 1, 2, "or :notation.", "Empty")
    return
  end
  local c = clip:get()
  local track = api.track_get(c.track)
  local hue = daw.draw.track_hue(track)
  local colour = daw.draw.track_colour(track)
  local layout = self:layout()
  model.space(layout, { lead = 2, acc = 1, grace = 2, tail = 1, unit = unit })
  local fifths, stored = view.key()
  local inserting = ctx.focused and daw.keymap.mode == "i"
  -- A grand staff in a panel too low for both staves: the cursor's staff alone.
  local only
  if #layout.staves == 2 and h - 1 < 22 then
    only = self:cursor_staff(layout)
    local full = layout
    local measures = {}
    for i, m in ipairs(full.measures) do
      measures[i] = setmetatable({ staves = { m.staves[only] } }, { __index = m })
    end
    layout = setmetatable({ staves = { full.staves[only] }, measures = measures }, { __index = full })
  end
  -- Nothing drawn over the title row or below the panel.
  local real = buf
  buf = setmetatable({
    text = function(_, bx, by, ...)
      if by < 1 or by >= h then return 0 end
      return real:text(bx, by, ...)
    end,
    fill = function(_, bx, by, bw, bh, ...)
      local y0, y1 = math.max(by, 1), math.min(by + bh, h)
      if y1 > y0 then return real:fill(bx, y0, bw, y1 - y0, ...) end
    end,
  }, { __index = function(_, k) local v = real[k] if type(v) == "function" then return function(_, ...) return v(real, ...) end end return v end })

  -- Title: the clip, its track, where the cursor is, what will be entered.
  local under = self:note()
  local _, _, written = self:note()
  local here = written and model.name(written) or model.name(model.spell(model.key_pitch(self.step, fifths), fifths))
  local value = (model.NAMES[self.value] or "?") .. (self.dot and " dotted" or "")
  local keyname = stored and (stored.root .. " " .. (stored.scale or "major")) or "C major"
  local extra = (layout.names and ("  " .. #layout.names .. " staves, to read") or "") .. (view.raw_view() and "  raw" or "")
    .. (only and ("  " .. (only == 1 and "right hand" or "left hand") .. " (low panel)") or "")
  daw.ui.titlebar(real, {
    pill = { c.name, hue.pill }, name = track.name, focused = ctx.focused,
    context = string.format("%s  %s", here, daw.time.format(c.start + self.beat)),
    right = value .. "  " .. keyname .. "  " .. layout.meter.num .. "/" .. layout.meter.den .. extra,
  })
  if inserting then
    local text = " INS " .. value .. " "
    real:text(math.max(0, w - api.str_width(text) - 1), 0, text, "RulerInsert")
  end

  -- Room: systems of staves down the panel.
  local staves = #layout.staves
  local tab = layout.tab
  -- Tablature goes below the lowest note and stem of the last staff.
  local tab_room = 0
  if tab then
    for _, m in ipairs(layout.measures) do
      for _, ev in ipairs(m.staves[staves] or {}) do
        for _, n in ipairs(ev.notes or {}) do
          tab_room = math.max(tab_room, -(n.pos - ((ev.stem or 0) < 0 and 4 or 0)))
        end
      end
    end
  end
  local margin, per, systems = rows_for(h - 1, staves, tab and (tab.strings + 1 + math.max(0, tab_room - 1)) or 0)
  if tab then tab_room = math.max(0, tab_room - margin) end
  local staff_rows = 9 + 2 * margin
  local function meter_changes(i)
    local m, before = layout.measures[i], layout.measures[i - 1]
    return i == 1 or (before and before.meter ~= m.meter)
  end
  local function prefix(i)
    local p = 3 + math.abs(fifths) + 1
    if meter_changes(i) then p = p + 3 end
    return p
  end
  -- Scroll by whole measures to keep the cursor's measure on screen.
  local _, cursor_measure = self:measure_at(self:follow_beat(), layout)
  if cursor_measure < self.first then self.first = cursor_measure end
  self.first = util.clamp(self.first, 1, #layout.measures)
  local rows_out, last = pack(layout, self.first, w, systems, prefix)
  while cursor_measure > last and self.first < cursor_measure do
    self.first = self.first + 1
    rows_out, last = pack(layout, self.first, w, systems, prefix)
  end

  local note_style = { fg = colour }
  local faint = { fg = daw.draw.mix(colour, "#101216", 0.55) }
  local faint_ink = { fg = daw.draw.mix(colour, "#101216", 0.3) }
  local staff_style, bar_style = "Faint", "Dim"
  local geometry = { systems = {}, margin = margin, staff_rows = staff_rows, staves = layout.staves }
  self.geometry = geometry
  local t = api.transport_get()
  local selection = ctx.focused and daw.keymap.selection()

  for si, sys in ipairs(rows_out) do
    local top = 1 + (si - 1) * per
    local function row_of(s, pos) return top + (s - 1) * staff_rows + margin + 8 - pos end
    geometry.systems[si] = { top = top, measures = sys.measures, row_of = row_of, width = sys.width }
    -- Staff lines, clef, key.
    for s, clef in ipairs(layout.staves) do
      for pos = 0, 8, 2 do buf:fill(0, row_of(s, pos), sys.width, 1, "─", staff_style) end
      buf:text(1, row_of(s, CLEF[clef][2]), CLEF[clef][1], { fg = colour, bold = true })
      if clef == "treble8" then buf:text(1, row_of(s, -1), "8", { fg = colour }) end
      if layout.names and layout.names[s] ~= "" then buf:text(2, row_of(s, 10), layout.names[s], "Dim") end
      for i, pos in ipairs(key_positions(fifths, clef)) do
        buf:text(2 + i, row_of(s, pos), fifths > 0 and "♯" or "♭", "Dim")
      end
      local first = sys.measures[1].m
      if meter_changes(first.index) then
        local tx = 3 + math.abs(fifths) + 1
        buf:text(tx, row_of(s, 6), tostring(first.meter.num), "Bright")
        buf:text(tx, row_of(s, 2), tostring(first.meter.den), "Bright")
      end
    end
    -- The system's left edge, and a brace for a grand staff.
    local y0, y1 = row_of(1, 8), row_of(staves, 0)
    -- Tablature under the staves: a row for each string, the highest first.
    local tab_top = top + staves * staff_rows + tab_room
    if tab then
      for i = 1, tab.strings do
        buf:fill(2, tab_top + i - 1, sys.width - 2, 1, "─", staff_style)
        buf:text(0, tab_top + i - 1, (daw.music.name(tab.tuning[tab.strings - i + 1]):gsub("%-?%d+$", "")):sub(1, 2), "Dim")
      end
    end
    for y = y0, y1 do buf:text(0, y, "│", bar_style) end
    if staves == 2 then
      for y = row_of(1, -1), row_of(2, 9) do buf:text(0, y, "│", bar_style) end
    end

    for _, placed in ipairs(sys.measures) do
      local m, mx = placed.m, placed.x
      local function xt(beat) return mx + floor(model.x_of(m, beat) + 0.5) end
      -- Barline after, the bar's number over it.
      local bx = mx + m.width
      for y = y0, y1 do buf:text(bx, y, "│", bar_style) end

      buf:text(mx, top + math.max(0, margin - 2), tostring(m.number), "Faint")
      if placed ~= sys.measures[1] and meter_changes(m.index) then
        buf:text(mx + 1 + #tostring(m.number), top + math.max(0, margin - 2), m.meter.num .. "/" .. m.meter.den, "Bright")
      end

      -- The selection of visual mode.
      if selection then
        local x0 = xt(math.max(selection.c0, m.start))
        local x1 = selection.c1 >= m.start + m.length - EPS and bx or xt(math.min(selection.c1, m.start + m.length))
        if selection.c1 > m.start and selection.c0 < m.start + m.length and x1 > x0 then
          for s, clef in ipairs(layout.staves) do
            local ya, yb = row_of(s, 8 + margin), row_of(s, -margin)
            if selection.kind ~= "char" and selection.kind ~= "line" then
              local bottom = model.CLEF_BOTTOM[clef]
              ya = row_of(s, math.min(8 + margin, model.spell(selection.r1, fifths).step - bottom))
              yb = row_of(s, math.max(-margin, model.spell(selection.r0, fifths).step - bottom))
            end
            if selection.kind == "line" then x0, x1 = mx, bx end
            if yb >= ya then buf:fill(x0, ya, x1 - x0, yb - ya + 1, nil, "Visual") end
          end
        end
      end

      for s in ipairs(layout.staves) do
        local evs = m.staves[s]
        local function row(pos) return row_of(s, pos) end
        -- Beam groups: where the beam runs.
        local beams = {}
        for _, ev in ipairs(evs) do
          if ev.beam then
            local b = beams[ev.beam] or { dir = ev.stem, events = {} }
            b.events[#b.events + 1] = ev
            beams[ev.beam] = b
          end
        end
        for _, b in pairs(beams) do
          local tip = b.dir > 0 and -math.huge or math.huge
          for _, ev in ipairs(b.events) do
            local top_pos, low_pos = ev.notes[#ev.notes].pos, ev.notes[1].pos
            if b.dir > 0 then tip = math.max(tip, top_pos + 4, 4) else tip = math.min(tip, low_pos - 4, 4) end
          end
          b.tip = tip
        end

        for ei, ev in ipairs(evs) do
          local ex = xt(ev.start)
          if ev.kind == "rest" then
            local sh = ev.shift or 0
            if ev.whole then
              buf:text(mx + floor(m.width / 2), row(5 + sh), "▀", note_style)
            elseif ev.base >= 4 then
              buf:text(ex, row(5 + sh), "▀", note_style)
            elseif ev.base >= 2 then
              buf:text(ex, row(5 + sh), "▄", note_style)
            else
              buf:text(ex, row(4 + sh), REST[ev.base] or "γ", note_style)
              if ev.base <= 0.25 then buf:text(ex, row(3 + sh), "ˈ", note_style) end
            end
            if ev.dots > 0 and not ev.whole then buf:text(ex + 1, row(5 + sh), "·", note_style) end
          else
            -- Heads, ledger lines and accidentals.
            local shifted = {}
            for i, n in ipairs(ev.notes) do
              local prev = ev.notes[i - 1]
              shifted[i] = prev and n.step - prev.step == 1 and not shifted[i - 1] or false
            end
            for i, n in ipairs(ev.notes) do
              local hx = ex + (shifted[i] and 1 or 0)
              for p = -2, n.pos, -2 do buf:text(hx - 1, row(p), "───", faint) end
              for p = 10, n.pos, 2 do buf:text(hx - 1, row(p), "───", faint) end
            end
            for i, n in ipairs(ev.notes) do
              local hx = ex + (shifted[i] and 1 or 0)
              local head = (ev.base or 1) >= 2 and "○" or "●"
              local is_cursor = under and ctx.focused and n.index == written.index and ev.start <= self.beat + EPS and self.beat < ev.start + ev.length - EPS
              buf:text(hx, row(n.pos), head, is_cursor and "NoteCursor" or note_style)
              if n.acc then buf:text(hx - 1, row(n.pos), ACC[n.acc], n.courtesy and "Dim" or note_style) end
              if ev.dots > 0 then
                local dot_x = ex + 1 + (shifted[i] or shifted[i + 1] and 1 or 0)
                buf:text(dot_x, row(n.pos % 2 == 0 and n.pos + 1 or n.pos), "·", note_style)
              end
              -- A tie to the next event: under the head when the stem is up.
              if n.tie then
                local nxt = ev.next
                local tx1 = (nxt and nxt.measure == ev.measure) and xt(nxt.start) or bx
                local ty = (ev.stem or 1) > 0 and row(n.pos - 1) or row(n.pos + 1)
                for tx = ex + 1 + (ev.dots > 0 and 1 or 0), tx1 - 1 do buf:text(tx, ty, (ev.stem or 1) > 0 and "‿" or "⁀", note_style) end
              end
            end
            -- Grace notes before the chord, an arpeggio's wave, a staccato dot.
            local left = ex - 1
            for _, n in ipairs(ev.notes) do
              if n.acc then left = ex - 2 end
            end
            if ev.arpeggio then
              for p = ev.notes[1].pos, ev.notes[#ev.notes].pos do buf:text(left, row(p), "≀", note_style) end
              buf:text(left, row(ev.arpeggio > 0 and ev.notes[#ev.notes].pos + 1 or ev.notes[1].pos - 1), ev.arpeggio > 0 and "^" or "v", note_style)
              left = left - 1
            end
            if ev.grace then
              for gi = #ev.grace, 1, -1 do
                local gn = ev.grace[gi]
                buf:text(left, row(gn.pos), "•", faint_ink)
                if gn.acc then buf:text(left - 1, row(gn.pos), ACC[gn.acc], faint_ink) end
                left = left - 2
              end
            end
            -- Articulations on the side away from the stem, nearest first.
            do
              local up = (ev.stem or 1) > 0
              local p = up and ev.notes[1].pos - 2 or ev.notes[#ev.notes].pos + 2
              local art = ev.art or {}
              for _, mark in ipairs({ { ev.staccato or art.staccato, "·" }, { art.tenuto, "–" }, { art.accent, ">" }, { art.marcato, "^" } }) do
                if mark[1] then
                  buf:text(ex, row(p), mark[2], note_style)
                  p = p + (up and -1 or 1)
                end
              end
            end
            if ev.lyric and s == 1 then buf:text(ex, row(-margin + (staves == 2 and 0 or 1)), ev.lyric, "Normal") end
            -- The stem, from the head furthest along it.
            if ev.stem then
              local top_pos, low_pos = ev.notes[#ev.notes].pos, ev.notes[1].pos
              local b = ev.beam and beams[ev.beam]
              if ev.stem > 0 then
                local tip = b and b.tip or math.max(top_pos + 4, 4)
                for p = low_pos + 1, tip do
                  if not has_head(ev, p) then buf:text(ex, row(p), "│", note_style) end
                end
                if not b then
                  for f = 1, ev.flags or 0 do buf:text(ex + 1, row(tip - f + 1), "╲", note_style) end
                end
              else
                local tip = b and b.tip or math.min(low_pos - 4, 4)
                for p = top_pos - 1, tip, -1 do
                  if not has_head(ev, p) then buf:text(ex, row(p), "│", note_style) end
                end
                if not b then
                  for f = 1, ev.flags or 0 do buf:text(ex + 1, row(tip + f - 1), "╱", note_style) end
                end
              end
            end
          end
        end
        -- Beams over the stems' ends: one for eighths, more for shorter values.
        for _, b in pairs(beams) do
          local list = b.events
          for level = 1, 3 do
            local y = row(b.tip - (level - 1) * b.dir)
            for i, ev in ipairs(list) do
              if (ev.flags or 0) >= level then
                local x0 = xt(ev.start)
                local nxt = list[i + 1]
                if nxt and (nxt.flags or 0) >= level then
                  for bx2 = x0, xt(nxt.start) do buf:text(bx2, y, "━", note_style) end
                elseif level > 1 and not (list[i - 1] and (list[i - 1].flags or 0) >= level) then
                  -- A part beam toward the neighbour.
                  if nxt then
                    buf:text(x0, y, "━╸", note_style)
                  else
                    buf:text(x0 - 1, y, "╺━", note_style)
                  end
                elseif level == 1 then
                  buf:text(x0, y, "━", note_style)
                end
              end
            end
          end
          for _, ev in ipairs(list) do buf:text(xt(ev.start), row(b.tip), b.dir > 0 and "┳" or "┻", note_style) end
        end
        -- Slurs: an arc over the notes, to where the slur ends in this system.
        for _, ev in ipairs(evs) do
          if ev.slur_to then
            local last = ev.slur_to
            local x0 = xt(ev.start)
            local x1
            for _, placed2 in ipairs(sys.measures) do
              if placed2.m.index == last.measure then x1 = placed2.x + floor(model.x_of(placed2.m, last.start) + 0.5) end
            end
            x1 = x1 or sys.width - 1
            local top = math.max(ev.notes[#ev.notes].pos, last.notes and last.notes[#last.notes].pos or 0)
            local up = (ev.stem or 1) < 0
            local y = up and row(top + 2) or row(math.min(ev.notes[1].pos, last.notes and last.notes[1].pos or 0) - 2)
            if x1 > x0 + 1 then
              buf:text(x0, y, up and "╭" or "╰", faint)
              for sx = x0 + 1, x1 - 1 do buf:text(sx, y, "─", faint) end
              buf:text(x1, y, up and "╮" or "╯", faint)
            end
          end
        end
        -- Tuplets: the number over (or under) its notes.
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
          local x0, x1 = xt(tp.events[1].start), xt(tp.events[#tp.events].start)
          local up = tp.up >= 0
          local edge = up and 10 or -2
          for _, ev in ipairs(tp.events) do
            for _, n in ipairs(ev.notes or {}) do
              if up then edge = math.max(edge, n.pos + 5) else edge = math.min(edge, n.pos - 5) end
            end
          end
          local y = row(edge)
          if x1 > x0 + 1 then
            buf:text(x0, y, up and "┌" or "└", faint)
            for bx2 = x0 + 1, x1 - 1 do buf:text(bx2, y, "─", faint) end
            buf:text(x1, y, up and "┐" or "┘", faint)
          end
          buf:text(floor((x0 + x1) / 2), y, tostring(span.n), note_style)
        end
      end

      if tab then
        for i = 1, tab.strings do buf:text(bx, tab_top + i - 1, "│", bar_style) end
        -- Frets, at the notes' places; a tied note's continuation is not played again.
        for st = 1, staves do
          for _, ev in ipairs(m.staves[st]) do
            if ev.kind == "note" then
              for _, n in ipairs(ev.notes) do
                if n.string and not n.tied then buf:text(xt(ev.start), tab_top + n.string - 1, tostring(n.fret), note_style) end
              end
            end
          end
        end
      end
      -- Dynamics, hairpins and text; repeat signs at the barlines.
      for _, mk in ipairs(m.marks or {}) do
        local mxp = xt(mk.at)
        -- Under the first staff; in a low panel, on the last row there is.
        local dyn_row = math.min(row_of(1, -margin), h - 1)
        if mk.kind == "dyn" then
          buf:text(mxp, dyn_row, mk.value, { fg = colour, bold = true })
        elseif mk.kind == "cresc" or mk.kind == "dim" then
          local x1 = mk.to >= m.start + m.length - EPS and bx - 1 or xt(mk.to)
          local y = dyn_row
          for _, other in ipairs(m.marks) do
            if other.kind == "dyn" and math.abs(other.at - mk.at) < EPS then mxp = mxp + #other.value + 1 end
          end
          for hx = mxp, x1 do buf:text(hx, y, "─", note_style) end
          if mk.kind == "cresc" then buf:text(mxp, y, "<", note_style) else buf:text(x1, y, ">", note_style) end
        elseif mk.kind == "text" then
          buf:text(mxp, row_of(1, 8 + margin - 1), tostring(mk.value), { fg = colour, italic = true })
        end
      end
      for st in ipairs(layout.staves) do
        if m.repeat_start then
          for pp = 0, 8 do buf:text(mx, row_of(st, pp), "║", bar_style) end
          buf:text(mx + 1, row_of(st, 3), ":", note_style)
          buf:text(mx + 1, row_of(st, 5), ":", note_style)
        end
        if m.repeat_end then
          for pp = 0, 8 do buf:text(bx, row_of(st, pp), "║", bar_style) end
          buf:text(bx - 1, row_of(st, 3), ":", note_style)
          buf:text(bx - 1, row_of(st, 5), ":", note_style)
        end
      end

      -- The playhead.
      if t.position >= c.start + m.start - EPS and t.position < c.start + m.start + m.length - EPS then
        local px = xt(t.position - c.start)
        buf:fill(px, y0, 1, y1 - y0 + 1, nil, "Playhead")
      end
    end
  end

  -- The cursor: on its line or space, at its time.
  if ctx.focused then
    for _, sys in ipairs(geometry.systems) do
      for _, placed in ipairs(sys.measures) do
        local m = placed.m
        if self.beat >= m.start - EPS and (self.beat < m.start + m.length - EPS or (m.index == #layout.measures and self.beat <= m.start + m.length + EPS)) then
          local s = only and 1 or self:cursor_staff(layout)
          local pos = self.step - model.CLEF_BOTTOM[layout.staves[s]]
          local cx = placed.x + floor(model.x_of(m, self.beat) + 0.5)
          if not under or inserting or selection then
            buf:fill(cx, sys.row_of(s, pos), 1, 1, nil, inserting and "InsertCursor" or "RollCursor")
          end
          return
        end
      end
    end
  end
end

--- A click puts the cursor on the line or space and the time under it.
function view:on_mouse(event)
  local g = self.geometry
  local layout = self:layout()
  if not (g and layout) then return end
  if event.kind == "scroll_up" then self.first = math.max(1, self.first - 1) end
  if event.kind == "scroll_down" then self.first = math.min(#layout.measures, self.first + 1) end
  if event.kind ~= "down" then return api.ui_redraw() end
  for _, sys in ipairs(g.systems) do
    for _, placed in ipairs(sys.measures) do
      local m = placed.m
      if event.x >= placed.x and event.x <= placed.x + m.width then
        for s, clef in ipairs(g.staves or layout.staves) do
          local pos = sys.row_of(s, 0) - event.y
          if pos >= -g.margin - 1 and pos <= 8 + g.margin + 1 then
            local beat = model.t_of(m, event.x - placed.x)
            local grid = daw.opt.notation_grid
            self:set(model.CLEF_BOTTOM[clef] + pos, math.max(0, floor(beat / grid + 0.5) * grid))
            -- A click on a note sounds it.
            local note = self:note()
            if note then self:audition(note.pitch) end
            return
          end
        end
      end
    end
  end
end

return view
