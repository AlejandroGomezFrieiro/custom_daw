-- Tests of small things in the terminal UI that people trip over: the
-- mixer's fader scale, texts that said the wrong key, what leaving insert
-- mode says, the order of the pickers, how the messages are shown, and a
-- window whose buffer went with the project. Loaded by tests/suite.lua with
-- its helpers.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = daw.api

local function shot(w, h) return api.ui_snapshot(w or 140, h or 44) end
local function screen(w, h) return table.concat(shot(w, h), "\n") end

--- The character in a cell of the screen.
local function cell(x, y, w, h)
  local col = 0
  for ch in (shot(w, h)[y + 1] or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if col == x then return ch end
    col = col + api.str_width(ch)
  end
end

local function start()
  fresh()
  api.engine_restart({ backend = "null" })
  daw.keymap.feed("<Esc><Esc>")
  while daw.ui.float do daw.ui.close() end
  for _, name in ipairs({ "pianoroll", "mixer", "devices", "session" }) do daw.ui.hide(name) end
  daw.ui.focus("arrange")
end

test("the mixer's fader scale labels the rows its cap takes", function()
  start()
  daw.add_track({ name = "A" })
  daw.ui.show("mixer")
  local mixer = daw.ui.views.mixer
  api.undo_checkpoint()
  shot(160, 60)
  local rect
  for _, r in ipairs(daw.ui.rects) do if r.name == "mixer" then rect = r end end
  local s = mixer.geometry.strips[#mixer.geometry.strips]
  local fx = s.x + math.floor(s.w / 2) + 1
  for _, mark in ipairs({ 6, 0, -6, -12, -24, -48 }) do
    daw.master.volume = mark
    local y = rect.y + 1 + s.y + s.rows - 1 - mixer.fader_row(mark, s.rows)
    eq(cell(rect.x + fx, y, 160, 60), daw.draw.g.fader, mark .. " dB: the cap is on its row")
    local label = (mark > 0 and "+" or "") .. mark
    eq(cell(rect.x + 3 - #label, y, 160, 60), label:sub(1, 1), mark .. " dB: and the scale names it there")
  end
  daw.master.volume = 0
end)

test("the welcome page and the empty roll name the right keys", function()
  start()
  local lines = screen()
  eq(lines:find("I%s+type notes") ~= nil, true, "`I` types notes like a piano")
  local roll = daw.ui.views.pianoroll
  daw.ui.show("pianoroll")
  local text = screen(140, 44)
  local at = text:find("press Enter", 1, true)
  eq(at ~= nil, true, "the roll asks for Enter after a space: " .. (text:match("press%S*") or "nothing"))
  daw.ui.hide("pianoroll")
  eq(roll ~= nil, true)
end)

test("leaving insert mode says how many notes were written", function()
  start()
  local t = daw.add_track({ name = "Keys" })
  local clip = t:add_clip({ start = 0, length = 4 })
  daw.cursor.set_track(t)
  daw.cursor.set_beat(0)
  api.undo_checkpoint()
  daw.ui.views.pianoroll:edit(clip)
  daw.ui.focus("pianoroll")
  daw.keymap.feed("I")
  daw.keymap.feed("a")
  daw.keymap.feed("s")
  daw.keymap.feed("<Esc>")
  eq(#clip:notes(), 2, "two notes were typed")
  eq(daw.ui.messages[#daw.ui.messages].text, "wrote 2 notes", "and Escape says so")
  daw.keymap.feed("I")
  daw.keymap.feed("<Esc>")
  eq(daw.ui.messages[#daw.ui.messages].text, "wrote 2 notes", "an insert that wrote nothing says nothing")
end)

test("the device picker lists instruments first on a track without one, effects on a track with one", function()
  start()
  local library = daw.fx.library()
  local kept = { library.favourites, library.recent }
  library.favourites, library.recent = {}, {}
  local t = daw.add_track({ name = "Empty" })
  daw.cursor.set_track(t)
  local items = daw.pick.sources.devices.items()
  eq(items[1].category, "instrument", "a track with nothing in it is offered instruments first")
  eq(daw.fx.preferred(t.id), "instrument", "that is what `preferred` says")
  t:add_device("synth")
  items = daw.pick.sources.devices.items()
  eq(items[1].category, "effect", "once it has one, effects come first")
  eq(daw.fx.preferred(0), "effect", "and the master wants effects")
  library.favourites, library.recent = kept[1], kept[2]
end)

test("the send picker lists returns before tracks that play an instrument, and a new send starts at -12 dB", function()
  start()
  local source = daw.add_track({ name = "Source" })
  local synth = daw.add_track({ name = "Synth" })
  synth:add_device("synth")
  local verb = daw.add_track({ name = "Verb" })
  verb:add_device("reverb")
  daw.cursor.set_track(source)
  local seen
  local pick = daw.pick
  daw.pick = setmetatable({}, { __index = pick, __call = function(_, spec) seen = spec end })
  daw.commands.run("send")
  daw.pick = pick
  eq(seen.items[1].name, "Verb", "the return is first")
  eq(seen.items[2].name, "Synth", "the instrument after it")
  daw.commands.run("send", { "Verb" })
  eq(source:get().sends[1].level, -12, "a send starts at -12 dB")
  daw.opt.send_level = -3
  daw.commands.run("send", { "Synth" })
  eq(source:get().sends[2].level, -3, "or at what `send_level` says")
  daw.opt.send_level = -12
end)

test(":messages keeps every message and wraps what is longer than the window", function()
  start()
  local before = #daw.ui.messages
  daw.notify("added Synth to Track 1")
  local long = "one two three four five six seven eight nine ten " .. ("long "):rep(30) .. "end"
  daw.notify(long)
  eq(#daw.ui.messages, before + 2, "both are kept")
  daw.commands.run("messages")
  local text = screen(140, 44)
  eq(text:find("added Synth to Track 1", 1, true) ~= nil, true, "the short one is shown")
  eq(text:find("end", 1, true) ~= nil, true, "the long one's last word is shown too, on a row of its own")
  daw.ui.close()
end)

test("a window whose curve is gone with the project closes", function()
  start()
  local t = daw.add_track({ name = "A" })
  local lane = t:automate("volume")
  local uri = daw.address.lane(lane.id)
  daw.commands.run("vs", { uri })
  local function shows()
    for _, entry in ipairs(daw.layout.all_windows()) do
      local buf = daw.layout.buf_of(entry.win)
      if buf and buf.target == uri then return true end
    end
    return false
  end
  eq(shows(), true, "a window shows the lane")
  fresh()
  eq(shows(), false, "after a new project it does not")
  daw.keymap.feed("<Esc><Esc>")
  daw.commands.run("only")
end)
