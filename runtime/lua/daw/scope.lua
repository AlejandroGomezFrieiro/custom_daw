-- Narrowing: a tab that shows one group of tracks and nothing else, as
-- REAPER's subprojects let a large project be worked on one section at a
-- time, but with one project and one undo tree.
--
--   daw.scope.narrow(strings)   -- a tab of its own for the group
--   daw.scope.widen()           -- back to the tab it came from
--   daw.scope.current()         -- the group the current tab shows, or nil
--   daw.scope.tracks()          -- the tracks the current tab sees, in order
--
-- A scope belongs to a tab (`tab.scope`, the group's id): the arrange view,
-- the mixer, the device panel, `daw://tracks`, the pickers, Ex ranges and
-- the track motions of that tab see the group and every track inside it,
-- however deep, and nothing else. Other tabs keep theirs, so several
-- sections can be open at once. A track added in a scope goes into its
-- group, so that it stays in sight.
--
-- What the rest of the song does while a scope's tab is the current one is
-- `daw.opt.scope_rest`: "play" (as a reference, the default), "mute", or
-- "frozen": each part of the rest is rendered in the background and played
-- from its file, so that its devices rest (see daw/freeze.lua). Neither
-- touches the project: they last as long as the tab is in front.
local api = daw.api
local M = {}

daw.option.define("scope_rest", "play") -- what the rest of the song does in a narrowed tab: "play", "mute" or "frozen"

local L = daw.layout
local groups = daw.groups

local function id_of(track) return type(track) == "table" and track.id or track end

local function exists(id) return id and pcall(api.track_get, id) end

--- The group a tab is narrowed to (the current tab's by default), or nil.
function M.current(tab)
  tab = tab or L.tab()
  local id = tab and tab.scope
  if id and exists(id) and groups.is_group(id) then return id end
end

--- Whether a track is inside a scope (the current one by default): the
--- group itself or any track in it, however deep. Every track is, with no
--- scope.
function M.contains(track, scope)
  scope = scope or M.current()
  if not scope then return true end
  local at, steps = id_of(track), 0
  while at and steps < 32 do
    if at == scope then return true end
    at, steps = groups.of(at), steps + 1
  end
  return false
end

--- The tracks a scope (the current one by default) holds, in the order of
--- the track list; every track, with no scope.
function M.tracks(scope)
  scope = scope or M.current()
  local list = api.track_list()
  if not scope then return list end
  local out = {}
  for _, id in ipairs(list) do
    if M.contains(id, scope) then out[#out + 1] = id end
  end
  return out
end

--- A group by its id, its track, or its name (or part of it).
function M.find(which)
  if which == nil then return nil end
  local id = tonumber(which) or id_of(which)
  if type(id) == "number" then return groups.is_group(id) and id or nil end
  local wanted = tostring(which):lower()
  local partial
  for _, other in ipairs(api.track_list()) do
    if groups.is_group(other) then
      local name = api.track_get(other).name:lower()
      if name == wanted then return other end
      partial = partial or (name:find(wanted, 1, true) and other)
    end
  end
  return partial or nil
end

--- The group a track stands for when narrowing: itself if it is one, else
--- the group it is in.
function M.group_at(track)
  track = id_of(track)
  if not track then return nil end
  if groups.is_group(track) then return track end
  return groups.of(track)
end

local function name_of(id) return api.track_get(id).name end

--- Put the cursor inside the current scope, on the group, when it is not.
local function cursor_inside()
  local scope = M.current()
  if not scope then return end
  local at = daw.cursor.track_id()
  if not (at and M.contains(at)) then daw.cursor.set_track(scope) end
end

--- Open a tab narrowed to a group, after the current one, with the same
--- windows, and go to it; a tab already narrowed to it is gone to instead.
--- Returns the tab.
function M.narrow(group)
  local id = M.find(group)
  if not id then error(group == nil and "not in a group" or ("no group `" .. tostring(group) .. "`"), 0) end
  local u = daw.ui
  for i, t in ipairs(u.tabs) do
    if t.scope == id then
      L.tab_go(i)
      return t
    end
  end
  local from = L.tab()
  local t = L.tab_copy(name_of(id))
  t.scope, t.from = id, from
  daw.emit("scope.changed", { scope = id })
  cursor_inside()
  return t
end

--- Leave the current tab's scope: the tab closes and the one it was
--- narrowed from comes back (or the tab stays, wide, when it is the last).
function M.widen()
  local u = daw.ui
  local t = L.tab()
  if not t.scope then return false end
  local back
  for i, other in ipairs(u.tabs) do
    if other == t.from then back = other end
  end
  if not L.tab_close(u.tab) then
    t.scope, t.from, t.name = nil, nil, nil
    daw.emit("scope.changed", {})
  elseif back then
    for i, other in ipairs(u.tabs) do
      if other == back then L.tab_go(i) end
    end
  end
  api.ui_redraw()
  return true
end

-- A tab follows its group's name, and closes when the group goes away.
daw.on("track.changed", function(event)
  for _, t in ipairs(daw.ui.tabs) do
    if t.scope == event.id and exists(event.id) then t.name = name_of(event.id) end
  end
end)

-- A tab whose group is taken away is wide again.
daw.on("track.removed", function(event)
  for _, t in ipairs(daw.ui.tabs) do
    if t.scope == event.id then t.scope, t.from, t.name = nil, nil, nil end
  end
end)

-- A track added in a scope goes into its group, so that it stays in sight
-- (undo and opening a project put tracks back where they were).
daw.on("track.added", function(event)
  if event.restored or not exists(event.id) then return end
  local scope = M.current()
  if scope and not M.contains(event.id, scope) and not daw.vca.is_vca(event.id) then
    pcall(groups.add, event.id, scope)
  end
end)

-- The rest of the song ---------------------------------------------------------------

-- Tracks of the rest rendered in the background, by id: `{ file, gen }`,
-- the generation of the edits the file was made from; and the ones being
-- rendered, by the file's path.
local held, pending = {}, {}
-- Edits since the start, by track: a part of the rest whose tracks are
-- edited is rendered again.
local gens = {}
local applied = {}  -- what the engine was last told: { audible, hold = { id = file } }
local made = 0      -- files rendered, for their names

local function held_dir()
  local dir = api.env().data_dir .. "/daw/held"
  os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "'")
  return dir
end

--- The parts of the rest of the song that can be frozen for a scope: the
--- tracks outside it at the top of their branch (a whole group, not its
--- members), not one the scope's sound passes through (its groups, and a
--- bus its sends reach), and not empty.
function M.rest_parts(scope)
  scope = scope or M.current()
  if not scope then return {} end
  local inside = {}
  for _, id in ipairs(M.tracks(scope)) do inside[id] = true end
  -- The scope's groups and wherever its sound goes carry it: they play live.
  local carries = {}
  for id in pairs(inside) do
    for to in pairs(daw.routes.reached(id)) do carries[to] = true end
  end
  local lineage, at = {}, groups.of(scope)
  while at do
    lineage[at] = true
    at = groups.of(at)
  end
  local function sounds(id)
    if #api.clip_list(id) > 0 then return true end
    for _, member in ipairs(groups.members(id)) do
      if sounds(member) then return true end
    end
    return false
  end
  local out = {}
  for _, id in ipairs(api.track_list()) do
    local parent = groups.of(id)
    local top = parent == nil or lineage[parent]
    if top and not inside[id] and not lineage[id] and not carries[id] and not daw.vca.is_vca(id)
      and not daw.freeze.state(id) and sounds(id) then
      out[#out + 1] = id
    end
  end
  return out
end

local function gen_of(track)
  -- A part's generation counts the edits of every track inside it.
  local n = gens[track] or 0
  for _, member in ipairs(groups.members(track)) do n = n + gen_of(member) end
  return n
end

--- Render a part of the rest in the background, unless it is being rendered.
local function render_part(id)
  for _, p in pairs(pending) do
    if p.id == id then return end
  end
  made = made + 1
  local path = string.format("%s/%d-%d-%d.wav", held_dir(), api.env().pid, id, made)
  pending[path] = { id = id, gen = gen_of(id) }
  local ok, err = pcall(daw.render, path, daw.freeze.render_opts(id, { background = true }))
  if not ok then
    pending[path] = nil
    daw.notify("could not freeze " .. name_of(id) .. " for the scope: " .. tostring(err), "warn")
  end
end

--- Tell the engine what the rest of the song does for a scope: the one of
--- the tab in front, which the last seat to change tabs (a terminal or a
--- window) chose.
function M.apply(scope)
  if scope ~= nil and not exists(scope) then scope = nil end
  applied.scope = scope
  local rest = daw.opt.scope_rest
  local audible = scope and rest == "mute" and table.concat(M.tracks(scope), ",") or nil
  if audible ~= applied.audible then
    api.engine_audible(audible and M.tracks(scope) or nil)
    applied.audible = audible
  end
  local want = {}
  if scope and rest == "frozen" then
    for _, id in ipairs(M.rest_parts(scope)) do
      local h = held[id]
      if h and h.gen == gen_of(id) then
        want[id] = h.file
      else
        render_part(id)
      end
    end
  end
  applied.hold = applied.hold or {}
  for id, file in pairs(applied.hold) do
    if want[id] ~= file then
      if exists(id) then pcall(api.engine_hold, id, nil) end
      applied.hold[id] = nil
    end
  end
  for id, file in pairs(want) do
    if applied.hold[id] ~= file then
      api.engine_hold(id, file)
      applied.hold[id] = file
    end
  end
end

--- The parts of the rest the engine plays from files now.
function M.held()
  local out = {}
  for id in pairs(applied.hold or {}) do out[#out + 1] = id end
  table.sort(out)
  return out
end

daw.on("render.done", function(info)
  local p = pending[info.path]
  if not p then return end
  pending[info.path] = nil
  local old = held[p.id]
  if old and old.file ~= info.path then os.remove(old.file) end
  held[p.id] = { file = info.path, gen = p.gen }
  M.apply(applied.scope)
end)
for _, name in ipairs({ "render.failed", "render.cancelled" }) do
  daw.on(name, function(info)
    if info.path then pending[info.path] = nil else pending = {} end
  end)
end

-- An edit to a track makes what was rendered of it out of date.
local function touched(event)
  local id = event.track or event.id
  if not id then return end
  gens[id] = (gens[id] or 0) + 1
end
for _, name in ipairs({ "clip.added", "clip.changed", "clip.removed", "device.added", "device.changed", "device.removed", "lane.added", "lane.changed", "lane.removed" }) do
  daw.on(name, touched)
end

--- Lists edited as text read what the tab in front sees: read them again
--- (one with changes not written is marked as behind instead).
local function reread()
  for _, buf in pairs(L.buffers) do
    if buf.type == "textbuf" and buf.state and buf.state.kind then
      buf.state.seen = nil
      daw.textbuf.sync(buf)
    end
  end
end

daw.on("tab.enter", function()
  cursor_inside()
  reread()
  M.apply(M.current())
end)
daw.on("scope.changed", function()
  reread()
  M.apply(M.current())
end)
daw.on("option.changed", function(e)
  if e.name == "scope_rest" then M.apply(M.current()) end
end)
-- Tracks that come, go or change places change what the rest is.
for _, name in ipairs({ "track.added", "track.removed", "track.moved", "clip.added", "clip.removed" }) do
  daw.on(name, function()
    if applied.scope and daw.opt.scope_rest ~= "play" then M.apply(applied.scope) end
  end)
end
-- Another project: nothing of the last one is held.
daw.on("project.loaded", function()
  held, pending, gens = {}, {}, {}
  for _, t in ipairs(daw.ui.tabs) do t.scope = nil end
  applied = {}
  api.engine_audible(nil)
  for _, id in ipairs(api.engine_held()) do pcall(api.engine_hold, id, nil) end
end)

-- Commands and keys --------------------------------------------------------------------

local function group_names()
  local out = {}
  for _, id in ipairs(api.track_list()) do
    if groups.is_group(id) then out[#out + 1] = name_of(id) end
  end
  return out
end

daw.command("narrow", function(ctx)
  local which = ctx.args[1]
  if which == nil or which == true then which = M.group_at(daw.cursor.track_id()) end
  local t = M.narrow(which)
  daw.notify(string.format("narrowed to %s: %d tracks · `:widen` or `zw` goes back", t.name, #M.tracks()))
end, { desc = "Open a tab with only a group's tracks: `narrow Strings`; alone, the group at the cursor", complete = group_names })

daw.command("widen", function()
  if not M.widen() then daw.notify("this tab is not narrowed", "warn") end
end, { desc = "Close the narrowed tab and go back to the one it was narrowed from" })

return M
