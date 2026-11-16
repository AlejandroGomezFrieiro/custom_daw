-- JSON-RPC messages as bytes, both ways: newline-delimited JSON (one message
-- a line, as MIDI LSP's engine speaks on `--stdio`) or LSP's
-- `Content-Length` headers.
local api = daw.api

local M = {}

local object_mt = {}

--- A table that is written as a JSON object even when it is empty
--- (`{}` alone is written as `[]`).
function M.object(t) return setmetatable(t or {}, object_mt) end

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function is_array(t)
  if getmetatable(t) == object_mt then return false end
  local n = #t
  if n == 0 then return next(t) == nil end
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then return false end
  end
  return true
end

local encode
local function value(v, out)
  local kind = type(v)
  if kind == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c) return escapes[c] or string.format("\\u%04x", c:byte()) end) .. '"'
  elseif kind == "number" then
    -- Whole numbers as integers: ticks, pitches and ids are integers to a
    -- server, and Lua has only one kind of number.
    if v ~= v or v == math.huge or v == -math.huge then
      out[#out + 1] = "null"
    elseif v % 1 == 0 and math.abs(v) < 2 ^ 53 then
      out[#out + 1] = string.format("%d", v)
    else
      out[#out + 1] = string.format("%.17g", v)
    end
  elseif kind == "boolean" then
    out[#out + 1] = tostring(v)
  elseif kind == "table" then
    encode(v, out)
  else
    out[#out + 1] = "null"
  end
end

encode = function(t, out)
  if is_array(t) then
    out[#out + 1] = "["
    for i, v in ipairs(t) do
      if i > 1 then out[#out + 1] = "," end
      value(v, out)
    end
    out[#out + 1] = "]"
  else
    out[#out + 1] = "{"
    local first = true
    for k, v in pairs(t) do
      if not first then out[#out + 1] = "," end
      first = false
      value(tostring(k), out)
      out[#out + 1] = ":"
      value(v, out)
    end
    out[#out + 1] = "}"
  end
end

--- A value as JSON text.
function M.encode(v)
  local out = {}
  value(v, out)
  return table.concat(out)
end

--- A message as the bytes to send in `framing` ("lines" or "headers").
function M.frame(message, framing)
  local text = M.encode(message)
  if framing == "headers" then return "Content-Length: " .. #text .. "\r\n\r\n" .. text end
  return text .. "\n"
end

--- Something that takes bytes as they arrive and gives back whole messages:
---   local reader = rpc.reader("lines")
---   for _, message in ipairs(reader:push(bytes)) do ... end
--- A part that is not JSON is given back as `{ invalid = text, error = why }`.
function M.reader(framing)
  local buffer = ""
  local self = {}
  local function decode(text, out)
    local message, err = api.json_decode(text)
    out[#out + 1] = type(message) == "table" and message or { invalid = text, error = err or "not an object" }
  end
  function self:push(bytes)
    buffer = buffer .. bytes
    local out = {}
    if framing == "headers" then
      while true do
        local head_end = buffer:find("\r\n\r\n", 1, true)
        if not head_end then break end
        local length = tonumber(buffer:sub(1, head_end):match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
        if not length then
          -- Not a header we understand: drop it and look for the next one.
          buffer = buffer:sub(head_end + 4)
        elseif #buffer < head_end + 3 + length then
          break
        else
          decode(buffer:sub(head_end + 4, head_end + 3 + length), out)
          buffer = buffer:sub(head_end + 4 + length)
        end
      end
    else
      while true do
        local nl = buffer:find("\n", 1, true)
        if not nl then break end
        local line = buffer:sub(1, nl - 1)
        buffer = buffer:sub(nl + 1)
        if line:match("%S") then decode(line, out) end
      end
    end
    return out
  end
  return self
end

return M
