-- Tracks, devices and clips as objects.
--
-- An object is only an id with methods: reading `track.volume` asks the
-- kernel, writing it tells the kernel. Objects stay valid across undo, and
-- raise an error when the thing they point at no longer exists.
local api = daw.api
local music = require("daw.music")

local Track, Device, Clip, Lane = {}, {}, {}, {}
local M = { Track = Track, Device = Device, Clip = Clip, Lane = Lane }

local function class(cls, name, get, set)
  cls.__name = name
  cls.__index = function(self, key)
    local method = cls[key]
    if method ~= nil then return method end
    return get(rawget(self, "id"))[key]
  end
  cls.__newindex = function(self, key, value)
    set(rawget(self, "id"), key, value)
  end
  cls.__eq = function(a, b) return rawget(a, "id") == rawget(b, "id") end
  cls.__tostring = function(self) return name .. "(" .. rawget(self, "id") .. ")" end
end

local function wrap(cls, id)
  return id and setmetatable({ id = id }, cls) or nil
end

local function id_of(value)
  return type(value) == "table" and value.id or value
end

-- Tracks ---------------------------------------------------------------------

class(Track, "Track", api.track_get, function(id, key, value)
  if key == "output" then value = id_of(value) end
  api.track_set(id, key, value)
end)

--- A plain table with every field of the track, read once.
function Track:get() return api.track_get(self.id) end

function Track:exists() return (pcall(api.track_get, self.id)) end

function Track:remove() api.track_remove(self.id) end

--- Move to a 1-based position in the track list.
function Track:move(index) api.track_move(self.id, index) end

--- Add a device to the end of the chain, or at the 1-based `opts.index`.
---   track:add_device("synth", { cutoff = 800 })
function Track:add_device(kind, params, opts)
  return wrap(Device, api.device_add(self.id, kind, { params = params, index = opts and opts.index }))
end

function Track:devices()
  local out = {}
  for i, id in ipairs(api.track_get(self.id).devices) do out[i] = wrap(Device, id) end
  return out
end

--- The first device of a kind, or the device at a 1-based position.
function Track:device(which)
  for i, device in ipairs(self:devices()) do
    if i == which or device.kind == which then return device end
  end
end

--- Add a clip. With `file` it is an audio clip, otherwise a MIDI clip.
---   track:add_clip({ start = 0, length = 4, notes = { { pitch = "C4", start = 0, length = 1 } } })
---   track:add_clip({ start = 8, file = "take1.wav" })
function Track:add_clip(opts)
  opts = opts or {}
  if opts.notes then opts = daw.util.merge(opts, { notes = M.notes(opts.notes) }) end
  return wrap(Clip, api.clip_add(self.id, opts))
end

function Track:clips()
  local out = {}
  for i, clip in ipairs(api.clip_list(self.id)) do out[i] = wrap(Clip, clip.id) end
  return out
end

--- The clip covering `beat`, if any. The later clip wins where two overlap.
function Track:clip_at(beat)
  local found
  for _, clip in ipairs(api.clip_list(self.id)) do
    if beat >= clip.start and beat < clip.start + clip.length then found = clip.id end
  end
  return wrap(Clip, found)
end

--- Peak level as linear `left, right`.
function Track:meter() return api.track_meter(self.id) end

--- Start a note now, outside the timeline. `pitch` may be a name like "C4".
--- With `attr`, a MIDI 2.0 attribute (`daw.attr`), the note carries it, and
--- what the track's `attr_map` sends for it goes first.
function Track:note_on(pitch, velocity, attr)
  daw.ui.poke()
  api.note_on(self.id, music.pitch(pitch), velocity, attr)
end

--- Stop a note, or every note when `pitch` is left out.
function Track:note_off(pitch)
  api.note_off(self.id, pitch and music.pitch(pitch))
end

--- Send a MIDI message to this track's devices now, outside the timeline:
--- a controller, the pitch wheel, pressure, or with `key` one note's own.
---   track:midi({ type = "cc", number = 1, value = 0.5 })
---   track:midi({ type = "bend", value = -0.25 })
---   track:midi({ type = "bend", key = "C4", value = 0.1 })
function Track:midi(event)
  if event.key then event = daw.util.merge(event, { key = music.pitch(event.key) }) end
  if event.pitch then event = daw.util.merge(event, { pitch = music.pitch(event.pitch) }) end
  api.midi_send(self.id, event)
