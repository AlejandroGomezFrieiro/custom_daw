-- The pointer in the piano roll: the window's pencil, as in REAPER's MIDI
-- editor, in cells. A press on empty grid draws a note as long as the drag
-- (a click gives the roll's note length), a press on a note chooses it and
-- a drag moves it, or either end of it; the right button drags a box that
-- chooses notes, or clicked removes a note or opens the menu; Alt and a
-- drag erases. The keyboard sounds a key; the velocity strip is drawn on.
-- Each gesture calls `daw.frontend.act` once, as the window does, and is
-- drawn as a layer of the roll until the button is let go. Beats are the
-- roll's (the active clip's); a note of another clip edited with it is
-- named by that clip and its place there.
local api = daw.api
local util = daw.util
local music = daw.music
local mouse = daw.mouse
local menus = require("daw.mouse_menus")
local strip = require("daw.views.pianoroll_strip")
local view = daw.ui.views.pianoroll
local A = daw.frontend.act

local function beat_at(self, tx) return mouse.beat(tx, self.scroll, self.geometry.zoom) end

--- The grid step a column falls in, or with `free` the column's own beat.
local function start_at(self, tx, free)
  if free then return beat_at(self, tx) end
  return mouse.on_grid(tx, self.scroll, self.geometry.zoom, daw.opt.note_grid)
end

--- Where the grid step a column falls in ends: a drag to a column takes in
--- the step drawn there.
local function end_at(self, tx, free)
  local beat = beat_at(self, tx + 1)
  if free then return beat end
  local grid = daw.opt.note_grid
  return math.ceil(beat / grid - 1e-6) * grid
end

