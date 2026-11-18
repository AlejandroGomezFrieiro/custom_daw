-- Extensions: directories (or single Lua files) in `<config>/extensions`.
--
--   extensions/euclid/init.lua      run at startup
--   extensions/euclid/manifest.lua  what it is and what it needs (optional)
--   extensions/euclid/lua/...       on the `require` path
--   extensions/scratch.lua          a one-file extension, run at startup
--
--   extensions/euclid/devices/*.lua devices written in Lua (see paw.luadev)
--
-- An extension is ordinary Lua using the same `paw` module as the user's
-- `init.lua`; there is no separate plugin interface. What it registers while
-- it loads (commands, keys, views, buffer types, hooks, ...) is recorded as
-- its own: `:extensions` lists it, and `paw.ext.unload(name)` takes it away.
--
-- A manifest is a Lua file that returns a table:
--
--   return {
--     name = "euclid", version = "1.2.0",
--     description = "Euclidean rhythms as clips",
--     requires = { paw = ">=1.0", sections = "^1" },  -- the API, and other extensions
--     provides = { "rhythms" },                      -- names others may require it by
--   }
local api = paw.api
local M = { loaded = {} }

local function exists(path)
  local file = io.open(path, "r")
  if file then file:close() end
  return file ~= nil
end

-- Versions --------------------------------------------------------------------------

--- A version's numbers: "1.2.3" gives { 1, 2, 3 }; missing parts are 0.
--- Nil for text that is no version.
function M.parse_version(text)
  local a, b, c = tostring(text or ""):match("^%s*v?(%d+)%.?(%d*)%.?(%d*)")
  if not a then return nil end
  return { tonumber(a), tonumber(b) or 0, tonumber(c) or 0 }
end

local function compare(a, b)
  for i = 1, 3 do
    if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
  end
  return 0
end

--- Whether `version` meets `want`: comparisons separated by spaces or
--- commas, each `>=1.2`, `>1`, `<=2`, `<2.0`, `=1.2.3`, `^1.2` (the same
--- first number, at least 1.2), `~1.2` (the same first two) or a bare
--- version, which means `^`. `*` or nothing is any version.
function M.satisfies(version, want)
  local v = M.parse_version(version)
  if not v then return false end
  for part in tostring(want or "*"):gmatch("[^%s,]+") do
    if part ~= "*" then
      local op, rest = part:match("^([<>=~^]*)(.*)$")
      local w = M.parse_version(rest)
      if not w then return false end
      local c = compare(v, w)
      local ok
      if op == ">=" then ok = c >= 0
      elseif op == ">" then ok = c > 0
      elseif op == "<=" then ok = c <= 0
      elseif op == "<" then ok = c < 0
      elseif op == "=" then ok = c == 0
      elseif op == "~" then ok = c >= 0 and v[1] == w[1] and v[2] == w[2]
      else ok = c >= 0 and v[1] == w[1] end
      if not ok then return false end
    end
  end
  return true
end

-- What extensions own --------------------------------------------------------------
--
-- Each registry an extension can add to is read before and after it loads;
-- what differs is the extension's, kept with what was there before, so that
-- unloading it puts that back. `put(key, value)` sets an entry, nil removes
-- it; `label` says what the entry is in a few words.

local function keyed(kind, title, get, put, label)
  return { kind = kind, title = title, snapshot = function()
    local out = {}
    for k, v in pairs(get() or {}) do out[k] = v end
    return out
  end, put = put or function(key, value) get()[key] = value end, label = label }
end

local function two_level(get)
  return function()
    local out = {}
    for a, inner in pairs(get() or {}) do
      for b, v in pairs(inner) do out[a .. " " .. b] = v end
    end
    return out
  end
end

local function split(key) return key:match("^(%S+) (.*)$") end

M.registries = {
  { kind = "commands", title = "commands", snapshot = function()
      local out = {}
      for _, spec in ipairs(paw.commands.list()) do out[spec.name] = spec end
      return out
    end, put = function(key, value) paw.commands.put(key, value) end,
    label = function(key) return ":" .. key end },
  { kind = "keys", title = "keys", snapshot = function()
      local out = {}
      paw.keymap.each(function(map, mode, scope, keys) out[mode .. " " .. scope .. " " .. keys] = map end)
      return out
    end, put = function(key, value)
      local mode, scope, keys = key:match("^(%S+) (%S+) (.*)$")
      paw.keymap.put(mode, scope, keys, value)
    end,
    label = function(_, map)
      return map.lhs .. " (" .. map.mode .. (map.scope ~= "global" and ", " .. map.scope or "") .. ")"
    end },
  { kind = "key_groups", title = "key groups", snapshot = two_level(function() return paw.keymap.groups() end),
    put = function(key, value)
      local scope, keys = split(key)
      local groups = paw.keymap.groups()
      groups[scope] = groups[scope] or {}
      groups[scope][keys] = value
    end },
  { kind = "views", title = "views", snapshot = function()
      local out = {}
      -- A buffer type's view is the buffer type's, listed as that.
      for name, view in pairs(paw.ui.views) do
        if not view.buftype then out[name] = view end
      end
      return out
    end, put = function(key, value)
      paw.ui.views[key] = value
      api.ui_redraw()
    end },
  keyed("buftypes", "buffer types", function() return paw.layout.types end, function(key, value)
    paw.layout.types[key] = value
    if value then
      paw.layout.buftype(key, value)
    else
      paw.ui.views[key] = nil
    end
  end),
  keyed("textbuf_kinds", "text buffer kinds", function() return paw.textbuf and paw.textbuf.kinds end),
  keyed("track_kinds", "kinds of track", function() return paw.track_kinds.kinds end, function(key, value)
    if value then paw.track_kinds.define(key, value) else paw.track_kinds.remove(key) end
  end),
  keyed("pickers", "picker sources", function() return paw.pick.sources end),
  { kind = "query_fields", title = "query fields", snapshot = two_level(function() return paw.query and paw.query.fields end),
    put = function(key, value)
      local kind, name = split(key)
      paw.query.fields[kind] = paw.query.fields[kind] or {}
      paw.query.fields[kind][name] = value
    end },
  keyed("ex_fields", "fields of :s and :g", function() return paw.ex and paw.ex.fields end),
  keyed("ex_views", "views of ranges", function() return paw.ex and paw.ex.views end),
  keyed("completers", "completers", function() return paw.commands.completers end),
  keyed("statusline", "status line components", function() return paw.statusline and paw.statusline.components end,
    function(key, value)
      paw.statusline.components[key] = value
      api.ui_redraw()
    end),
  keyed("grep", "grep sources", function() return paw.grep and paw.grep.sources end, function(key, value)
    local g = paw.grep
    if value and not g.sources[key] then g.order[#g.order + 1] = key end
    g.sources[key] = value
    if not value then
      for i = #g.order, 1, -1 do
        if g.order[i] == key then table.remove(g.order, i) end
      end
    end
  end),
  keyed("curves", "curve providers", function() return paw.curves and paw.curves.providers end),
  keyed("addresses", "address schemes", function() return paw.address and paw.address.schemes end),
  keyed("complete", "completion sources", function() return paw.complete and paw.complete.sources end),
  { kind = "layers", title = "layers", snapshot = function()
      local out = {}
      for view, parts in pairs(paw.ui.layers) do
        for part, list in pairs(parts) do
          for _, layer in ipairs(list) do out[view .. " " .. part .. " " .. layer.name] = layer end
        end
      end
      return out
    end, put = function(key, value)
      local view, part, name = key:match("^(%S+) (%S+) (.*)$")
      paw.ui.layer(view, part, name, value and value.order, value and value.paint)
    end },
  keyed("health", "health checks", function() return paw.health and paw.health.checks end),
  { kind = "hooks", title = "hooks", snapshot = function()
      local out = {}
      for id, h in pairs(require("paw.events").handlers()) do out[id] = h end
      return out
    end, put = function(key, value)
      if not value then paw.off(key) end
    end,
    label = function(_, h) return h.pattern end },
  -- Options keep their default once defined: a value set for one stays
  -- meaningful after its extension is gone, as in Neovim.
  { kind = "options", title = "options", snapshot = function()
      local out = {}
      for _, o in ipairs(paw.option.list()) do out[o.name] = o.default end
      return out
    end, put = function() end, keeps = true },
}

local function snapshot()
  local out = {}
  for _, reg in ipairs(M.registries) do
    local ok, got = pcall(reg.snapshot)
    out[reg.kind] = ok and got or {}
  end
  return out
end

-- Which extension each entry is, by kind and key: an extension that loads
-- another while it loads does not take the other's entries for its own.
local claimed = {}

--- Record what `entry` added since `before` was taken.
local function claim(entry, before)
  local after = snapshot()
  entry.owned = entry.owned or {}
  for _, reg in ipairs(M.registries) do
    local was, now = before[reg.kind] or {}, after[reg.kind] or {}
    local list = entry.owned[reg.kind] or {}
    local function own(key, old)
      local id = reg.kind .. "\0" .. tostring(key)
      local holder = claimed[id]
      if holder and holder.value == now[key] and holder.name ~= entry.name then return end
      claimed[id] = { name = entry.name, value = now[key] }
      list[#list + 1] = { key = key, value = now[key], old = old }
    end
    for key, value in pairs(now) do
      if was[key] ~= value then own(key, was[key]) end
    end
    for key, value in pairs(was) do
      if now[key] == nil then own(key, value) end
    end
    if #list > 0 then
      table.sort(list, function(a, b) return tostring(a.key) < tostring(b.key) end)
      entry.owned[reg.kind] = list
    end
  end
end

--- What a loaded extension registered: a list of `{ kind, title, items }`,
--- each item a short label, in the order of `paw.ext.registries`.
function M.provides(name)
  local entry = M.loaded[name]
  local out = {}
  for _, reg in ipairs(M.registries) do
    local list = entry and entry.owned and entry.owned[reg.kind]
    if list then
      local items = {}
      for _, item in ipairs(list) do
        if item.value ~= nil then
          items[#items + 1] = reg.label and reg.label(item.key, item.value) or tostring(item.key)
        end
      end
      if #items > 0 then out[#out + 1] = { kind = reg.kind, title = reg.title, items = items } end
    end
  end
  return out
end

-- Manifests ------------------------------------------------------------------------

--- An extension's manifest: `manifest.lua` in its directory. A one-file
--- extension has none. Returns the table (with `name` filled in), or nil
--- and what is wrong with it.
function M.manifest(path, name)
  if path:match("%.lua$") then return { name = name } end
  local file = path .. "/manifest.lua"
  if not exists(file) then return { name = name } end
  local chunk, err = loadfile(file)
  if not chunk then return nil, err end
  local ok, got = pcall(chunk)
  if not ok then return nil, got end
  if type(got) ~= "table" then return nil, "manifest.lua returns no table" end
  if got.name and got.name ~= name then return nil, "manifest.lua names it " .. tostring(got.name) end
  got.name = name
  return got
end

--- The loaded extension that is `name`, or that provides it.
local function holder(name)
  if M.loaded[name] then return M.loaded[name] end
  for _, entry in pairs(M.loaded) do
    for _, other in ipairs(entry.manifest and entry.manifest.provides or {}) do
      if other == name then return entry end
    end
  end
end

--- Load what an extension requires and check the versions. Returns nil,
--- or what is wrong.
local function require_all(entry)
  local requires = entry.manifest.requires or {}
  local names = {}
  for name in pairs(requires) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local want = requires[name]
    if name == "paw" then
      if not M.satisfies(api.version, want) then
        return "needs the paw API " .. want .. ", and this is " .. api.version
      end
    else
      local other = holder(name)
      if not other then
        -- Beside it first, then among those that come with the program.
        local sibling = entry.path:match("^(.*)/[^/]+$")
        if sibling and exists(sibling .. "/" .. name .. "/init.lua") then
          other = M.load(sibling .. "/" .. name)
        else
          other = M.load_bundled(name)
        end
        other = other or holder(name)
      end
      if not other then return "needs the extension " .. name .. ", which is not to be found" end
      if not other.ok then return "needs the extension " .. name .. ", which failed to load" end
      local version = other.manifest and other.manifest.version
      if want ~= "*" and want ~= true and not (version and M.satisfies(version, want)) then
        return "needs " .. name .. " " .. tostring(want) .. ", and " .. (version and "this is " .. version or "it says no version")
      end
    end
  end
end

-- Loading and unloading ------------------------------------------------------------

--- Load one extension from a directory or a `.lua` file. One the program
--- was built with is not loaded again from elsewhere: the configuration
--- that names the source tree's copy gets the packaged one.
function M.load(path)
  local name = path:match("([^/]+)$"):gsub("%.lua$", "")
  local known = M.loaded[name]
  if known and known.packaged then return known end
  local entry = { name = name, path = path, ok = true }
  M.loaded[name] = entry
  local manifest, merr = M.manifest(path, name)
  entry.manifest = manifest or { name = name }
  entry.version = entry.manifest.version
  local err = merr or require_all(entry)
  if err then
    entry.ok, entry.error = false, err
    paw.notify("extension " .. name .. " failed: " .. tostring(err), "error")
    return entry
  end
  local before = snapshot()
  local outer = M.current
  M.current = entry
  local init = path
  if not path:match("%.lua$") then
    entry.lua_path = path .. "/lua/?.lua;" .. path .. "/lua/?/init.lua;"
    package.path = entry.lua_path .. package.path
    for _, item in ipairs(api.read_dir(path)) do
      if item.is_dir and item.name == "devices" and paw.luadev then
        paw.luadev.add_dir(path .. "/devices")
        entry.devices = path .. "/devices"
      end
    end
    init = path .. "/init.lua"
    if not exists(init) then
      paw.snippet.load_dir(path .. "/snippets", "extension")
      claim(entry, before)
      M.current = outer
      paw.emit("ext.loaded", { name = name, ok = true })
      return entry
    end
  end
  local chunk
  chunk, err = loadfile(init)
  if chunk then
    -- Kept out of the compiler, so that the time limit can stop its loops.
    paw.limit.untrusted(chunk)
    entry.ok, err = xpcall(chunk, debug.traceback)
  else
    entry.ok = false
  end
  -- Its snippets, one file per set; the user's own of the same name win.
  if entry.ok and not path:match("%.lua$") then paw.snippet.load_dir(path .. "/snippets", "extension") end
  claim(entry, before)
  M.current = outer
  if not entry.ok then
    entry.error = err
    paw.notify("extension " .. name .. " failed: " .. tostring(err), "error")
  end
  paw.emit("ext.loaded", { name = name, ok = entry.ok })
  return entry
end

--- Take an extension away: everything it registered while it loaded is
--- removed, and what it replaced put back (a command or key of the core it
--- remapped). Its modules are forgotten, so loading it again runs them
--- afresh. Options it defined keep their defaults; devices it ships stay
--- among the devices for the session. Returns true, or nil and why not.
function M.unload(name)
  local entry = M.loaded[name]
  if not entry then return nil, "no extension `" .. tostring(name) .. "` is loaded" end
  for _, other in pairs(M.loaded) do
    local requires = other ~= entry and other.ok and other.manifest and other.manifest.requires
    if requires and requires[name] ~= nil then
      return nil, other.name .. " requires " .. name .. ": unload it first"
    end
  end
  paw.emit("ext.unloading", { name = name })
  for i = #M.registries, 1, -1 do
    local reg = M.registries[i]
    local list = entry.owned and entry.owned[reg.kind] or {}
    local now = reg.snapshot()
    for j = #list, 1, -1 do
      local item = list[j]
      -- Something registered over it since is left alone.
      if now[item.key] == item.value then pcall(reg.put, item.key, item.old) end
      claimed[reg.kind .. "\0" .. tostring(item.key)] = nil
    end
  end
  if entry.lua_path then
    local prefix = entry.path .. "/lua/"
    for module, _ in pairs(package.loaded) do
      local file = package.searchpath and package.searchpath(module, entry.lua_path)
      if file and file:sub(1, #prefix) == prefix then package.loaded[module] = nil end
    end
    local from, to = package.path:find(entry.lua_path, 1, true)
    if from then package.path = package.path:sub(1, from - 1) .. package.path:sub(to + 1) end
  end
  M.loaded[name] = nil
  api.ui_redraw()
  paw.emit("ext.unloaded", { name = name })
  return true
end

--- Load the extensions the program was built with: `dirs` is a list of
--- their directories separated by `:` (`$PAW_EXTENSIONS`, which the flake's
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
    local path = dir .. "/" .. item.name
    -- One loaded already, as another's requirement, is not loaded twice.
    local known = M.loaded[(item.name:gsub("%.lua$", ""))]
    if (item.is_dir or item.name:match("%.lua$")) and not (known and known.path == path) then M.load(path) end
  end
end

--- The directory of the extensions that come with the program:
--- `$PAW_HOME/extensions`, or `extensions` under the working directory in a
--- source tree. Nil when neither is there.
function M.bundled_dir()
  for _, root in ipairs({ os.getenv("PAW_HOME") or ".", "." }) do
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
  return nil, "no bundled extension `" .. tostring(name) .. "`" .. (M.bundled_dir() and "" or ": set PAW_HOME to the source tree")
end

--- Loaded extensions, sorted by name.
function M.list()
  local out = {}
  for _, entry in pairs(M.loaded) do out[#out + 1] = entry end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

return M
