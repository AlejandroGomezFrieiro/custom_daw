-- Saving and loading a large project.
--   daw --clean --no-plugins -l bench/saveload.lua <tracks> <clips per track>
-- Each track has a synth and a delay and `clips` one-bar MIDI clips of 12
-- notes, as in the Tracktion driver's `saveload`.
local daw = require("daw")
local api = daw.api
local B = dofile(debug.getinfo(1, "S").source:sub(2):match("(.*)/") .. "/lib.lua")

local tracks, clips = ...
tracks, clips = tonumber(tracks) or 100, tonumber(clips) or 8

local function build()
  for i = 0, tracks - 1 do
    local id = api.track_add({ name = "T" .. i })
    api.device_add(id, "synth", { params = { wave = 1 } })
    api.device_add(id, "delay")
    for c = 0, clips - 1 do
      local notes = B.bar_notes(0, i)
      api.clip_add(id, { start = c * 4, length = 4, notes = notes })
    end
  end
  api.undo_checkpoint()
  daw.flush()
end

local build_ms = B.time(build)
local path = B.tmp .. "/bench-project.json"
local save_ms = B.time(api.project_save, path)
local f = io.open(path, "rb")
local bytes = f:seek("end")
f:close()
api.project_new()
daw.flush()
local load_ms = B.time(function()
  api.project_load(path)
  daw.flush()
end)
local loaded = #api.track_list()
os.remove(path)
B.emit({
  workload = "saveload", tracks = tracks, clips_per_track = clips, build_ms = build_ms, save_ms = save_ms,
  load_ms = load_ms, file_bytes = bytes, loaded_tracks = loaded, rss_kb = B.rss(),
})
api.quit(0)
