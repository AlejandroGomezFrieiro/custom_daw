-- Tests for the tutor, run by tests/suite.lua:
--
--   daw --clean --no-plugins -l tests/suite.lua tutor
--
-- Every lesson is played from start to finish by typing each step's keys as
-- a person would, and the tutor must notice each step only once it is done.
local T = ...
local daw = require("daw")
local api = daw.api
local test, eq = T.test, T.eq

local function ext()
  -- Progress and practice projects go in the suite's scratch directory,
  -- never in the user's state directory.
  daw.opt.tutor_dir = T.scratch .. "/tutor"
  if not daw.ext.loaded.tutor then daw.ext.load("extensions/tutor") end
  return require("tutor")
end

--- A clean start: no lesson running, no progress, the arrange view.
local function start()
  local tutor = ext()
  -- Some other extensions' tests leave the picker switched off.
  if not daw.pick then daw.pick = require("daw.pick") end
  if tutor.state().active then tutor.quit() end
  tutor._forget()
  os.remove(T.scratch .. "/tutor/progress.lua")
  T.fresh()
  daw.keymap.feed("<Esc><Esc>")
  daw.ui.close()
  daw.ui.focus("arrange")
  daw.flush()
  return tutor
end

--- Type keys one at a time as a person does: the kernel closes the undo
--- step after every key, and the tutor's timer looks after every key.
local function type_keys(text)
  local tutor = require("tutor")
  for _, key in ipairs(daw.keymap.parse(text)) do
    daw.keymap.feed(key)
    api.undo_checkpoint()
    daw.flush()
    tutor.poll()
  end
end

--- Do what a step's `keys` say: type them, wait, or stand in for what a
--- person does outside the keyboard (a microphone, a MIDI keyboard, quitting).
local function perform(step, lesson, from, to)
  local tutor = require("tutor")
  for index = from or 1, to or #step.keys do
    local item = step.keys[index]
    if type(item) == "string" then
      type_keys(item)
    elseif item.wait then
      api.sleep(item.wait)
      daw.flush()
      tutor.poll()
    elseif item.sim == "quit" then
      -- Quitting cannot be typed in a test: the suite would end. The tutor
      -- hears of it through `command.pre`, as it would.
      daw.emit("command.pre", { name = "quit", args = {} })
    elseif type(item.sim) == "function" then
      item.sim(lesson)
      daw.flush()
      tutor.poll()
    elseif type(item.keys) == "function" then
      type_keys(item.keys())
    end
  end
end

local panel_text = function() return require("tutor.panel").text() end
local function screen() return table.concat(api.ui_snapshot(120, 40), "\n") end

--- Every key string a step asks for appears in its text, in backticks, so
--- what is typed in the test is what the learner is told to type.
local function said(step, key)
  local text = step.say .. " " .. (step.hint or "")
  return text:find("`" .. key .. "`", 1, true) ~= nil
end

