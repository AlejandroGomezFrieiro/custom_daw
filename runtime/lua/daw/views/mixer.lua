-- The mixer: one channel strip per track, the master after the last behind a
-- heavier rule. Each strip, top to bottom: the name on a plate in the
-- track's colour; its first devices and its sends when there is room; the
-- level meters for both sides beside the fader, with the loudest of late held
-- and 0 dB marked on the fader's rail; the peak and the fader in dB; the pan;
-- and the M S R I chips.
local api = daw.api
local util = daw.util

-- `row` is the row of a strip the cursor is on (daw/mixer_rows.lua): "volume",
-- "pan", "send2", "insert1", "mute" ...
local view = { scroll = 0, row = "volume" }
daw.seats.fields("mixer", view, { "scroll", "geometry", "row" }, { scroll = 0, row = "volume" })
local draw = daw.draw

local SCALE = 4 -- columns for the dB scale on the left

--- Columns a strip takes on a screen `w` wide, the gap after it included.
function view.strip_width(w)
  return w < 80 and 8 or 10
end

-- What the scale names: where the fader's cap is at each of these levels.
-- The meters beside it are linear in decibels from -60 (bottom) to 0 (top)
-- and have their loudest of late in numbers under them, so the scale is the
-- fader's and does not claim to be theirs.
local marks = { 6, 0, -6, -12, -24, -48 }

-- The fader's travel: most of it is the top twenty decibels, as on a desk.
local function fader_row(volume, rows)
  return math.floor(util.clamp((volume + 60) / 66, 0, 1) ^ 2.5 * (rows - 1) + 0.5)
end
view.fader_row = fader_row

