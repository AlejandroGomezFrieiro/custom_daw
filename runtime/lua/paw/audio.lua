-- `paw.audio`: which audio devices are open, and what each track takes in.
--
--   paw.audio.devices()                         -- { outputs = {...}, inputs = {...}, output, input }
--   paw.audio.use({ output = "UR22", input = "UR22", buffer = 128 })
--   paw.audio.levels()                          -- each input channel's level, 0 to 1
--   paw.audio.choices(track)                    -- what a track's input can be, for a menu or a picker
--   paw.audio.choose(track, choice)             -- take one of them
--
-- The lists and what each choice means live here, so that the terminal and
-- the window offer the same and mean the same by it.
local api = paw.api
local M = {}

--- Every device the system offers: `outputs` and `inputs`, each a list of
--- `{ name, id, channels, sample_rate, min_block, max_block }`, and the
--- names of the `output` and `input` that are open.
M.devices = api.audio_devices

--- Open other devices: `output` and `input` by name or part of one
--- (`"default"` for the system's), `buffer` in frames (0 for the device's
--- own), `rate` in Hz (0 for the device's own), `backend` the sound system
--- (`"auto"`, `"pipewire"`, `"alsa"`, `"jack"`). What is left out stays. The choice belongs to this machine and is
--- remembered for the next run; a name that matches nothing is an error.
function M.use(opts)
  api.audio_use(opts or {})
end

--- The level of each of the input device's channels, as linear gain.
M.levels = api.input_levels

--- Block sizes offered where the device is chosen.
M.blocks = { 32, 64, 128, 256, 512, 1024, 2048 }

--- A device's name made short enough for a track header: the maker's name
--- goes when a model number follows it, and so does a trailing number.
---   "Steinberg UR22mkII 0" → "UR22mkII", "Bose NC 700 HP" → "Bose NC 700 HP"
function M.short(name)
  if not name or name == "" or name == "none" then return nil end
  local words = {}
  for word in name:gmatch("%S+") do words[#words + 1] = word end
  if #words > 1 and words[#words]:match("^%d+$") then table.remove(words) end
  if #words > 1 and words[2]:match("%a") and words[2]:match("%d") and not words[1]:match("%d") then table.remove(words, 1) end
  local short = table.concat(words, " ")
  if #short > 18 then short = short:sub(1, 17) .. "…" end
  return short
end

--- The input device's short name, or nil when there is none.
function M.device()
  local e = api.engine_get()
  if e.input_channels == 0 then return nil end
  return M.short(e.input_device) or "input"
end

local function midi_text(midi)
  local port = midi.port and M.short(midi.port:match("^[^:]*:%s*(.+)$") or midi.port) or "all ports"
  return midi.channel and (port .. " · ch " .. midi.channel) or port
end

--- What a track takes in, in a few words: `UR22mkII · 1/2` for audio,
--- `MIDI · Keystation · ch 1` for MIDI from one port. Nil for a track that
--- takes nothing in particular: no audio, and MIDI from everywhere.
function M.label(t)
  if t.input then
    return (M.device() or "no input") .. " · " .. t.input
  end
  if t.midi_input then return "MIDI · " .. midi_text(t.midi_input) end
  return nil
end

--- The level of what arrives at a track's audio input, 0 to 1, whether or
--- not the track is armed or monitored; 0 for a track without one.
function M.level(t, levels)
  if not t.input then return 0 end
  levels = levels or M.levels()
  local first, second = t.input:match("^(%d+)/?(%d*)$")
  first = tonumber(first)
  local level = levels[first] or 0
  if second ~= "" then level = math.max(level, levels[tonumber(second)] or 0) end
  return level
end

--- Everything a track's input can be, in order, under three headings
--- (`group`): "audio" (none, each channel of the input device, each pair of
--- neighbouring channels), "midi" (every port, or one) and "channel" (every
--- MIDI channel, or one). Each is `{ group, label, checked, value }`; give it
--- to `M.choose`. A choice that is saved but not there now is listed too,
--- marked as missing, so that it can be seen and changed.
function M.choices(track)
  local t = type(track) == "table" and track.id and api.track_get(track.id) or api.track_get(track)
  local out = {}
  local function add(group, label, value, checked)
    out[#out + 1] = { group = group, label = label, value = value, checked = checked and true or false }
  end
  local device = M.device()
  local n = api.engine_get().input_channels
  add("audio", "No audio input", { input = "none" }, t.input == nil)
  local listed = {}
  for ch = 1, n do
    listed[tostring(ch)] = true
    add("audio", device .. " · " .. ch, { input = tostring(ch) }, t.input == tostring(ch))
  end
  for ch = 1, n - 1 do
    local spec = ch .. "/" .. ch + 1
    listed[spec] = true
    add("audio", device .. " · " .. spec, { input = spec }, t.input == spec)
  end
  if t.input and not listed[t.input] then
    add("audio", (device or "input") .. " · " .. t.input .. " (the device has no such channel)", { input = t.input }, true)
  end

  local midi = t.midi_input or {}
  add("midi", "All MIDI ports", { midi_port = false }, not midi.port)
  local seen = false
  for _, port in ipairs(paw.midi.inputs()) do
    seen = seen or port.name == midi.port
    add("midi", port.name, { midi_port = port.name }, port.name == midi.port)
  end
  if midi.port and not seen then
    add("midi", midi.port .. " (not connected)", { midi_port = midi.port }, true)
  end
  add("channel", "Every channel", { midi_channel = false }, not midi.channel)
  for ch = 1, 16 do
    add("channel", "Channel " .. ch, { midi_channel = ch }, midi.channel == ch)
  end

  -- Where it sends what it plays, and on which channel.
  local sent = t.midi_output or {}
  add("midi_out", "None", { midi_out = false }, not sent.port)
  local found = false
  for _, port in ipairs(paw.midi.outputs()) do
    found = found or port.name == sent.port
    add("midi_out", port.name, { midi_out = port.name }, port.name == sent.port)
  end
  if sent.port and not found then
    add("midi_out", sent.port .. " (not connected)", { midi_out = sent.port }, true)
  end
  add("midi_out_channel", "Each message's own", { midi_out_channel = false }, not sent.channel)
  for ch = 1, 16 do
    add("midi_out_channel", "Channel " .. ch, { midi_out_channel = ch }, sent.channel == ch)
  end
  -- What it becomes at a port that takes no MIDI 2.0.
  for _, form in ipairs(paw.routes.midi_out_form_order) do
    local label = paw.routes.midi_out_forms[form]
    add("midi_out_form", label:sub(1, 1):upper() .. label:sub(2), { midi_out_form = form }, (sent.form or "auto") == form)
  end
  return out
end

--- Take a choice from `M.choices`. A MIDI port or channel is only heard on
--- a track without audio input, so choosing one takes the audio input away.
function M.choose(track, choice)
  local id = type(track) == "table" and track.id or track
  local value = choice.value or choice
  if value.input then
    api.track_set(id, "input", value.input)
  end
  if value.midi_port ~= nil or value.midi_channel ~= nil then
    local midi = api.track_get(id).midi_input or {}
    local port, channel = midi.port, midi.channel
    if value.midi_port ~= nil then port = value.midi_port or nil end
    if value.midi_channel ~= nil then channel = value.midi_channel or nil end
    api.track_set(id, "input", "none")
    api.track_set(id, "midi_input", (port or channel) and { port = port, channel = channel } or nil)
  end
  -- A channel without a port waits for one.
  if value.midi_out ~= nil or value.midi_out_channel ~= nil or value.midi_out_form ~= nil then
    local sent = api.track_get(id).midi_output or {}
    local port, channel, form = sent.port, sent.channel, sent.form
    if value.midi_out ~= nil then port = value.midi_out or nil end
    if value.midi_out_channel ~= nil then channel = value.midi_out_channel or nil end
    if value.midi_out_form ~= nil then form = value.midi_out_form end
    api.track_set(id, "midi_output", port and { port = port, channel = channel, form = form, members = sent.members } or nil)
  end
end

--- The engine in a few words, for the transport bar: `pipewire · UR22mkII · 48 kHz`.
function M.summary()
  local e = api.engine_get()
  -- A device that went away is what matters most.
  if e.lost then return "lost: " .. (M.short(e.lost.device) or e.lost.device) .. " · no sound" end
  local parts = { e.backend }
  local out = M.short(e.device)
  if e.backend ~= "null" and out then parts[#parts + 1] = out end
  parts[#parts + 1] = string.format("%g kHz", e.sample_rate / 1000)
  return table.concat(parts, " · ")
end

--- Sample rate, block size and latencies in one line.
function M.timing()
  local e = api.engine_get()
  local block = e.block > 0 and e.block or e.buffer_size
  local parts = { string.format("%g kHz", e.sample_rate / 1000) }
  parts[#parts + 1] = block > 0 and (block .. " frames") or "block set by the device"
  if e.backend ~= "null" then
    parts[#parts + 1] = string.format("in %.1f ms", e.input_latency)
    parts[#parts + 1] = string.format("out %.1f ms", e.output_latency)
  end
  return table.concat(parts, " · ")
end

--- What can be chosen where the devices are: under the headings (`group`)
--- "output", "input", "block", "rate" and "backend" (the sound system),
--- each `{ group, label, checked, value }`
--- for `M.choose_engine`, and `info` lines that cannot be chosen.
function M.engine_choices()
  local list = M.devices()
  local out = {}
  local function add(group, label, value, checked)
    out[#out + 1] = { group = group, label = label, value = value, checked = checked and true or false }
  end
  add("info", list.backend .. " · " .. M.timing())
  add("output", "System default", { output = "default" }, list.output_id == "" and list.backend ~= "null")
  for _, d in ipairs(list.outputs) do
    add("output", string.format("%s  (%d ch)", d.name, d.channels), { output = d.name }, d.name == list.output and list.output_id ~= "")
  end
  add("input", "System default", { input = "default" }, list.input_id == "" and list.backend ~= "null")
  for _, d in ipairs(list.inputs) do
    add("input", string.format("%s  (%d ch)", d.name, d.channels), { input = d.name }, d.name == list.input)
  end
  local e = api.engine_get()
  add("block", "Device's own", { buffer = 0 }, list.buffer_size == 0)
  for _, frames in ipairs(M.blocks) do
    add("block", string.format("%d frames (%.1f ms)", frames, frames * 1000 / e.sample_rate), { buffer = frames }, list.buffer_size == frames)
  end
  for _, rate in ipairs(list.rates or {}) do
    add("rate", string.format("%g kHz", rate / 1000), { rate = rate }, list.sample_rate == rate)
  end
  for _, name in ipairs(list.backends or {}) do
    add("backend", name == "auto" and "Automatic (the first that works)" or name, { backend = name }, name == e.backend)
  end
  return out
end

--- Take a choice from `M.engine_choices`.
function M.choose_engine(choice)
  local value = choice.value or choice
  if not value or next(value) == nil then return end
  M.use(value)
  local e = api.engine_get()
  paw.notify(string.format("audio: %s → %s, %s", e.input_device, e.device, M.timing()))
end

return M
