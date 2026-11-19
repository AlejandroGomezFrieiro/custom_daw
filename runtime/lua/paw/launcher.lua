-- Clip launching, for playing live: every track has slots, a column of
-- clips kept apart from the timeline, and a row of slots across the tracks
-- is a scene. Launching a slot starts its clip looping on its track at the
-- next boundary of its quantize (a bar by default), to the frame; while a
-- track plays a slot, or has been stopped, its clips on the timeline are
-- silent until it goes back to the arrangement. Stopping the song sends
-- every track back. A render plays the timeline: `capture` writes a
-- performance into it.
--
--   :launch                 the slot under the session view's cursor
--   :scene 2                every clip in the second row
--   :launch.stop            stop the track's clip; `launch.stop all` every one
--   :launch.back            back to the arrangement; `launch.back all`
--   :launch.quantize 1/8    where launches land (off 1/16 1/8 1/4 beat bar 2bars 4bars)
--   paw.launcher.launch(track.id, 0)
--
-- The clips are clips like any other (`paw.api.clip_add(track, { slot = row })`),
-- saved with the project and undone like any edit. Scene names are kept in
-- `project.meta.scenes`. Rows count from 0 here and in `paw.api`, from 1 in
-- commands and on screen.
local api = paw.api
local M = {
  -- The slot the session view's cursor is on, as a row from 0; the track
  -- is the cursor's.
  row = 0,
  quantizes = { "off", "1/16", "1/8", "1/4", "beat", "bar", "2bars", "4bars" },
  modes = { "trigger", "gate", "toggle" },
  -- A performance is being written into the timeline.
  capturing = false,
}

-- Rows the session view shows at least.
paw.option.define("launch_rows", 8)

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

--- The clips in a track's slots, by row: `{ [row] = clip view }`.
function M.slots(track)
  local out = {}
  for _, clip in ipairs(api.slot_list(track)) do out[clip.slot] = clip end
  return out
end

--- The clip in a slot, or nil.
function M.clip(track, row)
  for _, clip in ipairs(api.slot_list(track)) do
    if clip.slot == row then return clip end
  end
end

--- What each track plays and has in its queue, by track id: see
--- `paw.api.launcher`. A track with no launched clip is not in the table.
function M.state()
  local out = {}
  for _, s in ipairs(api.launcher()) do
    if s.slot or s.stopped or s.queued then out[s.track] = s end
  end
  return out
end

--- What one track plays: "arrangement", "stopped" or a row. The second
--- value is what it has in its queue, if anything.
function M.playing(track)
  local s = M.state()[track]
  if not s then return "arrangement" end
  return s.slot or (s.stopped and "stopped" or "arrangement"), s.queued
end

--- The names of the scenes, by row from 1. Rows without a name are nil.
function M.scenes()
  local scenes = api.project_get().meta.scenes
  return type(scenes) == "table" and scenes or {}
end

--- A scene's name (rows from 0): its own, or "Scene N".
function M.scene_name(row)
  local name = M.scenes()[row + 1]
  return (type(name) == "string" and name ~= "") and name or ("Scene " .. (row + 1))
end

--- Name a scene (rows from 0), kept with the project.
function M.set_scene_name(row, name)
  local meta = api.project_get().meta
  local scenes = type(meta.scenes) == "table" and meta.scenes or {}
  for i = 1, row do scenes[i] = scenes[i] or "" end
  scenes[row + 1] = name
  while #scenes > 0 and scenes[#scenes] == "" do scenes[#scenes] = nil end
  meta.scenes = #scenes > 0 and scenes or nil
  api.project_set("meta", meta)
end

--- How many rows there are: those with clips or names, one empty row more,
--- and at least `paw.opt.launch_rows`.
function M.rows()
  local last = #M.scenes()
  for _, id in ipairs(api.track_list()) do
    for _, clip in ipairs(api.slot_list(id)) do last = math.max(last, clip.slot + 1) end
  end
  return math.max(paw.opt.launch_rows, last + 1)
end

-- Launching ------------------------------------------------------------------

--- Send launches, and start the song if it is stopped: launched while
--- stopped, clips start at once.
local function send(list, start)
  if #list == 0 then return end
  api.launch(list)
  if start and not paw.transport.playing then paw.transport.play() end
  api.ui_redraw()
end

