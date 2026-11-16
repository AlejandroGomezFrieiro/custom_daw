-- Language servers for music, as `vim.lsp`: any program that speaks MIDI
-- LSP's protocol (JSON-RPC 2.0 on its standard input and output, LSP's
-- lifecycle, `midi/*` methods for documents) is started from a config, sent
-- the clip open in the piano roll and what sounds with it, and its answers
-- go to the generic consumers: diagnostics to `daw.diagnostic`, the chords
-- and key it hears to `daw.harmony`, its suggestions to `daw.complete`, its
-- hover to a float. Nothing here knows any server by name: an extension
-- names one with `daw.lsp.config`.
--
--   daw.lsp.config("range", { cmd = { "python3", "range.py" }, attach = { tracks = { "Flute*" } } })
--   daw.lsp.enable("range")
local api = daw.api
local rpc = require("daw.lsp.rpc")
local document = require("daw.lsp.document")

local M = {
  configs = {},     -- name -> config
  handlers = {},    -- method -> function(client, params, message): what a server sends
  analysis = {},    -- clip id -> { key, keys, chords, client }: the last a server heard there
  debounce_ms = 250,
  log = {},         -- the last messages to and from servers, for `:lsp log`
}

local clients = {}  -- name -> client
local by_proc = {}  -- process id -> client

