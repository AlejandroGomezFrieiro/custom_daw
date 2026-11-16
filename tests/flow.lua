-- Working from the keyboard: the keys picker, command-line completion, exact
-- values, sizes, undo labels, automation lanes as rows, and limits on
-- runaway Lua.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = daw.api
local pick = daw.pick

local function screen(w, h)
  return table.concat(api.ui_snapshot(w or 100, h or 30), "\n")
end

local function has(text, part, what)
  if not text:find(part, 1, true) then error(string.format("%s: %q is not in\n%s", what or "text", part, text), 2) end
end

local function lacks(text, part, what)
  if text:find(part, 1, true) then error(string.format("%s: %q should not be in\n%s", what or "text", part, text), 2) end
end

local function start()
  fresh()
  daw.keymap.feed("<Esc><Esc>")
  while daw.ui.float do daw.ui.close() end
  daw.ui.focus("arrange")
end

-- The keys picker -------------------------------------------------------------

test("keys are written as a person writes them", function()
  local human = daw.keymap.human
  eq(human("<A-h>"), "Alt-h", "Alt")
  eq(human("<leader>at"), ",at", "the leader")
  eq(human("<C-w>o"), "Ctrl-w o", "a key after a chord stands apart")
  eq(human("<C-w><lt>"), "Ctrl-w <", "<lt> is <")
  eq(human("<CR>"), "Enter", "Enter")
  eq(human("<S-Tab>"), "Shift-Tab", "Shift")
  eq(human("gg"), "gg", "plain keys run together")
  eq(human("<leader><leader>"), ",,", "two leaders")
end)

test("? opens a picker of the keys for the focused view, titled with it", function()
  start()
  daw.keymap.feed("?")
  local state = pick.state()
  eq(state and state.title, "Keys · arrange", "the title names the view")
  local text = table.concat(state.matches, "\n")
  has(text, "Alt-h", "a key of the arrange view, humanised")
  has(text, "Ctrl-w o", "a global key")
  has(text, "arrange", "a tag says where a key works")
  has(text, "global", "and for global ones")
  has(text, "operator", "operators are marked")
  daw.keymap.feed("<Esc>")
end)

