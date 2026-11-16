-- `daw.snippet`: named music made from its context, written at the cursor
-- of the piano roll or over a selection, with choices to step through
-- afterwards. As `vim.snippet` or LuaSnip, for notes.
--
--   daw.snippet.add({
--     name = "dominant", desc = "the dominant seventh of the next chord, up to it",
--     views = { "pianoroll" },
--     expand = function(ctx)
--       local target = ctx.harmony.next(ctx.at)
--       if not target then return nil, "no chord after the cursor" end
--       local root = (target.root + 7) % 12
--       return {
--         notes = ctx:chord(ctx.harmony.tones(root, "7"), ctx.at, target.at),
--         choices = { { name = "voicing", values = { "smooth", "close", "drop2", "open" } } },
--       }
--     end,
--   })
--
-- `expand(ctx)` returns `{ notes, choices, remove }` or nil and a reason.
-- Notes are a note set in project beats: `{ pitch, start, length, velocity }`
-- (velocity 1..127, `daw.opt.velocity` when left out). `remove` lists notes
-- of `ctx.selection` the snippet replaces. Each choice is `{ name, values }`
-- and optionally `apply(result, value)` returning the notes; without it the
-- snippet is expanded again with `ctx.values[name]` set to the value chosen.
--
-- Expanding writes the notes as one undo step and makes the snippet active:
-- `<Tab>` and `<S-Tab>` go from choice to choice, `<C-n>` and `<C-p>` step
-- the current one (rewriting the notes within the same undo step), `<C-y>`,
-- `<Esc>` or the cursor leaving the snippet's span ends it.
local api = daw.api
local harmony = daw.harmony
local M = { list = {} }

local RANK = { extension = 1, config = 2 }

--- Add a snippet, or replace one of the same name. A snippet from an
--- extension never replaces one from the user's configuration.
function M.add(spec)
  assert(type(spec) == "table" and type(spec.name) == "string" and type(spec.expand) == "function",
    "usage: daw.snippet.add({ name = ..., expand = function(ctx) ... end })")
  local source = spec.source or M.loading or (daw.ext.current and "extension") or "config"
  local old = M.list[spec.name]
  if old and RANK[old.source] > RANK[source] then return old end
  local entry = {}
  for k, v in pairs(spec) do entry[k] = v end
  entry.source, entry.desc, entry.views = source, spec.desc or "", spec.views or { "pianoroll" }
  M.list[spec.name] = entry
  return entry
end

--- Remove a snippet.
function M.remove(name)
  M.list[name] = nil
end

function M.get(name)
  return M.list[name]
end

