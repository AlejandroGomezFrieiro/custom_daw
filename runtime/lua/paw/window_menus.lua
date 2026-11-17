-- The window's menus, built here so that the window only shows them: the
-- context menus are the terminal's (`paw.mouse_menus`), entry for entry,
-- and the menus only the window has (the File menu, "+ Track", More, the
-- audio devices, a track's input, a device's presets and routing) are here.
--
--   paw.frontend.menu("clip", { id, beat })      -- entries to show
--   paw.frontend.act.menu_choose("clip", { id, beat }, { 9, 2 })  -- the 2nd of the 9th's submenu
--
-- An entry is `{ label, keys, enabled, checked, items }`, or
-- `{ separator = true }`. An entry the window does itself names it in
-- `window` (a dialog of its own, leaving the project): "new", "open",
-- "open:<path>", "saveas", "import", "render", "quit", "listen".
local api = paw.api
local M = {}

local function act() return paw.frontend.act end
local function run(line) return function() paw.commands.exec(line) end end

-- A menu of choices as the frontend lists them (`{ label, checked }`),
-- each passed to `choose` with its place from 1.
local function choices(list, choose)
  local out = {}
  for i, c in ipairs(list or {}) do
    out[i] = { label = c.label, checked = c.checked, run = function() choose(i) end }
  end
  return out
end

local function heading(label) return { label = label, enabled = false } end

