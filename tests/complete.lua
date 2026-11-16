-- Tests of completion (`daw.complete`): sources, requests and their
-- deadlines, the ghost notes in the piano roll and the keys that take them.
-- The sources here are made for the tests: one that answers at once, one
-- that answers late, one that never does, ones that fail. Loaded by
-- tests/suite.lua with its helpers.
local T = ...
local eq = T.eq
local api = daw.api
local complete = daw.complete
local roll = daw.ui.views.pianoroll

local log = {}

--- A test that leaves the piano roll closed and the arrange view focused,
--- as the tests after it expect, however it ends.
local function test(name, fn)
  T.test(name, function()
    local ok, err = xpcall(fn, debug.traceback)
    complete.dismiss()
    daw.keymap.feed("<Esc><Esc>")
    daw.ui.hide("pianoroll")
    daw.ui.focus("arrange")
    if not ok then error(err, 0) end
  end)
end

--- Wait, letting timers fire, until `cond()` holds or `ms` have passed.
local function wait_for(cond, ms)
  local limit = api.now() + (ms or 5000)
  while not cond() and api.now() < limit do daw.wait(10) end
  return cond()
end

local function n(pitch, start, length) return { pitch = pitch, start = start, length = length or 1 } end

--- A source that answers at once with `items` (a list, or a function of the context).
local function fixed(name, items, priority)
  return {
    name = name, priority = priority or 0,
    complete = function(ctx, done)
      log[#log + 1] = name .. " asked " .. ctx.trigger
      done(type(items) == "function" and items(ctx) or items)
    end,
  }
end

--- A source that answers after `ms`, and notes when it is cancelled.
local function slow(name, ms, items, priority)
  return {
    name = name, priority = priority or 0,
    complete = function(ctx, done)
      log[#log + 1] = name .. " asked " .. ctx.id
      daw.defer(function() done(type(items) == "function" and items(ctx) or items) end, ms)
    end,
    cancel = function(ctx) log[#log + 1] = name .. " cancelled " .. ctx.id end,
  }
end

--- A track with a clip of four notes open in the piano roll, the cursor
--- after them.
local function start()
  T.fresh()
  complete.dismiss()
  daw.keymap.feed("<Esc><Esc>")
  while daw.ui.float do daw.ui.close() end
  log = {}
  local t = daw.add_track({ name = "Lead" })
  local clip = t:add_clip({ start = 0, length = 4, notes = { n(60, 0), n(62, 1), n(64, 2), n(65, 3) } })
  roll:edit(clip)
  roll:set(65, 4)
  daw.flush()
  api.undo_checkpoint()
  return t, clip
end

--- Run `fn` with the sources registered and the options set, taking them
--- away afterwards whatever happens.
local function with(sources, opts, fn)
  local saved = {}
  for name, value in pairs(opts) do saved[name] = daw.opt[name] end
  daw.opt.complete_auto = false
  for name, value in pairs(opts) do daw.opt[name] = value end
  for _, s in ipairs(sources) do complete.register(s) end
  local ok, err = xpcall(fn, debug.traceback)
  for _, s in ipairs(sources) do complete.unregister(s.name) end
  complete.dismiss()
  daw.opt.complete_auto = true
  for name, value in pairs(saved) do daw.opt[name] = value end
  if not ok then error(err, 0) end
end

local function screen()
  return table.concat(api.ui_snapshot(120, 40), "\n")
end

local function shown_notes()
  local cur = complete.current()
  if not cur then return "" end
  local out = {}
  for i, x in ipairs(cur.item.notes) do out[i] = string.format("%d@%g", x.pitch, x.start) end
  return table.concat(out, " ")
end

local next_bar = { { label = "rise", notes = { n(67, 4), n(69, 5) } }, { label = "fall", notes = { n(64, 4), n(62, 5) } } }

test("without a source nothing is suggested and the piano roll's keys are as they were", function()
  start()
  eq(complete.request("manual"), nil, "nobody to ask")
  eq(complete.current(), nil, "nothing shows")
  eq(roll:subscope(), nil, "no keys of its own")
  daw.keymap.feed("<Esc>")
  eq(daw.ui.focused, "arrange", "Escape leaves the piano roll as before")
end)

test("a suggestion shows as ghost notes with its badge and changes nothing in the project", function()
  local _, clip = start()
  with({ fixed("fixed", next_bar) }, {}, function()
    local edits, before = api.project_get().edits, T.melody(clip)
    daw.keymap.feed("<C-Space>")
    eq(shown_notes(), "67@4 69@5", "the first alternative shows")
    eq(log[1], "fixed asked manual", "the source was asked by the key")
    local text = screen()
    eq(text:find("1/2 fixed: rise", 1, true) ~= nil, true, "the badge says which of how many, from where")
    eq(text:find("G4", 1, true) ~= nil, true, "the ghost notes are drawn with their names")
    eq(T.melody(clip), before, "the clip is as it was")
    eq(api.project_get().edits, edits, "and nothing was edited")
  end)
end)

test("tab accepts the whole suggestion as one undo step", function()
  local _, clip = start()
  with({ fixed("fixed", { { label = "on", notes = { n(67, 4), n(69, 5, 2), n(71, 7) } } }) }, {}, function()
    local before = T.melody(clip)
    daw.keymap.feed("<C-Space>")
    T.keys("<Tab>")
    eq(T.melody(clip), before .. " 67@4+1 69@5+2 71@7+1", "every note is written")
    eq(clip.length, 8, "the clip grew to hold them, by whole bars")
    eq(complete.current(), nil, "and the suggestion is gone")
    eq(roll.beat, 8, "the cursor is where they end")
    daw.undo()
    eq(T.melody(clip), before, "one undo takes all of it away")
    eq(clip.length, 4, "the clip's length too")
  end)
end)

test("ctrl-l accepts exactly the next onset, a chord or a note, and the rest stays", function()
  local _, clip = start()
  local item = { label = "on", notes = { n(62, 5), n(60, 4), n(64, 4), n(67, 4), n(65, 5.5) } }
  with({ fixed("fixed", { item, { label = "other", notes = { n(48, 4) } } }) }, {}, function()
    local before = T.melody(clip)
    daw.keymap.feed("<C-Space>")
    T.keys("<C-l>")
    eq(T.melody(clip), before .. " 60@4+1 64@4+1 67@4+1", "the chord that starts first, whole")
    eq(shown_notes(), "62@5 65@5.5", "the rest still shows")
    eq(#complete.current().items, 1, "alone, without the other alternatives")
    eq(roll.beat, 5, "the cursor waits where the rest begins")
    T.keys("<C-l>")
    eq(T.melody(clip), before .. " 60@4+1 64@4+1 67@4+1 62@5+1", "then one note")
    T.keys("<C-l>")
    eq(complete.current(), nil, "the last one ends the suggestion")
    daw.undo()
    eq(T.melody(clip), before .. " 60@4+1 64@4+1 67@4+1 62@5+1", "each part is an undo step of its own")
  end)
end)

test("alternatives are stepped through with ctrl-n and ctrl-p and picked with alt and a digit", function()
  start()
  local three = { next_bar[1], next_bar[2], { label = "stay", notes = { n(65, 4) } } }
  with({ fixed("fixed", three) }, {}, function()
    complete.request()
    daw.keymap.feed("<C-n>")
    eq(complete.current().index, 2, "the next")
    daw.keymap.feed("<C-n><C-n>")
    eq(complete.current().index, 1, "round past the last")
    daw.keymap.feed("<C-p>")
    eq(complete.current().index, 3, "and back past the first")
    daw.keymap.feed("<A-2>")
    eq(shown_notes(), "64@4 62@5", "Alt-2 shows the second")
    daw.keymap.feed("<A-9>")
    eq(complete.current().index, 2, "a digit with no alternative does nothing")
  end)
end)

test("escape dismisses the suggestion before it leaves insert mode or the piano roll", function()
  start()
  with({ fixed("fixed", next_bar) }, {}, function()
    daw.keymap.feed("i<C-Space>")
    eq(complete.current() ~= nil, true, "shows in insert mode")
    daw.keymap.feed("<Esc>")
    eq(complete.current(), nil, "the first Escape dismisses it")
    eq(daw.keymap.mode, "i", "and stays in insert mode")
    daw.keymap.feed("<Esc>")
    eq(daw.keymap.mode, "n", "the second leaves insert mode")
    daw.keymap.feed("<C-Space><C-e>")
    eq(complete.current(), nil, "Ctrl-e dismisses too")
    daw.keymap.feed("<C-Space><Esc>")
    eq(daw.ui.focused, "pianoroll", "in normal mode Escape dismisses first")
    daw.keymap.feed("<Esc>")
    eq(daw.ui.focused, "arrange", "and only then leaves the piano roll")
  end)
end)

test("a request shows what came by the deadline and adds late answers at the end", function()
  start()
  local sizes = {}
  local id = daw.on("complete.changed", function()
    local cur = complete.current()
    sizes[#sizes + 1] = cur and #cur.items or 0
  end)
  with({ fixed("quick", { next_bar[1] }), slow("late", 900, { next_bar[2] }, 100) }, { complete_deadline_ms = 200 }, function()
    complete.request()
    eq(complete.current(), nil, "nothing before the deadline while one source is still out")
    eq(complete.pending(), true, "the request waits")
    eq(wait_for(function() return complete.current() and #complete.current().items == 2 end), true, "the late answer arrives")
    eq(sizes[1], 1, "what came in time showed first")
    eq(sizes[#sizes], 2, "then the late one was added")
    eq(complete.current().items[2].source, "late", "at the end, though its source ranks higher")
    eq(complete.pending(), false, "nothing is owed any more")
  end)
  daw.off(id)
end)

test("answers that all come in time show at once, in the sources' order", function()
  start()
  with({ fixed("low", { next_bar[1] }, 1), fixed("high", { next_bar[2] }, 9) }, {}, function()
    complete.request()
    local cur = complete.current()
    eq(cur and #cur.items, 2, "both, without waiting for the deadline")
    eq(cur.items[1].source, "high", "the higher priority first")
  end)
end)

test("a source that never answers does not hold up the others", function()
  start()
  local never = {
    name = "never", complete = function() end,
    cancel = function(ctx) log[#log + 1] = "never cancelled " .. ctx.id end,
  }
  with({ never, fixed("quick", next_bar) }, { complete_deadline_ms = 50 }, function()
    local id = complete.request()
    eq(wait_for(function() return complete.current() ~= nil end), true, "the others show at the deadline")
    complete.dismiss()
    eq(log[#log], "never cancelled " .. id, "dismissing cancels what is still owed")
  end)
end)

test("a newer request cancels the older one and its late answer is dropped", function()
  start()
  local function labelled(ctx) return { { label = "for " .. ctx.id, notes = { n(67, 4) } } } end
  with({ slow("late", 150, labelled) }, { complete_deadline_ms = 1000 }, function()
    local first = complete.request()
    local second = complete.request()
    eq(log[#log - 1], "late cancelled " .. first, "the older one is cancelled")
    eq(wait_for(function() return complete.current() ~= nil end), true, "the newer one shows")
    daw.wait(300)
    eq(#complete.current().items, 1, "the older answer never joins it")
    eq(complete.current().item.label, "for " .. second, "it is the newer answer that shows")
  end)
end)

test("an edit of the clip dismisses the suggestion and cancels the request", function()
  local _, clip = start()
  with({ fixed("fixed", next_bar) }, {}, function()
    complete.request()
    clip:add_note(n(72, 0))
    daw.flush()
    eq(complete.current(), nil, "an edit dismisses what shows")
  end)
  with({ slow("late", 200, next_bar) }, {}, function()
    local id = complete.request()
    clip:add_note(n(74, 0))
    daw.flush()
    eq(log[#log], "late cancelled " .. id, "and cancels what is owed")
    daw.wait(400)
    eq(complete.current(), nil, "whose answer is dropped")
  end)
end)

test("a source that fails or answers nonsense never breaks the piano roll", function()
  start()
  local crash = { name = "crash", complete = function() error("boom") end }
  local twice = {
    name = "twice",
    complete = function(_, done)
      done({ { label = "once", notes = { n(60, 4) } } })
      done({ { label = "again", notes = { n(61, 4) } } })
    end,
  }
  local nonsense = fixed("nonsense", {
    "not an item", { label = "empty" }, { label = "broken", notes = { { pitch = 0 / 0, start = 4, length = 1 }, { pitch = 60, start = 4, length = -1 } } },
    { label = "half", notes = { { pitch = 61.6, at = 4, length = 1, velocity = 400 }, "x" } },
  })
  local garbage = fixed("garbage", "garbage")
  with({ crash, twice, nonsense, garbage, fixed("fine", next_bar) }, {}, function()
    complete.request()
    local labels = {}
    for i, item in ipairs(complete.current().items) do labels[i] = item.label end
    table.sort(labels)
    eq(table.concat(labels, " "), "fall half once rise", "what is usable shows, each source's first answer only")
    for _, item in ipairs(complete.current().items) do
      if item.label == "half" then
        eq(item.notes[1].pitch .. "@" .. item.notes[1].start .. " v" .. item.notes[1].velocity, "62@4 v127", "made whole")
      end
    end
    roll:layer("broken", { order = 45, draw = function() error("layer boom") end, marks = function() error("marks boom") end })
    local ok, text = pcall(screen)
    roll:layer("broken", nil)
    eq(ok, true, "drawing goes on past a failing layer")
    eq(text:find("1/4", 1, true) ~= nil, true, "with the suggestion drawn")
  end)
  with({ crash }, {}, function()
    eq(complete.request() ~= nil, true, "a request to a failing source alone is still made")
    eq(complete.current(), nil, "and shows nothing")
    eq(complete.pending(), false, "and waits for nothing")
  end)
end)

test("suggestions come by themselves after an idle pause, never while playing or recording", function()
  local _, clip = start()
  api.engine_restart({ backend = "null" })
  with({ fixed("fixed", next_bar) }, { complete_idle_ms = 30 }, function()
    complete.poke()
    daw.wait(150)
    eq(complete.current(), nil, "not while automatic suggestions are off")
    daw.opt.complete_auto = true
    daw.transport.play()
    clip:add_note(n(72, 0))
    daw.flush()
    daw.wait(200)
    eq(complete.current(), nil, "not while playing")
    eq(#log, 0, "the sources are not even asked")
    daw.transport.stop()
    daw.flush()
    complete.poke()
    eq(wait_for(function() return complete.current() ~= nil end), true, "after a pause when stopped")
    eq(log[1], "fixed asked auto", "asked as an automatic request")
    daw.transport.play()
    daw.flush()
    eq(complete.current(), nil, "and hidden when the transport starts")
    eq(roll:subscope(), nil, "its keys with it")
    daw.transport.stop()
    daw.flush()
  end)
end)

test("a source that only answers keys is not asked by itself", function()
  start()
  local manual = fixed("manual", next_bar)
  manual.auto = false
  with({ manual }, { complete_idle_ms = 20 }, function()
    daw.opt.complete_auto = true
    complete.poke()
    daw.wait(150)
    eq(#log, 0, "not after a pause")
    complete.request()
    eq(complete.current() ~= nil, true, "but when asked")
  end)
end)

test("complete.show draws ghost notes for any module, with or without the keys", function()
  local _, clip = start()
  complete.show({ { label = "preview", notes = { n(70, 4) } } }, { keys = false })
  eq(shown_notes(), "70@4", "shown without a source")
  eq(roll:subscope(), nil, "a preview takes no keys")
  eq(screen():find("preview", 1, true) ~= nil, true, "it is drawn")
  complete.show({})
  eq(complete.current(), nil, "an empty list hides it")
  complete.show({ { label = "fix", notes = { n(70, 4) }, remove = { 4 }, velocities = { [1] = 40 } } })
  T.keys("<Tab>")
  eq(T.melody(clip), "60@0+1 62@1+1 64@2+1 70@4+1", "accepting writes it, replacing what it names")
  eq(clip:notes()[1].velocity, 40, "with its velocities")
end)

test("the window is told the ghost notes, a chip per alternative and the toolbar switch", function()
  local _, clip = start()
  with({ fixed("fixed", next_bar) }, {}, function()
    local function told() return daw.frontend.state(daw.frontend.revision).modal.roll end
    local tools = told().tools
    eq(tools[1] and tools[1].label, "Suggest", "the switch for automatic suggestions")
    eq(tools[1].on, false, "off here")
    daw.frontend.act[tools[1].act](clip.id)
    eq(daw.opt.complete_auto, true, "a click turns it on")
    daw.opt.complete_auto = false
    complete.request()
    local over = told().over
    local ghosts, chips = 0, {}
    for _, mark in ipairs(over) do
      if mark.badge then chips[#chips + 1] = mark else ghosts = ghosts + 1 end
    end
    eq(ghosts, 2, "the ghost notes, in front of the clip's")
    eq(#chips, 3, "a chip for each alternative, and one for what shows")
    eq(chips[3].label, "1/2 fixed: rise", "which says what it is")
    daw.frontend.act[chips[2].act](clip.id, chips[2].arg)
    eq(complete.current().index, 2, "a click on another chip shows it")
    local before = T.melody(clip)
    over = told().over
    daw.frontend.act[over[#over].act](clip.id, over[#over].arg)
    eq(T.melody(clip), before .. " 64@4+1 62@5+1", "a click on the one showing accepts it")
  end)
end)

test("hearing a suggestion changes nothing in the project", function()
  local t, clip = start()
  t:add_device("synth")
  api.engine_restart({ backend = "null" })
  with({ fixed("fixed", next_bar) }, {}, function()
    complete.request()
    local edits, before = api.project_get().edits, T.melody(clip)
    daw.keymap.feed("gh")
    daw.wait(300)
    eq(T.melody(clip), before, "the clip is as it was")
    eq(api.project_get().edits, edits, "nothing was edited")
    eq(complete.current() ~= nil, true, "and the suggestion still shows")
    complete.dismiss()
  end)
end)
