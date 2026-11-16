-- Tests of the REAPER bridge, run by tests/suite.lua (`daw --clean -l tests/suite.lua rpp`).
local T = ...
local daw = require("daw")
local api = daw.api
local test, eq, near, fails = T.test, T.eq, T.near, T.fails

local HERE = "extensions/rpp"
local FIXTURES = HERE .. "/fixtures/"

local rpp
local function load()
  if not rpp then
    daw.ext.load(HERE)
    rpp = require("rpp")
  end
  return rpp
end

local function has(kind)
  for _, t in ipairs(api.device_types()) do
    if t.kind == kind then return true end
  end
  return false
end

--- A mono 16-bit WAV of a sine.
local function write_wav(path, seconds, freq, level)
  local rate = 44100
  local n = math.floor(seconds * rate)
  local samples = {}
  for i = 0, n - 1 do
    local v = math.floor(math.sin(2 * math.pi * freq * i / rate) * (level or 0.5) * 32767 + 0.5)
    if v < 0 then v = v + 65536 end
    samples[#samples + 1] = string.char(v % 256, math.floor(v / 256))
  end
  local data = table.concat(samples)
  local b64 = require("rpp.base64")
  local function u16(x) return string.char(x % 256, math.floor(x / 256) % 256) end
  T.write_file(path, "RIFF" .. b64.pack_u32(36 + #data) .. "WAVEfmt " .. b64.pack_u32(16) .. u16(1) .. u16(1)
    .. b64.pack_u32(rate) .. b64.pack_u32(rate * 2) .. u16(2) .. u16(16) .. "data" .. b64.pack_u32(#data) .. data)
end

--- A folder in the scratch directory holding a copy of a fixture, with the
--- media it refers to made beside it.
local folders = 0
local function project_dir(fixture)
  folders = folders + 1
  local dir = T.scratch .. "/rpp" .. folders
  os.execute("mkdir -p '" .. dir .. "/media'")
  T.write_file(dir .. "/" .. fixture, T.read_file(FIXTURES .. fixture))
  write_wav(dir .. "/media/tone.wav", 2, 440)
  local midi = require("rpp.midi")
  T.write_file(dir .. "/media/riff.mid", midi.write_smf({
    { tick = 0, length = 240, pitch = 50, velocity = 90 },
    { tick = 480, length = 480, pitch = 52, velocity = 70 },
  }, 480, 100))
  return dir
end

local function by_name(name)
  local t = daw.track(name)
  assert(t, "no track " .. name)
  return t
end

local function items_of(report, group)
  for _, g in ipairs(report:data()) do
    if g.name == group then return g.items end
  end
  return {}
end

local function has_item(report, group, pattern)
  for _, text in ipairs(items_of(report, group)) do
    if text:find(pattern, 1, true) then return true end
  end
  return false
end

-- The format ------------------------------------------------------------------------

test("rpp: a file parses and writes back byte for byte", function()
  local fmt = load().format
  local text = T.read_file(FIXTURES .. "format.rpp")
  eq(fmt.write(fmt.parse(text)), text, "LF file")
  local crlf = text:gsub("\n", "\r\n")
  eq(fmt.write(fmt.parse(crlf)), crlf, "CRLF file")
  -- Odd spacing, a missing last line ending, an unclosed block.
  local odd = "<A  1   \"two  words\"\n\t B\t'x y' ``\n   >  \n<C\n  D 1"
  eq(fmt.write(fmt.parse(odd)), odd, "odd spacing")
end)

test("rpp: tokens, quotes and numbers", function()
  local fmt = load().format
  local doc = fmt.parse(T.read_file(FIXTURES .. "format.rpp"))
  local p = doc.project
  eq(p:arg(1), "0.1", "header")
  eq(p:arg(2), "7.55/linux-x86_64", "quoted header token")
  eq(p:getn("TEMPO", 1), 135, "TEMPO")
  local markers = p:all("MARKER")
  eq(markers[2]:arg(3), "Two words", "double quotes")
  eq(markers[3]:arg(3), 'Say "hi"', "single quotes")
  eq(markers[4]:arg(3), [[It's "both"]], "backticks")
  eq(markers[1]:arg(3), "", "empty string")
  local track = p:child("TRACK")
  eq(track:get("NAME"), "Lead Guitar", "track name")
  eq(track:child("AUXRECV"):arg(10), "-1:U", "bare token with a colon")
  eq(track:child("AUXRECV"):arg(13), "", "'' is an empty string")
  -- Writing: quoting only what needs it, numbers as REAPER does.
  eq(fmt.quote("abc"), "abc", "bare")
  eq(fmt.quote("a b"), '"a b"', "spaces")
  eq(fmt.quote(""), '""', "empty")
  eq(fmt.quote('say "hi"'), "'say \"hi\"'", "double quote inside")
  eq(fmt.quote([[it's "x"]]), "`it's \"x\"`", "both quotes inside")
  eq(fmt.number(4), "4", "integer")
  eq(fmt.number(0.70794578438414), "0.70794578438414", "14 decimals")
  eq(fmt.number(441.6), "441.6", "shortest form")
  eq(fmt.number(1 / 3), "0.33333333333333", "rounded")
  eq(fmt.number(-0.5), "-0.5", "negative")
end)

test("rpp: a changed line is rewritten, the rest stays as read", function()
  local fmt = load().format
  local text = T.read_file(FIXTURES .. "format.rpp")
  local doc = fmt.parse(text)
  doc.project:set("TEMPO", 96, 3, 4, 0)
  local track = doc.project:child("TRACK")
  track:set("NAME", "Rhythm Guitar")
  track:add(fmt.line("MUTESOLO", 1, 0, 0), 2)
  local out = fmt.write(doc)
  local want = text:gsub("  TEMPO 135 4 4 0\n", "  TEMPO 96 3 4 0\n")
    :gsub('    NAME "Lead Guitar"\n', '    NAME "Rhythm Guitar"\n    MUTESOLO 1 0 0\n')
  eq(out, want, "only the changed lines differ")
  -- A tree built from nothing.
  local new = fmt.document()
  local root = new:add(fmt.block("REAPER_PROJECT", 0.1, "7.0/x", 0))
  root:add(fmt.line("NAME", "two words"))
  root:add(fmt.block("SOURCE", "WAVE")):add(fmt.line("FILE", "a.wav")):quoted(1)
  eq(fmt.write(new), '<REAPER_PROJECT 0.1 7.0/x 0\n  NAME "two words"\n  <SOURCE WAVE\n    FILE "a.wav"\n  >\n>\n', "new tree")
  -- And it reads back as the same tree.
  local again = fmt.parse(fmt.write(new))
  eq(again.project:child("SOURCE"):get("FILE"), "a.wav", "read back")
end)

test("rpp: base64 blocks and plugin chunks", function()
  local r = load()
  local b64 = require("rpp.base64")
  local fx = require("rpp.fx")
  for _, s in ipairs({ "", "a", "ab", "abc", "abcd", string.rep("\0\255\128", 100) }) do
    eq(b64.decode(b64.encode(s)), s, "base64 round trip of " .. #s .. " bytes")
  end
  local doc = r.parse(T.read_file(FIXTURES .. "format.rpp"))
  local vst = doc.project:child("TRACK"):child("FXCHAIN"):child("VST")
  local groups = vst:data_groups()
  eq(#groups, 3, "header, state, trailer")
  local parts = assert(fx.vst_parts(vst))
  eq(#parts.data, 24, "state size from the header")
  local state = assert(fx.vst3_state_from_reaper(parts.data))
  eq(state, b64.pack_u32(4) .. "abcd" .. b64.pack_u32(4) .. "wxyz", "paw's VST3 state")
  eq(fx.vst3_state_to_reaper(state), parts.data, "and back")
  -- Data lines are rewritten in groups of 128 characters.
  local block = r.block("STATE")
  block:set_data({ string.rep("A", 300), "QUJD" })
  eq(#block.children, 4, "lines")
  eq(#block.children[1].tokens[1], 128, "first line width")
  eq(block:data_groups()[1], string.rep("A", 300), "first group")
  eq(block:data_groups()[2], "QUJD", "second group")
  -- MIDI events in the source, sysex included.
  local midi = require("rpp.midi")
  local src = midi.read_source(doc.project:child("TRACK"):child("ITEM"):child("SOURCE"))
  eq(#src.notes, 1, "one note")
  eq(src.notes[1].length, 480, "note length in ticks")
  eq(src.length, 960, "source length")
  eq(src.other["sysex and text events"], 1, "the sysex is counted")
  eq(fx.split_display("VSTi: Ugritone Drums (Ugritone) (32 out)") == "VSTi", true, "prefix")
  local _, name, vendor = fx.split_display("VSTi: Ugritone Drums (Ugritone) (32 out)")
  eq(name .. "|" .. vendor, "Ugritone Drums|Ugritone", "name and vendor")
end)

-- Import ------------------------------------------------------------------------------

test("rpp: import, track by track and clip by clip", function()
  local r = load()
  local dir = project_dir("song.rpp")
  local result = r.import(dir .. "/song.rpp")
  local report = result.report
  daw.flush()
  local p = daw.project.get()
  eq(p.tempo, 90, "first tempo")
  eq(p.sig_num .. "/" .. p.sig_den, "3/4", "time signature")
  -- The tempo envelope: 90 for 100 seconds (150 beats), then 120.
  local points = daw.tempo.points()
  eq(#points, 2, "the tempo change comes in")
  near(points[2].beat, 150, 1e-9, "at its beat")
  eq(points[2].bpm, 120, "with its tempo")
  eq(p.name, "song", "name")
  local tr = daw.transport.get()
  eq(tr.loop_enabled, true, "loop on")
  near(tr.loop_start, 3, 1e-9, "loop start (2 s at 90 BPM)")
  near(tr.loop_end, 9, 1e-9, "loop end")
  near(daw.master.volume, -6.0206, 1e-3, "master volume")

  local names = {}
  for i, t in ipairs(daw.tracks()) do names[i] = t.name end
  eq(table.concat(names, ","), "Band,Keys,Gtr DI,Verb", "tracks in order")
  local band, keys, gtr, verb = by_name("Band"), by_name("Keys"), by_name("Gtr DI"), by_name("Verb")

  -- Band: a folder with automation and plugins.
  near(band.volume, -3, 1e-3, "Band volume")
  near(band.pan, 0.25, 1e-9, "Band pan")
  eq(band.output, nil, "Band to the master")
  eq(band.input, "1", "Band input")
  eq(band.monitor, true, "Band monitoring")
  local vol = band:lane("volume")
  local pts = vol:points()
  eq(#pts, 4, "volume points")
  near(pts[1][1], 0, 1e-9, "point 1 beat")
  near(pts[1][2], 0, 1e-3, "point 1 is 0 dB (amplitudes, whatever VOLTYPE says)")
  near(pts[2][1], 6, 1e-9, "point 2 beat (4 s)")
  near(pts[2][2], -24.08, 0.01, "point 2 dB")
  eq(vol.enabled, true, "volume lane on")
  local pan = band:lane("pan")
  eq(pan.enabled, false, "pan lane off, as in REAPER")
  local pp = pan:points()
  eq(#pp, 3, "pan points with the square step")
  near(pp[1][2], -0.5, 1e-9, "pan +0.5 in REAPER's envelope is left")
  near(pp[2][1], 3, 1e-9, "held to the next point")
  near(pp[2][2], -0.5, 1e-9, "held value")
  near(pp[3][2], 0.5, 1e-9, "then the next value")
  if has("lv2:http://lsp-plug.in/plugins/lv2/gate_mono") then
    local gate = band:devices()[1]
    eq(gate.kind, "lv2:http://lsp-plug.in/plugins/lv2/gate_mono", "LV2 plugin")
    eq(gate.bypass, true, "bypassed as in REAPER")
    near(gate.params.at, 7.5, 1e-4, "parameter by port symbol")
    near(gate.params.rt, 120, 1e-3, "another parameter")
    eq(has_item(report, "Plugin settings", "not_a_port"), true, "unknown parameter reported")
  else
    eq(has_item(report, "Plugins left as placeholders", "LSP Gate Mono"), true, "gate left behind")
  end
  local holders = band.meta.rpp_placeholders
  local amp = holders[#holders]
  eq(amp.name, "VST3: Nowhere Amp (Nobody)", "placeholder named after the plugin")
  eq(amp.reason, "not installed here", "and why")
  eq(amp.rpp:find("<VST", 1, true) ~= nil, true, "its REAPER text is kept")
  eq(has_item(report, "Plugin parameter automation", "Band"), true, "parameter envelope reported")

  -- Keys: in the folder; MIDI clips.
  eq(keys.output, band.id, "Keys feeds the folder")
  local clips = keys:clips()
  eq(#clips, 3, "Keys clips")
  local a = clips[1]:get()
  eq(a.name, "Chords A", "clip name")
  near(a.start, 3, 1e-9, "clip start (2 s)")
  near(a.length, 6, 1e-9, "clip length (4 s)")
  local notes = clips[1]:notes()
  eq(#notes, 2, "muted note left out")
  eq(notes[1].pitch, 60, "first pitch")
  near(notes[1].start, 0, 1e-9, "first start")
  near(notes[1].length, 0.5, 1e-9, "first length")
  eq(notes[1].velocity, 100, "first velocity")
  eq(notes[2].pitch, 64, "second pitch")
  near(notes[2].start, 1, 1e-9, "second start")
  near(notes[2].length, 1, 1e-9, "second length")
  eq(notes[2].meta.channel, 2, "MIDI channel kept with the note")
  local b = clips[2]:get()
  near(b.start, 12, 1e-9, "looped clip start")
  near(b.length, 6, 1e-9, "looped clip length")
  local looped = clips[2]:notes()
  eq(#looped, 8, "the source loops 8 times")
  near(looped[2].start, 0.75, 1e-9, "a pass is 960 ticks at 120 BPM = 0.75 beats at 90")
  near(looped[1].length, 0.375, 1e-9, "note length at the source's own tempo")
  local c = clips[3]:get()
  eq(c.muted, true, "muted item")
  near(c.start, 18, 1e-9, "MIDI file clip start")
  local riff = clips[3]:notes()
  eq(#riff, 2, "notes from the .mid file")
  near(riff[2].start, 1, 1e-9, "ticks of the .mid file are beats")
  near(riff[2].length, 1, 1e-9, "and lengths")

  -- Gtr DI: the last child; audio clips.
  eq(gtr.output, band.id, "Gtr DI feeds the folder")
  eq(gtr.mute, true, "muted")
  eq(gtr.solo, true, "soloed")
  eq(gtr.armed, true, "armed")
  near(gtr.pan, -1, 1e-9, "panned left")
  local g = gtr:clips()
  eq(#g, 3, "an audio clip and a looped one in two parts")
  local di = g[1]:get()
  eq(di.name, "DI take", "the active take")
  eq(di.file:match("media/tone%.wav$") ~= nil, true, "file relative to the project")
  near(di.offset, 0.5, 1e-9, "start in source")
  near(di.gain, -12.0412, 1e-3, "item volume times take volume")
  near(di.start, 1.5, 1e-9, "start")
  near(di.length, 1.5, 1e-9, "length")
  local l1, l2 = g[2]:get(), g[3]:get()
  eq(l1.file:match("media/tone%.wav$") ~= nil, true, "found in the recording folder")
  near(l1.start, 6, 1e-9, "first pass start")
  near(l1.length, 1.5, 1e-9, "first pass: the rest of the file after 1 s")
  near(l1.offset, 1, 1e-9, "first pass offset")
  near(l2.start, 7.5, 1e-9, "second pass start")
  near(l2.length, 3, 1e-9, "second pass: until the item ends")
  near(l2.offset, 0, 1e-9, "second pass from the file's start")
  eq(l1.muted and l2.muted, true, "both muted")

  -- Verb: receives become sends on the senders.
  near(verb.volume, -6.0206, 1e-3, "Verb volume")
  local bs = band.sends
  eq(#bs, 1, "Band sends")
  eq(bs[1].target, verb.id, "to Verb")
  near(bs[1].level, -6.0206, 1e-3, "send level")
  eq(#keys.sends, 1, "Keys send")
  near(keys.sends[1].level, -12.0412, 1e-3, "pre-fader send level")
  eq(#gtr.sends, 0, "a muted send is left out")

  -- Markers and regions for other extensions.
  local meta = p.meta
  eq(meta.markers[1].name, "Verse", "marker")
  near(meta.markers[1].beat, 6, 1e-9, "marker beat")
  eq(meta.regions[1].name, "Big Chorus", "region")
  near(meta.regions[1].start, 12, 1e-9, "region start")
  near(meta.regions[1].length, 6, 1e-9, "region length")
  -- The master's JSFX is a placeholder.
  eq(daw.master.meta.rpp_placeholders[1].format, "JSFX", "master placeholder")
end)

test("rpp: what is not carried over is reported, grouped", function()
  local r = load()
  local dir = project_dir("song.rpp")
  local report = r.import(dir .. "/song.rpp").report
  local function check(group, pattern)
    eq(has_item(report, group, pattern), true, group .. ": " .. pattern)
  end
  check("Envelope curve shapes (made straight lines)", "Band volume")
  check("Plugins left as placeholders", "Nowhere Amp")
  check("Plugins left as placeholders", "JS: loser/masterLimiter")
  check("Plugin parameter automation", "Band")
  check("MIDI other than notes", "CC")
  check("MIDI other than notes", "pitch bend")
  check("MIDI other than notes", "sysex")
  check("Muted MIDI notes (left out)", "Chords A")
  check("Play rate (ignored: played at 1x)", "rate 1.5")
  check("Item volume on MIDI items", "riff.mid")
  check("Takes other than the active one (left out)", "Gtr DI")
  check("Fades (ignored)", "Gtr DI")
  check("Missing media", "/nonexistent/folder/lost.wav")
  check("Tracks with the master/parent send off (here they still play through their output)", "Verb")
  check("Pre-fader and pre-FX sends (made post-fader)", "Keys -> Verb")
  check("Muted sends (left out)", "Gtr DI -> Verb")
  local text = report:text()
  eq(text:find("Not carried over from song.rpp", 1, true) ~= nil, true, "titled")
  eq(#report:lines(1) < #report:lines(100), true, "long groups are shortened")
end)

test("rpp: MIDI timing follows the project tempo", function()
  local r = load()
  local fmt = r.format
  -- The same item at three tempos: 1.5 s in, a note on beat 2 of the item.
  for _, bpm in ipairs({ 60, 90, 137 }) do
    local doc = fmt.parse(table.concat({
      "<REAPER_PROJECT 0.1 \"7.55\" 0",
      "  TEMPO " .. bpm .. " 4 4",
      "  <TRACK",
      "    NAME M",
      "    <ITEM",
      "      POSITION 1.5",
      "      LENGTH 3",
      "      SOFFS 0.25",
      "      <SOURCE MIDI",
      "        HASDATA 1 480 QN",
      "        E 480 90 3c 64",
      "        E 240 80 3c 00",
      "        E 2000 b0 7b 00",
      "      >",
      "    >",
      "  >",
      ">",
    }, "\n"))
    r.format.save(doc, T.scratch .. "/tempo.rpp")
    r.import(T.scratch .. "/tempo.rpp")
    local clip = daw.track("M"):clips()[1]
    local beats = bpm / 60
    near(clip.start, 1.5 * beats, 1e-9, bpm .. " BPM: item start")
    near(clip.length, 3 * beats, 1e-9, bpm .. " BPM: item length")
    local n = clip:notes()[1]
    -- Tick 480 is beat 1 of the source; the take starts 0.25 s into it.
    near(n.start, 1 - 0.25 * beats, 1e-9, bpm .. " BPM: note start")
    near(n.length, 0.5, 1e-9, bpm .. " BPM: note length")
  end
end)

test("rpp: an envelope's points become an automation lane", function()
  local r = load()
  local doc = r.parse(table.concat({
    "<REAPER_PROJECT 0.1 \"7.55\" 0",
    "  TEMPO 120 4 4",
    "  <TRACK",
    "    NAME E",
    "    <VOLENV2",
    "      ACT 1 -1",
    "      PT 0 1 0",
    "      PT 1 0.5 0",
    "      PT 2 0 0",
    "    >",
    "  >",
    ">",
  }, "\n"))
  r.format.save(doc, T.scratch .. "/env.rpp")
  r.import(T.scratch .. "/env.rpp")
  local lane = daw.track("E"):lane("volume")
  local pts = lane:points()
  eq(#pts, 3, "points")
  near(pts[2][1], 2, 1e-9, "1 s is beat 2 at 120")
  near(pts[2][2], -6.0206, 1e-3, "amplitude 0.5 is -6 dB")
  eq(pts[3][2], -120, "silence is the bottom of the range")
end)

-- Commands --------------------------------------------------------------------------

test("rpp: commands, and edit and write on .rpp files", function()
  load()
  local dir = project_dir("song.rpp")
  daw.project.new()
  daw.cmd("rpp.import", { dir .. "/song.rpp" })
  eq(#daw.tracks(), 4, "rpp.import")
  daw.project.new()
  daw.commands.exec("edit " .. dir .. "/song.rpp")
  eq(#daw.tracks(), 4, "edit song.rpp")
  daw.project.new()
  daw.commands.exec("e " .. dir .. "/song.rpp")
  eq(#daw.tracks(), 4, "e song.rpp")
  -- What was opened has no file of its own yet: the next open asks first.
  daw.commands.exec("rpp.import " .. dir .. "/song.rpp merge=true")
  local tracks = #daw.tracks()
  daw.commands.exec("rpp.import " .. dir .. "/song.rpp")
  daw.commands.exec("edit " .. dir .. "/song.rpp")
  eq(#daw.tracks(), tracks, "rpp.import and edit leave an unsaved project alone; merge adds")
  daw.commands.exec("rpp.import! " .. dir .. "/song.rpp")
  eq(#daw.tracks(), 4, "rpp.import! replaces it")
  daw.commands.exec("rpp.export " .. dir .. "/out.rpp")
  eq(T.read_file(dir .. "/out.rpp"):sub(1, 15), "<REAPER_PROJECT", "rpp.export")
  daw.commands.exec("w " .. dir .. "/out2.rpp")
  eq(T.read_file(dir .. "/out2.rpp"):sub(1, 15), "<REAPER_PROJECT", "w out.rpp")
  -- Other files still go to the original commands.
  daw.commands.exec("w " .. dir .. "/song.json")
  eq(T.read_file(dir .. "/song.json"):sub(1, 1), "{", "w song.json saves as before")
  daw.project.new()
  daw.commands.exec("e " .. dir .. "/song.json")
  eq(#daw.tracks(), 4, "e song.json loads as before")
end)

-- Export ------------------------------------------------------------------------------

--- The project as plain data, for comparing two projects.
local function describe()
  local p = daw.project.get()
  local tr = daw.transport.get()
  local out = {
    tempo = p.tempo, sig = p.sig_num .. "/" .. p.sig_den,
    loop = tr.loop_enabled and string.format("%.6f-%.6f", tr.loop_start, tr.loop_end) or "off",
    master = string.format("%.4f %.4f %s", daw.master.volume, daw.master.pan, tostring(daw.master.mute)),
    tracks = {},
  }
  local name_of = {}
  for _, t in ipairs(daw.tracks()) do name_of[t.id] = t.name end
  for _, t in ipairs(daw.tracks()) do
    local g = t:get()
    local d = {
      string.format("%s vol %.4f pan %.4f mute %s solo %s armed %s out %s input %s monitor %s",
        g.name, g.volume, g.pan, tostring(g.mute), tostring(g.solo), tostring(g.armed),
        tostring(name_of[g.output]), tostring(g.input), tostring(g.monitor)),
    }
    for _, s in ipairs(g.sends) do d[#d + 1] = string.format("send %s %.4f", name_of[s.target], s.level) end
    for _, lane in ipairs(t:lanes()) do
      local l = lane:get()
      local pts = {}
      for _, pt in ipairs(lane:points()) do pts[#pts + 1] = string.format("%.6f:%.4f", pt[1], pt[2]) end
      d[#d + 1] = string.format("lane %s %s %s", l.target, tostring(l.enabled), table.concat(pts, " "))
    end
    for _, dev in ipairs(t:devices()) do
      local keys = {}
      for k in pairs(dev.params) do keys[#keys + 1] = k end
      table.sort(keys)
      local params = {}
      for _, k in ipairs(keys) do params[#params + 1] = string.format("%s=%.4f", k, dev.params[k]) end
      d[#d + 1] = string.format("device %s bypass %s %s", dev.kind, tostring(dev.bypass), table.concat(params, ","))
    end
    for _, c in ipairs(t:clips()) do
      local cg = c:get()
      local line = string.format("clip %s %s %.6f+%.6f muted %s", cg.kind, cg.name, cg.start, cg.length, tostring(cg.muted))
      if cg.kind == "audio" then
        line = line .. string.format(" %s offset %.6f gain %.4f", cg.file, cg.offset, cg.gain)
      else
        for _, n in ipairs(c:notes()) do
          line = line .. string.format(" [%d %.6f %.6f %d %s]", n.pitch, n.start, n.length, n.velocity,
            tostring(n.meta and n.meta.channel))
        end
      end
      d[#d + 1] = line
    end
    out.tracks[#out.tracks + 1] = table.concat(d, "\n  ")
  end
  return out
end

local function same(a, b)
  for _, key in ipairs({ "tempo", "sig", "loop", "master" }) do eq(b[key], a[key], key) end
  eq(#b.tracks, #a.tracks, "number of tracks")
  for i = 1, #a.tracks do eq(b.tracks[i], a.tracks[i], "track " .. i) end
end

local function build(dir)
  T.fresh()
  daw.project.tempo = 100
  daw.project.sig_num = 3
  daw.project.sig_den = 4
  daw.transport.loop_start, daw.transport.loop_end = 3, 12
  daw.transport.loop_enabled = true
  daw.master.volume = -2
  daw.master.pan = 0.1
  local bus = daw.add_track({ name = "Drum Bus", volume = -1.5 })
  local kick = daw.add_track({ name = "Kick", output = bus, pan = -0.2 })
  local snare = daw.add_track({ name = "Snare", output = bus, volume = -4 })
  local keys = daw.add_track({ name = "Keys", volume = -6, pan = 0.3 })
  local verb = daw.add_track({ name = "Verb" })
  local gtr = daw.add_track({ name = "Gtr" })
  kick.mute = true
  snare.solo = true
  keys.armed = true
  keys:send(verb, -9)
  snare:send(verb, -15.5)
  kick:add_clip({ name = "kick", start = 0, length = 3, notes = {
    { pitch = 36, start = 0, length = 0.25, velocity = 120 },
    { pitch = 36, start = 1.5, length = 0.25, velocity = 90, meta = { channel = 10 } },
  } })
  keys:add_clip({ name = "chords", start = 3, length = 6, notes = {
    { pitch = 60, start = 0, length = 2, velocity = 80 }, { pitch = 64, start = 0, length = 2, velocity = 80 },
    { pitch = 67, start = 2.5, length = 0.125, velocity = 64 },
  } })
  local quiet = keys:add_clip({ name = "muted", start = 12, length = 3, notes = { { pitch = 72, start = 0, length = 1 } } })
  quiet.muted = true
  local wav = dir .. "/media/tone.wav"
  local audio = gtr:add_clip({ start = 1, file = wav, offset = 0.25, gain = -3.5 })
  audio.length = 2
  keys:automate("volume"):set_points({ { 0, -10 }, { 4, 0 }, { 8, -120 } })
  local pan = gtr:automate("pan")
  pan:set_points({ { 0, -1 }, { 6, 0.5 } })
  pan.enabled = false
  bus:automate("volume"):set_points({ { 2, 3 } })
  daw.project.meta = { markers = { { name = "Intro", beat = 0 }, { name = "Drop", beat = 9 } },
    regions = { { name = "Verse", start = 3, length = 6 } } }
  daw.flush()
end

test("rpp: export, then import, gives the same project", function()
  local r = load()
  local dir = project_dir("song.rpp")
  build(dir)
  local before = describe()
  local result = r.export(dir .. "/built.rpp")
  eq(result.report:empty(), true, "nothing left out: " .. result.report:text())
  -- It is a REAPER project by our own reading of it, laid out as REAPER's.
  local doc = r.read(dir .. "/built.rpp")
  local p = doc.project
  eq(p:child("TEMPO"):arg(1), "100", "TEMPO")
  eq(#p:blocks("TRACK"), 6, "tracks")
  local kick = p:blocks("TRACK")[2]
  eq(kick:get("ISBUS"), "0", "Kick in the folder")
  eq(p:blocks("TRACK")[1]:child("ISBUS"):arg(2), "1", "Drum Bus opens the folder")
  eq(p:blocks("TRACK")[3]:child("ISBUS"):arg(2), "-1", "Snare closes it")
  local verb = p:blocks("TRACK")[5]
  eq(#verb:all("AUXRECV"), 2, "Verb receives from Keys and Snare")
  eq(T.read_file(dir .. "/built.rpp"):find("\r\n", 1, true) ~= nil, true, "CRLF as REAPER writes")
  local file = p:blocks("TRACK")[6]:child("ITEM"):child("SOURCE"):get("FILE")
  eq(file, "media/tone.wav", "media path relative to the project")
  r.import(dir .. "/built.rpp")
  local after = describe()
  same(before, after)
  local meta = daw.project.get().meta
  eq(meta.markers[2].name, "Drop", "marker")
  near(meta.markers[2].beat, 9, 1e-9, "marker beat")
  eq(meta.regions[1].name, "Verse", "region")
  near(meta.regions[1].length, 6, 1e-9, "region length")
end)

test("rpp: plugins go out and come back with their settings", function()
  local r = load()
  local dir = project_dir("song.rpp")
  local clap = "clap:in.lsp-plug.gate_mono"
  local lv2 = "lv2:http://lsp-plug.in/plugins/lv2/gate_mono"
  local vst3 = "vst3:Gate Mono"
  if not (has(clap) and has(lv2) and has(vst3)) then return "skipped: LSP plugins not installed" end
  T.fresh()
  local t = daw.add_track({ name = "FX" })
  local a = t:add_device(clap)
  a:set("output_gain", -6)
  local b = t:add_device(lv2)
  b:set("scr", 37)
  b.bypass = true
  t:add_device(vst3)
  daw.flush()
  api.sleep(300) -- plugins take new values with their next audio block
  local result = r.export(dir .. "/fx.rpp")
  eq(has_item(result.report, "Plugins not written", "vst3:Gate Mono"), true, "a VST3 made here is not written")
  local chain = r.read(dir .. "/fx.rpp").project:child("TRACK"):child("FXCHAIN")
  eq(chain:child("CLAP"):arg(2), "in.lsp-plug.gate_mono", "CLAP id")
  eq(chain:child("CLAP"):child("STATE") ~= nil, true, "CLAP state")
  eq(chain:child("LV2"):arg(2), "http://lsp-plug.in/plugins/lv2/gate_mono", "LV2 uri")
  r.import(dir .. "/fx.rpp")
  local devs = daw.track("FX"):devices()
  eq(#devs, 2, "the CLAP and the LV2 plugin")
  eq(devs[1].kind, clap, "CLAP back")
  near(devs[1].params.output_gain, -6, 1e-3, "CLAP setting from its state")
  eq(devs[2].kind, lv2, "LV2 back")
  near(devs[2].params.scr, 37, 1e-3, "LV2 setting from its parameters")
  eq(devs[2].bypass, true, "bypass")
  -- A VST3 that came from REAPER goes back with its state.
  local vdoc = r.parse(table.concat({
    "<REAPER_PROJECT 0.1 \"7.55\" 0", "  TEMPO 120 4 4", "  <TRACK", "    NAME V", "    <FXCHAIN", "      BYPASS 0 0 0",
    '      <VST "VST3: Gate Mono (LSP VST3)" lsp-plugins.vst3 0 "" 1{00000000000000000000000000000000} ""',
    "      >", "      WAK 0 0", "    >", "  >", ">",
  }, "\n"))
  -- REAPER's chunk around the state of a gate made here.
  local fx = require("rpp.fx")
  local b64 = require("rpp.base64")
  T.fresh()
  local g = daw.add_track({ name = "tmp" }):add_device(vst3)
  local key = "sidechain_reactivity"
  g:set(key, 0.2)
  daw.flush()
  -- A VST3 takes a new value with its next audio block; its saved state
  -- only has it after that.
  api.sleep(300)
  local state = api.device_state(g.id)
  -- The plugin rounds the value it saves; what paw's own copy of the
  -- state gives is what the import must give.
  local want = api.device_get(api.device_add(g:track().id, vst3, { state = state })).params[key]
  local default = api.device_get(api.device_add(g:track().id, vst3, {})).params[key]
  eq(math.abs(want - default) > 0.05, true, "the setting is not the default")
  local reaper_state = fx.vst3_state_to_reaper(b64.decode(state))
  local header = b64.decode("9mZpeO5e7f4CAAAAAQAAAAAAAAACAAAAAAAAAAIAAAABAAAAAAAAAAIAAAAAAAAAGAAAAAEAAAD//wAA")
  header = header:sub(1, #header - 12) .. b64.pack_u32(#reaper_state) .. header:sub(#header - 7)
  vdoc.project:child("TRACK"):child("FXCHAIN"):child("VST"):set_data({ b64.encode(header), b64.encode(reaper_state), "AAAAAAAA" })
  r.save(vdoc, dir .. "/vst3.rpp")
  r.import(dir .. "/vst3.rpp")
  local v = daw.track("V"):devices()[1]
  eq(v.kind, vst3, "VST3 found by name")
  near(v.params[key], want, 1e-6, "VST3 setting from REAPER's chunk")
  r.export(dir .. "/vst3-out.rpp")
  local out = r.read(dir .. "/vst3-out.rpp").project:child("TRACK"):child("FXCHAIN"):child("VST")
  eq(out:arg(1), "VST3: Gate Mono (LSP VST3)", "written back under REAPER's name for it")
  eq(b64.decode(out:data_groups()[1]):sub(1, 8), header:sub(1, 8), "with REAPER's header")
  r.import(dir .. "/vst3-out.rpp")
  near(daw.track("V"):devices()[1].params[key], want, 1e-6, "and back again")
end)

test("rpp: routing a folder cannot hold is written as a send", function()
  local r = load()
  T.fresh()
  local bus = daw.add_track({ name = "Bus" })
  daw.add_track({ name = "Between" })
  daw.add_track({ name = "Late", output = bus })
  daw.flush()
  local result = r.export(T.scratch .. "/route.rpp")
  eq(has_item(result.report, "Routing written as a send (REAPER folders need the child right after its parent)", "Late -> Bus"), true, "reported")
  local late = r.read(T.scratch .. "/route.rpp").project:blocks("TRACK")[3]
  eq(late:child("MAINSEND"):arg(1), "0", "no parent send")
  local bus_block = r.read(T.scratch .. "/route.rpp").project:blocks("TRACK")[1]
  eq(bus_block:child("AUXRECV"):arg(1), "2", "the bus receives from it")
end)

test("rpp: an imported project with audio and MIDI renders", function()
  local r = load()
  local dir = project_dir("render.rpp")
  local result = r.import(dir .. "/render.rpp", { instrument = "synth" })
  eq(has_item(result.report, "Plugins left as placeholders", "ReaSynth"), true, "ReaSynth stays behind")
  eq(daw.track("Synth"):devices()[1].kind, "synth", "a synth for the MIDI track")
  local info = T.render({ bits = 16, tail = 0 })
  local audio = T.channel_peaks(info, 0.2, 1.8)
  local notes = T.channel_peaks(info, 2.2, 3.8)
  eq(audio > 0.1, true, "the audio clip is heard: " .. audio)
  eq(notes > 0.05, true, "the MIDI clip is heard: " .. notes)
  near(T.frequency(info, 0.2, 1.8), 440, 5, "the WAV's pitch")
  near(T.frequency(info, 2.2, 3.8), 220, 5, "the MIDI note's pitch (A3)")
end)

test("rpp: the tempo map goes out as TEMPOENVEX and comes back", function()
  local r = load()
  T.fresh()
  daw.project.tempo = 120
  daw.tempo.set(8, 120, { ramp = true })
  daw.tempo.set(16, 90)
  daw.tempo.set_signature(9, 6, 8)
  local track = daw.add_track({ name = "Keys" })
  track:add_clip({ start = 34, length = 3, notes = { { pitch = 60, start = 0, length = 1 } } })
  local path = T.scratch .. "/map.rpp"
  r.export(path)
  local text = T.read_file(path)
  eq(text:find("<TEMPOENVEX", 1, true) ~= nil, true, "a tempo envelope is written")
  eq(text:find("PT 4.000000000000 120 0", 1, true) ~= nil, true, "the ramp starts at 4 s, shape 0")
  eq(text:find(" 524294 0 1", 1, true) ~= nil, true, "6/8 packed as 6 + 8 * 65536")
  local seconds = daw.tempo.beats_to_seconds(34)
  T.fresh()
  r.import(path)
  local points = daw.tempo.points()
  eq(#points, 4, "three tempo points and one where the 6/8 starts")
  eq(points[2].ramp, true, "the ramp")
  near(points[3].beat, 16, 1e-6, "the ramp's end lands on its beat")
  eq(daw.tempo.bar_of(32), 9, "the 6/8 starts bar 9")
  local num, den = daw.tempo.signature_at(33)
  eq(num .. "/" .. den, "6/8", "in 6/8")
  local clip = daw.tracks()[1]:clips()[1]
  near(clip.start, 34, 1e-6, "the clip at its beat")
  near(daw.tempo.beats_to_seconds(clip.start), seconds, 1e-6, "and its time")
end)
