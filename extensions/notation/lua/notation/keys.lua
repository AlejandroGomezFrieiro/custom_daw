-- Commands and keys of the notation view. The view takes the grammar of the
-- piano roll: motions, operators with any of them, text objects, visual
-- mode, registers, counts and `.`; its rows are pitches, so the runtime's
-- note editing (`daw.edit.roll`) works on it unchanged.
local api = daw.api
local util = daw.util
local model = require("notation.model")
local view = require("notation")
local keymap, edit = daw.keymap, daw.edit
local map, command = keymap.set, daw.command

local EPS = 1e-6

-- Commands --------------------------------------------------------------------------------

command("notation", function()
  local clip = view.target()
  if not clip then return daw.notify("no clip under the cursor", "warn") end
  view:edit(clip)
end, { desc = "Show the clip under the cursor as notation, to read and edit" })
command("notation.open", function() daw.cmd("notation") end, { desc = "Show the clip under the cursor as notation" })

command("notation.clef", function(ctx)
  local clip = view.target()
  local track = clip and clip:track() or daw.cursor.track()
  if not track then return daw.notify("no track", "warn") end
  local want = ctx.args[1] and tostring(ctx.args[1])
  local meta = track.meta or {}
  if not want then
    local fixed = type(meta.notation) == "table" and meta.notation.clef
    return daw.notify("clef: " .. (fixed or "chosen by the notes"))
  end
  if not ({ treble = true, bass = true, grand = true, auto = true, treble8 = true })[want] then
    return daw.notify("a clef is treble, treble8 (guitar), bass, grand or auto", "warn")
  end
  local own = type(meta.notation) == "table" and meta.notation or {}
  own.clef = want ~= "auto" and want or nil
  meta.notation = next(own) and own or nil
  track.meta = meta
  daw.notify("clef: " .. (own.clef or "chosen by the notes"))
end, { desc = "Fix the track's clef: `notation.clef bass` (treble, bass, grand, auto)" })

