-- Zip archives, as far as compressed MusicXML (.mxl) needs them: reading
-- the files of an archive (stored, or deflated: RFC 1951, in the manner of
-- zlib's puff.c), and writing one with its files stored.
--
--   local files = zip.read(bytes)      -- { [name] = bytes }, or nil and why
--   zip.write({ { name, data } })      -- the bytes of an archive
local bit = require("bit")

local M = {}

local byte, char, floor = string.byte, string.char, math.floor

local function u16(s, p) return byte(s, p) + byte(s, p + 1) * 256 end
local function u32(s, p) return u16(s, p) + u16(s, p + 2) * 65536 end

-- Inflate ----------------------------------------------------------------------------------------

local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
  4097, 6145, 8193, 12289, 16385, 24577 }
local DEXT = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

--- A canonical Huffman code from code lengths (index 0 up): counts by
--- length and the symbols in code order.
local function huffman(lengths, n)
  local count, offs, symbol = {}, {}, {}
  for len = 0, 15 do count[len] = 0 end
  for s = 0, n - 1 do count[lengths[s] or 0] = count[lengths[s] or 0] + 1 end
  offs[1] = 0
  for len = 1, 14 do offs[len + 1] = offs[len] + count[len] end
  for s = 0, n - 1 do
    local len = lengths[s] or 0
    if len ~= 0 then
      symbol[offs[len]] = s
      offs[len] = offs[len] + 1
    end
  end
  return { count = count, symbol = symbol }
end

local fixed_lit, fixed_dist

