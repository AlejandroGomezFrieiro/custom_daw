-- Tests of pictures under the cells (`buf:strip`) beyond the curve editor's:
-- `daw.plot`'s bars and waveform and their twins in cells, an audio clip's
-- waveform in the arrange view, the piano roll's controller strip. Loaded
-- by tests/suite.lua with its helpers.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = daw.api

local W, H = 120, 36
local PIXELS = { graphics = true, cell = { w = 10, h = 20 }, under = true }

--- Pictures on, for the rest of a test.
local function pictures()
  api.ui_caps_set(PIXELS)
  T.after(function() api.ui_caps_set({ graphics = false, cell = { w = 0, h = 0 } }) end)
end

--- The strip kept under `key` in the last drawing, or nil.
local function strip(key)
  for _, s in ipairs(daw.ui.rects.surfaces or {}) do
    if s.key == key then return s end
  end
end

--- What a strip draws, as `paint_surfaces` asks it.
local function ops_of(s)
  local cw, ch = s.cell.w, s.cell.h
  return daw.canvas.draw(s.draw, {
    w = s.whole_w * cw, h = s.whole_h * ch, cell = s.cell,
    view = { x = s.left * cw, y = s.top * ch, w = s.w * cw, h = s.h * ch },
  })
end

local function count(ops, kind, colour)
  local n = 0
  for _, op in ipairs(ops) do
    if op[1] == kind and (not colour or op[6] == colour or op[3] == colour or op[5] == colour) then n = n + 1 end
  end
  return n
end

--- A view that runs `draw(buf)` in a float of its own, and the screen drawn.
local function in_cells(draw)
  daw.ui.view("plot_test", { render = function(_, buf) draw(buf) end })
  daw.ui.open("plot_test", { width = 24, height = 8 })
  local lines = api.ui_snapshot(W, H)
  daw.ui.close()
  return table.concat(lines, "\n")
end

test("daw.plot draws bars and a waveform in pixels, and each has a twin in cells", function()
  fresh()
  local px = { w = 400, h = 80, cell = { w = 10, h = 20 } }
  local ops = daw.canvas.draw(function(g, p)
    daw.plot.bars(g, p, { items = { { beat = 0, value = 1 }, { beat = 2, value = 0.5, bright = true } }, pixels_per_beat = 40 })
  end, px)
  eq(count(ops, "r"), 4, "a bar and its head for each")
  local peaks = {}
  for i = 1, 400 do peaks[i] = { -0.5, i == 200 and 1 or 0.5, 0.3 } end
  ops = daw.canvas.draw(function(g, p) daw.plot.wave(g, p, { peaks = function(n) eq(n, 400, "a peak a pixel") return peaks end }) end, px)
  local fills = 0
  for _, op in ipairs(ops) do if op[1] == "p" and op[5] ~= "" then fills = fills + 1 end end
  eq(fills >= 2, true, "the wave and its RMS band, filled")
  local P = require("daw.theme").palette
  eq(count(ops, "r", daw.plot.alpha(P.red, 0.8)), 1, "the column at full scale in red")

  local shown = in_cells(function(buf)
    daw.plot.bars_cells(buf:sub(0, 0, 10, 2), { items = { { beat = 1, value = 1 }, { beat = 3, value = 0.5 } }, zoom = 1 })
    daw.plot.curve_cells(buf:sub(0, 2, 20, 2), { points = { { beat = 0, value = 0 }, { beat = 10, value = 1 } }, zoom = 2 })
    daw.plot.wave_cells(buf:sub(0, 4, 16, 2), { peaks = function(n) local out = {} for i = 1, n do out[i] = { -0.9, 0.9 } end return out end })
  end)
  eq(shown:find("█", 1, true) ~= nil, true, "bars in eighth blocks")
  local sextant = false
  for cp = 0x1FB00, 0x1FB3B do if shown:find(daw.draw.sextant(cp - 0x1FB00 + 1), 1, true) then sextant = true end end
  eq(sextant or shown:find("▐", 1, true) ~= nil, true, "the curve in sextants")
end)

