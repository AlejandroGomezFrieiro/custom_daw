-- The how-to guide docs/how-to/arrange-your-screen.md, driven with the keys
-- and commands that it gives. Loaded by tests/suite.lua with its helpers.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = paw.api
local L = paw.layout

local W, H = 160, 48

local function keys(text)
  paw.keymap.feed(text)
  paw.flush()
  api.undo_checkpoint()
end

local function windows()
  local out = {}
  for _, r in ipairs(paw.ui.arrange(W, H)) do
    if r.win then out[#out + 1] = r.name end
  end
  return table.concat(out, " ")
end

test("guide: arrange your screen: windows, tabs and layouts", function()
  fresh()
  local initial = L.capture()
  local size = api.ui_size
  api.ui_size = function() return W, H end
  T.after(function()
    api.ui_size = size
    paw.ui.start_layout = nil
    L.restore(initial)
    paw.ui.focus("arrange")
  end)
  if not package.loaded["notation.keys"] then paw.ext.load("extensions/notation") end
  local t = paw.add_track({ name = "Piano" })
  local riff = t:add_clip({ start = 0, length = 4, name = "riff", notes = { { pitch = 60, start = 0, length = 1 } } })
  local hook = t:add_clip({ start = 4, length = 4, name = "hook", notes = { { pitch = 67, start = 0, length = 1 } } })
  -- Show a view in a window.
  keys(":only<CR>")
  keys(":e mixer<CR>")
  eq(windows(), "mixer", ":e mixer")
  keys(":e roll://riff<CR>")
  eq(windows() .. " " .. paw.ui.views.pianoroll.clip_id, "pianoroll " .. riff.id, ":e roll://riff")
  keys(":e roll://" .. hook.id .. "<CR>")
  eq(paw.ui.views.pianoroll.clip_id, hook.id, "a number names a clip")
  keys(":e notation://riff<CR>")
  eq(windows(), "notation", ":e notation://riff")
  keys("<C-^>")
  eq(windows(), "pianoroll", "Ctrl-^ returns to the view before")
  -- Two views side by side.
  keys(":e roll://riff<CR>")
  keys(":vs roll://hook<CR>")
  eq(windows(), "pianoroll pianoroll", ":vs roll://hook")
  keys(":sp mixer<CR>")
  eq(windows(), "pianoroll pianoroll mixer", ":sp mixer below")
  keys("<C-w>c")
  keys("<C-w>h")
  eq(paw.ui.views.pianoroll.clip_id, riff.id, "Ctrl-w h: the left window, with its own clip")
  keys("<C-w>v")
  eq(windows(), "pianoroll pianoroll pianoroll", "Ctrl-w v shows the same view again")
  eq(paw.ui.views.pianoroll.clip_id, riff.id, "on the same clip")
  -- The whole screen.
  keys("<C-w>|")
  eq(windows(), "pianoroll", "Ctrl-w | for some time")
  keys("<C-w>|")
  eq(windows(), "pianoroll pianoroll pianoroll", "and back")
  keys("<C-w>o")
  eq(windows(), "pianoroll", "Ctrl-w o")
  keys("<C-w>c")
  eq(windows(), "pianoroll", "the last window does not close")
  -- Tabs.
  keys(":tabnew mixer<CR>")
  eq(#paw.ui.tabs .. " " .. windows(), "2 mixer", ":tabnew mixer")
  keys("gt")
  eq(paw.ui.tab, 1, "gt")
  keys("gT")
  keys(":tabclose<CR>")
  eq(#paw.ui.tabs, 1, ":tabclose")
  keys(":tabnew<CR>")
  eq(windows(), "empty", "a tab without a view: the start page")
  eq(table.concat(api.ui_snapshot(W, H), "\n"):find("Recent projects", 1, true) ~= nil, true, "which lists the recent projects")
  keys(":tabclose<CR>")
  -- A start layout.
  paw.ui.start_layout = "notation"
  L.start()
  eq(windows(), "notation", "paw.ui.start_layout = \"notation\"")
  paw.ui.start_layout = { dir = "h", "notation", "roll" }
  L.start()
  eq(windows(), "notation pianoroll", "a start layout that splits the screen")
  paw.ui.start_layout = { { name = "Write", layout = "notation" }, { name = "Mix", layout = "mixer" } }
  L.start()
  eq(#paw.ui.tabs .. " " .. L.tab_title(paw.ui.tabs[2]), "2 Mix", "a start layout with tabs")
  -- The layout with the project.
  local path = T.scratch .. "/guide-screen.json"
  keys(":w " .. path .. "<CR>")
  L.restore(initial)
  keys(":e " .. path .. "<CR>")
  eq(#paw.ui.tabs .. " " .. windows(), "2 notation", "the project opens with its tabs and windows")
  keys(":set project_screen=false<CR>")
  T.after(function() paw.opt.project_screen = true end)
  L.restore(initial)
  keys(":e " .. path .. "<CR>")
  eq(windows(), "arrange", ":set project_screen=false keeps the screen")
  keys(":layout save guide_write<CR>")
  T.after(function() os.remove(api.env().state_dir .. "/layouts/guide_write.json") end)
  keys(":e mixer<CR>")
  keys(":layout guide_write<CR>")
  eq(windows(), "arrange", ":layout puts a saved layout back")
end)
