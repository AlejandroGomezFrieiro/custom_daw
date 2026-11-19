-- Tests of the plugstate extension; tests/suite.lua runs them. The tests
-- with plugins need the dev shell's test plugins (`tests/tools/suite.sh
-- plugins`): Neural Amp Modeler and its sample models, LSP and sfizz.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = paw.api

local plugstate
local function load()
  if not plugstate then
    paw.ext.load("extensions/plugstate")
    plugstate = require("plugstate")
  end
  return plugstate
end

local function kind_of(format, pattern)
  for _, info in ipairs(paw.device_types()) do
    if info.format == format and info.name:find(pattern) then return info.kind end
  end
end

local function render()
  local info = T.render({ tail = 0 })
  local data = T.read_file(info.path)
  info.samples = data:sub(data:find("data", 1, true) + 8)
  return info
end

--- A track that plays one held note through the built-in synth, with the
--- cursor and the device panel on it.
local function guitar(name)
  local track = T.tone(name or "guitar", 2, "A2")
  paw.cursor.set_track(track.id)
  return track
end

--- Let a state loaded into the plugin (an undo, a recall) reach it, and
--- the plugin tell what it holds now: wait until `model` is the file the
--- slot of `device` holds (two seconds at most).
local function settle(device, model)
  paw.flush()
  for _ = 1, 100 do
    if plugstate.slot(device).value == model then return end
    api.sleep(20)
  end
end

local function keys(text)
  paw.keymap.feed(text)
  api.undo_checkpoint()
end

local function write_wav(path, frames)
  -- 16-bit mono at 48 kHz, one sample per entry of `frames` (from -1 to 1).
  local body = {}
  for i, v in ipairs(frames) do
    local n = math.floor(v * 32767 + 0.5) % 65536
    body[i] = string.char(n % 256, math.floor(n / 256))
  end
  local data = table.concat(body)
  local function le(n, size)
    local out = {}
    for i = 1, size do out[i] = string.char(math.floor(n / 256 ^ (i - 1)) % 256) end
    return table.concat(out)
  end
  T.write_file(path, "RIFF" .. le(36 + #data, 4) .. "WAVEfmt " .. le(16, 4) .. le(1, 2) .. le(1, 2)
    .. le(48000, 4) .. le(96000, 4) .. le(2, 2) .. le(16, 2) .. "data" .. le(#data, 4) .. data)
end

test("plugstate: base64 and the sfizz state codec read and write back", function()
  load()
  local bytes = require("plugstate.bytes")
  for _, text in ipairs({ "", "a", "ab", "abc", "abcd", "\0\1\255 state" }) do
    eq(bytes.decode64(bytes.encode64(text)), text, "base64 of " .. #text .. " bytes")
  end
  eq(bytes.encode64("paw"), "cGF3", "the usual alphabet")
  local codec = require("plugstate.adapters").sfizz_codec
  -- A state as paw keeps it: version 5, an empty SFZ path, then settings;
  -- then a controller state.
  local component = "\5\0\0\0\0\0\0\0" .. bytes.le32(1) .. "\0" .. "SETTINGS"
  local state = bytes.encode64(codec.join(component, "CTRL"))
  eq(codec.path(state), "", "no file yet")
  local with = codec.with_path(state, "/sfz/strings.sfz")
  eq(codec.path(with), "/sfz/strings.sfz", "the file is written in")
  local c, ctrl = codec.split(bytes.decode64(with))
  eq(c:sub(-8), "SETTINGS", "the settings after it stay")
  eq(ctrl, "CTRL", "and the controller's state")
  T.fails(function() codec.path(bytes.encode64("\1\0")) end, "not a VST3 state", "a state of another kind")
end)

test("plugstate: an amp model is chosen with keys, undone, kept in snapshots and in the project", function()
  local kind = kind_of("lv2", "^Neural Amp Modeler$")
  local models = os.getenv("PAW_TEST_NAM_MODELS")
  if not kind or not models then return "skipped: Neural Amp Modeler and its models not found" end
  load()
  local folders = paw.opt.plugstate_folders
  paw.opt.plugstate_folders = models
  T.after(function() paw.opt.plugstate_folders = folders end)

  fresh()
  local track = guitar()
  local amp = track:add_device(kind)
  paw.flush()
  api.undo_checkpoint()
  eq(plugstate.adapter_of(amp.id).name, "nam", "the NAM adapter knows the plugin")
  local slot = plugstate.slot(amp.id)
  eq(slot.what, "model", "it holds a model")
  eq(#plugstate.files(slot), 6, "the six models of the folder")
  eq(#plugstate.search(slot, "lstm 2x"), 2, "found by words")
  local words = require("plugstate.adapters").nam_words(models .. "/BossWN-feather.nam")
  eq(words:find("WaveNet", 1, true) ~= nil, true, "a .nam file says what it is: " .. words)

  local dry = render()
  paw.ui.focus("devices")
  paw.fx.select(amp.id)
  keys("]m")
  eq(plugstate.slot(amp.id).value, models .. "/BossLSTM-1x16.nam", "]m loads the first model")
  eq(amp:get().meta.preset, "BossLSTM-1x16", "and the device shows its name")
  local first = render()
  eq(first.samples ~= dry.samples, true, "the model changes the sound")
  keys("]m")
  eq(plugstate.slot(amp.id).value, models .. "/BossLSTM-1x24.nam", "]m again, the next one")
  local second = render()
  eq(second.samples ~= first.samples, true, "another model, another sound")

  keys("u")
  settle(amp.id, models .. "/BossLSTM-1x16.nam")
  eq(plugstate.slot(amp.id).value, models .. "/BossLSTM-1x16.nam", "u takes the model back, in the plugin too")
  eq(render().samples, first.samples, "and the sound")

  keys("\\s")
  keys("]m")
  keys("\\s")
  eq(#plugstate.snapshots(amp.id), 2, "two snapshots kept")
  eq(plugstate.current(amp.id), "B", "named A and B")
  keys("[v")
  settle(amp.id, models .. "/BossLSTM-1x16.nam")
  eq(plugstate.current(amp.id), "A", "[v brings back the one before")
  eq(plugstate.slot(amp.id).value, models .. "/BossLSTM-1x16.nam", "with its model")
  eq(render().samples, first.samples, "and its sound")
  keys("u")
  settle(amp.id, models .. "/BossLSTM-1x24.nam")
  eq(plugstate.current(amp.id), "B", "u after a recall: one undo step")
  eq(render().samples, second.samples, "the sound of B again")

  local path = paw.project.save(T.scratch .. "/plugstate.json")
  fresh()
  paw.project.load(path)
  local loaded = paw.tracks()[1]:devices()[2]
  settle(loaded.id, models .. "/BossLSTM-1x24.nam")
  eq(#plugstate.snapshots(loaded.id), 2, "the snapshots are in the project")
  eq(plugstate.slot(loaded.id).value, models .. "/BossLSTM-1x24.nam", "the model comes back")
  eq(render().samples, second.samples, "and sounds the same")

  -- The same model set in a new device sounds the same: the change is the
  -- model, not some other part of the state.
  fresh()
  local other = guitar("other"):add_device(kind)
  paw.flush()
  local ok, err = plugstate.set(other.id, nil, models .. "/BossLSTM-1x16.nam")
  eq(ok, true, "set from Lua: " .. tostring(err))
  eq(render().samples, first.samples, "a new amp with that model sounds as the first did")
  local bad, why = plugstate.set(other.id, nil, models .. "/none.nam")
  eq(bad, nil, "a file that is not there")
  eq(why:find("no file", 1, true) ~= nil, true, "says so: " .. tostring(why))
end)

test("plugstate: an impulse response file goes into LSP's convolver", function()
  local kind = kind_of("lv2", "^LSP Impulse Responses Stereo$")
  if not kind then return "skipped: test plugins not found" end
  load()
  fresh()
  local track = guitar("room")
  local ir = track:add_device(kind)
  paw.flush()
  eq(plugstate.adapter_of(ir.id).name, "lsp-ir", "the LSP adapter knows the plugin")
  local slots = plugstate.slots(ir.id)
  eq(#slots, 2, "two impulse response files")
  eq(slots[1].what, "impulse response", "in the words of the user")
  local before = render()
  -- An impulse response that is a click after 10 ms.
  local frames = {}
  for i = 1, 4800 do frames[i] = i == 481 and 0.9 or 0 end
  local file = T.scratch .. "/click.wav"
  write_wav(file, frames)
  local ok, err = plugstate.set(ir.id, slots[1].key, file)
  eq(ok, true, "set: " .. tostring(err))
  eq(plugstate.slots(ir.id)[1].value, file, "the plugin holds the file")
  eq(render().samples ~= before.samples, true, "and the sound changes")
end)

test("plugstate: a state codec gives sfizz (VST3) another instrument", function()
  local kind = kind_of("vst3", "^sfizz$")
  if not kind then return "skipped: sfizz not found" end
  load()
  fresh()
  local track = paw.add_track({ name = "sfizz" })
  track:add_clip({ start = 0, length = 4, notes = { { pitch = "A3", start = 0, length = 4 } } })
  local sfizz = track:add_device(kind)
  paw.flush()
  eq(plugstate.adapter_of(sfizz.id).name, "sfizz", "the sfizz adapter knows the plugin")
  local low, high = T.scratch .. "/low.sfz", T.scratch .. "/high.sfz"
  T.write_file(low, "<region> sample=*sine\n")
  T.write_file(high, "<region> sample=*sine transpose=12\n")
  eq(plugstate.set(sfizz.id, nil, low), true, "the first instrument")
  eq(plugstate.slot(sfizz.id).value, low, "is in the state")
  local a = T.render({ tail = 0, bits = 16 })
  eq(plugstate.set(sfizz.id, nil, high), true, "the second")
  local b = T.render({ tail = 0, bits = 16 })
  T.near(T.frequency(a, 0.5, 1.5), 220, 5, "the first plays the note")
  T.near(T.frequency(b, 0.5, 1.5), 440, 10, "the second an octave higher")
end)
