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
