-- Tests of score clips: the written score is what is kept and edited, the
-- clip's notes are rendered from it. Loaded by tests.lua.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local daw = require("daw")
local api = daw.api

local function load()
  if not package.loaded["notation.keys"] then daw.ext.load("extensions/notation") end
  return require("notation"), require("notation.doc"), require("notation.render")
end

local function N(pitch, start, length, velocity) return { pitch = pitch, start = start, length = length, velocity = velocity or 80 } end

local function keys(text)
  daw.keymap.feed(text)
  api.undo_checkpoint()
end

--- A track with a clip open as notation.
local function song(notes, length)
  fresh()
  local view = load()
  local track = daw.add_track({ name = "Lead" })
  track:add_device("synth")
  local clip = track:add_clip({ start = 0, length = length or 4, name = "tune", notes = notes or {} })
  daw.flush()
  daw.keymap.set_mode("n")
  view:edit(clip)
  view.value, view.dot, view.voice, view.triplets = 1, false, 1, false
  api.undo_checkpoint()
  return view, clip, track
end

--- The clip's notes as "C4@0+0.9/80".
local function played(clip, with_velocity)
  local out = {}
  for _, n in ipairs(clip:notes()) do
    out[#out + 1] = string.format("%s@%g+%g", daw.music.name(n.pitch), math.floor(n.start * 1e6 + 0.5) / 1e6,
      math.floor(n.length * 1e6 + 0.5) / 1e6) .. (with_velocity and ("/" .. n.velocity) or "")
  end
  return table.concat(out, " ")
end

--- The written text of the open clip's staff and voice: "q C4 q D4 hr | R".
local function written(view, staff, voice)
  return require("notation.model").text(view:layout(), staff, voice)
end

local function score_of(clip) return require("notation").score_of(clip:get()) end

-- The document ----------------------------------------------------------------------------------

