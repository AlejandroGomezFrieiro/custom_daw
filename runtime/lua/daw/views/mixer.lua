-- The mixer: one channel strip per track, the master after the last behind a
-- heavier rule. Each strip, top to bottom: the name on a plate in the
-- track's colour; its first devices and its sends when there is room; the
-- level meters for both sides beside the fader, with the loudest of late held
-- and 0 dB marked on the fader's rail; the peak and the fader in dB; the pan;
-- and the M S R I chips.
local api = daw.api
local util = daw.util

local view = { scroll = 0 }
local draw = daw.draw

local SCALE = 4 -- columns for the dB scale on the left

--- Columns a strip takes on a screen `w` wide, the gap after it included.
function view.strip_width(w)
  return w < 80 and 8 or 10
end

local marks = { 0, -6, -12, -24, -48 }

-- The fader's travel: most of it is the top twenty decibels, as on a desk.
local function fader_row(volume, rows)
  return math.floor(util.clamp((volume + 60) / 66, 0, 1) ^ 2.5 * (rows - 1) + 0.5)
end

local function strip(buf, x, t, index, selected, height, sw)
  local g = draw.g
  local hue = draw.track_hue(t, index)
  local w = sw - 1
  buf:fill(x, 0, w, height, " ", selected and "TrackHeaderSel" or "TrackHeader")
  -- The name on a plate in the track's colour, lit for the track the cursor is on.
  buf:fill(x, 0, w, 1, " ", selected and hue.title_cur or hue.plate)
  buf:text(x + 1, 0, util.fit(t.name, w - 1))
  local y = 1
  -- The first devices, with room.
  if height >= 20 then
    for i = 1, 3 do
      local id = (t.devices or {})[i]
      local ok, d = id ~= nil, nil
      if ok then ok, d = pcall(api.device_get, id) end
      if ok and d then
        buf:text(x + 1, y, util.fit((d.bypass and g.bypass or " ") .. d.name, w - 1), d.bypass and "TrackIndex" or "TrackInfo")
      else
        buf:text(x + 1, y, util.fit(i == 1 and g.dot or "", w - 1), "TrackIndex")
      end
      y = y + 1
    end
  end
  -- The sends, with more room.
  if height >= 24 then
    for i = 1, 2 do
      local send = (t.sends or {})[i]
      if send then
        local okt, to = pcall(api.track_get, send.target)
        local text = g.send .. (okt and to.name:sub(1, 3) or "?") .. " " .. string.format("%g", math.floor(send.level + 0.5))
        buf:text(x + 1, y, util.fit(text, w - 1), "TrackInfo")
      end
      y = y + 1
    end
  end

  -- Meters and fader, over what the rows under them leave.
  local rows = math.max(1, height - y - 4)
  local left, right = api.track_meter(t.id)
  local hold = draw.hold("mix" .. t.id, math.max(left, right))
  draw.vmeter(buf, x + 1, y, rows, left, hold)
  draw.vmeter(buf, x + 2, y, rows, right, hold)
  local fx = x + math.floor(w / 2) + 1
  local at = fader_row(t.volume, rows)
  local zero = fader_row(0, rows)
  buf:fill(fx, y, 1, rows, g.fader_rail, "FaderTrack")
  buf:text(fx, y + rows - 1 - zero, g.zero, "FaderZero")
  buf:text(fx - 1, y + rows - 1 - at, g.fader .. g.fader .. g.fader, selected and "FaderSel" or "Fader")
  y = y + rows
  -- The loudest of late, then the fader, in dB.
  local db = 20 * math.log10(math.max(hold, 1e-6))
  local peak = db < -60 and "-inf" or string.format("%.1f", db)
  buf:text(x + w - #peak, y, peak, db > -0.1 and "MeterHigh" or "TrackIndex")
  local vol = draw.db_text(t.volume)
  buf:text(x + w - #vol, y + 1, vol, selected and "Bright" or "TrackInfo")
  draw.pan(buf, x + 1, y + 2, math.min(7, w - 1), t.pan or 0)
  if not t.master then
    draw.chips(buf, x + 1, y + 3, {
      { "M", t.mute, "Mute" }, { "S", t.solo, "Solo" }, { "R", t.armed, "Armed" }, { "I", t.monitor, "Monitor" },
    }, w >= 8 and 1 or 0)
  else
    buf:text(x + 1, y + 3, "master", "TrackIndex")
  end
  return { y = y - rows, rows = rows }
end

function view:render(buf, ctx)
  local g = draw.g
  local tracks = api.track_list()
  local body = daw.ui.titlebar(buf, {
    name = "Mixer", context = #tracks .. (#tracks == 1 and " track" or " tracks"), focused = ctx.focused,
  })
  local w, h = body.width, body.height
  body:fill(0, 0, w, h, " ", "TrackHeader")
  local sw = view.strip_width(w + 1)
  local room = math.max(1, math.floor((w - SCALE - sw - 1) / sw))
  local index = daw.cursor.index() or 1
  if index <= self.scroll then self.scroll = index - 1 end
  if index > self.scroll + room then self.scroll = index - room end
  self.scroll = util.clamp(self.scroll, 0, math.max(0, #tracks - room))
  local cursor_track = daw.cursor.track_id()
  local x, shown, block = SCALE, 0, nil
  for col = 0, room - 1 do
    local id = tracks[self.scroll + col + 1]
    if not id then break end
    block = strip(body, x, api.track_get(id), self.scroll + col + 1, id == cursor_track, h, sw)
    x, shown = x + sw, shown + 1
  end
  -- The master, after the last track behind a heavier rule.
  body:fill(x, 0, 1, h, g.strip_sep, "Rule")
  block = strip(body, x + 1, api.track_get(0), nil, false, h, sw) or block
  -- The scale beside the first strip's meters.
  if block and block.rows >= 6 then
    for _, mark in ipairs(marks) do
      local level = (mark + 60) / 60
      local row = block.y + block.rows - 1 - math.floor(level * block.rows - 0.5)
      if row >= block.y then body:text(SCALE - 1 - #tostring(mark), math.max(block.y, row), tostring(mark), "MeterScale") end
    end
  end
  self.geometry = { sw = sw, shown = shown }
end

function view:on_mouse(event)
  if event.kind ~= "down" or not self.geometry then return end
  local col = math.floor((event.x - SCALE) / self.geometry.sw)
  if col < 0 or col >= self.geometry.shown then return end
  local id = api.track_list()[self.scroll + col + 1]
  if id then daw.cursor.set_track(id) end
end

daw.ui.view("mixer", view)
return view
