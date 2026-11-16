-- A small song to look around in: `daw -e 'dofile("examples/demo-song.lua")'`.
daw.project.tempo = 112
local function clip(track, start, length, name, notes) return track:add_clip({ start = start, length = length, name = name, notes = notes }) end
local drums = daw.add_track({ name = "Drums" })
drums:add_device("drums")
for bar = 0, 7 do
  local n = {}
  for s = 0, 7 do
    if s % 4 == 0 then n[#n + 1] = { pitch = 36, start = s * 0.5, length = 0.25 } end
    if s % 4 == 2 then n[#n + 1] = { pitch = 38, start = s * 0.5, length = 0.25 } end
    n[#n + 1] = { pitch = 42, start = s * 0.5, length = 0.25, velocity = s % 2 == 0 and 100 or 60 }
  end
  clip(drums, bar * 4, 4, bar % 4 == 3 and "fill" or "beat", n)
end
local bass = daw.add_track({ name = "Bass", volume = -4 })
bass:add_device("synth", { wave = 1, cutoff = 600 })
local roots = { 33, 33, 36, 31 }
for i = 0, 7 do
  local n, r = {}, roots[i % 4 + 1]
  for s = 0, 7 do n[#n + 1] = { pitch = r + (s % 4 == 3 and 12 or 0), start = s * 0.5, length = 0.4 } end
  clip(bass, i * 4, 4, "bass " .. (i % 4 + 1), n)
end
local keys = daw.add_track({ name = "Keys", volume = -8, pan = -0.3 })
keys:add_device("synth", { wave = 3, attack = 0.02, release = 0.4 })
keys:add_device("delay", { time = 268, mix = 0.2 })
local chords = { { 57, 60, 64 }, { 57, 60, 65 }, { 55, 60, 64 }, { 55, 59, 62 } }
for i = 0, 3 do
  local n = {}
  for b = 0, 1 do
    for _, p in ipairs(chords[i + 1]) do
      n[#n + 1] = { pitch = p, start = b * 4, length = 3.5, velocity = 80 }
      n[#n + 1] = { pitch = p, start = b * 4 + 3.5, length = 0.5, velocity = 60 }
    end
  end
  clip(keys, i * 8, 8, "chords", n)
end
local lead = daw.add_track({ name = "Lead", volume = -6, pan = 0.25 })
lead:add_device("synth", { wave = 2, cutoff = 2400 })
local tune = { 69, 72, 76, 74, 72, 69, 67, 69, 72, 76, 79, 77, 76, 74, 72, 71 }
local n = {}
for i, p in ipairs(tune) do n[i] = { pitch = p, start = (i - 1) * 1, length = i % 4 == 0 and 1 or 0.75, velocity = 70 + (i * 13) % 50 } end
clip(lead, 8, 16, "melody", n)
lead:automate("volume"):set_points({ { 8, -18 }, { 12, -6 }, { 20, -6 }, { 24, -14 } })
local bus = daw.add_track({ name = "Reverb" })
bus:add_device("delay", { time = 90, feedback = 0.6, mix = 1 })
lead:send(bus, -9)
keys:send(bus, -12)
drums.mute = false
bass.solo = false
daw.transport.loop_start, daw.transport.loop_end = 8, 16
daw.cursor.set_track(keys)
daw.flush()
