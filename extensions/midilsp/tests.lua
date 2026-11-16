-- Tests for extensions/midilsp, run by tests/suite.lua with its helpers.
-- Those that need MIDI LSP's engine run when one is found (daw.opt.midilsp_cmd,
-- $MIDI_LSP_ENGINE or reaper-midi-lsp on the PATH) and are skipped otherwise.
local T = ...
local eq, fresh = T.eq, T.fresh

-- Each test leaves things as the next expects them: no servers, no
-- diagnostics, the piano roll closed, whether it passed or not.
local function test(name, fn)
  T.test(name, function()
    local result = { xpcall(fn, debug.traceback) }
    daw.lsp.stop()
    daw.diagnostic.reset()
    while daw.ui.float do daw.ui.close() end
    daw.ui.views.pianoroll.clip_id = nil
    daw.ui.hide("pianoroll")
    daw.ui.focus("arrange")
    if not result[1] then error(result[2], 0) end
    return result[2]
  end)
end
local api = daw.api

local midilsp

local function load()
  if not midilsp then
    daw.opt.midilsp_autostart = false
    daw.ext.load("extensions/midilsp")
    midilsp = require("midilsp")
  end
  return midilsp
end

local function until_(fn, what, ms)
  local deadline = api.now() + (ms or 30000)
  while not fn() do
    if api.now() > deadline then error("waited in vain for " .. what, 2) end
    daw.wait(10)
  end
end

local function start()
  fresh()
  load()
  daw.lsp.stop()
  daw.diagnostic.reset()
  daw.keymap.feed("<Esc><Esc>")
  while daw.ui.float do daw.ui.close() end
  daw.ui.focus("arrange")
end

local function running(name)
  for _, c in ipairs(daw.lsp.clients()) do
    if c.name == name then return c.status == "running" end
  end
end

--- Two voices moving in parallel fifths, C5 over F4 then D5 over G4, with
--- the upper one open in the piano roll.
local function fifths()
  local upper = daw.add_track({ name = "Upper" }):add_clip({ start = 0, length = 4,
    notes = { { pitch = 72, start = 0, length = 1 }, { pitch = 74, start = 1, length = 1 } } })
  daw.add_track({ name = "Lower" }):add_clip({ start = 0, length = 4,
    notes = { { pitch = 65, start = 0, length = 1 }, { pitch = 67, start = 1, length = 1 } } })
  daw.ui.views.pianoroll:edit(upper)
  return upper
end

