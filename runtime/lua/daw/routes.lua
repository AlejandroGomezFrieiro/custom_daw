-- Routes between tracks besides outputs and sends: side-chains, which a
-- device on one track takes from another.
--
--   comp:set_sidechain(kick)                -- the bass's compressor listens to the kick
--   comp:set_sidechain(kick, { pre = true }) -- before the kick's fader, pan and mute
--   daw.routes.feeds(a, b)                  -- whether a's sound reaches b
--   :device.sidechain Kick                  -- the device panel's device
--   :device.sidechain none
local api = daw.api
local M = {}

--- Where each track's sound goes next, by id: its output (the master, 0,
--- without one), its sends, and the tracks of the devices that listen to it.
local function edges()
  local out = {}
  for _, id in ipairs(api.track_list()) do out[id] = out[id] or {} end
  for _, id in ipairs(api.track_list()) do
    local t = api.track_get(id)
    table.insert(out[id], t.output or 0)
    for _, send in ipairs(t.sends or {}) do table.insert(out[id], send.target) end
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

--- Set a device's side-chain by a track, a track's id or name ("none" or
--- nil for none), and `pre`. Errors say why it cannot be.
function M.set_sidechain(device, track, pre)
  if type(track) == "string" then
    if track == "" or track:lower() == "none" then
      track = nil
    else
      local found = daw.track(track)
      if not found then
        for _, id in ipairs(api.track_list()) do
          if api.track_get(id).name:lower():find(track:lower(), 1, true) then
            found = daw.track(id)
            break
          end
        end
      end
      if not found then error("no track `" .. track .. "`", 0) end
      track = found
    end
  end
  daw.device(device):set_sidechain(track, { pre = pre })
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
end

return M
