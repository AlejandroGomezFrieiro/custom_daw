-- Scenes for graphical frontends: every window a frontend shows from the
-- kernel's drawing (a pane of its main area that it does not draw itself,
-- a view in a window of its own) is sent as a scene (crates/paw-scene) and
-- then as what changed of it, pushed as it changes. The frontend says how
-- big each window is in cell units (`scene.area`), sends the pointer back in
-- the same units (`scene.input`), and asks once for each drawing sent by its
-- content key (`scene.blob`). docs/protocol.md has the whole protocol.
--
--   scene.watch { cell = { w, h }, live = true }   scenes from now on
--   scene.area  win w h                            a window's size in units
--   scene.input win { kind, x, y, button, ... }    the pointer, in units
--   scene.blob  key                                a drawing by its key
--   scene.unwatch
--
-- A window is named by a string: a window of the layout by its number
-- ("3"), a view in a window of its own as `view:<name>`.
local api = paw.api
local L = require("paw.layout")
local M = {}

-- What each watching connection has: its cell in pixels, its windows'
-- sizes (`areas`, by name: `{ w, h, drawn, at, view }`, `drawn` the redraw
-- they were last drawn at), whether it hears the live values, and what it
-- was last told of them.
local watchers = {}
local timer
-- The redraw the windows were last looked at for, after a turn.
local looked

--- The windows a seat's frontend shows from the kernel's drawing, by name:
--- `{ view, win }` each, `win` the window of the layout.
local function shown()
  local out = {}
  local state = paw.panes.state()
  for _, pane in ipairs(state and state.panes or {}) do
    if pane.kind ~= "native" then out[tostring(pane.win)] = { view = pane.view, win = L.find_id(paw.ui.layout, pane.win) } end
  end
  for _, w in ipairs(paw.canvas.windows()) do out["view:" .. w.name] = { view = w.name } end
  return out
end

--- Draw again the windows of a connection whose drawing may have changed
--- (all of them with `all`, as on a tick: what moves while playing, and
--- once a second what changes on its own, such as times), and push what
--- changed of each.
local function push(client, all)
  local w = watchers[client]
  if not w then return end
  paw.seats.within(client, function()
    local redraws, now, playing = api.ui_redraws(), api.now(), api.transport_get().playing
    local wanted = shown()
    for id, area in pairs(w.areas) do
      local what = wanted[id]
      if not what then
        if area.drawn then api.scene_forget(client, id) end
        area.drawn, area.view = nil, nil
      elseif area.drawn ~= redraws or area.view ~= what.view
        or (all and now - area.at >= (playing and 30 or 1000)) then
        area.drawn, area.view, area.at = redraws, what.view, now
        local ok, err = pcall(paw.ui.render_scene, what.view, area.w, area.h, w.cell, what.win)
        if not ok then api.log("the scene of " .. what.view .. " failed: " .. tostring(err)) end
        local _, open = api.scene_end(client, id)
        if not open then return M.closed(client) end
      end
    end
  end)
end

--- The values a frontend moves bound nodes by (see crates/paw-scene's
--- `bind`): the playhead, the clock, the engine's load, and each track's
--- meter and input, by track id; rounded to what a frontend can show, so
--- that an idle program has nothing new to say (the load as
--- `paw.audio.load` gives it, as `frontend.watch` sends it).
local function live()
  local t, e = api.transport_get(), api.engine_get()
  local meters, inputs, levels = {}, {}, paw.audio.levels()
  local function meter(id)
    local l, r = api.track_meter(id)
    meters[tostring(id)] = { math.floor(l * 10000 + 0.5) / 10000, math.floor(r * 10000 + 0.5) / 10000 }
  end
  for _, id in ipairs(api.track_list()) do
    meter(id)
    inputs[tostring(id)] = math.floor(paw.audio.level(api.track_get(id), levels) * 10000 + 0.5) / 10000
  end
  -- The master's, as track 0.
  meter(0)
  return {
    position = t.position, playing = t.playing, recording = t.take ~= nil, clock = paw.time.clock(t.position),
    cpu = paw.audio.load(e.cpu), meters = meters, inputs = inputs,
  }
end

local function tick()
  local values, text
  for client, w in pairs(watchers) do
    push(client, true)
    if w.live and watchers[client] then
      values = values or live()
      text = text or api.json_encode(values)
      if text ~= w.told and api.rpc_push(client, "scene.live", values) then w.told = text end
    end
  end
