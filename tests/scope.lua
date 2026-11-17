-- Tests of narrowing to a group (daw.scope), freezing tracks and groups
-- (daw.freeze, crates/daw-core/src/freeze.rs) and stems by group
-- (daw.stems). Loaded by tests/suite.lua with its helpers.
local T = ...
local test, eq, near, fails, fresh = T.test, T.eq, T.near, T.fails, T.fresh
local api = daw.api
local ffi = require("ffi")
local L = daw.layout

local W, H = 160, 48

local initial = L.capture()

local function reset()
  daw.keymap.feed("<Esc><Esc>")
  while daw.ui.float do daw.ui.close() end
  L.restore(initial)
  daw.opt.scope_rest = "play"
  daw.ui.focus("arrange")
end

local function start()
  fresh()
  api.engine_restart({ backend = "null" })
  reset()
end

local function keys(text)
  daw.keymap.feed(text)
  api.undo_checkpoint()
end

local function screen() return table.concat(api.ui_snapshot(W, H), "\n") end

local function names(ids)
  local out = {}
  for i, id in ipairs(ids) do out[i] = api.track_get(id).name end
  return table.concat(out, " ")
end

local function wait_for(what, limit, fn)
  local waited = 0
  while not fn() do
    if waited >= limit then error("waited " .. limit .. " ms for " .. what, 2) end
    daw.wait(20)
    waited = waited + 20
  end
end

--- A track with a synth playing a few notes.
local function synth(name, pitch)
  local t = daw.add_track({ name = name })
  t:add_device("synth", { attack = 0.001, release = 0.05 })
  t:add_clip({ start = 0, length = 4, notes = {
    { pitch = pitch, start = 0, length = 1 }, { pitch = pitch + 4, start = 1, length = 1 }, { pitch = pitch + 7, start = 2, length = 2 },
  } })
  return t
end

--- Orchestra holding Strings (Violins, Cellos) and Brass (Horns); Drums
--- outside it.
local function orchestra()
  local violins, cellos, horns = synth("Violins", 72), synth("Cellos", 48), synth("Horns", 60)
  local drums = synth("Drums", 36)
  local strings = daw.groups.make({ violins, cellos }, "Strings")
  local brass = daw.groups.make({ horns }, "Brass")
  local orch = daw.groups.make({ strings, brass }, "Orchestra")
  daw.flush()
  api.undo_checkpoint()
  return { violins = violins, cellos = cellos, horns = horns, drums = drums, strings = strings, brass = brass, orchestra = orch }
end

