-- Tests of the sampler extension; tests/suite.lua runs them. Those that
-- play need the plugin built and on the plugin path, as
-- extensions/sampler/native/test.sh runs them; elsewhere they are skipped.
local T = ...
local test, eq, near, fresh = T.test, T.eq, T.near, T.fresh
local api = paw.api

local sampler
local function load()
  if not sampler then
    paw.ext.load("extensions/sampler")
    sampler = require("sampler")
  end
  return sampler
end

local function write(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

-- The fixture instruments (sines of known pitches), written by the
-- plugin's own command; nil when it is not built.
local fixtures
local function fixture_dir()
  if fixtures == nil then
    local loaded = paw.ext.loaded.sampler
    local cli = loaded and (loaded.path .. "/bin/paw-sampler")
    local dir = T.scratch .. "/sampler-fixtures"
    fixtures = cli and os.execute("'" .. cli .. "' fixtures '" .. dir .. "' 2>/dev/null") == 0 and dir or false
  end
  return fixtures or nil
end

--- Wait for a device to be running again (a project opened, a state put back).
local function running(device)
  for _ = 1, 400 do
    if api.device_get(device).status == "running" then return device end
    paw.wait(50)
  end
  return device
end

--- A sampler track with one of the fixtures loaded, or a reason to skip.
local function sampler_track(instrument)
  local s = load()
  if not s.available() then return nil, "the sampler plugin is not on the plugin path" end
  local dir = fixture_dir()
  if not dir then return nil, "extensions/sampler/bin/paw-sampler is not built" end
  fresh()
  local track = paw.add_track({ name = "Strings" })
  paw.track_kinds.set(track, "sampler", { path = dir .. "/" .. instrument, ask = false })
  api.undo_checkpoint()
  return track, s.device_of(track.id)
end

-- Without the plugin -------------------------------------------------------------

test("sampler: instruments are found in the library folders, by name, format and folder", function()
  local s = load()
  local root = T.scratch .. "/sampler-library"
  os.execute("mkdir -p '" .. root .. "/Strings/Violins' '" .. root .. "/.hidden'")
  write(root .. "/Strings/Violins/Violins KS.sfz", "<region> sample=*sine\n")
  write(root .. "/Strings/Cello.dspreset", "<DecentSampler/>\n")
  write(root .. "/Strings/notes.txt", "")
  write(root .. "/.hidden/Secret.sfz", "")
  local found = s.instruments({ root })
  eq(#found, 2, "two instruments")
  eq(found[1].name .. "|" .. found[1].format .. "|" .. found[1].folder, "Cello|dspreset|Strings", "the first")
  eq(found[2].name .. "|" .. found[2].folder, "Violins KS|Strings/Violins", "the second")
end)

test("sampler: an instrument is summed up by name, format and articulations", function()
  local s = load()
  eq(s.summary({ name = "Violins", format = "sfz", articulations = { {}, {}, {} } }), "Violins · SFZ · 3 articulations", "with articulations")
  eq(s.summary({ name = "Piano", format = "dspreset", articulations = {} }), "Piano · Decent Sampler", "without")
  eq(s.summary({ name = "", path = "", articulations = {} }), "no instrument yet", "empty")
  eq(s.summary({ path = "/x.sfz", error = "missing" }), "cannot read /x.sfz", "missing")
end)

test("sampler: the phrase a picker plays stays inside the instrument's range", function()
  local s = load()
  for _, range in ipairs({ { 55, 105 }, { 36, 40 }, { 60, 60 } }) do
    for _, n in ipairs(s.phrase({ range = range })) do
      assert(n.pitch >= range[1] and n.pitch <= range[2], n.pitch .. " outside " .. range[1] .. "-" .. range[2])
    end
  end
end)

test("sampler: a sampler track is a kind of track, S in the header", function()
  load()
  local kind = paw.track_kinds.kinds.sampler
  eq(kind and kind.letter, "S", "the letter")
  eq(kind.title, "Sampler track", "the title")
end)

-- With the plugin ----------------------------------------------------------------

test("sampler: a sampler track plays an SFZ instrument at the keys' pitches", function()
  local track, why = sampler_track("basic.sfz")
  if not track then return why end
  track:add_clip({ start = 0, length = 4, notes = {
    { pitch = 57, start = 0, length = 1, velocity = 127 },
    { pitch = 69, start = 2, length = 1, velocity = 127 },
  } })
  local info = T.render({ bits = 16, tail = 0, ["end"] = 4 })
  near(T.frequency(info, 0.05, 0.45), 220, 6, "A3")
  near(T.frequency(info, 1.05, 1.45), 440, 8, "A4")
end)

test("sampler: describe gives keyswitches and articulations with their M2-123 codes, and K says so", function()
  local track, device = sampler_track("ks.sfz")
  if not track then return device end
  local d = sampler.describe(device)
  eq(d.format, "sfz", "format")
  eq(d.range[1] .. "-" .. d.range[2], "48-96", "range")
  eq(#d.keyswitches, 2, "keyswitches")
  eq(d.articulations[2].name .. " " .. d.articulations[2].m2 .. " " .. d.articulations[2].keyswitch, "Staccato 11.0 25", "staccato")
  eq(paw.track_kinds.describe(track.id), "Sampler track · ks · SFZ · 2 articulations", "what K and the header say")
end)

test("sampler: a keyswitch note chooses the articulation in a render", function()
  local track = sampler_track("ks.sfz")
  if not track then return "the sampler is not built" end
  track:add_clip({ start = 0, length = 8, notes = {
    { pitch = 69, start = 0, length = 1, velocity = 100 },
    { pitch = 25, start = 2, length = 0.25, velocity = 100 },
    { pitch = 69, start = 2, length = 1, velocity = 100 },
    { pitch = 69, start = 4, length = 1, velocity = 100 },
  } })
  local info = T.render({ bits = 16, tail = 0, ["end"] = 6 })
  near(T.frequency(info, 0.05, 0.45), 440, 8, "sustain by default")
  near(T.frequency(info, 1.05, 1.45), 660, 10, "staccato after its keyswitch")
  near(T.frequency(info, 2.05, 2.45), 660, 10, "and it sticks")
end)

test("sampler: loading an instrument is one undo step, kept with the project", function()
  local track, device = sampler_track("basic.sfz")
  if not track then return device end
  sampler.load(device, fixture_dir() .. "/rr.sfz")
  eq(sampler.describe(device).name, "rr", "loaded")
  eq(api.device_get(device).meta.preset, "rr", "named as the device's preset")
  paw.cmd("undo")
  paw.flush()
  eq(sampler.describe(running(device)).name, "basic", "undo takes the load back")
  local path = T.scratch .. "/sampler-project.json"
  paw.project.save(path)
  paw.open(path)
  local again = running(sampler.device_of(paw.tracks()[1].id))
  eq(sampler.describe(again).name, "basic", "the project brings it back")
end)

test("sampler: an instrument heard in a trial is taken back without a trace", function()
  local track, device = sampler_track("basic.sfz")
  if not track then return device end
  local d = paw.audition.try(function() return sampler.load(device, fixture_dir() .. "/vel.sfz") end)
  eq(d.name, "vel", "heard")
  paw.audition.stop()
  paw.flush()
  eq(sampler.describe(running(device)).name, "basic", "put back")
end)

test("sampler: the picker lists the library, hears the instrument under the selection, and Escape puts the old one back", function()
  local track, device = sampler_track("basic.sfz")
  if not track then return device end
  local before = paw.opt.sampler_libraries
  T.after(function()
    paw.opt.sampler_libraries = before
    paw.keymap.feed("<Esc><Esc>")
  end)
  paw.opt.sampler_libraries = fixture_dir()
  paw.cmd("sampler.load")
  local screen = table.concat(api.ui_snapshot(120, 30), "\n")
  assert(screen:find("Instruments", 1, true), "the picker is open:\n" .. screen)
  assert(screen:find("ks%s+DS") and screen:find("ks%s+SFZ"), "it lists the fixtures in both formats:\n" .. screen)
  paw.keymap.feed("vel")
  local limit = api.now() + 5000
  while api.now() < limit and sampler.known(device).name ~= "vel" do paw.wait(20) end
  eq(sampler.known(device).name, "vel", "heard: loaded as a trial")
  screen = table.concat(api.ui_snapshot(120, 30), "\n")
  assert(screen:find("vel · SFZ", 1, true), "the pane says what plays:\n" .. screen)
  paw.keymap.feed("<Esc>")
  paw.flush()
  eq(sampler.describe(running(device)).name, "basic", "Escape puts the old one back")
end)
