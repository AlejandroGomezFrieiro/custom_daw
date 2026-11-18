-- The how-to guides of the user guide about projects and files, each driven
-- with the keys and commands that it gives (docs/how-to/save-and-open-projects.md,
-- import-audio-and-midi-files.md, use-track-templates.md). Loaded by
-- tests/suite.lua with its helpers.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = paw.api

local function keys(text)
  paw.keymap.feed(text)
  api.undo_checkpoint()
  paw.flush()
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

local function dir(name)
  local d = T.scratch .. "/" .. name
  os.execute("mkdir -p '" .. d .. "'")
  return d
end

test("guide: save, back up and open projects", function()
  start()
  local d = dir("projects")
  paw.recent.use(d .. "/recent.json")
  T.after(function() paw.recent.use() end)
  T.tone("Lead", 8)
  paw.ui.focus("arrange")
  keys(":w " .. d .. "/song.json<CR>")
  eq(exists(d .. "/song.json"), true, ":w song.json saves the project")
  eq(paw.project.unsaved(), false, "with nothing left to save")
  keys("3-")
  eq(paw.project.unsaved(), true, "an edit is not saved")
  keys(":w<CR>")
  eq(exists(d .. "/song.json.bak"), true, ":w keeps the file before as song.json.bak")
  keys(":new<CR>")
  eq(#paw.tracks() .. " " .. tostring(paw.project.path), "0 nil", ":new starts an empty project")
  T.tone("Bass", 4)
  keys(":w " .. d .. "/second.json<CR>")
  keys(",fR")
  eq(paw.ui.float ~= nil, true, ",fR lists the recent projects")
  keys("song<CR>")
  eq(paw.project.path, d .. "/song.json", "and opens the one chosen")
  keys(":recent 2<CR>")
  eq(paw.project.path, d .. "/second.json", ":recent 2 opens the second newest")
  keys(":e " .. d .. "/song.json<CR>")
  eq(paw.project.path, d .. "/song.json", ":e opens a project by its path")
  keys("3-")
  keys(":e " .. d .. "/second.json<CR>")
  eq(paw.project.path, d .. "/song.json", ":e refuses to drop work that is not saved")
  keys(":edit! " .. d .. "/second.json<CR>")
  eq(paw.project.path, d .. "/second.json", ":edit! drops it and opens the other project")
  keys(":set autosave 30<CR>")
  eq(paw.opt.autosave, 30, ":set autosave 30 makes a safety copy every 30 seconds")
  paw.opt.autosave = 0
end)

test("guide: import audio and MIDI files", function()
  start()
  local lib = dir("library")
  -- A sound file and a MIDI file to bring in.
  T.tone("Source", 4)
  paw.render(lib .. "/loop.wav", { tail = 0, bits = 16 })
  paw.midifile.export(lib .. "/riff.mid")
  start()
  local d = dir("importing")
  paw.project.save(d .. "/song.json")
  keys(":import " .. lib .. "/loop.wav<CR>")
  eq(#paw.tracks(), 1, ":import puts a sound file on a new track")
  eq(paw.tracks()[1]:clips()[1].kind, "audio", "as an audio clip")
  eq(paw.tracks()[1].name, "loop", "named after the file")
  keys("3|")
  keys(":import " .. lib .. "/loop.wav<CR>")
  eq(paw.tracks()[2]:clips()[1].start, 8, "a clip that starts at the cursor")
  keys("u")
  keys("o")
  keys("5|")
  keys(":clip.import " .. lib .. "/loop.wav<CR>")
  local t2 = paw.tracks()[2]
  eq(#t2:clips() .. "@" .. t2:clips()[1].start, "1@16", ":clip.import puts it on the track of the cursor, at the cursor")
  keys(":import " .. lib .. "/riff.mid<CR>")
  eq(#paw.tracks(), 3, ":import adds the tracks of a MIDI file")
  eq(paw.tracks()[3]:clips()[1].kind, "midi", "with their notes")
  keys(":files " .. lib .. "<CR>")
  eq(table.concat(api.ui_snapshot(100, 30), "\n"):find("loop.wav", 1, true) ~= nil, true, ":files shows the folder")
  keys("/loop<CR>")
  keys("go")
  eq(#paw.tracks(), 4, "go puts the file on a new track")
  keys(":files " .. lib .. "<CR>")
  keys("/loop<CR>")
  keys("<CR>")
  eq(#paw.tracks(), 4, "Enter puts it on the track of the cursor")
  eq(#paw.tracks()[4]:clips(), 2, "beside the other clip")
  paw.ui.focus("arrange")
  keys(":media.collect<CR>")
  for _, t in ipairs(paw.tracks()) do
    for _, c in ipairs(t:clips()) do
      if c.kind == "audio" then eq(c:get().file, d .. "/media/loop.wav", ":media.collect copies the files into media") end
    end
  end
end)

test("guide: make and use track templates", function()
  start()
  paw.opt.templates_dir = T.scratch .. "/guide-templates"
  T.after(function() paw.opt.templates_dir = T.scratch .. "/templates" end)
  keys(":ext.load templates<CR>")
  local vocal = paw.add_track({ name = "Vocal" })
  vocal:add_device("eq")
  vocal:add_device("compressor")
  vocal.volume = -4
  paw.flush()
  paw.ui.focus("arrange")
  paw.cursor.set_track(vocal)
  keys(",TsLead vocal<CR>")
  eq(require("templates").list("track")[1].name, "Lead vocal", ",Ts saves the track as a template")
  keys(",TfVocal chain<CR>")
  eq(require("templates").list("fx")[1] ~= nil, true, ",Tf saves the devices as a chain")
  start()
  paw.add_track({ name = "Guitar" })
  paw.flush()
  paw.ui.focus("arrange")
  paw.cursor.set_track(paw.tracks()[1])
  keys(",Tllead<CR>")
  eq(#paw.tracks(), 2, ",Tl makes the track again")
  local made = paw.tracks()[2]
  eq(made.name .. " " .. made.volume, "Vocal -4", "below the cursor track, with its level")
  eq(made:devices()[1].kind .. " " .. made:devices()[2].kind, "eq compressor", "and its devices")
  paw.cursor.set_track(paw.tracks()[1])
  keys(",Tlvocal chain<CR>")
  eq(#paw.tracks()[1]:devices(), 2, "a chain goes onto the devices of the cursor track")
  keys(":templates<CR>")
  eq(table.concat(api.ui_snapshot(100, 20), "\n"):find("Lead vocal", 1, true) ~= nil, true, ":templates lists them")
end)
