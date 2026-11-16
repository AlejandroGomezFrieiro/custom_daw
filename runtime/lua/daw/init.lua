-- `require("daw")`: the whole scripting surface, assembled from the modules in
-- this directory. The kernel provides `daw.api`; everything else is Lua that
-- you can read, replace or extend.
local api = require("daw.api")

local daw = { api = api, version = "0.1.0" }
_G.daw = daw
package.loaded["daw"] = daw

daw.util = require("daw.util")
daw.inspect = daw.util.inspect

--- Call a function, reporting an error as a message instead of raising it.
--- Returns true and the function's results, or false and the error.
function daw.try(fn, ...)
  local result = { xpcall(fn, debug.traceback, ...) }
  if not result[1] then daw.notify(result[2], "error") end
  return unpack(result)
end

local events = require("daw.events")
daw.on, daw.once, daw.off, daw.emit = events.on, events.once, events.off, events.emit

local options = require("daw.options")
daw.opt, daw.option = options.opt, options
daw.limit = require("daw.limit")

--- Run `fn` once, after `ms` milliseconds (or as soon as the current turn ends).
function daw.defer(fn, ms)
  return api.timer_start(ms or 0, false, fn)
end

--- Run `fn` every `ms` milliseconds. Returns a handle for `daw.cancel`.
function daw.every(ms, fn)
  return api.timer_start(ms, true, fn)
end

daw.cancel = api.timer_stop

--- Let `ms` milliseconds pass while timers fire and events are delivered, as
--- they do between key presses. A script run with `-l` is one long turn in
--- which neither happens unless it waits like this.
daw.wait = api.wait

daw.commands = require("daw.commands")
daw.command = setmetatable({ alias = daw.commands.alias }, {
  __call = function(_, ...) return daw.commands.define(...) end,
})
daw.cmd = daw.commands.run

daw.music = require("daw.music")
daw.params = require("daw.params")
daw.ui = require("daw.ui")
daw.draw = require("daw.draw")
daw.ui.keybar = require("daw.keybar")
daw.canvas = require("daw.canvas")
daw.notify = daw.ui.notify
daw.keymap = require("daw.keymap")

local objects = require("daw.objects")
daw.Track, daw.Device, daw.Clip, daw.Lane = objects.Track, objects.Device, objects.Clip, objects.Lane
daw.tracks, daw.track, daw.device, daw.clip = objects.tracks, objects.track, objects.device, objects.clip
daw.lane = objects.lane
daw.add_track = objects.add_track
daw.restore_track, daw.restore_clip, daw.restore_device = objects.restore_track, objects.restore_clip, objects.restore_device
daw.master, daw.project, daw.transport, daw.time = objects.master, objects.project, objects.transport, objects.time
daw.midi = objects.midi
daw.tempo = require("daw.tempo")
daw.audio = require("daw.audio")

--- Descriptions of every kind of device that can be added to a track.
daw.device_types = api.device_types

--- Render the project to a file, and render stems: see `daw/render.lua`
--- for the options. `daw.render_status()` and `daw.render_cancel()` look
--- after a render running in the background; `daw.render_ranges` holds the
--- named ranges a render can take.
function daw.render(path, opts) return require("daw.render").render(path, opts) end
function daw.render_stems(dir, opts) return require("daw.render").stems(dir, opts) end
function daw.render_status() return require("daw.render").status() end
function daw.render_cancel() return require("daw.render").cancel() end
daw.render_ranges = setmetatable({}, {
  __index = function(_, k) return require("daw.render").ranges[k] end,
  __newindex = function(_, k, v) require("daw.render").ranges[k] = v end,
})

--- Render a track with its devices to audio, as one clip on a new track
--- right below it that feeds where it fed, and mute the original. Goes
--- through `daw.render`, so `render.before` is heard. `opts.name` names the
--- new track ("<name> (bounced)" by default), `opts.tail` is the seconds
--- rendered after its last clip (2). Returns the new track, or nil when the
--- track has no clips.
function daw.bounce(track, opts)
  opts = opts or {}
  track = type(track) == "table" and track or daw.track(track)
  local finish = 0
  for _, clip in ipairs(track:clips()) do finish = math.max(finish, clip.start + clip.length) end
  if finish <= 0 then return nil end
  local dir = api.media_dir()
  os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "'")
  local path = string.format("%s/%s-bounce-%d-%d.wav", dir, track.name:gsub("[^%w%-_]", "_"), os.time(), track.id)
  daw.render(path, { tracks = { track.id }, start = 0, ["end"] = finish, tail = opts.tail or 2, bits = 32 })
  local index = 0
  for i, id in ipairs(api.track_list()) do
    if id == track.id then index = i end
  end
  local bounced = daw.add_track({ name = opts.name or (track.name .. " (bounced)"), index = index + 1, output = track.output })
  bounced:add_clip({ file = path, start = 0, name = track.name })
  track.mute = true
  return bounced
end

