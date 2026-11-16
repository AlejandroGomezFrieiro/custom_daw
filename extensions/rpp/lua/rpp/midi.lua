-- MIDI in REAPER projects: the events of an inline `<SOURCE MIDI` block, and
-- Standard MIDI Files that a source refers to.
--
-- Both give notes in ticks from the start of the source, plus counts of what
-- is not a note, so an import can say what it left out.
local fmt = require("rpp.format")
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

-- Standard MIDI Files --------------------------------------------------------------

local function be(data, pos, n)
  local v = 0
  for i = 0, n - 1 do v = v * 256 + data:byte(pos + i) end
  return v
end

--- Read a Standard MIDI File. Returns { ppq, notes, length, other, tempo }
--- with every track's notes merged, ticks counted from the start, and the
--- first tempo found (bpm), or nil and a reason.
function M.read_smf(data)
  if #data < 14 or data:sub(1, 4) ~= "MThd" then return nil, "not a MIDI file" end
  local ntracks, division = be(data, 11, 2), be(data, 13, 2)
  if division >= 32768 then return nil, "SMPTE time division is not supported" end
  local out = { ppq = division, notes = {}, length = 0, other = {}, muted = 0 }
  local function count(what) out.other[what] = (out.other[what] or 0) + 1 end
  local events = {}
  local pos = 9 + be(data, 5, 4)
  for _ = 1, ntracks do
    if pos + 8 > #data + 1 then break end
    local id, size = data:sub(pos, pos + 3), be(data, pos + 4, 4)
    local p, stop = pos + 8, pos + 8 + size
    pos = stop
    if id == "MTrk" then
      local tick, running = 0, nil
      while p < stop do
        local delta = 0
        repeat
          local b = data:byte(p)
          p = p + 1
          delta = delta * 128 + b % 128
        until b < 128 or p >= stop
        tick = tick + delta
        local status = data:byte(p)
        if status >= 0x80 then p = p + 1 else status = running end
        if not status then break end
        if status == 0xFF then
          local kind = data:byte(p)
          p = p + 1
          local len = 0
          repeat
            local b = data:byte(p)
            p = p + 1
            len = len * 128 + b % 128
          until b < 128
          if kind == 0x51 and len == 3 and not out.tempo then
            out.tempo = 60000000 / be(data, p, 3)
          elseif kind ~= 0x2F and kind ~= 0x58 and kind ~= 0x03 and kind ~= 0x51 then
            count("text and other meta events")
          end
          p = p + len
        elseif status == 0xF0 or status == 0xF7 then
          local len = 0
          repeat
            local b = data:byte(p)
            p = p + 1
            len = len * 128 + b % 128
          until b < 128
          p = p + len
          count("sysex and text events")
        else
          running = status
          local kind = math.floor(status / 16)
          local d1 = data:byte(p) or 0
          local d2 = 0
          if kind == 12 or kind == 13 then
            p = p + 1
          else
            d2 = data:byte(p + 1) or 0
            p = p + 2
          end
          if kind == 8 or kind == 9 then
            events[#events + 1] = { tick, status, d1, d2 }
          else
            count(KIND_NAMES[kind] or "other events")
          end
        end
      end
      out.length = math.max(out.length, tick)
    end
  end
  table.sort(events, function(a, b) return a[1] < b[1] end)
  local open
  out.notes, open = pair(events, out.length)
  if open > 0 then out.other["notes without an end (held to the end)"] = open end
  return out
end

--- Write a Standard MIDI File (format 0) with these notes in ticks.
function M.write_smf(notes, ppq, bpm)
  local function vlq(n)
    local bytes = { string.char(n % 128) }
    n = math.floor(n / 128)
    while n > 0 do
      table.insert(bytes, 1, string.char(128 + n % 128))
      n = math.floor(n / 128)
    end
    return table.concat(bytes)
  end
  local events = {}
  for _, n in ipairs(notes) do
    events[#events + 1] = { n.tick, 1, 0x90 + (n.channel or 0), n.pitch, n.velocity }
    events[#events + 1] = { n.tick + n.length, 0, 0x80 + (n.channel or 0), n.pitch, 0 }
  end
  table.sort(events, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[2] < b[2]
  end)
  local us = math.floor(60000000 / (bpm or 120) + 0.5)
  local body = { "\0\255\81\3" .. string.char(math.floor(us / 65536), math.floor(us / 256) % 256, us % 256) }
  local tick = 0
  for _, e in ipairs(events) do
    body[#body + 1] = vlq(e[1] - tick) .. string.char(e[3], e[4], e[5])
    tick = e[1]
  end
  body[#body + 1] = "\0\255\47\0"
  local track = table.concat(body)
  local function u32(n) return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256) end
  return "MThd" .. u32(6) .. "\0\0\0\1" .. string.char(math.floor(ppq / 256), ppq % 256) .. "MTrk" .. u32(#track) .. track
end

return M
