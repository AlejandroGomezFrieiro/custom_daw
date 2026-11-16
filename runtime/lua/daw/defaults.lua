-- The default commands and key mappings. This file uses nothing but the
-- public `daw` module: anything here can be redefined from `init.lua` with the
-- same calls.
local api = daw.api
local util = daw.util
local command, map = daw.command, daw.keymap.set
local cursor, transport = daw.cursor, daw.transport
local keymap, edit = daw.keymap, daw.edit
local roll = daw.ui.views.pianoroll

local function need_track()
  local track = cursor.track()
  if not track then daw.notify("no track selected", "warn") end
  return track
end

local function need_clip()
  local clip = cursor.clip()
  if not clip then daw.notify("no clip under the cursor", "warn") end
  return clip
end

-- Transport ------------------------------------------------------------------

command("transport.toggle", transport.toggle, { desc = "Play or stop" })
command("transport.play", transport.play, { desc = "Play" })
command("transport.stop", transport.stop, { desc = "Stop" })
command("transport.start", function() transport.seek(0) end, { desc = "Move the playhead to the start" })
command("transport.to_cursor", function() transport.seek(cursor.beat) end, { desc = "Move the playhead to the cursor" })
command("transport.play_cursor", function()
  transport.seek(cursor.beat)
  transport.play()
end, { desc = "Play from the cursor" })
command("transport.seek", function(ctx)
  transport.seek(daw.time.bar_start(tonumber(ctx.args[1]) or 1))
end, { desc = "Move the playhead to a bar: `transport.seek 5`" })
command("transport.loop", function(ctx)
  local from, to = tonumber(ctx.args[1]), tonumber(ctx.args[2])
  if from and to then
    transport.loop_start, transport.loop_end = daw.time.bar_start(from), daw.time.bar_start(to + 1)
    transport.loop_enabled = true
  else
    transport.loop_enabled = not transport.loop_enabled
  end
end, { desc = "Toggle looping, or loop bars: `transport.loop 1 4`" })
command("transport.loop_clip", function()
  local clip = need_clip()
  if not clip then return end
  local c = clip:get()
  transport.loop_start, transport.loop_end, transport.loop_enabled = c.start, c.start + c.length, true
end, { desc = "Loop the clip under the cursor" })
command("transport.record", function()
  if transport.recording then
    transport.recording = false
  else
    transport.record()
  end
end, { desc = "Record armed tracks from the playhead, or stop recording" })
command("transport.metronome", function()
  transport.metronome = not transport.metronome
end, { desc = "Toggle the metronome" })

-- The count-in is an option (`daw.opt.count_in`, bars) that the kernel is
-- told of: it counts before a take begun with the song stopped.
local function count_in_bars(value)
  return util.clamp(math.floor(tonumber(value) or 0), 0, 16)
end
api.transport_set("count_in", count_in_bars(daw.opt.count_in))
daw.on("option.changed", function(e)
  if e.name == "count_in" then api.transport_set("count_in", count_in_bars(e.value)) end
end)
-- Esc while counting in calls the take off, as stopping does.
daw.on("escape", function()
  if (api.transport_get().counting or 0) > 0 then transport.stop() end
end)
local last_count = 1
command("countin", function(ctx)
  local word = ctx.args[1]
  local bars
  if word == "off" or word == "0" then
    bars = 0
  elseif tonumber(word) then
    bars = count_in_bars(word)
  elseif word == nil then
    bars = daw.opt.count_in > 0 and 0 or last_count
  else
    return daw.notify("countin: a number of bars, or `off`", "warn")
  end
  if bars > 0 then last_count = bars end
  daw.opt.count_in = bars
  daw.notify(bars > 0 and string.format("count-in: %d bar%s before a take", bars, bars == 1 and "" or "s") or "count-in off")
end, { desc = "Count bars in before recording from a stop: `countin 1`, `countin off`, or toggle" })

-- The pre-roll is two options (`daw.opt.pre_roll` bars and
-- `daw.opt.pre_roll_seconds`) that the kernel is told of: a take punched in
-- from a stop starts playing that long before the punch in.
local function pre_roll_values()
  return util.clamp(math.floor(tonumber(daw.opt.pre_roll) or 0), 0, 16),
    util.clamp(tonumber(daw.opt.pre_roll_seconds) or 0, 0, 30)
end
local function send_pre_roll()
  local bars, seconds = pre_roll_values()
  api.transport_set("pre_roll", bars)
  api.transport_set("pre_roll_seconds", seconds)
end
send_pre_roll()
daw.on("option.changed", function(e)
  if e.name == "pre_roll" or e.name == "pre_roll_seconds" then send_pre_roll() end
end)
local last_pre_roll = 2
command("preroll", function(ctx)
  local word = ctx.args[1]
  local bars, seconds = 0, 0
  if word == "off" or word == "0" then
    bars = 0
  elseif word == nil then
    local now_bars, now_seconds = pre_roll_values()
    bars = (now_bars > 0 or now_seconds > 0) and 0 or last_pre_roll
  elseif tostring(word):match("^%d+%.?%d*s$") then
    seconds = tonumber(word:sub(1, -2))
  elseif tonumber(word) then
    bars = tonumber(word)
  else
    return daw.notify("preroll: a number of bars, `3s` for seconds, or `off`", "warn")
  end
  if bars > 16 or seconds > 30 then return daw.notify("preroll: up to 16 bars or 30 seconds", "warn") end
  bars = math.floor(bars)
  if bars > 0 then last_pre_roll = bars end
  daw.opt.pre_roll, daw.opt.pre_roll_seconds = bars, seconds
  if bars > 0 then
    daw.notify(string.format("pre-roll: %d bar%s before the punch in", bars, bars == 1 and "" or "s"))
  elseif seconds > 0 then
    daw.notify(string.format("pre-roll: %g seconds before the punch in", seconds))
  else
    daw.notify("pre-roll off")
  end
end, { desc = "Play bars (or `3s` seconds) before the punch in when recording from a stop: `preroll 2`, `preroll 3s`, `preroll off`, or toggle" })

--- Punch in and out: record only between two points while the song plays.
--- The range is kept with the project, as the loop is.
local function punch_from_selection()
  local sel = keymap.selection()
  if sel and sel.kind ~= "line" and sel.c0 and sel.c1 and sel.c1 > sel.c0 then return sel.c0, sel.c1, "the selection" end
  if transport.loop_end > transport.loop_start then return transport.loop_start, transport.loop_end, "the loop" end
end
local function said_punch()
  local t = api.transport_get()
  if not t.punch_enabled then return daw.notify("punch off: recording takes in everything") end
  daw.notify(string.format("punch in at %s, out at %s", daw.time.format(t.punch_start), daw.time.format(t.punch_end)))
end
command("punch", function(ctx)
  local word = ctx.args[1]
  local from, to = tonumber(ctx.args[1]), tonumber(ctx.args[2])
  if from and to then
    transport.punch_start, transport.punch_end = daw.time.bar_start(math.min(from, to)), daw.time.bar_start(math.max(from, to) + 1)
    transport.punch_enabled = true
  elseif word == "selection" or (word == nil and not transport.punch_enabled and transport.punch_end <= transport.punch_start) then
    -- The first time, or when asked: the selection, else the loop.
    local a, b, what = punch_from_selection()
    if not a then return daw.notify("punch: select a stretch of time, or set the loop, or say `punch 5 8`", "warn") end
    transport.punch_start, transport.punch_end, transport.punch_enabled = a, b, true
    if keymap.mode == "x" then keymap.set_mode("n") end
    daw.notify(string.format("punch over %s: in at %s, out at %s", what, daw.time.format(a), daw.time.format(b)))
    return
  elseif word == "off" or word == "on" then
    transport.punch_enabled = word == "on" and transport.punch_end > transport.punch_start
  elseif word == nil then
    transport.punch_enabled = not transport.punch_enabled
  else
    return daw.notify("punch: `punch`, `punch 5 8` (bars), `punch selection`, `punch off`", "warn")
  end
  said_punch()
end, { desc = "Record only between two points: toggle, `punch 5 8` (bars), `punch selection` (or the loop)" })
-- `tempo`, `tempo.ramp`, `tempo.remove`, `tempo.list`, `tempo.tap`, `timesig`.
daw.tempo.commands(command)
-- `tempo.lane`, `tempo.move`.
daw.tempolane.commands(command)

-- Cursor ---------------------------------------------------------------------

command("cursor.down", function(ctx) cursor.move_track(ctx.count or 1) end, { desc = "Next track" })
command("cursor.up", function(ctx) cursor.move_track(-(ctx.count or 1)) end, { desc = "Previous track" })
command("cursor.right", function(ctx)
  cursor.set_beat(cursor.beat + (ctx.count or 1) * daw.opt.grid)
end, { desc = "Move right one grid step" })
command("cursor.left", function(ctx)
  cursor.set_beat(cursor.beat - (ctx.count or 1) * daw.opt.grid)
end, { desc = "Move left one grid step" })
command("cursor.next_bar", function(ctx)
  cursor.set_beat(daw.time.bar_start(daw.time.bar_of(cursor.beat) + (ctx.count or 1)))
end, { desc = "Start of the next bar" })
command("cursor.prev_bar", function(ctx)
  -- From inside a bar, its own start is the first one back.
  local bar = daw.time.bar_of(cursor.beat) - (ctx.count or 1) + (daw.tempo.is_bar_line(cursor.beat) and 0 or 1)
  cursor.set_beat(daw.time.bar_start(math.max(1, bar)))
end, { desc = "Start of the previous bar" })
command("cursor.start", function() cursor.set_beat(0) end, { desc = "Start of the project" })

