-- Extensions: directories (or single Lua files) in `<config>/extensions`.
--
--   extensions/euclid/init.lua      run at startup
--   extensions/euclid/lua/...       on the `require` path
--   extensions/scratch.lua          a one-file extension, run at startup
--
--   extensions/euclid/devices/*.lua devices written in Lua (see daw.luadev)
--
-- An extension is ordinary Lua using the same `daw` module as the user's
-- `init.lua`; there is no separate plugin interface.
local api = daw.api
local M = { loaded = {} }

local function exists(path)
  local file = io.open(path, "r")
  if file then file:close() end
  return file ~= nil
end

--- Load one extension from a directory or a `.lua` file.
function M.load(path)
  local name = path:match("([^/]+)$"):gsub("%.lua$", "")
  local entry = { name = name, path = path, ok = true }
  M.loaded[name] = entry
  local init = path
  if not path:match("%.lua$") then
    package.path = path .. "/lua/?.lua;" .. path .. "/lua/?/init.lua;" .. package.path
    for _, item in ipairs(api.read_dir(path)) do
      if item.is_dir and item.name == "devices" and daw.luadev then daw.luadev.add_dir(path .. "/devices") end
    end
    init = path .. "/init.lua"
    if not exists(init) then return entry end
  end
  local chunk, err = loadfile(init)
  if chunk then
    -- Kept out of the compiler, so that the time limit can stop its loops.
    daw.limit.untrusted(chunk)
    entry.ok, err = xpcall(chunk, debug.traceback)
  else
    entry.ok = false
  end
  if not entry.ok then
    entry.error = err
    daw.notify("extension " .. name .. " failed: " .. tostring(err), "error")
  end
  return entry
end

--- Load everything in a directory of extensions.
function M.load_dir(dir)
  for _, item in ipairs(api.read_dir(dir)) do
    if item.is_dir or item.name:match("%.lua$") then M.load(dir .. "/" .. item.name) end
  end
end

--- Loaded extensions, sorted by name.
function M.list()
  local out = {}
  for _, entry in pairs(M.loaded) do out[#out + 1] = entry end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

return M
