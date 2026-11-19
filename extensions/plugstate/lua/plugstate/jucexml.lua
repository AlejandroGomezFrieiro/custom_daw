-- XML as JUCE plugins keep it (`AudioProcessor::copyXmlToBinary`,
-- `ValueTree::createXml`, `XmlElement::writeTo`), read into the trees of
-- `plugstate.juce`: an element is a node, its attributes are string
-- properties. What is not changed is written back byte for byte: each
-- element keeps the text of its tags, and the text between its children.
-- A changed or new element is written as JUCE writes it on one line.
local juce = require("plugstate.juce")

local M = {}

local ENTITY = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

local function utf8(n)
  if n < 0x80 then return string.char(n) end
  if n < 0x800 then return string.char(0xc0 + math.floor(n / 64), 0x80 + n % 64) end
  if n < 0x10000 then
    return string.char(0xe0 + math.floor(n / 4096), 0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
  end
  return string.char(0xf0 + math.floor(n / 262144), 0x80 + math.floor(n / 4096) % 64, 0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
end

--- Text with its entities read.
function M.unescape(text)
  return (text:gsub("&(#?x?)([%w]+);", function(kind, body)
    if kind == "#" then return utf8(tonumber(body)) end
    if kind == "#x" then return utf8(tonumber(body, 16)) end
    return ENTITY[body] or ("&" .. body .. ";")
  end))
end

-- JUCE's `isLegalXmlChar`: the ASCII characters written as they are.
local LEGAL = {}
do
  local mask = { 0, 0, 0, 0, 187, 255, 255, 175, 255, 255, 255, 191, 254, 255, 255, 127 }
  for c = 0, 127 do
    LEGAL[c] = math.floor(mask[math.floor(c / 8) + 1] / 2 ^ (c % 8)) % 2 == 1
  end
end

--- Text as JUCE escapes it (`XmlOutputFunctions::escapeIllegalXmlChars`).
function M.escape(text, attribute)
  return (text:gsub("[%z\1-\127]", function(c)
    local n = c:byte()
    if LEGAL[n] then return c end
    if c == "&" then return "&amp;" end
    if c == '"' then return "&quot;" end
    if c == ">" then return "&gt;" end
    if c == "<" then return "&lt;" end
    if (c == "\n" or c == "\r") and not attribute then return c end
    return "&#" .. n .. ";"
  end))
end

--- A number as JUCE writes a double in text (`serialiseDouble`): a whole
--- number with ".0", else the shortest text that reads back the same.
function M.number(v)
  if v ~= v then return "nan" end
  if v == math.huge then return "inf" end
  if v == -math.huge then return "-inf" end
  local a = math.abs(v)
  if a < 1e6 and a > 1e-5 and v == math.floor(v) then return string.format("%.1f", v) end
  if v == 0 then return "0.0" end
  for digits = 1, 17 do
    local text = string.format("%." .. digits .. "g", v)
    if tonumber(text) == v then return text end
  end
  return string.format("%.17g", v)
end

--- The text of a stored var, as `var::toString` gives it.
function M.text_of(raw)
  local v = juce.value(raw)
  local kind = juce.kind(raw)
  if v == nil then return "" end
  if type(v) == "boolean" then return v and "1" or "0" end
  if kind == "double" then return M.number(v) end
  if type(v) == "number" then return string.format("%d", v) end
  if type(v) == "table" and v.binary then return juce.encode64(v.binary) end
  if type(v) == "table" then return "" end
  return v
end

-- --- reading --------------------------------------------------------------------

local function fail(at, what) error(string.format("the XML is broken at byte %d: %s", at, what), 0) end

-- Skip what is not an element (text, comments, processing instructions,
-- a doctype) from `i`; returns where the next `<name` or `</` is, and the
-- text found (entities read, CDATA as it is).
local function skip(s, i)
  local text = {}
  while true do
    local lt = s:find("<", i, true)
    if not lt then
      text[#text + 1] = M.unescape(s:sub(i))
      return #s + 1, table.concat(text)
    end
    text[#text + 1] = M.unescape(s:sub(i, lt - 1))
    local two = s:sub(lt + 1, lt + 1)
    if s:sub(lt, lt + 3) == "<!--" then
      local stop = s:find("-->", lt + 4, true) or fail(lt, "a comment has no end")
      i = stop + 3
    elseif s:sub(lt, lt + 8) == "<![CDATA[" then
      local stop = s:find("]]>", lt + 9, true) or fail(lt, "a CDATA section has no end")
      text[#text + 1] = s:sub(lt + 9, stop - 1)
      i = stop + 3
    elseif two == "?" or two == "!" then
      local stop = s:find(">", lt, true) or fail(lt, "a declaration has no end")
      i = stop + 1
    else
      return lt, table.concat(text)
    end
  end
end

local parse_element

parse_element = function(s, i)
  local name, after = s:match("^<([%w_:%.%-]+)()", i)
  if not name then fail(i, "an element has no name") end
  local node = { type = name, props = {}, children = {}, xml = true, _attr = {} }
  local at = after
  while true do
    at = s:match("^%s*()", at)
    local c = s:sub(at, at)
    if c == "/" then
      if s:sub(at + 1, at + 1) ~= ">" then fail(at, "`/` not before `>`") end
      node._open, node._self = s:sub(i, at + 1), true
      return node, at + 2
    elseif c == ">" then
      node._open = s:sub(i, at)
      at = at + 1
      break
    elseif c == "" then
      fail(at, "the tag of " .. name .. " has no end")
    else
      local attr, q, stop = s:match("^([%w_:%.%-]+)%s*=%s*([\"'])()", at)
      if not attr then fail(at, "an attribute is broken") end
      local close = s:find(q, stop, true) or fail(stop, "an attribute value has no end")
      local text = s:sub(stop, close - 1)
      local raw = juce.raw(M.unescape(text), "string")
      node.props[#node.props + 1] = { attr, raw }
      node._attr[attr] = { raw = raw, text = text }
      at = close + 1
    end
  end
  -- The children, and the text before each and before the end tag.
  node._gaps = {}
  local texts = {}
  while true do
    local lt, text = skip(s, at)
    local gap = s:sub(at, lt - 1)
    texts[#texts + 1] = text
    if lt > #s then fail(at, "the element " .. name .. " has no end") end
    if s:sub(lt, lt + 1) == "</" then
      local stop = s:find(">", lt, true) or fail(lt, "an end tag has no `>`")
      if s:sub(lt + 2, stop - 1):match("^%s*(.-)%s*$") ~= name then fail(lt, "the end tag is not </" .. name .. ">") end
      node._tail, node._close = gap, s:sub(lt, stop)
      at = stop + 1
      break
    end
    local child
    child, at = parse_element(s, lt)
    node._gaps[child] = gap
    node.children[#node.children + 1] = child
  end
  local all = table.concat(texts)
  if all:find("%S") then node.text = all end
  node._text0 = node.text
  return node, at
end

local function signature(node)
  local parts = {}
  for _, p in ipairs(node.props) do parts[#parts + 1] = p[1] .. "\0" .. p[2] end
  return table.concat(parts, "\1")
end

--- The tree of an XML text, and what is around it: `{ root, before, after }`
--- (`before`: the declaration and what else is before the root element).
function M.parse(s)
  local lt = skip(s, 1)
  if lt > #s then error("the XML has no element", 0) end
  local root, stop = parse_element(s, lt)
  local function mark(node)
    node._sig = signature(node)
    node._n = #node.children
    for _, c in ipairs(node.children) do mark(c) end
  end
  mark(root)
  return { root = root, before = s:sub(1, lt - 1), after = s:sub(stop) }
end

-- --- writing --------------------------------------------------------------------

local function attribute(node, p)
  local was = node._attr and node._attr[p[1]]
  local text = was and was.raw == p[2] and was.text or M.escape(M.text_of(p[2]), true)
  return p[1] .. '="' .. text .. '"'
end

local function write(node, out)
  local empty = #node.children == 0 and not node.text
  -- An element read with an end tag keeps it; one read as `<a/>` keeps
  -- that form while it has nothing in it.
  local selfclose = empty
  if node._open and not node._self then selfclose = false end
  if node._open and node._sig == signature(node) and (node._self == true) == selfclose then
    out[#out + 1] = node._open
  else
    local parts = { "<" .. node.type }
    for _, p in ipairs(node.props) do parts[#parts + 1] = " " .. attribute(node, p) end
    parts[#parts + 1] = selfclose and "/>" or ">"
    out[#out + 1] = table.concat(parts)
  end
  if selfclose then return end
  if node.text ~= node._text0 then
    -- New text: written as JUCE writes the text of an element.
    out[#out + 1] = M.escape(node.text or "", false)
    for _, c in ipairs(node.children) do write(c, out) end
  else
    for _, c in ipairs(node.children) do
      out[#out + 1] = node._gaps and node._gaps[c] or ""
      write(c, out)
    end
    out[#out + 1] = node._tail or ""
  end
  out[#out + 1] = node._close or ("</" .. node.type .. ">")
end

--- The text of a tree, with what was around it (`doc` from `parse`, or a
--- tree alone: then with JUCE's declaration, as `copyXmlToBinary` writes).
function M.write(doc)
  if doc.type then doc = { root = doc, before = '<?xml version="1.0" encoding="UTF-8"?> ', after = "" } end
  local out = { doc.before or "" }
  write(doc.root, out)
  out[#out + 1] = doc.after or ""
  return table.concat(out)
end

--- A new element (a tree with `xml` set, so its numbers are written as
--- text): `props` is `{ { name, value }, ... }`.
function M.tree(kind, props, children)
  local node = juce.tree(kind, nil, children)
  node.xml = true
  for _, p in ipairs(props or {}) do juce.set(node, p[1], p[2], p[3]) end
  return node
end

return M