--- Where the clips on the cursor's track start or end, in order.
local function clip_edges(which)
  local track, out = cursor.track(), {}
  for _, c in ipairs(track and api.clip_list(track.id) or {}) do
    out[#out + 1] = which == "end" and c.start + c.length or c.start
  end
  table.sort(out)
  return out
end

command("cursor.end", function()
  local ends = clip_edges("end")
  cursor.set_beat(ends[#ends] or 0)
end, { desc = "End of the track's last clip" })
command("cursor.first_clip", function()
  cursor.set_beat(clip_edges("start")[1] or 0)
end, { desc = "Start of the track's first clip" })
command("cursor.next_clip", function(ctx)
  for _ = 1, ctx.count or 1 do
    local to
    for _, beat in ipairs(clip_edges("start")) do
      if beat > cursor.beat + 1e-9 then
        to = beat
        break
      end
    end
    -- After the last clip there is only the end of it to go to.
    if not to then
      local ends = clip_edges("end")
      to = ends[#ends]
    end
    if not to or to <= cursor.beat then return end
    cursor.set_beat(to)
  end
end, { desc = "Start of the next clip on the track" })
command("cursor.prev_clip", function(ctx)
  for _ = 1, ctx.count or 1 do
    local to = 0
    for _, beat in ipairs(clip_edges("start")) do
      if beat < cursor.beat - 1e-9 then to = beat end
    end
    cursor.set_beat(to)
  end
end, { desc = "Start of the clip under the cursor, or of the one before" })
command("cursor.clip_end", function(ctx)
  for _ = 1, ctx.count or 1 do
    for _, beat in ipairs(clip_edges("end")) do
      if beat > cursor.beat + 1e-9 then
        cursor.set_beat(beat)
        break
      end
    end
  end
end, { desc = "End of the clip under the cursor, or of the next one" })
command("cursor.bar", function(ctx)
  cursor.set_beat(daw.time.bar_start(ctx.count or tonumber(ctx.args[1]) or 1))
end, { desc = "Start of a bar: `cursor.bar 9`" })
command("cursor.first_track", function(ctx)
  local list = api.track_list()
  if #list > 0 then cursor.set_track(list[util.clamp(ctx.count or 1, 1, #list)]) end
end, { desc = "First track, or track number N" })
command("cursor.last_track", function(ctx)
  local list = api.track_list()
  if #list > 0 then cursor.set_track(list[util.clamp(ctx.count or #list, 1, #list)]) end
end, { desc = "Last track, or track number N" })
command("cursor.to_playhead", function()
  cursor.set_beat(cursor.snap(transport.position))
end, { desc = "Move the cursor to the playhead" })

-- Tracks ---------------------------------------------------------------------

command("track.add", function(ctx)
  local index = cursor.index()
  local track = daw.add_track({
    name = ctx.args.name or ctx.args[1] and tostring(ctx.args[1]) or nil,
    index = index and (ctx.args.above and index or index + 1) or nil,
  })
  if ctx.args.device then
    -- Do not leave a track behind when its device cannot be added.
    local ok, err = pcall(track.add_device, track, ctx.args.device)
    if not ok then
      track:remove()
      error(err, 0)
    end
  end
  cursor.set_track(track)
  return track
end, { desc = "Add a track below the cursor, or above it: `track.add Bass device=synth`, `track.add above=true`" })
command("track.remove", function()
  local track = need_track()
  if not track then return end
  local index = cursor.index()
  track:remove()
  local list = api.track_list()
  if #list > 0 then cursor.set_track(list[math.min(index, #list)]) end
end, { desc = "Remove the track" })
command("track.rename", function(ctx)
  local track = need_track()
  if not track then return end
  if ctx.args[1] then
    track.name = tostring(ctx.args[1])
  else
    daw.ui.input({ prompt = "Track name: ", text = track.name }, function(name)
      if name ~= "" then track.name = name end
    end)
  end
end, { desc = "Rename the track" })
-- The theme's track colours by name, for `track.color`.
local colour_names = require("daw.theme").hue_names
command("track.color", function(ctx)
  local track = need_track()
  if not track then return end
  local want = ctx.args[1] and tostring(ctx.args[1]):lower()
  if not want then
    return daw.notify("track.color takes " .. table.concat(colour_names, ", ") .. ", a colour as #rrggbb, or none")
  end
  local hues = require("daw.theme").hues
  for i, name in ipairs(colour_names) do
    if name == want then want = hues[i] end
  end
  if want == "none" then
    track.color = nil
  elseif want:match("^#%x%x%x%x%x%x$") then
    track.color = want
  else
    daw.notify("no colour `" .. want .. "`: use " .. table.concat(colour_names, ", ") .. ", #rrggbb, or none", "warn")
  end
end, {
  desc = "Give the track a colour: `track.color teal`, `track.color #ff8800`, `track.color none`",
  complete = function()
    local words = { "none" }
    for _, name in ipairs(colour_names) do words[#words + 1] = name end
    return words
  end,
})
-- Where a track's sound goes: its output and its sends.

--- A track by a part of its name, or the master for "master".
local function track_named(name)
  if not name or name == "" then return nil end
  if name:lower() == "master" then return 0 end
  local found
  for _, id in ipairs(api.track_list()) do
    local known = api.track_get(id).name
    if known == name then return id end
    if known:lower():find(name:lower(), 1, true) then found = found or id end
  end
  return found
end

--- Choose among the tracks a track can play into or send to.
local function pick_target(track, title, with_master, on_choose)
  local items = {}
  for _, target in ipairs(daw.frontend.routing(track).targets) do
    if with_master or target.id ~= 0 then items[#items + 1] = target end
  end
  daw.pick({ title = title, items = items, format = function(t) return t.name end, on_choose = function(t) on_choose(t.id) end })
end

command("track.output", function(ctx)
  local track = need_track()
  if not track then return end
  local function set(target)
    local ok, err = pcall(daw.frontend.act.set_output, track.id, target)
    if not ok then return daw.notify((tostring(err):gsub("^[^:]*:%d+: ", ""):match("^[^\n]*")), "warn") end
    daw.notify(track.name .. " → " .. daw.frontend.routing(track.id).output)
  end
  local name = ctx.args[1]
  if not name or name == "" then return pick_target(track.id, "Output of " .. track.name, true, set) end
  local target = track_named(name)
  if not target then return daw.notify("no track `" .. name .. "`", "warn") end
  set(target)
end, { desc = "Play the track into another: `track.output Drum bus`, `track.output master`; alone, choose from a list", raw = true, complete = "tracks" })

command("send", function(ctx)
  local track = need_track()
  if not track then return end
  local level = tonumber(ctx.args[2]) or tonumber(ctx.args.level) or 0
  local function add(target)
    daw.frontend.act.add_send(track.id, target, level)
    if ctx.args.pre then
      local sends = track:get().sends
      daw.frontend.act.set_send(track.id, #sends, nil, true)
    end
    daw.notify(string.format("%s ↗ %s at %g dB%s", track.name, api.track_get(target).name, level, ctx.args.pre and ", ahead of the fader" or ""))
  end
  local name = ctx.args[1]
  if not name then return pick_target(track.id, "Send " .. track.name .. " to", false, add) end
  local target = track_named(tostring(name))
  if not target or target == 0 then return daw.notify("no track `" .. tostring(name) .. "` to send to", "warn") end
  add(target)
end, { desc = "Send the track's sound to another as well: `send Reverb -9`, `send Reverb -9 pre=1`; alone, choose from a list", complete = { "tracks" } })

command("send.remove", function(ctx)
  local track = need_track()
  if not track then return end
  local sends = track:get().sends
  local name = ctx.args[1]
  for index, send in ipairs(sends) do
    local to = api.track_get(send.target).name
    if not name or to:lower():find(tostring(name):lower(), 1, true) then
      daw.frontend.act.remove_send(track.id, index)
      return daw.notify(track.name .. " no longer sends to " .. to)
    end
  end
  daw.notify(#sends == 0 and "the track has no sends" or "no send to `" .. tostring(name) .. "`", "warn")
end, {
  desc = "Take a send away: `send.remove Reverb`; alone, the first",
  complete = function()
    local track, out = cursor.track(), {}
    for _, send in ipairs(track and track:get().sends or {}) do out[#out + 1] = api.track_get(send.target).name end
    return out
  end,
})

-- Groups of tracks (see daw.groups).

--- The tracks a group command is about: those of the selection, else the
--- cursor track.
local function chosen_tracks()
  local selection = keymap.selection()
  if selection and selection.view == "arrange" then
    local rows, out = daw.groups.rows(), {}
    for row = math.max(1, selection.r0), selection.r1 do
      if rows[row] then out[#out + 1] = rows[row] end
    end
    if #out > 0 then return out end
  end
  local id = cursor.track_id()
  return id and { id } or {}
end

command("track.group", function(ctx)
  local tracks = chosen_tracks()
  if #tracks == 0 then return daw.notify("no track to group", "warn") end
  -- Typed as a command alone, a raw command is given an empty text.
  local name = ctx.args[1] ~= "" and ctx.args[1] or nil
  local function make(text)
    if not text or text == "" then return end
    local group = daw.groups.make(tracks, text)
    if keymap.mode == "x" then keymap.set_mode("n") end
    cursor.set_track(group)
    daw.notify(string.format("group “%s” holds %d track%s; its fader and devices act on all of them", text, #tracks, #tracks == 1 and "" or "s"))
  end
  if name then return make(name) end
  daw.ui.input({ prompt = "Group name: ", text = "Group" }, make)
end, { desc = "Put the selected tracks (or the cursor track) in a new group: `track.group Strings`", raw = true })

command("track.ungroup", function()
  local track = need_track()
  if not track then return end
  if daw.groups.is_group(track.id) then
    daw.groups.dissolve(track.id)
    return daw.notify("the group is dissolved; its tracks stay")
  end
  for _, id in ipairs(chosen_tracks()) do daw.groups.remove(id) end
end, { desc = "Take the track out of its group; on a group, dissolve it" })

command("track.into", function(ctx)
  local tracks = chosen_tracks()
  local function into(group)
    for _, id in ipairs(tracks) do
      if id ~= group then
        local ok, err = pcall(daw.groups.add, id, group)
        if not ok then return daw.notify(tostring(err):gsub("^[^:]*:%d+: ", ""), "warn") end
      end
    end
  end
  local groups = {}
  for _, id in ipairs(api.track_list()) do
    if daw.groups.is_group(id) then groups[#groups + 1] = { id = id, name = api.track_get(id).name } end
  end
  local name = ctx.args[1]
  if name then
    for _, group in ipairs(groups) do
      if group.name:lower():find(name:lower(), 1, true) then return into(group.id) end
    end
    return daw.notify("no group `" .. name .. "`", "warn")
  end
  if #groups == 0 then return daw.notify("no groups yet: `:track.group` makes one", "warn") end
  daw.pick({ title = "Move into group", items = groups, format = function(g) return g.name end,
    on_choose = function(g) into(g.id) end })
end, {
  desc = "Move the track into a group: `track.into Strings`; alone, choose it from a list", raw = true,
  complete = function()
    local out = {}
    for _, id in ipairs(api.track_list()) do
      if daw.groups.is_group(id) then out[#out + 1] = api.track_get(id).name end
    end
    return out
  end,
})

command("track.fold", function(ctx)
  local track = need_track()
  if not track then return end
  local group = daw.groups.is_group(track.id) and track.id or daw.groups.of(track.id)
  if not group then return daw.notify("not in a group", "warn") end
  if ctx.args[1] == "all" or ctx.args[1] == "none" then
    for _, id in ipairs(api.track_list()) do daw.groups.fold(id, ctx.args[1] == "all") end
    return
  end
  daw.groups.fold(group)
end, { desc = "Fold the group away, or open it: `track.fold`; `track.fold all`, `track.fold none`" })

command("group.link", function()
  local track = need_track()
  if not track then return end
  local group = daw.groups.is_group(track.id) and track.id or daw.groups.of(track.id)
  if not group then return daw.notify("not in a group", "warn") end
  daw.groups.link(group)
  daw.notify(string.format("faders of “%s” %s", api.track_get(group).name,
    daw.groups.linked(group) and "are linked: moving one member's fader moves the others" or "are free again"))
end, { desc = "Link the faders of the group's members, or let them go: moving one moves the others by as many dB" })

-- VCAs: faders over tracks that do not route them (see daw.vca).

--- The VCA named, by part of its name, or nil.
local function vca_named(name)
  for _, id in ipairs(daw.vca.list()) do
    if api.track_get(id).name:lower():find(tostring(name):lower(), 1, true) then return id end
  end
end

local function vca_names()
  local out = {}
  for _, id in ipairs(daw.vca.list()) do out[#out + 1] = api.track_get(id).name end
  return out
end

--- Do something with a VCA: the one named, else one chosen from a list.
local function with_vca(name, title, from, act)
  if name == "" then name = nil end
  local vcas = {}
  for _, id in ipairs(from) do vcas[#vcas + 1] = { id = id, name = api.track_get(id).name } end
  if name then
    local id = vca_named(name)
    if id then return act(id) end
    return daw.notify("no VCA `" .. name .. "`", "warn")
  end
  if #vcas == 0 then return daw.notify("no VCAs here: `:vca.make` makes one", "warn") end
  daw.pick({ title = title, items = vcas, format = function(v) return v.name end, on_choose = function(v) act(v.id) end })
end

command("vca.make", function(ctx)
  local tracks = chosen_tracks()
  if #tracks == 0 then return daw.notify("no track to put under a VCA", "warn") end
  local function make(text)
    if not text or text == "" then return end
    local vca = daw.vca.make(tracks, text)
    if keymap.mode == "x" then keymap.set_mode("n") end
    cursor.set_track(vca)
    daw.notify(string.format("VCA “%s” moves %d track%s; their routing is as it was", text, #tracks, #tracks == 1 and "" or "s"))
  end
  if ctx.args[1] and ctx.args[1] ~= "" then return make(ctx.args[1]) end
  daw.ui.input({ prompt = "VCA name: ", text = "VCA" }, make)
end, { desc = "A new VCA over the selected tracks (or the cursor track): `vca.make Drums`", raw = true })

command("vca.assign", function(ctx)
  local tracks = chosen_tracks()
  if #tracks == 0 then return daw.notify("no track to put under a VCA", "warn") end
  with_vca(ctx.args[1], "Put under VCA", daw.vca.list(), function(vca)
    for _, id in ipairs(tracks) do
      local ok, err = pcall(daw.vca.assign, id, vca)
      if not ok then return daw.notify(tostring(err):gsub("^[^:]*:%d+: ", ""), "warn") end
    end
  end)
end, { desc = "Put the selected tracks under a VCA: `vca.assign Drums`; alone, choose it from a list", raw = true, complete = vca_names })

command("vca.release", function(ctx)
  local tracks = chosen_tracks()
  local name = ctx.args[1]
  if not name or name == "" then
    for _, id in ipairs(tracks) do daw.vca.unassign(id) end
    return
  end
  with_vca(name, "Take out of VCA", daw.vca.list(), function(vca)
    for _, id in ipairs(tracks) do daw.vca.unassign(id, vca) end
  end)
end, { desc = "Take the selected tracks out of a VCA (`vca.release Drums`), or out of all of them", raw = true, complete = vca_names })

command("vca.dissolve", function()
  local track = need_track()
  if not track then return end
  if not daw.vca.is_vca(track.id) then return daw.notify("not a VCA", "warn") end
  daw.vca.dissolve(track.id)
  daw.notify("the VCA is gone; its tracks stay, at their own faders")
end, { desc = "Take the VCA at the cursor away; its tracks stay" })

command("track.duplicate", function()
  local track = need_track()
  if track then cursor.set_track(track:duplicate()) end
end, { desc = "Duplicate the track" })

for _, flag in ipairs({ "mute", "solo", "armed", "monitor" }) do
  command("track." .. flag, function()
    local track = need_track()
    if track then track[flag] = not track[flag] end
  end, { desc = "Toggle " .. flag })
end

command("track.volume", function(ctx)
  local track = need_track()
  if not track then return end
  if ctx.args.by then
    track.volume = track.volume + ctx.args.by * (ctx.count or 1)
  elseif tonumber(ctx.args[1]) then
    track.volume = tonumber(ctx.args[1])
  end
end, { desc = "Set the volume in dB, or nudge it: `track.volume -6`, `track.volume by=1`" })
command("track.pan", function(ctx)
  local track = need_track()
  if not track then return end
  if ctx.args.by then
    track.pan = util.round(track.pan + ctx.args.by * (ctx.count or 1), 0.01)
  elseif tonumber(ctx.args[1]) then
    track.pan = tonumber(ctx.args[1])
  end
end, { desc = "Set the pan from -1 to 1, or nudge it: `track.pan by=0.1`" })
command("track.move", function(ctx)
  local track = need_track()
  if track then track:move(cursor.index() + (ctx.args.by or 1)) end
end, { desc = "Move the track down or up: `track.move by=-1`" })
-- What each choice of input means, and the lists, are `daw.audio`'s; here
-- they are a picker and commands.
local group_names = {
  audio = "audio", midi = "MIDI", channel = "MIDI channel", midi_out = "MIDI out", midi_out_channel = "out channel",
  midi_out_form = "out form",
}
local function input_picker(track)
  local items = {}
  local t = track:get()
  items[1] = { label = (t.monitor and "● " or "○ ") .. "Monitor: hear the input without arming", monitor = true }
  for _, choice in ipairs(daw.audio.choices(track)) do items[#items + 1] = choice end
  daw.pick({
    title = "Input of " .. t.name,
    items = items,
    format = function(item)
      if item.monitor then return item.label end
      return string.format("%s %-13s %s", item.checked and "●" or " ", group_names[item.group], item.label)
    end,
    on_choose = function(item)
      if item.monitor then
        track.monitor = not track.monitor
        return daw.notify(track.name .. (track.monitor and ": monitoring its input" or ": not monitoring"))
      end
      daw.audio.choose(track, item)
      if item.group:find("^midi_out") then
        return daw.notify(track.name .. " → " .. daw.routes.midi_out_text(track:get()))
      end
      daw.notify(track.name .. " ← " .. (daw.audio.label(track:get()) or "MIDI from every port"))
    end,
  })
end

command("track.input", function(ctx)
  local track = need_track()
  if not track then return end
  local spec = ctx.args[1]
  if spec == nil then return input_picker(track) end
  track.input = tostring(spec)
  daw.notify(track.name .. " ← " .. (daw.audio.label(track:get()) or "no audio input"))
end, {
  desc = "Choose the track's input from a list; or set it: `track.input 1/2`, `track.input 3`, `track.input none`",
  complete = function()
    local words = {}
    for _, choice in ipairs(daw.audio.choices(cursor.track_id() or daw.tracks()[1] or 0)) do
      if choice.group == "audio" then words[#words + 1] = choice.value.input end
    end
    if #words == 0 then words = { "none", "1", "2", "1/2" } end
    return words
  end,
})
command("track.midi", function(ctx)
  local track = need_track()
  if not track then return end
  local port = ctx.args[1] and table.concat(ctx.args, " ")
  if port == nil and ctx.args.ch == nil then return input_picker(track) end
  local value = {}
  if port then
    -- A part of a port's name is enough.
    local found = port ~= "all" and port
    for _, p in ipairs(daw.midi.inputs()) do
      if found and p.name:lower():find(found:lower(), 1, true) then found = p.name break end
    end
    value.midi_port = found or false
  end
  if ctx.args.ch then
    local ch = tonumber(ctx.args.ch)
    value.midi_channel = ch and ch >= 1 and ch <= 16 and math.floor(ch) or false
  end
  daw.audio.choose(track, value)
  daw.notify(track.name .. " ← " .. (daw.audio.label(track:get()) or "MIDI from every port"))
end, {
  desc = "Take MIDI from one port and channel, or all: `track.midi Keystation ch=1`, `track.midi all`",
  complete = function()
    local words = { "all" }
    for _, p in ipairs(daw.midi.inputs()) do words[#words + 1] = p.name end
    return words
  end,
})
command("track.color.pick", function()
  local track = need_track()
  if not track then return end
  local hues = require("daw.theme").hues
  local items = {}
  for i, name in ipairs(colour_names) do items[#items + 1] = { name = name, value = hues[i] } end
  items[#items + 1] = { name = "none", value = nil }
  daw.pick({
    title = "Colour of " .. track.name,
    items = items,
    format = function(item)
      local now = (track.color or "") == (item.value or "") and "● " or "  "
      return now .. string.format("%-8s %s", item.name, item.value or "the theme's, in turn")
    end,
    on_choose = function(item)
      track.color = item.value
      daw.notify(track.name .. " is " .. item.name)
    end,
  })
end, { desc = "Choose the track's colour from the theme's hues" })

command("track.output", function(ctx)
  local track = need_track()
  if not track then return end
  local target = ctx.args[1] and daw.track(ctx.args[1])
  track.output = target
  daw.notify(track.name .. " → " .. (target and target.name or "Master"))
end, { desc = "Route the track into another by name, or to the master: `track.output Drums`", complete = { "tracks" } })

-- Clips ----------------------------------------------------------------------

command("clip.add", function(ctx)
  local track = need_track()
  if not track then return end
  local length = tonumber(ctx.args.length) or daw.opt.clip_length
  local clip = track:add_clip({ start = cursor.beat, length = length * (ctx.count or 1), name = ctx.args.name })
  return clip
end, { desc = "Add an empty MIDI clip at the cursor" })
command("clip.import", function(ctx)
  local track = need_track()
  if not track then return end
  local file = ctx.args[1]
  if not file then return daw.notify("usage: clip.import <file.wav>", "warn") end
  if daw.midifile.is_midi_file(file) then
    -- A MIDI file is one clip of all its notes, on this track.
    return daw.midifile.import(tostring(file), { track = track }).clips[1]
  end
  return track:add_clip({ start = cursor.beat, file = tostring(file) })
end, { desc = "Add an audio or MIDI file at the cursor: `clip.import take.wav`, `clip.import riff.mid`", complete = { "audio_files" } })
-- Sound files this program reads.
local audio_extensions = { "wav", "wave", "aif", "aiff", "flac", "mp3", "ogg", "oga" }

--- Whether a path names a sound file, by its ending.
function daw.is_audio_file(path)
  local ext = (tostring(path):match("%.([^./]+)$") or ""):lower()
  for _, known in ipairs(audio_extensions) do
    if ext == known then return true end
  end
  return false
end

--- Bring a sound file into the project: on a new track named after the
--- file (or on `opts.track`), at the cursor (or `opts.start`). Returns the clip.
function daw.import_audio(path, opts)
  opts = opts or {}
  local name = (path:match("([^/]+)$") or path):gsub("%.[^.]+$", "")
  local made
  -- With `daw.opt.copy_imports`, the project plays a copy in its own `media` folder.
  if daw.opt.copy_imports then path = api.media_adopt(path) end
  local track = opts.track and daw.track(opts.track)
  if not track then
    track = daw.add_track({ name = name, index = cursor.index() and cursor.index() + 1 or nil })
    made = track
  end
  local ok, clip = pcall(track.add_clip, track, { start = opts.start or cursor.beat, file = path, name = name })
  if not ok then
    if made then made:remove() end
    error((tostring(clip):gsub("^[^:]*:%d+: ", ""):gsub("^runtime error: ", ""):match("^[^\n]*")), 0)
  end
  cursor.set_track(track)
  return clip
end

--- Open what a path names: a sound file as a new track, anything else as a
--- project, with plugins offline as `opts` says (see `daw.loading.open`).
function daw.open(path, opts)
  if daw.is_audio_file(path) then return daw.import_audio(path, { start = 0 }) end
  if daw.midifile.is_midi_file(path) then return daw.midifile.open(path) end
  return daw.loading.open(path, opts)
end

--- What a MIDI file brought in or opened came to, said.
local function midi_said(path, done)
  local name = path:match("([^/]+)$") or path
  local text = string.format("%s: %d notes on %d track%s", name, done.notes, #done.tracks, #done.tracks == 1 and "" or "s")
  if done.skipped then text = text .. "; left out: " .. done.skipped end
  return text
end

command("import", function(ctx)
  local tempo = ctx.args.tempo
  local function bring(path)
    if daw.midifile.is_midi_file(path) then
      local ok, done = pcall(daw.midifile.import, path, { tempo = tempo == true or tempo == "yes" or tempo == "on" })
      if not ok then return daw.notify("could not import " .. path .. ": " .. tostring(done):gsub("^[^:]*:%d+: ", ""), "error") end
      return daw.notify("imported " .. midi_said(path, done))
    end
    local ok, clip = pcall(daw.import_audio, path, { track = ctx.args.track })
    if not ok then return daw.notify("could not import " .. path .. ": " .. tostring(clip), "error") end
    daw.notify(string.format("imported %s: %.1f beats on track “%s”", path:match("([^/]+)$") or path, clip.length, clip:track().name))
  end
  local path = ctx.args[1]
  -- `tempo=yes` at the end of the line, the path being the rest.
  if path then
    local rest, word = path:match("^(.-)%s+tempo=(%S+)%s*$")
    if rest then path, tempo = rest, word end
  end
  if path and path ~= "" then return bring((path:gsub("^~", os.getenv("HOME") or "~"))) end
  local endings = {}
  for _, list in ipairs({ audio_extensions, daw.midifile.extensions }) do
    for _, ext in ipairs(list) do endings[#endings + 1] = ext end
  end
  daw.pick.file({ title = "Import", extensions = endings, on_choose = bring })
end, { desc = "Bring a sound file in on a new track, or a MIDI file's tracks at the cursor: `import take.mp3`, `import song.mid`, `import song.mid tempo=yes` (its tempo map too); alone, choose it from a list", raw = true, complete = "audio_files" })

command("open", function(ctx)
  local function go(path)
    local ok, err = pcall(daw.open, path)
    if not ok then return daw.notify("could not open " .. path .. ": " .. tostring(err):gsub("^[^:]*:%d+: ", ""), "error") end
    if daw.midifile.is_midi_file(path) then return daw.notify("opened " .. midi_said(path, err) .. " (`:w` asks where to save it)") end
    daw.notify("opened " .. path)
  end
  local path = ctx.args[1]
  if path and path ~= "" then return go((path:gsub("^~", os.getenv("HOME") or "~"))) end
  daw.pick.file({ title = "Open", on_choose = go })
end, { desc = "Open a project, a MIDI file as a new project, or a sound file on a new track: `open song.json`, `open song.mid`, `open take.wav`; alone, choose it from a list", raw = true, complete = "files" })

command("export", function(ctx)
  local path, what = ctx.args[1] and tostring(ctx.args[1]), ctx.args[2] and tostring(ctx.args[2])
  if not path or not daw.midifile.is_midi_file(path) then
    return daw.notify("usage: export <song.mid> [clip|selection]; `:render` makes sound files", "warn")
  end
  path = path:gsub("^~", os.getenv("HOME") or "~")
  local opts = {}
  if what == "clip" then
    local clip = cursor.clip()
    if not clip or clip.kind ~= "midi" then return daw.notify("no MIDI clip at the cursor", "warn") end
    opts.clips = { clip.id }
  elseif what == "selection" then
    local region = daw.keymap.selection()
    if not region then return daw.notify("nothing is selected", "warn") end
    opts.tracks = edit.arrange.tracks(region)
  elseif what then
    return daw.notify("export what: `clip`, `selection`, or nothing for the whole project", "warn")
  end
  local notes = daw.midifile.export(path, opts)
  daw.notify(string.format("exported %d notes to %s", notes, path))
end, { desc = "Write a MIDI file of the project, of the clip at the cursor, or of the selection's tracks: `export song.mid`, `export riff.mid clip`, `export part.mid selection`", complete = { "files", function() return { "clip", "selection" } end } })

--- Text typed for an option, as the value it stands for.
local function option_value(text)
  if text == "true" or text == "on" then return true end
  if text == "false" or text == "off" then return false end
  return tonumber(text) or text
end

command("set", function(ctx)
  local name, value = ctx.args[1], ctx.args[2]
  for key, v in pairs(ctx.args) do
    if type(key) == "string" then name, value = key, v end
  end
  if not name then return daw.pick("options") end
  name = tostring(name)
  -- `set follow!` flips a true/false option, as in Vim.
  local flip = name:match("^(.-)!$")
  if flip then
    name = flip
    if type(daw.opt[name]) ~= "boolean" then return daw.notify(name .. " is not a true/false option", "warn") end
    value = not daw.opt[name]
  end
  if value == nil then return daw.notify(name .. " = " .. tostring(daw.opt[name])) end
  daw.opt[name] = type(value) == "string" and option_value(value) or value
  daw.notify(name .. " = " .. tostring(daw.opt[name]))
end, {
  desc = "Show or set an option: `set zoom 4`, `set zoom=4`, `set follow!` flips it, `set` alone lists them",
  complete = { "options" },
})

command("clip.remove", function()
  local clip = need_clip()
  if clip then clip:remove() end
end, { desc = "Remove the clip under the cursor" })
command("clip.duplicate", function()
  local clip = need_clip()
  if not clip then return end
  local copy = clip:duplicate()
  cursor.set_beat(copy.start)
end, { desc = "Repeat the clip right after itself" })
command("clip.mute", function()
  local clip = need_clip()
  if clip then clip.muted = not clip.muted end
end, { desc = "Mute or unmute the clip" })
command("clip.move", function(ctx)
  local clip = need_clip()
  if not clip then return end
  local by = (ctx.args.by or 1) * (ctx.count or 1) * daw.opt.grid
  clip.start = math.max(0, clip.start + by)
  cursor.set_beat(math.max(0, cursor.beat + by))
end, { desc = "Move the clip by grid steps: `clip.move by=-1`" })
command("clip.resize", function(ctx)
  local clip = need_clip()
  if not clip then return end
  local length = clip.length + (ctx.args.by or 1) * (ctx.count or 1) * daw.opt.grid
  if length > 0 then clip.length = length end
end, { desc = "Lengthen or shorten the clip by grid steps: `clip.resize by=-1`" })
command("clip.split", function()
  -- Clips chosen with the pointer are split together.
  if daw.frontend.act.split_clips() then return end
  local clip = need_clip()
  if not clip then return end
  local c = clip:get()
  local at = cursor.beat - c.start
  if at <= 0 or at >= c.length then return end
  local right = { start = cursor.beat, length = c.length - at, name = c.name, kind = c.kind }
  -- The right half plays as the clip does: stretched, shifted, looped.
  local moved = daw.stretch.carry(c, right, at)
  if c.kind == "midi" and c.loop then
    -- Each half of a looped clip repeats the whole loop, from where it begins.
    right.notes = clip:notes()
    for _, note in ipairs(right.notes) do note.start = note.start + moved.shift end
    if c.control_count > 0 then
      right.controls = clip:controls()
      for _, control in ipairs(right.controls) do control.start = control.start + moved.shift end
    end
  elseif c.kind == "midi" then
    local keep, move = {}, {}
    for _, note in ipairs(clip:notes()) do
      if note.start < at then
        note.length = math.min(note.length, at - note.start)
        keep[#keep + 1] = note
      else
        note.start = note.start - at
        move[#move + 1] = note
      end
    end
    clip:set_notes(keep)
    right.notes = move
    -- Controller moves go to the half they happen in.
    if c.control_count > 0 then
      local stay, go = {}, {}
      for _, control in ipairs(clip:controls()) do
        if control.start < at then
          stay[#stay + 1] = control
        else
          control.start = control.start - at
          go[#go + 1] = control
        end
      end
      clip:set_controls(stay)
      right.controls = go
    end
  else
    right.file, right.gain = c.file, c.gain
    right.offset = moved.offset
    -- The fade out goes with the end, which the right half now has.
    right.fade_out = math.min(c.fade_out, right.length)
    clip.fade_out = 0
    clip.fade_in = math.min(c.fade_in, at)
  end
  -- Both halves keep every take, lined up.
  local takes = daw.takes.piece(c, cursor.beat, c.start + c.length, c.loop and moved.shift)
  if takes then right.meta = { takes = takes } end
  clip.length = at
  clip:track():add_clip(right)
end, { desc = "Split the clip at the cursor" })
command("clip.join", function()
  local clip = need_clip()
  if not clip then return end
  local finish, next_clip = clip.start + clip.length, nil
  for _, other in ipairs(clip:track():clips()) do
    if other.start >= finish - 1e-9 and (not next_clip or other.start < next_clip.start) then next_clip = other end
  end
  if not next_clip then return daw.notify("no clip after this one to join it with", "warn") end
  edit.arrange.join(clip:track().id, clip.start, next_clip.start + next_clip.length)
end, { desc = "Join the clip with the next one on the track" })
command("clip.rename", function(ctx)
  local clip = need_clip()
  if not clip then return end
  if ctx.args[1] then
    clip.name = tostring(ctx.args[1])
  else
    daw.ui.input({ prompt = "Clip name: ", text = clip.name }, function(name)
      if name ~= "" then clip.name = name end
    end)
  end
end, { desc = "Rename the clip" })
command("clip.transpose", function(ctx)
  local clip, row = need_clip(), cursor.index()
  if not clip then return end
  edit.arrange.transpose(
    { kind = "char", r0 = row, r1 = row, c0 = clip.start, c1 = clip.start + clip.length },
    (ctx.args.by or tonumber(ctx.args[1]) or 1) * (ctx.count or 1))
end, { desc = "Move the clip's notes by semitones: `clip.transpose 12`, `clip.transpose by=-1`" })
command("clip.insert", function()
  local track = need_track()
  if not track then return end
  local clip = cursor.clip()
  if clip and clip.kind ~= "midi" then return daw.notify("notes cannot be entered in an audio clip", "warn") end
  clip = clip or track:add_clip({ start = cursor.beat, length = daw.opt.clip_length })
  local at = cursor.beat - clip.start
  roll:edit(clip)
  roll:set(nil, math.floor(at / daw.opt.note_grid + 1e-9) * daw.opt.note_grid)
  keymap.set_mode("i")
end, { desc = "Enter notes at the cursor from the keyboard, in a new clip if there is none" })
command("clip.fade", function(ctx)
  local clip = need_clip()
  if not clip then return end
  if clip.kind ~= "audio" then return daw.notify("only audio clips fade", "warn") end
  local fade_in, fade_out = tonumber(ctx.args["in"]), tonumber(ctx.args.out)
  if ctx.args[1] then fade_in, fade_out = tonumber(ctx.args[1]), tonumber(ctx.args[2] or ctx.args[1]) end
  if not fade_in and not fade_out then
    -- Alone, it asks: one number for both ends, or two.
    return daw.ui.input({
      prompt = string.format("Fade %s in and out, in beats (now %g %g): ", clip.name, clip.fade_in, clip.fade_out),
      label = "Fade the clip",
    }, function(text)
      local a, b = text:match("^%s*([%d%.]+)%s*([%d%.]*)%s*$")
      if not a then return daw.notify("type one length for both ends, or two: `1 2`", "warn") end
      daw.commands.run("clip.fade", { tonumber(a), tonumber(b) or tonumber(a) })
    end)
  end
  if fade_in then clip.fade_in = math.min(math.max(0, fade_in), clip.length) end
  if fade_out then clip.fade_out = math.min(math.max(0, fade_out), clip.length) end
  daw.notify(string.format("%s fades in over %g beats and out over %g", clip.name, clip.fade_in, clip.fade_out))
end, { desc = "Fade an audio clip in and out, in beats: `clip.fade in=1 out=2`, `clip.fade 0.5`, `clip.fade 0`; alone, it asks" })
command("clip.crossfade", function(ctx)
  local clip = need_clip()
  if not clip then return end
  local finish, next_clip = clip.start + clip.length, nil
  for _, other in ipairs(clip:track():clips()) do
    if other.id ~= clip.id and other.start > clip.start and (not next_clip or other.start < next_clip.start) then
      next_clip = other
    end
  end
  if not next_clip or clip.kind ~= "audio" or next_clip.kind ~= "audio" then
    return daw.notify("a crossfade needs an audio clip here and another after it", "warn")
  end
  -- Let this clip run on under the start of the next for as long as its
  -- file has sound, and fade the two across each other there.
  local beats = tonumber(ctx.args[1]) or daw.opt.grid
  local overlap = math.min(beats, next_clip.length)
  local file_end = clip.start + api.clip_source_length(clip.id)
  local reach = math.min(next_clip.start + overlap, file_end)
  if reach > finish then clip.length = reach - clip.start end
  overlap = clip.start + clip.length - next_clip.start
  if overlap <= 0 then return daw.notify("the clips do not meet: move them together first", "warn") end
  clip.fade_out, next_clip.fade_in = overlap, overlap
end, { desc = "Fade this audio clip into the next one over some beats: `clip.crossfade 1`" })
-- Stretching, pitch shifting and looping: `daw.stretch`.
local function stretch_run(f, ...)
  local ok, err = pcall(f, ...)
  if not ok then daw.notify((tostring(err):gsub("^[^:]*:%d+: ", ""):gsub("^runtime error: ", "")), "warn") end
  return ok
end
command("clip.stretch", function(ctx)
  local clip = need_clip()
  if not clip then return end
  if clip.kind ~= "audio" then return daw.notify("only audio clips are stretched", "warn") end
  local word, to = ctx.args[1], tonumber(ctx.args.to)
  local ok
  if to then
    ok = stretch_run(daw.stretch.to, clip.id, to)
  elseif word == "selection" or word == "loop" then
    local from, finish = require("daw.render").ranges[word]()
    if not from then return daw.notify(finish, "warn") end
    ok = stretch_run(daw.stretch.fit, clip.id, from, finish)
  elseif word == "reset" then
    ok = stretch_run(daw.stretch.reset, clip.id)
  elseif tonumber(word) then
    ok = stretch_run(daw.stretch.set, clip.id, tonumber(word))
  else
    return daw.ui.input({ prompt = string.format("Stretch %s to (now ×%g): ", clip.name, clip.stretch), label = "Stretch the clip" },
      function(text) daw.commands.run("clip.stretch", { tonumber(text) or text }) end)
  end
  if ok then daw.notify(string.format("%s plays ×%g as long as its file", clip.name, clip.stretch)) end
end, { desc = "Stretch an audio clip, keeping its pitch: `clip.stretch 1.5` (times as long), `clip.stretch to=8` (beats), `clip.stretch selection`, `clip.stretch loop`, `clip.stretch reset`" })
command("clip.pitch", function(ctx)
  local clip = need_clip()
  if not clip then return end
  if clip.kind ~= "audio" then return daw.notify("only audio clips are shifted: transpose a MIDI clip's notes", "warn") end
  local semitones = tonumber(ctx.args[1])
  if not semitones then
    return daw.ui.input({ prompt = string.format("Shift %s by semitones (now %+g): ", clip.name, clip.pitch), label = "Shift the pitch" },
      function(text) if tonumber(text) then daw.commands.run("clip.pitch", { tonumber(text) }) end end)
  end
  if stretch_run(daw.stretch.pitch, clip.id, semitones) then
    daw.notify(string.format("%s plays %+g semitones from its file", clip.name, semitones))
  end
end, { desc = "Shift an audio clip's pitch by semitones, keeping its length: `clip.pitch 3`, `clip.pitch -0.5`, `clip.pitch 0`" })
command("clip.tempo", function(ctx)
  local clip = need_clip()
  if not clip then return end
  local word = ctx.args[1]
  if word == "off" then
    stretch_run(daw.stretch.follow, clip.id, false)
    return daw.notify(clip.name .. " keeps its length in seconds")
  end
  if stretch_run(daw.stretch.follow, clip.id, tonumber(word)) then
    daw.notify(string.format("%s follows the tempo; its sound is at %g BPM", clip.name, clip.source_tempo))
  end
end, { desc = "Make an audio clip keep its beats when the tempo changes, stretched to fit: `clip.tempo 120` (its sound's tempo), `clip.tempo` (as it plays now), `clip.tempo off`" })
command("clip.stretch_mode", function(ctx)
  local clip = need_clip()
  if not clip then return end
  local mode = ctx.args[1]
  if mode then stretch_run(function() clip.stretch_mode = mode end) end
  daw.notify(clip.name .. " is stretched as " .. tostring(clip.stretch_mode))
end, { desc = "How an audio clip is stretched: `clip.stretch_mode tonal` (held notes), `percussive` (drums, speech), `auto`", complete = { "auto", "tonal", "percussive" } })
command("clip.warp", function(ctx)
  local clip = need_clip()
  if not clip then return end
  if clip.kind ~= "audio" then return daw.notify("only audio clips have warp markers", "warn") end
  local word, beat = ctx.args[1] or "add", cursor.beat
  local index = tonumber(ctx.args[2])
  local function say(i)
    local m = api.clip_get(clip.id).warp[i]
    daw.notify(string.format("warp marker %d: %.3f s into the file, at %s", i, m.source, daw.time.format(m.beat)))
  end
  local i
  if word == "add" then
    if stretch_run(function() i = daw.stretch.warp_add(clip.id, index or beat) end) then say(i) end
  elseif word == "remove" or word == "move" then
    index = index or daw.stretch.warp_near(clip, beat)
    if not index then return daw.notify(clip.name .. " has no warp markers", "warn") end
    if word == "remove" then
      if stretch_run(daw.stretch.warp_remove, clip.id, index) then daw.notify("warp marker " .. index .. " taken off") end
    elseif stretch_run(function() i = daw.stretch.warp_move(clip.id, index, tonumber(ctx.args[3]) or beat) end) then
      say(i)
    end
  elseif word == "snap" then
    if stretch_run(daw.stretch.warp_snap, clip.id) then daw.notify(clip.name .. "'s warp markers are on the grid") end
  elseif word == "clear" then
    if stretch_run(function() clip.warp = {} end) then daw.notify(clip.name .. " has no warp markers now") end
  else
    daw.notify("clip.warp add, remove, move, snap or clear", "warn")
  end
end, { desc = "Warp markers: `clip.warp` pins the sound at the cursor; `clip.warp move` pulls the nearest marker to the cursor (`move 2`: marker 2, `move 2 8.5`: to beat 8.5); `clip.warp remove`, `snap` (all onto the grid), `clear`",
  complete = { "add", "remove", "move", "snap", "clear" } })
command("clip.formants", function(ctx)
  local clip = need_clip()
  if not clip then return end
  if clip.kind ~= "audio" then return daw.notify("only audio clips are shifted", "warn") end
  local word = ctx.args[1]
  local on = word == "on" or (word ~= "off" and not clip.formants)
  if stretch_run(function() clip.formants = on end) then
    daw.notify(clip.name .. (on and " keeps its formants when shifted" or " shifts its formants with its pitch"))
  end
end, { desc = "Keep an audio clip's formants when its pitch is shifted, so that a voice keeps its size: `clip.formants on`, `off`, or turn it over", complete = { "on", "off" } })
command("clip.loop", function(ctx)
  local clip = need_clip()
  if not clip then return end
  local word = ctx.args[1]
  if word == "off" or (word == nil and clip.loop) then
    stretch_run(daw.stretch.loop, clip.id, false)
    return daw.notify(clip.name .. " no longer loops")
  end
  if stretch_run(daw.stretch.loop, clip.id, true, tonumber(word)) then
    daw.notify(string.format("%s loops every %g beats: drag its end out to repeat it", clip.name, clip.loop_length))
  end
end, { desc = "Loop a clip: dragged longer it repeats what it plays. `clip.loop` turns it on or off, `clip.loop 4` repeats 4 beats, `clip.loop off`" })
command("clip.edit", function()
  local clip = need_clip()
  if not clip then return end
  -- An extension with an editor of its own for this clip opens it, as it
  -- does for a double click in a graphical frontend.
  for _, opener in ipairs(daw.frontend.openers) do
    if opener(clip) then return end
  end
  daw.ui.views.pianoroll:edit(clip)
end, { desc = "Open the clip in its editor: the piano roll, or one an extension has for it" })

-- Devices --------------------------------------------------------------------

--- Device kinds whose kind or name contains `text`, built-in ones first.
local function device_kinds(text)
  local wanted, out = text:lower(), {}
  for _, info in ipairs(daw.device_types()) do
    if info.kind:lower():find(wanted, 1, true) or info.name:lower():find(wanted, 1, true) then
      out[#out + 1] = info
    end
  end
  table.sort(out, function(a, b)
    if (a.format == "builtin") ~= (b.format == "builtin") then return a.format == "builtin" end
    return a.kind < b.kind
  end)
  for i, info in ipairs(out) do out[i] = info.kind end
  return out
end

command("device.add", function(ctx)
  local track = need_track()
  if not track then return end
  local function add(text)
    if text == "" then return end
    -- An exact kind, or else the first device with `text` in its kind or name.
    local matches = device_kinds(text)
    local kind = matches[1]
    for _, match in ipairs(matches) do
      if match == text then kind = match end
    end
    if not kind then return daw.notify("no device matches `" .. text .. "`", "warn") end
    daw.fx.add(track, kind)
  end
  if ctx.args[1] then return add(table.concat(ctx.args, " ")) end
  daw.notify(#daw.device_types() .. " devices. Type part of a name and press Tab; `:devices` lists them all.")
  daw.ui.input({ prompt = "Add device: ", complete = device_kinds, history = "device" }, add)
end, { desc = "Add a device to the track: `device.add delay`, `device.add dragonfly hall`", complete = { "devices" } })
command("midi.inputs", function()
  local lines = {}
  for _, port in ipairs(daw.midi.inputs()) do
    lines[#lines + 1] = { text = string.format("%-8s %s %s", port.id, port.open and "open  " or "closed", port.name), style = port.open and "Normal" or "Dim" }
  end
  if #lines == 0 then lines[1] = "No MIDI input ports (they are only opened with an audio device)." end
  daw.ui.page("MIDI inputs", lines)
end, { desc = "List MIDI input ports" })
command("midi.select", function(ctx)
  local which = {}
  for _, arg in ipairs(ctx.args) do which[#which + 1] = tostring(arg) end
  if #which == 0 or which[1] == "all" then which = nil end
  daw.midi.select(which)
  daw.notify(which and "MIDI input from " .. table.concat(which, ", ") or "MIDI input from every port")
end, { desc = "Open only some MIDI ports by id or name, or all: `midi.select Keystation`, `midi.select all`" })
command("devices", function()
  local lines = {}
  for _, kind in ipairs(device_kinds("")) do lines[#lines + 1] = kind end
  daw.ui.page("Devices", lines)
end, { desc = "List every device that can be added" })
command("device.remove", function()
  local device = daw.ui.views.devices:selected()
  if device then device:remove() end
end, { desc = "Remove the device selected in the device panel" })
command("device.restart", function()
  -- The device selected in the panel if it has stopped, else every device
  -- of the track that has.
  local chosen = daw.ui.focused == "devices" and daw.ui.views.devices:selected() or nil
  local track = need_track()
  local started, failed = 0, nil
  for _, device in ipairs(chosen and { chosen } or track and track:devices() or {}) do
    local d = device:get()
    if d.stopped or d.missing or chosen then
      local ok, err = pcall(device.restart, device)
      if ok then started = started + 1 else failed = tostring(err):match("^[^\n]*") end
    end
  end
  if failed then return daw.notify(failed, "error") end
  daw.notify(started == 0 and "no device here has stopped" or started == 1 and "the device is running again"
    or started .. " devices are running again")
end, { desc = "Start a plugin again that stopped working, with the state the project last had of it" })
command("device.bypass", function()
  local device = daw.ui.views.devices:selected()
  if device then device.bypass = not device.bypass end
end, { desc = "Bypass the device selected in the device panel" })
command("device.editor", function()
  -- The device selected in the panel, else the track's first one with a window.
  local device = daw.ui.focused == "devices" and daw.ui.views.devices:selected() or nil
  if not (device and device.editor) then
    device = nil
    local track = need_track()
    for _, candidate in ipairs(track and track:devices() or {}) do
      if candidate.editor then
        device = candidate
        break
      end
    end
  end
  if not device then return daw.notify("no device with an editor window here", "warn") end
  api.device_editor(device.id)
end, { desc = "Show or hide the plugin's own window" })
command("device.set", function(ctx)
  local track = need_track()
  local device = track and track:device(ctx.args[1])
  if not device then return daw.notify("usage: device.set <kind> <param>=<value> ...", "warn") end
  for key, value in pairs(ctx.args) do
    if type(key) == "string" then device:set(key, value) end
  end
end, {
  desc = "Set parameters: `device.set synth cutoff=800 wave=2`",
  complete = function(_, info)
    if info.index == 1 then return daw.commands.completers.track_devices() end
    local track = cursor.track()
    local device = track and track:device(info.words[1])
    local out = {}
    for _, p in ipairs(device and device:get().param_info or {}) do
      out[#out + 1] = { text = p.key .. "=", desc = p.name }
    end
    return out
  end,
})

-- Automation -----------------------------------------------------------------

--- What a lane command acts on: the cursor track's volume, or what
--- `target=pan` or `target=<param> device=<kind>` names. Returns the track or
--- device that owns the lane, and the target.
local function lane_owner(ctx)
  local track = need_track()
  if not track then return end
  local target = tostring(ctx.args.target or "volume")
  if not ctx.args.device then return track, target end
  local device = track:device(ctx.args.device)
  if not device then daw.notify("no device `" .. tostring(ctx.args.device) .. "` on the track", "warn") end
  return device, target
end

local function need_lane(ctx)
  -- On a lane's row, that lane.
  if not ctx.args.target and not ctx.args.device and cursor.lane_id() then return daw.lane(cursor.lane_id()) end
  local owner, target = lane_owner(ctx)
  local lane = owner and owner:lane(target)
  if owner and not lane then daw.notify("no " .. target .. " automation on the track", "warn") end
  return lane
end

command("lane.add", function(ctx)
  local owner, target = lane_owner(ctx)
  if not owner then return end
  local beat = cursor.beat
  local function add(value) owner:automate(target):add(beat, value) end
  local current = owner:value_at(target, beat)
  if tonumber(ctx.args[1]) then return add(tonumber(ctx.args[1])) end
  if ctx.args.by then return add(current + ctx.args.by * (ctx.count or 1)) end
  daw.ui.input({ prompt = target .. " at " .. daw.time.format(beat) .. ": ", text = string.format("%g", current) }, function(text)
    if tonumber(text) then add(tonumber(text)) end
  end)
end, { desc = "Add an automation point at the cursor: `lane.add -6`, `lane.add by=1 target=pan`, `lane.add 800 target=cutoff device=synth`" })
command("lane.clear", function(ctx)
  local lane = need_lane(ctx)
  if lane then lane:clear() end
end, { desc = "Remove every point of the track's volume automation, or of `target=...`" })
command("lane.toggle", function(ctx)
  local lane = need_lane(ctx)
  if not lane then return end
  lane.enabled = not lane.enabled
  daw.notify(lane.target .. " automation " .. (lane.enabled and "on" or "off"))
end, { desc = "Turn the track's volume automation, or `target=...`, off or on" })
command("lane.remove", function(ctx)
  local lane = need_lane(ctx)
  if lane then lane:remove() end
end, { desc = "Remove the track's volume automation, or `target=...`" })

-- Views ----------------------------------------------------------------------

command("view.next", function() daw.ui.focus_next(1) end, { desc = "Focus the next view" })
command("view.prev", function() daw.ui.focus_next(-1) end, { desc = "Focus the previous view" })
command("view.toggle", function(ctx) daw.ui.toggle(tostring(ctx.args[1])) end, { desc = "Show or hide a view: `view.toggle mixer`", complete = { "views" } })
command("view.focus", function(ctx) daw.ui.focus(tostring(ctx.args[1])) end, { desc = "Focus a view by name", complete = { "views" } })
command("view.close", function()
  if daw.ui.float then return daw.ui.close() end
  if daw.ui.focused ~= "arrange" then daw.ui.hide(daw.ui.focused) end
  daw.ui.focus("arrange")
end, { desc = "Close the focused panel" })
command("view.window", function(ctx)
  local name = ctx.args[1] and tostring(ctx.args[1]) or (daw.ui.float and daw.ui.float.name) or daw.ui.focused
  if not daw.ui.views[name] then return daw.notify("no view `" .. name .. "`", "warn") end
  daw.canvas.open_view(name)
end, { desc = "Open a view in a window of its own, in the graphical frontend: `view.window undotree`; the focused one without a name", complete = { "views" } })
command("view.only", function()
  for _, rect in ipairs(daw.ui.arrange()) do
    local view = daw.ui.views[rect.name]
    if rect.name ~= "arrange" and view and view.focusable ~= false then daw.ui.hide(rect.name) end
  end
  daw.ui.focus("arrange")
end, { desc = "Close every panel but the arrange view" })
command("zoom", function(ctx)
  local name = daw.ui.focused == "pianoroll" and "note_zoom" or "zoom"
  if ctx.args.by then
    daw.opt[name] = util.clamp(daw.opt[name] * ctx.args.by, 0.125, 64)
  elseif tonumber(ctx.args[1]) then
    daw.opt[name] = tonumber(ctx.args[1])
  end
end, { desc = "Set columns per beat, or scale them: `zoom 4`, `zoom by=2`" })
command("grid", function(ctx)
  local name = daw.ui.focused == "pianoroll" and "note_grid" or "grid"
  if ctx.args.by then
    daw.opt[name] = util.clamp(daw.opt[name] * ctx.args.by, 1 / 32, 16)
  elseif tonumber(ctx.args[1]) then
    daw.opt[name] = tonumber(ctx.args[1])
  end
  daw.notify(string.format("grid %g beats", daw.opt[name]))
end, { desc = "Set the grid in beats, or scale it: `grid 0.5`, `grid by=2`" })

-- Project and program --------------------------------------------------------

--- What made the state the project is in now, as the undo tree names it.
local function step_name()
  local ok, tree = pcall(api.undo_tree)
  if not ok then return nil end
  local current = api.undo_current()
  for _, state in ipairs(tree.states or {}) do
    if state.id == current then return state.label or state.keys end
  end
end

command("undo", function(ctx)
  local undone = {}
  for _ = 1, ctx.count or 1 do
    local name = step_name()
    if not daw.undo() then
      if #undone == 0 then return daw.notify("nothing to undo") end
      break
    end
    undone[#undone + 1] = name or "a change"
  end
  daw.notify("undid " .. table.concat(undone, ", "))
end, { desc = "Undo, saying what was undone" })
command("redo", function(ctx)
  local redone = {}
  for _ = 1, ctx.count or 1 do
    if not daw.redo() then
      if #redone == 0 then return daw.notify("nothing to redo") end
      break
    end
    redone[#redone + 1] = step_name() or "a change"
  end
  daw.notify("redid " .. table.concat(redone, ", "))
end, { desc = "Redo, saying what was redone" })
command("write", function(ctx)
  local path = ctx.args[1] and tostring(ctx.args[1]) or nil
  -- A project that has no file yet is asked where it goes, when there is
  -- somebody to ask.
  if not path and not api.project_get().path and daw.fx.interactive() then return daw.frontend.save_as() end
  if path and daw.midifile.is_midi_file(path) then
    return daw.notify("a project is not saved as a MIDI file: `:export " .. path .. "` writes one", "warn")
  end
  daw.notify("saved " .. daw.project.save(path))
end, { desc = "Save the project: `write song.json`", complete = { "projects" } })
command("saveas", function() daw.frontend.save_as() end, { desc = "Save the project under a name chosen from a list of directories" })
command("edit", function(ctx)
  if not ctx.args[1] then return daw.notify("usage: edit <project.json>", "warn") end
  local how = ctx.args[2] and tostring(ctx.args[2])
  if how and how ~= "offline" and how ~= "online" then return daw.notify("usage: edit <project.json> [offline|online]", "warn") end
  local path = tostring(ctx.args[1])
  if daw.midifile.is_midi_file(path) or daw.is_audio_file(path) then return daw.commands.run("open", { path }) end
  daw.open(tostring(ctx.args[1]), { plugins_offline = how == "offline", all_online = how == "online" })
end, { desc = "Open a project: `edit song.json`; `edit song.json offline` with every plugin offline, `online` with none held back; a MIDI or sound file as `open` does", complete = { "openable", function() return { "offline", "online" } end } })
command("new", function() daw.project.new() end, { desc = "Start an empty project" })
-- `:render`, `:render.cancel` and `:stems` are in daw/render.lua.
command("track.bounce", function()
  local track = need_track()
  if not track then return end
  -- What the track sounds like, devices and all, as one audio clip on a new
  -- track below it; the original is muted, not removed.
  local bounced = daw.bounce(track)
  if not bounced then return daw.notify("nothing on the track to bounce", "warn") end
  cursor.set_track(bounced)
end, { desc = "Render the track with its devices to audio on a new track, and mute the original" })
command("lane.write", function(ctx)
  local on = ctx.args[1]
  if on == nil then on = not transport.write else on = on == true or on == "on" end
  transport.write = on
  daw.notify(on and "moving a fader or a parameter while playing now writes automation" or "automation writing is off")
end, { desc = "Write automation by moving things while the song plays, on every track: `lane.write`, `lane.write off`" })
-- How a track treats its automation: see `daw.lanes.modes`.
command("automation", function(ctx)
  local track = need_track()
  if not track then return end
  local mode = ctx.args[1] and tostring(ctx.args[1]):lower()
  if not mode then
    -- Without a word: the next mode in turn.
    local modes = daw.lanes.modes
    for i, name in ipairs(modes) do
      if name == track.automation then mode = modes[i % #modes + 1] end
    end
  end
  if not daw.lanes.mode_text[mode] then
    return daw.notify("automation: " .. table.concat(daw.lanes.modes, ", "), "warn")
  end
  local ids = ctx.args[2] == "all" and api.track_list() or { track.id }
  for _, id in ipairs(ids) do api.track_set(id, "automation", mode) end
  daw.notify(string.format("%s: automation %s (%s)", ctx.args[2] == "all" and "every track" or track.name, mode, daw.lanes.mode_text[mode]))
end, {
  desc = "How the track treats automation: `automation touch`, `automation read all`; read, touch, latch, write or off",
  complete = function() return daw.lanes.modes end,
})
command("engine", function(ctx)
  if ctx.args.threads then daw.opt.threads = tonumber(ctx.args.threads) end
  if ctx.args[1] or ctx.args.rate or ctx.args.buffer then
    api.engine_restart({ backend = ctx.args[1] and tostring(ctx.args[1]), sample_rate = ctx.args.rate, buffer_size = ctx.args.buffer })
  end
  local e = api.engine_get()
  daw.notify(string.format("%s: %s, %d Hz, %d %s, %d xruns", e.backend, e.device, e.sample_rate, e.threads,
    e.threads == 1 and "thread" or "threads", e.xruns))
end, { desc = "Show the audio engine, restart it, or set its threads: `engine pipewire rate=48000 buffer=256`, `engine threads=4`" })
command("engine.status", function()
  local e = api.engine_get()
  daw.notify(string.format("%s %s: cpu %d%%, %d xruns, %d late plugin blocks, %d MIDI events dropped, %d recorded frames lost, %d devices stopped",
    e.backend, e.device, math.floor((e.cpu or 0) * 100 + 0.5), e.xruns, e.late_blocks, e.midi_dropped, e.record_dropped, e.devices_stopped))
end, { desc = "What has gone wrong while playing: xruns, late plugin blocks, dropped MIDI, lost recorded frames, stopped devices" })
-- The audio devices: a picker, and a command for each.
local engine_groups = { info = "", output = "output", input = "input", block = "block", rate = "rate", backend = "system" }
command("audio", function()
  local choices = daw.audio.engine_choices()
  daw.pick({
    title = "Audio devices",
    items = choices,
    format = function(item)
      if item.group == "info" then return item.label end
      return string.format("%s %-7s %s", item.checked and "●" or " ", engine_groups[item.group], item.label)
    end,
    on_choose = function(item) daw.audio.choose_engine(item) end,
  })
end, { desc = "Choose the audio output, input, block size, sample rate and sound system from a list" })
local function device_names(which)
  return function()
    local ok, list = pcall(daw.audio.devices)
    local words = { "default" }
    for _, d in ipairs(ok and list[which] or {}) do words[#words + 1] = d.name end
    return words
  end
end
for _, which in ipairs({ "output", "input" }) do
  command("audio." .. which, function(ctx)
    if not ctx.args[1] then return daw.notify("audio." .. which .. ": " .. api.engine_get()[which == "output" and "device" or "input_device"]) end
    daw.audio.choose_engine({ [which] = table.concat(ctx.args, " ") })
  end, {
    desc = "Open the " .. which .. " device by name or part of it, or `default`: `audio." .. which .. " UR22`",
    complete = device_names(which .. "s"),
  })
end
command("audio.buffer", function(ctx)
  local frames = tonumber(ctx.args[1])
  if not frames then return daw.notify("audio.buffer: " .. daw.audio.timing()) end
  daw.audio.choose_engine({ buffer = math.floor(frames) })
end, { desc = "Frames per audio callback, or 0 for the device's own: `audio.buffer 128`" })
command("audio.rate", function(ctx)
  local rate = tonumber(ctx.args[1])
  if not rate then return daw.notify("audio.rate: " .. daw.audio.timing()) end
  daw.audio.choose_engine({ rate = math.floor(rate) })
end, { desc = "The sample rate in Hz, or 0 for the device's own: `audio.rate 48000`" })
command("audio.system", function(ctx)
  if not ctx.args[1] then return daw.notify("audio.system: " .. api.engine_get().backend) end
  daw.audio.choose_engine({ backend = tostring(ctx.args[1]) })
end, { desc = "The sound system, as `:audio` lists them: `audio.system pipewire`, `audio.system auto`",
  complete = function() return (daw.audio.devices().backends or {}) end })
-- Tracks that do not feed each other are processed side by side.
daw.on("option.changed", function(e)
  if e.name == "threads" then api.engine_set_threads(e.value) end
end)
command("quit", function()
  if daw.project.modified then
    return daw.notify("the project has unsaved changes: `:w` saves them, `:q!` quits without them", "error")
  end
  api.quit(0)
end, { desc = "Quit, unless there are unsaved changes" })
command("quit!", function()
  daw.autosave.discard = true
  api.quit(0)
end, { desc = "Quit without saving" })
command("reload", function()
  api.reload()
  daw.defer(function() daw.notify("reloaded") end)
end, { desc = "Reload the Lua runtime, your configuration and extensions" })
command("lua", function(ctx)
  local code = ctx.args[1] or ""
  local chunk = loadstring("return " .. code, "=lua") or assert(loadstring(code, "=lua"))
  -- Asked for by hand: a minute, not the two seconds a callback gets.
  daw.limit.untrusted(chunk)
  daw.limit.extend(60000)
  local results = { chunk() }
  if #results > 0 then
    for i, v in ipairs(results) do results[i] = daw.inspect(v) end
    daw.notify(table.concat(results, ", "))
  end
end, { desc = "Run Lua: `lua daw.project.tempo = 90`, `lua daw.tracks()`", raw = true })
command("messages", function()
  local styles = { info = "Normal", warn = "Warn", error = "Error" }
  local lines = {}
  for _, m in ipairs(daw.ui.messages) do lines[#lines + 1] = { text = m.text, style = styles[m.level] } end
  if #lines == 0 then lines[1] = { text = "No messages yet.", style = "Dim" } end
  daw.ui.page("Messages", lines, { bottom = true })
end, { desc = "Show every message so far, the newest at the bottom" })
command("commands", function()
  local lines = {}
  for _, spec in ipairs(daw.commands.list()) do
    lines[#lines + 1] = string.format("%-22s %s", spec.name, spec.desc)
  end
  daw.ui.page("Commands", lines)
end, { desc = "List every command" })
command("extensions", function()
  local lines = {}
  for _, e in ipairs(daw.ext.list()) do
    lines[#lines + 1] = { text = string.format("%-20s %s", e.name, e.ok and e.path or "FAILED: " .. tostring(e.error)), style = e.ok and "Normal" or "Error" }
  end
  if #lines == 0 then lines[1] = "No extensions loaded. They live in " .. api.env().config_dir .. "/extensions" end
  daw.ui.page("Extensions", lines)
end, { desc = "List loaded extensions" })

for alias, target in pairs({ w = "write", e = "edit", q = "quit", ["q!"] = "quit!", u = "undo" }) do
  command.alias(alias, target)
end

command("cmdline", function()
  daw.ui.input({
    prompt = ":",
    history = "cmdline",
    -- Command names, then what each command says its arguments are.
    complete = function(text) return daw.commands.complete(text) end,
  }, function(line)
    -- A number alone is a bar to go to, as it is a line in an editor.
    if line:match("^%s*%d+%s*$") then return daw.commands.run("cursor.bar", { tonumber(line) }) end
    if line:match("%S") then daw.state.last_cmdline = line end
    daw.commands.exec(line)
  end)
end, { desc = "Type a command" })

-- Modal editing ----------------------------------------------------------------

command("visual", function(ctx)
  keymap.visual_start(ctx.args[1] == "line" and "V" or ctx.args[1] == "block" and "b" or "v")
end, { desc = "Start or stop selecting: `visual`, `visual line`, `visual block`" })
command("normal", function(ctx)
  keymap.normal(ctx.args[1] or "")
end, { desc = "Type keys: `normal 3j dd`", raw = true })
command("search", function(ctx)
  local function go(text)
    if text == "" then return end
    keymap.push_jump()
    keymap.search(text, 1)
  end
  if ctx.args[1] then return go(table.concat(ctx.args, " ")) end
  daw.ui.input({ prompt = "/", history = "search" }, go)
end, { desc = "Find a clip or track by name: `search chorus`; `n` and `N` go on to the next and previous" })
command("registers", function()
  local lines = {}
  local names = {}
  for name in pairs(keymap.registers) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local value, what = keymap.registers[name], nil
    if value.kind == "keys" then
      what = "macro   " .. value.keys
    elseif value.kind == "tracks" then
      local list = {}
      for i, t in ipairs(value.tracks) do list[i] = t.name end
      what = "tracks  " .. table.concat(list, ", ")
    elseif value.kind == "range" then
      local clips = 0
      for _, row in ipairs(value.rows) do clips = clips + #row end
      what = string.format("time    %g beats on %d track%s, %d clip%s", value.length, #value.rows, #value.rows == 1 and "" or "s", clips, clips == 1 and "" or "s")
    elseif value.kind == "notes" then
      what = string.format("notes   %d over %g beats", #value.notes, value.length)
    elseif value.kind == "device" then
      what = "device  " .. value.device.kind
    else
      what = value.kind
    end
    lines[#lines + 1] = string.format('"%s  %s', name, what)
  end
  if #lines == 0 then lines[1] = "Nothing yanked or recorded yet." end
  daw.ui.page("Registers", lines)
end, { desc = "Show what the registers hold" })
command("marks", function()
  local lines = {}
  for view, list in pairs({ arrange = keymap.marks("arrange"), pianoroll = keymap.marks("pianoroll") }) do
    local names = {}
    for name in pairs(list) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local pos = list[name]
      local where = view == "arrange" and daw.time.format(pos.beat) .. "  " .. (pcall(api.track_get, pos.track) and api.track_get(pos.track).name or "(track gone)")
        or daw.music.name(pos[1]) .. "  beat " .. pos[2] + 1
      lines[#lines + 1] = string.format("%s  %-10s %s", name, view, where)
    end
  end
  if #lines == 0 then lines[1] = "No marks. `ma` sets mark a at the cursor, `'a` goes back to it." end
  daw.ui.page("Marks", lines)
end, { desc = "List the marks" })
local function remove_marks(spec, all)
  local removed, err = keymap.delmarks(spec, all)
  if not removed then return daw.notify(err, "warn") end
  if removed == 0 then return daw.notify("no such mark is set", "warn") end
  daw.notify(removed == 1 and "removed 1 mark" or "removed " .. removed .. " marks")
end
command("delmarks", function(ctx)
  if not ctx.args[1] then return daw.notify("usage: delmarks a b c-e; delmarks! removes every lowercase mark", "warn") end
  remove_marks(table.concat(ctx.args, " "))
end, {
  desc = "Remove marks: `delmarks a`, `delmarks a-d x`",
  complete = function()
    local seen, out = {}, {}
    for _, view in ipairs({ "arrange", "pianoroll" }) do
      for name in pairs(keymap.marks(view)) do seen[name] = true end
    end
    for name in pairs(seen) do out[#out + 1] = name end
    table.sort(out)
    return out
  end,
})
command("delmarks!", function() remove_marks("", true) end, { desc = "Remove every lowercase mark" })
command.alias("delm", "delmarks")
command.alias("delm!", "delmarks!")
command("info", function()
  local track = need_track()
  if not track then return end
  local t, lines = track:get(), {}
  local clip = cursor.clip()
  if clip then
    local c = clip:get()
    lines[#lines + 1] = { text = "Clip  " .. c.name, style = "Title" }
    lines[#lines + 1] = string.format("  %s to %s, %g beats%s", daw.time.format(c.start), daw.time.format(c.start + c.length), c.length, c.muted and ", muted" or "")
    if c.kind == "midi" then
      lines[#lines + 1] = string.format("  %d notes", c.note_count)
    else
      lines[#lines + 1] = string.format("  %s", c.file)
      lines[#lines + 1] = string.format("  from %.3f s into the file, gain %+.1f dB", c.offset, c.gain)
    end
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = { text = "Track  " .. t.name, style = "Title" }
  lines[#lines + 1] = string.format("  volume %+.1f dB, pan %+.2f%s%s%s", t.volume, t.pan, t.mute and ", muted" or "", t.solo and ", solo" or "", t.armed and ", armed" or "")
  lines[#lines + 1] = "  output  " .. (t.output and api.track_get(t.output).name or "Master")
  if t.input then lines[#lines + 1] = "  input   " .. t.input end
  for _, send in ipairs(t.sends) do
    lines[#lines + 1] = string.format("  send    %s at %+.1f dB", api.track_get(send.target).name, send.level)
  end
  for i, device in ipairs(track:devices()) do
    local d = device:get()
    lines[#lines + 1] = string.format("  %d. %s%s", i, d.name, d.bypass and "  (bypassed)" or "")
  end
  for _, lane in ipairs(api.lane_list(track.id)) do
    lines[#lines + 1] = string.format("  automation  %s, %d points%s", lane.param or lane.target, lane.point_count, lane.enabled and "" or ", off")
  end
  daw.ui.page("Under the cursor", lines)
end, { desc = "Describe the clip and track under the cursor" })
command("wq", function(ctx)
  daw.commands.run("write", ctx.args)
  api.quit(0)
end, { desc = "Save the project and quit" })
command.alias("x", "wq")
command.alias("reg", "registers")

-- Keys -----------------------------------------------------------------------
--
-- Neovim's grammar on a timeline. Beats are the columns and tracks the lines
-- of the arrange view; a clip is a word. In the piano roll pitches are the
-- lines and a note is a word. So `dw` deletes up to the next clip, `yy` yanks
-- a track, `3>ic` nudges a clip three steps later, `.` does it again.

local nx = { "n", "x" }
local motion = { motion = true }
local linewise = { motion = true, linewise = true }
local far = { motion = true, jump = true }
local far_lines = { motion = true, linewise = true, jump = true }

map("<Space>", "transport.toggle", { mode = nx, desc = "Play or stop" })
map("<S-CR>", "transport.play_cursor", { mode = nx, desc = "Play from the cursor" })
map("gs", "transport.start", { mode = nx, desc = "Playhead to the start" })
map("gp", "transport.to_cursor", { mode = nx, desc = "Playhead to the cursor" })
map("gL", "transport.loop", { mode = nx, desc = "Toggle looping" })
map("gm", "transport.metronome", { mode = nx, desc = "Toggle the metronome" })
map("gC", "countin", { mode = nx, desc = "Count a bar in before recording, or not" })
map("gI", "punch", { desc = "Punch in and out: record only between two points, or not" })
map("gI", "punch selection", { mode = "x", desc = "Punch in and out over the selection" })
map("ge", "device.editor", { desc = "Show or hide the plugin's window" })
map("R", "transport.record", { desc = "Record, or stop recording" })
map(":", "cmdline", { mode = nx, desc = "Type a command" })
map("?", "help", { mode = nx, desc = "Show key mappings" })
map("u", "undo", { desc = "Undo", repeatable = false })
map("<C-r>", "redo", { desc = "Redo", repeatable = false })
map(".", function(ctx) keymap.repeat_last(ctx.count) end, { desc = "Repeat the last change", repeatable = false })
map("q", function(ctx) keymap.record(ctx.char) end, { mode = nx, char = true, record = true, desc = "Record keys into a register; `q` again stops" })
map("@", function(ctx)
  if ctx.char == ":" then
    for _ = 1, ctx.count or 1 do daw.commands.exec(daw.state.last_cmdline or "") end
  else
    keymap.play(ctx.char, ctx.count)
  end
end, { mode = nx, char = true, repeatable = false, desc = "Play the keys in a register; `@@` the last one, `@:` the last command" })
map("m", function(ctx) keymap.mark(ctx.char) end, { char = true, desc = "Set a mark at the cursor" })
map("'", function(ctx) keymap.goto_mark(ctx.char) end, { motion = true, char = true, desc = "Go to a mark; `''` goes back" })
map("`", function(ctx) keymap.goto_mark(ctx.char) end, { motion = true, char = true, desc = "Go to a mark" })
map("<C-o>", function(ctx) keymap.jump(ctx.count or 1) end, { desc = "Back to where the cursor jumped from" })
map("<C-i>", function(ctx) keymap.jump(-(ctx.count or 1)) end, { desc = "Forward again" })
map("v", function() keymap.visual_start("v") end, { mode = nx, desc = "Select a stretch of time" })
map("V", function() keymap.visual_start("V") end, { mode = nx, desc = "Select whole rows" })
map("<C-v>", function() keymap.visual_start("b") end, { mode = nx, desc = "Select a block" })
map("gv", keymap.visual_restore, { desc = "Select what was selected last" })
map("o", keymap.visual_swap, { mode = "x", desc = "Go to the other end of the selection" })
map("/", "search", { mode = nx, desc = "Find by name" })
map("n", function(ctx) keymap.search_next(1, ctx.count) end, util.merge(far, { desc = "Next match" }))
map("N", function(ctx) keymap.search_next(-1, ctx.count) end, util.merge(far, { desc = "Previous match" }))
map("<Tab>", "view.next", { mode = nx, desc = "Focus the next view" })
map("<S-Tab>", "view.prev", { mode = nx, desc = "Focus the previous view" })
-- Windows and tabs (`Ctrl-w`, `gt`) are mapped in daw/layout.lua.
map("<leader>m", "view.toggle mixer", { desc = "Show or hide the mixer" })
map("<leader>d", "view.toggle devices", { desc = "Show or hide the device panel" })
map("<leader>p", "view.toggle pianoroll", { desc = "Show or hide the piano roll" })
-- What other programs have taught the fingers.
map("<Del>", function() keymap.normal("x") end, { desc = "Delete what is under the cursor" })
-- On a selection it is the operator: what the Delete key does anywhere else.
map("<Del>", function() keymap.normal("d") end, { mode = "x", desc = "Delete the selection" })
map("<C-z>", "undo", { mode = nx, desc = "Undo", repeatable = false })
map("<C-y>", "redo", { mode = nx, desc = "Redo", repeatable = false })
map("<C-s>", "write", { mode = nx, desc = "Save the project" })
map("ZZ", "wq", { desc = "Save and quit" })
map("ZQ", "quit!", { desc = "Quit without saving" })
map("zi", "zoom by=2", { mode = nx, desc = "Zoom in" })
map("zo", "zoom by=0.5", { mode = nx, desc = "Zoom out" })
map("]g", "grid by=2", { mode = nx, desc = "Coarser grid" })
map("[g", "grid by=0.5", { mode = nx, desc = "Finer grid" })

--- Whole tracks from a row down, as a region.
local function rows(first, n)
  return { view = "arrange", kind = "line", r0 = first, r1 = first + (n or 1) - 1, c0 = 0, c1 = 0 }
end

--- Put the cursor on the track now at a row, after tracks came or went.
local function settle(row)
  local list = api.track_list()
  if #list > 0 then cursor.set_track(list[util.clamp(row, 1, #list)]) end
end

-- Tracks can be driven from the arrange view and the mixer alike.
for _, name in ipairs({ "arrange", "mixer" }) do
  local across = name == "mixer"
  local function vmap(lhs, rhs, desc, opts) map(lhs, rhs, util.merge({ view = name, desc = desc }, opts)) end
  vmap(across and "l" or "j", "cursor.down", "Next track", linewise)
  vmap(across and "h" or "k", "cursor.up", "Previous track", linewise)
  vmap(across and "<Right>" or "<Down>", "cursor.down", "Next track", linewise)
  vmap(across and "<Left>" or "<Up>", "cursor.up", "Previous track", linewise)
  vmap("gg", "cursor.first_track", "First track, or track N", far_lines)
  vmap("G", "cursor.last_track", "Last track, or track N", far_lines)
  vmap("o", "track.add", "Add a track below")
  vmap("O", "track.add above=true", "Add a track above")
  vmap("grn", "track.rename", "Rename the track")
  vmap("M", "track.mute", "Mute the track")
  vmap("s", "track.solo", "Solo")
  vmap("r", "track.armed", "Arm for recording")
  vmap("I", "track.input", "Choose the input")
  vmap("<A-i>", "track.monitor", "Hear the input without arming")
  vmap(across and "k" or "+", "track.volume by=1", "Volume up 1 dB")
  vmap(across and "j" or "-", "track.volume by=-1", "Volume down 1 dB")
  vmap(across and ">" or ")", "track.pan by=0.1", "Pan right")
  vmap(across and "<lt>" or "(", "track.pan by=-0.1", "Pan left")
  vmap("<A-j>", "track.move by=1", "Move the track down")
  vmap("<A-k>", "track.move by=-1", "Move the track up")
  vmap("a", "device.add", "Add a device")
end

-- The mixer has no timeline, so its tracks are cut and pasted with plain keys.
local function mmap(lhs, rhs, desc) map(lhs, rhs, { view = "mixer", desc = desc }) end
mmap("dd", function(ctx)
  local row = cursor.index()
  if not row then return end
  keymap.setreg(edit.arrange.delete(rows(row, ctx.count)), ctx.register)
  settle(row)
end, "Cut the track")
mmap("yy", function(ctx)
  local row = cursor.index()
  if row then keymap.setreg(edit.arrange.yank(rows(row, ctx.count)), ctx.register, true) end
end, "Yank the track")
mmap("p", function(ctx) edit.arrange.paste(keymap.getreg(ctx.register), false, ctx.count) end, "Paste tracks after this one")
mmap("P", function(ctx) edit.arrange.paste(keymap.getreg(ctx.register), true, ctx.count) end, "Paste tracks before this one")

-- The session view: clips in slots, launched while the song plays (`daw.launcher`).
local launcher = daw.launcher
map("<leader>l", "view.toggle session", { desc = "Show or hide the session view, clips to launch" })
local function smap(lhs, rhs, desc) map(lhs, rhs, { view = "session", desc = desc }) end
local function to_row(row)
  launcher.row = math.max(0, row)
  api.ui_redraw()
end
smap("l", "cursor.down", "Next track")
smap("h", "cursor.up", "Previous track")
smap("<Right>", "cursor.down", "Next track")
smap("<Left>", "cursor.up", "Previous track")
smap("j", function(ctx) to_row(launcher.row + (ctx.count or 1)) end, "Next slot")
smap("k", function(ctx) to_row(launcher.row - (ctx.count or 1)) end, "Previous slot")
smap("<Down>", function(ctx) to_row(launcher.row + (ctx.count or 1)) end, "Next slot")
smap("<Up>", function(ctx) to_row(launcher.row - (ctx.count or 1)) end, "Previous slot")
smap("gg", function(ctx) to_row((ctx.count or 1) - 1) end, "First slot, or slot N")
smap("G", function(ctx) to_row(ctx.count and ctx.count - 1 or launcher.rows() - 2) end, "Last slot with a clip, or slot N")
smap("<CR>", "launch", "Launch the slot (an empty one stops the track)")
smap("L", "scene", "Launch the scene: the whole row")
smap("s", "launch.stop", "Stop the track's clip")
smap("S", "launch.stop all", "Stop every clip")
smap("b", "launch.back", "Back to the track's timeline")
smap("B", "launch.back all", "Every track back to its timeline")
smap("n", "slot.new", "A new MIDI clip in the slot")
smap("e", "slot.edit", "Open the clip's notes")
smap("x", "slot.delete", "Empty the slot")
smap("dd", "slot.delete", "Empty the slot")
smap("gp", "slot.copy", "Copy the arrange view's clip into the slot")
smap("m", "slot.mode", "Next launch mode: trigger, gate, toggle")
smap("gl", "slot.legato", "Legato on or off")
smap("grn", "scene.name", "Name the scene")
smap("C", "launch.capture", "Capture what is launched into the timeline")
smap("R", "slot.record", "Record into the empty slot, a bar (or a count of bars) from the next boundary")
smap("yy", function(ctx)
  local track = cursor.track_id()
  local clip = track and launcher.clip(track, launcher.row)
  if clip then keymap.setreg({ kind = "slot", clip = daw.clip(clip.id):snapshot() }, ctx.register, true) end
end, "Yank the slot's clip")
smap("p", function(ctx)
  local track, value = cursor.track_id(), keymap.getreg(ctx.register)
  if not track or not value then return end
  -- A slot's clip, or the first clip yanked in the arrange view.
  local snap = value.kind == "slot" and value.clip
  if value.kind == "range" then
    for _, row in ipairs(value.rows) do snap = snap or row[1] end
  end
  if not snap then return daw.notify("the register holds no clip", "warn") end
  daw.restore_clip(util.merge(snap, { slot = launcher.row, start = 0 }), track)
end, "Paste a clip into the slot")

-- Arrange: motions.
local function amap(lhs, rhs, desc, opts) map(lhs, rhs, util.merge({ view = "arrange", desc = desc }, opts)) end
amap("l", "cursor.right", "Right one grid step", motion)
amap("h", "cursor.left", "Left one grid step", motion)
amap("<Right>", "cursor.right", "Right one grid step", motion)
amap("<Left>", "cursor.left", "Left one grid step", motion)
amap("w", "cursor.next_clip", "Start of the next clip", motion)
amap("b", "cursor.prev_clip", "Start of this clip, or the one before", motion)
amap("e", "cursor.clip_end", "End of this clip, or the next", motion)
amap("W", "cursor.next_bar", "Next bar", motion)
amap("B", "cursor.prev_bar", "Previous bar", motion)
amap("0", "cursor.start", "Start of the project", motion)
amap("^", "cursor.first_clip", "Start of the track's first clip", motion)
amap("$", "cursor.end", "End of the track's last clip", motion)
amap("|", "cursor.bar", "Bar N", far)
amap("gP", "cursor.to_playhead", "Cursor to the playhead", far)
amap("<C-d>", function(ctx) cursor.move_track(4 * (ctx.count or 1)) end, "Four tracks down", linewise)
amap("<C-u>", function(ctx) cursor.move_track(-4 * (ctx.count or 1)) end, "Four tracks up", linewise)
amap("*", function()
  local clip = cursor.clip()
  if clip then keymap.search(clip.name, 1) end
end, "Next clip with this one's name", far)
amap("zz", function() daw.ui.views.arrange:center() end, "Scroll the cursor to the middle")
-- Groups of tracks.
map("<leader>g", "track.group", { view = "arrange", mode = nx, desc = "Group the selected tracks" })
amap("<leader>G", "track.ungroup", "Take the track out of its group; dissolve a group")
amap("za", "track.fold", "Fold the group away, or open it")
-- VCAs, and the faders of a group moving together.
map("<leader>vn", "vca.make", { view = "arrange", mode = nx, desc = "A new VCA over the selected tracks" })
map("<leader>va", "vca.assign", { view = "arrange", mode = nx, desc = "Put the selected tracks under a VCA" })
map("<leader>vr", "vca.release", { view = "arrange", mode = nx, desc = "Take the selected tracks out of their VCAs" })
amap("<leader>vx", "vca.dissolve", "Take the VCA at the cursor away")
amap("<leader>vl", "group.link", "Link the faders of the group's members")
amap("<leader>s", "send", "Send the track's sound to another as well")
amap("<leader>o", "track.output", "Choose where the track's sound goes")
amap("zM", "track.fold all", "Fold every group")
amap("zR", "track.fold none", "Open every group")
amap("zl", function(ctx) daw.ui.views.arrange:scroll_by(ctx.count or 1) end, "Scroll a bar later")
amap("zh", function(ctx) daw.ui.views.arrange:scroll_by(-(ctx.count or 1)) end, "Scroll a bar earlier")

-- Arrange: text objects.
local function aobject(lhs, fn, desc) keymap.textobject(lhs, fn, { view = "arrange", desc = desc }) end
local function on_row(c0, c1)
  local row = cursor.index() or 1
  return { view = "arrange", kind = "char", r0 = row, r1 = row, c0 = c0, c1 = c1 }
end
aobject("ic", function()
  local clip = cursor.clip()
  if clip then return on_row(clip.start, clip.start + clip.length) end
end, "The clip under the cursor")
aobject("ac", function()
  local clip = cursor.clip()
  if not clip then return end
  -- With the silence after it, up to the next clip.
  local c1 = clip.start + clip.length
  local finish = c1
  for _, other in ipairs(clip:track():clips()) do
    if other.start >= c1 - 1e-9 and (finish == c1 or other.start < finish) then finish = other.start end
  end
  return on_row(clip.start, finish)
end, "The clip and the gap after it")
for _, lhs in ipairs({ "ib", "ab" }) do
  aobject(lhs, function(ctx)
    local n = daw.time.bar_of(cursor.beat)
    return on_row(daw.time.bar_start(n), daw.time.bar_start(n + (ctx.count or 1)))
  end, "This bar, or N bars from it")
end
for _, lhs in ipairs({ "il", "al" }) do
  aobject(lhs, function() return on_row(transport.loop_start, transport.loop_end) end, "The loop")
end
for _, lhs in ipairs({ "it", "at" }) do
  aobject(lhs, function()
    local row = cursor.index() or 1
    local c0, c1 = edit.arrange.span(rows(row))
    if c1 > c0 then return on_row(c0, c1) end
  end, "Everything on the track")
end
for _, lhs in ipairs({ "ie", "ae" }) do
  aobject(lhs, function()
    local n = #api.track_list()
    if n == 0 or daw.project.length <= 0 then return end
    return { view = "arrange", kind = "block", r0 = 1, r1 = n, c0 = 0, c1 = daw.project.length }
  end, "The entire project")
end

-- Arrange: operators.
local function aop(lhs, fn, desc) keymap.operator(lhs, fn, { view = "arrange", desc = desc }) end
aop("d", function(region, ctx)
  keymap.setreg(edit.arrange.delete(region), ctx.register)
  if region.kind == "line" then settle(region.r0) end
end, "Delete")
aop("y", function(region, ctx)
  local value = edit.arrange.yank(region)
  keymap.setreg(value, ctx.register, true)
  if value.kind == "tracks" then
    daw.notify(#value.tracks == 1 and "yanked track " .. value.tracks[1].name or "yanked " .. #value.tracks .. " tracks")
  else
    daw.notify(string.format("yanked %g beats", value.length))
  end
end, "Yank")
aop("c", function(region, ctx)
  -- Empty the stretch and start a fresh clip there, open for typing notes.
  local c0, c1 = edit.arrange.span(region)
  if c1 - c0 < 1e-9 then c0, c1 = cursor.beat, cursor.beat + daw.opt.clip_length end
  local removed = edit.arrange.delete(util.merge(region, { kind = "char", c0 = c0, c1 = c1 }))
  keymap.setreg(removed, ctx.register)
  local track = need_track()
  if not track then return end
  cursor.set_beat(c0)
  -- The new clip takes the name of the one it replaces.
  local first = removed.rows[1] and removed.rows[1][1]
  roll:edit(track:add_clip({ start = c0, length = c1 - c0, name = first and first.name or nil }))
  keymap.set_mode("i")
end, "Change: empty it and enter notes")
--- Move a region's clips by grid steps, and the cursor with them so that
--- `.` finds them again.
local function shift(region, steps)
  local by = math.max(steps * daw.opt.grid, -region.c0)
  edit.arrange.shift(region, by)
  if region.kind ~= "line" then cursor.set_beat(cursor.beat + by) end
end
aop(">", function(region, ctx) shift(region, region.visual and ctx.count or 1) end, "Move clips later")
aop("<lt>", function(region, ctx) shift(region, -(region.visual and ctx.count or 1)) end, "Move clips earlier")
aop("=", edit.arrange.quantize, "Snap clips and their notes to the grid")
aop("gc", edit.arrange.mute, "Mute or unmute")
aop("gl", function(region)
  local c0, c1 = edit.arrange.span(region)
  if c1 <= c0 then return end
  transport.loop_start, transport.loop_end, transport.loop_enabled = c0, c1, true
end, "Loop")

-- Arrange: what is done so often that it has a key of its own.
amap("x", function() keymap.normal("dic") end, "Delete the clip")
amap("D", function() keymap.normal("d$") end, "Delete to the end of the track")
amap("C", function() keymap.normal("c$") end, "Change to the end of the track")
amap("Y", function() keymap.normal("y$") end, "Yank to the end of the track")
amap("p", function(ctx) edit.arrange.paste(keymap.getreg(ctx.register), false, ctx.count) end, "Paste after the clip, or tracks below")
amap("P", function(ctx) edit.arrange.paste(keymap.getreg(ctx.register), true, ctx.count) end, "Paste at the cursor, or tracks above")
amap("&", "clip.duplicate", "Repeat the clip after itself")
amap("~", "clip.mute", "Mute or unmute the clip")
amap("S", "clip.split", "Split the clip at the cursor")
amap("J", "clip.join", "Join the clip with the next one")
amap("<CR>", "clip.edit", "Edit the clip's notes")
amap("i", "clip.insert", "Enter notes here, in a new clip if there is none")
amap("grc", "clip.rename", "Rename the clip")
amap("gw", "clip.warp", "Put a warp marker on the audio clip at the cursor")
amap("gW", "clip.warp remove", "Take off the clip's warp marker nearest the cursor")
amap("L", "clip.move by=1", "Move the clip right")
amap("H", "clip.move by=-1", "Move the clip left")
amap("<A-l>", "clip.resize by=1", "Lengthen the clip")
amap("<A-h>", "clip.resize by=-1", "Shorten the clip")
amap("<C-a>", "clip.transpose by=1", "Transpose the clip up a semitone")
amap("<C-x>", "clip.transpose by=-1", "Transpose the clip down a semitone")
amap("A", "lane.add", "Add a volume automation point at the cursor")
amap("<leader>at", "lane.toggle", "Turn volume automation off or on")
amap("<leader>aw", "lane.write", "Write automation by moving things while playing, or stop")
amap("<leader>am", "automation", "The track's automation mode: read, touch, latch, write, off in turn")
amap("]t", "take next", "The clip's next take")
amap("[t", "take prev", "The clip's take before")
amap("zT", "tempo.lane", "Show or hide the tempo curve under the ruler")
amap("zt", "take.lanes", "Show the track's takes as lanes under its clips, or hide them")
amap("]'", "marker.next", "The next marker or region", { motion = true })
amap("['", "marker.prev", "The marker or region before", { motion = true })
amap("g'", "marker", "Put a marker at the cursor")
amap('g"', "marker.list", "Go to a marker or region from a list")
amap("gx", "marker.remove", "Remove the marker or region at the cursor")
amap("<leader>ax", "lane.clear", "Clear the volume automation")
amap("K", "info", "Describe what is under the cursor")

-- Arrange: on a selection.
local function ax(lhs, fn, desc) map(lhs, nil, { view = "arrange", mode = "x", operator = fn, desc = desc }) end
ax("x", function(region, ctx) keymap.setreg(edit.arrange.delete(region), ctx.register) end, "Delete")
ax("p", function(region, ctx)
  local value = keymap.getreg(ctx.register)
  if not value then return daw.notify("nothing to paste yet", "warn") end
  local replaced = edit.arrange.delete(region)
  if region.kind == "line" then settle(region.r0) end
  edit.arrange.paste(value, true, ctx.count)
  keymap.setreg(replaced)
end, "Replace with the register")
ax("J", function(region)
  for _, id in ipairs(edit.arrange.tracks(region)) do
    local c0, c1 = edit.arrange.span(region)
    edit.arrange.join(id, c0, c1, region.clips)
  end
end, "Join the clips")
map("S", "clip.split", { view = "arrange", mode = "x", desc = "Split the chosen clips at the cursor" })
ax("~", edit.arrange.mute, "Mute or unmute")
ax("M", edit.arrange.mute, "Mute or unmute")
ax("<CR>", function(region)
  local ids = {}
  for _, track in ipairs(edit.arrange.tracks(region)) do
    for _, c in ipairs(api.clip_list(track)) do
      local inside
      if region.clips then
        inside = region.clips[c.id]
      else
        inside = region.kind == "line" or (c.start < region.c1 - 1e-9 and c.start + c.length > region.c0 + 1e-9)
      end
      if inside and c.kind == "midi" then ids[#ids + 1] = c.id end
    end
  end
  local under = daw.cursor.clip()
  daw.roll_clips.open(ids, under and under.id)
end, "Edit the notes of the selected MIDI clips together")
ax("<C-a>", function(region, ctx) edit.arrange.transpose(region, ctx.count or 1) end, "Transpose up")
ax("<C-x>", function(region, ctx) edit.arrange.transpose(region, -(ctx.count or 1)) end, "Transpose down")
ax("L", function(region, ctx) shift(region, ctx.count or 1) end, "Move the clips right")
ax("H", function(region, ctx) shift(region, -(ctx.count or 1)) end, "Move the clips left")

-- Device panel.
local devices = daw.ui.views.devices
local function dmap(lhs, rhs, desc) map(lhs, rhs, { view = "devices", desc = desc }) end
local function row(step) return function(ctx)
  devices.row = devices.row + step * (ctx.count or 1)
  api.ui_redraw()
end end
dmap("j", row(1), "Next row")
dmap("k", row(-1), "Previous row")
dmap("<Down>", row(1), "Next row")
dmap("<Up>", row(-1), "Previous row")
dmap("l", function(ctx) devices:adjust(ctx.count or 1) end, "Raise the parameter")
dmap("h", function(ctx) devices:adjust(-(ctx.count or 1)) end, "Lower the parameter")
dmap("L", function() devices:adjust(10) end, "Raise the parameter a lot")
dmap("H", function() devices:adjust(-10) end, "Lower the parameter a lot")
dmap("<C-a>", function(ctx) devices:adjust(ctx.count or 1) end, "Raise the parameter")
dmap("<C-x>", function(ctx) devices:adjust(-(ctx.count or 1)) end, "Lower the parameter")
dmap("a", "device.add", "Add a device")
dmap("x", "device.remove", "Remove the device")
dmap("b", "device.bypass", "Bypass the device")
dmap("R", "device.restart", "Start a stopped plugin again")
dmap("o", "device.offline", "Set the device offline, or back online")
dmap("e", "device.editor", "Show or hide the plugin's window")
dmap("<CR>", "device.editor", "Show or hide the plugin's window")
dmap("yy", function(ctx)
  local device = devices:selected()
  if device then keymap.setreg({ kind = "device", device = device:snapshot() }, ctx.register, true) end
end, "Yank the device")
dmap("dd", function(ctx)
  local device = devices:selected()
  if not device then return end
  keymap.setreg({ kind = "device", device = device:snapshot() }, ctx.register)
  device:remove()
end, "Cut the device")
local function paste_device(offset) return function(ctx)
  local value, track = keymap.getreg(ctx.register), need_track()
  if not track then return end
  if not (value and (value.kind == "device" or value.kind == "devices")) then return daw.notify("no device in the register: `yy` or `dd` on one first", "warn") end
  local selected = devices:selected()
  local at = selected and selected.index + offset or nil
  -- Several devices, from a selection, go in in their order.
  for i, snap in ipairs(value.devices or { value.device }) do daw.restore_device(snap, track, at and at + i - 1) end
end end
dmap("p", paste_device(1), "Paste the device after this one")
dmap("P", paste_device(0), "Paste the device before this one")
dmap("<A-j>", function()
  local device = devices:selected()
  if device then device:move(device.index + 1) end
end, "Move the device later in the chain")
dmap("<A-k>", function()
  local device = devices:selected()
  if device and device.index > 1 then device:move(device.index - 1) end
end, "Move the device earlier in the chain")

-- Piano roll: motions.
local function pmap(lhs, rhs, desc, opts) map(lhs, rhs, util.merge({ view = "pianoroll", desc = desc }, opts)) end
local function move(dbeat, dpitch) return function(ctx)
  local n = ctx.count or 1
  roll:move(dbeat * n * daw.opt.note_grid, dpitch * n)
end end
pmap("h", move(-1, 0), "Left one step", motion)
pmap("l", move(1, 0), "Right one step", motion)
pmap("j", move(0, -1), "Down a semitone", linewise)
pmap("k", move(0, 1), "Up a semitone", linewise)
pmap("<Left>", move(-1, 0), "Left one step", motion)
pmap("<Right>", move(1, 0), "Right one step", motion)
pmap("<Down>", move(0, -1), "Down a semitone", linewise)
pmap("<Up>", move(0, 1), "Up a semitone", linewise)
pmap("J", move(0, -12), "Down an octave", linewise)
pmap("K", move(0, 12), "Up an octave", linewise)
pmap("w", function(ctx) roll:to_note(1, ctx.count) end, "Next note", motion)
pmap("b", function(ctx) roll:to_note(-1, ctx.count) end, "Previous note", motion)
pmap("e", function(ctx) roll:to_note_end(ctx.count) end, "End of this note, or the next", motion)
pmap("W", function(ctx) roll:to_bar(ctx.count or 1) end, "Next bar", motion)
pmap("B", function(ctx) roll:to_bar(-(ctx.count or 1)) end, "Previous bar", motion)
pmap("0", function() roll:set(nil, (roll:span())) end, "Start of the clip", motion)
pmap("^", function() roll:to_edge(1) end, "The first note", motion)
pmap("$", function() roll:to_edge(-1) end, "End of the clip", motion)
pmap("gg", function() roll:to_extreme(1) end, "The highest note", far_lines)
pmap("G", function() roll:to_extreme(-1) end, "The lowest note", far_lines)
pmap("*", function() keymap.search(daw.music.name(roll.pitch), 1) end, "Next note of this pitch", far)
pmap("gp", function()
  local clip = roll:clip()
  if clip then transport.seek(clip.start + roll.beat) end
end, "Playhead to the cursor")

-- Piano roll: text objects.
local function pobject(lhs, fn, desc) keymap.textobject(lhs, fn, { view = "pianoroll", desc = desc }) end
for _, lhs in ipairs({ "in", "an" }) do
  pobject(lhs, function()
    local note = roll:note_at(roll.pitch, roll.beat)
    if note then
      return { view = "pianoroll", kind = "block", r0 = note.pitch, r1 = note.pitch, c0 = note.start, c1 = note.start + note.length }
    end
  end, "The note under the cursor")
end
for _, lhs in ipairs({ "ib", "ab" }) do
  pobject(lhs, function(ctx)
    local clip = roll:clip()
    if not clip then return end
    local n = daw.time.bar_of(clip.start + roll.beat)
    local c0, c1 = daw.time.bar_start(n) - clip.start, daw.time.bar_start(n + (ctx.count or 1)) - clip.start
    return { view = "pianoroll", kind = "char", r0 = roll.pitch, r1 = roll.pitch, c0 = c0, c1 = c1 }
  end, "This bar, or N bars from it")
end
for _, lhs in ipairs({ "ic", "ac", "ie", "ae" }) do
  pobject(lhs, function()
    if not roll:clip() then return end
    local c0, c1 = roll:span()
    return { view = "pianoroll", kind = "char", r0 = roll.pitch, r1 = roll.pitch, c0 = c0, c1 = c1 }
  end, "Every note of the clip, or of the clips edited")
end

-- Piano roll: operators. They act on every clip the roll edits.
local function editing()
  local parts = roll:parts()
  return #parts > 1 and parts or roll:clip()
end
local function pop(lhs, fn, desc)
  keymap.operator(lhs, function(region, ctx)
    if roll:clip() then return fn(editing(), region, ctx) end
  end, { view = "pianoroll", desc = desc })
end
pop("d", function(clip, region, ctx) keymap.setreg(edit.roll.delete(clip, region), ctx.register) end, "Delete")
pop("y", function(clip, region, ctx)
  local value = edit.roll.yank(clip, region)
  keymap.setreg(value, ctx.register, true)
  daw.notify(#value.notes == 1 and "yanked 1 note" or "yanked " .. #value.notes .. " notes")
end, "Yank")
pop("c", function(clip, region, ctx)
  keymap.setreg(edit.roll.delete(clip, region), ctx.register)
  if region.kind ~= "line" then roll:set(nil, region.c0) end
  keymap.set_mode("i")
end, "Change: delete and enter notes")
local function shift_notes(clip, region, steps)
  local by = math.max(steps * daw.opt.note_grid, region.kind == "line" and -math.huge or -region.c0)
  edit.roll.each(clip, region, function(n) n.start = math.max(0, n.start + by) end)
  if region.kind ~= "line" then roll:set(nil, roll.beat + by) end
end
pop(">", function(clip, region, ctx) shift_notes(clip, region, region.visual and ctx.count or 1) end, "Move notes later")
pop("<lt>", function(clip, region, ctx) shift_notes(clip, region, -(region.visual and ctx.count or 1)) end, "Move notes earlier")
pop("=", function(clip, region)
  local grid = daw.opt.note_grid
  edit.roll.each(clip, region, function(n)
    n.start, n.length = util.round(n.start, grid), math.max(grid, util.round(n.length, grid))
  end)
end, "Snap notes to the grid")
pop("gl", function(_, region)
  local clip = roll:clip()
  local c0, c1 = region.c0, region.c1
  if region.kind == "line" then c0, c1 = roll:span() end
  transport.loop_start, transport.loop_end, transport.loop_enabled = clip.start + c0, clip.start + c1, true
end, "Loop")

-- Piano roll: single keys.
pmap("<CR>", function() roll:toggle_note() end, "Add or remove a note")
pmap("i", function() keymap.set_mode("i") end, "Draw notes from the cursor")
pmap("a", function()
  local note = roll:note_at(roll.pitch, roll.beat)
  if note then
    roll:set(nil, note.start + note.length)
  elseif daw.opt.roll_insert ~= "keys" then
    -- A step on, past the end of the clip if need be: it grows to hold what is drawn.
    roll.beat = roll.beat + daw.opt.note_grid
  end
  keymap.set_mode("i")
end, "Draw notes after this one")
pmap("I", function()
  daw.roll_draw.keys_once()
  keymap.set_mode("i")
end, "Enter notes from the keyboard, as a piano")
-- Notes chosen with the pointer (a click, a box) come first for the keys
-- that would otherwise act on the note under the cursor.
-- The first of them: its clip's id and its place there.
local function chosen()
  for _, part in ipairs(roll:parts()) do
    local places = daw.frontend.chosen_notes(part.id)
    if #places > 0 then return part.id, places[1] end
  end
end
pmap("x", function()
  local clip = roll:clip()
  -- Controller moves chosen in the strip go with the chosen notes.
  local moves = clip and daw.controls.remove(clip.id) or 0
  local first = chosen()
  if first then return daw.frontend.act.remove_chosen_notes(first) end
  if moves == 0 then keymap.normal("din") end
end, "Delete the note, or the notes and controller moves chosen with the pointer")
pmap("gA", function()
  local clip = roll:clip()
  if clip then daw.frontend.act.select_all_notes(clip.id) end
end, "Choose every note")
command("notes.quantize", function(ctx)
  local clip = roll:clip()
  if not clip then return daw.notify("open a clip in the piano roll first", "warn") end
  local n = daw.frontend.act.quantize_notes(clip.id, tonumber(ctx.args[1]) and tonumber(ctx.args[1]) / 100 or 1)
  daw.notify(string.format("%d note%s on the %g-beat grid", n, n == 1 and "" or "s", daw.opt.note_grid))
end, { desc = "Quantize the piano roll's chosen notes, or all, to its grid: `notes.quantize [strength%]`" })
pmap("E", "notes.list", "The clip's notes and controller moves as a list, to change in place")
command("notes.list", function()
  local clip = roll:clip()
  if not clip then return daw.notify("open a clip in the piano roll first", "warn") end
  daw.ui.open("eventlist", { title = "Events · " .. clip.name, width = 60, height = 24 })
end, { desc = "List the piano roll's notes and controller moves, each cell changed in place (Enter), `x` deletes, `a` adds a move" })
command("controls.line", function(ctx)
  local clip = roll:clip()
  if not clip then return daw.notify("open a clip in the piano roll first", "warn") end
  local args = ctx.args
  local kind, at = args[1], 2
  local number
  if kind == "cc" then number, at = tonumber(args[2]), 3 end
  local from, to = tonumber(args[at]), tonumber(args[at + 1])
  if not (kind == "cc" and number or kind == "bend" or kind == "pressure") or not from or not to then
    return daw.notify("controls.line cc 74 0 127, controls.line bend -8192 8191, controls.line pressure 0 127", "warn")
  end
  -- From and to in the units the event list shows: seven-bit steps, or the wheel's -8192 to 8191.
  local function height(v) return kind == "bend" and (v / 8192 + 1) / 2 or v / 127 end
  local selection = keymap.selection()
  local b0, b1 = 0, clip.length
  if selection and daw.ui.focused == "pianoroll" and selection.kind ~= "line" then b0, b1 = selection.c0, selection.c1 end
  -- The last step of the stretch reaches `to`.
  b1 = math.max(b0, b1 - daw.opt.note_grid)
  local made = daw.frontend.act.line_controls(clip.id, kind, number, b0, height(from), b1, height(to), false)
  keymap.set_mode("n")
  daw.notify(string.format("%d %s moves in a line", made, kind == "cc" and "CC " .. number or kind))
end, { desc = "Draw a straight line of controller moves over the piano roll's selection, or its whole clip: "
  .. "`controls.line cc 74 0 127`, `controls.line bend 0 8191`, `controls.line pressure 127 0`" })
command("notes.step_input", function() daw.frontend.act.toggle_step_input() end,
  { desc = "Turn step input on or off: notes from a MIDI keyboard are entered at the piano roll's cursor while stopped" })
pmap("D", function() keymap.normal("d$") end, "Delete to the end of the clip")
pmap("C", function() keymap.normal("c$") end, "Change to the end of the clip")
pmap("Y", function() keymap.normal("y$") end, "Yank to the end of the clip")
pmap("p", function(ctx) roll:paste(keymap.getreg(ctx.register), false, ctx.count) end, "Paste after the note")
pmap("P", function(ctx) roll:paste(keymap.getreg(ctx.register), true, ctx.count) end, "Paste at the cursor")
pmap("+", function()
  roll:change(function(n) n.length = n.length + daw.opt.note_grid end)
end, "Lengthen the note")
pmap("-", function()
  roll:change(function(n) n.length = math.max(daw.opt.note_grid, n.length - daw.opt.note_grid) end)
end, "Shorten the note")
pmap("L", function()
  if roll:change(function(n) n.start = n.start + daw.opt.note_grid end) then roll:move(daw.opt.note_grid, 0) end
end, "Move the note right")
pmap("H", function()
  local step = math.min(daw.opt.note_grid, roll.beat)
  if roll:change(function(n) n.start = math.max(0, n.start - step) end) then roll:move(-step, 0) end
end, "Move the note left")
pmap("<C-a>", function(ctx)
  local by = ctx.count or 1
  local clip, place = chosen()
  if clip then return daw.frontend.act.drag_notes(clip, place, 0, by, false, true) end
  if roll:change(function(n) n.pitch = math.min(127, n.pitch + by) end) then roll:move(0, by) end
end, "Move the note up a semitone")
pmap("<C-x>", function(ctx)
  local by = ctx.count or 1
  local clip, place = chosen()
  if clip then return daw.frontend.act.drag_notes(clip, place, 0, -by, false, true) end
  if roll:change(function(n) n.pitch = math.max(0, n.pitch - by) end) then roll:move(0, -by) end
end, "Move the note down a semitone")
pmap("]", function()
  roll:change(function(n) n.velocity = math.min(127, n.velocity + 10) end)
end, "Louder")
pmap("[", function()
  roll:change(function(n) n.velocity = math.max(1, n.velocity - 10) end)
end, "Softer")
pmap("gh", function() roll:audition() end, "Hear the pitch under the cursor")
-- The clips the roll edits (`daw.roll_clips`).
local function clip_here()
  -- The clip of the note under the cursor: one edited, or one shown behind.
  local _, _, part = roll:note_at(roll.pitch, roll.beat)
  if part then return part.id end
  local note = daw.roll_clips.context_at(roll.pitch, roll.beat)
  if note then return note.clip end
  daw.notify("no note under the cursor", "warn")
end
pmap("ga", function()
  local id = clip_here()
  if id then daw.roll_clips.activate(id) end
end, "Edit the clip of the note under the cursor: new notes go there")
pmap("gE", function()
  local id = clip_here()
  if id then daw.roll_clips.toggle(id) end
end, "Edit the clip of the note under the cursor too, or no longer")
pmap("gn", function(ctx) daw.roll_clips.cycle(ctx.count or 1) end, "The next clip edited becomes the active one")
pmap("gN", function(ctx) daw.roll_clips.cycle(-(ctx.count or 1)) end, "The clip edited before becomes the active one")
command("roll.tracks", function() daw.roll_clips.pick() end,
  { desc = "Choose whose notes the piano roll shows behind its own, and which clips it edits together" })
command("roll.only", function() daw.roll_clips.only() end, { desc = "Edit the piano roll's active clip alone" })
pmap("<Esc>", function()
  if chosen() then return daw.frontend.act.clear_note_selection() end
  daw.ui.focus("arrange")
end, "Let go of the chosen notes; back to the arrange view")

-- Diagnostics and language servers (daw.diagnostic, daw.lsp), on whatever
-- is under the cursor in each view: a note, a clip, a track, a strip, a
-- device or parameter. `K` means other things in these views, so asking
-- what is known about it is `gK`.
for _, v in ipairs({ "pianoroll", "arrange", "mixer", "devices" }) do
  map("]d", function(ctx) daw.diagnostic.jump(1, ctx.count) end, { view = v, desc = "Next diagnostic here", jump = true })
  map("[d", function(ctx) daw.diagnostic.jump(-1, ctx.count) end, { view = v, desc = "Previous diagnostic here", jump = true })
  map("gK", function() daw.lsp.show_hover() end, { view = v, desc = "What the diagnostics and language servers say about what is under the cursor" })
  map("<leader>ca", function() daw.lsp.code_actions() end, { view = v, desc = "Fixes and actions for what is under the cursor" })
end
command("diagnostics", function(ctx) daw.diagnostic.list(ctx.args[1] == "clip" and daw.ui.views.pianoroll.clip_id or nil) end,
  { desc = "List the diagnostics, grouped by what they are about, or (`diagnostics clip`) the piano roll's; Enter goes to one", complete = { "clip" } })
command("lsp", function(ctx) daw.lsp.command(ctx) end,
  { desc = "Language servers: `lsp info`, `lsp start|stop|restart [name]`, `lsp log`", complete = function() return daw.lsp.command_complete() end })

-- Piano roll: on a selection.
local function px(lhs, fn, desc)
  map(lhs, nil, { view = "pianoroll", mode = "x", desc = desc, operator = function(region, ctx)
    if roll:clip() then fn(editing(), region, ctx) end
  end })
end
px("x", function(clip, region, ctx) keymap.setreg(edit.roll.delete(clip, region), ctx.register) end, "Delete")
px("p", function(clip, region, ctx)
  local value = keymap.getreg(ctx.register)
  if not value then return end
  local replaced = edit.roll.delete(clip, region)
  roll:paste(value, true, ctx.count)
  keymap.setreg(replaced)
end, "Replace with the register")
px("<C-a>", function(clip, region, ctx)
  local by = ctx.count or 1
  edit.roll.each(clip, region, function(n) n.pitch = math.min(127, n.pitch + by) end)
end, "Up a semitone")
px("<C-x>", function(clip, region, ctx)
  local by = ctx.count or 1
  edit.roll.each(clip, region, function(n) n.pitch = math.max(0, n.pitch - by) end)
end, "Down a semitone")
px("]", function(clip, region) edit.roll.each(clip, region, function(n) n.velocity = math.min(127, n.velocity + 10) end) end, "Louder")
px("[", function(clip, region) edit.roll.each(clip, region, function(n) n.velocity = math.max(1, n.velocity - 10) end) end, "Softer")
px("+", function(clip, region)
  edit.roll.each(clip, region, function(n) n.length = n.length + daw.opt.note_grid end)
end, "Lengthen")
px("-", function(clip, region)
  edit.roll.each(clip, region, function(n) n.length = math.max(daw.opt.note_grid, n.length - daw.opt.note_grid) end)
end, "Shorten")

-- Piano roll: insert mode draws a note from the cursor (`daw.roll_draw`).
-- What is drawn is written when insert mode ends, as one undo step.
local function drawmap(lhs, fn, desc) map(lhs, fn, { view = "pianoroll", mode = "i", desc = desc }) end
local drawing = daw.roll_draw
for digit = 0, 9 do
  drawmap(tostring(digit), function() drawing.digit(digit) end, "A count for the next key")
end
for _, lhs in ipairs({ "l", "<Right>" }) do drawmap(lhs, function() drawing.grow(1) end, "The note a step longer") end
for _, lhs in ipairs({ "h", "<Left>" }) do drawmap(lhs, function() drawing.grow(-1) end, "The note a step shorter") end
for _, lhs in ipairs({ "k", "<Up>" }) do drawmap(lhs, function() drawing.pitch(1) end, "The note up a semitone") end
for _, lhs in ipairs({ "j", "<Down>" }) do drawmap(lhs, function() drawing.pitch(-1) end, "The note down a semitone") end
drawmap("K", function() drawing.pitch(12) end, "The note up an octave")
drawmap("J", function() drawing.pitch(-12) end, "The note down an octave")
drawmap("<CR>", function() drawing.next("legato") end, "Keep the note, and draw the next where it ends")
drawmap("<Space>", function() drawing.next("rest") end, "Keep the note, and draw the next after a step's rest")
drawmap("o", function() drawing.next("chord") end, "Keep the note, and draw another as long from where it starts, for a chord")
drawmap("<BS>", function() drawing.back() end, "Take back the note kept last, to draw it again")
drawmap("]", function() daw.opt.velocity = math.min(127, daw.opt.velocity + 10) end, "Louder notes")
drawmap("[", function() daw.opt.velocity = math.max(1, daw.opt.velocity - 10) end, "Softer notes")

-- Piano roll: insert mode the other way (`I`, or `daw.opt.roll_insert =
-- "keys"`). The middle row of the keyboard is the white keys from C and the
-- row above it the black ones, as on a piano. These keys come before the
-- drawing ones while that way is in use.
roll:key_scope("pianoroll.keys", 90, function() return keymap.mode == "i" and not drawing.active() end)
local function imap(lhs, rhs, desc) map(lhs, rhs, { view = "pianoroll.keys", mode = "i", desc = desc }) end
local layout = { "a", "w", "s", "e", "d", "f", "t", "g", "y", "h", "u", "j", "k", "o", "l", "p", ";" }
for semitone, key in ipairs(layout) do
  local name = (daw.music.name(60 + semitone - 1):gsub("%d+$", ""))
  imap(key, function() roll:enter(semitone - 1, true) end, "Enter " .. name .. " and step on")
  if key:match("%a") then
    imap(key:upper(), function() roll:enter(semitone - 1, false) end, "Enter " .. name .. " and stay, for a chord")
  end
end
for digit = 1, 9 do
  imap(tostring(digit), function() roll:set_step(digit * daw.opt.note_grid) end, "Notes " .. digit .. " grid steps long")
end
imap("<Space>", function() roll:step(1) end, "A rest: step on")
imap("<BS>", function() roll:backspace() end, "Step back, removing what was entered there")
imap("z", function() roll:set_octave(-1) end, "An octave lower")
imap("x", function() roll:set_octave(1) end, "An octave higher")
imap("]", function() daw.opt.velocity = math.min(127, daw.opt.velocity + 10) end, "Louder notes")
imap("[", function() daw.opt.velocity = math.max(1, daw.opt.velocity - 10) end, "Softer notes")
imap("<Left>", function() roll:step(-1) end, "Step back")
imap("<Right>", function() roll:step(1) end, "Step on")
imap("<Up>", move(0, 1), "Up a semitone")
imap("<Down>", move(0, -1), "Down a semitone")

-- Piano roll: snippets (runtime/lua/daw/snippet.lua). While one is active its
-- keys come first; otherwise each key does what it does everywhere else.
roll.layer("snippet", 40, function(p) daw.snippet.paint(p) end, function(clip_id) return daw.snippet.window_marks(clip_id) end)
command("snippet", function(ctx)
  local name = ctx.args[1]
  local region = daw.snippet.take_cmdline_selection()
  if name == nil then return daw.snippet.pick({ count = ctx.count, selection = region }) end
  local _, why = daw.snippet.expand(tostring(name), { count = ctx.count, selection = region })
  if why then daw.notify(why, "warn") end
end, {
  desc = "Expand a snippet at the piano roll's cursor: `snippet dominant`, `3snippet arp`; alone, choose one",
  complete = function()
    local out = {}
    for _, s in ipairs(daw.snippet.offered("pianoroll")) do out[#out + 1] = { text = s.name, desc = s.desc } end
    return out
  end,
})
-- While a snippet is active its keys come first, before a suggestion's and
-- before Escape leaves insert mode.
roll:key_scope("pianoroll.snippet", 40, function() return daw.snippet.active() ~= nil end)
local function smap(lhs, fn, desc)
  map(lhs, fn, { view = "pianoroll.snippet", mode = { "n", "i" }, desc = desc, repeatable = false })
end
smap("<Tab>", function() daw.snippet.jump(1) end, "The snippet's next choice")
smap("<S-Tab>", function() daw.snippet.jump(-1) end, "The snippet's choice before")
smap("<C-n>", function() daw.snippet.step(1) end, "The snippet's choice: its next value")
smap("<C-p>", function() daw.snippet.step(-1) end, "The snippet's choice: its value before")
smap("<C-y>", function() daw.snippet.finish() end, "End the snippet, keeping its notes")
smap("<Esc>", function() daw.snippet.finish() end, "End the snippet, keeping its notes")
map("<C-s>", function(ctx) daw.snippet.pick({ count = ctx.count }) end,
  { view = "pianoroll", mode = { "n", "i", "x" }, desc = "Choose a snippet to expand here", repeatable = false })

-- Piano roll: suggestions (`daw.complete`). Ctrl-Space asks the sources;
-- while a suggestion shows, its keys come first, in normal and insert mode.
local ni = { "n", "i" }
map("<C-Space>", function() daw.complete.request("manual") end, { view = "pianoroll", mode = ni, desc = "Suggest what comes next", repeatable = false })
local function cmap(lhs, fn, desc, modes)
  map(lhs, fn, { view = "pianoroll.complete", mode = modes or ni, desc = desc, repeatable = false })
end
cmap("<Tab>", function() daw.complete.accept() end, "Accept the suggestion")
cmap("<C-l>", function() daw.complete.accept(true) end, "Accept the suggestion's next note or chord")
cmap("<C-n>", function() daw.complete.select(1) end, "The next alternative")
cmap("<C-p>", function() daw.complete.select(-1) end, "The previous alternative")
for n = 1, 9 do
  cmap("<A-" .. n .. ">", function() daw.complete.select(n, true) end, "Alternative " .. n)
end
cmap("<C-e>", function() daw.complete.dismiss() end, "Dismiss the suggestion")
cmap("<Esc>", function() daw.complete.dismiss() end, "Dismiss the suggestion")
cmap("gh", function() daw.complete.audition() end, "Hear the suggestion, from a bar before", { "n" })

command("complete", function() daw.complete.request("manual") end, { desc = "Suggest what comes next in the piano roll" })
command("complete.accept", function(args) daw.complete.accept(args[1] == "next") end,
  { desc = "Accept the suggestion: `:complete.accept next` takes its next note or chord only" })
command("complete.dismiss", function() daw.complete.dismiss() end, { desc = "Dismiss the suggestion" })
command("complete.audition", function() daw.complete.audition() end, { desc = "Hear the suggestion through the track, from a bar before" })
command("complete.sources", function()
  local lines = {}
  for _, s in ipairs(daw.complete.list()) do
    lines[#lines + 1] = string.format("%-16s priority %-4d %s%s", s.name, s.priority, table.concat(s.views, ","), s.auto and "  auto" or "")
  end
  daw.notify(#lines > 0 and table.concat(lines, "\n") or "no completion sources: an extension adds them")
end, { desc = "List the completion sources" })

-- Sizes -----------------------------------------------------------------------
--
-- Every size is an option, so a configuration can set it: `track_height`
-- and `header_width` ("auto" fits them to the screen), and for a panel beside
-- the arrange view `<name>_width`, for one above or below it
-- `<name>_height` (0 shares the space): `devices_width`, `mixer_height`,
-- `pianoroll_height`.

daw.option.define("devices_width", 36)
daw.option.define("mixer_height", 12)
daw.option.define("pianoroll_height", 0)

--- A view's place in the layout: its node, and whether it sits in a row
--- beside others (it has a width) or in the column (a height).
local function layout_node(name)
  local function find(node, in_row)
    if node.view == name then return node, in_row end
    for _, child in ipairs(node) do
      local found, row = find(child, node.dir == "h")
      if found then return found, row end
    end
  end
  return find(daw.ui.layout, false)
end

daw.on("option.changed", function(e)
  local name, what = tostring(e.name):match("^(.+)_(%a+)$")
  if what ~= "width" and what ~= "height" then return end
  local node, in_row = layout_node(name)
  if not node or in_row ~= (what == "width") then return end
  local value = tonumber(e.value) or 0
  node.size = value > 0 and math.floor(value) or nil
end)

--- How many columns or rows a view has on screen now.
local function drawn_size(name, what)
  for _, rect in ipairs(daw.ui.arrange()) do
    if rect.name == name then return what == "width" and rect.w or rect.h end
  end
end

--- Change a size option by `by`, starting from what is drawn when it is 0.
local function resize(option, by, view, what, least)
  local now = tonumber(daw.opt[option]) or 0
  if now <= 0 then now = view and drawn_size(view, what) or 0 end
  daw.opt[option] = math.max(least or 1, now + by)
  daw.notify(string.format("%s %d", option, daw.opt[option]))
end

--- Whether the arrange view is the only window: then the size keys size
--- its tracks and headers, as there is no window to share with.
local function arrange_alone()
  local wins = daw.layout.focusable_windows()
  return daw.ui.focused == "arrange" and #wins == 1 and wins[1].view == "arrange"
end

command("view.height", function(ctx)
  local by = (tonumber(ctx.args[1]) or 1) * (ctx.count or 1)
  local name = daw.ui.focused
  local node, in_row = layout_node(name)
  if name ~= "arrange" and node and not in_row then
    return resize(name .. "_height", by, name, "height", 3)
  end
  if not arrange_alone() and daw.layout.resize(nil, "height", by, true) then return end
  -- From "auto", from the height the tracks have now.
  local now = tonumber(daw.opt.track_height)
  if not now or now <= 0 then now = daw.ui.views.arrange.geometry and daw.ui.views.arrange.geometry.th or 3 end
  daw.opt.track_height = util.clamp(now + by, 1, 12)
  daw.notify("track height " .. daw.opt.track_height)
end, { desc = "Taller tracks, or a taller panel: `view.height 2`, `view.height -1`" })
command("view.width", function(ctx)
  local by = (tonumber(ctx.args[1]) or 2) * (ctx.count or 1)
  local name = daw.ui.focused
  local node, in_row = layout_node(name)
  if name ~= "arrange" and node and in_row then return resize(name .. "_width", by, name, "width", 12) end
  if not arrange_alone() and daw.layout.resize(nil, "width", by, true) then return end
  local now = tonumber(daw.opt.header_width)
  if not now then now = daw.ui.views.arrange.geometry and daw.ui.views.arrange.geometry.hw or 24 end
  daw.opt.header_width = util.clamp(now + by, 8, 60)
  daw.notify("header width " .. daw.opt.header_width)
end, { desc = "A wider side panel, or track header in the arrange view: `view.width 4`, `view.width -2`" })
command("view.equal", function()
  if not arrange_alone() then return daw.layout.equalize() end
  daw.opt.track_height = "auto"
  daw.notify("track height fits the tracks to the screen")
end, { desc = "Windows of equal size; with the arrange view alone, track height back to automatic" })
command("view.maximize", function()
  if daw.layout.maximize() then
    daw.notify(daw.ui.focused .. " fills the screen; `Ctrl-w _` again puts the others back")
  end
end, { desc = "Give the focused window the whole tab, or put the others back" })

map("<C-w>+", "view.height 1", { desc = "Taller window; with the arrange view alone, taller tracks" })
map("<C-w>-", "view.height -1", { desc = "Shorter window; with the arrange view alone, shorter tracks" })
map("<C-w>=", "view.equal", { desc = "Windows of equal size; with the arrange view alone, track height automatic" })
map("<C-w><lt>", "view.width -2", { desc = "Narrower window; with the arrange view alone, track headers" })
map("<C-w>>", "view.width 2", { desc = "Wider window; with the arrange view alone, track headers" })
map("<C-w>_", "view.maximize", { desc = "Give the window the whole tab, or put the others back" })

-- Exact values ----------------------------------------------------------------
--
-- A prompt that takes a number, or `+2` and `-3` to step from the value now.

--- Pan as it is shown, L30 C R25, read back into -100..100.
local function read_pan(text)
  text = text:upper()
  if text == "C" then return 0 end
  local side, n = text:match("^([LR])%s*([%d%.]+)")
  if side then return (side == "L" and -1 or 1) * tonumber(n) end
  return tonumber((text:match("^([%+%-]?[%d%.]+)")))
end

command("track.volume.set", function()
  local track = need_track()
  if not track then return end
  daw.ui.ask_value({ label = track.name .. " volume", now = track.volume, unit = "dB", min = -150, max = 24 }, function(v)
    track.volume = v
    daw.notify(string.format("%s at %+.1f dB", track.name, track.volume))
  end)
end, { desc = "Type the track's volume in dB: a number, or +2 and -3 to step" })
command("track.pan.set", function()
  local track = need_track()
  if not track then return end
  daw.ui.ask_value({
    label = track.name .. " pan", now = util.round(track.pan * 100, 1), parse = read_pan, min = -100, max = 100,
    show = function(v) return daw.draw.pan_text(v / 100) end,
  }, function(v)
    track.pan = v / 100
    daw.notify(track.name .. " panned " .. daw.draw.pan_text(track.pan))
  end)
end, { desc = "Type the track's pan: L30, R25, C, or -100 to 100; +10 and -10 step" })
command("tempo.set", function()
  -- The tempo in force at the cursor: the change at or before it.
  local point = daw.tempo.point_at(cursor.beat)
  daw.ui.ask_value({ label = "Tempo", now = point.bpm, unit = "bpm", min = 1, max = 999 }, function(v)
    api.tempo_set(point.beat, v)
    daw.notify(string.format("tempo %g bpm from %s", v, point.beat == 0 and "the start" or "bar " .. daw.time.bar_of(point.beat)))
  end)
end, { desc = "Type the tempo in force at the cursor (the change at or before it) in bpm: a number, or +2 and -3 to step", label = "Set the tempo" })

--- Read a parameter's value as it is shown: a choice by name, or a number.
local function param_reader(p)
  return function(text)
    if #p.choices > 0 then
      local low = text:lower()
      for i, choice in ipairs(p.choices) do
        if tostring(choice):lower() == low then return i - 1 end
      end
      for i, choice in ipairs(p.choices) do
        if tostring(choice):lower():sub(1, #low) == low then return i - 1 end
      end
    end
    return tonumber((text:match("^([%+%-]?[%d%.]+)")))
  end
end

command("device.value", function()
  local device, row = daw.ui.views.devices:selected()
  if not (device and row and row.param) then return daw.notify("choose a parameter in the device panel first", "warn") end
  local p = row.param
  daw.ui.ask_value({
    label = p.name, now = api.device_get(row.device.id).params[p.key], min = p.min, max = p.max, parse = param_reader(p),
    show = function(v) return daw.frontend.format_value(p, v) end,
  }, function(v)
    api.device_set_param(row.device.id, p.key, v)
    daw.notify(p.name .. " " .. daw.frontend.format_value(p, api.device_get(row.device.id).params[p.key]))
  end)
end, { desc = "Type the value of the parameter chosen in the device panel, in its own unit" })

for _, name in ipairs({ "arrange", "mixer" }) do
  map("grv", "track.volume.set", { view = name, desc = "Type the volume" })
  map("grp", "track.pan.set", { view = name, desc = "Type the pan" })
end
map("grt", "tempo.set", { desc = "Type the tempo" })
map("c", "device.value", { view = "devices", desc = "Type the parameter's value" })
map("=", "device.value", { view = "devices", desc = "Type the parameter's value" })

-- Automation lanes as rows (see daw.lanes) ------------------------------------

--- What a new lane's first point starts from: the target's value now.
local function value_now(lane)
  return daw.lanes.value_at(lane:get(), cursor.beat)
end

local function clamp_to(l, v) return util.clamp(v, l.min, l.max) end

--- The lane the cursor's row is, or a warning.
local function cursor_lane()
  local id = cursor.lane_id()
  if not id then daw.notify("the cursor is not on an automation lane: `,aa` shows the track's lanes", "warn") end
  return id and daw.lane(id)
end

--- How near the cursor a point must be to be the one under it.
local function reach() return daw.opt.grid / 2 - 1e-9 end

command("lane.pick", function()
  local track = need_track()
  if not track then return end
  local have = {}
  for _, l in ipairs(api.lane_list(track.id)) do
    have[(l.target == "param" and l.device .. ":" .. l.param) or l.target] = true
  end
  local items = { { target = "volume", name = "Volume" }, { target = "pan", name = "Pan" } }
  for _, device in ipairs(track:devices()) do
    local d = device:get()
    for _, p in ipairs(d.param_info) do
      items[#items + 1] = { target = "param", device = d.id, param = p.key, name = d.name .. " › " .. p.name }
    end
  end
  daw.pick({
    title = "Automate on " .. track.name,
    items = items,
    format = function(item)
      local key = item.target == "param" and item.device .. ":" .. item.param or item.target
      return (have[key] and "● " or "  ") .. item.name
    end,
    on_choose = function(item)
      local lane = item.target == "param" and daw.device(item.device):automate(item.param) or track:automate(item.target)
      daw.lanes.open(track)
      cursor.set_track(track.id, lane.id)
      daw.ui.focus("arrange")
      daw.notify(daw.lanes.name(lane.id) .. " lane: `A` adds a point, `+` `-` `c` change it, `x` removes it")
    end,
  })
end, { desc = "Choose what to automate on the track (volume, pan, a device's parameter) and show its lane" })
command("lane.show", function(ctx)
  local which = ctx.args[1]
  if which == "all" or which == "none" then
    for _, id in ipairs(api.track_list()) do
      if which == "none" or #api.lane_list(id) > 0 then daw.lanes.open(id, which == "all") end
    end
    if which == "none" and cursor.lane_id() == nil then cursor.set_track(cursor.track_id()) end
    return
  end
  local track = need_track()
  if not track then return end
  if #api.lane_list(track.id) == 0 then
    return daw.notify(track.name .. " has no automation yet: `,al` chooses what to automate", "warn")
  end
  local now = daw.lanes.toggle(track)
  cursor.set_track(track.id)
  daw.notify(track.name .. (now and ": lanes shown" or ": lanes hidden"))
end, { desc = "Show the track's automation lanes as rows under it, or hide them: `lane.show`, `lane.show all`, `lane.show none`", complete = function() return { "all", "none" } end })
command("lane.rows", function()
  local track = need_track()
  if not track then return end
  local now = daw.frontend.act.lane_rows(track.id)
  daw.notify(track.name .. (now and ": lanes shown as rows" or ": lanes hidden"))
end, { desc = "Show the track's automation lanes as rows under it, making one for its fader if it has none; or hide them" })
command("lane.point.add", function()
  local lane = cursor_lane()
  if not lane then return end
  local l = lane:get()
  local v = value_now(lane)
  lane:add(cursor.beat, v)
  daw.notify(string.format("%s: a point at %s, %s", daw.lanes.name(l), daw.time.format(cursor.beat), daw.lanes.format(l, v)))
end, { desc = "Add an automation point at the cursor, at the curve's value there", label = "Add a point" })
command("lane.point.nudge", function(ctx)
  local lane = cursor_lane()
  if not lane then return end
  local l = lane:get()
  local at = daw.lanes.point_at(l.id, cursor.beat, reach())
  if not at then return daw.notify("no point under the cursor: `A` adds one", "warn") end
  local by = (tonumber(ctx.args.by) or 1) * (ctx.count or 1) * daw.lanes.step(l)
  local v
  daw.lanes.edit(l.id, function(points)
    points[at][2] = clamp_to(l, points[at][2] + by)
    v = points[at][2]
  end)
  daw.notify(daw.lanes.name(l) .. " " .. daw.lanes.format(l, v))
end, { desc = "Raise or lower the automation point under the cursor: `lane.point.nudge by=-1`", label = "Change a point" })
command("lane.point.set", function()
  local lane = cursor_lane()
  if not lane then return end
  local l = lane:get()
  local at, point = daw.lanes.point_at(l.id, cursor.beat, reach())
  local beat = point and point[1] or cursor.beat
  local now = point and point[2] or value_now(lane)
  local opts = { label = daw.lanes.name(l), now = now, min = l.min, max = l.max }
  local scale = 1
  if l.target == "volume" then
    opts.unit = "dB"
  elseif l.target == "pan" then
    scale = 100
    opts.now, opts.min, opts.max = util.round(now * 100, 1), -100, 100
    opts.parse = read_pan
    opts.show = function(v) return daw.draw.pan_text(v / 100) end
  else
    local p = daw.lanes.param_of(l)
    if p then
      opts.parse = param_reader(p)
      opts.show = function(v) return daw.frontend.format_value(p, v) end
    end
  end
  daw.ui.ask_value(opts, function(v)
    v = v / scale
    daw.lanes.edit(l.id, function(points)
      if at then points[at][2] = v else points[#points + 1] = { beat, v } end
    end)
  end)
end, { desc = "Type the value of the automation point under the cursor, or of a new one there", label = "Set a point" })
command("lane.point.remove", function()
  local lane = cursor_lane()
  if not lane then return end
  local at = daw.lanes.point_at(lane.id, cursor.beat, reach())
  if not at then return daw.notify("no point under the cursor", "warn") end
  daw.lanes.edit(lane.id, function(points) table.remove(points, at) end)
end, { desc = "Remove the automation point under the cursor", label = "Remove a point" })

--- The points of the cursor's lane within a selection, by index: from one
--- end to the other, both included, since a point is an instant.
local function points_in(lane_id, region)
  local c0, c1 = region.c0, region.c1
  -- A selection not yet stretched is the cursor's own beat.
  if region.unstretched then c1 = c0 end
  local out = {}
  for i, p in ipairs(api.lane_points(lane_id)) do
    if p[1] >= c0 - 1e-9 and p[1] <= c1 + 1e-9 then out[#out + 1] = i end
  end
  return out
end

--- Next (`dir` 1) or previous point of the cursor's lane.
local function to_point(dir, n)
  local id = cursor.lane_id()
  if not id then return end
  for _ = 1, n or 1 do
    local to
    for _, p in ipairs(api.lane_points(id)) do
      if dir > 0 and p[1] > cursor.beat + 1e-9 and not to then to = p[1] end
      if dir < 0 and p[1] < cursor.beat - 1e-9 then to = p[1] end
    end
    if not to then return end
    cursor.set_beat(to)
  end
end

local function lmap(lhs, rhs, desc, opts) map(lhs, rhs, util.merge({ view = "arrange.lane", desc = desc }, opts)) end
lmap("A", "lane.point.add", "Add a point at the cursor, at the curve's value")
lmap("+", "lane.point.nudge by=1", "Raise the point under the cursor")
lmap("-", "lane.point.nudge by=-1", "Lower the point under the cursor")
lmap("c", "lane.point.set", "Type the value of the point under the cursor")
lmap("=", "lane.point.set", "Type the value of the point under the cursor")
lmap("x", "lane.point.remove", "Remove the point under the cursor")
lmap("w", function(ctx) to_point(1, ctx.count) end, "Next point", motion)
lmap("b", function(ctx) to_point(-1, ctx.count) end, "Previous point", motion)
local function lx(lhs, fn, desc)
  map(lhs, nil, { view = "arrange.lane", mode = "x", desc = desc, operator = function(region, ctx)
    local id = cursor.lane_id()
    if id then fn(id, region, ctx) end
  end })
end
local function remove_points(id, region)
  local gone = {}
  for _, i in ipairs(points_in(id, region)) do gone[i] = true end
  daw.lanes.edit(id, function(points)
    for i = #points, 1, -1 do
      if gone[i] then table.remove(points, i) end
    end
  end)
end
lx("x", remove_points, "Remove the points selected")
lx("d", remove_points, "Remove the points selected")
local function move_points(steps) return function(id, region, ctx)
  local by = steps * (ctx.count or 1) * daw.opt.grid
  local chosen = {}
  for _, i in ipairs(points_in(id, region)) do chosen[i] = true end
  daw.lanes.edit(id, function(points)
    local landed = {}
    for i, p in ipairs(points) do
      if chosen[i] then
        p[1] = math.max(0, p[1] + by)
        landed[#landed + 1] = p[1]
      end
    end
    -- A point moved onto another's beat takes its place.
    for i = #points, 1, -1 do
      if not chosen[i] then
        for _, beat in ipairs(landed) do
          if math.abs(points[i][1] - beat) < 1e-9 then
            table.remove(points, i)
            break
          end
        end
      end
    end
  end)
end end
lx("L", move_points(1), "Move the points selected later")
lx("H", move_points(-1), "Move the points selected earlier")
local function nudge_points(sign) return function(id, region, ctx)
  local l = api.lane_get(id)
  local by = sign * (ctx.count or 1) * daw.lanes.step(l)
  local chosen = {}
  for _, i in ipairs(points_in(id, region)) do chosen[i] = true end
  daw.lanes.edit(id, function(points)
    for i, p in ipairs(points) do
      if chosen[i] then p[2] = clamp_to(l, p[2] + by) end
    end
  end)
end end
lx("+", nudge_points(1), "Raise the points selected")
lx("-", nudge_points(-1), "Lower the points selected")
amap("<leader>cf", "clip.fade", "Fade the clip in and out: type the lengths")
for _, name in ipairs({ "arrange", "mixer" }) do
  map("grC", "track.color.pick", { view = name, desc = "Choose the track's colour" })
end
amap("<leader>al", "lane.pick", "Choose what to automate, and show its lane")
amap("<leader>aa", "lane.show", "Show or hide the track's automation lanes")
amap("<leader>aA", "lane.show all", "Show every track's automation lanes")

-- Pickers --------------------------------------------------------------------
--
-- `daw.pick` chooses from a list by typing a few letters of what is wanted.
-- Every source in `daw.pick.sources` has a command, `:pick <name>`, and the
-- built-in ones a command of their own and a key under `<leader>f`.

command("pick", function(ctx)
  local name = ctx.args[1] and tostring(ctx.args[1]) or "pickers"
  if not daw.pick.sources[name] then return daw.notify("no picker `" .. name .. "`; `:pick` lists them", "warn") end
  daw.pick(name, { query = ctx.args.query and tostring(ctx.args.query) or nil })
end, { desc = "Choose from a list: `pick tracks`, `pick devices query=reverb`; with no name, every picker", complete = { "pickers" } })
command("pick.resume", function() daw.pick.resume() end, { desc = "Open the last picker again, with what was typed" })

local pick_keys = {
  { "commands", "c", "Run a command" },
  { "keys", "k", "Find a key mapping for this view" },
  { "tracks", "t", "Go to a track" },
  { "clips", "l", "Go to a clip" },
  { "devices", "a", "Add a device or plugin to the track" },
  { "track_devices", "d", "Show a device of the track" },
  { "marks", "m", "Go to a mark" },
  { "registers", "r", "Paste a register or play a macro" },
  { "messages", "n", "Earlier messages" },
  { "files", "f", "Open a project or import audio from here" },
  { "options", "o", "Set an option" },
  { "pickers", "p", "Every picker" },
}
for _, entry in ipairs(pick_keys) do
  local name, key, desc = entry[1], entry[2], entry[3]
  command("pick." .. name, function(ctx)
    daw.pick(name, { query = ctx.args[1] and table.concat(ctx.args, " ") or nil })
  end, { desc = desc .. ", in a picker" })
  map("<leader>f" .. key, "pick." .. name, { desc = desc })
end
map("<leader>fR", "recent", { desc = "Open a recent project" })
map("<leader>f.", "pick.resume", { desc = "The last picker again" })
map("<leader><leader>", "pick.commands", { desc = "Run a command" })

-- With no argument, `device.add` chooses from every device in a picker.
do
  local add_by_name = daw.commands.get("device.add")
  command("device.add", function(ctx)
    if ctx.args[1] then return add_by_name.run(ctx) end
    if need_track() then daw.pick("devices") end
  end, { desc = add_by_name.desc .. "; with no name, choose in a picker", complete = add_by_name.complete })
end


-- A plugin runs in a process of its own; when that stops, the session goes
-- on without it and says so.
daw.on("device.stopped", function(event)
  local track = pcall(api.track_get, event.track) and api.track_get(event.track).name or "a track"
  if event.loading then
    return daw.notify(string.format("%s on %s could not be loaded: %s. It is passed over and keeps its saved state; `:device.restart` tries again.",
      event.name, track, event.reason), "error")
  end
  daw.notify(string.format("%s on %s stopped working: %s. The track plays on without it; `:device.restart` starts it again.",
    event.name, track, event.reason), "error")
end)
command("plugins.rescan", function(ctx)
  local name = ctx.args[1] and tostring(ctx.args[1]) or nil
  local notes = api.plugins_rescan(name)
  if not notes then return daw.notify("plugins are not loaded in this session", "warn") end
  for _, note in ipairs(notes) do daw.api.log("plugin scan: " .. note) end
  daw.emit("plugins.scanned", { notes = notes, name = name })
  daw.notify(string.format("looked into %s again%s", name and ("plugin files matching “" .. name .. "”") or "every plugin file",
    #notes > 0 and (": " .. #notes .. " could not be used (see the log)") or ""))
end, { desc = "Look into plugin files again, including ones skipped because they failed: `plugins.rescan`, `plugins.rescan surge`" })
-- A device whose output holds NaN or infinity is silenced where it is, once said.
daw.on("device.invalid", function(event)
  local track = pcall(api.track_get, event.track) and api.track_get(event.track).name or "a track"
  daw.notify(string.format("%s on %s put out invalid numbers (NaN or infinity); its output is replaced by silence",
    event.name, track), "error")
end)
