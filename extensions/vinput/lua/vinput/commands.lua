-- Commands and keys for the virtual inputs, in the panel and from anywhere.
local api = daw.api
local keymap = daw.keymap
local vinput = require("vinput")
local run = require("vinput.run")
local panel = require("vinput.panel")
local command, map = daw.command, keymap.set

local M = {}

--- The input a command is about: the one named, the one the panel's cursor
--- is on while the panel has the keyboard, or the only one there is.
function M.target(name)
  if name and name ~= "" then
    local input = vinput.get(name)
    if not input then
      -- A part of a name is enough when it is one input's alone.
      local found
      for _, other in ipairs(vinput.inputs) do
        if other.name:lower():find(tostring(name):lower(), 1, true) then
          if found then found = false break end
          found = other
        end
      end
      input = found or nil
    end
    if not input then daw.notify("no virtual input `" .. name .. "`", "warn") end
    return input
  end
  local row = panel:current()
  if row and (daw.ui.focused == "vinput" or #vinput.inputs == 1) then return row.input end
  if #vinput.inputs == 1 then return vinput.inputs[1] end
  daw.notify(#vinput.inputs == 0 and "no virtual inputs yet: `:vinput.add` makes one" or "which input? name it", "warn")
end

--- Show the panel, and the window where there is a graphical frontend.
function M.open(name)
  if name then panel:go(name) end
  daw.ui.focus("vinput")
  daw.canvas.open("vinput", { title = "Virtual inputs", width = 880, height = 520 })
end

--- Choose an input's source from the ports there are.
function M.pick_source(input)
  local sources = run.sources(input.kind, true)
  local items = {}
  for _, name in ipairs(sources or {}) do items[#items + 1] = { label = name, source = name } end
  if input.source ~= "" then
    local known = false
    for _, item in ipairs(items) do known = known or item.source == input.source end
    if not known then table.insert(items, 1, { label = input.source .. "  (not there now)", source = input.source }) end
  end
  items[#items + 1] = { label = "Type a part of a port's name…", type = true }
  daw.pick({
    title = "Source of " .. input.name,
    items = items,
    format = function(item) return (item.source == input.source and "● " or "  ") .. item.label end,
    on_choose = function(item)
      if item.type then
        return daw.ui.input({ prompt = "Source: ", text = input.source }, function(text)
          if text then vinput.set(input.name, "source", text) end
        end)
      end
      vinput.set(input.name, "source", item.source)
    end,
  })
end

--- Ask for a setting's value on the command line.
local function ask(input, key, label, current)
  daw.ui.input({ prompt = label .. ": ", text = tostring(current) }, function(text)
    if not text then return end
    local ok, err = pcall(vinput.set, input.name, key, text)
    if not ok then daw.notify(tostring(err), "warn") end
  end)
end

--- Enter on a row: what the row is for.
function M.activate(row)
  if not row then return end
  local input, setting = row.input, row.setting
  if row.heading then
    vinput.set(input.name, "on", not input.on)
  elseif row.name then
    ask(input, "name", "Name", input.name)
  elseif setting.type == "choice" then
    M.pick_source(input)
  elseif setting.type == "switch" then
    vinput.set(input.name, setting.key, not input[setting.key])
  else
    ask(input, setting.key, setting.name, input[setting.key])
  end
end

local function names()
  local out = {}
  for i, input in ipairs(vinput.inputs) do out[i] = input.name end
  return out
end

command("vinput", function(ctx) M.open(ctx.args[1]) end, { desc = "Show the virtual inputs", complete = names })

command("vinput.add", function(ctx)
  local spec = { name = ctx.args[1], kind = ctx.args.kind }
  for key, value in pairs(ctx.args) do
    if type(key) == "string" and key ~= "kind" then spec[key] = value end
  end
  local ok, input = pcall(vinput.add, spec)
  if not ok then return daw.notify(tostring(input), "warn") end
  M.open(input.name)
  daw.notify("virtual input “" .. input.name .. "”: a track takes it as its MIDI input"
    .. (input.source == "" and "; choose its source" or ""))
end, { desc = "A new guitar-to-MIDI input: `vinput.add Guitar source=Input_2 gain=1.2`" })

command("vinput.remove", function(ctx)
  local input = M.target(ctx.args[1])
  if input and vinput.remove(input.name) then daw.notify("virtual input “" .. input.name .. "” is gone") end
end, { desc = "Take a virtual input away", complete = names })

command("vinput.set", function(ctx)
  local key, value = ctx.args[1], ctx.args[2]
  local input = M.target(ctx.args.input)
  if not input then return end
  if not key or value == nil then return daw.notify("usage: vinput.set <setting> <value> [input=name]", "warn") end
  local ok, err = pcall(vinput.set, input.name, key, value)
  if not ok then return daw.notify(tostring(err), "warn") end
  local setting = vinput.setting(input.kind, key)
  daw.notify(input.name .. ": " .. key .. " " .. (setting and vinput.format(setting, input[key]) or tostring(input[key] or input.name)))
end, {
  desc = "Change a setting of a virtual input: `vinput.set gain 1.2`, `vinput.set threshold 0.8 input=Guitar`",
  complete = function()
    local words = { "name" }
    for _, setting in ipairs(vinput.settings("gdi2m")) do words[#words + 1] = setting.key end
    return words
  end,
})

command("vinput.source", function(ctx)
  local input = M.target()
  if not input then return end
  local text = ctx.args[1]
  if not text or text == "" then return M.pick_source(input) end
  vinput.set(input.name, "source", text)
  daw.notify(input.name .. " ← " .. input.source)
end, { desc = "The audio port a virtual input listens to: from a list, or `vinput.source Input 2`", raw = true })

for _, on in ipairs({ true, false }) do
  command(on and "vinput.on" or "vinput.off", function(ctx)
    local input = M.target(ctx.args[1])
    if input then vinput.set(input.name, "on", on) end
  end, { desc = on and "Turn a virtual input on" or "Turn a virtual input off", complete = names })
end

command("vinput.restart", function(ctx)
  local input = M.target(ctx.args[1])
  if input then run.restart(input.name) end
end, { desc = "Start a virtual input's tracker again", complete = names })

command("vinput.track", function(ctx)
  local input = M.target(ctx.args[1])
  if not input then return end
  local track = vinput.make_track(input.name, ctx.args[2])
  daw.notify("track “" .. track.name .. "” plays what “" .. input.name .. "” hears; record with it armed")
end, { desc = "A track that takes a virtual input: `vinput.track Guitar [instrument]`", complete = names })

command("vinput.gain", function(ctx)
  local input = M.target(ctx.args[1])
  if not input then return end
  local advice = vinput.status(input.name).advice
  if not advice then return daw.notify("the tracker says what gain it would take when it has heard some playing and stopped", "info") end
  vinput.set(input.name, "gain", advice.gain)
  daw.notify(string.format("%s: gain %.2f, the level was %.1f dB %s", input.name, input.gain, advice.db, advice.way))
end, { desc = "Take the gain the tracker asked for after its last run", complete = names })

command("vinput.status", function()
  if #vinput.inputs == 0 then return daw.notify("no virtual inputs: `:vinput.add` makes one") end
  local lines = {}
  for _, input in ipairs(vinput.inputs) do
    lines[#lines + 1] = input.name .. ": " .. panel.status_text(vinput.status(input.name)) .. "   " .. panel.chain(input)
  end
  daw.notify(table.concat(lines, "\n"))
end, { desc = "What every virtual input is doing" })

-- Keys ------------------------------------------------------------------------------

map("<leader>i", "vinput", { view = "arrange", desc = "Virtual inputs (guitar to MIDI)" })

local function pmap(lhs, rhs, desc, opts) map(lhs, rhs, daw.util.merge({ view = "vinput", desc = desc }, opts)) end
local function move(by) return function(ctx)
  panel.row = panel.row + by * (ctx.count or 1)
  panel:current()
  api.ui_redraw()
end end
pmap("j", move(1), "Down a row")
pmap("k", move(-1), "Up a row")
pmap("<Down>", move(1), "Down a row")
pmap("<Up>", move(-1), "Up a row")
pmap("gg", function() panel.row = 1 api.ui_redraw() end, "The first row")
pmap("G", function() panel.row = #panel:rows() api.ui_redraw() end, "The last row")
local function adjust(steps) return function(ctx)
  local row = panel:current()
  if not row then return end
  if row.heading then return vinput.set(row.input.name, "on", steps > 0) end
  if row.setting then vinput.nudge(row.input.name, row.setting.key, steps * (ctx.count or 1)) end
end end
pmap("l", adjust(1), "More; on")
pmap("h", adjust(-1), "Less; off")
pmap("<Right>", adjust(1), "More; on")
pmap("<Left>", adjust(-1), "Less; off")
pmap("L", adjust(10), "Much more")
pmap("H", adjust(-10), "Much less")
pmap("<CR>", function() M.activate((panel:current())) end, "Change this: on or off, choose, type")
pmap("=", function()
  local row = panel:current()
  if row and row.setting then vinput.set(row.input.name, row.setting.key, row.setting.default) end
end, "Back to the setting's usual value")
pmap("o", function()
  local row = panel:current()
  if row then vinput.set(row.input.name, "on", not row.input.on) end
end, "The input on or off")
pmap("a", "vinput.add", "A new input")
pmap("D", "vinput.remove", "Take the input away")
pmap("r", "vinput.restart", "Start the tracker again")
pmap("R", function()
  local row = panel:current()
  run.sources(row and row.input.kind or "gdi2m", true)
  daw.notify("looking for audio ports")
end, "Look for audio ports again")
pmap("s", "vinput.source", "Choose the source")
pmap("t", "vinput.track", "A track that takes the input")
pmap("g", "vinput.gain", "Take the gain the tracker asked for")
pmap("<Esc>", function() daw.ui.focus("arrange") end, "Back to the arrange view")

if daw.ui.keybar then
  daw.ui.keybar.set("vinput", "n", {
    { "<CR>", "change" }, { "h", "less" }, { "l", "more" }, { "o", "on/off" }, { "s", "source" }, { "a", "add" },
    { "t", "track" }, { "g", "take gain" }, { "r", "restart" }, { "D", "remove" }, { "<Esc>", "back" },
  })
end

-- In the window's menus ----------------------------------------------------------

table.insert(daw.frontend.menus.timeline, { label = "New track from a virtual input", run = function()
  -- The first input, made if there is none; its window, to choose the source in.
  local input = vinput.inputs[1] or vinput.add({})
  vinput.make_track(input.name)
  M.open(input.name)
end })
table.insert(daw.frontend.menus.timeline, { label = "Virtual inputs…", run = function() M.open() end })

package.loaded["vinput.commands"] = M
return M