test("typing in the keys picker filters, and Enter runs the key", function()
  start()
  local ran
  daw.keymap.set("gQ", function() ran = true end, { view = "arrange", desc = "zz flow mapping" })
  daw.keymap.feed("?zz flow")
  eq(#pick.state().matches, 1, "one match")
  daw.keymap.feed("<CR>")
  eq(ran, true, "Enter ran the mapping")
  eq(pick.state(), nil, "and closed the picker")
  daw.keymap.del("gQ", { view = "arrange" })
end)

test("the keys picker ranks a match on the key above one in a description", function()
  start()
  daw.keymap.feed("?gg")
  local first = pick.state().matches[1]
  eq(first:match("^gg ") ~= nil, true, "gg first: " .. first)
  daw.keymap.feed("<Esc>")
end)

test(":help all lists every key in one page", function()
  start()
  daw.cmd("help", { "all" })
  eq(daw.ui.float and daw.ui.float.name, "help", "the long list")
  local keys = {}
  for _, line in ipairs(daw.ui.views.help.lines) do keys[#keys + 1] = line.key or "" end
  has(table.concat(keys, "\n"), "Ctrl-w o", "with keys humanised")
  daw.ui.close()
end)

test("the commands picker shows each command's key and ranks names first", function()
  start()
  daw.pick("commands")
  local lines = pick.state().matches
  local undo
  for _, line in ipairs(lines) do
    if line:match("^undo ") then undo = line end
  end
  daw.keymap.feed("<Esc>")
  eq(undo ~= nil and undo:find(" u ", 1, true) ~= nil, true, "undo shows its key u: " .. tostring(undo))
  daw.command("zz_aaa", function() end, { desc = "mentions mute in passing" })
  daw.pick("commands", { query = "mute" })
  local first = pick.state().matches[1]
  daw.keymap.feed("<Esc>")
  eq(first:match("^%S*mute") ~= nil, true, "a command named mute first: " .. first)
end)

-- Command-line completion -----------------------------------------------------

local function prompt() return require("daw.views.cmdline").state() end

test("typing on the command line lists the commands it could be, with what they do", function()
  start()
  daw.keymap.feed(":track.mu")
  local state = prompt()
  eq(state.matches and #state.matches > 0, true, "candidates while typing")
  eq(state.matches[1].label, "track.mute", "the command that starts with it")
  eq(state.match, 0, "none chosen yet")
  local text = screen(100, 30)
  has(text, "Toggle mute", "the description is shown")
  daw.keymap.feed("<Tab>")
  eq(prompt().before, "track.mute", "Tab puts the first one in the line")
  has(screen(100, 30), "▶", "and marks it")
  daw.keymap.feed("<Esc>")
  eq(prompt(), nil, "Esc closes the prompt")
  lacks(screen(100, 30), "Toggle mute", "and the list with it")
end)

test("the list shows at most ten, and Tab and Shift-Tab move through them all", function()
  start()
  daw.keymap.feed(":track.")
  local n = #prompt().matches
  eq(n > 10, true, "more than ten track commands")
  local rows = 0
  for line in screen(100, 30):gmatch("[^\n]+") do
    if line:find("Toggle mute", 1, true) or line:find("Toggle solo", 1, true) or line:find("track%.") then rows = rows + 1 end
  end
  eq(rows <= 11, true, "no more than ten rows of candidates and the prompt: " .. rows)
  daw.keymap.feed("<Tab><Tab><S-Tab>")
  eq(prompt().match, 1, "Tab twice, Shift-Tab once")
  daw.keymap.feed("<Esc>")
end)

test("arguments complete as the command says: tracks by name, quoted when they have a space", function()
  start()
  daw.add_track({ name = "Lead Guitar" })
  daw.add_track({ name = "Reverb" })
  local t = daw.add_track({ name = "Vox" })
  daw.cursor.set_track(t)
  local list = daw.commands.complete("send Rev")
  eq(list[1] and list[1].text, "send Reverb", "a track for send")
  list = daw.commands.complete("send Lead")
  eq(list[1] and list[1].text, 'send "Lead Guitar"', "quoted")
  daw.command("zz_raw", function() end, { raw = true, complete = "tracks" })
  list = daw.commands.complete("zz_raw Lead")
  eq(list[1] and list[1].text, "zz_raw Lead Guitar", "a command that takes its text whole needs no quotes")
  eq(#daw.commands.complete("send Reverb "), 0, "the level after the track is not completed")
  daw.keymap.feed(":send Rev<Tab><CR>")
  eq(#t:get().sends, 1, "Tab then Enter runs it")
end)

test("devices, options, views and files complete", function()
  start()
  local function first(line)
    local list = daw.commands.complete(line)
    return list[1] and list[1].text
  end
  eq(first("device.add dela"), "device.add delay", "a device kind")
  eq(first("set zoo"), "set zoom", "an option")
  eq(first("view.toggle mix"), "view.toggle mixer", "a view")
  T.write_file(T.scratch .. "/flowfile.wav", "")
  eq(first("open " .. T.scratch .. "/flowf"), "open " .. T.scratch .. "/flowfile.wav", "a file")
  local dirs = daw.commands.complete("import " .. T.scratch:match("^(.*/)") )
  local found
  for _, c in ipairs(dirs) do if c.label:match("/$") then found = true end end
  eq(found, true, "directories end in /")
end)

test(":set shows, sets and flips options", function()
  start()
  local zoom = daw.opt.zoom
  daw.keymap.feed(":set zoom 7<CR>")
  eq(daw.opt.zoom, 7, "set name value")
  daw.cmd("set", { zoom = 3 })
  eq(daw.opt.zoom, 3, "set name=value")
  local follow = daw.opt.follow
  daw.keymap.feed(":set follow!<CR>")
  eq(daw.opt.follow, not follow, "! flips")
  daw.opt.follow, daw.opt.zoom = follow, zoom
end)

-- Exact values ----------------------------------------------------------------

test("grv, grp and grt take a typed value, or a step from the one there is", function()
  start()
  local t = daw.add_track({ name = "Vox", volume = -8 })
  daw.cursor.set_track(t)
  T.keys("grv-6.5<CR>")
  eq(t.volume, -14.5, "-6.5 steps down from -8")
  T.keys("grv=-6<CR>")
  eq(t.volume, -6, "=-6 sets it")
  T.keys("grv+2<CR>")
  eq(t.volume, -4, "+2 steps up")
  T.keys("grv3 dB<CR>")
  eq(t.volume, 3, "a plain number, with its unit")
  T.keys("grpL30<CR>")
  T.near(t.pan, -0.3, 1e-9, "L30 is 30% left")
  T.keys("grp+50<CR>")
  T.near(t.pan, 0.2, 1e-9, "+50 steps right")
  T.keys("grpC<CR>")
  eq(t.pan, 0, "C is the centre")
  local tempo = daw.project.tempo
  T.keys("grt140<CR>")
  eq(daw.project.tempo, 140, "the tempo")
  T.keys("grt-10<CR>")
  eq(daw.project.tempo, 130, "stepped")
  daw.project.tempo = tempo
  T.keys("grvloud<CR>")
  eq(t.volume, 3, "text that is not a value changes nothing")
end)

test("in the mixer grv sets the selected strip's volume", function()
  start()
  local a = daw.add_track({ name = "A" })
  local b = daw.add_track({ name = "B" })
  daw.cursor.set_track(b)
  daw.ui.focus("mixer")
  T.keys("grv=-12<CR>")
  eq(b.volume, -12, "the strip under the cursor")
  eq(a.volume, 0, "not another")
  daw.ui.hide("mixer")
  daw.ui.focus("arrange")
end)

test("c and = in the device panel ask for the parameter's value in its unit", function()
  start()
  local t = daw.add_track({ name = "S" })
  t:add_device("synth")
  daw.cursor.set_track(t)
  daw.ui.focus("devices")
  local panel = daw.ui.views.devices
  local cutoff
  for i, row in ipairs(panel:rows()) do
    if row.param and row.param.key == "cutoff" then panel.row, cutoff = i, row end
  end
  T.keys("c800<CR>")
  eq(api.device_get(cutoff.device.id).params.cutoff, 800, "cutoff 800 Hz")
  T.keys("=+200<CR>")
  eq(api.device_get(cutoff.device.id).params.cutoff, 1000, "+200 steps")
  for i, row in ipairs(panel:rows()) do
    if row.param and #row.param.choices > 0 then panel.row, cutoff = i, row end
  end
  if cutoff.param.choices[2] then
    T.keys("c" .. cutoff.param.choices[2] .. "<CR>")
    eq(api.device_get(cutoff.device.id).params[cutoff.param.key], 1, "a choice by its name")
  end
  daw.ui.hide("devices")
  daw.ui.focus("arrange")
end)

-- Sizes -----------------------------------------------------------------------

test("Ctrl-w + and - change track height, = makes it automatic", function()
  start()
  local th = daw.opt.track_height
  daw.opt.track_height = 3
  daw.keymap.feed("<C-w>+")
  eq(daw.opt.track_height, 4, "taller")
  daw.keymap.feed("2<C-w>-")
  eq(daw.opt.track_height, 2, "a count steps further")
  daw.keymap.feed("<C-w>=")
  eq(daw.opt.track_height, "auto", "automatic")
  daw.add_track({ name = "A" })
  daw.add_track({ name = "B" })
  screen(100, 30)
  eq(daw.ui.views.arrange.geometry.th, 6, "two tracks on 30 rows get the most")
  daw.opt.track_height = th
end)

test("Ctrl-w < and > change the side panel's width or the header width; sizes are options", function()
  start()
  local hw, dw = daw.opt.header_width, daw.opt.devices_width
  daw.opt.header_width = 24
  daw.keymap.feed("<C-w>>")
  eq(daw.opt.header_width, 26, "the header in the arrange view")
  daw.ui.focus("devices")
  daw.keymap.feed("<C-w><lt>")
  eq(daw.opt.devices_width, dw - 2, "the device panel")
  local rects = daw.ui.arrange(120, 30)
  local width
  for _, r in ipairs(rects) do if r.name == "devices" then width = r.w end end
  eq(width, dw - 2, "and it is drawn so")
  daw.opt.devices_width = 50
  for _, r in ipairs(daw.ui.arrange(120, 30)) do if r.name == "devices" then width = r.w end end
  eq(width, 50, "setting the option sets the size")
  daw.ui.focus("mixer")
  daw.keymap.feed("<C-w>+")
  eq(daw.opt.mixer_height, 13, "a panel below grows taller")
  daw.opt.header_width, daw.opt.devices_width, daw.opt.mixer_height = hw, dw, 12
  daw.ui.hide("mixer")
  daw.ui.hide("devices")
  daw.ui.focus("arrange")
end)

test("Ctrl-w _ maximises the focused panel and puts the others back", function()
  start()
  daw.ui.show("devices")
  daw.ui.show("mixer")
  daw.ui.focus("devices")
  daw.keymap.feed("<C-w>_")
  local names = {}
  for _, r in ipairs(daw.ui.arrange(120, 30)) do names[#names + 1] = r.name .. ":" .. r.w end
  eq(table.concat(names, " "), "devices:120 status:120 cmdline:120", "only the panel, the whole width")
  daw.keymap.feed("<C-w>_")
  names = {}
  for _, r in ipairs(daw.ui.arrange(120, 30)) do names[#names + 1] = r.name end
  eq(table.concat(names, " "), "arrange devices mixer status cmdline", "back as it was")
  eq(daw.ui.focused, "devices", "with the panel focused")
  daw.ui.hide("mixer")
  daw.ui.hide("devices")
  daw.ui.focus("arrange")
end)

-- Undo steps with names ---------------------------------------------------------

local function current_label()
  local current = api.undo_current()
  for _, s in ipairs(api.undo_tree().states) do
    if s.id == current then return s.label end
  end
end

test("an undo step is named by the key or command that made it", function()
  start()
  local t = daw.add_track({ name = "T" })
  t:add_clip({ start = 0, length = 4, name = "c" })
  daw.cursor.set_track(t)
  daw.cursor.set_beat(0)
  api.undo_checkpoint()
  daw._kernel.key("x")
  api.undo_checkpoint()
  eq(current_label(), "Delete the clip", "the key's description")
  daw.undo()
  daw._kernel.key("d")
  daw._kernel.key("w")
  api.undo_checkpoint()
  eq(current_label(), "Delete", "an operator names the step, not its motion")
  daw.cmd("track.volume", { -3 })
  api.undo_checkpoint()
  eq(current_label(), "Set the volume in dB", "a command's description, without examples")
  -- Each key is a turn of its own, as at the keyboard.
  for _, key in ipairs({ "g", "r", "v", "-", "1", "<CR>" }) do
    daw._kernel.key(key)
    api.undo_checkpoint()
  end
  eq(current_label(), "Set T volume", "a value typed at a prompt")
end)

test("u and Ctrl-r say what they undid and redid", function()
  start()
  local t = daw.add_track({ name = "T" })
  daw.cursor.set_track(t)
  api.undo_checkpoint()
  daw._kernel.key("M")
  api.undo_checkpoint()
  daw._kernel.key("u")
  eq(daw.ui.message and daw.ui.message.text, "undid Mute the track", "u")
  eq(t.mute, false, "undone")
  daw._kernel.key("<C-r>")
  eq(daw.ui.message and daw.ui.message.text, "redid Mute the track", "Ctrl-r")
end)

-- After an error ----------------------------------------------------------------

test("after an error the key line says how to read it, until it is read", function()
  start()
  daw.notify("something broke\nwith details", "error")
  local last = screen(120, 30):match("([^\n]*)$")
  has(last, "something broke", "the error itself")
  has(last, ",fn or :messages shows it all", "and how to see it whole")
  daw.ui.message = nil
  last = screen(120, 30):match("([^\n]*)$")
  has(last, ",fn last error", "once it has gone, the key line still says so")
  daw.cmd("messages")
  local text = screen(120, 30)
  daw.ui.close()
  has(text, "with details", ":messages shows the whole of it, newest at the bottom")
  daw.ui.message = nil
  last = screen(120, 30):match("([^\n]*)$")
  lacks(last, "last error", "read, it is no longer mentioned")
end)

-- Automation lanes as rows ------------------------------------------------------

local function lane_setup()
  start()
  daw.lanes.open(1, false)
  for _, id in ipairs(api.track_list()) do daw.lanes.open(id, false) end
  local t = daw.add_track({ name = "Lead", volume = -6 })
  t:add_device("synth")
  local other = daw.add_track({ name = "Other" })
  daw.cursor.set_track(t)
  daw.cursor.set_beat(0)
  daw.opt.grid = 1
  return t, other
end

local function points(lane)
  local out = {}
  for i, p in ipairs(api.lane_points(lane)) do out[i] = string.format("%g:%g", p[1], p[2]) end
  return table.concat(out, " ")
end

test(",al chooses what to automate and shows its lane as a row under the track", function()
  local t = lane_setup()
  daw.keymap.feed(",al")
  local state = pick.state()
  eq(state and state.title, "Automate on Lead", "the lane picker")
  local text = table.concat(state.matches, "\n")
  has(text, "Volume", "volume")
  has(text, "Pan", "pan")
  has(text, "Synth › cutoff", "a device's parameter")
  daw.keymap.feed("cutoff<CR>")
  local lane = daw.cursor.lane_id()
  eq(lane ~= nil, true, "the cursor is on the new lane's row")
  eq(api.lane_get(lane).param, "cutoff", "a cutoff lane")
  eq(daw.lanes.is_open(t), true, "the track's lanes are open")
  local rows = daw.groups.rows({ lanes = true })
  eq(#rows, 3, "two tracks and one lane row")
  eq(rows[2].lane, lane, "the lane is a row under its track")
  eq(daw.cursor.line(), 2, "the cursor's row among them")
  eq(daw.cursor.row(), 1, "and its track's row among tracks")
  local text2 = screen(120, 30)
  has(text2, "↳ Synth › cutoff", "the lane header names the parameter")
  has(text2, "read", "and says the lane is read")
end)

test("on a lane row A adds a point at the curve's value, + - c change it, x removes it", function()
  local t = lane_setup()
  local lane = t:automate("volume")
  daw.lanes.open(t)
  daw.cursor.set_track(t.id, lane.id)
  T.keys("A")
  eq(points(lane.id), "0:-6", "the track's volume, with no points yet")
  T.keys("4lA")
  eq(points(lane.id), "0:-6 4:-6", "the curve's value there")
  T.keys("+")
  eq(points(lane.id), "0:-6 4:-5", "+ raises the point under the cursor a dB")
  T.keys("3-")
  eq(points(lane.id), "0:-6 4:-8", "a count")
  T.keys("c=-20<CR>")
  eq(points(lane.id), "0:-6 4:-20", "c takes a typed value")
  T.keys("b")
  eq(daw.cursor.beat, 0, "b goes to the previous point")
  T.keys("w")
  eq(daw.cursor.beat, 4, "w to the next")
  T.keys("x")
  eq(points(lane.id), "0:-6", "x removes the point")
  eq(#t:clips(), 0, "and no clip was touched")
  T.keys("<leader>at")
  eq(api.lane_get(lane.id).enabled, false, ",at bypasses the lane the cursor is on")
  has(screen(120, 30), "bypass", "the header says so")
end)

test("j and k walk lane rows; ,aa opens and closes them", function()
  local t, other = lane_setup()
  local lane = t:automate("volume")
  t:automate("pan")
  T.keys(",aa")
  eq(daw.lanes.is_open(t), true, ",aa opens them")
  T.keys("j")
  eq(daw.cursor.lane_id(), lane.id, "j goes onto the first lane")
  T.keys("jj")
  eq(daw.cursor.track_id(), other.id, "and past the lanes to the next track")
  eq(daw.cursor.lane_id(), nil, "on the track itself")
  T.keys("k")
  eq(daw.cursor.lane_id() ~= nil, true, "k comes back onto a lane")
  daw.cursor.set_track(t)
  T.keys(",aa")
  eq(daw.lanes.is_open(t), false, ",aa again closes them")
  eq(#daw.groups.rows({ lanes = true }), 2, "only the tracks are rows")
end)

test("in a selection on a lane row, points move and go together", function()
  local t = lane_setup()
  local lane = t:automate("volume")
  lane:set_points({ { 0, -6 }, { 1, -3 }, { 2, 0 }, { 6, -10 } })
  api.undo_checkpoint()
  daw.lanes.open(t)
  daw.cursor.set_track(t.id, lane.id)
  T.keys("vllx")
  eq(points(lane.id), "6:-10", "x removes the points in the stretch selected")
  daw.undo()
  daw.cursor.set_track(t.id, lane.id)
  daw.cursor.set_beat(0)
  T.keys("vlL")
  eq(points(lane.id), "1:-6 2:-3 6:-10", "L moves them a grid step later, onto the place of the one at 2")
end)

test("automation lanes as rows are drawn at 80 columns without spilling", function()
  local t = lane_setup()
  t:automate("volume"):set_points({ { 0, -20 }, { 4, 0 } })
  daw.lanes.open(t)
  local text = screen(80, 24)
  has(text, "↳ Volume", "the lane row")
  for line in text:gmatch("[^\n]+") do
    eq(api.str_width(line) <= 80, true, "a line fits: " .. line)
  end
end)

-- Fades and colour ------------------------------------------------------------

test(",cf asks for the clip's fades; grC chooses the track's colour", function()
  start()
  local t = daw.add_track({ name = "Audio" })
  local clip = t:add_clip({ start = 0, file = "tests/fixtures/tone-mono-8k.wav" })
  daw.cursor.set_track(t)
  daw.cursor.set_beat(0)
  clip.length = 4
  T.keys(",cf1 0.5<CR>")
  eq(clip.fade_in .. "/" .. clip.fade_out, "1/0.5", "in and out")
  T.keys(",cf0.25<CR>")
  eq(clip.fade_in .. "/" .. clip.fade_out, "0.25/0.25", "one length for both")
  T.keys("grC")
  eq(pick.state() and pick.state().title, "Colour of Audio", "the colour picker")
  T.keys("teal<CR>")
  local theme = require("daw.theme")
  local teal
  for i, name in ipairs(theme.hue_names) do if name == "teal" then teal = theme.hues[i] end end
  eq(t.color, teal, "teal")
  T.keys("grCnone<CR>")
  eq(t.color, nil, "none goes back to the theme's")
end)

-- A time limit on runaway Lua ---------------------------------------------------

--- An endless loop, as an extension's code is.
local function endless()
  return daw.limit.untrusted(loadstring("return function() local x = 0 while true do x = x + 1 end end")())
end

--- Read the messages, as a person would, so that the key line stops
--- mentioning the errors these tests make.
local function read_errors()
  daw.cmd("messages")
  daw.ui.close()
end

local function last_error()
  for i = #daw.ui.messages, 1, -1 do
    if daw.ui.messages[i].level == "error" then return daw.ui.messages[i].text end
  end
  return ""
end

test("a key whose handler never returns is stopped with an error naming it", function()
  start()
  local limit = daw.opt.lua_limit
  daw.opt.lua_limit = 300
  daw.keymap.set("gZ", endless(), { view = "arrange", desc = "zz runaway" })
  local t0 = api.now()
  daw._kernel.key("g")
  daw._kernel.key("Z")
  local took = api.now() - t0
  daw.opt.lua_limit = limit
  daw.keymap.del("gZ", { view = "arrange" })
  has(last_error(), "the key gZ (zz runaway) ran for more than 0.3 s", "the error names the key")
  eq(took < 3000, true, "stopped soon: " .. took .. " ms")
  daw._kernel.key("j")
  eq(daw.keymap.mode, "n", "keys work again afterwards")
  read_errors()
end)

test("the limit reaches into compiled code, so extensions are compiled", function()
  eq(api.limit_async, true, "this build's LuaJIT looks for hooks in compiled loops")
  local hot = daw.limit.untrusted(loadstring("return function(n) local x = 0 for i = 1, n do x = x + i end return x end")())
  local traces = 0
  local function count() traces = traces + 1 end
  jit.attach(count, "trace")
  hot(100000)
  jit.attach(count)
  eq(traces > 0, true, "a loop in untrusted code was compiled")
end)

test("a command and a timer that run away are stopped too", function()
  start()
  local limit = daw.opt.lua_limit
  daw.opt.lua_limit = 300
  daw.command("zz_forever", endless(), { desc = "never ends" })
  daw.limit.guard("test", daw.commands.run, "zz_forever")
  has(last_error(), "the command `zz_forever` ran for more than", "a command")
  daw.defer(endless())
  daw.wait(50)
  has(last_error(), "a timer ran for more than", "a timer")
  daw.opt.lua_limit = limit
  read_errors()
end)

test("time spent waiting in the kernel does not count against a callback", function()
  start()
  local limit = daw.opt.lua_limit
  daw.opt.lua_limit = 150
  local before, reached = #daw.ui.messages, false
  daw.limit.guard("test", function()
    daw.api.wait(400)
    -- Enough work afterwards for the clock to be looked at again.
    local x = 0
    for i = 1, 400000 do x = x + i % 3 end
    daw.limit.unhurried(function() local till = daw.api.now() + 300 while daw.api.now() < till do end end)
    for i = 1, 400000 do x = x + i % 3 end
    reached = true
  end)
  daw.opt.lua_limit = limit
  eq(reached, true, "the callback ran to its end")
  for i = before + 1, #daw.ui.messages do eq(daw.ui.messages[i].level ~= "error", true, "no error") end
end)

test(":lua asked for by hand gets far longer than a callback", function()
  start()
  local limit = daw.opt.lua_limit
  daw.opt.lua_limit = 100
  local before = #daw.ui.messages
  daw.limit.guard("test", daw.commands.run, "lua", { "(function() local t = daw.api.now() + 300 while daw.api.now() < t do end return 'done' end)()" })
  daw.opt.lua_limit = limit
  eq(daw.ui.messages[#daw.ui.messages].text, '"done"', "it ran to the end")
  for i = before + 1, #daw.ui.messages do eq(daw.ui.messages[i].level ~= "error", true, "no error") end
end)
