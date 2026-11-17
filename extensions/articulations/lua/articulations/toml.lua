-- A small TOML reader, and the quoting a writer needs: enough for the
-- articulation maps and for most TOML people write by hand. It reads
-- comments, tables (`[a.b]`), arrays of tables (`[[a]]`), dotted and quoted
-- keys, basic and literal strings (also over several lines), integers
-- (decimal, `0x`, `0o`, `0b`, with `_`), floats (`inf`, `nan`), booleans,
-- arrays and inline tables. Dates and times are not read: a map has none.
--
--   local t, err = toml.parse(text)     -- a table, or nil and "line 4: why"
--   toml.quote("pizz.")                 -- "\"pizz.\""
--   toml.key("col-legno")               -- a bare key when it can be one
local M = {}

local function utf8(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  end
  return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64, 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local ESCAPES = { b = "\b", t = "\t", n = "\n", f = "\f", r = "\r", ['"'] = '"', ["\\"] = "\\" }

-- The keys of each table read, in the order the text has them.
local orders = setmetatable({}, { __mode = "k" })

--- The keys of a table `parse` made, in the order they were written (a
--- map's articulations are numbered in that order).
function M.keys(t)
  local out = {}
  for i, k in ipairs(orders[t] or {}) do out[i] = k end
  if #out == 0 then
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
  end
  return out
end

--- Parse TOML text into a table. Returns the table, or nil and what is
--- wrong with the line it is on.
function M.parse(text)
  local s = tostring(text or ""):gsub("^\239\187\191", "")
  local pos, n = 1, #s
  local root = {}
  local current = root
  -- Tables that were defined by a header or an inline table, which may not be defined again.
  local defined, inline, arrays = { [root] = true }, {}, {}

  local function put(t, k, v)
    t[k] = v
    local order = orders[t]
    if not order then
      order = {}
      orders[t] = order
    end
    order[#order + 1] = k
  end

  local function line_at(p)
    local _, count = s:sub(1, p - 1):gsub("\n", "")
    return count + 1
  end
  local function fail(why, at) error({ toml = "line " .. line_at(at or pos) .. ": " .. why }, 0) end

  local function skip_ws() pos = s:match("^[ \t]*()", pos) end
  local function skip_comment()
    if s:sub(pos, pos) == "#" then pos = (s:find("\n", pos, true) or n + 1) end
  end
  -- Blank lines, comments and new lines, as inside an array.
  local function skip_all()
    while pos <= n do
      skip_ws()
      local c = s:sub(pos, pos)
      if c == "#" then
        skip_comment()
      elseif c == "\n" or c == "\r" then
        pos = pos + 1
      else
        return
      end
    end
  end
  local function end_of_line()
    skip_ws()
    skip_comment()
    local c = s:sub(pos, pos)
    if c == "\r" then pos = pos + 1; c = s:sub(pos, pos) end
    if c == "\n" then pos = pos + 1 elseif pos <= n then fail("expected the end of the line, found `" .. c .. "`") end
  end

  local function escape(multi)
    local c = s:sub(pos + 1, pos + 1)
    if ESCAPES[c] then
      pos = pos + 2
      return ESCAPES[c]
    elseif c == "u" or c == "U" then
      local len = c == "u" and 4 or 8
      local hex = s:sub(pos + 2, pos + 1 + len)
      if not hex:match("^%x+$") or #hex ~= len then fail("a bad \\" .. c .. " escape") end
      pos = pos + 2 + len
      return utf8(tonumber(hex, 16))
    elseif multi and c:match("[ \t\r\n]") then
      -- A backslash at the end of a line joins it to the next, without the blanks.
      pos = s:match("^[ \t\r\n]*()", pos + 1)
      return ""
    end
    fail("an unknown escape \\" .. c)
  end

  local function basic_string()
    if s:sub(pos, pos + 2) == '"""' then
      pos = pos + 3
      if s:sub(pos, pos) == "\n" then pos = pos + 1 elseif s:sub(pos, pos + 1) == "\r\n" then pos = pos + 2 end
      local out = {}
      while true do
        if pos > n then fail("a string that does not end") end
        if s:sub(pos, pos + 2) == '"""' then
          -- Up to two quotes may end the text right before the closing three.
          local quotes = #s:match('^"*', pos)
          out[#out + 1] = string.rep('"', math.min(quotes - 3, 2))
          pos = pos + math.min(quotes, 5)
          return table.concat(out)
        end
        local c = s:sub(pos, pos)
        if c == "\\" then out[#out + 1] = escape(true) else out[#out + 1] = c; pos = pos + 1 end
      end
    end
    pos = pos + 1
    local out = {}
    while true do
      local c = s:sub(pos, pos)
      if c == "" or c == "\n" then fail("a string that does not end on its line") end
      if c == '"' then
        pos = pos + 1
        return table.concat(out)
      end
      if c == "\\" then out[#out + 1] = escape(false) else out[#out + 1] = c; pos = pos + 1 end
    end
  end

  local function literal_string()
    if s:sub(pos, pos + 2) == "'''" then
      pos = pos + 3
      if s:sub(pos, pos) == "\n" then pos = pos + 1 elseif s:sub(pos, pos + 1) == "\r\n" then pos = pos + 2 end
      local finish = s:find("'''", pos, true)
      if not finish then fail("a string that does not end") end
      local quotes = #s:match("^'*", finish)
      local text = s:sub(pos, finish - 1) .. string.rep("'", math.min(quotes - 3, 2))
      pos = finish + math.min(quotes, 5)
      return text
    end
    local finish = s:find("[\n']", pos + 1)
    if not finish or s:sub(finish, finish) ~= "'" then fail("a string that does not end on its line") end
    local text = s:sub(pos + 1, finish - 1)
    pos = finish + 1
    return text
  end

  local function key_part()
    local c = s:sub(pos, pos)
    if c == '"' then return basic_string() end
    if c == "'" then return literal_string() end
    local bare = s:match("^[%w_%-]+", pos)
    if not bare then fail("expected a key, found `" .. c .. "`") end
    pos = pos + #bare
    return bare
  end

  local function dotted_key()
    local parts = {}
    while true do
      skip_ws()
      parts[#parts + 1] = key_part()
      skip_ws()
      if s:sub(pos, pos) ~= "." then return parts end
      pos = pos + 1
    end
  end

  local value

  local function number()
    local word = s:match("^[%w_%+%-%.]+", pos)
    if not word then fail("expected a value") end
    local at = pos
    pos = pos + #word
    if word == "true" then return true end
    if word == "false" then return false end
    local clean = word:gsub("_", "")
    if clean:match("^[%+%-]?inf$") then return clean:sub(1, 1) == "-" and -math.huge or math.huge end
    if clean:match("^[%+%-]?nan$") then return 0 / 0 end
    local base = { x = 16, o = 8, b = 2 }
    local prefix, digits = clean:match("^0([xob])(%w+)$")
    if prefix then
      local v = tonumber(digits, base[prefix])
      if v then return v end
    elseif clean:match("^[%+%-]?%d+$") or clean:match("^[%+%-]?%d+%.?%d*[eE]?[%+%-]?%d*$") then
      local v = tonumber(clean)
      if v then return v end
    end
    fail("`" .. word .. "` is not a value (a date? dates are not read)", at)
  end

  local function array()
    pos = pos + 1
    local out = {}
    while true do
      skip_all()
      if s:sub(pos, pos) == "]" then
        pos = pos + 1
        return out
      end
      out[#out + 1] = value()
      skip_all()
      local c = s:sub(pos, pos)
      if c == "," then
        pos = pos + 1
      elseif c == "]" then
        pos = pos + 1
        return out
      else
        fail("expected `,` or `]` in an array")
      end
    end
  end

  local assign

  local function inline_table()
    pos = pos + 1
    local out = {}
    skip_ws()
    if s:sub(pos, pos) == "}" then
      pos = pos + 1
      inline[out] = true
      return out
    end
    while true do
      assign(out)
      skip_ws()
      local c = s:sub(pos, pos)
      if c == "," then
        pos = pos + 1
      elseif c == "}" then
        pos = pos + 1
        inline[out] = true
        return out
      else
        fail("expected `,` or `}` in an inline table")
      end
    end
  end

  value = function()
    skip_ws()
    local c = s:sub(pos, pos)
    if c == '"' then return basic_string() end
    if c == "'" then return literal_string() end
    if c == "[" then return array() end
    if c == "{" then return inline_table() end
    return number()
  end

  -- `a.b.c = v` into `into`: the tables on the way are made as needed.
  assign = function(into)
    local at = pos
    local parts = dotted_key()
    if s:sub(pos, pos) ~= "=" then fail("expected `=` after the key `" .. table.concat(parts, ".") .. "`") end
    pos = pos + 1
    local v = value()
    local t = into
    for i = 1, #parts - 1 do
      local next_t = t[parts[i]]
      if next_t == nil then
        next_t = {}
        put(t, parts[i], next_t)
      elseif type(next_t) ~= "table" or inline[next_t] then
        fail("`" .. parts[i] .. "` is already a value", at)
      end
      t = next_t
    end
    local last = parts[#parts]
    if t[last] ~= nil then fail("`" .. table.concat(parts, ".") .. "` is defined twice", at) end
    put(t, last, v)
  end

  local function header()
    local many = s:sub(pos, pos + 1) == "[["
    local at = pos
    pos = pos + (many and 2 or 1)
    local parts = dotted_key()
    if s:sub(pos, pos + (many and 1 or 0)) ~= (many and "]]" or "]") then fail("a table's name does not end with `]`") end
    pos = pos + (many and 2 or 1)
    local t = root
    for i = 1, #parts - 1 do
      local next_t = t[parts[i]]
      if next_t == nil then
        next_t = {}
        put(t, parts[i], next_t)
      elseif type(next_t) ~= "table" or inline[next_t] then
        fail("`" .. parts[i] .. "` is already a value", at)
      end
      -- Within an array of tables, the last one made.
      if arrays[next_t] then next_t = next_t[#next_t] end
      t = next_t
    end
    local last = parts[#parts]
    if many then
      local list = t[last]
      if list == nil then
        list = {}
        put(t, last, list)
        arrays[list] = true
      elseif not arrays[list] then
        fail("`" .. table.concat(parts, ".") .. "` is not an array of tables", at)
      end
      local item = {}
      list[#list + 1] = item
      defined[item] = true
      current = item
    else
      local existing = t[last]
      if existing == nil then
        existing = {}
        put(t, last, existing)
      elseif type(existing) ~= "table" or inline[existing] or defined[existing] then
        fail("the table `" .. table.concat(parts, ".") .. "` is defined twice", at)
      end
      defined[existing] = true
      current = existing
    end
  end

  local ok, err = pcall(function()
    while true do
      skip_all()
      if pos > n then break end
      if s:sub(pos, pos) == "[" then header() else assign(current) end
      end_of_line()
    end
  end)
  if not ok then
    if type(err) == "table" and err.toml then return nil, err.toml end
    error(err, 0)
  end
  return root
end

--- A string as TOML writes it.
function M.quote(text)
  return '"' .. tostring(text):gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    if c == "\n" then return "\\n" end
    if c == "\t" then return "\\t" end
    return string.format("\\u%04X", c:byte())
  end) .. '"'
end

--- A key as TOML writes it: bare when it can be.
function M.key(text)
  text = tostring(text)
  if text:match("^[%w_%-]+$") then return text end
  return M.quote(text)
end

--- A value on one line: strings, numbers, booleans, lists and tables
--- (inline, keys in `order` first, then the rest sorted).
function M.inline(v, order)
  local kind = type(v)
  if kind == "string" then return M.quote(v) end
  if kind == "boolean" then return tostring(v) end
  if kind == "number" then
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
    return string.format("%.17g", v)
  end
  if kind ~= "table" then error("TOML cannot hold a " .. kind, 2) end
  if #v > 0 or next(v) == nil then
    local out = {}
    for i, x in ipairs(v) do out[i] = M.inline(x) end
    return "[" .. table.concat(out, ", ") .. "]"
  end
  local keys, seen = {}, {}
  for _, k in ipairs(order or {}) do
    if v[k] ~= nil then keys[#keys + 1], seen[k] = k, true end
  end
  local rest = {}
  for k in pairs(v) do
    if not seen[k] then rest[#rest + 1] = k end
  end
  table.sort(rest)
  for _, k in ipairs(rest) do keys[#keys + 1] = k end
  local out = {}
  for i, k in ipairs(keys) do out[i] = M.key(k) .. " = " .. M.inline(v[k]) end
  return "{ " .. table.concat(out, ", ") .. " }"
end

return M
