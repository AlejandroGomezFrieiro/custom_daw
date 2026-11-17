-- The piano roll on a score clip: what it shows of what is written and what
-- is feel (extensions/notation/lua/notation/roll.lua). Loaded by tests/suite.lua.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local daw = require("daw")
local api = daw.api

local function load()
  if not package.loaded["notation.keys"] then daw.ext.load("extensions/notation") end
  return require("notation"), require("notation.roll")
end

--- A score clip C D E F, quarters in bar one, open in the roll and in notation.
local function song()
  fresh()
  local view, rollscore = load()
  local track = daw.add_track({ name = "Lead" })
  track:add_device("synth")
  local clip = track:add_clip({ start = 0, length = 4, name = "tune", notes = {} })
  daw.flush()
  daw.keymap.set_mode("n")
  view:edit(clip)
  view.value, view.dot, view.voice, view.triplets = 1, false, 1, false
  daw.keymap.feed("icdef<Esc>")
  api.undo_checkpoint()
  daw.ui.views.pianoroll:edit(clip)
  return view, rollscore, clip
end

local function screen(w, h)
  local rows = {}
  for _, row in ipairs(api.ui_view_snapshot("pianoroll", w or 140, h or 40).rows) do
    local parts = {}
    for _, run in ipairs(row) do parts[#parts + 1] = run.text end
    rows[#rows + 1] = table.concat(parts)
  end
  return rows
end

local function has(rows, text)
  for _, r in ipairs(rows) do
    if r:find(text, 1, true) then return true end
  end
  return false
end

--- How many cells of the screen show `glyph`.
local function count(rows, glyph)
  local n = 0
  for _, r in ipairs(rows) do
    for _ in r:gmatch(glyph) do n = n + 1 end
  end
  return n
end

test("rollscore: a score clip is labelled in the roll, with the keys that write and the keys that feel", function()
  local _, _, clip = song()
  local rows = screen(160, 40)
  eq(has(rows, "written in notation"), true, "the title says so")
  eq(has(rows, "written: ] [ x i H L"), true, "the key line says which keys write")
  eq(has(rows, "feel: velocity"), true, "and which are feel")
  local plain = daw.add_track({ name = "Pad" }):add_clip({ start = 0, length = 4, name = "pad", notes = { { pitch = 60, start = 0, length = 1 } } })
  daw.ui.views.pianoroll:edit(plain)
  eq(has(screen(160, 40), "written in notation"), false, "a plain MIDI clip is not")
  local function chip()
    for _, t in ipairs(daw.ui.views.pianoroll:toolbar()) do
      if t.label == "Notation" then return true end
    end
    return false
  end
  eq(chip(), false, "and has no chip for it")
  daw.ui.views.pianoroll:edit(clip)
  eq(chip(), true, "a score clip has the chip that opens its score")
end)

test("rollscore: a nudge shows a tick at the written onset, and quantize takes it away", function()
  local _, rollscore, clip = song()
  local roll = daw.ui.views.pianoroll
  local function ticks()
    local n = 0
    for _, m in ipairs(select(2, roll:marks(clip.id))) do
      if m.tip and m.tip:find("written here", 1, true) then n = n + 1 end
    end
    return n
  end
  eq(ticks(), 0, "nothing is nudged")
  eq(count(screen(), "▎"), 0, "no tick in the terminal either")
  clip:set_note(2, { start = 1.03 })
  api.undo_checkpoint()
  eq(ticks(), 1, "the window is handed one tick")
  local _, over = roll:marks(clip.id)
  local tick
  for _, m in ipairs(over) do
    if m.tip and m.tip:find("written here", 1, true) then tick = m end
  end
  eq(tick.start, 1, "at the written onset")
  eq(tick.pitch, 62, "on the note's row")
  eq(math.abs(rollscore.notes(clip.id).list[2].late - 0.03) < 1e-9, true, "the note knows how late it plays")
  eq(count(screen(), "▎") >= 1, true, "and the terminal draws the tick")
  -- A longer note: its written end too.
  clip:set_note(1, { length = 0.93 })
  api.undo_checkpoint()
  local ends = 0
  for _, m in ipairs(select(2, roll:marks(clip.id))) do
    if m.tip == "written to end here" then ends = ends + 1 end
  end
  eq(ends, 1, "a length that differs shows the written end")
  -- Quantize: the feel goes, the ticks with it.
  local notes = clip:notes()
  for _, n in ipairs(notes) do n.start, n.length = math.floor(n.start + 0.5), 0.9 end
  clip:set_notes(notes)
  api.undo_checkpoint()
  eq(ticks(), 0, "quantized: no tick")
  eq(count(screen(), "▎"), 0, "in the terminal either")
end)

test("rollscore: the velocity strip says the note's velocity against the dynamic", function()
  local view, rollscore, clip = song()
  clip:set_note(1, { velocity = 100 })
  api.undo_checkpoint()
  local e = rollscore.notes(clip.id).list[1]
  eq(e.dvel, 20, "twenty over the dynamic")
  eq(rollscore.velocity_text(e), "100 = mf 80+20", "said as the dynamic and the difference")
  local roll = daw.ui.views.pianoroll
  roll:set(60, 0)
  eq(has(screen(140, 40), "100 = mf 80+20"), true, "the strip shows it at the cursor")
  eq(count(screen(140, 40), "─") >= 1, true, "with a line at the dynamic's level")
  view = view
end)

test("rollscore: a generated note is hatched, and editing it asks the mark or only this pass", function()
  local view, rollscore, clip = song()
  local roll = daw.ui.views.pianoroll
  view:set(36, 1)
  eq(view:toggle_grace(), true, "the D is a grace note")
  api.undo_checkpoint()
  local entry
  for _, e in ipairs(rollscore.notes(clip.id).list) do
    if e.generated then entry = e end
  end
  eq(entry ~= nil and entry.generated, "grace", "the roll knows it is generated")
  eq(count(screen(), "╱") >= 1, true, "hatched in the terminal")
  local hatched = 0
  for _, m in ipairs(select(2, roll:marks(clip.id))) do
    if m.tip and m.tip:find("made from a written grace", 1, true) then hatched = hatched + 1 end
  end
  eq(hatched, 1, "and a mark for the window")
  -- A pitch: ask.
  local before = clip:notes()[entry.place].pitch
  clip:set_note(entry.place, { pitch = before + 1 })
  eq(clip:notes()[entry.place].pitch, before, "nothing changes before the answer")
  eq(daw.ui.grabber ~= nil, true, "a question is put")
  daw.keymap.feed("t")
  eq(clip:notes()[entry.place].pitch, before, "only this pass: a pitch has none, so it stays")
  clip:set_note(entry.place, { pitch = before + 1 })
  daw.keymap.feed("w")
  api.undo_checkpoint()
  eq(clip:notes()[entry.place].pitch, before + 1, "the mark: written")
  -- A delete of it asks too; any other key leaves it.
  local n = #clip:notes()
  clip:remove_note(entry.place)
  daw.keymap.feed("<Esc>")
  eq(#clip:notes(), n, "left as it was")
  -- A nudge in time is already only this pass: no question.
  clip:set_note(entry.place, { start = clip:notes()[entry.place].start + 0.01 })
  eq(daw.ui.grabber, nil, "a nudge asks nothing")
end)

test("rollscore: with timebind the note under one window's cursor is outlined in the other", function()
  local view, rollscore, clip = song()
  local roll = daw.ui.views.pianoroll
  eq(rollscore.partner("pianoroll"), nil, "not bound: no outline")
  -- Whatever happens, leave no bound or extra windows for the tests after.
  T.after(function()
    for _, win in ipairs(daw.layout.windows(daw.ui.layout)) do
      if win.view == "pianoroll" or win.view == "notation" then daw.layout.set_option(win, "timebind", false) end
    end
    daw.ui.hide("notation")
    daw.ui.hide("pianoroll")
  end)
  daw.ui.show("pianoroll")
  daw.ui.show("notation")
  for _, win in ipairs(daw.layout.windows(daw.ui.layout)) do
    if win.view == "pianoroll" or win.view == "notation" then daw.layout.set_option(win, "timebind", true) end
  end
  eq(rollscore.bound(clip.id), true, "bound")
  view:set(36, 1)
  local id = rollscore.partner("pianoroll")
  eq(id, clip:notes()[2].meta.score.n, "the roll outlines the note under notation's cursor")
  local outlined
  for _, m in ipairs(select(2, roll:marks(clip.id))) do
    if m.edge == "#ffd34d" then outlined = m end
  end
  eq(outlined ~= nil and outlined.pitch, 62, "as a mark for the window, on its row")
  eq(has(screen(), "⟦"), true, "and in the terminal")
  roll:set(64, 2)
  eq(rollscore.partner("notation"), clip:notes()[3].meta.score.n, "notation outlines the note under the roll's cursor")
  eq(rollscore.partner_place(), 3, "by its place among the clip's notes")
  view:set(38, 3)
  local moved = rollscore.partner("pianoroll")
  eq(moved, clip:notes()[4].meta.score.n, "and the outline follows the cursor")
  for _, win in ipairs(daw.layout.windows(daw.ui.layout)) do
    if win.view == "pianoroll" then daw.layout.set_option(win, "timebind", false) end
  end
  eq(rollscore.partner("pianoroll"), nil, "unbound: gone")
  daw.ui.hide("notation")
end)
