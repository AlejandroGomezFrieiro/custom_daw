-- The status line: segments separated by faint rules, the mode first and the
-- project's name on the right. Each segment has the narrowest screen it is
-- shown on, so that the line does not change shape as the width changes by
-- a column; past that, the project's name is cut, and only then are the
-- least needed segments dropped.
local api = daw.api
local util = daw.util

local view = { focusable = false }

local modes = { n = "NORMAL", c = "COMMAND", i = "INSERT", o = "PENDING" }
local short = { n = "NOR", c = "CMD", i = "INS", o = "PND", VISUAL = "VIS", ["V-LINE"] = "VLN", ["V-BLOCK"] = "VBL", CLIPS = "CLP" }
local visual = { v = "VISUAL", V = "V-LINE", b = "V-BLOCK", clips = "CLIPS" }
local styles = { x = "StatusVisual", i = "StatusInsert", o = "StatusPending", c = "StatusCommand" }

--- A grid in beats as a note value: 1 is `1/4`, 0.25 is `1/16`.
function view.grid_text(grid)
  local n = 4 / grid
  if math.abs(n - math.floor(n + 0.5)) < 1e-6 and n >= 1 then return "1/" .. math.floor(n + 0.5) end
  return string.format("%g beats", grid)
end

local function width_of(seg)
  local n = 0
  for _, piece in ipairs(seg) do n = n + api.str_width(piece[1]) end
  return n
end

