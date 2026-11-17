-- The kernel side of paw-mcp. The server sends this chunk with every tool
-- call (`eval`, with the tool's name and its arguments as `...`), so it needs
-- nothing installed in the kernel and survives `:reload`.
--
-- Arguments arrive normalized by the server: positions and lengths in beats,
-- pitches as MIDI numbers, paths absolute and checked. Tracks may still be
-- named. Everything is done through `paw.api`, so every change is undoable,
-- and each tool call that writes is exactly one undo step: a failed call is
-- rolled back.
local api = paw.api
local T = {}

local function clean(e)
  local text = tostring(e)
  text = text:match("^(.-)\nstack traceback") or text
  text = text:gsub("^runtime error: ", ""):gsub("^%[string [^%]]*%]:%d+: ", ""):gsub("^rpc:%d+: ", "")
  return text
end

local function fail(msg) error(msg, 0) end

local function exists(get, id) return id ~= nil and (pcall(get, id)) end

-- Tracks, by id, by name, or "master" ------------------------------------------

local function track_id(ref)
  if ref == nil then fail("which track? give its id or its name") end
  if type(ref) == "number" then
    if not exists(api.track_get, ref) then fail("no track " .. ref .. " (get_project lists the tracks)") end
    return ref
  end
  local text = tostring(ref)
  if text:lower() == "master" then return 0 end
  if tonumber(text) then return track_id(tonumber(text)) end
  local wanted, partial = text:lower(), {}
  for _, id in ipairs(api.track_list()) do
    local name = api.track_get(id).name
    if name:lower() == wanted then return id end
    if name:lower():find(wanted, 1, true) then partial[#partial + 1] = { id = id, name = name } end
  end
  if #partial == 1 then return partial[1].id end
  if #partial > 1 then
    local names = {}
    for i, t in ipairs(partial) do names[i] = string.format("%q (id %d)", t.name, t.id) end
    fail("`" .. text .. "` matches several tracks: " .. table.concat(names, ", ") .. "; use an id")
  end
  fail("no track named `" .. text .. "` (get_project lists the tracks)")
end

local function need(get, id, what)
  if type(id) ~= "number" then fail(what .. " must be given by its numeric id") end
  if not exists(get, id) then fail("no " .. what .. " " .. id) end
  return id
end

-- Device kinds -----------------------------------------------------------------

local function matches(info, words)
  local hay = (info.kind .. " " .. info.name .. " " .. (info.vendor or "") .. " " .. (info.category or "") .. " " .. info.format):lower()
  for _, word in ipairs(words) do
    if not hay:find(word, 1, true) then return false end
  end
  return true
end

local function search(query, format)
  local words = {}
  for word in tostring(query or ""):lower():gmatch("%S+") do words[#words + 1] = word end
  local out = {}
  for _, info in ipairs(api.device_types()) do
    if (not format or info.format == format) and matches(info, words) then out[#out + 1] = info end
  end
  table.sort(out, function(a, b)
    if (a.format == "builtin") ~= (b.format == "builtin") then return a.format == "builtin" end
    return a.kind < b.kind
  end)
  return out
end

local function find_kind(text)
  for _, info in ipairs(api.device_types()) do
    if info.kind == text then return info.kind end
  end
  for _, info in ipairs(api.device_types()) do
    if info.name:lower() == text:lower() then return info.kind end
  end
  local found = search(text)
  if #found == 0 then fail("no device matches `" .. text .. "`; find_devices searches what can be added") end
  return found[1].kind
end

-- Views: plain data for the server to format ----------------------------------

local function param_list(d)
  local out = {}
  for i, p in ipairs(d.param_info) do
    out[i] = {
      key = p.key, name = p.name, value = d.params[p.key], min = p.min, max = p.max,
      default = p.default, unit = p.unit, choices = p.choices,
    }
  end
  return out
end

local function device_view(id, full)
  local d = api.device_get(id)
  local v = {
    id = d.id, kind = d.kind, name = d.name, format = d.format, bypass = d.bypass, index = d.index,
    track = d.track, missing = d.missing, param_count = #d.param_info,
  }
  if full then v.params = param_list(d) end
  return v
end

local function clip_view(c, notes)
  local v = {
    id = c.id, name = c.name, track = c.track, start = c.start, length = c.length, kind = c.kind,
    muted = c.muted, file = c.file, gain = c.gain, offset = c.offset, note_count = c.note_count,
  }
  if c.kind == "midi" then
    local list = api.clip_notes(c.id)
    for _, n in ipairs(list) do
      v.low = math.min(v.low or 127, n.pitch)
      v.high = math.max(v.high or 0, n.pitch)
    end
    if notes then
      v.notes = {}
      for i, n in ipairs(list) do
        v.notes[i] = { pitch = n.pitch, start = n.start, length = n.length, velocity = n.velocity, lyric = n.meta and n.meta.lyric }
      end
    end
  end
  return v
end

local function lane_view(lane, points)
  local v = {
    id = lane.id, target = lane.target, device = lane.device, param = lane.param, enabled = lane.enabled,
    min = lane.min, max = lane.max, point_count = lane.point_count,
  }
  if points then v.points = api.lane_points(lane.id) end
  return v
end

local function track_view(id, detail)
  local t = api.track_get(id)
  local v = {
    id = id, index = t.index, name = t.name, volume = t.volume, pan = t.pan, mute = t.mute, solo = t.solo,
    armed = t.armed, master = t.master, input = t.input, monitor = t.monitor, color = t.color,
    output = t.output, sends = {}, devices = {}, clips = {}, lanes = {},
  }
  if t.output then v.output_name = api.track_get(t.output).name end
  for i, s in ipairs(t.sends or {}) do
    v.sends[i] = { target = s.target, level = s.level, name = exists(api.track_get, s.target) and api.track_get(s.target).name or "?" }
  end
  for i, d in ipairs(t.devices) do v.devices[i] = device_view(d, detail) end
  for i, c in ipairs(api.clip_list(id)) do v.clips[i] = clip_view(c, false) end
  for i, l in ipairs(api.lane_list(id)) do v.lanes[i] = lane_view(l, detail) end
  return v
end

-- Whether there are edits since the project was last saved or opened. The
-- kernel's `modified` only says the project has history, so remember the
-- edit count at each save (ours, and others' once this has run).
local SAVED = "paw-mcp.saved_edits"
if not rawget(_G, "__paw_mcp_hooked") then
  rawset(_G, "__paw_mcp_hooked", true)
  paw.on("project.saved", function() paw.state[SAVED] = api.project_get().edits end)
  paw.on("project.loaded", function() paw.state[SAVED] = api.project_get().edits end)
end
local function unsaved(p)
  return p.modified and paw.state[SAVED] ~= p.edits
end

local function project_view()
  local p, t = api.project_get(), api.transport_get()
  local v = {
    name = p.name, path = p.path, modified = unsaved(p), tempo = p.tempo, sig_num = p.sig_num,
    sig_den = p.sig_den, length = p.length, transport = t, tracks = {},
    tempo_ramp = p.tempo_ramp, tempo_changes = p.tempo_changes, sig_changes = p.sig_changes,
  }
  for i, id in ipairs(api.track_list()) do v.tracks[i] = track_view(id, false) end
  v.master = track_view(0, false)
  return v
end

-- Writes -----------------------------------------------------------------------

local function set_params(id, params)
  if not params then return end
  local d = api.device_get(id)
  for key, value in pairs(params) do
    local info
    for _, p in ipairs(d.param_info) do
      if p.key == key or p.name:lower() == tostring(key):lower() then info = p end
    end
    if not info then
      local keys = {}
      for i, p in ipairs(d.param_info) do if i <= 40 then keys[i] = p.key end end
      fail(string.format("%s has no parameter `%s`; it has: %s%s", d.name, key, table.concat(keys, ", "), #d.param_info > 40 and ", ..." or ""))
    end
    if type(value) == "string" then
      local index
      for i, choice in ipairs(info.choices or {}) do
        if choice:lower() == value:lower() then index = i - 1 end
      end
      value = index or tonumber(value) or fail(string.format("`%s` is not a value of %s (%s)", value, info.key,
        #(info.choices or {}) > 0 and "one of: " .. table.concat(info.choices, ", ") or "a number"))
    end
    if type(value) ~= "number" then fail("parameter values are numbers (or a choice's name)") end
    api.device_set_param(id, info.key, value)
  end
end

local function add_device(track, spec)
  if type(spec) == "string" then spec = { kind = spec } end
  local kind = find_kind(spec.kind or fail("a device needs a `kind`"))
  local id = api.device_add(track, kind, { index = spec.index })
  set_params(id, spec.params)
  if spec.bypass ~= nil then api.device_set(id, "bypass", spec.bypass) end
  return id
end

local function add_clip(track, spec)
  local opts = { name = spec.name, start = spec.start or 0, length = spec.length, notes = spec.notes }
  if spec.file then
    opts.kind, opts.file, opts.offset, opts.gain, opts.notes = "audio", spec.file, spec.offset or 0, spec.gain or 0, nil
  end
  local id = api.clip_add(track, opts)
  if spec.muted then api.clip_set(id, "muted", true) end
  return id
end

local function set_sends(id, sends)
  local list = {}
  for i, s in ipairs(sends) do list[i] = { target = track_id(s.target), level = s.level or 0 } end
  api.track_set(id, "sends", list)
end

function T.add_track(a)
  local output = a.output ~= nil and track_id(a.output) or nil
  local id = api.track_add({ name = a.name, index = a.index, volume = a.volume, pan = a.pan, output = output, color = a.color })
  for _, d in ipairs(a.devices or {}) do add_device(id, d) end
  for _, c in ipairs(a.clips or {}) do add_clip(id, c) end
  if a.sends then set_sends(id, a.sends) end
  return { track = track_view(id, false) }
end

function T.set_track(a)
  local id = track_id(a.track)
  for _, key in ipairs({ "name", "volume", "pan", "mute", "solo", "color" }) do
    if a[key] ~= nil then api.track_set(id, key, a[key]) end
  end
  if a.output ~= nil then
    local out = a.output
    if out == false or out == "" then out = 0 end
    api.track_set(id, "output", track_id(out))
  end
  if a.sends then set_sends(id, a.sends) end
  if a.index then api.track_move(id, a.index) end
  return { track = track_view(id, false) }
end

function T.remove(a)
  local removed = {}
  for _, id in ipairs(a.automation or {}) do
    local lane = api.lane_get(need(api.lane_get, id, "automation lane"))
    api.lane_remove(id)
    removed[#removed + 1] = string.format("automation lane %d (%s%s)", id, lane.target, lane.param and " " .. lane.param or "")
  end
  for _, id in ipairs(a.clips or {}) do
    local c = api.clip_get(need(api.clip_get, id, "clip"))
    api.clip_remove(id)
    removed[#removed + 1] = string.format("clip %d %q", id, c.name)
  end
  for _, id in ipairs(a.devices or {}) do
    local d = api.device_get(need(api.device_get, id, "device"))
    api.device_remove(id)
    removed[#removed + 1] = string.format("device %d %s", id, d.name)
  end
  for _, ref in ipairs(a.tracks or {}) do
    local id = track_id(ref)
    local name = api.track_get(id).name
    api.track_remove(id)
    removed[#removed + 1] = string.format("track %d %q", id, name)
  end
  return { removed = removed }
end

function T.add_clip(a)
  local track = track_id(a.track)
  local id = add_clip(track, a)
  return { clip = clip_view(api.clip_get(id), #(a.notes or {}) <= 64) }
end

function T.edit_clip(a)
  local id = need(api.clip_get, a.clip, "clip")
  local c = api.clip_get(id)
  for _, key in ipairs({ "name", "start", "length", "muted", "gain", "offset" }) do
    if a[key] ~= nil then api.clip_set(id, key, a[key]) end
  end
  if a.track ~= nil then api.clip_set(id, "track", track_id(a.track)) end
  local touches_notes = a.remove_notes or a.transpose or a.notes or a.add_notes or a.velocity
  if touches_notes and c.kind ~= "midi" then fail("clip " .. id .. " is an audio clip; only MIDI clips have notes") end
  local removed = 0
  if a.remove_notes or a.transpose or a.velocity then
    local keep = {}
    local r = a.remove_notes
    if r and r.pitches then
      local set = {}
      for _, pitch in ipairs(r.pitches) do set[pitch] = true end
      r = { all = r.all, from = r.from, to = r.to, pitches = set }
    end
    for _, n in ipairs(api.clip_notes(id)) do
      local hit = r and (r.all
        or ((not r.pitches or r.pitches[n.pitch]) and (not r.from or n.start >= r.from - 1e-9) and (not r.to or n.start < r.to - 1e-9)
          and (r.pitches or r.from or r.to)))
      if hit then
        removed = removed + 1
      else
        if a.transpose then
          n.pitch = n.pitch + a.transpose
          if n.pitch < 0 or n.pitch > 127 then fail("transposing by " .. a.transpose .. " takes a note outside MIDI's range") end
        end
        if a.velocity then n.velocity = math.max(1, math.min(127, math.floor(n.velocity * a.velocity + 0.5))) end
        keep[#keep + 1] = n
      end
    end
    api.clip_set_notes(id, keep)
  end
  if a.notes then api.clip_set_notes(id, a.notes) end
  if a.add_notes then api.clip_add_notes(id, a.add_notes) end
  local v = clip_view(api.clip_get(id), true)
  if #v.notes > 64 then v.notes = nil end
  v.removed_notes = removed
  return { clip = v }
end

function T.add_device(a)
  local id = add_device(track_id(a.track), a)
  return { device = device_view(id, true) }
end

function T.set_device(a)
  local id = need(api.device_get, a.device, "device")
  set_params(id, a.params)
  if a.bypass ~= nil then api.device_set(id, "bypass", a.bypass) end
  if a.track ~= nil or a.index ~= nil then
    local d = api.device_get(id)
    local track = a.track ~= nil and track_id(a.track) or d.track
    api.device_move(id, track, a.index or #api.track_get(track).devices + (track == d.track and 0 or 1))
  end
  local v = device_view(id, true)
  if a.params and #v.params > 24 then
    -- Only what was asked about, for a plugin with hundreds of parameters.
    local wanted, keep = {}, {}
    for key in pairs(a.params) do wanted[tostring(key):lower()] = true end
    for _, p in ipairs(v.params) do
      if wanted[p.key:lower()] or wanted[p.name:lower()] then keep[#keep + 1] = p end
    end
    v.params, v.only_changed = keep, true
  end
  return { device = v }
end

function T.automate(a)
  local track, target, device = a.track, a.target or "volume", a.device
  if device then
    local d = api.device_get(need(api.device_get, device, "device"))
    track = track ~= nil and track_id(track) or d.track
    target = "param"
    if not a.param then fail("automating a device needs `param`, the parameter's key or name") end
  else
    track = track_id(track)
    if target ~= "volume" and target ~= "pan" then fail("target is `volume` or `pan`; for a device parameter give `device` and `param`") end
  end
  local lane
  for _, l in ipairs(api.lane_list(track)) do
    if l.target == target and (target ~= "param" or (l.device == device and (l.param == a.param))) then lane = l end
  end
  if not lane and target == "param" then
    -- The parameter may have been named by its display name.
    for _, p in ipairs(api.device_get(device).param_info) do
      if p.name:lower() == a.param:lower() then
        for _, l in ipairs(api.lane_list(track)) do
          if l.target == "param" and l.device == device and l.param == p.key then lane = l end
        end
      end
    end
  end
  if a.remove then
    if not lane then fail("there is no such automation lane to remove") end
    api.lane_remove(lane.id)
    return { removed = { "automation lane " .. lane.id } }
  end
  local created = false
  if not lane then
    local id = api.lane_add(track, { target = target, device = device, param = a.param, points = {} })
    lane, created = api.lane_get(id), true
  end
  if a.clear then api.lane_set_points(lane.id, {}) end
  if a.points then
    if a.mode == "add" then
      for _, p in ipairs(a.points) do api.lane_add_point(lane.id, p[1], p[2]) end
    else
      api.lane_set_points(lane.id, a.points)
    end
  end
  if a.enabled ~= nil then api.lane_set(lane.id, "enabled", a.enabled) end
  local v = lane_view(api.lane_get(lane.id), true)
  v.created, v.track = created, track
  v.track_name = api.track_get(track).name
  if target == "param" then v.device_name = api.device_get(device).name end
  return { lane = v }
end

function T.set_project(a)
  if a.tempo then api.project_set("tempo", a.tempo) end
  if a.sig_num then api.project_set("sig_num", a.sig_num) end
  if a.sig_den then api.project_set("sig_den", a.sig_den) end
  if a.name then api.project_set("name", a.name) end
  if a.tempo_changes or a.signature_changes then
    local map = api.tempo_points()
    local tempos, sigs = { map.tempos[1] }, { map.signatures[1] }
    for i, c in ipairs(a.tempo_changes or {}) do tempos[i + 1] = c end
    for i, c in ipairs(a.signature_changes or {}) do sigs[i + 1] = c end
    if not a.tempo_changes then tempos = map.tempos end
    if not a.signature_changes then sigs = map.signatures end
    api.tempo_set_points(tempos, sigs)
  end
  return { project = project_view() }
end

-- Not undoable: the transport is not part of the project's history.
function T.transport(a)
  for _, key in ipairs({ "loop_start", "loop_end", "metronome" }) do
    if a[key] ~= nil then api.transport_set(key, a[key]) end
  end
  if a.loop ~= nil then api.transport_set("loop_enabled", a.loop) end
  if a.action == "stop" or a.action == "pause" then api.transport_stop() end
  if a.position then api.transport_seek(a.position) end
  if a.action == "play" then api.transport_play() end
  return { transport = api.transport_get() }
end

function T.undo(a)
  local done, fn = 0, a.redo and api.redo or api.undo
  for _ = 1, a.steps or 1 do
    if not fn() then break end
    done = done + 1
  end
  paw.flush()
  return { done = done, project = project_view() }
end

function T.file(a)
  local p = api.project_get()
  if a.action == "save" then
    local path = api.project_save(a.path)
    paw.state[SAVED] = api.project_get().edits
    return { saved = path, project = { name = p.name, tempo = p.tempo } }
  end
  if unsaved(p) and not a.discard then
    fail("the project has unsaved changes, which " .. a.action .. " would lose for good (it also clears undo): save first, or pass discard=true")
  end
  if a.action == "load" then api.project_load(a.path) else api.project_new() end
  paw.state[SAVED] = api.project_get().edits
  paw.flush()
  return { project = project_view() }
end

function T.render(a)
  local p = api.project_get()
  local info = paw.render(a.path, { start = a.start, ["end"] = a["end"], tail = a.tail, bits = a.bits, sample_rate = a.sample_rate })
  info.start, info["end"] = a.start or 0, a["end"] or p.length
  info.tempo, info.sig_num, info.sig_den = p.tempo, p.sig_num, p.sig_den
  return { render = info }
end

-- Reads ------------------------------------------------------------------------

function T.project() return { project = project_view() } end

function T.track(a) return { track = track_view(track_id(a.track), true) } end

function T.clip(a)
  local v = clip_view(api.clip_get(need(api.clip_get, a.clip, "clip")), true)
  v.track_name = api.track_get(v.track).name
  return { clip = v }
end

function T.device(a)
  local v = device_view(need(api.device_get, a.device, "device"), true)
  if a.filter then
    local keep, words = {}, a.filter:lower()
    for _, p in ipairs(v.params) do
      if p.key:lower():find(words, 1, true) or p.name:lower():find(words, 1, true) then keep[#keep + 1] = p end
    end
    v.params, v.filtered = keep, true
  end
  v.track_name = api.track_get(v.track).name
  return { device = v }
end

function T.find_devices(a)
  local found = search(a.query, a.format)
  local out, limit = {}, a.limit or 25
  for i = 1, math.min(limit, #found) do
    local info = found[i]
    out[i] = { kind = info.kind, name = info.name, format = info.format, vendor = info.vendor, category = info.category, params = #info.params }
    if a.params then out[i].param_info = info.params end
  end
  return { total = #found, devices = out, all = #api.device_types() }
end

function T.status(a)
  local p, e = api.project_get(), api.engine_get()
  local out = { transport = api.transport_get(), engine = e, project = {
    name = p.name, path = p.path, modified = unsaved(p), tempo = p.tempo, sig_num = p.sig_num, sig_den = p.sig_den, length = p.length,
  }, messages = {} }
  local msgs = paw.ui.messages
  for i = math.max(1, #msgs - (a.messages or 10) + 1), #msgs do
    out.messages[#out.messages + 1] = { text = msgs[i].text, level = msgs[i].level }
  end
  return out
end

-- Escape hatches ---------------------------------------------------------------

function T.command(a)
  local result = paw.commands.exec(a.line)
  return { result = result ~= nil and paw.inspect(result) or nil }
end

function T.keys(a)
  paw.keymap.feed(a.keys)
  local km = paw.keymap
  return { mode = km.mode, pending = km.pending(), focused = paw.ui.focused }
end

function T.lua(a)
  local chunk = loadstring("return " .. a.code, "=lua") or assert(loadstring(a.code, "=lua"))
  local results = { chunk() }
  local shown = {}
  for i = 1, table.maxn(results) do shown[i] = paw.inspect(results[i]) end
  return { result = table.concat(shown, "\n") }
end

-- Entry ------------------------------------------------------------------------

local writes = {
  add_track = true, set_track = true, remove = true, add_clip = true, edit_clip = true, add_device = true,
  set_device = true, automate = true, set_project = true, command = true, keys = true, lua = true,
}
local rollback = { command = false, keys = false, lua = false }

local name, args = ...
local fn = T[name] or fail("no tool `" .. tostring(name) .. "` in the kernel side")
args = args or {}

local messages = paw.ui.messages
local last = messages[#messages]
local function new_messages()
  local out = {}
  for i = #messages, math.max(1, #messages - 20), -1 do
    if messages[i] == last then break end
    table.insert(out, 1, { text = messages[i].text, level = messages[i].level })
  end
  return out
end

local result
if writes[name] then
  api.undo_checkpoint()
  local before = api.project_get().edits
  local ok, res = xpcall(fn, function(e) return e end, args)
  if not ok then
    local undone = false
    if rollback[name] ~= false and api.project_get().edits ~= before then
      api.undo()
      undone = true
    end
    paw.flush()
    fail(clean(res) .. (undone and " (nothing was changed: the call was rolled back)" or ""))
  end
  paw.flush()
  api.undo_checkpoint()
  result = res
  result.edited = api.project_get().edits ~= before
else
  local ok, res = xpcall(fn, function(e) return e end, args)
  if not ok then fail(clean(res)) end
  paw.flush()
  result = res
end
result.messages = new_messages()
return result
