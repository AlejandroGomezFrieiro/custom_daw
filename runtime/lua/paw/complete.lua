-- Completion: suggestions of what to write next, shown as ghost notes in the
-- piano roll, from any number of sources (nvim-cmp's core with Copilot's
-- ghost text). The runtime has no source of its own: without an extension
-- that registers one, nothing is ever suggested.
--
--   paw.complete.register({
--     name = "continue", priority = 50,
--     views = { "pianoroll" },
--     auto = true,                              -- may be asked after an idle pause
--     complete = function(ctx, done)            -- call done(items) once, now or later; done(nil) for nothing
--       done({ { label = "repeat the bar", notes = { { pitch = 60, start = ctx.at, length = 1 } } } })
--     end,
--     cancel = function(ctx) end,               -- a newer request superseded this one
--   })
--
-- A request asks every source for the view at once. What has arrived by
-- `paw.opt.complete_deadline_ms` shows, highest priority first; answers that
-- come later are added at the end. A source that fails, answers twice or
-- answers something that is not a list of items is skipped, and a request
-- that something newer replaced (another request, an edit of the clip, the
-- clip closing) is cancelled: its late answers are dropped.
--
-- An item: `label`, `detail`, `notes` (a note set to add: `{ pitch, start,
-- length, velocity }` with `start` in beats from the clip's start, as
-- `clip:notes()` gives them; `at` is taken for `start`, and velocity is 1 to
-- 127, `paw.opt.velocity` when left out), `remove` (places of the clip's
-- notes it replaces, as `clip:notes()` numbers them), `velocities` (`{
-- [place] = velocity }`) and `controls` (moves added to the clip's, as
-- `clip:controls()` gives them). `source` says where it came from: the
-- source's name, unless the item names one of its own (a server's).
local api = paw.api
local M = {}

paw.option.define("complete_auto", true)          -- ask the sources by themselves after an idle pause
paw.option.define("complete_idle_ms", 1200)       -- how long without an edit before that
paw.option.define("complete_deadline_ms", 300)    -- how long a request waits before showing what has arrived
paw.option.define("complete_audition", false)     -- play each alternative shown through the track

local EPS = 1e-6

local sources = {}    -- name -> spec
local request         -- the request being answered: { id, ctx, waiting, answers, late, timer }
local shown           -- what shows: { items, index, clip, stamp, trigger, keys }
local next_id = 0
local idle_timer

M.sources = sources

-- What shows and what is being asked are each person's own: a seat has its
-- suggestion, its request, its idle pause and what it is hearing.
local audition_stop
paw.seats.keep("complete",
  function() return shown, request, idle_timer, audition_stop end,
  function(s, r, i, a) shown, request, idle_timer, audition_stop = s, r, i, a end,
  function() return nil, nil, nil, nil end)

local function roll() return paw.ui.views.pianoroll end

local function busy()
  local t = api.transport_get()
  return t.playing or t.take ~= nil or (t.counting or 0) > 0
end

local function stamp_of(clip_id)
  local ok, c = pcall(api.clip_get, clip_id)
  return ok and c.stamp or nil
end

--- Add a source, or replace the one of the same name.
function M.register(spec)
  assert(type(spec) == "table" and type(spec.name) == "string" and type(spec.complete) == "function",
    "usage: paw.complete.register({ name = ..., complete = function(ctx, done) ... end })")
  sources[spec.name] = paw.util.merge(spec, {
    priority = spec.priority or 0,
    views = spec.views or { "pianoroll" },
    auto = spec.auto ~= false,
  })
end

--- Remove the source of a name.
function M.unregister(name)
  sources[name] = nil
end

