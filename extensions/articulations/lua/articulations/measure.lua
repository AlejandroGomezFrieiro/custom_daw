-- How late each articulation of an instrument sounds, measured: one note
-- per articulation is rendered offline through the track's own devices
-- (any plugin, a Lua device, paw's sampler), each after what tells the
-- instrument its articulation, and where its sound starts is found in the
-- rendering. The delays found go into the instrument's map (`delay =
-- "-80ms"`), and from there into the track's downgrade map, so that the
-- kernel plays those notes that much earlier and they sit on the grid.
--
-- The onset: the rendering is cut into 1 ms blocks from the note's start;
-- the first block whose peak reaches 20 dB under the loudest block of the
-- note's first two seconds is where its sound starts.
local api = daw.api
local art = require("articulations")
local maps = art.maps
local toml = art.toml

local M = {}

M.method = "the first 1 ms block reaching 20 dB under the note's loudest, in the first 2 s after it"

local SPACING = 8      -- beats between two articulations' notes
local LENGTH = 4       -- beats a note is held
local LEAD = 0.5       -- beats before a note its keyswitch and controllers come
local WINDOW = 2       -- seconds looked at after a note
local BELOW = 10 ^ (-20 / 20)

local function song_end()
  local finish = 0
  for _, id in ipairs(api.track_list()) do
    for _, c in ipairs(api.clip_list(id)) do finish = math.max(finish, c.start + c.length) end
  end
  return finish
end

--- The pitch an articulation is measured on: the middle of its range, the
--- comfortable range's or the map's, else middle C.
local function pitch_of(map, a)
  local r = a.range or map.comfortable or map.range
  return r and math.floor((r[1] + r[2]) / 2) or 60
end

--- The notes and controller moves that play each articulation once, in a
--- clip that starts at beat 0: `notes, controls, at` (`at[i]` the beat of
--- the i-th articulation's note).
function M.score(map)
  local notes, controls, at = {}, {}, {}
  for i, a in ipairs(map.arts) do
    local t = 1 + (i - 1) * SPACING
    at[i] = t
    for _, e in ipairs(a.events) do
      if e.type == "note" then
        notes[#notes + 1] = { pitch = e.key, start = t - LEAD, length = 0.1, velocity = e.velocity or 100 }
      elseif e.type == "hold" then
        notes[#notes + 1] = { pitch = e.key, start = t - LEAD, length = LEAD + LENGTH, velocity = e.velocity or 100 }
      elseif e.type == "cc" then
        controls[#controls + 1] = { start = t - LEAD, type = "cc", number = e.number, value = e.value / 127 }
      elseif e.type == "program" then
        controls[#controls + 1] = { start = t - LEAD, type = "program", program = e.program, bank = e.bank }
      elseif e.type == "bend" then
        controls[#controls + 1] = { start = t - LEAD, type = "bend", value = e.value }
        controls[#controls + 1] = { start = t + LENGTH, type = "bend", value = 0 }
      end
    end
    local note = { pitch = pitch_of(map, a), start = t, length = LENGTH, velocity = 100 }
    for k, v in pairs(art.attr_fields(note, a.attr)) do note[k] = v end
    notes[#notes + 1] = note
  end
  table.sort(controls, function(x, y) return x.start < y.start end)
  return notes, controls, at
end

--- Peaks of 1 ms blocks of a 16-bit stereo WAV between two times in seconds.
local function blocks(path, from, to)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  local rate = 48000
  local fmt = data:find("fmt ", 1, true)
  if fmt then
    local b = { data:byte(fmt + 12, fmt + 15) }
    rate = b[1] + b[2] * 256 + b[3] * 65536 + b[4] * 16777216
  end
  local at = data:find("data", 1, true) + 8
  local per = math.max(1, math.floor(rate / 1000))
  local out = {}
  local first = math.floor(from * rate)
  local last = math.floor(to * rate)
  local byte = string.byte
  for frame0 = first, last - 1, per do
    local peak = 0
    for frame = frame0, math.min(last, frame0 + per) - 1 do
      local p = at + frame * 4
      if p + 3 > #data then break end
      for c = 0, 2, 2 do
        local lo, hi = byte(data, p + c, p + c + 1)
        local v = lo + hi * 256
        if v >= 32768 then v = v - 65536 end
        if v < 0 then v = -v end
        if v > peak then peak = v end
      end
    end
    out[#out + 1] = peak / 32768
  end
  return out
end

--- Render one note of each articulation through a track and find where each
--- one's sound starts. Returns `{ { art, onset (ms, nil when silent), delay
--- (the map's value: minus the onset), now (the map's delay) } }`.
function M.measure(track)
  local map = art.map_of(track)
  if not map then error("the track has no articulation map: :art.map", 0) end
  local notes, controls, at = M.score(map)
  local start = daw.time.bar_ceil(song_end() + 1e-9) + 4
  local length = at[#at] + SPACING
  local path = api.env().data_dir .. "/articulations/measure.wav"
  os.execute("mkdir -p '" .. (path:match("^(.*)/")):gsub("'", "'\\''") .. "'")
  local info
  daw.audition.try(function()
    -- The sound as the instrument makes it: the core plays notes early by
    -- the delays already in the map, which is not what is measured.
    local sent = art.attr_map(track)
    if sent and pcall(api.track_get, track) and api.track_get(track).attr_map then
      local plain = daw.util.merge(sent, { arts = {} })
      plain.delay = nil
      for code, e in pairs(sent.arts or {}) do
        plain.arts[code] = type(e) == "table" and { out = e.out } or e
      end
      api.track_set(track, "attr_map", plain)
    end
    local clip = daw.track(track):add_clip({ start = start, length = length, name = "measure", notes = notes })
    if #controls > 0 then clip:set_controls(controls) end
    daw.flush()
    info = daw.render(path, { start = start, ["end"] = start + length, tracks = { track }, tail = 0, bits = 16 })
  end)
  daw.audition.revert()
  local origin = daw.time.to_seconds(start)
  local out = {}
  for i, a in ipairs(map.arts) do
    local from = daw.time.to_seconds(start + at[i]) - origin
    local b = blocks(info.path or path, from, from + WINDOW)
    local loudest = 0
    for _, v in ipairs(b) do loudest = math.max(loudest, v) end
    local onset
    if loudest > 1e-4 then
      for k, v in ipairs(b) do
        if v >= loudest * BELOW then
          onset = k - 1
          break
        end
      end
    end
    out[i] = { art = a, onset = onset, delay = onset and -onset or nil, now = a.delay }
  end
  return out
end

--- A map's text with each articulation's `delay` set as `delays[id]` says
--- (milliseconds; nil leaves it), or nil and why.
function M.rewrite(text, delays)
  local lines, section = {}, nil
  local done = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local head = line:match("^%s*%[([^%]]+)%]")
    if head then section = head end
    if section == "art" and not head then
      for id, ms in pairs(delays) do
        local key = toml.key(id)
        local prefix = line:match("^(%s*" .. key:gsub("%p", "%%%0") .. "%s*=%s*{)")
        if prefix and line:find("}", #prefix + 1, true) then
          local value = 'delay = "' .. maps.delay_text(ms) .. '"'
          if line:find('delay%s*=%s*"[^"]*"') then
            line = line:gsub('delay%s*=%s*"[^"]*"', value, 1)
          else
            line = line:gsub("%s*}(%s*#?.*)$", ", " .. value .. " }%1", 1)
          end
          done[id] = true
        end
      end
    end
    lines[#lines + 1] = line
  end
  for id in pairs(delays) do
    if not done[id] then return nil, "articulation `" .. id .. "` is not one line of its own in the map's [art]" end
  end
  return (table.concat(lines, "\n"):gsub("\n*$", "\n"))
end

--- Write measured delays into the map's file and bind it again, so that the
--- track's downgrade map has them: one undo step for the track.
function M.apply(track, results)
  local map = art.map_of(track)
  local delays = {}
  for _, r in ipairs(results) do
    if r.delay then delays[r.art.id] = r.delay end
  end
  local text = maps.read(map.file)
  local new, why = M.rewrite(text, delays)
  if not new then error(why, 0) end
  maps.write(map.file, new)
  maps.forget()
  art.bind(track, map.file)
  return map.file
end

--- What a measurement found, as lines for a page.
function M.lines(map, results)
  local lines = { { text = "Articulation delays · " .. map.name, style = "Title" }, "  measured: " .. M.method, "" }
  for _, r in ipairs(results) do
    lines[#lines + 1] = string.format("  %-22s %-5s %s   delay %s%s", r.art.name, r.art.code,
      r.onset and ("sounds " .. r.onset .. " ms after its note") or "no sound",
      r.delay and maps.delay_text(r.delay) or "—",
      r.now and ("  (now " .. maps.delay_text(r.now) .. ")") or "")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  :art.measure! writes them into " .. tostring(map.file)
  return lines
end

local plan  -- the last measurement: { track, results }

daw.command("art.measure", function()
  local track = daw.ui.views.pianoroll:clip() and daw.ui.views.pianoroll:clip():get().track or (daw.cursor.track() and daw.cursor.track().id)
  if not track then error("no track here", 0) end
  local results = M.measure(track)
  plan = { track = track, results = results }
  daw.ui.page("Articulation delays", M.lines(art.map_of(track), results))
end, { desc = "Measure how late each articulation of the track's instrument sounds (one note each, rendered offline), and show the delays to write" })

daw.command("art.measure!", function()
  local track = daw.ui.views.pianoroll:clip() and daw.ui.views.pianoroll:clip():get().track or (daw.cursor.track() and daw.cursor.track().id)
  if not track then error("no track here", 0) end
  local results = plan and plan.track == track and plan.results or M.measure(track)
  plan = nil
  local file = M.apply(track, results)
  daw.notify("delays written into " .. file)
end, { label = "Articulation delays", desc = "Write the delays :art.measure found (or measure now) into the instrument's map, and send them" })

return M