-- `here` is the row the cursor is on, on the strip it is on (daw/mixer_rows.lua).
local function strip(buf, x, t, index, selected, height, sw, here)
  local g = draw.g
  local hue = draw.track_hue(t, index)
  local w = sw - 1
  buf:fill(x, 0, w, height, " ", selected and "TrackHeaderSel" or "TrackHeader")
  -- The name on a plate in the track's colour, lit for the track the cursor is on.
  buf:fill(x, 0, w, 1, " ", selected and hue.title_cur or hue.plate)
  buf:text(x + 1, 0, util.fit(t.name, w - 1))
  -- What modules mark on the strip (`daw.ui.layer("mixer", "strip", ...)`).
  daw.ui.paint("mixer", "strip", { buf = buf, x = x, y = 0, width = w, height = height, track = t.id })
  -- Where each part is, for the pointer.
  local parts = { x = x, w = w, id = t.id }
  local y = 1
  local vca = t.meta and t.meta.vca == true
  -- A VCA names the tracks it moves, with room; a track the VCAs it is under.
  if vca and height >= 12 then
    local members = daw.vca.members(t.id)
    for i = 1, 3 do
      local name = members[i] and api.track_get(members[i]).name
      if i == 3 and #members > 3 then name = "+" .. (#members - 2) .. " more" end
      buf:text(x + 1, y, util.fit(name or (i == 1 and "no tracks" or ""), w - 1), name and "TrackInfo" or "TrackIndex")
      y = y + 1
    end
  elseif height >= 20 then
    parts.devices = y
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
  -- The VCAs the track is under.
  if not vca and not t.master and height >= 12 then
    local words = daw.frontend.vca_words(t.id)
    if words ~= "" then buf:text(x + 1, y, util.fit("vca " .. words, w - 1), "TrackInfo") end
    y = y + 1
  end
  -- The sends, with more room.
  if height >= 24 then
    parts.sends = y
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

  -- With too little room for them, the devices and sends fold into one row
  -- that counts them (`3 ↗2`), or names the one the cursor is on: they are
  -- rows of the strip for `j` `k`, and must show.
  local devices, sends = t.devices or {}, t.sends or {}
  local fold_devices = not vca and not parts.devices and #devices > 0
  local fold_sends = not vca and not parts.sends and #sends > 0
  if (fold_devices or fold_sends) and height >= 10 then
    parts.compact = y
    local text
    if here and here.kind == "insert" and fold_devices then
      local ok, d = pcall(api.device_get, devices[here.index])
      text = (ok and d.bypass and g.bypass or "") .. (ok and d.name or "?")
    elseif here and here.kind == "send" and fold_sends then
      local send = sends[here.index]
      local okt, to = pcall(api.track_get, send.target)
      text = g.send .. (okt and to.name:sub(1, 3) or "?") .. " " .. string.format("%g", math.floor(send.level + 0.5))
    else
      text = (fold_devices and #devices .. " " or "") .. (fold_sends and g.send .. #sends or "")
    end
    buf:text(x + 1, y, util.fit(text, w - 1), "TrackInfo")
    y = y + 1
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
  -- What modules label the strip with, on the peak's row (`daw.ui.layer("mixer", "strip_foot", ...)`).
  daw.ui.paint("mixer", "strip_foot", { buf = buf, x = x + 1, y = y, width = w - 1, track = t.id })
  local vol = draw.db_text(t.volume)
  buf:text(x + w - #vol, y + 1, vol, selected and "Bright" or "TrackInfo")
  if not vca then draw.pan(buf, x + 1, y + 2, math.min(7, w - 1), t.pan or 0) end
  parts.fader, parts.rows, parts.vol, parts.pan, parts.pan_w, parts.chips = y - rows, rows, y + 1, y + 2, math.min(7, w - 1), y + 3
  if vca then
    draw.chips(buf, x + 1, y + 3, { { "M", t.mute, "Mute" }, { "S", t.solo, "Solo" } }, w >= 8 and 1 or 0)
    buf:text(x + 1, y + 2, "vca", "TrackIndex")
  elseif not t.master then
    draw.chips(buf, x + 1, y + 3, {
      { "M", t.mute, "Mute" }, { "S", t.solo, "Solo" }, { "R", t.armed, "Armed" }, { "I", t.monitor, "Monitor" },
    }, w >= 8 and 1 or 0)
  else
    buf:text(x + 1, y + 3, "master", "TrackIndex")
  end
  parts.y = parts.fader
  parts.chip_gap = w >= 8 and 1 or 0
  return parts
end

--- Mark the row of the strip the cursor is on (`j` `k` move it): a mark
--- on the strip's left edge beside the row, or the chip itself lit. A row
--- the strip has no room to show is named in the title bar alone.
local function mark_row(buf, parts, row)
  local g = draw.g
  local y
  if row.kind == "insert" and parts.devices and row.index <= 3 then y = parts.devices + row.index - 1
  elseif row.kind == "send" and parts.sends and row.index <= 2 then y = parts.sends + row.index - 1
  elseif (row.kind == "insert" or row.kind == "send") and parts.compact then y = parts.compact
  elseif row.kind == "volume" then y = parts.vol
  elseif row.kind == "pan" then y = parts.pan
  end
  if y then
    buf:fill(parts.x + 1, y, parts.w - 1, 1, nil, "Selected")
    return buf:text(parts.x, y, g.mark, "SelectedMark")
  end
  if row.kind == "toggle" then
    local order = { mute = 0, solo = 1, armed = 2, monitor = 3 }
    buf:fill(parts.x + 1 + order[row.field] * (1 + parts.chip_gap), parts.chips, 1, 1, nil, "Cursor")
  end
end

--- The tracks in the order of the strips: VCAs after the others.
local function strip_order()
  local tracks, vcas = {}, {}
  for _, id in ipairs(api.track_list()) do
    local list = daw.vca.is_vca(id) and vcas or tracks
    list[#list + 1] = id
  end
  table.move(vcas, 1, #vcas, #tracks + 1, tracks)
  return tracks
end

function view:render(buf, ctx)
  local g = draw.g
  local tracks = strip_order()
  -- The row under the cursor, by name and value, on the right of the title.
  local row, row_track = daw.mixer_rows.current()
  local here
  if row and ctx.focused then
    local name, value = daw.mixer_rows.describe_row(row_track, row)
    here = name .. " " .. value
  end
  local body = daw.ui.titlebar(buf, {
    name = "Mixer", context = #tracks .. (#tracks == 1 and " track" or " tracks"), focused = ctx.focused, right = here,
  })
  local w, h = body.width, body.height
  body:fill(0, 0, w, h, " ", "TrackHeader")
  local sw = view.strip_width(w + 1)
  local room = math.max(1, math.floor((w - SCALE - sw - 1) / sw))
  local cursor_track = daw.cursor.track_id()
  local index = 1
  for i, id in ipairs(tracks) do
    if id == cursor_track then index = i end
  end
  if index <= self.scroll then self.scroll = index - 1 end
  if index > self.scroll + room then self.scroll = index - room end
  self.scroll = util.clamp(self.scroll, 0, math.max(0, #tracks - room))
  local x, shown, block, strips = SCALE, 0, nil, {}
  for col = 0, room - 1 do
    local id = tracks[self.scroll + col + 1]
    if not id then break end
    block = strip(body, x, api.track_get(id), self.scroll + col + 1, id == cursor_track, h, sw,
      id == cursor_track and ctx.focused and row or nil)
    if id == cursor_track and row and ctx.focused then mark_row(body, block, row) end
    strips[#strips + 1] = block
    x, shown = x + sw, shown + 1
  end
  -- The master, after the last track behind a heavier rule.
  body:fill(x, 0, 1, h, g.strip_sep, "Rule")
  block = strip(body, x + 1, api.track_get(0), nil, false, h, sw) or block
  strips[#strips + 1] = block
  -- The scale beside the first strip, on the rows the fader's cap takes.
  if block and block.rows >= 6 then
    local last = nil
    for _, mark in ipairs(marks) do
      local row = block.y + block.rows - 1 - fader_row(mark, block.rows)
      local label = (mark > 0 and "+" or "") .. mark
      if row ~= last then body:text(SCALE - 1 - #label, row, label, mark == 0 and "FaderZero" or "MeterScale") end
      last = row
    end
  end
  self.geometry = { sw = sw, shown = shown, strips = strips }
end

daw.ui.view("mixer", view)
return view
