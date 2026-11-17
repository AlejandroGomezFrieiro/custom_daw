-- Writing paw's project as a REAPER project.
--
--   local result = require("rpp.export").file("song.rpp")
--   print(result.report:text())     -- what could not be written, grouped
--
-- The file is laid out the way REAPER 7 writes its own: the same lines in the
-- same order, with REAPER's defaults for the settings paw does not have.
-- Beats become seconds by the project's tempo map, which is written as
-- REAPER's tempo envelope (TEMPOENVEX) when it has more than one point.
local api = paw.api
local fmt = require("rpp.format")
local midi = require("rpp.midi")
local fx = require("rpp.fx")
local reports = require("rpp.report")

local M = {}

M.PPQ = 960

local function amp(db)
  if db <= -120 then return 0 end
  return 10 ^ (db / 20)
end

-- GUIDs ------------------------------------------------------------------------------

local function guid_maker(seed)
  local state = seed % 2147483647
  if state <= 0 then state = state + 2147483646 end
  local function hex(n)
    local out = {}
    for i = 1, n do
      state = (state * 16807) % 2147483647
      out[i] = string.format("%X", state % 16)
    end
    return table.concat(out)
  end
  return function()
    return "{" .. hex(8) .. "-" .. hex(4) .. "-" .. hex(4) .. "-" .. hex(4) .. "-" .. hex(12) .. "}"
  end
end

-- Pieces -----------------------------------------------------------------------------