local function append(list, more)
  for _, item in ipairs(more) do list[#list + 1] = item end
  return list
end

--- The File menu, from the project's name.
function M.file()
  local recent = {}
  for i, entry in ipairs(paw.frontend.recent_menu()) do
    recent[i] = { label = entry.label, window = "open:" .. entry.path }
  end
  recent[#recent + 1] = "-"
  recent[#recent + 1] = { label = "Clear the list", run = run("recent.clear") }
  return {
    { label = "New project", window = "new" },
    { label = "Open…", window = "open" },
    { label = "Open recent", items = recent },
    { label = "Recover unsaved work…", run = run("recover") },
    "-",
    { label = "Save", run = run("write") },
    { label = "Save as…", window = "saveas" },
    "-",
    { label = "Import…", window = "import" },
    { label = "Render…", window = "render" },
    { label = "Sound files", items = {
      { label = "Find missing files…", run = run("media.relink") },
      { label = "Copy into the project's folder", run = run("media.collect") },
    } },
    "-",
    { label = "Markers and regions…", run = run("marker.list") },
    { label = "MIDI controllers…", run = run("learn.list") },
    "-",
    { label = "Quit", window = "quit" },
  }
end

--- "+ Track": an empty one, one from a sound file, and the kinds of track
--- extensions add (the timeline's entries, for the selected track).
function M.add_track()
  local items = {
    { label = "Empty track", run = run("track.add") },
    { label = "From a sound file…", window = "import" },
  }
  for index, entry in ipairs(paw.frontend.menus.timeline) do
    items[#items + 1] = { label = entry.label, run = function() act().menu("timeline", index, paw.cursor.track_id(), -1) end }
  end
  return items
end

--- More: every view to open in a pane, the extensions' among them.
function M.views()
  local items = {}
  for i, v in ipairs(paw.canvas.openable()) do
    items[i] = { label = v.title, run = run("view.open " .. v.name) }
  end
  if #items == 0 then items[1] = heading("No other views") end
  return items
end

--- The audio devices, from the engine indicator. `opts`: whether the
--- window is attached to a kernel elsewhere (`remote`) and plays its sound
--- (`listening`).
function M.engine(opts)
  opts = opts or {}
  local menu = paw.frontend.engine_menu()
  local items = {}
  for _, line in ipairs(menu.info) do items[#items + 1] = heading(line.label) end
  items[#items + 1] = "-"
  items[#items + 1] = { label = "Hear it on this machine", checked = opts.listening or false, enabled = opts.remote or false, window = "listen" }
  local function group(name) return function(i) act().choose_engine(name, i) end end
  append(items, { "-", heading("Output") })
  append(items, choices(menu.output, group("output")))
  append(items, { "-", heading("Input") })
  append(items, choices(menu.input, group("input")))
  append(items, {
    "-",
    { label = "Block size", items = choices(menu.block, group("block")) },
    { label = "Sample rate", items = choices(menu.rate, group("rate")) },
    { label = "Sound system", items = choices(menu.backend, group("backend")) },
  })
  return items
end

--- A track's input button: its audio inputs, MIDI ports and channels,
--- monitoring, and where it sends MIDI.
function M.input(track)
  local menu = paw.frontend.input_menu(track)
  local function group(name) return function(i) act().choose_input(track, name, i) end end
  local items = { heading("Audio") }
  append(items, choices(menu.audio, group("audio")))
  append(items, { "-", heading("MIDI") })
  append(items, choices(menu.midi, group("midi")))
  append(items, {
    { label = "MIDI channel", items = choices(menu.channel, group("channel")) },
    "-",
    { label = "Monitor: hear the input without arming", checked = menu.monitor or false, run = function() act().toggle(track, "monitor") end },
    "-",
    { label = "MIDI out: send what it plays to", items = choices(menu.midi_out, group("midi_out")) },
    { label = "MIDI out channel", items = choices(menu.midi_out_channel, group("midi_out_channel")) },
    { label = "MIDI out form, where the port takes no MIDI 2.0", items = choices(menu.midi_out_form, group("midi_out_form")) },
  })
  return items
end

--- Where a track plays into: the master or another track.
function M.output(track)
  local routing = paw.frontend.routing(track)
  local items = {}
  for i, t in ipairs(routing.targets) do
    items[i] = { label = t.name, checked = t.id == routing.output_id, run = function() act().set_output(track, t.id) end }
  end
  return items
end

--- A track to send a track's sound to as well.
function M.send(track)
  local items = {}
  for i, t in ipairs(paw.frontend.routing(track).targets) do
    items[i] = { label = t.name, enabled = t.id ~= 0, run = function() act().add_send(track, t.id) end }
  end
  return items
end

--- A device's presets, and saving one.
function M.preset(device)
  local items = {}
  for i, name in ipairs(act().preset_menu(device)) do
    items[i] = { label = name, run = function() act().preset_choose(device, i) end }
  end
  append(items, {
    { label = "Save as a preset…", run = function() act().device_command(device, "preset.save") end },
    { label = "New ones start from this preset", run = function() act().device_command(device, "preset.default") end },
  })
  return items
end

--- What a device listens to on its side-chain.
function M.sidechain(device)
  return choices(paw.frontend.sidechain_menu(device), function(i) act().choose_sidechain(device, i) end)
end

--- Where a device's further output pairs play.
function M.outputs(device)
  local items = {}
  for p, pair in ipairs(paw.frontend.outputs_menu(device)) do
    items[p] = { label = pair.label, items = choices(pair.choices, function(i) act().route_pair(device, p + 1, i) end) }
  end
  append(items, { "-", { label = "Spread the outputs over new tracks", run = function() act().device_command(device, "device.spread") end } })
  return items
end

--- The entries of menu `kind` for `args` (a list), as the terminal's
--- menu takes them.
function M.items(kind, args)
  args = args or {}
  local build = M[kind] ~= nil and kind ~= "items" and kind ~= "describe" and kind ~= "choose" and M[kind] or require("paw.mouse_menus")[kind]
  if not build then error("no menu " .. tostring(kind)) end
  return build(unpack(args)) or {}
end

local function describe(items)
  local out = {}
  for i, item in ipairs(items) do
    if item == "-" or item.separator then
      out[i] = { separator = true }
    else
      out[i] = {
        label = item.label, keys = item.keys or "", enabled = item.enabled ~= false, checked = item.checked or false,
        window = item.window, items = item.items and describe(item.items) or nil,
      }
    end
  end
  return out
end

--- Menu `kind` for `args`, as plain data for a window to show.
function M.describe(kind, args)
  return describe(M.items(kind, args))
end

--- Do the entry at `path` (its place from 1 in each menu down to it) of
--- menu `kind` for `args`, as built again now.
function M.choose(kind, args, path)
  local items = M.items(kind, args)
  local item
  for _, at in ipairs(path) do
    item = items and items[at]
    if type(item) ~= "table" then return end
    items = item.items
  end
  if item and item.enabled ~= false and item.run then item.run() end
end

paw.frontend.menu = M.describe
paw.frontend.act.menu_choose = M.choose

return M
