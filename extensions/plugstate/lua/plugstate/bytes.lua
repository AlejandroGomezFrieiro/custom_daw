-- Bytes for state codecs: base64 (the form `paw.api.device_state` gives a
-- plugin's state in) and little-endian numbers.
local bit = require("bit")

local M = {}

local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local index = {}
for i = 1, #alphabet do index[alphabet:byte(i)] = i - 1 end

--- Bytes from base64 text. Characters outside the alphabet are passed over.
function M.decode64(text)
  local out, acc, bits = {}, 0, 0
  for i = 1, #text do
    local v = index[text:byte(i)]
    if v then
      acc, bits = bit.bor(bit.lshift(acc, 6), v), bits + 6
      if bits >= 8 then
        bits = bits - 8
        out[#out + 1] = string.char(bit.band(bit.rshift(acc, bits), 0xff))
      end
    end
  end
  return table.concat(out)
end

--- Base64 text of bytes, padded with `=`.
function M.encode64(data)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local q = {
      alphabet:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1),
      alphabet:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1),
      b and alphabet:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "=",
      c and alphabet:sub(n % 64 + 1, n % 64 + 1) or "=",
    }
    out[#out + 1] = table.concat(q)
  end
  return table.concat(out)
end

--- The unsigned 32-bit little-endian number at `at` (from 1), or nil past the end.
function M.u32(data, at)
  local a, b, c, d = data:byte(at, at + 3)
  if not d then return nil end
  return a + b * 256 + c * 65536 + d * 16777216
end

--- Four bytes of an unsigned 32-bit number, little-endian.
function M.le32(n)
  return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

return M
