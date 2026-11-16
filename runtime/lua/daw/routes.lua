-- Routes between tracks besides outputs and sends: side-chains, which a
-- device on one track takes from another, and the further output pairs of
-- a device with several (a drum plugin with a pair per drum).
--
--   comp:set_sidechain(kick)                -- the bass's compressor listens to the kick
--   comp:set_sidechain(kick, { pre = true }) -- before the kick's fader, pan and mute
--   kit:set_output(2, kick_track)           -- the kit's second pair plays there
--   daw.routes.spread(kit)                  -- a track for each pair
--   daw.routes.feeds(a, b)                  -- whether a's sound reaches b
--   :device.sidechain Kick                  -- the device panel's device
--   :device.output 2 Kick   :device.spread
local api = daw.api
local M = {}

--- Where each track's sound goes next, by id: its output (the master, 0,
--- without one), its sends, where its devices' further output pairs play,
--- and the tracks of the devices that listen to it.
local function edges()
  local out = {}
  for _, id in ipairs(api.track_list()) do out[id] = out[id] or {} end
  for _, id in ipairs(api.track_list()) do
    local t = api.track_get(id)
    table.insert(out[id], t.output or 0)
    for _, send in ipairs(t.sends or {}) do table.insert(out[id], send.target) end
    for _, to in ipairs(t.pairs_into or {}) do table.insert(out[id], to) end
    for _, source in ipairs(t.listens or {}) do
      if out[source] then table.insert(out[source], id) end
    end
  end
  return out
end

