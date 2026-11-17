-- What connections on the control socket can ask to be sent, on top of
-- calling into the kernel: events as they happen, and the state a graphical
-- frontend draws, pushed when it changes instead of asked for thirty times
-- a second. docs/protocol.md describes the whole protocol; the transport
-- (the socket, TCP, the token) is in crates/daw-core/src/rpc.rs.
--
--   subscribe "transport.*" "project.saved"   -- events are pushed as they happen
--   unsubscribe                               -- all of them, or the ones named
--   frontend.watch                            -- `frontend.state` events from now on
--   frontend.unwatch
--
-- An extension can add methods of its own:
--   daw.remote.methods["mything.status"] = function(client, ...) return ... end
local api = daw.api
local M = { methods = {} }

local subs = {}      -- connection -> list of event patterns
local watchers = {}  -- connection -> { revision, tick, sent = { section -> its JSON } }
local timer

local function matches(pattern, name)
  if pattern == "*" or pattern == name then return true end
  local family = pattern:match("^(.-)%.%*$")
  return family ~= nil and name:sub(1, #family + 1) == family .. "."
end

M.methods.subscribe = function(client, ...)
  local list = subs[client] or {}
  for _, pattern in ipairs({ ... }) do
    if type(pattern) == "string" then list[#list + 1] = pattern end
  end
  subs[client] = list
  return list
end

M.methods.unsubscribe = function(client, ...)
  local drop = { ... }
  if #drop == 0 then
    subs[client] = nil
    return {}
  end
  local keep = {}
  for _, pattern in ipairs(subs[client] or {}) do
    local gone = false
    for _, d in ipairs(drop) do gone = gone or d == pattern end
    if not gone then keep[#keep + 1] = pattern end
  end
  subs[client] = #keep > 0 and keep or nil
  return keep
end

-- Every event goes to the connections that asked for it. What cannot be
-- written as JSON (an extension's event carrying a function) is not sent.
daw.on("*", function(payload, name)
  for client, patterns in pairs(subs) do
    for _, pattern in ipairs(patterns) do
      if matches(pattern, name) then
        local ok, sent = pcall(api.rpc_push, client, name, payload)
        if ok and not sent then subs[client] = nil end
        break
      end
    end
  end
end)

-- The parts of `daw.frontend.state` that only change with the project, each
-- sent again only when it differs from what the connection last got. The
-- bar and beat lines are a part of their own: they are most of a long
-- song's state and change least.
local function sections_of(state)
  local project = {}
  for k, v in pairs(state.project) do project[k] = v end
  project.lines = nil
  return {
    project = project, lines = state.project.lines or {}, tracks = state.tracks or {},
    clips = state.clips or {}, devices = state.devices or {}, routing = state.routing or false, slots = state.slots or {},
    kinds = state.kinds, view = { selected = state.selected, cursor = state.cursor },
  }
end

local SECTION_KEYS = { "project", "tracks", "clips", "devices", "routing", "kinds", "selected", "cursor", "slots" }

--- Send a connection what has changed of the frontend's state since it was
--- last sent anything: nothing at all when nothing has.
function M.push(client)
  local w = watchers[client]
  if not w then return end
  -- What the window draws is seen from its own seat.
  local state = daw.seats.within(client, daw.frontend.state, w.revision)
  local changed
  if state.project then
    w.revision = state.revision
    for name, value in pairs(sections_of(state)) do
      local text = api.json_encode(value)
      if w.sent[name] ~= text then
        w.sent[name] = text
        changed = changed or {}
        changed[name] = value
      end
    end
    for _, key in ipairs(SECTION_KEYS) do state[key] = nil end
  end
  -- Numbers that tremble (the engine's load, a meter falling towards
  -- nothing) are rounded to what a frontend can show, so that an idle
  -- program has nothing new to say.
  state.cpu = math.floor((state.cpu or 0) * 100 + 0.5) / 100
  for _, key in ipairs({ "levels", "inputs" }) do
    for i, level in ipairs(state[key] or {}) do state[key][i] = math.floor(level * 10000 + 0.5) / 10000 end
  end
  local text = api.json_encode(state)
  if not changed and text == w.tick then return end
  w.tick = text
  state.sections = changed
  if not api.rpc_push(client, "frontend.state", state) then M.closed(client) end
end

local function retime()
  local fastest
  for _, w in pairs(watchers) do fastest = math.min(fastest or w.interval, w.interval) end
  if timer then daw.cancel(timer) end
  timer = fastest and daw.every(fastest, function()
    for client in pairs(watchers) do M.push(client) end
  end) or nil
end

M.methods["frontend.watch"] = function(client, opts)
  if client == 0 then error("only a connection can watch", 0) end
  local interval = type(opts) == "table" and tonumber(opts.interval) or 33
  watchers[client] = { revision = -1, sent = {}, interval = math.max(16, interval) }
  -- A window has a seat of its own, unless it shares the instance's (one
  -- that started its kernel itself, and is the instance's only face).
  if not (type(opts) == "table" and opts.seat == "instance") then
    daw.seats.open(client, "window")
    daw.seats.enter(client)
  end
  retime()
  -- The whole state at once, without waiting for the first tick.
  M.push(client)
  return true
end

M.methods["frontend.unwatch"] = function(client)
  watchers[client] = nil
  retime()
  daw.seats.close(client, "window")
  return true
end

--- A connection closed: nothing more is sent to it.
function M.closed(client)
  subs[client] = nil
  if watchers[client] then
    watchers[client] = nil
    retime()
    daw.seats.close(client, "window")
  end
end

--- Who is listening: { client = { patterns = {...}, watching = bool }, ... }.
function M.listeners()
  local out = {}
  for _, client in ipairs(api.rpc_clients()) do
    out[#out + 1] = { client = client, patterns = subs[client] or {}, watching = watchers[client] ~= nil }
  end
  return out
end

-- The instance cannot read the disk of the machine a terminal is attached
-- from, so it asks that terminal's program to send the file (`file.wanted`),
-- which sends it into the project's media folder and imports it.
daw.command("upload", function(ctx)
  local path = ctx.args[1]
  if not path or path == "" then return daw.notify("upload what? `upload ~/takes/bass.wav`", "warn") end
  local client = api.ui_client()
  if not daw.seats.has(client) then
    return daw.notify("this terminal is the instance's own: `:import` reads this machine's files", "warn")
  end
  api.rpc_push(client, "file.wanted", { path = path, import = true })
  daw.notify("asked for " .. path .. " from the attached terminal's machine")
end, { desc = "From a terminal attached with `daw attach`: send a sound file from that machine and import it: `upload ~/take.wav`", raw = true })

-- Sound plays on the instance's machine; a terminal or window attached from
-- another can have it played there too (`monitor.listen`), which its own
-- program starts and stops.
daw.command("listen", function()
  local client = api.ui_client()
  if not daw.seats.has(client) then
    return daw.notify("this is the instance's own terminal: its sound plays here already", "warn")
  end
  api.rpc_push(client, "monitor.toggle", {})
end, { desc = "From a terminal or window attached from another machine: hear the instance's sound there, or stop" })

daw.command("detach", function()
  local client = api.ui_client()
  -- A connection without a seat of its own (`daw ctl`) is no terminal.
  if not daw.seats.has(client) then
    return daw.notify("this is the program's own terminal: `:q` quits; `daw attach` from another terminal can be detached", "warn")
  end
  api.ui_detach(client)
end, { desc = "Leave a terminal that was attached with `daw attach`; the program runs on" })

return M