--- Raw deflate data from `pos` of `data` inflated: the bytes, or an error.
function M.inflate(data, pos)
  pos = pos or 1
  local buf, cnt = 0, 0
  local out, n = {}, 0
  local function bits(need)
    while cnt < need do
      local b = byte(data, pos)
      if not b then error("the compressed data ends too soon", 0) end
      buf = buf + b * 2 ^ cnt
      pos, cnt = pos + 1, cnt + 8
    end
    local p = 2 ^ need
    local v = buf % p
    buf, cnt = floor(buf / p), cnt - need
    return v
  end
  local function decode(h)
    local code, first, index = 0, 0, 0
    local count, symbol = h.count, h.symbol
    for len = 1, 15 do
      code = code + bits(1)
      local c = count[len]
      if code - c < first then return symbol[index + code - first] end
      index = index + c
      first = (first + c) * 2
      code = code * 2
    end
    error("a bad code in the compressed data", 0)
  end
  local function codes(lit, dist)
    while true do
      local sym = decode(lit)
      if sym < 256 then
        n = n + 1
        out[n] = sym
      elseif sym == 256 then
        return
      else
        sym = sym - 257
        if sym >= 29 then error("a bad length in the compressed data", 0) end
        local len = LBASE[sym + 1] + bits(LEXT[sym + 1])
        local d = decode(dist)
        if d >= 30 then error("a bad distance in the compressed data", 0) end
        local back = DBASE[d + 1] + bits(DEXT[d + 1])
        if back > n then error("a distance too far back in the compressed data", 0) end
        for _ = 1, len do
          n = n + 1
          out[n] = out[n - back]
        end
      end
    end
  end
  repeat
    local last = bits(1)
    local kind = bits(2)
    if kind == 0 then
      buf, cnt = 0, 0
      local len = u16(data, pos)
      pos = pos + 4
      for i = 0, len - 1 do out[n + 1 + i] = byte(data, pos + i) end
      n, pos = n + len, pos + len
    elseif kind == 1 then
      if not fixed_lit then
        local l = {}
        for s = 0, 143 do l[s] = 8 end
        for s = 144, 255 do l[s] = 9 end
        for s = 256, 279 do l[s] = 7 end
        for s = 280, 287 do l[s] = 8 end
        fixed_lit = huffman(l, 288)
        local d = {}
        for s = 0, 29 do d[s] = 5 end
        fixed_dist = huffman(d, 30)
      end
      codes(fixed_lit, fixed_dist)
    elseif kind == 2 then
      local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
      local lengths = {}
      for i = 1, 19 do lengths[ORDER[i]] = 0 end
      for i = 1, ncode do lengths[ORDER[i]] = bits(3) end
      local lencode = huffman(lengths, 19)
      local all, i = {}, 0
      while i < nlen + ndist do
        local sym = decode(lencode)
        if sym < 16 then
          all[i], i = sym, i + 1
        else
          local len, rep = 0, 0
          if sym == 16 then
            if i == 0 then error("a repeat with nothing before it in the compressed data", 0) end
            len, rep = all[i - 1], 3 + bits(2)
          elseif sym == 17 then
            rep = 3 + bits(3)
          else
            rep = 11 + bits(7)
          end
          for _ = 1, rep do all[i], i = len, i + 1 end
        end
      end
      local lit, dist = {}, {}
      for s = 0, nlen - 1 do lit[s] = all[s] end
      for s = 0, ndist - 1 do dist[s] = all[nlen + s] end
      codes(huffman(lit, nlen), huffman(dist, ndist))
    else
      error("a bad block in the compressed data", 0)
    end
  until last == 1
  local parts = {}
  for i = 1, n, 4096 do parts[#parts + 1] = char(unpack(out, i, math.min(n, i + 4095))) end
  return table.concat(parts)
end

-- Archives ---------------------------------------------------------------------------------------

--- The files of a zip archive, `{ [name] = bytes }`, or nil and why.
function M.read(data)
  -- The end of the central directory: the last signature in the file.
  local eocd
  for p = #data - 21, math.max(1, #data - 65557), -1 do
    if data:sub(p, p + 3) == "PK\5\6" then
      eocd = p
      break
    end
  end
  if not eocd then return nil, "not a zip archive" end
  local count, at = u16(data, eocd + 10), u32(data, eocd + 16) + 1
  local files = {}
  for _ = 1, count do
    if data:sub(at, at + 3) ~= "PK\1\2" then return nil, "the archive's directory is damaged" end
    local method, size = u16(data, at + 10), u32(data, at + 20)
    local nlen, xlen, clen = u16(data, at + 28), u16(data, at + 30), u16(data, at + 32)
    local local_at = u32(data, at + 42) + 1
    local name = data:sub(at + 46, at + 45 + nlen)
    at = at + 46 + nlen + xlen + clen
    if data:sub(local_at, local_at + 3) ~= "PK\3\4" then return nil, "the archive's " .. name .. " is damaged" end
    local start = local_at + 30 + u16(data, local_at + 26) + u16(data, local_at + 28)
    if method == 0 then
      files[name] = data:sub(start, start + size - 1)
    elseif method == 8 then
      local ok, bytes = pcall(M.inflate, data, start)
      if not ok then return nil, name .. ": " .. tostring(bytes) end
      files[name] = bytes
    else
      return nil, name .. " is compressed in a way not read here (method " .. method .. ")"
    end
  end
  return files
end

local crc_table
--- The CRC-32 of a string, as zip keeps it.
function M.crc32(s)
  if not crc_table then
    crc_table = {}
    for i = 0, 255 do
      local c = i
      for _ = 1, 8 do
        if bit.band(c, 1) == 1 then c = bit.bxor(0xEDB88320, bit.rshift(c, 1)) else c = bit.rshift(c, 1) end
      end
      crc_table[i] = c
    end
  end
  local c = 0xFFFFFFFF
  for i = 1, #s do c = bit.bxor(crc_table[bit.band(bit.bxor(c, byte(s, i)), 0xFF)], bit.rshift(c, 8)) end
  c = bit.bxor(c, 0xFFFFFFFF)
  if c < 0 then c = c + 4294967296 end
  return c
end

local function le(v, n)
  local out = {}
  for i = 1, n do
    out[i] = char(v % 256)
    v = floor(v / 256)
  end
  return table.concat(out)
end

--- The bytes of a zip archive of `files` (`{ { name, data } }`), stored.
function M.write(files)
  local body, dir, at = {}, {}, 0
  for _, f in ipairs(files) do
    local name, data = f[1], f[2]
    local crc = M.crc32(data)
    local head = "PK\3\4" .. le(20, 2) .. le(0, 2) .. le(0, 2) .. le(0, 2) .. le(33, 2) .. le(crc, 4)
      .. le(#data, 4) .. le(#data, 4) .. le(#name, 2) .. le(0, 2) .. name
    dir[#dir + 1] = "PK\1\2" .. le(20, 2) .. le(20, 2) .. le(0, 2) .. le(0, 2) .. le(0, 2) .. le(33, 2) .. le(crc, 4)
      .. le(#data, 4) .. le(#data, 4) .. le(#name, 2) .. le(0, 2) .. le(0, 2) .. le(0, 2) .. le(0, 2) .. le(0, 4)
      .. le(at, 4) .. name
    body[#body + 1] = head .. data
    at = at + #head + #data
  end
  local directory = table.concat(dir)
  return table.concat(body) .. directory .. "PK\5\6" .. le(0, 2) .. le(0, 2) .. le(#files, 2) .. le(#files, 2)
    .. le(#directory, 4) .. le(at, 4) .. le(0, 2)
end

return M
