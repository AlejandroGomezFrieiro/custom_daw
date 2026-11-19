-- zlib and gzip data (RFC 1950, 1951, 1952), for plugin states that JUCE's
-- `GZIPCompressorOutputStream` wrote. `inflate` reads every kind of deflate
-- block. `deflate` writes stored blocks only: a state written back is
-- larger than the plugin's own, but each reader takes it. A state that is
-- not changed keeps its own bytes (see `plugstate.jucestate`).
local ffi = require("ffi")
local bit = require("bit")
local band, bor, lshift, rshift, bxor = bit.band, bit.bor, bit.lshift, bit.rshift, bit.bxor

local M = {}

-- --- checksums ----------------------------------------------------------------

local CRC = ffi.new("uint32_t[256]")
for n = 0, 255 do
  local c = n
  for _ = 1, 8 do
    if band(c, 1) ~= 0 then c = bxor(0xedb88320, rshift(c, 1)) else c = rshift(c, 1) end
  end
  CRC[n] = c
end

--- The CRC-32 of bytes (as gzip has it), a number from 0.
function M.crc32(data)
  local c = 0xffffffff
  local src = ffi.cast("const uint8_t*", data)
  for i = 0, #data - 1 do
    c = bxor(CRC[band(bxor(c, src[i]), 0xff)], rshift(c, 8))
  end
  return (bxor(c, 0xffffffff) % 4294967296)
end

--- The Adler-32 of bytes (as zlib has it).
function M.adler32(data)
  local a, b = 1, 0
  local src = ffi.cast("const uint8_t*", data)
  for i = 0, #data - 1 do
    a = (a + src[i]) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end

-- --- inflate --------------------------------------------------------------------

