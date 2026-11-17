-- MIDI in REAPER projects: the events of an inline `<SOURCE MIDI` block, and
-- Standard MIDI Files that a source refers to.
--
-- Both give notes in ticks from the start of the source, plus counts of what
-- is not a note, so an import can say what it left out.
local fmt = require("rpp.format")
local smf = require("paw.midifile")
local M = {}

--- Pair note-ons with note-offs. `events` is a list of
--- { tick, status, data1, data2, muted }; returns notes as
--- { tick, length, pitch, velocity, channel, muted } in start order, and the
--- number of notes still held at the end (closed at `end_tick`).
local function pair(events, end_tick)
  local held, notes, open = {}, {}, 0
  for _, e in ipairs(events) do
    local kind, channel = math.floor(e[2] / 16), e[2] % 16
    local key = channel * 128 + e[3]
    if kind == 9 and e[4] > 0 then
      local list = held[key] or {}
      held[key] = list
      local note = { tick = e[1], pitch = e[3], velocity = e[4], channel = channel, muted = e[5] }
      list[#list + 1] = note
      notes[#notes + 1] = note
    elseif kind == 8 or kind == 9 then
      local list = held[key]
      local note = list and table.remove(list, 1)
      if note then note.length = e[1] - note.tick end
    end
  end
  for _, note in ipairs(notes) do
    if not note.length then
      note.length = math.max(0, end_tick - note.tick)
      open = open + 1
    end
  end
  table.sort(notes, function(a, b)
    if a.tick ~= b.tick then return a.tick < b.tick end
    return a.pitch < b.pitch
  end)
  return notes, open
end

local KIND_NAMES = {
  [10] = "aftertouch", [11] = "CC", [12] = "program change", [13] = "channel pressure", [14] = "pitch bend",
}

--- Read the events of a `<SOURCE MIDI` block. Returns
--- { ppq, qn, notes, length (ticks), other = { [what] = count }, muted, file }
--- where `file` is set instead when the source refers to a .mid file.
function M.read_source(source)
  local out = { ppq = 960, qn = true, notes = {}, length = 0, other = {}, muted = 0 }
  local file = source:child("FILE")
  if file then
    out.file = file:arg(1)
    return out
  end
  local hasdata = source:child("HASDATA")
  if hasdata then
    out.ppq = hasdata:argn(2) or 960
    out.qn = hasdata:arg(3) == "QN"
  end
  local ign = source:child("IGNTEMPO")
  if ign and ign:argn(1) == 1 then out.ignore_tempo = ign:argn(2) end
  local tick, events = 0, {}
  local function count(what) out.other[what] = (out.other[what] or 0) + 1 end
  for _, c in ipairs(source.children) do
    local name = c.tokens[1]
    if name == "E" or name == "e" or name == "Em" or name == "em" then
      tick = tick + (tonumber(c.tokens[2]) or 0)
      local status = tonumber(c.tokens[3] or "", 16)
      local d1, d2 = tonumber(c.tokens[4] or "0", 16) or 0, tonumber(c.tokens[5] or "0", 16) or 0
      if status then
        local kind = math.floor(status / 16)
        if kind == 8 or kind == 9 then
          events[#events + 1] = { tick, status, d1, d2, name:sub(2, 2) == "m" }
        elseif not (kind == 11 and d1 == 123 and d2 == 0) then
          -- "All notes off" is how REAPER marks the end of the source.
          count(KIND_NAMES[kind] or "other events")
        end
      end
    elseif name == "X" or name == "x" or name == "Xm" or name == "xm" then
      tick = tick + (tonumber(c.tokens[2]) or 0)
      count(c.children and #c.children > 0 and "sysex and text events" or "other events")
    end
  end
  out.length = tick
  local notes, open = pair(events, tick)
  for _, n in ipairs(notes) do
    if n.muted then out.muted = out.muted + 1 else out.notes[#out.notes + 1] = n end
  end
  if open > 0 then out.other["notes without an end (held to the end)"] = open end
  return out
end

--- Lines for the events of a `<SOURCE MIDI` block from notes in ticks
--- ({ tick, length, pitch, velocity, channel }), ending with REAPER's
--- end-of-source marker at `length` ticks.
function M.event_lines(notes, length)
  local events = {}
  for _, n in ipairs(notes) do
    local ch = n.channel or 0
    events[#events + 1] = { n.tick, 1, 0x90 + ch, n.pitch, n.velocity }
    events[#events + 1] = { n.tick + n.length, 0, 0x80 + ch, n.pitch, 0 }
  end
  -- Offs before ons at the same tick, so a repeated note is not cut short.
  table.sort(events, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    if a[2] ~= b[2] then return a[2] < b[2] end
    return a[4] < b[4]
  end)
  local lines, tick = {}, 0
  for _, e in ipairs(events) do
    lines[#lines + 1] = fmt.line("E", e[1] - tick, string.format("%02x", e[3]), string.format("%02x", e[4]),
      string.format("%02x", e[5]))
    tick = e[1]
  end
  lines[#lines + 1] = fmt.line("E", math.max(0, length - tick), "b0", "7b", "00")
  return lines
end

-- Standard MIDI Files: read and written by the program's own reader
-- (runtime/lua/paw/midifile.lua), in the shape a source's events have here.

local CONTROL_NAMES = { cc = "CC", bend = "pitch bend", pressure = "channel pressure", program = "program change" }

--- Read a Standard MIDI File. Returns { ppq, notes, length, other, tempo }
--- with every track's notes merged, ticks counted from the start, and the
--- first tempo found (bpm), or nil and a reason.
function M.read_smf(data)
  local file, why = smf.parse(data)
  if not file then return nil, why end
  local out = { ppq = file.ppq, notes = {}, length = file.length, other = {}, muted = 0 }
  local function count(what, n) out.other[what] = (out.other[what] or 0) + (n or 1) end
  for _, track in ipairs(file.tracks) do
    for _, n in ipairs(track.notes) do
      out.notes[#out.notes + 1] = { tick = n.tick, length = n.length, pitch = n.pitch, velocity = n.velocity, channel = n.channel }
    end
    for _, c in ipairs(track.controls) do count(c.key and "aftertouch" or CONTROL_NAMES[c.type]) end
  end
  for what, n in pairs(file.skipped) do count(what, n) end
  if #file.markers > 0 then count("markers", #file.markers) end
  table.sort(out.notes, function(a, b)
    if a.tick ~= b.tick then return a.tick < b.tick end
    return a.pitch < b.pitch
  end)
  out.tempo = file.tempos[1] and file.tempos[1].bpm
  return out
end

--- Write a Standard MIDI File (format 0) with these notes in ticks.
function M.write_smf(notes, ppq, bpm)
  return smf.encode({ format = 0, ppq = ppq, tempos = { { tick = 0, bpm = bpm or 120 } }, tracks = { { notes = notes } } })
end

return M