-- Servers left running by the Lua state before a `:reload`: the kernel
-- keeps processes, the clients that knew them are gone.
for _, id in ipairs(daw.state.lsp_procs or {}) do pcall(api.proc_kill, id) end
local function remember_procs()
  local ids = {}
  for id in pairs(by_proc) do ids[#ids + 1] = id end
  daw.state.lsp_procs = ids
end

-- Settings are objects to a server, even when they are empty.
local function object(t)
  if t == nil then return nil end
  local out = rpc.object()
  for k, v in pairs(t) do out[k] = v end
  return out
end

local function note(client, text)
  local line = string.format("%s %s", client and client.name or "lsp", text)
  M.log[#M.log + 1] = line
  if #M.log > 400 then table.remove(M.log, 1) end
  api.log("[lsp] " .. line)
end

-- Sending ---------------------------------------------------------------------

local function send(client, message)
  if not client.proc then return false end
  local ok, err = pcall(api.proc_write, client.proc, rpc.frame(message, client.config.framing))
  if not ok then note(client, "could not send: " .. tostring(err)) end
  return ok
end

local function client_of(which)
  if type(which) == "table" then return which end
  return clients[which]
end

--- Ask a server something; `cb(err, result)` is called with its answer.
--- Returns the request's id, or nil when the server is not there.
function M.request(which, method, params, cb)
  local client = client_of(which)
  if not client or not client.proc then
    if cb then cb({ code = -32803, message = "the server is not running" }) end
    return nil
  end
  client.next_id = client.next_id + 1
  local id = client.next_id
  client.pending[id] = { method = method, cb = cb }
  if not send(client, { jsonrpc = "2.0", id = id, method = method, params = params or rpc.object() }) then
    client.pending[id] = nil
    if cb then cb({ code = -32803, message = "the server is not running" }) end
    return nil
  end
  return id
end

--- Tell a server something that has no answer.
function M.notify(which, method, params)
  local client = client_of(which)
  if not client or not client.proc then return false end
  return send(client, { jsonrpc = "2.0", method = method, params = params or rpc.object() })
end

--- Tell a server to forget a request it has not answered yet.
function M.cancel(which, id)
  local client = client_of(which)
  if client and client.pending[id] then
    client.pending[id] = nil
    M.notify(client, "$/cancelRequest", { id = id })
  end
end

-- What a server can do, from its `initialize` answer: protocol version 2's
-- capabilities, or version 1's booleans read as them.
local function capabilities(result)
  local raw = type(result.capabilities) == "table" and result.capabilities or {}
  local caps = {}
  if (tonumber(result.protocolVersion) or 1) < 2 then
    if raw.diagnostics then caps.diagnosticProvider = { fixes = true } end
    if raw.hover then caps.hoverProvider = true end
    if raw.completion then caps.completionProvider = { lanes = { "notes", "velocity", "cc" } } end
    if raw.chords then caps.analysisProvider = { "key", "chords" } end
    return caps
  end
  for k, v in pairs(raw) do caps[k] = v end
  if caps.completionProvider == true then caps.completionProvider = { lanes = { "notes" } } end
  return caps
end

--- Whether a server said it can do something: `has(client, "hoverProvider")`,
--- or a lane of completion: `has(client, "completionProvider", "velocity")`.
function M.has(which, capability, lane)
  local client = client_of(which)
  local cap = client and client.status == "running" and client.caps[capability]
  if not cap then return false end
  if lane then
    for _, l in ipairs(type(cap) == "table" and cap.lanes or { "notes" }) do
      if l == lane then return true end
    end
    return false
  end
  return true
end

-- Documents -------------------------------------------------------------------

-- The clips open in a piano roll: each seat (each person's terminal or
-- window) has its own, and the servers are shared, so they get all of them.
local function roll_clips()
  local open = {}
  local function look()
    local view = daw.ui.views.pianoroll
    if view and view.clip_id and pcall(api.clip_get, view.clip_id) then open[view.clip_id] = true end
  end
  local seats = daw.seats and daw.seats.list() or {}
  if #seats <= 1 then
    look()
  else
    for _, seat in ipairs(seats) do daw.seats.within(seat, look) end
  end
  return open
end

-- Shell-style patterns with `*` and `?`, ignoring case.
local function matches(pattern, text)
  local lua = "^" .. pattern:lower():gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0"):gsub("%*", ".*"):gsub("%?", ".") .. "$"
  return text:lower():match(lua) ~= nil
end

--- Whether a server's `attach` takes a clip: `kinds` must hold "clip",
--- and the track's name must match one of `tracks` (when given), and the
--- track must play drums or not as `drums` says (when given).
function M.attaches(which, id)
  local client = client_of(which)
  local attach = client and client.config.attach or {}
  local kinds = attach.kinds or { "clip" }
  local ok, c = pcall(api.clip_get, id)
  if not ok or c.kind ~= "midi" then return false end
  local wanted = false
  for _, k in ipairs(kinds) do wanted = wanted or k == "clip" end
  if not wanted then return false end
  local track = api.track_get(c.track)
  if attach.tracks then
    local any = false
    for _, p in ipairs(attach.tracks) do any = any or matches(p, track.name) end
    if not any then return false end
  end
  if attach.drums ~= nil and attach.drums ~= document.is_drums(track) then return false end
  return true
end

local function close_doc(client, id)
  if not client.docs[id] then return end
  client.docs[id] = nil
  M.notify(client, "midi/didClose", { uri = document.uri(id) })
  daw.diagnostic.reset(client.name, id)
end

-- Send a clip to a server if it changed since it was last sent (or was
-- never sent): `midi/didOpen` the first time, `midi/didChange` after.
local function send_doc(client, id)
  local key = document.key_of(id)
  if not key then return close_doc(client, id) end
  local doc = client.docs[id]
  if doc and doc.hash == key then return end
  local params = document.build(id, key)
  if not params then return end
  client.docs[id] = { hash = key, version = (doc and doc.version or 0) + 1, kept = doc and doc.kept }
  M.request(client, doc and "midi/didChange" or "midi/didOpen", params, function(err)
    if err then note(client, "the document was refused: " .. tostring(err.message)) end
  end)
end

--- Bring every running server up to date with the piano roll's clip now:
--- open it, send what changed, close what it showed before. Requests call
--- this first, so that they are about what is on screen.
function M.sync()
  if M.timer then
    daw.cancel(M.timer)
    M.timer = nil
  end
  local open = roll_clips()
  for _, client in pairs(clients) do
    if client.status == "running" then
      for id, doc in pairs(client.docs) do
        if not open[id] and not doc.kept then close_doc(client, id) end
      end
      for id in pairs(open) do
        if M.attaches(client, id) then send_doc(client, id) end
      end
      for id, doc in pairs(client.docs) do
        if doc.kept then send_doc(client, id) end
      end
    end
  end
end

-- An edit is sent once the edits have paused for `debounce_ms`.
local function schedule()
  if M.timer or not next(clients) then return end
  M.timer = daw.defer(function()
    M.timer = nil
    M.sync()
  end, M.debounce_ms)
end

--- Have a server keep a clip open whether or not it is in the piano roll
--- (`keep` false lets it go). The server must take the clip (`attaches`).
function M.attach(which, id, keep)
  local client = client_of(which)
  if not client then return false end
  if keep == false then
    if client.docs[id] then client.docs[id].kept = nil end
    M.sync()
    return true
  end
  if client.status ~= "running" or not M.attaches(client, id) then return false end
  send_doc(client, id)
  if client.docs[id] then client.docs[id].kept = true end
  return true
end

-- Answers ---------------------------------------------------------------------

-- The clip a message is about, when it is about the document as last sent.
local function current_doc(client, params)
  local id = document.clip_of(params and params.uri)
  local doc = id and client.docs[id]
  if not doc then return nil end
  if params.hash and params.hash ~= doc.hash then return nil end
  return id, doc
end

M.handlers["midi/publishDiagnostics"] = function(client, params)
  local id = current_doc(client, params)
  if not id then return end
  local list = {}
  for _, d in ipairs(params.diagnostics or {}) do
    local notes = {}
    for _, n in ipairs(d.notes or {}) do notes[#notes + 1] = n + 1 end
    local fixes = {}
    for _, fix in ipairs(d.fixes or {}) do
      local edits = {}
      for _, e in ipairs(fix.edits or {}) do
        edits[#edits + 1] = { note = e.note + 1, pitch = e.pitch, delete = e.delete,
          start = e.start and document.beats(e.start), length = e.length and document.beats(e.length), velocity = e.vel }
      end
      fixes[#fixes + 1] = { title = fix.title, edits = edits }
    end
    list[#list + 1] = {
      notes = notes, at = document.beats(d.start), length = document.beats((d["end"] or d.start or 0) - (d.start or 0)),
      severity = d.severity, message = d.message, rule = d.code or d.rule, source = d.source or client.name,
      fixes = fixes, data = { related = d.related },
    }
  end
  daw.diagnostic.set(client.name, id, list)
end

-- Chords and keys in project beats, as `daw.harmony` has them.
local function analysis_of(id, params)
  local c = api.clip_get(id)
  local chords, keys = {}, {}
  for _, ch in ipairs(params.chords or {}) do
    if ch.start then
      chords[#chords + 1] = {
        at = c.start + document.beats(ch.start), length = document.beats(ch["end"] - ch.start),
        root = ch.root, quality = ch.quality, bass = ch.bass or ch.root, name = ch.name, roman = ch.roman,
        tones = ch.tones, ["function"] = ch["function"], cadence = ch.cadence,
      }
    end
  end
  local mode = function(k) return tostring(k.scale or k.mode or "major") end
  for _, k in ipairs(params.keys or {}) do
    if k.root then
      local from = k.start and c.start + document.beats(k.start) or c.start
      local to = k["end"] and c.start + document.beats(k["end"]) or c.start + c.length
      keys[#keys + 1] = { at = from, length = to - from, tonic = k.root, mode = mode(k), name = k.name }
    end
  end
  local key = params.key and params.key.root and { tonic = params.key.root, mode = mode(params.key), name = params.key.name }
  return { chords = chords, keys = keys, key = key }
end

-- What the servers heard, offered to `daw.harmony` for the stretch asked.
local function harmony_provider(from, to)
  local chords, keys = {}, {}
  for _, a in pairs(M.analysis) do
    for _, ch in ipairs(a.chords) do
      if ch.at < to and ch.at + ch.length > from then chords[#chords + 1] = ch end
    end
    for _, k in ipairs(a.keys) do
      if k.at < to and k.at + k.length > from then keys[#keys + 1] = k end
    end
  end
  if #chords == 0 and #keys == 0 then return nil end
  table.sort(chords, function(a, b) return a.at < b.at end)
  table.sort(keys, function(a, b) return a.at < b.at end)
  return chords, keys
end

local provided = false
M.handlers["midi/publishAnalysis"] = function(client, params)
  local id = current_doc(client, params)
  if not id then return end
  local a = analysis_of(id, params)
  a.client = client.name
  M.analysis[id] = a
  if not provided and daw.harmony and daw.harmony.provide then
    daw.harmony.provide("lsp", harmony_provider, 50)
    provided = true
  end
  daw.emit("lsp.analysis", { clip = id, client = client.name })
end

M.handlers["window/logMessage"] = function(client, params) note(client, tostring(params.message)) end
M.handlers["window/showMessage"] = function(client, params)
  note(client, tostring(params.message))
  daw.notify(client.name .. ": " .. tostring(params.message), params.type == 1 and "error" or params.type == 2 and "warn" or "info")
end

-- What a server may ask of us.
M.handlers["workspace/configuration"] = function(client, params)
  local out = {}
  for i = 1, #(params.items or { 1 }) do out[i] = object(client.config.settings) or rpc.object() end
  return out
end

local function dispatch(client, message)
  if message.invalid then
    note(client, "sent something that is not JSON-RPC: " .. tostring(message.error))
    return
  end
  if message.id ~= nil and not message.method then
    local waiting = client.pending[message.id]
    client.pending[message.id] = nil
    if waiting and waiting.cb then
      if message.error then
        waiting.cb(message.error)
      else
        waiting.cb(nil, message.result)
      end
    end
    return
  end
  local handler = M.handlers[message.method]
  if message.id ~= nil then
    -- A request of the server's own: always answered.
    if handler then
      local ok, result = pcall(handler, client, message.params or {}, message)
      if ok then
        send(client, { jsonrpc = "2.0", id = message.id, result = result == nil and rpc.object() or result })
      else
        send(client, { jsonrpc = "2.0", id = message.id, error = { code = -32603, message = tostring(result) } })
      end
    else
      send(client, { jsonrpc = "2.0", id = message.id, error = { code = -32601, message = "unknown method " .. tostring(message.method) } })
    end
  elseif handler then
    local ok, err = pcall(handler, client, message.params or {}, message)
    if not ok then note(client, message.method .. ": " .. tostring(err)) end
  end
end

-- Starting and stopping ------------------------------------------------------

local start

local function forget(client, status, why)
  if client.proc then
    by_proc[client.proc] = nil
    pcall(api.proc_kill, client.proc)
    client.proc = nil
    remember_procs()
  end
  for id, waiting in pairs(client.pending) do
    client.pending[id] = nil
    if waiting.cb then pcall(waiting.cb, { code = -32803, message = "the server stopped" }) end
  end
  client.status, client.error = status, why or client.error
  client.docs = {}
  daw.diagnostic.reset(client.name)
  for id, a in pairs(M.analysis) do
    if a.client == client.name then M.analysis[id] = nil end
  end
  note(client, status .. (why and (": " .. why) or ""))
  daw.emit("lsp.status", { client = client.name, status = status })
  api.ui_redraw()
end

-- The process ended without being asked: start it again if the config
-- allows that many restarts in that time.
local function died(client)
  local code = (select(2, pcall(api.proc_status, client.proc)) or {}).code
  forget(client, "dead", "the server stopped" .. (code and (" with code " .. code) or ""))
  local restart = client.config.restart or {}
  local now = api.now()
  local recent = {}
  for _, t in ipairs(client.restarts) do
    if now - t < (restart.within_s or 60) * 1000 then recent[#recent + 1] = t end
  end
  client.restarts = recent
  if #recent < (restart.max or 0) then
    client.restarts[#client.restarts + 1] = now
    daw.defer(function()
      if clients[client.name] == client and client.status == "dead" then start(client) end
    end, 500)
  end
end

local function on_output(event)
  local client = by_proc[event.id]
  if not client then return end
  while client.proc == event.id do
    local bytes = api.proc_read(event.id)
    if bytes == nil then return died(client) end
    if bytes == "" then return end
    for _, message in ipairs(client.reader:push(bytes)) do dispatch(client, message) end
  end
end
daw.on("proc.output", on_output)

local function command_of(config)
  local cmd = config.cmd
  if type(cmd) == "function" then cmd = cmd() end
  if type(cmd) == "string" then cmd = { cmd } end
  return type(cmd) == "table" and #cmd > 0 and cmd or nil
end

--- Where a server's errors are written.
function M.log_path(name)
  return api.env().state_dir .. "/daw/lsp-" .. tostring(name):gsub("[^%w%-_.]", "_") .. ".log"
end

start = function(client)
  local cmd = command_of(client.config)
  if not cmd then return forget(client, "dead", "no command to start it with") end
  local log = M.log_path(client.name)
  os.execute("mkdir -p '" .. log:match("^(.*)/"):gsub("'", "'\\''") .. "'")
  local ok, proc = pcall(api.proc_spawn, cmd, { pipe = true, log = log, env = client.config.env, cwd = client.config.cwd })
  if not ok then return forget(client, "dead", tostring(proc)) end
  client.proc, client.reader, client.status, client.error = proc, rpc.reader(client.config.framing), "starting", nil
  client.pending, client.docs, client.next_id = {}, {}, 0
  by_proc[proc] = client
  remember_procs()
  note(client, "started: " .. table.concat(cmd, " "))
  M.request(client, "initialize", {
    protocolVersion = 2,
    clientInfo = { name = "daw", version = daw.version },
    capabilities = rpc.object(),
    initializationOptions = object(client.config.init_options),
    configuration = object(client.config.settings),
  }, function(err, result)
    if client.proc ~= proc then return end
    if err or type(result) ~= "table" then
      return forget(client, "dead", "initialize failed: " .. tostring(err and err.message or "no answer"))
    end
    client.caps, client.info = capabilities(result), result.serverInfo or {}
    client.protocol = tonumber(result.protocolVersion) or 1
    if client.protocol >= 2 then M.notify(client, "initialized", rpc.object()) end
    client.status = "running"
    note(client, "running" .. (client.info.name and (": " .. client.info.name .. " " .. tostring(client.info.version or "")) or ""))
    daw.emit("lsp.status", { client = client.name, status = "running" })
    M.sync()
  end)
end

local function stop(client, status)
  if client.proc then
    local proc = client.proc
    -- LSP's way out: `shutdown`, then `exit`. The process is let go of
    -- at once, and killed if it is still there in a while.
    M.request(client, "shutdown", nil)
    M.notify(client, "exit")
    pcall(api.proc_close_input, proc)
    daw.defer(function() pcall(api.proc_kill, proc) end, 1000)
    by_proc[proc] = nil
    client.proc = nil
  end
  forget(client, status or "stopped")
end

--- Say how to start a server and what to send it, as `vim.lsp.config`. A
--- second call changes only the fields it gives.
---   cmd          the program and its arguments (or a function giving them)
---   framing      "lines" (newline-delimited JSON, the default) or "headers" (Content-Length)
---   attach       { kinds = { "clip" }, tracks = { "Flute*" }, drums = false }
---   settings     sent at `initialize` and with `workspace/didChangeConfiguration`
---   init_options sent once, as `initializationOptions`
---   restart      { max = 3, within_s = 60 }: restarts after it dies (none by default)
---   env, cwd     for the process
function M.config(name, config)
  local old = M.configs[name] or {}
  for k, v in pairs(config or {}) do old[k] = v end
  M.configs[name] = old
  local client = clients[name]
  if client then
    client.config = old
    if config and config.settings and client.status == "running" then
      M.notify(client, "workspace/didChangeConfiguration", { settings = object(old.settings) })
    end
  end
  return old
end

--- Start a configured server (`on` false stops it).
function M.enable(name, on)
  local client = clients[name]
  if on == false then
    if client then
      stop(client)
      clients[name] = nil
    end
    return
  end
  local config = M.configs[name]
  if not config then error("no server `" .. tostring(name) .. "`: daw.lsp.config it first", 2) end
  if client and client.proc then return client end
  client = client or { name = name, restarts = {}, pending = {}, docs = {}, caps = {}, next_id = 0 }
  client.config = config
  clients[name] = client
  start(client)
  return client
end

--- Stop a server and start it again.
function M.restart(name)
  local client = clients[name]
  if not client then return M.enable(name) end
  stop(client, "restarting")
  client.restarts = {}
  start(client)
  return client
end

--- Stop every server, or the one named.
function M.stop(name)
  for n, client in pairs(clients) do
    if not name or n == name then
      stop(client)
      clients[n] = nil
    end
  end
end

--- The servers that were enabled, as
--- `{ name, status, error, capabilities, server, pid, documents, client }`.
function M.clients()
  local out = {}
  for name, client in pairs(clients) do
    local docs = {}
    for id in pairs(client.docs) do docs[#docs + 1] = id end
    table.sort(docs)
    local pid = client.proc and (select(2, pcall(api.proc_status, client.proc)) or {}).pid
    out[#out + 1] = { name = name, status = client.status, error = client.error, capabilities = client.caps,
      server = client.info, pid = pid, documents = docs, client = client }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- Wait in a script until every server has started and answered what it
--- was sent (or `ms` have passed, 10 s by default). Returns whether they did.
function M.settle(ms)
  local deadline = api.now() + (ms or 10000)
  M.sync()
  while api.now() < deadline do
    local busy = false
    for _, client in pairs(clients) do
      busy = busy or client.status == "starting" or (client.proc and next(client.pending) ~= nil)
    end
    if not busy then return true end
    daw.wait(10)
  end
  return false
end

-- Hover ----------------------------------------------------------------------

-- What a hover answer says, in lines: LSP's `contents` when the server
-- gives them, else the musical facts it answered, one a line.
function M.hover_lines(result)
  if type(result) ~= "table" then return {} end
  local contents = result.contents
  if type(contents) == "table" and contents.value then contents = contents.value end
  if type(contents) == "table" then contents = table.concat(contents, "\n") end
  if type(contents) == "string" then
    local out = {}
    for line in (contents .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = line end
    return out
  end
  local out = {}
  local p = result.pitch
  if type(p) == "table" then out[#out + 1] = "note   " .. tostring(p.name or p.pitch) .. (p.degree and ("  (degree " .. p.degree .. " of the key)") or "") end
  local ch = result.chord
  if type(ch) == "table" then out[#out + 1] = "chord  " .. tostring(ch.name) .. (ch.roman and ch.roman ~= ch.name and ("  " .. ch.roman) or "") end
  local key = result.key
  if type(key) == "table" then out[#out + 1] = "key    " .. tostring(key.name or key.root) end
  for k, v in pairs(result) do
    if k ~= "pitch" and k ~= "chord" and k ~= "key" and k ~= "tick" and (type(v) == "string" or type(v) == "number") then
      out[#out + 1] = string.format("%-6s %s", k, tostring(v))
    end
  end
  return out
end

--- Ask every server that hovers about a place in a clip (`pitch` and `beat`
--- from its start); `cb(sections)` gets `{ { client, lines } }` once all
--- have answered.
function M.hover(id, pitch, beat, cb)
  M.sync()
  local asked, sections = 0, {}
  local function finish()
    asked = asked - 1
    if asked == 0 then
      table.sort(sections, function(a, b) return a.client < b.client end)
      cb(sections)
    end
  end
  for name, client in pairs(clients) do
    local doc = client.docs[id]
    if doc and M.has(client, "hoverProvider") then
      asked = asked + 1
      M.request(client, "midi/hover", { uri = document.uri(id), hash = doc.hash, tick = document.tick(beat), pitch = pitch }, function(err, result)
        if not err then
          local lines = M.hover_lines(result)
          if #lines > 0 then sections[#sections + 1] = { client = name, lines = lines } end
        end
        finish()
      end)
    end
  end
  if asked == 0 then cb(sections) end
end

--- Show what is known about the note (or place) under the piano roll's
--- cursor, in a float: the diagnostics about it, then each server's hover.
function M.show_hover(id, pitch, beat)
  local view = daw.ui.views.pianoroll
  id, pitch, beat = id or view.clip_id, pitch or view.pitch, beat or view.beat
  if not id then return daw.notify("open a clip in the piano roll first", "warn") end
  local _, place = api.clip_note_at(id, pitch, beat)
  local lines = {}
  for _, d in ipairs(place and daw.diagnostic.get(id, { note = place }) or {}) do
    lines[#lines + 1] = { text = daw.diagnostic.format(d), style = daw.diagnostic.group("Diagnostic", d.severity) }
    for _, fix in ipairs(d.fixes) do lines[#lines + 1] = "  fix: " .. tostring(fix.title) end
  end
  -- The answers may come in another person's turn: the float is shown to
  -- whoever asked.
  local seat = daw.seats and daw.seats.current
  M.hover(id, pitch, beat, function(sections)
    if seat and seat ~= daw.seats.current then return daw.seats.within(seat, M.show_lines, id, pitch, beat, lines, sections) end
    M.show_lines(id, pitch, beat, lines, sections)
  end)
end

--- The hover float itself: the diagnostics' lines, then each server's.
function M.show_lines(id, pitch, beat, lines, sections)
  for _, s in ipairs(sections) do
    if #lines > 0 then lines[#lines + 1] = "" end
    lines[#lines + 1] = { text = s.client, style = "Title" }
    for _, line in ipairs(s.lines) do lines[#lines + 1] = "  " .. line end
  end
  if #lines == 0 then return daw.notify("nothing to say about " .. daw.music.name(pitch) .. " here") end
  local width = 20
  for _, line in ipairs(lines) do width = math.max(width, api.str_width(type(line) == "table" and line.text or line) + 4) end
  daw.ui.page(daw.music.name(pitch) .. " " .. daw.time.format(api.clip_get(id).start + beat), lines,
    { width = math.min(100, width), height = math.min(30, #lines + 3) })
end

-- Code actions -----------------------------------------------------------------

--- Pick a fix for the note under the piano roll's cursor (or, off a note,
--- for the diagnostics where the cursor is), and carry it out as one undo step.
function M.code_actions()
  local view = daw.ui.views.pianoroll
  local id = view.clip_id
  if not id then return daw.notify("open a clip in the piano roll first", "warn") end
  local _, place = api.clip_note_at(id, view.pitch, view.beat)
  local actions = place and daw.diagnostic.actions(id, place) or {}
  if not place then
    for _, d in ipairs(daw.diagnostic.get(id)) do
      if view.beat >= d.at - 1e-9 and view.beat < d.at + math.max(d.length, 1e-6) then
        for _, fix in ipairs(d.fixes) do
          actions[#actions + 1] = { title = fix.title, diagnostic = d, run = function() return daw.diagnostic.apply(d, fix) end }
        end
      end
    end
  end
  if #actions == 0 then return daw.notify("no fixes here") end
  local items = {}
  for _, a in ipairs(actions) do
    items[#items + 1] = { text = string.format("%s  (%s)", a.title, a.diagnostic.rule or a.diagnostic.source), action = a }
  end
  daw.pick({
    title = "Code actions",
    items = items,
    on_choose = function(item) if item then item.action.run() end end,
  })
end

-- Completion -------------------------------------------------------------------

-- A server's suggested notes in the clip's beats.
local function ghost_notes(notes)
  local out = {}
  for _, n in ipairs(notes or {}) do
    out[#out + 1] = { pitch = n.pitch, start = document.beats(n.start), length = document.beats(n["end"] - n.start), velocity = n.vel or 100 }
  end
  return out
end

-- The places of the notes of a note set in a clip, found by pitch and start.
local function places_of(id, set)
  local out = {}
  for _, n in ipairs(set or {}) do
    local place = n.place or n.index
    if not place then
      local found, at = api.clip_notes(id, { from = (n.start or n.at) - 1e-6, to = (n.start or n.at) + 1e-6, low = n.pitch, high = n.pitch })
      place = at[1]
    end
    if place then out[#out + 1] = place - 1 end
  end
  return out
end

--- A completion source over every running server that suggests, in the
--- shape `daw.complete.register` takes: `ctx` names the `clip` and where
--- the suggestion starts (`at`, beats from the clip's start); with a
--- `selection` (a note set of the clip) servers that suggest lines and
--- velocities are asked about those notes too. `done(items)` is called once.
function M.complete(ctx, done)
  local id = ctx.clip and (type(ctx.clip) == "table" and ctx.clip.id or ctx.clip)
  if not id then return done(nil) end
  local items, asked, ids = {}, 0, {}
  local function finish()
    asked = asked - 1
    if asked == 0 then done(#items > 0 and items or nil) end
  end
  local function ask(client, method, params, make)
    asked = asked + 1
    local request = M.request(client, method, params, function(err, result)
      if not err and type(result) == "table" then
        for _, item in ipairs(result.items or {}) do
          local made = make(item)
          if made then
            made.source = made.source or client.name
            items[#items + 1] = made
          end
        end
      end
      finish()
    end)
    if request then ids[#ids + 1] = { client = client, id = request } end
  end
  asked = 1
  for _, client in pairs(clients) do
    if client.status == "running" and M.has(client, "completionProvider") and M.attaches(client, id) then
      send_doc(client, id)
      local doc = client.docs[id]
      if doc then
        local base = { uri = document.uri(id), hash = doc.hash }
        if M.has(client, "completionProvider", "notes") then
          ask(client, "midi/completion", daw.util.merge(base, { position = document.tick(ctx.at or 0), count = ctx.count or 3, mode = ctx.mode or "auto" }),
            function(item)
              return { label = item.label or item.kind or "notes", detail = item.kind and string.format("%s %.2f", item.kind, item.score or 0) or nil, notes = ghost_notes(item.notes) }
            end)
        end
        local selected = ctx.selection and places_of(id, ctx.selection)
        if selected and #selected > 0 and M.has(client, "completionProvider", "line") then
          ask(client, "midi/line", daw.util.merge(base, { notes = selected }), function(item)
            return { label = item.label or "line", detail = item.kind, notes = ghost_notes(item.notes) }
          end)
        end
        if selected and #selected > 0 and M.has(client, "completionProvider", "velocity") then
          ask(client, "midi/velocity", daw.util.merge(base, { notes = selected }), function(item)
            local velocities = {}
            for _, e in ipairs(item.edits or {}) do velocities[e.note + 1] = e.vel end
            return { label = item.label or "velocity", detail = "velocities", notes = {}, velocities = velocities }
          end)
        end
        if ctx.controller and M.has(client, "completionProvider", "cc") then
          ask(client, "midi/cc", daw.util.merge(base, { cc = ctx.controller }), function(item)
            local controls = {}
            for _, p in ipairs(item.points or {}) do
              controls[#controls + 1] = { start = document.beats(p.tick), type = "cc", number = ctx.controller, value = p.value / 127 }
            end
            return { label = item.label or ("CC " .. ctx.controller), detail = "controller curve", notes = {}, controls = controls }
          end)
        end
      end
    end
  end
  M.pending_completion = ids
  finish()
end

--- Forget the completion requests still out (a newer one replaced them).
function M.complete_cancel()
  for _, r in ipairs(M.pending_completion or {}) do M.cancel(r.client, r.id) end
  M.pending_completion = nil
end

-- Offered to `daw.complete` when it is there, whichever is loaded first.
local offered = false
local function offer()
  if offered or not (daw.complete and daw.complete.register) then return end
  offered = true
  daw.complete.register({
    name = "lsp", priority = 100, views = { "pianoroll" }, auto = true,
    complete = function(ctx, done) M.complete(ctx, done) end,
    cancel = function() M.complete_cancel() end,
  })
end
offer()
daw.on("startup", offer)

-- Following the piano roll --------------------------------------------------------

daw.on("pianoroll.opened", function() if next(clients) then M.sync() end end)
for _, name in ipairs({ "changed", "clip.*", "track.*", "device.*", "project.changed" }) do daw.on(name, schedule) end
daw.on("exit", function() M.stop() end)

-- `:lsp` -------------------------------------------------------------------------

--- What `:lsp info` shows: each server, its state, what it said it can do
--- and what it was sent.
function M.info_lines()
  local lines = {}
  local names = {}
  for name in pairs(M.configs) do names[#names + 1] = name end
  table.sort(names)
  if #names == 0 then return { "No language servers are configured.", "", "daw.lsp.config(name, { cmd = { ... } }) and daw.lsp.enable(name)." } end
  for _, name in ipairs(names) do
    local client, config = clients[name], M.configs[name]
    lines[#lines + 1] = { text = name .. "  " .. (client and client.status or "off"), style = "Title" }
    local cmd = command_of(config)
    lines[#lines + 1] = "  command   " .. (cmd and table.concat(cmd, " ") or "(none found)")
    if client then
      if client.error then lines[#lines + 1] = "  error     " .. client.error end
      if client.info and client.info.name then lines[#lines + 1] = "  server    " .. client.info.name .. " " .. tostring(client.info.version or "") end
      local caps = {}
      for k in pairs(client.caps or {}) do caps[#caps + 1] = (k:gsub("Provider$", "")) end
      table.sort(caps)
      if #caps > 0 then lines[#lines + 1] = "  can       " .. table.concat(caps, ", ") end
      local docs = {}
      for id in pairs(client.docs) do docs[#docs + 1] = document.uri(id) end
      table.sort(docs)
      if #docs > 0 then lines[#lines + 1] = "  documents " .. table.concat(docs, ", ") end
    end
    lines[#lines + 1] = "  errors to " .. M.log_path(name)
    lines[#lines + 1] = ""
  end
  return lines
end

--- `:lsp [info|start|stop|restart|log] [name]`.
function M.command(ctx)
  local verb, name = ctx.args[1] or "info", ctx.args[2]
  if verb == "info" then
    daw.ui.page("Language servers", M.info_lines())
  elseif verb == "log" then
    daw.ui.page("Language servers: log", #M.log > 0 and M.log or { "Nothing yet." }, { bottom = true })
  elseif verb == "stop" then
    M.stop(name)
  elseif verb == "start" or verb == "restart" then
    local names = {}
    if name then names[1] = name else for n in pairs(M.configs) do names[#names + 1] = n end end
    for _, n in ipairs(names) do
      local ok, err = pcall(verb == "start" and M.enable or M.restart, n)
      if not ok then daw.notify(tostring(err), "error") end
    end
  else
    daw.notify("lsp: info, start, stop, restart or log", "warn")
  end
end

function M.command_complete()
  local out = { "info", "log", "start", "stop", "restart" }
  for name in pairs(M.configs) do out[#out + 1] = name end
  return out
end

-- The window's gestures on the piano roll's notes.
function daw.frontend.act.note_hover(clip, place)
  local n = api.clip_notes(clip)[place]
  if n then M.show_hover(clip, n.pitch, n.start) end
end

return M
