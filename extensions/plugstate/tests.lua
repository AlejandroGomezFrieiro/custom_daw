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

-- --- TONE3000 and Soundshed Guitar ---------------------------------------------
-- These plugins are not in nixpkgs: their tests run when PAW_TEST_TONE3000
-- or PAW_TEST_SOUNDSHED names the package (its store path), and the run
-- gives the plugins a scratch HOME: both keep their files in ~/.config
-- whatever XDG_CONFIG_HOME says. `tests/tools/suite.sh plugins` does both.

--- The package a variable names, when the plugin's files go to a scratch
--- folder; else nil and why the test is skipped.
local function package(var)
  local dir = os.getenv(var)
  if not dir or dir == "" then return nil, "skipped: " .. var .. " names no package" end
  -- The home folder of the user in the system's list, which a changed HOME
  -- does not hide.
  local user, home = os.getenv("USER") or os.getenv("LOGNAME") or "", nil
  for line in (io.open("/etc/passwd") and io.open("/etc/passwd"):read("*a") or ""):gmatch("[^\n]+") do
    local name, dir = line:match("^([^:]*):[^:]*:[^:]*:[^:]*:[^:]*:([^:]*):")
    if name == user then home = dir end
  end
  local now = (os.getenv("HOME") or ""):gsub("/+$", "")
  if now == "" or not home or now == home then
    return nil, "skipped: the plugin would write to the home folder (give the test run a scratch HOME)"
  end
  return dir
end

--- The loudness (RMS, 0 to 1) of a render at 16 bits, from `from` seconds:
--- a plugin that loads its model in the background in the render's own
--- copy of it plays dry for its first moments.
local function level(info, from)
  local data = T.read_file(info.path)
  local at = data:find("data", 1, true) + 8 + math.floor((from or 0) * info.sample_rate) * 4
  local sum, n = 0, 0
  for i = at, #data - 1, 2 do
    local lo, hi = data:byte(i, i + 1)
    local v = lo + hi * 256
    if v >= 32768 then v = v - 65536 end
    sum, n = sum + v * v, n + 1
  end
  return math.sqrt(sum / math.max(n, 1)) / 32768
end

local function loudness(from) return level(T.render({ tail = 0, bits = 16 }), from) end

--- A track that holds a note for two bars, with the cursor on it.
local function long_guitar(name)
  local track = T.tone(name or "guitar", 8, "A2")
  paw.cursor.set_track(track.id)
  return track
end

--- The sound after the first second (see `level`).
local function sound() return loudness(1) end

local function same(a, b, what) T.near(a, b, 0.002, what) end
local function differs(a, b, what) eq(math.abs(a - b) > 0.005, true, what .. string.format(" (%.4f, %.4f)", a, b)) end

local function devices_on(id)
  paw.ui.focus("devices")
  paw.fx.select(id)
end

