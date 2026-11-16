-- Diagnostics, as `vim.diagnostic`: what is wrong with the notes of a clip,
-- published by anyone (a language server through `daw.lsp`, a lint written in
-- Lua) under a namespace of their own, and shown in one place: notes marked
-- in the piano roll of both frontends, a mark on the ruler, a count in the
-- status line, a mark on the clip in the arrange view, a list, `]d` and `[d`.
--
-- A diagnostic is a table:
--   { at, length,            -- beats from the clip's start
--     notes = { 3, 4 },      -- the notes it is about, by their place in the clip (from 1)
--     severity,              -- 1 error, 2 warning, 3 info, 4 hint; or those words
--     message, rule, source,
--     fixes = { { title, edits = { { note = 4, pitch = 73 }, { note = 5, delete = true } } },
--               { title, apply = function(d) ... end } } }
-- An edit may also set `start`, `length` and `velocity`. The notes are found
-- again by pitch and start when the clip changes, so a diagnostic keeps
-- pointing at its notes until its publisher sends new ones.
local api = daw.api

local M = {}

--- Severities by name and number, as `vim.diagnostic.severity`.
M.severity = { ERROR = 1, WARN = 2, INFO = 3, HINT = 4, "error", "warning", "info", "hint" }
local by_word = { error = 1, warning = 2, warn = 2, info = 3, information = 3, hint = 4 }
local groups = { "Error", "Warn", "Info", "Hint" }

local options = { virtual_text = true, signs = true, underline = true, severity_sort = true }

local store = {}    -- store[namespace][clip id] = list
M.revision = 0      -- moves on every change, for whoever caches what is drawn

local function clip_id(clip) return type(clip) == "table" and clip.id or clip end

local function severity_of(value)
  if type(value) == "number" then return math.max(1, math.min(4, math.floor(value))) end
  return by_word[tostring(value or ""):lower()] or 2
end

--- The highlight group for a severity with a prefix: `Diagnostic` gives
--- `DiagnosticWarn`.
function M.group(prefix, severity) return prefix .. groups[severity_of(severity)] end

