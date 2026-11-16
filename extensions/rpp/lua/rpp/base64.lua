-- Base64 (RFC 4648, with padding) and little-endian integers, for the binary
-- blocks of a REAPER project: plugin states, MIDI sysex, render settings.
local M = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local VALUE = {}
for i = 1, 64 do VALUE[ALPHABET:byte(i)] = i - 1 end

function M.encode(data)
  local out, n = {}, #data
  for i = 1, n, 3 do
    local a, b, c = data:byte(i, i + 2)
    local v = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1 = math.floor(v / 262144) % 64
    local c2 = math.floor(v / 4096) % 64
    local c3 = math.floor(v / 64) % 64
    local c4 = v % 64
    out[#out + 1] = ALPHABET:sub(c1 + 1, c1 + 1) .. ALPHABET:sub(c2 + 1, c2 + 1)
      .. (b and ALPHABET:sub(c3 + 1, c3 + 1) or "=") .. (c and ALPHABET:sub(c4 + 1, c4 + 1) or "=")
  end
  return table.concat(out)
end

--- Decode, ignoring whitespace. Raises on characters outside the alphabet.
function M.decode(text)
  text = text:gsub("%s", "")
  local out, acc, bits = {}, 0, 0
  for i = 1, #text do
    local ch = text:byte(i)
    if ch == 61 then break end -- '='
    local v = VALUE[ch]
    if not v then error("not base64: " .. string.char(ch)) end
    acc = acc * 64 + v
    bits = bits + 6
    if bits >= 8 then
      bits = bits - 8
      local byte = math.floor(acc / 2 ^ bits)
      out[#out + 1] = string.char(byte)
      acc = acc - byte * 2 ^ bits
    end
  end
  return table.concat(out)
end

--- Unsigned 32-bit little-endian integer at 1-based `pos`.
function M.u32(data, pos)
  local a, b, c, d = data:byte(pos, pos + 3)
  if not d then return nil end
  return a + b * 256 + c * 65536 + d * 16777216
end

function M.pack_u32(n)
  n = n % 4294967296
  return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

return M
