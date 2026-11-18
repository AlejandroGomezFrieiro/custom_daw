-- The how-to guides of the user guide about rendering and sharing, and about
-- projects and files, each driven with the keys and commands that it gives.
-- Loaded by tests/suite.lua with its helpers. The guides that load an
-- extension run last (`T.last`), so that its commands do not reach the other tests.
local T = ...
local test, eq, near, fresh = T.test, T.eq, T.near, T.fresh
local api = paw.api

local function keys(text)
  paw.keymap.feed(text)
  api.undo_checkpoint()
end

local function start()
  fresh()
  paw.keymap.feed("<Esc><Esc>")
  while paw.ui.float do paw.ui.close() end
  paw.ui.focus("arrange")
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() end
  return f ~= nil
end

--- Wait for a render started in the background.
local function rendered(path)
  local deadline = api.now() + 30000
  while (api.render_status() or not exists(path)) and api.now() < deadline do paw.wait(20) end
  eq(exists(path), true, "the file " .. path)
end

local function dir(name)
  local d = T.scratch .. "/" .. name
  os.execute("mkdir -p '" .. d .. "'")
  return d
end

test("guide: export a song as WAV, FLAC or MP3", function()
  start()
  T.tone("Lead", 8)
  local d = dir("export")
  paw.project.save(d .. "/song.json")
  keys(":render<CR>")
  rendered(d .. "/song.wav")
  eq(paw.render_tags().title, nil, "no tags set")
  keys(":render " .. d .. "/mix.flac<CR>")
  rendered(d .. "/mix.flac")
  -- A name alone goes next to the project.
  keys(":render guide-export-test.wav<CR>")
  rendered(d .. "/guide-export-test.wav")
  keys(":render.tags artist=Ana album=\"First one\" year=2026<CR>")
  eq(paw.render_tags().artist .. "/" .. paw.render_tags().album, "Ana/First one", ":render.tags sets the tags")
  local mp3
  for _, f in ipairs(api.render_formats()) do
    if f.name == "MP3" then mp3 = f.available end
  end
  if mp3 then
    keys(":render " .. d .. "/mix.mp3 quality=best<CR>")
    rendered(d .. "/mix.mp3")
  end
end)

--- The length of a WAV file in seconds.
local function seconds(path)
  local data = T.read_file(path)
  local function u32(at) local a, b, c, d = data:byte(at, at + 3) return a + b * 256 + c * 65536 + d * 16777216 end
  local rate, bytes = u32(25), u32(29)
  local at = data:find("data", 37, true)
  return u32(at + 4) / bytes, rate
end

test("guide: export part of the song or a loop", function()
  start()
  paw.project.tempo = 120
  T.tone("Lead", 32)
  local d = dir("part")
  paw.project.save(d .. "/song.json")
  paw.ui.focus("arrange")
  paw.cursor.set_track(paw.tracks()[1])
  keys("3|gl2W")
  eq(paw.transport.loop_start .. "-" .. paw.transport.loop_end, "8-16", "gl2W loops two bars")
  keys(":render " .. d .. "/loop.wav range=loop tail=0<CR>")
  rendered(d .. "/loop.wav")
  near(seconds(d .. "/loop.wav"), 4, 0.01, "range=loop renders the loop")
  keys("5|v2W")
  keys(":render " .. d .. "/sel.wav range=selection tail=0<CR>")
  rendered(d .. "/sel.wav")
  near(seconds(d .. "/sel.wav"), 4, 0.01, "range=selection renders the selection")
  keys("<Esc>5|v2W")
  keys(":region Verse<CR>")
  local region = paw.markers.list()[1]
  eq(region.name .. " " .. region.beat .. "+" .. region.length, "Verse 16+8", ":region names the selection")
  keys("<Esc>")
  keys(":render " .. d .. "/verse.wav range=Verse tail=0<CR>")
  rendered(d .. "/verse.wav")
  near(seconds(d .. "/verse.wav"), 4, 0.01, "range=Verse renders the region")
  keys(":render.regions " .. d .. "/regions<CR>")
  rendered(d .. "/regions/01 Verse.wav")
end)

test("guide: export MIDI for another program", function()
  start()
  local lead = T.tone("Lead", 8, "A4")
  local bass = T.tone("Bass", 8, "A2")
  bass:clips()[1]:add_note({ pitch = "E2", start = 4, length = 2 })
  local d = dir("midiout")
  paw.ui.focus("arrange")
  paw.cursor.set_track(lead)
  keys(":export " .. d .. "/song.mid<CR>")
  eq(exists(d .. "/song.mid"), true, ":export writes the song")
  keys(":open! " .. d .. "/song.mid<CR>")
  eq(paw.project.path, nil, "the MIDI file opens as a new project")
  eq(#paw.tracks(), 2, "with its two tracks")
  eq(#paw.tracks()[2]:clips()[1]:notes(), 2, "and their notes")
  paw.ui.focus("arrange")
  paw.cursor.set_track(paw.tracks()[2])
  paw.cursor.set_beat(0)
  keys(":export " .. d .. "/riff.mid clip<CR>")
  local function parts(path)
    local out = {}
    for _, part in ipairs(paw.midifile.parts(paw.midifile.read(path))) do out[#out + 1] = part.name .. ":" .. #part.notes end
    return table.concat(out, " ")
  end
  eq(parts(d .. "/riff.mid"), "Bass:2", ":export clip writes the clip at the cursor")
  keys("ggVj")
  keys(":export " .. d .. "/part.mid selection<CR>")
  keys("<Esc>")
  eq(parts(d .. "/part.mid"), "Lead:1 Bass:2", ":export selection writes the selected tracks")
end)

T.last("guide: open a REAPER project, and save one for REAPER", function()
  start()
  T.tone("Lead", 8)
  local d = dir("reaper")
  paw.project.save(d .. "/song.json")
  keys(":ext.load rpp<CR>")
  keys(":w " .. d .. "/song.rpp<CR>")
  eq(exists(d .. "/song.rpp"), true, ":w song.rpp writes a REAPER project")
  local page = table.concat(api.ui_snapshot(100, 30), "\n")
  eq(page:find("Not written to song.rpp", 1, true) ~= nil, true, "a page lists what REAPER cannot take")
  keys("q")
  eq(paw.ui.focused, "arrange", "q closes the page")
  eq(paw.project.path, d .. "/song.json", "the project stays where it was")
  keys(":e " .. d .. "/song.rpp<CR>")
  eq(paw.project.path, nil, ":e song.rpp opens the REAPER project as a new project")
  eq(#paw.tracks(), 1, "with its tracks")
  eq(paw.tracks()[1].name .. " " .. #paw.tracks()[1]:clips()[1]:notes(), "Lead 1", "with its tracks and notes")
  keys(":w " .. d .. "/from-reaper.json<CR>")
  eq(exists(d .. "/from-reaper.json"), true, ":w saves it as a project of paw")
  eq(#paw.tracks()[1]:devices(), 0, "the synth stayed behind")
  keys(":rpp.import " .. d .. "/song.rpp merge=true<CR>")
  eq(#paw.tracks(), 2, "merge=true adds the tracks to the project")
  keys(":w<CR>")
  keys(":rpp.import " .. d .. "/song.rpp instrument=synth<CR>")
  eq(#paw.tracks(), 1, "rpp.import replaces the project")
  eq(paw.tracks()[1]:devices()[1].kind, "synth", "instrument=synth gives the MIDI track an instrument")
end)
