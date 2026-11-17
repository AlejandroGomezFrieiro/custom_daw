-- A small XML reader and the escaping a writer needs: enough for the
-- MusicXML that MuseScore, Dorico, Sibelius and Finale write (a prolog, a
-- DOCTYPE with or without an internal subset, comments, CDATA, character
-- and the five named entities, UTF-8 or UTF-16 with a byte order mark).
-- Namespaces, processing instructions and entities a DTD defines are not
-- understood: their text is kept as it is.
--
--   local el = xml.parse(text)          -- the root element, or nil and why
--   el.name, el.attrs, el.kids, el.text -- kids: the child elements in order
--   xml.child(el, "part-list")          -- the first child of that name
--   xml.children(el, "part")            -- every child of that name
--   xml.text(el, "divisions")           -- a child's text, trimmed (nil if none)
local M = {}

local NAMED = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

--- UTF-8 for a code point.
local function utf8(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  end
  return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64, 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local function unescape(s)
  if not s:find("&", 1, true) then return s end
  return (s:gsub("&(#?[xX]?%w+);", function(e)
    if e:sub(1, 2) == "#x" or e:sub(1, 2) == "#X" then
      local n = tonumber(e:sub(3), 16)
      return n and utf8(n) or nil
    elseif e:sub(1, 1) == "#" then
      local n = tonumber(e:sub(2))
      return n and utf8(n) or nil
    end
    return NAMED[e]
  end))
end
M.unescape = unescape

--- Text with UTF-16 (by its byte order mark) as UTF-8.
local function from_utf16(s, big)
  local out, i = {}, 3
  while i + 1 <= #s do
    local a, b = s:byte(i), s:byte(i + 1)
    local u = big and a * 256 + b or b * 256 + a
    i = i + 2
    if u >= 0xD800 and u < 0xDC00 and i + 1 <= #s then
      local c, d = s:byte(i), s:byte(i + 1)
      local lo = big and c * 256 + d or d * 256 + c
      i = i + 2
      u = 0x10000 + (u - 0xD800) * 1024 + (lo - 0xDC00)
    end
    out[#out + 1] = utf8(u)
  end
  return table.concat(out)
end

local function attributes(s)
  local attrs = {}
  for k, q, v in s:gmatch("([%w_:%.%-]+)%s*=%s*([\"'])(.-)%2") do attrs[k] = unescape(v) end
  return attrs
end

--- The root element of a document, or nil and what is wrong.
function M.parse(text)
  if text:sub(1, 2) == "\255\254" then
    text = from_utf16(text, false)
  elseif text:sub(1, 2) == "\254\255" then
    text = from_utf16(text, true)
  elseif text:sub(1, 3) == "\239\187\191" then
    text = text:sub(4)
  end
  local root
  local stack = {}
  local pos, n = 1, #text
  local find, sub = string.find, string.sub
  local function add_text(s)
    local top = stack[#stack]
    if top and s ~= "" then
      top.parts = top.parts or {}
      top.parts[#top.parts + 1] = s
    end
  end
  while pos <= n do
    local lt = find(text, "<", pos, true)
    if not lt then
      add_text(unescape(sub(text, pos)))
      break
    end
    if lt > pos then add_text(unescape(sub(text, pos, lt - 1))) end
    local c = sub(text, lt + 1, lt + 1)
    if c == "?" then
      local e = find(text, "?>", lt + 2, true)
      if not e then return nil, "a processing instruction is not closed" end
      pos = e + 2
    elseif sub(text, lt + 1, lt + 3) == "!--" then
      local e = find(text, "-->", lt + 4, true)
      if not e then return nil, "a comment is not closed" end
      pos = e + 3
    elseif sub(text, lt + 1, lt + 8) == "![CDATA[" then
      local e = find(text, "]]>", lt + 9, true)
      if not e then return nil, "a CDATA section is not closed" end
      add_text(sub(text, lt + 9, e - 1))
      pos = e + 3
    elseif c == "!" then
      -- A DOCTYPE, perhaps with an internal subset in brackets.
      local depth, i = 0, lt + 2
      while i <= n do
        local ch = sub(text, i, i)
        if ch == "[" then
          depth = depth + 1
        elseif ch == "]" then
          depth = depth - 1
        elseif ch == ">" and depth <= 0 then
          break
        end
        i = i + 1
      end
      pos = i + 1
    elseif c == "/" then
      local e = find(text, ">", lt + 2, true)
      if not e then return nil, "a closing tag is not closed" end
      local name = sub(text, lt + 2, e - 1):match("^%s*([^%s>]+)")
      local top = table.remove(stack)
      if not top or top.name ~= name then
        return nil, "</" .. tostring(name) .. "> closes <" .. tostring(top and top.name) .. ">"
      end
      if top.parts then top.text = table.concat(top.parts) top.parts = nil end
      pos = e + 1
    else
      -- An element's start: attributes may hold ">" inside quotes.
      local i = lt + 1
      while true do
        local e = find(text, "[>\"']", i)
        if not e then return nil, "a tag is not closed" end
        local ch = sub(text, e, e)
        if ch == ">" then
          i = e
          break
        end
        local close = find(text, ch, e + 1, true)
        if not close then return nil, "an attribute's quotes are not closed" end
        i = close + 1
      end
      local body = sub(text, lt + 1, i - 1)
      local empty = body:sub(-1) == "/"
      if empty then body = body:sub(1, -2) end
      local name, rest = body:match("^([^%s/>]+)(.*)$")
      if not name then return nil, "a tag with no name" end
      local el = { name = name, attrs = rest:find("=", 1, true) and attributes(rest) or {}, kids = {} }
      local top = stack[#stack]
      if top then
        top.kids[#top.kids + 1] = el
      elseif not root then
        root = el
      end
      if not empty then stack[#stack + 1] = el end
      pos = i + 1
    end
  end
  if #stack > 0 then return nil, "<" .. stack[#stack].name .. "> is not closed" end
  if not root then return nil, "no element in it" end
  return root
end

--- The first child of an element with a name.
function M.child(el, name)
  if not el then return nil end
  for _, k in ipairs(el.kids) do
    if k.name == name then return k end
  end
end

--- Every child of an element with a name (every child without one).
function M.children(el, name)
  local out = {}
  if not el then return out end
  for _, k in ipairs(el.kids) do
    if not name or k.name == name then out[#out + 1] = k end
  end
  return out
end

--- A child's text, trimmed; nil when there is no such child.
function M.text(el, name)
  local c = M.child(el, name)
  if not c then return nil end
  return ((c.text or ""):match("^%s*(.-)%s*$"))
end

--- A child's text as a number, or nil.
function M.number(el, name) return tonumber(M.text(el, name) or "") end

--- Text made safe for XML, in text and in quoted attributes.
function M.escape(text)
  return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

return M
