-- The editor scene's song: the demo song with its melody sung, "sakura
-- sakura, yayoi no sora", on a vocal track under the lead, and the cursor
-- on the vocal clip. UTAU_SINGER (a global) names the singer.
dofile("examples/demo-song.lua")
daw.opt.zoom = 2.75
daw.ext.load("extensions/utau")
local lead = daw.tracks()[4]
local vocal = daw.track_kinds.add("vocal", { name = "Vocal", ask = false })
require("utau").configure(vocal.id, { singer = UTAU_SINGER, phonemizer = "OpenUtau.Plugin.Builtin.JapaneseVCVPhonemizer" })
local lyrics = { "さ", "く", "ら", "さ", "く", "ら", "や", "よ", "い", "の", "そ", "ら" }
local notes = {}
for i, n in ipairs(daw.api.clip_notes(lead:clips()[1].id)) do
  notes[i] = { pitch = n.pitch, start = n.start, length = n.length, velocity = n.velocity, meta = { lyric = lyrics[i] } }
end
vocal:add_clip({ start = 16, length = 16, name = "sakura", notes = notes })
lead.mute = true
daw.cursor.set_track(vocal)
daw.cursor.set_beat(16)
daw.flush()
