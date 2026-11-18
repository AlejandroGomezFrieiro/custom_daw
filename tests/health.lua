-- `:checkhealth`: the core's checks, an extension's, and how they are
-- reported. Loaded by tests/suite.lua with its helpers.
local T = ...
local test, eq = T.test, T.eq

local function pager_text()
  local out = {}
  for _, line in ipairs(paw.ui.views.pager.lines) do out[#out + 1] = line.text end
  return table.concat(out, "\n")
end

local function levels(result)
  local out = {}
  for _, item in ipairs(result.items) do out[#out + 1] = item.level end
  return table.concat(out, " ")
end

-- The errors a test means to cause are read, as `:messages` reads them,
-- so that the key line of the tests after it does not point at them.
local function read_errors()
  paw.commands.exec("messages")
  paw.ui.close()
end

test("checkhealth: the core's checks each report, with a level and advice", function()
  for _, name in ipairs({ "paw", "audio", "plugins", "ffmpeg", "terminal", "fonts", "extensions" }) do
    local r = paw.health.run(name)
    eq(#r.items > 0, true, name .. " says something")
    for _, item in ipairs(r.items) do
      eq(({ ok = true, info = true, warn = true, error = true })[item.level], true, name .. "'s level " .. tostring(item.level))
    end
  end
  local paw_check = paw.health.run("paw")
  eq(paw_check.items[1].text:find("Lua API " .. paw.api.version, 1, true) ~= nil, true, "the API version")
  local audio = paw.health.run("audio")
  eq(audio.items[1].level, "warn", "the null backend the suite runs on is a warning")
  eq(#audio.items[1].advice > 0, true, "with advice")
end)

test("checkhealth: the command shows every check, or the ones named", function()
  paw.cmd("checkhealth")
  local text = pager_text()
  paw.ui.close()
  for _, name in ipairs({ "paw", "audio", "plugins", "extensions" }) do
    eq(text:find("\n" .. name .. ": ", 1, true) ~= nil or text:sub(1, #name + 2) == name .. ": ", true, name .. " is in it")
  end
  eq(text:find("- WARN the null audio backend", 1, true) ~= nil, true, "levels shown as Neovim shows them")
  eq(text:find("    - start without --audio null", 1, true) ~= nil, true, "advice under its item")
  local worst = paw.cmd("checkhealth", { "ffmpeg" })
  eq(pager_text():match("^ffmpeg: ") ~= nil, true, "one check by name")
  eq(pager_text():find("audio:", 1, true), nil, "and only it")
  eq(worst == "ok" or worst == "warn", true, "it returns the worst level")
  paw.ui.close()
  local completions = paw.commands.complete("checkhealth au")
  local found = false
  for _, c in ipairs(completions) do found = found or (c.text or ""):match("audio$") ~= nil end
  eq(found, true, "names complete")
end)

test("checkhealth: an extension's check is its own, and a check that fails is an error of its own", function()
  local dir = T.scratch .. "/health-ext"
  os.execute("mkdir -p '" .. dir .. "'")
  T.write_file(dir .. "/healthy.lua", [[
    paw.health.register("healthy", function(h)
      h.ok("all well")
      h.warn("but this", { "do that", "or the other" })
    end, { desc = "a test" })
    paw.health.register("broken", function(h) error("oops") end)
  ]])
  paw.ext.load(dir .. "/healthy.lua")
  local r = paw.health.run("healthy")
  eq(levels(r), "ok warn", "what it reported")
  eq(r.items[2].advice[2], "or the other", "with advice")
  eq(r.desc, "a test", "and what it checks")
  local b = paw.health.run("broken")
  eq(levels(b), "error", "a check that fails")
  eq(b.items[1].text:find("oops", 1, true) ~= nil, true, "says why")
  eq(levels(paw.health.run("nowhere")), "error", "a name with no check")
  local owned = ""
  for _, group in ipairs(paw.ext.provides("healthy")) do
    if group.kind == "health" then owned = table.concat(group.items, " ") end
  end
  eq(owned, "broken healthy", "the extension owns its checks")
  eq(paw.health.run("extensions").items[1] ~= nil, true, "the extensions check runs")
  paw.ext.unload("healthy")
  eq(paw.health.checks.healthy, nil, "and they go with it")
end)

test("checkhealth: the extensions check lists versions and requirements, and a failed one is an error", function()
  T.after(read_errors)
  T.write_file(T.scratch .. "/health-bad.lua", "error('cannot start')")
  local bad = paw.ext.load(T.scratch .. "/health-bad.lua")
  eq(bad.ok, false, "it failed")
  local found
  for _, item in ipairs(paw.health.run("extensions").items) do
    if item.text:find("^health%-bad") then found = item end
  end
  eq(found and found.level, "error", "the failed extension is an error")
  eq(found.text:find("cannot start", 1, true) ~= nil, true, "with its error")
  paw.ext.unload("health-bad")
  for _, name in ipairs({ "utau", "sampler" }) do
    if paw.health.checks[name] then
      eq(#paw.health.run(name).items > 0, true, name .. "'s own check reports")
    end
  end
end)
