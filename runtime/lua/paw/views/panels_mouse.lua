-- The pointer in the mixer, the device panel and the session view: faders,
-- pans, sends and parameters dragged, buttons clicked, slots chosen,
-- launched and moved, as in the window, through `daw.frontend.act`. A
-- control follows the pointer as it moves; moves of one control close
-- together are one undo step.
local api = daw.api
local util = daw.util
local mouse = daw.mouse
local menus = require("daw.mouse_menus")
local A = daw.frontend.act

local function screen(e) return { x = e.x + (e.view_x or 0), y = e.y + (e.view_y or 0) } end

--- Drag a value: `set(start, d)` is called as the pointer moves, with the
--- value when the button went down. A fader or a pan held writes
--- automation in touch mode for as long as it is held.
local function drag(e, get, set, track, target)
  local start = get()
  if target then A.hold(track, target, 0, "", true) end
  local function let_go() if target then A.hold(track, target, 0, "", false) end end
  mouse.grab(e, { drag = function(d) set(start, d) end, up = let_go, cancel = let_go })
end

-- The mixer ------------------------------------------------------------------------------

local mixer = daw.ui.views.mixer

-- The fader's travel, as the mixer draws it: most of it is the top twenty decibels.
local function fader_position(volume) return util.clamp((volume + 60) / 66, 0, 1) ^ 2.5 end
local function fader_volume(position) return util.clamp(position, 0, 1) ^ (1 / 2.5) * 66 - 60 end

local flags = { "mute", "solo", "armed", "monitor" }

local function draw_db(volume) return daw.draw.db_text(volume) .. " dB" end

function mixer:on_mouse(e)
  local g = self.geometry
  if not (g and g.strips) then return end
  -- Under the title bar, in the strips' own lines.
  local x, y = e.x, e.y - 1
  local s
  for _, strip in ipairs(g.strips) do
    if x >= strip.x and x < strip.x + strip.w then s = strip end
  end
  if not s then return end
  local id = s.id
  local step, sideways = mouse.wheel(e)
  if step then
    if sideways or mouse.has(e, "S") then
      -- The strips scroll with the track the cursor is on.
      daw.cursor.move_track(step)
    else
      A.set_volume(id, api.track_get(id).volume - step)
    end
    return api.ui_redraw()
  end
  if e.kind == "move" then
    local t = api.track_get(id)
    return mouse.hint(t.name .. " · " .. draw_db(t.volume) .. " · drag the fader or the pan · double click resets · right click for more")
  end
  if e.kind ~= "down" then return end
  if id ~= 0 then daw.cursor.set_track(id) end
  if e.button == "right" then
    if id == 0 then return end
    return mouse.grab(e, { up = function(u) if not u.moved then daw.ui.menu(menus.track(id), screen(e)) end end })
  end
  if e.button ~= "left" then return end
  if y >= s.fader and y < s.fader + s.rows then
    if e.double then return A.set_volume(id, 0) end
    return drag(e, function() return fader_position(api.track_get(id).volume) end, function(start, d)
      local per = (mouse.has(d, "S") and 0.25 or 1) / math.max(1, s.rows - 1)
      A.set_volume(id, fader_volume(start - d.dy * per))
    end, id, "volume")
  elseif y == s.vol then
    if e.double then return A.set_volume(id, 0) end
    return drag(e, function() return api.track_get(id).volume end, function(start, d)
      A.set_volume(id, start + d.dx * (mouse.has(d, "S") and 0.1 or 1))
    end, id, "volume")
  elseif y == s.pan then
    if e.double then return A.set_pan(id, 0) end
    local function pan_at(px) return util.clamp((px - s.x - 1) / math.max(1, s.pan_w - 1) * 2 - 1, -1, 1) end
    if x > s.x and x <= s.x + s.pan_w then A.set_pan(id, pan_at(x)) end
    return drag(e, function() return 0 end, function(_, d) A.set_pan(id, pan_at(d.x)) end, id, "pan")
  elseif y == s.chips and id ~= 0 then
    local gap = s.w >= 8 and 1 or 0
    local i = (x - s.x - 1) / (1 + gap)
    if i == math.floor(i) and flags[i + 1] then A.toggle(id, flags[i + 1]) end
  elseif s.devices and y >= s.devices and y < s.devices + 3 then
    local index = y - s.devices + 1
    if (api.track_get(id).devices or {})[index] then A.pick_device(id, index) end
  elseif s.sends and y >= s.sends and y < s.sends + 2 then
    local index = y - s.sends + 1
    local send = (api.track_get(id).sends or {})[index]
    if not send then return end
    return drag(e, function() return send.level end, function(start, d)
      A.set_send(id, index, start + d.dx * (mouse.has(d, "S") and 0.1 or 1))
    end)
  end
end

-- The device panel ---------------------------------------------------------------------

local devices = daw.ui.views.devices

--- Where the parts of a parameter's line are on a panel `w` wide, as the
--- panel draws them: the slider's first column and its width.
local function slider(w)
  local name_w = math.min(12, math.max(4, w - 24))
  local at = 2 + name_w + 1
  return at, math.max(3, w - at - 9 - 1)
end

