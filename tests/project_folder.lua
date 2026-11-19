-- A project as a folder of files: project.toml, a folder per track, a MIDI
-- 2.0 clip file per clip, files no longer used moved to unused/.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local paw = require("paw")
local api = paw.api

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() end
  return f ~= nil
end

local n = 0
local function folder(name)
  n = n + 1
  return T.scratch .. "/folder" .. n .. "-" .. name
end

local function notes(at)
  return {
    { start = at, length = 0.5, pitch = 60, velocity = 100 },
    { start = at + 0.5, length = 0.25, pitch = 64, velocity = 90 },
    { start = at + 1, length = 1, pitch = 67, velocity = 80, meta = { lyric = "la" } },
  }
end

--- A small song: two tracks, MIDI clips, a device, a lane.
local function song()
  fresh()
  api.project_set("tempo", 96)
  local keys = api.track_add({ name = "Keys", volume = -3 })
  local bass = api.track_add({ name = "Bass" })
  local synth = api.device_add(keys, "synth", { params = { wave = 1 } })
  api.device_add(keys, "delay")
  local riff = api.clip_add(keys, { name = "riff", start = 0, length = 4, notes = notes(0) })
  api.clip_set_controls(riff, { { start = 1, type = "cc", number = 1, value = 0.25 } })
  api.clip_add(bass, { name = "line", start = 4, length = 4, notes = { { start = 0, length = 2, pitch = 36 } } })
  api.lane_add(keys, { target = "volume", points = { { 0, -6 }, { 4, 0 } } })
  api.lane_add(keys, { target = "param", device = synth, param = "wave", points = { { 0, 0 } } })
  api.undo_checkpoint()
  paw.flush()
  return keys, bass, riff
end

