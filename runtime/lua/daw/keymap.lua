-- Key mappings and modal editing, with Neovim's notation and grammar.
--
-- A mapping belongs to a mode and optionally to a view; a view's mappings win
-- over global ones while that view has focus. The right hand side is a
-- command line (`"track.mute"`) or a function.
--
--   mode   what it is                      how mappings get there
--   n      normal                          `set` (the default)
--   x      visual: a selection is open     `set` with `mode = "x"`; motions, operators
--   o      an operator waits for a motion  motions and text objects
--   i      insert: keys enter material     `set` with `mode = "i"`
--   c      a prompt has the keyboard       (not mapped)
--
-- Three kinds of mapping make up the grammar. A *motion* moves the cursor. An
-- *operator* acts on a region: after `d` the next motion or text object says
-- which, `dd` means whole rows, and in visual mode it is the selection. A
-- *text object* names a region outright, such as the clip under the cursor.
-- Counts (`3w`, `2dd`), registers (`"ayy`), `.`, macros and marks work on any
-- of them, so an extension that adds one operator gets all of that with it.
--
-- A view takes part by having a `grid`: `get()` returns the cursor as a row
-- and a column in beats, and `set(row, col)` moves it. See `daw.edit` for the
-- regions the built-in views work on.
local api = daw.api
local M = {}

local maps = {}     -- mode -> scope -> lhs -> mapping
local pending = {}  -- keys typed so far of an unfinished sequence
local count         -- number typed before the sequence
local register      -- register named with `"x` for the next command
local op            -- the operator waiting for a motion: { map, count, register, key }
local awaiting      -- function that takes the next key, whatever it is
local timer
local hint_at       -- when to start listing the keys that can follow

local track = {}    -- the command being typed: { keys, edits, norepeat }
local last_change   -- the keys of the last command that changed the project
local replaying     -- `.` is running: its keys are not a new change
local depth = 0     -- how many replays (macros, `.`) are running inside each other
local macro         -- { name, keys } while recording
local last_macro

local registers = {}
local marks, jumps = {}, {}

M.mode = "n"
M.visual = nil      -- the open selection's fixed end: { kind, row, col, view }
M.registers = registers

-- Everything above but the mappings is each seat's own: two people can be
-- half way through two commands, in two modes, with registers of their own.
daw.seats.keep("keymap",
  function()
    return pending, count, register, op, awaiting, timer, hint_at, track, last_change, macro, last_macro,
      registers, marks, jumps, M.mode, M.visual, M.last_visual, M.search_text
  end,
  function(...)
    pending, count, register, op, awaiting, timer, hint_at, track, last_change, macro, last_macro,
      registers, marks, jumps, M.mode, M.visual, M.last_visual, M.search_text = ...
    M.registers = registers
  end,
  function() return {}, nil, nil, nil, nil, nil, nil, {}, nil, nil, nil, {}, {}, {}, "n", nil, nil, nil end)

