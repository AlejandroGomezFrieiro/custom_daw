-- What an `<Audio>` element must say about its file: the channels, the
-- sample rate and the length in seconds, read from the header of a WAV,
-- AIFF or FLAC file.
local M = {}

local function le(s, at, n)
  local v = 0
  for i = n, 1, -1 do v = v * 256 + s:byte(at + i - 1) end
  return v
end

local function be(s, at, n)
  local v = 0
  for i = 1, n do v = v * 256 + s:byte(at + i - 1) end
  return v
end

-- An 80-bit IEEE extended number (AIFF's sample rate).
local function extended(s, at)
  local exp = be(s, at, 2) % 32768
  local mant = be(s, at + 2, 4) * 2 ^ 32 + be(s, at + 6, 4)
  return mant * 2 ^ (exp - 16383 - 63)
end

--- { channels, rate, seconds } of a file's bytes, or nil.
function M.info(data)
  if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WAVE" then
    local at, fmt, size = 13, nil, nil
    while at + 8 <= #data do
      local id, len = data:sub(at, at + 3), le(data, at + 4, 4)
      if id == "fmt " then
        fmt = { channels = le(data, at + 10, 2), rate = le(data, at + 12, 4), align = le(data, at + 20, 2) }
      elseif id == "data" then
        size = math.min(len, #data - at - 7)
      end
      at = at + 8 + len + len % 2
    end
    if fmt and size and fmt.align > 0 and fmt.rate > 0 then
      return { channels = fmt.channels, rate = fmt.rate, seconds = size / fmt.align / fmt.rate }
    end
  elseif data:sub(1, 4) == "FORM" and (data:sub(9, 12) == "AIFF" or data:sub(9, 12) == "AIFC") then
    local at = 13
    while at + 8 <= #data do
      local id, len = data:sub(at, at + 3), be(data, at + 4, 4)
      if id == "COMM" then
        local channels, frames, rate = be(data, at + 8, 2), be(data, at + 10, 4), extended(data, at + 16)
        if rate > 0 then return { channels = channels, rate = math.floor(rate + 0.5), seconds = frames / rate } end
      end
      at = at + 8 + len + len % 2
    end
  elseif data:sub(1, 4) == "fLaC" then
    -- STREAMINFO: rate 20 bits, channels - 1 3 bits, bits - 1 5 bits, frames 36 bits.
    local s = 9
    local rate = math.floor(be(data, s + 10, 3) / 16)
    local channels = math.floor(be(data, s + 12, 1) / 2) % 8 + 1
    local frames = (be(data, s + 13, 1) % 16) * 2 ^ 32 + be(data, s + 14, 4)
    if rate > 0 then return { channels = channels, rate = rate, seconds = frames / rate } end
  end
end

return M