daw.undo, daw.redo = api.undo, api.redo
daw.cursor = require("daw.cursor")
daw.edit = require("daw.edit")
daw.ext = require("daw.ext")
daw.groups = require("daw.groups")
daw.lanes = require("daw.lanes")
daw.frontend = require("daw.frontend")
daw.pick = require("daw.pick")
daw.fx = require("daw.fx")
daw.takes = require("daw.takes")

-- JSON, for what extensions keep in files: `daw.json.encode(value, pretty)`
-- gives text, `daw.json.decode(text)` the value, or nil and the reason.
daw.json = { encode = api.json_encode, decode = api.json_decode }

-- Values kept by the kernel, so they survive `:reload`.
daw.state = setmetatable({}, {
  __index = function(_, key) return api.state_get(key) end,
  __newindex = function(_, key, value) api.state_set(key, value) end,
})

-- Entry points the kernel calls. Not part of the scripting interface.
local K = {}
daw._kernel = K

function K.startup()
  daw.ui.theme(require("daw.theme").groups)
  for _, name in ipairs({ "arrange", "status", "cmdline", "mixer", "devices", "pianoroll", "help", "effect_windows" }) do
    require("daw.views." .. name)
  end
  require("daw.defaults")
  daw.fx.setup()
  daw.media = require("daw.media")
  require("daw.render")
  daw.markers = require("daw.markers")
  daw.learn = require("daw.learn")
  daw.autosave = require("daw.autosave")
  daw.loading = require("daw.loading")
  daw.reconnect = require("daw.reconnect")
  daw.ui.start_ticker()

  local env = api.env()
  if not env.clean then
    daw.ext.load_dir(env.config_dir .. "/extensions")
    local init = env.config_dir .. "/init.lua"
    local file = io.open(init, "r")
    if file then
      file:close()
      local chunk, err = loadfile(init)
      if chunk then daw.try(daw.limit.untrusted(chunk)) else daw.notify(err, "error") end
    end
  end
  for _, warning in ipairs(api.warnings()) do daw.notify(warning, "warn") end
  daw.emit("startup", {})
end

--- The program is about to end.
function K.exit()
  daw.emit("exit", {})
end

function K.key(key)
  -- The keys of a finished command (`dd`, `3>ic`) label the undo step it makes.
  -- Keys typed into a prompt are text, not commands.
  local typed = not daw.ui.grabber and daw.keymap.pending() .. key
  daw.limit.guard("the key " .. key, daw.keymap.dispatch, key)
  if typed and daw.keymap.pending() == "" then api.undo_keys(typed) end
end

function K.paste(text)
  if daw.ui.grabber then daw.limit.guard("pasting", daw.ui.grabber, text, true) end
end

function K.mouse(event)
  daw.limit.guard("the mouse", daw.ui.mouse, event)
end

function K.resize(width, height)
  daw.emit("ui.resized", { width = width, height = height })
end

--- Deliver the change events for edits made so far. The kernel does this at
--- the end of every turn; call `daw.flush()` to have handlers run sooner.
local function settle()
  -- Handlers may edit the project and cause more events, so go round until
  -- it is quiet, with a limit in case two handlers keep triggering each other.
  for _ = 1, 64 do
    local events = api.events_take()
    if #events == 0 then return end
    for _, event in ipairs(events) do
      if event.name == "changed" then
        for _, warning in ipairs(api.warnings()) do daw.notify(warning, "warn") end
        api.ui_redraw()
      elseif event.name == "transport.record" then
        -- What starting a take has to say (a punch range already passed).
        for _, warning in ipairs(api.warnings()) do daw.notify(warning, "warn") end
      end
      daw.emit(event.name, event.payload)
    end
  end
  daw.notify("event handlers keep triggering each other; stopped delivering events for this turn", "error")
end

daw.flush = settle

--- The kernel's own call at the end of a turn: with the time limit on the
--- handlers it runs.
function K.settle()
  daw.limit.guard("an event handler", settle)
end

function K.timer(fn)
  daw.limit.guard("a timer", fn)
end

function K.render(width, height)
  daw.limit.guard("drawing the screen", daw.ui.render, daw.ui.Buf.root(width, height))
end

--- Calls from the control socket: `eval`, `cmd`, `keys`, or any `daw.api` function.
function K.rpc(method, params)
  params = params or {}
  if method == "eval" then
    local code = params[1]
    local chunk = loadstring("return " .. code, "=rpc") or assert(loadstring(code, "=rpc"))
    return chunk(unpack(params, 2))
  elseif method == "cmd" then
    return daw.commands.exec(table.concat(params, " "))
  elseif method == "keys" then
    return daw.keymap.feed(params[1])
  elseif method == "render" then
    -- Through `daw.render`, so that what listens for `render.before` hears of it.
    return daw.render(unpack(params))
  elseif api[method] then
    return api[method](unpack(params))
  end
  error("no method `" .. tostring(method) .. "`")
end

-- With a screen attached, stdout belongs to the terminal UI.
local raw_print = print
function print(...)
  if not api.ui_attached() then return raw_print(...) end
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  daw.notify(table.concat(parts, "  "))
end

return daw
