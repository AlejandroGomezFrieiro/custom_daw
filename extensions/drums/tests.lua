-- Tests of the drums extension; tests/suite.lua runs them.
local T = ...
local test, eq, near, fresh = T.test, T.eq, T.near, T.fresh
local api = daw.api

local drums
local function load()
  if not drums then
    daw.ext.load("extensions/drums")
    drums = require("drums")
  end
  return drums
end

--- A clip's hits as "pitch@start", in order; with `vel`, "pitch@start:velocity".
local function hits(clip, vel)
  local notes = clip:notes()
  table.sort(notes, function(a, b)
    if math.abs(a.start - b.start) > 1e-9 then return a.start < b.start end
    return a.pitch < b.pitch
  end)
  local out = {}
  for i, n in ipairs(notes) do
    out[i] = string.format("%d@%g", n.pitch, math.floor(n.start * 1000 + 0.5) / 1000) .. (vel and (":" .. n.velocity) or "")
  end
  return table.concat(out, " ")
end

local function keys(text)
  daw.keymap.feed(text)
  api.undo_checkpoint()
end

--- A fresh project with a drum track made by the command, its clip open in the grid.
local function drum_track()
  load()
  fresh()
  daw.keymap.feed("<Esc><Esc>")
  daw.ui.focus("arrange")
  daw.opt.drums_step, daw.opt.drums_velocity = 0.25, 100
  daw.cmd("drums.track")
  daw.flush()
  local track = daw.cursor.track()
  local clip = track:clips()[1]
  local grid = daw.ui.views.drums
  grid.step = nil
  api.undo_checkpoint()
  return track, clip, grid
end

local function screen(w, h) return table.concat(api.ui_snapshot(w or 120, h or 40), "\n") end

-- Maps and tracks -------------------------------------------------------------------