--- A mono 16-bit file of `seconds` at 48 kHz of a loud square wave.
local function loud_file(name, seconds)
  local n = math.floor(48000 * seconds)
  local hi, lo = string.char(0xff, 0x7f), string.char(0x01, 0x80)
  local parts = {}
  for i = 1, n do parts[i] = (math.floor(i / 50) % 2 == 0) and hi or lo end
  local data = table.concat(parts)
  local function u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
  local function u32(v) return u16(v % 65536) .. u16(math.floor(v / 65536)) end
  local path = T.scratch .. "/" .. name .. ".wav"
  T.write_file(path, "RIFF" .. u32(36 + #data) .. "WAVEfmt " .. u32(16) .. u16(1) .. u16(1) .. u32(48000)
    .. u32(96000) .. u16(2) .. u16(16) .. "data" .. u32(#data) .. data)
  return path
end

test("an audio clip's waveform is a strip under its cells, of the whole clip, kept as it scrolls", function()
  fresh()
  local t = daw.add_track({ name = "loop" })
  local clip = t:add_clip({ start = 0, file = loud_file("loud", 8) })
  daw.cursor.set_track(t)
  daw.opt.zoom, daw.opt.track_height = 8, 4
  T.after(function() daw.opt.zoom, daw.opt.track_height = 2, "auto" end)
  local cells = api.ui_snapshot(W, H)
  eq(strip("arrange:wave:" .. clip.id), nil, "no pictures: cells")

  pictures()
  api.ui_snapshot(W, H)
  local s = strip("arrange:wave:" .. clip.id)
  eq(s ~= nil and s.under, true, "a strip under the clip's cells")
  local length = api.clip_get(clip.id).length
  eq(s.whole_w, math.max(1, math.floor(length * 8 + 0.5)), "as wide as the whole clip")
  local first = ops_of(s)
  eq(count(first, "p") >= 2, true, "drawn in pixels")
  eq(count(first, "r", daw.plot.alpha(require("daw.theme").palette.red, 0.8)) >= 1, true, "full scale in red")

  -- Scrolled four beats on: the clip's start is off the left edge, the
  -- strip the same, and what it draws there the same as before.
  daw.ui.views.arrange.scroll = 4
  api.ui_snapshot(W, H)
  s = strip("arrange:wave:" .. clip.id)
  eq(s.left, 32, "four beats of it off the left")
  local again, seen, same = ops_of(s), {}, 0
  for _, op in ipairs(first) do seen[table.concat(op, " ")] = true end
  for _, op in ipairs(again) do if seen[table.concat(op, " ")] then same = same + 1 end end
  eq(same >= 2, true, "stretches drawn before are drawn the same: " .. same)
  daw.ui.views.arrange.scroll = 0

  -- Pictures off: the cells as before.
  daw.opt.graphics = false
  T.after(function() daw.opt.graphics = true end)
  eq(table.concat(api.ui_snapshot(W, H), "\n"), table.concat(cells, "\n"), "graphics off draws the same cells")
end)

test("the piano roll's controller strip is a strip under its cells, the moves marked", function()
  fresh()
  local roll = daw.ui.views.pianoroll
  local t = daw.add_track({ name = "keys" })
  local clip = t:add_clip({ name = "riff", start = 0, length = 8, notes = { { pitch = 60, start = 0, length = 1 } },
    controls = { { start = 1, type = "bend", value = 0.5 }, { start = 3, type = "bend", value = -0.5 } } })
  roll:edit(clip)
  roll.top, roll.scroll, roll.pitch, roll.beat = 72, 0, 60, 0
  local strip_view = require("daw.views.pianoroll_strip")
  strip_view.show("bend")
  T.after(function() strip_view.show(nil) end)
  local cells = api.ui_snapshot(W, H)
  pictures()
  api.ui_snapshot(W, H)
  local s = strip("pianoroll:strip")
  eq(s ~= nil and s.under, true, "a strip under the controller's cells")
  local ops = ops_of(s)
  eq(count(ops, "p") >= 1, true, "the value held, as a line")
  local marks = 0
  local colour = daw.draw.track_colour(api.track_get(t.id))
  for _, op in ipairs(ops) do if op[1] == "r" and op[6] == colour and op[4] == 4 then marks = marks + 1 end end
  eq(marks, 2, "a mark on each move")
  daw.opt.graphics = false
  T.after(function() daw.opt.graphics = true end)
  eq(table.concat(api.ui_snapshot(W, H), "\n"), table.concat(cells, "\n"), "graphics off draws the same cells")
end)
