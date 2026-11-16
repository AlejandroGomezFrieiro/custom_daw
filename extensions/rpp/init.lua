-- REAPER bridge: open REAPER projects (.rpp) and write paw's projects as
-- .rpp. See README.md beside this file.
local rpp = require("rpp")

local function import(path, args)
  if args.merge ~= true and not daw.project.guard("rpp.import") then return end
  local result = rpp.import(path, { merge = args.merge == true, instrument = args.instrument and tostring(args.instrument) })
  rpp.show(result.report, string.format("imported %s: %d tracks, %d clips, %d plugins",
    path, #result.tracks, result.clips, result.devices))
  return result
end

local function export(path)
  local result = rpp.export(path)
  rpp.show(result.report, "wrote " .. path)
  return result
end

daw.command("rpp.import", function(ctx)
  local path = ctx.args[1]
  if not path then return daw.notify("usage: rpp.import <file.rpp> [merge=true] [instrument=synth]", "warn") end
  return import(tostring(path), ctx.args)
end, { desc = "Open a REAPER project: `rpp.import song.rpp`, `merge=true` adds its tracks, `instrument=synth` gives MIDI tracks a synth", complete = { "projects" } })

daw.command("rpp.export", function(ctx)
  local path = ctx.args[1]
  if not path then return daw.notify("usage: rpp.export <file.rpp>", "warn") end
  return export(tostring(path))
end, { desc = "Write the project as a REAPER project: `rpp.export song.rpp`", complete = { "projects" } })

-- `edit song.rpp` and `write song.rpp` go through the bridge; other files
-- are left to the commands as they were.
local function hook(name, alias, run)
  local spec = daw.commands.get(name)
  if not spec or spec.rpp_hooked then return end
  local original = spec.run
  daw.command(name, function(ctx)
    local path = ctx.args and ctx.args[1]
    if path and tostring(path):lower():match("%.rpp$") then return run(tostring(path), ctx.args) end
    return original(ctx)
  end, { desc = spec.desc .. " (or a REAPER .rpp)", raw = spec.raw, complete = spec.complete })
  daw.commands.get(name).rpp_hooked = true
  if alias and daw.commands.get(alias) then daw.command.alias(alias, name) end
end

daw.project.allow_discard("rpp.import")
hook("edit", "e", import)
hook("write", "w", export)