--- The sources, highest priority first.
function M.list()
  local out = {}
  for _, s in pairs(sources) do out[#out + 1] = s end
  table.sort(out, function(a, b)
    if a.priority ~= b.priority then return a.priority > b.priority end
    return a.name < b.name
  end)
  return out
end

local function offers(source, view, trigger)
  if trigger == "auto" and not source.auto then return false end
  for _, v in ipairs(source.views) do
    if v == view then return true end
  end
  return false
end

-- Context ---------------------------------------------------------------------

--- What a request is about: the clip open in the piano roll, where the
--- suggestion starts and what is chosen there. Nil without an open clip.
---   clip, track      ids
---   start, length    where the clip is in the project, in beats
---   at, pitch        where the suggestion starts (clip beats) and the cursor's pitch
---   notes            the clip's notes, as `clip:notes()` gives them
---   selection        the chosen notes, or nil
---   grid, view, trigger ("manual" or "auto"), id
---   key              `paw.harmony.key(at)` when there is such a module
function M.context(trigger)
  local r = roll()
  local clip = r and r:clip()
  if not clip then return nil end
  local c = clip:get()
  local notes = clip:notes()
  -- After the chosen notes when there are any (with the pointer, or a
  -- selection in visual mode), else at the cursor: in insert mode that is
  -- right after the notes entered last.
  local selection
  local places = paw.frontend.chosen_notes(c.id)
  if #places > 0 then
    selection = {}
    for _, place in ipairs(places) do selection[#selection + 1] = notes[place] end
  else
    local region = paw.ui.focused == "pianoroll" and paw.keymap.selection()
    if region then
      for _, n in ipairs(notes) do
        if n.start >= region.c0 - EPS and n.start < region.c1 - EPS and n.pitch >= region.r0 and n.pitch <= region.r1 then
          selection = selection or {}
          selection[#selection + 1] = n
        end
      end
    end
  end
  local at = r.beat
  if selection then
    at = 0
    for _, n in ipairs(selection) do at = math.max(at, n.start + n.length) end
  end
  local key
  if paw.harmony and paw.harmony.key then
    local ok, k = pcall(paw.harmony.key, c.start + at)
    if ok then key = k end
  end
  return {
    clip = c.id, track = c.track, start = c.start, length = c.length, at = at, pitch = r.pitch,
    notes = notes, selection = selection, grid = paw.opt.note_grid, view = "pianoroll",
    trigger = trigger or "manual", key = key,
  }
end

-- Items -----------------------------------------------------------------------

local function number(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

--- A source's item made safe to draw and to apply, or nil when it holds
--- nothing usable. Places become the notes they name, so that they still
--- find them after part of the item has been accepted.
local function normalize(item, source, clip_notes)
  if type(item) ~= "table" then return nil end
  local out = {
    label = tostring(item.label or source), detail = item.detail and tostring(item.detail) or nil,
    source = type(item.source) == "string" and item.source or source, notes = {}, remove = {}, velocities = {}, controls = {},
  }
  for _, n in ipairs(type(item.notes) == "table" and item.notes or {}) do
    local start = n.start or n.at
    if type(n) == "table" and number(n.pitch) and number(start) and number(n.length) and n.length > 0 and start >= 0 then
      out.notes[#out.notes + 1] = {
        pitch = paw.util.clamp(math.floor(n.pitch + 0.5), 0, 127), start = start, length = n.length,
        velocity = number(n.velocity) and paw.util.clamp(math.floor(n.velocity + 0.5), 1, 127) or paw.opt.velocity,
      }
    end
  end
  table.sort(out.notes, function(a, b)
    if math.abs(a.start - b.start) > EPS then return a.start < b.start end
    return a.pitch < b.pitch
  end)
  for _, place in ipairs(type(item.remove) == "table" and item.remove or {}) do
    local n = clip_notes[place]
    if n then out.remove[#out.remove + 1] = { pitch = n.pitch, start = n.start } end
  end
  for place, v in pairs(type(item.velocities) == "table" and item.velocities or {}) do
    local n = clip_notes[place]
    if n and number(v) then
      out.velocities[#out.velocities + 1] = { pitch = n.pitch, start = n.start, length = n.length, velocity = paw.util.clamp(math.floor(v + 0.5), 1, 127) }
    end
  end
  for _, move in ipairs(type(item.controls) == "table" and item.controls or {}) do
    if type(move) == "table" and number(move.start) and type(move.type) == "string" and number(move.value) then
      out.controls[#out.controls + 1] = move
    end
  end
  if #out.notes + #out.remove + #out.velocities + #out.controls == 0 then return nil end
  return out
end

-- Showing ---------------------------------------------------------------------

local function changed()
  api.ui_redraw()
  paw.emit("complete.changed", { shown = shown ~= nil })
end

--- Hide what shows, and drop the request being answered.
function M.dismiss()
  M.cancel()
  if audition_stop then audition_stop() end
  if shown then
    shown = nil
    changed()
  end
end

local function audition_if_wanted()
  if paw.opt.complete_audition and shown and shown.keys then M.audition() end
end

local function show(items, clip, trigger, keys)
  if #items == 0 then return end
  shown = { items = items, index = 1, clip = clip, stamp = stamp_of(clip), trigger = trigger, keys = keys }
  changed()
  audition_if_wanted()
end

--- Show items as ghost notes in the piano roll without being a source: a
--- snippet's preview, what a fix would do. `opts.clip` is the clip they
--- are for (the one open), `opts.keys = false` shows them only, without
--- the keys that accept or step through them. Nothing, or an empty list,
--- hides them.
function M.show(items, opts)
  opts = opts or {}
  M.dismiss()
  local r = roll()
  local clip_id = opts.clip or (r:clip() and r.clip_id)
  if not clip_id or not items then return end
  local ok, notes = pcall(api.clip_notes, clip_id)
  if not ok then return end
  local list = {}
  for _, item in ipairs(items) do
    list[#list + 1] = normalize(item, item.source or opts.source or "preview", notes)
  end
  show(list, clip_id, "manual", opts.keys ~= false)
end

--- What shows: `{ items, index, item, clip }`, or nil. A suggestion asked
--- for by itself does not show while the transport plays or records.
function M.current()
  if not shown then return nil end
  if shown.trigger == "auto" and busy() then return nil end
  -- Another seat may have edited the clip since: what shows is stale.
  if stamp_of(shown.clip) ~= shown.stamp then return nil end
  return { items = shown.items, index = shown.index, item = shown.items[shown.index], clip = shown.clip }
end

local function keys_on()
  return shown ~= nil and shown.keys and M.current() ~= nil and paw.ui.focused == "pianoroll"
    and roll().clip_id == shown.clip
end

-- Requests --------------------------------------------------------------------

--- Drop the request being answered, telling the sources that still owe
--- an answer.
function M.cancel()
  local r = request
  if not r then return end
  request = nil
  if r.timer then paw.cancel(r.timer) end
  for name in pairs(r.waiting) do
    local source = sources[name]
    if source and source.cancel then
      local ok, err = pcall(source.cancel, r.ctx)
      if not ok then api.log("completion source " .. name .. " failed to cancel: " .. tostring(err)) end
    end
  end
end

--- Show what has arrived for the request, in the order of the sources'
--- priorities.
local function present(r)
  local items = {}
  for _, source in ipairs(M.list()) do
    for _, item in ipairs(r.answers[source.name] or {}) do items[#items + 1] = item end
  end
  r.presented = true
  if r.ctx.trigger == "auto" and busy() then return end
  show(items, r.ctx.clip, r.ctx.trigger, true)
end

local function answer(r, name, items)
  if request ~= r or not r.waiting[name] then return end
  r.waiting[name] = nil
  local list = {}
  if type(items) == "table" then
    for _, item in ipairs(items) do list[#list + 1] = normalize(item, name, r.ctx.notes) end
  end
  if r.presented then
    -- Late: added at the end of what shows, or shown if nothing does.
    if #list == 0 then return end
    if shown and shown.clip == r.ctx.clip then
      for _, item in ipairs(list) do shown.items[#shown.items + 1] = item end
      changed()
    elseif not (r.ctx.trigger == "auto" and busy()) then
      show(list, r.ctx.clip, r.ctx.trigger, true)
    end
  else
    r.answers[name] = list
    if next(r.waiting) == nil then
      if r.timer then paw.cancel(r.timer) end
      r.timer = nil
      present(r)
    end
  end
  if next(r.waiting) == nil and request == r then request = nil end
end

--- Ask every source for this view at once. `trigger` is "manual" (a key,
--- the default) or "auto". Returns the request's id, or nil when there is
--- nothing to ask about or nobody to ask.
function M.request(trigger)
  trigger = trigger or "manual"
  if trigger == "auto" and busy() then return nil end
  local ctx = M.context(trigger)
  if not ctx then return nil end
  local asked = {}
  for _, source in ipairs(M.list()) do
    if offers(source, ctx.view, trigger) then asked[#asked + 1] = source end
  end
  if #asked == 0 then return nil end
  M.dismiss()
  next_id = next_id + 1
  ctx.id = next_id
  local r = { id = next_id, ctx = ctx, waiting = {}, answers = {}, stamp = stamp_of(ctx.clip) }
  request = r
  for _, source in ipairs(asked) do r.waiting[source.name] = true end
  for _, source in ipairs(asked) do
    local once = false
    local function done(items)
      if once then return end
      once = true
      local ok, err = pcall(answer, r, source.name, items)
      if not ok then api.log("completion source " .. source.name .. ": " .. tostring(err)) end
    end
    -- Each source gets a context of its own to keep or change.
    local own = paw.util.merge(ctx, {})
    local ok, err = pcall(paw.limit.named, "the completion source " .. source.name, source.complete, own, done)
    if not ok then
      api.log("completion source " .. source.name .. " failed: " .. tostring(err))
      if trigger == "manual" then paw.notify("completion source " .. source.name .. " failed: " .. tostring(err):match("^[^\n]*"), "warn") end
      done(nil)
    end
  end
  if request == r and not r.presented then
    r.timer = paw.defer(function()
      r.timer = nil
      if request == r and not r.presented then present(r) end
    end, paw.opt.complete_deadline_ms)
  end
  return r.id
end

--- Whether a request is waiting for answers.
function M.pending()
  return request ~= nil
end

-- Choosing and accepting ------------------------------------------------------

--- Show the next alternative (`n` 1), the previous (-1), or with `absolute`
--- the `n`th.
function M.select(n, absolute)
  if not M.current() then return end
  local count = #shown.items
  local index = absolute and n or ((shown.index - 1 + n) % count) + 1
  if index < 1 or index > count then return end
  if index ~= shown.index then
    shown.index = index
    if audition_stop then audition_stop() end
    changed()
    audition_if_wanted()
  end
end

--- The places in `notes` of the notes named by pitch and start.
local function places_of(notes, named)
  local out, taken = {}, {}
  for _, want in ipairs(named) do
    for place, n in ipairs(notes) do
      if not taken[place] and n.pitch == want.pitch and math.abs(n.start - want.start) < EPS then
        taken[place] = true
        out[#out + 1] = place
        break
      end
    end
  end
  return out
end

--- Write the alternative that shows into the clip, as one edit: all of it,
--- or with `next_only` the notes of its first onset alone (a note, or the
--- notes of a chord that start together), keeping the rest showing. The
--- cursor goes to where the accepted part ends. Returns whether anything
--- was written.
function M.accept(next_only)
  local cur = M.current()
  if not cur then return false end
  local item, clip = cur.item, paw.clip(cur.clip)
  if not clip:exists() then
    M.dismiss()
    return false
  end
  local add, rest = item.notes, {}
  local until_beat = math.huge
  if next_only and #item.notes > 0 then
    local first = item.notes[1].start
    add = {}
    for _, n in ipairs(item.notes) do
      if math.abs(n.start - first) < EPS then add[#add + 1] = n else rest[#rest + 1] = n end
    end
    if rest[1] then until_beat = rest[1].start end
  end
  -- Replacements and velocity changes go with the part of the time accepted.
  local function within(list)
    local now, later = {}, {}
    for _, x in ipairs(list) do
      if x.start < until_beat - EPS then now[#now + 1] = x else later[#later + 1] = x end
    end
    return now, later
  end
  local remove, remove_later = within(item.remove)
  local velocities, velocities_later = within(item.velocities)
  local controls, controls_later = within(item.controls)

  local notes = clip:notes()
  local set = {}
  local places = places_of(notes, velocities)
  for i, place in ipairs(places) do set[#set + 1] = { index = place, velocity = velocities[i].velocity } end
  local finish = 0
  for _, n in ipairs(add) do finish = math.max(finish, n.start + n.length) end
  local c = clip:get()
  if finish > c.length + EPS then
    clip.length = paw.time.bar_ceil(c.start + finish - EPS) - c.start
  end
  clip:edit_notes({ set = set, remove = places_of(notes, remove), add = add })
  if #controls > 0 then
    local moves = clip:controls()
    for _, move in ipairs(controls) do moves[#moves + 1] = move end
    table.sort(moves, function(a, b) return a.start < b.start end)
    clip:set_controls(moves)
  end
  api.undo_label(next_only and "Accept the next notes of the suggestion" or "Accept the suggestion")

  local r = roll()
  if r.clip_id == cur.clip then
    local to = next_only and rest[1] and rest[1].start or finish
    if #add == 0 then to = r.beat end
    r:set(add[1] and add[#add].pitch or nil, to)
  end
  if next_only and (#rest + #remove_later + #velocities_later + #controls_later) > 0 then
    -- What is left keeps showing: the item without what was written, and
    -- no other alternative, since the others started from before it.
    shown.items = { paw.util.merge(item, { notes = rest, remove = remove_later, velocities = velocities_later, controls = controls_later }) }
    shown.index = 1
    shown.stamp = stamp_of(cur.clip)
    changed()
  else
    M.dismiss()
  end
  return true
end

-- Audition --------------------------------------------------------------------

--- Play the alternative that shows through the clip's track, starting a
--- bar before it with the notes already there, without changing the
--- project. Not while the transport runs.
function M.audition()
  local cur = M.current()
  if not cur then return end
  if busy() then return paw.notify("not while playing", "warn") end
  if audition_stop then audition_stop() end
  local item = cur.item
  local c = api.clip_get(cur.clip)
  local first = item.notes[1] and item.notes[1].start or roll().beat
  local from = math.max(0, first - paw.time.bar(c.start + first))
  local replaced = {}
  for _, x in ipairs(item.remove) do replaced[x.pitch .. "@" .. x.start] = true end
  local events = {}
  for _, n in ipairs(api.clip_notes(cur.clip)) do
    if n.start >= from - EPS and n.start < first - EPS and not replaced[n.pitch .. "@" .. n.start] then events[#events + 1] = n end
  end
  for _, n in ipairs(item.notes) do events[#events + 1] = n end
  local origin = paw.time.to_seconds(c.start + from)
  local function ms(beat) return math.max(0, (paw.time.to_seconds(c.start + beat) - origin) * 1000) end
  local track, timers, sounding = c.track, {}, {}
  local function stop()
    for _, t in ipairs(timers) do paw.cancel(t) end
    for pitch in pairs(sounding) do pcall(api.note_off, track, pitch) end
    if audition_stop == stop then audition_stop = nil end
  end
  audition_stop = stop
  for _, n in ipairs(events) do
    timers[#timers + 1] = paw.defer(function()
      sounding[n.pitch] = true
      pcall(api.note_on, track, n.pitch, n.velocity)
      paw.ui.poke()
    end, ms(n.start))
    timers[#timers + 1] = paw.defer(function()
      sounding[n.pitch] = nil
      pcall(api.note_off, track, n.pitch)
    end, math.max(ms(n.start) + 20, ms(n.start + n.length) - 5))
  end
end

-- Asking by itself ------------------------------------------------------------

local function idle_ask()
  idle_timer = nil
  if not paw.opt.complete_auto or shown or request or busy() then return end
  local mode = paw.keymap.mode
  if paw.ui.focused ~= "pianoroll" or paw.ui.float or not (mode == "n" or mode == "i") or paw.keymap.pending() ~= "" then return end
  M.request("auto")
end

--- Start the idle pause again: after an edit.
function M.poke()
  if idle_timer then paw.cancel(idle_timer) end
  idle_timer = nil
  if paw.opt.complete_auto and next(sources) then idle_timer = paw.defer(idle_ask, paw.opt.complete_idle_ms) end
end

paw.on("clip.changed", function(e)
  local r = roll()
  if shown and shown.clip == e.id and stamp_of(e.id) ~= shown.stamp then M.dismiss() end
  if request and request.ctx.clip == e.id and stamp_of(e.id) ~= request.stamp then M.cancel() end
  if r and r.clip_id == e.id then M.poke() end
end)

paw.on("clip.removed", function(e)
  if (shown and shown.clip == e.id) or (request and request.ctx.clip == e.id) then M.dismiss() end
end)

paw.on("option.changed", function(e)
  if e.name == "complete_auto" then
    if e.value then M.poke() elseif shown and shown.trigger == "auto" then M.dismiss() end
  end
end)

paw.on("project.loaded", function() M.dismiss() end)

-- Drawing ---------------------------------------------------------------------

local styles = {}

--- The terminal's shades for ghost notes of a colour: a faint fill with
--- the colour's own text, and the badge.
local function ghost_style(colour)
  local palette = require("paw.theme").palette
  local key = colour .. palette.bg
  if not styles[key] then
    local name = "CompleteGhost_" .. colour:sub(2)
    local mix = paw.draw.mix
    paw.ui.hl(name, { fg = mix(palette.bg, colour, 0.9), bg = mix(palette.bg, colour, 0.22), italic = true })
    paw.ui.hl(name .. "_badge", { fg = palette.bg, bg = mix(palette.bg, colour, 0.7), bold = true })
    styles[key] = { note = name, badge = name .. "_badge" }
  end
  return styles[key]
end

local function badge_text(cur)
  local item = cur.item
  return string.format(" %d/%d %s ", cur.index, #cur.items, item.label ~= item.source and item.source .. ": " .. item.label or item.label)
end

local function paint(l)
  local cur = M.current()
  if not cur or cur.clip ~= l.data.id then return end
  local colour = paw.draw.track_colour(api.track_get(l.data.track))
  local style = ghost_style(colour)
  local g = paw.draw.g
  -- Dashed, to tell them from notes that are there and from other tracks'.
  local dash = paw.opt.ascii and "-" or "┄"
  local highest
  for _, n in ipairs(cur.item.notes) do
    local row = l.row(n.pitch)
    local x0, x1 = l.x(n.start), l.x(n.start + n.length)
    if row and x1 > 0 and x0 < l.width then
      local w = math.max(1, x1 - x0)
      l.roll:fill(x0, row, w, 1, dash, style.note)
      l.roll:text(x0, row, g.clip_start, style.note)
      if w >= 4 then l.roll:text(x0 + 1, row, paw.music.name(n.pitch):sub(1, w - 1), style.note) end
    end
    highest = math.max(highest or n.pitch, n.pitch)
  end
  for _, v in ipairs(cur.item.velocities) do
    local row = l.row(v.pitch)
    if row then l.roll:text(l.x(v.start), row, tostring(v.velocity), style.badge) end
  end
  -- The badge: which alternative of how many, and from where, above it.
  local first = cur.item.notes[1] or cur.item.velocities[1] or cur.item.remove[1]
  local at = first and first.start or roll().beat
  -- Kept on screen when the notes reach past its top or bottom.
  local row = paw.util.clamp(l.top - ((highest or roll().pitch) + 1), 0, l.rows - 1)
  local x = math.max(0, math.min(l.x(at), l.width - 12))
  local w = l.roll:text(x, row, badge_text(cur), style.badge)
  -- A click on it accepts the suggestion.
  l.roll:hit(x, row, w, 1, {
    kind = "act", act = "complete_badge", arg = cur.index, tip = "accept the suggestion (Tab; Ctrl-l its next notes) · Esc dismisses",
  })
end

roll().layer("complete", 50, paint)

roll():key_scope("pianoroll.complete", 50, keys_on)
-- The terminal's key line while a suggestion shows.
local keyline = {
  { "<Tab>", "accept" }, { "<C-l>", "next notes" }, { "<C-n>", "other" }, { "<A-1>", "pick", "Alt-1…9" },
  { "<Esc>", "dismiss" },
}
paw.ui.keybar.set("pianoroll.complete", "n", paw.util.merge(keyline, { [6] = { "gh", "hear" } }))
paw.ui.keybar.set("pianoroll.complete", "i", keyline)
roll():tool("complete", function() return M.tool() end)

-- The window's gestures -------------------------------------------------------

local act = paw.frontend.act

--- A click on a suggestion's chip: show that alternative, or accept it
--- when it is the one showing.
function act.complete_badge(_, index)
  local cur = M.current()
  if not cur then return end
  if index == cur.index then return M.accept() end
  M.select(index, true)
end

function act.complete_accept() return M.accept() end
function act.complete_dismiss() return M.dismiss() end
function act.complete_request() return M.request("manual") end

--- The toolbar's switch for suggestions that come by themselves.
function act.toggle_complete_auto()
  paw.opt.complete_auto = not paw.opt.complete_auto
end

--- What the window's piano roll toolbar shows of completion: nil without sources.
function M.tool()
  if not next(sources) then return nil end
  return {
    label = "Suggest", on = paw.opt.complete_auto, act = "toggle_complete_auto",
    tip = "suggestions: ask the completion sources by themselves after a pause (Ctrl-Space asks now) · Tab accepts, Esc dismisses",
  }
end

return M
