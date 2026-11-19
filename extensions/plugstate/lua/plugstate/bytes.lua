-- Bytes for state codecs: base64 (the form `paw.api.device_state` gives a
-- plugin's state in) and little-endian numbers. A state can be megabytes
-- (an amp model inside it), so base64 goes through FFI buffers.
local bit = require("bit")
local ffi = require("ffi")

local M = {}

local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local index = ffi.new("int8_t[256]", -1)
for i = 1, #alphabet do index[alphabet:byte(i)] = i - 1 end
local chars = ffi.new("uint8_t[64]")
for i = 1, 64 do chars[i - 1] = alphabet:byte(i) end

--- Bytes from base64 text. Characters outside the alphabet are passed over.
function M.decode64(text)
  local n = #text
  local src = ffi.cast("const uint8_t*", text)
  local out = ffi.new("uint8_t[?]", math.floor(n * 3 / 4) + 3)
  local o, acc, bits = 0, 0, 0
  for i = 0, n - 1 do
    local v = index[src[i]]
    if v >= 0 then
      acc, bits = bit.band(bit.bor(bit.lshift(acc, 6), v), 0xffffff), bits + 6
      if bits >= 8 then
        bits = bits - 8
        out[o] = bit.band(bit.rshift(acc, bits), 0xff)
        o = o + 1
      end
    end
  end
  return ffi.string(out, o)
end

--- Base64 text of bytes, padded with `=`.
function M.encode64(data)
  local n = #data
  local src = ffi.new("uint8_t[?]", n + 3)
  ffi.copy(src, data, n)
  local out = ffi.new("uint8_t[?]", math.floor((n + 2) / 3) * 4 + 1)
  local o = 0
  for i = 0, n - 1, 3 do
    local v = bit.bor(bit.lshift(src[i], 16), bit.lshift(src[i + 1], 8), src[i + 2])
    out[o] = chars[bit.band(bit.rshift(v, 18), 63)]
    out[o + 1] = chars[bit.band(bit.rshift(v, 12), 63)]
    out[o + 2] = i + 1 < n and chars[bit.band(bit.rshift(v, 6), 63)] or 61
    out[o + 3] = i + 2 < n and chars[bit.band(v, 63)] or 61
    o = o + 4
  end
  return ffi.string(out, o)
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

--- The bytes of a file, or nil and why.
function M.read_file(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local data = f:read("*a")
  f:close()
  return data
end

local function u16(data, at)
  local a, b = data:byte(at, at + 1)
  return a + b * 256
end

--- The entries of a zip archive that are stored, not compressed (as
--- preset packs often are): `{ [name] = bytes }`. Compressed entries are
--- left out.
function M.unzip(data)
  -- The end of the central directory: its signature, from the end.
  local eocd
  for at = #data - 21, math.max(1, #data - 65557), -1 do
    if data:sub(at, at + 3) == "PK\5\6" then eocd = at break end
  end
  if not eocd then error("not a zip archive", 0) end
  local count, at = u16(data, eocd + 10), M.u32(data, eocd + 16) + 1
  local out = {}
  for _ = 1, count do
    if data:sub(at, at + 3) ~= "PK\1\2" then error("a broken zip archive", 0) end
    local method, size = u16(data, at + 10), M.u32(data, at + 20)
    local nlen, xlen, clen = u16(data, at + 28), u16(data, at + 30), u16(data, at + 32)
    local name = data:sub(at + 46, at + 45 + nlen)
    local head = M.u32(data, at + 42) + 1
    if method == 0 and data:sub(head, head + 3) == "PK\3\4" then
      local start = head + 30 + u16(data, head + 26) + u16(data, head + 28)
      out[name] = data:sub(start, start + size - 1)
    end
    at = at + 46 + nlen + xlen + clen
  end
  return out
end

return M