function devices:on_mouse(e)
  local rows = self:rows()
  local index = e.y + self.scroll
  local row = e.y >= 1 and rows[index] or nil
  local step = mouse.wheel(e)
  if step then
    if mouse.has(e, "C") and row and row.param then
      self.row = index
      self:adjust(-step)
    else
      self.row = self.row + step
    end
    return api.ui_redraw()
  end
  local w = e.w or 40
  if e.kind == "move" then
    if row and row.param then return mouse.hint(row.param.name .. " · drag the slider · double click puts it back · Ctrl and the wheel nudge it") end
    if row and not row.picture then return mouse.hint(row.device.name .. " · click on/off to bypass it") end
    return
  end
  -- A right click on a device or a parameter: automating a parameter, its
  -- fixes and what the servers say of it.
  if e.kind == "down" and e.button == "right" and row and not row.picture then
    self.row = index
    local uri = row.param and daw.address.param(row.device.id, row.param.key) or daw.address.device(row.device.id)
    local items = row.param and menus.param(row.device.id, row.param.key) or {}
    local lens = menus.lens({ uri = uri })
    if #items > 0 and #lens > 0 then items[#items + 1] = "-" end
    for _, item in ipairs(lens) do items[#items + 1] = item end
    if #items > 0 then
      return mouse.grab(e, { up = function(u) if not u.moved then daw.ui.menu(items, screen(e)) end end })
    end
    return api.ui_redraw()
  end
  if e.kind ~= "down" or e.button ~= "left" or not row then return end
  self.row = index
  api.ui_redraw()
  local d = row.device
  if row.param then
    local key = row.param.key
    if e.double then return A.reset_param(d.id, key) end
    local at, width = slider(w)
    local function fraction(x) return util.clamp((x - at + 0.5) / width, 0, 1) end
    if e.x >= at and e.x < at + width then A.set_param(d.id, key, fraction(e.x)) end
    return drag(e, function() return daw.params.fraction(row.param, api.device_get(d.id).params[key]) end, function(start, m)
      if mouse.has(m, "S") then
        A.set_param(d.id, key, util.clamp(start + m.dx / (width * 8), 0, 1))
      else
        A.set_param(d.id, key, fraction(m.x))
      end
    end)
  elseif not row.picture then
    -- The on and off chip at the right of the device's line.
    local chip = d.bypass and " off " or " on "
    local chip_at = w - #chip - 1
    if e.x >= chip_at and e.x < chip_at + #chip then A.toggle_bypass(d.id) end
  end
end

-- The session view -----------------------------------------------------------------------

local session = daw.ui.views.session

local slot_hints = {
  clip = "clip: its play mark launches it · click chooses · double click opens its notes · drag moves it, Ctrl copies · right click for more",
  empty = "empty slot: double click makes a MIDI clip · its dot records a bar into it",
  scene = "scene: launches every clip in its row together",
  stop = "stops the track's clip",
}

--- The column of the session view under `x`, if any.
local function slot_column(geo, x)
  for _, c in ipairs(geo.columns) do
    if x >= c.x - 1 and x < c.x + geo.cw - 1 then return c end
  end
end

function session:on_mouse(e)
  local geo = self.geometry
  if not geo then return end
  local launcher = daw.launcher
  -- Under the title bar, in the body's own lines.
  local x, y = e.x, e.y - 1
  local row = self.top + y - 1
  local step, sideways = mouse.wheel(e)
  if step then
    if sideways or mouse.has(e, "S") then daw.cursor.move_track(step) else self.top = math.max(0, self.top + step) end
    return api.ui_redraw()
  end
  local in_slots = y >= 1 and y <= geo.shown
  if x >= geo.sx then
    if e.kind == "move" then return mouse.hint(in_slots and slot_hints.scene or nil) end
    if e.kind ~= "down" or e.button ~= "left" then return end
    if y == geo.h - 1 then return A.stop_slots(nil) end
    if in_slots then return A.scene(row) end
    return
  end
  local col = slot_column(geo, x)
  if not col then return end
  local clip = in_slots and launcher.clip(col.id, row) or nil
  if e.kind == "move" then
    return mouse.hint(y == geo.h - 1 and slot_hints.stop or in_slots and (clip and slot_hints.clip or slot_hints.empty) or nil)
  end
  if e.kind ~= "down" then return end
  if y == geo.h - 1 then
    if e.button == "left" then A.stop_slots(col.id) end
    return
  end
  if not in_slots then return end
  if e.button == "right" then
    if clip then
      local where = screen(e)
      mouse.grab(e, { up = function(u) if not u.moved then daw.ui.menu(menus.clip(clip.id, clip.start), where) end end })
    end
    return
  end
  if e.button ~= "left" then return end
  if e.double then return A.open_slot(col.id, row) end
  if clip and x == col.x then
    -- The play mark launches it, and its release lets a gate or a one-shot go.
    A.press_slot(col.id, row, true)
    return mouse.grab(e, { up = function() A.press_slot(col.id, row, false) end })
  end
  if not clip and x == col.x + 1 then return A.record_slot(col.id, row) end
  A.choose_slot(col.id, row)
  if not clip then return end
  mouse.grab(e, {
    up = function(u)
      local to = u.moved and slot_column(geo, u.x)
      local to_row = self.top + u.y - 2
      if to and to_row >= 0 then A.move_slot(clip.id, to.id, to_row, mouse.has(u, "C")) end
    end,
  })
end