local function relative(path, dir)
  if dir and path:sub(1, #dir + 1) == dir .. "/" then return path:sub(#dir + 2) end
  return path
end

local SOURCE_TYPES = { wav = "WAVE", wave = "WAVE", aif = "WAVE", aiff = "WAVE", flac = "FLAC", mp3 = "MP3", ogg = "VORBIS" }

local function envelope(name, lane, ctx)
  local env = fmt.block(name)
  env:add(fmt.line("EGUID", ctx.guid()))
  env:add(fmt.line("ACT", lane.enabled and 1 or 0, -1))
  env:add(fmt.line("VIS", 1, 1, 1))
  env:add(fmt.line("LANEHEIGHT", 0, 0))
  env:add(fmt.line("ARM", 0))
  env:add(fmt.line("DEFSHAPE", 0, -1, -1))
  -- Points are amplitudes whatever the scaling; REAPER 7 marks volume
  -- envelopes with fader scaling, which only changes how they are drawn.
  if name:match("VOLENV") then env:add(fmt.line("VOLTYPE", 1)) end
  local points = api.lane_points(lane.id)
  for _, p in ipairs(points) do
    local value
    if lane.target == "volume" then
      value = amp(p[2])
    else
      value = -p[2] -- REAPER's pan envelopes run from +1 (left) to -1 (right)
    end
    env:add(fmt.line("PT", string.format("%.12f", ctx.sec(p[1])), value, 0))
  end
  return env
end

local function fx_chain(name, track, t, ctx, label)
  local chain = fmt.block(name)
  chain:add(fmt.line("SHOW", 0))
  chain:add(fmt.line("LASTSEL", 0))
  chain:add(fmt.line("DOCKED", 0))
  local count = 0
  local types = {}
  for _, info in ipairs(api.device_types()) do types[info.kind] = info end
  local function add(block, bypass)
    chain:add(fmt.line("BYPASS", bypass and 1 or 0, 0, 0))
    chain:add(block)
    chain:add(fmt.line("FLOATPOS", 0, 0, 0, 0))
    chain:add(fmt.line("FXID", ctx.guid()))
    chain:add(fmt.line("WAK", 0, 0))
    count = count + 1
  end
  -- Plugins kept from an imported REAPER project go back as they were, at
  -- their places in the chain.
  local entries = {}
  for _, device in ipairs(t.devices) do entries[#entries + 1] = { device = device } end
  local holders = {}
  for _, holder in ipairs((t.meta or {}).rpp_placeholders or {}) do
    if holder.rpp then holders[#holders + 1] = holder end
  end
  table.sort(holders, function(x, y) return (x.position or 0) < (y.position or 0) end)
  for _, holder in ipairs(holders) do
    table.insert(entries, math.max(1, math.min(holder.position or #entries + 1, #entries + 1)), { holder = holder })
  end
  for _, entry in ipairs(entries) do
    if entry.holder then
      local block = fmt.parse(entry.holder.rpp).children[1]
      if block and block.children then add(block, entry.holder.bypass) end
    else
      local device = entry.device
      local d = api.device_get(device)
      local info = types[d.kind]
      if info and info.format ~= "builtin" then
        local ok, block, why = pcall(fx.export, device, info)
        if ok and block then
          add(block, d.bypass)
          if why then ctx.report:count("Plugin settings", why) end
        else
          ctx.report:add("Plugins not written", label .. ": " .. d.kind .. " (" .. tostring(ok and why or block) .. ")")
        end
      else
        ctx.report:add("Built-in devices (no REAPER equivalent)", label .. ": " .. d.kind)
      end
    end
  end
  return count > 0 and chain or nil
end

local function item_common(item, clip, ctx)
  item:add(fmt.line("POSITION", ctx.sec(clip.start)))
  item:add(fmt.line("SNAPOFFS", 0))
  item:add(fmt.line("LENGTH", ctx.sec(clip.start + clip.length) - ctx.sec(clip.start)))
  item:add(fmt.line("LOOP", 0))
  item:add(fmt.line("ALLTAKES", 0))
  item:add(fmt.line("FADEIN", 1, 0, 0, 1, 0, 0, 0))
  item:add(fmt.line("FADEOUT", 1, 0, 0, 1, 0, 0, 0))
  item:add(fmt.line("MUTE", clip.muted and 1 or 0, 0))
  item:add(fmt.line("SEL", 0))
  item:add(fmt.line("IGUID", ctx.guid()))
  ctx.iid = ctx.iid + 1
  item:add(fmt.line("IID", ctx.iid))
  item:add(fmt.line("NAME", clip.name or "")):quoted(1)
end

local function audio_item(clip, ctx)
  local item = fmt.block("ITEM")
  item_common(item, clip, ctx)
  item:add(fmt.line("VOLPAN", 1, 0, amp(clip.gain or 0), -1))
  item:add(fmt.line("SOFFS", clip.offset or 0))
  item:add(fmt.line("PLAYRATE", 1, 1, 0, -1, 0, 0.0025))
  item:add(fmt.line("CHANMODE", 0))
  item:add(fmt.line("GUID", ctx.guid()))
  local ext = (clip.file:match("%.(%w+)$") or ""):lower()
  local source = item:add(fmt.block("SOURCE", SOURCE_TYPES[ext] or "WAVE"))
  source:add(fmt.line("FILE", relative(clip.file, ctx.dir))):quoted(1)
  if not SOURCE_TYPES[ext] then ctx.report:add("Media REAPER may not read", clip.file) end
  return item
end

local function midi_item(clip, ctx, label)
  local item = fmt.block("ITEM")
  item_common(item, clip, ctx)
  item:add(fmt.line("VOLPAN", 1, 0, 1, -1))
  item:add(fmt.line("SOFFS", 0))
  item:add(fmt.line("PLAYRATE", 1, 1, 0, -1, 0, 0.0025))
  item:add(fmt.line("CHANMODE", 0))
  item:add(fmt.line("GUID", ctx.guid()))
  local source = item:add(fmt.block("SOURCE", "MIDI"))
  source:add(fmt.line("HASDATA", 1, M.PPQ, "QN"))
  source:add(fmt.line("CCINTERP", 32))
  source:add(fmt.line("POOLEDEVTS", ctx.guid()))
  local notes, rounded, attrs = {}, 0, 0
  local shown = {}
  -- Notes before the clip's start are hidden by a trim, and not played.
  for _, n in ipairs(api.clip_notes(clip.id)) do
    if n.start >= 0 then shown[#shown + 1] = n end
  end
  for _, n in ipairs(shown) do
    local tick = math.floor(n.start * M.PPQ + 0.5)
    local stop = math.floor((n.start + n.length) * M.PPQ + 0.5)
    if math.abs(tick - n.start * M.PPQ) > 1e-6 or math.abs(stop - (n.start + n.length) * M.PPQ) > 1e-6 then
      rounded = rounded + 1
    end
    if n.attr then attrs = attrs + 1 end
    local channel = n.meta and tonumber(n.meta.channel)
    notes[#notes + 1] = {
      tick = tick, length = math.max(1, stop - tick), pitch = n.pitch, velocity = n.velocity,
      channel = channel and math.max(0, math.min(15, channel - 1)) or 0,
    }
  end
  if rounded > 0 then ctx.report:count("Note times rounded to 1/960 beat", label, rounded) end
  -- A REAPER project keeps MIDI 1.0, where a note has no attribute.
  if attrs > 0 then ctx.report:count("Note attributes (MIDI 2.0 articulations)", label, attrs) end
  local length = math.floor(clip.length * M.PPQ + 0.5)
  for _, line in ipairs(midi.event_lines(notes, length)) do source:add(line) end
  source:add(fmt.line("CCINTERP", 32))
  source:add(fmt.line("GUID", ctx.guid()))
  source:add(fmt.line("IGNTEMPO", 0, 120, 4, 4))
  return item
end

-- Tracks and folders -----------------------------------------------------------------

--- Folder depth changes for REAPER (`ISBUS`), and which tracks' outputs a
--- folder cannot express (they become sends from a track whose parent send
--- is off). A track is in a folder when it follows its output track
--- directly, or follows a sibling in that folder.
local function layout(list)
  local index = {}
  for i, t in ipairs(list) do index[t.id] = i end
  local depth, stack, unfoldered = {}, {}, {}
  for i, t in ipairs(list) do
    depth[i] = 0
    local parent = t.output
    local inside = false
    for _, open in ipairs(stack) do
      if open == parent then inside = true end
    end
    if parent and not inside then unfoldered[t.id] = true end
    -- Close folders until the innermost open one is the parent (or none is).
    local pops = 0
    while #stack > 0 and stack[#stack] ~= (inside and parent or nil) do
      stack[#stack] = nil
      pops = pops + 1
    end
    if pops > 0 then depth[i - 1] = depth[i - 1] - pops end
    local nxt = list[i + 1]
    if nxt and nxt.output == t.id then
      depth[i] = 1
      stack[#stack + 1] = t.id
    end
  end
  if #list > 0 then depth[#list] = depth[#list] - #stack end
  return depth, unfoldered, index
end

local function track_block(t, i, ctx, depth, unfoldered, index, receives)
  local guid = ctx.guid()
  local block = fmt.block("TRACK", guid)
  block:add(fmt.line("NAME", t.name or "")):quoted(1)
  block:add(fmt.line("PEAKCOL", 16576))
  block:add(fmt.line("BEAT", -1))
  block:add(fmt.line("AUTOMODE", 0))
  block:add(fmt.line("VOLPAN", amp(t.volume or 0), t.pan or 0, -1, -1, 1))
  block:add(fmt.line("MUTESOLO", t.mute and 1 or 0, t.solo and 2 or 0, 0))
  block:add(fmt.line("IPHASE", 0))
  block:add(fmt.line("PLAYOFFS", 0, 1))
  local d = depth[i] or 0
  block:add(fmt.line("ISBUS", d > 0 and 1 or (d < 0 and 2 or 0), d))
  block:add(fmt.line("BUSCOMP", 0, 0, 0, 0, 0))
  block:add(fmt.line("SHOWINMIX", 1, 0.6667, 0.5, 1, 0.5, 0, 0, 0, 0))
  block:add(fmt.line("SEL", 0))
  local input, monitor = -1, 0
  if t.input then
    local a, b = t.input:match("^(%d+)/(%d+)$")
    if a then input = 1024 + tonumber(a) - 1 else input = (tonumber(t.input) or 1) - 1 end
  end
  if t.monitor then monitor = 1 end
  block:add(fmt.line("REC", t.armed and 1 or 0, input, monitor, 0, 0, 0, 0, 0))
  block:add(fmt.line("VU", 2))
  block:add(fmt.line("TRACKHEIGHT", 0, 0, 0, 0, 0, 0, 0))
  block:add(fmt.line("INQ", 0, 0, 0, 0.5, 100, 0, 0, 100))
  block:add(fmt.line("NCHAN", 2))
  block:add(fmt.line("FX", 1))
  block:add(fmt.line("TRACKID", guid))
  block:add(fmt.line("PERF", 0))
  block:add(fmt.line("MIDIOUT", -1))
  block:add(fmt.line("MAINSEND", unfoldered[t.id] and 0 or 1, 0))
  for _, r in ipairs(receives[t.id] or {}) do
    block:add(fmt.line("AUXRECV", index[r.from] - 1, 0, amp(r.level), 0, 0, 0, 0, 0, 0, "-1:U", 0, -1, "")):quoted(13)
  end
  return block
end

--- REAPER's tempo envelope for a map with more than one point, or nil: a
--- point per tempo change (shape 0 ramps, 1 holds) and per signature
--- change, the signature packed as num + den * 65536.
function M.tempo_envelope(ctx)
  local map = api.tempo_points()
  if #map.tempos == 1 and #map.signatures == 1 then return nil end
  local points = {}
  local function at(beat)
    for _, p in ipairs(points) do
      if math.abs(p.beat - beat) < 1e-9 then return p end
    end
    local p = { beat = beat }
    points[#points + 1] = p
    return p
  end
  for _, t in ipairs(map.tempos) do
    local p = at(t.beat)
    p.bpm, p.ramp = t.bpm, t.ramp
  end
  for _, s in ipairs(map.signatures) do
    local p = at(s.beat)
    p.sig = s.num + s.den * 65536
  end
  table.sort(points, function(a, b) return a.beat < b.beat end)
  local env = fmt.block("TEMPOENVEX")
  env:add(fmt.line("EGUID", ctx.guid()))
  env:add(fmt.line("ACT", 0, -1))
  env:add(fmt.line("VIS", 1, 0, 1))
  env:add(fmt.line("LANEHEIGHT", 0, 0))
  env:add(fmt.line("ARM", 0))
  env:add(fmt.line("DEFSHAPE", 1, -1, -1))
  local ramp = false
  for _, p in ipairs(points) do
    -- A signature change inside a ramp keeps the ramp going through it.
    if p.bpm == nil then p.bpm, p.ramp = api.tempo_at(p.beat), ramp end
    ramp = p.ramp
    local t = string.format("%.12f", api.tempo_seconds(p.beat))
    if p.sig then
      env:add(fmt.line("PT", t, p.bpm, p.ramp and 0 or 1, p.sig, 0, 1))
    else
      env:add(fmt.line("PT", t, p.bpm, p.ramp and 0 or 1))
    end
  end
  return env
end

--- Build the document for the current project. `opts.dir` is the folder
--- the file will be in (media under it are written relative to it).
function M.doc(opts)
  opts = opts or {}
  local p = api.project_get()
  local tr = api.transport_get()
  local ctx = {
    tempo = p.tempo, sec = api.tempo_seconds, dir = opts.dir, iid = 0,
    guid = guid_maker(opts.seed or (os.time() + math.floor(api.now()))),
    report = reports.new("Not written to " .. (opts.name or "the REAPER project") .. ":"),
  }
  local doc = fmt.document("\r\n")
  local root = doc:add(fmt.block("REAPER_PROJECT", 0.1, "7.0/paw-rpp", opts.timestamp or os.time(), 0)):quoted(2)
  local function line(...) return root:add(fmt.line(...)) end
  line("RIPPLE", 0, 0)
  line("GROUPOVERRIDE", 0, 0, 0, 0)
  line("AUTOXFADE", 129)
  line("ENVATTACH", 3)
  line("POOLEDENVATTACH", 0)
  line("PANLAW", 1)
  line("PROJOFFS", 0, 0, 0)
  line("MAXPROJLEN", 0, 0)
  line("GRID", 3199, 8, 1, 8, 1, 0, 0, 0)
  line("TIMEMODE", 1, 5, -1, 30, 0, 0, -1, 0)
  line("PANMODE", 3)
  line("CURSOR", 0)
  line("ZOOM", 100, 0, 0)
  local looped = tr.loop_end and tr.loop_start and tr.loop_end > tr.loop_start
  line("LOOP", (tr.loop_enabled and looped) and 1 or 0)
  line("LOOPGRAN", 0, 4)
  line("RECORD_PATH", "Media", ""):quoted(1)
  line("TIMELOCKMODE", 1)
  line("TEMPOENVLOCKMODE", 1)
  line("ITEMMIX", 1)
  line("DEFPITCHMODE", 589824, 0)
  line("TAKELANE", 1)
  line("SAMPLERATE", 44100, 0, 0)
  line("LOCK", 1)
  line("GLOBAL_AUTO", -1)
  line("TEMPO", p.tempo, p.sig_num, p.sig_den, 0)
  line("PLAYRATE", 1, 0, 0.25, 4)
  local a, b = 0, 0
  if looped then a, b = ctx.sec(tr.loop_start), ctx.sec(tr.loop_end) end
  line("SELECTION", a, b)
  line("SELECTION2", a, b)
  line("MASTERAUTOMODE", 0)
  line("MASTERTRACKHEIGHT", 0, 0)
  line("MASTERPEAKCOL", 16576)
  local master = api.track_get(0)
  line("MASTERMUTESOLO", master.mute and 1 or 0)
  line("MASTERHWOUT", 0, 0, 1, 0, 0, 0, 0, -1)
  line("MASTER_NCH", 2, 2)
  line("MASTER_VOLUME", amp(master.volume or 0), master.pan or 0, -1, -1, 1)
  line("MASTER_PANMODE", 3)
  line("MASTER_FX", 1)
  line("MASTER_SEL", 0)
  local master_chain = fx_chain("MASTERFXLIST", 0, master, ctx, "Master")
  if master_chain then root:add(master_chain) end
  for _, lane in ipairs(api.lane_list(0)) do
    if lane.target == "volume" or lane.target == "pan" then
      root:add(envelope(lane.target == "volume" and "MASTERVOLENV2" or "MASTERPANENV2", lane, ctx))
    else
      ctx.report:add("Plugin parameter automation", "Master: " .. tostring(lane.param))
    end
  end
  -- Markers and regions kept in the project's meta (from an import, or
  -- another extension), in beats.
  local meta = p.meta or {}
  local n = 0
  for _, m in ipairs(meta.markers or {}) do
    n = n + 1
    line("MARKER", tonumber(m.id) or n, ctx.sec(m.beat or 0), m.name or "", 0, m.color or 0, 1, "B", ctx.guid(), 0):quoted(3)
  end
  for _, r in ipairs(meta.regions or {}) do
    n = n + 1
    local id = tonumber(r.id) or n
    local guid = ctx.guid()
    line("MARKER", id, ctx.sec(r.start or 0), r.name or "", 1, r.color or 0, 1, "B", ctx.guid(), 0):quoted(3)
    line("MARKER", id, ctx.sec((r.start or 0) + (r.length or 0)), "", 1):quoted(3)
  end
  -- Song sections (`project.meta.sections`, as the sections extension
  -- keeps them) become regions, each up to where the next starts.
  local ok, sections = pcall(require, "sections")
  local parts = ok and sections.list() or {}
  for _, s in ipairs(parts) do
    n = n + 1
    line("MARKER", n, ctx.sec(s.start), s.name, 1, 0, 1, "B", ctx.guid(), 0):quoted(3)
    line("MARKER", n, ctx.sec(s.finish), "", 1):quoted(3)
  end
  if #parts > 0 then ctx.report:count("Sections written as regions (they come back as regions)", "sections", #parts) end
  local tempo_env = M.tempo_envelope(ctx)
  if tempo_env then root:add(tempo_env) end
  root:add(fmt.block("PROJBAY"))

  -- Tracks.
  local list = {}
  for i, id in ipairs(api.track_list()) do list[i] = api.track_get(id) end
  local depth, unfoldered, index = layout(list)
  local receives = {}
  for _, t in ipairs(list) do
    if unfoldered[t.id] then
      receives[t.output] = receives[t.output] or {}
      table.insert(receives[t.output], { from = t.id, level = 0 })
      ctx.report:add("Routing written as a send (REAPER folders need the child right after its parent)",
        t.name .. " -> " .. api.track_get(t.output).name)
    end
    for _, s in ipairs(t.sends or {}) do
      receives[s.target] = receives[s.target] or {}
      table.insert(receives[s.target], { from = t.id, level = s.level })
    end
  end
  for i, t in ipairs(list) do
    local block = root:add(track_block(t, i, ctx, depth, unfoldered, index, receives))
    for _, lane in ipairs(api.lane_list(t.id)) do
      if lane.target == "volume" or lane.target == "pan" then
        block:add(envelope(lane.target == "volume" and "VOLENV2" or "PANENV2", lane, ctx))
      else
        ctx.report:add("Plugin parameter automation", t.name .. ": " .. tostring(lane.param))
      end
    end
    local chain = fx_chain("FXCHAIN", t.id, t, ctx, t.name)
    if chain then block:add(chain) end
    for _, clip in ipairs(api.clip_list(t.id)) do
      local label = t.name .. ": " .. (clip.name or "clip")
      if clip.kind == "audio" then
        block:add(audio_item(clip, ctx))
      else
        block:add(midi_item(clip, ctx, label))
      end
    end
    if t.color then ctx.report:count("Track colours", t.name) end
  end
  return doc, ctx.report
end

--- Write the current project to a file.
function M.file(path, opts)
  opts = opts or {}
  opts.dir = opts.dir or (path:match("^(.*)/[^/]*$") or ".")
  opts.name = path:match("([^/]+)$") or path
  if opts.dir:sub(1, 1) ~= "/" then
    local pwd = os.getenv("PWD")
    if pwd then opts.dir = pwd .. (opts.dir == "." and "" or "/" .. opts.dir) end
  end
  local doc, report = M.doc(opts)
  fmt.save(doc, path)
  return { report = report, doc = doc }
end

return M