test("plugstate: TONE3000 presets and block models are chosen with keys, undone, kept in snapshots and in the project", function()
  local pkg, why = package("PAW_TEST_TONE3000")
  if not pkg then return why end
  local kind = kind_of("clap", "^TONE3000$")
  if not kind then return "skipped: TONE3000 not found" end
  load()
  local t3k, juce = require("plugstate.tone3000"), require("plugstate.juce")
  local factory = pkg .. "/share/tone3000/factory-presets"

  fresh()
  local track = long_guitar()
  local amp = track:add_device(kind)
  paw.flush()
  api.undo_checkpoint()
  eq(plugstate.adapter_of(amp.id).name, "tone3000", "the TONE3000 adapter knows the plugin")
  local slot = plugstate.slot(amp.id)
  eq(slot.key, "preset", "its first slot is the preset")
  eq(#plugstate.files(slot), 8, "the eight factory presets beside the plugin")
  eq(#plugstate.slots(amp.id), 11, "and the ten blocks of its chain")
  local dry = sound()

  devices_on(amp.id)
  keys("]m")
  eq(plugstate.slot(amp.id).value, factory .. "/Ampeg Bass Drive.t3kpreset", "]m loads the first preset")
  eq(amp:get().meta.preset, "Ampeg Bass Drive", "and the device shows its name")
  local ampeg = sound()
  differs(ampeg, dry, "the preset changes the sound")
  keys("]m")
  eq(plugstate.slot(amp.id).value, factory .. "/Bogner Fullstack.t3kpreset", "]m again, the next one")
  local bogner = sound()
  differs(bogner, ampeg, "another preset, another sound")
  eq(plugstate.slot(amp.id, "block1").label:match("^Block 1 %(.+%)$") ~= nil, true, "the block says its tone")

  keys("u")
  eq(plugstate.slot(amp.id).value, factory .. "/Ampeg Bass Drive.t3kpreset", "u takes the preset back")
  same(sound(), ampeg, "and the sound")

  -- A model of a file into a block: one from a preset, written out.
  local preset = t3k.read_preset(factory .. "/Stereo Fuzz.t3kpreset")
  local cached = juce.child(juce.child(t3k.blocks(preset)[1].block, "ModelCache"), "CachedModel")
  local nam = T.scratch .. "/magnatone.nam"
  T.write_file(nam, juce.get(cached, "data").binary)
  keys(":plugstate.load slot=block2 " .. nam .. "<CR>")
  local block = plugstate.slot(amp.id, "block2")
  eq(block.value, nam, "block 2 holds the file")
  eq(block.label, "Block 2 (magnatone)", "named after it")
  local with_model = sound()
  differs(with_model, ampeg, "the model plays")
  local log = T.read_file(os.getenv("HOME") .. "/.config/TONE3000/TONE3000.log")
  eq(log:find("tone 0 model %d+ %(cached%)") ~= nil, true, "the plugin loads it from the state, not the network")

  -- Snapshots, and the project.
  keys("\\s")
  keys(":plugstate.load " .. factory .. "/Bogner Fullstack.t3kpreset<CR>")
  keys("\\s")
  eq(plugstate.current(amp.id), "B", "two snapshots, A and B")
  keys("[v")
  eq(plugstate.slot(amp.id, "block2").value, nam, "[v brings back A, with its model")
  same(sound(), with_model, "and its sound")
  local path = paw.project.save(T.scratch .. "/tone3000.json")
  fresh()
  paw.project.load(path)
  local loaded = paw.tracks()[1]:devices()[2]
  paw.flush()
  eq(plugstate.slot(loaded.id, "block2").value, nam, "the project keeps the model")
  same(sound(), with_model, "and sounds the same")
  eq(#plugstate.snapshots(loaded.id), 2, "and the snapshots")

  -- The same preset in each format of the plugin sounds the same.
  for _, format in ipairs({ "vst3", "lv2" }) do
    local other = kind_of(format, "^TONE3000$")
    if other then
      fresh()
      local d = long_guitar(format):add_device(other)
      paw.flush()
      local ok, err = plugstate.set(d.id, nil, factory .. "/Bogner Fullstack.t3kpreset")
      eq(ok, true, format .. ": " .. tostring(err))
      same(sound(), bogner, format .. ": Bogner Fullstack sounds as in CLAP")
    end
  end

  local bad, why2 = plugstate.set(amp.id, "block3", T.scratch .. "/none.nam")
  eq(bad, nil, "a file that is not there")
  eq(why2 ~= nil, true, "says why")
end)

test("plugstate: Soundshed Guitar presets of a pack, scenes and block models", function()
  local pkg, why = package("PAW_TEST_SOUNDSHED")
  if not pkg then return why end
  local kind = kind_of("vst3", "^Soundshed Guitar$")
  if not kind then return "skipped: Soundshed Guitar not found" end
  load()

  fresh()
  local track = long_guitar()
  local amp = track:add_device(kind)
  paw.flush()
  api.undo_checkpoint()
  eq(plugstate.adapter_of(amp.id).name, "soundshed", "the Soundshed adapter knows the plugin")
  local slot = plugstate.slot(amp.id)
  eq(slot.key, "preset", "its first slot is the preset")
  eq(#plugstate.files(slot), 21, "the presets of the factory pack beside the plugin")
  eq(slot.value:find("#Preset%-Pack%-Vol%.%-1__") ~= nil, true, "it plays one of them: " .. tostring(slot.value))
  -- What the plugin plays from its own library, to compare with.
  local own = sound()

  devices_on(amp.id)
  keys("]m")
  local first = plugstate.slot(amp.id).value
  eq(first ~= slot.value, true, "]m loads another preset")
  local after = sound()
  differs(after, own, "and the sound changes")
  keys(":plugstate.load black album<CR>")
  eq(amp:get().meta.preset, "Black Album (Full Rig)", "words find one preset, and it loads")
  same(sound(), own, "the preset of the pack, with its files by path, sounds as the plugin's own copy")
  eq(plugstate.slot(amp.id, "scene").value, "Rhythm", "its first scene plays")

  keys(":plugstate.load slot=scene solo<CR>")
  eq(plugstate.slot(amp.id, "scene").value, "Solo", "the scene changes")
  local solo = sound()
  differs(solo, own, "and the sound")
  keys("u")
  eq(plugstate.slot(amp.id, "scene").value, "Rhythm", "u: the scene before")
  same(sound(), own, "and its sound")

  -- A model of a file into a block.
  local amp1 = plugstate.slot(amp.id, "amp1")
  eq(amp1.what, "model", "the amp block takes a model")
  local other
  for _, f in ipairs(plugstate.files(amp1)) do
    if f.path ~= amp1.value then other = f.path end
  end
  keys(":plugstate.load slot=amp1 " .. other .. "<CR>")
  eq(plugstate.slot(amp.id, "amp1").value, other, "the block holds the file")
  local marshall = sound()
  differs(marshall, own, "and plays it")

  local path = paw.project.save(T.scratch .. "/soundshed.json")
  fresh()
  paw.project.load(path)
  local loaded = paw.tracks()[1]:devices()[2]
  paw.flush()
  eq(plugstate.slot(loaded.id, "amp1").value, other, "the project keeps it")
  same(sound(), marshall, "and sounds the same")

  local lv2 = kind_of("lv2", "^Soundshed Guitar$")
  if lv2 then
    fresh()
    local d = long_guitar("lv2"):add_device(lv2)
    paw.flush()
    local ok, err = plugstate.set(d.id, "preset", first)
    eq(ok, true, "LV2: " .. tostring(err))
    same(sound(), after, "LV2: the preset sounds as in VST3")
  end
end)


-- --- state lanes ---------------------------------------------------------------
-- A model, a preset or a snapshot on the device's state lane changes at its
-- point as the song plays and in a render. Each test measures where the
-- change lands in the rendered file.

--- The left channel of a render at 16 bits, as numbers.
local function left(info)
  local data = T.read_file(info.path)
  local at = data:find("data", 1, true) + 8
  local out = {}
  for i = at, #data - 1, 4 do
    local lo, hi = data:byte(i, i + 1)
    local v = lo + hi * 256
    out[#out + 1] = v >= 32768 and v - 65536 or v
  end
  return out
end

--- The first frame (from 0) where two renders differ by more than `by`
--- steps of 16 bits, or nil.
local function first_difference(a, b, by)
  for i = 1, math.min(#a, #b) do
    if math.abs(a[i] - b[i]) > (by or 0) then return i - 1 end
  end
end

local function rms(list, from, to)
  local sum, n = 0, 0
  for i = from + 1, math.min(to, #list) do sum, n = sum + list[i] ^ 2, n + 1 end
  return math.sqrt(sum / math.max(n, 1)) / 32768
end

local function frames_per_beat(info) return info.sample_rate * 60 / paw.tempo.at(0) end

local function render16() return T.render({ tail = 0, bits = 16 }) end

test("plugstate: a state lane switches the NAM model on the frame of a bar, in every render", function()
  local kind = kind_of("lv2", "^Neural Amp Modeler$")
  local models = os.getenv("PAW_TEST_NAM_MODELS")
  if not kind or not models then return "skipped: Neural Amp Modeler and its models not found" end
  load()
  local one, two = models .. "/BossLSTM-1x16.nam", models .. "/BossWN-feather.nam"
  fresh()
  local amp = long_guitar():add_device(kind)
  paw.flush()
  eq(plugstate.set(amp.id, nil, one), true, "the first model")
  local first = render16()
  eq(plugstate.set(amp.id, nil, two), true, "the second model")
  local second = render16()
  local a, b = left(first), left(second)

  -- The first model from the start, the second from the second bar.
  local lane = plugstate.lane_point(amp.id, 0, plugstate.lane_state(amp.id, nil, one))
  plugstate.lane_point(amp.id, 4, plugstate.lane_state(amp.id, nil, two))
  eq(#lane:states(), 2, "two states on the lane")
  eq(lane:states()[1].call.method, "property.set", "a model is a property set, which lands on its frame")
  local info = render16()
  local mixed = left(info)
  local at = math.floor(4 * frames_per_beat(info) + 0.5)
  local changed = first_difference(mixed, a, 1)
  eq(changed, at, "the sound changes on the first frame of the bar")
  eq(first_difference(left(render16()), mixed), nil, "a second render is the same, sample for sample")
  -- The new model plays from there: as the second render, once the
  -- network has heard as much of the note.
  local late = at + math.floor(info.sample_rate / 2)
  T.near(rms(mixed, late, late + 4800), rms(b, late, late + 4800), 0.002, "the second model after the bar")
end)

test("plugstate: a state lane gives sfizz another instrument through its saved state, on its frame", function()
  local kind = kind_of("vst3", "^sfizz$")
  if not kind then return "skipped: sfizz not found" end
  load()
  fresh()
  local track = paw.add_track({ name = "sfizz" })
  -- An instrument lets go of its notes when it takes a new state: a note
  -- starts a little after the point.
  track:add_clip({ start = 0, length = 4, notes = { { pitch = "A3", start = 0, length = 2 }, { pitch = "A3", start = 2.25, length = 1.75 } } })
  local sfizz = track:add_device(kind)
  paw.flush()
  local low, high = T.scratch .. "/low.sfz", T.scratch .. "/high.sfz"
  T.write_file(low, "<region> sample=*sine\n")
  T.write_file(high, "<region> sample=*sine transpose=12\n")
  local lane = plugstate.lane_point(sfizz.id, 0, plugstate.lane_state(sfizz.id, nil, low))
  plugstate.lane_point(sfizz.id, 2, plugstate.lane_state(sfizz.id, nil, high))
  eq(lane:states()[2].state ~= nil, true, "the instrument is in a saved state, which the main thread loads")
  local info = render16()
  local seconds = 2 * 60 / paw.tempo.at(0)
  T.near(T.frequency(info, 0.2, seconds - 0.05), 220, 5, "the first instrument up to the point")
  T.near(T.frequency(info, seconds * 1.15, 2 * seconds - 0.05), 440, 10, "the second from it")
  eq(first_difference(left(render16()), left(info)), nil, "a second render is the same")
end)

--- A state lane on an amp that changes only through its saved state:
--- `a` from the start and `b` from beat 8 of a held note of 16 beats.
--- Returns the renders of a and b alone, of the lane twice, and the frame
--- of the point.
local function amp_lane(kind, slot, a, b, prepare)
  fresh()
  local track = T.tone("guitar", 16, "A2")
  paw.cursor.set_track(track.id)
  local amp = track:add_device(kind)
  paw.flush()
  if prepare then prepare(amp) end
  eq(plugstate.set(amp.id, slot, a), true, "the first preset")
  local only_a = left(render16())
  eq(plugstate.set(amp.id, slot, b), true, "the second preset")
  local only_b = left(render16())
  local sa, why = plugstate.lane_state(amp.id, slot, a)
  eq(sa ~= nil, true, "a state of the first: " .. tostring(why))
  plugstate.lane_point(amp.id, 0, sa)
  plugstate.lane_point(amp.id, 8, (plugstate.lane_state(amp.id, slot, b)))
  local info = render16()
  local lane = left(info)
  local again = left(render16())
  return only_a, only_b, lane, again, math.floor(8 * frames_per_beat(info) + 0.5), info
end

test("plugstate: a state lane switches TONE3000's preset through its state, at the point, in every render", function()
  local pkg, why = package("PAW_TEST_TONE3000")
  if not pkg then return why end
  local kind = kind_of("clap", "^TONE3000$")
  if not kind then return "skipped: TONE3000 not found" end
  load()
  local factory = pkg .. "/share/tone3000/factory-presets"
  local a, b, lane, again, at, info = amp_lane(kind, nil, factory .. "/Ampeg Bass Drive.t3kpreset",
    factory .. "/Bogner Fullstack.t3kpreset")
  local changed = first_difference(lane, a, 2)
  print(string.format("      TONE3000: the sound changes at frame %s, the point is at %d", tostring(changed), at))
  eq(changed ~= nil and changed >= at and changed < at + 512, true,
    "the sound changes within a block of the point: " .. tostring(changed) .. " for " .. at)
  eq(first_difference(again, lane, 2), nil, "a second render is the same")
  local late = at + info.sample_rate
  T.near(rms(lane, late, late + 9600), rms(b, late, late + 9600), 0.003, "the second preset after the point")
  T.near(rms(lane, 9600, at - 9600), rms(a, 9600, at - 9600), 0.003, "the first before it, from the start")
end)

test("plugstate: a state lane switches Soundshed Guitar's scene through its state, at the point, in every render", function()
  local pkg, why = package("PAW_TEST_SOUNDSHED")
  if not pkg then return why end
  local kind = kind_of("vst3", "^Soundshed Guitar$")
  if not kind then return "skipped: Soundshed Guitar not found" end
  load()
  local a, b, lane, again, at, info = amp_lane(kind, "scene", "Rhythm", "Solo", function(amp)
    local found = plugstate.search(plugstate.slot(amp.id), "black album")
    eq(#found, 1, "the preset of the pack")
    eq(plugstate.set(amp.id, "preset", found[1].path), true, "a preset with scenes")
  end)
  -- Two instances of Soundshed do not give the same samples, but each
  -- render of the lane does: where the change lands is where the level
  -- leaves the first scene's, in windows of 128 frames.
  local changed
  for w = 9600, #lane - 128, 128 do
    local x, y = rms(lane, w, w + 128), rms(a, w, w + 128)
    if math.abs(x - y) > 0.3 * y then changed = w break end
  end
  print(string.format("      Soundshed: the level changes in the window from frame %s, the point is at %d", tostring(changed), at))
  -- The plugin moves to a new scene over a few milliseconds of its own.
  eq(changed ~= nil and changed >= at - 128 and changed < at + 2048, true,
    "the sound changes at the point: " .. tostring(changed) .. " for " .. at)
  eq(first_difference(again, lane, 2), nil, "a second render is the same")
  local late = at + info.sample_rate
  T.near(rms(lane, late, late + 9600), rms(b, late, late + 9600), 0.003, "the second scene after the point")
end)

--- Play from the start and wait until the playhead is past `beat` and
--- `done()` holds (four seconds at most); say whether it did.
local function plays_past(beat, done)
  api.transport_seek(0)
  api.transport_play()
  T.after(function() api.transport_stop() end)
  local deadline = api.now() + 4000
  while api.now() < deadline do
    api.wait(20)
    if api.transport_get().position > beat and done() then
      api.transport_stop()
      return true
    end
  end
  api.transport_stop()
  return false
end

test("plugstate: as the song plays, a state lane switches the NAM model and TONE3000's preset at their points", function()
  local kind = kind_of("lv2", "^Neural Amp Modeler$")
  local models = os.getenv("PAW_TEST_NAM_MODELS")
  if not kind or not models then return "skipped: Neural Amp Modeler and its models not found" end
  load()
  local one, two = models .. "/BossLSTM-1x16.nam", models .. "/BossWN-feather.nam"
  fresh()
  local amp = long_guitar():add_device(kind)
  paw.flush()
  plugstate.lane_point(amp.id, 0, plugstate.lane_state(amp.id, nil, one))
  plugstate.lane_point(amp.id, 1, plugstate.lane_state(amp.id, nil, two))
  eq(plays_past(1, function() return plugstate.slot(amp.id).value == two end), true,
    "NAM holds the second model once the playhead is past its point")
  eq(plays_past(0, function() return plugstate.slot(amp.id).value == one end), true,
    "and the first again when the song plays from the start")

  local pkg = package("PAW_TEST_TONE3000")
  local t3k = pkg and kind_of("clap", "^TONE3000$")
  if not t3k then return end
  local factory = pkg .. "/share/tone3000/factory-presets"
  local a, b = factory .. "/Ampeg Bass Drive.t3kpreset", factory .. "/Bogner Fullstack.t3kpreset"
  fresh()
  local tone = long_guitar():add_device(t3k)
  paw.flush()
  plugstate.lane_point(tone.id, 0, (plugstate.lane_state(tone.id, nil, a)))
  plugstate.lane_point(tone.id, 1, (plugstate.lane_state(tone.id, nil, b)))
  eq(plays_past(1, function() return plugstate.slot(tone.id).value == b end), true,
    "TONE3000 holds the second preset once the playhead is past its point")
end)
