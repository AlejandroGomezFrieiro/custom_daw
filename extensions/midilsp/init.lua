-- MIDI LSP for daw: the language server for music from openutau_reaper_editor
-- (projects/midi-lsp), plugged into `daw.lsp` as any server is. This file is
-- its configuration and nothing more: where the engine is, how to start it,
-- its settings as commands, and a list of what every server says. See
-- README.md.
daw.option.define("midilsp_cmd", "")        -- the engine to run; empty: $MIDI_LSP_ENGINE, else reaper-midi-lsp on PATH
daw.option.define("midilsp_suggest", true)  -- also start the engine's suggestion role, for completion
daw.option.define("midilsp_autostart", true) -- start when loaded, if the engine is found

local midilsp = require("midilsp")

daw.command("midilsp", function(ctx)
  local verb = ctx.args[1] or "info"
  if verb == "start" then
    midilsp.start(true)
  elseif verb == "stop" then
    midilsp.stop()
  else
    daw.ui.page("MIDI LSP", midilsp.info_lines())
  end
end, { desc = "MIDI LSP: `midilsp` says where the engine is and how it runs; `midilsp start`, `midilsp stop`", complete = { "info", "start", "stop" } })

daw.command("midilsp.preset", function(ctx)
  local name = ctx.args[1]
  if not name then return daw.notify("midilsp: preset " .. midilsp.settings().preset .. " (of " .. table.concat(midilsp.presets(), ", ") .. ")") end
  local ok, err = pcall(midilsp.set_preset, name)
  if not ok then daw.notify(tostring(err):gsub("^.-:%d+: ", ""), "error") end
end, { desc = "The rules MIDI LSP checks, as a profile: `midilsp.preset strict-counterpoint`", complete = function() return midilsp.presets() end })

daw.command("midilsp.rule", function(ctx)
  local id, state = ctx.args[1], ctx.args[2]
  if not id then return midilsp.pick_rules() end
  local ok, err = pcall(midilsp.set_rule, id, state == nil and "toggle" or state == "on")
  if not ok then daw.notify(tostring(err):gsub("^.-:%d+: ", ""), "error") end
end, { desc = "Switch a MIDI LSP rule on or off: `midilsp.rule parallel-perfect off`; alone, a list to toggle them in",
  complete = function() return midilsp.rule_ids() end })

daw.command("problems", function() midilsp.problems() end,
  { desc = "Every language server's diagnostics with their fixes: Enter goes to one, or applies a fix" })

daw.keymap.set("<leader>lp", "problems", { desc = "Problems: every server's diagnostics and fixes" })
daw.keymap.set("<leader>lr", "midilsp.rule", { desc = "MIDI LSP's rules, to switch on and off" })
daw.keymap.set("<leader>li", "lsp info", { desc = "The language servers and what they can do" })

if daw.opt.midilsp_autostart then midilsp.start(false) end
