-- What the window's status bar is told: the key bar, the quickfix count,
-- the command line's candidates, a track's sends, and how a render's peak is
-- worded. The window only draws these; the terminal shows the same.
-- Loaded by tests/suite.lua with its helpers.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = daw.api

local function modal() return daw.frontend.state(-1).modal end

local function calm()
  fresh()
  daw.keymap.feed("<Esc><Esc>")
  while daw.ui.float do daw.ui.close() end
  daw.ui.message = nil
  daw.ui.focus("arrange")
end

test("the window is told the keys of the focused view when there is no message", function()
  calm()
  local keys = modal().keys
  eq(keys ~= nil and #keys > 3, true, "keys are listed")
  eq(keys[1].key .. " " .. keys[1].desc, daw.ui.keybar.entries()[1][1] .. " " .. daw.ui.keybar.entries()[1][2], "the first as the terminal shows it")
  daw.ui.focus("mixer")
  local mixer = modal().keys
  eq(mixer[1].desc, "next", "the mixer's own")
  daw.notify("something happened")
  eq(modal().keys, nil, "a message has the line")
  eq(modal().message.time ~= nil, true, "and says when it was made")
  daw.ui.message = nil
  daw.keymap.feed("g")
  eq(modal().keys, nil, "a half-typed command lists what follows instead")
  daw.keymap.feed("<Esc>")
end)

test("the command line's candidates are told with their descriptions, around the one chosen", function()
  calm()
  daw.keymap.feed(":tem")
  local list = modal().prompt.matches
  eq(list ~= nil and #list.items > 0, true, "something to complete to")
  eq(list.chosen, 0, "none chosen yet")
  eq(list.items[1].label:match("^tempo") ~= nil, true, "the first is tempo")
  eq(type(list.items[1].desc), "string", "with its description")
  daw.keymap.feed("<Tab>")
  eq(modal().prompt.matches.chosen, 1, "Tab chooses the first")
  daw.keymap.feed("<Esc>")
  eq(modal().prompt, nil, "shut")
end)

test("a long list of candidates is told ten at a time with the one chosen among them", function()
  calm()
  daw.keymap.feed(":")
  daw.keymap.feed("<Tab>")
  for _ = 1, 14 do daw.keymap.feed("<Tab>") end
  local list = modal().prompt.matches
  eq(#list.items, 10, "ten shown")
  eq(list.total > 10, true, "of more")
  eq(list.chosen >= 1 and list.chosen <= 10, true, "the chosen one is among them")
  daw.keymap.feed("<Esc>")
end)

test("the quickfix count is told for the status bar, worst level first", function()
  calm()
  eq(modal().qf, nil, "nothing without entries")
  daw.qf.set({
    { text = "one", level = "error" },
    { text = "two", level = "warning" },
    { text = "three", level = "warning" },
  }, { title = "Mine" })
  local qf = modal().qf
  eq(qf.text, "qf E1 W2", "as the terminal says it")
  eq(qf.level, 2, "an error colours it")
end)

test("a track's sends are told with their target and level", function()
  fresh()
  local a, b = daw.add_track({ name = "a" }), daw.add_track({ name = "Reverb" })
  api.track_set(a.id, "sends", { { target = b.id, level = -6 } })
  daw.flush()
  local sends = daw.frontend.state(-1).tracks[1].sends
  eq(#sends, 1, "one send")
  eq(sends[1].name .. " " .. sends[1].level, "Reverb -6", "where to and how loud")
end)

test("a render's peak keeps its sign and a clipping one is a warning", function()
  calm()
  daw.emit("render.done", { path = "/x/loud.wav", seconds = 3, peak = 2.04 })
  eq(daw.ui.message.text:find("peak +6.2 dB", 1, true) ~= nil, true, "the plus sign: " .. daw.ui.message.text)
  eq(daw.ui.message.level, "warn", "a warning")
  daw.emit("render.done", { path = "/x/soft.wav", seconds = 3, peak = 0.5 })
  eq(daw.ui.message.text:find("peak -6.0 dB", 1, true) ~= nil, true, "the minus sign: " .. daw.ui.message.text)
  eq(daw.ui.message.level, "info", "not a warning")
end)
