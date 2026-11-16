-- Addresses: a URI for everything a language server, a lint or a person
-- could talk about, built from ids so that it survives edits.
--
--   daw://project
--   daw://track/12                        daw://track/0 is the master
--   daw://track/12/device/3               daw://track/12/device/3/param/cutoff
--   daw://track/12/send/5                 the send to track 5
--   daw://clip/7                          daw://clip/7/note/41 (the note's own id)
--   daw://clip/7/control/cc/74            daw://lane/9
--   daw://tempo                           daw://marker/5
--   daw://render/<the file's path, %-encoded>
--
-- A note's id is the model's: every note has one from the moment it is
-- made, kept through every move and change, and only a note that is copied
-- next to its original gets a new one (crates/daw-core/src/model.rs,
-- `Note::id`).
--
-- A **selector** narrows an address to a part of it: `{ time = { from, to } }`
-- (beats), `{ notes = { ids } }`, `{ pitch = { lo, hi } }`, `{ value = x }`.
-- A **location** is `{ uri = ..., selector = ... }`.
--
-- A **workspace edit** is a list of changes, each `{ uri, set = { ... } }`,
-- `{ uri, insert = { ... } }` or `{ uri, delete = true }`: `daw.address.edit`
-- checks every one before it does anything and makes them one undo step.
local api = daw.api

local M = { schemes = {} }

local function decode(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
local function encode(s) return (s:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end)) end

