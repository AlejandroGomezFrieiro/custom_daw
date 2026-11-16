-- The arrange view: track headers on the left, clips on a timeline on the right.
local api = daw.api
local util = daw.util

local view = {
  scroll = 0,    -- beat at the left edge of the timeline
  top = 1,       -- index of the first track shown
  flags = {},    -- header columns of the M, S, R and I chips, for the mouse
  -- What extensions draw on the timeline, by name, in name order, once the
  -- ruler and the tracks are drawn and before the playhead:
  --   daw.ui.views.arrange.layers.marks = function(view, layer) ... end
  -- `layer.ruler` is the timeline's part of the ruler row, `layer.ruler2`
  -- its second row when `view.ruler2` asks for one (else nil), and
  -- `layer.lanes` the timeline below, down to the master track;
  -- `layer.x(beat)` is the column of a beat in any of them. Also `scroll`, `zoom`, `span` (beats shown),
  -- `top`, `rows` and `th` (the first track shown, how many, rows per track).
  layers = {},
}

local draw = daw.draw

-- Small piano rolls and waveforms drawn inside clips, and what a header says
-- about its track's devices, kept until the project changes.
local previews, chains = {}, {}
daw.on("changed", function() previews, chains = {}, {} end)

--- The rows under a clip's name: its notes as a small piano roll, or its
--- waveform.
local function preview(clip, width, rows, zoom)
  local key = clip.id .. ":" .. width .. ":" .. rows .. ":" .. zoom
  if previews[key] then return previews[key] end
  local out
  if clip.kind == "midi" then
    out = draw.miniroll(daw.stretch.sounding(clip, api.clip_notes(clip.id)), width, rows, zoom)
  else
    -- A file that has gone missing has been reported already; draw nothing.
    local ok, peaks = pcall(api.clip_peaks, clip.id, width)
    out = draw.waveform(ok and peaks or {}, rows)
  end
  previews[key] = out
  return out
end

