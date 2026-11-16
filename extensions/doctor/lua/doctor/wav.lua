-- Sound files for the checks: writing the test sounds, reading back what was
-- recorded. Only what the checks need: PCM and float WAV.
local ffi = require("ffi")
local M = {}

local function u32(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
local function u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end

local function header(rate, channels, frames)
  local bytes = frames * channels * 2
  return "RIFF" .. u32(36 + bytes) .. "WAVEfmt " .. u32(16) .. u16(1) .. u16(channels) .. u32(rate)
    .. u32(rate * channels * 2) .. u16(channels * 2) .. u16(16) .. "data" .. u32(bytes)
end

--- Write a 16-bit WAV of `frames` frames. `sample(frame, channel)` gives each
--- sample from -1 to 1, with `frame` counting from 0 and `channel` from 1.
--- It is written a second at a time, so a long file takes no more memory.
function M.write(path, rate, channels, frames, sample)
  local file = assert(io.open(path, "wb"))
  file:write(header(rate, channels, frames))
  local buf = ffi.new("int16_t[?]", rate * channels)
  local at = 0
  while at < frames do
    local n = math.min(rate, frames - at)
    for i = 0, n - 1 do
      for ch = 1, channels do
        local v = sample(at + i, ch)
        buf[i * channels + ch - 1] = math.max(-32767, math.min(32767, math.floor(v * 32767 + 0.5)))
      end
    end
    file:write(ffi.string(buf, n * channels * 2))
    at = at + n
  end
  file:close()
end

--- The linear level of a number of decibels.
function M.gain(db) return 10 ^ (db / 20) end

--- The decibels of a linear level, -120 at the quietest.
function M.db(level)
  if level <= 1e-6 then return -120 end
  return 20 * math.log10(level)
end

--- Read a WAV file whole: `{ rate, channels, frames, peaks, onset }`, where
--- `peaks[ch]` is the loudest sample of each channel and `onset(level)` the
--- time in seconds of the first frame any channel is louder than `level`
--- (nil if none is). Float and 16, 24 and 32 bit integer files.
function M.read(path)
  local file = io.open(path, "rb")
  if not file then return nil, "cannot open " .. path end
  local data = file:read("*a")
  file:close()
  if data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then return nil, "not a WAV file" end
  local function u(at, n)
    local v = 0
    for i = n, 1, -1 do v = v * 256 + data:byte(at + i - 1) end
    return v
  end
  local pos, fmt, first, size = 13, nil, nil, 0
  while pos + 8 <= #data do
    local id, len = data:sub(pos, pos + 3), u(pos + 4, 4)
    if id == "fmt " then
      fmt = { tag = u(pos + 8, 2), channels = u(pos + 10, 2), rate = u(pos + 12, 4), bits = u(pos + 22, 2) }
    elseif id == "data" then
      -- A file cut short by a crash has a length that says more than is there.
      first, size = pos + 8, math.min(len, #data - pos - 7)
      break
    end
    pos = pos + 8 + len + len % 2
  end
  if not (fmt and first) then return nil, "no sound in the file" end
  local width = fmt.bits / 8
  local frames = math.floor(size / (width * fmt.channels))
  local base = ffi.cast("const uint8_t*", data) + (first - 1)
  local at
  if fmt.tag == 3 and fmt.bits == 32 then
    local p = ffi.cast("const float*", base)
    at = function(i) return p[i] end
  elseif fmt.bits == 16 then
    local p = ffi.cast("const int16_t*", base)
    at = function(i) return p[i] / 32768 end
  elseif fmt.bits == 32 then
    local p = ffi.cast("const int32_t*", base)
    at = function(i) return p[i] / 2147483648 end
  elseif fmt.bits == 24 then
    at = function(i)
      local b = base + i * 3
      local v = b[0] + b[1] * 256 + b[2] * 65536
      if v >= 8388608 then v = v - 16777216 end
      return v / 8388608
    end
  else
    return nil, "a " .. fmt.bits .. " bit file cannot be read here"
  end
  local ch = fmt.channels
  local peaks = {}
  for c = 1, ch do peaks[c] = 0 end
  for f = 0, frames - 1 do
    for c = 1, ch do
      local v = math.abs(at(f * ch + c - 1))
      if v > peaks[c] then peaks[c] = v end
    end
  end
  local info = { rate = fmt.rate, channels = ch, frames = frames, peaks = peaks, data = data }
  function info.onset(level)
    for f = 0, frames - 1 do
      for c = 1, ch do
        if math.abs(at(f * ch + c - 1)) > level then return f / fmt.rate end
      end
    end
  end
  return info
end

return M
