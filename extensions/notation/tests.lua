-- Tests for the notation extension; run by tests/suite.lua.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local daw = require("daw")
local api = daw.api

local function load()
  if not package.loaded["notation.keys"] then daw.ext.load("extensions/notation") end
  return require("notation"), require("notation.model")
end

local function N(pitch, start, length) return { pitch = pitch, start = start, length = length } end

--- The model's text for some notes: "q. C4 e D4 h E4 | ...".
local function written(notes, opts)
  local _, model = load()
  opts = opts or {}
  opts.length = opts.length or 4
  return model.text(model.layout(notes, opts), opts.staff)
end

-- From notes to notation --------------------------------------------------------------------

test("notation: a dotted quarter and an eighth are written so", function()
  eq(written({ N(60, 0, 1.5), N(62, 1.5, 0.5), N(64, 2, 2) }), "q. C4 e D4 h E4", "dotted quarter, eighth, half")
end)

test("notation: a note across a barline is tied over it", function()
  eq(written({ N(67, 3, 2), N(65, 5, 3) }, { length = 8 }), "hr qr q~ G4 | q G4 q~ F4 h F4",
    "G tied into the next bar; F from beat two tied to a half on beat three")
end)

test("notation: a syncopation is split at the beat it hides", function()
  eq(written({ N(60, 0, 0.5), N(62, 0.5, 1), N(64, 1.5, 0.5), N(65, 2, 2) }), "e C4 e~ D4 e D4 e E4 h F4",
    "the quarter off the beat is two tied eighths")
  eq(written({ N(60, 0, 1), N(62, 1, 2), N(64, 3, 1) }), "q C4 q~ D4 q D4 q E4", "a half on beat two does not hide the middle of a 4/4 bar")
  eq(written({ N(60, 0, 1), N(62, 1, 2) }, { length = 3, num = 3, den = 4 }), "q C4 h D4", "but stands on beat two of 3/4")
end)

test("notation: rests fill the bar, a bar of silence is one whole rest", function()
  eq(written({ N(60, 1, 1) }, { length = 8 }), "qr q C4 hr | R", "rests before, after, and a whole empty bar")
  eq(written({ N(60, 0, 0.5), N(62, 2, 2) }), "e C4 er qr h D4", "an eighth rest, then a quarter rest to beat three")
end)

test("notation: notes hidden before a trimmed clip's start are not written", function()
  eq(written({ N(55, -1, 1), N(60, 0, 1), N(62, 1, 1), N(64, 2, 2) }), "q C4 q D4 h E4", "the note before 0 is left out")
end)

test("notation: notes that start together are a chord", function()
  eq(written({ N(60, 0, 2), N(64, 0, 2), N(67, 0, 2), N(72, 2, 2) }), "h <C4 E4 G4> h C5", "a C major triad, then C5")
end)

test("notation: accidentals follow the key and the bar's memory", function()
  -- D major: F# is in the key; F natural needs a sign, once a bar.
  eq(written({ N(66, 0, 1), N(65, 1, 1), N(65, 2, 1), N(66, 3, 1), N(65, 4, 1), N(66, 5, 1) }, { length = 8, fifths = 2 }),
    "q F4 q Fn4 q F4 q F#4 | q Fn4 q F#4 hr", "naturals and sharps as the bar remembers them, and the barline forgets")
  -- In C, a C# in one bar is reminded back in the next.
  eq(written({ N(60, 0, 1), N(61, 1, 3), N(60, 4, 1), N(60, 5, 1) }, { length = 8 }), "q C4 q~ C#4 h C4 | q C(n)4 q C4 hr",
    "a tied note keeps its sharp without a sign; the next bar says the C is natural again, once")
end)

