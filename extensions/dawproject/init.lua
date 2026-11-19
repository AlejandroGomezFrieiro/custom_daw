-- DAWproject: open .dawproject files (Bitwig Studio, Studio One, Cubase)
-- and write paw's projects as .dawproject. See README.md beside this file.
local dp = require("dawproject")

local function import(path, args)
  if args.merge ~= true and not paw.project.guard("dawproject.import") then return end
  local ok, result = pcall(dp.import, path, { merge = args.merge == true })
  if not ok then return paw.notify("dawproject: " .. (tostring(result):gsub("\n.*", "")), "error") end
  dp.show(result.report, string.format("imported %s: %d tracks, %d clips, %d plugins",
    path, #result.tracks, result.clips, result.devices))
  return result
end

local function export(path, args)
  local ok, result = pcall(dp.export, path, { embed = not (args and args.embed == false) })
  if not ok then return paw.notify("dawproject: " .. (tostring(result):gsub("\n.*", "")), "error") end
  dp.show(result.report, "wrote " .. path)
  return result
end

paw.command("dawproject.import", function(ctx)
  local path = ctx.args[1]
  if not path then return paw.notify("usage: dawproject.import <file.dawproject> [merge=true]", "warn") end
  return import(tostring(path), ctx.args)
end, { desc = "Open a DAWproject file: `dawproject.import song.dawproject`, `merge=true` adds its tracks", complete = { "projects" } })

paw.command("dawproject.export", function(ctx)
  local path = ctx.args[1]
  if not path then return paw.notify("usage: dawproject.export <file.dawproject> [embed=false]", "warn") end
  return export(tostring(path), ctx.args)
end, { desc = "Write the project as a DAWproject file: `dawproject.export song.dawproject`, `embed=false` keeps the audio outside", complete = { "projects" } })

-- `edit song.dawproject` and `write song.dawproject` go through the
-- extension; other files are left to the commands as they were.
local function hook(name, alias, run)
  local spec = paw.commands.get(name)
  if not spec or spec.dawproject_hooked then return end
  local original = spec.run
  paw.command(name, function(ctx)
    local path = ctx.args and ctx.args[1]
    if path and tostring(path):lower():match("%.dawproject$") then return run(tostring(path), ctx.args) end
    return original(ctx)
  end, { desc = spec.desc .. " (or a .dawproject)", raw = spec.raw, complete = spec.complete })
  paw.commands.get(name).dawproject_hooked = true
  if alias and paw.commands.get(alias) then paw.command.alias(alias, name) end
end

paw.project.allow_discard("dawproject.import")
hook("edit", "e", import)
hook("write", "w", export)