test("drums: the General MIDI map names the pieces a beat needs, in order", function()
  local d = load()
  local names = {}
  for _, row in ipairs(d.maps.gm.rows) do names[#names + 1] = row.note .. " " .. row.name end
  eq(table.concat(names, ", "), "36 Kick, 38 Snare, 37 Rim, 39 Clap, 42 Closed hat, 44 Pedal hat, 46 Open hat, "
    .. "50 High tom, 47 Mid tom, 45 Low tom, 49 Crash, 51 Ride, 53 Ride bell, 56 Cowbell, 54 Tambourine", "the rows")
  eq(#d.maps["gm-full"].rows, 47, "every General MIDI percussion note is in gm-full")
end)

test("drums: drums.track makes a track ready for drums in one step", function()
  local track, clip = drum_track()
  eq(track.name, "Drums", "named")
  eq(track.color, drums.colour, "coloured")
  eq(track:devices()[1].kind, "drums", "with the built-in kit")
  eq(drums.info(track).map, "gm", "and the General MIDI map")
  eq(#drums.rows(track), 15, "fifteen rows")
  eq(clip.length, daw.time.bar(), "a bar to program")
  eq(daw.ui.focused, "drums", "open in the drum grid")
  eq(daw.ui.views.drums.clip_id, clip.id, "on its clip")
  eq(daw.canvas.open_views.drums ~= nil, true, "and in a window for a graphical frontend")
end)

test("drums: the map is kept with the track in the project", function()
  local track = drum_track()
  local path = T.scratch .. "/drums-map.json"
  daw.project.save(path)
  daw.project.load(path)
  local again = daw.tracks()[1]
  eq(drums.info(again).map, "gm", "the map's name")
  eq(drums.rows(again)[5].name, "Closed hat", "and its rows")
  eq(drums.is_drum(again), true, "still a drum track")
  local _ = track
end)

test("drums: drums.map turns any track into a drum track, and back", function()
  load()
  fresh()
  local synth = daw.add_track({ name = "Plugin kit" })
  synth:add_device("synth")
  daw.cursor.set_track(synth)
  eq(drums.is_drum(synth), false, "an ordinary track to begin with")
  daw.commands.exec("drums.map gm-full")
  eq(drums.info(synth).map, "gm-full", "a drum track with the map chosen")
  eq(synth:devices()[1].kind, "synth", "whatever its instrument")
  eq(#drums.rows(synth), 47, "all its rows")
  daw.commands.exec("drums.map off")
  eq(drums.is_drum(synth), false, "and an ordinary track again")
  T.fails(function() daw.commands.exec("drums.map nosuch") end, "no drum map", "an unknown map")
end)

test("drums: maps are plain tables an init.lua can add to", function()
  load()
  fresh()
  drums.maps.tiny = { label = "two pieces", rows = { { note = "C2", name = "Boom" }, { note = 40, name = "Crack" } } }
  local t = daw.add_track({ name = "T" })
  drums.set_map(t, "tiny")
  eq(drums.rows(t)[1].note, 36, "notes may be given by name")
  eq(drums.rows(t)[2].name, "Crack", "and the rows keep their names")
  drums.maps.tiny = nil
end)

test("drums: a note the map does not name still gets a row", function()
  local track, clip = drum_track()
  clip:add_note({ pitch = 81, start = 0, length = 0.25 })
  local rows = drums.rows(track, clip)
  eq(#rows, 16, "one more row")
  eq(rows[16].note, 81, "for the note")
  eq(rows[16].extra, true, "marked as outside the map")
  eq(rows[16].name, "Open triangle", "named after General MIDI")
  daw.flush()
  eq(screen():find("Open triangle", 1, true) ~= nil, true, "and shown in the grid")
end)

-- The terminal grid -------------------------------------------------------------------

test("drums: Enter toggles a hit, and the grid shows it by name and by how hard", function()
  local _, clip = drum_track()
  keys("<CR>")
  eq(hits(clip, true), "36@0:100", "a kick on the first step")
  keys("2l<CR>")
  eq(hits(clip), "36@0 36@0.5", "and on the third")
  keys("<CR>")
  eq(hits(clip), "36@0", "Enter again takes it out")
  keys("j2l<CR>")
  eq(hits(clip), "36@0 38@1", "a snare on beat two")
  daw.flush()
  local text = screen(120, 30)
  eq(text:find("Kick", 1, true) ~= nil and text:find("Snare", 1, true) ~= nil, true, "rows are named")
  eq(text:find("▇▇", 1, true) ~= nil, true, "a hit at 100 is drawn seven eighths tall")
end)

test("drums: the ruler marks the beats with ticks and no numbers, as the roll's does", function()
  drum_track()
  daw.flush()
  local lines = api.ui_snapshot(140, 30)
  local ruler
  for i, line in ipairs(lines) do
    if line:find("Kick", 1, true) and line:find("·", 1, true) then ruler = lines[i - 1] break end
  end
  eq(type(ruler), "string", "the ruler is above the first row")
  eq(ruler:find("▏", 1, true) ~= nil, true, "beats are ticks: " .. ruler)
  eq(ruler:find("▏%d") == nil, true, "with no number after them: " .. ruler)
end)

test("drums: a new hit is heard", function()
  local track = drum_track()
  local before = 0
  keys("<CR>")
  daw.wait(30)
  local l, r = track:meter()
  before = math.max(l, r)
  eq(before > 0, true, "the kick sounds when it is entered")
end)

test("drums: + and - make a hit harder and softer", function()
  local _, clip = drum_track()
  keys("<CR>+")
  eq(hits(clip, true), "36@0:116", "harder")
  keys("3-")
  eq(hits(clip, true), "36@0:68", "a count goes three times as far")
  keys("9+")
  eq(hits(clip, true), "36@0:127", "never past 127")
  keys("[h")
  eq(hits(clip, true), "36@0:111", "[ is softer too, as in the piano roll")
end)

test("drums: the step size changes, with triplets", function()
  local _, clip, grid = drum_track()
  keys("]g")
  eq(grid:step_size(), 0.5, "]g is coarser")
  keys("T")
  eq(grid:step_size(), 1 / 3, "T makes it triplets")
  keys("[g")
  eq(grid:step_size(), 1 / 6, "[g is finer, still triplets")
  keys("ll<CR>")
  eq(hits(clip), "36@0.333", "a hit on the third sixteenth triplet")
  keys("T")
  eq(grid:step_size(), 0.25, "T again is straight")
end)

test("drums: motions move by steps, rows, hits and bars", function()
  local _, clip, grid = drum_track()
  clip.length = 8
  clip:add_notes({ { pitch = 38, start = 1, length = 0.25 }, { pitch = 38, start = 3, length = 0.25 } })
  keys("j")
  eq(grid:piece().name, "Snare", "j is the next row")
  keys("w")
  eq(grid.beat, 1, "w is the next hit on the row")
  keys("w")
  eq(grid.beat, 3, "and the next")
  keys("b")
  eq(grid.beat, 1, "b goes back")
  keys("W")
  eq(grid.beat, 4, "W is the next bar")
  keys("G")
  eq(grid:piece().name, "Tambourine", "G is the last row")
  keys("gg")
  eq(grid:piece().name, "Kick", "gg the first")
  keys("/clap<CR>")
  eq(grid:piece().name, "Clap", "a piece is found by name")
end)

test("drums: dd clears a row, and u brings it back", function()
  local _, clip = drum_track()
  clip:add_notes({
    { pitch = 36, start = 0, length = 0.25 }, { pitch = 36, start = 2, length = 0.25 },
    { pitch = 38, start = 1, length = 0.25 },
  })
  api.undo_checkpoint()
  keys("dd")
  eq(hits(clip), "38@1", "the kicks are gone, the snare stays")
  daw.undo()
  eq(hits(clip), "36@0 38@1 36@2", "undone")
  keys("2dd")
  eq(hits(clip), "", "2dd clears two rows")
  daw.undo()
  keys("x")
  eq(hits(clip), "38@1 36@2", "x removes the hit under the cursor")
end)

test("drums: & repeats a bar to the end of the clip, or N times", function()
  local _, clip = drum_track()
  clip.length = 16
  clip:add_notes({ { pitch = 36, start = 0, length = 0.25 }, { pitch = 38, start = 1, length = 0.25 } })
  clip:add_note({ pitch = 42, start = 6, length = 0.25 })
  api.undo_checkpoint()
  keys("&")
  eq(hits(clip), "36@0 38@1 36@4 38@5 36@8 38@9 36@12 38@13", "every bar after it is the first again")
  daw.undo()
  keys("1&")
  eq(hits(clip), "36@0 38@1 36@4 38@5", "1& repeats it once, and what was there gives way")
  eq(clip.length, 16, "the clip keeps its length")
  clip.length = 4
  api.undo_checkpoint()
  keys("&")
  eq(clip.length, 8, "a one-bar clip grows to hold the repeat")
end)

test("drums: yank and paste hits, by row and by stretch of time", function()
  local _, clip = drum_track()
  clip.length = 8
  clip:add_notes({ { pitch = 36, start = 0, length = 0.25 }, { pitch = 38, start = 1, length = 0.25 } })
  api.undo_checkpoint()
  keys("yib")
  keys("W")
  keys("P")
  eq(hits(clip), "36@0 38@1 36@4 38@5", "a bar of every row pasted at the next bar")
  daw.undo()
  keys("0yy4jp")
  -- The kick row's hits go on the row the cursor is on: the closed hat.
  eq(hits(clip), "36@0 42@0 38@1", "a row pasted on another row")
end)

test("drums: visual mode selects hits to change together", function()
  local _, clip = drum_track()
  clip:add_notes({
    { pitch = 36, start = 0, length = 0.25 }, { pitch = 36, start = 1, length = 0.25 },
    { pitch = 38, start = 1, length = 0.25 }, { pitch = 36, start = 2, length = 0.25 },
  })
  api.undo_checkpoint()
  keys("<C-v>j5l-")
  eq(hits(clip, true), "36@0:84 36@1:84 38@1:84 36@2:100", "a block of two rows and five steps is softer")
  keys("0Vx")
  eq(hits(clip), "38@1", "the cursor is back where the selection began, and V then x clears that row")
end)

test("drums: > and < move hits by a step", function()
  local _, clip = drum_track()
  clip:add_note({ pitch = 36, start = 0, length = 0.25 })
  api.undo_checkpoint()
  keys(">ih")
  eq(hits(clip), "36@0.25", "a step later")
  keys("<lt>ih")
  eq(hits(clip), "36@0", "and back")
end)

test("drums: Enter opens a drum track's clip in the grid, other clips in the piano roll", function()
  load()
  fresh()
  daw.keymap.feed("<Esc><Esc>")
  daw.ui.focus("arrange")
  -- Enter opens the roll and the grid in panes that Esc leaves on screen.
  T.after(function() daw.ui.hide("pianoroll") daw.ui.hide("drums") end)
  local keys_track = daw.add_track({ name = "Keys" })
  keys_track:add_device("synth")
  keys_track:add_clip({ start = 0, length = 4, notes = { { pitch = 60, start = 0, length = 1 } } })
  local beat = drums.make_track({ name = "Beat" })
  beat:add_clip({ start = 0, length = 4 })
  daw.cursor.set_track(keys_track)
  daw.cursor.set_beat(0)
  daw.keymap.feed("<CR>")
  eq(daw.ui.focused, "pianoroll", "an ordinary clip opens in the piano roll")
  daw.keymap.feed("<C-w>p")
  daw.cursor.set_track(beat)
  daw.keymap.feed("<CR>")
  eq(daw.ui.focused, "drums", "a drum track's clip opens in the drum grid")
  daw.keymap.feed("<Esc>")
  eq(daw.ui.focused, "drums", "Esc stays in the grid, as in every view")
  daw.keymap.feed("<C-w>p")
  eq(daw.ui.focused, "arrange", "Ctrl-w p goes back")
end)

test("drums: the key bar shows only keys that are mapped", function()
  load()
  eq(table.concat(daw.ui.keybar.check(), ", "), "", "keys shown with nothing mapped to them")
end)

-- The window ------------------------------------------------------------------------

local function paint(w, h) return daw.canvas.paint("drums", w or 1040, h or 560) end

--- Where the drum grid paints a row and a cell, from its own layout.
local function at(row, cell)
  local gui = require("drums.gui")
  local l = gui.layout
  return 132 + cell * l.cellw + l.cellw / 2 - gui.scroll, 40 + 24 + (row - 1 - gui.top) * 26 + 13
end

local function pointer(kind, x, y, extra)
  daw.canvas.pointer("drums", daw.util.merge({ kind = kind, x = x, y = y, button = "left" }, extra or {}))
end

local function click(row, cell, button)
  local x, y = at(row, cell)
  pointer("down", x, y, { button = button or "left" })
  pointer("up", x, y, { button = button or "left" })
end

test("drums: the window opens on a double click of a drum track's clip only", function()
  load()
  fresh()
  daw.canvas.close("drums")
  local keys_track = daw.add_track({ name = "Keys" })
  keys_track:add_device("synth")
  local other = keys_track:add_clip({ start = 0, length = 4 })
  daw.frontend.act.open_clip(other.id)
  eq(daw.canvas.open_views.drums, nil, "not for a clip of another track")
  eq(daw.ui.focused, "pianoroll", "which opens in the piano roll")
  local beat = drums.make_track({ name = "Beat" })
  local clip = beat:add_clip({ start = 0, length = 4 })
  daw.frontend.act.open_clip(clip.id)
  eq(daw.canvas.open_views.drums ~= nil, true, "a drum track's clip opens the drum grid's window")
  eq(daw.ui.views.drums.clip_id, clip.id, "on that clip")
end)

test("drums: the window paints rows by name and hits by velocity", function()
  local _, clip = drum_track()
  clip:add_notes({ { pitch = 36, start = 0, length = 0.25, velocity = 127 }, { pitch = 38, start = 1, length = 0.25, velocity = 40 } })
  local drawing = paint()
  local texts = {}
  for _, op in ipairs(drawing.ops) do
    if op[1] == "t" then texts[op[4]] = true end
  end
  eq(texts.Kick and texts.Snare and texts["Ride bell"] or false, true, "every row is named")
  local function fill_at(x, y)
    local found
    for _, op in ipairs(drawing.ops) do
      if op[1] == "r" and op[6] ~= "" and x >= op[2] and x < op[2] + op[4] and y >= op[3] and y < op[3] + op[5] then found = op[6] end
    end
    return found
  end
  local loud, soft = fill_at(at(1, 0)), fill_at(at(2, 4))
  local empty = fill_at(at(1, 1))
  eq(loud ~= soft and soft ~= empty and loud ~= nil, true, "a loud hit, a soft hit and no hit look different")
end)

test("drums: clicking a cell in the window adds a hit, clicking it again removes it", function()
  local _, clip = drum_track()
  paint()
  click(1, 0)
  eq(hits(clip, true), "36@0:100", "a kick")
  click(2, 4)
  eq(hits(clip), "36@0 38@1", "a snare")
  click(1, 0)
  eq(hits(clip), "38@1", "the kick is gone")
  click(2, 4, "right")
  eq(hits(clip), "", "right click removes")
end)

test("drums: dragging along a row paints hits, or erases them, as one undo step", function()
  local _, clip = drum_track()
  paint()
  local x0, y = at(5, 0)
  pointer("down", x0, y)
  for cell = 1, 7 do
    local x = at(5, cell)
    pointer("move", x, y + 30)
  end
  pointer("up", at(5, 7), y)
  api.undo_checkpoint()
  eq(hits(clip), "42@0 42@0.25 42@0.5 42@0.75 42@1 42@1.25 42@1.5 42@1.75", "eight hats along the row, though the pointer wandered off it")
  local x2 = at(5, 2)
  pointer("down", x2, y)
  pointer("move", at(5, 5), y)
  pointer("up", at(5, 5), y)
  api.undo_checkpoint()
  eq(hits(clip), "42@0 42@0.25 42@1.5 42@1.75", "a drag from a hit erases")
  daw.undo()
  eq(#clip:notes(), 8, "one undo brings the erased ones back")
  daw.undo()
  eq(#clip:notes(), 0, "and one more takes the painted ones away")
end)

test("drums: the velocity lane sets how hard the row's hits are", function()
  local _, clip, grid = drum_track()
  clip:add_notes({ { pitch = 36, start = 0, length = 0.25 }, { pitch = 36, start = 0.5, length = 0.25 }, { pitch = 38, start = 0.5, length = 0.25 } })
  grid.row = 1
  paint(1040, 560)
  local l = require("drums.gui").layout
  local lane_top = 40 + 24 + l.body_h
  local x0 = at(1, 0)
  pointer("down", x0, lane_top + 6)
  pointer("move", at(1, 2), lane_top + 6)
  pointer("up", at(1, 2), lane_top + 6)
  eq(hits(clip, true), "36@0:127 36@0.5:127 38@0.5:100", "a stroke at the top makes the kicks it crosses as hard as can be")
  pointer("down", x0, lane_top + 72 - 6 - 60 / 2)
  pointer("up", x0, lane_top + 72 - 6 - 60 / 2)
  near(clip:notes()[1].velocity, 64, 2, "halfway up is half as hard")
end)

test("drums: the window's toolbar sets the step and the clip's length", function()
  local _, clip, grid = drum_track()
  local function press(label)
    paint()
    for _, b in ipairs(require("drums.gui").buttons) do
      if b.label == label then return pointer("down", b.x + 4, b.y + 4) end
    end
    error("no button " .. label)
  end
  press("1/8T")
  eq(grid:step_size(), 1 / 3, "triplet eighths")
  press("1/16")
  eq(grid:step_size(), 0.25, "sixteenths")
  press("+")
  eq(clip.length, 2 * daw.time.bar(), "two bars")
  press("−")
  eq(clip.length, daw.time.bar(), "one again")
end)

test("drums: clicking a row's name in the window plays the piece", function()
  local track, _, grid = drum_track()
  paint()
  local _, y = at(2, 0)
  pointer("down", 20, y)
  eq(grid:piece().name, "Snare", "the row is chosen")
  daw.wait(30)
  local l, r = track:meter()
  eq(math.max(l, r) > 0, true, "and heard")
end)

test("drums: the window shows the playhead", function()
  local _, clip = drum_track()
  daw.transport.seek(clip.start + 1)
  local drawing = paint()
  local found = false
  for _, op in ipairs(drawing.ops) do
    if op[1] == "p" and op[3] == require("daw.canvas").palette.play then found = true end
  end
  eq(found, true, "a line in the playhead's colour")
end)

-- The sound ---------------------------------------------------------------------------

test("drums: the built-in kit plays every row of the General MIDI map", function()
  local track, clip = drum_track()
  daw.project.tempo = 120
  local rows = drums.rows(track)
  clip.length = #rows
  local notes = {}
  for i, row in ipairs(rows) do notes[i] = { pitch = row.note, start = i - 1, length = 0.25 } end
  clip:add_notes(notes)
  -- A beat is half a second: each piece gets its own.
  local info = T.render({ bits = 16, ["end"] = #rows, tail = 0 })
  for i, row in ipairs(rows) do
    local peak = T.channel_peaks(info, (i - 1) * 0.5 + 0.005, (i - 1) * 0.5 + 0.1)
    eq(peak > 0.02, true, row.name .. " sounds: " .. peak)
  end
end)

test("drums: a closed hat cuts the open hat off", function()
  local _, clip = drum_track()
  daw.project.tempo = 120
  clip:add_note({ pitch = 46, start = 0, length = 0.25 })
  local open = T.channel_peaks(T.render({ bits = 16, ["end"] = 2, tail = 0 }), 0.4, 0.55)
  clip:add_note({ pitch = 42, start = 0.5, length = 0.25 })
  local cut = T.channel_peaks(T.render({ bits = 16, ["end"] = 2, tail = 0 }), 0.4, 0.55)
  eq(open > 0.005, true, "the open hat rings on alone: " .. open)
  eq(cut < 0.0005, true, "and stops when the closed hat comes: " .. cut)
end)

-- A kit of samples ------------------------------------------------------------------

--- A mono 16-bit WAV of `seconds` at `level`, at 48 kHz.
local function wav(path, level, seconds)
  local rate, n = 48000, math.floor(48000 * seconds)
  local function u32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
  local function u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
  local sample = math.floor(level * 32767 + 0.5)
  local s = u16(sample % 65536)
  local body = s:rep(n)
  T.write_file(path, "RIFF" .. u32(36 + #body) .. "WAVEfmt " .. u32(16) .. u16(1) .. u16(1) .. u32(rate) .. u32(rate * 2)
    .. u16(2) .. u16(16) .. "data" .. u32(#body) .. body)
end

local kit_dir
local function samples()
  if kit_dir then return kit_dir end
  kit_dir = T.scratch .. "/kit"
  os.execute("mkdir -p '" .. kit_dir .. "'")
  wav(kit_dir .. "/Kick 808.wav", 0.5, 0.1)
  wav(kit_dir .. "/snare_tight.wav", 0.25, 0.1)
  wav(kit_dir .. "/hh closed.wav", 0.4, 0.05)
  wav(kit_dir .. "/OpenHat.wav", 0.3, 1.0)
  wav(kit_dir .. "/zap.wav", 0.2, 0.1)
  T.write_file(kit_dir .. "/notes.txt", "not a sound")
  return kit_dir
end

test("drums: a folder of samples becomes a kit, the files named by what they are", function()
  load()
  local kit = require("drums.kit")
  local pads, rows = kit.from_folder(samples())
  local by_note = {}
  for _, p in ipairs(pads) do by_note[p.note] = p.file:match("[^/]+$") .. (p.group > 0 and " g" .. p.group or "") end
  eq(by_note[36], "Kick 808.wav", "a kick on 36")
  eq(by_note[38], "snare_tight.wav", "a snare on 38")
  eq(by_note[42], "hh closed.wav g1", "a closed hat on 42, in the hats' group")
  eq(by_note[46], "OpenHat.wav g1", "an open hat on 46, in the same group")
  eq(by_note[60], "zap.wav", "what it does not know goes from 60 up")
  eq(#pads, 5, "and nothing that is not a sound")
  local names = {}
  for i, row in ipairs(rows) do names[i] = row.note .. " " .. row.name end
  eq(table.concat(names, ", "), "36 Kick 808, 38 snare_tight, 42 hh closed, 46 OpenHat, 60 zap", "rows named after the files, a beat's order")
  eq(kit.classify("BD_01").name, "Kick", "short names too")
  eq(kit.classify("ride-bell").name, "Ride bell", "and two words")
  eq(kit.classify("hat_pedal").name, "Pedal hat", "pedal hats")
end)

test("drums: drums.kit makes a drum track that plays the files", function()
  load()
  fresh()
  daw.project.tempo = 120
  daw.commands.exec("drums.kit " .. samples())
  local track = daw.cursor.track()
  eq(drums.is_drum(track), true, "a drum track")
  eq(track:devices()[1].kind, "sampler", "playing samples")
  eq(drums.rows(track)[1].name, "Kick 808", "its rows named after the files")
  local clip = track:add_clip({ start = 0, length = 4, notes = {
    { pitch = 36, start = 0, length = 0.25, velocity = 127 }, { pitch = 38, start = 1, length = 0.25, velocity = 127 },
    { pitch = 60, start = 2, length = 0.25, velocity = 127 },
  } })
  local info = T.render({ bits = 16, ["end"] = 4, tail = 0 })
  near(T.channel_peaks(info, 0.01, 0.09), 0.5, 0.01, "the kick file, as loud as it is")
  near(T.channel_peaks(info, 0.51, 0.59), 0.25, 0.01, "the snare file")
  near(T.channel_peaks(info, 1.01, 1.09), 0.2, 0.01, "the one it did not know")
  eq(T.channel_peaks(info, 0.15, 0.45) < 0.001, true, "and nothing between")

  -- Saved with the project, and heard again when it is opened.
  local path = T.scratch .. "/drums-kit.json"
  daw.project.save(path)
  daw.project.load(path)
  info = T.render({ bits = 16, ["end"] = 4, tail = 0 })
  near(T.channel_peaks(info, 0.01, 0.09), 0.5, 0.01, "the kick after opening the project again")
  local _ = clip
end)

test("drums: a pad's level, pan, tuning and group are set, and undone", function()
  load()
  fresh()
  daw.project.tempo = 120
  local track = drums.make_track({ kit = samples() })
  local kit = require("drums.kit")
  local device = kit.device(track)
  track:add_clip({ start = 0, length = 4, notes = { { pitch = 36, start = 0, length = 0.25, velocity = 127 } } })
  api.undo_checkpoint()
  kit.set_pad(device, 36, { level = -6.0206, pan = -1 })
  api.undo_checkpoint()
  local info = T.render({ bits = 16, ["end"] = 1, tail = 0 })
  local left, right = T.channel_peaks(info, 0.01, 0.09)
  near(left, 0.5 * 0.5 * math.sqrt(2), 0.01, "half as loud, and all on the left")
  eq(right < 0.001, true, "nothing on the right")
  daw.undo()
  info = T.render({ bits = 16, ["end"] = 1, tail = 0 })
  left, right = T.channel_peaks(info, 0.01, 0.09)
  near(left, 0.5, 0.01, "undo puts the pad back")
  near(right, 0.5, 0.01, "in the middle")
  kit.set_pad(device, 36, { tune = 12 })
  eq(kit.pads(device)[1].tune, 12, "tuned an octave up")
  local open, closed = 46, 42
  track:clips()[1]:set_notes({ { pitch = open, start = 0, length = 0.25, velocity = 127 }, { pitch = closed, start = 0.5, length = 0.25, velocity = 127 } })
  info = T.render({ bits = 16, ["end"] = 2, tail = 0 })
  eq(T.channel_peaks(info, 0.35, 0.6) < 0.001, true, "the closed hat cuts the open one off, by their group")
  kit.set_pad(device, closed, { group = 0 })
  info = T.render({ bits = 16, ["end"] = 2, tail = 0 })
  near(T.channel_peaks(info, 0.35, 0.6), 0.3, 0.01, "and does not once it is out of the group")
end)

test("drums: a kit's files are read again for a render, and a missing one is reported", function()
  load()
  fresh()
  local track = drums.make_track({ kit = samples() })
  local kit = require("drums.kit")
  local device = kit.device(track)
  kit.set_pad(device, 37, { file = T.scratch .. "/nowhere.wav" })
  daw.flush()
  local status = api.device_call(device.id, "status")
  eq(status:find("37 missing", 1, true) ~= nil, true, "the status says which file is missing")
  eq(status:find("36 4800 48000", 1, true) ~= nil, true, "and what the others hold")
end)

-- Swing and beats --------------------------------------------------------------------

test("drums: gs swings every other step of what it covers, and does not add up", function()
  local _, clip = drum_track()
  clip:add_notes({
    { pitch = 42, start = 0, length = 0.25 }, { pitch = 42, start = 0.25, length = 0.25 },
    { pitch = 42, start = 0.5, length = 0.25 }, { pitch = 42, start = 0.75, length = 0.25 },
    { pitch = 36, start = 0.25, length = 0.25 },
  })
  daw.opt.drums_swing = 0.33
  api.undo_checkpoint()
  keys("4jgsir")
  eq(hits(clip), "42@0 36@0.25 42@0.333 42@0.5 42@0.833", "the hats' offbeats are a third of a step late; the kick is not touched")
  keys("gsir")
  eq(hits(clip), "42@0 36@0.25 42@0.333 42@0.5 42@0.833", "swinging again changes nothing")
  daw.undo()
  daw.undo()
  keys("50gsic")
  eq(hits(clip), "42@0 36@0.375 42@0.375 42@0.5 42@0.875", "a count is the percent of a step, for every row")
end)

test("drums: a beat to start from fills the clip", function()
  local _, clip = drum_track()
  clip.length = 8
  clip:add_note({ pitch = 81, start = 0, length = 0.25 })
  daw.commands.exec("drums.beat rock")
  local text = hits(clip)
  eq(text:find("81@", 1, true), nil, "in place of what was there")
  eq(text:find("36@0 42@0 ", 1, true) == 1, true, "kick and hat on one: " .. text)
  eq(text:find("38@1 ", 1, true) ~= nil and text:find("38@5 ", 1, true) ~= nil, true, "snare on two, in both bars")
  eq(#clip:notes(), 2 * (8 + 2 + 3), "every bar of the clip")
  T.fails(function() daw.commands.exec("drums.beat polka") end, "no beat", "an unknown beat")
end)
