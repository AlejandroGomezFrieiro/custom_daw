-- The binary forms of JUCE plugins (TONE3000 and others), read and written
-- back byte for byte:
--
--   a ValueTree as `ValueTree::writeToStream` writes it: its type, its
--   properties (each a name and a `var`), its children
--   the base64 of `MemoryBlock::toBase64Encoding` ("<size>.<chars>"), which
--   JUCE's LV2 wrapper puts in the plugin's state
--
-- A tree is `{ type = "ChainBlock", props = { { name, raw }, ... },
-- children = { tree, ... } }`. `raw` is the property's value as stored (its
-- kind byte, then the data), so a property that is not changed is written
-- back as it was.
local ffi = require("ffi")
local bit = require("bit")
local bytes = require("plugstate.bytes")

local M = {}

-- --- compressed integers: a count of bytes (high bit: negative), then the
-- number, little-endian ----------------------------------------------------

local function read_cint(s, i)
  local n = s:byte(i)
  if not n then error("the data ends early", 0) end
  local neg = n >= 128
  n = n % 128
  local v = 0
  for k = n, 1, -1 do v = v * 256 + s:byte(i + k) end
  return neg and -v or v, i + 1 + n
end

local function cint(v)
  local neg = v < 0
  if neg then v = -v end
  local out = {}
  while v > 0 do
    out[#out + 1] = string.char(v % 256)
    v = math.floor(v / 256)
  end
  return string.char(#out + (neg and 128 or 0)) .. table.concat(out)
end
M.read_cint, M.cint = read_cint, cint

-- --- var ----------------------------------------------------------------------

local KIND = { int = 1, ["true"] = 2, ["false"] = 3, double = 4, string = 5, int64 = 6, binary = 8 }

local d1 = ffi.new("double[1]")
local i1 = ffi.new("int32_t[1]")
local l1 = ffi.new("int64_t[1]")

--- The value of a stored var: a number, a boolean, a string, or for a
--- binary block `{ binary = <bytes> }`.
function M.value(raw)
  if not raw or raw == "" then return nil end
  local kind, data = raw:byte(1), raw:sub(2)
  if kind == 1 then ffi.copy(i1, data, 4) return tonumber(i1[0]) end
  if kind == 2 then return true end
  if kind == 3 then return false end
  if kind == 4 then ffi.copy(d1, data, 8) return tonumber(d1[0]) end
  if kind == 5 then return (data:gsub("%z$", "")) end
  if kind == 6 then ffi.copy(l1, data, 8) return tonumber(l1[0]) end
  if kind == 8 then return { binary = data } end
  return nil
end

--- A var stored: `kind` is "int", "double" (numbers without it), "string",
--- "binary" (a string of bytes) or none for what the value is.
function M.raw(value, kind)
  local t = type(value)
  if t == "boolean" then return string.char(value and 2 or 3) end
  if t == "number" then
    if kind == "int" then i1[0] = value return "\1" .. ffi.string(i1, 4) end
    if kind == "int64" then l1[0] = value return "\6" .. ffi.string(l1, 8) end
    d1[0] = value
    return "\4" .. ffi.string(d1, 8)
  end
  if t == "table" and value.binary then return "\8" .. value.binary end
  if kind == "binary" then return "\8" .. value end
  return "\5" .. tostring(value) .. "\0"
end

-- --- trees --------------------------------------------------------------------

--- The tree at `i` (from 1) of `s`, and where it ends.
function M.parse(s, i)
  i = i or 1
  local zero = s:find("\0", i, true)
  if not zero then error("not a JUCE tree", 0) end
  local node = { type = s:sub(i, zero - 1), props = {}, children = {} }
  i = zero + 1
  local n
  n, i = read_cint(s, i)
  for k = 1, n do
    local z = s:find("\0", i, true)
    if not z then error("not a JUCE tree", 0) end
    local name = s:sub(i, z - 1)
    local size
    size, i = read_cint(s, z + 1)
    if i + size - 1 > #s then error("the data ends early", 0) end
    node.props[k] = { name, s:sub(i, i + size - 1) }
    i = i + size
  end
  n, i = read_cint(s, i)
  for k = 1, n do node.children[k], i = M.parse(s, i) end
  return node, i
end

local function emit(node, out)
  out[#out + 1] = node.type .. "\0" .. cint(#node.props)
  for _, p in ipairs(node.props) do
    out[#out + 1] = p[1] .. "\0" .. cint(#p[2])
    out[#out + 1] = p[2]
  end
  out[#out + 1] = cint(#node.children)
  for _, c in ipairs(node.children) do emit(c, out) end
end

--- The bytes of a tree.
function M.write(node)
  local out = {}
  emit(node, out)
  return table.concat(out)
end

--- A property's value.
function M.get(node, name)
  for _, p in ipairs(node.props) do
    if p[1] == name then return M.value(p[2]) end
  end
end

--- Set a property (added at the end when it is not there).
function M.set(node, name, value, kind)
  local raw = M.raw(value, kind)
  for _, p in ipairs(node.props) do
    if p[1] == name then p[2] = raw return end
  end
  node.props[#node.props + 1] = { name, raw }
end

--- The first child of a type, and its place.
function M.child(node, kind)
  for i, c in ipairs(node.children) do
    if c.type == kind then return c, i end
  end
end

--- A new tree.
function M.tree(kind, props, children)
  local node = { type = kind, props = {}, children = children or {} }
  for _, p in ipairs(props or {}) do M.set(node, p[1], p[2], p[3]) end
  return node
end

-- --- JUCE's base64 ---------------------------------------------------------------

local CHARS = ".ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+"
local DIGIT = ffi.new("int8_t[256]", -1)
for i = 1, 64 do DIGIT[CHARS:byte(i)] = i - 1 end
local CHAR = ffi.new("uint8_t[64]")
for i = 1, 64 do CHAR[i - 1] = CHARS:byte(i) end

--- Bytes from JUCE's "<size>.<chars>" text.
function M.decode64(text)
  local size, rest = text:match("^(%d+)%.(.*)$")
  if not size then error("not JUCE base64", 0) end
  size = tonumber(size)
  local out = ffi.new("uint8_t[?]", size + 2)
  local src = ffi.cast("const uint8_t*", rest)
  local pos = 0
  for k = 0, #rest - 1 do
    local v = DIGIT[src[k]]
    if v < 0 then error("not JUCE base64", 0) end
    -- Six bits from bit `pos`, least significant first.
    local byte, off = bit.rshift(pos, 3), bit.band(pos, 7)
    if byte < size then
      out[byte] = bit.bor(out[byte], bit.band(bit.lshift(v, off), 0xff))
      if off > 2 and byte + 1 < size then
        out[byte + 1] = bit.bor(out[byte + 1], bit.rshift(v, 8 - off))
      end
    end
    pos = pos + 6
  end
  return ffi.string(out, size)
end

--- JUCE's "<size>.<chars>" text of bytes.
function M.encode64(data)
  local size = #data
  local count = math.floor((size * 8 + 5) / 6)
  local src = ffi.new("uint8_t[?]", size + 2)
  ffi.copy(src, data, size)
  local out = ffi.new("uint8_t[?]", count)
  local pos = 0
  for k = 0, count - 1 do
    local byte, off = bit.rshift(pos, 3), bit.band(pos, 7)
    local v = bit.rshift(src[byte], off)
    if off > 2 then v = bit.bor(v, bit.lshift(src[byte + 1], 8 - off)) end
    out[k] = CHAR[bit.band(v, 63)]
    pos = pos + 6
  end
  return size .. "." .. ffi.string(out, count)
end

-- --- a JUCE plugin's state in paw's forms -----------------------------------------
-- paw gives the state of a CLAP plugin as the plugin wrote it; of a VST3
-- plugin as the component's part and the controller's, each after its
-- length; of an LV2 plugin as Turtle text, where JUCE's wrapper puts the
-- plugin's data in base64 under `...:StateString`. `open` finds the
-- plugin's own data in each form, and `close` puts new data back in its
-- place; the rest stays as it was.

--- The plugin's data in a state (paw's base64), and a function that gives
--- the state with other data in its place.
function M.open(state64, format)
  local raw = bytes.decode64(state64)
  if format == "lv2" then
    local before, text, after = raw:match('^(.-StateString>%s*")(%d+%.[^"]*)(".*)$')
    if not text then error("the state has no JUCE data", 0) end
    return M.decode64(text), function(data)
      return bytes.encode64(before .. M.encode64(data) .. after)
    end
  elseif format == "vst3" then
    local size = bytes.u32(raw, 1)
    if not size or 4 + size > #raw then error("not a VST3 state", 0) end
    local component, rest = raw:sub(5, 4 + size), raw:sub(5 + size)
    return component, function(data)
      return bytes.encode64(bytes.le32(#data) .. data .. rest)
    end
  end
  return raw, function(data) return bytes.encode64(data) end
end

return M