--- What a track's sound goes through, in a few words: `synth › delay`.
local function chain(t)
  if chains[t.id] then return chains[t.id] end
  local names = {}
  for _, id in ipairs(t.devices or {}) do
    local ok, device = pcall(api.device_get, id)
    if ok then names[#names + 1] = device.name end
  end
  local text = table.concat(names, " " .. draw.g.chain .. " ")
  chains[t.id] = text
  return text
end

view.meter = draw.meter

--- Columns for the track headers on a screen `w` wide, the rule on their
--- right included: `daw.opt.header_width`, or by the width with "auto".
function view.header_width(w)
  local want = tonumber(daw.opt.header_width)
  if not want then
    want = w >= 120 and 26 or w >= 100 and 22 or w >= 80 and 18 or 12
  end
  return math.max(4, math.min(want, w - 4))
end

--- Rows a track takes when `count` tracks share `room` rows:
--- `daw.opt.track_height`, or with "auto" as many as fit, from 3 to 6.
function view.track_height(count, room)
  local want = tonumber(daw.opt.track_height)
  if want then return math.max(1, math.floor(want)) end
  if count < 1 then return 3 end
  return util.clamp(math.floor(room / count), 3, 6)
end

--- Whether the ruler has a second row: when something registered in
--- `view.ruler2` (by name, a function of the view) has something to show.
---   daw.ui.views.arrange.ruler2.marks = function(view) return #my_marks > 0 end
view.ruler2 = {}

local function wants_ruler2(self)
  for _, wants in pairs(self.ruler2) do
    local ok, yes = pcall(wants, self)
    if ok and yes then return true end
  end
  return false
end

--- Where everything goes on a `w` by `h` view: the header width, the ruler's
--- rows, and the rows of the timeline, each `{ kind = "track", id, index, y,
--- h }` from the first track shown, then the master's. All placement is
--- here, so that rows of other kinds can be added in one place.
function view:layout(w, h)
  local tracks = daw.groups.rows()
  local hw = view.header_width(w)
  -- The ruler, its second row if something asks for one, and the tempo
  -- lane's two rows when it is shown.
  local tempo_rows = daw.tempolane.shown() and 2 or 0
  local ruler_rows = (wants_ruler2(self) and 2 or 1) + tempo_rows
  local master_rows = 2
  local room = math.max(1, h - ruler_rows - master_rows)
  -- Take lanes (a line each) and automation lanes shown as rows (two
  -- lines each) take their lines first.
  local lane_lines = 0
  for _, id in ipairs(tracks) do lane_lines = lane_lines + daw.takes.lane_count(id) + 2 * #daw.lanes.shown(id) end
  local th = view.track_height(#tracks, math.max(1, room - lane_lines))
  -- Squeezed by panels below, a track takes what there is rather than vanish.
  if not tonumber(daw.opt.track_height) and room < th then th = math.max(1, room) end
  local fit = math.max(1, math.floor(room / th))
  local cursor_index = daw.cursor.row() or 1
  if lane_lines > 0 then
    local rows, y = self:rows_with_lanes(tracks, th, ruler_rows, room, cursor_index)
    return {
      hw = hw, tw = w - hw, th = th, ruler_rows = ruler_rows, tempo_rows = tempo_rows, rows = rows, tracks = tracks,
      used = y, master = { kind = "master", id = 0, y = h - master_rows, h = master_rows },
    }
  end
  if cursor_index ~= self.seen_index or fit ~= self.seen_fit then
    if cursor_index < self.top then self.top = cursor_index end
    if cursor_index >= self.top + fit then self.top = cursor_index - fit + 1 end
  end
  self.seen_index, self.seen_fit = cursor_index, fit
  self.top = util.clamp(self.top, 1, math.max(1, #tracks - fit + 1))
  local rows, y = {}, ruler_rows
  for index = self.top, #tracks do
    if y + th > ruler_rows + room then break end
    rows[#rows + 1] = { kind = "track", id = tracks[index], index = index, y = y, h = th }
    y = y + th
  end
  return {
    hw = hw, tw = w - hw, th = th, ruler_rows = ruler_rows, tempo_rows = tempo_rows, rows = rows, tracks = tracks,
    used = y, master = { kind = "master", id = 0, y = h - master_rows, h = master_rows },
  }
end

--- The chips of a header, in order: mute, solo, arm, monitor.
local function chips(t)
  return {
    { "M", t.mute, "Mute", "mute" }, { "S", t.solo, "Solo", "solo" },
    { "R", t.armed, "Armed", "armed" }, { "I", t.monitor, "Monitor", "monitor" },
  }
end

--- What a track sends, in a few words: `↗ Reverb -9  ↗ Delay -12`.
local function sends_text(t)
  local out = {}
  for _, send in ipairs(t.sends or {}) do
    local ok, to = pcall(api.track_get, send.target)
    if ok then
      out[#out + 1] = draw.g.send .. " " .. to.name .. " " .. string.format("%g", math.floor(send.level * 10 + 0.5) / 10)
    end
  end
  return table.concat(out, "  ")
end

local function header(self, buf, y, height, t, index, selected, lanes, hue)
  local g = draw.g
  local w = buf.width
  local style = selected and "TrackHeaderSel" or "TrackHeader"
  buf:fill(0, y, w, height, " ", style)
  -- A stripe in the track's colour down its whole height.
  for row = 0, height - 1 do buf:text(0, y + row, selected and g.stripe_sel or g.stripe, hue.fg) end
  local narrow = w < 16
  if not narrow then buf:text(1, y, string.format("%2s", index or ""), selected and "TrackInfo" or "TrackIndex") end
  local name_at = narrow and 2 or 4

  -- The chips on the right: M S R I with room, MSRI in less, only those
  -- that are on in less still.
  local right = w - 1
  local list = not t.master and chips(t) or {}
  if narrow then
    local lit = {}
    for _, chip in ipairs(list) do if chip[2] then lit[#lit + 1] = chip end end
    list = lit
  end
  local gap = w >= 24 and 1 or 0
  local chips_w = #list > 0 and #list + gap * (#list - 1) or 0
  local chips_at = right - chips_w
  self.flags = {}
  if chips_w > 0 then
    draw.chips(buf, chips_at, y, list, gap)
    if not narrow then
      for i, chip in ipairs(list) do self.flags[chip[4]] = chips_at + (i - 1) * (1 + gap) end
    end
  end
  local before = chips_w > 0 and chips_at - 1 or right
  -- In front of the chips: an `A` when the track has automation, and
  -- the letter of its automation mode when that is not the usual one
  -- (Touch, Latch, Write, or `-` for off).
  local mode = t.automation or "read"
  if #lanes > 0 or mode ~= "read" then
    local on = false
    for _, lane in ipairs(lanes) do on = on or lane.enabled and lane.point_count > 0 end
    local letter = ({ read = "A", touch = "T", latch = "L", write = "W", off = "-" })[mode] or "A"
    local writes = mode == "touch" or mode == "latch" or mode == "write"
    buf:text(before - 1, y, letter, writes and "Armed" or (on and mode ~= "off") and "Automation" or "TrackIndex")
    before = before - 2
  end
  -- With one row, the volume goes there too.
  if height == 1 and not narrow then
    local vol = draw.db_text(t.volume)
    if before - #vol - 1 > name_at + 4 then
      buf:text(before - #vol, y, vol, "TrackInfo")
      before = before - #vol - 1
    end
  end
  -- A member of a group stands a step in under it; a group has a mark
  -- that says whether it is open, and when folded how many tracks it holds.
  local name = t.name
  if not t.master then
    local groups = daw.groups
    name = string.rep(" ", groups.depth(t.id)) .. name
    if groups.is_group(t.id) then
      name = (groups.folded(t.id) and g.closed or g.open) .. " " .. name
        .. (groups.folded(t.id) and (" +" .. #groups.members(t.id)) or "")
    end
  end
  local room = math.max(1, before - name_at)
  if api.str_width(name) > room then name = util.fit(name, room) end
  buf:text(name_at, y, name, selected and "TrackNameSel" or "TrackName")

  if height >= 2 then
    local left, r = api.track_meter(t.id)
    local peak = math.max(left, r)
    local vol = draw.db_text(t.volume)
    local vol_at = right - #vol
    if vol_at - 1 > name_at then
      draw.meter(buf, name_at, y + 1, vol_at - 1 - name_at, peak, draw.hold("track" .. t.id, peak))
    end
    buf:text(vol_at, y + 1, vol, selected and "Bright" or "TrackInfo")
  end

  -- The rows under: pan, devices and output; sends; the input.
  local lines = {}
  if height >= 3 then
    lines[#lines + 1] = "route"
    if #(t.sends or {}) > 0 then lines[#lines + 1] = "sends" end
    if not t.master and (t.input or daw.audio.label(t)) and height >= 4 then lines[#lines + 1] = "input" end
  end
  for i, kind in ipairs(lines) do
    local row = y + 1 + i
    if row >= y + height then break end
    local x = name_at
    local width = right - x
    if kind == "route" then
      local pan = draw.pan_text(t.pan or 0)
      if not (narrow and pan == "C") then
        buf:text(x, row, pan, pan == "C" and "TrackIndex" or "TrackInfo")
        x = x + (narrow and #pan + 1 or math.max(4, #pan + 1))
      end
      local out = ""
      if t.output and t.output ~= 0 then
        local ok, to = pcall(api.track_get, t.output)
        if ok then out = g.out .. " " .. to.name end
      end
      local devices = chain(t)
      local room_left = right - x
      if out ~= "" then
        local out_w = api.str_width(out)
        if out_w > room_left - 2 then out = util.fit(out, math.max(1, room_left - 2)) out_w = api.str_width(out) end
        buf:text(right - out_w, row, out, "TrackInfo")
        room_left = room_left - out_w - 1
      end
      if devices ~= "" and room_left > 2 then
        if api.str_width(devices) > room_left then devices = util.fit(devices, room_left) end
        buf:text(x, row, devices, "TrackRoute")
      end
    elseif kind == "sends" then
      local text = sends_text(t)
      if api.str_width(text) > width then text = util.fit(text, width) end
      buf:text(x, row, text, "TrackInfo")
    elseif kind == "input" then
      -- What the track takes in, with the level arriving there whether or
      -- not it is heard, so that a guitar can be seen before anything is armed.
      local label = daw.audio.label(t)
      if label then
        local heard = t.input and (t.monitor or t.armed)
        if t.input then
          local level = daw.audio.level(t)
          buf:text(x, row, view.level_glyph(level), level > 0.001 and "Input" or "TrackIndex")
          x = x + 2
        end
        label = util.fit(label, math.max(1, right - x))
        buf:text(x, row, label, heard and "Input" or "TrackInfo")
      end
    end
  end
end

--- One character for a level, 0 to 1 linear, from -60 dB up: a dot for silence.
function view.level_glyph(level)
  if level <= 0.001 then return draw.g.dot end
  local db = 20 * math.log10(level)
  return draw.g.eighths[util.clamp(math.floor((db + 60) / 60 * 8) + 1, 1, 8)]
end

--- The columns of the bar and beat lines on a timeline `width` wide.
local function grid_lines(scroll, zoom, width)
  local out = {}
  for _, line in ipairs(draw.bar_lines(scroll, width / zoom)) do
    out[#out + 1] = { x = math.floor((line.beat - scroll) * zoom + 0.5), bar = line.bar, beat = line.beat }
  end
  return out
end

local function lane(buf, y, height, track, selected, scroll, zoom, cursor_clip, lanes, hue, lines, loop)
  local g = draw.g
  local w = buf.width
  buf:fill(0, y, w, height, " ", selected and hue.lane_sel or "Lane")
  if loop then buf:fill(loop[1], y, loop[2] - loop[1], height, nil, "LaneLoop") end
  for _, line in ipairs(lines) do
    if line.bar then
      buf:fill(line.x, y, 1, height, g.bar, "LaneBar")
    elseif zoom >= 4 then
      buf:fill(line.x, y, 1, height, g.beat, "LaneBeat")
    end
  end
  local spans = {}
  for _, clip in ipairs(api.clip_list(track.id)) do
    local x0 = math.floor((clip.start - scroll) * zoom + 0.5)
    local x1 = math.floor((clip.start + clip.length - scroll) * zoom + 0.5)
    local cw = math.max(1, x1 - x0)
    if x0 < w and x0 + cw > 0 then
      spans[#spans + 1] = { x0, x0 + cw }
      local kind = clip.muted and "_off" or clip.id == cursor_clip and "_cur" or ""
      local box = buf:sub(x0, y, cw, height)
      box:fill(0, 0, cw, 1, " ", hue["title" .. kind])
      -- A clip with takes says which plays: `take 3 ‹2/4›`.
      local badge = daw.takes.badge(clip)
      local label = clip.offline and ("offline · " .. clip.name) or clip.name
      -- Stretched, shifted, looped: `×1.5 ⟳ drums`.
      local mark = daw.stretch.badge(clip)
      if mark then label = mark .. " " .. label end
      box:text(cw > 2 and 1 or 0, 0, badge and (label .. " ‹" .. badge .. "›") or label)
      if height >= 2 then
        box:fill(0, 1, cw, height - 1, " ", hue["body" .. kind])
        if clip.kind == "audio" or clip.note_count > 0 then
          for row, text in ipairs(preview(clip, cw, height - 1, zoom)) do box:text(0, row, text) end
        end
      end
      -- A notch where each repeat of a looped clip begins.
      for _, at in ipairs(daw.stretch.repeats(clip)) do
        local nx = math.floor(at * zoom + 0.5)
        if nx > 0 and nx < cw and height >= 2 then box:fill(nx, 1, 1, height - 1, g.step, "ClipEdge") end
      end
      -- A hairline where the clip starts, so that clips side by side stay apart.
      box:fill(0, 0, 1, height, g.clip_start, "ClipEdge")
    end
  end
  -- The volume curve runs over the empty lane, never over clips.
  for _, l in ipairs(lanes) do
    if height >= 2 and l.target == "volume" and l.point_count > 0 then
      local function over_clip(col)
        for _, span in ipairs(spans) do
          if col >= span[1] and col < span[2] then return true end
        end
        return false
      end
      draw.curve(buf:sub(0, y + 1, w, height - 1), 0, height - 1, function(i)
        if over_clip(math.floor(i / 2)) then return nil end
        return (api.lane_value_at(l.id, scroll + (i + 0.5) / (zoom * 2)) + 60) / 66
      end, l.enabled and "Automation" or "Faint")
    end
  end
  return spans
end

--- What a new project shows in place of tracks: how to begin.
local function welcome(buf)
  local lines = {
    { "o", "add a track" },
    { "a", "put an instrument on it" },
    { "i", "type notes: a s d f g h j k are a scale" },
    { "Space", "play, and stop" },
    { ",,", "find any command, track or device" },
    { "?", "every key that works where you are" },
    { ":", "run a command by name" },
  }
  if daw.commands.get("tutor") then lines[#lines + 1] = { ":tutor", "take the course, ten minutes a lesson" } end
  local x, y = math.max(2, math.floor((buf.width - 52) / 2)), math.max(1, math.floor((buf.height - #lines - 3) / 2))
  buf:text(x, y, "A new project", "WelcomeTitle")
  buf:text(x, y + 1, "Everything is driven from the keyboard. To begin:", "Dim")
  for i, line in ipairs(lines) do
    buf:text(x + 2, y + 2 + i, line[1], "HintKey")
    buf:text(x + 11, y + 2 + i, line[2], "Welcome")
  end
end

local scale = { -48, -24, -12, -6, 0 }

--- The master's level along the timeline: both sides in one row of half
--- blocks, the loudest of late in numbers beside them, and a scale under.
local function master_meter(buf, y, width)
  local left, right = api.track_meter(0)
  local x, mw = 1, math.min(40, width - 10)
  if mw < 8 then
    draw.meter(buf, 1, y, math.max(1, width - 2), math.max(left, right))
    return
  end
  draw.stereo_meter(buf, x, y, mw, left, right)
  local hold = draw.hold("master", math.max(left, right))
  local db = 20 * math.log10(math.max(hold, 1e-6))
  local text = db < -60 and "-inf" or string.format("%.1f", db)
  buf:text(x + mw + 2, y, text, db > -0.1 and "MeterHigh" or "TrackInfo")
  for _, mark in ipairs(scale) do
    local at = x + draw.db_cell(mark, mw)
    local label = tostring(mark)
    buf:text(math.min(at - math.floor(#label / 2), x + mw - #label), y + 1, label, "MeterScale")
  end
end

--- The rows from `self.top` when some tracks show their take lanes or their
--- automation lanes: each track, then a row `{ kind = "take", id, take,
--- index, y, h = 1 }` for each of its take lanes, then a row `{ kind =
--- "lane", id, lane, index, y, h = 2 }` for each of its automation lanes.
--- Scrolls so that the cursor's row is in view. Returns the rows and the
--- line after the last.
function view:rows_with_lanes(tracks, th, ruler_rows, room, cursor_index)
  local bottom = ruler_rows + room
  local function place(top)
    local out, y = {}, ruler_rows
    for index = top, #tracks do
      local id = tracks[index]
      if #out > 0 and y + th > bottom then break end
      out[#out + 1] = { kind = "track", id = id, index = index, y = y, h = th }
      y = y + th
      for k = 1, daw.takes.lane_count(id) do
        if y + 1 > bottom then return out, y, false end
        out[#out + 1] = { kind = "take", id = id, take = k, index = index, y = y, h = 1 }
        y = y + 1
      end
      for _, l in ipairs(daw.lanes.shown(id)) do
        if y + 2 > bottom then return out, y, false end
        out[#out + 1] = { kind = "lane", id = id, lane = l, index = index, y = y, h = 2 }
        y = y + 2
      end
    end
    return out, y, true
  end
  local function shows_cursor(rows)
    local lane = daw.cursor.lane_id()
    for _, row in ipairs(rows) do
      if row.index == cursor_index and ((row.kind == "track" and not lane) or (row.lane and row.lane.id == lane)) then
        return true
      end
    end
    return false
  end
  local lane = daw.cursor.lane_id()
  if cursor_index ~= self.seen_index or lane ~= self.seen_lane then
    if cursor_index < self.top then self.top = cursor_index end
    while self.top < cursor_index and not shows_cursor((place(self.top))) do self.top = self.top + 1 end
  end
  self.seen_index, self.seen_lane, self.seen_fit = cursor_index, lane, nil
  self.top = util.clamp(self.top, 1, math.max(1, #tracks))
  -- No room left empty below while tracks above are scrolled away.
  while self.top > 1 do
    local rows, _, whole = place(self.top - 1)
    if not whole or rows[#rows].index < #tracks or not shows_cursor(rows) then break end
    self.top = self.top - 1
  end
  return place(self.top)
end

--- One automation lane row: the header names what the lane moves, its value
--- at the cursor and whether it is read or bypassed; the timeline has its
--- curve and points.
function view:draw_lane_row(headers, timeline, row, lines)
  local l, y = row.lane, row.y
  local zoom, scroll = self.geometry.zoom, self.scroll
  local beat = daw.cursor.beat
  local hw, tw = headers.width, timeline.width
  local on = daw.cursor.lane_id() == l.id
  local hue = draw.track_hue(api.track_get(row.id), row.index)
  local style = on and "TrackHeaderSel" or "TrackHeader"
  headers:fill(0, y, hw, 2, " ", style)
  for r = 0, 1 do headers:text(0, y + r, "▏", hue.fg) end
  headers:text(2, y, util.fit("↳ " .. daw.lanes.name(l), math.max(1, hw - 3)), style)
  local state = l.enabled and "read" or "bypass"
  headers:text(math.max(2, hw - #state - 1), y + 1, state, l.enabled and "Automation" or "FlagOff")
  headers:text(4, y + 1, util.fit(daw.lanes.format(l, daw.lanes.value_at(l, beat)), math.max(1, hw - #state - 5)), "TrackInfo")
  timeline:fill(0, y, tw, 2, " ", on and hue.lane_sel or "Lane")
  for _, line in ipairs(lines) do
    if line.bar then timeline:fill(line.x, y, 1, 2, draw.g.bar, "LaneBar") end
  end
  -- Volume on the fader's useful stretch, -60 to +6 dB; the rest across their range.
  local lo, hi = l.min or 0, l.max or 1
  if l.target == "volume" then lo, hi = -60, 6 end
  local function level(v) return hi ~= lo and util.clamp((v - lo) / (hi - lo), 0, 1) or 0.5 end
  if l.point_count > 0 then
    draw.curve(timeline:sub(0, y, tw, 2), 0, 2, function(i)
      return level(api.lane_value_at(l.id, scroll + (i + 0.5) / (zoom * 2)))
    end, l.enabled and "Automation" or "Faint")
  end
  for _, p in ipairs(api.lane_points(l.id)) do
    local x = math.floor((p[1] - scroll) * zoom + 0.5)
    if x >= 0 and x < tw then timeline:text(x, level(p[2]) >= 0.5 and y or y + 1, "◆", l.enabled and "Automation" or "Faint") end
  end
  if not on then return end
  -- A selection on this lane: the stretch of time chosen.
  local selection = daw.keymap.selection()
  if selection then
    local x0 = math.max(0, math.floor((selection.c0 - scroll) * zoom + 0.5))
    local x1 = math.min(tw, math.floor((selection.c1 - scroll) * zoom + 0.5))
    if x1 > x0 then timeline:fill(x0, y, x1 - x0, 2, nil, "Visual") end
  end
  local x = math.floor((beat - scroll) * zoom + 0.5)
  local cw = math.max(1, math.floor(daw.opt.grid * zoom))
  timeline:fill(x, y, cw, 1, nil, daw.keymap.mode == "x" and "CursorVisual" or "Cursor")
  timeline:fill(x, y + 1, cw, 1, nil, "CursorTail")
end

--- The tempo lane: the header says what the tempo is at the cursor, the
--- timeline draws the map as a curve, a step where a change holds and a slope
--- where it ramps, a mark on each change. `:tempo.lane` or `zT` hides it.
function view:draw_tempo_row(headers, timeline, y, lines)
  local zoom, scroll = self.geometry.zoom, self.scroll
  local hw, tw = headers.width, timeline.width
  local beat = daw.cursor.beat
  headers:fill(0, y, hw, 2, " ", "TrackHeader")
  headers:text(2, y, util.fit("tempo", math.max(1, hw - 3)), "TrackHeader")
  headers:text(2, y + 1, util.fit(string.format("%g bpm", daw.tempo.at(beat)), math.max(1, hw - 3)), "TrackInfo")
  timeline:fill(0, y, tw, 2, " ", "Lane")
  for _, line in ipairs(lines) do
    if line.bar then timeline:fill(line.x, y, 1, 2, draw.g.bar, "LaneBar") end
  end
  local lo, hi = daw.tempolane.range()
  local function level(bpm) return util.clamp((bpm - lo) / (hi - lo), 0, 1) end
  draw.curve(timeline:sub(0, y, tw, 2), 0, 2, function(i)
    return level(daw.tempo.at(scroll + (i + 0.5) / (zoom * 2)))
  end, "Automation")
  for _, p in ipairs(daw.tempo.points()) do
    local x = math.floor((p.beat - scroll) * zoom + 0.5)
    if x >= 0 and x < tw then timeline:text(x, level(p.bpm) >= 0.5 and y or y + 1, (daw.opt.ascii and (p.ramp and ">" or "*") or (p.ramp and "◢" or "◆")), "Automation") end
  end
  local x = math.floor((beat - scroll) * zoom + 0.5)
  timeline:fill(x, y, math.max(1, math.floor(daw.opt.grid * zoom)), 1, nil, "Cursor")
end

--- One take lane: take `row.take` of every clip of the track that has that
--- many, over the clip's own stretch of time, lit where it is the one that
--- plays and faint where it is not, with its name. To look at: comping here
--- is `:take 2` over a selection, or a drag across the lane, with the
--- mouse in the terminal or the window.
function view:draw_take_row(headers, timeline, row, lines)
  local y, k = row.y, row.take
  local zoom, scroll = self.geometry.zoom, self.scroll
  local hw, tw = headers.width, timeline.width
  local hue = draw.track_hue(api.track_get(row.id), row.index)
  headers:fill(0, y, hw, 1, " ", "TrackHeader")
  headers:text(0, y, "▏", hue.fg)
  headers:text(2, y, util.fit("↳ take " .. k, math.max(1, hw - 3)), "TrackInfo")
  timeline:fill(0, y, tw, 1, " ", "TakeLane")
  for _, line in ipairs(lines) do
    if line.bar then timeline:fill(line.x, y, 1, 1, draw.g.bar, "LaneBar") end
  end
  for _, clip in ipairs(api.clip_list(row.id)) do
    local takes = daw.takes.of(clip)
    local entry = takes and takes.list[k]
    if entry then
      local x0 = math.floor((clip.start - scroll) * zoom + 0.5)
      local x1 = math.floor((clip.start + clip.length - scroll) * zoom + 0.5)
      local cw = math.max(1, x1 - x0)
      if x0 < tw and x0 + cw > 0 then
        local on = takes.active == k
        local box = timeline:sub(x0, y, cw, 1)
        box:fill(0, 0, cw, 1, " ", on and hue.title or "TakeLaneName")
        box:text(cw > 2 and 1 or 0, 0, (on and (draw.g.play .. " ") or "") .. (entry.name or ("take " .. k)))
        box:fill(0, 0, 1, 1, draw.g.clip_start, "ClipEdge")
      end
    end
  end
  -- The stretch being dragged over.
  local comp = self.comp
  if comp and comp.id == row.id and comp.take == k then
    local x0, x1 = math.min(comp.x0, comp.x1) - hw, math.max(comp.x0, comp.x1) - hw
    timeline:fill(math.max(0, x0), y, math.max(0, x1 - math.max(0, x0) + 1), 1, nil, "Visual")
  end
end

--- On an automation lane row the lane's own keys come first.
function view:subscope()
  return daw.cursor.lane_id() and "arrange.lane" or nil
end

function view:render(buf, ctx)
  local g = draw.g
  local w, h = buf.width, buf.height
  local opt = daw.opt
  local zoom = opt.zoom
  local t = api.transport_get()
  local cursor = daw.cursor
  local cursor_track = cursor.track_id()
  local bar = daw.time.bar()

  local L = self:layout(w, h)
  local hw, tw = L.hw, L.tw
  local span = tw / zoom
  local tracks = L.tracks

  -- Keep the playhead in view while playing, and the cursor whenever it moves.
  if t.playing and opt.follow then
    if t.position < self.scroll or t.position >= self.scroll + span then
      self.scroll = daw.time.bar_floor(t.position)
    end
  elseif cursor.beat ~= self.seen_beat then
    if cursor.beat < self.scroll then
      self.scroll = daw.time.bar_floor(cursor.beat)
    elseif cursor.beat >= self.scroll + span - 1 / zoom then
      self.scroll = math.max(0, math.ceil((cursor.beat - span) / bar + 1) * bar)
    end
  end
  self.seen_beat = cursor.beat
  self.scroll = math.max(0, self.scroll)
  local th = L.th
  self.geometry = { hw = hw, th = th, rows = #L.rows, zoom = zoom, span = span, layout = L }
  local function col(beat) return math.floor((beat - self.scroll) * zoom + 0.5) end

  -- The rule between the headers and the timeline, from top to bottom.
  buf:fill(hw - 1, 0, 1, h, g.rule, "Rule")
  local headers, lanes = buf:sub(0, 0, hw - 1, h), buf:sub(hw, 0, tw, h)
  headers:fill(0, 0, hw - 1, h, " ", "TrackHeader")

  -- Ruler: where the cursor is in the corner; bars, beat ticks and the loop.
  buf:fill(0, 0, hw - 1, L.ruler_rows, " ", "Ruler")
  local ruler = buf:sub(hw, 0, tw, 1)
  ruler:fill(0, 0, tw, 1, " ", "Ruler")
  if hw >= 12 then
    local pos = daw.time.format(cursor.beat)
    if hw - 2 >= #pos + 5 then
      buf:text(1, 0, "cur", "RulerCornerLabel")
      buf:text(5, 0, pos, "RulerCorner")
    else
      buf:text(1, 0, util.fit(pos, hw - 2), "RulerCorner")
    end
  end
  local loop
  if t.loop_enabled and t.loop_end > t.loop_start then
    local x0, x1 = math.max(0, col(t.loop_start)), math.min(tw, col(t.loop_end))
    if x1 > x0 then
      loop = { x0, x1 }
      ruler:fill(x0, 0, x1 - x0, 1, nil, "RulerLoop")
    end
  end
  -- The punch range, in red over the loop's amber where they meet.
  local punch
  if t.punch_enabled and t.punch_end > t.punch_start then
    local x0, x1 = math.max(0, col(t.punch_start)), math.min(tw, col(t.punch_end))
    if x1 > x0 then
      punch = { x0, x1 }
      ruler:fill(x0, 0, x1 - x0, 1, nil, "RulerPunch")
    end
  end
  local lines = grid_lines(self.scroll, zoom, tw)
  local in_loop = function(x) return loop and x >= loop[1] and x < loop[2] end
  local in_punch = function(x) return punch and x >= punch[1] and x < punch[2] end
  -- Skip bar numbers that would run into each other when zoomed out.
  local every = math.max(1, math.ceil(5 / (daw.time.bar(self.scroll) * zoom)))
  local free = 0 -- the first column a label has not taken
  for _, line in ipairs(lines) do
    if line.bar then
      if (line.bar - 1) % every == 0 and line.x >= free then
        local style = in_punch(line.x) and "RulerPunch" or in_loop(line.x) and "RulerLoop" or "RulerBar"
        free = line.x + ruler:text(line.x, 0, tostring(line.bar), style) + 1
      end
    elseif zoom >= 2 and line.x >= free then
      ruler:text(line.x, 0, g.tick, in_punch(line.x) and "RulerPunchTick" or in_loop(line.x) and "RulerLoopTick" or "RulerTick")
    end
  end
  if loop then
    if col(t.loop_start) >= 1 then ruler:text(col(t.loop_start) - 1, 0, g.loop_in, "RulerLoopEdge") end
    -- The end's mark sits in the band's last cell, clear of the next bar's number.
    if col(t.loop_end) >= 1 and col(t.loop_end) <= tw then ruler:text(col(t.loop_end) - 1, 0, g.loop_out, "RulerLoopEdgeIn") end
  end
  if punch then
    if col(t.punch_start) >= 1 then ruler:text(col(t.punch_start) - 1, 0, g.punch_in, "RulerPunchEdge") end
    if col(t.punch_end) >= 1 and col(t.punch_end) <= tw then ruler:text(col(t.punch_end) - 1, 0, g.punch_out, "RulerPunchEdge") end
  end
  -- Tempo and signature changes: a mark and the value, after the bar number.
  local mark_end = -1
  for _, mark in ipairs(daw.tempo.marks(self.scroll, self.scroll + span)) do
    local x = col(mark.beat)
    if daw.tempo.is_bar_line(mark.beat) then x = x + #tostring(daw.time.bar_of(mark.beat)) end
    x = math.max(x, mark_end)
    mark_end = x + ruler:text(x, 0, (mark.kind == "tempo" and "▾" or "‖") .. mark.text, "RulerTempo") + 1
  end
  local ruler2
  if L.ruler_rows - L.tempo_rows > 1 then
    ruler2 = buf:sub(hw, 1, tw, 1)
    ruler2:fill(0, 0, tw, 1, " ", "Ruler")
  end
  if L.tempo_rows > 0 then self:draw_tempo_row(headers, lanes, L.ruler_rows - L.tempo_rows, lines) end

  -- Tracks.
  local cursor_clip = cursor.clip()
  cursor_clip = cursor_clip and cursor_clip.id
  local covered = {}
  local cursor_lane = cursor.lane_id()
  for _, row in ipairs(L.rows) do
    if row.kind == "lane" then self:draw_lane_row(headers, lanes, row, lines) end
    if row.kind == "take" then self:draw_take_row(headers, lanes, row, lines) end
  end
  for _, row in ipairs(L.rows) do
    if row.kind == "track" then
      local track, y = api.track_get(row.id), row.y
      local selected = row.id == cursor_track
      local automation = api.lane_list(row.id)
      local hue = draw.track_hue(track, row.index)
      header(self, headers, y, row.h, track, row.index, selected and not cursor_lane, automation, hue)
      -- With its lanes open as rows, a track's curve is drawn there, not here.
      covered[row] = lane(lanes, y, row.h, track, selected, self.scroll, zoom, cursor_clip,
        daw.lanes.is_open(row.id) and {} or automation, hue, lines, loop)
      if selected and not cursor_lane then
        local x = col(cursor.beat)
        -- In the mode's colour where the clips' names are, a shadow below.
        local cw = math.max(1, math.floor(opt.grid * zoom))
        local mode = daw.keymap.mode
        lanes:fill(x, y, cw, 1, nil, mode == "x" and "CursorVisual" or mode == "i" and "InsertCursor" or "Cursor")
        if row.h > 1 then lanes:fill(x, y + 1, cw, row.h - 1, nil, "CursorTail") end
      end
    end
  end
  -- The selection of visual mode: whole tracks, or a stretch of time on some.
  local selection = daw.keymap.selection()
  if selection then
    for _, row in ipairs(cursor_lane and {} or L.rows) do
      if row.kind == "track" and row.index >= selection.r0 and row.index <= selection.r1 then
        if selection.kind == "line" then
          buf:fill(0, row.y, hw - 1, row.h, nil, "Visual")
          lanes:fill(0, row.y, tw, row.h, nil, "Visual")
        else
          local x0 = math.max(0, col(selection.c0))
          local x1 = math.min(tw, col(selection.c1))
          if x1 > x0 then lanes:fill(x0, row.y, x1 - x0, row.h, nil, "Visual") end
        end
      end
    end
  end

  -- The master track is pinned to the bottom, with its level on both sides.
  local mst = L.master
  if #tracks == 0 then
    welcome(buf:sub(0, L.ruler_rows, w, mst.y - L.ruler_rows))
  elseif mst.y - L.used >= 2 then
    -- Room left under the last track says how to fill it.
    headers:text(hw >= 16 and 4 or 2, L.used, "o", "EmptyKey")
    headers:text(hw >= 16 and 6 or 4, L.used, "new track", "Empty")
  end
  local master = api.track_get(0)
  header(self, headers, mst.y, mst.h, master, nil, false, api.lane_list(0), draw.track_hue(master))
  lanes:fill(0, mst.y, tw, mst.h, " ", "TrackHeader")
  master_meter(lanes, mst.y, tw)

  local names = {}
  for name in pairs(self.layers) do names[#names + 1] = name end
  if #names > 0 then
    table.sort(names)
    local scroll = self.scroll
    local layer = {
      ruler = ruler, ruler2 = ruler2, lanes = buf:sub(hw, L.ruler_rows, tw, mst.y - L.ruler_rows),
      x = function(beat) return math.floor((beat - scroll) * zoom + 0.5) end,
      scroll = scroll, zoom = zoom, span = span, top = self.top, rows = #L.rows, th = th,
    }
    for _, name in ipairs(names) do
      local ok, err = pcall(self.layers[name], self, layer)
      if not ok then ruler:text(0, 0, util.fit(name .. ": " .. tostring(err), tw), "Error") end
    end
  end

  -- The playhead: a mark on the ruler and a thin line on the beat's left
  -- edge, which is where a clip that starts there begins to be drawn. Over a
  -- clip the line keeps the clip's colour behind it, so the clip is seen to
  -- start where it does.
  local px = col(t.position)
  if px >= 0 and px < tw then
    ruler:text(px, 0, g.cap, "RulerPlayhead")
    for _, row in ipairs(L.rows) do
      local on_clip = false
      for _, s in ipairs(covered[row] or {}) do
        if px >= s[1] and px < s[2] then on_clip = true end
      end
      if on_clip then
        -- Under the clip's name only, so the name row reads unbroken.
        local skip = row.h > 1 and 1 or 0
        lanes:fill(px, row.y + skip, 1, row.h - skip, g.playhead, "PlayheadClip")
      else
        lanes:fill(px, row.y, 1, row.h, g.playhead, "Playhead")
      end
    end
  end
end

--- Scroll so that the cursor is in the middle of the timeline.
function view:center()
  local g = self.geometry
  if not g then return end
  self.scroll = math.max(0, daw.time.bar_floor(math.max(0, daw.cursor.beat - g.span / 2)))
  api.ui_redraw()
end

--- Scroll by bars without moving the cursor.
function view:scroll_by(bars)
  self.scroll = math.max(0, self.scroll + bars * daw.time.bar(self.scroll))
  api.ui_redraw()
end

-- What modal editing works on: rows are positions in the track list.
view.grid = {
  get = function() return daw.cursor.row() or 1, daw.cursor.beat end,
  set = function(row, col)
    local list = daw.groups.rows()
    local id = list[util.clamp(row, 1, #list)]
    -- Staying on the same track keeps the cursor on the lane row it is on.
    if #list > 0 and id ~= daw.cursor.track_id() then daw.cursor.set_track(id) end
    daw.cursor.set_beat(col)
  end,
  step = function() return daw.opt.grid end,
  -- A mark stays with its track when tracks are moved around.
  mark = function() return { track = daw.cursor.track_id(), beat = daw.cursor.beat } end,
  jump = function(pos)
    if pos.track and pcall(api.track_get, pos.track) then daw.cursor.set_track(pos.track) end
    daw.cursor.set_beat(pos.beat)
  end,
  -- Clips by name where they start, and tracks by name at the cursor's beat.
  search = function(text)
    local wanted, hits = text:lower(), {}
    for row, id in ipairs(daw.groups.rows()) do
      if api.track_get(id).name:lower():find(wanted, 1, true) then
        hits[#hits + 1] = { row = row, col = daw.cursor.beat }
      end
      for _, clip in ipairs(api.clip_list(id)) do
        if clip.name:lower():find(wanted, 1, true) then hits[#hits + 1] = { row = row, col = clip.start } end
      end
    end
    return hits
  end,
}

--- A drag across a take lane, as the window's: the cells from where the
--- button went down to where it is now are marked, and on release that
--- take plays over them (`daw.frontend.act.comp`; a cell shorter than a
--- grid step is a click, which chooses the take for the piece under it).
function view:comp_drag(event)
  local g, comp = self.geometry, self.comp
  comp.x1 = math.max(g.hw, event.x)
  if event.kind == "up" then
    self.comp = nil
    local from = self.scroll + (math.min(comp.x0, comp.x1) - g.hw) / g.zoom
    local to = self.scroll + (math.max(comp.x0, comp.x1) + 1 - g.hw) / g.zoom
    daw.frontend.act.comp(comp.id, comp.take, from, to, event.mods:find("S") ~= nil)
  end
  api.ui_redraw()
end

function view:on_mouse(event)
  local g = self.geometry
  if not g then return end
  local bar = daw.time.bar()
  if event.kind == "scroll_down" or event.kind == "scroll_up" then
    local step = event.kind == "scroll_down" and 1 or -1
    if event.mods:find("S") then
      self.scroll = math.max(0, self.scroll + step * bar)
    else
      self.top = self.top + step
    end
    return api.ui_redraw()
  elseif event.kind == "scroll_left" or event.kind == "scroll_right" then
    self.scroll = math.max(0, self.scroll + (event.kind == "scroll_right" and bar or -bar))
    return api.ui_redraw()
  elseif self.comp and (event.kind == "drag" or event.kind == "up") then
    return self:comp_drag(event)
  elseif event.kind ~= "down" or event.button ~= "left" then
    return
  end

  local beat = self.scroll + (event.x - g.hw) / g.zoom
  self.comp = nil
  if event.y == 0 then
    if event.x >= g.hw then api.transport_seek(daw.cursor.snap(beat)) end
    return
  end
  local hit
  for _, row in ipairs(g.layout.rows) do
    if event.y >= row.y and event.y < row.y + row.h then hit = row end
  end
  if hit and hit.kind == "take" then
    if event.x < g.hw then
      -- The label makes the take play wherever the track has it.
      local last = 0
      for _, clip in ipairs(api.clip_list(hit.id)) do last = math.max(last, clip.start + clip.length) end
      daw.takes.comp(hit.id, hit.take, 0, last)
      daw.cursor.set_track(hit.id)
    else
      self.comp = { id = hit.id, take = hit.take, x0 = event.x, x1 = event.x }
    end
    return api.ui_redraw()
  end
  if not hit or (hit.kind ~= "track" and hit.kind ~= "lane") then return end
  local id = hit.id
  daw.cursor.set_track(id, hit.lane and hit.lane.id)
  if event.x >= g.hw then
    daw.cursor.set_beat(math.floor(beat / daw.opt.grid) * daw.opt.grid)
  elseif event.y == hit.y and hit.kind == "track" then
    for field, x in pairs(self.flags) do
      if event.x == x then api.track_set(id, field, not api.track_get(id)[field]) end
    end
  end
end

daw.ui.view("arrange", view)
return view