--- Launch the clip in a slot on its next boundary. An empty slot stops the
--- track. `opts.quantize` and `opts.legato` replace the values of the slot.
function M.launch(track, row, opts)
  opts = opts or {}
  send({ { track = track, slot = row, quantize = opts.quantize, legato = opts.legato } }, true)
end

--- A slot's button pressed, from a key, the mouse or a controller: what that
--- does is the clip's mode. A toggle stops a clip that plays or is queued.
function M.press(track, row)
  local clip = M.clip(track, row)
  local now, queued = M.playing(track)
  if clip and clip.mode == "toggle" and (now == row or queued == row) then return M.stop(track) end
  M.launch(track, row)
end

--- A slot's button let go: a gate clip stops.
function M.release(track, row)
  local clip = M.clip(track, row)
  local now, queued = M.playing(track)
  if clip and clip.mode == "gate" and (now == row or queued == row) then M.stop(track) end
end

--- Stop the clip of a track on the next boundary. With no track, stop the
--- clips of all tracks. A stopped track makes no sound until you launch it
--- again or send it back to its timeline.
function M.stop(track)
  local list = {}
  if track then
    list[1] = { track = track, stop = true }
  else
    for id, s in pairs(M.state()) do
      if s.slot or (s.queued and s.queued ~= "stop") then list[#list + 1] = { track = id, stop = true } end
    end
  end
  send(list)
end

--- Send a track back to its timeline. With no track, send back each track
--- that left its timeline.
function M.back(track)
  local list = {}
  if track then
    list[1] = { track = track, arrangement = true }
  else
    for id in pairs(M.state()) do list[#list + 1] = { track = id, arrangement = true } end
  end
  send(list)
end

--- Launch a scene: the clip in that row on every track that has one, all
--- on the same boundary. Tracks without one stop what they play from a slot.
function M.scene(row)
  local list, state = {}, M.state()
  for _, id in ipairs(api.track_list()) do
    if M.clip(id, row) then
      list[#list + 1] = { track = id, slot = row }
    elseif state[id] and state[id].slot then
      list[#list + 1] = { track = id, stop = true }
    end
  end
  send(list, true)
end

--- Where launches land unless a slot says otherwise.
function M.set_quantize(q)
  if not contains(M.quantizes, q) then
    error("a quantize is one of " .. table.concat(M.quantizes, ", "), 2)
  end
  api.project_set("launch_quantize", q)
end

-- Making clips in slots --------------------------------------------------------

--- An empty MIDI clip of `bars` bars (1) in a slot. Returns its id.
function M.new_clip(track, row, bars)
  local length = paw.time.bar(0) * (bars or 1)
  return api.clip_add(track, { slot = row, length = length, name = "clip " .. (row + 1) })
end

--- Copy a clip from the timeline (or another slot) into a slot.
function M.copy(clip, track, row)
  return api.clip_to_slot(clip, track, row)
end

-- Recording into a slot ----------------------------------------------------------
--
-- An empty slot of a track records `bars` bars from the next boundary. The
-- take is made by the transport's recording, as any take is; when the bars
-- are done the part of it between the two boundaries becomes the slot's
-- clip, the take leaves the timeline, and the clip plays on in step, as if
-- it had been playing since the first boundary.

-- The slot being recorded: { track, row, from, to, before = clip ids on the
-- track before }, or nil.
M.recording = nil
local rec_timer

local grids = { ["1/16"] = 0.25, ["1/8"] = 0.5, ["1/4"] = 1 }
local bar_counts = { bar = 1, ["2bars"] = 2, ["4bars"] = 4 }

--- The first boundary of a quantize (the project's by default) at or after
--- `beat`, as the engine finds it.
function M.boundary(beat, q)
  q = q or api.project_get().launch_quantize
  if q == "off" then return beat end
  local bar = api.tempo_bar_of(beat)
  local start = api.tempo_bar_start(bar)
  local every = bar_counts[q]
  if every then
    if start < beat - 1e-9 then bar = bar + 1 end
    return api.tempo_bar_start(math.ceil(bar / every) * every)
  end
  local unit = grids[q] or 4 / select(2, paw.tempo.signature_at(beat))
  local steps = math.max(0, math.ceil((beat - start) / unit - 1e-9))
  return math.min(start + steps * unit, api.tempo_bar_start(bar + 1))
end

--- The part of a recorded clip from `from` to `to`, as options for a clip
--- in a slot.
local function piece(c, from, to)
  local opts = { name = "rec " .. c.name, length = to - from }
  if c.kind == "midi" then
    opts.notes, opts.controls = {}, {}
    for _, n in ipairs(api.clip_notes(c.id)) do
      local at = c.start + n.start
      if at >= from - 1e-9 and at < to - 1e-9 then
        opts.notes[#opts.notes + 1] = { pitch = n.pitch, velocity = n.velocity, start = at - from, length = math.min(n.length, to - at) }
      end
    end
    for _, m in ipairs(c.control_count > 0 and api.clip_controls(c.id) or {}) do
      local at = c.start + m.start
      if at >= from - 1e-9 and at < to - 1e-9 then opts.controls[#opts.controls + 1] = paw.util.merge(m, { start = at - from }) end
    end
  else
    opts.file, opts.gain = c.file, c.gain
    opts.offset = c.offset + paw.time.seconds(from - c.start, c.start)
  end
  return opts
end

--- End the clip being recorded into a slot.
local function finish_recording()
  local r = M.recording
  if not r then return end
  M.recording = nil
  if rec_timer then paw.cancel(rec_timer) end
  rec_timer = nil
  local stopped_at = paw.transport.position
  -- Ending the take puts it on the timeline, as any take.
  paw.transport.recording = false
  if r.punch then api.transport_set("punch_enabled", true) end
  local made
  for _, c in ipairs(api.clip_list(r.track)) do
    if not r.before[c.id] then
      if not made and c.start <= r.from + 1e-9 and c.start + c.length > r.from then
        local opts = piece(c, r.from, r.to)
        opts.slot = r.row
        made = api.clip_add(r.track, opts)
      end
      api.clip_remove(c.id)
    end
  end
  api.undo_checkpoint()
  api.ui_redraw()
  if not made then
    return paw.notify("nothing was recorded into the slot: the song stopped before its first boundary", "warn")
  end
  -- Going on in step: the loop counts from where the recording began.
  if paw.transport.playing and stopped_at >= r.to - 1e-9 then
    api.launch({ { track = r.track, slot = r.row, quantize = "off", from = r.from } })
  end
end

--- Record `bars` bars (1) into an empty slot of a track, from the next
--- boundary of the quantize of the project. paw arms the track if it is not
--- armed. The track stops what it plays at that boundary. If the song is
--- stopped, it starts. If you stop the song early, paw keeps the recording.
function M.record(track, row, bars)
  if M.clip(track, row) then error("the slot holds a clip already", 2) end
  if M.recording then error("a slot is being recorded already", 2) end
  if not api.track_get(track, "armed") then api.track_set(track, "armed", true) end
  local before = {}
  for _, c in ipairs(api.clip_list(track)) do before[c.id] = true end
  -- The slot's bars are the take: punching (and with it the pre-roll) is
  -- set aside until they are done. A count-in still leads in when stopped.
  local punch = api.transport_get().punch_enabled
  if punch then api.transport_set("punch_enabled", false) end
  if paw.transport.playing then
    paw.transport.recording = true
  else
    paw.transport.record()
  end
  local from = M.boundary(paw.transport.position)
  M.recording = { track = track, row = row, from = from, to = from + (bars or 1) * paw.time.bar(from), before = before, punch = punch }
  api.launch({ { track = track, stop = true } })
  rec_timer = paw.every(10, function()
    local r = M.recording
    if r and (not paw.transport.playing or paw.transport.position >= r.to) then finish_recording() end
  end)
  api.ui_redraw()
end

--- Stop recording into a slot now, keeping what was recorded.
M.finish_recording = finish_recording

-- Capturing a performance ------------------------------------------------------
--
-- While capturing and playing, what each track plays is read from the engine
-- every few milliseconds; the engine says on which beat each launch
-- happened, so the timeline gets them exactly. When the song stops, every
-- stretch a track played a slot becomes a looped copy of the clip there, and
-- every stretch it was stopped is cleared, in one undo step.

local log, last, timer = {}, {}, nil

--- Begin or end a stretch for a track, from what the engine says of it.
local function note(s, position)
  local was = last[s.track]
  local key = string.format("%s|%.9f", tostring(s.slot or s.stopped or "timeline"), s.since)
  if was and was.key == key then return end
  if was and was.kind then was.to = s.since end
  if s.slot or s.stopped then
    -- How far into its loop the clip was where it began (a legato launch).
    local phase = s.slot and s.length and ((s.phase or 0) - (position - s.since)) % s.length or 0
    local entry = { kind = s.slot and "slot" or "stop", row = s.slot, from = s.since, phase = phase, key = key }
    log[#log + 1] = { track = s.track, entry = entry }
    last[s.track] = entry
  else
    last[s.track] = { key = key }
  end
end

local function poll()
  if not paw.transport.playing then return end
  local position = paw.transport.position
  for _, s in ipairs(api.launcher()) do note(s, position) end
end

--- Write what was captured into the timeline.
local function write(position)
  for track, entry in pairs(last) do
    if entry.kind and not entry.to then entry.to = position end
    last[track] = nil
  end
  local wrote = 0
  for _, item in ipairs(log) do
    local e, track = item.entry, item.track
    if e.to and e.to - e.from > 1e-9 and pcall(api.track_get, track) then
      paw.edit.arrange.clear(track, e.from, e.to)
      local clip = e.kind == "slot" and M.clip(track, e.row)
      if clip then
        local snap = paw.clip(clip.id):snapshot()
        snap.slot, snap.quantize, snap.mode, snap.legato = nil, nil, nil, nil
        snap.start, snap.length = e.from, e.to - e.from
        snap.loop, snap.loop_length, snap.loop_start = true, clip.length, 0
        if clip.kind == "midi" and e.phase > 1e-9 then
          -- Begun partway through its loop: the loop starts that much before the clip.
          snap.loop_start = -e.phase
          for _, n in ipairs(snap.notes or {}) do n.start = n.start - e.phase end
          for _, c in ipairs(snap.controls or {}) do c.start = c.start - e.phase end
        end
        paw.restore_clip(snap, track)
      end
      wrote = wrote + 1
    end
  end
  log = {}
  return wrote
end

--- Start or stop the capture. If you stop it while the song plays, paw
--- writes the captured notes.
function M.capture(on)
  if on == nil then on = not M.capturing end
  if on == M.capturing then return end
  M.capturing = on
  if on then
    log, last = {}, {}
    timer = paw.every(10, poll)
    poll()
    paw.notify("capturing: what is launched is written into the timeline when the song stops")
  else
    if timer then paw.cancel(timer) end
    timer = nil
    poll()
    M.write_captured(paw.transport.position)
  end
  api.ui_redraw()
end

--- Write the captured notes that paw did not write yet, as one undo step,
--- up to `position` where the capture continues.
function M.write_captured(position)
  if #log == 0 then return end
  local wrote = write(position)
  api.undo_checkpoint()
  if wrote > 0 then paw.notify("captured " .. wrote .. (wrote == 1 and " clip" or " clips") .. " into the timeline") end
end

-- The song stopped where it says: so did what was launched.
paw.on("transport.stop", function(e)
  if M.capturing then M.write_captured(e.position or paw.transport.position) end
end)

paw.on("project.loaded", function()
  M.row = 0
  if M.capturing then M.capture(false) end
end)

-- Commands ---------------------------------------------------------------------

local function track_or_warn()
  local id = paw.cursor.track_id()
  if not id or id == 0 then paw.notify("no track selected", "warn") end
  return id ~= 0 and id or nil
end

--- A row from a command's argument (from 1), or the cursor's.
local function row_arg(arg)
  local n = tonumber(arg)
  return n and math.max(0, math.floor(n) - 1) or M.row
end

paw.command("launch", function(ctx)
  local track = track_or_warn()
  if track then M.press(track, row_arg(ctx.args[1])) end
end, { desc = "Launch a slot of the selected track: `launch 2`, or the one under the cursor" })
paw.command("launch.stop", function(ctx)
  if ctx.args[1] == "all" then return M.stop() end
  local track = track_or_warn()
  if track then M.stop(track) end
end, { desc = "Stop the selected track's clip on the next boundary: `launch.stop all` stops every one", complete = { "all" } })
paw.command("launch.back", function(ctx)
  if ctx.args[1] == "all" then return M.back() end
  local track = track_or_warn()
  if track then M.back(track) end
end, { desc = "Have the selected track play its timeline again: `launch.back all` for every track", complete = { "all" } })
paw.command("launch.quantize", function(ctx)
  local q = ctx.args[1]
  if not q then return paw.notify("launches land on: " .. api.project_get().launch_quantize) end
  M.set_quantize(q)
end, { desc = "Where launches land: `launch.quantize 1/8` (off 1/16 1/8 1/4 beat bar 2bars 4bars)", complete = M.quantizes })
paw.command("launch.capture", function() M.capture() end, {
  desc = "Write what is launched into the timeline when the song stops (again: stop capturing)",
})
paw.command("scene", function(ctx) M.scene(row_arg(ctx.args[1])) end, {
  desc = "Launch a scene, every clip in a row: `scene 2`, or the cursor's row",
})
paw.command("scene.name", function(ctx)
  local name = table.concat(ctx.args, " ")
  if name ~= "" then return M.set_scene_name(M.row, name) end
  paw.ui.input({ prompt = "Scene name: ", text = M.scene_name(M.row) }, function(text)
    if text then M.set_scene_name(M.row, text) end
  end)
end, { desc = "Name the scene of the cursor's row: `scene.name Chorus`" })

--- The clip in the slot under the cursor, or a warning.
local function slot_clip()
  local track = track_or_warn()
  local clip = track and M.clip(track, M.row)
  if track and not clip then paw.notify("the slot is empty", "warn") end
  return clip
end

paw.command("slot.new", function(ctx)
  local track = track_or_warn()
  if not track then return end
  if M.clip(track, M.row) then return paw.notify("the slot holds a clip already", "warn") end
  M.new_clip(track, M.row, tonumber(ctx.args[1]))
end, { desc = "A new MIDI clip in the slot under the cursor: `slot.new 2` for two bars" })
paw.command("slot.record", function(ctx)
  if M.recording then return M.finish_recording() end
  local track = track_or_warn()
  if not track then return end
  if M.clip(track, M.row) then return paw.notify("the slot holds a clip already", "warn") end
  M.record(track, M.row, tonumber(ctx.args[1]) or ctx.count)
end, { desc = "Record into the empty slot under the cursor from the next boundary: `slot.record 2` for two bars (again: stop now)" })
paw.command("slot.copy", function()
  local track = track_or_warn()
  local clip = track and paw.cursor.clip()
  if not clip then return paw.notify("no clip under the arrange view's cursor", "warn") end
  M.copy(clip.id, track, M.row)
end, { desc = "Copy the clip under the arrange view's cursor into the slot under the session view's" })
paw.command("slot.delete", function()
  local clip = slot_clip()
  if clip then api.clip_remove(clip.id) end
end, { desc = "Empty the slot under the cursor" })
paw.command("slot.edit", function()
  local clip = slot_clip()
  if clip and clip.kind == "midi" then paw.ui.views.pianoroll:edit(paw.clip(clip.id)) end
end, { desc = "Open the notes of the clip in the slot under the cursor" })
paw.command("slot.mode", function(ctx)
  local clip = slot_clip()
  if not clip then return end
  local mode = ctx.args[1]
  if not mode then
    -- Round the modes.
    for i, m in ipairs(M.modes) do
      if m == clip.mode then mode = M.modes[i % #M.modes + 1] end
    end
  end
  if not contains(M.modes, mode) then return paw.notify("a mode is trigger, gate or toggle", "warn") end
  api.clip_set(clip.id, "mode", mode)
  paw.notify(clip.name .. ": " .. mode)
end, { desc = "How the slot's clip launches: `slot.mode gate` (trigger, gate, toggle; none goes round them)", complete = M.modes })
paw.command("slot.legato", function()
  local clip = slot_clip()
  if clip then api.clip_set(clip.id, "legato", not clip.legato) end
end, { desc = "Have the slot's clip take over where the clip before it had got to, or not" })
paw.command("slot.quantize", function(ctx)
  local clip = slot_clip()
  if not clip then return end
  local q = ctx.args[1]
  if q and q ~= "project" and not contains(M.quantizes, q) then
    return paw.notify("a quantize is project or one of " .. table.concat(M.quantizes, ", "), "warn")
  end
  api.clip_set(clip.id, "quantize", (q and q ~= "project") and q or nil)
end, {
  desc = "Where the slot's clip launches: `slot.quantize 1/16`, or `slot.quantize` for the project's",
  complete = function() return { "project", unpack(M.quantizes) } end,
})
paw.command("slot.length", function(ctx)
  local clip = slot_clip()
  local bars = tonumber(ctx.args[1])
  if clip and bars and bars > 0 then api.clip_set(clip.id, "length", bars * paw.time.bar(0)) end
end, { desc = "How many bars the slot's clip loops over: `slot.length 2`" })

return M