test("midilsp: the engine is found from the option, then the environment", function()
  start()
  local saved = daw.opt.midilsp_cmd
  daw.opt.midilsp_cmd = "/opt/engine --rules /r"
  eq(table.concat(midilsp.engine(), " "), "/opt/engine --rules /r", "the option, as words")
  midilsp.configure()
  eq(table.concat(daw.lsp.configs["midi-lsp"].cmd(), " "), "/opt/engine --rules /r --stdio", "the language role on stdio")
  eq(table.concat(daw.lsp.configs["midi-lsp-suggest"].cmd(), " "), "/opt/engine --rules /r --role suggest --stdio", "and the suggestion role")
  daw.opt.midilsp_cmd = saved
  local text = {}
  for _, line in ipairs(midilsp.info_lines()) do text[#text + 1] = type(line) == "table" and line.text or line end
  eq(table.concat(text, "\n"):find("preset default", 1, true) ~= nil, true, ":midilsp shows the settings")
end)

test("midilsp: settings are kept with the project and sent as the engine takes them", function()
  start()
  midilsp.set_rule("parallel-perfect", false)
  eq(api.project_get().meta.midilsp.rules["parallel-perfect"], false, "kept in the project")
  local s = daw.lsp.configs["midi-lsp"].settings
  eq(s.preset .. " " .. tostring(s.rules["parallel-perfect"].enabled), "default false", "as the engine's configuration")
  midilsp.set_preset("strict-counterpoint")
  eq(midilsp.settings().preset, "strict-counterpoint", "a preset")
end)

test("midilsp: Problems lists every namespace's diagnostics with their fixes, and applies one", function()
  start()
  local clip = daw.add_track({ name = "Oboe" }):add_clip({ start = 0, length = 4, notes = { { pitch = 100, start = 0, length = 1 } } })
  daw.diagnostic.set("lint", clip, { { notes = { 1 }, message = "too high", fixes = { { title = "Down an octave", edits = { { note = 1, pitch = 88 } } } } } })
  daw.cmd("problems")
  local state = daw.pick.state()
  eq(#state.matches, 2, "the diagnostic and its fix")
  eq(state.matches[2]:find("fix: Down an octave", 1, true) ~= nil, true, "the fix")
  daw.keymap.feed("<C-n><CR>")
  eq(clip:notes()[1].pitch, 88, "applied")
end)

-- With the real engine ----------------------------------------------------------

local function engine_or_skip()
  if not load().engine() then return "no MIDI LSP engine: set $MIDI_LSP_ENGINE to run these" end
end

test("midilsp: the engine marks a parallel fifth, and its fix is one undo step", function()
  local skip = engine_or_skip()
  if skip then return skip end
  start()
  local clip = fifths()
  midilsp.start(true)
  until_(function() return #daw.diagnostic.get(clip.id, { namespace = "midi-lsp" }) > 0 end, "the engine's diagnostics")
  local d
  for _, x in ipairs(daw.diagnostic.get(clip.id)) do
    if x.rule == "parallel-perfect" then d = x end
  end
  eq(d ~= nil, true, "a parallel-perfect diagnostic")
  eq(d.message:find("Parallel fifths", 1, true) ~= nil, true, "it says so: " .. d.message)
  eq(table.concat(d.notes, ","), "1,2", "on both notes")
  eq(d.source, "midi-lsp", "from the engine")
  local marks = daw.diagnostic.roll_marks(clip.id)
  eq(#marks, 2, "the window is told to mark both")
  api.undo_checkpoint()
  local actions = daw.diagnostic.actions(clip.id, 2)
  eq(actions[1].title, "Change D5 to C#5", "the engine's fix")
  actions[1].run()
  daw.flush()
  api.undo_checkpoint()
  eq(clip:notes()[2].pitch, 73, "applied")
  until_(function()
    for _, x in ipairs(daw.diagnostic.get(clip.id)) do
      if x.rule == "parallel-perfect" then return false end
    end
    return true
  end, "the fifths to be gone")
  daw.undo()
  eq(clip:notes()[2].pitch, 74, "one undo takes it back")
  until_(function() return #daw.diagnostic.get(clip.id, { namespace = "midi-lsp" }) > 0 end, "the diagnostic again")
  -- The chords it hears.
  until_(function() return daw.lsp.analysis[clip.id] end, "the analysis")
  local chords = {}
  for _, c in ipairs(daw.lsp.analysis[clip.id].chords) do chords[#chords + 1] = c.name .. "@" .. c.at end
  eq(table.concat(chords, " "), "F@0 G@1", "the chords, in project beats")
  -- Switching the rule off is sent at once.
  midilsp.set_rule("parallel-perfect", false)
  until_(function()
    for _, x in ipairs(daw.diagnostic.get(clip.id)) do
      if x.rule == "parallel-perfect" then return false end
    end
    return true
  end, "the rule to be off")
  daw.lsp.stop()
end)

test("midilsp: the engine's hover and suggestions come back", function()
  local skip = engine_or_skip()
  if skip then return skip end
  start()
  local clip = fifths()
  midilsp.start(true)
  until_(function() return running("midi-lsp") and running("midi-lsp-suggest") end, "both roles")
  local hover
  daw.lsp.hover(clip.id, 74, 1, function(sections) hover = sections end)
  until_(function() return hover end, "the hover")
  eq(hover[1].client, "midi-lsp", "the language role hovers")
  local text = table.concat(hover[1].lines, "\n")
  eq(text:find("chord  G", 1, true) ~= nil and text:find("note   D5", 1, true) ~= nil, true, "the note and the chord:\n" .. text)
  local items
  daw.lsp.complete({ clip = clip.id, at = 2, trigger = "manual" }, function(list) items = list or {} end)
  until_(function() return items end, "the suggestions")
  eq(#items > 0, true, "something suggested")
  eq(items[1].source, "midi-lsp-suggest", "by the suggestion role")
  eq(#items[1].notes > 0 and items[1].notes[1].start >= 2, true, "notes from where it was asked, in the clip's beats")
  daw.lsp.stop()
end)