local function play_lesson(tutor, n)
  local lesson = tutor.lessons[n]
  if lesson.test and lesson.test.before then lesson.test.before() end
  local ok, err = xpcall(function()
    tutor.start(n, { fresh = true, force = true })
    eq(tutor.state().active, true, lesson.id .. ": started")
    eq(daw.ui.float and daw.ui.float.title, "Lesson " .. n .. ": " .. lesson.title, lesson.id .. ": the introduction is shown")
    type_keys("<Esc>")
    eq(daw.ui.float, nil, lesson.id .. ": any key closes the introduction")
    eq(daw.project.path, T.scratch .. "/tutor/practice/" .. lesson.id .. ".json", lesson.id .. ": the practice project is the tutor's")
    for i, step in ipairs(lesson.steps) do
      local where = lesson.id .. " step " .. i
      eq(tutor.state().step, i, where .. ": the tutor is on it")
      eq(panel_text():find(require("tutor.panel").keys(step.say), 1, true) ~= nil, true, where .. ": the panel says what to do")
      eq(screen():find(string.format("step %d of %d", i, #lesson.steps), 1, true) ~= nil, true, where .. ": the panel is on screen")
      for _, item in ipairs(step.keys) do
        local list = type(item) == "string" and { item } or item.instead or {}
        for _, key in ipairs(list) do eq(said(step, key), true, where .. ": the text asks for `" .. key .. "`") end
      end
      -- Not done yet, so not noticed.
      tutor.poll()
      eq(tutor.state().step, i, where .. ": not noticed before it is done")
      -- Half done is not done: everything but the last keys is not enough.
      local last = #step.keys
      if last > 1 and not step.early then
        perform(step, lesson, 1, last - 1)
        eq(tutor.state().step, i, where .. ": not noticed before its last keys")
        perform(step, lesson, last, last)
      else
        perform(step, lesson)
      end
      if step.unchecked then
        eq(tutor.state().step, i, where .. ": an unchecked step waits for the learner")
        type_keys(",hn")
      end
      if tutor.state().step ~= i + 1 then
        error(string.format("%s: not noticed after typing its keys (%s)\nthe panel says:\n%s", where, step.say, panel_text()), 0)
      end
      local rec = tutor.record(lesson.id).steps[i]
      eq(rec, step.unchecked and "skipped" or "done", where .. ": recorded")
      if not step.unchecked then
        eq(panel_text():find("✓ " .. (step.done or "Done."), 1, true) ~= nil, true, where .. ": the panel says it is done")
      end
    end
    eq(tutor.state().finished, true, lesson.id .. ": finished")
    eq(tutor.record(lesson.id).done, true, lesson.id .. ": recorded as done")
  end, debug.traceback)
  if lesson.test and lesson.test.after then lesson.test.after() end
  if not ok then error(err, 0) end
end

-- One test per lesson, so that a failure names the lesson.
do
  local tutor = ext()
  for n, lesson in ipairs(tutor.lessons) do
    test("tutor: lesson " .. n .. " (" .. lesson.id .. ") can be played from start to finish by typing", function()
      local t = start()
      play_lesson(t, n)
      t.quit()
    end)
  end
end

-- Hints, skipping, restarting -----------------------------------------------------

test("tutor: a hint is shown when asked for, and skipping goes on without doing the step", function()
  local tutor = start()
  type_keys(":tutor 1<CR>")
  type_keys("<Esc>")
  local lesson = tutor.by_id["first-steps"]
  eq(tutor.state().step, 1, "on the first step")
  eq(screen():find("Hint:", 1, true), nil, "no hint before it is asked for")
  type_keys(",hh")
  eq(panel_text():find("Hint: " .. lesson.steps[1].hint, 1, true) == nil, false, "the hint is in the panel")
  type_keys(",hn")
  eq(tutor.state().step, 2, "skipped to the second step")
  eq(tutor.record("first-steps").steps[1], "skipped", "recorded as skipped")
  eq(panel_text():find("✓ Skipped.", 1, true) ~= nil, true, "the panel says so")
  eq(panel_text():find("Hint:", 1, true), nil, "the hint goes with its step")
  eq(daw.transport.playing, false, "skipping did not do the step")
  -- A step that is not done is not noticed, even after other keys.
  type_keys("jk")
  eq(tutor.state().step, 2, "other keys do not do the step")
  tutor.quit()
end)

test("tutor: restarting a lesson builds its practice project again", function()
  local tutor = start()
  type_keys(":tutor 5<CR><Esc>")
  type_keys("dw")
  eq(tutor.state().step, 2, "the first step is done")
  eq(require("tutor.look").names("Beat"), "snare fill crash", "kick deleted")
  type_keys(",hr")
  type_keys("<Esc>")
  eq(tutor.state().step, 1, "back at the first step")
  eq(require("tutor.look").names("Beat"), "kick snare fill crash", "a fresh practice project")
  eq(next(tutor.record("grammar").steps), nil, "the lesson's record starts again")
  eq(daw.undo(), false, "the fresh project has nothing to undo: building it is not an edit")
  tutor.quit()
end)

test("tutor: a finished lesson says so, and the next one follows", function()
  local tutor = start()
  type_keys(":tutor 13<CR><Esc>")
  for _ = 1, #tutor.by_id.saving.steps do type_keys(",hn") end
  eq(tutor.state().finished, true, "finished")
  eq(panel_text():find("Lesson done. `,hn` goes on to lesson 14", 1, true) ~= nil, true, "the panel offers the next lesson")
  type_keys(",hn<Esc>")
  eq(tutor.state().lesson, "finding", "on to lesson 14")
  eq(tutor.state().step, 1, "at its first step")
  tutor.quit()
end)

test("tutor: skipping a step never makes the tutor jump over the next one", function()
  local tutor = start()
  local problems = {}
  for n, lesson in ipairs(tutor.lessons) do
    if lesson.test and lesson.test.before then lesson.test.before() end
    tutor.start(n, { fresh = true, force = true })
    type_keys("<Esc>")
    while not tutor.state().finished do
      local i = tutor.state().step
      type_keys(",hn")
      if not tutor.state().finished and tutor.state().step ~= i + 1 then
        problems[#problems + 1] = string.format("%s: step %d was passed without being done", lesson.id, i + 1)
      end
    end
    if lesson.test and lesson.test.after then lesson.test.after() end
  end
  tutor.quit()
  if #problems > 0 then error(table.concat(problems, "\n"), 0) end
end)

-- The learner's own project ---------------------------------------------------------

local function own_project()
  T.fresh()
  local mine = daw.add_track({ name = "Mine" })
  mine:add_clip({ name = "idea", start = 0, length = 4 })
  daw.opt.grid = 2
  local path = T.scratch .. "/mine.json"
  api.undo_checkpoint()
  daw.project.save(path)
  daw.flush()
  return path, T.read_file(path)
end

test("tutor: the learner's project is never touched, and comes back when they leave", function()
  local tutor = start()
  local path, before = own_project()
  type_keys(":tutor 3<CR>")
  eq(daw.ui.messages[#daw.ui.messages].text:find(path .. " is closed while you practise", 1, true) ~= nil, true, "the tutor says what happens to it")
  type_keys("<Esc>")
  eq(daw.project.path ~= path, true, "a practice project of its own")
  eq(daw.track("Mine"), nil, "the learner's tracks are not in it")
  eq(daw.opt.grid, 1, "lessons start from the default grid")
  type_keys("o")
  type_keys(",hq")
  eq(tutor.state().active, false, "left the tutor")
  eq(daw.project.path, path, "the learner's project is open again")
  eq(daw.track("Mine") ~= nil and #daw.tracks() == 1, true, "as it was")
  eq(daw.project.modified, false, "with nothing to save")
  eq(T.read_file(path), before, "its file was not written")
  eq(daw.opt.grid, 2, "the learner's grid is back")
  eq(daw.ui.visible("tutor"), false, "the panel is gone")
end)

test("tutor: a project with unsaved changes is not closed without asking", function()
  local tutor = start()
  local path = own_project()
  daw.add_track({ name = "Unsaved" })
  api.undo_checkpoint()
  daw.flush()
  type_keys(":tutor 1<CR>")
  eq(tutor.state().active, false, "the lesson did not start")
  eq(daw.ui.messages[#daw.ui.messages].text:find("changes that are not saved", 1, true) ~= nil, true, "the tutor says why")
  eq(daw.track("Unsaved") ~= nil and daw.project.path == path, true, "the project is still open, changes and all")
  type_keys(":tutor! 1<CR><Esc>")
  eq(tutor.state().active, true, "`:tutor!` starts anyway")
  tutor.quit()
  eq(daw.project.path, path, "and leaving reopens the project as last saved")
  eq(daw.track("Unsaved"), nil, "without the changes that were thrown away")
end)

test("tutor: a project opened from a MIDI file is not replaced without asking", function()
  local tutor = start()
  local t = daw.add_track({ name = "Keys" })
  t:add_clip({ start = 0, length = 4, notes = { { pitch = 60, start = 0, length = 1, velocity = 90 } } })
  local path = T.scratch .. "/tutor-import.mid"
  daw.midifile.export(path)
  T.fresh()
  type_keys(":open " .. path .. "<CR>")
  eq(api.project_get().modified, false, "an imported project is not modified")
  type_keys(":tutor 1<CR>")
  eq(tutor.state().active, false, "yet the lesson did not start")
  eq(daw.track("Keys") ~= nil, true, "and the notes are still there")
  type_keys(":tutor! 1<CR><Esc>")
  eq(tutor.state().active, true, "`:tutor!` starts anyway")
  tutor.quit()
end)

test("tutor: progress survives leaving and coming back, and a restart of the program", function()
  local tutor = start()
  type_keys(":tutor 3<CR><Esc>")
  type_keys("o")                         -- step 1: a track
  type_keys("grn<C-u>Bass<CR>")           -- step 2: its name
  eq(tutor.state().step, 3, "two steps done")
  type_keys(",hq")
  eq(require("tutor.store").exists(T.scratch .. "/tutor/progress.lua"), true, "progress is in the tutor's directory")
  -- As if the program had been closed and started again.
  tutor._forget()
  T.fresh()
  type_keys(":tutor<CR>")
  eq(daw.ui.float and daw.ui.float.title, "Lesson 3: Tracks, clips and notes", "back in lesson 3")
  type_keys("<Esc>")
  eq(tutor.state().step, 3, "at the step after the last one done")
  eq(daw.track("Bass") ~= nil, true, "with the practice project as it was left")
  eq(tutor.record("making").steps[2], "done", "and the steps done are remembered")
  type_keys("asynth<CR>")
  eq(tutor.state().step, 4, "and it carries on noticing")
  tutor.quit()
end)

test("tutor: quitting the program in a lesson keeps the place", function()
  local tutor = start()
  type_keys(":tutor 3<CR><Esc>o")
  eq(tutor.state().step, 2, "a step done")
  daw.emit("command.pre", { name = "quit", args = {} })   -- what `:q` in the last window says before the program ends
  tutor._forget()
  T.fresh()
  type_keys(":tutor<CR><Esc>")
  eq(tutor.state().lesson .. " " .. tutor.state().step, "making 2", "back where it was")
  eq(#daw.tracks(), 2, "with the track that was added")
  tutor.quit()
end)

test("tutor: in another project the tutor waits, and `:tutor` goes back to the lesson", function()
  local tutor = start()
  local path = own_project()
  type_keys(":tutor 2<CR><Esc>")
  type_keys(":e " .. path .. "<CR>")
  eq(daw.project.path, path, "the learner opened their own project")
  type_keys("lll")
  eq(tutor.state().step, 1, "steps are not checked against it")
  eq(panel_text():find("not the lesson's project", 1, true) ~= nil, true, "the panel says the tutor is waiting")
  type_keys(":tutor<CR><Esc>")
  eq(daw.project.path ~= path and tutor.state().step == 1, true, "back in the lesson")
  type_keys("lll")
  eq(tutor.state().step, 2, "and noticing again")
  tutor.quit()
end)

test("tutor: the lessons are listed with progress, and one is chosen from the list", function()
  local tutor = start()
  type_keys(":tutor 1<CR><Esc>")
  for _ = 1, #tutor.by_id["first-steps"].steps do type_keys(",hn") end
  type_keys(",hl")
  local state = daw.pick.state()
  eq(state and state.title, "Lessons", "a picker of lessons")
  eq(#state.matches, #tutor.lessons, "every lesson")
  eq(state.matches[1]:find("✓", 1, true) ~= nil, true, "lesson 1 is marked done")
  type_keys("visual<CR><Esc>")
  eq(tutor.state().lesson, "visual", "the chosen lesson starts")
  tutor.quit()
end)

test("tutor: another extension can add a lesson", function()
  local tutor = start()
  local lesson = tutor.register({
    id = "extra", title = "An extra lesson",
    setup = function() daw.add_track({ name = "X" }) end,
    steps = { { say = "Press `o`.", keys = { "o" }, check = function() return #daw.tracks() == 2 end } },
  }, { after = "first-steps" })
  eq(tutor.number(lesson), 2, "it goes where it was asked")
  type_keys(":tutor extra<CR><Esc>o")
  eq(tutor.state().finished, true, "it runs like the others")
  tutor.quit()
  for i, other in ipairs(tutor.lessons) do
    if other == lesson then table.remove(tutor.lessons, i) end
  end
  tutor.by_id.extra = nil
  T.fails(function() tutor.register({ id = "bad", title = "Bad", steps = { { say = "x" } } }) end, "keys", "a step needs its keys")
end)

-- The course as text -------------------------------------------------------------------

test("tutor: docs/course is made from the lessons and agrees with them", function()
  local tutor = ext()
  local files = require("tutor.docs").files(tutor.lessons)
  for name, text in pairs(files) do
    local on_disk = T.read_file("docs/course/" .. name)
    if on_disk ~= text then
      error("docs/course/" .. name .. " differs from the lessons: run `daw --clean --no-plugins -l extensions/tutor/make-docs.lua`", 0)
    end
  end
  for _, entry in ipairs(api.read_dir("docs/course")) do
    local name = entry.name
    eq(files[name] ~= nil or name == "keys.md", true, "docs/course/" .. name .. " belongs to a lesson")
  end
end)

test("tutor: every key in docs/course/keys.md is a key paw has", function()
  ext()
  local keymap = daw.keymap
  local known, operators, chars = {}, {}, {}
  for _, mode in ipairs({ "n", "x", "o", "i" }) do
    for _, view in ipairs({ "arrange", "pianoroll", "pianoroll.complete", "pianoroll.keys", "mixer", "devices", "textbuf" }) do
      for _, map in ipairs(keymap.list(mode, view)) do
        local keys = table.concat(keymap.parse(map.lhs))
        known[keys] = true
        if map.operator and mode == "n" then operators[#operators + 1] = keymap.parse(map.lhs) end
        if map.char then chars[keymap.parse(map.lhs)[1]] = true end
      end
    end
  end
  local function plain(token)
    local keys = keymap.parse(token)
    local text = table.concat(keys)
    if known[text] then return true end
    if #keys == 2 and chars[keys[1]] then return true end   -- `ma`, `'a`, `@a`, `qa`
    return false
  end
  local function counted(token)
    if token:match("^%d+$") then return plain(token) end
    return plain(token:gsub("^%d+", ""))
  end
  local function ok(token)
    if token == "<" then token = "<lt>" end
    if token:match("^:.") then
      local name = token:sub(2):match("^%S+")
      return name:match("^%d+$") ~= nil or daw.commands.get(name) ~= nil
    end
    if token:find(" ") then
      for piece in token:gmatch("%S+") do if not ok(piece) then return false end end
      return true
    end
    token = token:gsub('^"[%w_"]', "")
    if token == "" then return true end
    if counted(token) then return true end
    -- An operator and what follows it.
    local rest = token:gsub("^%d+", "")
    for _, op in ipairs(operators) do
      local lhs = table.concat(op)
      if rest:sub(1, #lhs) == lhs then
        local after = rest:sub(#lhs + 1)
        if after == op[#op] or after:gsub("^%d+", "") == op[#op] or counted(after) then return true end
      end
    end
    return false
  end
  local text = T.read_file("docs/course/keys.md")
  local checked = 0
  for line in text:gmatch("[^\n]+") do
    local first = line:gsub("\\|", "\1"):match("^| ([^|]*) |")
    if first and first:find("`") then
      first = first:gsub("\1", "|")
      for token in first:gmatch("`([^`]+)`") do
        checked = checked + 1
        if not ok(token) then error("keys.md: `" .. token .. "` is not a key of paw", 0) end
      end
    end
  end
  eq(checked > 150, true, "keys checked: " .. checked)
end)