end

local function retime()
  if timer then paw.cancel(timer) end
  timer = next(watchers) and paw.every(33, tick) or nil
end

--- After a turn of the kernel: the windows whose drawing may have changed
--- are pushed now, not at the next tick.
function M.turn()
  if not next(watchers) then return end
  local redraws = api.ui_redraws()
  if redraws == looked then return end
  looked = redraws
  for client in pairs(watchers) do push(client) end
end

paw.remote.methods["scene.watch"] = function(client, opts)
  if client == 0 then error("only a connection can watch", 0) end
  opts = type(opts) == "table" and opts or {}
  local cell = opts.cell or {}
  cell = { w = tonumber(cell.w) or paw.canvas.cell.w, h = tonumber(cell.h) or paw.canvas.cell.h }
  -- The frontend's main area is laid out on its cell (paw/panes.lua).
  paw.canvas.cell = cell
  api.scene_forget(client)
  -- The roles it paints itself are sent as roles, without their cells.
  local roles = {}
  for _, name in ipairs(type(opts.roles) == "table" and opts.roles or {}) do
    if type(name) == "string" then roles[#roles + 1] = name end
  end
  api.scene_roles(client, roles)
  watchers[client] = { cell = cell, areas = {}, live = opts.live == true, held = {} }
  retime()
  return { theme = paw.canvas.palette, roles_version = paw.roles.version }
end

paw.remote.methods["scene.unwatch"] = function(client)
  M.closed(client)
  return true
end

paw.remote.methods["scene.area"] = function(client, id, w, h)
  local watcher = watchers[client]
  if not watcher then error("scene.area before scene.watch", 0) end
  id = tostring(id)
  w, h = math.max(0, tonumber(w) or 0), math.max(0, tonumber(h) or 0)
  if w == 0 or h == 0 then
    -- No longer shown: its next scene is sent whole.
    watcher.areas[id] = nil
    api.scene_forget(client, id)
    return true
  end
  local area = watcher.areas[id]
  if area and area.w == w and area.h == h then return true end
  watcher.areas[id] = { w = w, h = h }
  push(client)
  return true
end

--- A pointer event as the frontend sends it, in units of the window, as
--- the views take them: in pixels of the watcher's cell.
local function in_pixels(event, cell)
  local out = {}
  for k, v in pairs(event) do out[k] = v end
  out.x, out.y = (tonumber(event.x) or 0) * cell.w, (tonumber(event.y) or 0) * cell.h
  return out
end

paw.remote.methods["scene.input"] = function(client, id, event)
  local watcher = watchers[client]
  if not (watcher and type(event) == "table") then return false end
  id = tostring(id)
  local name = id:match("^view:(.+)$")
  -- On a hit region of the scene it was sent, the view's gesture has it
  -- in units (paw/roles.lua); anything else goes on as a terminal's would.
  local area = watcher.areas[id]
  local view = paw.ui.views[name or (area and area.view) or ""]
  if view and paw.roles.input(client, id, view, not name and tonumber(id) or nil, event, watcher.held) then
    return true
  end
  local e = in_pixels(event, watcher.cell)
  if name then
    paw.canvas.pointer(name, e)
    return true
  end
  -- The window's area keeps the button held, for a drag in cells.
  local area = watcher.areas[id] or {}
  area.cell, area.cols, area.rows = watcher.cell, math.floor(area.w or 0), math.floor(area.h or 0)
  paw.panes.pointer(tonumber(id), e, area)
  return true
end

paw.remote.methods["scene.blob"] = function(client, key)
  return api.scene_blob(client, key)
end

--- A connection closed or stopped watching: nothing more is kept for it.
function M.closed(client)
  if not watchers[client] then return end
  watchers[client] = nil
  api.scene_forget(client)
  retime()
end

--- Who is watching: `{ client, windows }` each, `windows` the names of
--- those it has said the size of.
function M.watchers()
  local out = {}
  for client, w in pairs(watchers) do
    local windows = {}
    for id in pairs(w.areas) do windows[#windows + 1] = id end
    table.sort(windows)
    out[#out + 1] = { client = client, windows = windows }
  end
  table.sort(out, function(a, b) return a.client < b.client end)
  return out
end

return M
