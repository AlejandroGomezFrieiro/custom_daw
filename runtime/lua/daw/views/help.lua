-- `?`: the keys that work where the cursor is, in a picker that filters as
-- you type and runs the key chosen. `:help all` shows them as one long list.
local api = daw.api

-- `modal` sends every key to `on_key`, bypassing the mappings behind the window.
local view = { scroll = 0, lines = {}, modal = true }

local function collect(target)
  local lines = {}
  local function section(title, list)
    if #list == 0 then return end
    lines[#lines + 1] = { title = title }
    for _, map in ipairs(list) do
      local what = map.desc or (type(map.rhs) == "string" and map.rhs) or "(function)"
      lines[#lines + 1] = { key = daw.keymap.human(map.lhs), text = what }
    end
    lines[#lines + 1] = {}
  end
  local function of(mode, keep)
    local own, global = {}, {}
    for _, map in ipairs(daw.keymap.list(mode, target)) do
      if not keep or keep(map) then table.insert(map.scope == "global" and global or own, map) end
    end
    return own, global
  end
  local function plain(map) return not map.operator and not map.motion end
  local function join(a, b)
    for _, map in ipairs(b) do a[#a + 1] = map end
    return a
  end
  local own, global = of("n", plain)
  section(target .. " view", own)
  section("everywhere", global)
  section("motions: alone, after an operator, or to stretch a selection", join(of("n", function(map) return map.motion end)))
  section("operators: then a motion or text object, twice for whole rows, or on a selection", join(of("n", function(map) return map.operator end)))
  section("text objects: after an operator, or in a selection", join(of("o", function(map) return map.object end)))
  section("on a selection (v, V, <C-v>)", join(of("x", function(map) return not map.motion and not map.object and not daw.keymap.has("n", map) end)))
  section("insert mode", join(of("i")))
  return lines
end

function view:render(buf)
  local rows = buf.height - 1
  self.scroll = daw.util.clamp(self.scroll, 0, math.max(0, #self.lines - rows))
  for row = 0, rows - 1 do
    local line = self.lines[row + 1 + self.scroll]
    if line and line.title then
      buf:text(1, row, line.title, "HelpSection")
    elseif line and line.key then
      buf:text(2, row, line.key, "HelpKey")
      buf:text(16, row, line.text, "Normal")
    end
  end
  buf:text(1, buf.height - 1, "j/k scroll   any other key closes   `:` runs any command by name", "Dim")
end

function view:on_key(key)
  if key == "j" or key == "<Down>" then
    self.scroll = self.scroll + 1
  elseif key == "k" or key == "<Up>" then
    self.scroll = self.scroll - 1
  elseif key == "<C-d>" or key == "<PageDown>" then
    self.scroll = self.scroll + 10
  elseif key == "<C-u>" or key == "<PageUp>" then
    self.scroll = self.scroll - 10
  else
    daw.ui.close()
  end
  api.ui_redraw()
end

function view:on_mouse(event)
  if event.kind == "scroll_down" then self.scroll = self.scroll + 3 end
  if event.kind == "scroll_up" then self.scroll = self.scroll - 3 end
  api.ui_redraw()
end

daw.ui.view("help", view)

daw.command("help", function(ctx)
  local target = daw.ui.focused
  if ctx.args[1] == "all" then
    view.lines, view.scroll = collect(target), 0
    return daw.ui.open("help", { title = "Keys · " .. tostring(target) .. " · all", width = 76, height = 30 })
  end
  local query = ctx.args[1] and table.concat(ctx.args, " ") or nil
  daw.pick("keys", { query = query })
end, {
  desc = "Find a key for the focused view by typing part of it; Enter runs it. `help all` lists every key",
  complete = function() return { "all" } end,
})

-- A scrollable list of text lines, used for `:messages` and similar.
local pager = { scroll = 0, lines = {}, modal = true }

function pager:render(buf)
  self.scroll = daw.util.clamp(self.scroll, 0, math.max(0, #self.lines - buf.height))
  for row = 0, buf.height - 1 do
    local line = self.lines[row + 1 + self.scroll]
    if line then buf:text(1, row, line.text, line.style or "Normal") end
  end
end

pager.on_key, pager.on_mouse = view.on_key, view.on_mouse
daw.ui.view("pager", pager)

--- Show lines of text in a floating window. Each line is a string or
--- `{ text = ..., style = ... }`. With `opts.bottom` it opens at the end.
function daw.ui.page(title, lines, opts)
  pager.lines, pager.scroll = {}, opts and opts.bottom and math.huge or 0
  for _, line in ipairs(lines) do
    line = type(line) == "table" and line or { text = line }
    for part in (tostring(line.text) .. "\n"):gmatch("([^\n]*)\n") do
      pager.lines[#pager.lines + 1] = { text = part:gsub("\t", "  "), style = line.style }
    end
  end
  daw.ui.open("pager", { title = title, width = 100, height = 30 })
end