test("notation: chromatic notes lean the way the key does", function()
  local _, model = load()
  local function names(fifths)
    local out = {}
    for _, p in ipairs({ 61, 63, 66, 68, 70 }) do out[#out + 1] = model.name(model.spell(p, fifths)) end
    return table.concat(out, " ")
  end
  eq(names(0), "C#4 Eb4 F#4 G#4 Bb4", "in C major")
  eq(names(-3), "Db4 Eb4 Gb4 Ab4 Bb4", "in E flat major")
  eq(names(4), "C#4 D#4 F#4 G#4 A#4", "in E major")
  eq(model.fifths_of("A", "minor"), 0, "A minor has no sharps")
  eq(model.fifths_of("Bb", "major"), -2, "B flat major two flats")
  eq(model.fifths_of("C#", "major"), -5, "C sharp major as musicops stores D flat: five flats")
  eq(model.fifths_of("G", "dorian"), -1, "G dorian one flat")
end)

test("notation: beams follow the beat, by half bars in 4/4 and by three eighths in 6/8", function()
  local _, model = load()
  local function beams(notes, opts)
    local layout = model.layout(notes, opts)
    local out = {}
    for _, ev in ipairs(layout.measures[1].staves[1]) do out[#out + 1] = ev.kind == "rest" and "r" or tostring(ev.beam or "-") end
    return table.concat(out, " ")
  end
  local eighths = {}
  for i = 0, 7 do eighths[#eighths + 1] = N(72, i * 0.5, 0.5) end
  eq(beams(eighths, { length = 4 }), "1 1 1 1 2 2 2 2", "eight eighths in 4/4: two beams of four")
  eq(beams({ N(72, 0, 0.5), N(72, 0.5, 0.5), N(72, 1, 1), N(72, 2, 0.5), N(72, 2.5, 0.25), N(72, 2.75, 0.25), N(72, 3, 1) }, { length = 4 }),
    "1 1 - 2 2 2 -", "pairs within a beat; quarters stand alone")
  local six = {}
  for i = 0, 5 do six[#six + 1] = N(72, i * 0.5, 0.5) end
  eq(beams(six, { length = 3, num = 6, den = 8 }), "1 1 1 2 2 2", "6/8: two groups of three")
  eq(written({ N(60, 0, 2), N(62, 2, 1) }, { length = 3, num = 6, den = 8 }), "q.~ C4 e C4 q D4", "6/8: a half note is split at the dotted quarter")
  local layout = model.layout({ N(72, 0, 0.5), N(74, 0.5, 0.5), N(60, 1, 0.5), N(62, 1.5, 0.5) }, { length = 2, num = 2, den = 4 })
  local evs = layout.measures[1].staves[1]
  eq(evs[1].stem, -1, "high notes: stems down")
  eq(evs[3].stem, 1, "low notes: stems up")
  eq(evs[1].flags, 1, "an eighth has one beam")
end)

test("notation: the clef is chosen by the notes, or fixed by the track", function()
  local _, model = load()
  eq(table.concat(model.layout({ N(72, 0, 1), N(64, 1, 1) }, { length = 4 }).staves, " "), "treble", "a melody above middle C")
  eq(table.concat(model.layout({ N(40, 0, 1), N(48, 1, 1) }, { length = 4 }).staves, " "), "bass", "a bass line")
  eq(table.concat(model.layout({ N(36, 0, 1), N(79, 0, 1) }, { length = 4 }).staves, " "), "treble bass", "both: a grand staff")
  eq(table.concat(model.layout({ N(72, 0, 1) }, { length = 4, clef = "bass" }).staves, " "), "bass", "a fixed clef wins")
  eq(written({ N(48, 0, 4), N(72, 0, 1), N(74, 1, 3) }, { staff = 2 }), "w C3", "the low C goes to the bass staff")
end)

test("notation: what was played loosely is written to the grid, and the notes stay as played", function()
  local _, model = load()
  local notes = { N(60, 0.03, 0.46), N(62, 0.52, 0.47), N(64, 0.98, 1.05) }
  eq(written(notes), "e C4 e D4 q E4 hr", "rounded to sixteenths")
  eq(notes[1].start, 0.03, "the notes themselves are not touched")
  eq(written({ N(60, 0, 1) }, { offset = 2 }), "hr q C4 qr | R", "a clip starting on beat three begins with rests")
end)

-- The score layer: what was played, written as a musician would ----------------------------

-- Clean scores, played: a seeded random, jitter, strums, swing, rubato.
local seed = 1
local function rand()
  seed = (seed * 1103515245 + 12345) % 2147483648
  return seed / 2147483648
end
local function spread(x) return (rand() * 2 - 1) * x end

--- Notes from text: "C4+E4 0 1, G4 1 0.5" (pitches, start, length).
local function clean(text)
  local out = {}
  for item in text:gmatch("[^,]+") do
    local p, st, l = item:match("(%S+)%s+(%S+)%s+(%S+)")
    for name in p:gmatch("[^+]+") do out[#out + 1] = { pitch = daw.music.pitch(name), start = tonumber(st), length = tonumber(l), velocity = 90 } end
  end
  table.sort(out, function(a, b) return a.start < b.start or (a.start == b.start and a.pitch < b.pitch) end)
  return out
end

--- Play clean notes: `jitter` ms either way, lengths `legato` of written
--- (0.9) give or take `release` ms, chords strummed `strum` ms a string
--- (`dir` 1 low first, -1 high first, "alt"), `swing` the long eighth's
--- share, `ahead` ms early, `rit` beats late by the end (growing with the
--- square), `overlap` beats past the written end, `graces` { name, main's
--- start, ms before, ms long }.
local function play(notes, o)
  local beat_ms = 60000 / (o.tempo or 120)
  local function ms(v) return v / beat_ms end
  local by, starts = {}, {}
  for _, n in ipairs(notes) do
    if not by[n.start] then starts[#starts + 1] = n.start end
    by[n.start] = by[n.start] or {}
    table.insert(by[n.start], n)
  end
  table.sort(starts)
  local last = notes[#notes].start + notes[#notes].length
  local function warp(t)
    local x = t
    if o.swing and math.abs(t - math.floor(t) - 0.5) < 1e-6 then x = math.floor(t) + o.swing end
    if o.rit then x = x + o.rit * (t / last) ^ 2 end
    return x
  end
  local out = {}
  for ci, st in ipairs(starts) do
    local chord = by[st]
    local dir = o.dir or 1
    if dir == "alt" then dir = ci % 2 == 1 and 1 or -1 end
    local base = warp(st) + ms(spread(o.jitter or 0)) - ms(o.ahead or 0)
    for k, n in ipairs(chord) do
      local order = dir == 1 and (k - 1) or (#chord - k)
      local start = math.max(0, base + (#chord > 1 and ms((o.strum or 0) * order) or 0))
      local finish = warp(n.start + n.length) - (1 - (o.legato or 0.9)) * n.length + ms(spread(o.release or 0))
      if o.overlap then finish = warp(n.start + n.length) + o.overlap end
      out[#out + 1] = { pitch = n.pitch, start = start, length = math.max(0.02, finish - start), velocity = 70 + math.floor(rand() * 40) }
    end
  end
  for _, g in ipairs(o.graces or {}) do
    out[#out + 1] = { pitch = daw.music.pitch(g[1]), start = g[2] - ms(g[3]), length = ms(g[4]), velocity = 70 }
  end
  table.sort(out, function(a, b) return a.start < b.start or (a.start == b.start and a.pitch < b.pitch) end)
  return out
end

--- What is written for the clean score and for it played.
local function both(text, how, opts, staff, voice)
  local _, model = load()
  opts = opts or {}
  opts.length = opts.length or 4
  local function copy() return daw.util.merge(opts, {}) end
  return model.text(model.layout(clean(text), copy()), staff, voice), model.text(model.layout(play(clean(text), how), copy()), staff, voice)
end

local MELODY = "C4 0 0.5, D4 0.5 0.5, E4 1 1, G4 2 0.5, F4 2.5 0.5, E4 3 0.75, D4 3.75 0.25, C4 4 2, G4 6 1, C5 7 1"

test("score: a melody played loosely is written as the clean score", function()
  for s = 1, 6 do
    seed = s
    local want, got = both(MELODY, { jitter = 20, release = 25 }, { length = 8 })
    eq(got, want, "seed " .. s .. ": onsets within 20 ms and releases within 25 ms of the score")
  end
  eq(select(1, both(MELODY, {}, { length = 8 })), "e C4 e D4 q E4 e G4 e F4 e. E4 s D4 | h C4 q G4 q C5", "the clean score itself")
end)

test("score: a part played ahead of the beat, legato, or slowing down is written straight", function()
  seed = 3
  local want, got = both(MELODY, { jitter = 10, ahead = 40 }, { length = 8 })
  eq(got, want, "40 ms ahead of the beat throughout")
  want, got = both(MELODY, { jitter = 15, overlap = 0.15 }, { length = 8 })
  eq(got, want, "every note held into the next: legato, no ties")
  want, got = both(MELODY, { jitter = 10, rit = 0.4 }, { length = 8 })
  eq(got, want, "a ritardando against the grid, the last note almost half a beat late")
  local run = "C4 0 0.5, D4 0.5 0.5, E4 1 0.5, F4 1.5 0.5, G4 2 0.5, A4 2.5 0.5, B4 3 0.5, C5 3.5 0.5, D5 4 1, C5 5 0.5, B4 5.5 0.5, "
    .. "A4 6 0.5, G4 6.5 0.5, F4 7 0.5, E4 7.5 0.5, D4 8 0.5, C4 8.5 0.5, D4 9 0.5, E4 9.5 0.5, F4 10 0.5, E4 10.5 0.5, D4 11 0.5, B3 11.5 0.5, C4 12 4"
  for s = 1, 3 do
    seed = 30 + s
    want, got = both(run, { jitter = 12, rit = 1.2 }, { length = 16 })
    eq(got, want, "eighths slowing until they are more than a beat behind, seed " .. s)
  end
end)

local CHORDS = "E3+G#3+B3+E4 0 1, E3+G#3+B3+E4 1 1, A3+C#4+E4+A4 2 0.5, A3+C#4+E4+A4 2.5 0.5, B3+D#4+F#4+B4 3 1"

test("score: strums are chords on the beat, in either direction, at any speed", function()
  seed = 7
  for _, case in ipairs({ { 8, 1 }, { 12, -1 }, { 18, "alt" }, { 25, 1 } }) do
    local want, got = both(CHORDS, { jitter = 15, strum = case[1], dir = case[2] }, { clef = "treble" })
    eq(got, want, case[1] .. " ms a string, direction " .. tostring(case[2]))
  end
  local _, got = both(CHORDS, { jitter = 10, strum = 60, dir = 1 }, { clef = "treble" })
  eq(got, "q <E3 G#3 B3 E4>^ q <E3 G3 B3 E4>^ e <A3 C#4 E4 A4>^ e <A3 C4 E4 A4>^ q <B3 Eb4 F#4 B4>^",
    "a slow roll (180 ms across four strings) is marked with an arpeggio sign")
  _, got = both(CHORDS, { jitter = 10, strum = 60, dir = -1 }, { clef = "treble" })
  eq(got:find("q <E3 G#3 B3 E4>v", 1, true), 1, "high to low, the arrow points down")
  local _, model = load()
  local slow = play(clean(CHORDS), { strum = 60, tempo = 60 })
  local layout = model.layout(slow, { length = 4, clef = "treble", tempo = 60, settings = { strum = 20 } })
  eq(model.text(layout):find("q <E3 G#3 B3 E4>", 1, true), nil, "with a window of 20 ms, strings 60 ms apart are not one chord")
  layout = model.layout(slow, { length = 4, clef = "treble", tempo = 60 })
  eq(model.text(layout):find("q <E3 G#3 B3 E4>^", 1, true), 1, "by default they are, with an arpeggio sign")
end)

test("score: swing is written as straight eighths", function()
  local text = "C4 0 0.5, D4 0.5 0.5, E4 1 0.5, F4 1.5 0.5, G4 2 0.5, A4 2.5 0.5, G4 3 1, E4 4 0.5, D4 4.5 0.5, C4 5 0.5, D4 5.5 0.5, E4 6 2"
  seed = 9
  for _, ratio in ipairs({ 0.6, 0.66, 0.7 }) do
    local want, got = both(text, { jitter = 8, swing = ratio }, { length = 8 })
    eq(got, want, "long-short eighths at " .. ratio .. " of the beat")
  end
  local _, model = load()
  local swung = play(clean(text), { swing = 0.66 })
  eq(model.layout(swung, { length = 8 }).score.swing ~= nil, true, "the swing is recognised")
  local straight = model.text(model.layout(swung, { length = 8, settings = { swing = "off" } }))
  eq(straight:find("3{", 1, true) ~= nil, true, "with swing off, the same notes are triplets")
end)

test("score: triplets, quarter-note triplets and 6/8", function()
  seed = 11
  local want, got = both("C4 0 0.5, D4 0.5 0.5, E4 1 0.3333333333, F4 1.3333333333 0.3333333333, G4 1.6666666667 0.3333333333, A4 2 1, G4 3 1", { jitter = 12 })
  eq(want, "e C4 e D4 3{e E4 e F4 e G4} q A4 q G4", "a beat of triplet eighths among straight eighths")
  eq(got, want, "played")
  want, got = both("C5 0 0.6666666667, B4 0.6666666667 0.6666666667, A4 1.3333333333 0.6666666667, G4 2 2", { jitter = 12 })
  eq(want, "3{q C5 q B4 q A4} h G4", "quarter-note triplets over two beats")
  eq(got, want, "played")
  seed = 13
  want, got = both("C4 0 1.5, D4 1.5 0.5, E4 2 0.5, F4 2.5 0.5, G4 3 1, A4 4 0.5, G4 4.5 1.5", { jitter = 18, tempo = 160 }, { num = 6, den = 8, length = 6, tempo = 160 })
  eq(want, "q. C4 e D4 e E4 e F4 | q G4 e A4 q. G4", "6/8 in dotted quarters")
  eq(got, want, "played")
  want = both("C4 0 0.75, D4 0.75 0.75, E4 1.5 1.5", {}, { num = 6, den = 8, length = 3 })
  eq(want, "2{e C4 e D4} q. E4", "a duplet in 6/8")
end)

test("score: grace notes, staccato, and a held note as a second voice", function()
  seed = 15
  local _, got = both("C5 0 1, E5 1 1, G5 2 2", { jitter = 8, graces = { { "D5", 1, 50, 35 }, { "F#5", 2, 45, 30 } } })
  eq(got, "q C5 q [D5]E5 h [F#5]G5", "a short note just before another is its grace note")
  seed = 19
  _, got = both("C5 0 1, D5 1 1, E5 2 1, C5 3 1", { jitter = 10, legato = 0.3 })
  eq(got, "q C5' q D5' q E5' q C5'", "quarters played short are staccato quarters, not sixteenths and rests")
  seed = 17
  local held = "E4 0 2, G4 0 0.5, A4 0.5 0.5, B4 1 0.5, C5 1.5 0.5, D5 2 1, C5 3 1"
  _, got = both(held, { jitter = 10 }, {}, 1, 1)
  eq(got, "e G4 e A4 e B4 e C5 q D5 q C5", "the melody is the first voice")
  _, got = both(held, { jitter = 10 }, {}, 1, 2)
  eq(got, "h E4 hr", "the held E under it the second")
  local _, model = load()
  local layout = model.layout(clean(held), { length = 4 })
  local evs = layout.measures[1].staves[1]
  eq(evs[1].stem, 1, "first voice: stems up")
  local second
  for _, ev in ipairs(evs) do
    if ev.voice == 2 and ev.kind == "note" then second = ev end
  end
  eq(second.stem, -1, "second voice: stems down")
end)

test("score: a grand staff's hands follow the music, not middle C", function()
  local piano = "C3+E3+G3+C5 0 1, B4 1 1, A4 2 0.5, G4 2.5 0.5, F4 3 0.5, E4 3.5 0.5, D4 4 0.5, C4 4.5 0.5, B3 5 1, C4 6 2, C3 4 4"
  seed = 21
  local _, rh = both(piano, { jitter = 10 }, { length = 8, clef = "grand" }, 1)
  eq(rh, "q C5 q B4 e A4 e G4 e F4 e E4 | e D4 e C4 q B3 h C4", "the melody goes on below middle C in the right hand")
  local _, lh = both(piano, { jitter = 10 }, { length = 8, clef = "grand" }, 2)
  eq(lh, "q <C3 E3 G3> qr hr | w C3", "the chord and the held C in the left")
end)

test("score: the performance is untouched and every written note knows its notes", function()
  local _, model = load()
  seed = 5
  local played = play(clean(CHORDS), { jitter = 15, strum = 25 })
  local before = {}
  for i, n in ipairs(played) do before[i] = n.start .. "/" .. n.length .. "/" .. n.velocity end
  local layout = model.layout(played, { length = 4, clef = "treble" })
  for i, n in ipairs(played) do eq(n.start .. "/" .. n.length .. "/" .. n.velocity, before[i], "note " .. i .. " as played") end
  local seen = {}
  for _, ev in ipairs(layout.score.events) do
    for _, n in ipairs(ev.notes) do
      seen[n.index] = true
      eq(math.abs(played[n.index].start - (ev.start + n.offset)) < 1e-9, true, "the offset from the written place is the played one")
    end
  end
  local count = 0
  for _ in pairs(seen) do count = count + 1 end
  eq(count, #played, "each played note is in one written chord")
  local raw = model.text(model.layout(played, { length = 4, clef = "treble", settings = { mode = "raw" } }))
  eq(raw ~= model.text(layout), true, "the raw view writes the strums note for note")
end)

-- Editing ----------------------------------------------------------------------------------

local function song(notes, length)
  fresh()
  local view = load()
  local track = daw.add_track({ name = "Lead" })
  track:add_device("synth")
  local clip = track:add_clip({ start = 0, length = length or 4, name = "tune", notes = notes or {} })
  daw.flush()
  daw.keymap.set_mode("n")
  view:edit(clip)
  view.value, view.dot = 1, false
  return view, clip, track
end

local function keys(text)
  daw.keymap.feed(text)
  api.undo_checkpoint()
end

--- The clip's notes as "C4@0+1 D4@1+0.5".
local function notes_of(clip)
  local out = {}
  for _, n in ipairs(clip:notes()) do out[#out + 1] = string.format("%s@%g+%g", daw.music.name(n.pitch), n.start, n.length) end
  return table.concat(out, " ")
end

test("notation: :notation opens the clip under the cursor, with the keyboard", function()
  local view, clip, track = song({ N(67, 1, 1) })
  daw.ui.focus("arrange")
  view.clip_id = nil
  daw.cursor.set_track(track)
  daw.cursor.beat = 0
  daw.cmd("notation")
  eq(view.clip_id, clip.id, "the clip is open")
  eq(daw.ui.focused, "notation", "and has the keyboard")
  eq(view.step, 39, "the cursor on the first note's line (G4)")
  eq(view.beat, 1, "at its time")
  local found
  for _, entry in ipairs(daw.frontend.menus.clip) do
    if entry.command == "notation.open" then found = entry end
  end
  eq(found and found.only, "midi", "the clip menu offers it for MIDI clips")
  local mapped
  for _, m in ipairs(daw.keymap.list("n", "arrange")) do
    if m.lhs == "<leader>n" then mapped = m.rhs end
  end
  eq(mapped, "notation", "and the arrange view has a key for it")
end)

test("notation: insert mode enters notes by letter, nearest the note before", function()
  local view, clip = song()
  keys("icdeb")
  eq(notes_of(clip), "C4@0+1 D4@1+1 E4@2+1 B3@3+1", "quarters by letter, B below C rather than above")
  keys("<Esc>")
  view:set(39, 0)
  keys("i4ga'")
  eq(notes_of(clip), "G4@0+0.5 A5@0.5+0.5 D4@1+1 E4@2+1 B3@3+1", "eighths replace what was there; ' lifts the last an octave")
end)

test("notation: entering in a key takes its sharps and flats; + and - change the last note", function()
  local view, clip = song()
  daw.cmd("notation.key", { "D", "major" })
  api.undo_checkpoint()
  keys("if")
  eq(notes_of(clip), "F#4@0+1", "f is F sharp in D major")
  keys("+c-")
  eq(notes_of(clip), "G4@0+1 C4@1+1", "+ raises the F sharp to G; c is C sharp, and - lowers it to C natural")
  eq(clip:notes()[2].meta.notation.letter, 0, "written as a C")
  eq(clip:notes()[2].meta.notation.alter, 0, "with a natural sign")
end)

test("notation: chords with capitals, rests, dots and the value keys", function()
  local view, clip = song(nil, 8)
  keys("iCEg")
  eq(notes_of(clip), "C4@0+1 E4@0+1 G4@0+1", "C and E stay, g steps on")
  keys("6.c")
  eq(notes_of(clip), "C4@0+1 E4@0+1 G4@0+1 C5@1+3", "a dotted half")
  keys("r")
  eq(view.beat, 7, "a rest steps on by the value")
  keys("<BS><BS>")
  eq(notes_of(clip), "C4@0+1 E4@0+1 G4@0+1", "backspace steps back and removes")
end)

test("notation: normal keys move by lines and spaces and edit the note under the cursor", function()
  local view, clip = song({ N(64, 0, 1), N(67, 3, 1) })
  view:set(37, 0)
  keys("k")
  eq(view.step, 38, "k: up a line or space")
  keys("j<C-a>")
  eq(notes_of(clip), "F4@0+1 G4@3+1", "Ctrl-a sharpens the E: E sharp")
  keys("<C-x><A-k>")
  eq(view:note() and select(3, view:note()).alter, 0, "spelled F natural")
  eq(notes_of(clip), "F4@0+1 G4@3+1", "flatten back, then up a step of the key")
  keys("}")
  eq(notes_of(clip), "F5@0+1 G4@3+1", "up an octave")
  keys("+")
  eq(notes_of(clip), "F5@0+2 G4@3+1", "lengthened by the chosen quarter")
  keys("g.")
  eq(notes_of(clip), "F5@0+3 G4@3+1", "dotted")
  keys("x")
  eq(notes_of(clip), "G4@3+1", "deleted")
  keys("u")
  eq(notes_of(clip), "F5@0+3 G4@3+1", "and back with undo")
end)

test("notation: a note played loosely keeps its timing when it is edited", function()
  local view, clip = song({ { pitch = 64, start = 0.02, length = 0.95, velocity = 77 } })
  view:set(37, 0)
  keys("<A-k>")
  local n = clip:notes()[1]
  eq(n.start, 0.02, "moving it up a step keeps when it was played")
  keys("+")
  n = clip:notes()[1]
  eq(n.start, 0.02, "lengthened, it still starts as played")
  eq(math.abs(n.length - 1.9) < 1e-9, true, "and its played length is doubled with the written quarter")
  eq(n.velocity, 77, "as loud as it was")
  eq(view:layout().score.events[1].length, 2, "written a half note")
end)

local function model_text_has(view, text)
  local _, model = load()
  return model.text((view:layout())):find(text, 1, true) ~= nil
end

local function played(clip)
  local out = {}
  for _, n in ipairs(clip:notes()) do out[#out + 1] = string.format("%s@%.3f+%.3f/%d", daw.music.name(n.pitch), n.start, n.length, n.velocity) end
  return table.concat(out, " ")
end

test("score editing: a chord moved, lengthened or deleted moves its played notes", function()
  local strum = {
    { pitch = 52, start = 1.01, length = 0.9, velocity = 90 }, { pitch = 56, start = 1.04, length = 0.85, velocity = 80 },
    { pitch = 59, start = 1.07, length = 0.8, velocity = 70 }, { pitch = 72, start = 5.0, length = 1, velocity = 64 },
  }
  local view, clip = song(strum, 8)
  daw.cmd("notation.clef", { "treble" })
  view.cache = nil
  eq(view:layout().score.events[1].start, 1, "the strum is written on beat two")
  view:set(37, 1)
  keys("<A-l>")
  eq(played(clip), "E3@2.010+0.900/90 G#3@2.040+0.850/80 B3@2.070+0.800/70 C5@5.000+1.000/64",
    "a beat later, strummed and as loud as before")
  eq(view.beat, 2, "the cursor goes with it")
  keys("+")
  eq(played(clip):find("E3@2.010+1.800/90 G#3@2.040+1.700/80 B3@2.070+1.600/70", 1, true) ~= nil, true, "a half note: each played length doubled")
  keys("X")
  eq(played(clip), "C5@5.000+1.000/64", "the chord deleted, all of it")
  keys("u")
  eq(#clip:notes(), 4, "and back")
end)

test("score editing: a note put in goes exactly on the grid, as loud as those around it", function()
  local view, clip = song({ { pitch = 60, start = 0.03, length = 0.9, velocity = 50 }, { pitch = 62, start = 1.02, length = 0.9, velocity = 54 } })
  view:set(37, 2)
  keys("<CR>")
  local n = clip:notes()[3]
  eq(n.start, 2, "on beat three exactly")
  eq(n.velocity, 52, "as loud as the notes near it")
  view:set(35, 0)
  keys("i")
  keys("e")
  keys("<Esc>")
  eq(played(clip):sub(1, 18), "E4@0.000+1.000/52 ", "entering over a loosely played C replaces it")
end)

test("score editing: quantize to the notation, and write again from the playing", function()
  local view, clip = song({ { pitch = 60, start = 0.03, length = 0.4, velocity = 80 }, { pitch = 62, start = 0.52, length = 0.45, velocity = 80 },
    { pitch = 64, start = 0.98, length = 1.9, velocity = 80 } })
  api.undo_checkpoint()
  daw.cmd("notation.quantize")
  api.undo_checkpoint()
  eq(notes_of(clip), "C4@0+0.5 D4@0.5+0.5 E4@1+2", "each note as written")
  keys("u")
  eq(clip:notes()[1].start, 0.03, "undone")
  view:set(35, 0)
  keys("=in")
  eq(clip:notes()[1].start, 0, "= on the note under the cursor")
  eq(clip:notes()[2].start, 0.52, "and on that one only")
end)

test("score editing: overrides are kept with the notes and survive edits elsewhere", function()
  local view, clip = song({ N(64, 0, 2), N(67, 0, 0.5), N(69, 0.5, 0.5), N(71, 1, 0.5), N(72, 1.5, 0.5), N(74, 2, 2) })
  local _, model = load()
  eq(model.text(view:layout(), 1, 2), "h E4 hr", "the held E is a second voice")
  view:set(37, 0)
  keys("gv")
  eq(clip:notes()[1].meta.notation.voice, 1, "into the first voice, kept with the note")
  eq(model.text(view:layout(), 1, 2), "", "no second voice left")
  view:set(39, 0)
  keys("gv")
  eq(clip:notes()[2].meta.notation.voice, 2, "the G marked as the second voice")
  -- An edit elsewhere: the last note moved; the G keeps its voice.
  clip:set_note(6, { start = 3 })
  view.cache = nil
  local found
  for _, ev in ipairs(view:layout().score.events) do
    for _, n in ipairs(ev.notes) do
      if n.pitch == 67 then found = ev.voice end
    end
  end
  eq(found, 2, "the override is still there")
  view:set(41, 1)
  keys("gt")
  eq(clip.meta.notation.tuplets[1].n, 3, "beat two in triplets, kept with the clip")
  keys("gt")
  eq(clip.meta.notation, nil, "and off")
  daw.cmd("notation.retranscribe")
  api.undo_checkpoint()
  eq((clip:notes()[2].meta or {}).notation, nil, "write again from the playing: overrides gone")
end)

test("score editing: grace notes, strums, beams and spelling by key", function()
  local view, clip = song({ N(72, 0, 0.5), N(74, 0.5, 0.5), N(76, 1, 0.5), N(77, 1.5, 0.5), N(60, 2, 1), N(64, 2, 1), N(67, 2, 1) })
  local _, model = load()
  view:set(43, 0.5)
  keys("gb")
  eq(view:layout().measures[1].staves[1][1].beam, nil, "the beam broken before the D: the C stands alone")
  view:set(43, 0.5)
  keys("gG")
  eq(model.text((view:layout())):find("[D5]E5", 1, true) ~= nil, true, "the D a grace note of the E")
  view:set(35, 2)
  keys("gs")
  eq(model.text((view:layout())):find("<C4 E4 G4>^", 1, true) ~= nil, true, "an arpeggio sign on the chord")
  view:set(45, 1.5)
  keys("ge")
  eq(model.text((view:layout())):find("E#5", 1, true) ~= nil, true, "F respelled as E sharp")
end)

test("notation: Enter adds a note of the chosen value at the cursor and takes it away", function()
  local view, clip = song()
  view:set(39, 2)
  keys("g4<CR>")
  eq(notes_of(clip), "G4@2+0.5", "an eighth at the cursor")
  keys("<CR>")
  eq(notes_of(clip), "", "and gone")
end)

test("notation: operators and visual mode work on notes as in the piano roll", function()
  local view, clip = song({ N(60, 0, 1), N(62, 1, 1), N(64, 2, 1), N(65, 3, 1) })
  view:set(35, 0)
  keys("dw")
  eq(notes_of(clip), "D4@1+1 E4@2+1 F4@3+1", "dw deletes up to the next note")
  view:set(36, 1)
  keys("vll<A-k>")
  eq(notes_of(clip), "E4@1+1 F4@2+1 F4@3+1", "a selection from beat two up to the cursor on beat four, up a step of the key")
  view:set(38, 2)
  keys("vl<C-a>")
  eq(notes_of(clip), "E4@1+1 F#4@2+1 F4@3+1", "Ctrl-a on a selection")
  view:set(38, 3)
  keys("yinP")
  eq(#clip:notes(), 3, "yank and paste over itself")
end)

test("notation: w, b and W move by what is written", function()
  local view = song({ N(60, 0, 1.5), N(62, 1.5, 0.5), N(64, 2, 2), N(65, 4, 4) }, 8)
  view:set(35, 0)
  keys("w")
  eq(view.beat, 1.5, "w: the next note")
  keys("w")
  eq(view.beat, 2, "and the next")
  keys("b")
  eq(view.beat, 1.5, "b: back")
  keys("W")
  eq(view.beat, 4, "W: the next bar")
end)

test("notation: :notation.key and :notation.clef keep the key with the project and the clef with the track", function()
  local view, clip, track = song({ N(72, 0, 1) })
  daw.cmd("notation.key", { "Eb", "major" })
  api.undo_checkpoint()
  eq(api.project_get().meta.musicops.root, "Eb", "the key is the project's, where musicops keeps it")
  eq(view:layout().fifths, -3, "three flats")
  daw.cmd("notation.clef", { "bass" })
  api.undo_checkpoint()
  eq(track.meta.notation.clef, "bass", "the clef is the track's")
  eq(view:layout().staves[1], "bass", "and the notation follows")
  keys("u")
  eq(view:layout().staves[1], "treble", "undone like any edit")
end)

test("notation: the terminal draws the staff, clef, key, heads, stems and beams", function()
  local view = song({ N(72, 0, 0.5), N(74, 0.5, 0.5), N(76, 1, 1), N(65, 2, 2) })
  daw.cmd("notation.key", { "D", "major" })
  local text = table.concat(api.ui_snapshot(120, 40), "\n")
  eq(text:find("G", 1, true) ~= nil, true, "a treble clef")
  eq(select(2, text:gsub("♯", "")) >= 2, true, "two sharps in the key signature")
  eq(select(2, text:gsub("●", "")) >= 3, true, "filled heads for the eighths and the quarter")
  eq(text:find("○", 1, true) ~= nil, true, "an open head for the half note")
  eq(text:find("♮", 1, true) ~= nil, true, "F natural against the key")
  eq(text:find("━", 1, true) ~= nil, true, "a beam over the eighths")
  eq(text:find("tune", 1, true) ~= nil and text:find("D major", 1, true) ~= nil, true, "the title says the clip and the key")
end)

test("score: the clip keeps its settings, and the view reads the song's bars", function()
  local view, clip = song(clean("C4 0 0.5, D4 0.5 0.5"), 8)
  daw.cmd("notation.set", { "voices", "off" })
  api.undo_checkpoint()
  eq(clip.meta.notation.settings.voices, false, "kept in clip.meta.notation")
  eq(view.settings_of(clip:get()).voices, false, "and read back")
  daw.cmd("notation.raw")
  api.undo_checkpoint()
  eq(view:layout().score.swing, nil, "raw")
  eq(clip.meta.notation.settings.mode, "raw", "the raw view is a setting of the clip")
  keys("u")
  eq(clip.meta.notation.settings.mode, nil, "undone like any edit")
  local was = daw.time.signature_at
  daw.time.signature_at = function(beat) if beat < 4 then return 4, 4 end return 3, 4 end
  view.cache = nil
  local layout = view:layout()
  daw.time.signature_at = was
  eq(#layout.measures, 3, "a bar of 4/4 and two of 3/4 in eight beats")
  eq(layout.measures[2].meter.num, 3, "the second bar in 3/4")
  view.cache = nil
end)

test("marks: articulations are written and played", function()
  local view, clip = song({ N(72, 0, 1), N(74, 1, 1), N(76, 2, 1), N(77, 3, 1) })
  view:set(42, 0)
  keys("g'")
  eq(clip:notes()[1].length, 0.5, "staccato: played half its written length")
  eq(clip:notes()[1].meta.notation.art.staccato, true, "and kept as a mark on the note")
  local ev = view:layout().measures[1].staves[1][1]
  eq(ev.art.staccato, true, "the written note carries it")
  eq(model_text_has(view, "q C5"), true, "still written a quarter")
  keys("g'")
  eq(clip:notes()[1].length, 0.9, "taken away: played long again")
  view:set(43, 1)
  local before = clip:notes()[2].velocity
  keys("g>")
  eq(clip:notes()[2].velocity, before + 20, "an accent: louder")
  keys("g>")
  eq(clip:notes()[2].velocity, before, "and back")
  view:set(44, 2)
  keys("vlg_")
  eq(clip:notes()[3].meta.notation.art.tenuto, true, "on a selection")
end)

test("marks: dynamics set the loudness, hairpins ramp it, slurs join the notes", function()
  local notes = {}
  for i = 0, 7 do notes[#notes + 1] = { pitch = 72, start = i, length = 0.5, velocity = 60 + (i % 2) * 10 } end
  local view, clip = song(notes, 8)
  view:set(42, 0)
  daw.cmd("notation.dyn", { "f" })
  api.undo_checkpoint()
  local v = {}
  for i, n in ipairs(clip:notes()) do v[i] = n.velocity end
  eq(v[1] >= 88 and v[1] <= 96, true, "f: the stretch moved to about 96")
  eq(math.abs(v[2] - v[1] - 10) <= 2, true, "the player's difference between the notes stays")
  eq(clip.meta.notation.marks[1].value, "f", "the dynamic is kept with the clip")
  view:set(42, 0)
  daw.cmd("notation.dyn", { "p" })
  view:set(42, 4)
  daw.cmd("notation.dyn", { "f" })
  view:set(42, 0)
  keys("vlll")
  daw.cmd("notation.cresc")
  keys("<Esc>")
  for i, n in ipairs(clip:notes()) do v[i] = n.velocity end
  eq(v[1] < v[3] and v[3] < v[5] and v[2] < v[4], true, "a crescendo from p to f: louder beat by beat, the player's accents kept")
  eq(v[5] >= 91 and v[5] <= 101, true, "reaching the f")
  local m = view:layout().measures[1]
  eq(#m.marks >= 2, true, "the hairpin is on the measure, to be drawn")
  daw.cmd("notation.slur")
  local xml = require("notation.export").musicxml(view:layout(), {})
  eq(xml:find("<dynamics><f/></dynamics>", 1, true) ~= nil, true, "MusicXML carries the dynamic")
  eq(xml:find('<wedge type="crescendo"/>', 1, true) ~= nil, true, "and the hairpin")
end)

test("tablature: a guitar track gets strings and frets, and the guitar's clef", function()
  local view, clip, track = song(clean("E2+B2+E3+G#3+B3+E4 0 1, A2 1 1, C4 2 1, G2+B2+D3+G3+B3+G4 3 1"), 4)
  daw.cmd("notation.tab", { "guitar" })
  api.undo_checkpoint()
  eq(track.meta.notation.tab.tuning[1], 40, "standard tuning kept with the track, low E first")
  view.cache = nil
  local layout = view:layout()
  eq(layout.staves[1], "treble8", "written in the guitar's treble clef, an octave up")
  local frets = {}
  for _, ev in ipairs(layout.measures[1].staves[1]) do
    if ev.kind == "note" then
      local out = {}
      for _, n in ipairs(ev.notes) do out[#out + 1] = (n.string or "?") .. ":" .. (n.fret or "?") end
      frets[#frets + 1] = table.concat(out, " ")
    end
  end
  eq(frets[1], "6:0 5:2 4:2 3:1 2:0 1:0", "an open E chord as a guitarist plays it")
  eq(frets[2], "5:0", "the open A string")
  eq(frets[3], "2:1", "C on the B string, first fret, near where the hand is")
  eq(frets[4], "6:3 5:2 4:0 3:0 2:0 1:3", "an open G chord")
  local text = table.concat(api.ui_snapshot(120, 40), "\n")
  eq(text:find("E ─", 1, true) ~= nil or text:find("E─", 1, true) ~= nil, true, "the terminal draws the strings, named")
  daw.cmd("notation.tab", { "off" })
  view.cache = nil
  eq(view:layout().tab, nil, "and takes them away")
end)

test("several tracks: one system of staves, to read; lyrics under the notes", function()
  local view, clip, track = song({ { pitch = 72, start = 0, length = 1, velocity = 90, meta = { lyric = "la" } }, N(74, 1, 1) }, 4)
  local bass = daw.add_track({ name = "Bass" })
  bass:add_clip({ start = 0, length = 4, notes = { N(40, 0, 2), N(43, 2, 2) } })
  daw.flush()
  local ev = view:layout().measures[1].staves[1][1]
  eq(ev.lyric, "la", "the note's lyric is written under it")
  local xml = require("notation.export").musicxml(view:layout(), {})
  eq(xml:find("<text>la</text>", 1, true) ~= nil, true, "and exported")
  keys("gT")
  local layout = view:layout()
  eq(#layout.staves, 2, "two staves: the clip's track and the bass")
  eq(layout.names[2], "Bass", "each named")
  local _, model = load()
  eq(model.text(layout, 2), "h E2 h G2", "the bass's notes on its staff")
  local before = notes_of(clip)
  view:set(42, 0)
  keys("x")
  eq(notes_of(clip), before, "read only: nothing is deleted")
  keys("gT")
  eq(#view:layout().staves, 1, "and back to the clip alone")
end)

-- The window -----------------------------------------------------------------------------------

local function paint(view)
  return daw.canvas.paint("notation", 1100, 560)
end

local function pointer(kind, x, y, extra)
  daw.canvas.pointer("notation", daw.util.merge({ kind = kind, x = x, y = y, button = "left" }, extra or {}))
  api.undo_checkpoint()
end

--- Where a beat and staff step are in the window, after a paint.
local function spot(view, beat, step)
  local model = require("notation.model")
  local engrave = require("notation.engrave")
  local gui = view.gui
  local eng = gui.engraved
  local layout = view:layout()
  for _, sys in ipairs(eng.systems) do
    for _, placed in ipairs(sys.measures) do
      local m = placed.m
      if beat >= m.start and beat < m.start + m.length then
        local pos = step - model.CLEF_BOTTOM[layout.staves[1]]
        return placed.x + model.x_of(placed.p, beat) - (view.galley and gui.hscroll or 0),
          engrave.y_of(eng.style, sys, 1, pos) + gui.area.top - gui.scroll
      end
    end
  end
end

test("notation window: it engraves notes, stems, beams and the clef with the music font", function()
  local view = song({ N(72, 0, 0.5), N(74, 0.5, 0.5), N(76, 1, 1), N(67, 2, 2) })
  local drawing = daw.canvas.paint("notation", 1100, 560, { glyphs = true })
  local glyphs, layers, cuts = {}, {}, 0
  for _, op in ipairs(drawing.ops) do
    if op[1] == "g" and layers[#layers] == "ink" then glyphs[op[5]] = (glyphs[op[5]] or 0) + 1 end
    if op[1] == "layer" then layers[#layers + 1] = op[2] end
    if op[1] == "cut" then cuts = cuts + 1 end
  end
  eq(glyphs[0xE0A4], 3, "three black note heads (Leland's noteheadBlack)")
  eq(glyphs[0xE0A3], 1, "a half note's head")
  eq(glyphs[0xE050], 1, "a treble clef")
  eq(table.concat(layers, " "), "ink selection ghost diagnostic caret playhead", "the page's ink, then what moves over it, as layers")
  eq(cuts >= 1, true, "and where a frontend may cut it at a barline")
  eq(#view.gui.heads, 4, "four note heads, each remembered for the pointer")
  local paths = 0
  for _, op in ipairs(paint(view).ops) do
    if op[1] == "g" then error("a frontend that does not draw glyphs is given none") end
    if op[1] == "p" then paths = paths + 1 end
  end
  eq(paths > 10, true, "the window is given each glyph as a path from the font's outline")
end)

test("notation window: staff lines, stems and barlines are on whole pixels, systems whole cell rows", function()
  local view = song({ N(72, 0, 0.5), N(74, 0.5, 0.5), N(76, 1, 1), N(67, 2, 2), N(60, 4, 4), N(64, 8, 1) }, 16)
  local drawing = daw.canvas.paint("notation", 1053, 600, { glyphs = true, surface = true, cell = { w = 13, h = 27 }, colors = { fg = "#cdd6f4", bg = "#1e1e2e" } })
  local whole = true
  for _, op in ipairs(drawing.ops) do
    if op[1] == "r" then
      for i = 2, 5 do whole = whole and op[i] == math.floor(op[i]) end
    end
    eq(op[1] ~= "t" or op[4] ~= "midi", true, "no toolbar on a terminal's surface")
  end
  eq(whole, true, "every rectangle on whole pixels")
  eq(drawing.ops[1][1], "layer", "no background: the terminal's own shows")
  local eng = view.gui.engraved
  eq(eng.style.sp, 9, "a staff space of a third of a 27 px cell")
  for _, sys in ipairs(eng.systems) do
    eq(sys.height % 27, 0, "each system whole rows of cells high")
    for _, placed in ipairs(sys.measures) do eq(placed.x % 13, 0, "each measure starting on a whole column") end
  end
  eq(eng.systems[1].height <= 6 * 27, true, "a single staff in no more than six rows")
end)

test("notation window: in normal mode a click chooses, a drag moves a note, a right click opens a menu", function()
  local view, clip = song({ N(67, 1, 0.5) }, 4)
  daw.ui.focus("notation")
  paint(view)
  local x, y = spot(view, 2, 39)
  pointer("down", x, y)
  pointer("up", x, y)
  eq(notes_of(clip), "G4@1+0.5", "a click on the paper adds nothing")
  eq(view.beat, 2, "it puts the cursor there")
  paint(view)
  local hx, hy = spot(view, 1, 39)
  local tx, ty = spot(view, 2, 41)
  pointer("down", hx, hy)
  eq(view.beat, 1, "a click on a note puts the cursor on it")
  pointer("move", (hx + tx) / 2, (hy + ty) / 2)
  pointer("move", tx, ty)
  pointer("up", tx, ty)
  eq(notes_of(clip), "B4@2+0.5", "dragged two steps up and a beat later")
  paint(view)
  local rx, ry = spot(view, 2, 41)
  pointer("down", rx, ry, { button = "right" })
  eq(require("daw.menu").is_open(), true, "a right click opens a menu")
  keys("<CR>")
  eq(notes_of(clip), "", "its first entry deletes the note")
end)

test("notation window: Shift extends a selection, a drag on the paper selects a box", function()
  local view = song({ N(60, 0, 1), N(62, 1, 1), N(64, 2, 1), N(65, 3, 1) }, 4)
  daw.ui.focus("notation")
  paint(view)
  local x, y = spot(view, 0, 35)
  pointer("down", x, y)
  pointer("up", x, y)
  local x2, y2 = spot(view, 2, 37)
  pointer("down", x2, y2, { shift = true })
  local sel = daw.keymap.selection()
  eq(sel and sel.c0, 0, "a selection from the cursor")
  eq(sel and sel.c1 >= 2, true, "to the note clicked with Shift")
  keys("<Esc>")
  paint(view)
  local ax, ay = spot(view, 1, 33)
  local bx, by = spot(view, 3, 40)
  pointer("down", ax, ay)
  pointer("move", bx, by)
  pointer("up", bx, by)
  sel = daw.keymap.selection()
  eq(sel and sel.kind, "block", "a box drawn on the paper selects a block")
  keys("<Esc>")
end)

test("notation window: a double click enters notes there; in insert mode a click enters a note and the note to enter follows the pointer", function()
  local view, clip = song(nil, 4)
  daw.ui.focus("notation")
  paint(view)
  view.value = 0.5
  local x, y = spot(view, 1, 39)
  pointer("double", x, y)
  eq(daw.keymap.mode, "i", "a double click enters notes")
  local hx, hy = spot(view, 2, 41)
  daw.canvas.pointer("notation", { kind = "hover", x = hx, y = hy })
  eq(view.gui.hover and view.gui.hover.step, 41, "the note to enter follows the pointer")
  local drawing = daw.canvas.paint("notation", 1100, 560, { glyphs = true })
  local in_caret, heads = false, 0
  for _, op in ipairs(drawing.ops) do
    if op[1] == "layer" then in_caret = op[2] == "caret" end
    if in_caret and op[1] == "g" and op[5] == 0xE0A4 then heads = heads + 1 end
  end
  eq(heads, 1, "drawn half transparent in the caret's layer")
  pointer("down", x, y)
  pointer("up", x, y)
  eq(notes_of(clip), "G4@1+0.5", "a click enters an eighth G on beat two")
  keys("<Esc>")
end)

test("notation window: the toolbar chooses the value, the accidental and rests", function()
  local view, clip = song({ N(64, 0, 4) }, 4)
  paint(view)
  local function press(label)
    for _, b in ipairs(view.gui.buttons) do
      if b.label == label then return pointer("down", b.x + 4, b.y + 4) end
    end
    error("no button " .. label)
  end
  press("half")
  eq(view.value, 2, "half notes")
  press("sharp")
  keys("i")
  paint(view)
  local x, y = spot(view, 2, 38)
  pointer("down", x, y)
  pointer("up", x, y)
  eq(notes_of(clip), "E4@0+2 F#4@2+2", "an F sharp half note; the E is cut to end where it starts")
  press("rest")
  paint(view)
  x, y = spot(view, 2, 38)
  pointer("down", x, y)
  eq(notes_of(clip), "E4@0+2", "a rest clears it")
end)

--- The ops of a layer of a drawing.
local function layer_ops(drawing, name)
  local out, current = {}, nil
  for _, op in ipairs(drawing.ops) do
    if op[1] == "layer" then current = op[2] elseif current == name then out[#out + 1] = op end
  end
  return out
end

local function surface_paint()
  return daw.canvas.paint("notation", 1053, 800, { glyphs = true, surface = true, cell = { w = 13, h = 27 } })
end

test("notation page: the selection, suggestions, diagnostics and the playhead are layers over the ink", function()
  local view, clip = song({ N(60, 0, 1), N(62, 1, 1), N(64, 2, 1), N(65, 3, 1) }, 8)
  daw.ui.focus("notation")
  view:set(35, 0)
  keys("vl")
  local d = surface_paint()
  local sel = layer_ops(d, "selection")
  eq(sel[1] and sel[1][1], "r", "a faint band over the selection")
  eq(#sel >= 2, true, "and its notes again in the accent")
  keys("<Esc>")
  daw.complete.show({ { label = "next", notes = { { pitch = 67, start = 4, length = 1 } } } }, { clip = clip.id, keys = false })
  local ghosts = 0
  for _, op in ipairs(layer_ops(surface_paint(), "ghost")) do
    if op[1] == "g" then ghosts = ghosts + 1 end
  end
  eq(ghosts, 1, "a suggested note laid out where it would be written")
  daw.complete.dismiss()
  daw.diagnostic.set("test", clip.id, { { notes = { 2 }, severity = "warning", message = "a leap" } })
  local diag = layer_ops(surface_paint(), "diagnostic")
  local wave, tinted = false, false
  for _, op in ipairs(diag) do
    if op[1] == "p" then wave = true end
    if op[1] == "g" then tinted = true end
  end
  eq(wave and tinted, true, "a wavy line under the staff and the note tinted")
  view:set(37, 1)
  eq(view:status_text(), "a leap", "its message on the cursor's note")
  daw.diagnostic.reset("test", clip.id)
  api.transport_seek(2)
  local play = layer_ops(surface_paint(), "playhead")
  eq(play[1] and play[1][4], 2, "a 2 px playhead")
end)

test("notation page: a cursor move draws the page from what was engraved; an edit engraves only the measures it changed", function()
  local view, clip = song({ N(60, 0, 1), N(62, 4, 1), N(64, 8, 1), N(65, 12, 1) }, 16)
  daw.ui.focus("notation")
  surface_paint()
  local cache = view.gui.measures
  local made = cache.count
  view:move(1, 0)
  surface_paint()
  eq(cache.count, made, "moving the cursor engraves nothing")
  clip:set_note(2, { pitch = 65 })
  surface_paint()
  eq(cache.count, made + 1, "an edit in one bar engraves that bar again")
  local bench = require("notation.bench")
  local r = bench.run(16, { glyphs = true, surface = true, cell = { w = 13, h = 27 } }, 5)
  -- Loose bounds, for a busy machine: the targets are 8 and 30 ms.
  eq(r.cursor < 80, true, "a cursor move paints quickly (" .. string.format("%.1f", r.cursor) .. " ms)")
  eq(r.edit < 300, true, "an edit paints quickly (" .. string.format("%.1f", r.edit) .. " ms)")
end)

test("notation page: the galley is one long system that keeps the cursor in view", function()
  local notes = {}
  for i = 0, 63 do notes[#notes + 1] = N(60 + i % 12, i, 1) end
  local view = song(notes, 64)
  daw.ui.focus("notation")
  keys("zg")
  eq(view.galley, true, "zg: one long system")
  surface_paint()
  eq(#view.gui.engraved.systems, 1, "every measure in one system")
  view:set(nil, 60)
  surface_paint()
  local _, x = view.gui.at_beat(view.gui.engraved, 60)
  local shown = x - view.gui.hscroll
  eq(shown > 0 and shown < 1053, true, "scrolled sideways to the cursor")
  keys("zg")
  eq(view.galley, false, "and back to wrapped systems")
end)

test("notation insert: an interval above, a tie, triplets and the last chord again", function()
  local view, clip = song(nil, 4)
  keys("i")
  keys("C<A-3><A-3>")
  eq(notes_of(clip), "C4@0+1 E4@0+1 G4@0+1", "Alt-3 twice: a third above, and a third above that, a chord")
  keys("<Space>")
  eq(view.beat, 1, "Space steps on")
  keys("R")
  eq(notes_of(clip), "C4@0+1 E4@0+1 G4@0+1 C4@1+1 E4@1+1 G4@1+1", "R: the chord again")
  keys("e~")
  eq(notes_of(clip):match("E4@2%+2") ~= nil, true, "~ holds the note just entered on by the value")
  eq(view.beat, 4, "and steps on")
  keys("<Esc>")
  local view2, clip2 = song(nil, 4)
  keys("i4tcde<Esc>")
  local _ = view2
  eq(notes_of(clip2), "C4@0+0.333333 D4@0.333333+0.333333 E4@0.666667+0.333333", "t: eighth triplets")
end)

-- Export -------------------------------------------------------------------------------------

test("notation export: LilyPond source writes what is shown", function()
  local _, model = load()
  local export = require("notation.export")
  local layout = model.layout({ N(74, 0, 1.5), N(73, 1.5, 0.5), N(71, 2, 3), N(48, 6, 1) }, { length = 8, fifths = 2 })
  local ly = export.lilypond(layout, { title = "tune" })
  eq(ly:find("\\key d \\major", 1) ~= nil, true, "the key")
  eq(ly:find("\\new PianoStaff", 1, true) ~= nil, true, "a grand staff for notes on both sides of middle C")
  eq(ly:find("d''4. cis''8 b'2~ |", 1, true) ~= nil, true, "values, octaves, sharps and the tie, bar by bar")
  eq(ly:find("R1*4/4", 1, true) ~= nil, true, "a whole bar's rest")
  eq(ly:find("c4 r4 |", 1, true) ~= nil, true, "the bass staff's C")
end)

test("notation export: MusicXML has the key, ties, beams and accidentals", function()
  local _, model = load()
  local export = require("notation.export")
  local layout = model.layout({ N(72, 0, 0.5), N(74, 0.5, 0.25), N(76, 0.75, 0.25), N(65, 1, 2), N(67, 3, 2) }, { length = 8, fifths = 2 })
  local xml = export.musicxml(layout, { title = "tune", part = "Lead" })
  eq(xml:find("<fifths>2</fifths>", 1, true) ~= nil, true, "two sharps")
  eq(xml:find("<accidental>natural</accidental>", 1, true) ~= nil, true, "F natural in D major")
  eq(xml:find('<beam number="1">begin</beam>', 1, true) ~= nil and xml:find('<beam number="2">end</beam>', 1, true) ~= nil, true, "beams with a second level")
  eq(xml:find('<tie type="start"/>', 1, true) ~= nil and xml:find('<tied type="stop"/>', 1, true) ~= nil, true, "a tie across the barline")
  eq(select(2, xml:gsub("<measure ", "")), 2, "two measures")
end)

test("notation export: tuplets, voices, grace notes and strums go out in both formats", function()
  local _, model = load()
  local export = require("notation.export")
  local notes = clean("E4 0 2, G4 0 0.5, A4 0.5 0.5, B4 1 0.3333333333, C5 1.3333333333 0.3333333333, D5 1.6666666667 0.3333333333, E5 2 2")
  table.insert(notes, { pitch = 77, start = 1.94, length = 0.05, velocity = 60 })   -- a grace note into beat three
  table.sort(notes, function(a, b) return a.start < b.start end)
  local layout = model.layout(notes, { length = 4 })
  local xml = export.musicxml(layout, { title = "t" })
  eq(xml:find("<actual-notes>3</actual-notes><normal-notes>2</normal-notes>", 1, true) ~= nil, true, "a triplet's time modification")
  eq(xml:find('<tuplet type="start" bracket="yes"/>', 1, true) ~= nil, true, "and its bracket")
  eq(xml:find("<voice>2</voice>", 1, true) ~= nil and xml:find("<backup>", 1, true) ~= nil, true, "the held E in voice 2, after a backup")
  eq(xml:find('<grace slash="yes"/>', 1, true) ~= nil, true, "a grace note")
  local ly = export.lilypond(layout, {})
  eq(ly:find("\\tuplet 3/2 {", 1, true) ~= nil, true, "LilyPond: the tuplet")
  eq(ly:find("\\voiceTwo", 1, true) ~= nil, true, "LilyPond: the second voice")
  eq(ly:find("\\acciaccatura { f''8 }", 1, true) ~= nil, true, "LilyPond: the grace note")
end)

test("notation export: :notation.export writes a file for the clip or the whole track", function()
  local _, clip, track = song({ N(72, 0, 1), N(74, 1, 1) })
  track:add_clip({ start = 8, length = 4, name = "more", notes = { N(76, 0, 4) } })
  local path = T.scratch .. "/notation-test.ly"
  daw.cmd("notation.export", { path, "track" })
  local f = io.open(path, "rb")
  local text = f and f:read("*a") or ""
  if f then f:close() end
  eq(text:find("c''4 d''4", 1, true) ~= nil, true, "the first clip")
  eq(text:find("e''1", 1, true) ~= nil, true, "and the second, in its bar")
end)
