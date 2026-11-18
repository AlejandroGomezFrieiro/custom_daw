-- The extension API: manifests and versions, what an extension owns and
-- taking it away again. Loaded by tests/suite.lua with its helpers.
local T = ...
local test, eq, fails = T.test, T.eq, T.fails
local api = paw.api

local function write(path, text)
  os.execute("mkdir -p '" .. path:match("^(.*)/") .. "'")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function dir(name)
  return T.scratch .. "/extapi/" .. name
end

local function names(list)
  local out = {}
  for _, item in ipairs(list) do out[#out + 1] = item end
  return table.concat(out, " ")
end

local function provided(name, kind)
  for _, group in ipairs(paw.ext.provides(name)) do
    if group.kind == kind then return names(group.items) end
  end
  return ""
end

-- The errors a test means to cause are read, as `:messages` reads them,
-- so that the key line of the tests after it does not point at them.
local function read_errors()
  paw.commands.exec("messages")
  paw.ui.close()
end

test("the API has a version, and requirements are checked against it", function()
  T.after(read_errors)
  eq(api.version, "1.0.0", "the version")
  eq(paw.ext.satisfies("1.2.3", ">=1.2"), true, ">=")
  eq(paw.ext.satisfies("1.2.3", "^1.0"), true, "^ keeps the first number")
  eq(paw.ext.satisfies("2.0.0", "^1.0"), false, "and refuses another")
  eq(paw.ext.satisfies("1.3.0", "~1.2"), false, "~ keeps the first two")
  eq(paw.ext.satisfies("1.2.9", "~1.2"), true, "~ within")
  eq(paw.ext.satisfies("1.2.3", ">=1.0, <1.2"), false, "a range")
  eq(paw.ext.satisfies("0.9", "*"), true, "any")
  eq(paw.ext.satisfies("1.0.0", "1.0"), true, "a bare version is ^")
  write(dir("future") .. "/manifest.lua", 'return { version = "1.0.0", requires = { paw = ">=9.0" } }')
  write(dir("future") .. "/init.lua", "paw.command('future.hi', function() end)")
  local entry = paw.ext.load(dir("future"))
  eq(entry.ok, false, "an extension for a later API does not load")
  eq(entry.error:find("needs the paw API >=9.0, and this is 1.0.0", 1, true) ~= nil, true, "and says why: " .. tostring(entry.error))
  eq(paw.commands.get("future.hi"), nil, "nothing of it ran")
  paw.ext.unload("future")
end)

test("an extension's requirements are loaded before it, and their versions checked", function()
  T.after(read_errors)
  write(dir("reqs/base") .. "/manifest.lua", 'return { version = "1.4.0", description = "the base", provides = { "basics" } }')
  write(dir("reqs/base") .. "/init.lua", "paw.command('base.hi', function() return 'base' end)")
  write(dir("reqs/top") .. "/manifest.lua", 'return { version = "0.2.0", requires = { paw = "^1", base = ">=1.2" } }')
  write(dir("reqs/top") .. "/init.lua", "assert(paw.ext.loaded.base, 'base first') paw.command('top.hi', function() return paw.cmd('base.hi') end)")
  write(dir("reqs/old") .. "/manifest.lua", 'return { requires = { base = ">=2" } }')
  write(dir("reqs/old") .. "/init.lua", "")
  write(dir("reqs/needy") .. "/manifest.lua", 'return { requires = { basics = "*", nowhere = "*" } }')
  write(dir("reqs/needy") .. "/init.lua", "")
  local top = paw.ext.load(dir("reqs/top"))
  eq(top.ok, true, "loads: " .. tostring(top.error))
  eq(paw.ext.loaded.base.version, "1.4.0", "with what it requires, loaded from beside it")
  eq(paw.cmd("top.hi"), "base", "which it can use")
  local old = paw.ext.load(dir("reqs/old"))
  eq(old.ok, false, "a version too old is refused")
  eq(old.error, "needs base >=2, and this is 1.4.0", "and says so")
  local needy = paw.ext.load(dir("reqs/needy"))
  eq(needy.error, "needs the extension nowhere, which is not to be found", "a name provided counts; a missing one does not")
  local ok, why = paw.ext.unload("base")
  eq(ok, nil, "an extension another requires stays")
  eq(why, "top requires base: unload it first", "and says which")
  for _, name in ipairs({ "needy", "old", "top", "base" }) do eq(paw.ext.unload(name), true, "unload " .. name) end
  eq(paw.commands.get("base.hi"), nil, "gone with it")
end)

test("what an extension registers is its own, and unloading it takes all of it away", function()
  T.fresh()
  local root = dir("owner")
  write(root .. "/manifest.lua", 'return { version = "0.3.0", description = "owns things" }')
  write(root .. "/lua/owner/lib.lua", "return { word = 'lib' }")
  write(root .. "/init.lua", [[
    local lib = require("owner.lib")
    paw.command("owner.go", function() return lib.word end, { desc = "Go" })
    -- One of the core's own, replaced: unloading puts the core's back.
    paw.command("info", function() return "owner's info" end, { desc = "Taken over" })
    paw.keymap.set("<leader>Zo", "owner.go", { desc = "Owner" })
    paw.keymap.group("<leader>Z", "owner things")
    paw.ui.view("ownerview", { render = function(_, buf) buf:text(0, 0, "owned") end })
    paw.buftype("ownerbuf", { create = function() return {} end, render = function() end })
    paw.textbuf.kind("owned", { pattern = "^paw://owned$", read = function() return {} end, format = function() return {} end })
    paw.track_kinds.define("ownedkind", { title = "Owned track" })
    paw.pick.sources.owned = { items = function() return {} end }
    paw.query.field("track", "ownedness", function() return 1 end)
    paw.statusline.component("owned", function() return "O" end)
    paw.grep.source("owned", function(add) end)
    paw.ex.field("owned", { level = "note", type = "number", get = function() return 1 end })
    paw.commands.completers.owned = function() return {} end
    paw.curves.provide("owned", function() end)
    paw.ui.layer("arrange", "header", "owned", 99, function() end)
    paw.on("track.added", function() _G.owner_heard = (_G.owner_heard or 0) + 1 end)
    paw.option.define("owned_option", 7)
  ]])
  local core_info = paw.commands.get("info")
  local entry = paw.ext.load(root)
  eq(entry.ok, true, "loads: " .. tostring(entry.error))
  eq(entry.version, "0.3.0", "the manifest's version")
  eq(provided("owner", "commands"), ":info :owner.go", "its commands")
  eq(provided("owner", "keys"), "<leader>Zo (n)", "its keys")
  eq(provided("owner", "views"), "ownerview", "its view")
  eq(provided("owner", "buftypes"), "ownerbuf", "its buffer type")
  eq(provided("owner", "track_kinds"), "ownedkind", "its kind of track")
  eq(provided("owner", "hooks"), "track.added", "its hook")
  eq(provided("owner", "options"), "owned_option", "its option")
  for _, kind in ipairs({ "key_groups", "textbuf_kinds", "pickers", "query_fields", "statusline", "grep", "ex_fields", "completers", "curves", "layers" }) do
    eq(provided("owner", kind) ~= "", true, "it owns its " .. kind)
  end
  eq(paw.commands.get("owner.go").ext, "owner", "a command says whose it is")
  paw.cmd("extensions")
  local shown = {}
  for _, line in ipairs(paw.ui.views.pager.lines) do shown[#shown + 1] = line.text end
  paw.ui.close()
  shown = table.concat(shown, "\n")
  eq(shown:find("owner 0.3.0", 1, true) ~= nil, true, ":extensions shows the name and version")
  eq(shown:find("owns things", 1, true) ~= nil, true, "the description")
  eq(shown:find(":owner.go", 1, true) ~= nil, true, "and what it registered")

  paw.add_track({ name = "heard" })
  paw.flush()
  eq(_G.owner_heard, 1, "its hook runs while it is loaded")

  eq(paw.ext.unload("owner"), true, "unloads")
  eq(paw.ext.loaded.owner, nil, "is no longer loaded")
  eq(paw.commands.get("owner.go"), nil, "its command is gone")
  eq(paw.commands.get("info"), core_info, "the core's command it replaced is back")
  eq(paw.keymap.groups().global and paw.keymap.groups().global[table.concat(paw.keymap.parse("<leader>Z"))], nil, "its key group is gone")
  for _, map in ipairs(paw.keymap.every()) do
    if map.lhs == "<leader>Zo" then error("its key is still mapped") end
  end
  eq(paw.ui.views.ownerview, nil, "its view")
  eq(paw.ui.views.ownerbuf, nil, "its buffer type's view")
  eq(paw.layout.types.ownerbuf, nil, "its buffer type")
  eq(paw.textbuf.kinds.owned, nil, "its text buffer kind")
  eq(paw.track_kinds.kinds.ownedkind, nil, "its kind of track")
  for _, item in ipairs(paw.frontend.menus.timeline) do
    if item.track_kind == "ownedkind" then error("its kind is still in the menu") end
  end
  eq(paw.pick.sources.owned, nil, "its picker source")
  eq(paw.query.fields.track.ownedness, nil, "its query field")
  eq(paw.statusline.components.owned, nil, "its status line component")
  eq(paw.grep.sources.owned, nil, "its grep source")
  for _, name in ipairs(paw.grep.order) do eq(name ~= "owned", true, "and its place in the order") end
  eq(paw.ex.fields.owned, nil, "its field")
  eq(paw.commands.completers.owned, nil, "its completer")
  eq(paw.curves.providers.owned, nil, "its curve provider")
  for _, layer in ipairs(paw.ui.layers.arrange.header or {}) do eq(layer.name ~= "owned", true, "its layer") end
  eq(package.loaded["owner.lib"], nil, "its modules are forgotten")
  paw.add_track({ name = "unheard" })
  paw.flush()
  eq(_G.owner_heard, 1, "its hook no longer runs")

  -- And it can be loaded again, afresh.
  eq(paw.ext.load(root).ok, true, "loads again")
  eq(paw.cmd("owner.go"), "lib", "with its modules")
  paw.ext.unload("owner")
  _G.owner_heard = nil
end)

test(":ext.unload takes a bundled extension away and :ext.load brings it back", function()
  T.fresh()
  local had = paw.ext.loaded.musicops ~= nil
  if not had then paw.cmd("ext.load", { "musicops" }) end
  eq(paw.ext.loaded.musicops.ok, true, "loaded")
  eq(paw.ext.loaded.musicops.version, "0.1.0", "with its manifest")
  local commands = provided("musicops", "commands")
  eq(commands ~= "", true, "it owns commands")
  local one = commands:match(":(%S+)")
  paw.commands.exec("ext.unload musicops")
  eq(paw.ext.loaded.musicops, nil, "unloaded")
  eq(paw.commands.get(one), nil, "its command " .. one .. " is gone")
  paw.commands.exec("ext.load musicops")
  eq(paw.commands.get(one) ~= nil, true, "and back")
  if not had then paw.ext.unload("musicops") end
end)

test("every bundled extension has a manifest that names it and asks for this API", function()
  for _, name in ipairs(paw.ext.bundled()) do
    local m, err = paw.ext.manifest(paw.ext.bundled_dir() .. "/" .. name, name)
    eq(err, nil, name .. "'s manifest reads")
    eq(type(m.version), "string", name .. " has a version")
    eq(type(m.description), "string", name .. " has a description")
    eq(paw.ext.satisfies(api.version, m.requires and m.requires.paw), true, name .. " asks for this API")
  end
end)
