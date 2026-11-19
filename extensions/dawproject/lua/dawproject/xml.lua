-- A small XML reader and writer, enough for the XML of a DAWproject file.
--
--   local root = xml.parse(text)        -- { name, attr = {}, children = {}, text }
--   root:child("Transport"), root:all("Track"), el.attr.name
--   local text = xml.write(root)        -- with the XML declaration
--
-- It reads elements, attributes, text, CDATA and the five named entities and
-- numeric character references. Comments, processing instructions and the
-- document type are skipped.
local M = {}

local Element = {}
Element.__index = Element

--- A new element: `xml.element("Track", { id = "t1", name = "Bass" })`.
function M.element(name, attr)
  return setmetatable({ name = name, attr = attr or {}, order = nil, children = {} }, Element)
end

--- The first child of a name, or nil.
function Element:child(name)
  for _, c in ipairs(self.children) do
    if c.name == name then return c end
  end
end

--- Every child of a name (every child with no name).
function Element:all(name)
  local out = {}
  for _, c in ipairs(self.children) do
    if not name or c.name == name then out[#out + 1] = c end
  end
  return out
end

--- Add a child element and return it: `el:add("Note", { time = 0 })`.
--- Attributes are written in the order of `keys` when it is given.
function Element:add(name, attr, keys)
  local c = type(name) == "table" and name or M.element(name, attr)
  c.order = keys or c.order
  self.children[#self.children + 1] = c
  return c
end

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

local function utf8(n)
  if n < 0x80 then return string.char(n) end
  if n < 0x800 then return string.char(0xC0 + math.floor(n / 64), 0x80 + n % 64) end
  if n < 0x10000 then
    return string.char(0xE0 + math.floor(n / 4096), 0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
  end
  return string.char(0xF0 + math.floor(n / 262144), 0x80 + math.floor(n / 4096) % 64, 0x80 + math.floor(n / 64) % 64,
    0x80 + n % 64)
end

local function unescape(s)
  return (s:gsub("&(#?x?)(%w+);", function(kind, name)
    if kind == "#" then return utf8(tonumber(name)) end
    if kind == "#x" then return utf8(tonumber(name, 16)) end
    return ENTITIES[name] or ("&" .. kind .. name .. ";")
  end))
end

--- Read a document. Returns its root element, or raises with the place of
--- the fault.
function M.parse(text)
  local pos = 1
  local root
  local stack = {}
  local function fail(why) error(string.format("XML: %s at byte %d", why, pos), 0) end
  while true do
    local lt = text:find("<", pos, true)
    local chunk = text:sub(pos, (lt or #text + 1) - 1)
    if #stack > 0 and chunk:find("%S") then
      local top = stack[#stack]
      top.text = (top.text or "") .. unescape(chunk)
    end
    if not lt then break end
    pos = lt
    if text:sub(pos, pos + 3) == "<!--" then
      local e = text:find("-->", pos + 4, true) or fail("a comment that does not end")
      pos = e + 3
    elseif text:sub(pos, pos + 8) == "<![CDATA[" then
      local e = text:find("]]>", pos + 9, true) or fail("CDATA that does not end")
      if #stack > 0 then
        local top = stack[#stack]
        top.text = (top.text or "") .. text:sub(pos + 9, e - 1)
      end
      pos = e + 3
    elseif text:sub(pos, pos + 1) == "<?" then
      local e = text:find("?>", pos + 2, true) or fail("a declaration that does not end")
      pos = e + 2
    elseif text:sub(pos, pos + 1) == "<!" then
      local e = text:find(">", pos + 2, true) or fail("a document type that does not end")
      pos = e + 1
    elseif text:sub(pos, pos + 1) == "</" then
      local name, e = text:match("^</%s*([^%s>]+)%s*>()", pos)
      if not name then fail("a bad end tag") end
      local top = table.remove(stack)
      if not top or top.name ~= name then fail("</" .. name .. "> does not match its start tag") end
      pos = e
    else
      local name, rest = text:match("^<([%w_:%.%-]+)()", pos)
      if not name then fail("a bad start tag") end
      local el = M.element(name)
      el.order = {}
      pos = rest
      while true do
        local s, e, key, q = text:find("^%s*([%w_:%.%-]+)%s*=%s*(['\"])", pos)
        if not s then break end
        local close = text:find(q, e + 1, true) or fail("an attribute value that does not end")
        el.attr[key] = unescape(text:sub(e + 1, close - 1))
        el.order[#el.order + 1] = key
        pos = close + 1
      end
      local selfclose, e = text:match("^%s*(/?)>()", pos)
      if not e then fail("a start tag of <" .. name .. "> that does not end") end
      pos = e
      if #stack > 0 then
        local parent = stack[#stack]
        parent.children[#parent.children + 1] = el
      elseif root then
        fail("more than one root element")
      else
        root = el
      end
      if selfclose ~= "/" then stack[#stack + 1] = el end
    end
  end
  if #stack > 0 then fail("<" .. stack[#stack].name .. "> does not end") end
  if not root then fail("no element") end
  return root
end

local function escape(s, attr)
  s = tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
  if attr then s = s:gsub('"', "&quot;"):gsub("\n", "&#10;"):gsub("\r", "&#13;"):gsub("\t", "&#9;") end
  return s
end

--- A number as text, short and exact enough: 0.5, 120, 0.333333333333.
function M.number(n)
  if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%d", n) end
  local s = string.format("%.12f", n):gsub("0+$", "")
  return s
end

local function value_text(v)
  if type(v) == "number" then return M.number(v) end
  if type(v) == "boolean" then return v and "true" or "false" end
  return tostring(v)
end

local function write_el(el, out, indent)
  local keys = {}
  local seen = {}
  for _, k in ipairs(el.order or {}) do
    if el.attr[k] ~= nil and not seen[k] then
      keys[#keys + 1] = k
      seen[k] = true
    end
  end
  local rest = {}
  for k in pairs(el.attr) do
    if not seen[k] then rest[#rest + 1] = k end
  end
  table.sort(rest)
  for _, k in ipairs(rest) do keys[#keys + 1] = k end
  local parts = { indent, "<", el.name }
  for _, k in ipairs(keys) do
    parts[#parts + 1] = string.format(' %s="%s"', k, escape(value_text(el.attr[k]), true))
  end
  if #el.children == 0 and not el.text then
    parts[#parts + 1] = "/>"
    out[#out + 1] = table.concat(parts)
  elseif #el.children == 0 then
    out[#out + 1] = table.concat(parts) .. ">" .. escape(el.text) .. "</" .. el.name .. ">"
  else
    out[#out + 1] = table.concat(parts) .. ">"
    for _, c in ipairs(el.children) do write_el(c, out, indent .. "  ") end
    out[#out + 1] = indent .. "</" .. el.name .. ">"
  end
end

--- The text of a document whose root is `root`.
function M.write(root)
  local out = { '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' }
  write_el(root, out, "")
  return table.concat(out, "\n") .. "\n"
end

return M
