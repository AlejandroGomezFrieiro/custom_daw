-- Fixes found by a second evaluation of the terminal UI. Loaded by
-- tests/suite.lua with its helpers.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = daw.api
local L = daw.layout

local function screen(w, h) return table.concat(api.ui_snapshot(w or 160, h or 48), "\n") end
local function last_message() local m = daw.ui.messages[#daw.ui.messages] return m and m.text or "" end

-- The focused view is drawn, and it is the one the keyboard is in.
local function focus_is_drawn(after)
  local focused = daw.ui.focused
  eq(daw.ui.visible(focused), true, "`" .. tostring(focused) .. "` has focus but is not drawn, after " .. after)
  local win = L.current()
  eq(win ~= nil and win.view == focused, true, "the current window shows `" .. tostring(focused) .. "` after " .. after)
end

test("focus only ever goes to a view that is drawn", function()
  fresh()
  daw.add_track({ name = "Lead" })
  for _, line in ipairs({
    "e daw://tracks", "view.focus arrange", "bprevious", "view.focus mixer", "view.focus arrange",
    "e daw://tracks", "view.focus mixer", "bnext", "view.only", "view.focus mixer", "view.focus arrange",
    "copen", "view.focus qflist", "cclose", "bprevious", "bnext", "view.focus arrange",
    "split", "vsplit", "wincmd j", "wincmd w", "close", "only", "e daw://tracks", "split",
    "view.focus mixer", "view.focus devices", "view.focus pianoroll", "view.focus session", "view.close",
    "view.toggle mixer", "view.toggle mixer", "view.toggle arrange", "view.toggle arrange", "view.next", "view.prev",
    "tabnew", "view.focus arrange", "tabnext", "tabclose", "view.only", "view.toggle arrange",
    "view.focus arrange", "view.focus mixer", "view.window arrange", "view.maximize", "view.equal",
  }) do
    daw.commands.exec(line)
    focus_is_drawn(line)
  end
  -- The same through the Lua calls: hiding the only window leaves one.
  daw.commands.exec("view.only")
  for _, name in ipairs({ "arrange", "mixer", "arrange" }) do
    daw.ui.hide(name)
    focus_is_drawn("ui.hide " .. name)
    daw.ui.focus(name)
    focus_is_drawn("ui.focus " .. name)
  end
end)

test("a command of a bundled extension that is not loaded says how to load it, and :ext.load does", function()
  if daw.ext.loaded.undotree then return "undotree is loaded already" end
  local ok, err = pcall(daw.commands.exec, "undotree")
  eq(ok, false, "no command yet")
  eq(err:find("bundled extension that isn't loaded", 1, true) ~= nil, true, err)
  eq(err:find(":ext.load undotree", 1, true) ~= nil, true, "it names the command: " .. err)
  local names = {}
  for _, c in ipairs(daw.commands.complete("ext.load und")) do names[#names + 1] = c.text end
  eq(names[1], "ext.load undotree", "bundled names complete: " .. table.concat(names, ","))
  daw.commands.exec("ext.load undotree")
  eq(daw.ext.loaded.undotree ~= nil and daw.ext.loaded.undotree.ok, true, "loaded")
  eq(daw.commands.get("undotree") ~= nil, true, "its commands exist")
  daw.commands.exec("ext.load nonesuch")
  eq(last_message():find("no bundled extension", 1, true) ~= nil, true, last_message())
end)

test("the mixer's scale and every strip's fader cap agree, whatever the strip holds", function()
  fresh()
  local plain = daw.add_track({ name = "Plain" })
  local with_fx = daw.add_track({ name = "Fx" })
  with_fx:add_device("synth")
  with_fx.volume = -6
  plain.volume = 0
  daw.flush()
  daw.ui.show("mixer")
  daw.ui.focus("mixer")
  local lines = api.ui_snapshot(160, 45)
  local function caps(line) return select(2, line:gsub("━━━", "")) end
  local zero, minus6
  for _, line in ipairs(lines) do
    if line:find("^%s*0%s") and line:find("━━━", 1, true) then zero = line end
    if line:find("^%s*%-6%s") and line:find("━━━", 1, true) then minus6 = line end
  end
  eq(zero ~= nil and caps(zero), 2, "the 0 dB caps (the plain track, the master) are on the row the scale calls 0")
  eq(minus6 ~= nil and caps(minus6), 1, "the -6 dB cap is on the row the scale calls -6")
  -- The cursor's row is lit across the strip, in a colour of its own.
  local theme = require("daw.theme").groups
  eq(theme.CursorLine.bg ~= theme.Selected.bg and theme.CursorLine.bg ~= theme.TrackHeaderSel.bg, true,
    "brighter than the selected strip it is on")
  daw.ui.hide("mixer")
end)

test(":notation.export takes the focused notation view's clip, else the arrange cursor's, and says which", function()
  fresh()
  if not package.loaded["notation.keys"] then daw.ext.load("extensions/notation") end
  local view = require("notation")
  local lead = daw.add_track({ name = "Lead" })
  local drums = daw.add_track({ name = "Drums" })
  local melody = lead:add_clip({ start = 0, length = 4, name = "melody", notes = { { pitch = 72, start = 0, length = 1 }, { pitch = 74, start = 1, length = 1 } } })
  drums:add_clip({ start = 0, length = 4, name = "beat", notes = { { pitch = 36, start = 0, length = 1 } } })
  daw.flush()
  local path = T.scratch .. "/uifix-export.pdf"
  daw.cursor.set_track(lead)
  daw.cursor.set_beat(1)
  daw.commands.exec("notation.export " .. path)
  eq(last_message(), "wrote 'melody' (Lead) to " .. path .. ", 1 page", "the clip under the arrange cursor")
  local f = io.open(path, "rb")
  local pdf = f and f:read("*a") or ""
  if f then f:close() end
  local box = { pdf:match("/MediaBox%s*%[%s*([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)") }
  eq(#box == 4 and tonumber(box[4]) < tonumber(box[3]) * 1.2, true, "a short score does not leave the page's empty foot: " .. table.concat(box, " "))
  os.remove(path)
  daw.cursor.set_track(drums)
  daw.commands.exec("notation.export " .. T.scratch .. "/uifix-export.musicxml")
  eq(last_message():find("'beat' (Drums)", 1, true) ~= nil, true, last_message())
  view:edit(melody)
  daw.ui.focus("notation")
  daw.commands.exec("notation.export " .. T.scratch .. "/uifix-export.musicxml")
  eq(last_message():find("'melody' (Lead)", 1, true) ~= nil, true, "the focused notation view's clip wins over the cursor: " .. last_message())
  os.remove(T.scratch .. "/uifix-export.musicxml")
  daw.ui.focus("arrange")
end)
