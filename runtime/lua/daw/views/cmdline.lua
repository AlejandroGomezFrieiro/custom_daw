-- The bottom row: a prompt while typing a command or answering a question,
-- otherwise the latest message.
local api = daw.api
local M = {}

local active      -- { prompt, chars, pos, on_submit, complete, history, index, matches, match }
local histories = {}
-- A prompt open in one seat is that seat's; the history is everyone's.
daw.seats.keep("cmdline", function() return active end, function(a) active = a end, function() return nil end)

local function text()
  return table.concat(active.chars)
end

local function set_text(value)
  active.chars = {}
  for ch in value:gmatch("[%z\1-\127\194-\244][\128-\191]*") do active.chars[#active.chars + 1] = ch end
  active.pos = #active.chars
end

local function finish(submit)
  local state, value = active, text()
  active = nil
  daw.ui.grabber = nil
  daw.keymap.set_mode("n")
  api.ui_redraw()
  if submit and state.on_submit then
    if value ~= "" and state.history[#state.history] ~= value then table.insert(state.history, value) end
    -- What the answer changes is an undo step named by the question.
    if state.label then api.undo_label(state.label) end
    state.on_submit(value)
  end
end

--- Candidates as `{ text, label, desc }`: a completer may give plain
--- strings, each the whole text it would make.
local function candidates()
  local ok, list = pcall(active.complete, text())
  local out = {}
  for _, c in ipairs(ok and type(list) == "table" and list or {}) do
    if type(c) == "table" then
      local t = tostring(c.text or c[1])
      out[#out + 1] = { text = t, label = c.label or t, desc = c.desc }
    else
      out[#out + 1] = { text = tostring(c), label = tostring(c) }
    end
  end
  return out
end

--- Work out what could finish the text as it is now; nothing is chosen yet.
local function refresh()
  if not active.complete then return end
  local matches = candidates()
  -- One candidate that is what is typed already has nothing to offer.
  if #matches == 1 and matches[1].text == text() then matches = {} end
  active.matches, active.match = matches, 0
end

--- Move through the candidates, putting the one chosen in the line.
local function complete(step)
  if not active.complete then return end
  if not active.matches then refresh() end
  local n = #active.matches
  if n == 0 then return end
  active.match = (active.match - 1 + step) % n + 1
  local matches, match = active.matches, active.match
  set_text(matches[match].text)
  active.matches, active.match = matches, match
end

local function on_key(key, pasted)
  local a = active
  if pasted then
    for ch in key:gsub("[\r\n]", " "):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      a.pos = a.pos + 1
      table.insert(a.chars, a.pos, ch)
    end
    return api.ui_redraw()
  end
  local keep_matches = false
  local chosen = a.matches and a.matches[a.match]
  if key == "<CR>" then
    -- A directory chosen from the list is gone into rather than run.
    if chosen and chosen.label:match("/$") then
      refresh()
      return api.ui_redraw()
    end
    return finish(true)
  elseif key == "<Esc>" or key == "<C-c>" then
    return finish(false)
  elseif key == "<Tab>" or key == "<S-Tab>" or key == "<C-n>" or key == "<C-p>"
    or (chosen and (key == "<Down>" or key == "<Up>")) then
    complete((key == "<Tab>" or key == "<C-n>" or key == "<Down>") and 1 or -1)
    keep_matches = true
  elseif key == "<BS>" then
    if #a.chars == 0 then return finish(false) end
    if a.pos > 0 then
      table.remove(a.chars, a.pos)
      a.pos = a.pos - 1
    end
  elseif key == "<Del>" then
    table.remove(a.chars, a.pos + 1)
  elseif key == "<Left>" then
    a.pos = math.max(0, a.pos - 1)
  elseif key == "<Right>" then
    a.pos = math.min(#a.chars, a.pos + 1)
  elseif key == "<Home>" or key == "<C-a>" then
    a.pos = 0
  elseif key == "<End>" or key == "<C-e>" then
    a.pos = #a.chars
  elseif key == "<C-u>" then
    set_text("")
  elseif key == "<C-w>" then
    while a.pos > 0 and a.chars[a.pos] == " " do
      table.remove(a.chars, a.pos)
      a.pos = a.pos - 1
    end
    while a.pos > 0 and a.chars[a.pos] ~= " " do
      table.remove(a.chars, a.pos)
      a.pos = a.pos - 1
    end
  elseif key == "<Up>" or key == "<Down>" then
    local h = a.history
    a.index = daw.util.clamp((a.index or #h + 1) + (key == "<Up>" and -1 or 1), 1, #h + 1)
    set_text(h[a.index] or "")
  else
    local ch = key == "<Space>" and " " or key == "<lt>" and "<" or key
    if not ch:match("^<.+>$") then
      a.pos = a.pos + 1
      table.insert(a.chars, a.pos, ch)
    end
  end
  if not keep_matches then
    a.matches = nil
    -- The list follows what is typed, once there is something typed.
    if a.complete and #a.chars > 0 and key ~= "<Up>" and key ~= "<Down>" then refresh() end
  end
  api.ui_redraw()
end

--- Start a prompt. `opts`: `prompt`, `text` (initial), `complete(text)` which
--- returns what the text could become, and `history` (a name; prompts with
--- the same name share their history), `label` (what the undo step the
--- answer makes is called; by default the prompt). Candidates are strings, or
--- `{ text = whole line, label = the part shown, desc = ... }`. They are
--- listed above the prompt as it is typed; Tab and Shift-Tab (or Ctrl-n,
--- Ctrl-p) choose one into the line, Enter runs the line.
function M.open(opts, on_submit)
  opts = opts or {}
  local name = opts.history or opts.prompt or ""
  histories[name] = histories[name] or {}
  active = {
    prompt = opts.prompt or "", on_submit = on_submit, complete = opts.complete,
    label = opts.label or (opts.prompt or ""):match("^(%a[^:]*%a)"),
    history = histories[name], chars = {}, pos = 0,
  }
  set_text(opts.text or "")
  daw.ui.grabber = on_key
  daw.keymap.set_mode("c")
  api.ui_redraw()
end

--- The prompt that is open, for a frontend that draws its own: what it asks,
--- the text so far, and how many characters of it are before the cursor.
function M.state()
  if not active then return nil end
  return {
    prompt = active.prompt, before = table.concat(active.chars, "", 1, active.pos),
    after = table.concat(active.chars, "", active.pos + 1),
    matches = active.matches, match = active.match,
  }
end

local MAX_ROWS = 10

--- A description in the list: its first line, without the examples.
local function brief(desc)
  return (desc:match("^[^\n]*"):gsub(":? `.*$", ""))
end

--- The list of candidates, over the bottom of the screen just above the
--- command line, starting under the word they complete.
function M.draw_popup(buf)
  local a = active
  if not (a and a.matches and #a.matches > 0) then return end
  local n = #a.matches
  local rows = math.min(MAX_ROWS, n, buf.height - 2)
  if rows < 1 then return end
  local top = 1
  if a.match > rows then top = a.match - rows + 1 end
  local label_w, desc_w = 0, 0
  for i = top, top + rows - 1 do
    local c = a.matches[i]
    label_w = math.max(label_w, api.str_width(c.label))
    if c.desc and c.desc ~= "" then desc_w = math.max(desc_w, api.str_width(brief(c.desc))) end
  end
  label_w = math.min(label_w, math.max(8, math.floor(buf.width / 2) - 4))
  desc_w = math.min(desc_w, 56)
  local width = 2 + label_w + (desc_w > 0 and 2 + desc_w or 0) + 2
  width = math.min(width, buf.width)
  desc_w = math.max(0, width - 2 - label_w - 2 - 2)
  -- Under the start of the word being completed.
  local current = a.matches[math.max(1, a.match)]
  local offset = api.str_width(current.text) - api.str_width(current.label)
  if a.match == 0 then
    -- Nothing chosen yet: the typed text is a prefix of what it completes.
    offset = math.min(offset, api.str_width(text()))
  end
  local x = api.str_width(a.prompt) + math.max(0, offset) - 2
  x = math.max(0, math.min(x, buf.width - width))
  local y = buf.height - 1 - rows
  for row = 0, rows - 1 do
    local i = top + row
    local c = a.matches[i]
    local sel = i == a.match
    buf:fill(x, y + row, width, 1, " ", sel and "PmenuSel" or "Pmenu")
    if sel then buf:text(x, y + row, "▶", "PmenuSel") end
    buf:text(x + 2, y + row, daw.util.fit(c.label, label_w), sel and "PmenuSel" or "Pmenu")
    if desc_w > 0 and c.desc then
      buf:text(x + 2 + label_w + 2, y + row, daw.util.fit(brief(c.desc), desc_w), sel and "PmenuSelDesc" or "PmenuDesc")
    end
  end
  -- More than fit: a thumb on the right edge says where in the list this is.
  if n > rows then
    local size = math.max(1, math.floor(rows * rows / n))
    local at = math.floor((top - 1) / (n - rows) * (rows - size) + 0.5)
    for row = 0, rows - 1 do
      buf:text(x + width - 1, y + row, (row >= at and row < at + size) and "┃" or "│", "PmenuThumb")
    end
  end
end
daw.ui.draw_popup = M.draw_popup

--- Read a typed value against the one there is now: `6` or `=6` is 6, and
--- `+2` or `-3` are steps from `now`. `parse(text)` reads one absolute
--- value (default: a number, with any unit after it ignored). Nil when the
--- text says nothing usable.
function M.read_value(text, now, parse)
  parse = parse or function(t) return tonumber((t:match("^%s*([%+%-]?[%d%.]+)"))) end
  text = text:match("^%s*(.-)%s*$")
  if text == "" then return nil end
  local sign, rest = text:match("^([%+%-])%s*(.+)$")
  if sign then
    local by = parse(rest)
    if not by then return nil end
    return now + (sign == "-" and -by or by)
  end
  return parse((text:gsub("^=%s*", "")))
end

--- Ask for an exact value on the command line: a number, `+2` and `-3` to
--- step from the value now, `=-6` for a value below zero.
---   daw.ui.ask_value({ label = "Volume", now = -8, unit = "dB", min = -60, max = 12 }, function(v) ... end)
--- Options: `show(value)` for how the value now is written, `parse(text)`
--- for reading one absolute value, `min` and `max` to keep it within.
function M.ask_value(opts, set)
  local now = opts.now
  local shown = opts.show and opts.show(now) or (string.format("%g", now) .. (opts.unit and opts.unit ~= "" and " " .. opts.unit or ""))
  M.open({ prompt = string.format("%s %s → (6, +2, -3, =-6): ", opts.label, shown), history = "value",
    label = "Set " .. opts.label }, function(text)
    local value = M.read_value(text, now, opts.parse)
    if not value then return daw.notify("not a value: `" .. text .. "`", "warn") end
    if opts.min then value = math.max(opts.min, value) end
    if opts.max then value = math.min(opts.max, value) end
    set(value)
  end)
end
daw.ui.ask_value = M.ask_value

local levels = { info = "Info", warn = "Warn", error = "Error" }

-- An error stays mentioned on the key line until the messages are looked
-- at, or for a minute.
local ERROR_SHOWN = 60000
local seen_at = 0

--- The last error, if it has not been read in the messages since.
function M.unread_error()
  local list = daw.ui.messages
  for i = #list, math.max(1, #list - 50), -1 do
    local m = list[i]
    if m.level == "error" then
      if m.time > seen_at and api.now() - m.time < ERROR_SHOWN then return m end
      return nil
    end
  end
end

--- How to see every message: the key for the messages, and the command.
function M.messages_hint()
  for _, map in ipairs(daw.keymap.list("n")) do
    if map.rhs == "pick.messages" or map.rhs == "messages" then return daw.keymap.human(map.lhs) .. " or :messages" end
  end
  return ":messages"
end

daw.on("command.pre", function(e)
  if e.command == "messages" or e.command == "pick.messages" then seen_at = api.now() end
end)

daw.ui.view("cmdline", {
  focusable = false,
  render = function(_, buf, ctx)
    if active then
      local used = buf:text(0, 0, active.prompt, "Accent")
      buf:text(used, 0, text(), "Normal")
      local before = table.concat(active.chars, "", 1, active.pos)
      api.ui_cursor(ctx.x + used + api.str_width(before), ctx.y)
      return
    end
    local pending = daw.keymap.pending()
    if pending ~= "" then buf:text(buf.width - #pending - 2, 0, pending, "Accent") end
    local message = daw.ui.message
    if message then
      local first = message.text:match("^[^\n]*")
      local how = M.messages_hint()
      local more = (message.text:find("\n") or message.level == "error") and ("  " .. how .. " shows it all") or ""
      local room = math.max(10, buf.width - api.str_width(more) - 1)
      local used = buf:text(0, 0, api.str_width(first) > room and daw.util.fit(first, room) or first, levels[message.level] or "Info")
      if more ~= "" then buf:text(used, 0, more, "Dim") end
    elseif daw.opt.keybar and pending == "" then
      -- With nothing to say, the line shows the keys worth knowing here,
      -- and a word on how to read an error that has gone by unread.
      -- The note goes at the right end, the keys keep their places.
      local room = buf.width - 2
      if M.unread_error() then
        -- Short, so that the keys keep their room: the key, and what it shows.
        local key = M.messages_hint():match("^(%S+) or ") or ":messages"
        local w = api.str_width(key) + 12
        local x = buf.width - w
        x = x + buf:text(x, 0, key, "KeyBarKey") + 1
        buf:text(x, 0, "last error", "Error")
        room = buf.width - w - 3
      end
      daw.draw.keys(buf, 1, 0, daw.ui.keybar.entries(), room)
    end
  end,
})

return M