test("score: entering notes writes a score that survives undo, saving and loading", function()
  local view, clip = song(nil, 8)
  eq(score_of(clip), nil, "a new clip is plain MIDI")
  keys("icde")
  local sc = score_of(clip)
  eq(sc ~= nil and sc.version, 1, "entering writes a score in the clip")
  eq(written(view), "q C4 q D4 q E4 qr | R", "written as entered")
  eq(played(clip), "C4@0+0.9 D4@1+0.9 E4@2+0.9", "and played from it, each at 90% of its value")
  local ids = {}
  for _, n in ipairs(clip:notes()) do ids[#ids + 1] = n.meta.score.n end
  eq(#ids, 3, "each note says which written note it plays")
  keys("<Esc>")
  view:set(36, 1)
  keys("<C-a>")
  eq(written(view), "q C4 q D#4 q E4 qr | R", "sharpened")
  keys("u")
  eq(written(view), "q C4 q D4 q E4 qr | R", "undo takes back the edit, written and played together")
  eq(played(clip), "C4@0+0.9 D4@1+0.9 E4@2+0.9", "the notes too")
  keys("u")
  eq(written(view), "R | R", "and the notes entered in one go, as one step")
  keys("<C-r>")
  local path = T.scratch .. "/score-roundtrip.daw"
  api.project_save(path)
  local before = api.json_encode(clip:get().meta.score)
  api.project_load(path)
  daw.flush()
  local again = daw.tracks()[1]:clips()[1]
  eq(api.json_encode(again:get().meta.score), before, "saved and loaded as it was")
  eq(played(again), "C4@0+0.9 D4@1+0.9 E4@2+0.9", "with its notes")
end)

test("score: ties, grace notes, articulations, dynamics and tuplets are rendered exactly", function()
  local _, D, render = load()
  local sc = D.new({ { start = 0, num = 4, den = 4 }, { start = 4, num = 4, den = 4 } }, { "treble" })
  local s = sc.staves[1].id
  local C4 = { step = 0, alter = 0, octave = 4 }
  local E4 = { step = 2, alter = 0, octave = 4 }
  local G4 = { step = 4, alter = 0, octave = 4 }
  -- A half note on beat four, tied over the barline.
  D.put_chord(sc, 1, s, 1, 3 * D.Q, 2 * D.Q, { C4 })
  -- Triplet eighths on beat two.
  for k = 0, 2 do D.put_tuplet_chord(sc, 1, s, 1, D.Q + k * D.Q / 3, D.Q / 2, 3, 2, { k == 1 and E4 or G4 }) end
  -- A staccato quarter on beat three of bar two, an acciaccatura before it.
  local ev = D.put_chord(sc, 2, s, 1, 2 * D.Q, D.Q, { E4 })
  ev.art = { staccato = true }
  local _, entry, k = D.find(sc, ev.id)
  table.insert(entry.events, k, { id = D.id(sc, "e"), kind = "chord", grace = "acciaccatura", dur = { 1, 8 }, dots = 0, notes = { { id = D.id(sc, "n"), step = 3, alter = 0, octave = 4 } } })
  sc.marks = { { id = "k1", kind = "dynamic", from = { measure = sc.measures[1].id, at = { 0, 1 } }, value = "p" },
    { id = "k2", kind = "dynamic", from = { measure = sc.measures[2].id, at = { 1, 2 } }, value = "f" } }
  local notes = render.render(sc)
  local list = {}
  for _, n in ipairs(notes) do list[#list + 1] = n end
  eq(#list, 6, "three triplets, the tied C as one note, the grace note and the E")
  eq(math.abs(list[1].start - 1) < 1e-12 and math.abs(list[2].start - 4 / 3) < 1e-12 and math.abs(list[3].start - 5 / 3) < 1e-12, true,
    "triplets start on exact thirds of the beat")
  eq(list[4].pitch .. "@" .. list[4].start .. "+" .. string.format("%.4f", list[4].length), "60@3+1.8000", "the tied half note is one note, 90% of two beats")
  eq(list[5].pitch, 65, "the grace note")
  eq(math.abs(list[5].start - (6 - 0.125)) < 1e-12, true, "a 32nd before its note")
  eq(list[6].start .. "+" .. list[6].length, "6+0.5", "the staccato quarter sounds half its value")
  eq(list[1].velocity, 52, "p: velocity 52")
  eq(list[6].velocity, 96, "f from the middle of bar two: 96")
  D.touch(sc, 2)
  sc.marks[3] = { id = "k3", kind = "hairpin", value = "cresc", from = { measure = sc.measures[1].id, at = { 0, 1 } }, to = { measure = sc.measures[2].id, at = { 1, 2 } } }
  local ramp = render.render(sc)
  eq(ramp[1].velocity > 52 and ramp[1].velocity < ramp[4].velocity, true, "a crescendo ramps from the p to the f")
end)

test("score: an edit renders again only the measures it changed", function()
  local view, clip = song(nil, 64)
  keys("i")
  for _ = 1, 16 do keys("cdedcdec") end
  keys("<Esc>")
  local _, _, render = load()
  local before = render.stats.measures
  view:set(36, 33)
  keys("<C-a>")
  eq(render.stats.measures - before <= 2, true, "a note sharpened in bar nine renders one bar again (" .. (render.stats.measures - before) .. ")")
  eq(written(view):find("D#4", 1, true) ~= nil, true, "and it is written so: " .. written(view):sub(1, 200))
end)

-- The roll and the notation, one clip ----------------------------------------------------------

test("score: the piano roll's pitch, add and delete are written; a nudge and a velocity are feel", function()
  local view, clip = song(nil, 4)
  keys("icdef<Esc>")
  -- A nudge off the grid: feel, the notation unchanged.
  clip:set_note(2, { start = 1.03 })
  api.undo_checkpoint()
  eq(written(view), "q C4 q D4 q E4 q F4", "a nudge does not change what is written")
  local sc = score_of(clip)
  local d_id = clip:notes()[2].meta.score.n
  eq(math.abs(sc.feel[d_id].dt - 0.03) < 1e-9, true, "it is the note's feel")
  -- A pitch: written, spelled by the key.
  clip:set_note(2, { pitch = 63 })
  api.undo_checkpoint()
  eq(written(view), "q C4 q Eb4 q En4 q F4", "the roll's new pitch is written (E flat in C)")
  eq(math.abs(clip:notes()[2].start - 1.03) < 1e-9, true, "and keeps its feel")
  -- Velocity: a delta from the dynamic.
  clip:set_note(1, { velocity = 100 })
  api.undo_checkpoint()
  eq(score_of(clip).feel[clip:notes()[1].meta.score.n].dvel, 20, "a velocity is kept as 20 over the dynamic's")
  -- Delete and add.
  clip:remove_note(4)
  api.undo_checkpoint()
  eq(written(view), "q C4 q Eb4 q En4 qr", "deleted: a rest")
  clip:add_note({ pitch = "G4", start = 3, length = 1 })
  api.undo_checkpoint()
  eq(written(view), "q C4 q Eb4 q En4 q G4", "added on the grid: written into the rest")
  clip:add_note({ pitch = "B4", start = 0, length = 1 })
  api.undo_checkpoint()
  eq(written(view), "q <C4 B4> q Eb4 q En4 q G4", "a note of the same start and length joins the chord")
  clip:add_note({ pitch = "A4", start = 0, length = 2 })
  api.undo_checkpoint()
  eq(written(view, 1, 2), "h A4 hr", "a longer one over busy voice 1 opens voice 2")
  -- A whole step of the grid later: written there.
  local place
  for i, n in ipairs(clip:notes()) do if n.pitch == 67 then place = i end end
  clip:set_note(place, { start = 2.5 })
  api.undo_checkpoint()
  eq(written(view, 1, 1):find("e G4", 1, true) ~= nil or written(view, 1, 2):find("G4", 1, true) ~= nil, true, "moved by the grid: written again where it starts")
end)

test("score: notation and the roll edit one clip in turn, and undo goes back through both", function()
  local view, clip = song(nil, 4)
  daw.ui.focus("notation")
  keys("icdef<Esc>")
  eq(played(clip), "C4@0+0.9 D4@1+0.9 E4@2+0.9 F4@3+0.9", "entered in notation")
  -- The roll nudges the D.
  clip:set_note(2, { start = 1.04 })
  api.undo_checkpoint()
  -- Notation raises the D a step.
  view:set(36, 1)
  keys("<A-k>")
  eq(played(clip), "C4@0+0.9 E4@1.04+0.9 E4@2+0.9 F4@3+0.9", "the pitch changed in notation keeps the roll's nudge")
  -- The roll lowers it a semitone.
  clip:set_note(2, { pitch = 63 })
  api.undo_checkpoint()
  eq(written(view), "q C4 q Eb4 q En4 q F4", "the roll's pitch is written")
  -- Velocities from the roll, then a dynamic in notation.
  clip:set_note(1, { velocity = 90 })
  api.undo_checkpoint()
  view:set(35, 0)
  daw.cmd("notation.dyn", { "f" })
  api.undo_checkpoint()
  local v = {}
  for i, n in ipairs(clip:notes()) do v[i] = n.velocity end
  eq(v[1] - v[3], 10, "f: the roll's ten more on the C is kept over the new loudness")
  eq(v[3], 96, "the others at f")
  -- The roll quantizes: the feel goes.
  daw.ui.focus("pianoroll")
  local notes = clip:notes()
  for _, n in ipairs(notes) do n.start = math.floor(n.start * 4 + 0.5) / 4 end
  clip:set_notes(notes)
  api.undo_checkpoint()
  eq(played(clip), "C4@0+0.9 D#4@1+0.9 E4@2+0.9 F4@3+0.9", "quantized in the roll: the nudge is gone")
  eq(written(view), "q C4 q Eb4 q En4 q F4", "and the writing is as it was")
  -- Undo three times from the roll's side.
  keys("u")
  eq(played(clip), "C4@0+0.9 D#4@1.04+0.9 E4@2+0.9 F4@3+0.9", "undo: the nudge is back")
  keys("u")
  eq(clip:notes()[3].velocity, 80, "undo: the dynamic is gone")
  eq(clip:notes()[1].velocity, 90, "and the roll's velocity is as it was before it")
  keys("u")
  eq(clip:notes()[1].velocity, 80, "undo: the roll's velocity")
  daw.ui.focus("notation")
  keys("u")
  eq(written(view), "q C4 q E4 q E4 q F4", "and from notation: before the roll's pitch")
end)

-- From MIDI, and back -------------------------------------------------------------------------

test("score: a MIDI clip is shown read only until an edit or :score.from-midi writes it, keeping what was played and decided", function()
  local played_notes = {
    { pitch = 65, start = 0.02, length = 0.4, velocity = 70, meta = { notation = { letter = 2, alter = 1, pitch = 65 } } },
    { pitch = 67, start = 1, length = 0.95, velocity = 90 },
  }
  local view, clip = song(played_notes, 4)
  local before = played(clip, true)
  local layout = view:layout()
  eq(layout.midi, true, "a plain MIDI clip is shown as it would be written")
  eq(table.concat(api.ui_snapshot(140, 40), "\n"):find(":score.from-midi", 1, true) ~= nil, true, "and the view says how to write it")
  daw.cmd("score.from-midi")
  api.undo_checkpoint()
  local sc = score_of(clip)
  eq(sc ~= nil, true, "now a score clip")
  eq(written(view):find("E#4", 1, true) ~= nil, true, "the spelling kept with the note is the score's")
  eq(played(clip, true), before, "and it plays exactly as it did: the playing is its feel")
  keys("u")
  eq(score_of(clip), nil, "one undo step")
  -- The first edit in notation writes it too.
  view:set(39, 1)
  keys("x")
  eq(score_of(clip) ~= nil, true, "an edit makes it a score clip")
  eq(#clip:notes(), 1, "and the edit is made")
  daw.cmd("score.detach")
  api.undo_checkpoint()
  eq(score_of(clip), nil, ":score.detach: plain MIDI again")
  eq((clip:notes()[1].meta or {}).score, nil, "its notes say nothing of a score")
  eq(view:layout().midi, true, "shown as a transcription again")
end)

test("score: entry goes into its voice and staff and leaves the others alone", function()
  local view, clip = song(nil, 4)
  keys("icdef<Esc>")
  daw.cmd("notation.voice", { "2" })
  view:set(32, 0)
  keys("i5ag<Esc>")
  eq(written(view, 1, 1), "q C4 q D4 q E4 q F4", "voice 1 untouched")
  eq(written(view, 1, 2), "q A3 q G3 hr", "voice 2 has its notes")
  view.voice = 1
  view:set(37, 2)
  keys("i6g<Esc>")
  eq(written(view, 1, 1), "q C4 q D4 h G4", "overwriting in voice 1 takes voice 1's notes only")
  eq(written(view, 1, 2), "q A3 q G3 hr", "voice 2 is as it was")
  daw.cmd("notation.clef", { "grand" })
  api.undo_checkpoint()
  view:set(28, 0)
  keys("i6c<Esc>")
  eq(written(view, 2, 1), "h C3 hr", "the bass staff has its C")
  eq(written(view, 1, 1), "q C4 q D4 h G4", "and the treble staff is untouched")
  eq(#clip:notes(), 6, "every note played: three in voice 1, two in voice 2, one in the bass")
end)

test("score: a tie, a triplet, a rest, two voices and a dynamic, typed", function()
  local view, clip = song(nil, 8)
  daw.ui.focus("notation")
  keys("i5c~d4tefg")
  keys("t5rc")
  keys("<Esc>")
  view:set(42, 0)
  daw.cmd("notation.dyn", { "mf" })
  api.undo_checkpoint()
  daw.cmd("notation.voice", { "2" })
  view:set(37, 4)
  keys("i7e<Esc>")
  local text = written(view, 1, 1)
  eq(text:find("q~ C4 q C4", 1, true) ~= nil, true, "the tie: " .. text)
  eq(text:find("3{", 1, true) ~= nil, true, "the triplet")
  eq(text:find("qr", 1, true) ~= nil, true, "the rest: " .. text)
  eq(written(view, 1, 2), " | w E4", "the second voice in bar two")
  local m = view:layout().measures[1]
  eq(m.marks[1] and m.marks[1].value, "mf", "the dynamic")
  local notes = clip:notes()
  eq(notes[1].pitch .. "@" .. notes[1].start .. "+" .. string.format("%.2f", notes[1].length), "60@0+1.80", "the tied C plays as one note")
  eq(notes[1].velocity, 80, "at mf")
end)

-- Speed ------------------------------------------------------------------------------------------

test("score: an edit in a 64 bar score is quicker than a MIDI clip's paint after an edit", function()
  load()
  local bench = require("notation.bench")
  local opts = { glyphs = true, surface = true, cell = { w = 13, h = 27 } }
  local midi = bench.run(64, opts, 3)
  local score = bench.run(64, opts, 3, { score = true })
  -- Against the other on the same machine at the same time, so a busy
  -- machine does not decide it: the edit itself and its paint, against a
  -- transcribed clip's paint alone.
  eq(score.edit < midi.edit, true, string.format("score: edit and paint %.1f ms; MIDI: paint after an edit %.1f ms", score.edit, midi.edit))
end)
