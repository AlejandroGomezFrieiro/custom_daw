-- The session view: a column of slots for each track and a row for each
-- scene, with the scenes' names down the right. A clip that plays is lit in
-- its track's colour and filled as it goes round its loop; one queued to
-- start is marked until its boundary comes. The last row says what each
-- track plays: a slot, nothing (stopped), or its timeline.
local api = daw.api
local util = daw.util
local draw = daw.draw
local launcher = daw.launcher

local view = { scroll = 0, top = 0 }

local GUTTER = 4 -- the row numbers
local SCENES = 14 -- the scenes' column

--- Columns a track takes on a screen `w` wide with `n` tracks, the gap after it included.
function view.column_width(w, n)
  return util.clamp(math.floor((w - GUTTER - SCENES) / math.max(1, n)), 10, 20)
end

--- The text of a slot, `width` cells: a mark, then the clip's name.
local function label(mark, name, width)
  return util.fit(mark .. " " .. name, width)
end

local function slot_cell(buf, x, y, width, clip, hue, state)
  local g = draw.g
  if not clip then
    buf:fill(x, y, width, 1, " ", "TrackHeader")
    buf:text(x + 1, y, g.dot, state.queued and "Accent" or "TrackIndex")
    return
  end
  if state.playing then
    -- Lit, and filled as far as it has gone round its loop.
    local text = label(g.play, clip.name, width)
    buf:fill(x, y, width, 1, " ", hue.title)
    buf:text(x, y, text, hue.title)
    local filled = math.floor(util.clamp(state.progress, 0, 1) * width + 0.5)
    if filled > 0 then
      buf:fill(x, y, filled, 1, " ", hue.pill)
      buf:text(x, y, util.fit(text, filled), hue.pill)
    end
  elseif state.queued then
    buf:fill(x, y, width, 1, " ", hue.body_cur)
    buf:text(x, y, label(g.closed, clip.name, width), hue.body_cur)
  else
    buf:fill(x, y, width, 1, " ", clip.muted and hue.body_off or hue.body)
    buf:text(x, y, label(g.stop, clip.name, width), clip.muted and hue.title_off or hue.body)
  end
end

--- What the last row says of a track.
local function status_text(s)
  local g = draw.g
  if not s then return "timeline", "TrackIndex" end
  local queued = s.queued == "stop" and (" " .. g.closed .. g.stop)
    or s.queued == "arrangement" and (" " .. g.closed .. "tl")
    or type(s.queued) == "number" and (" " .. g.closed .. (s.queued + 1)) or ""
  if s.slot then
    local bar = daw.time.bar(0)
    local at = s.length and string.format(" %d/%d", math.floor(s.phase / bar) + 1, math.max(1, math.ceil(s.length / bar - 1e-9))) or ""
    return g.play .. " " .. (s.slot + 1) .. at .. queued, "Bright"
  elseif s.stopped then
    return g.stop .. " stopped" .. queued, "TrackInfo"
  end
  return "timeline" .. queued, "TrackIndex"
end

function view:render(buf, ctx)
  local g = draw.g
  -- A VCA has no clips to launch.
  local tracks = {}
  for _, id in ipairs(api.track_list()) do
    if not daw.vca.is_vca(id) then tracks[#tracks + 1] = id end
  end
  local quantize = api.project_get().launch_quantize
  local body = daw.ui.titlebar(buf, {
    name = "Session",
    context = "launches on " .. quantize .. (launcher.capturing and ("  " .. g.rec .. " capturing") or ""),
    focused = ctx.focused,
  })
  local w, h = body.width, body.height
  body:fill(0, 0, w, h, " ", "TrackHeader")
  local cw = view.column_width(w, #tracks)
  local room = math.max(1, math.floor((w - GUTTER - SCENES) / cw))
  local index = 1
  for i, id in ipairs(tracks) do
    if id == daw.cursor.track_id() then index = i end
  end
  if index <= self.scroll then self.scroll = index - 1 end
  if index > self.scroll + room then self.scroll = index - room end
  self.scroll = util.clamp(self.scroll, 0, math.max(0, #tracks - room))
  -- Rows: the names, the slots, and the line saying what plays.
  local rows = launcher.rows()
  local shown = math.max(1, h - 2)
  if launcher.row < self.top then self.top = launcher.row end
  if launcher.row >= self.top + shown then self.top = launcher.row - shown + 1 end
  self.top = util.clamp(self.top, 0, math.max(0, rows - shown))
  local state = launcher.state()
  local cursor_track = daw.cursor.track_id()
  local columns = {}
  for col = 0, room - 1 do
    local i = self.scroll + col + 1
    local id = tracks[i]
    if not id then break end
    local t = api.track_get(id)
    local hue = draw.track_hue(t, i)
    local x = GUTTER + col * cw
    local selected = id == cursor_track
    columns[#columns + 1] = { id = id, x = x }
    body:fill(x, 0, cw - 1, 1, " ", selected and hue.title_cur or hue.plate)
    body:text(x + 1, 0, util.fit(t.name, cw - 2), selected and hue.title_cur or hue.plate)
    local s = state[id] or {}
    local slots = launcher.slots(id)
    for r = 0, shown - 1 do
      local row = self.top + r
      if row >= rows then break end
      local clip = slots[row]
      local cell = {
        playing = s.slot == row,
        queued = s.queued == row,
        progress = (s.slot == row and s.length and s.length > 0) and s.phase / s.length or 0,
      }
      local rec = launcher.recording
      if rec and rec.track == id and rec.row == row then
        body:fill(x, r + 1, cw - 1, 1, " ", "Armed")
        body:text(x, r + 1, label(g.rec, "recording", cw - 1), "Armed")
      else
        slot_cell(body, x, r + 1, cw - 1, clip, hue, cell)
      end
      if selected and row == launcher.row then
        body:text(x - 1, r + 1, g.mark, ctx.focused and "Cursor" or "Accent")
      end
    end
    local text, style = status_text(state[id])
    body:text(x, h - 1, util.fit(text, cw - 1), style)
  end
  -- Row numbers, and the scenes down the right.
  local sx = GUTTER + #columns * cw + 1
  body:fill(sx - 1, 0, 1, h, g.rule, "Rule")
  body:text(sx, 0, util.fit("Scenes", SCENES - 1), "TrackName")
  for r = 0, shown - 1 do
    local row = self.top + r
    if row >= rows then break end
    local here = row == launcher.row
    body:text(0, r + 1, string.format("%3d", row + 1), here and "Bright" or "TrackIndex")
    body:text(sx, r + 1, label(g.play, launcher.scene_name(row), SCENES - 1), here and "TrackNameSel" or "TrackInfo")
  end
  body:text(0, h - 1, util.fit(g.stop, GUTTER - 1), "TrackIndex")
  body:text(sx, h - 1, util.fit(g.stop .. " stop all", SCENES - 1), "TrackInfo")
  self.geometry = { columns = columns, cw = cw, sx = sx, shown = shown, h = h }
end

daw.ui.view("session", view)
daw.ui.dock("session", { side = "bottom", hidden = true })
return view
