-- The undo tree, named checkpoints and A/B listening. See README.md beside
-- this file.
local api = daw.api
local undotree = require("undotree")
local view = require("undotree.view")

daw.option.define("undotree_ab_key", "\\")   -- the one key that switches between A and B; "" for none

local command, map = daw.command, daw.keymap.set

command("undotree", function()
  if daw.ui.float and daw.ui.float.name == "undotree" then return daw.ui.close() end
  view.open()
end, { desc = "Show the undo tree" })

command("earlier", function(ctx)
  undotree.travel(-1, ctx.args[1], ctx.count)
end, { desc = "Go back in time across branches: `earlier 5`, `earlier 2m` (s, m, h, d)" })

command("later", function(ctx)
  undotree.travel(1, ctx.args[1], ctx.count)
end, { desc = "Go forward in time across branches: `later 5`, `later 30s`" })

command("undo.goto", function(ctx)
  local id = tonumber(ctx.args[1])
  if not id then return daw.notify("usage: undo.goto <state number>", "warn") end
  undotree.go(id)
end, { desc = "Go to a state of the undo tree by its number" })

command("undo.name", function(ctx)
  local name = table.concat(ctx.args, " ")
  local id = api.undo_name(name ~= "" and name or nil)
  daw.notify(name ~= "" and ("named #" .. id .. " " .. name) or ("#" .. id .. " has no name now"))
end, { desc = "Name the current state, in this session (`checkpoint` also writes it to disk)", raw = true })

command("undo.diff", function(ctx)
  local diff = api.undo_diff(tonumber(ctx.args[1]), tonumber(ctx.args[2]))
  local lines = { { text = undotree.summary(diff), style = "HelpSection" }, "" }
  for _, item in ipairs(diff.items) do lines[#lines + 1] = item end
  daw.ui.page(string.format("#%d → #%d", diff.from, diff.to), lines)
end, { desc = "What changed: `undo.diff` the last step, `undo.diff 3` from #3 to now, `undo.diff 3 7`" })

command("checkpoint", function(ctx)
  local function write(name)
    local ok, result, why = pcall(undotree.checkpoint, name)
    if not ok then return daw.notify(tostring(result), "error") end
    if not result then return daw.notify(why, "warn") end
    if result.pending then
      daw.notify("named #" .. result.state .. " " .. result.name .. "; it is written beside the project when the project is first saved")
    else
      daw.notify("checkpoint " .. result.name .. " written (#" .. result.state .. ")")
    end
  end
  local name = table.concat(ctx.args, " ")
  if name ~= "" then return write(name) end
  daw.ui.input({ prompt = "Checkpoint name: " }, write)
end, { desc = "Name the current state and write it beside the project: `checkpoint before the bridge`", raw = true })

command("checkpoints", function()
  undotree.choose()
end, { desc = "List the checkpoints, and restore one" })

command("checkpoint.restore", function(ctx)
  local item = undotree.find(ctx.args[1] or "")
  if not item then return daw.notify("no such checkpoint: `:checkpoints` lists them", "warn") end
  local ok, err = pcall(undotree.restore, item)
  if not ok then daw.notify(tostring(err), "error") end
end, { desc = "Restore a checkpoint by its number in `:checkpoints` or its name", raw = true })

command("checkpoint.delete", function(ctx)
  local item = undotree.find(ctx.args[1] or "")
  if not item or not item.file then return daw.notify("no such checkpoint on disk", "warn") end
  api.checkpoint_delete(item.file)
  daw.notify("deleted checkpoint " .. item.name)
end, { desc = "Delete a checkpoint from disk, by number or name", raw = true })

command("ab.mark", function(ctx)
  undotree.mark_a(tonumber(ctx.args[1]))
end, { desc = "Mark the current state (or the one given) as A, for comparing by ear" })

command("ab.toggle", function()
  local where, why = undotree.toggle()
  if where then daw.notify("playing " .. where) else daw.notify(why, "warn") end
end, { desc = "Switch between A and the state you came from, while the song plays on" })

command("ab.clear", function()
  undotree.clear_ab()
  daw.notify("A and B cleared")
end, { desc = "Forget the A/B marks" })

map("g-", function(ctx) undotree.travel(-1, nil, ctx.count) end, { desc = "Older state, across branches", repeatable = false })
map("g+", function(ctx) undotree.travel(1, nil, ctx.count) end, { desc = "Newer state, across branches", repeatable = false })
map("<leader>uu", "undotree", { desc = "Undo tree", repeatable = false })
map("<leader>ua", "ab.mark", { desc = "Mark this state as A", repeatable = false })
map("<leader>ub", "ab.toggle", { desc = "Switch between A and B", repeatable = false })
map("<leader>uB", "ab.clear", { desc = "Forget A and B", repeatable = false })
map("<leader>uc", "checkpoint", { desc = "Write a checkpoint", repeatable = false })
map("<leader>ul", "checkpoints", { desc = "List checkpoints", repeatable = false })
map("<leader>un", function()
  daw.ui.input({ prompt = "Name this state: " }, function(text) daw.cmd("undo.name", { text }) end)
end, { desc = "Name this state", repeatable = false })
map("<leader>ud", "undo.diff", { desc = "What the last step changed", repeatable = false })
if daw.opt.undotree_ab_key ~= "" then
  map(daw.opt.undotree_ab_key, "ab.toggle", { desc = "Switch between A and B", repeatable = false })
end
