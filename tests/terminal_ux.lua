-- Terminal fixes found by evaluating the program: wrapping of long words in
-- the pager, `:edit` with buffer names, new windows and tabs, searching keys
-- and commands, prompts that come selected, `:set` on unknown options, the
-- quickfix key line, bare extension names, the cursor on open, autosave of
-- imported work. Loaded by tests/suite.lua with its helpers.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = daw.api
local L = daw.layout

local W, H = 160, 48
local initial = L.capture()

-- Empty windows made here are forgotten with their buffers.
local function clear_empty()
  for id, buf in pairs(L.buffers) do
    if buf.type == "empty" then L.buffers[id] = nil end
  end
end

local function start()
  fresh()
  daw.keymap.feed("<Esc><Esc>")
  while daw.ui.float do daw.ui.close() end
  L.restore(initial)
  clear_empty()
  daw.ui.focus("arrange")
  T.after(function()
    daw.keymap.feed("<Esc><Esc>")
    while daw.ui.float do daw.ui.close() end
    L.restore(initial)
    clear_empty()
    daw.ui.focus("arrange")
  end)
end

local function screen() return table.concat(api.ui_snapshot(W, H), "\n") end
local function last_message() return daw.ui.messages[#daw.ui.messages].text end
local function windows()
  local out = {}
  for _, win in ipairs(L.windows(daw.ui.layout)) do out[#out + 1] = L.buf_of(win).name end
  return table.concat(out, " ")
end

test("the pager breaks a word longer than its width instead of hanging", function()
  local wrap = daw.ui.views.pager.wrap
  local long = "saved " .. string.rep("a/", 40) .. "song.json"
  local rows = wrap(long, 20)
  for _, row in ipairs(rows) do eq(#row <= 20, true, "every row fits: " .. row) end
  eq((table.concat(rows):gsub("%s", "")), (long:gsub("%s", "")), "nothing is lost")
  eq(#wrap(string.rep("x", 100), 10) > 1, true, "one long word is cut")
  eq(wrap("one two three four five six seven", 12)[2], "  three four", "words still break at spaces")
end)

test(":messages shows a message with a long path", function()
  start()
  daw.notify("saved /" .. string.rep("long-directory-name/", 12) .. "song.json")
  daw.cmd("messages")
  eq(screen():find("song.json", 1, true) ~= nil, true, "the end of the path is on the screen")
  daw.ui.close()
end)

test(":edit and :e show a known buffer by name even when there is unsaved work", function()
  start()
  daw.add_track({ name = "Keys" })
  daw.ui.show("mixer")
  daw.commands.exec("e mixer")
  eq(L.buf_of(L.current()).name, "mixer", "`:e` shows the mixer here")
  daw.commands.exec("edit arrange")
  eq(L.buf_of(L.current()).name, "arrange", "`:edit` shows the arrange view here, not the project guard")
  eq(api.project_get().path, nil, "no file was read")
  daw.commands.exec("edit daw://tracks")
  eq(L.buf_of(L.current()).type, "textbuf", "an address opens its text buffer")
  eq(#api.track_list(), 1, "the work is still there")
end)

test("`,m` in a window that is only the mixer brings the arrange view back", function()
  start()
  daw.ui.show("mixer")
  daw.ui.focus("mixer")
  L.only()
  eq(windows(), "mixer", "the mixer alone")
  daw.keymap.feed(",m")
  eq(windows(), "arrange", "the mixer made way for the arrange view")
  daw.keymap.feed(",m")
  eq(windows():find("mixer", 1, true) ~= nil, true, "and `,m` shows it again")
end)

test(":vs and :sp without a name show the same buffer as far as a view can", function()
  start()
  daw.cmd("vs")
  eq(windows(), "arrange roll", "the arrange view's companion is the piano roll")
  daw.cmd("only")
  daw.commands.exec("e mixer")
  daw.cmd("sp")
  eq(windows():find("[No Name]", 1, true) ~= nil, true, "a view with no companion leaves an empty window")
  eq(screen():find("shows in one window only", 1, true) ~= nil, true, "which says why")
  daw.cmd("only")
  daw.commands.exec("e daw://tracks")
  local buf = L.buf_of(L.current())
  daw.cmd("vs")
  eq(L.buf_of(L.current()), buf, "a text buffer shows in both windows")
  eq(#L.windows(daw.ui.layout), 2, "two windows")
  daw.cmd("vnew")
  eq(L.buf_of(L.current()).type, "empty", ":vnew is always empty")
end)

test("empty windows are numbered among those there are, from none", function()
  start()
  daw.cmd("tabnew")
  eq(L.tab_title(daw.ui.tabs[2]), "[No Name]", "the first is not numbered")
  daw.cmd("tabnew")
  eq(L.tab_title(daw.ui.tabs[3]), "[No Name 2]", "the second is")
  daw.cmd("tabclose")
  daw.cmd("tabclose")
  daw.cmd("tabnew")
  eq(L.tab_title(daw.ui.tabs[2]), "[No Name]", "the numbers are free again once the windows are closed")
  eq(L.tab_title(daw.ui.tabs[1]), "arrange", "the first tab is named after its buffer")
  daw.cmd("tabclose")
end)

local function ranked(source, query)
  local src = daw.pick.sources[source]
  src = type(src) == "function" and src() or src
  local out = {}
  for _, r in ipairs(daw.pick.filter(query, src.items(), src.format, src.primary)) do out[#out + 1] = r end
  return out
end

test("`?` in the mixer finds the arrange view's `,s` for `send`, and says it is an arrange key", function()
  start()
  daw.ui.show("mixer")
  daw.ui.focus("mixer")
  local list = ranked("keys", "send")
  local found
  for _, r in ipairs(list) do
    if r.item.other == "arrange" and r.item.map.lhs == "<leader>s" then found = r end
  end
  eq(found ~= nil, true, "`,s` is listed")
  eq(found.text:find("arrange view", 1, true) ~= nil, true, "as a key of the arrange view")
  eq(list[1].item.map.lhs:find("<C%-w>") == nil, true, "and the window keys do not come first")
end)

test("`,,` puts the command named like the query first", function()
  start()
  eq(ranked("commands", "arrange")[1].item.name, "arrange", "`:arrange` is first for arrange")
  eq(ranked("commands", "send")[1].item.name, "send", "and `:send` for send")
  eq(ranked("commands", "mixer")[1].item.name, "mixer", "and `:mixer` for mixer")
end)

test("a prompt with text comes with the text selected, so that typing replaces it", function()
  start()
  local got
  daw.ui.input({ prompt = "Name: ", text = "Track 1" }, function(text) got = text end)
  eq(daw.ui.messages and require("daw.views.cmdline").state().selected, true, "selected")
  daw.keymap.feed("Lead<CR>")
  eq(got, "Lead", "typing replaced it")
  daw.ui.input({ prompt = "Name: ", text = "Track 1" }, function(text) got = text end)
  daw.keymap.feed("<CR>")
  eq(got, "Track 1", "Enter keeps it")
  daw.ui.input({ prompt = "Name: ", text = "Track 1" }, function(text) got = text end)
  daw.keymap.feed("<Right>s<CR>")
  eq(got, "Track 1s", "a motion key takes the selection off, and typing adds")
  daw.ui.input({ prompt = "Name: ", text = "Track 1" }, function(text) got = text end)
  daw.keymap.feed("<C-u>x<CR>")
  eq(got, "x", "Ctrl-u clears it")
  daw.ui.input({ prompt = "Name: ", text = "Track 1" }, function(text) got = text end)
  daw.keymap.feed("<BS>y<CR>")
  eq(got, "y", "backspace clears it")
  daw.ui.input({ prompt = ":", text = "set " }, function(text) got = text end)
  daw.keymap.feed("zoom<CR>")
  eq(got, "set zoom", "the command line's text is not selected")
end)

test("`grn` asks for the name with the old one selected", function()
  start()
  daw.add_track({ name = "Track 1" })
  daw.keymap.feed("grn")
  daw.keymap.feed("Lead<CR>")
  eq(daw.tracks()[1].name, "Lead", "the name was replaced")
end)

test(":set says an unknown option is an error, and `?` shows a known one", function()
  start()
  daw.commands.exec("set master?")
  eq(last_message(), "E518: Unknown option: master", "unknown")
  eq(daw.ui.messages[#daw.ui.messages].level, "error", "as an error")
  daw.commands.exec("set zoom?")
  eq(last_message(), "zoom = " .. tostring(daw.opt.zoom), "a known option is shown")
  daw.commands.exec("set nosuch 3")
  eq(last_message(), "E518: Unknown option: nosuch", "setting one is the same error")
end)

test("the quickfix list's key line has Enter to jump and q to close", function()
  local entries = daw.ui.keybar.lines.qflist.n
  local keys = {}
  for _, entry in ipairs(entries) do keys[entry[1]] = entry[2] end
  eq(keys["<CR>"], "jump", "jump")
  eq(keys["q"], "close", "close")
end)

test("a bare extension name opens its main view, or suggests what it could mean", function()
  local ran = 0
  daw.command("uxext.open", function() ran = ran + 1 end, { desc = "the view" })
  daw.command("uxext.other", function() end, { desc = "another" })
  daw.command("uxonly.first", function() end, { desc = "one" })
  daw.commands.exec("uxext")
  eq(ran, 1, "`:uxext` ran `uxext.open`")
  local ok, why = pcall(daw.commands.exec, "uxonly")
  eq(ok, false, "without one it is still an error")
  eq(tostring(why):find("did you mean :uxonly.first", 1, true) ~= nil, true, "which suggests: " .. tostring(why))
end)

-- A Standard MIDI file of one note.
local function midi_file()
  local path = T.scratch .. "/ux.mid"
  local f = assert(io.open(path, "wb"))
  local data = "\0\144\60\64" .. "\96\128\60\0" .. "\0\255\47\0"
  f:write("MThd\0\0\0\6\0\0\0\1\0\96", "MTrk\0\0\0", string.char(#data), data)
  f:close()
  return path
end

test("opening a project puts the cursor back at its start", function()
  start()
  daw.add_track({ name = "A" })
  daw.add_track({ name = "B" })
  daw.cursor.set_track(daw.tracks()[2])
  daw.cursor.set_beat(24)
  daw.commands.exec("open! " .. midi_file())
  daw.flush()
  eq(daw.cursor.beat, 0, "at the start")
  eq(daw.cursor.index(), 1, "on the first track")
end)

test("autosave keeps a copy of an imported project that was never modified", function()
  start()
  local dir = T.scratch .. "/ux-autosave"
  os.execute("mkdir -p '" .. dir .. "'")
  local old = daw.autosave.dir
  daw.autosave.dir = dir
  T.after(function() daw.autosave.dir = old end)
  daw.commands.exec("open! " .. midi_file())
  daw.flush()
  eq(api.project_get().modified, false, "nothing was changed")
  eq(daw.project.unsaved(), true, "yet it is not on disk")
  eq(daw.autosave.copy() ~= nil, true, "a copy is written")
end)
