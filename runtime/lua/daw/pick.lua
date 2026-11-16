-- `daw.pick`: choose one of many things by typing a few letters of it.
--
--   daw.pick({
--     title = "Tracks",
--     items = { { text = "Bass", id = 3 }, "Drums" },   -- or a function returning the list
--     format = function(item) return item.text end,    -- optional: the line shown and matched
--     on_choose = function(item) end,                  -- Enter
--     on_cancel = function() end,                      -- optional: Escape
--   })
--
-- Optional fields beyond those: `query` (typed in already), `prompt`,
-- `preview(item)` returning lines (strings or `{ text, style }`) for a pane
-- beside the list, `actions` mapping other keys to `function(item, query)`
-- (or `{ fn = ..., desc = ..., keep = true }` to leave the picker open),
-- `multi = true` to mark several with Tab and get them in
-- `on_choose_multi(items)`, `width` and `height`, `top = true` to sit at the
-- top of the screen (leaving what is below in view), `empty` (what to say
-- when there is nothing to choose from), and `primary(item)`: the part of
-- the line that counts first, so that lines matching there rank above
-- lines matching only elsewhere.
--
-- `daw.pick("tracks")` opens a source by name. `daw.pick.sources` holds them:
-- add a table of the same fields with a `desc`, or a function returning one.
-- The picker of pickers (`daw.pick("pickers")`) lists every source.
local api = daw.api
local M = { sources = {} }

local byte, lower, sub = string.byte, string.lower, string.sub
local floor, max, min = math.floor, math.max, math.min

-- Matching ---------------------------------------------------------------------
--
-- The scoring follows fzf's: every matched character is worth `MATCH`, a gap
-- costs `GAP_START` and `GAP_EXTEND` for each further character skipped, and a
-- character earns a bonus for where it is: after a space, a separator or at the
-- start of a word, at a lower-to-upper case change, or when it carries on a run
-- of consecutive matches. The first character's bonus counts double. Of all the
-- ways the query can be found in a line, the best scoring one is taken. Equal
-- scores go to the match nearer the start, then to the shorter line.

local MATCH, GAP_START, GAP_EXTEND = 16, -3, -1
local BONUS_BOUNDARY = MATCH / 2                         -- 8: start of a word
local BONUS_WHITE = BONUS_BOUNDARY + 2                   -- 10: after a space
local BONUS_DELIMITER = BONUS_BOUNDARY + 1               -- 9: after / : , ; |
local BONUS_NONWORD = BONUS_BOUNDARY                     -- 8: punctuation itself
local BONUS_CAMEL = BONUS_BOUNDARY + GAP_EXTEND          -- 7: aB, a1
local BONUS_CONSECUTIVE = -(GAP_START + GAP_EXTEND)      -- 4
local FIRST_MULTIPLIER = 2
local NONE = -1e9

-- Character classes, by byte.
local WHITE, NONWORD, DELIM, LOWER, UPPER, NUMBER = 0, 1, 2, 3, 4, 5
local class = {}
for b = 0, 255 do
  local c = NONWORD
  if b == 32 or b == 9 or b == 10 or b == 13 then
    c = WHITE
  elseif b >= 97 and b <= 122 or b >= 128 then
    c = LOWER   -- bytes of non-ASCII characters count as letters
  elseif b >= 65 and b <= 90 then
    c = UPPER
  elseif b >= 48 and b <= 57 then
    c = NUMBER
  elseif b == 47 or b == 58 or b == 44 or b == 59 or b == 124 then
    c = DELIM
  end
  class[b] = c
end

local function bonus_for(prev, cur)
  if cur > DELIM then
    if prev == WHITE then return BONUS_WHITE end
    if prev == DELIM then return BONUS_DELIMITER end
    if prev == NONWORD then return BONUS_BOUNDARY end
  end
  if prev == LOWER and cur == UPPER or prev ~= NUMBER and cur == NUMBER then return BONUS_CAMEL end
  if cur == NONWORD or cur == DELIM then return BONUS_NONWORD end
  if cur == WHITE then return BONUS_WHITE end
  return 0