local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DEXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- A Huffman table from code lengths: counts per length and the symbols in
-- canonical order (as zlib's `puff` does).
local function huffman(lengths, n)
  local count, symbol = {}, {}
  for len = 0, 15 do count[len] = 0 end
  for s = 0, n - 1 do count[lengths[s]] = count[lengths[s]] + 1 end
  local offs = { [1] = 0 }
  for len = 1, 14 do offs[len + 1] = offs[len] + count[len] end
  for s = 0, n - 1 do
    local len = lengths[s]
    if len ~= 0 then
      symbol[offs[len]] = s
      offs[len] = offs[len] + 1
    end
  end
  return { count = count, symbol = symbol }
end

--- The bytes of raw deflate data from `at` (from 1), and where it ends.
function M.inflate_raw(data, at)
  local src = ffi.cast("const uint8_t*", data)
  local size = #data
  local pos, bitbuf, bitcnt = (at or 1) - 1, 0, 0
  local cap = math.max(1024, size * 4)
  local out = ffi.new("uint8_t[?]", cap)
  local n = 0

  local function need(len)
    if n + len > cap then
      while n + len > cap do cap = cap * 2 end
      local grown = ffi.new("uint8_t[?]", cap)
      ffi.copy(grown, out, n)
      out = grown
    end
  end

  local function bits(want)
    local v = bitbuf
    while bitcnt < want do
      if pos >= size then error("the compressed data ends early", 0) end
      v = bor(v, lshift(src[pos], bitcnt))
      pos = pos + 1
      bitcnt = bitcnt + 8
    end
    bitbuf = rshift(v, want)
    bitcnt = bitcnt - want
    return band(v, lshift(1, want) - 1)
  end

  local function decode(h)
    local code, first, index = 0, 0, 0
    for len = 1, 15 do
      code = bor(code, bits(1))
      local count = h.count[len]
      if code - count < first then return h.symbol[index + (code - first)] end
      index = index + count
      first = (first + count) * 2
      code = code * 2
    end
    error("broken compressed data", 0)
  end

  local function codes(lencode, distcode)
    while true do
      local s = decode(lencode)
      if s < 256 then
        need(1)
        out[n] = s
        n = n + 1
      elseif s == 256 then
        return
      else
        s = s - 257
        if s >= 29 then error("broken compressed data", 0) end
        local len = LBASE[s + 1] + bits(LEXTRA[s + 1])
        local d = decode(distcode)
        local dist = DBASE[d + 1] + bits(DEXTRA[d + 1])
        if dist > n then error("broken compressed data", 0) end
        need(len)
        for _ = 1, len do
          out[n] = out[n - dist]
          n = n + 1
        end
      end
    end
  end

  local fixed_len, fixed_dist
  repeat
    local last = bits(1)
    local kind = bits(2)
    if kind == 0 then
      bitbuf, bitcnt = 0, 0
      if pos + 4 > size then error("the compressed data ends early", 0) end
      local len = src[pos] + src[pos + 1] * 256
      pos = pos + 4
      if pos + len > size then error("the compressed data ends early", 0) end
      need(len)
      ffi.copy(out + n, src + pos, len)
      n, pos = n + len, pos + len
    elseif kind == 1 then
      if not fixed_len then
        local l = {}
        for s = 0, 143 do l[s] = 8 end
        for s = 144, 255 do l[s] = 9 end
        for s = 256, 279 do l[s] = 7 end
        for s = 280, 287 do l[s] = 8 end
        fixed_len = huffman(l, 288)
        local d = {}
        for s = 0, 29 do d[s] = 5 end
        fixed_dist = huffman(d, 30)
      end
      codes(fixed_len, fixed_dist)
    elseif kind == 2 then
      local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
      local lengths = {}
      for i = 0, 18 do lengths[i] = 0 end
      for i = 1, ncode do lengths[ORDER[i]] = bits(3) end
      local lencode = huffman(lengths, 19)
      local all, i = {}, 0
      while i < nlen + ndist do
        local sym = decode(lencode)
        if sym < 16 then
          all[i] = sym
          i = i + 1
        else
          local len, rep = 0, 0
          if sym == 16 then
            if i == 0 then error("broken compressed data", 0) end
            len, rep = all[i - 1], 3 + bits(2)
          elseif sym == 17 then
            rep = 3 + bits(3)
          else
            rep = 11 + bits(7)
          end
          for _ = 1, rep do
            all[i] = len
            i = i + 1
          end
        end
      end
      local l, d = {}, {}
      for k = 0, nlen - 1 do l[k] = all[k] end
      for k = 0, ndist - 1 do d[k] = all[nlen + k] end
      codes(huffman(l, nlen), huffman(d, ndist))
    else
      error("broken compressed data", 0)
    end
  until last == 1
  return ffi.string(out, n), pos + 1
end

--- Raw deflate data of bytes, in stored blocks.
function M.deflate_raw(data)
  local out, at, size = {}, 1, #data
  repeat
    local len = math.min(65535, size - at + 1)
    local last = at + len > size and 1 or 0
    out[#out + 1] = string.char(last, len % 256, math.floor(len / 256), 255 - len % 256, 255 - math.floor(len / 256))
    out[#out + 1] = data:sub(at, at + len - 1)
    at = at + len
  until at > size
  return table.concat(out)
end

local function be32(n)
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

local function le32(n)
  return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

--- True when bytes start as zlib data does (a header whose check holds).
function M.is_zlib(data)
  local a, b = data:byte(1, 2)
  return a ~= nil and b ~= nil and band(a, 0x0f) == 8 and rshift(a, 4) <= 7 and (a * 256 + b) % 31 == 0 and band(b, 0x20) == 0
end

--- True when bytes start as gzip data does.
function M.is_gzip(data)
  return data:sub(1, 3) == "\31\139\8"
end

--- The bytes of zlib data, and where the data ends.
function M.unzlib(data)
  if not M.is_zlib(data) then error("not zlib data", 0) end
  local out, stop = M.inflate_raw(data, 3)
  local sum = data:sub(stop, stop + 3)
  if #sum == 4 and sum ~= be32(M.adler32(out)) then error("the zlib data is broken (checksum)", 0) end
  return out, stop + 4
end

--- zlib data of bytes.
function M.zlib(data)
  return "\120\1" .. M.deflate_raw(data) .. be32(M.adler32(data))
end

--- The bytes of gzip data, and where the data ends.
function M.ungzip(data)
  if not M.is_gzip(data) then error("not gzip data", 0) end
  local flags = data:byte(4)
  local at = 11
  if band(flags, 4) ~= 0 then at = at + 2 + data:byte(at) + data:byte(at + 1) * 256 end
  if band(flags, 8) ~= 0 then at = data:find("\0", at, true) + 1 end
  if band(flags, 16) ~= 0 then at = data:find("\0", at, true) + 1 end
  if band(flags, 2) ~= 0 then at = at + 2 end
  local out, stop = M.inflate_raw(data, at)
  return out, stop + 8
end

--- gzip data of bytes.
function M.gzip(data)
  return "\31\139\8\0\0\0\0\0\0\255" .. M.deflate_raw(data) .. le32(M.crc32(data)) .. le32(#data % 4294967296)
end

return M
