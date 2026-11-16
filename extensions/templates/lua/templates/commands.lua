-- Commands, keys and menu entries for templates.
local api = daw.api
local templates = require("templates")
local command = daw.command

local function clean(err)
  return (tostring(err):gsub("^[^:]*:%d+: ", ""):match("^[^\n]*"))
end

--- Ask for a name, starting from one, and call `done` with it.
local function named(given, start, done)
  if given and given ~= "" then return done(given) end
  daw.ui.input({ prompt = "Template name: ", text = start }, function(text)
    if text and text ~= "" then done(text) end
  end)
end

command("template.save", function(ctx)
  local track = daw.cursor.track()
  if not track then return daw.notify("no track to save", "warn") end
  local group = daw.groups.is_group(track.id)
  named(ctx.args[1], track.name, function(name)
    local ok, path = pcall(group and templates.save_group or templates.save_track, track, name)
    if not ok then return daw.notify(clean(path), "error") end
    daw.notify(string.format("%s “%s” saved as a template (%s)", group and "group" or "track", name, path))
  end)
end, { desc = "Save the track as a template, or the group with every track in it: `template.save Lead vocal`", raw = true })

command("template.fx", function(ctx)
  local track = daw.cursor.track()
  if not track then return daw.notify("no track", "warn") end
  named(ctx.args[1], track.name .. " chain", function(name)
    local ok, path = pcall(templates.save_fx, track, name)
    if not ok then return daw.notify(clean(path), "error") end
    daw.notify(string.format("the devices of “%s” saved as the chain “%s” (%s)", track.name, name, path))
  end)
end, { desc = "Save the track's devices as a chain to add elsewhere: `template.fx Vocal chain`", raw = true })

--- Make a template again and say what was made.
local function load(name, kind)
  local ok, made, was = pcall(templates.load, name, { kind = kind })
  if not ok then return daw.notify(clean(made), "error") end
  if was == "fx" then
    daw.notify(#made .. (#made == 1 and " device" or " devices") .. " added from “" .. name .. "”")
  else
    daw.notify((was == "group" and "group “" or "track “") .. made.name .. "” made from a template")
  end
end

--- Choose among the templates of one kind, or of all.
local function pick(kind, on_choose)
  local items = templates.list(kind)
  if #items == 0 then
    return daw.notify("no templates yet: `:template.save` saves the track, `:template.fx` its devices", "warn")
  end
  daw.pick({
    title = "Templates",
    items = items,
    format = function(item) return string.format("%-16s %s", item.title, item.name) end,
    on_choose = on_choose,
  })
end

command("template.load", function(ctx)
  local name = ctx.args[1]
  if name and name ~= "" then return load(name) end
  pick(nil, function(item) load(item.name, item.kind) end)
end, {
  desc = "Make a template again: a track or group below the cursor track, a chain on it. `template.load Lead vocal`; alone, choose from a list",
  raw = true,
  complete = function()
    local names = {}
    for i, item in ipairs(templates.list()) do names[i] = item.name end
    return names
  end,
})

command("template.delete", function(ctx)
  local name = ctx.args[1]
  if name and name ~= "" then
    return daw.notify(templates.delete(name) and ("template “" .. name .. "” deleted") or ("no template `" .. name .. "`"))
  end
  pick(nil, function(item)
    templates.delete(item.name, item.kind)
    daw.notify("template “" .. item.name .. "” deleted")
  end)
end, {
  desc = "Delete a template: `template.delete Lead vocal`; alone, choose from a list", raw = true,
  complete = function()
    local names = {}
    for i, item in ipairs(templates.list()) do names[i] = item.name end
    return names
  end,
})

command("templates", function()
  local items = templates.list()
  if #items == 0 then return daw.notify("no templates yet, in " .. templates.dir()) end
  local lines = {}
  for i, item in ipairs(items) do lines[i] = string.format("%-16s %s", item.title, item.name) end
  daw.notify(table.concat(lines, "\n"))
end, { desc = "List the templates" })

daw.keymap.group("<leader>T", "templates", { view = "arrange" })
daw.keymap.set("<leader>Tl", "template.load", { view = "arrange", desc = "Make a track, group or chain from a template" })
daw.keymap.set("<leader>Ts", "template.save", { view = "arrange", desc = "Save the track or group as a template" })
daw.keymap.set("<leader>Tf", "template.fx", { view = "arrange", desc = "Save the track's devices as a chain" })

-- In the window's menus.
table.insert(daw.frontend.menus.timeline, { label = "From a template…", command = "template.load" })
table.insert(daw.frontend.menus.track, { label = "Save as a template…", command = "template.save" })
table.insert(daw.frontend.menus.track, { label = "Save its devices as a chain…", command = "template.fx" })
table.insert(daw.frontend.menus.track, { label = "Add devices from a template…", run = function()
  pick("fx", function(item) load(item.name, "fx") end)
end })