--- An address in parts: `{ kind = "note", track?, device?, param?, send?,
--- clip?, note?, lane?, marker?, control?, number?, path?, segments }`, or
--- nil when it is not one. The fragment (`#mix`) is kept as `fragment`.
function M.parse(uri)
  if type(uri) ~= "string" then return nil end
  local body, fragment = uri:match("^daw://([^#]*)#?(.*)$")
  if not body then return nil end
  local seg = {}
  for part in body:gmatch("[^/]+") do seg[#seg + 1] = part end
  local out = { segments = seg, fragment = fragment ~= "" and fragment or nil, uri = uri }
  local head = seg[1]
  if head == "project" or head == "tempo" then
    out.kind = head
  elseif head == "track" then
    out.track = tonumber(seg[2])
    out.kind = "track"
    if seg[3] == "device" then
      out.device, out.kind = tonumber(seg[4]), "device"
      if seg[5] == "param" then out.param, out.kind = seg[6] and decode(seg[6]), "param" end
    elseif seg[3] == "send" then
      out.send, out.kind = tonumber(seg[4]), "send"
    end
  elseif head == "clip" then
    out.clip, out.kind = tonumber(seg[2]), "clip"
    if seg[3] == "note" then
      out.note, out.kind = tonumber(seg[4]), "note"
    elseif seg[3] == "control" then
      out.control, out.number, out.kind = seg[4], tonumber(seg[5]), "control"
    end
  elseif head == "lane" then
    out.lane, out.kind = tonumber(seg[2]), "lane"
  elseif head == "marker" then
    out.marker, out.kind = tonumber(seg[2]), "marker"
  elseif head == "render" then
    out.path, out.kind = decode(body:sub(#"render/" + 1)), "render"
  elseif head and M.schemes[head] then
    out.kind = head
  else
    return nil
  end
  return out
end

-- Constructors ---------------------------------------------------------------

function M.project() return "daw://project" end
function M.tempo() return "daw://tempo" end
function M.track(id) return "daw://track/" .. id end
function M.clip(id) return "daw://clip/" .. id end
function M.note(clip, id) return "daw://clip/" .. clip .. "/note/" .. id end
function M.lane(id) return "daw://lane/" .. id end
function M.marker(id) return "daw://marker/" .. id end
function M.render(path) return "daw://render/" .. encode(path) end
function M.send(track, target) return "daw://track/" .. track .. "/send/" .. target end

function M.device(id)
  local d = api.device_get(id)
  return "daw://track/" .. d.track .. "/device/" .. id
end

function M.param(device, key) return M.device(device) .. "/param/" .. encode(key) end

--- A location: an address and, optionally, a part of it.
function M.location(uri, selector) return { uri = uri, selector = selector } end

--- The address of an object of the scripting interface (`daw.track(3)`,
--- `daw.clip(7)`, a device) or of a table `daw.api` gave (with its fields).
function M.of(object)
  if type(object) == "string" and M.parse(object) then return object end
  if type(object) ~= "table" then return nil end
  local mt = getmetatable(object)
  if mt == daw.Track then return M.track(object.id) end
  if mt == daw.Clip then return M.clip(object.id) end
  if mt == daw.Device then return M.device(object.id) end
  if object.param_info and object.id then return M.device(object.id) end
  if object.kind and object.track and object.id and object.length then return M.clip(object.id) end
  if object.sends and object.devices and object.id then return M.track(object.id) end
  for name, scheme in pairs(M.schemes) do
    local uri = scheme.of and scheme.of(object)
    if uri then return uri, name end
  end
  return nil
end

-- Resolving ------------------------------------------------------------------

local function try(fn, ...)
  local ok, v = pcall(fn, ...)
  if ok then return v end
end

--- The note of a clip with an id, and its place in the clip (from 1).
function M.find_note(clip, id)
  local notes = try(api.clip_notes, clip)
  for place, n in ipairs(notes or {}) do
    if n.id == id then return n, place end
  end
end

--- What an address names, as `daw.api` has it (a note also says its
--- `place`; a parameter is `{ key, value, info }`), or nil when it is gone.
function M.resolve(uri)
  local p = M.parse(uri)
  if not p then return nil end
  if p.kind == "project" then return api.project_get() end
  if p.kind == "tempo" then return api.tempo_points() end
  if p.kind == "track" then return p.track and try(api.track_get, p.track) end
  if p.kind == "device" or p.kind == "param" then
    local d = p.device and try(api.device_get, p.device)
    if not d or d.track ~= p.track then return nil end
    if p.kind == "device" then return d end
    for _, info in ipairs(d.param_info or {}) do
      if info.key == p.param then return { key = p.param, value = d.params[p.param], info = info, device = d.id } end
    end
    return nil
  end
  if p.kind == "send" then
    local t = p.track and try(api.track_get, p.track)
    for _, s in ipairs(t and t.sends or {}) do
      if s.target == p.send then return s end
    end
    return nil
  end
  if p.kind == "clip" then return p.clip and try(api.clip_get, p.clip) end
  if p.kind == "note" then
    local n, place = M.find_note(p.clip, p.note)
    if n then return daw.util.merge(n, { place = place, clip = p.clip }) end
    return nil
  end
  if p.kind == "control" then
    local out = {}
    for _, c in ipairs(try(api.clip_controls, p.clip) or {}) do
      if c.type == p.control and (not p.number or c.number == p.number) then out[#out + 1] = c end
    end
    return try(api.clip_get, p.clip) and out or nil
  end
  if p.kind == "lane" then return p.lane and try(api.lane_get, p.lane) end
  if p.kind == "marker" then
    for _, m in ipairs(daw.markers and daw.markers.list() or {}) do
      if m.id == p.marker then return m end
    end
    return nil
  end
  if p.kind == "render" then
    return M.renders[p.path] or (io.open(p.path) and { path = p.path }) or nil
  end
  local scheme = M.schemes[p.kind]
  return scheme and scheme.resolve(uri, p)
end

--- The address that holds this one (a note's clip, a device's track), or nil.
function M.parent(uri)
  local p = M.parse(uri)
  if not p then return nil end
  if p.kind == "note" or p.kind == "control" then return M.clip(p.clip) end
  if p.kind == "param" then return "daw://track/" .. p.track .. "/device/" .. p.device end
  if p.kind == "device" or p.kind == "send" then return M.track(p.track) end
  if p.kind == "clip" then
    local c = try(api.clip_get, p.clip)
    return c and M.track(c.track) or nil
  end
  if p.kind == "lane" then
    local l = try(api.lane_get, p.lane)
    return l and l.track and M.track(l.track) or M.project()
  end
  if p.kind == "project" then return nil end
  local scheme = M.schemes[p.kind]
  if scheme and scheme.parent then return scheme.parent(uri, p) end
  return M.project()
end

--- What an address holds, one level down.
function M.children(uri)
  local p = M.parse(uri)
  local out = {}
  if not p then return out end
  if p.kind == "project" then
    for _, id in ipairs(api.track_list()) do out[#out + 1] = M.track(id) end
    out[#out + 1] = M.track(0)
    out[#out + 1] = M.tempo()
  elseif p.kind == "track" then
    local t = try(api.track_get, p.track)
    for _, d in ipairs(t and t.devices or {}) do out[#out + 1] = "daw://track/" .. p.track .. "/device/" .. d end
    for _, s in ipairs(t and t.sends or {}) do out[#out + 1] = M.send(p.track, s.target) end
    for _, c in ipairs(t and try(api.clip_list, p.track) or {}) do out[#out + 1] = M.clip(c.id) end
  elseif p.kind == "device" then
    local d = try(api.device_get, p.device)
    for _, info in ipairs(d and d.param_info or {}) do out[#out + 1] = uri .. "/param/" .. encode(info.key) end
  elseif p.kind == "clip" then
    for _, n in ipairs(try(api.clip_notes, p.clip) or {}) do
      if n.id then out[#out + 1] = M.note(p.clip, n.id) end
    end
  elseif M.schemes[p.kind] and M.schemes[p.kind].children then
    out = M.schemes[p.kind].children(uri, p)
  end
  return out
end

--- Whether `uri` is `ancestor` or lies inside it (a note inside its clip,
--- a parameter inside its device and track). Everything is inside the project.
function M.within(uri, ancestor)
  if ancestor == M.project() then return true end
  local at = uri
  for _ = 1, 8 do
    if not at then return false end
    if at == ancestor or at:sub(1, #ancestor + 1) == ancestor .. "/" then return true end
    at = M.parent(at)
  end
  return false
end

--- The track an address belongs to, if any.
function M.track_of(uri)
  local at = uri
  for _ = 1, 8 do
    local p = at and M.parse(at)
    if not p then return nil end
    if p.track then return p.track end
    at = M.parent(at)
  end
end

--- Add a kind of address: `daw://<name>/...`, for what an extension keeps
--- (the vocal editor's phrases, a score's measures). `spec.resolve(uri,
--- parts)` gives the thing or nil; optional `of(object)`, `children(uri,
--- parts)`, `parent(uri, parts)`, and `edit(change, parts)` to apply a
--- workspace edit's change to it (which must make its edits through
--- `daw.api`, so that they join the undo step).
function M.scheme(name, spec)
  assert(type(spec) == "table" and spec.resolve, "usage: daw.address.scheme(name, { resolve = fn, ... })")
  M.schemes[name] = spec
end

-- Workspace edits ------------------------------------------------------------

local TRACK_FIELDS = { volume = true, pan = true, mute = true, solo = true, name = true, output = true, armed = true }
local CLIP_FIELDS = { start = true, length = true, name = true, muted = true }
local NOTE_FIELDS = { pitch = true, start = true, length = true, velocity = true, meta = true }

-- Check one change; return what to do, or nil and why not.
local function plan(change)
  local p = M.parse(change.uri)
  if not p then return nil, "not an address: " .. tostring(change.uri) end
  local what = change.delete and "delete" or change.insert and "insert" or change.set and "set"
  if not what then return nil, change.uri .. ": a change sets, inserts or deletes" end
  if p.kind ~= "render" and not M.resolve(change.uri) then return nil, change.uri .. " is gone" end
  local function only(fields, set)
    for k in pairs(set) do
      if not fields[k] then return nil, string.format("%s: cannot set `%s`", change.uri, k) end
    end
    return true
  end
  if p.kind == "note" then
    if what == "insert" then return nil, "notes are inserted into their clip" end
    if what == "set" then
      local ok, err = only(NOTE_FIELDS, change.set)
      if not ok then return nil, err end
    end
  elseif p.kind == "clip" then
    if what == "set" then
      local ok, err = only(CLIP_FIELDS, change.set)
      if not ok then return nil, err end
    elseif what == "insert" and not (change.insert.notes or change.insert.pitch) then
      return nil, change.uri .. ": a clip takes notes"
    end
  elseif p.kind == "track" then
    if what == "set" then
      local ok, err = only(TRACK_FIELDS, change.set)
      if not ok then return nil, err end
    elseif what == "insert" and not (change.insert.device or change.insert.clip) then
      return nil, change.uri .. ": a track takes a device or a clip"
    elseif what == "delete" and p.track == 0 then
      return nil, "the master track stays"
    end
  elseif p.kind == "device" then
    if what == "insert" then return nil, "nothing is inserted into a device" end
  elseif p.kind == "param" then
    if what ~= "set" or change.set.value == nil then return nil, change.uri .. ": a parameter takes `set = { value = ... }`" end
  elseif p.kind == "send" then
    if what == "insert" then return nil, "nothing is inserted into a send" end
  elseif p.kind == "render" then
    if what ~= "set" then return nil, "a render is rendered again with `set`" end
  elseif M.schemes[p.kind] then
    if not M.schemes[p.kind].edit then return nil, p.kind .. " addresses cannot be edited" end
  else
    return nil, p.kind .. " addresses cannot be edited"
  end
  return p
end

--- Carry out a workspace edit: every change is checked first, and nothing
--- is done unless all can be; then all are made as one undo step labelled
--- `label`. Returns true, or nil and why not.
---   daw.address.edit({ { uri = "daw://track/3", set = { volume = -6 } },
---                      { uri = "daw://clip/7/note/41", set = { pitch = 62 } } }, "Lower the bass")
function M.edit(changes, label)
  local plans = {}
  for i, change in ipairs(changes or {}) do
    local p, why = plan(change)
    if not p then return nil, why end
    plans[i] = p
  end
  if label then api.undo_label(label) end
  -- Notes go clip by clip in one edit each, by their places before it.
  local by_clip, renders = {}, {}
  local function clip_edit(id)
    by_clip[id] = by_clip[id] or { set = {}, remove = {}, add = {} }
    return by_clip[id]
  end
  for i, change in ipairs(changes) do
    local p = plans[i]
    if p.kind == "note" then
      local _, place = M.find_note(p.clip, p.note)
      local e = clip_edit(p.clip)
      if change.delete then e.remove[#e.remove + 1] = place
      else e.set[#e.set + 1] = daw.util.merge(change.set, { index = place }) end
    elseif p.kind == "clip" then
      if change.delete then api.clip_remove(p.clip)
      elseif change.insert then
        local e = clip_edit(p.clip)
        for _, n in ipairs(change.insert.notes or { change.insert }) do e.add[#e.add + 1] = n end
      else
        for k, v in pairs(change.set) do api.clip_set(p.clip, k, v) end
      end
    elseif p.kind == "track" then
      if change.delete then api.track_remove(p.track)
      elseif change.insert and change.insert.device then
        api.device_add(p.track, change.insert.device, { params = change.insert.params, index = change.insert.index })
      elseif change.insert then
        api.clip_add(p.track, change.insert.clip)
      else
        for k, v in pairs(change.set) do api.track_set(p.track, k, v) end
      end
    elseif p.kind == "device" then
      if change.delete then api.device_remove(p.device)
      else
        for k, v in pairs(change.set) do
          if k == "params" then
            for key, value in pairs(v) do api.device_set_param(p.device, key, value) end
          else
            api.device_set(p.device, k, v)
          end
        end
      end
    elseif p.kind == "param" then
      api.device_set_param(p.device, p.param, change.set.value)
    elseif p.kind == "send" then
      local sends = {}
      for _, s in ipairs(api.track_get(p.track).sends) do
        if s.target ~= p.send then sends[#sends + 1] = s
        elseif not change.delete then sends[#sends + 1] = daw.util.merge(s, change.set) end
      end
      api.track_set(p.track, "sends", sends)
    elseif p.kind == "render" then
      renders[#renders + 1] = { path = p.path, opts = change.set }
    else
      M.schemes[p.kind].edit(change, p)
    end
  end
  for id, e in pairs(by_clip) do daw.clip(id):edit_notes(e) end
  -- A render is not an edit of the project: it is made again afterwards,
  -- with what was set over the options it was made with.
  for _, r in ipairs(renders) do
    local before = M.renders[r.path] and M.renders[r.path].opts or {}
    daw.render(r.path, daw.util.merge(daw.util.merge(before, r.opts), { background = true }))
  end
  return true
end

-- Renders ----------------------------------------------------------------------

--- What was rendered, by path: what the render returned, with the options
--- it was made with (`opts`). The `render` subject and addresses read it.
M.renders = {}

local pending_opts = {}
daw.on("render.before", function(e) pending_opts[e.path] = e.opts end)
local function rendered(info)
  if type(info) ~= "table" or not info.path then return end
  local entry = daw.util.merge(info, { opts = pending_opts[info.path] or {}, at = api.now() })
  pending_opts[info.path] = nil
  M.renders[info.path] = entry
  daw.emit("address.changed", { uris = { M.render(info.path) }, revision = api.project_get().edits, rendered = entry })
end
daw.on("render.done", rendered)
daw.on("render.finished", rendered)

-- Change events --------------------------------------------------------------

-- The kernel says what changed by id (`track.changed { id }`, `clip.added
-- { id, track }`, `device.removed { id }`, `lane.*`, `project.*`); these
-- become one `address.changed { uris, revision }` for the edit, after the
-- kernel's own `changed`, so that whoever watches addresses never diffs
-- snapshots.
local pending, scheduled = {}, false
local function tell()
  scheduled = false
  if not next(pending) then return end
  local uris = {}
  for uri in pairs(pending) do uris[#uris + 1] = uri end
  table.sort(uris)
  pending = {}
  daw.emit("address.changed", { uris = uris, revision = api.project_get().edits })
end
local function changed(uris)
  for _, uri in ipairs(uris) do pending[uri] = true end
  if not scheduled then
    scheduled = true
    daw.defer(tell, 0)
  end
end
daw.on("track.*", function(e) if e.id then changed({ M.track(e.id) }) end end)
daw.on("clip.*", function(e) if e.id then changed({ M.clip(e.id) }) end end)
daw.on("device.*", function(e)
  if not e.id then return end
  local ok, d = pcall(api.device_get, e.id)
  changed({ ok and ("daw://track/" .. d.track .. "/device/" .. e.id) or M.project() })
end)
daw.on("lane.*", function(e) if e.id then changed({ M.lane(e.id) }) end end)
daw.on("project.*", function() changed({ M.project() }) end)
-- What changes without an event of its own (the tempo map, the project's
-- meta) is the project's.
daw.on("changed", function()
  changed({ M.project() })
  tell()
end)

--- Whether an address matches a pattern: `daw://track/*` (one level),
--- `daw://track/**` (any depth), or an exact address.
function M.matches(pattern, uri)
  if pattern == uri then return true end
  local lua = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*%*", "\1"):gsub("%*", "[^/]*"):gsub("\1", ".*") .. "$"
  return uri:match(lua) ~= nil
end

return M
