-- What connections on the control socket can ask to be sent, on top of
-- calling into the kernel: events as they happen, and the state a graphical
-- frontend draws, pushed when it changes instead of asked for thirty times
-- a second. docs/reference/protocol.md describes the whole protocol; the transport
-- (the socket, TCP, the token) is in crates/paw-core/src/rpc.rs.
--
--   subscribe "transport.*" "project.saved"   -- events are pushed as they happen
--   unsubscribe                               -- all of them, or the ones named
--   frontend.watch                            -- `frontend.state` events from now on
--   frontend.unwatch
--
-- An extension can add methods of its own:
--   paw.remote.methods["mything.status"] = function(client, ...) return ... end
local api = paw.api
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
paw.on("*", function(payload, name)
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

-- The parts of `paw.frontend.state` that only change with the project, each
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

--- Send to a connection the changes of the state of the frontend after the
--- last send. Send nothing when nothing changed.
function M.push(client)
  local w = watchers[client]
  if not w then return end
  -- What the window draws is seen from its own seat.
  local state = paw.seats.within(client, paw.frontend.state, w.revision)
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
  -- Numbers that tremble (a meter falling towards nothing) are rounded to
  -- what a frontend can show, so that an idle program has nothing new to
  -- say; the engine's load comes steady already (`paw.audio.load`).
  for _, key in ipairs({ "levels", "inputs" }) do
    for i, level in ipairs(state[key] or {}) do state[key][i] = math.floor(level * 10000 + 0.5) / 10000 end
  end
  local text = api.json_encode(state)
  if not changed and text == w.tick then return end
  w.tick = text
  state.sections = changed
  if not api.rpc_push(client, "frontend.state", state) then M.closed(client) end
end

-- While something moves (the song plays, meters fall), the state is
-- pushed at the watchers' pace (`frontend.pace`); else once a second, for
-- what changes slowly on its own (the engine's load). What a key, the
-- pointer, a call or an edit changes is pushed after its turn (`M.turn`).
local fast  -- the timer waiting is at the pace
local touched = false
local last_push, pending = 0, nil
local seen_revision, seen_redraws

local function push_all()
  last_push = api.now()
  for client in pairs(watchers) do M.push(client) end
end

local function retime()
  local fastest
  for _, w in pairs(watchers) do fastest = math.min(fastest or w.interval, w.interval) end
  if timer then paw.cancel(timer) end
  timer = nil
  if not fastest then return end
  fast = paw.ui.active()
  timer = paw.defer(function()
    timer = nil
    push_all()
    retime()
  end, fast and fastest or 1000)
end

--- Something started to move (the song, a note played): push at the pace
--- from now.
function M.wake()
  if next(watchers) and not fast then retime() end
end

paw.on("transport.play", M.wake)

--- A turn had input: a key, the pointer, a call. What the frontends show
--- may have changed.
function M.touch()
  touched = true
  M.touches = M.touches + 1
end

--- How many turns had input: what a frontend is sent of the keyboard and
--- the panes can change only then (`paw.frontend.state`).
M.touches = 0

--- After each turn of the kernel: push now what its input or its edits
--- changed, at most once in 8 ms.
function M.turn()
  if not next(watchers) or pending then return end
  local revision, redraws = paw.frontend.revision, api.ui_redraws()
  if not touched and revision == seen_revision and redraws == seen_redraws then return end
  touched, seen_revision, seen_redraws = false, revision, redraws
  local wait = 8 - (api.now() - last_push)
  if wait <= 0 then return push_all() end
  pending = paw.defer(function()
    pending = nil
    push_all()
  end, wait)
end

M.methods["frontend.watch"] = function(client, opts)
  if client == 0 then error("only a connection can watch", 0) end
  local interval = type(opts) == "table" and tonumber(opts.interval) or 33
  watchers[client] = { revision = -1, sent = {}, interval = math.max(16, interval) }
  -- A window has a seat of its own, unless it shares the instance's (one
  -- that started its kernel itself, and is the instance's only face).
  if not (type(opts) == "table" and opts.seat == "instance") then
    paw.seats.open(client, "window")
    paw.seats.enter(client)
  end
  retime()
  -- The whole state at once, without waiting for the first tick.
  M.push(client)
  return true
end

--- The window says how often it draws what moves (`paw.opt.window_fps`):
--- the milliseconds between two frames. The state and the live values are
--- pushed at that pace while the song plays.
M.methods["frontend.pace"] = function(client, ms)
  ms = math.max(8, math.min(1000, tonumber(ms) or 33))
  if watchers[client] then watchers[client].interval = ms end
  if paw.scene then paw.scene.set_pace(ms) end
  retime()
  return true
end

M.methods["frontend.unwatch"] = function(client)
  watchers[client] = nil
  retime()
  paw.seats.close(client, "window")
  return true
end

--- A connection closed: nothing more is sent to it.
function M.closed(client)
  subs[client] = nil
  if watchers[client] then
    watchers[client] = nil
    retime()
    paw.seats.close(client, "window")
  end
end

--- The listeners: `{ client = { patterns = {...}, watching = bool }, ... }`.
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
paw.command("upload", function(ctx)
  local path = ctx.args[1]
  if not path or path == "" then return paw.notify("upload what? `upload ~/takes/bass.wav`", "warn") end
  local client = api.ui_client()
  if not paw.seats.has(client) then
    return paw.notify("this terminal is the instance's own: `:import` reads this machine's files", "warn")
  end
  api.rpc_push(client, "file.wanted", { path = path, import = true })
  paw.notify("asked for " .. path .. " from the attached terminal's machine")
end, { desc = "From a terminal attached with `paw attach`: send a sound file from that machine and import it: `upload ~/take.wav`", raw = true })

-- Sound plays on the instance's machine; a terminal or window attached from
-- another can have it played there too (`monitor.listen`), which its own
-- program starts and stops.
paw.command("listen", function()
  local client = api.ui_client()
  if not paw.seats.has(client) then
    return paw.notify("this is the instance's own terminal: its sound plays here already", "warn")
  end
  api.rpc_push(client, "monitor.toggle", {})
end, { desc = "From a terminal or window attached from another machine: hear the instance's sound there, or stop" })

paw.command("detach", function()
  local client = api.ui_client()
  -- A connection without a seat of its own (`paw ctl`) is no terminal.
  if not paw.seats.has(client) then
    return paw.notify("this is the program's own terminal: `:q` quits; `paw attach` from another terminal can be detached", "warn")
  end
  api.ui_detach(client)
end, { desc = "Leave a terminal that was attached with `paw attach`; the program runs on" })

return M