command("notation.key", function(ctx)
  local words = {}
  for _, a in ipairs(ctx.args) do words[#words + 1] = tostring(a) end
  if #words == 0 then
    local fifths, stored = view.key()
    return daw.notify("key: " .. (stored and (stored.root .. " " .. (stored.scale or "major")) or "none (C major)") .. ", " .. math.abs(fifths) .. (fifths >= 0 and " sharps" or " flats"))
  end
  local meta = api.project_get().meta or {}
  local stored = type(meta.musicops) == "table" and meta.musicops or {}
  if words[1] == "off" then
    stored.root, stored.scale = nil, nil
  else
    local root = words[1]:sub(1, 1):upper() .. words[1]:sub(2)
    if not root:match("^[A-G][#b]?$") then return daw.notify("a key is a root and a scale: `notation.key Bb major`", "warn") end
    stored.root, stored.scale = root, words[2] or "major"
  end
  meta.musicops = next(stored) and stored or nil
  api.project_set("meta", meta)
  daw.emit("musicops.key", { key = stored.root and (stored.root .. " " .. stored.scale) or nil })
end, { desc = "Set the project's key, as musicops keeps it: `notation.key Eb major`, `notation.key off`" })

--- The clip the settings commands work on.
local function settings_clip()
  local clip = view.target()
  if not clip then daw.notify("no clip under the cursor", "warn") end
  return clip
end

local function parse_value(text, default)
  if text == "on" or text == "true" or text == "yes" then return true end
  if text == "off" or text == "false" or text == "no" then
    if type(default) == "number" then return 0 end
    if type(default) == "string" and default ~= "score" then return "off" end
    return false
  end
  return tonumber(text) or text
end

command("notation.set", function(ctx)
  local clip = settings_clip()
  if not clip then return end
  local score = require("notation.score")
  local name = ctx.args[1] and tostring(ctx.args[1])
  local set = view.settings_of(clip:get())
  if not name then
    local words = {}
    for _, k in ipairs(score.ORDER) do words[#words + 1] = k .. "=" .. tostring(set[k]) end
    return daw.notify(table.concat(words, " "))
  end
  if score.DEFAULTS[name] == nil then return daw.notify("no setting " .. name .. "; they are: " .. table.concat(score.ORDER, ", "), "warn") end
  if ctx.args[2] == nil then return daw.notify(name .. " = " .. tostring(set[name])) end
  local value = parse_value(tostring(ctx.args[2]), score.DEFAULTS[name])
  if ctx.args[2] == "default" then value = nil end
  view.keep(clip, function(own)
    own.settings = util.merge(own.settings or {}, {})
    own.settings[name] = value
    if not next(own.settings) then own.settings = nil end
  end)
  daw.notify(name .. " = " .. tostring(view.settings_of(clip:get())[name]))
end, { desc = "Set how the clip is transcribed: `notation.set strum 80`, `notation.set swing off`, `notation.set voices off`; alone, list them" })

-- Marks: articulations, dynamics, hairpins, slurs, text, repeats.
local marks = require("notation.marks")

--- The places of the notes a mark goes on: the selection's, or the chord's under the cursor.
local function target_notes(region)
  local clip = view:clip()
  if region and clip then
    local _, places = edit.roll.notes(clip, region)
    return places
  end
  return view:chord_indices()
end

command("notation.art", function(ctx)
  local kind = tostring(ctx.args[1] or "")
  if not marks.ARTICULATIONS[kind] then return daw.notify("an articulation is staccato, accent, tenuto or marcato", "warn") end
  local on = marks.toggle_art(kind, target_notes())
  if on ~= nil then daw.notify(kind .. (on and " on" or " off")) end
end, { desc = "Staccato, accent, tenuto or marcato on the chord under the cursor: `notation.art accent`" })

--- Where a mark goes: the cursor's place, or the start and end of the selection.
local function mark_span()
  local sel = daw.keymap.selection()
  if sel and sel.view == "notation" then return math.max(0, sel.c0), sel.c1 + (sel.kind == "line" and 0 or view:entry_length()) end
  local layout = view:layout()
  local m = view:measure_at(view.beat, layout)
  return view.beat, m and (m.start + m.length) or (view.beat + 4)
end

command("notation.dyn", function(ctx)
  local clip = view:clip()
  if not clip then return daw.notify("no clip open as notation", "warn") end
  local value = tostring(ctx.args[1] or "")
  local at = mark_span()
  if value == "off" then
    marks.put(clip, { at = at, kind = "dyn", value = false })
    return daw.notify("no dynamic here")
  end
  if not marks.DYNAMICS[value] then return daw.notify("a dynamic is " .. table.concat(marks.ORDER, ", ") .. " or off", "warn") end
  marks.put(clip, { at = at, kind = "dyn", value = value })
  daw.notify(value .. ": notes from here as loud as " .. marks.DYNAMICS[value])
end, { desc = "A dynamic at the cursor, which sets how loud the notes from there play: `notation.dyn mf`" })

for _, kind in ipairs({ "cresc", "dim" }) do
  command("notation." .. kind, function()
    local clip = view:clip()
    if not clip then return daw.notify("no clip open as notation", "warn") end
    local from, to = mark_span()
    marks.put(clip, { at = from, to = to, kind = kind })
    daw.notify((kind == "cresc" and "crescendo" or "diminuendo") .. " to " .. daw.time.format(clip.start + to))
  end, { desc = (kind == "cresc" and "A crescendo" or "A diminuendo") .. " hairpin over the selection (or to the end of the bar), ramping the loudness" })
end

command("notation.text", function(ctx)
  local clip = view:clip()
  if not clip then return daw.notify("no clip open as notation", "warn") end
  local text = tostring(ctx.args[1] or ""):match("^%s*(.-)%s*$")
  marks.put(clip, { at = view.beat, kind = "text", value = text ~= "" and text or false })
end, { raw = true, desc = "Text above the staff at the cursor: `notation.text Allegro`; with nothing, takes it away" })

command("notation.repeat", function(ctx)
  local clip = view:clip()
  if not clip then return daw.notify("no clip open as notation", "warn") end
  local which = tostring(ctx.args[1] or "")
  local m = view:measure_at(view.beat)
  if which == "start" then
    marks.put(clip, { at = m.start, kind = "repeat", value = "start" })
  elseif which == "end" then
    marks.put(clip, { at = m.start + m.length, kind = "repeat", value = "end" })
  elseif which == "off" then
    marks.put(clip, { at = m.start, kind = "repeat", value = false })
    marks.put(clip, { at = m.start + m.length, kind = "repeat", value = false })
  else
    return daw.notify("a repeat sign is start, end or off", "warn")
  end
end, { desc = "A repeat sign at the start or end of the cursor's bar (written only): `notation.repeat start`" })

command("notation.slur", function()
  local clip = view:clip()
  if not clip then return daw.notify("no clip open as notation", "warn") end
  local from, to = mark_span()
  local on = marks.slur(clip, from, to - 1e-3, view:cursor_staff())
  daw.notify(on and "slurred: the notes played legato" or "slur taken away")
end, { desc = "A slur over the selection: the notes under it played legato" })

command("notation.quantize", function()
  if not view:clip() then return daw.notify("no clip open as notation", "warn") end
  local n = view:quantize()
  daw.notify(n .. " notes played as written")
end, { desc = "Make the clip's notes exactly what is written (quantize to the notation)" })

command("notation.retranscribe", function()
  if not view:clip() then return daw.notify("no clip open as notation", "warn") end
  view:retranscribe()
  daw.notify("written again from the playing")
end, { desc = "Forget the voices, hands, graces, strums, beams and triplets set by hand" })

command("notation.raw", function()
  local clip = settings_clip()
  if not clip then return end
  local raw = view.settings_of(clip:get()).mode ~= "raw"
  view.keep(clip, function(own)
    own.settings = util.merge(own.settings or {}, {})
    own.settings.mode = raw and "raw" or nil
    if not next(own.settings) then own.settings = nil end
  end)
  daw.notify(raw and "notation: every note as played (raw)" or "notation: as a musician would write it")
end, { desc = "Show the clip note for note as played, or interpreted again" })

command("notation.reset", function()
  local clip = settings_clip()
  if not clip then return end
  view.keep(clip, function(own) own.settings = nil end)
  daw.notify("notation: default transcription")
end, { desc = "Forget the clip's transcription settings" })

command("notation.tab", function(ctx)
  local tab = require("notation.tab")
  local clip = view.target()
  local track = clip and clip:track() or daw.cursor.track()
  if not track then return daw.notify("no track", "warn") end
  local words = {}
  for _, a in ipairs(ctx.args) do words[#words + 1] = tostring(a) end
  if #words == 0 then
    local own = tab.of_track(track.id)
    if not own then return daw.notify("no tablature: `notation.tab guitar`, `bass`, `dropd`, `7string`, `bass5`, or the strings' notes") end
    local names = {}
    for i, p in ipairs(own.tuning) do names[i] = daw.music.name(p) end
    return daw.notify("tablature: " .. table.concat(names, " "))
  end
  local own, err = tab.set(track, words)
  if err then return daw.notify(err, "warn") end
  view.cache = nil
  daw.notify(own and ("tablature: " .. #own.tuning .. " strings") or "no tablature")
end, { desc = "Tablature under the staff for a guitar or bass track: `notation.tab guitar` (bass, dropd, dadgad, 7string, bass5, or `E2 A2 D3 G3 B3 E4`), `notation.tab off`" })

command("notation.tracks", function(ctx)
  local clip = view:clip() or view.target()
  if not clip then return daw.notify("no clip open as notation", "warn") end
  if view.multi and not ctx.args[1] then
    view.multi, view.cache = nil, nil
    return daw.notify("notation: this clip alone, to edit")
  end
  if not view:clip() then view:edit(clip) end
  local c = clip:get()
  local ids = {}
  for _, t in ipairs(daw.tracks()) do
    for _, other in ipairs(t:clips()) do
      local oc = other:get()
      if oc.kind == "midi" and oc.start < c.start + c.length and oc.start + oc.length > c.start and oc.note_count > 0 then
        ids[#ids + 1] = t.id
        break
      end
    end
  end
  view.multi, view.cache = ids, nil
  daw.notify("notation: " .. #ids .. " tracks, to read; :notation.tracks again to edit this clip")
end, { desc = "Show every track's MIDI over this clip's stretch as one system of staves (to read), or this clip alone again" })

command("notation.value", function(ctx)
  local names = { whole = 4, half = 2, quarter = 1, eighth = 0.5, ["16th"] = 0.25, ["32nd"] = 0.125 }
  local v = names[tostring(ctx.args[1] or "")]
  if not v then return daw.notify("a value is whole, half, quarter, eighth, 16th or 32nd", "warn") end
  view:choose(v)
end, { desc = "Choose the value notes are entered with: `notation.value eighth`" })

command("notation.export", function(ctx)
  local export = require("notation.export")
  local clip = view.target()
  if not clip then return daw.notify("no clip under the cursor", "warn") end
  local whole_track = ctx.args.track == "yes" or ctx.args.track == true or ctx.args[2] == "track"
  local c = clip:get()
  local track = clip:track()
  local name = whole_track and track.name or c.name
  local path = ctx.args[1] and tostring(ctx.args[1]) or (name:gsub("[^%w%-_]+", "_") .. ".musicxml")
  local _, stored = view.key()
  local opts = view.layout_opts(c)
  local layout
  if whole_track then
    opts.bars, opts.tuplets, opts.length, opts.offset = nil, nil, nil, nil
    layout = export.track_layout(track, opts, view.bars)
  else
    layout = model.layout(clip:notes(), opts)
  end
  view.decorate(layout, clip)
  local text
  if path:match("%.ly$") then
    text = export.lilypond(layout, { title = name, scale = stored and stored.scale })
  else
    text = export.musicxml(layout, { title = name, part = track.name })
  end
  local ok, err = export.write(path, text)
  if not ok then return daw.notify("could not write " .. path .. ": " .. tostring(err), "error") end
  daw.notify("wrote " .. path)
end, { desc = "Write the clip as MusicXML or LilyPond: `notation.export song.musicxml`, `notation.export lead.ly track`", complete = { "files", function() return { "track" } end } })

-- Reaching it from the arrange view and the window's clip menu.
map("<leader>n", "notation", { view = "arrange", desc = "Show the clip as notation" })
map("<leader>n", "notation", { view = "pianoroll", desc = "Show this clip as notation" })
if daw.frontend and daw.frontend.menus then
  table.insert(daw.frontend.menus.clip, { label = "Open as notation", command = "notation.open", only = "midi" })
end

-- Keys in the view ------------------------------------------------------------------------

local motion, linewise = { motion = true }, { motion = true, linewise = true }
local far = { motion = true, jump = true }
--- Keys that edit do nothing (and say why) while several tracks are shown.
local function guarded(rhs)
  if type(rhs) ~= "function" then return rhs end
  return function(...)
    if view:readonly() then return end
    return rhs(...)
  end
end
local READ = { gh = true, gp = true, zi = true, zo = true, ["<Esc>"] = true, gd = true, gR = true, gT = true }
local function nmap(lhs, rhs, desc, opts)
  if not (opts and opts.motion) and not READ[lhs] and not lhs:match("^g%d$") then rhs = guarded(rhs) end
  map(lhs, rhs, util.merge({ view = "notation", desc = desc }, opts))
end

local function move(dvalue, dstep) return function(ctx)
  local n = ctx.count or 1
  view:move(dvalue * n * view:entry_length(), dstep * n)
end end
nmap("h", move(-1, 0), "Back by the chosen value", motion)
nmap("l", move(1, 0), "On by the chosen value", motion)
nmap("<Left>", move(-1, 0), "Back by the chosen value", motion)
nmap("<Right>", move(1, 0), "On by the chosen value", motion)
nmap("j", move(0, -1), "Down a line or space", linewise)
nmap("k", move(0, 1), "Up a line or space", linewise)
nmap("<Down>", move(0, -1), "Down a line or space", linewise)
nmap("<Up>", move(0, 1), "Up a line or space", linewise)
nmap("J", move(0, -7), "Down an octave", linewise)
nmap("K", move(0, 7), "Up an octave", linewise)
nmap("w", function(ctx) view:to_event(1, ctx.count) end, "Next note or rest", motion)
nmap("b", function(ctx) view:to_event(-1, ctx.count) end, "Previous note or rest", motion)
nmap("e", function(ctx)
  for _ = 1, ctx.count or 1 do view:to_event_end() end
end, "End of this note, or the next", motion)
nmap("W", function(ctx) view:to_bar(ctx.count or 1) end, "Next bar", motion)
nmap("B", function(ctx) view:to_bar(-(ctx.count or 1)) end, "Previous bar", motion)
nmap("0", function() view:set(nil, 0) end, "Start of the clip", motion)
nmap("^", function()
  local first = view:starts()[1]
  for _, ev in ipairs(view:starts()) do
    if ev.notes then
      first = ev
      break
    end
  end
  if first then view:set(first.notes and first.notes[1].step or nil, math.max(0, first.start)) end
end, "The first note", motion)
nmap("$", function()
  local clip = view:clip()
  if clip then view:set(nil, clip.length) end
end, "End of the clip", motion)
nmap("gg", function() view:to_extreme(1) end, "The highest note's line", util.merge(far, { linewise = true }))
nmap("G", function() view:to_extreme(-1) end, "The lowest note's line", util.merge(far, { linewise = true }))
nmap("gp", function()
  local clip = view:clip()
  if clip then daw.transport.seek(clip.start + view.beat) end
end, "Playhead to the cursor")

-- Text objects: the note, the bar, the clip.
local function object(lhs, fn, desc) keymap.textobject(lhs, fn, { view = "notation", desc = desc }) end
for _, lhs in ipairs({ "in", "an" }) do
  object(lhs, function()
    local note = view:note()
    if note then return { view = "notation", kind = "block", r0 = note.pitch, r1 = note.pitch, c0 = note.start, c1 = note.start + note.length } end
  end, "The note under the cursor")
end
for _, lhs in ipairs({ "ib", "ab" }) do
  object(lhs, function(ctx)
    local m = view:measure_at(view.beat)
    if not m then return end
    local pitch = view:cursor_pitch()
    return { view = "notation", kind = "char", r0 = pitch, r1 = pitch, c0 = math.max(0, m.start), c1 = m.start + m.length * (ctx.count or 1) }
  end, "This bar, or N bars from it")
end
for _, lhs in ipairs({ "ic", "ac", "ie", "ae" }) do
  object(lhs, function()
    local clip = view:clip()
    local pitch = view:cursor_pitch()
    if clip then return { view = "notation", kind = "char", r0 = pitch, r1 = pitch, c0 = 0, c1 = clip.length } end
  end, "Every note of the clip")
end

-- Operators, as in the piano roll.
local function op(lhs, fn, desc)
  keymap.operator(lhs, function(region, ctx)
    local clip = view:clip()
    if lhs ~= "y" and lhs ~= "gl" and view:readonly() then return end
    if clip then return fn(clip, region, ctx) end
  end, { view = "notation", desc = desc })
end
op("d", function(clip, region, ctx) keymap.setreg(edit.roll.delete(clip, region), ctx.register) end, "Delete")
op("y", function(clip, region, ctx)
  local value = edit.roll.yank(clip, region)
  keymap.setreg(value, ctx.register, true)
  daw.notify(#value.notes == 1 and "yanked 1 note" or "yanked " .. #value.notes .. " notes")
end, "Yank")
op("c", function(clip, region, ctx)
  keymap.setreg(edit.roll.delete(clip, region), ctx.register)
  if region.kind ~= "line" then view:set(nil, region.c0) end
  view.last, view.chord = nil, nil
  keymap.set_mode("i")
end, "Change: delete and enter notes")
local function shift(clip, region, values)
  local by = math.max(values * view:entry_length(), region.kind == "line" and -math.huge or -region.c0)
  edit.roll.each(clip, region, function(n) n.start = math.max(0, n.start + by) end)
  if region.kind ~= "line" then view:set(nil, math.max(0, view.beat + by)) end
end
op(">", function(clip, region, ctx) shift(clip, region, region.visual and ctx.count or 1) end, "Move notes later by the chosen value")
op("<lt>", function(clip, region, ctx) shift(clip, region, -(region.visual and ctx.count or 1)) end, "Move notes earlier by the chosen value")
local function bounds(region)
  if region.kind == "line" then return nil, nil, nil, nil end
  if region.kind == "char" then return region.c0, region.c1 end
  return region.c0, region.c1, region.r0, region.r1
end
op("=", function(_, region)
  -- The performance made what is written: each note at its written place and value.
  local n = view:quantize(bounds(region))
  daw.notify(n == 1 and "1 note played as written" or n .. " notes played as written")
end, "Quantize to the notation: the notes exactly as they are written")
op("g=", function(_, region)
  local n = view:retranscribe(bounds(region))
  daw.notify("written again from the playing" .. (n > 0 and (" (" .. n .. " notes)") or ""))
end, "Write again from the playing: forget voices, hands, graces, strums and beams set here")
op("gl", function(clip, region)
  local c0, c1 = region.c0, region.c1
  if region.kind == "line" then c0, c1 = 0, clip.length end
  daw.transport.loop_start, daw.transport.loop_end, daw.transport.loop_enabled = clip.start + c0, clip.start + c1, true
end, "Loop")

-- Single keys.
local function each_count(fn) return function(ctx)
  for _ = 1, ctx.count or 1 do fn() end
end end
nmap("<CR>", function() view:toggle_note() end, "Add a note of the chosen value, or take away the one here")
local function insert()
  view.last, view.chord = nil, nil
  keymap.set_mode("i")
end
nmap("i", insert, "Enter notes by letter name (a to g)")
nmap("a", function()
  local note, index = view:note()
  if note then
    local _, finish = view:written_span(index)
    view:set(nil, finish)
  end
  insert()
end, "Enter notes after this one")
nmap("x", function() view:delete() end, "Delete the note")
nmap("X", function() view:delete_chord() end, "Delete the chord: every note it stands for")
nmap("<A-l>", function(ctx) view:move_chord((ctx.count or 1) * view:entry_length()) end, "Move the chord later by the chosen value, as played")
nmap("<A-h>", function(ctx) view:move_chord(-(ctx.count or 1) * view:entry_length()) end, "Move the chord earlier by the chosen value, as played")
nmap("gv", function()
  local v = view:toggle_voice()
  if v then daw.notify("voice " .. v) end
end, "The chord into the other voice")
nmap("gH", function()
  local s = view:toggle_staff()
  if s then daw.notify(s == 1 and "right hand" or "left hand") end
end, "The chord onto the other staff (hand)")
nmap("gs", function()
  local mark = view:cycle_strum()
  daw.notify("arpeggio: " .. tostring(mark or "as played"))
end, "Arpeggio sign: up, down, none, as played")
nmap("gG", function() daw.notify(view:toggle_grace() and "grace note" or "not a grace note") end, "The note a grace note, or the chord's grace note not one")
nmap("gb", function() daw.notify(view:toggle_beam() and "beam broken here" or "beam joined") end, "Break the beam before the chord, or join it")
nmap("gt", function()
  local on = view:toggle_tuplet()
  if on ~= nil then daw.notify(on and "this beat in triplets" or "triplets as played") end
end, "This beat in triplets (a duplet in 6/8), or as played")
nmap("ge", function() view:respell() end, "Respell the note: G sharp, A flat")
for lhs, kind in pairs({ ["g'"] = "staccato", ["g>"] = "accent", ["g_"] = "tenuto", ["g^"] = "marcato" }) do
  nmap(lhs, function()
    local on = marks.toggle_art(kind, view:chord_indices())
    if on ~= nil then daw.notify(kind .. (on and " on" or " off")) end
  end, kind:sub(1, 1):upper() .. kind:sub(2) .. " on the chord, or off")
end
nmap("D", function() keymap.normal("d$") end, "Delete to the end of the clip")
nmap("Y", function() keymap.normal("y$") end, "Yank to the end of the clip")
local function paste(before) return function(ctx)
  local clip = view:clip()
  if not clip then return end
  local at = view.beat
  if not before then
    local note, index = view:note()
    if note then
      local _, finish = view:written_span(index)
      at = finish or (note.start + note.length)
    end
  end
  local start = at
  for _ = 1, ctx.count or 1 do
    start = at
    at = edit.roll.paste(clip, keymap.getreg(ctx.register), view:cursor_pitch(), at)
    if not at then return end
  end
  view:set(nil, start)
end end
nmap("p", paste(false), "Paste after the note")
nmap("P", paste(true), "Paste at the cursor")
nmap("+", function(ctx) view:lengthen((ctx.count or 1) * view:entry_length()) end, "Lengthen the note by the chosen value")
nmap("-", function(ctx) view:lengthen(-(ctx.count or 1) * view:entry_length()) end, "Shorten the note by the chosen value")
nmap("g.", function() view:toggle_dot() end, "Dot the note, or take its dot away")
nmap("<C-a>", each_count(function() view:inflect(1) end), "Sharpen the note: a semitone up")
nmap("<C-x>", each_count(function() view:inflect(-1) end), "Flatten the note: a semitone down")
nmap("<A-k>", function(ctx) view:transpose_steps(ctx.count or 1) end, "Move the note up a step of the key")
nmap("<A-j>", function(ctx) view:transpose_steps(-(ctx.count or 1)) end, "Move the note down a step of the key")
nmap("}", function(ctx) view:transpose_octaves(ctx.count or 1) end, "Move the note up an octave")
nmap("{", function(ctx) view:transpose_octaves(-(ctx.count or 1)) end, "Move the note down an octave")
local VALUES = { [2] = 0.125, [3] = 0.25, [4] = 0.5, [5] = 1, [6] = 2, [7] = 4 }
for digit = 2, 7 do
  nmap("g" .. digit, function() view:choose(VALUES[digit]) end, "Enter " .. model.NAMES[VALUES[digit]] .. " notes")
end
nmap("gd", function()
  view.dot = not view.dot
  api.ui_redraw()
end, "Dotted values on or off, for entering")
nmap("gh", function() view:audition() end, "Hear the pitch under the cursor")
nmap("gR", function() daw.cmd("notation.raw") end, "Raw view: every note as played, or interpreted again")
nmap("gT", function() daw.cmd("notation.tracks") end, "Every track over this stretch, to read, or this clip alone")
nmap("zi", function()
  view.zoom = math.min(4, view.zoom + 0.5)
  view.gui_zoom = math.min(3, (view.gui_zoom or 1) * 1.25)
  api.ui_redraw()
end, "Spread the notes out")
nmap("zo", function()
  view.zoom = math.max(0.5, view.zoom - 0.5)
  view.gui_zoom = math.max(0.5, (view.gui_zoom or 1) / 1.25)
  api.ui_redraw()
end, "Draw the notes closer")
nmap("<Esc>", function() daw.ui.focus("arrange") end, "Back to the arrange view")

-- On a selection.
local function vmap(lhs, fn, desc)
  map(lhs, nil, { view = "notation", mode = "x", desc = desc, operator = function(region, ctx)
    local clip = view:clip()
    if view:readonly() then return end
    if clip then fn(clip, region, ctx) end
  end })
end
vmap("x", function(clip, region, ctx) keymap.setreg(edit.roll.delete(clip, region), ctx.register) end, "Delete")
for lhs, kind in pairs({ ["g'"] = "staccato", ["g>"] = "accent", ["g_"] = "tenuto", ["g^"] = "marcato" }) do
  vmap(lhs, function(_, region) marks.toggle_art(kind, target_notes(region)) end, kind:sub(1, 1):upper() .. kind:sub(2) .. " on the selection, or off")
end
vmap("(", function(clip, region)
  marks.slur(clip, math.max(0, region.c0), region.c1 - 1e-3, view:cursor_staff())
end, "A slur over the selection, played legato")
vmap("+", function(clip, region, ctx)
  view:relength_region(region, (ctx.count or 1) * view:entry_length())
end, "Lengthen each chord of the selection by the chosen value")
vmap("-", function(clip, region, ctx)
  view:relength_region(region, -(ctx.count or 1) * view:entry_length())
end, "Shorten each chord of the selection by the chosen value")
vmap("gs", function(clip, region)
  local _, places = edit.roll.notes(clip, region)
  local id = string.format("%x", math.floor(api.now() * 1000) % 0xffffff)
  view:override(places, function(own) own.chord = id end)
  daw.notify(#places .. " notes as one chord")
end, "The notes one chord (a strum)")
vmap("<C-a>", function(clip, region, ctx)
  local by = ctx.count or 1
  edit.roll.each(clip, region, function(n) n.pitch = math.min(127, n.pitch + by) end)
end, "Up a semitone")
vmap("<C-x>", function(clip, region, ctx)
  local by = ctx.count or 1
  edit.roll.each(clip, region, function(n) n.pitch = math.max(0, n.pitch - by) end)
end, "Down a semitone")
local function diatonic(by) return function(clip, region, ctx)
  local fifths = view.key()
  local n_by = by * (ctx.count or 1)
  edit.roll.each(clip, region, function(n)
    local sp = model.spell(n.pitch, fifths)
    n.pitch = util.clamp(model.key_pitch(sp.step + n_by, fifths), 0, 127)
    if n.meta then n.meta.notation = nil end
  end)
end end
vmap("<A-k>", diatonic(1), "Up a step of the key")
vmap("<A-j>", diatonic(-1), "Down a step of the key")
vmap("}", function(clip, region, ctx)
  edit.roll.each(clip, region, function(n) n.pitch = math.min(127, n.pitch + 12 * (ctx.count or 1)) end)
end, "Up an octave")
vmap("{", function(clip, region, ctx)
  edit.roll.each(clip, region, function(n) n.pitch = math.max(0, n.pitch - 12 * (ctx.count or 1)) end)
end, "Down an octave")

-- Insert mode: notes by letter name, as notation programs enter them.
local function imap(lhs, rhs, desc) map(lhs, guarded(rhs), { view = "notation", mode = "i", desc = desc }) end
for _, letter in ipairs({ "c", "d", "e", "f", "g", "a", "b" }) do
  imap(letter, function() view:enter(letter, true) end, "Enter " .. letter:upper() .. " and step on")
  imap(letter:upper(), function() view:enter(letter, false) end, "Enter " .. letter:upper() .. " and stay, for a chord")
end
for digit = 2, 7 do
  imap(tostring(digit), function() view:choose(VALUES[digit]) end, model.NAMES[VALUES[digit]] .. " notes")
end
imap(".", function()
  view.dot = not view.dot
  api.ui_redraw()
end, "Dotted values on or off")
imap("0", function() view:enter_rest() end, "A rest: clear the chosen value and step on")
imap("r", function() view:enter_rest() end, "A rest: clear the chosen value and step on")
imap("<Space>", function() view:step_on(1) end, "Step on, leaving what is there")
imap("<BS>", function() view:backspace() end, "Step back, removing what starts there")
imap("+", function() view:inflect_last(1) end, "Sharpen the note just entered")
imap("#", function() view:inflect_last(1) end, "Sharpen the note just entered")
imap("-", function() view:inflect_last(-1) end, "Flatten the note just entered")
imap("'", function() view:octave_last(1) end, "The note just entered an octave up")
imap(",", function() view:octave_last(-1) end, "The note just entered an octave down")
imap("<Left>", function() view:step_on(-1) end, "Step back")
imap("<Right>", function() view:step_on(1) end, "Step on")
imap("<Up>", function() view:move(0, 1) end, "Up a line or space")
imap("<Down>", function() view:move(0, -1) end, "Down a line or space")

-- What modal editing works on: rows are pitches, counting upwards.
view.grid = {
  down = -1,
  get = function() return view:cursor_pitch(), view.beat end,
  set = function(row, col)
    local step
    if row then step = model.spell(util.clamp(row, 0, 127), (view.key())).step end
    view:set(step, col)
  end,
  step = function() return view:entry_length() end,
  search = function(text)
    local wanted, hits = text:lower(), {}
    local layout = view:layout()
    for _, ev in ipairs(model.events(layout)) do
      for _, n in ipairs(ev.notes or {}) do
        if not n.tied and model.name(n):lower():find(wanted, 1, true) == 1 then hits[#hits + 1] = { row = n.pitch, col = math.max(0, ev.start) } end
      end
    end
    return hits
  end,
}

if daw.ui.keybar then
  daw.ui.keybar.set("notation", "n", {
    { "i", "enter" }, { "<CR>", "note" }, { "x", "delete" }, { "<C-a>", "sharp" }, { "<C-x>", "flat" },
    { "+", "longer" }, { "-", "shorter" }, { "g5", "quarter" }, { "gd", "dot" }, { "<Esc>", "back" },
  })
  daw.ui.keybar.set("notation", "i", {
    { "c", "C..B", "a-g" }, { "C", "chord", "A-G" }, { "5", "value", "2-7" }, { ".", "dot" }, { "r", "rest" },
    { "+", "sharp" }, { "-", "flat" }, { "'", "8va" }, { ",", "8vb" }, { "<BS>", "back" },
  })
end

return {}