--- The samples of a 32-bit float WAV file written by `daw.render`.
local function samples(path)
  local data = T.read_file(path)
  local at = data:find("data", 1, true)
  local n = (#data - (at + 7)) / 4
  local buf = ffi.new("float[?]", n)
  ffi.copy(buf, data:sub(at + 8), n * 4)
  return buf, n
end

--- The largest difference between two float WAV files, sample by sample,
--- and the larger file's peak.
local function difference(a, b)
  local x, n = samples(a.path)
  local y, m = samples(b.path)
  local worst, peak = 0, 0
  for i = 0, math.min(n, m) - 1 do
    worst = math.max(worst, math.abs(x[i] - y[i]))
    peak = math.max(peak, math.abs(x[i]))
  end
  return worst, peak, n, m
end

local renders = 0
local function render(opts)
  renders = renders + 1
  return daw.render(T.scratch .. "/scope" .. renders .. ".wav", daw.util.merge({ bits = 32, tail = 1 }, opts or {}))
end

-- Narrowing ---------------------------------------------------------------------------

test("narrowing to a group opens a tab of its tracks alone, and widening comes back", function()
  start()
  local o = orchestra()
  daw.cursor.set_track(o.drums)
  daw.scope.narrow("Strings")
  eq(#daw.ui.tabs, 2, "a tab of its own")
  eq(daw.ui.tab, 2, "gone to")
  eq(L.tab_title(daw.ui.tabs[2]), "Strings", "named after the group")
  eq(names(daw.groups.rows()), "Strings Violins Cellos", "the arrange view's rows")
  eq(daw.cursor.track_id(), o.strings.id, "the cursor came inside")
  local text = screen()
  eq(text:find("Violins", 1, true) ~= nil and text:find("Horns", 1, true) == nil and text:find("Drums", 1, true) == nil, true,
    "drawn: only the strings")
  eq(text:find("narrowed Strings", 1, true) ~= nil, true, "the status line says so")
  -- The rest of the program sees the scope too.
  local items = daw.pick.sources.tracks.items()
  eq(#items, 3, "the track picker lists its tracks")
  eq(names(daw.scope.tracks()), "Strings Violins Cellos", "daw.scope.tracks")
  daw.ui.show("mixer")
  eq(screen():find("Horns", 1, true), nil, "the mixer has no strip for the rest")
  daw.ui.hide("mixer")
  -- Motions stay inside.
  keys("G")
  eq(daw.cursor.track_id(), o.cellos.id, "G: the last track of the scope")
  keys("gg")
  eq(daw.cursor.track_id(), o.strings.id, "gg: the first")
  -- Folding the group itself does not empty its tab.
  daw.groups.fold(o.strings.id, true)
  eq(names(daw.groups.rows()), "Strings Violins Cellos", "the scope's own fold is open in it")
  daw.groups.fold(o.strings.id, false)
  -- Back out.
  eq(daw.scope.widen(), true, "widened")
  eq(#daw.ui.tabs, 1, "the tab closed")
  eq(daw.scope.current(), nil, "no scope")
  eq(#daw.groups.rows(), 7, "every track again")
  reset()
end)

test("zn narrows to the group at the cursor and zw widens; scopes open side by side in tabs", function()
  start()
  local o = orchestra()
  daw.cursor.set_track(o.violins)
  keys("zn")
  eq(daw.scope.current(), o.strings.id, "zn on a member: its group")
  local seen = daw.frontend.revision
  keys("gt")
  eq(daw.frontend.revision > seen, true, "a window is told to draw the other tab's tracks")
  eq(daw.scope.current(), nil, "the first tab is wide")
  eq(#daw.groups.rows(), 7, "and shows everything")
  daw.cursor.set_track(o.brass)
  keys("zn")
  eq(#daw.ui.tabs, 3, "a second scope, in a tab of its own")
  eq(names(daw.groups.rows()), "Brass Horns", "the brass")
  daw.scope.narrow("Strings")
  eq(#daw.ui.tabs, 3, "narrowing to a group that has a tab goes there")
  eq(daw.scope.current(), o.strings.id, "the strings' tab")
  eq(names(daw.groups.rows()), "Strings Violins Cellos", "with its rows")
  keys("zw")
  eq(#daw.ui.tabs, 2, "zw closed it")
  eq(daw.scope.current(), nil, "back in the wide tab")
  reset()
end)

test("in a scope Ex ranges, :g and :s see only its tracks", function()
  start()
  local o = orchestra()
  daw.scope.narrow("Strings")
  local function range(text) return names(daw.ex.range(text).tracks) end
  eq(range("t*"), "Strings Violins Cellos", "t*")
  eq(range("t2"), "Violins", "t2 is the scope's second track")
  eq(range("t$"), "Cellos", "t$ its last")
  eq(range("t/o/"), "Violins Cellos", "t/o/ searches the scope's names")
  local _, _, err = daw.ex.range("t5")
  eq(tostring(err):find("3 tracks", 1, true) ~= nil, true, "t5 is past its end: " .. tostring(err))
  keys(":%s/c3/d3/<CR>")
  daw.flush()
  local function first(t) return t:clips()[1]:notes()[1].pitch end
  eq(first(o.cellos), 50, ":%s changed the scope's notes")
  eq(first(o.drums), 36, "and not the rest's")
  keys(":g/c4/d<CR>")
  eq(#o.horns:clips()[1]:notes(), 3, ":g finds nothing in the scope to delete: the horns' C4 is outside it")
  keys(":g/c5/d<CR>")
  eq(#o.violins:clips()[1]:notes(), 2, ":g/c5/d deletes the violins' C5")
  reset()
end)

test("a track added in a scope goes into its group; one undo tree across the tabs", function()
  start()
  local o = orchestra()
  daw.scope.narrow("Strings")
  local violas = daw.add_track({ name = "Violas" })
  daw.flush()
  daw.wait(20)
  eq(daw.groups.of(violas.id), o.strings.id, "the new track is in Strings")
  eq(names(daw.groups.rows()), "Strings Violins Cellos Violas", "and in sight")
  api.undo_checkpoint()
  o.violins.name = "First violins"
  api.undo_checkpoint()
  daw.scope.widen()
  daw.undo()
  eq(o.violins.name, "Violins", "the rename made in the scope is undone from outside it")
  daw.undo()
  eq(pcall(api.track_get, violas.id), false, "and so is the track added there")
  reset()
end)

test("daw://tracks in a scope lists its tracks, and writing it leaves the rest alone", function()
  start()
  local o = orchestra()
  -- A buffer an earlier test read is forgotten, so that this one reads afresh.
  local function forget()
    for _, buf in ipairs(L.buffers_list()) do
      if buf.type == "textbuf" then L.buf_delete(buf) end
    end
  end
  forget()
  T.after(forget)
  -- One read wide is read again in the narrowed tab.
  keys(":e daw://tracks<CR>")
  keys(":b arrange<CR>")
  daw.scope.narrow("Strings")
  keys(":e daw://tracks<CR>")
  local lines = {}
  for i, l in ipairs(daw.textbuf.buf().state.text.lines) do lines[i] = l.text end
  local text = table.concat(lines, "\n")
  eq(text:find("Violins", 1, true) ~= nil and text:find("Horns", 1, true) == nil, true, "only the strings: " .. text)
  -- Rename the cellos and write: the rest keeps its tracks and their order.
  keys("G0")
  keys("cw\"Basses\"<Esc>")
  keys(":w<CR>")
  keys("y")
  eq(o.cellos.name, "Basses", "renamed")
  eq(names(api.track_list()), "Orchestra Strings Violins Basses Brass Horns Drums", "the rest as it was")
  reset()
end)

-- What the rest does ---------------------------------------------------------------------

test("scope_rest=mute silences the rest while the scope's tab is in front", function()
  start()
  local o = orchestra()
  daw.project.tempo = 60
  daw.scope.narrow("Strings")
  daw.opt.scope_rest = "mute"
  daw.transport.seek(0)
  daw.transport.play()
  wait_for("the violins", 3000, function() return select(1, o.violins:meter()) > 0.01 end)
  daw.wait(100)
  eq(select(1, o.drums:meter()) < 1e-4, true, "the drums are silent")
  eq(select(1, o.orchestra:meter()) > 0.01, true, "the group the strings pass through is not")
  keys("gt")
  wait_for("the drums", 3000, function() return select(1, o.drums:meter()) > 0.01 end)
  daw.transport.stop()
  eq(o.drums.mute, false, "the project's mute was not touched")
  reset()
end)

test("scope_rest=frozen plays the rest from files rendered in the background", function()
  start()
  local o = orchestra()
  daw.scope.narrow("Strings")
  local edits = api.project_get().edits
  eq(names(daw.scope.rest_parts()), "Brass Drums", "the parts of the rest: whole groups, not the scope's own")
  daw.opt.scope_rest = "frozen"
  wait_for("the rest to be frozen", 20000, function() return #daw.scope.held() == 2 end)
  table.sort(api.engine_held())
  eq(#api.engine_held(), 2, "the engine plays them from files")
  eq(api.project_get().edits, edits, "the project is not changed")
  keys("gt")
  eq(#api.engine_held(), 0, "a wide tab plays everything live")
  keys("gt")
  eq(#api.engine_held(), 2, "back in the scope, the files are there already")
  -- An edit to a frozen part plays it live until it is rendered again.
  o.horns:clips()[1]:set_notes({ { pitch = 62, start = 0, length = 2 } })
  daw.flush()
  daw.wait(50)
  wait_for("the brass again", 20000, function() return #daw.scope.held() == 2 end)
  daw.scope.widen()
  eq(#api.engine_held(), 0, "widening lets it go")
  reset()
end)

-- Freezing -----------------------------------------------------------------------------

test("a frozen track renders as it did live, and its fader stays live", function()
  start()
  local t = synth("Lead", 60)
  t:add_device("delay", {})
  daw.flush()
  local live = render()
  daw.freeze.freeze(t)
  eq(daw.freeze.state(t), "frozen", "frozen")
  eq(#t:clips(), 1, "its clips are as they were")
  local frozen = render()
  local worst, peak = difference(live, frozen)
  eq(peak > 0.05, true, "it sounds")
  eq(worst < 1e-5, true, "the same sound, frozen as live: " .. worst)
  t.volume = -6
  local quieter = render()
  near(quieter.peak / frozen.peak, 10 ^ (-6 / 20), 1e-3, "the fader still works")
  reset()
end)

test("a frozen group renders as it did live; its members are held", function()
  start()
  local o = orchestra()
  o.strings:add_device("delay", {})
  o.violins.volume = -3
  daw.flush()
  local live = render()
  daw.freeze.freeze(o.strings)
  eq(daw.freeze.state(o.violins), "held", "a member is held")
  eq(daw.freeze.state(o.strings), "frozen", "the group frozen")
  local worst, peak = difference(live, render())
  eq(peak > 0.05, true, "it sounds")
  eq(worst < 1e-5, true, "the song is the same: " .. worst)
  fails(function() daw.freeze.freeze(o.violins) end, "unfreeze that first", "a held track is not frozen again")
  -- The group's fader and mute stay live.
  o.strings.mute = true
  local without = render()
  o.strings.mute = false
  local w2 = difference(live, without)
  eq(w2 > 0.01, true, "muting the frozen group takes it out")
  reset()
end)

test("freezing is one undo step and saved with the project, the file beside it", function()
  start()
  local t = synth("Pad", 55)
  daw.flush()
  api.undo_checkpoint()
  local file = daw.freeze.freeze(t)
  api.undo_checkpoint()
  daw.undo()
  eq(daw.freeze.state(t), nil, "undone")
  daw.redo()
  eq(daw.freeze.frozen(t).file, file, "and redone")
  local dir = T.scratch .. "/frozen-project"
  os.execute("mkdir -p '" .. dir .. "'")
  daw.cmd("write", { dir .. "/song.json" })
  local saved = T.read_file(dir .. "/song.json")
  eq(saved:find('"media/Pad%-frozen') ~= nil, true, "the file is named relative to the project")
  daw.project.new()
  daw.open(dir .. "/song.json")
  local pad = daw.track(api.track_list()[1])
  local frozen = daw.freeze.frozen(pad)
  eq(frozen and frozen.file:find("^/") ~= nil and io.open(frozen.file) ~= nil, true, "it opens frozen, the file found")
  daw.freeze.unfreeze(pad)
  eq(daw.freeze.state(pad), nil, ":unfreeze")
  reset()
end)

test(":freeze and :unfreeze, and an edit to a frozen track asks to unfreeze it", function()
  start()
  local t = synth("Keys", 64)
  daw.cursor.set_track(t)
  keys(":freeze<CR>")
  eq(daw.freeze.state(t), "frozen", ":freeze the cursor's track")
  local clip = t:clips()[1]
  clip:set_notes({ { pitch = 70, start = 0, length = 1 } })
  daw.flush()
  daw.wait(20)
  eq(screen():find("Keys is frozen: unfreeze it", 1, true) ~= nil, true, "asked")
  keys("y<CR>")
  eq(daw.freeze.state(t), nil, "y: unfrozen")
  keys(":freeze Keys<CR>")
  eq(daw.freeze.state(t), "frozen", ":freeze by name")
  keys(":unfreeze<CR>")
  eq(daw.freeze.state(t), nil, ":unfreeze")
  reset()
end)

test("a frozen track's heavy Lua device rests: the engine works far less", function()
  start()
  local dir = T.scratch .. "/heavy-devices"
  os.execute("mkdir -p '" .. dir .. "'")
  T.write_file(dir .. "/heavy.lua", [[
local dev = require("daw.dsp").device { name = "Heavy" }
local x = 0
function dev.process(b)
  for i = 0, b.frames - 1 do
    local s = b.left[i]
    for _ = 1, 400 do s = math.sin(s + x) * 0.5 end
    x = x + 1e-7
    b.left[i] = b.left[i] + s * 1e-6
  end
end
return dev
]])
  daw.luadev.add_dir(dir)
  local t = synth("Heavy", 60)
  t:add_device("lua:heavy")
  daw.flush()
  local function load()
    api.engine_reset_stats()
    daw.transport.seek(0)
    daw.transport.play()
    daw.wait(1500)
    daw.transport.stop()
    return api.engine_get().blocks.mean
  end
  local live = load()
  daw.freeze.freeze(t)
  daw.flush()
  local frozen = load()
  print(string.format("      block time: %.3f ms live, %.3f ms frozen", live, frozen))
  eq(frozen < live * 0.3, true, string.format("frozen %.3f ms against %.3f ms a block", frozen, live))
  reset()
end)

-- Stems by group ---------------------------------------------------------------------------

test(":render stems shows a plan of one file per group, and they add up to the mix", function()
  start()
  local o = orchestra()
  daw.flush()
  local mix = render({ master = false })
  local dir = T.scratch .. "/group-stems"
  keys(":render stems " .. dir .. " wait=true bits=32 tail=1<CR>")
  eq(daw.ui.float and daw.ui.float.name, "render.plan", "a plan first")
  local text = screen()
  eq(text:find("Orchestra.wav", 1, true) ~= nil and text:find("Drums.wav", 1, true) ~= nil, true, "a file per group: " .. text)
  eq(text:find("Violins, Cellos, Horns", 1, true) ~= nil, true, "saying what each holds")
  keys("y")
  local a = { path = dir .. "/Orchestra.wav" }
  local b = { path = dir .. "/Drums.wav" }
  eq(io.open(a.path) ~= nil and io.open(b.path) ~= nil, true, "written")
  -- The stems summed are the mix (without the master's processing).
  local x, n = samples(a.path)
  local y = samples(b.path)
  local m, k = samples(mix.path)
  local worst = 0
  for i = 0, math.min(n, k) - 1 do worst = math.max(worst, math.abs(x[i] + y[i] - m[i])) end
  eq(worst < 1e-5, true, "they add up to the mix: " .. worst)
  -- Narrowed, the parts of the group; and one group on its own.
  daw.scope.narrow("Orchestra")
  local plan = daw.stems.plan({ dir = dir })
  local list = {}
  for i, s in ipairs(plan) do list[i] = s.file:match("([^/]+)$") end
  eq(table.concat(list, " "), "Strings.wav Brass.wav", "in a scope: its groups")
  plan = daw.stems.plan({ dir = dir, tracks = true })
  list = {}
  for i, s in ipairs(plan) do list[i] = s.name end
  eq(table.concat(list, " "), "Violins Cellos Horns", "per track")
  daw.scope.widen()
  keys(":render Strings bits=32 wait=true<CR>")
  eq(daw.ui.float and daw.ui.float.name, "render.plan", "one group: a plan too")
  keys("<Esc>")
  eq(daw.ui.float, nil, "Esc leaves it")
  reset()
end)