test("a project saved to a folder name writes a folder of files and opens again the same", function()
  local keys = song()
  local dir = folder("song")
  local path = paw.project.save(dir)
  eq(path, dir .. "/project.toml", "the project's file is its project.toml")
  for _, file in ipairs({ "project.toml", ".gitattributes", "tracks/Keys/track.json", "tracks/Keys/devices.json",
    "tracks/Keys/clips/riff.midi2", "tracks/Bass/clips/line.midi2", "tracks/Keys/automation/volume.json",
    "tracks/Keys/automation/1-synth-wave.json", "master/track.json" }) do
    eq(exists(dir .. "/" .. file), true, file)
  end
  eq(T.read_file(dir .. "/tracks/Keys/clips/riff.midi2"):sub(1, 8), "SMF2CLIP", "a MIDI 2.0 clip file")
  eq(T.read_file(dir .. "/.gitattributes"), "*.midi2 diff=paw-midi2\n", ".gitattributes")
  eq(T.read_file(dir .. "/project.toml"):match("tempo = ([%d.]+)"), "96.0", "the tempo is in project.toml")
  local before = api.project_file_text and nil
  local was = {}
  for _, t in ipairs(api.track_list()) do
    for _, c in ipairs(api.clip_list(t)) do was[c.name] = api.clip_notes(c.id) end
  end
  api.project_new()
  api.project_load(dir)
  paw.flush()
  eq(api.project_get().path, dir .. "/project.toml", "opened by its folder")
  eq(api.project_get().tempo, 96, "tempo")
  eq(api.project_get().name, "folder1-song", "named after its folder")
  local tracks = api.track_list()
  eq(#tracks, 2, "two tracks")
  local k = api.track_get(tracks[1])
  eq(k.name, "Keys", "the order of the tracks")
  eq(k.volume, -3, "the track's fields")
  eq(#k.devices, 2, "the chain")
  eq(api.device_get(k.devices[1]).params.wave, 1, "a parameter")
  eq(#api.lane_list(tracks[1]), 2, "the lanes")
  for _, t in ipairs(tracks) do
    for _, c in ipairs(api.clip_list(t)) do
      local got, want = api.clip_notes(c.id), was[c.name]
      eq(#got, #want, c.name .. ": notes")
      for i = 1, #want do
        for _, field in ipairs({ "start", "length", "pitch", "velocity", "id" }) do
          eq(got[i][field], want[i][field], c.name .. " note " .. i .. " " .. field)
        end
      end
    end
  end
  local riff = api.clip_list(tracks[1])[1]
  eq(api.clip_notes(riff.id)[3].meta.lyric, "la", "a note's meta")
  eq(api.clip_controls(riff.id)[1].value, 0.25, "a controller move")
  eq(api.project_get().modified, false, "not changed by opening")
  local _ = keys
end)

test("saving a folder again changes no file, and the same project gives the same bytes", function()
  song()
  local dir = folder("same")
  paw.project.save(dir)
  local first = T.read_file(dir .. "/tracks/Keys/track.json")
  paw.flush()
  local events = {}
  local off = paw.on("project.saved", function(e) events[#events + 1] = e end)
  paw.project.save()
  paw.flush()
  paw.off(off)
  eq(#events[1].written, 0, "nothing written: " .. table.concat(events[1].written, ", "))
  api.project_load(dir)
  paw.flush()
  local dir2 = folder("again")
  paw.project.save(dir2)
  eq(T.read_file(dir2 .. "/tracks/Keys/track.json"), first, "the same bytes after a round trip")
  eq(T.read_file(dir2 .. "/tracks/Keys/clips/riff.midi2"), T.read_file(dir .. "/tracks/Keys/clips/riff.midi2"), "the same clip file")
end)

test("repeats of a part share one file until one of them is edited", function()
  local keys, _, riff = song()
  local copy = api.clip_add(keys, { name = "riff", start = 8, length = 4, notes = notes(0) })
  api.clip_set_controls(copy, { { start = 1, type = "cc", number = 1, value = 0.25 } })
  api.undo_checkpoint()
  local dir = folder("repeats")
  paw.project.save(dir)
  eq(exists(dir .. "/tracks/Keys/clips/riff-2.midi2"), false, "one file for both")
  api.clip_note_set(copy, 1, { pitch = 61 })
  api.undo_checkpoint()
  paw.flush()
  local events = {}
  local off = paw.on("project.saved", function(e) events[#events + 1] = e end)
  paw.project.save()
  paw.flush()
  paw.off(off)
  eq(exists(dir .. "/tracks/Keys/clips/riff-2.midi2"), true, "the edited one has its own file")
  local written = table.concat(events[1].written, " ")
  eq(written:find("riff.midi2", 1, true) ~= nil, false, "the first one's file stays: " .. written)
  local _ = riff
end)

test("a renamed track's folder moves, and a removed clip's file goes to unused/", function()
  local keys, bass = song()
  local dir = folder("unused")
  paw.project.save(dir)
  api.track_set(bass, "name", "Low")
  local line = api.clip_list(bass)[1]
  api.undo_checkpoint()
  paw.project.save()
  eq(exists(dir .. "/tracks/Low/clips/line.midi2"), true, "the folder has the new name")
  eq(exists(dir .. "/tracks/Bass"), false, "the old folder is gone")
  eq(exists(dir .. "/unused/tracks/Bass/clips/line.midi2"), false, "a moved file is not unused")
  api.clip_remove(line.id)
  api.undo_checkpoint()
  paw.project.save()
  eq(exists(dir .. "/tracks/Low/clips/line.midi2"), false, "not in the track any more")
  eq(exists(dir .. "/unused/tracks/Low/clips/line.midi2"), true, "kept in unused/")
  -- A file of the same name in unused/ already stays, and the next goes beside it.
  api.clip_add(bass, { name = "line", start = 0, length = 1, notes = { { start = 0, length = 1, pitch = 40 } } })
  api.undo_checkpoint()
  paw.project.save()
  api.clip_remove(api.clip_list(bass)[1].id)
  api.undo_checkpoint()
  paw.project.save()
  eq(exists(dir .. "/unused/tracks/Low/clips/line-2.midi2"), true, "never over a file in unused/")
  local _ = keys
end)

test("a project folder opens from its project.toml and from the command line name", function()
  song()
  local dir = folder("open")
  paw.project.save(dir)
  api.project_new()
  paw.open(dir .. "/project.toml")
  paw.flush()
  eq(#api.track_list(), 2, "opened from project.toml")
  eq(api.project_get().path, dir .. "/project.toml", "its path")
end)

test("a plugin's state is a file of its own beside devices.json", function()
  fresh()
  local t = api.track_add({ name = "Lead" })
  local d = api.device_add(t, "synth")
  api.device_set(d, "state", "aGVsbG8=")
  api.undo_checkpoint()
  local dir = folder("state")
  paw.project.save(dir)
  eq(T.read_file(dir .. "/tracks/Lead/1-synth.state"), "hello", "the state's bytes")
  eq(T.read_file(dir .. "/tracks/Lead/devices.json"):find("state_file", 1, true) ~= nil, true, "named in devices.json")
  api.project_new()
  api.project_load(dir)
  local again = folder("state-again")
  paw.project.save(again)
  eq(T.read_file(again .. "/tracks/Lead/1-synth.state"), "hello", "read back and written again")
end)

test(":w in the piano roll writes the clip's file and what it needs, :ls shows each file, :wa writes them all", function()
  local keys, bass, riff = song()
  local dir = folder("buffers")
  paw.project.save(dir)
  paw.flush()
  -- Two edits: a note of the riff, and the bass track's volume.
  api.clip_note_set(riff, 1, { velocity = 50 })
  api.track_set(bass, "volume", -10)
  api.undo_checkpoint()
  paw.ui.views.pianoroll:edit(paw.clip(riff))
  paw.flush()
  T.keys(":ls<CR>")
  local files = {}
  for _, f in ipairs(api.project_files()) do files[f.path] = f.modified end
  eq(files["tracks/Keys/clips/riff.midi2"], true, "the clip differs from the disk")
  eq(files["tracks/Bass/track.json"], true, "the bass track too")
  eq(files["tracks/Keys/devices.json"], false, "the chain does not")
  T.keys("<Esc>:w<CR>")
  eq(paw.ui.message.text, "wrote riff.midi2", "only the clip's file (its track.json and project.toml did not change)")
  files = {}
  for _, f in ipairs(api.project_files()) do files[f.path] = f.modified end
  eq(files["tracks/Keys/clips/riff.midi2"], false, "written")
  eq(files["tracks/Bass/track.json"], true, "the bass track is still to write")
  eq(api.project_get().modified, true, "the project still has a change that is not saved")
  T.keys(":wa<CR>")
  eq(api.project_get().modified, false, "all saved")
  -- Undo of the volume makes the bass track's file differ again, and redo
  -- makes it the same as the disk.
  api.undo()
  paw.flush()
  files = {}
  for _, f in ipairs(api.project_files()) do files[f.path] = f.modified end
  eq(files["tracks/Bass/track.json"], true, "undone: differs from the disk")
  api.redo()
  files = {}
  for _, f in ipairs(api.project_files()) do files[f.path] = f.modified end
  eq(files["tracks/Bass/track.json"], false, "redone: as on the disk")
  local _ = keys
end)

test("a clip file from outside is referred to until its first edit, which makes a copy that undo takes back", function()
  fresh()
  local lib = folder("library")
  os.execute("mkdir -p '" .. lib .. "'")
  api.midi2_write(lib .. "/riff.midi2", { notes = notes(0), length = 4 })
  local t = paw.add_track({ name = "Keys" })
  paw.cursor.set_track(t)
  paw.cursor.beat = 4
  T.keys(":import " .. lib .. "/riff.midi2<CR>")
  local clip = t:clips()[1]
  eq(clip.start, 4, "at the cursor")
  eq(clip.length, 4, "the file's length")
  eq(api.clip_get(clip.id).source, lib .. "/riff.midi2", "it refers to the file")
  eq(#api.clip_notes(clip.id), 3, "its notes")
  local dir = folder("refers")
  paw.project.save(dir)
  eq(exists(dir .. "/tracks/Keys/clips/riff.midi2"), false, "no copy in the folder")
  eq(T.read_file(dir .. "/tracks/Keys/track.json"):find(lib .. "/riff.midi2", 1, true) ~= nil, true, "track.json names the file")
  api.project_load(dir)
  paw.flush()
  clip = paw.tracks()[1]:clips()[1]
  eq(api.clip_get(clip.id).source, lib .. "/riff.midi2", "still referred to after opening")
  -- The first edit.
  local copied = 0
  local id = paw.on("clip.copied", function() copied = copied + 1 end)
  T.after(function() paw.off(id) end)
  api.clip_note_set(clip.id, 1, { pitch = 61 })
  api.undo_checkpoint()
  paw.flush()
  eq(paw.ui.message.text, "riff is now this project's own copy (was " .. lib .. "/riff.midi2)", "said once")
  eq(api.clip_get(clip.id).source, nil, "its own")
  eq(api.clip_get(clip.id).origin, lib .. "/riff.midi2", "it remembers where it came from")
  eq(api.midi2_read(lib .. "/riff.midi2").notes[1].pitch, 60, "the library's file did not change")
  api.clip_note_set(clip.id, 2, { pitch = 65 })
  api.undo_checkpoint()
  paw.flush()
  eq(copied, 1, "not said again")
  api.undo()
  api.undo()
  eq(api.clip_get(clip.id).source, lib .. "/riff.midi2", "undo returns to the reference")
  api.redo()
  paw.project.save()
  eq(exists(dir .. "/tracks/Keys/clips/riff.midi2"), true, "the copy is in the folder")
end)

test(":collect makes every clip from outside the project's own", function()
  fresh()
  local lib = folder("library2")
  os.execute("mkdir -p '" .. lib .. "'")
  api.midi2_write(lib .. "/hook.midi2", { notes = notes(0), length = 2 })
  local t = paw.add_track({ name = "Keys" })
  t:add_clip({ file = lib .. "/hook.midi2", start = 0 })
  local dir = folder("collect")
  paw.project.save(dir)
  T.keys(":collect<CR>")
  eq(paw.ui.message.text, "1 clip and 0 sound files are now the project's own; `:w` writes them into its folder", "said")
  T.keys(":wa<CR>")
  eq(exists(dir .. "/tracks/Keys/clips/hook.midi2"), true, "copied in")
  eq(api.clip_get(t:clips()[1].id).origin, lib .. "/hook.midi2", "where it came from")
end)

test("a clip file opens alone in the piano roll, plays on a track of its own, and :w writes it back", function()
  local lib = folder("alone")
  os.execute("mkdir -p '" .. lib .. "'")
  local path = lib .. "/riff.midi2"
  api.midi2_write(path, { notes = notes(0), length = 4 })
  fresh()
  T.keys(":e " .. path .. "<CR>")
  eq(paw.ui.message.text, "opened riff.midi2 alone: `:w` writes it back, `:w song` saves a project of it", "said")
  eq(#paw.tracks(), 1, "one track")
  eq(paw.tracks()[1]:devices()[1].kind, "synth", "the default instrument")
  eq(paw.ui.views.pianoroll:clip().name, "riff", "the piano roll shows it")
  eq(api.project_get().modified, false, "nothing changed yet")
  local clip = paw.tracks()[1]:clips()[1]
  api.clip_note_set(clip.id, 1, { pitch = 72 })
  api.undo_checkpoint()
  T.keys(":w<CR>")
  eq(paw.ui.message.text, "wrote " .. path, "written back")
  eq(api.midi2_read(path).notes[1].pitch, 72, "the file has the edit")
  eq(api.project_get().modified, false, "saved")
  eq(api.midi2_text(path):match("^# 3 notes") ~= nil, true, "as text: " .. api.midi2_text(path))
end)

test("a MIDI 1.0 file written, opened and written again is the same file", function()
  fresh()
  local t = paw.add_track({ name = "Keys" })
  t:add_clip({ start = 0, length = 4, notes = notes(0), controls = { { start = 1, type = "cc", number = 64, value = 1 } } })
  local a, b = T.scratch .. "/same-a.mid", T.scratch .. "/same-b.mid"
  -- A MIDI file opened names the project after itself: the same name.
  api.project_set("name", "same-a")
  paw.midifile.export(a, {})
  paw.midifile.open(a)
  paw.midifile.export(b, {})
  local x, y = T.read_file(a), T.read_file(b)
  if x ~= y then
    local i = 1
    while x:byte(i) == y:byte(i) do i = i + 1 end
    error(string.format("differ at byte %d of %d/%d: %q vs %q", i, #x, #y, x:sub(i - 8, i + 24), y:sub(i - 8, i + 24)))
  end
end)

test("MIDI 1.0 notes and controllers go into a clip file and back with no loss", function()
  fresh()
  local t = paw.add_track({ name = "Keys" })
  local list = {}
  for v = 1, 127, 7 do list[#list + 1] = { start = #list * 0.25, length = 0.25, pitch = v, velocity = v } end
  local controls = {}
  for v = 0, 127, 9 do controls[#controls + 1] = { start = #controls * 0.125, type = "cc", number = 7, value = v / 127 } end
  local c = t:add_clip({ start = 0, length = 8, notes = list, controls = controls })
  local path = T.scratch .. "/seven.midi2"
  api.midi2_write(path, { notes = api.clip_notes(c.id), controls = api.clip_controls(c.id), length = 8 })
  local back = api.midi2_read(path)
  for i, n in ipairs(list) do
    eq(back.notes[i].velocity, n.velocity, "velocity " .. n.velocity)
    eq(back.notes[i].pitch, n.pitch, "pitch")
  end
  for i, m in ipairs(api.clip_controls(c.id)) do
    eq(math.floor(back.controls[i].value * 127 + 0.5), math.floor(m.value * 127 + 0.5), "a 7-bit value")
  end
  -- And the clip file written again is the same file.
  local again = T.scratch .. "/seven-again.midi2"
  api.midi2_write(again, { notes = back.notes, controls = back.controls, length = back.length })
  eq(T.read_file(again) == T.read_file(path), true, "the same bytes")
end)