--- The snippets offered in `view` (the focused one when nil), by name.
function M.offered(view)
  view = view or daw.ui.focused
  local out = {}
  for _, s in pairs(M.list) do
    for _, v in ipairs(s.views) do
      if v == view then out[#out + 1] = s break end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- Load every `*.lua` file of a directory: each calls `daw.snippet.add` or
--- returns a list of snippets. `source` is "config" or "extension".
function M.load_dir(dir, source)
  local ok, entries = pcall(api.read_dir, dir)
  if not ok then return end
  table.sort(entries, function(a, b) return a.name < b.name end)
  for _, entry in ipairs(entries) do
    if not entry.is_dir and entry.name:match("%.lua$") then
      local path = dir .. "/" .. entry.name
      M.loading = source
      local chunk, err = loadfile(path)
      local done, result = false, err
      if chunk then done, result = xpcall(daw.limit.untrusted(chunk), debug.traceback) end
      if done and type(result) == "table" then
        for _, spec in ipairs(result.name and { result } or result) do M.add(spec) end
      elseif not done then
        daw.notify("snippets " .. path .. ": " .. tostring(result), "error")
      end
      M.loading = nil
    end
  end
end

-- The context ----------------------------------------------------------------------

local Ctx = {}
Ctx.__index = Ctx

--- The notes of this clip that sound together, as pitches: the chord that
--- starts last before `beat` (the cursor's), or nil.
function Ctx:before(beat)
  beat = beat or self.at
  local best, out = nil, {}
  for _, n in ipairs(self.notes) do
    if n.start < beat - 1e-9 and (not best or n.start > best + 1e-6) then best = n.start end
  end
  if not best then return nil end
  for _, n in ipairs(self.notes) do
    if math.abs(n.start - best) < 1 / 16 then out[#out + 1] = n.pitch end
  end
  table.sort(out)
  return out
end

--- The pitches of the first chord of this clip starting at `beat`, or
--- within a beat after it.
function Ctx:after(beat)
  beat = beat or self.at
  local best, out = nil, {}
  for _, n in ipairs(self.notes) do
    if n.start >= beat - 1e-9 and n.start < beat + 1 and (not best or n.start < best - 1e-6) then best = n.start end
  end
  if not best then return nil end
  for _, n in ipairs(self.notes) do
    if math.abs(n.start - best) < 1 / 16 then out[#out + 1] = n.pitch end
  end
  table.sort(out)
  return out
end

--- The pitches other pitched tracks play inside this track's range at
--- `beat` (sounding just before it with `before`), or nil: what to lead
--- from or into when this clip has nothing there.
function Ctx:around(beat, before)
  local out = {}
  for _, n in ipairs(self.harmony.notes()) do
    local inside = n.pitch >= self.range.low and n.pitch <= self.range.high and n.clip ~= self.clip_id
    local sounding = before and (n.start < beat - 1e-9 and n.start + n.length >= beat - 1e-9)
      or (not before and math.abs(n.start - beat) < 1 / 16)
    if inside and sounding then out[#out + 1] = n.pitch end
  end
  table.sort(out)
  return #out > 0 and out or nil
end

--- Pitches for a chord (pitch classes, root first) in the track's range,
--- led from what this clip plays before `opts.from` (the cursor) and into
--- what it plays at `opts.to`; where it plays nothing, from and into what
--- the other tracks play in its range. Options as
--- `daw.harmony.voice.voice`; the style is the `voicing` choice when there
--- is one.
function Ctx:voice(tones, opts)
  opts = opts or {}
  local from = opts.from or self.at
  local prev = opts.prev
  if prev == nil then prev = self:before(from) or self:around(from, true) end
  local nxt = opts.next
  if nxt == nil and opts.to then nxt = self:after(opts.to) or self:around(opts.to, false) end
  local count = opts.count or math.max(math.min(#tones, 4), prev and math.min(#prev, 4) or 0, 3)
  return harmony.voice.voice(tones, {
    low = opts.low or self.range.low, high = opts.high or self.range.high,
    style = opts.style or self.values.voicing, prev = prev, next = nxt, count = count, bass = opts.bass,
    center = self.pitch,
  })
end

--- A chord as notes from `from` to `to` (project beats), voiced by `voice`.
function Ctx:chord(tones, from, to, opts)
  opts = opts or {}
  local pitches = opts.pitches or self:voice(tones, { from = from, to = to, style = opts.style, prev = opts.prev, next = opts.next, bass = opts.bass, count = opts.count })
  local out = {}
  for _, p in ipairs(pitches or {}) do
    out[#out + 1] = { pitch = p, start = from, length = to - from, velocity = opts.velocity or self.velocity }
  end
  return out, pitches
end

--- Where the snippet should end when nothing says: the next chord's start,
--- else the end of the bar after the cursor.
function Ctx:until_next()
  local nxt = self.harmony.next(self.at)
  if nxt then return nxt.at, nxt end
  return daw.time.bar_ceil(self.at + 1e-9)
end

--- The context of an expansion in the piano roll, or nil and why not.
--- `opts`: `at` (project beats, the cursor's when nil), `count`, `values`,
--- `selection` (a region; the visual selection's when nil).
function M.context(opts)
  opts = opts or {}
  local roll = daw.ui.views.pianoroll
  local clip = roll and roll:clip()
  if not clip then return nil, "open a MIDI clip in the piano roll" end
  local c = clip:get()
  local notes = {}
  for i, n in ipairs(clip:notes()) do
    notes[i] = { pitch = n.pitch, start = c.start + n.start, length = n.length, velocity = n.velocity, place = i }
  end
  local ctx = setmetatable({
    view = "pianoroll", clip = clip, clip_id = c.id, track = clip:track(), track_id = c.track,
    at = opts.at or (c.start + roll.beat), pitch = roll.pitch, start = c.start,
    harmony = harmony, grid = daw.opt.note_grid, count = opts.count or 1, opt = daw.opt,
    range = harmony.range(c.track), velocity = daw.opt.velocity, values = opts.values or {}, notes = notes,
  }, Ctx)
  ctx.key = harmony.key(ctx.at)
  local region = opts.selection
  if region == nil and daw.ui.focused == "pianoroll" then region = daw.keymap.selection() end
  if region then
    ctx.selected_region = region
    local found, places = daw.edit.roll.notes(clip, region)
    ctx.selection = {}
    for i, n in ipairs(found) do
      ctx.selection[i] = { pitch = n.pitch, start = c.start + n.start, length = n.length, velocity = n.velocity, place = places[i] }
    end
    ctx.region = { from = c.start + region.c0, to = c.start + region.c1 }
  end
  return ctx
end

-- Expanding ----------------------------------------------------------------------------

--- The value of each choice: its current one, else its first.
local function chosen(choices, index)
  local values = {}
  for _, choice in ipairs(choices or {}) do
    values[choice.name] = choice.values[(index[choice.name] or 1)]
    if values[choice.name] == nil then values[choice.name] = choice.values[1] end
    index[choice.name] = index[choice.name] or 1
  end
  return values
end

--- Run a snippet: its notes (project beats), its choices and what it
--- replaces, repeated `count` times one after another unless it takes the
--- count itself (`count = true`). Nil and a reason when it has nothing.
local function run(spec, opts, index)
  local ctx, why = M.context(opts)
  if not ctx then return nil, why end
  local times = spec.count and 1 or (opts.count or 1)
  local all, remove, choices = {}, {}, nil
  local at = ctx.at
  for k = 1, times do
    local c = k == 1 and ctx or M.context(daw.util.merge(opts, { at = at, selection = false }))
    if k > 1 then c.count = 1 end
    c.values = chosen(choices or spec.choices, index)
    local ok, result, reason = xpcall(spec.expand, debug.traceback, c)
    if not ok then return nil, tostring(result) end
    if not result then
      if k == 1 then return nil, reason or "nothing to write here" end
      break
    end
    if k == 1 then
      choices = result.choices or spec.choices
      local values = chosen(choices, index)
      -- First run: the choices were not known yet; run again with them.
      local again = false
      for name, v in pairs(values) do
        if c.values[name] ~= v then again = true end
      end
      if again then
        c.values = values
        result = spec.expand(c) or result
      end
    end
    local notes = result.notes or {}
    for _, choice in ipairs(choices or {}) do
      if choice.apply then notes = choice.apply(result, c.values[choice.name]) or notes end
    end
    local finish = at
    for _, n in ipairs(notes) do
      all[#all + 1] = n
      finish = math.max(finish, (n.start or n.at) + n.length)
    end
    for _, n in ipairs(result.remove or {}) do remove[#remove + 1] = n end
    if finish <= at + 1e-9 then break end
    at = finish
  end
  if #all == 0 and #remove == 0 then return nil, "nothing to write here" end
  return { notes = all, remove = remove, choices = choices or {}, ctx = ctx }
end

--- What a snippet would write here, without writing it: `{ notes, choices,
--- ctx }` or nil and why.
function M.preview(name, opts)
  local spec = M.list[name]
  if not spec then return nil, "no snippet " .. tostring(name) end
  return run(spec, opts or {}, {})
end

local active      -- the snippet being edited: see `expand`
M.previewing = nil -- what the picker would write: `{ clip, notes }` for drawing

--- Write `result` into its clip in place of what the clip held before.
local function write(state, result)
  local clip = daw.clip(state.clip)
  local start = state.start
  local removed = {}
  for _, n in ipairs(result.remove) do
    if n.place then removed[n.place] = true end
  end
  local list = {}
  for i, n in ipairs(state.before) do
    if not removed[i] then list[#list + 1] = n end
  end
  local finish = 0
  for _, n in ipairs(result.notes) do
    local s = (n.start or n.at) - start
    if s >= -1e-9 then
      list[#list + 1] = { pitch = n.pitch, start = math.max(0, s), length = n.length, velocity = n.velocity or daw.opt.velocity, meta = n.meta }
      finish = math.max(finish, s + n.length)
    end
  end
  local length = state.length
  if finish > length + 1e-9 then length = daw.time.bar_ceil(start + finish - 1e-9) - start end
  if math.abs(clip.length - length) > 1e-9 then clip.length = length end
  api.clip_set_notes(state.clip, list)
  state.notes, state.span = result.notes, { from = result.ctx.at, to = result.ctx.at }
  for _, n in ipairs(result.notes) do
    state.span.from = math.min(state.span.from, n.start or n.at)
    state.span.to = math.max(state.span.to, (n.start or n.at) + n.length)
  end
  for _, n in ipairs(result.remove) do
    state.span.from = math.min(state.span.from, n.start)
    state.span.to = math.max(state.span.to, n.start + n.length)
  end
  state.edits = api.project_get().edits
end

local function describe(state)
  local choice = state.choices[state.current]
  local parts = { state.name }
  if choice then
    parts[#parts + 1] = string.format("%s: %s (%d/%d)", choice.name, tostring(choice.values[state.index[choice.name]]),
      state.index[choice.name], #choice.values)
  elseif #state.choices > 0 then
    parts[#parts + 1] = "Tab: " .. state.choices[1].name
  end
  return table.concat(parts, " · ")
end

--- Expand a snippet at the cursor of the piano roll (or over its
--- selection): `opts` `count`, `at`, `values` (a choice's value by name).
--- Returns the active snippet, or nil and why nothing was written.
function M.expand(name, opts)
  opts = opts or {}
  local spec = M.list[name]
  if not spec then return nil, "no snippet " .. tostring(name) end
  M.finish()
  local index = {}
  for k, v in pairs(opts.values or {}) do
    for _, choice in ipairs(spec.choices or {}) do
      if choice.name == k then
        for i, value in ipairs(choice.values) do
          if value == v then index[k] = i end
        end
      end
    end
  end
  local result, why = run(spec, opts, index)
  if not result then return nil, why end
  local clip = result.ctx.clip
  local c = clip:get()
  -- Leave visual mode: the selection is what the snippet worked on.
  if daw.keymap.mode == "x" then daw.keymap.set_mode("n") end
  api.undo_label("snippet " .. name)
  local state = {
    name = name, spec = spec, opts = { count = opts.count, at = result.ctx.at, selection = result.ctx.selected_region or false },
    clip = c.id, start = c.start, length = c.length, before = api.clip_notes(c.id),
    choices = result.choices, index = index, current = 0,
  }
  write(state, result)
  active = state
  daw.emit("snippet.expanded", { name = name, clip = c.id })
  daw.notify(describe(state))
  api.ui_redraw()
  return state
end

--- The active snippet, or nil. A snippet ends when the project changed
--- other than through it, or the piano roll's cursor left its span.
function M.active()
  if not active then return nil end
  local roll = daw.ui.views.pianoroll
  local clip = roll and roll:clip()
  local stale = api.project_get().edits ~= active.edits
  local away = not clip or clip.id ~= active.clip
    or clip.start + roll.beat < active.span.from - 1e-9 or clip.start + roll.beat > active.span.to + 1e-9
  if stale or away then M.finish() end
  return active
end

--- End the active snippet, keeping what it wrote.
function M.finish()
  if not active then return end
  local name = active.name
  active = nil
  daw.emit("snippet.finished", { name = name })
  api.ui_redraw()
end

--- Rewrite the active snippet with its choices as they are now, joining
--- the undo step that wrote it. It runs again on the clip as it was
--- before, so that it sees what it saw the first time.
local function rewrite(state)
  api.undo_join(api.undo_current())
  local clip = daw.clip(state.clip)
  api.clip_set_notes(state.clip, state.before)
  if math.abs(clip.length - state.length) > 1e-9 then clip.length = state.length end
  local result, why = run(state.spec, state.opts, state.index)
  if not result then
    daw.notify(why, "warn")
    return M.finish()
  end
  write(state, result)
end

--- Go to the next choice (`dir` 1) or the one before (-1). False when no
--- snippet is active, so that the key can do what it otherwise does.
function M.jump(dir)
  local state = M.active()
  if not state then return false end
  local n = #state.choices
  if n == 0 then
    daw.notify(state.name .. " has no choices")
    return true
  end
  state.current = (state.current - 1 + (dir or 1)) % n + 1
  daw.notify(describe(state))
  api.ui_redraw()
  return true
end

--- Step the current choice (the first when none is) to its next value
--- (`dir` 1) or the one before (-1), and rewrite the notes.
function M.step(dir)
  local state = M.active()
  if not state then return false end
  if #state.choices == 0 then
    daw.notify(state.name .. " has no choices")
    return true
  end
  if state.current == 0 then state.current = 1 end
  local choice = state.choices[state.current]
  local i = state.index[choice.name] or 1
  state.index[choice.name] = (i - 1 + (dir or 1)) % #choice.values + 1
  rewrite(state)
  daw.notify(describe(state))
  api.ui_redraw()
  return true
end

--- The active snippet's notes and span in the clip's beats, for drawing:
--- `{ name, notes, from, to, label }`, or nil.
function M.marks(clip_id)
  local state = M.active()
  if not state or state.clip ~= clip_id then return nil end
  local notes = {}
  for i, n in ipairs(state.notes) do
    notes[i] = { pitch = n.pitch, start = (n.start or n.at) - state.start, length = n.length }
  end
  return { name = state.name, notes = notes, from = state.span.from - state.start, to = state.span.to - state.start, label = describe(state) }
end

-- The picker -------------------------------------------------------------------------

local function note_names(notes)
  local pitches, seen = {}, {}
  for _, n in ipairs(notes) do
    if not seen[n.pitch] then
      seen[n.pitch] = true
      pitches[#pitches + 1] = n.pitch
    end
  end
  table.sort(pitches)
  local out = {}
  for i, p in ipairs(pitches) do out[i] = daw.music.name(p) end
  return table.concat(out, " ")
end

--- Lines describing what a snippet would write here.
function M.describe_preview(spec, opts)
  local lines = { { text = spec.name, style = "Title" }, spec.desc ~= "" and spec.desc or nil }
  local result, why = run(spec, opts or {}, {})
  if not result then
    lines[#lines + 1] = ""
    lines[#lines + 1] = { text = why or "nothing to write here", style = "Comment" }
    return lines, nil
  end
  lines[#lines + 1] = ""
  -- The notes, a chord at a time.
  local groups, order = {}, {}
  for _, n in ipairs(result.notes) do
    local s = n.start or n.at
    local key = string.format("%.4f", s)
    if not groups[key] then
      groups[key] = { at = s, notes = {} }
      order[#order + 1] = groups[key]
    end
    table.insert(groups[key].notes, n)
  end
  table.sort(order, function(a, b) return a.at < b.at end)
  for i, g in ipairs(order) do
    if i > 8 then
      lines[#lines + 1] = string.format("… and %d more", #order - 8)
      break
    end
    lines[#lines + 1] = string.format("%-8s %s", daw.time.format(g.at), note_names(g.notes))
  end
  if #result.choices > 0 then
    lines[#lines + 1] = ""
    for _, choice in ipairs(result.choices) do
      lines[#lines + 1] = { text = choice.name .. ": " .. table.concat(choice.values, ", "), style = "Comment" }
    end
  end
  return lines, result
end

--- Open the picker of the snippets offered in the focused view; Enter
--- expands the one chosen, `count` times.
function M.pick(opts)
  opts = opts or {}
  local view = daw.ui.focused
  local items = M.offered(view)
  -- The context is the cursor's now, before the picker takes the keys.
  local region = view == "pianoroll" and daw.keymap.selection() or nil
  local run_opts = { count = opts.count, selection = region or false }
  return daw.pick({
    title = "Snippets",
    items = items,
    query = opts.query,
    format = function(s) return string.format("%-12s %s", s.name, s.desc) end,
    primary = function(s) return s.name end,
    empty = "No snippets here. Load extensions/snippets, or add your own with daw.snippet.add.",
    preview = function(s)
      local lines, result = M.describe_preview(s, run_opts)
      M.previewing = result and { clip = result.ctx.clip_id, start = result.ctx.start, notes = result.notes } or nil
      return lines
    end,
    on_choose = function(s)
      M.previewing = nil
      local _, why = M.expand(s.name, run_opts)
      if why then daw.notify(why, "warn") end
    end,
    on_cancel = function() M.previewing = nil end,
  })
end

--- The notes the picker would write, in the clip's beats, for drawing.
function M.preview_marks(clip_id)
  local p = M.previewing
  if not p or p.clip ~= clip_id or not daw.ui.float then return nil end
  local out = {}
  for i, n in ipairs(p.notes) do out[i] = { pitch = n.pitch, start = (n.start or n.at) - p.start, length = n.length } end
  return out
end

--- The piano roll's layer (see `views/pianoroll.lua`): the active
--- snippet's notes marked and its span along the bottom with what Tab and
--- `<C-n>` work on; what the picker would write, as ghosts.
M.layer = {
  order = 20,
  draw = function(_, g)
    local roll, glyphs = g.roll, daw.draw.g
    for _, n in ipairs(M.preview_marks(g.clip.id) or {}) do
      local row = g.row(n.pitch)
      if row then
        local x0 = g.x(n.start)
        roll:fill(x0, row, math.max(1, g.x(n.start + n.length) - x0), 1, " ", "SnippetGhost")
        roll:text(x0, row, glyphs.clip_start, "SnippetGhost")
      end
    end
    local m = M.marks(g.clip.id)
    if not m then return end
    for _, n in ipairs(m.notes) do
      local row = g.row(n.pitch)
      if row then
        local x0 = g.x(n.start)
        local w = math.max(1, g.x(n.start + n.length) - x0)
        roll:fill(x0, row, w, 1, " ", "SnippetNote")
        roll:text(x0, row, glyphs.clip_start, "SnippetNote")
        if w >= 4 then roll:text(x0 + 1, row, daw.music.name(n.pitch):sub(1, w - 1), "SnippetNote") end
      end
    end
    local x0, x1 = math.max(0, g.x(m.from)), math.min(g.width, g.x(m.to))
    if x1 > x0 then
      -- The span along the bottom row, and what it is doing, running on
      -- past it when the span is short.
      local label = " " .. m.label .. " "
      roll:fill(x0, g.rows - 1, x1 - x0, 1, " ", "SnippetSpan")
      roll:text(x0, g.rows - 1, daw.util.fit(label, math.min(api.str_width(label), g.width - x0)), "SnippetSpan")
    end
  end,
  marks = function(clip_id)
    local out = {}
    for _, n in ipairs(M.preview_marks(clip_id) or {}) do
      out[#out + 1] = { kind = "ghost", pitch = n.pitch, start = n.start, length = n.length }
    end
    local m = M.marks(clip_id)
    if m then
      for _, n in ipairs(m.notes) do out[#out + 1] = { kind = "mark", pitch = n.pitch, start = n.start, length = n.length } end
      out[#out + 1] = { kind = "span", start = m.from, length = m.to - m.from, label = m.label }
    end
    return out
  end,
}

daw.on("escape", function() M.finish() end)
daw.on("mode.changed", function(e)
  if e.old == "i" and e.mode == "n" then M.finish() end
end)

return M
