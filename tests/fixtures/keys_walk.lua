-- Run by tests/keys_constitution.lua in a kernel of its own, so that loading
-- every bundled extension does not change the suite's: the key rule over
-- every view's mappings, and Escape staying in the extensions' views.
-- Prints one line for each thing wrong, each starting `wrong:`, then `done`
-- (messages the program shows are printed too, and are not counted).
--   daw --clean --no-plugins --no-listen --audio null -l tests/fixtures/keys_walk.lua
local api = daw.api
for _, entry in ipairs(api.read_dir("extensions")) do
  if entry.is_dir and io.open("extensions/" .. entry.name .. "/init.lua") then
    local ok, err = pcall(daw.ext.load, "extensions/" .. entry.name)
    if not ok or not (daw.ext.loaded[entry.name] and daw.ext.loaded[entry.name].ok) then
      print("wrong: load " .. entry.name .. ": " .. tostring(err or daw.ext.loaded[entry.name].error))
    end
  end
end
for _, line in ipairs(daw.keyrule.broken()) do print("wrong: rule " .. line) end
for _, line in ipairs(daw.keyrule.lost_groups()) do print("wrong: group " .. line .. " leads to nothing") end

-- Escape cancels and stays.
local t = daw.add_track({ name = "Keys" })
t:add_device("synth")
t:add_clip({ name = "c", start = 0, length = 4, notes = { { pitch = 60, start = 0, length = 1 } } })
api.undo_checkpoint()
daw.cursor.set_track(t)
daw.cursor.set_beat(0)
local function stays(name, open)
  daw.ui.focus("arrange")
  local ok, err = pcall(open)
  if not ok then return print("wrong: escape " .. name .. ": did not open: " .. tostring(err)) end
  if daw.ui.focused ~= name then return print("wrong: escape " .. name .. ": did not open") end
  daw.keymap.feed("3<Esc><Esc><Esc>")
  if daw.ui.focused ~= name then print("wrong: escape " .. name .. ": left for " .. tostring(daw.ui.focused)) end
  if daw.keymap.pending() ~= "" then print("wrong: escape " .. name .. ": left " .. daw.keymap.pending() .. " typed") end
end
stays("drums", function()
  local beat = require("drums").make_track({ name = "Beat" })
  beat:add_clip({ start = 0, length = 4 })
  daw.cursor.set_track(beat)
  daw.keymap.feed("<CR>")
end)
stays("notation", function()
  daw.cursor.set_track(t)
  daw.cursor.set_beat(0)
  daw.keymap.feed("<leader>n")
end)
stays("vinput", function() daw.ui.show("vinput") daw.ui.focus("vinput") end)
print("done")
api.quit(0)
