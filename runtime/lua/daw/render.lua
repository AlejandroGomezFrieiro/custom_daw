-- Rendering: `daw.render`, stems, the `:render` command, and the render
-- that runs in the background with its progress and cancelling. The work is
-- in the kernel (crates/daw-core/src/session/render.rs).
local api = daw.api
local M = {}

--- Named ranges a render can take besides beats: each a function giving
--- `start, end` in beats, or nil and why not. Extensions may add their own
--- (`daw.render_ranges.chorus = function() return 32, 48 end`).
M.ranges = {
  song = function() return 0, nil end,
  loop = function()
    local t = api.transport_get()
    if not (t.loop_end > t.loop_start) then return nil, "there is no loop" end
    return t.loop_start, t.loop_end
  end,
  selection = function()
    local sel = daw.keymap.selection()
    if not (sel and sel.c0 and sel.c1 and sel.c1 > sel.c0) then return nil, "nothing is selected: select a stretch of time first" end
    return sel.c0, sel.c1
  end,
}

--- The options as the kernel takes them: `range` turned into `start` and
--- `end`, and what only Lua knows taken out.
local function kernel_opts(opts)
  local out = {}
  for k, v in pairs(opts or {}) do out[k] = v end
  local range = out.range
  out.range, out.background, out.format = nil, nil, nil
  if out.channels == "mono" then out.channels = 1 elseif out.channels == "stereo" then out.channels = 2 end
  if out.rate then out.sample_rate, out.rate = out.rate, nil end
  if range and range ~= "song" then
    local resolve = M.ranges[range]
    if not resolve then
      local names = {}
      for name in pairs(M.ranges) do names[#names + 1] = name end
      table.sort(names)
      error(string.format("no range `%s`: use %s, or start= and end= in beats", tostring(range), table.concat(names, ", ")), 0)
    end
    local start, finish = resolve()
    if not start then error(finish, 0) end
    out.start, out["end"] = start, finish
  end
  return out
end

local function check(path)
  local why = api.render_check(path)
  if why then error(why, 0) end
end

-- Renders waiting for the one running: stems are rendered one at a time.
local queue = {}

local function start(path, opts)
  daw.emit("render.before", { path = path, opts = opts })
  api.render_start(path, opts)
  daw.ui.poke()
end

--- Render the project to a file: WAV or FLAC, by the file's extension.
--- `opts` (all optional):
---   range       "song" (the default), "loop", "selection", or a name in `daw.render_ranges`
---   start, end  beats, instead of a range (`end` defaults to the end of the last clip)
---   tail        seconds after the end, for reverbs and delays to ring out (1)
---   sample_rate (or rate) Hz; the engine's by default
---   bits        16, 24 or 32 (float; WAV only); 24 by default
---   channels    2 (or "stereo") or 1 (or "mono")
---   dither      true to add dither when writing 16 or 24 bits
---   normalize   bring the loudest sample to this level in dB, such as -1
---   loudness    bring the integrated loudness to this level in LUFS, such as -14;
---               with `normalize` too, the peak level is a ceiling
---   tracks      { id, ... }: only these, with what they pass through (a stem)
---   master      false to leave out the master track's devices, fader and pan
---   threads     threads to render on
---   background  true to return at once and render on a thread of its own:
---               `render.progress` ({ path, fraction, seconds }) follows now
---               and then, and `render.done` (what is returned below),
---               `render.failed` ({ path, error }) or `render.cancelled` at the end
--- Returns { path, frames, seconds, sample_rate, peak, gain, loudness, format,
--- bits, channels, ... } when done. `render.before` is emitted first, and its
--- handlers run before rendering starts, so an extension that makes audio of
--- its own can finish it. A file that cannot be written is refused before
--- anything is rendered; nothing is left under the name asked for when a
--- render fails or is cancelled.
function M.render(path, opts)
  check(path)
  local background = opts and opts.background
  opts = kernel_opts(opts)
  if background then
    if api.render_status() then
      queue[#queue + 1] = { path = path, opts = opts }
    else
      start(path, opts)
    end
    return nil
  end
  daw.emit("render.before", { path = path, opts = opts })
  local info = api.render(path, opts)
  -- What the render had to leave out (a plugin that stopped answering).
  for _, why in ipairs(info.left_out or {}) do daw.notify(why, "warn") end
  return info
end

--- The render running in the background: { path, fraction, seconds,
--- cancelling, queued }, or nil.
function M.status()
  local s = api.render_status()
  if s then s.queued = #queue end
  return s
end

--- Stop the background render, and those waiting after it. Its file is not
--- written. Returns whether one was running.
function M.cancel()
  queue = {}
  return api.render_cancel()
end

--- Render each track on its own into a directory, one file per track named
--- after it: stems. A track is rendered with what it passes through on the
--- way to the master, as when it is soloed, so that the stems add up to the
--- mix. `opts` is as for `daw.render`, plus `tracks` to choose which (all
--- that are not muted, by default) and `format` ("wav" or "flac"). With
--- `background`, they are rendered one after another. Returns the files.
function M.stems(dir, opts)
  opts = opts or {}
  local ext = opts.format or "wav"
  check(dir .. "/stem." .. ext)
  os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "'")
  local out, used = {}, {}
  local tracks = opts.tracks
  if not tracks then
    tracks = {}
    for _, track in ipairs(daw.tracks()) do
      if not track.mute and #track:clips() > 0 then tracks[#tracks + 1] = track.id end
    end
  end
  for _, id in ipairs(tracks) do
    id = type(id) == "table" and id.id or id
    local name = api.track_get(id).name:gsub("[^%w%-_ ]", "_")
    -- Two tracks of one name get a number each.
    used[name] = (used[name] or 0) + 1
    if used[name] > 1 then name = name .. " " .. used[name] end
    local path = string.format("%s/%s.%s", dir, name, ext)
    M.render(path, daw.util.merge(opts, { tracks = { id }, format = false }))
    out[#out + 1] = path
  end
  return out
end

local function next_in_queue()
  local nxt = table.remove(queue, 1)
  if nxt then
    local ok, err = pcall(start, nxt.path, nxt.opts)
    if not ok then
      daw.notify("could not render " .. nxt.path .. ": " .. tostring(err), "error")
      return next_in_queue()
    end
  end
end

local function name_of(path) return tostring(path):match("([^/]+)$") or tostring(path) end

daw.on("render.progress", function() api.ui_redraw() end)
daw.on("render.done", function(info)
  daw.notify(string.format("rendered %s: %.1f s, peak %.1f dB%s", name_of(info.path), info.seconds,
    20 * math.log10(math.max(info.peak, 1e-6)), info.loudness and string.format(", %.1f LUFS", info.loudness) or ""))
  for _, why in ipairs(info.left_out or {}) do daw.notify(why, "warn") end
  next_in_queue()
end)
daw.on("render.failed", function(e)
  daw.notify("render of " .. name_of(e.path) .. " failed: " .. tostring(e.error), "error")
  next_in_queue()
end)
daw.on("render.cancelled", function(e)
  queue = {}
  daw.notify("render of " .. name_of(e.path) .. " cancelled; no file written")
end)
-- `Esc` in normal mode, with nothing else to cancel, stops a render.
daw.on("escape", function()
  if api.render_status() then M.cancel() end
end)

-- The command ------------------------------------------------------------------

--- What `:render` takes, for its description and completion.
M.options = {
  { "range=", { "song", "loop", "selection" }, "what to render" },
  { "start=", nil, "beat to start at" },
  { "end=", nil, "beat to end at" },
  { "tail=", { "0", "1", "2", "4" }, "seconds after the end" },
  { "rate=", { "44100", "48000", "96000" }, "sample rate" },
  { "bits=", { "16", "24", "32" }, "sample size; 32 is float" },
  { "channels=", { "stereo", "mono" }, "" },
  { "dither=", { "true" }, "dither at 16 or 24 bits" },
  { "normalize=", { "-1", "-0.3" }, "peak level in dB" },
  { "loudness=", { "-14", "-16", "-23" }, "integrated loudness in LUFS" },
  { "tracks=", { "selected", "all" }, "a stem of these tracks (ids, comma-separated)" },
  { "stems=", { "true" }, "one file per track, into a directory" },
  { "master=", { "false" }, "leave out the master's devices and fader" },
  { "wait=", { "true" }, "render in the foreground" },
}

local function default_path()
  local p = api.project_get()
  local name = (p.name and p.name ~= "" and p.name or "render"):gsub("[^%w%-_ ]", "_")
  local dir = p.path and tostring(p.path):match("^(.*)/[^/]+$")
  return (dir and dir .. "/" or "") .. name .. ".wav"
end

M.default_path = default_path

local function track_list(spec)
  if spec == nil or spec == "all" then return nil end
  if spec == "selected" then
    local id = daw.cursor.track_id()
    if not id then error("no track is selected", 0) end
    return { id }
  end
  local ids = {}
  for n in tostring(spec):gmatch("[^,%s]+") do ids[#ids + 1] = tonumber(n) or error("not a track id: " .. n, 0) end
  return ids
end

daw.command("render", function(ctx)
  local a = ctx.args
  local opts = {
    range = a.range, start = tonumber(a.start), ["end"] = tonumber(a["end"]), tail = tonumber(a.tail),
    rate = tonumber(a.rate), bits = tonumber(a.bits), dither = a.dither == true or nil,
    channels = a.channels == "mono" and 1 or a.channels == "stereo" and 2 or tonumber(a.channels),
    normalize = tonumber(a.normalize), loudness = tonumber(a.loudness),
    master = a.master ~= false and nil or false, tracks = track_list(a.tracks),
    background = a.wait ~= true,
  }
  if opts.start or opts["end"] then opts.range = nil end
  if a.stems == true then
    local dir = a[1] and tostring(a[1]) or (default_path():gsub("%.wav$", "") .. " stems")
    local files = M.stems(dir, daw.util.merge(opts, { format = a.format }))
    return daw.notify(string.format("rendering %d stem%s into %s", #files, #files == 1 and "" or "s", dir))
  end
  local path = a[1] and tostring(a[1]) or default_path()
  local info = M.render(path, opts)
  if info then
    daw.notify(string.format("rendered %s: %.1f s, peak %.1f dB", name_of(path), info.seconds,
      20 * math.log10(math.max(info.peak, 1e-6))))
  else
    daw.notify("rendering " .. name_of(path) .. " · Esc cancels")
  end
end, {
  desc = "Render to WAV or FLAC by the file's extension: `render mix.flac range=loop tail=2 bits=16 dither=true "
    .. "channels=mono rate=44100 normalize=-1 loudness=-14 tracks=selected master=false stems=true`",
  complete = function(rest)
    local before, last = rest:match("^(.-)(%S*)$")
    local out = {}
    local key = last:match("^(%w+)=")
    for _, o in ipairs(M.options) do
      if key and o[1] == key .. "=" then
        for _, v in ipairs(o[2] or {}) do out[#out + 1] = before .. o[1] .. v end
      elseif not key then
        out[#out + 1] = before .. o[1]
      end
    end
    return out
  end,
})

daw.command("render.cancel", function()
  if not M.cancel() then daw.notify("nothing is being rendered") end
end, { desc = "Stop the render running in the background; it leaves no file" })

daw.command("stems", function(ctx)
  local dir = tostring(ctx.args[1] or "stems")
  local files = M.stems(dir, {
    tail = tonumber(ctx.args.tail), bits = tonumber(ctx.args.bits), format = ctx.args.format,
    master = ctx.args.master ~= false and nil or false, background = ctx.args.wait ~= true,
  })
  daw.notify(string.format("rendering %d stem%s into %s", #files, #files == 1 and "" or "s", dir))
end, { desc = "Render each track on its own into a directory: `stems out tail=2 bits=24 format=flac master=false`" })

return M