--- What is under the pointer at `x`, `y` of the view: `area` "ruler",
--- "keys", "grid" or "velocity", the pitch, the column of the roll, and on
--- the grid the note there (its start in the roll's beats), the clip it is
--- in (`owner`) with its place there, and the part pressed ("start", "end"
--- or "body").
local function hit(self, x, y)
  local g = self.geometry
  local out = { tx = x - g.keys }
  local row = y - g.head
  if y == g.head - 1 then
    out.area = "ruler"
  elseif row >= 0 and row < g.rows then
    out.area = x < g.keys and "keys" or "grid"
    out.pitch = util.clamp(self.top - row, 0, 127)
  elseif row >= g.rows and row < g.rows + g.vel then
    out.area = "velocity"
  else
    out.area = "title"
  end
  out.beat = beat_at(self, out.tx)
  if out.area ~= "grid" then return out end
  local zoom = g.zoom
  -- The active clip's notes last, so that they win where clips overlap.
  local parts = self:parts()
  for k = #parts, 1, -1 do
    local part = parts[k]
    local notes, places = part.clip:notes({
      from = self.scroll - part.offset, to = self.scroll + g.span - part.offset, low = out.pitch, high = out.pitch,
    })
    for i, n in ipairs(notes) do
      local start = n.start + part.offset
      local x0 = math.floor((start - self.scroll) * zoom + 0.5)
      local nw = math.max(1, math.floor((start + n.length - self.scroll) * zoom + 0.5) - x0)
      if out.tx >= x0 and out.tx < x0 + nw then
        out.note = { pitch = n.pitch, start = start, length = n.length, velocity = n.velocity }
        out.owner, out.offset, out.place, out.part = part.id, part.offset, places[i], "body"
        if nw >= 3 and out.tx == x0 then out.part = "start" elseif nw >= 2 and out.tx == x0 + nw - 1 then out.part = "end" end
      end
    end
  end
  return out
end

local function say(n, clip)
  return string.format("%s  %s  length %g", music.name(n.pitch), daw.time.format(clip.start + n.start), n.length)
end

--- Draw notes where a gesture will put them, over the roll.
local function ghost(p, start, length, pitch)
  local row = p.row(pitch)
  if not row then return end
  local x0 = p.x(start)
  local w = math.max(1, p.x(start + length) - x0)
  p.roll:fill(x0, row, w, 1, " ", "MouseGhost")
  if w >= 4 then p.roll:text(x0 + 1, row, music.name(pitch):sub(1, w - 1), "MouseGhost") end
end

--- The notes a gesture on the note at `place` of clip `owner` takes
--- along: every chosen note of the clips edited, if it is one of them, as
--- `{ clip, place }` each.
local function grabbed(owner, place)
  local refs = daw.frontend.chosen_refs()
  for _, ref in ipairs(refs) do
    if ref[1] == owner and ref[2] == place then return refs end
  end
  return { { owner, place } }
end

local function among(owner, place)
  for _, other in ipairs(daw.frontend.chosen_notes(owner)) do
    if other == place then return true end
  end
  return false
end

--- A press on a note: chooses it, drags it and the chosen with it, or
--- either end of them.
local function press_note(self, e, h, clip)
  local id, place, n = h.owner, h.place, h.note
  if e.double then return A.remove_note(id, place) end
  local mode = (mouse.has(e, "C") or mouse.has(e, "S")) and "toggle" or "only"
  local deferred = mode ~= "only" or among(id, place)
  if not deferred then A.select_note(id, place, "only") end
  self:set(n.pitch, n.start)
  local free, copy = mouse.has(e, "S"), mouse.has(e, "C")
  local part = h.part
  local zoom = self.geometry.zoom
  mouse.grab(e, {
    roll = function(p)
      local d = mouse.gesture().d
      if not (d and d.moved) then return end
      local dbeat, dpitch = d.dx / zoom, -d.dy
      for _, ref in ipairs(grabbed(id, place)) do
        local m = daw.clip(ref[1]):notes()[ref[2]]
        if m then
          m.start = m.start + daw.roll_clips.offset(ref[1]) - daw.roll_clips.offset(clip.id)
          if part == "start" then
            local stop = m.start + m.length
            local start = math.min(stop - 1 / 64, m.start + dbeat)
            ghost(p, start, stop - start, m.pitch)
          elseif part == "end" then
            ghost(p, m.start, math.max(1 / 64, m.length + dbeat), m.pitch)
          else
            ghost(p, m.start + dbeat, m.length, util.clamp(m.pitch + dpitch, 0, 127))
          end
        end
      end
    end,
    drag = function(d)
      mouse.gesture().d = d
      local dbeat = d.dx / zoom
      local shown = part == "start" and { pitch = n.pitch, start = n.start + dbeat, length = n.length - dbeat }
        or part == "end" and { pitch = n.pitch, start = n.start, length = n.length + dbeat }
        or { pitch = util.clamp(n.pitch - d.dy, 0, 127), start = math.max(0, n.start + dbeat), length = n.length }
      mouse.hint(say(shown, clip))
    end,
    up = function(u)
      if not u.moved then
        if deferred then A.select_note(id, place, mode) end
        return
      end
      local dbeat = u.dx / zoom
      if part == "start" then
        A.stretch_notes(id, place, dbeat, nil, free)
      elseif part == "end" then
        A.stretch_notes(id, place, nil, dbeat, free)
      else
        A.drag_notes(id, place, dbeat, -u.dy, copy, free)
      end
    end,
  })
end

--- A press on empty grid: a note from the step pressed to the step the
--- pointer is let go over; a click gives the roll's note length.
local function press_draw(self, e, h, clip)
  local free = mouse.has(e, "S") or not daw.opt.note_snap
  local start, pitch, tx0 = start_at(self, h.tx, free), h.pitch, h.tx
  self:set(pitch, start)
  local function stop(tx) return end_at(self, math.max(tx, tx0), free) end
  mouse.grab(e, {
    roll = function(p)
      local d = mouse.gesture().d
      local length = d and d.moved and stop(d.x - self.geometry.keys) - start or self:step_length()
      ghost(p, start, length, pitch)
    end,
    drag = function(d)
      mouse.gesture().d = d
      if d.moved then
        mouse.hint(say({ pitch = pitch, start = start, length = stop(d.x - self.geometry.keys) - start }, clip))
      end
    end,
    up = function(u)
      local length = u.moved and stop(u.x - self.geometry.keys) - start or nil
      A.add_note(clip.id, pitch, start, length, free)
    end,
  })
end

--- A box drawn over the grid: the notes it touches are chosen. From the
--- right button (Shift adds, Ctrl turns over) or the left with Ctrl.
--- Without moving, the right button removes the note it was on (with Ctrl
--- opens the note's menu: its fixes) or opens the menu of the grid, and
--- the left with Ctrl edits the clip of another track's note shown there
--- too (or no longer).
local function press_box(self, e, h, clip)
  local x0, y0 = e.x, e.y
  local right = e.button == "right"
  local where = { x = e.x + (e.view_x or 0), y = e.y + (e.view_y or 0) }
  local g = self.geometry
  local function pitch_of(y) return util.clamp(self.top - (y - g.head), 0, 127) end
  mouse.grab(e, {
    roll = function(p)
      local d = mouse.gesture().d
      if not (d and d.moved) then return end
      local g2 = daw.draw.g
      local l, r = math.min(x0, d.x) - g.keys, math.max(x0, d.x) - g.keys
      local t, b = math.min(y0, d.y) - g.head, math.max(y0, d.y) - g.head
      p.roll:fill(l, t, r - l + 1, 1, g2.h, "MouseBox")
      p.roll:fill(l, b, r - l + 1, 1, g2.h, "MouseBox")
      p.roll:fill(l, t, 1, b - t + 1, g2.v, "MouseBox")
      p.roll:fill(r, t, 1, b - t + 1, g2.v, "MouseBox")
    end,
    drag = function(d) mouse.gesture().d = d end,
    up = function(u)
      if u.moved then
        local a, b = math.min(x0, u.x) - g.keys, math.max(x0, u.x) - g.keys
        local mode = mouse.has(u, "S") and "add" or (right and mouse.has(u, "C")) and "toggle" or "only"
        A.select_notes_box(clip.id, beat_at(self, a), pitch_of(y0), beat_at(self, b + 1), pitch_of(u.y), mode)
      elseif right and h.note and mouse.has(u, "C") then
        daw.ui.menu(menus.note(h.owner, h.place), where)
      elseif right and h.note then
        A.remove_note(h.owner, h.place)
      elseif right then
        daw.ui.menu(menus.roll(clip.id), where)
      else
        -- Ctrl and a click on another track's note shown behind: its clip
        -- is edited too, or no longer.
        A.context_click(clip.id, beat_at(self, h.tx), h.pitch)
      end
    end,
  })
end

--- Alt and a drag: every note the pointer crosses is taken away.
local function press_erase(self, e, h, clip)
  local g = self.geometry
  local function point(x, y) return { beat_at(self, x - g.keys + 0.5), self.top - (y - g.head) } end
  local stroke = { point(e.x, e.y) }
  mouse.grab(e, {
    drag = function(d) stroke[#stroke + 1] = point(d.x, d.y) end,
    up = function(u)
      stroke[#stroke + 1] = point(u.x, u.y)
      A.erase_notes(clip.id, stroke)
    end,
  })
end

--- The keyboard down the left: a key sounds under a click or a drag; the
--- right button dragged chooses the notes of the pitches it crosses.
local function press_keys(self, e, h, clip)
  local g = self.geometry
  local function pitch_of(y) return util.clamp(self.top - (y - g.head), 0, 127) end
  if e.button == "right" then
    return mouse.grab(e, {
      up = function(u)
        if u.moved then A.select_pitches(clip.id, h.pitch, pitch_of(u.y), mouse.has(u, "S") and "add" or mouse.has(u, "C") and "toggle" or "only") end
      end,
    })
  end
  A.audition(clip.id, h.pitch)
  local last = h.pitch
  mouse.grab(e, {
    drag = function(d)
      local pitch = pitch_of(d.y)
      if pitch ~= last then
        last = pitch
        A.audition(clip.id, pitch)
      end
    end,
  })
end

--- The velocity strip: what is drawn over it sets how hard the notes
--- under the stroke are played (only the chosen, if any are).
local function press_velocity(self, e, h, clip)
  local g = self.geometry
  local top = g.head + g.rows
  local half = 0.5 / g.zoom
  local function point(x, y)
    return { beat_at(self, x - g.keys) + half, util.clamp(1 - (y - top + 0.5) / g.vel, 0, 1) }
  end
  local stroke = { point(e.x, e.y) }
  mouse.grab(e, {
    drag = function(d)
      stroke[#stroke + 1] = point(d.x, d.y)
      mouse.hint(string.format("velocity %d", util.clamp(math.floor(stroke[#stroke][2] * 127 + 0.5), 1, 127)))
    end,
    up = function() A.draw_velocities(clip.id, stroke, half) end,
  })
end

--- The furthest left the roll scrolls: its start, or before it the start
--- of an earlier clip edited with it.
local function leftmost()
  return math.min(0, math.floor((daw.roll_clips.span())))
end

local function wheel(self, e, h)
  local step, sideways = mouse.wheel(e)
  local g = self.geometry
  if mouse.has(e, "C") and not sideways then
    -- Zoom in time, keeping the beat under the pointer where it is.
    local tx = math.max(0, h.tx)
    local at = beat_at(self, tx)
    local zoom = util.clamp(daw.opt.note_zoom * (step < 0 and math.sqrt(2) or 1 / math.sqrt(2)), 0.125, 64)
    daw.opt.note_zoom = zoom
    self.scroll = math.max(leftmost(), at - tx / zoom)
  elseif sideways or mouse.has(e, "S") then
    self.scroll = math.max(leftmost(), self.scroll + step)
  else
    self.top = util.clamp(self.top - 2 * step, g.rows - 1, 127)
  end
  self:follow()
end

--- Scrolling moves what is shown, so the cursor is brought along with it.
function view:follow()
  local g = self.geometry
  local span = g.span or 1
  self.pitch = util.clamp(self.pitch, self.top - g.rows + 1, self.top)
  self.beat = util.clamp(self.beat, self.scroll, math.max(self.scroll, self.scroll + span - 2 * daw.opt.note_grid))
  api.ui_redraw()
end

local hints = {
  grid = "click draws a note (drag for its length) · right drag chooses · right click for more · Alt drag erases",
  note = "click chooses · drag moves (Ctrl copies) · drag an end to resize · double or right click removes",
  keys = "click sounds the key · right drag chooses the notes of those pitches",
  velocity = "draw across the bars to set how hard the notes play (only the chosen, if any are)",
  controller = "draw with the button held · right drag draws a line · drag a move's head to move the chosen · Ctrl drag chooses · right click for more",
  ruler = "click moves the playhead",
}

local function hover(self, h, clip)
  local text
  if h.area == "grid" then
    local at = music.name(h.pitch) .. "  " .. daw.time.format(clip.start + math.max(0, h.beat))
    text = h.note and (say(h.note, clip) .. " · " .. hints.note) or (at .. " · " .. hints.grid)
  elseif h.area == "keys" then
    text = music.name(h.pitch) .. " · " .. hints.keys
  elseif h.area == "velocity" then
    text = h.tx < 0 and "click to choose what the strip shows: velocity or a controller"
      or strip.shown().kind and hints.controller or hints.velocity
  elseif h.area == "ruler" then
    text = hints.ruler
  end
  mouse.hint(text)
end

function view:on_mouse(e)
  local clip = self:clip()
  if not (self.geometry and self.geometry.keys and clip) then return end
  local h = hit(self, e.x, e.y)
  if e.kind == "move" then return hover(self, h, clip) end
  if mouse.wheel(e) then return wheel(self, e, h) end
  if e.kind ~= "down" then return end
  if e.button == "middle" then
    -- The middle button held pans.
    local scroll, top, zoom = self.scroll, self.top, self.geometry.zoom
    return mouse.grab(e, {
      drag = function(d)
        self.scroll = math.max(leftmost(), scroll - d.dx / zoom)
        self.top = util.clamp(top + d.dy, self.geometry.rows - 1, 127)
        self:follow()
      end,
    })
  end
  if h.area == "ruler" and h.tx >= 0 and e.button == "left" then return A.roll_seek(clip.id, beat_at(self, h.tx)) end
  if h.area == "keys" then return press_keys(self, e, h, clip) end
  if h.area == "velocity" and strip.press(self, e, clip) then return end
  if h.area == "velocity" and h.tx >= 0 and e.button == "left" then return press_velocity(self, e, h, clip) end
  if h.area ~= "grid" then return end
  if e.button == "right" or (e.button == "left" and mouse.has(e, "C") and not h.note) then
    return press_box(self, e, h, clip)
  end
  if e.button ~= "left" then return end
  if mouse.has(e, "A") then return press_erase(self, e, h, clip) end
  if h.note then return press_note(self, e, h, clip) end
  press_draw(self, e, h, clip)
end

-- What a gesture under way draws: over the notes, under the cursor.
view.layer("mouse", 60, function(p)
  local g = mouse.gesture()
  if g and g.roll then g.roll(p) end
end)
