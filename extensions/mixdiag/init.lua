-- Mix diagnostics for daw: loudness, true peak, clipping, stereo and more,
-- reported as findings you can list and jump between. See README.md.
daw.option.define("mixdiag_target", "streaming") -- a name in require("mixdiag").targets
daw.option.define("mixdiag_tail", 1)              -- seconds measured after the end, for releases
daw.option.define("mixdiag_ignore", "")           -- rule names to skip: "silence,forgotten"
daw.option.define("mixdiag_strip", true)          -- a row of marks above the arrange view

local mixdiag = require("mixdiag")
require("mixdiag.rules")
require("mixdiag.view")
require("mixdiag.paint")
package.loaded["daw.mixdiag"] = mixdiag

-- The findings are diagnostics too: a language server in this process,
-- attached to the mix (lua/mixdiag/lens.lua).
daw.lsp.config("mixdiag", { server = require("mixdiag.lens").server, attach = { subjects = { "mix" } } })
daw.lsp.enable("mixdiag")

local function try(fn)
  local ok, err = pcall(fn)
  if not ok then daw.notify("mix: " .. tostring(err), "error") end
end

local scopes = { "song", "loop", "selection", "track" }

daw.command("mix.analyze", function(ctx)
  local scope = ctx.args[1] or (daw.keymap.selection() and "selection") or "song"
  if ctx.args.file then scope = { file = ctx.args.file } end
  if daw.keymap.mode == "x" then daw.keymap.set_mode("n") end
  try(function() mixdiag.analyze(scope) end)
end, {
  desc = "Measure the mix and list what is wrong: `mix.analyze [song|loop|selection|track]`, `mix.analyze file=x.wav`",
  complete = function() return scopes end,
})

daw.command("mix.file", function(ctx)
  local path = ctx.args[1]
  if not path then return daw.notify("mix.file needs a path", "warn") end
  try(function() mixdiag.analyze({ file = path }) end)
end, { desc = "Measure an audio file: `mix.file master.wav`", complete = { "audio_files" } })

daw.command("mix.list", function() mixdiag.list() end, { desc = "List the mix findings" })
daw.command("mix.report", function() mixdiag.report() end, { desc = "The mix report: the loudness, peaks and range measured, and the findings to go to" })
daw.command("mix.next", function(ctx) mixdiag.step(1, ctx.count) end, { desc = "Go to the next mix finding" })
daw.command("mix.prev", function(ctx) mixdiag.step(-1, ctx.count) end, { desc = "Go to the previous mix finding" })
daw.command("mix.cancel", function()
  daw.notify(mixdiag.cancel() and "mix: measuring cancelled" or "mix: nothing is being measured")
end, { desc = "Stop a measurement that is running" })
daw.command("mix.clear", function() mixdiag.clear() end, { desc = "Forget the mix findings" })
daw.command("mix.summary", function()
  daw.notify(mixdiag.line and (mixdiag.line .. (mixdiag.stale() and "  (project changed since)" or "")) or "mix: nothing measured yet")
end, { desc = "Show the loudness, true peak and range of the last measurement" })

daw.command("mix.target", function(ctx)
  local name = ctx.args[1]
  if not name then
    local names = {}
    for key in pairs(mixdiag.targets) do names[#names + 1] = key end
    table.sort(names)
    local now = daw.opt.mixdiag_target
    local next_name = names[1]
    for i, key in ipairs(names) do
      if key == now then next_name = names[i % #names + 1] end
    end
    name = next_name
  end
  if not mixdiag.targets[name] then return daw.notify("mix: no target `" .. name .. "`", "warn") end
  daw.opt.mixdiag_target = name
  if mixdiag.result then mixdiag.finish(mixdiag.result, mixdiag.range_measured, true) end
  local t = mixdiag.targets[name]
  daw.notify(string.format("mix: target %s%s", t.name,
    t.integrated and string.format(" (%g LUFS, %g dBTP)", t.integrated, t.true_peak or 0) or ""))
end, {
  desc = "Choose the delivery target: `mix.target streaming|ebu|none`, or the next one",
  complete = function()
    local names = {}
    for key in pairs(mixdiag.targets) do names[#names + 1] = key end
    table.sort(names)
    return names
  end,
})

local map = daw.keymap.set
daw.keymap.group("<leader>x", "mix checks")
map("<leader>xa", "mix.analyze", { mode = { "n", "x" }, desc = "Measure the mix (the selection in visual mode)" })
map("<leader>xl", "mix.analyze loop", { desc = "Measure the loop" })
map("<leader>xk", "mix.analyze track", { desc = "Measure the cursor track's contribution" })
map("<leader>xx", "mix.list", { desc = "List the mix findings" })
map("<leader>xr", "mix.report", { desc = "The mix report" })
map("<leader>xs", "mix.summary", { desc = "Loudness, true peak and range of the last measurement" })
map("<leader>xt", "mix.target", { desc = "Next delivery target" })
map("<leader>xc", "mix.clear", { desc = "Forget the mix findings" })
map("<leader>xq", "mix.cancel", { desc = "Stop measuring" })
map("]d", function(ctx) mixdiag.step(1, ctx.count) end,
  { view = "arrange", motion = true, jump = true, desc = "Next mix finding" })
map("[d", function(ctx) mixdiag.step(-1, ctx.count) end,
  { view = "arrange", motion = true, jump = true, desc = "Previous mix finding" })