--- Split `gg<C-x>` into { "g", "g", "<C-x>" }, expanding `<leader>`.
function M.parse(lhs)
  local keys = {}
  local expanded = lhs:gsub("<[Ll]eader>", function() return daw.opt.leader end)
  local pos = 1
  while pos <= #expanded do
    local special = expanded:match("^<[%w%-]+>", pos)
    local key = special or expanded:match("^[%z\1-\127\194-\244][\128-\191]*", pos)
    keys[#keys + 1] = key
    pos = pos + #key
  end
  return keys
end

local key_names = {
  CR = "Enter", Enter = "Enter", Return = "Enter", Space = "Space", Esc = "Esc", BS = "Backspace",
  Del = "Delete", Tab = "Tab", lt = "<", Bar = "|", Bslash = "\\", Up = "Up", Down = "Down",
  Left = "Left", Right = "Right", Home = "Home", End = "End", PageUp = "PageUp", PageDown = "PageDown",
}
local modifier_names = { C = "Ctrl", A = "Alt", M = "Alt", S = "Shift", D = "Super" }

--- Keys as a person writes them: `<A-h>` is `Alt-h`, `<leader>at` is `,at`,
--- `<C-w>o` is `Ctrl-w o`, `<CR>` is `Enter`. Takes an lhs or a list of keys.
function M.human(keys)
  if type(keys) == "string" then keys = M.parse(keys) end
  local out, prev_word = {}, false
  for i, key in ipairs(keys) do
    local inner = key:match("^<(.+)>$")
    local text, word = key, false
    if inner then
      local mods = ""
      while inner:match("^%a%-.") do
        local m = inner:sub(1, 1):upper()
        mods = mods .. (modifier_names[m] or m) .. "-"
        inner = inner:sub(3)
      end
      text = mods .. (key_names[inner] or inner)
      -- `<lt>` alone is a plain character; anything else is a word of its own.
      word = mods ~= "" or #text > 1
    end
    if i > 1 and (word or prev_word) then out[#out + 1] = " " end
    out[#out + 1] = text
    prev_word = word
  end
  return table.concat(out)
end

--- Every mapping that can be typed while `view` has focus, each once:
--- normal mode, then what only a selection, an operator or insert mode
--- takes. Each comes with `kind`: "key", "motion", "operator", "object",
--- "visual" or "insert".
function M.all(view)
  local out = {}
  local shadowed = {}   -- mode .. keys the part of the view takes over
  -- A part of the view the cursor is in comes first: its keys win.
  if view == daw.ui.focused then
    local sub = M.scopes()
    for i = 1, #sub - 2 do
      for _, mode in ipairs({ "n", "x", "i" }) do
        local list = {}
        for _, map in pairs(maps[mode] and maps[mode][sub[i]] or {}) do list[#list + 1] = map end
        table.sort(list, function(a, b) return a.lhs:lower() .. a.lhs < b.lhs:lower() .. b.lhs end)
        for _, map in ipairs(list) do
          if not shadowed[mode .. table.concat(map.keys)] and (mode ~= "x" or not M.has("n", map)) then
            local kind = mode == "x" and "visual" or mode == "i" and "insert" or map.motion and "motion" or "key"
            out[#out + 1] = { map = map, kind = kind }
          end
          shadowed[mode .. table.concat(map.keys)] = true
        end
      end
    end
  end
  for _, map in ipairs(M.list("n", view)) do
    if not shadowed["n" .. table.concat(map.keys)] then
      out[#out + 1] = { map = map, kind = map.operator and "operator" or map.motion and "motion" or "key" }
    end
  end
  for _, map in ipairs(M.list("x", view)) do
    if not shadowed["x" .. table.concat(map.keys)] and not map.motion and not map.object and not M.has("n", map) then out[#out + 1] = { map = map, kind = "visual" } end
  end
  for _, map in ipairs(M.list("o", view)) do
    if map.object then out[#out + 1] = { map = map, kind = "object" } end
  end
  for _, map in ipairs(M.list("i", view)) do
    if not shadowed["i" .. table.concat(map.keys)] then out[#out + 1] = { map = map, kind = "insert" } end
  end
  return out
end

--- Map keys.
---   daw.keymap.set("M", "track.mute", { desc = "Mute track" })
---   daw.keymap.set("<leader>x", function(ctx) ... end, { view = "arrange" })
--- `ctx` has `count`, `register` and, for mappings made with `char = true`,
--- the key typed after the mapping as `char`.
---
--- Options: `mode` (one or a list, default "n"), `view`, `desc`;
--- `motion = true` for a mapping that only moves the cursor, which makes it
--- work in visual mode and after an operator as well; `linewise = true` for a
--- motion across rows; `jump = true` to remember where the cursor was for
--- `<C-o>`; `repeatable = false` to keep `.` from repeating it.
function M.set(lhs, rhs, opts)
  opts = opts or {}
  local default = opts.motion and { "n", "x", "o" } or { "n" }
  local modes = type(opts.mode) == "table" and opts.mode or opts.mode and { opts.mode } or default
  local scope = opts.view or "global"
  local keys = M.parse(lhs)
  for _, mode in ipairs(modes) do
    if mode == "v" then mode = "x" end
    maps[mode] = maps[mode] or {}
    maps[mode][scope] = maps[mode][scope] or {}
    local map = { lhs = lhs, keys = keys, rhs = rhs, mode = mode, scope = scope }
    for name, value in pairs(opts) do
      if name ~= "mode" and name ~= "view" then map[name] = value end
    end
    map.norepeat = opts.repeatable == false
    maps[mode][scope][table.concat(keys)] = map
  end
end

--- Define an operator: `fn(region, ctx)` acts on a region of the focused
--- view. A region has `r0`, `r1` (rows, inclusive), `c0`, `c1` (beats, the
--- end not included) and `kind`: "char" for a stretch of time, "line" for
--- whole rows, "block" for a rectangle.
---   daw.keymap.operator("gl", function(region) ... end, { view = "arrange", desc = "Loop" })
function M.operator(lhs, fn, opts)
  M.set(lhs, nil, daw.util.merge(opts or {}, { mode = { "n", "x" }, operator = fn }))
end

--- Define a text object: `fn(ctx)` returns a region, or nil when there is
--- nothing of that kind at the cursor.
---   daw.keymap.textobject("ic", function() ... end, { view = "arrange", desc = "The clip" })
function M.textobject(lhs, fn, opts)
  M.set(lhs, nil, daw.util.merge(opts or {}, { mode = { "o", "x" }, object = fn }))
end

function M.del(lhs, opts)
  opts = opts or {}
  local scope = maps[opts.mode or "n"] and maps[opts.mode or "n"][opts.view or "global"]
  if scope then scope[table.concat(M.parse(lhs))] = nil end
end

--- Mappings that apply in `mode` for `view`, the view's own first.
function M.list(mode, view)
  local out = {}
  for _, scope in ipairs({ view or false, "global" }) do
    local list = {}
    for _, map in pairs(scope and maps[mode] and maps[mode][scope] or {}) do list[#list + 1] = map end
    table.sort(list, function(a, b) return a.lhs:lower() .. a.lhs < b.lhs:lower() .. b.lhs end)
    for _, map in ipairs(list) do out[#out + 1] = map end
  end
  return out
end

--- Whether a mapping is also made, with the same keys and scope, in `mode`.
function M.has(mode, map)
  local scope = maps[mode] and maps[mode][map.scope]
  return scope ~= nil and scope[table.concat(map.keys)] ~= nil
end

local function grid()
  local view = daw.ui.views[daw.ui.focused]
  return view and view.grid
end

local function stop_timer()
  if timer then
    api.timer_stop(timer)
    timer = nil
  end
end

--- Change mode. Leaving visual mode closes the selection; `gv` reopens it.
function M.set_mode(mode)
  if mode == "v" then mode = "x" end
  local old = M.mode
  if M.visual and mode ~= "x" and mode ~= "c" then
    local g = grid()
    if g and M.visual.view == daw.ui.focused then
      local row, col = g.get()
      M.last_visual = daw.util.merge(M.visual, { cursor_row = row, cursor_col = col })
    end
    M.visual = nil
  end
  if mode == old then return end
  M.mode = mode
  daw.emit("mode.changed", { mode = mode, old = old })
  api.ui_redraw()
end

local function reset()
  pending, count, register, awaiting, hint_at = {}, nil, nil, nil, nil
  stop_timer()
  if op then
    op = nil
    M.set_mode("n")
  end
  api.ui_redraw()
end

local function region(r, c, r2, c2, kind)
  return {
    view = daw.ui.focused, kind = kind,
    r0 = math.min(r, r2), r1 = math.max(r, r2), c0 = math.min(c, c2), c1 = math.max(c, c2),
  }
end

--- The row a region starts on: rows count downwards in most views, upwards
--- (`grid.down = -1`) in the piano roll.
local function first_row(g, reg)
  return g.down == -1 and reg.r1 or reg.r0
end

--- Start selecting from the cursor: "v" a stretch of time, "V" whole rows,
--- "b" a rectangle. The same kind again leaves visual mode.
function M.visual_start(kind)
  local g = grid()
  if not g then return daw.notify("nothing to select in this view", "warn") end
  if M.visual and M.visual.kind == kind then return M.set_mode("n") end
  if M.visual then
    M.visual.kind, M.visual.region = kind, nil
    return api.ui_redraw()
  end
  local row, col = g.get()
  M.visual = { kind = kind, row = row, col = col, view = daw.ui.focused }
  M.set_mode("x")
end

--- Open the last selection again.
function M.visual_restore()
  local g, last = grid(), M.last_visual
  if not (g and last and last.view == daw.ui.focused) then return end
  M.visual = { kind = last.kind, row = last.row, col = last.col, view = last.view }
  g.set(last.cursor_row, last.cursor_col)
  M.set_mode("x")
end

--- Swap the cursor with the selection's other end.
function M.visual_swap()
  local g, v = grid(), M.visual
  if not (g and v) then return end
  local row, col = g.get()
  g.set(v.row, v.col)
  v.row, v.col = row, col
end

--- The region selected in the focused view, or nil outside visual mode. From
--- the cursor to where the selection began; a selection that has not been
--- stretched yet covers one grid step.
function M.selection()
  local v, g = M.visual, grid()
  if not (v and g) or v.view ~= daw.ui.focused then return nil end
  -- Clips chosen one by one with the pointer: the region they span, which
  -- names them (`clips`), and is not stretched by the cursor.
  if v.region then
    local out = v.region()
    if out then out.visual, out.view = true, v.view end
    return out
  end
  local row, col = g.get()
  local out = region(v.row, v.col, row, col, v.kind == "V" and "line" or v.kind == "b" and "block" or "char")
  out.visual = true
  if out.c1 - out.c0 < 1e-9 then
    out.c1 = out.c0 + g.step()
    out.unstretched = true
  end
  return out
end

-- Registers -------------------------------------------------------------------

--- Put a value in a register: the unnamed one, and `name` if given. With
--- `yank` and no name it also goes to `"0`, which deleting never touches.
--- A value is a table with a `kind`; what else it holds is up to whoever
--- yanks and pastes it. `"_` discards.
function M.setreg(value, name, yank)
  if name == "_" then return end
  registers['"'] = value
  if name and name ~= '"' then registers[name:lower()] = value end
  if yank and not name then registers["0"] = value end
end

function M.getreg(name)
  return registers[name and name:lower() or '"']
end

-- Marks and jumps -------------------------------------------------------------

local function position(g)
  if g.mark then return g.mark() end
  local row, col = g.get()
  return { row, col }
end

local function go(g, pos)
  if g.jump then return g.jump(pos) end
  g.set(pos[1], pos[2])
end

local function same(a, b)
  for k, v in pairs(a) do
    if b[k] ~= v then return false end
  end
  return true
end

--- Remember where the cursor is before it goes somewhere far away.
function M.push_jump()
  local g = grid()
  if not g then return end
  local list = jumps[daw.ui.focused] or {}
  jumps[daw.ui.focused] = list
  if list.at then
    for i = #list, list.at + 1, -1 do list[i] = nil end
    list.at = nil
  end
  local here = position(g)
  if list[#list] and same(list[#list], here) then return end
  list[#list + 1] = here
  if #list > 100 then table.remove(list, 1) end
end

--- Go back (or with a negative `n` forward again) through the places jumped from.
function M.jump(n)
  local g, list = grid(), jumps[daw.ui.focused]
  if not (g and list) or #list == 0 then return end
  if not list.at then
    local here = position(g)
    if not same(list[#list], here) then list[#list + 1] = here end
    list.at = #list
  end
  list.at = daw.util.clamp(list.at - n, 1, #list)
  go(g, list[list.at])
end

function M.mark(name)
  local g = grid()
  if not g or not name:match("^%a$") then return end
  marks[daw.ui.focused] = marks[daw.ui.focused] or {}
  marks[daw.ui.focused][name] = position(g)
end

--- Move to a mark; `'` or a backtick as the name goes back to where the last
--- jump came from.
function M.goto_mark(name)
  local g = grid()
  if not g then return end
  if name == "'" or name == "`" then
    local list = jumps[daw.ui.focused]
    if not list or #list == 0 then return end
    local here = position(g)
    go(g, list[#list])
    list[#list], list.at = here, nil
    return
  end
  local pos = marks[daw.ui.focused] and marks[daw.ui.focused][name]
  if not pos then return daw.notify("mark `" .. name .. "` is not set", "warn") end
  M.push_jump()
  go(g, pos)
end

--- Remove marks from every view, as Vim's `:delmarks` does: `spec` lists
--- letters and ranges (`"a b"`, `"a-d"`), and `all` removes every lowercase
--- one. Returns how many were removed, or nil and what is wrong.
function M.delmarks(spec, all)
  local names = {}
  if all then
    for c = ("a"):byte(), ("z"):byte() do names[#names + 1] = string.char(c) end
  else
    spec = spec:gsub("%s+", "")
    local i = 1
    while i <= #spec do
      local first, dash, last = spec:sub(i, i), spec:sub(i + 1, i + 1), spec:sub(i + 2, i + 2)
      if not first:match("^%a$") then return nil, "`" .. first .. "` is not a mark name" end
      if dash == "-" then
        if not last:match("^%a$") or last:byte() < first:byte() or (last:match("%l") == nil) ~= (first:match("%l") == nil) then
          return nil, "`" .. spec:sub(i, i + 2) .. "` is not a range of marks"
        end
        for c = first:byte(), last:byte() do names[#names + 1] = string.char(c) end
        i = i + 3
      else
        names[#names + 1] = first
        i = i + 1
      end
    end
  end
  local removed = 0
  for _, name in ipairs(names) do
    for _, list in pairs(marks) do
      if list[name] then list[name], removed = nil, removed + 1 end
    end
  end
  return removed
end

--- The marks of a view: name -> position.
function M.marks(view)
  return marks[view or daw.ui.focused] or {}
end

-- Search ----------------------------------------------------------------------

--- Move to the next (`dir` 1) or previous (-1) thing in the focused view that
--- matches the last search. Views say what matches through `grid.search`.
function M.search_next(dir, n)
  local g = grid()
  if not (g and g.search) then return end
  if not M.search_text then return daw.notify("nothing searched for yet: `/`", "warn") end
  local hits = g.search(M.search_text)
  if #hits == 0 then return daw.notify("nothing matches `" .. M.search_text .. "`", "warn") end
  table.sort(hits, function(a, b)
    if a.col ~= b.col then return a.col < b.col end
    return a.row < b.row
  end)
  local row, col = g.get()
  for _ = 1, n or 1 do
    local found
    if dir > 0 then
      for _, hit in ipairs(hits) do
        if hit.col > col + 1e-9 or (math.abs(hit.col - col) < 1e-9 and hit.row > row) then
          found = hit
          break
        end
      end
      found = found or hits[1]
    else
      for i = #hits, 1, -1 do
        local hit = hits[i]
        if hit.col < col - 1e-9 or (math.abs(hit.col - col) < 1e-9 and hit.row < row) then
          found = hit
          break
        end
      end
      found = found or hits[#hits]
    end
    row, col = found.row, found.col
  end
  g.set(row, col)
end

function M.search(text, dir)
  M.search_text = text
  M.search_next(dir or 1)
end

-- Running mappings --------------------------------------------------------------

local function exec(map, ctx)
  -- The key's description names the undo step it makes. Keys that replay
  -- others (`.`, `@a`) leave the name to what they replay.
  if map.desc and not map.norepeat then api.undo_label(map.desc) end
  if type(map.rhs) == "function" then
    return daw.limit.named("the key " .. M.human(map.lhs) .. (map.desc and " (" .. map.desc .. ")" or ""), map.rhs, ctx)
  end
  return daw.commands.exec(map.rhs, ctx)
end

local function times(a, b)
  if a or b then return (a or 1) * (b or 1) end
end

local function run(map, char)
  local ctx = { count = count, register = register, keys = map.lhs, char = char, mode = M.mode }
  local g = grid()
  pending, count, register, hint_at = {}, nil, nil, nil
  stop_timer()
  if map.norepeat then track.norepeat = true end

  if M.mode == "o" then
    -- A motion or text object, for the operator that was waiting for one.
    local o = op
    op = nil
    M.set_mode("n")
    if o.map.desc then api.undo_label(o.map.desc) end
    ctx.count, ctx.register = times(o.count, ctx.count), o.register
    local r, c = g.get()
    local reg
    if map.object then
      reg = map.object(ctx)
    else
      exec(map, ctx)
      local r2, c2 = g.get()
      if not map.linewise and r == r2 and c == c2 then return end
      reg = region(r, c, r2, c2, map.linewise and "line" or "char")
    end
    if not reg then return end
    -- The cursor ends up where the region starts.
    if reg.kind == "line" then g.set(first_row(g, reg), c) else g.set(r, reg.c0) end
    return o.map.operator(reg, ctx)
  end

  if map.operator then
    if M.mode == "x" then
      local reg = M.selection()
      local _, col = g.get()
      M.set_mode("n")
      if not reg then return end
      if map.desc then api.undo_label(map.desc) end
      if reg.kind == "line" then g.set(first_row(g, reg), col) else g.set(first_row(g, reg), reg.c0) end
      return map.operator(reg, ctx)
    end
    if not g then return daw.notify("nothing in this view for `" .. map.lhs .. "` to act on", "warn") end
    op = { map = map, count = ctx.count, register = ctx.register, key = map.keys[#map.keys] }
    return M.set_mode("o")
  end

  if map.object then
    -- In visual mode a text object becomes the selection.
    local reg = map.object(ctx)
    if reg and M.visual then
      M.visual.row, M.visual.col, M.visual.region = reg.r0, reg.c0, nil
      if reg.kind == "line" then
        M.visual.kind = "V"
      elseif reg.kind == "block" then
        M.visual.kind = "b"
      elseif M.visual.kind == "V" then
        M.visual.kind = "v"
      end
      g.set(reg.r1, reg.c1)
    end
    return
  end

  if map.jump then M.push_jump() end
  return exec(map, ctx)
end

--- Where mappings are looked up, first to last: the part of the focused
--- view the cursor is in, if the view has such parts (`view:subscope()`,
--- such as "arrange.lane" on an automation lane row, or a list of them,
--- first first), the view, then everywhere.
local function scopes()
  local name = daw.ui.focused
  local view = name and daw.ui.views[name]
  local out = {}
  if view and view.subscope then
    local ok, sub = pcall(view.subscope, view)
    if ok and type(sub) == "table" then
      for _, s in ipairs(sub) do out[#out + 1] = s end
    elseif ok and sub then
      out[#out + 1] = sub
    end
  end
  if name then out[#out + 1] = name end
  out[#out + 1] = "global"
  return out
end
M.scopes = scopes

--- The mapping for exactly `seq`, and whether a longer mapping starts with it.
local function lookup(seq)
  local exact, longer
  for _, scope in ipairs(scopes()) do
    local scoped = scope and maps[M.mode] and maps[M.mode][scope]
    for lhs, map in pairs(scoped or {}) do
      if lhs == seq then
        exact = exact or map
      elseif lhs:sub(1, #seq) == seq then
        longer = true
      end
    end
  end
  return exact, longer
end

--- Whether a part of the focused view (not the view itself, nor the global
--- mappings) maps `key` in this mode.
local function held(key)
  local list = scopes()
  for i = 1, #list - 2 do
    if maps[M.mode] and maps[M.mode][list[i]] and maps[M.mode][list[i]][key] then return true end
  end
  return false
end

local function idle()
  return M.mode == "n" and #pending == 0 and not count and not register and not op and not awaiting
    and not daw.ui.grabber
end

-- Changes made outside the project that `.` repeats too: a text buffer's.
local changes = 0

--- Note a change that is not an edit of the project (a text buffer's
--- lines), so that `.` repeats the command that made it.
function M.changed() changes = changes + 1 end

local function edits() return api.project_get().edits + changes end

--- Once a command is complete, remember it for `.` if it changed the project.
local function finish_command()
  if not idle() then return end
  if track.keys and not track.norepeat and not replaying and edits() ~= track.edits then
    last_change = track.keys
  end
  track = {}
end

--- Run a mapping, or wait for the key it wants first (`ma`, `"ayy`, `@q`).
local function take(map)
  if not map.char then return run(map) end
  awaiting = function(key)
    if key == "<Esc>" or key == "<C-c>" then return reset() end
    run(map, key == "<Space>" and " " or key == "<lt>" and "<" or key)
  end
end

local handle

--- Handle one key press.
handle = function(key)
  if daw.ui.grabber then return daw.ui.grabber(key) end
  local focused = daw.ui.views[daw.ui.focused]
  if focused and focused.modal then return focused:on_key(key) end
  if awaiting then
    local fn = awaiting
    awaiting = nil
    return fn(key)
  end

  local escape = key == "<Esc>" or key == "<C-c>"
  if escape and (#pending > 0 or count or register or op) then return reset() end
  -- Escape leaves visual and insert mode, unless something that holds keys
  -- for a while (a suggestion showing: see `view:subscope()`) maps it first.
  if escape and (M.mode == "x" or M.mode == "i") and not held(key) then return M.set_mode("n") end

  if #pending == 0 and M.mode ~= "i" then
    if key:match("^%d$") and (count or key ~= "0") then
      count = (count or 0) * 10 + tonumber(key)
      return api.ui_redraw()
    end
    if key == '"' then
      awaiting = function(name)
        if name:match('^[%w_"]$') then register = name else reset() end
      end
      return
    end
    -- While a macro is being recorded, the key that started it ends it.
    if macro and (M.mode == "n" or M.mode == "x") then
      local map = lookup(key)
      if map and map.record then
        macro.keys[#macro.keys] = nil
        registers[macro.name] = { kind = "keys", keys = table.concat(macro.keys) }
        daw.notify("recorded @" .. macro.name)
        macro = nil
        return api.ui_redraw()
      end
    end
    -- The operator's own key again: whole rows, as many as the count.
    if M.mode == "o" and key == op.key then
      local o, g = op, grid()
      local n = times(o.count, count) or 1
      op, count = nil, nil
      M.set_mode("n")
      local row, col = g.get()
      local reg = region(row, col, row + (n - 1) * (g.down or 1), col, "line")
      if o.map.desc then api.undo_label(o.map.desc) end
      return o.map.operator(reg, { count = n, register = o.register, keys = o.map.lhs .. key })
    end
  end

  pending[#pending + 1] = key
  local exact, longer = lookup(table.concat(pending))
  stop_timer()

  if exact and not longer then
    return take(exact)
  elseif longer then
    -- Wait for the rest. Only when what was typed is a mapping already does
    -- the wait end by itself, in favour of that one; a bare prefix stays
    -- until it is finished or Escape drops it.
    if exact then
      timer = api.timer_start(daw.opt.timeoutlen, false, function()
        timer = nil
        take(exact)
        finish_command()
      end)
    end
  elseif #pending > 1 then
    -- The sequence led nowhere. Run the longest mapping it began with, if
    -- there is one, and take what was typed after it as new keys.
    local keys, n, found = pending, #pending - 1, nil
    while n >= 1 and not found do
      found = lookup(table.concat(keys, "", 1, n))
      if not found then n = n - 1 end
    end
    if found then
      pending = {}
      take(found)
    elseif M.mode == "o" then
      return reset()
    else
      reset()
      n = #keys - 1
    end
    for i = n + 1, #keys do handle(keys[i]) end
  else
    local mode = M.mode
    reset()
    if mode ~= "n" then return end
    local view = daw.ui.views[daw.ui.focused]
    if key == "<Esc>" then
      daw.emit("escape", {})
    elseif view and view.on_key then
      view:on_key(key)
    end
  end
end

function M.dispatch(key)
  if macro and depth == 0 then macro.keys[#macro.keys + 1] = key end
  if not track.keys then track.keys, track.edits = {}, edits() end
  track.keys[#track.keys + 1] = key
  local ok, err = xpcall(handle, debug.traceback, key)
  if not ok then
    reset()
    if M.mode == "o" then M.set_mode("n") end
    track = {}
    error(err, 0)
  end
  if #pending > 0 or op then
    -- Something is half typed: offer what can follow, after a moment.
    if not hint_at then
      hint_at = api.now() + daw.opt.hint_delay
      daw.defer(api.ui_redraw, daw.opt.hint_delay + 1)
    end
  else
    hint_at = nil
  end
  api.ui_redraw()
  finish_command()
end

--- Run keys inside the command that is running now, as a macro does.
local function replay(keys)
  if depth > 40 then error("a macro is running itself without end", 0) end
  depth = depth + 1
  local outer = track
  track = {}
  local ok = true
  for _, key in ipairs(keys) do
    ok = daw.try(M.dispatch, key)
    if not ok then break end
  end
  track, depth = outer, depth - 1
  return ok
end

--- Type keys as if from the keyboard: `daw.keymap.feed("jj<Space>")`.
function M.feed(keys)
  for _, key in ipairs(M.parse(keys)) do
    daw.try(M.dispatch, key)
  end
end

--- Type keys from inside a mapping, the way `:normal` does: they run as
--- part of the command that is running, not as a command of their own.
function M.normal(keys)
  return replay(M.parse(keys))
end

-- Repeating ---------------------------------------------------------------------

--- Do the last change again, with `n` in place of its count if given.
function M.repeat_last(n)
  if not last_change then return daw.notify("nothing to repeat yet") end
  local keys = {}
  for i, key in ipairs(last_change) do keys[i] = key end
  if n then
    -- The count sits after a register name, if there is one.
    local at = keys[1] == '"' and 3 or 1
    while keys[at] and keys[at]:match("^%d$") do table.remove(keys, at) end
    for digit in tostring(n):reverse():gmatch("%d") do table.insert(keys, at, digit) end
  end
  replaying = true
  local ok, err = pcall(replay, keys)
  replaying = false
  if not ok then error(err, 0) end
end

--- Start recording keys into a register, or stop with no name.
function M.record(name)
  if not name:match("^%a$") then return daw.notify("a macro goes in a register named a to z", "warn") end
  macro = { name = name:lower(), keys = {} }
  api.ui_redraw()
end

--- The register being recorded into, if any.
function M.recording()
  return macro and macro.name
end

--- Play the keys in a register `n` times; `@` as the name plays the last one again.
function M.play(name, n)
  if name == "@" then name = last_macro end
  local value = name and registers[name:lower()]
  if not (value and value.kind == "keys") then
    return daw.notify("no macro in register `" .. tostring(name) .. "`", "warn")
  end
  last_macro = name
  local keys = M.parse(value.keys)
  for _ = 1, n or 1 do
    if not replay(keys) then break end
  end
end

-- What to show --------------------------------------------------------------------

--- What has been typed towards a command, for display: `"a2d3`.
function M.pending()
  local out = ""
  if op then out = (op.register and '"' .. op.register or "") .. (op.count or "") .. op.map.lhs end
  return out .. (register and '"' .. register or "") .. (count or "") .. table.concat(pending)
end

--- The keys that can follow what has been typed, once the typist has paused:
--- a list of { key, desc }, and a title. Nil when there is nothing to offer.
function M.hints()
  if not hint_at or api.now() < hint_at then return nil end
  local seq, found = table.concat(pending), {}
  for _, scope in ipairs(scopes()) do
    for lhs, map in pairs(scope and maps[M.mode] and maps[M.mode][scope] or {}) do
      if #lhs > #seq and lhs:sub(1, #seq) == seq then
        local key = map.keys[#pending + 1]
        local entry = found[key] or { key = key, more = 0 }
        found[key] = entry
        if #map.keys == #pending + 1 then
          entry.desc = entry.desc or map.desc or (type(map.rhs) == "string" and map.rhs) or ""
        else
          entry.more = entry.more + 1
        end
      end
    end
  end
  if op and #pending == 0 then
    found[op.key] = found[op.key] or { key = op.key, desc = "the whole row, or as many as the count", more = 0 }
  end
  local out = {}
  for _, entry in pairs(found) do
    if not entry.desc then entry.desc = "+" .. entry.more .. " more" end
    out[#out + 1] = entry
  end
  if #out == 0 then return nil end
  table.sort(out, function(a, b) return a.key:lower() .. a.key < b.key:lower() .. b.key end)
  return out, op and (op.map.desc or op.map.lhs) .. " …" or M.pending() .. " …"
end

-- Changing view ends whatever was half done in the old one.
daw.on("view.focused", function()
  if M.mode == "x" or M.mode == "i" or M.mode == "o" then
    reset()
    M.set_mode("n")
  end
end)

-- A seat that closes leaves no key waiting to run in it.
daw.on("seat.closing", function() reset() end)

return setmetatable(M, { __call = function(_, ...) return M.set(...) end })
