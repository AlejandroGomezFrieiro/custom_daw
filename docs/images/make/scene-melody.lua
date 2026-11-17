-- The song the notation scenes start from: a melody track with a short
-- tune, to be read and added to in staff notation, and a bass line.
daw.ext.load("extensions/notation")
daw.project.tempo = 100
local lead = daw.add_track({ name = "Melody" })
lead:add_device("synth", { wave = 2, cutoff = 2400 })
local tune = { 67, 69, 71, 72, 74, 72, 71, 69, 67, 67, 71, 74, 72, 71, 69, 67 }
local n = {}
for i, p in ipairs(tune) do n[i] = { pitch = p, start = i - 1, length = 0.9, velocity = 80 } end
lead:add_clip({ start = 0, length = 32, name = "tune", notes = n })
local bass = daw.add_track({ name = "Bass", volume = -5 })
bass:add_device("synth", { wave = 1, cutoff = 600 })
local b = {}
for i, p in ipairs({ 43, 43, 48, 43 }) do b[i] = { pitch = p, start = (i - 1) * 4, length = 3.5 } end
bass:add_clip({ start = 0, length = 32, name = "bass", notes = b })
daw.cursor.set_track(lead)
daw.flush()
