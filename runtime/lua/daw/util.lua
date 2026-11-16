-- Small helpers with no dependencies on the rest of the runtime.
local M = {}

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then return a < b end
    return tostring(a) < tostring(b)
  end)
  return keys
end

--- Render any value as readable Lua-like text.
function M.inspect(value, indent, seen)
  indent, seen = indent or "", seen or {}
  if type(value) == "string" then return string.format("%q", value) end
  if type(value) ~= "table" then return tostring(value) end
  if seen[value] then return "<cycle>" end
  seen[value] = true
  if next(value) == nil then return "{}" end
  local parts, inner = {}, indent .. "  "
  local n = #value
  for i = 1, n do parts[#parts + 1] = inner .. M.inspect(value[i], inner, seen) end
  for _, k in ipairs(sorted_keys(value)) do
    if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then
      local key = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or "[" .. M.inspect(k) .. "]"
      parts[#parts + 1] = inner .. key .. " = " .. M.inspect(value[k], inner, seen)
    end
  end
  seen[value] = nil
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

function M.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function M.round(v, step)
  step = step or 1
  return math.floor(v / step + 0.5) * step
end

--- Shallow copy with the fields of `extra` laid over it.
function M.merge(base, extra)
  local out = {}
  for k, v in pairs(base or {}) do out[k] = v end
  for k, v in pairs(extra or {}) do out[k] = v end
  return out
end

--- Cut or pad text to exactly `width` columns.
function M.fit(text, width)
  text = tostring(text)
  local have = daw.api.str_width(text)
  if have <= width then return text .. string.rep(" ", width - have) end
  local out, used = {}, 0
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    local w = daw.api.str_width(ch)
    if used + w > width - 1 then break end
    out[#out + 1], used = ch, used + w
  end
  return table.concat(out) .. (daw.draw and daw.draw.g.ellipsis or "…") .. string.rep(" ", width - used - 1)
end

return M
