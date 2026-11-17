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

--- Load one extension from a directory or a `.lua` file. One the program
--- was built with is not loaded again from elsewhere: the configuration
--- that names the source tree's copy gets the packaged one.
function M.load(path)
  local name = path:match("([^/]+)$"):gsub("%.lua$", "")
  local known = M.loaded[name]
  if known and known.packaged then return known end
  local entry = { name = name, path = path, ok = true }
  M.loaded[name] = entry
  local init = path
  if not path:match("%.lua$") then
    package.path = path .. "/lua/?.lua;" .. path .. "/lua/?/init.lua;" .. package.path
    for _, item in ipairs(api.read_dir(path)) do
      if item.is_dir and item.name == "devices" and daw.luadev then daw.luadev.add_dir(path .. "/devices") end
    end
    init = path .. "/init.lua"
    if not exists(init) then
      daw.snippet.load_dir(path .. "/snippets", "extension")
      return entry
    end
  end
  local chunk, err = loadfile(init)
  if chunk then
    -- Kept out of the compiler, so that the time limit can stop its loops.
    daw.limit.untrusted(chunk)
    M.current = entry
    entry.ok, err = xpcall(chunk, debug.traceback)
    M.current = nil
  else
    entry.ok = false
  end
  -- Its snippets, one file per set; the user's own of the same name win.
  if entry.ok and not path:match("%.lua$") then daw.snippet.load_dir(path .. "/snippets", "extension") end
  if not entry.ok then
    entry.error = err
    daw.notify("extension " .. name .. " failed: " .. tostring(err), "error")
  end
  return entry
end

--- Load the extensions the program was built with: `dirs` is a list of
--- their directories separated by `:` (`$DAW_EXTENSIONS`, which the flake's
--- `paw.withExtensions` sets).
function M.load_packaged(dirs)
  for dir in (dirs or ""):gmatch("[^:]+") do
    local entry = M.load(dir)
    entry.packaged = true
  end
end

--- Load everything in a directory of extensions.
function M.load_dir(dir)
  for _, item in ipairs(api.read_dir(dir)) do
    if item.is_dir or item.name:match("%.lua$") then M.load(dir .. "/" .. item.name) end
  end
end

--- The directory of the extensions that come with the program:
--- `$DAW_HOME/extensions`, or `extensions` under the working directory in a
--- source tree. Nil when neither is there.
function M.bundled_dir()
  for _, root in ipairs({ os.getenv("DAW_HOME") or ".", "." }) do
    if #api.read_dir(root .. "/extensions") > 0 then return root .. "/extensions" end
  end
end

--- The names of the bundled extensions, loaded or not, sorted.
function M.bundled()
  local dir, out = M.bundled_dir(), {}
  for _, item in ipairs(dir and api.read_dir(dir) or {}) do
    if item.is_dir then out[#out + 1] = item.name end
  end
  table.sort(out)
  return out
end

--- Load a bundled extension by name; a name already loaded is left alone.
--- Returns the entry, or nil and what is wrong.
function M.load_bundled(name)
  if M.loaded[name] then return M.loaded[name] end
  for _, known in ipairs(M.bundled()) do
    if known == name then return M.load(M.bundled_dir() .. "/" .. name) end
  end
  return nil, "no bundled extension `" .. tostring(name) .. "`" .. (M.bundled_dir() and "" or ": set DAW_HOME to the source tree")
end

--- Loaded extensions, sorted by name.
function M.list()
  local out = {}
  for _, entry in pairs(M.loaded) do out[#out + 1] = entry end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

return M