end

--- Play a note for `ms` milliseconds (default 200), with `attr` if given.
function Track:play_note(pitch, velocity, ms, attr)
  self:note_on(pitch, velocity, attr)
  daw.defer(function() if self:exists() then self:note_off(pitch) end end, ms or 200)
end

--- Send some of this track's output to another track. `level` is in dB.
--- With `{ pre = true }` the send is taken before the fader and pan, so it
--- keeps its level when the fader moves: `vocal:send(reverb, -6, { pre = true })`.
function Track:send(target, level, opts)
  local sends = api.track_get(self.id).sends
  sends[#sends + 1] = { target = id_of(target), level = level or 0, pre = opts and opts.pre or nil }
  api.track_set(self.id, "sends", sends)
end

--- Everything about the track as plain data: its settings, devices (plugins
--- with their state), clips and automation. `daw.restore_track` makes a
--- track from it again, in this project or after the original is gone.
function Track:snapshot()
  local t = self:get()
  local snap = {
    name = t.name, volume = t.volume, pan = t.pan, output = t.output, color = t.color, mute = t.mute,
    sends = t.sends, input = t.input, monitor = t.monitor, midi_input = t.midi_input, height = t.height,
    midi_output = t.midi_output,
    -- How its notes' articulations reach its instrument.
    attr_map = t.attr_map,
    -- What extensions keep with the track: a drum map, the group it is in.
    meta = next(t.meta or {}) and t.meta or nil,
    devices = {}, clips = {}, lanes = {},
  }
  local position = {}
  for i, device in ipairs(self:devices()) do
    position[device.id] = i
    snap.devices[i] = device:snapshot()
  end
  for i, clip in ipairs(self:clips()) do snap.clips[i] = clip:snapshot() end
  -- The clips in its slots, each knowing its row (`daw.launcher`).
  for _, clip in ipairs(api.slot_list(self.id)) do snap.clips[#snap.clips + 1] = wrap(Clip, clip.id):snapshot() end
  for i, lane in ipairs(api.lane_list(self.id)) do
    snap.lanes[i] = {
      target = lane.target, device = lane.device and position[lane.device], param = lane.param,
      enabled = lane.enabled, points = api.lane_points(lane.id),
    }
  end
  return snap
end

--- Make a track from a snapshot, at a 1-based position in the track list.
function M.restore_track(snap, index)
  local exists = function(id) return id ~= nil and (pcall(api.track_get, id)) end
  local track = M.add_track({
    name = snap.name, volume = snap.volume, pan = snap.pan, color = snap.color, index = index,
    -- What it fed may be gone by now; then it goes to the master.
    output = exists(snap.output) and snap.output or nil,
  })
  local sends = {}
  for _, send in ipairs(snap.sends or {}) do
    if exists(send.target) then sends[#sends + 1] = send end
  end
  if snap.mute then track.mute = true end
  if #sends > 0 then track.sends = sends end
  if snap.input then track.input = snap.input end
  if snap.monitor then track.monitor = true end
  if snap.midi_input then track.midi_input = snap.midi_input end
  if snap.midi_output then track.midi_output = snap.midi_output end
  if snap.attr_map then track.attr_map = snap.attr_map end
  if snap.height then api.track_set(track.id, "height", snap.height) end
  if snap.meta then api.track_set(track.id, "meta", snap.meta) end
  local devices = {}
  for i, d in ipairs(snap.devices or {}) do devices[i] = M.restore_device(d, track) end
  for _, clip in ipairs(snap.clips or {}) do M.restore_clip(clip, track) end
  for _, lane in ipairs(snap.lanes or {}) do
    api.lane_add(track.id, {
      target = lane.target, device = lane.device and devices[lane.device].id, param = lane.param,
      enabled = lane.enabled, points = lane.points,
    })
  end
  return track
end

--- Copy the track with its devices, clips and automation, placing the copy after it.
function Track:duplicate()
  local snap = self:snapshot()
  snap.name = snap.name .. " copy"
  -- The tracks the original's output pairs play into stay the original's.
  for _, device in ipairs(snap.devices) do device.outputs = nil end
  return M.restore_track(snap, self.index + 1)
end

--- The automation lanes of the track, its devices' included.
function Track:lanes()
  local out = {}
  for i, lane in ipairs(api.lane_list(self.id)) do out[i] = wrap(Lane, lane.id) end
  return out
end

--- The lane for "volume" or "pan", if there is one.
function Track:lane(target)
  for _, lane in ipairs(api.lane_list(self.id)) do
    if lane.target == target then return wrap(Lane, lane.id) end
  end
end

--- The lane for "volume" or "pan", made if there is none yet.
---   track:automate("volume"):set_points({ { 0, -60 }, { 8, 0 } })
function Track:automate(target)
  return self:lane(target) or wrap(Lane, api.lane_add(self.id, { target = target }))
end

--- What "volume" or "pan" is at a beat while playing: the lane's value when
--- one is on, else the track's own.
function Track:value_at(target, beat)
  local lane = self:lane(target)
  local value = lane and lane.enabled and api.lane_value_at(lane.id, beat)
  if value then return value end
  return api.track_get(self.id)[target]
end

-- Devices --------------------------------------------------------------------

class(Device, "Device", api.device_get, function(id, key, value)
  if key == "sidechain" then value = id_of(value) end
  if key == "outputs" and type(value) == "table" then
    local ids = {}
    for pair, track in pairs(value) do ids[tostring(pair)] = id_of(track) end
    value = next(ids) and ids or nil
  end
  api.device_set(id, key, value)
end)

function Device:get() return api.device_get(self.id) end

function Device:exists() return (pcall(api.device_get, self.id)) end

function Device:remove() api.device_remove(self.id) end

--- The track this device is on.
function Device:track() return wrap(Track, api.device_get(self.id).track) end

--- Set one parameter, or several from a table.
---   device:set("cutoff", 800)
---   device:set({ cutoff = 800, resonance = 0.4 })
function Device:set(name, value)
  if type(name) == "table" then
    for k, v in pairs(name) do api.device_set_param(self.id, k, v) end
  else
    api.device_set_param(self.id, name, value)
  end
  return self
end

--- The description of this device: its name, category, format, and its
--- parameters with their ranges. A plugin's parameters are those of this
--- instance, which is the only place they are known.
function Device:info()
  local d = api.device_get(self.id)
  for _, info in ipairs(api.device_types()) do
    if info.kind == d.kind then
      info.params = d.param_info
      return info
    end
  end
end

--- The device as plain data, for `daw.restore_device`. A plugin is captured
--- by its state, which holds more than its parameters do.
function Device:snapshot()
  local d = self:get()
  local state = api.device_state(self.id)
  -- What extensions keep with the device goes where the device goes.
  local meta = type(d.meta) == "table" and next(d.meta) and d.meta or nil
  return {
    kind = d.kind, bypass = d.bypass, state = state, params = not state and d.params or nil, meta = meta,
    sidechain = d.sidechain, sidechain_pre = d.sidechain_pre or nil,
    outputs = next(d.outputs or {}) and d.outputs or nil,
  }
end

--- Play the device's output pair `pair` (2 and on: the first plays on its
--- own track) into a track, or nowhere with nil. `device.outputs` is a table
--- of pair number to track id; `device.ports.outputs` names the pairs.
function Device:set_output(pair, track)
  require("daw.routes").set_output(self.id, pair, id_of(track))
  return self
end

--- Listen to another track's sound as the device's side-chain: a
--- compressor on the bass ducks under the kick with `comp:set_sidechain(kick)`.
--- `{ pre = true }` takes it before that track's fader, pan and mute; nil
--- (or no track) takes the side-chain away. `device.sidechain` is the
--- track's id.
function Device:set_sidechain(track, opts)
  api.device_set(self.id, "sidechain", id_of(track))
  api.device_set(self.id, "sidechain_pre", track ~= nil and opts ~= nil and opts.pre == true)
  return self
end

--- Show the plugin's own window. `device.editor` is "open", "closed", or nil
--- for devices that have none.
--- Start the device again: for a plugin that stopped working (`stopped`
--- says why) or never loaded. It comes back with the state the project last
--- had of it.
function Device:restart() return api.device_restart(self.id) end

--- Set the device offline: not made at all (no process for a plugin),
--- passed over, its state and parameters kept as they are; or back online.
function Device:set_offline(on) api.device_set(self.id, "offline", on ~= false) end

function Device:open_editor() return api.device_editor(self.id, true) end

function Device:close_editor() return api.device_editor(self.id, false) end

--- The key of a parameter given by key or by name.
local function param_key(d, name)
  for _, p in ipairs(d.param_info) do
    if p.key == name then return p.key end
  end
  for _, p in ipairs(d.param_info) do
    if p.name:lower() == tostring(name):lower() then return p.key end
  end
  return name
end

function Device:lanes()
  local out = {}
  for _, lane in ipairs(api.lane_list(api.device_get(self.id).track)) do
    if lane.device == self.id then out[#out + 1] = wrap(Lane, lane.id) end
  end
  return out
end

--- The lane for a parameter, if there is one.
function Device:lane(param)
  local d = api.device_get(self.id)
  local key = param_key(d, param)
  for _, lane in ipairs(api.lane_list(d.track)) do
    if lane.device == self.id and lane.param == key then return wrap(Lane, lane.id) end
  end
end

--- The lane for a parameter, made if there is none yet.
---   synth:automate("cutoff"):add(0, 200)
function Device:automate(param)
  return self:lane(param)
    or wrap(Lane, api.lane_add(api.device_get(self.id).track, { target = "param", device = self.id, param = param }))
end

--- What a parameter is at a beat while playing: the lane's value when one is
--- on, else the device's own.
function Device:value_at(param, beat)
  local lane = self:lane(param)
  local value = lane and lane.enabled and api.lane_value_at(lane.id, beat)
  if value then return value end
  local d = api.device_get(self.id)
  return d.params[param_key(d, param)]
end

--- Move within the chain, or to another track: `device:move(1)`, `device:move(2, other)`.
function Device:move(index, track)
  api.device_move(self.id, id_of(track) or api.device_get(self.id).track, index)
end

-- Clips ----------------------------------------------------------------------

class(Clip, "Clip", api.clip_get, function(id, key, value)
  if key == "track" then value = id_of(value) end
  api.clip_set(id, key, value)
end)

function Clip:get() return api.clip_get(self.id) end

function Clip:exists() return (pcall(api.clip_get, self.id)) end

function Clip:remove() api.clip_remove(self.id) end

function Clip:track() return wrap(Track, api.clip_get(self.id).track) end

--- The notes of a MIDI clip: a list of { pitch, start, length, velocity },
--- with `start` in beats from the start of the clip, `meta`, a table of
--- extension data such as a lyric, on notes that have any, and `attr`, the
--- MIDI 2.0 attribute of the note's start (`{ type, data }`, see
--- `daw.attr`), on notes that have one.
---
--- With a range, only the notes sounding within it, and as a second value
--- the place of each in the whole list, for `set_note` and `remove_note`:
---   local notes, at = clip:notes({ from = 4, to = 8, low = "C3", high = "C5" })
function Clip:notes(range)
  if range and (range.low or range.high) then
    range = daw.util.merge(range, { low = range.low and music.pitch(range.low), high = range.high and music.pitch(range.high) })
  end
  return api.clip_notes(self.id, range)
end

--- The note on a pitch sounding at a beat of the clip, and its place among
--- the clip's notes; nothing when there is none.
function Clip:note_at(pitch, beat) return api.clip_note_at(self.id, music.pitch(pitch), beat) end

--- Change one note, named by its place among the clip's notes (from 1),
--- without touching the others: `clip:set_note(3, { length = 2 })`. Returns
--- the note's place afterwards, since notes stay in the order they start.
--- `attr = false` takes its attribute away.
function Clip:set_note(index, fields)
  if fields.pitch then fields = daw.util.merge(fields, { pitch = music.pitch(fields.pitch) }) end
  return api.clip_note_set(self.id, index, fields)
end

function Clip:remove_note(index) api.clip_note_remove(self.id, index) end

--- Change, remove and add several notes as one edit. Every index is a
--- note's place before the call:
---   clip:edit_notes({ set = { { index = 3, start = 1 } }, remove = { 5, 6 }, add = { note } })
function Clip:edit_notes(edit)
  local set = {}
  for i, change in ipairs(edit.set or {}) do
    set[i] = change.pitch and daw.util.merge(change, { pitch = music.pitch(change.pitch) }) or change
  end
  api.clip_notes_edit(self.id, { set = set, remove = edit.remove or {}, add = M.notes(edit.add or {}) })
end

--- The waveform of an audio clip: `n` { min, max, rms } entries, each
--- covering an equal part of what the clip plays, scaled by its gain: how
--- far the wave reaches each way (-1 to 1) and how loud it is there. Cached,
--- so drawing code can ask for it every frame.
function Clip:peaks(n) return api.clip_peaks(self.id, n) end

function Clip:set_notes(notes) api.clip_set_notes(self.id, M.notes(notes)) end

--- What the clip does besides notes: controller moves, the pitch wheel,
--- pressure and program changes, each `{ start, type, value }` with `start`
--- in beats from the start of the clip. `type` is "cc" (with `number`),
--- "bend" (-1 to 1), "pressure", "registered" or "assignable" (with `bank`
--- and `index`), or "program" (with `program` and maybe `bank`); values run
--- from 0 to 1 at any resolution. With `key` a move belongs to the note on
--- that key alone, as in MIDI 2.0: its own bend, pressure or controller.
function Clip:controls() return api.clip_controls(self.id) end

---   clip:set_controls({ { start = 0, type = "cc", number = 64, value = 1 },
---                       { start = 1, type = "bend", key = "E4", value = 0.02 } })
function Clip:set_controls(controls)
  local out = {}
  for i, c in ipairs(controls) do
    out[i] = c.key and daw.util.merge(c, { key = music.pitch(c.key) }) or c
  end
  api.clip_set_controls(self.id, out)
end

function Clip:add_notes(notes) api.clip_add_notes(self.id, M.notes(notes)) end

---   clip:add_note({ pitch = "E4", start = 1, length = 0.5, velocity = 90 })
---   clip:add_note({ pitch = "G4", start = 2, attr = daw.attr.m2("11.A") })   -- pizzicato
--- Returns the note's place among the clip's notes.
function Clip:add_note(note) return api.clip_note_add(self.id, M.notes({ note })[1]) end

--- The clip as plain data, for `daw.restore_clip`.
function Clip:snapshot()
  local c = self:get()
  local snap = {
    name = c.name, start = c.start, length = c.length, kind = c.kind, muted = c.muted,
    file = c.file, offset = c.offset, gain = c.gain, fade_in = c.fade_in, fade_out = c.fade_out,
    -- How it plays: an audio clip's timebase, stretch and shift; looping.
    timebase = c.timebase, stretch = c.stretch, pitch = c.pitch, stretch_mode = c.stretch_mode,
    source_tempo = c.source_tempo, loop = c.loop or nil, loop_length = c.loop_length, loop_start = c.loop_start,
    warp = daw.stretch.markers(c), formants = c.formants or nil,
    -- What extensions keep with the clip goes where the clip goes.
    meta = next(c.meta) and c.meta or nil,
    -- A clip in a slot: its row, and how it launches.
    slot = c.slot, quantize = c.quantize, mode = c.slot and c.mode, legato = c.slot and c.legato,
  }
  if c.kind == "midi" then
    snap.notes = self:notes()
    if c.control_count > 0 then snap.controls = self:controls() end
  end
  return snap
end

--- Copy the clip. By default the copy goes right after the original.
function Clip:duplicate(opts)
  opts = opts or {}
  local snap = self:snapshot()
  snap.start = opts.start or (snap.start + snap.length)
  return M.restore_clip(snap, opts.track or self:track())
end

-- Automation lanes -------------------------------------------------------------
-- Fields: `target` ("volume", "pan" or "param"), `device` and `param` for a
-- parameter, `enabled`, `point_count`, `min` and `max`, `track`.

class(Lane, "Lane", api.lane_get, api.lane_set)

function Lane:get() return api.lane_get(self.id) end

function Lane:exists() return (pcall(api.lane_get, self.id)) end

function Lane:remove() api.lane_remove(self.id) end

function Lane:track() return wrap(Track, api.lane_get(self.id).track) end

--- The points as a list of { beat, value }, sorted by beat.
function Lane:points() return api.lane_points(self.id) end

--- Replace the points: `lane:set_points({ { 0, -60 }, { 8, 0 } })`. Points may
--- also be written { beat = 0, value = -60 }.
function Lane:set_points(points) api.lane_set_points(self.id, M.points(points)) end

--- Add a point, replacing any at the same beat. The value is in the target's
--- own units: dB for volume, -1 to 1 for pan, the parameter's range otherwise.
function Lane:add(beat, value) api.lane_add_point(self.id, beat, value) end

function Lane:clear() api.lane_set_points(self.id, {}) end

--- The value at a beat, whether or not the lane is on. Nil without points.
function Lane:value_at(beat) return api.lane_value_at(self.id, beat) end

-- Module ---------------------------------------------------------------------

--- Normalize automation points to { beat, value } pairs.
function M.points(points)
  local out = {}
  for i, p in ipairs(points) do out[i] = { p.beat or p[1], p.value or p[2] } end
  return out
end

--- Normalize notes: accept pitch names and fill in defaults.
function M.notes(notes)
  local out = {}
  for i, note in ipairs(notes) do
    out[i] = {
      pitch = music.pitch(note.pitch or note[1]),
      start = note.start or note[2] or 0,
      length = note.length or note[3] or 1,
      velocity = note.velocity or note[4] or daw.opt.velocity,
      meta = note.meta,
      attr = note.attr,
      -- A note given back keeps its name (`daw.address`); a new one gets one.
      id = note.id,
    }
  end
  return out
end

--- Add a clip from a snapshot to a track.
function M.restore_clip(snap, track)
  local opts = daw.util.merge(snap, {})
  opts.muted = nil
  local clip = wrap(Clip, api.clip_add(id_of(track), opts))
  if snap.muted then clip.muted = true end
  return clip
end

--- Add a device from a snapshot to a track, at the end of the chain or at
--- the 1-based `index`.
function M.restore_device(snap, track, index)
  local device = wrap(Device, api.device_add(id_of(track), snap.kind, {
    params = snap.params, state = snap.state, index = index,
  }))
  if snap.bypass then device.bypass = true end
  if snap.meta then api.device_set(device.id, "meta", snap.meta) end
  -- The track it listened to is kept while it exists and can still be
  -- listened to from here; otherwise the side-chain is dropped, and said so.
  if snap.sidechain then
    local ok = pcall(device.set_sidechain, device, snap.sidechain, { pre = snap.sidechain_pre })
    if not ok then
      daw.notify(string.format("%s no longer has its side-chain: track %s is gone or would make a loop",
        device.name, tostring(snap.sidechain)), "warn")
    end
  end
  -- So are the tracks its further output pairs played into.
  for pair, track in pairs(snap.outputs or {}) do
    if not pcall(device.set_output, device, tonumber(pair), track) then
      daw.notify(string.format("%s output pair %s no longer plays anywhere: track %s is gone or would make a loop",
        device.name, tostring(pair), tostring(track)), "warn")
    end
  end
  return device
end

function M.add_track(opts)
  if opts and opts.output then opts = daw.util.merge(opts, { output = id_of(opts.output) }) end
  return wrap(Track, api.track_add(opts))
end

function M.tracks()
  local out = {}
  for i, id in ipairs(api.track_list()) do out[i] = wrap(Track, id) end
  return out
end

--- A track by id, or by name.
function M.track(which)
  if type(which) == "number" then return wrap(Track, which) end
  for _, id in ipairs(api.track_list()) do
    if api.track_get(id).name == which then return wrap(Track, id) end
  end
end

function M.device(id) return wrap(Device, id) end
function M.clip(id) return wrap(Clip, id) end
function M.lane(id) return wrap(Lane, id) end

M.master = wrap(Track, 0)

-- `daw.project.tempo = 140`, `daw.project.save("song.json")`
M.project = setmetatable({
  new = api.project_new,
  load = api.project_load,
  save = api.project_save,
  get = api.project_get,
}, {
  __index = function(_, key) return api.project_get()[key] end,
  __newindex = function(_, key, value) api.project_set(key, value) end,
})

-- `daw.transport.play()`, `daw.transport.position`, `daw.transport.loop_enabled = true`
M.transport = setmetatable({
  play = api.transport_play,
  stop = function()
    daw.ui.poke()
    api.transport_stop()
  end,
  --- Turn recording on and play. Each armed track records a take until the
  --- transport stops or `recording` is turned off.
  record = function()
    daw.ui.poke()
    api.transport_record()
  end,
  seek = api.transport_seek,
  get = api.transport_get,
  toggle = function()
    if api.transport_get().playing then M.transport.stop() else api.transport_play() end
  end,
}, {
  __index = function(_, key) return api.transport_get()[key] end,
  __newindex = function(_, key, value)
    if key == "position" then
      api.transport_seek(value)
    elseif key == "tempo" then
      api.project_set("tempo", value)
    else
      api.transport_set(key, value)
    end
  end,
})

-- Fields set with rawset: the project's own setter takes only settings.
local discarding = false

--- Whether replacing the project now would lose work: it has changes that
--- are not saved, or it has no file and something in it. A project opened
--- from a MIDI file or a REAPER project has no changes to count, but it is
--- not on disk either, and this is every guard's one question.
rawset(M.project, "unsaved", function()
  local p = api.project_get()
  return p.modified or (p.path == nil and #api.track_list() > 0)
end)

--- Whether the project may be replaced: says why not, naming `what` (the
--- command, whose `!` form goes on anyway), when there is unsaved work.
--- `force` is for a choice made later from a list, which asked before.
rawset(M.project, "guard", function(what, force)
  if force or discarding or not M.project.unsaved() then return true end
  daw.notify(string.format("the project has unsaved work: `:w` saves it, `:%s!` goes on without it", what), "error")
  return false
end)

--- Whether a `!` command is running, for a choice made later from a list.
rawset(M.project, "discarding", function() return discarding end)

--- Define `<name>!`, which is `name` with the unsaved work thrown away.
rawset(M.project, "allow_discard", function(name)
  local spec = daw.commands.get(name)
  daw.command(name .. "!", function(ctx)
    discarding = true
    local ok, err = pcall(daw.commands.get(name).run, ctx)
    discarding = false
    if not ok then error(err, 0) end
  end, { desc = (spec.desc:gsub("%.$", "")) .. "; the unsaved work is thrown away", raw = spec.raw, complete = spec.complete })
end)

-- MIDI input -----------------------------------------------------------------

-- `daw.midi.inputs()`, `daw.midi.select({ "Keystation" })`, `daw.midi.note_on("C4", 100)`
M.midi = {
  --- Every port that can send MIDI: { id, name, open, own }.
  inputs = api.midi_inputs,
  --- A port of this program's for other programs to send MIDI to: they see
  --- it as `daw: <name>`, it is listed among the inputs with `own` set, and
  --- a track takes it by `name` like any other port. `close_port` takes it
  --- away, and says whether there was one.
  open_port = api.midi_open_port,
  close_port = api.midi_close_port,
  --- Open only the ports matching these ids or parts of names, or all of
  --- them with no argument.
  select = function(which)
    if type(which) == "string" then which = { which } end
    api.midi_select(which)
  end,
  --- Deliver an event as if it came from a MIDI port:
  --- `{ type = "note_on", pitch = "C4", velocity = 100, channel = 1 }`, or
  --- a controller move as `Clip:controls` describes them. What arrives,
  --- from here or from a port, is also the event `midi.in` for scripts.
  inject = function(event)
    if event.pitch then event = daw.util.merge(event, { pitch = music.pitch(event.pitch) }) end
    if event.key then event = daw.util.merge(event, { key = music.pitch(event.key) }) end
    api.midi_inject(event)
  end,
  --- An event as a MIDI 2.0 packet: two 32-bit words. And the other way:
  --- deliver a Universal MIDI Packet (MIDI 1.0 or 2.0) as if from a port.
  ump = function(event)
    if event.pitch then event = daw.util.merge(event, { pitch = music.pitch(event.pitch) }) end
    if event.key then event = daw.util.merge(event, { key = music.pitch(event.key) }) end
    return api.midi_ump(event)
  end,
  inject_ump = api.midi_inject_ump,
  --- The ports MIDI can be sent to, `{ id, name, own }` each: a track
  --- sends what it plays to one with `track.midi_output = { port = name,
  --- channel = 1 }` (channel nil: each message's own).
  outputs = api.midi_outputs,
  --- A port of this program's that other programs read from (`daw out:
  --- <name>`): a track sending to `name` plays a synth in another program.
  open_output = api.midi_open_output,
  close_output = api.midi_close_output,
}

function M.midi.note_on(pitch, velocity, channel)
  M.midi.inject({ type = "note_on", pitch = pitch, velocity = velocity, channel = channel })
end

function M.midi.note_off(pitch, channel)
  M.midi.inject({ type = "note_off", pitch = pitch, channel = channel })
end

-- Musical time ---------------------------------------------------------------

local time = {}
M.time = time

-- These ask the tempo map (`daw.tempo`): bars follow the signature changes
-- along the song and seconds follow the tempo changes.

--- Length in beats of the bar at beat `at` (the first bar if left out).
function time.bar(at) return api.tempo_bar_length(at or 0) end

--- Beat where bar `n` (1-based) starts.
function time.bar_start(n) return api.tempo_bar_start(n - 1) end

--- The signature (two numbers) and the tempo at a beat, as `daw.tempo` has them.
function time.signature_at(beat) return api.tempo_signature(beat or 0) end
function time.tempo_at(beat) return api.tempo_at(beat or 0) end

--- The bar (1-based) a beat is in.
function time.bar_of(beat) return api.tempo_bar_of(beat) + 1 end

--- Where the bar a beat is in starts.
function time.bar_floor(beat) return api.tempo_bar_start(api.tempo_bar_of(beat)) end

--- The first bar line at or after a beat.
function time.bar_ceil(beat)
  local start = api.tempo_bar_start(api.tempo_bar_of(beat))
  if math.abs(start - beat) < 1e-9 then return start end
  return api.tempo_bar_start(api.tempo_bar_of(beat) + 1)
end

--- The bar lines from beat `from` up to `to`: { beat, bar } each, bars
--- counting from 1.
function time.bars(from, to)
  local out = {}
  local bar = api.tempo_bar_of(math.max(0, from))
  if api.tempo_bar_start(bar) < from - 1e-9 then bar = bar + 1 end
  while #out < 10000 do
    local beat = api.tempo_bar_start(bar)
    if beat >= to then break end
    out[#out + 1] = { beat = beat, bar = bar + 1 }
    bar = bar + 1
  end
  return out
end

--- "bar.beat.hundredths" for a position in beats, counting from 1; beats
--- are of the signature's unit (an eighth in 6/8).
function time.format(beats)
  local bar, beat, frac = api.tempo_bbt(beats)
  local part = math.floor(frac * 100 + 0.5)
  if part >= 100 then part = 99 end
  return string.format("%d.%d.%02d", bar + 1, beat + 1, part)
end

--- Seconds that `beats` beats take from beat `at` (the start if left out).
function time.seconds(beats, at)
  at = at or 0
  return api.tempo_seconds(at + beats) - api.tempo_seconds(at)
end

--- Seconds from the start of the song to beat `beat`, and back.
function time.to_seconds(beat) return api.tempo_seconds(beat) end
function time.to_beat(seconds) return api.tempo_beat(seconds) end

--- "m:ss.s" for a beat's time from the start of the song.
function time.clock(beat)
  local seconds = api.tempo_seconds(beat)
  return string.format("%d:%04.1f", math.floor(seconds / 60), seconds % 60)
end

return M
