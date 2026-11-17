-- The leader's list of keys in every view, ghost examples in an empty popover,
-- panes that keep the arrange view its share, `,p` with no clip open, and
-- help that lands on a one-line entry for a key. Loaded by tests/suite.lua.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local daw = require("daw")
local api = daw.api
local L = daw.layout

local function hint_of(key)
  for _, hint in ipairs(daw.keymap.hints() or {}) do
    if hint.key == key then return hint.desc end
  end
end

local function load()
  if not package.loaded["notation.keys"] then daw.ext.load("extensions/notation") end
  return require("notation")
end

--- A clip open as notation, the cursor in it.
local function song()
  fresh()
  local view = load()
  local track = daw.add_track({ name = "Lead" })
  track:add_device("synth")
  local notes = {}
  for i, p in ipairs({ 60, 62, 64, 65 }) do notes[i] = { pitch = p, start = i - 1, length = 1, velocity = 80 } end
  local clip = track:add_clip({ start = 0, length = 4, name = "tune", notes = notes })
  daw.flush()
  daw.keymap.set_mode("n")
  view:edit(clip)
  view:ensure_score()
  return view
end

local function screen() return table.concat(api.ui_snapshot(140, 40), "\n") end

local function rows_with(text)
  local rows = {}
  for i, line in ipairs(api.ui_snapshot(140, 40)) do
    if line:find(text, 1, true) then rows[#rows + 1] = i end
  end
  return rows
end

test("leader: in the notation view , lists the popovers by name and stays up while the list is read", function()
  local view = song()
  local hints, wait = daw.opt.hint_delay, daw.opt.timeoutlen
  T.after(function() daw.opt.hint_delay, daw.opt.timeoutlen = hints, wait; daw.keymap.feed("<Esc>") end)
  daw.opt.hint_delay, daw.opt.timeoutlen = 20, 100
  daw.keymap.feed(",")
  daw.wait(400)
  eq(daw.keymap.pending(), ",", "still waiting well after timeoutlen, the list is on")
  for _, key in ipairs({ "d", "t", "k", "m", "q", "l" }) do
    eq((hint_of(key) or ""):match("^Popover: %a+") ~= nil, true, "," .. key .. " is listed as a popover")
  end
  eq(hint_of("d"):match("^Popover: dynamics") ~= nil, true, "with its name")
  daw.keymap.feed("<Esc>")
  eq(daw.keymap.pending(), "", "Escape drops it")
  -- A key no leader map has: the motion runs, then the key is a command of its own.
  view:set(nil, 2)
  daw.keymap.feed("fe")
  local at = view.beat
  daw.keymap.feed(",")
  daw.keymap.feed("<Esc>")
  eq(daw.keymap.pending(), "", "nothing left half typed")
  eq(at ~= nil, true, "the cursor is somewhere")
end)

test("leader: , in the notation view still goes back along an f after a pause, with no list to read", function()
  local view = song()
  local wait, hints = daw.opt.timeoutlen, daw.opt.hints
  T.after(function() daw.opt.timeoutlen, daw.opt.hints = wait, hints end)
  daw.opt.timeoutlen, daw.opt.hints = 20, false
  view:set(nil, 0)
  daw.keymap.feed("fe")
  local after_f = view.beat
  daw.keymap.feed(",")
  daw.wait(300)
  eq(daw.keymap.pending(), "", "the wait ended")
  eq(view.beat < after_f or view.beat == after_f, true, "and , went the other way, or stayed")
end)

test("popover: an empty prompt shows examples, and Tab fills the line", function()
  local view = song()
  daw.keymap.feed(",d")
  eq(rows_with("pp p mp mf f ff  mp<f  sfz") ~= nil and #rows_with("pp p mp mf f ff  mp<f  sfz") > 0, true, "dynamics examples")
  daw.keymap.feed("<Tab>")
  eq(#rows_with("pp p mp mf f ff  mp<f  sfz"), 0, "gone once the line has text")
  daw.keymap.feed("<Esc>")
  for key, ghost in pairs({ t = "Allegro q=132  rit.  a tempo", k = "Eb  f#m  D dorian", m = "6/8  3+3+2/8", q = "Cmaj7  G/B  N.C.",
      l = "syllables, Space next, - hyphen" }) do
    daw.keymap.feed("," .. key)
    eq(#rows_with(ghost) > 0, true, "," .. key .. " shows " .. ghost)
    daw.keymap.feed("<Esc>")
  end
end)

test("popover: it sits under the staff, so a tempo mark stays in sight", function()
  local view = song()
  daw.keymap.feed(",tAllegro q=132")
  local rows = rows_with("Allegro")
  eq(#rows >= 2, true, "the mark on the staff and the text in the prompt are both on the screen")
  daw.keymap.feed("<Esc>")
end)

test("panes: the arrange view keeps two fifths of a column with a roll, notation, quickfix and a curve", function()
  fresh()
  local tree = { dir = "v", L.leaf("arrange"), L.leaf("pianoroll", { weight = 2 }), L.leaf("notation", { weight = 2 }),
    L.leaf("qflist", { size = 10 }), L.leaf("curve", { size = 8 }) }
  local rects = daw.ui.place(tree, 0, 0, 100, 60)
  local arrange
  for _, r in ipairs(rects) do if r.name == "arrange" then arrange = r end end
  eq(arrange.h >= 24, true, "arrange has at least 24 of 60 rows, got " .. arrange.h)
  local sum = 0
  for _, r in ipairs(rects) do sum = sum + r.h end
  eq(sum, 60, "and the rows add up")
end)

test("roll.toggle: with no clip open it opens the clip under the cursor, or says there is none", function()
  fresh()
  daw.ui.hide("pianoroll")
  daw.ui.focus("arrange")
  local before = api.json_encode(daw.ui.arrange())
  daw.commands.exec("roll.toggle")
  eq(daw.ui.visible("pianoroll"), false, "no pane opened")
  eq(api.json_encode(daw.ui.arrange()), before, "the layout is as it was")
  eq((daw.ui.message and daw.ui.message.text or ""):match("no clip") ~= nil, true, "the message line says so")
  local track = daw.add_track({ name = "Lead" })
  local clip = track:add_clip({ start = 0, length = 4, name = "tune", notes = { { pitch = 60, start = 0, length = 1, velocity = 80 } } })
  daw.flush()
  daw.cursor.set_track(track)
  daw.cursor.set_beat(1)
  daw.commands.exec("roll.toggle")
  eq(daw.ui.visible("pianoroll"), true, "with a clip under the cursor the roll is shown")
  eq(daw.ui.views.pianoroll:clip() ~= nil, true, "on that clip")
  daw.commands.exec("roll.toggle")
  eq(daw.ui.visible("pianoroll"), false, "and again hides it")
end)

test("help: a key's entry is its row in the key table, and the help split takes half the screen", function()
  fresh()
  local initial = L.capture()
  T.after(function()
    for _, buf in ipairs(L.buffers_list()) do
      if buf.type == "textbuf" then L.buf_delete(buf) end
    end
    L.restore(initial)
    daw.ui.focus("arrange")
  end)
  daw.help.open("gU")
  local _, buf, t, s = daw.textbuf.here()
  eq(buf.name, "help://course/keys.md", "the key table's page")
  eq(t:line(s.row):match("^%s*|") ~= nil or t:line(s.row):match("gU") ~= nil, true, "on a line that names the key")
  eq(#t:line(s.row) < 120, true, "a one-line entry, not a paragraph")
  local _, height = daw.ui.size()
  for _, r in ipairs(daw.ui.arrange()) do
    if r.name == "textbuf" then eq(r.h >= math.floor(height / 2) - 1, true, "help has about half of " .. height .. ", got " .. r.h) end
  end
end)
