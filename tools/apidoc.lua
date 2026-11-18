-- The Lua API's reference, made from the source: the `---` comment over
-- each public function of the `paw` modules, and the `//` comment over
-- each `paw.api` function in crates/paw-core/src/api.rs. Run from the
-- source tree:
--
--   paw --clean --no-plugins -l tools/apidoc.lua          write both files
--   paw --clean --no-plugins -l tools/apidoc.lua check    say what is out of date or undocumented
--
-- It writes runtime/types/paw.lua, a LuaLS meta file (point `workspace.library`
-- at runtime/types, and editors complete `paw.*` in a configuration or an
-- extension), and docs/reference/api.md, the reference `:help` shows (`:help
-- paw.commands.define`). tests/apidoc.lua checks both are up to date and
-- that every public function says what it does.
local api = paw.api
local M = {}

M.META = "runtime/types/paw.lua"
M.PAGE = "docs/reference/api.md"

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function lines_of(path)
  local text = read(path)
  if not text then return nil end
  local out = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = line end
  return out
end

-- Modules ---------------------------------------------------------------------------

--- The modules of the runtime as they are reached from `paw`: each a table
--- that `require("paw...")` gives, by its shortest name, and the classes
--- (`paw.Track`). A list of `{ name, table, module }`, sorted by name.
function M.modules()
  -- The runtime's own: an extension may put a module of its under `paw.`
  -- (`package.loaded["paw.sampler"]`), which is its to document.
  local function ours(name)
    local file = "runtime/lua/" .. name:gsub("%.", "/")
    return read(file .. ".lua") or read(file .. "/init.lua")
  end
  local loaded = {}
  for name, value in pairs(package.loaded) do
    if type(value) == "table" and (name == "paw" or name:match("^paw%.")) and name ~= "paw.api" and ours(name) then loaded[value] = name end
  end
  local found, out = {}, {}
  local queue = { { "paw", paw, 0 } }
  local i = 1
  while queue[i] do
    local name, t, depth = queue[i][1], queue[i][2], queue[i][3]
    i = i + 1
    local class = depth == 1 and name:match("^paw%.%u")
    if not found[t] and (loaded[t] or class) then
      found[t] = true
      out[#out + 1] = { name = name, table = t, module = loaded[t] }
      if depth < 3 then
        local keys = {}
        for k, v in pairs(t) do
          if type(k) == "string" and type(v) == "table" and not k:match("^_") and k ~= "api" then keys[#keys + 1] = k end
        end
        table.sort(keys)
        for _, k in ipairs(keys) do queue[#queue + 1] = { name .. "." .. k, t[k], depth + 1 } end
      end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- Functions and their comments -------------------------------------------------------

local sources = {}

--- The `---` comment over the line where a Lua function starts, and the
--- line itself: nil for a function the runtime did not write. A function
--- made by another (`M.join = small(function ... end)`) has its comment over
--- the line that names it `key`.
local function lua_doc(fn, key)
  local info = debug.getinfo(fn, "S")
  local path = info.source:match("^@.-(runtime/lua/.*)$")
  if not path then return nil end
  sources[path] = sources[path] or lines_of(path) or {}
  local lines = sources[path]
  local at = info.linedefined
  local first = lines[at] or ""
  if not (first:match("^%s*local%s+function") or first:match("^%s*function%s") or first:match("^%s*[%w_.:%[%]\"]+%s*=%s*function")) then
    for i, line in ipairs(lines) do
      if line:match("^%s*[%w_.]*%." .. key .. "%s*=") then at = i break end
    end
  end
  local doc = {}
  local n = at - 1
  while n > 0 and lines[n] and lines[n]:match("^%s*%-%-%-") do
    table.insert(doc, 1, (lines[n]:gsub("^%s*%-%-%- ?", "")))
    n = n - 1
  end
  return doc, path, at
end

local function params_of(fn)
  local out = {}
  local info = debug.getinfo(fn, "u")
  for i = 1, info.nparams or 0 do out[#out + 1] = debug.getlocal(fn, i) end
  if info.isvararg then out[#out + 1] = "..." end
  return out
end

--- The `paw.api` functions as api.rs has them: name -> `{ params, types, doc }`.
function M.kernel_functions()
  local out = {}
  local lines = lines_of("crates/paw-core/src/api.rs") or {}
  local comment = {}
  for _, line in ipairs(lines) do
    local name, args, types = line:match("^%s+fn ([%w_]+)%([%w_]+, [%w_]+, (.-) => (.-)%)%s*{")
    if name then
      local params = {}
      if args ~= "()" then
        for p in args:gsub("^%(", ""):gsub("%)$", ""):gmatch("[%w_]+") do params[#params + 1] = p end
      end
      local list = {}
      local inner = types:match("^%((.*)%)$") or types
      local depth, cur = 0, ""
      for ch in inner:gmatch(".") do
        if ch == "<" then depth = depth + 1 elseif ch == ">" then depth = depth - 1 end
        if ch == "," and depth == 0 then list[#list + 1] = cur cur = "" else cur = cur .. ch end
      end
      if cur:match("%S") then list[#list + 1] = cur end
      out[name] = { params = params, types = list, doc = comment }
      comment = {}
    elseif line:match("^%s+//") then
      comment[#comment + 1] = (line:gsub("^%s+// ?", ""))
    elseif not line:match("^%s*$") or #comment > 0 then
      comment = {}
    end
  end
  return out
end

local RUST_TYPES = {
  String = "string", f64 = "number", f32 = "number", i64 = "integer", u64 = "integer", u32 = "integer",
  i32 = "integer", usize = "integer", u8 = "integer", u16 = "integer", Id = "integer", bool = "boolean",
  LuaValue = "any", Table = "table", Function = "function", ["()"] = "nil",
}

local function lua_type(rust)
  rust = rust:gsub("^%s+", ""):gsub("%s+$", "")
  local inner = rust:match("^Option<(.*)>$")
  if inner then return lua_type(inner) .. "?" end
  local vec = rust:match("^Vec<(.*)>$")
  if vec then return lua_type(vec) .. "[]" end
  return RUST_TYPES[rust] or "any"
end

--- Every public function: `{ name, fn, params, doc, path, line, method,
--- alias_of }`, by module, in order. A function reached under two names is
--- written once, the other name an alias of it.
function M.functions()
  local seen, out = {}, {}
  local kernel = {}
  for name, fn in pairs(api) do
    if type(fn) == "function" then kernel[fn] = name end
  end
  for _, mod in ipairs(M.modules()) do
    local names = {}
    for k, v in pairs(mod.table) do
      if type(k) == "string" and type(v) == "function" and not k:match("^_") then names[#names + 1] = k end
    end
    table.sort(names)
    for _, k in ipairs(names) do
      local fn = mod.table[k]
      local full = mod.name .. "." .. k
      local entry = { name = full, module = mod.name, key = k, fn = fn }
      if seen[fn] then
        entry.alias_of = seen[fn]
      elseif kernel[fn] then
        entry.alias_of = "paw.api." .. kernel[fn]
      else
        seen[fn] = full
        local doc, path, line = lua_doc(fn, k)
        entry.doc, entry.path, entry.line = doc, path, line
        entry.params = params_of(fn)
        -- A method, written with `:`: its `self` is not named.
        if entry.params[1] == "self" and mod.name:match("^paw%.%u") then
          entry.method = true
          table.remove(entry.params, 1)
        end
      end
      out[#out + 1] = entry
    end
  end
  return out
end

--- The public functions with no `---` comment: their names and where they are.
function M.undocumented()
  local out = {}
  for _, f in ipairs(M.functions()) do
    if not f.alias_of and f.path and #f.doc == 0 then out[#out + 1] = f.name .. "  " .. f.path .. ":" .. f.line end
  end
  return out
end

-- Writing -----------------------------------------------------------------------------

local HEADER = "Generated by tools/apidoc.lua from the source's comments: do not edit."

local function call_name(f)
  return f.method and f.name:gsub("%.([%w_]+)$", ":%1") or f.name
end

--- The LuaLS meta file's text.
function M.meta()
  local out = { "---@meta", "-- " .. HEADER, "-- Point LuaLS at this directory (`workspace.library`) to complete `paw.*`.", "" }
  local function add(line) out[#out + 1] = line end
  for _, mod in ipairs(M.modules()) do
    add("---@class " .. mod.name)
    add(mod.name .. " = {}")
    add("")
  end
  add("---@class paw.api")
  add("paw.api = {}")
  add("---@type string")
  add("paw.api.version = " .. string.format("%q", api.version))
  add("")
  for _, f in ipairs(M.functions()) do
    if f.alias_of then
      add(f.name .. " = " .. f.alias_of)
    else
      for _, line in ipairs(f.doc or {}) do add("--- " .. line) end
      for _, p in ipairs(f.params) do
        if p ~= "..." and not (f.doc and table.concat(f.doc, "\n"):find("@param " .. p .. "%f[^%w_]")) then add("---@param " .. p .. " any") end
      end
      add("function " .. call_name(f) .. "(" .. table.concat(f.params, ", ") .. ") end")
    end
    add("")
  end
  local kernel = M.kernel_functions()
  local names = {}
  for name, fn in pairs(api) do
    if type(fn) == "function" then names[#names + 1] = name end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local k = kernel[name]
    if k then
      for _, line in ipairs(k.doc) do add("--- " .. line) end
      for i, p in ipairs(k.params) do add("---@param " .. p .. " " .. lua_type(k.types[i] or "LuaValue")) end
      add("function paw.api." .. name .. "(" .. table.concat(k.params, ", ") .. ") end")
    else
      add("---@type fun(...): any")
      add("paw.api." .. name .. " = nil")
    end
    add("")
  end
  return table.concat(out, "\n")
end

local function signature(f)
  return call_name(f) .. "(" .. table.concat(f.params or {}, ", ") .. ")"
end

--- The `:help` page's Markdown.
function M.page()
  local out = { "# Lua API reference", "", "<!-- " .. HEADER .. " -->", "",
    "Every public function of the `paw` modules, with what its comment in the",
    "source says, module by module; [The Lua interface](scripting.md) and",
    "[Extensions](../extensions.md) say how they fit together. The kernel's own",
    "functions (`paw.api`, plain data in and out) are listed at the end.",
    "`runtime/types/paw.lua` holds the same for editors (LuaLS).", "" }
  local function add(line) out[#out + 1] = line end
  local by_module = {}
  for _, f in ipairs(M.functions()) do
    by_module[f.module] = by_module[f.module] or {}
    table.insert(by_module[f.module], f)
  end
  for _, mod in ipairs(M.modules()) do
    local list = by_module[mod.name]
    if list then
      add("## Module " .. mod.name)
      add("")
      for _, f in ipairs(list) do
        if f.alias_of then
          add("- `" .. f.name .. "`: the same as `" .. f.alias_of .. "`.")
        else
          local sig = signature(f)
          local doc = {}
          for _, line in ipairs(f.doc or {}) do
            if not line:match("^@") then doc[#doc + 1] = line end
          end
          -- Runs of prose and of examples (the lines indented in the
          -- comment), in order: the first prose after the name, the rest
          -- under it.
          local runs = {}
          for _, line in ipairs(doc) do
            local code = line:match("^  ") ~= nil
            local last = runs[#runs]
            if not last or last.code ~= code then
              last = { code = code }
              runs[#runs + 1] = last
            end
            last[#last + 1] = code and line:gsub("^  ", "") or line
          end
          local first = runs[1] and not runs[1].code and table.remove(runs, 1)
          add("- `" .. sig .. "`" .. (first and ": " .. table.concat(first, " ") or ""))
          for _, run in ipairs(runs) do
            add("")
            if run.code then
              add("  ```lua")
              for _, line in ipairs(run) do add("  " .. line) end
              add("  ```")
            else
              add("  " .. table.concat(run, " "))
            end
          end
        end
      end
      add("")
    end
  end
  add("## Module paw.api")
  add("")
  local kernel = M.kernel_functions()
  local names = {}
  for name, fn in pairs(api) do
    if type(fn) == "function" then names[#names + 1] = name end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local k = kernel[name]
    local params = k and table.concat(k.params, ", ") or "..."
    local doc = k and #k.doc > 0 and ": " .. table.concat(k.doc, " ") or ""
    add("- `paw.api." .. name .. "(" .. params .. ")`" .. doc)
  end
  add("")
  return table.concat(out, "\n")
end

--- What is out of date: a list of the files whose text differs.
function M.stale()
  local out = {}
  if read(M.META) ~= M.meta() then out[#out + 1] = M.META end
  if read(M.PAGE) ~= M.page() then out[#out + 1] = M.PAGE end
  return out
end

function M.write()
  os.execute("mkdir -p runtime/types")
  for path, text in pairs({ [M.META] = M.meta(), [M.PAGE] = M.page() }) do
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
  end
end

local mode = ...
if mode == "module" then return M end
if mode == "check" then
  local gaps, stale = M.undocumented(), M.stale()
  for _, gap in ipairs(gaps) do print("undocumented: " .. gap) end
  for _, path in ipairs(stale) do print("out of date: " .. path .. " (run tools/apidoc.lua)") end
  api.quit((#gaps == 0 and #stale == 0) and 0 or 1)
else
  M.write()
  print("wrote " .. M.META .. " and " .. M.PAGE)
  api.quit(0)
end
