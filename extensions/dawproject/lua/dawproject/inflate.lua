-- Inflate (RFC 1951): the "deflate" method of a ZIP entry, decoded in Lua.
--
--   local data = require("dawproject.inflate")(compressed)
--
-- A DAWproject file is a ZIP archive, and the programs that write one
-- compress its XML (and often its media) with deflate.
local bit = require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local byte, char, concat = string.byte, string.char, table.concat

local LENGTH_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LENGTH_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
  4097, 6145, 8193, 12289, 16385, 24577 }
local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

--- A Huffman table from code lengths: for each length, the codes as
--- { [reversed code] = symbol }, and the longest length.
local function table_of(lengths, n)
  local count, next_code = {}, {}
  local max = 0
  for i = 0, 15 do count[i] = 0 end
  for s = 0, n - 1 do
    local l = lengths[s] or 0
    count[l] = count[l] + 1
    if l > max then max = l end
  end
  count[0] = 0
  local code = 0
  for l = 1, 15 do
    code = lshift(code + count[l - 1], 1)
    next_code[l] = code
  end
  local codes = {}
  for l = 1, max do codes[l] = {} end
  for s = 0, n - 1 do
    local l = lengths[s] or 0
    if l > 0 then
      local c = next_code[l]
      next_code[l] = c + 1
      -- Bits are read lowest first: keep the code reversed.
      local r = 0
      for _ = 1, l do
        r = bor(lshift(r, 1), band(c, 1))
        c = rshift(c, 1)
      end
      codes[l][r] = s
    end
  end
  return { codes = codes, max = max }
end

local FIXED_LIT, FIXED_DIST
do
  local l = {}
  for s = 0, 143 do l[s] = 8 end
  for s = 144, 255 do l[s] = 9 end
  for s = 256, 279 do l[s] = 7 end
  for s = 280, 287 do l[s] = 8 end
  FIXED_LIT = table_of(l, 288)
  local d = {}
  for s = 0, 29 do d[s] = 5 end
  FIXED_DIST = table_of(d, 30)
end

return function(data)
  local pos, bitbuf, bitcount = 1, 0, 0
  local out, outn = {}, 0
  local function bits(n)
    while bitcount < n do
      local b = byte(data, pos)
      if not b then error("inflate: the data ends early", 0) end
      pos = pos + 1
      bitbuf = bitbuf + b * 2 ^ bitcount
      bitcount = bitcount + 8
    end
    local v = band(bitbuf, lshift(1, n) - 1)
    bitbuf = rshift(bitbuf, n)
    bitcount = bitcount - n
    return v
  end
  local function decode(t)
    local code, len = 0, 0
    while len < t.max do
      code = bor(code, lshift(bits(1), len))
      len = len + 1
      local s = t.codes[len][code]
      if s then return s end
    end
    error("inflate: a bad code", 0)
  end
  repeat
    local final = bits(1)
    local kind = bits(2)
    if kind == 0 then
      bitbuf, bitcount = 0, 0
      local lo, hi = byte(data, pos, pos + 1)
      local len = lo + hi * 256
      pos = pos + 4
      for j = pos, pos + len - 1 do
        outn = outn + 1
        out[outn] = char(byte(data, j))
      end
      pos = pos + len
    else
      local lit, dist
      if kind == 1 then
        lit, dist = FIXED_LIT, FIXED_DIST
      elseif kind == 2 then
        local hlit, hdist, hclen = bits(5) + 257, bits(5) + 1, bits(4) + 4
        local cl = {}
        for i = 1, hclen do cl[ORDER[i]] = bits(3) end
        local clt = table_of(cl, 19)
        local lengths, i = {}, 0
        while i < hlit + hdist do
          local s = decode(clt)
          if s < 16 then
            lengths[i] = s
            i = i + 1
          else
            local rep, val = 0, 0
            if s == 16 then rep, val = 3 + bits(2), lengths[i - 1]
            elseif s == 17 then rep = 3 + bits(3)
            else rep = 11 + bits(7) end
            for _ = 1, rep do
              lengths[i] = val
              i = i + 1
            end
          end
        end
        local ll, dl = {}, {}
        for s = 0, hlit - 1 do ll[s] = lengths[s] end
        for s = 0, hdist - 1 do dl[s] = lengths[hlit + s] end
        lit, dist = table_of(ll, hlit), table_of(dl, hdist)
      else
        error("inflate: a bad block type", 0)
      end
      -- Symbols are kept one byte each in `out`, so a match can copy from them.
      while true do
        local s = decode(lit)
        if s < 256 then
          outn = outn + 1
          out[outn] = char(s)
        elseif s == 256 then
          break
        else
          local k = s - 256
          local len = LENGTH_BASE[k] + bits(LENGTH_EXTRA[k])
          local d = decode(dist) + 1
          local back = DIST_BASE[d] + bits(DIST_EXTRA[d])
          if back > outn then error("inflate: a match reaches before the start", 0) end
          for _ = 1, len do
            outn = outn + 1
            out[outn] = out[outn - back]
          end
        end
      end
    end
  until final == 1
  return concat(out, "", 1, outn)
end
