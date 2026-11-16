-- Takes: several versions of what a clip plays, one of them playing.
--
-- Recording with the loop on goes round it, and every time round becomes a
-- take of one clip over the loop; the last is the one that plays. Any clip
-- can be given takes by hand as well (`:take.new`).
--
--   ]t and [t             -- the next take of the clip under the cursor, the one before
--   :take 2               -- play the second; over a selection, only there (see below)
--   :take.list            -- choose from a list
--   :take.new             -- keep what the clip plays as a take and carry on in a copy
--   :take.remove          -- throw the playing take away
--   :take.keep            -- throw the others away
--   :take.explode         -- every take as a clip on a track of its own
--
-- Comping, choosing the best of each take: cut the clip where the choice
-- changes (`s`, or select a stretch of time and say `:take 2`, which cuts
-- at its ends) and choose a take for each piece. Every piece keeps all the
-- takes, lined up, so a cut can be moved and a choice changed later.
-- `M.comp(track, take, from, to)` does it in one go, and joins pieces side
-- by side that then play the same take back into one where that is exact.
--
-- Take lanes: a track can show its takes as rows under its clips
-- (`:take.lanes`, `zt`), row k holding take k of every clip of the track
-- that has takes, each over the clip's own stretch of time, so that the
-- pieces of a comp line up into lanes. In the window a drag across row k
-- makes take k play over that stretch (`daw.frontend.act.comp`). Which
-- tracks show them is kept for the session, like open automation lanes,
-- not in the project.
--
--   :take.lanes           -- show or hide the take lanes of the cursor's track
--
-- Where they are kept: `clip.meta.takes = { active, origin, list }`. The
-- playing take is the clip's own content and its entry holds only a name;
-- the others hold theirs: `file`, `offset` and `gain` for sound, `notes`
-- and `controls` for notes. `origin` is the clip's own offset into its file
-- at the time the others' offsets were written, so that a clip trimmed or
-- cut since (which moves its offset) still finds them lined up.
local api = daw.api
local M = {}

local EPS = 1e-9

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

--- The takes of a clip: { active, list = { { name }, ... } }, or nil for a
--- clip that has only what it plays.
function M.of(clip)
  local c = type(clip) == "table" and clip or api.clip_get(clip)
  local takes = type(c.meta) == "table" and c.meta.takes
  if type(takes) ~= "table" or type(takes.list) ~= "table" or #takes.list < 2 then return nil end
  return takes
end

--- How many takes a clip has (1 without any others), and which plays.
function M.count(clip)
  local takes = M.of(clip)
  if not takes then return 1, 1 end
  return #takes.list, takes.active
end

local function write(id, c, takes)
  local meta = copy(type(c.meta) == "table" and c.meta or {})
  meta.takes = takes
  api.clip_set(id, "meta", meta)
end

--- What the clip plays now, as an entry of the list.
local function current(id, c, name)
  if c.kind == "audio" then return { name = name, file = c.file, offset = c.offset, gain = c.gain } end
  return {
    name = name, notes = api.clip_notes(id),
    controls = c.control_count > 0 and api.clip_controls(id) or nil,
  }
end

--- Make an entry what the clip plays. `shift` is how far the clip's offset
--- has moved since the entry's own was written.
local function play(id, c, entry, shift)
  if c.kind == "audio" then
    if entry.file ~= c.file then api.clip_set(id, "file", entry.file) end
    api.clip_set(id, "offset", math.max(0, (entry.offset or 0) + shift))
    api.clip_set(id, "gain", entry.gain or 0)
  else
    api.clip_set_notes(id, entry.notes or {})
    api.clip_set_controls(id, entry.controls or {})
  end
end

--- Play take `index` of a clip. One undo step. Returns the take's name.
function M.select(id, index)
  local c = api.clip_get(id)
  local takes = M.of(c)
  if not takes then error("the clip has no other takes", 2) end
  index = math.floor(index)
  if not takes.list[index] then error("the clip has " .. #takes.list .. " takes", 2) end
  if index == takes.active then return takes.list[index].name end
  local list = {}
  -- How far the clip has been trimmed or slipped since the offsets were written.
  local shift = c.kind == "audio" and (c.offset - (takes.origin or c.offset)) or 0
  for i, entry in ipairs(takes.list) do
    if i == takes.active then
      list[i] = current(id, c, entry.name)
    elseif i == index then
      list[i] = { name = entry.name }
    else
      list[i] = copy(entry)
      if c.kind == "audio" then list[i].offset = (entry.offset or 0) + shift end
    end
  end
  play(id, c, takes.list[index], shift)
  local origin = c.kind == "audio" and api.clip_get(id).offset or nil
  write(id, c, { active = index, origin = origin, list = list })
  return takes.list[index].name
end

--- Step through a clip's takes, round and round.
function M.step(id, by)
  local n, active = M.count(id)
  if n < 2 then return nil end
  return M.select(id, (active - 1 + by) % n + 1)
end

--- Keep what the clip plays as a take and carry on in a copy of it, which
--- becomes the one that plays: for trying a variation. Returns its number.
function M.new(id, name)
  local c = api.clip_get(id)
  local takes = M.of(c)
  local list = {}
  local shift = takes and c.kind == "audio" and (c.offset - (takes.origin or c.offset)) or 0
  if takes then
    for i, entry in ipairs(takes.list) do
      if i == takes.active then
        list[i] = current(id, c, entry.name)
      else
        list[i] = copy(entry)
        if c.kind == "audio" then list[i].offset = (entry.offset or 0) + shift end
      end
    end
  else
    list[1] = current(id, c, c.name .. " 1")
  end
  list[#list + 1] = { name = name or (c.name .. " " .. (#list + 1)) }
  write(id, c, { active = #list, origin = c.kind == "audio" and c.offset or nil, list = list })
  return #list
end

--- Throw a take away: the playing one by default, and then the one before
--- it plays. With one left, the clip is a clip without takes again.
function M.remove(id, index)
  local c = api.clip_get(id)
  local takes = M.of(c)
  if not takes then error("the clip has no other takes", 2) end
  index = index or takes.active
  if not takes.list[index] then error("the clip has " .. #takes.list .. " takes", 2) end
  if index == takes.active then
    M.select(id, index > 1 and index - 1 or 2)
    c = api.clip_get(id)
    takes = M.of(c)
  end
  local list, active = {}, takes.active
  for i, entry in ipairs(takes.list) do
    if i ~= index then list[#list + 1] = entry end
  end
  if index < active then active = active - 1 end
  write(id, c, #list > 1 and { active = active, origin = takes.origin, list = list } or nil)
end

--- Throw away every take but the one that plays.
function M.keep(id)
  local c = api.clip_get(id)
  if M.of(c) then write(id, c, nil) end
end

--- Every take as a clip of its own, on new tracks below the clip's track,
--- one each; the clip is left with the take that plays. Returns the tracks.
function M.explode(id)
  local c = api.clip_get(id)
  local takes = M.of(c)
  if not takes then error("the clip has no other takes", 2) end
  local track = api.track_get(c.track)
  local shift = c.kind == "audio" and (c.offset - (takes.origin or c.offset)) or 0
  local out, at = {}, track.index
  for i, entry in ipairs(takes.list) do
    if i ~= takes.active then
      at = at + 1
      local t = daw.add_track({ name = entry.name or (track.name .. " take " .. i), index = at })
      local snap = { name = entry.name or c.name, start = c.start, length = c.length, kind = c.kind }
      -- Each plays as the clip does: stretched, shifted, looped.
      daw.stretch.carry(c, snap, 0)
      if c.kind == "audio" then
        snap.file, snap.offset, snap.gain = entry.file, math.max(0, (entry.offset or 0) + shift), entry.gain or 0
        snap.fade_in, snap.fade_out = c.fade_in, c.fade_out
      else
        snap.notes, snap.controls = entry.notes or {}, entry.controls
      end
      daw.restore_clip(snap, t)
      out[#out + 1] = t
    end
  end
  write(id, c, nil)
  return out
end

--- The takes that go with a piece of a clip, from beat `from` to `to` of
--- the timeline: what a cut gives each side. Sound keeps its entries as
--- they are (the piece's own offset says where it is in them); notes are
--- those of the stretch, counted from the piece's start. Nil for a clip
--- without takes. The notes of a looped clip all go with every piece,
--- moved by `shift` as the piece's own are (see `daw.stretch.moved`).
function M.piece(c, from, to, shift)
  local takes = M.of(c)
  if not takes then return nil end
  if c.kind == "audio" then return takes end
  local a, b = from - c.start, to - c.start
  if shift then a, b = -shift, math.huge end
  local list = {}
  for i, entry in ipairs(takes.list) do
    local e = copy(entry)
    if entry.notes then
      e.notes = {}
      for _, n in ipairs(entry.notes) do
        if shift then
          local note = copy(n)
          note.start = n.start + shift
          e.notes[#e.notes + 1] = note
        elseif n.start >= a - EPS and n.start < b - EPS then
          local note = copy(n)
          note.start, note.length = n.start - a, math.min(n.length, b - n.start)
          e.notes[#e.notes + 1] = note
        end
      end
    end
    if entry.controls then
      e.controls = {}
      for _, move in ipairs(entry.controls) do
        if shift or (move.start >= a - EPS and move.start < b - EPS) then
          local m = copy(move)
          m.start = move.start - a
          e.controls[#e.controls + 1] = m
        end
      end
    end
    list[i] = e
  end
  return { active = takes.active, list = list }
end

--- Move the notes of a clip's other takes by `by` beats, as its own are
--- moved when its start is trimmed or its content slipped.
function M.shift(id, by)
  local c = api.clip_get(id)
  local takes = M.of(c)
  if not takes or c.kind ~= "midi" then return end
  local list = {}
  for i, entry in ipairs(takes.list) do
    local e = copy(entry)
    if entry.notes then
      e.notes = {}
      for j, n in ipairs(entry.notes) do
        e.notes[j] = copy(n)
        e.notes[j].start = n.start + by
      end
    end
    if entry.controls then
      e.controls = {}
      for j, move in ipairs(entry.controls) do
        e.controls[j] = copy(move)
        e.controls[j].start = move.start + by
      end
    end
    list[i] = e
  end
  write(id, c, { active = takes.active, list = list })
end

--- A clip's takes in a few characters, for its label: "2/4", or nil.
function M.badge(c)
  local takes = M.of(c)
  return takes and (takes.active .. "/" .. #takes.list) or nil
end

--- What take `index` of a clip plays, as the clip would have it if that
--- take were chosen: `{ file, offset, gain }` for sound, the offset where
--- the clip's start falls in the file; `{ notes, controls }` for notes,
--- counted from the clip's start. The playing take is the clip's own.
function M.content(clip, index)
  local c = type(clip) == "table" and clip or api.clip_get(clip)
  local takes = M.of(c)
  local entry = takes and index ~= takes.active and takes.list[index]
  if not entry then
    if c.kind == "audio" then return { file = c.file, offset = c.offset, gain = c.gain } end
    return { notes = api.clip_notes(c.id), controls = c.control_count > 0 and api.clip_controls(c.id) or {} }
  end
  if c.kind == "audio" then
    local shift = c.offset - (takes.origin or c.offset)
    return { file = entry.file, offset = math.max(0, (entry.offset or 0) + shift), gain = entry.gain or 0 }
  end
  return { notes = entry.notes or {}, controls = entry.controls or {} }
end

-- Comping --------------------------------------------------------------------------

--- Whether every note of a list lies within a clip `length` beats long:
--- notes hidden past either edge would show if the clip were joined to another.
local function within(notes, length)
  for _, n in ipairs(notes or {}) do
    if n.start < -EPS or n.start >= length - EPS then return false end
  end
  return true
end

--- Whether two lists of notes or controller moves are the same, the first
--- moved by `by` beats.
local function same_moved(x, y, by)
  x, y = x or {}, y or {}
  if #x ~= #y then return false end
  local function key(item, shift)
    return string.format("%.6f|%s|%s|%s|%s|%s", item.start + shift, tostring(item.pitch), tostring(item.length),
      tostring(item.velocity), tostring(item.type or item.number), tostring(item.value))
  end
  local a, b = {}, {}
  for i, item in ipairs(x) do a[i] = key(item, by) end
  for i, item in ipairs(y) do b[i] = key(item, 0) end
  table.sort(a)
  table.sort(b)
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

--- Whether looped clip `b` carries on `a`'s repeats where `a` ends: the
--- same loop, turned on as far as `a` is long (see `daw.stretch.moved`),
--- and for notes the same notes, every take's too.
local function loop_continues(a, b, ta, tb)
  if not (a.loop and b.loop) or math.abs(a.loop_length - b.loop_length) > 1e-9 then return false end
  local m = daw.stretch.moved(a, a.length)
  if math.abs(m.loop_start - b.loop_start) > 1e-6 then return false end
  if a.kind == "audio" then
    for i = 1, #ta.list do
      local x, y = M.content(a, i), M.content(b, i)
      if x.file ~= y.file or math.abs((x.gain or 0) - (y.gain or 0)) > 1e-9 then return false end
    end
    return math.abs(m.offset - b.offset) < 1e-6
  end
  if not same_moved(api.clip_notes(a.id), api.clip_notes(b.id), m.shift) then return false end
  if (a.control_count > 0 or b.control_count > 0)
    and not same_moved(api.clip_controls(a.id), api.clip_controls(b.id), m.shift) then
    return false
  end
  for i = 1, #ta.list do
    if i ~= ta.active then
      if not same_moved(ta.list[i].notes, tb.list[i].notes, m.shift) then return false end
      if not same_moved(ta.list[i].controls, tb.list[i].controls, m.shift) then return false end
    end
  end
  return true
end

--- Whether clip `b` carries straight on from clip `a`: side by side on the
--- track, alike in kind, name and mute, playing the same take of the same
--- list, stretched, shifted and looped alike, and for sound every take
--- lined up across the join (the same file, gain and place in it), so that
--- one clip in their place plays just what the two did. Looped clips join
--- where the second carries on the first's repeats.
local function continues(a, b)
  if math.abs(a.start + a.length - b.start) > 1e-6 or a.kind ~= b.kind then return false end
  if a.name ~= b.name or (a.muted or false) ~= (b.muted or false) then return false end
  local ta, tb = M.of(a), M.of(b)
  if not (ta and tb) or ta.active ~= tb.active or #ta.list ~= #tb.list then return false end
  for i = 1, #ta.list do
    if ta.list[i].name ~= tb.list[i].name then return false end
  end
  for _, key in ipairs({ "stretch", "pitch", "stretch_mode", "source_tempo", "timebase", "loop", "loop_length" }) do
    if a[key] ~= b[key] then return false end
  end
  if a.loop then
    if a.kind == "audio" and ((a.fade_out or 0) > EPS or (b.fade_in or 0) > EPS) then return false end
    return loop_continues(a, b, ta, tb)
  end
  if a.kind == "midi" then
    if not (within(api.clip_notes(a.id), a.length) and within(api.clip_notes(b.id), b.length)) then return false end
    for i = 1, #ta.list do
      if not (within(ta.list[i].notes, a.length) and within(tb.list[i].notes, b.length)) then return false end
    end
    return true
  end
  if (a.fade_out or 0) > EPS or (b.fade_in or 0) > EPS then return false end
  local seconds = daw.stretch.file_seconds(a, a.length)
  for i = 1, #ta.list do
    local x, y = M.content(a, i), M.content(b, i)
    if x.file ~= y.file or math.abs((x.gain or 0) - (y.gain or 0)) > 1e-9 then return false end
    if math.abs(x.offset + seconds - y.offset) > 1e-6 then return false end
  end
  return true
end

local function shifted(list, by)
  local out = {}
  for i, item in ipairs(list or {}) do
    out[i] = copy(item)
    out[i].start = item.start + by
  end
  return out
end

local function append(into, more)
  for _, item in ipairs(more) do into[#into + 1] = item end
  return into
end

--- Make clip `b` part of clip `a`, which `continues` has found it carries on.
--- A looped clip already holds what the other repeats.
local function join(a, b)
  if a.loop then
    if a.kind == "audio" then api.clip_set(a.id, "fade_out", b.fade_out or 0) end
  elseif a.kind == "midi" then
    local ta, tb = M.of(a), M.of(b)
    api.clip_set_notes(a.id, append(api.clip_notes(a.id), shifted(api.clip_notes(b.id), a.length)))
    if a.control_count > 0 or b.control_count > 0 then
      local mine = a.control_count > 0 and api.clip_controls(a.id) or {}
      local theirs = b.control_count > 0 and api.clip_controls(b.id) or {}
      api.clip_set_controls(a.id, append(mine, shifted(theirs, a.length)))
    end
    local list = {}
    for i, entry in ipairs(ta.list) do
      local e = copy(entry)
      if i ~= ta.active then
        e.notes = append(shifted(entry.notes, 0), shifted(tb.list[i].notes, a.length))
        if entry.controls or tb.list[i].controls then
          e.controls = append(shifted(entry.controls, 0), shifted(tb.list[i].controls, a.length))
        end
      end
      list[i] = e
    end
    write(a.id, a, { active = ta.active, list = list })
  else
    api.clip_set(a.id, "fade_out", b.fade_out or 0)
  end
  api.clip_set(a.id, "length", a.length + b.length)
  api.clip_remove(b.id)
end

--- Join the pieces of a track that carry straight on from one another (see
--- `continues`), among those reaching from beat `from` to `to`, the ones
--- touching either end included. Returns how many joins were made.
function M.join_pieces(track, from, to)
  local joins = 0
  local again = true
  while again do
    again = false
    local list = api.clip_list(track)
    table.sort(list, function(x, y) return x.start < y.start end)
    for i = 1, #list - 1 do
      local a, b = list[i], list[i + 1]
      if a.start + a.length >= from - 1e-6 and b.start <= to + 1e-6 and continues(a, b) then
        join(a, b)
        joins, again = joins + 1, true
        break
      end
    end
  end
  return joins
end

--- Make take `take` play on a track from beat `from` to `to`: every clip
--- there with that many takes is cut at both ends where it reaches across
--- them, take `take` is chosen for each piece in between, and pieces side
--- by side that then play the same take are joined again where that is
--- exact (`M.join_pieces`). Clips without takes are left alone. Returns how
--- many pieces were given the take, or 0 when no clip there has it.
function M.comp(track, take, from, to)
  take = math.floor(take)
  from, to = math.max(0, math.min(from, to)), math.max(from, to)
  local function has(c)
    local n = M.count(c)
    return n > 1 and take >= 1 and take <= n
  end
  local function cut(at)
    local only = {}
    for _, c in ipairs(api.clip_list(track)) do
      if has(c) then only[c.id] = true end
    end
    daw.edit.arrange.clear(track, at, at, only)
  end
  local any = false
  for _, c in ipairs(api.clip_list(track)) do
    any = any or (has(c) and c.start < to - EPS and c.start + c.length > from + EPS)
  end
  if not any then return 0 end
  cut(from)
  cut(to)
  local n = 0
  for _, c in ipairs(api.clip_list(track)) do
    if c.start >= from - EPS and c.start + c.length <= to + EPS and has(c) then
      M.select(c.id, take)
      n = n + 1
    end
  end
  M.join_pieces(track, from, to)
  return n
end

--- The clip of a track at `beat` that has a take `take`, or nil.
local function piece_at(track, take, beat)
  for _, c in ipairs(api.clip_list(track)) do
    local n = M.count(c)
    if beat >= c.start - EPS and beat < c.start + c.length - EPS and n > 1 and take <= n then return c end
  end
end

--- Make take `take` play in the piece of a track at `beat`, and join it to
--- its neighbours where that is exact. Returns the clip, or nil if there is
--- no piece there with such a take.
function M.choose_at(track, take, beat)
  local c = piece_at(track, math.floor(take), beat)
  if not c then return nil end
  M.select(c.id, math.floor(take))
  M.join_pieces(track, c.start, c.start + c.length)
  return c
end

-- Take lanes -----------------------------------------------------------------------

local lanes_open = {}
do
  local saved = api.state_get("take_lanes_open")
  for key, on in pairs(type(saved) == "table" and saved or {}) do
    if on then lanes_open[tonumber(key) or key] = true end
  end
end

local function save_lanes()
  local out = {}
  for id, on in pairs(lanes_open) do
    if on then out[tostring(id)] = true end
  end
  api.state_set("take_lanes_open", out)
  api.ui_redraw()
  -- A graphical frontend draws them too.
  if daw.emit then daw.emit("lanes.changed", {}) end
end

local function id_of(track) return type(track) == "table" and track.id or track end

--- Whether a track shows its take lanes.
function M.lanes_shown(track)
  return lanes_open[id_of(track)] == true
end

--- Show a track's take lanes, or hide them (`on` false).
function M.show_lanes(track, on)
  lanes_open[id_of(track)] = on ~= false or nil
  save_lanes()
end

function M.toggle_lanes(track)
  M.show_lanes(track, not M.lanes_shown(track))
  return M.lanes_shown(track)
end

--- How many take lanes a track shows: as many as the most takes any of its
--- clips has, none while they are hidden or no clip has takes.
function M.lane_count(track)
  local id = id_of(track)
  if not lanes_open[id] then return 0 end
  local most = 0
  local ok, clips = pcall(api.clip_list, id)
  for _, c in ipairs(ok and clips or {}) do
    local n = M.count(c)
    if n > 1 then most = math.max(most, n) end
  end
  return most
end

-- A track that goes away takes its take lanes with it.
if daw.on then
  daw.on("track.removed", function(event)
    if lanes_open[event.id] then
      lanes_open[event.id] = nil
      save_lanes()
    end
  end)
end

-- Commands -----------------------------------------------------------------------

local function need_clip()
  local clip = daw.cursor.clip()
  if not clip then daw.notify("no clip under the cursor", "warn") return nil end
  if not M.of(clip.id) then daw.notify("the clip has no other takes: record with the loop on, or `:take.new`", "warn") return nil end
  return clip
end

local function said(id)
  local n, active = M.count(id)
  local takes = M.of(id)
  daw.notify(string.format("take %d of %d: %s", active, n, takes and takes.list[active].name or ""))
end

--- The cursor's track and the stretch of time selected on it, or nil when
--- no stretch is selected.
local function selected_stretch()
  local sel = daw.keymap.selection()
  local track = daw.cursor.track_id()
  if not (sel and sel.kind ~= "line" and sel.c0 and sel.c1 and sel.c1 > sel.c0 and track) then return nil end
  return track, sel.c0, sel.c1
end

daw.command("take", function(ctx)
  local word = ctx.args[1]
  local track, from, to
  if word then track, from, to = selected_stretch() end
  -- Comping: this take over the selected stretch, whatever plays around it.
  if track and tonumber(word) and M.comp(track, tonumber(word), from, to) > 0 then
    daw.keymap.set_mode("n")
    return daw.notify("take " .. word .. " over the selection")
  end
  local clip = need_clip()
  if not clip then return end
  if word == "next" or not word then
    M.step(clip.id, ctx.count or 1)
  elseif word == "prev" then
    M.step(clip.id, -(ctx.count or 1))
  else
    local index = tonumber(word)
    if not index then
      for i, entry in ipairs(M.of(clip.id).list) do
        if entry.name == table.concat(ctx.args, " ") then index = i end
      end
    end
    if not index then return daw.notify("take: a number, `next` or `prev`", "warn") end
    M.select(clip.id, index)
  end
  said(clip.id)
end, { desc = "Play another take of the clip: `take 2`, `take next`, `take prev`; over a selected stretch, only there" })

daw.command("take.list", function()
  local clip = need_clip()
  if not clip then return end
  local takes = M.of(clip.id)
  local items = {}
  for i, entry in ipairs(takes.list) do
    items[i] = { text = string.format("%s %d  %s", i == takes.active and "●" or " ", i, entry.name or ""), index = i }
  end
  daw.pick({ title = "Takes", items = items, on_choose = function(item)
    M.select(clip.id, item.index)
    said(clip.id)
  end })
end, { desc = "Choose the take that plays from a list" })

daw.command("take.new", function(ctx)
  local clip = daw.cursor.clip()
  if not clip then return daw.notify("no clip under the cursor", "warn") end
  local n = M.new(clip.id, ctx.args[1] and table.concat(ctx.args, " "))
  daw.notify("take " .. n .. ": a copy to change, with what was there kept as take " .. (n - 1))
end, { desc = "Keep what the clip plays as a take and carry on in a copy" })

daw.command("take.remove", function(ctx)
  local clip = need_clip()
  if not clip then return end
  M.remove(clip.id, tonumber(ctx.args[1]))
  if M.of(clip.id) then said(clip.id) else daw.notify("one take left: the clip is a clip again") end
end, { desc = "Throw away the playing take, or the one numbered: `take.remove 1`" })

daw.command("take.keep", function()
  local clip = need_clip()
  if not clip then return end
  M.keep(clip.id)
  daw.notify("kept the playing take alone")
end, { desc = "Throw away every take but the one that plays" })

daw.command("take.lanes", function(ctx)
  local track = daw.cursor.track_id()
  if not track then return daw.notify("no track selected", "warn") end
  local word = ctx.args[1]
  local on
  if word == "on" or word == "off" then
    M.show_lanes(track, word == "on")
    on = word == "on"
  else
    on = M.toggle_lanes(track)
  end
  if not on then return daw.notify("take lanes hidden") end
  local n = M.lane_count(track)
  if n == 0 then return daw.notify("take lanes shown: no clip of this track has takes yet") end
  daw.notify(n .. " take lanes: a drag across one in the window makes that take play there; `:take 2` over a selection here")
end, { desc = "Show the track's takes as lanes under its clips, or hide them: `take.lanes`, `take.lanes on`" })

daw.command("take.explode", function()
  local clip = need_clip()
  if not clip then return end
  local tracks = M.explode(clip.id)
  daw.notify(#tracks .. " takes are clips on tracks of their own now")
end, { desc = "Put every other take on a track of its own" })

return M