end

local bonus_table = {}
for prev = 0, 5 do
  bonus_table[prev] = {}
  for cur = 0, 5 do bonus_table[prev][cur] = bonus_for(prev, cur) end
end

-- Scratch rows, reused for every line so that matching makes no garbage.
local bonus, cmp, first, last = {}, {}, {}, {}
local prev_score, prev_run, score_row, run_row = {}, {}, {}, {}

--- Score one term (no spaces) against a line. `text` is the line as it is
--- compared: lowered when the term is. Returns the score, or nil when the term
--- is not in the line. With `trace` a table, fills it with the byte positions
--- matched.
local function match_term(term, text, orig, trace)
  local m, n = #term, #text
  if m == 0 then return 0 end
  if m > n then return nil end
  -- Where each character of the term can first and last be, which also
  -- rejects lines that do not hold the term as a subsequence.
  local j = 1
  for i = 1, m do
    local c = byte(term, i)
    while j <= n and byte(text, j) ~= c do j = j + 1 end
    if j > n then return nil end
    first[i] = j
    j = j + 1
  end
  j = n
  for i = m, 1, -1 do
    local c = byte(term, i)
    while byte(text, j) ~= c do j = j - 1 end
    last[i] = j
    j = j - 1
  end

  local lo, hi = first[1], last[m]
  local prev_class = lo > 1 and class[byte(orig, lo - 1)] or WHITE
  for k = lo, hi do
    local cur = class[byte(orig, k)]
    bonus[k] = bonus_table[prev_class][cur]
    prev_class = cur
    cmp[k] = byte(text, k)
  end

  -- prev_score[k]: best score with term[i-1] matched at k; run: length of the
  -- run of consecutive matches ending there.
  local from = trace and {} or nil
  local c1 = byte(term, 1)
  for k = lo, hi do
    if k >= first[1] and k <= last[1] and cmp[k] == c1 then
      prev_score[k], prev_run[k] = MATCH + bonus[k] * FIRST_MULTIPLIER, 1
    else
      prev_score[k], prev_run[k] = NONE, 0
    end
  end
  if from then
    from[1] = {}
  end
  for i = 2, m do
    local c = byte(term, i)
    local a, b = first[i], last[i]
    local gap, gap_at = NONE, 0   -- best of prev_score[k] less the gap up to here
    local row_from = from and {} or nil
    if from then from[i] = row_from end
    for k = lo, hi do
      -- Bring the gap candidate forward to column k: a match of the
      -- previous character two or more columns back.
      if k - 2 >= lo then
        local p = prev_score[k - 2]
        if gap ~= NONE then gap = gap + GAP_EXTEND end
        if p ~= NONE and p + GAP_START > gap then gap, gap_at = p + GAP_START, k - 2 end
      end
      local s, r, src = NONE, 0, nil
      if k >= a and k <= b and cmp[k] == c then
        local own = bonus[k]
        local d = k > lo and prev_score[k - 1] or NONE
        if d ~= NONE then
          local run = prev_run[k - 1]
          local start_bonus = bonus[k - run]
          local bb = own
          if own >= BONUS_BOUNDARY and own > start_bonus then
            run = 0   -- a new word starts here: a run of its own
          else
            bb = max(own, BONUS_CONSECUTIVE, start_bonus)
          end
          s, r, src = d + MATCH + bb, run + 1, k - 1
        end
        if gap ~= NONE and gap + MATCH + own > s then
          s, r, src = gap + MATCH + own, 1, gap_at
        end
      end
      score_row[k], run_row[k] = s, r
      if row_from then row_from[k] = src end
    end
    for k = lo, hi do
      prev_score[k], prev_run[k] = score_row[k], run_row[k]
    end
  end
  local best, at = NONE, nil
  for k = lo, hi do
    if prev_score[k] > best then best, at = prev_score[k], k end
  end
  if best == NONE then return nil end
  local finish = at
  if trace then
    for i = m, 1, -1 do
      trace[#trace + 1] = at
      at = i > 1 and from[i][at] or nil
    end
  end
  return best, finish
end

--- Split a query into terms. A term with a capital letter is matched as
--- typed; one without ignores case.
local function terms_of(query)
  local out = {}
  for word in query:gmatch("%S+") do
    out[#out + 1] = { text = word, exact = word:find("%u") ~= nil }
  end
  return out
end

--- How well `query` matches `text`: a score, higher is better, and the byte
--- positions of the matched characters in order. Nil when it does not match.
--- Words of the query separated by spaces must each match.
---   daw.pick.match("bs", "Bass Synth")   --> score, { 1, 6 }
function M.match(query, text, want_positions)
  if want_positions == nil then want_positions = true end
  local total, positions = 0, want_positions and {} or nil
  local low = lower(text)
  for _, term in ipairs(terms_of(query)) do
    local s = match_term(term.exact and term.text or lower(term.text), term.exact and text or low, text, positions)
    if not s then return nil end
    total = total + s
  end
  if positions then table.sort(positions) end
  return total, positions
end

--- Entries for a list of items: { item, text, low, index }, and `primary`
--- (lowered) when the picker says which part of a line counts first.
local function entries_of(items, format, primary)
  local out = {}
  for i, item in ipairs(items) do
    local text
    if format then
      text = format(item)
    elseif type(item) == "table" then
      text = item.text or item.name or item[1]
    end
    text = tostring(text == nil and item or text):gsub("[\r\n\t]", " ")
    out[i] = { item = item, text = text, low = lower(text), index = i }
    if primary then out[i].primary = tostring(primary(item) or "") end
  end
  return out
end

-- What a match in an entry's primary part (a command's name, say) is worth
-- over one found only in the rest of the line.
local PRIMARY_BONUS = 1000

-- Equal scores go to the match that ends sooner, then to the shorter line.
local function by_score(a, b)
  if a.score ~= b.score then return a.score > b.score end
  if a.finish ~= b.finish then return a.finish < b.finish end
  if #a.text ~= #b.text then return #a.text < #b.text end
  return a.index < b.index
end

--- Keep the entries that match `query`, best first. An empty query keeps
--- every entry, in its order.
local function filter_entries(query, entries)
  local terms = terms_of(query)
  if #terms == 0 then
    local out = {}
    for i, e in ipairs(entries) do
      e.score, e.finish = 0, 0
      out[i] = e
    end
    return out
  end
  for _, term in ipairs(terms) do
    if not term.exact then term.text = lower(term.text) end
  end
  local out = {}
  for _, e in ipairs(entries) do
    local total, finish = 0, nil
    for _, term in ipairs(terms) do
      local s, at = match_term(term.text, term.exact and e.text or e.low, e.text)
      if not s then
        total = nil
        break
      end
      total, finish = total + s, finish or at
    end
    if total and e.primary then
      local all = true
      for _, term in ipairs(terms) do
        local p = term.exact and e.primary or lower(e.primary)
        if not match_term(term.text, p, e.primary) then
          all = false
          break
        end
      end
      if all then total = total + PRIMARY_BONUS end
    end
    if total then
      e.score, e.finish = total, finish
      out[#out + 1] = e
    end
  end
  table.sort(out, by_score)
  return out
end

--- The items that match `query`, best first, each as { item, text, score }.
---   daw.pick.filter("bass", { "Bass", "Bass Synth", "Drums" })
function M.filter(query, items, format)
  local out = {}
  for i, e in ipairs(filter_entries(query, entries_of(items, format))) do
    out[i] = { item = e.item, text = e.text, score = e.score }
  end
  return out
end

-- The picker --------------------------------------------------------------------

local active        -- the open picker
local last_spec     -- for `resume`
daw.seats.keep("pick",
  function() return active, last_spec end,
  function(a, spec) active, last_spec = a, spec end,
  function() return nil, nil end)

local view = { modal = true }

local function chars_of(text)
  local out = {}
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = ch end
  return out
end

local function refilter(p)
  local query = table.concat(p.query)
  -- Typing on only narrows the matches (a longer term, another term, a
  -- capital that makes a term match case), so start from the last ones.
  local base = p.entries
  if p.last_query ~= "" and query:sub(1, #p.last_query) == p.last_query then base = p.matches end
  -- A picker may match and rank its items itself: `rank(item, query, line)`
  -- returns a score, higher first, or nil to leave the item out.
  if p.spec.rank then
    local kept = {}
    for _, e in ipairs(base) do
      e.score, e.finish = p.spec.rank(e.item, query, e.text), 0
      if e.score then kept[#kept + 1] = e end
    end
    -- With nothing typed the list keeps its own order.
    if query ~= "" then table.sort(kept, by_score) end
    p.matches = kept
  else
    p.matches = filter_entries(query, base)
  end
  p.last_query = query
  p.selected, p.top = 1, 1
end

local function current(p)
  local e = p.matches[p.selected]
  return e and e.item, e
end

local function close(p)
  if active == p then active = nil end
  if daw.ui.float and daw.ui.float.name == "pick" then daw.ui.close() end
end

local function choose(p)
  local item = current(p)
  close(p)
  if p.multi and next(p.marked) then
    local items = {}
    for _, e in ipairs(p.entries) do
      if p.marked[e] then items[#items + 1] = e.item end
    end
    if p.spec.on_choose_multi then return p.spec.on_choose_multi(items) end
    for _, it in ipairs(items) do p.spec.on_choose(it) end
    return
  end
  if item == nil then
    if p.spec.on_cancel then p.spec.on_cancel() end
    return
  end
  if p.spec.on_choose then p.spec.on_choose(item) end
end

local function cancel(p)
  close(p)
  if p.spec.on_cancel then p.spec.on_cancel() end
end

local function move(p, by)
  local n = #p.matches
  if n == 0 then return end
  p.selected = (p.selected - 1 + by) % n + 1
end

local function action_of(p, key)
  local a = p.spec.actions and p.spec.actions[key]
  if type(a) == "function" then return { fn = a } end
  return a
end

function view:on_key(key)
  local p = active
  if not p then return daw.ui.close() end
  -- `resume` reopens with what was typed when Enter or Escape closed it.
  if last_spec and last_spec.spec == p.spec then last_spec.query = table.concat(p.query) end
  local action = action_of(p, key)
  if action then
    local item = current(p)
    if not action.keep then close(p) end
    action.fn(item, table.concat(p.query), p)
    return api.ui_redraw()
  end
  if key == "<CR>" then
    return choose(p)
  elseif key == "<Esc>" or key == "<C-c>" then
    return cancel(p)
  elseif key == "<C-n>" or key == "<Down>" or key == "<C-j>" then
    move(p, 1)
  elseif key == "<C-p>" or key == "<Up>" or key == "<C-k>" then
    move(p, -1)
  elseif key == "<PageDown>" or key == "<C-d>" then
    p.selected = min(#p.matches, p.selected + (p.rows or 10))
  elseif key == "<PageUp>" then
    p.selected = max(1, p.selected - (p.rows or 10))
  elseif key == "<Home>" then
    p.selected = 1
  elseif key == "<End>" then
    p.selected = max(1, #p.matches)
  elseif key == "<Tab>" and p.multi then
    local _, e = current(p)
    if e then p.marked[e] = not p.marked[e] or nil end
    move(p, 1)
  elseif key == "<S-Tab>" and p.multi then
    local _, e = current(p)
    if e then p.marked[e] = not p.marked[e] or nil end
    move(p, -1)
  elseif key == "<C-u>" then
    p.query = {}
    refilter(p)
  elseif key == "<C-w>" then
    local q = p.query
    while #q > 0 and q[#q] == " " do q[#q] = nil end
    while #q > 0 and q[#q] ~= " " do q[#q] = nil end
    refilter(p)
  elseif key == "<BS>" or key == "<C-h>" then
    if #p.query > 0 then
      p.query[#p.query] = nil
      refilter(p)
    end
  else
    local ch = key == "<Space>" and " " or key == "<lt>" and "<" or key
    if not ch:match("^<.+>$") then
      p.query[#p.query + 1] = ch
      refilter(p)
    end
  end
  api.ui_redraw()
end

function view:on_mouse(event)
  local p = active
  if not p then return end
  if event.kind == "scroll_down" then
    move(p, 3)
  elseif event.kind == "scroll_up" then
    move(p, -3)
  elseif event.kind == "down" and p.list_y and event.y >= p.list_y then
    local at = p.top + event.y - p.list_y
    if p.matches[at] then
      if at == p.selected then return choose(p) end
      p.selected = at
    end
  end
  api.ui_redraw()
end

--- Draw `text` cut to `width` columns, with the characters at byte
--- `positions` (sorted) in `style`.
local function draw_matched(buf, x, y, text, positions, width, style)
  buf:text(x, y, daw.util.fit(text, width), nil)
  if not positions or #positions == 0 then return end
  -- A line that does not fit ends in "…" in its last column.
  local limit = api.str_width(text) > width and width - 1 or width
  local at, col, pi = 1, 0, 1
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    local w = api.str_width(ch)
    if col + w > limit then break end
    local stop = at + #ch - 1
    while positions[pi] and positions[pi] < at do pi = pi + 1 end
    if not positions[pi] then break end
    if positions[pi] <= stop then buf:fill(x + col, y, w, 1, nil, style) end
    at, col = stop + 1, col + w
  end
end

local function preview_lines(p, item)
  if item == nil or not p.spec.preview then return {} end
  local ok, lines = pcall(p.spec.preview, item)
  if not ok then return { { text = tostring(lines), style = "Error" } } end
  if type(lines) == "string" then lines = { lines } end
  local out = {}
  for _, line in ipairs(lines or {}) do
    line = type(line) == "table" and line or { text = line }
    for part in (tostring(line.text) .. "\n"):gmatch("([^\n]*)\n") do
      out[#out + 1] = { text = part:gsub("\t", "  "), style = line.style }
    end
  end
  return out
end

function view:render(buf, ctx)
  local p = active
  if not p then return end
  local w, h = buf.width, buf.height
  buf:fill(0, 0, w, h, " ", "Normal")

  -- The query line: the prompt, what is typed, and how many match.
  local query = table.concat(p.query)
  local count = string.format("%d/%d", #p.matches, #p.entries)
  if p.multi and next(p.marked) then
    local n = 0
    for _ in pairs(p.marked) do n = n + 1 end
    count = string.format("(%d) %s", n, count)
  end
  local used = buf:text(0, 0, p.prompt, "PickPrompt")
  local room = max(1, w - used - #count - 2)
  local shown = query
  if api.str_width(shown) > room then shown = "…" .. shown:sub(-(room - 1)) end
  local qw = buf:text(used, 0, shown, "Normal")
  buf:text(w - #count, 0, count, "PickCount")
  if ctx then api.ui_cursor(ctx.x + used + qw, ctx.y) end
  buf:text(0, 1, string.rep("─", w), "Border")

  -- A preview pane takes the right 40% when there is room for one.
  local list_w = w
  local has_preview = p.spec.preview and w >= 60
  if has_preview then list_w = floor(w * 0.6) end

  local footer = p.footer
  local rows = h - 2 - (footer and 1 or 0)
  p.rows, p.list_y = rows, 2
  if p.selected < p.top then p.top = p.selected end
  if p.selected >= p.top + rows then p.top = p.selected - rows + 1 end
  p.top = max(1, min(p.top, max(1, #p.matches - rows + 1)))

  if #p.entries == 0 then
    buf:text(2, 2, p.spec.empty or "Nothing to choose from.", "Dim")
  elseif #p.matches == 0 then
    buf:text(2, 2, "Nothing matches.", "Dim")
  end
  local mark_room = p.multi and 2 or 0
  local terms_query = query:match("%S") and query or nil
  for row = 0, rows - 1 do
    local index = p.top + row
    local e = p.matches[index]
    if not e then break end
    local y = 2 + row
    local selected = index == p.selected
    if selected then buf:fill(0, y, list_w, 1, nil, "PickSelected") end
    buf:text(0, y, selected and "▶" or " ", selected and "PickCaret" or nil)
    if p.multi then buf:text(2, y, p.marked[e] and "+" or " ", "PickMarked") end
    local positions
    if terms_query then
      local _, pos = M.match(terms_query, e.text)
      positions = pos
    end
    draw_matched(buf, 2 + mark_room, y, e.text, positions, list_w - 3 - mark_room, "PickMatch")
  end

  if has_preview then
    for y = 2, h - 1 - (footer and 1 or 0) do buf:text(list_w, y, "│", "Border") end
    local lines = preview_lines(p, current(p))
    local pw = w - list_w - 2
    for i, line in ipairs(lines) do
      if i > rows then break end
      buf:text(list_w + 2, 1 + i, daw.util.fit(line.text, pw), line.style or "Normal")
    end
  end
  if footer then buf:text(0, h - 1, daw.util.fit(footer, w), "Dim") end
end

daw.ui.view("pick", view)

local function footer_of(spec)
  local parts = { "Enter choose", "Esc cancel", "C-n/C-p move" }
  if spec.multi then parts[#parts + 1] = "Tab mark" end
  local keys = {}
  for key, a in pairs(spec.actions or {}) do
    if type(a) == "table" and a.desc then keys[#keys + 1] = key:gsub("^<(.*)>$", "%1") .. " " .. a.desc end
  end
  table.sort(keys)
  for _, k in ipairs(keys) do parts[#parts + 1] = k end
  return table.concat(parts, "  ")
end

--- Open a picker. See the top of this file for the fields of `spec`, or pass
--- the name of a source. Returns the picker's state.
function M.open(spec, extra)
  if type(spec) == "string" then
    local name = spec
    local source = M.sources[name]
    if not source then error("no picker `" .. name .. "`", 2) end
    spec = type(source) == "function" and source(extra or {}) or source
    if not spec then return end
    if extra and extra.query then spec = daw.util.merge(spec, { query = extra.query }) end
    if not spec.title then spec = daw.util.merge(spec, { title = name }) end
  end
  assert(type(spec) == "table", "usage: daw.pick({ items = ..., on_choose = function(item) end })")
  local items = spec.items
  if type(items) == "function" then items = items() end
  local p = {
    spec = spec, prompt = spec.prompt or "> ", query = chars_of(spec.query or ""),
    entries = entries_of(items or {}, spec.format, spec.primary), selected = 1, top = 1,
    multi = spec.multi, marked = {}, last_query = "",
  }
  p.matches = p.entries
  p.footer = footer_of(spec)
  if #p.query > 0 or spec.rank then refilter(p) end
  active, last_spec = p, { spec = spec, query = spec.query }
  local width, height = api.ui_size()
  daw.ui.open("pick", {
    title = spec.title or "Pick",
    width = spec.width or (spec.preview and min(120, width - 4) or min(80, width - 4)),
    height = spec.height or min(28, max(10, height - 4)),
    top = spec.top,
  })
  return p
end

--- Open the last picker again, with the query it had.
function M.resume()
  if not last_spec then return daw.notify("no picker opened yet", "warn") end
  local spec, query = last_spec.spec, last_spec.query
  local p = M.open(spec)
  p.query = chars_of(query or "")
  refilter(p)
  return p
end

--- The open picker, if any: its query, the matches as lines, and the item
--- under the selection. For tests and for frontends.
function M.state()
  local p = active
  if not p or not (daw.ui.float and daw.ui.float.name == "pick") then return nil end
  local lines = {}
  for i, e in ipairs(p.matches) do lines[i] = e.text end
  return { query = table.concat(p.query), matches = lines, selected = p.selected, item = current(p), title = p.spec.title or "Pick" }
end

local palette = require("daw.theme").palette
for name, def in pairs({
  PickPrompt = { fg = palette.blue, bold = true },
  PickCount = { fg = palette.dim },
  PickMatch = { fg = palette.orange, bold = true },
  PickSelected = { bg = palette.bg_hl },
  PickCaret = { fg = palette.orange, bold = true },
  PickMarked = { fg = palette.green, bold = true },
}) do
  api.hl_set(name, def)
end

M.sources = require("daw.pick.sources")(M)

--- Choose a file by walking directories:
---
---   daw.pick.file({ title = "Import audio", extensions = { "wav", "mp3" },
---                   on_choose = function(path) end })
---
--- Directories come first and are entered with Enter; `..` goes up; only
--- files with one of `extensions` are listed (all files without it). It
--- starts in `dir`, else where a file was last chosen, else beside the
--- project, else in the home directory. With `directory = true` the first
--- item chooses the directory being shown, and `on_choose` gets it.
function M.file(opts)
  local wanted
  if opts.extensions then
    wanted = {}
    for _, ext in ipairs(opts.extensions) do wanted[ext:lower()] = true end
  end
  local function open(dir)
    dir = dir:gsub("/+$", "")
    if dir == "" then dir = "/" end
    local items = {}
    if dir ~= "/" then items[1] = { name = "..", dir = true, path = dir:match("^(.*)/[^/]+$") or "/" } end
    local dirs, files = {}, {}
    for _, entry in ipairs(api.read_dir(dir)) do
      if opts.hidden or entry.name:sub(1, 1) ~= "." then
        local path = (dir == "/" and "" or dir) .. "/" .. entry.name
        if entry.is_dir then
          dirs[#dirs + 1] = { name = entry.name, dir = true, path = path }
        elseif not wanted or wanted[(entry.name:match("%.([^.]+)$") or ""):lower()] then
          files[#files + 1] = { name = entry.name, path = path }
        end
      end
    end
    -- Choosing a directory rather than a file: this one, as the first item.
    if opts.directory then table.insert(items, 1, { name = "[choose this directory]", here = true, path = dir }) end
    for _, item in ipairs(dirs) do items[#items + 1] = item end
    for _, item in ipairs(files) do items[#items + 1] = item end
    M.open({
      title = (opts.title or "Open") .. " · " .. dir,
      items = items,
      format = function(item) return (item.dir and "▸ " or "  ") .. item.name .. (item.dir and "/" or "") end,
      empty = "nothing here to choose",
      on_choose = function(item)
        if item.here then daw.state.pick_dir = dir return opts.on_choose(dir) end
        if item.dir then return open(item.path == "" and "/" or item.path) end
        daw.state.pick_dir = dir
        opts.on_choose(item.path)
      end,
      on_cancel = opts.on_cancel,
    })
  end
  local project = api.project_get and api.project_get().path
  open(opts.dir or daw.state.pick_dir or (project and project:match("^(.*)/[^/]+$")) or os.getenv("HOME") or "/")
end

return setmetatable(M, { __call = function(_, spec, extra) return M.open(spec, extra) end })