--- The segments for a screen `width` wide, as `{ left = {...}, right = {...} }`;
--- each is a list of `{ text, style }` pieces with a `rank` (lower is
--- dropped last) and, for the name, `name = true`.
function view.segments(width)
  local g = daw.draw.g
  local t, p, e = api.transport_get(), api.project_get(), api.engine_get()
  local left, right = {}, {}
  local function add(list, min, rank, seg)
    if width >= min then
      seg.rank = rank
      list[#list + 1] = seg
    end
  end

  -- 1: the mode.
  local mode = daw.keymap.mode
  local name = mode == "x" and daw.keymap.visual and visual[daw.keymap.visual.kind] or modes[mode] or mode:upper()
  if width < 80 then
    name = short[name] or short[mode] or name:sub(1, 3)
  elseif daw.ui.focused then
    -- The view that has the keys, so that focus can be told at a glance.
    name = name .. g.dot .. daw.ui.focused
  end
  add(left, 0, 0, { { " " .. name .. " ", styles[mode] or "StatusMode" }, pill = true })
  -- 2: a macro being recorded.
  if daw.keymap.recording() then add(left, 0, 1, { { "@" .. daw.keymap.recording(), "StatusMacro" } }) end
  -- 3, 4: the transport and where it is.
  local state = t.take and { g.rec, "StatusRec" } or t.playing and { g.play, "StatusPlay" } or { g.stop, "StatusStop" }
  if (t.counting or 0) > 0 then
    -- Counting in: the beats left before the take starts, in place of the time.
    add(left, 0, 2, { state, { " count " .. t.counting, "StatusRec" } })
  else
    add(left, 0, 2, { state, { " " .. daw.time.format(t.position), "StatusTime" } })
  end
  -- 5: the time in minutes and seconds.
  add(left, 90, 8, { { daw.time.clock(t.position), "StatusDim" } })
  -- 6: tempo and time signature where the playhead is.
  local num, den = daw.tempo.signature_at(t.position)
  local bpm = math.floor(daw.tempo.at(t.position) * 10 + 0.5) / 10
  add(left, 70, 5, { { string.format("%g bpm %d/%d", bpm, num, den), "StatusLine" } })
  -- 7: what is switched on, and only that.
  local on = {}
  if t.loop_enabled then
    local bar = daw.time.bar()
    local from = math.floor(t.loop_start / bar + 1e-9) + 1
    local to = math.max(from, math.ceil(t.loop_end / bar - 1e-9))
    on[#on + 1] = { "loop " .. from .. (g.ellipsis == "…" and "–" or "-") .. to, "StatusOn" }
  end
  if t.metronome then on[#on + 1] = { "click", "StatusOn" } end
  if t.punch_enabled and t.punch_end > t.punch_start then
    local from = daw.time.bar_of(t.punch_start)
    local to = math.max(from, daw.time.bar_of(t.punch_end - 1e-9))
    on[#on + 1] = { "punch " .. from .. (g.ellipsis == "…" and "–" or "-") .. to, "StatusRec" }
  end
  if (t.count_in or 0) > 0 then on[#on + 1] = { "count " .. t.count_in, "StatusOn" } end
  if t.recording then on[#on + 1] = { "rec", "StatusRec" } end
  if t.write then on[#on + 1] = { "write", "StatusRec" } end
  if #on > 0 then
    local seg = {}
    for i, piece in ipairs(on) do
      if i > 1 then seg[#seg + 1] = { " ", "StatusLine" } end
      seg[#seg + 1] = piece
    end
    add(left, 0, 4, seg)
  end
  -- A render in the background: how far it has got, and how to stop it;
  -- only the percentage on a narrow screen.
  local job = api.render_status()
  if job then
    local pct = string.format("%d%%", math.floor(job.fraction * 100))
    local file = tostring(job.path):match("([^/]+)$") or tostring(job.path)
    local verb = job.stage == "encoding" and "encoding" or "rendering"
    local text = width >= 120 and (verb .. " " .. file .. " " .. pct .. " · Esc cancels")
      or width >= 80 and (verb:sub(1, 6) .. " " .. pct .. " · Esc") or (verb:sub(1, 6) .. " " .. pct)
    add(left, 0, 3, { { text, "StatusRec" } })
  end
  -- Diagnostics: how many of each, for the piano roll's clip or the project.
  local diagnostics = daw.diagnostic and daw.diagnostic.status()
  if diagnostics then add(left, 0, 3, diagnostics) end
  -- The quickfix list, while it has entries.
  local qf = daw.qf and daw.qf.status()
  if qf then add(left, 0, 3, qf) end
  -- What is under the pointer, or what it would do there, in what room is left.
  local pointer = daw.mouse.hint_text()
  local room = width - 70
  if pointer and room >= 12 then
    if api.str_width(pointer) > room then pointer = util.fit(pointer, room) end
    add(left, 0, 3, { { pointer, "StatusHint" } })
  end
  -- 8: the grid of the view that has focus: the roll and the drums keep their own.
  local focused = daw.ui.views[daw.ui.focused]
  local cells = focused and focused.grid
  if not (cells and cells.step) or cells.rows then
    cells = { step = function() return daw.opt.grid end }
  end
  add(left, 100, 9, { { "grid " .. view.grid_text(cells.step()), "StatusDim" } })
  -- 9: how much is selected, in visual mode.
  local selection = mode == "x" and daw.ui.focused == "arrange" and daw.keymap.selection()
  if selection then
    local tracks = selection.r1 - selection.r0 + 1
    local text = tracks .. (tracks == 1 and " track" or " tracks")
    if selection.kind ~= "line" then
      local beats = selection.c1 - selection.c0
      local bars = beats / daw.time.bar()
      text = text .. " " .. (math.abs(bars - math.floor(bars + 0.5)) < 1e-9 and string.format("%g bar%s", bars, bars == 1 and "" or "s")
        or string.format("%g beats", beats))
    end
    add(left, 110, 10, { { "sel " .. text, "StatusLine" } })
  end

  -- 10: keys typed so far, or the register chosen.
  local pending = daw.keymap.pending()
  if pending ~= "" then add(right, 0, 3, { { pending, "StatusOn" } }) end
  -- 11: the project, with an amber dot when it has unsaved changes.
  local seg = { { p.name, "StatusName" }, name = true }
  if p.modified then table.insert(seg, 1, { g.modified .. " ", "StatusModified" }) end
  add(right, 0, 1, seg)
  -- 12: the engine.
  local block = (e.block and e.block > 0) and e.block or e.buffer_size
  add(right, 120, 7, { { string.format("%s %gk%s", e.backend, e.sample_rate / 1000, block and block > 0 and (" " .. block) or ""), "StatusDim" } })
  -- 13: how busy the engine is, and dropouts since it started.
  local load = math.max(0, math.min(1, e.cpu or 0))
  local cpu = { { "cpu " .. g.eighths[1 + math.floor(load * 7.99)] .. string.format(" %d%%", math.floor(load * 100 + 0.5)),
    load > 0.8 and "StatusError" or load > 0.5 and "StatusWarn" or "StatusDim" } }
  if (e.xruns or 0) > 0 then
    cpu[#cpu + 1] = { " xrun " .. e.xruns, "StatusWarn" }
  end
  add(right, 90, 6, cpu)
  return { left = left, right = right }
end

local SEP = 3 -- " │ "

local function total(segs)
  local n = 0
  for i, seg in ipairs(segs) do
    n = n + width_of(seg) + ((i > 1 and not segs[i - 1].pill) and SEP or (i > 1 and 1 or 0))
  end
  return n
end

function view:render(buf)
  local w = buf.width
  buf:fill(0, 0, w, 1, " ", "StatusLine")
  local s = view.segments(w)
  local left, right = s.left, s.right
  local function need() return total(left) + total(right) + 2 end
  -- Too long: cut the name, down to a few characters, then drop segments
  -- from the least needed.
  local name_seg
  for _, seg in ipairs(right) do if seg.name then name_seg = seg end end
  if need() > w and name_seg then
    local piece = name_seg[#name_seg]
    local over = need() - w
    local keep = math.max(8, api.str_width(piece[1]) - over)
    if keep < api.str_width(piece[1]) then piece[1] = util.fit(piece[1], keep) end
  end
  while need() > w do
    local worst, worst_list, worst_i = -1, nil, nil
    for _, list in ipairs({ left, right }) do
      for i, seg in ipairs(list) do
        if seg.rank > worst and seg.rank > 0 and not seg.name then worst, worst_list, worst_i = seg.rank, list, i end
      end
    end
    if not worst_list then break end
    table.remove(worst_list, worst_i)
  end

  local g = daw.draw.g
  local x = 0
  local function put(segs, at)
    for i, seg in ipairs(segs) do
      if i > 1 then
        if segs[i - 1].pill then
          at = at + 1
        else
          at = at + buf:text(at, 0, " " .. g.sep .. " ", "StatusSep")
        end
      end
      for _, piece in ipairs(seg) do at = at + buf:text(at, 0, piece[1], piece[2]) end
    end
    return at
  end
  x = put(left, x)
  put(right, math.max(x + 1, w - total(right) - 1))
end

daw.ui.view("status", view)
return view