-- Where each note a diagnostic names is, so that it can be found again.
local function spots(id, places)
  local ok, notes = pcall(api.clip_notes, id)
  local out = {}
  for _, place in ipairs(places) do
    local n = ok and notes[place]
    if n then out[#out + 1] = { pitch = n.pitch, start = n.start, length = n.length } end
  end
  return out
end

local function normalize(ns, id, d)
  local notes = {}
  for _, place in ipairs(d.notes or {}) do notes[#notes + 1] = math.floor(place) end
  local out = {
    namespace = ns, clip = id, notes = notes, spots = d.spots or spots(id, notes),
    at = tonumber(d.at) or 0, length = math.max(0, tonumber(d.length) or 0),
    severity = severity_of(d.severity), message = tostring(d.message or ""),
    rule = d.rule, source = d.source or ns, fixes = d.fixes or {}, data = d.data,
  }
  if not d.at and #out.spots > 0 then
    local first, last = math.huge, -math.huge
    for _, s in ipairs(out.spots) do first, last = math.min(first, s.start), math.max(last, s.start + s.length) end
    out.at, out.length = first, last - first
  end
  return out
end

local function changed(ns, id)
  M.revision = M.revision + 1
  daw.emit("diagnostic.changed", { namespace = ns, clip = id })
  api.ui_redraw()
end

--- Publish the diagnostics of `namespace` for a clip, replacing what that
--- namespace said about it before. An empty list clears them.
function M.set(namespace, clip, list)
  assert(type(namespace) == "string", "usage: daw.diagnostic.set(namespace, clip, { diagnostic, ... })")
  local id = clip_id(clip)
  local out = {}
  for _, d in ipairs(list or {}) do out[#out + 1] = normalize(namespace, id, d) end
  store[namespace] = store[namespace] or {}
  store[namespace][id] = #out > 0 and out or nil
  changed(namespace, id)
end

--- Forget what `namespace` said, about one clip or all; with no namespace,
--- everything about that clip, or everything.
function M.reset(namespace, clip)
  local id = clip and clip_id(clip)
  for ns, clips in pairs(store) do
    if not namespace or ns == namespace then
      if id then clips[id] = nil else store[ns] = nil end
    end
  end
  changed(namespace, id)
end

--- The namespaces that have published anything.
function M.namespaces()
  local out = {}
  for ns, clips in pairs(store) do
    if next(clips) then out[#out + 1] = ns end
  end
  table.sort(out)
  return out
end

--- The places the notes of a diagnostic have now (from 1), found by their
--- pitch and start; a note that has gone is left out.
function M.places(d)
  local out = {}
  for _, s in ipairs(d.spots) do
    local ok, found, at = pcall(api.clip_notes, d.clip, { from = s.start - 1e-6, to = s.start + 1e-6, low = s.pitch, high = s.pitch })
    if ok then
      for i, n in ipairs(found) do
        if math.abs(n.start - s.start) < 1e-6 then
          out[#out + 1] = at[i]
          break
        end
      end
    end
  end
  return out
end

local function sorted(list)
  table.sort(list, function(a, b)
    if a.clip ~= b.clip then return a.clip < b.clip end
    if math.abs(a.at - b.at) > 1e-9 then return a.at < b.at end
    if options.severity_sort and a.severity ~= b.severity then return a.severity < b.severity end
    return a.message < b.message
  end)
  return list
end

--- Diagnostics of a clip (nil: of every clip), sorted by where they are.
--- `filter`: `namespace`, `severity` (a severity or `{ min, max }`, where
--- min is the least severe), `note` (only those about the note at that place).
function M.get(clip, filter)
  filter = filter or {}
  local id = clip and clip_id(clip)
  local min, max = 1, 4
  if type(filter.severity) == "table" then
    min, max = severity_of(filter.severity.max or 1), severity_of(filter.severity.min or 4)
  elseif filter.severity then
    min = severity_of(filter.severity)
    max = min
  end
  local out = {}
  for ns, clips in pairs(store) do
    if not filter.namespace or filter.namespace == ns then
      for cid, list in pairs(clips) do
        -- A clip that has gone takes its diagnostics with it.
        if not pcall(api.clip_get, cid) then
          clips[cid], list = nil, {}
          M.revision = M.revision + 1
        end
        if not id or cid == id then
          for _, d in ipairs(list) do
            if d.severity >= min and d.severity <= max then out[#out + 1] = d end
          end
        end
      end
    end
  end
  if filter.note then
    local kept = {}
    for _, d in ipairs(out) do
      for _, place in ipairs(M.places(d)) do
        if place == filter.note then
          kept[#kept + 1] = d
          break
        end
      end
    end
    out = kept
  end
  return sorted(out)
end

--- How many diagnostics of each severity a clip has (nil: every clip):
--- `{ error = 1, warning = 2, info = 0, hint = 0, total = 3 }`.
function M.count(clip)
  local out = { error = 0, warning = 0, info = 0, hint = 0, total = 0 }
  for _, d in ipairs(M.get(clip)) do
    local word = M.severity[d.severity]
    out[word], out.total = out[word] + 1, out.total + 1
  end
  return out
end

--- Change how diagnostics are shown; returns the options in force.
---   daw.diagnostic.config({ virtual_text = false })
function M.config(opts)
  for k, v in pairs(opts or {}) do options[k] = v end
  if opts then api.ui_redraw() end
  return daw.util.merge(options, {})
end

-- Fixes ----------------------------------------------------------------------

--- Carry out a fix of a diagnostic as one undo step. Returns whether it did.
function M.apply(d, fix)
  fix = fix or d.fixes[1]
  if not fix then return false end
  api.undo_label(fix.title or "Fix")
  if fix.apply then
    fix.apply(d)
    return true
  end
  -- The places in a fix are those the diagnostic was published with: find
  -- each note where it is now.
  local now = {}
  for i, place in ipairs(d.notes) do now[place] = M.places({ clip = d.clip, spots = { d.spots[i] } })[1] end
  local set, remove = {}, {}
  for _, e in ipairs(fix.edits or {}) do
    local place = now[e.note]
    if not place then
      daw.notify("the note this fix changes has gone: the diagnostic is out of date", "warn")
      return false
    end
    if e.delete then
      remove[#remove + 1] = place
    else
      set[#set + 1] = { index = place, pitch = e.pitch, start = e.start, length = e.length, velocity = e.velocity }
    end
  end
  daw.clip(d.clip):edit_notes({ set = set, remove = remove })
  return true
end

--- What can be done about the note at `place` in a clip: each fix of each
--- diagnostic about it, as `{ title, diagnostic, fix, run }`, the most
--- severe first.
function M.actions(clip, place)
  local out = {}
  for _, d in ipairs(M.get(clip, { note = place })) do
    for _, fix in ipairs(d.fixes) do
      out[#out + 1] = { title = fix.title or "Fix", diagnostic = d, fix = fix, run = function() return M.apply(d, fix) end }
    end
  end
  table.sort(out, function(a, b) return a.diagnostic.severity < b.diagnostic.severity end)
  return out
end

-- Going from one to the next --------------------------------------------------

local function roll() return daw.ui.views.pianoroll end

--- Put the piano roll's cursor on a diagnostic: its first note, else its start.
function M.show(d)
  local view = roll()
  if view.clip_id ~= d.clip then view:edit(daw.clip(d.clip)) else daw.ui.focus("pianoroll") end
  local place = M.places(d)[1]
  local note = place and api.clip_notes(d.clip)[place]
  if note then view:set(note.pitch, note.start) else view:set(nil, d.at) end
  daw.notify(M.format(d), d.severity == 1 and "error" or d.severity == 2 and "warn" or "info")
end

--- A diagnostic in one line: `warning parallel-perfect: Parallel fifths … [midi-lsp]`.
function M.format(d)
  return string.format("%s%s: %s [%s]", M.severity[d.severity], d.rule and (" " .. d.rule) or "", d.message, d.source)
end

--- In the piano roll, the next (`dir` 1) or previous (-1) diagnostic of its
--- clip from the cursor; in the arrange view, the next clip with any. Wraps
--- around. Returns the diagnostic or clip gone to.
function M.jump(dir, count)
  if daw.ui.focused == "pianoroll" then
    local view = roll()
    local list = view.clip_id and M.get(view.clip_id) or {}
    if #list == 0 then return daw.notify("no diagnostics in this clip") end
    local beat, found = view.beat, nil
    for _ = 1, count or 1 do
      found = nil
      if dir > 0 then
        for _, d in ipairs(list) do
          if d.at > beat + 1e-6 then found = d break end
        end
        found = found or list[1]
      else
        for i = #list, 1, -1 do
          if list[i].at < beat - 1e-6 then found = list[i] break end
        end
        found = found or list[#list]
      end
      beat = found.at
    end
    M.show(found)
    return found
  end
  -- The arrange view: clips with diagnostics, in the order they start.
  local clips = {}
  for ns in pairs(store) do
    for id in pairs(store[ns]) do
      local ok, c = pcall(api.clip_get, id)
      if ok and not clips[id] then clips[id], clips[#clips + 1] = true, c end
    end
  end
  if #clips == 0 then return daw.notify("no diagnostics") end
  local rows = {}
  for i, id in ipairs(api.track_list()) do rows[id] = i end
  table.sort(clips, function(a, b)
    if a.start ~= b.start then return a.start < b.start end
    return (rows[a.track] or 0) < (rows[b.track] or 0)
  end)
  local beat, row, found = daw.cursor.beat, daw.cursor.index() or 0, nil
  for _ = 1, count or 1 do
    found = nil
    if dir > 0 then
      for _, c in ipairs(clips) do
        if c.start > beat + 1e-6 or (math.abs(c.start - beat) <= 1e-6 and (rows[c.track] or 0) > row) then found = c break end
      end
      found = found or clips[1]
    else
      for i = #clips, 1, -1 do
        local c = clips[i]
        if c.start < beat - 1e-6 or (math.abs(c.start - beat) <= 1e-6 and (rows[c.track] or 0) < row) then found = c break end
      end
      found = found or clips[#clips]
    end
    beat, row = found.start, rows[found.track] or 0
  end
  daw.cursor.set_track(found.track)
  daw.cursor.set_beat(found.start)
  local n = M.count(found.id)
  daw.notify(string.format("%s: %d diagnostic%s", found.name, n.total, n.total == 1 and "" or "s"))
  return found
end

function M.goto_next(opts) return M.jump(1, opts and opts.count) end
function M.goto_prev(opts) return M.jump(-1, opts and opts.count) end

--- Every diagnostic in a picker, as the quickfix list: Enter goes to it.
function M.list(clip)
  local items = {}
  for _, d in ipairs(M.get(clip)) do
    local ok, c = pcall(api.clip_get, d.clip)
    local where = ok and string.format("%s %s", c.name, daw.time.format(c.start + d.at)) or "?"
    items[#items + 1] = { text = string.format("%-7s %-18s %s", M.severity[d.severity], daw.util.fit(where, 18), M.format(d):gsub("^%a+ ", "")), diagnostic = d }
  end
  if #items == 0 then return daw.notify("no diagnostics") end
  daw.pick({
    title = "Diagnostics",
    items = items,
    on_choose = function(item) if item then M.show(item.diagnostic) end end,
  })
end

-- Drawing --------------------------------------------------------------------

--- Mark the diagnostics of the piano roll's clip, as one of its layers:
--- each note underlined in its severity's colour, the message after the last
--- note while there is room, and a mark on the ruler where it starts.
function M.paint_roll(p)
  local list = M.get(p.clip.id)
  if #list == 0 then return end
  local worst = {}
  for _, d in ipairs(list) do
    for _, s in ipairs(d.spots) do
      local key = s.pitch .. ":" .. s.start
      if not worst[key] or d.severity < worst[key].severity then worst[key] = { spot = s, severity = d.severity } end
    end
  end
  if options.underline then
    for _, w in pairs(worst) do
      local x0, x1, row = p.x(w.spot.start), p.x(w.spot.start + w.spot.length), p.row(w.spot.pitch)
      if row then p.roll:fill(x0, row, math.max(1, x1 - x0), 1, nil, M.group("DiagnosticUnderline", w.severity)) end
    end
  end
  local g = daw.draw.g
  for _, d in ipairs(list) do
    -- On the cell's left edge, where the diagnostic starts.
    if options.signs then p.ruler:text(p.x(d.at), 0, g.mark, M.group("Diagnostic", d.severity)) end
    if options.virtual_text then
      local last
      for _, s in ipairs(d.spots) do
        if not last or s.start + s.length > last.start + last.length then last = s end
      end
      local row = last and p.row(last.pitch)
      if row then
        local x = p.x(last.start + last.length) + 1
        local room = p.roll.width - x
        if room >= 8 then
          local text = api.str_width(d.message) > room and daw.util.fit(d.message, room) or d.message
          p.roll:text(x, row, text, M.group("DiagnosticVirtualText", d.severity))
        end
      end
    end
  end
end

--- A small mark on a clip in the arrange view, in its worst severity's
--- colour, at the clip's right end. `box` is the clip's cells.
function M.mark_clip(box, id, width)
  if width < 3 or not next(store) then return end
  local worst
  for _, clips in pairs(store) do
    for _, d in ipairs(clips[id] or {}) do worst = math.min(worst or 4, d.severity) end
  end
  if worst then box:text(width - 1, 0, worst == 1 and daw.draw.g.error or daw.draw.g.warn, M.group("Diagnostic", worst)) end
end

--- The status line's piece: `E1 W2` for the clip in the piano roll, or the
--- whole project when none is open. Nil when there is nothing to say.
function M.status()
  if not next(store) then return nil end
  local view = roll()
  local n = M.count(daw.ui.visible("pianoroll") and view.clip_id or nil)
  if n.total == 0 then return nil end
  local pieces = {}
  for i, word in ipairs({ "error", "warning", "info", "hint" }) do
    if n[word] > 0 then
      if #pieces > 0 then pieces[#pieces + 1] = { " ", "StatusLine" } end
      pieces[#pieces + 1] = { ("EWIH"):sub(i, i) .. n[word], i == 1 and "StatusError" or i == 2 and "StatusWarn" or "StatusDim" }
    end
  end
  return pieces
end

--- What the window marks in its piano roll for a clip: each note a
--- diagnostic is about, by place from 0, with its worst severity, the
--- messages about it and the titles of the fixes for it.
function M.roll_marks(id)
  local out, by_place = {}, {}
  local list = M.get(id)
  local notes = #list > 0 and api.clip_notes(id) or {}
  for _, d in ipairs(list) do
    for _, place in ipairs(M.places(d)) do
      local mark = by_place[place]
      local n = notes[place]
      if not mark then
        mark = { index = place - 1, pitch = n.pitch, start = n.start, length = n.length, severity = d.severity,
          message = M.format(d), actions = {} }
        by_place[place], out[#out + 1] = mark, mark
      elseif d.severity < mark.severity then
        mark.severity, mark.message = d.severity, M.format(d) .. "\n" .. mark.message
      else
        mark.message = mark.message .. "\n" .. M.format(d)
      end
    end
  end
  for place, mark in pairs(by_place) do
    for _, action in ipairs(M.actions(id, place)) do mark.actions[#mark.actions + 1] = action.title end
  end
  return out
end

daw.ui.views.pianoroll.layer("diagnostics", 30, function(p) M.paint_roll(p) end)

-- The window's menu on a note: the `n`th of its fixes, as `actions` lists them.
function daw.frontend.act.note_action(clip, place, n)
  local action = M.actions(clip, place)[n]
  if action then action.run() end
end

daw.on("project.loaded", function() if next(store) then M.reset() end end)

return M
