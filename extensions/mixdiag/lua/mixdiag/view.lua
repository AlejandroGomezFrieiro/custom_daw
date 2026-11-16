-- The list of findings (when there is no picker), and the strip of marks
-- drawn above the arrange view, lined up with its timeline.
local api = daw.api
local M = {}

local styles = { error = "MixError", warn = "MixWarn", info = "MixInfo", hint = "MixHint" }
local glyphs = { error = "E", warn = "W", info = "I", hint = "H" }
local rank = { error = 1, warn = 2, info = 3, hint = 4 }

daw.ui.hl("MixError", "Error")
daw.ui.hl("MixWarn", "Warn")
daw.ui.hl("MixInfo", "Title")
daw.ui.hl("MixHint", "Dim")

-- The list ----------------------------------------------------------------------

local list = { items = {}, at = 1, scroll = 0, modal = true }

function list:render(buf)
  local rows = buf.height - 1
  if self.at < self.scroll + 1 then self.scroll = self.at - 1 end
  if self.at > self.scroll + rows then self.scroll = self.at - rows end
  if #self.items == 0 then buf:text(1, 0, "no findings", "Dim") end
  for row = 0, rows - 1 do
    local i = row + 1 + self.scroll
    local item = self.items[i]
    if not item then break end
    if i == self.at then buf:fill(0, row, buf.width, 1, " ", "Visual") end
    buf:text(1, row, item.text, styles[item.severity] or "Normal")
  end
  buf:text(1, buf.height - 1, "j/k move   Enter go there   q close", "Dim")
end

function list:on_key(key)
  if key == "j" or key == "<Down>" then
    self.at = math.min(#self.items, self.at + 1)
  elseif key == "k" or key == "<Up>" then
    self.at = math.max(1, self.at - 1)
  elseif key == "gg" or key == "g" then
    self.at = 1
  elseif key == "G" then
    self.at = #self.items
  elseif key == "<CR>" or key == "<Enter>" then
    local item = self.items[self.at]
    daw.ui.close()
    if item and item.finding then
      daw.ui.focus("arrange")
      require("mixdiag").jump(item.finding)
    end
  elseif key == "q" or key == "<Esc>" then
    daw.ui.close()
  end
  api.ui_redraw()
end

daw.ui.view("mixdiag", list)

function M.open(title, items)
  list.items, list.at, list.scroll = items, 1, 0
  local width = 40
  for _, item in ipairs(items) do width = math.max(width, api.str_width(item.text) + 4) end
  daw.ui.open("mixdiag", { title = title, width = math.min(width, 140), height = math.min(#items + 3, 30) })
end

M.list_view = list

-- The strip -----------------------------------------------------------------------

local strip = { focusable = false }

function strip:render(buf)
  local mixdiag = require("mixdiag")
  buf:fill(0, 0, buf.width, 1, " ", "Ruler")
  local arrange = daw.ui.views.arrange
  local g = arrange and arrange.geometry
  local job = mixdiag.job
  local label
  if job then
    label = string.format(" measuring %d%%", math.floor((job.progress or 0) * 100 + 0.5))
  elseif mixdiag.result then
    label = " " .. #mixdiag.findings .. (mixdiag.stale() and " (old)" or "")
  end
  if g then
    buf:text(0, 0, daw.util.fit(" mix" .. (label or ""), math.max(1, g.hw - 1)), job and "Warn" or "Dim")
    -- The most severe finding wins a column.
    local columns = {}
    for _, mark in ipairs(mixdiag.marks()) do
      local x = g.hw + math.floor((mark.beat - arrange.scroll) * g.zoom + 0.5)
      if x >= g.hw and x < buf.width and (not columns[x] or rank[mark.severity] < rank[columns[x]]) then
        columns[x] = mark.severity
      end
    end
    for x, severity in pairs(columns) do buf:text(x, 0, glyphs[severity], styles[severity]) end
  else
    buf:text(0, 0, " mix" .. (label or ""), "Dim")
  end
end

daw.ui.view("mixdiag_strip", strip)

local docked = false

function M.strip(show)
  if show and not docked then
    daw.ui.dock("mixdiag_strip", { side = "top", size = 1 })
    docked = true
  elseif show then
    daw.ui.show("mixdiag_strip")
  elseif docked then
    daw.ui.hide("mixdiag_strip")
  end
end

function M.strip_visible()
  return docked and daw.ui.visible("mixdiag_strip")
end

return M