--- Every track reachable from `start` along `next`, as a set of ids.
local function walk(next, start)
  local seen, stack = {}, { start }
  while #stack > 0 do
    for _, id in ipairs(next[table.remove(stack)] or {}) do
      if not seen[id] then
        seen[id] = true
        stack[#stack + 1] = id
      end
    end
  end
  return seen
end

--- The tracks a track's sound reaches, directly or through others, as a set
--- of ids: by outputs, sends and side-chains.
function M.reached(from) return walk(edges(), from) end

--- The tracks whose sound reaches a track, as a set of ids.
function M.reaching(into)
  local back = {}
  for from, list in pairs(edges()) do
    for _, to in ipairs(list) do
      back[to] = back[to] or {}
      table.insert(back[to], from)
    end
  end
  return walk(back, into)
end

--- Whether `from`'s sound reaches `into`.
function M.feeds(from, into) return M.reached(from)[into] == true end

--- The tracks a device can listen to, `{ id, name }` each in the order of
--- the track list: not its own, not the master, and none its own feeds.
function M.sidechain_sources(device)
  local track = api.device_get(device).track
  local reached = M.reached(track)
  local out = {}
  for _, id in ipairs(api.track_list()) do
    if id ~= track and not reached[id] then out[#out + 1] = { id = id, name = api.track_get(id).name } end
  end
  return out
end

--- What a device listens to, as text: the track's name, with "pre" when
--- taken before its fader; nil without one.
function M.sidechain_text(d)
  if not d.sidechain then return nil end
  local ok, t = pcall(api.track_get, d.sidechain)
  return (ok and t.name or "?") .. (d.sidechain_pre and " pre" or "")
end

--- A track by itself, its id, or its name (the first whose name holds it);
--- nil for "none", "" or nil. Errors when there is no such track.
local function track_of(track)
  if type(track) ~= "string" then return track end
  if track == "" or track:lower() == "none" then return nil end
  local found = daw.track(track)
  if not found then
    for _, id in ipairs(api.track_list()) do
      if api.track_get(id).name:lower():find(track:lower(), 1, true) then return daw.track(id) end
    end
    error("no track `" .. track .. "`", 0)
  end
  return found
end

--- Set a device's side-chain by a track, a track's id or name ("none" or
--- nil for none), and `pre`. Errors say why it cannot be.
function M.set_sidechain(device, track, pre)
  daw.device(device):set_sidechain(track_of(track), { pre = pre })
end

--- A device's output pairs: `{ pair, name, target, target_name }` each,
--- the main one (pair 1, on its own track) first; empty for a device with
--- one pair.
function M.outputs(device)
  local d = api.device_get(device)
  local out = {}
  for pair, name in ipairs(d.ports and d.ports.outputs or {}) do
    local target = pair > 1 and (d.outputs or {})[tostring(pair)] or nil
    local ok, t = pcall(api.track_get, target or d.track)
    out[pair] = { pair = pair, name = name, target = target, target_name = target and ok and t.name or nil }
  end
  return out
end

--- Play a device's output pair `pair` (2 and on) into a track (a track, its
--- id or name; nil or "none" for nowhere). Errors say why it cannot be.
function M.set_output(device, pair, track)
  pair = math.floor(tonumber(pair) or 0)
  if pair < 2 then error("output pairs from 2 on can be routed; the first plays on the device's track", 0) end
  local outputs = {}
  for key, to in pairs(api.device_get(device).outputs or {}) do outputs[tostring(key)] = to end
  track = track_of(track)
  outputs[tostring(pair)] = track and (type(track) == "table" and track.id or track) or nil
  if next(outputs) == nil then outputs = nil end
  api.device_set(device, "outputs", outputs)
end

--- Make a track for each output pair of a device that plays nowhere yet,
--- named after the pair, and route the pair there. The new tracks and the
--- device's own are put in a group (or the group the device's track is
--- already in), since the device's track cannot be the group itself: its
--- pairs feed the new tracks, which would then feed it back. Returns the
--- new tracks.
function M.spread(device)
  local d = api.device_get(device)
  local made = {}
  local track = daw.track(d.track)
  local at = track.index
  for _, out in ipairs(M.outputs(device)) do
    if out.pair > 1 and not out.target then
      at = at + 1
      local t = daw.add_track({ name = out.name, index = at })
      M.set_output(device, out.pair, t)
      made[#made + 1] = t
    end
  end
  if #made == 0 then return made end
  local group = daw.groups.of(track)
  if group then
    for _, t in ipairs(made) do daw.groups.add(t, group) end
  else
    local members = { track }
    for _, t in ipairs(made) do members[#members + 1] = t end
    daw.groups.make(members, track.name .. " outputs")
  end
  return made
end

function M.setup()
  local command = daw.command

  command("device.sidechain", function(ctx)
    local device = daw.fx.target()
    if not device then return end
    local pre = ctx.args.pre ~= nil and ctx.args.pre ~= "0" and ctx.args.pre ~= "false"
    local function set(track)
      local ok, err = pcall(M.set_sidechain, device.id, track, pre)
      if not ok then return daw.notify((tostring(err):gsub("^[^:]*:%d+: ", ""):match("^[^\n]*")), "warn") end
      local text = M.sidechain_text(device:get())
      daw.notify(text and device.name .. " listens to " .. text or device.name .. " listens to its own input")
    end
    local name = table.concat(ctx.args, " ")
    if name ~= "" then return set(name) end
    local items = { { id = false, name = "None: its own input" } }
    for _, source in ipairs(M.sidechain_sources(device.id)) do items[#items + 1] = source end
    daw.pick({
      title = "Side-chain of " .. device.name, items = items,
      format = function(t) return t.name end,
      on_choose = function(t) set(t.id or nil) end,
    })
  end, {
    desc = "Let the device listen to another track as its side-chain: `device.sidechain Kick`, "
      .. "`device.sidechain Kick pre=1` (before its fader), `device.sidechain none`; alone, choose from a list",
    complete = { "tracks" },
  })

  daw.keymap.set("K", "device.sidechain", { view = "devices", desc = "Choose the track the device listens to (side-chain)" })

  local function warn(err) daw.notify((tostring(err):gsub("^[^:]*:%d+: ", ""):match("^[^\n]*")), "warn") end

  command("device.output", function(ctx)
    local device = daw.fx.target()
    if not device then return end
    local outputs = M.outputs(device.id)
    if #outputs < 2 then return daw.notify(device.name .. " has one output pair", "warn") end
    local function set(pair, track)
      local ok, err = pcall(M.set_output, device.id, pair, track)
      if not ok then return warn(err) end
      local out = M.outputs(device.id)[pair]
      daw.notify(string.format("%s %s → %s", device.name, out.name, out.target_name or "not heard"))
    end
    local function choose_track(pair)
      local items = { { id = false, name = "Nowhere: not heard" } }
      local reaching = M.reaching(device:get().track)
      for _, id in ipairs(api.track_list()) do
        if id ~= device:get().track and not reaching[id] then items[#items + 1] = { id = id, name = api.track_get(id).name } end
      end
      daw.pick({
        title = outputs[pair].name .. " of " .. device.name .. " into", items = items,
        format = function(t) return t.name end,
        on_choose = function(t) set(pair, t.id or nil) end,
      })
    end
    local pair = tonumber(ctx.args[1])
    if pair then
      local name = table.concat(ctx.args, " ", 2)
      if name == "" then return choose_track(pair) end
      return set(pair, name)
    end
    local items = {}
    for i = 2, #outputs do items[#items + 1] = outputs[i] end
    daw.pick({
      title = "Outputs of " .. device.name, items = items,
      format = function(o) return string.format("%-3d %-24s → %s", o.pair, o.name, o.target_name or "not heard") end,
      on_choose = function(o) choose_track(o.pair) end,
    })
  end, {
    desc = "Play one of the device's further output pairs into a track: `device.output 2 Kick`, "
      .. "`device.output 2 none`; alone, choose from a list",
  })

  command("device.spread", function()
    local device = daw.fx.target()
    if not device then return end
    local ok, made = pcall(M.spread, device.id)
    if not ok then return warn(made) end
    daw.notify(#made == 0 and "every output pair of " .. device.name .. " already plays somewhere"
      or string.format("%d output pairs of %s on tracks of their own", #made, device.name))
  end, { desc = "Spread the device's output pairs over new tracks, named after them and grouped with its track" })

  daw.keymap.set("O", "device.output", { view = "devices", desc = "Route the device's further output pairs" })
end

return M
