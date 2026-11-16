-- What a graphical frontend needs to draw the project, in one call.
--
-- A frontend polls `daw.frontend.state(known)` many times a second. The
-- answer always holds what moves on its own (transport position, meters). The
-- project itself is only included when it has changed since revision `known`,
-- so an idle project costs almost nothing to watch. Waveforms are a separate
-- call, `daw.frontend.peaks(clip)`, made only when a clip's `waveform` changes.
local api = daw.api
local M = { revision = 0, max_params = 16, peak_points = 128, preview_notes = 2000 }

for _, event in ipairs({ "changed", "transport.changed", "cursor.changed", "project.loaded", "engine.started", "option.changed", "lanes.changed" }) do
  daw.on(event, function() M.revision = M.revision + 1 end)
end

-- Values as text in their unit, and sliders on a log scale for frequencies
-- and times: see `daw.params`.
local function format_value(param, value) return daw.params.format(param, value) end
M.format_value = format_value

local function device_state(id)
  local d = api.device_get(id)
  local params = {}
  -- The device's own parameters, those the user chose to show first (see
  -- `daw.fx.card_params`); the host's wet/dry mix and gain are on the header.
  local own = daw.fx.card_params(d)
  for i = 1, math.min(M.max_params, #own) do
    local p = own[i]
    local value = d.params[p.key]
    params[i] = {
      key = p.key, name = p.name, text = format_value(p, value),
      -- Sliders work on 0..1 whatever the parameter's own range is.
      value = daw.params.fraction(p, value),
      min = p.min, max = p.max,
      -- Where the slider rests, for a double click.
      default = daw.params.fraction(p, p.default),
    }
  end
  return {
    id = d.id, name = d.name, format = d.format, bypass = d.bypass, params = params,
    more = #own - #params,
    -- The wet share, 0 to 1, and the output gain in dB.
    wet = (d.params.fx_wet or 100) / 100, gain = d.params.fx_gain or 0,
    -- "open", "closed", or "" for a device with no window of its own.
    editor = d.editor or "",
    -- Why a plugin has stopped working, or "".
    stopped = d.stopped or (d.missing and "it is not installed or did not load") or "",
    -- The preset last loaded or saved, or "".
    preset = type(d.meta) == "table" and d.meta.preset or "",
    -- "running", "loading", "stopped", "offline" or "missing".
    status = d.status or "running",
    -- Whether it can listen to a side-chain, and the track it listens to
    -- ("" for its own input); `sidechain_menu` lists the choices.
    keyed = (d.ports and d.ports.sidechain) or d.sidechain ~= nil,
    sidechain = daw.routes.sidechain_text(d) or "",
  }
end

--- What extensions add to the frontend's right-click menus: on a clip, on a
--- track's header, on an empty stretch of the timeline.
---
---   table.insert(daw.frontend.menus.clip, { label = "Open as notation", command = "notation.open", only = "midi" })
---   table.insert(daw.frontend.menus.timeline, { label = "New drum track", run = function(track, beat) ... end })
---
--- `command` is a command line and `run` a function given the clip or track
--- and the beat that was clicked; either runs with the cursor put there
--- first. `only` keeps a clip's entry to "midi" or "audio" clips.
M.menus = { clip = {}, track = {}, timeline = {} }

local function menus()
  local out = {}
  for kind, entries in pairs(M.menus) do
    local list = {}
    for i, entry in ipairs(entries) do list[i] = { label = entry.label, only = entry.only or "" } end
    out[kind] = list
  end
  return out
end

local mode_names = { n = "NORMAL", c = "COMMAND", i = "INSERT", o = "PENDING" }
local visual_names = { v = "VISUAL", V = "V-LINE", b = "V-BLOCK", clips = "CLIPS" }

--- Where the keyboard is: the mode, what is half typed, the prompt or the
--- message, the selection, and the cursors of the panels. Small, and sent
--- every time, because a key press changes it without changing the project.
local function modal()
  local keymap, ui = daw.keymap, daw.ui
  local out = {
    mode = keymap.mode, pending = keymap.pending(), recording = keymap.recording() or "",
    name = keymap.mode == "x" and keymap.visual and visual_names[keymap.visual.kind]
      or mode_names[keymap.mode] or keymap.mode:upper(),
    focused = ui.focused, mixer = ui.visible("mixer"),
    float = ui.float and (ui.float.title or ui.float.name) or nil,
    selection = keymap.selection(),
    -- A render in the background: { path, fraction, seconds, cancelling }.
    render = daw.api.render_status(),
    -- What `:learn` is waiting to bind a controller to, in words.
    learning = daw.learn and daw.learn.learning and daw.learn.target_name(daw.learn.learning) or nil,
  }
  -- Chosen clips are told one by one, with the clips (`selected`).
  if out.selection then out.selection.clips = nil end
  local prompt = require("daw.views.cmdline").state()
  if prompt then
    out.prompt = prompt
  elseif ui.message then
    out.message = { text = ui.message.text:match("^[^\n]*"), level = ui.message.level }
  end
  if daw.opt.hints then
    local hints, title = keymap.hints()
    if hints then out.hints = { title = title, items = hints } end
  end
  local roll = ui.views.pianoroll
  local clip = ui.visible("pianoroll") and roll:clip()
  if clip then
    out.roll = {
      clip = clip.id, pitch = roll.pitch, beat = roll.beat, step = roll:step_length(), octave = daw.opt.octave,
      snap = daw.opt.note_snap,
      -- The notes chosen with the pointer, by place.
      selected = M.chosen_notes(clip.id),
      -- The chosen notes in words: how many, and the stretch they cover.
      chosen = M.chosen_text(clip.id),
      step_input = M.step_input(),
    }
  end
  local under = daw.cursor.clip()
  out.clip = ui.focused == "arrange" and under and under.id or nil
  -- Views that paint, open in windows of their own.
  out.windows = daw.canvas.windows()
  out.menus = menus()
  if ui.focused == "devices" then
    -- The row the keyboard is on, as a device of the track and one of its
    -- parameters (0 for the device's own line).
    local panel = ui.views.devices
    local rows = panel:rows()
    panel.row = daw.util.clamp(panel.row, 1, math.max(1, #rows))
    local row = rows[panel.row]
    if row then
      out.device, out.param = row.device.index, 0
      for i, p in ipairs(row.device.param_info) do
        if row.param and p.key == row.param.key then out.param = i end
      end
    end
  end
  return out
end

--- The floating window that is open (help, a list, a picker), drawn as
--- text `width` columns wide: its title and its lines. Nil when there is none.
function M.float(width, height)
  if not daw.ui.float then return nil end
  local lines = api.ui_snapshot(width, height)
  local rect
  for _, r in ipairs(daw.ui.rects) do
    if r.name == daw.ui.float.name then rect = r end
  end
  if not rect then return nil end
  local out = {}
  for y = rect.y, rect.y + rect.h - 1 do
    local cells = {}
    for ch in (lines[y + 1] or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do cells[#cells + 1] = ch end
    out[#out + 1] = table.concat(cells, "", rect.x + 1, math.min(#cells, rect.x + rect.w))
  end
  return { title = daw.ui.float.title or daw.ui.float.name, lines = out }
end

--- The stretch of a lane's range that is worth drawing it over: a fader's
--- travel for volume, the whole range for anything else.
function M.lane_span(lane)
  if lane.target == "volume" then return -60, 6 end
  return lane.min, lane.max
end

--- What a lane moves, in words: `Volume`, `Pan`, `Synth · cutoff`.
function M.lane_name(lane)
  if lane.target == "volume" then return "Volume" end
  if lane.target == "pan" then return "Pan" end
  local ok, device = pcall(api.device_get, lane.device)
  if not ok then return tostring(lane.param) end
  for _, p in ipairs(device.param_info) do
    if p.key == lane.param then return device.name .. " · " .. p.name end
  end
  return device.name .. " · " .. tostring(lane.param)
end

--- One clip with its notes and controller moves, for a piano roll, and the
--- name and colour of the track it is on. Nil when the clip is gone.
function M.clip(id)
  local ok, clip = pcall(api.clip_get, id)
  if not ok then return nil end
  -- Notes hidden by a trim of the clip's edges are left out. Those before
  -- its start come first in the clip's order: `hidden` says how many, so
  -- that the place of the notes given is their index plus it.
  clip.notes, clip.hidden = {}, 0
  for _, n in ipairs(clip.kind == "midi" and api.clip_notes(id) or {}) do
    if n.start < 0 then
      clip.hidden = clip.hidden + 1
    elseif n.start < clip.length then
      clip.notes[#clip.notes + 1] = n
    end
  end
  clip.controls = {}
  for _, move in ipairs(clip.kind == "midi" and api.clip_controls(id) or {}) do
    if move.start >= 0 and move.start < clip.length then clip.controls[#clip.controls + 1] = move end
  end
  local track = api.track_get(clip.track)
  clip.track_name, clip.color = track.name, daw.draw.track_colour(track)
  -- The notes of the track's other MIDI clips that sound during this one,
  -- with their starts in this clip's beats, for drawing faintly.
  clip.ghosts = {}
  for _, other in ipairs(clip.kind == "midi" and api.clip_list(clip.track) or {}) do
    if other.id ~= id and other.kind == "midi" and other.start < clip.start + clip.length and other.start + other.length > clip.start then
      for _, n in ipairs(api.clip_notes(other.id)) do
        local at = other.start + n.start - clip.start
        if n.start < other.length and at < clip.length and at + n.length > 0 and #clip.ghosts < M.preview_notes then
          clip.ghosts[#clip.ghosts + 1] = { pitch = n.pitch, start = at, length = math.min(n.length, other.length - n.start), velocity = n.velocity }
        end
      end
    end
  end
  return clip
end

--- A clip's takes as its take lanes show them: `{ name, key }` each, `key`
--- changing exactly when what the take plays does. Nil for a clip
--- without takes, which has nothing in the lanes.
function M.take_rows(clip)
  local takes = daw.takes.of(clip)
  if not takes then return nil end
  local out = {}
  local seconds = clip.kind == "audio" and daw.time.seconds(clip.length, clip.start) or 0
  for i, entry in ipairs(takes.list) do
    local key
    if clip.kind == "audio" then
      local c = daw.takes.content(clip, i)
      key = string.format("%s|%.17g|%.17g|%.17g|%.17g", c.file, c.offset, c.gain, clip.length, seconds)
    else
      key = string.format("%s|%d|%d|%d|%.17g", tostring(clip.stamp), takes.active, i, #(entry.notes or {}), clip.length)
    end
    out[i] = { name = entry.name or ("take " .. i), key = key }
  end
  return out
end

--- What take `take` of a clip plays, for the picture in its take lane: a
--- waveform as `M.peaks` gives one at `points` points for sound, the notes
--- as `M.preview` gives them for MIDI.
function M.take_preview(id, take, points)
  local ok, clip = pcall(api.clip_get, id)
  if not ok then return {} end
  local c = daw.takes.content(clip, take)
  local flat = {}
  if clip.kind == "audio" then
    points = daw.util.clamp(math.floor(points or M.peak_points), 8, 4096)
    local seconds = daw.time.seconds(clip.length, clip.start)
    local got, peaks = pcall(api.media_peaks, c.file, c.offset, seconds, points)
    local gain = 10 ^ ((c.gain or 0) / 20)
    for i, p in ipairs(got and peaks or {}) do
      flat[3 * i - 2], flat[3 * i - 1], flat[3 * i] = p[1] * gain, p[2] * gain, p[3] * gain
    end
    return flat
  end
  local i = 0
  for _, n in ipairs(c.notes) do
    if i >= M.preview_notes then break end
    if n.start >= 0 and n.start < clip.length then
      i = i + 1
      flat[3 * i - 2], flat[3 * i - 1], flat[3 * i] = n.start, n.length, n.pitch
    end
  end
  return flat
end

--- A MIDI clip's notes for the small picture inside it: one flat list
--- { start1, length1, pitch1, start2, ... }, at most `M.preview_notes` notes.
--- Fetched when the clip's `stamp` in `state` changes.
function M.preview(id)
  local flat = {}
  local ok, notes = pcall(api.clip_notes, id)
  local length = ok and api.clip_get(id).length or 0
  local i = 0
  for _, n in ipairs(ok and notes or {}) do
    if i >= M.preview_notes then break end
    -- Notes hidden by a trim of the clip's edges are not drawn.
    if n.start >= 0 and n.start < length then
      i = i + 1
      flat[3 * i - 2], flat[3 * i - 1], flat[3 * i] = n.start, n.length, n.pitch
    end
  end
  return flat
end

function M.state(known)
  M.polled = api.now() -- someone is looking: see `daw.fx.interactive`
  local t, e = api.transport_get(), api.engine_get()
  -- The tracks that are drawn: those folded away into a group are left out.
  local ids = daw.groups.rows()
  ids[#ids + 1] = 0 -- the master track goes last
  -- Both sides of every track's meter, one after the other.
  local levels = {}
  for i, id in ipairs(ids) do
    levels[2 * i - 1], levels[2 * i] = api.track_meter(id)
  end
  -- What arrives at each track's audio input, armed or not: 0 without one.
  local inputs, device_levels = {}, daw.audio.levels()
  for i, id in ipairs(ids) do
    inputs[i] = id ~= 0 and daw.audio.level(api.track_get(id), device_levels) or 0
  end
  local num, den = daw.tempo.signature_at(t.position)
  local out = {
    revision = M.revision, playing = t.playing, recording = t.take ~= nil, position = t.position,
    -- Beats of a count-in still to be counted before the take starts; 0 for none.
    counting = t.counting or 0,
    time = daw.time.format(t.position), clock = daw.time.clock(t.position),
    -- The tempo and signature where the playhead is.
    tempo = math.floor(daw.tempo.at(t.position) * 100 + 0.5) / 100, signature = num .. "/" .. den,
    cpu = e.cpu, levels = levels, inputs = inputs, modal = modal(), armed = t.recording,
    -- What went wrong while playing (see `:engine.status`).
    xruns = e.xruns, late_blocks = e.late_blocks, midi_dropped = e.midi_dropped,
    record_dropped = e.record_dropped, devices_stopped = e.devices_stopped,
  }
  if known == M.revision then return out end

  local p = api.project_get()
  out.project = {
    name = p.name, modified = p.modified, tempo = out.tempo, bar = daw.time.bar(), length = p.length,
    signature = out.signature, loop_enabled = t.loop_enabled, loop_start = t.loop_start,
    loop_end = t.loop_end, metronome = t.metronome, backend = e.backend, sample_rate = e.sample_rate,
    -- Recording only between two points, and the bars counted before a take.
    punch_enabled = t.punch_enabled, punch_start = t.punch_start, punch_end = t.punch_end,
    count_in = t.count_in,
    grid = daw.opt.grid, note_grid = daw.opt.note_grid, threads = e.threads, xruns = e.xruns,
    -- The engine in a few words: backend, output device, sample rate.
    engine = daw.audio.summary(),
  }
  -- Bar and beat lines from the tempo map, well past the end and the last
  -- change, and the tempo and signature changes to flag on the ruler.
  out.project.marks = daw.tempo.marks(0, math.huge)
  -- Markers and regions (`daw.markers`): { id, beat, name, length } each.
  out.project.markers = {}
  for i, m in ipairs(daw.markers and daw.markers.list() or {}) do
    out.project.markers[i] = { id = m.id, beat = m.beat, name = daw.markers.label(m), length = m.length or 0 }
  end
  local last = math.max(p.length or 0, t.loop_end or 0)
  for _, mark in ipairs(out.project.marks) do last = math.max(last, mark.beat) end
  local stop = daw.time.bar_start(daw.time.bar_of(last) + 17)
  out.project.lines = {}
  local lines = daw.tempo.lines(0, stop)
  for i, line in ipairs(lines) do
    local next_beat = lines[i + 1] and lines[i + 1].beat or line.beat + (line.beat - (lines[i - 1] and lines[i - 1].beat or line.beat - 1))
    out.project.lines[i] = {
      beat = line.beat, bar = line.bar, index = line.index, next = next_beat,
      label = line.index == 0 and tostring(line.bar) or "", place = line.bar .. "." .. (line.index + 1),
    }
  end
  out.selected = daw.cursor.track_id() or -1
  out.cursor = daw.cursor.beat
  out.tracks, out.clips, out.devices = {}, {}, {}
  local chosen_set = {}
  for _, id in ipairs(M.chosen_clips()) do chosen_set[id] = true end
  for i, id in ipairs(ids) do
    local track = api.track_get(id)
    -- What the track's sound goes through, in a few words.
    local chain = {}
    for j, device in ipairs(track.devices or {}) do chain[j] = api.device_get(device).name end
    local to = track.output and select(2, pcall(api.track_get, track.output))
    out.tracks[i] = {
      id = id, name = track.name, volume = track.volume, pan = track.pan, mute = track.mute,
      solo = track.solo, armed = track.armed, master = track.master, lanes = {},
      input = track.input, monitor = track.monitor,
      -- What the track takes in, in words (`UR22mkII · 1/2`), or nil.
      input_label = not track.master and daw.audio.label(track) or nil,
      -- The colour everything of the track's is drawn in, as in the terminal.
      color = daw.draw.track_colour(track, i), chain = table.concat(chain, " › "),
      output = type(to) == "table" and to.name or nil,
      -- Groups: how many groups the track is inside, whether it is one,
      -- whether it is folded, and how many tracks it holds.
      depth = id ~= 0 and daw.groups.depth(id) or 0,
      group = id ~= 0 and daw.groups.is_group(id) or false,
      folded = id ~= 0 and daw.groups.folded(id) or false,
      members = id ~= 0 and #daw.groups.members(id) or 0,
      -- How tall it is drawn, as a share of the zoom's height.
      height = track.height or 1,
      -- "read", "touch", "latch", "write" or "off".
      automation = track.automation or "read",
      -- The lanes shown as rows of their own under the track, by id.
      lane_rows = {},
      -- How many take lanes it shows under its clips, above those rows.
      take_rows = id ~= 0 and daw.takes.lane_count(id) or 0,
    }
    for j, lane in ipairs(id ~= 0 and daw.lanes.shown(id) or {}) do out.tracks[i].lane_rows[j] = lane.id end
    -- Points are in the target's own units; `min` and `max` give its range,
    -- `lo` and `hi` the part of it a frontend draws the lane over, and
    -- `name` says what the lane moves.
    for j, lane in ipairs(api.lane_list(id)) do
      local lo, hi = M.lane_span(lane)
      out.tracks[i].lanes[j] = {
        id = lane.id, target = lane.target, device = lane.device, param = lane.param,
        enabled = lane.enabled, min = lane.min, max = lane.max, points = api.lane_points(lane.id),
        lo = lo, hi = hi, name = M.lane_name(lane),
      }
    end
    local take_lanes = out.tracks[i].take_rows > 0
    for _, clip in ipairs(api.clip_list(id)) do
      out.clips[#out.clips + 1] = {
        -- In take lanes: each take's name, and what changes exactly when
        -- its picture does (fetch `M.take_preview` again then).
        take_rows = take_lanes and M.take_rows(clip) or nil,
        id = clip.id, track = i - 1, start = clip.start, length = clip.length,
        name = clip.offline and ("offline · " .. clip.name) or clip.name,
        midi = clip.kind == "midi", muted = clip.muted,
        -- How many takes it has (1 without others), and which plays.
        takes = select(1, daw.takes.count(clip)), take = select(2, daw.takes.count(clip)),
        -- Chosen with the pointer (`M.chosen_clips`).
        selected = chosen_set[clip.id] or false,
        -- An audio clip's fades, in beats, and its gain in dB.
        fade_in = clip.fade_in, fade_out = clip.fade_out, gain = clip.gain,
        -- Its file is missing: silent until relinked. The name says so too.
        offline = clip.offline or nil,
        -- Changes exactly when the clip's notes do: fetch `M.preview` again then.
        stamp = clip.stamp and string.format("%.0f|%.17g", clip.stamp, clip.length) or nil,
        -- Changes exactly when the clip's waveform does: fetch `M.peaks` again then.
        waveform = clip.kind == "audio"
          and string.format("%s|%.17g|%.17g|%.17g|%.17g", clip.file, clip.offset, clip.length, clip.gain, daw.time.seconds(clip.length, clip.start)) or nil,
      }
    end
  end
  if out.selected >= 0 then
    for i, id in ipairs(api.track_get(out.selected).devices) do out.devices[i] = device_state(id) end
    out.routing = M.routing(out.selected)
  end
  if known < 0 then
    out.kinds = {}
    for i, info in ipairs(api.device_types()) do out.kinds[i] = info.kind end
  end
  return out
end

--- Save the project under a new name: choose the directory from a list,
--- then type the file's name. `after` runs once it is saved.
function M.save_as(after)
  daw.pick.file({
    title = "Save the project in",
    directory = true,
    on_choose = function(dir)
      local p = api.project_get()
      local name = p.path and p.path:match("([^/]+)$") or ((p.name ~= "" and p.name or "song") .. ".json")
      daw.ui.input({ prompt = "File name: ", text = name }, function(typed)
        if typed == "" then return end
        if not typed:match("%.[%w]+$") then typed = typed .. ".json" end
        daw.notify("saved " .. daw.project.save(dir .. "/" .. typed))
        if after then after() end
      end)
    end,
  })
end

--- Whether closing now would lose anything: { modified, name, path }.
function M.closing()
  local p = api.project_get()
  return { modified = p.modified, name = p.name, path = p.path }
end

--- What the render dialog starts from: the file a render would go to, the
--- ranges that can be rendered (`{ name, label }`: the song, the loop, the
--- selection, every region), and the engine's sample rate.
function M.render_dialog()
  local t = api.transport_get()
  local ranges = { { name = "song", label = "The whole song" } }
  if t.loop_end > t.loop_start then
    ranges[#ranges + 1] = { name = "loop", label = string.format("The loop (%s – %s)", daw.time.format(t.loop_start), daw.time.format(t.loop_end)) }
  end
  local sel = daw.keymap.selection()
  if sel and sel.c0 and sel.c1 and sel.c1 > sel.c0 then ranges[#ranges + 1] = { name = "selection", label = "The selection" } end
  for _, r in ipairs(daw.markers.regions()) do
    ranges[#ranges + 1] = { name = "region:" .. r.id, label = "Region “" .. daw.markers.label(r) .. "”" }
  end
  -- A project with no file yet renders to where a file was last chosen, or home.
  local path = require("daw.render").default_path()
  if not path:find("/", 1, true) then path = (daw.state.pick_dir or os.getenv("HOME") or ".") .. "/" .. path end
  return { path = path, ranges = ranges, sample_rate = api.engine_get().sample_rate }
end

--- The menu of a track's input: the choices of `daw.audio.choices` under
--- their headings, `audio`, `midi` and `channel`, each a list of
--- `{ label, checked }`. `act.choose_input` takes one by heading and place.
function M.input_menu(track)
  local out = { audio = {}, midi = {}, channel = {}, monitor = api.track_get(track).monitor }
  for _, choice in ipairs(daw.audio.choices(track)) do
    local list = out[choice.group]
    list[#list + 1] = { label = choice.label, checked = choice.checked }
  end
  return out
end

--- The menu where the audio devices are chosen: `info` (lines to show),
--- `output`, `input`, `block`, `rate` and `backend`, each a list of
--- `{ label, checked }`.
--- `act.choose_engine` takes one by heading and place.
function M.engine_menu()
  local out = { info = {}, output = {}, input = {}, block = {}, rate = {}, backend = {} }
  local ok, choices = pcall(daw.audio.engine_choices)
  if not ok then
    out.info[1] = { label = tostring(choices):match("[^\n]*"), checked = false }
    return out
  end
  for _, choice in ipairs(choices) do
    local list = out[choice.group]
    list[#list + 1] = { label = choice.label, checked = choice.checked }
  end
  return out
end

--- The waveform of an audio clip at `points` points (`M.peak_points`
--- without), as one flat list { min1, max1, rms1, min2, max2, rms2, ... }:
--- how far the wave reaches each way and how loud it is, which is its body.
--- Kept out of `state`, which is sent again whenever the cursor moves, so
--- that a frontend fetches each waveform once for each width it draws at.
function M.peaks(clip, points)
  local flat = {}
  points = daw.util.clamp(math.floor(points or M.peak_points), 8, 4096)
  for i, p in ipairs(api.clip_peaks(clip, points)) do
    flat[3 * i - 2], flat[3 * i - 1], flat[3 * i] = p[1], p[2], p[3]
  end
  return flat
end

-- What a pointer does ---------------------------------------------------------
--
-- A frontend sends gestures here (`daw.frontend.act.move_clip(id, 8, track)`)
-- instead of spelling out what they mean, so that every frontend means the
-- same by a drag or a double click, and the suite can test it. Beats snap to
-- the grid here. Notes and points are named by their place, from 1.

local A = {}
M.act = A
M.openers = {}

local function snap(beat) return math.max(0, daw.cursor.snap(beat)) end

local function note_snap(beat)
  local grid = daw.opt.note_grid
  return math.max(0, math.floor(beat / grid + 0.5) * grid)
end

--- Give the arrange view the keyboard, unless a window is open over it.
local function to_arrange()
  if daw.keymap.mode == "x" then daw.keymap.set_mode("n") end
  if not daw.ui.float and daw.ui.focused ~= "arrange" then daw.ui.focus("arrange") end
end

-- Clips chosen with the pointer -----------------------------------------------
--
-- A click chooses a clip, Ctrl and a click adds or takes one away, Shift and
-- a click takes in the clips between it and the last one chosen, a box drawn
-- with the right button takes in what it touches. Gestures on a chosen clip
-- act on all of them. So do the keys: two or more chosen clips (or any chosen
-- with a modifier or a box) are visual mode's selection, of the kind "clips",
-- which every operator acts on (`d`, `x`, `y`, `>`, `gc`...) and Esc lets go
-- of; one clip chosen with a plain click is the clip under the cursor, which
-- `x` already deletes, and is let go of when the cursor leaves it.

local picked = { set = {}, anchor = nil }
-- A gesture is choosing: the cursor and mode it moves keep the choice.
local pointing = false

--- The ids of the chosen clips, in order.
function M.chosen_clips()
  local keymap = daw.keymap
  -- Another kind of selection is open: that is what the keys act on.
  if keymap.mode == "x" and not (keymap.visual and keymap.visual.region) then return {} end
  local out = {}
  for id in pairs(picked.set) do
    if pcall(api.clip_get, id) then out[#out + 1] = id end
  end
  table.sort(out)
  return out
end

--- Where each drawn track is, by id: its row from 1.
local function row_index()
  local rows = {}
  for i, id in ipairs(daw.groups.rows()) do rows[id] = i end
  return rows
end

--- The chosen clips as a region for the operators: the rows and the stretch
--- they span, and `clips`, the set of them.
local function clip_region()
  local rows, set = row_index(), {}
  local r0, r1, c0, c1 = math.huge, -math.huge, math.huge, -math.huge
  for _, id in ipairs(M.chosen_clips()) do
    local c = api.clip_get(id)
    local row = rows[c.track]
    if row then
      set[id] = true
      r0, r1 = math.min(r0, row), math.max(r1, row)
      c0, c1 = math.min(c0, c.start), math.max(c1, c.start + c.length)
    end
  end
  if not next(set) then return nil end
  return { kind = "clips", clips = set, r0 = r0, r1 = r1, c0 = c0, c1 = c1 }
end

local function changed()
  M.revision = M.revision + 1
  api.ui_redraw()
end

--- Choose a set of clips (`{ [id] = true }`); with `visual` they become
--- visual mode's selection.
local function choose_clips(set, anchor, visual)
  picked = { set = set, anchor = anchor or picked.anchor }
  local keymap = daw.keymap
  pointing = true
  if visual and next(set) and clip_region() then
    if not daw.ui.float and daw.ui.focused ~= "arrange" then daw.ui.focus("arrange") end
    local region = clip_region()
    keymap.visual = { kind = "clips", row = region.r0, col = region.c0, view = daw.ui.focused, region = clip_region }
    if keymap.mode ~= "x" then keymap.set_mode("x") end
  elseif keymap.mode == "x" then
    keymap.set_mode("n")
  end
  pointing = false
  changed()
end

daw.on("mode.changed", function(e)
  if not pointing and e.old == "x" and next(picked.set) then
    picked.set = {}
    changed()
  end
end)
daw.on("cursor.changed", function()
  if pointing or daw.keymap.mode == "x" or not next(picked.set) then return end
  local under = daw.cursor.clip()
  if not (under and picked.set[under.id]) then
    picked.set = {}
    changed()
  end
end)

--- Let go of the chosen clips.
function A.clear_clip_selection()
  if next(picked.set) then choose_clips({}, nil, false) end
end

--- Put the cursor on a track at a beat: a click on a lane or a header. A
--- click on a lane (one with a beat) lets go of the chosen clips.
function A.select(track, beat)
  pointing = true
  to_arrange()
  if track ~= 0 then daw.cursor.set_track(track) end
  if beat then daw.cursor.set_beat(snap(beat)) end
  pointing = false
  if beat and next(picked.set) then
    picked.set = {}
    changed()
  end
end

--- Put the cursor in a clip where it was clicked, on the grid but inside
--- the clip, so that the keys act on it.
local function cursor_into(id, beat)
  local c = api.clip_get(id)
  pointing = true
  to_arrange()
  daw.cursor.set_track(c.track)
  beat = snap(beat or c.start)
  if beat < c.start or beat >= c.start + c.length then beat = c.start end
  daw.cursor.set_beat(beat)
  pointing = false
end

--- The clips on drawn rows `row0` to `row1` reaching into beats `from` to `to`.
local function clips_in(row0, row1, from, to)
  local rows, out = daw.groups.rows(), {}
  for row = math.max(1, math.min(row0, row1)), math.min(#rows, math.max(row0, row1)) do
    for _, c in ipairs(api.clip_list(rows[row])) do
      if c.start < to - 1e-9 and c.start + c.length > from + 1e-9 then out[#out + 1] = c.id end
    end
  end
  return out
end

--- A click on a clip: the cursor goes there, and `mode` says what happens
--- to the chosen clips: "only" (or nil) the clip alone, "toggle" (Ctrl) in
--- or out, "add" (Shift) the clips from the last one chosen to this one: on
--- one track those that start between them, across tracks those in the
--- rectangle the two span.
function A.select_clip(id, beat, mode)
  cursor_into(id, beat)
  mode = mode or "only"
  if mode == "only" then return choose_clips({ [id] = true }, id, false) end
  local set = {}
  for _, other in ipairs(M.chosen_clips()) do set[other] = true end
  if mode == "toggle" then
    set[id] = not set[id] or nil
    return choose_clips(set, set[id] and id or picked.anchor, true)
  end
  local anchor = picked.anchor and set[picked.anchor] and pcall(api.clip_get, picked.anchor) and api.clip_get(picked.anchor)
  local c = api.clip_get(id)
  if not anchor then
    set[id] = true
    return choose_clips(set, id, true)
  end
  local rows = row_index()
  local from, to = math.min(anchor.start, c.start), math.max(anchor.start, c.start)
  if anchor.track == c.track then
    for _, other in ipairs(api.clip_list(c.track)) do
      if other.start >= from - 1e-9 and other.start <= to + 1e-9 then set[other.id] = true end
    end
  else
    to = math.max(anchor.start + anchor.length, c.start + c.length)
    for _, other in ipairs(clips_in(rows[anchor.track] or 1, rows[c.track] or 1, from, to)) do set[other] = true end
  end
  set[id] = true
  choose_clips(set, anchor.id, true)
end

--- A box drawn with the right button over the timeline, from row `row0`
--- at `beat0` to `row1` at `beat1` (rows of drawn tracks, from 1): the
--- clips it touches are chosen. `mode` as for `select_clip`: "add" keeps
--- those chosen already, "toggle" turns the ones it touches over.
function A.select_clips_box(row0, beat0, row1, beat1, mode)
  local set = {}
  if mode == "add" or mode == "toggle" then
    for _, id in ipairs(M.chosen_clips()) do set[id] = true end
  end
  local touched = clips_in(row0, row1, math.min(beat0, beat1), math.max(beat0, beat1))
  for _, id in ipairs(touched) do
    if mode == "toggle" and set[id] then set[id] = nil else set[id] = true end
  end
  choose_clips(set, touched[1] or picked.anchor, true)
  local count = 0
  for _ in pairs(set) do count = count + 1 end
  return count
end

--- Every clip on the timeline, chosen.
function A.select_all_clips()
  local set = {}
  for _, track in ipairs(daw.groups.rows()) do
    for _, c in ipairs(api.clip_list(track)) do set[c.id] = true end
  end
  choose_clips(set, nil, true)
end

--- Drop a clip somewhere else: at `start`, on `track` if given. With `copy`
--- the clip stays and a copy is dropped.
function A.move_clip(id, start, track, copy)
  local clip = daw.clip(id)
  start = snap(start)
  track = track and track ~= 0 and track or clip:get().track
  if copy then
    local made = daw.restore_clip(daw.util.merge(clip:snapshot(), { start = start }), track)
    return made.id
  end
  api.clip_set(id, "start", start)
  if track ~= api.clip_get(id).track then api.clip_set(id, "track", track) end
  return id
end

--- The clips a gesture on clip `id` acts on: all the chosen ones if it is
--- one of them, else that clip alone, which is then the chosen one.
local function grabbed_clips(id)
  local ids = M.chosen_clips()
  for _, other in ipairs(ids) do
    if other == id then return ids end
  end
  choose_clips({ [id] = true }, id, false)
  return { id }
end

--- Drag clips: the one at `id` and, if it is chosen, the others chosen with
--- it, by `dbeat` beats and `drows` rows of drawn tracks, keeping their
--- places to one another. Snapping is relative: the clips move by whole
--- grid steps, so the grabbed clip keeps its distance from the grid line
--- before it, which is none if it started on one. `free` (Shift) moves them
--- by exactly `dbeat`. With `copy` (Ctrl) they stay and copies are dropped,
--- which are then the chosen clips. Nothing goes before the start or off
--- the tracks. One undo step, as one call. Returns the ids of what moved.
function A.drag_clips(id, dbeat, drows, copy, free)
  local ids = grabbed_clips(id)
  local by = free and dbeat or daw.util.round(dbeat, daw.opt.grid)
  drows = math.floor((drows or 0) + 0.5)
  local rows, list = row_index(), daw.groups.rows()
  local clips = {}
  for i, cid in ipairs(ids) do
    local c = api.clip_get(cid)
    clips[i] = c
    by = math.max(by, -c.start)
    local row = rows[c.track]
    if row then drows = daw.util.clamp(drows, 1 - row, #list - row) end
  end
  if math.abs(by) < 1e-9 and drows == 0 and not copy then return ids end
  local out = {}
  for i, c in ipairs(clips) do
    local row = rows[c.track]
    local track = row and list[row + drows] or c.track
    if copy then
      local made = daw.restore_clip(daw.util.merge(daw.clip(c.id):snapshot(), { start = c.start + by }), track)
      out[i] = made.id
    else
      api.clip_set(c.id, "start", c.start + by)
      if track ~= c.track then api.clip_set(c.id, "track", track) end
      out[i] = c.id
    end
  end
  if copy then
    local set = {}
    for _, cid in ipairs(out) do set[cid] = true end
    choose_clips(set, out[1], #out > 1)
  end
  return out
end

--- Move what plays inside a MIDI clip by `by` beats: its notes and its
--- controller moves. What goes before the clip's start keeps a place below
--- 0, where it is not played or drawn, and comes back when the start is
--- dragged out over it again.
local function shift_content(id, by)
  local notes = api.clip_notes(id)
  for _, n in ipairs(notes) do n.start = n.start + by end
  api.clip_set_notes(id, notes)
  local c = api.clip_get(id)
  if c.control_count > 0 then
    local controls = api.clip_controls(id)
    for _, move in ipairs(controls) do move.start = move.start + by end
    api.clip_set_controls(id, controls)
  end
  -- The takes that are not playing stay lined up with the one that is.
  daw.takes.shift(id, by)
end

--- Beats in an audio clip's offset into its file.
--- How far before an audio clip's start its file begins, in beats of the
--- tempo map there (a negative number).
local function file_start(c)
  return daw.time.to_beat(math.max(0, daw.time.to_seconds(c.start) - c.offset)) - c.start
end

--- Drag an edge of a clip, and the same edge of the clips chosen with it:
--- `edge` is "start" or "end", `dbeat` how far it went. The grabbed clip's
--- edge lands on the grid unless `free` (Shift); the others change by as
--- much, each within what it can do. The start is trimmed without moving
--- what plays: an audio clip starts further into its file, a MIDI clip
--- hides the notes before its new start, which come back when it is
--- dragged out again. A clip is never shorter than a grid step (a 64th of
--- a beat when free). With `slip` (Alt) the edge stays and what plays
--- inside the clip moves instead. One undo step. Returns the ids.
function A.trim_clips(id, edge, dbeat, free, slip)
  local ids = grabbed_clips(id)
  local held = api.clip_get(id)
  local least = free and 1 / 64 or daw.opt.grid
  if slip then
    for _, cid in ipairs(ids) do
      local c = api.clip_get(cid)
      if c.kind == "audio" then
        -- Later in the clip is earlier in the file, which has no time before 0.
        api.clip_set(cid, "offset", math.max(0, c.offset - daw.time.seconds(dbeat, c.start)))
      else
        shift_content(cid, dbeat)
      end
    end
    return ids
  end
  local at = edge == "start" and held.start or held.start + held.length
  local by = (free and math.max(0, at + dbeat) or snap(at + dbeat)) - at
  if math.abs(by) < 1e-9 then return ids end
  for _, cid in ipairs(ids) do
    local c = api.clip_get(cid)
    if edge == "start" then
      local d = math.min(by, c.length - least)
      d = math.max(d, -c.start)
      if c.kind == "audio" then d = math.max(d, file_start(c)) end
      if math.abs(d) > 1e-9 then
        api.clip_set(cid, "start", c.start + d)
        api.clip_set(cid, "length", c.length - d)
        if c.kind == "audio" then
          api.clip_set(cid, "offset", math.max(0, c.offset + daw.time.seconds(d, c.start)))
          api.clip_set(cid, "fade_in", math.min(c.fade_in, c.length - d))
          api.clip_set(cid, "fade_out", math.min(c.fade_out, c.length - d))
        else
          shift_content(cid, -d)
        end
      end
    else
      local length = math.max(least, c.length + by)
      api.clip_set(cid, "length", length)
      if c.kind == "audio" then
        api.clip_set(cid, "fade_in", math.min(c.fade_in, length))
        api.clip_set(cid, "fade_out", math.min(c.fade_out, length))
      end
    end
  end
  return ids
end

--- The handle at a top corner of an audio clip: its fade in (`which` "in")
--- or out ("out") is set to `beats`, and so is that of the audio clips
--- chosen with it, each no longer than the clip. One undo step.
function A.set_fade(id, which, beats)
  local field = which == "out" and "fade_out" or "fade_in"
  for _, cid in ipairs(grabbed_clips(id)) do
    local c = api.clip_get(cid)
    if c.kind == "audio" then api.clip_set(cid, field, daw.util.clamp(beats, 0, c.length)) end
  end
end

--- A drag on the top line of an audio clip: its gain, in dB, is set to
--- `db`, and that of the audio clips chosen with it changes by as much,
--- each between -60 and +24 dB. The waveform is drawn as loud as it plays.
function A.set_clip_gain(id, db)
  local by = db - api.clip_get(id).gain
  for _, cid in ipairs(grabbed_clips(id)) do
    local c = api.clip_get(cid)
    if c.kind == "audio" then api.clip_set(cid, "gain", daw.util.clamp(c.gain + by, -60, 24)) end
  end
end

--- Drag a clip's right edge to a new length, never shorter than a grid step.
function A.resize_clip(id, length)
  api.clip_set(id, "length", math.max(daw.opt.grid, daw.cursor.snap(length)))
end

--- A tempo (`kind` "tempo") or signature change flagged on the ruler at
--- `beat`: "move" it to beat `to` (on the grid; a signature to the bar
--- line nearest), "edit" its value through a prompt, or "remove" it.
function A.tempo_mark(action, kind, beat, to)
  local map = api.tempo_points()
  local list = kind == "tempo" and map.tempos or map.signatures
  local index
  for i, p in ipairs(list) do
    if math.abs(p.beat - beat) < 1e-6 then index = i end
  end
  if not index or index == 1 then return end
  local point = list[index]
  if action == "remove" then
    if kind == "tempo" then api.tempo_remove(point.beat) else api.signature_remove(point.beat) end
  elseif action == "move" then
    table.remove(list, index)
    local was = point.beat
    if kind == "tempo" then
      point.beat = math.max(daw.opt.grid, daw.cursor.snap(to))
    else
      -- To the nearest bar line, so that the bars before it stay whole.
      local n = daw.time.bar_of(to)
      local a, b = daw.time.bar_start(n), daw.time.bar_start(n + 1)
      point.beat = math.max(daw.time.bar_start(2), (to - a < b - to) and a or b)
    end
    list[#list + 1] = point
    if math.abs(point.beat - was) > 1e-9 then api.tempo_set_points(map.tempos, map.signatures) end
  elseif action == "edit" then
    local where = "bar " .. daw.time.bar_of(point.beat)
    if kind == "tempo" then
      daw.ui.input({ prompt = "tempo at " .. where .. ": ", text = string.format("%g", point.bpm) }, function(text)
        local bpm = tonumber(text)
        if bpm then api.tempo_set(point.beat, bpm) end
      end)
    else
      daw.ui.input({ prompt = "signature at " .. where .. ": ", text = point.num .. "/" .. point.den }, function(text)
        local n, d = tostring(text):match("^%s*(%d+)%s*/%s*(%d+)%s*$")
        if n then api.signature_set(point.beat, tonumber(n), tonumber(d)) end
      end)
    end
  end
end

--- A double click on an empty lane: a clip of one bar in the bar clicked.
function A.add_clip(track, beat)
  local start = daw.time.bar_floor(math.max(0, beat))
  local id = api.clip_add(track, { start = start, length = daw.time.bar(start) })
  A.select(track, api.clip_get(id).start)
  return id
end

--- Open a clip's notes; an audio clip has none to open. An extension that
--- has an editor of its own for some clips adds a function to
--- `daw.frontend.openers`, which is asked first: it gets the clip and
--- returns true if it has opened it.
function A.open_clip(id)
  local clip = daw.clip(id)
  A.select_clip(id, clip.start)
  for _, opener in ipairs(M.openers) do
    if opener(clip) then return end
  end
  if clip.kind == "midi" then daw.ui.views.pianoroll:edit(clip) end
end

--- The record button. With nothing being recorded: arm the selected track
--- if no track is armed, then record from the playhead. Otherwise: end the
--- take and stop.
function A.record()
  local t = api.transport_get()
  if t.recording or t.take then
    daw.transport.recording = false
    if t.playing then daw.transport.stop() end
    return
  end
  local armed = false
  for _, id in ipairs(api.track_list()) do armed = armed or api.track_get(id).armed end
  if not armed then
    local track = daw.cursor.track()
    if not track then
      return daw.notify("nothing to record on: select a track, or arm one with its R button", "warn")
    end
    track.armed = true
    daw.notify("recording on " .. track.name .. ": it was armed for you (its R button)")
  end
  daw.transport.record()
end

function A.close_roll()
  daw.ui.hide("pianoroll")
  to_arrange()
end

--- Run a command on a clip or a track that was not under the cursor: what
--- a context menu does. The cursor goes there first, as a click would put it.
function A.clip_command(id, beat, line)
  A.menu_target(id, beat)
  daw.commands.exec(line)
end

--- The cursor goes to the clip a menu was opened on; the chosen clips stay
--- chosen if it is one of them, else it is chosen alone.
function A.menu_target(id, beat)
  local among = false
  for _, other in ipairs(M.chosen_clips()) do among = among or other == id end
  if among then return cursor_into(id, beat) end
  A.select_clip(id, beat)
end

function A.track_command(id, line)
  A.select(id)
  daw.commands.exec(line)
end

--- Set a device offline, or back online.
function A.toggle_offline(id)
  daw.loading.toggle(daw.device(id))
end

--- Start a plugin again that has stopped working.
function A.restart_device(id)
  local ok, err = pcall(api.device_restart, id)
  if not ok then daw.notify(tostring(err):match("^[^\n]*"), "error") end
end

--- An entry an extension added to a menu (`daw.frontend.menus`), by its
--- place in the list: `target` is the clip or the track that was clicked.
--- The timeline's entries are also offered by the buttons that make a
--- track, which have no place to give: no track, or a beat below 0, leaves
--- the cursor where it is.
function A.menu(kind, index, target, beat)
  local entry = (M.menus[kind] or {})[index]
  if not entry then return end
  if beat and beat < 0 then beat = nil end
  if kind == "clip" then
    A.menu_target(target, beat)
  elseif target and target > 0 then
    A.select(target, beat)
  else
    to_arrange()
  end
  if entry.run then
    entry.run(target, beat)
  elseif entry.command then
    daw.commands.exec(entry.command)
  end
end

--- Drag along the ruler: loop that stretch. Too short a drag is a click,
--- which only moves the playhead.
function A.set_loop(from, to)
  from, to = snap(math.min(from, to)), snap(math.max(from, to))
  if to - from < daw.opt.grid then return api.transport_seek(from) end
  daw.transport.loop_start, daw.transport.loop_end = from, to
  daw.transport.loop_enabled = true
end

--- The pointer on the floating window, drawn as the lines of `M.float`:
--- `kind` is "down" for a click, "scroll_up" or "scroll_down" for the
--- wheel; `line` and `col` count from 1. It goes where a click in the
--- terminal goes: in a picker a click on a row selects it, and a click on
--- the selected row (the second of a double click) chooses it.
function A.float_pointer(kind, line, col)
  local float = daw.ui.float
  if not float then return end
  for _, r in ipairs(daw.ui.rects) do
    if r.name == float.name then
      return daw.ui.mouse({ kind = kind, button = "left", x = r.x + math.max(0, (col or 1) - 1), y = r.y + math.max(0, line - 1) })
    end
  end
end

local splitting = false

--- Split every chosen clip that the edit cursor is inside, there: what
--- `clip.split` (`S`, and the clip menu's "Split at the edit cursor") does
--- while clips are chosen. Both halves are chosen afterwards. Returns false
--- when no clip is chosen, for `clip.split` to split the clip under the
--- cursor instead.
function A.split_clips()
  local ids = M.chosen_clips()
  if splitting or #ids == 0 then return false end
  local beat, track, visual = daw.cursor.beat, daw.cursor.track_id(), daw.keymap.mode == "x"
  local set = {}
  splitting, pointing = true, true
  local ok, err = pcall(function()
    for _, id in ipairs(ids) do
      set[id] = true
      local c = api.clip_get(id)
      if beat > c.start + 1e-9 and beat < c.start + c.length - 1e-9 then
        daw.cursor.set_track(c.track)
        daw.commands.exec("clip.split")
        local right = daw.track(c.track):clip_at(beat)
        if right then set[right.id] = true end
      end
    end
  end)
  if track then daw.cursor.set_track(track) end
  splitting, pointing = false, false
  if not ok then error(err, 0) end
  choose_clips(set, ids[1], visual or #ids > 1)
  return true
end

--- Glue the chosen clips on each track into one clip, the gaps between
--- them included: what the clip menu's "Glue" and `J` on chosen clips do.
--- MIDI clips are joined; audio clips are glued into a new file
--- (`daw.media.glue`). A track whose chosen clips are of both kinds is left
--- as it is.
function A.glue_clips()
  local region = clip_region()
  if not region then return daw.notify("no clips chosen to glue", "warn") end
  local glued = false
  for _, track in ipairs(daw.edit.arrange.tracks(region)) do
    local audio, midi = {}, 0
    for _, c in ipairs(api.clip_list(track)) do
      if region.clips[c.id] then
        if c.kind == "audio" then audio[#audio + 1] = c.id else midi = midi + 1 end
      end
    end
    local ok, done = true, false
    if #audio >= 2 and midi == 0 then
      ok, done = pcall(daw.media.glue, audio)
      done = ok and done and done.glued and done.glued > 1
    elseif midi >= 2 and #audio == 0 then
      ok, done = pcall(daw.edit.arrange.join, track, region.c0, region.c1, region.clips)
    elseif #audio > 0 and midi > 0 then
      daw.notify("audio and MIDI clips cannot be glued together", "warn")
    end
    if not ok then return daw.notify(tostring(done):match("^[^\n]*"), "warn") end
    glued = glued or done
  end
  if not glued then daw.notify("glue takes two or more chosen clips of one kind on a track", "warn") end
  local left = {}
  for _, id in ipairs(M.chosen_clips()) do left[id] = true end
  choose_clips(left, nil, false)
end

--- The clip menu's "Split at the edit cursor" and "Glue", opened on clip
--- `id`: on the chosen clips if it is one of them, else on it alone. The
--- edit cursor stays where it is.
function A.menu_split(id)
  grabbed_clips(id)
  if not A.split_clips() then daw.commands.exec("clip.split") end
end

function A.menu_glue(id)
  grabbed_clips(id)
  A.glue_clips()
end

--- Drag an edge of the loop, "start" or "end", to a beat on the grid; it
--- stays at least a grid step long.
function A.set_loop_edge(edge, beat)
  local t = daw.transport
  beat = snap(beat)
  if edge == "start" then
    t.loop_start = math.min(beat, t.loop_end - daw.opt.grid)
  else
    t.loop_end = math.max(beat, t.loop_start + daw.opt.grid)
  end
end

--- Drag an edge of the punch range, "start" or "end", to a beat on the
--- grid (anywhere with `free`); it stays at least a grid step long.
function A.set_punch_edge(edge, beat, free)
  local t = daw.transport
  beat = free and math.max(0, beat) or snap(beat)
  local least = free and 1 / 64 or daw.opt.grid
  if edge == "start" then
    t.punch_start = math.min(beat, t.punch_end - least)
  else
    t.punch_end = math.max(beat, t.punch_start + least)
  end
end

--- Punch in and out between two beats, on the grid, and turn punching on.
function A.set_punch(from, to)
  from, to = snap(math.min(from, to)), snap(math.max(from, to))
  if to - from < daw.opt.grid then return end
  daw.transport.punch_start, daw.transport.punch_end = from, to
  daw.transport.punch_enabled = true
end

--- Show a track's take lanes under its clips, or hide them. Returns
--- whether they show now.
function A.take_lanes(track)
  return daw.takes.toggle_lanes(track)
end

--- A drag across take lane `take` of a track, from beat `from` to `to`:
--- that take plays over the stretch (see `daw.takes.comp`). The ends land
--- on the grid unless `free` (Shift). A stretch shorter than a grid step is
--- a click, which chooses the take for the piece under the pointer. One
--- undo step. Returns how many pieces play the take now.
function A.comp(track, take, from, to, free)
  local a, b = math.min(from, to), math.max(from, to)
  if not free then a, b = snap(a), snap(b) end
  a = math.max(0, a)
  if b - a < (free and 1 / 64 or daw.opt.grid) - 1e-9 then
    return A.take_click(track, take, math.min(from, to)) and 1 or 0
  end
  local n = daw.takes.comp(track, take, a, b)
  if n > 0 then daw.cursor.set_track(track) end
  return n
end

--- A click on take lane `take` of a track: the piece under the pointer
--- plays that take. Returns its clip, or nil when there is none there.
function A.take_click(track, take, beat)
  local c = daw.takes.choose_at(track, take, beat)
  if c then
    pointing = true
    to_arrange()
    daw.cursor.set_track(track)
    pointing = false
  end
  return c and c.id or nil
end

--- A click on the ruler: the edit cursor goes to the beat, on the grid,
--- and the playhead with it.
function A.ruler_click(beat)
  beat = snap(beat)
  pointing = true
  daw.cursor.set_beat(beat)
  pointing = false
  api.transport_seek(beat)
end

--- Drag across empty lanes: select that stretch of time on those tracks,
--- as visual mode does, for the keys and the menu to act on. Rows are
--- places in the track list, from 1.
function A.select_range(row0, beat0, row1, beat1)
  local tracks = daw.groups.rows()
  if #tracks == 0 then return end
  to_arrange()
  local clamp = daw.util.clamp
  daw.cursor.set_track(tracks[clamp(row0, 1, #tracks)])
  daw.cursor.set_beat(snap(math.min(beat0, beat1)))
  daw.keymap.visual_start("v")
  daw.cursor.set_track(tracks[clamp(row1, 1, #tracks)])
  daw.cursor.set_beat(snap(math.max(beat0, beat1)))
end

--- Type keys as if at the keyboard: what a menu entry for an operator does
--- to a selection.
function A.keys(keys)
  daw.keymap.feed(keys)
end

function A.set_volume(track, db) api.track_set(track, "volume", daw.util.clamp(db, -60, 6)) end

--- A fader, a pan or a parameter is under the pointer (`on`), or let go:
--- in touch mode it writes automation for as long as it is held. `device`
--- and `param` name a parameter; 0 and "" for a fader or a pan.
function A.hold(track, target, device, param, on)
  if target ~= "param" then device, param = nil, nil end
  api.automation_hold(track, target, device, param, on)
end

--- Leave the project: `what` is "quit", "new" (an empty project) or
--- "open" (another, chosen from a list). `how` is "save" to save its
--- changes first (asking where, for a project with no file yet),
--- "discard" to throw them away, or "go" when there are none.
function A.leave(how, what)
  local function go()
    if what == "quit" then
      if how == "discard" then daw.autosave.discard = true end
      api.quit(0)
    elseif what == "new" then
      daw.project.new()
    else
      daw.commands.exec("open")
    end
  end
  if how ~= "save" then return go() end
  if api.project_get().path then
    daw.project.save()
    return go()
  end
  M.save_as(go)
end

--- The lanes of a lane's track are no longer shown as rows.
function A.hide_lane_rows(lane)
  daw.lanes.open(api.lane_get(lane).track, false)
end

--- Show a track's lanes as rows of their own under it, or hide them. A
--- track that has none yet gets one for its fader, to draw on.
function A.lane_rows(track)
  if not daw.lanes.is_open(track) and #api.lane_list(track) == 0 then A.lane(track, "volume") end
  return daw.lanes.toggle(track)
end

--- Render as the window's dialog says: `o.path`, `o.range` (a name from
--- `render_dialog`), `o.format` ("wav" or "flac"), `o.bits`, `o.tail`
--- seconds, `o.normalize` dB or nil, `o.dither`, `o.mono`, and `o.stems`
--- for a file per track in a directory named after the path. It runs in
--- the background: the state's `modal.render` says how far it is.
function A.render(o)
  local opts = {
    tail = tonumber(o.tail), bits = tonumber(o.bits), dither = o.dither and true or nil,
    normalize = tonumber(o.normalize), channels = o.mono and 1 or nil, background = true,
  }
  local format = o.format == "flac" and "flac" or "wav"
  if format == "flac" and opts.bits == 32 then opts.bits = 24 end
  local range = o.range or "song"
  local region = range:match("^region:(%d+)$")
  if region then
    local r = daw.markers.find({ id = tonumber(region) })
    if not r then error("that region is gone", 0) end
    opts.start, opts["end"] = r.beat, r.beat + r.length
  elseif range ~= "song" then
    opts.range = range
  end
  local path = tostring(o.path or ""):gsub("^~", os.getenv("HOME") or "~")
  if path == "" then error("render: name a file to write", 0) end
  local stem = path:gsub("%.[Ww][Aa][Vv]$", ""):gsub("%.[Ff][Ll][Aa][Cc]$", "")
  if o.stems then
    opts.format = format
    local files = daw.render_stems(stem .. " stems", opts)
    return daw.notify(string.format("rendering %d stem%s into %s", #files, #files == 1 and "" or "s", stem .. " stems"))
  end
  daw.render(stem .. "." .. format, opts)
  daw.notify("rendering " .. (stem:match("([^/]+)$") or stem) .. "." .. format .. " · Esc cancels")
end

-- Where a track's sound goes.

--- Where a track's sound goes, for a frontend to show and change:
---   output   the name of the track it plays into ("Master" without one)
---   targets  the tracks it could play into or send to, `{ id, name }` each;
---            the master is first, with id 0
---   sends    `{ target, name, level, pre }` each, levels in dB
--- A track cannot play into itself or into a track that plays into it.
function M.routing(track)
  local t = api.track_get(track)
  local targets = { { id = 0, name = "Master" } }
  -- Not a track whose sound reaches this one, by any route.
  local reaching = daw.routes.reaching(track)
  for _, id in ipairs(api.track_list()) do
    if id ~= track and not reaching[id] then targets[#targets + 1] = { id = id, name = api.track_get(id).name } end
  end
  local sends = {}
  for i, send in ipairs(t.sends or {}) do
    local ok, to = pcall(api.track_get, send.target)
    sends[i] = { target = send.target, name = ok and to.name or "?", level = send.level, pre = send.pre or false }
  end
  local ok, to = pcall(api.track_get, t.output or 0)
  return { output = t.output and ok and to.name or "Master", output_id = t.output or 0, targets = targets, sends = sends, master = t.master or false }
end

--- Play a track into another (`target` 0 or nil for the master).
function A.set_output(track, target)
  api.track_set(track, "output", target and target ~= 0 and target or nil)
end

--- Send a track's sound to another as well, at `level` dB (0 without).
function A.add_send(track, target, level)
  local sends = api.track_get(track).sends
  for _, send in ipairs(sends) do
    if send.target == target then return end
  end
  sends[#sends + 1] = { target = target, level = level or 0 }
  api.track_set(track, "sends", sends)
end

--- Change the send at `index` (from 1): `level` in dB, `pre` whether it is
--- taken ahead of the fader; nil leaves either as it is.
function A.set_send(track, index, level, pre)
  local sends = api.track_get(track).sends
  if not sends[index] then return end
  if level ~= nil then sends[index].level = daw.util.clamp(level, -60, 6) end
  if pre ~= nil then sends[index].pre = pre and true or nil end
  api.track_set(track, "sends", sends)
end

function A.remove_send(track, index)
  local sends = api.track_get(track).sends
  if not sends[index] then return end
  table.remove(sends, index)
  api.track_set(track, "sends", sends)
end

--- The menu of a device's side-chain: "None" first, then the tracks it
--- can listen to, then whether it is taken before their fader; each
--- `{ label, checked }`. `act.choose_sidechain` takes one by place.
function M.sidechain_menu(device)
  local d = api.device_get(device)
  local out = { { label = "None: its own input", checked = d.sidechain == nil } }
  for _, source in ipairs(daw.routes.sidechain_sources(device)) do
    out[#out + 1] = { label = source.name, checked = source.id == d.sidechain }
  end
  out[#out + 1] = { label = "Before the fader", checked = d.sidechain_pre or false }
  return out
end

--- Choose from a device's side-chain menu (`M.sidechain_menu`), by place
--- from 1: none, a track, or the last entry, which turns taking it before
--- the fader on or off.
function A.choose_sidechain(device, index)
  local d = api.device_get(device)
  local sources = daw.routes.sidechain_sources(device)
  if index == 1 then
    daw.routes.set_sidechain(device, nil)
  elseif sources[index - 1] then
    daw.routes.set_sidechain(device, sources[index - 1].id, d.sidechain_pre)
  elseif index == #sources + 2 and d.sidechain then
    api.device_set(device, "sidechain_pre", not d.sidechain_pre)
  end
end

function A.set_pan(track, pan) api.track_set(track, "pan", daw.util.clamp(pan, -1, 1)) end

function A.toggle(track, flag) api.track_set(track, flag, not api.track_get(track)[flag]) end

local function nth(list, group, index)
  local n = 0
  for _, choice in ipairs(list) do
    if choice.group == group then
      n = n + 1
      if n == index then return choice end
    end
  end
end

--- Choose a track's input from its menu (`M.input_menu`): the `index`th
--- entry, from 1, under the heading `group`.
function A.choose_input(track, group, index)
  local choice = nth(daw.audio.choices(track), group, index)
  if not choice then return end
  daw.audio.choose(track, choice)
  A.select(track)
end

--- Choose an audio device or a block size from `M.engine_menu`.
function A.choose_engine(group, index)
  local choice = nth(daw.audio.engine_choices(), group, index)
  if choice then daw.audio.choose_engine(choice) end
end

--- A click on a device of a track's chain, as a mixer strip lists them: the
--- track becomes the cursor's and the device panel gets the keyboard, on
--- the `index`th device, from 1.
function A.pick_device(track, index)
  A.select(track)
  local panel = daw.ui.views.devices
  for row, entry in ipairs(panel:rows()) do
    if not entry.param and entry.device.index == index then panel.row = row end
  end
  daw.ui.focus("devices")
end

function A.rename_track(track, name)
  name = name:match("^%s*(.-)%s*$")
  if name ~= "" then api.track_set(track, "name", name) end
end

--- Give a track one of the theme's colours by name, any `#rrggbb`, or "none".
function A.color_track(track, colour)
  A.track_command(track, "track.color " .. colour)
end

--- Drag a track's header to another place among the drawn rows, from 1.
--- It goes into the group of the track drawn above it where it lands (or
--- into that track, if it is an open group), and out of its own group if it
--- lands outside it. A group takes its tracks along.
function A.move_track(track, index)
  local groups = daw.groups
  -- The row is among the tracks that are drawn; the list may hold more.
  local rows = groups.rows()
  local target = rows[daw.util.clamp(index, 1, #rows)]
  for place, id in ipairs(api.track_list()) do
    if id == target then api.track_move(track, place) end
  end
  local above
  rows = groups.rows()
  for i, id in ipairs(rows) do
    if id == track then above = rows[i - 1] end
  end
  local want
  if above then
    want = groups.is_group(above) and not groups.folded(above) and above or groups.of(above)
  end
  if want ~= groups.of(track) then
    if want then
      -- A group cannot go inside itself; then it stays in its own group.
      pcall(groups.add, track, want)
    else
      while groups.of(track) do groups.remove(track, true) end
    end
  end
  if groups.is_group(track) then groups.gather(track) end
  local group = groups.of(track)
  if group then groups.gather(group) end
end

--- Drag a track's bottom edge: its height, as a share of the zoom's height
--- that every track has (`1` for that height, which is then not kept).
function A.set_track_height(track, share)
  api.track_set(track, "height", share)
end

--- A press on one of a track's M, S or R buttons swept down across others:
--- each it crosses is set as the first was (`flag` is "mute", "solo" or
--- "armed").
function A.set_flag(track, flag, on)
  if flag ~= "mute" and flag ~= "solo" and flag ~= "armed" then
    error("not a flag of a track: " .. tostring(flag), 2)
  end
  api.track_set(track, flag, on and true or false)
end

--- The same, for the drawn tracks from row `row0` to `row1` (from 1, either
--- way round): where a sweep has gone so far.
function A.sweep_flag(row0, row1, flag, on)
  local rows = daw.groups.rows()
  for row = math.max(1, math.min(row0, row1)), math.min(#rows, math.max(row0, row1)) do
    A.set_flag(rows[row], flag, on)
  end
end

--- Fold a group away or open it: a click on its triangle.
function A.fold(track)
  daw.groups.fold(track)
end

-- Notes, in the clip the piano roll has open.

-- The notes chosen with the pointer: places in one clip. They are kept as
-- long as the clip's notes are what the pointer's own edits left; an edit
-- made any other way (a key, an undo) forgets them, since places move.
local chosen = { clip = nil, places = {}, stamp = nil }

local function stamp_of(clip)
  local ok, data = pcall(api.clip_get, clip)
  return ok and data.stamp or nil
end

--- The places of the chosen notes of `clip`, in order; none if the clip's
--- notes have changed under them.
function M.chosen_notes(clip)
  if chosen.clip ~= clip or chosen.stamp ~= stamp_of(clip) then return {} end
  local out = {}
  for place in pairs(chosen.places) do out[#out + 1] = place end
  table.sort(out)
  return out
end

--- The chosen notes of `clip` in words, for a toolbar: "3 notes · 5.1.00 – 5.3.00",
--- or "" with none chosen.
function M.chosen_text(clip)
  local places = M.chosen_notes(clip)
  if #places == 0 then return "" end
  local c = api.clip_get(clip)
  local notes = api.clip_notes(clip)
  local first, last = math.huge, -math.huge
  for _, place in ipairs(places) do
    local n = notes[place]
    if n then first, last = math.min(first, n.start), math.max(last, n.start + n.length) end
  end
  if first == math.huge then return "" end
  return string.format("%d note%s · %s – %s", #places, #places == 1 and "" or "s",
    daw.time.format(c.start + first), daw.time.format(c.start + last))
end

local function choose(clip, places)
  local set = {}
  for _, place in ipairs(places) do set[place] = true end
  chosen = { clip = clip, places = set, stamp = stamp_of(clip) }
  api.ui_redraw()
end

--- Where notes are now, given what they are: `wanted` is a list of
--- `{ start, pitch }`.
local function places_of(clip, wanted)
  local notes = daw.clip(clip):notes()
  local out, used = {}, {}
  for _, want in ipairs(wanted) do
    for place, n in ipairs(notes) do
      if not used[place] and n.pitch == want.pitch and math.abs(n.start - want.start) < 1e-6 then
        out[#out + 1], used[place] = place, true
        break
      end
    end
  end
  return out
end

-- A gesture's beat on the grid, unless it is `free` (Shift held) or snap
-- is off in the piano roll (`daw.opt.note_snap`): then to the nearest of
-- 960 ticks a beat, as MIDI files count them.
local function snap_note(beat, free)
  if free or not daw.opt.note_snap then return math.max(0, math.floor(beat * 960 + 0.5) / 960) end
  return note_snap(beat)
end

--- A press and drag on the empty grid: a note from `start` for `length`,
--- which is then the one chosen note. `free` leaves it off the grid. A
--- click gives no length (nil, or 0 or less): the note is the piano roll's
--- note length (`set_note_length`); a drawn length becomes that length.
function A.add_note(clip, pitch, start, length, free)
  local c = daw.clip(clip)
  free = free or not daw.opt.note_snap
  start = snap_note(start, free)
  if start >= c.length or c:note_at(pitch, start) then return end
  local roll = daw.ui.views.pianoroll
  if not length or length <= 0 then
    length = roll:step_length()
  else
    length = math.max(free and 1 / 64 or daw.opt.note_grid, snap_note(length, free))
    roll:set_step(length)
  end
  local index = c:add_note({ pitch = pitch, start = start, length = math.min(length, c.length - start), velocity = daw.opt.velocity })
  c:track():play_note(pitch, daw.opt.velocity, 150)
  choose(clip, { index })
  return index
end

--- Choose notes with a click: `mode` is "only" (the note alone), "add" or
--- "toggle" (Shift or Ctrl held).
function A.select_note(clip, index, mode)
  local places = M.chosen_notes(clip)
  if mode == "only" or mode == nil then return choose(clip, { index }) end
  local set = {}
  for _, place in ipairs(places) do set[place] = true end
  if mode == "toggle" and set[index] then set[index] = nil else set[index] = true end
  local out = {}
  for place in pairs(set) do out[#out + 1] = place end
  choose(clip, out)
end

--- Choose the notes a box touches: from `beat0, pitch0` to `beat1, pitch1`,
--- in any order. `mode` as for `select_note`.
function A.select_notes_box(clip, beat0, pitch0, beat1, pitch1, mode)
  if beat0 > beat1 then beat0, beat1 = beat1, beat0 end
  if pitch0 > pitch1 then pitch0, pitch1 = pitch1, pitch0 end
  local set = {}
  if mode == "add" or mode == "toggle" then
    for _, place in ipairs(M.chosen_notes(clip)) do set[place] = true end
  end
  for place, n in ipairs(daw.clip(clip):notes()) do
    if n.start >= 0 and n.pitch >= pitch0 and n.pitch <= pitch1 and n.start < beat1 and n.start + n.length > beat0 then
      if mode == "toggle" and set[place] then set[place] = nil else set[place] = true end
    end
  end
  local out = {}
  for place in pairs(set) do out[#out + 1] = place end
  choose(clip, out)
  return #out
end

function A.select_all_notes(clip)
  local out = {}
  local length = daw.clip(clip).length
  for place, n in ipairs(daw.clip(clip):notes()) do
    -- Not those hidden by a trim of the clip's edges.
    if n.start >= 0 and n.start < length then out[#out + 1] = place end
  end
  choose(clip, out)
end

function A.clear_note_selection()
  if next(chosen.places) then choose(chosen.clip, {}) end
end

--- The notes a gesture on the note at `index` acts on: all the chosen ones
--- if it is one of them, else that note alone, which is then the chosen one.
local function grabbed(clip, index)
  local places = M.chosen_notes(clip)
  for _, place in ipairs(places) do
    if place == index then return places end
  end
  choose(clip, { index })
  return { index }
end

--- Drag notes: the one at `index` and, if it is chosen, the others chosen
--- with it, by `dbeat` and `dpitch`. The grabbed note lands on the grid
--- unless `free`; the rest keep their distance from it. With `copy` the
--- notes stay and copies are dropped.
function A.drag_notes(clip, index, dbeat, dpitch, copy, free)
  local c = daw.clip(clip)
  local notes = c:notes()
  local held = notes[index]
  if not held then return end
  local places = grabbed(clip, index)
  local by = snap_note(held.start + dbeat, free) - held.start
  dpitch = math.floor((dpitch or 0) + 0.5)
  -- Nothing leaves the clip or the keyboard.
  for _, place in ipairs(places) do
    local n = notes[place]
    by = math.max(by, -n.start)
    by = math.min(by, c.length - n.start - math.min(n.length, daw.opt.note_grid))
    dpitch = daw.util.clamp(dpitch, -n.pitch, 127 - n.pitch)
  end
  if math.abs(by) < 1e-9 and dpitch == 0 and not copy then return end
  local wanted, set, add = {}, {}, {}
  for _, place in ipairs(places) do
    local n = notes[place]
    local moved = { start = n.start + by, pitch = n.pitch + dpitch }
    wanted[#wanted + 1] = moved
    if copy then
      add[#add + 1] = daw.util.merge(n, moved)
    else
      set[#set + 1] = { index = place, start = moved.start, pitch = moved.pitch }
    end
  end
  c:edit_notes({ set = set, add = add })
  if dpitch ~= 0 then c:track():play_note(held.pitch + dpitch, held.velocity, 120) end
  choose(clip, places_of(clip, wanted))
end

--- Drag an end of the note at `index`, and the same end of the notes chosen
--- with it: `dstart` moves their starts (the ends stay), `dlength` their ends.
function A.stretch_notes(clip, index, dstart, dlength, free)
  local c = daw.clip(clip)
  local notes = c:notes()
  local held = notes[index]
  if not held then return end
  local places = grabbed(clip, index)
  local least = (free or not daw.opt.note_snap) and 1 / 64 or daw.opt.note_grid
  -- The grabbed note's end lands on the grid; the others change by as much.
  if dstart and dstart ~= 0 then
    dstart = snap_note(held.start + dstart, free) - held.start
  else
    dstart = 0
  end
  if dlength and dlength ~= 0 then
    dlength = snap_note(held.start + held.length + dlength, free) - (held.start + held.length)
  else
    dlength = 0
  end
  local wanted, set = {}, {}
  for _, place in ipairs(places) do
    local n = notes[place]
    local stop = n.start + n.length
    local start = daw.util.clamp(n.start + dstart, 0, stop - least)
    local length = math.max(least, math.min(stop + dlength, c.length) - start)
    wanted[#wanted + 1] = { start = start, pitch = n.pitch }
    set[#set + 1] = { index = place, start = start, length = length }
  end
  c:edit_notes({ set = set })
  choose(clip, places_of(clip, wanted))
  return notes[index] and (dlength ~= 0 or dstart ~= 0)
end

--- Take a note away, and with it the others if it is one of the chosen.
function A.remove_note(clip, index)
  local places = grabbed(clip, index)
  daw.clip(clip):edit_notes({ remove = places })
  choose(clip, {})
end

--- Take the chosen notes away: what Delete does in the piano roll.
function A.remove_chosen_notes(clip)
  local places = M.chosen_notes(clip)
  if #places == 0 then return false end
  daw.clip(clip):edit_notes({ remove = places })
  choose(clip, {})
  return true
end

-- One note at a time, as scripts and older frontends ask for it.
function A.move_note(clip, index, start, pitch)
  pitch = daw.util.clamp(pitch, 0, 127)
  local c = daw.clip(clip)
  local before = c:notes()[index]
  local at = c:set_note(index, { start = note_snap(start), pitch = pitch })
  if before and before.pitch ~= pitch then c:track():play_note(pitch, before.velocity, 120) end
  return at
end

function A.resize_note(clip, index, length)
  daw.clip(clip):set_note(index, { length = math.max(daw.opt.note_grid, note_snap(length)) })
end

--- How hard a note is played; with the note among the chosen, all of them.
function A.set_velocity(clip, index, velocity)
  velocity = daw.util.clamp(math.floor(velocity + 0.5), 1, 127)
  local places = M.chosen_notes(clip)
  local among = false
  for _, place in ipairs(places) do among = among or place == index end
  if not among then return daw.clip(clip):set_note(index, { velocity = velocity }) end
  local set = {}
  for i, place in ipairs(places) do set[i] = { index = place, velocity = velocity } end
  daw.clip(clip):edit_notes({ set = set })
  choose(clip, places)
end

--- Hear a pitch on the track of the clip that is open: a click on the keyboard.
function A.audition(clip, pitch)
  daw.clip(clip):track():play_note(daw.util.clamp(pitch, 0, 127), daw.opt.velocity, 250)
end

--- A drag with Alt held: take away every note the pointer crossed. `points`
--- are `{ beat, pitch }` as the pointer went; between two of them the path
--- is a straight line, so a quick stroke misses nothing it passed over.
function A.erase_notes(clip, points)
  local c = daw.clip(clip)
  local hit = {}
  local function crosses(n, b0, p0, b1, p1)
    -- Walk the segment in steps finer than a note's height and a 64th.
    local steps = math.max(1, math.ceil(math.max(math.abs(p1 - p0) * 4, math.abs(b1 - b0) * 64)))
    for s = 0, steps do
      local t = s / steps
      local beat, pitch = b0 + (b1 - b0) * t, p0 + (p1 - p0) * t
      if n.start >= 0 and math.floor(pitch + 0.5) == n.pitch and beat >= n.start and beat < n.start + n.length then return true end
    end
    return false
  end
  for place, n in ipairs(c:notes()) do
    for i = 1, #points do
      local a, b = points[i], points[math.min(i + 1, #points)]
      if crosses(n, a[1], a[2], b[1], b[2]) then
        hit[#hit + 1] = place
        break
      end
    end
  end
  if #hit > 0 then
    c:edit_notes({ remove = hit })
    choose(clip, {})
  end
  return #hit
end

--- A drag with the right button down the keyboard: choose every note from
--- `low` to `high` (either way round). `mode` as for `select_note`.
function A.select_pitches(clip, low, high, mode)
  return A.select_notes_box(clip, -1, low, daw.clip(clip).length + 1, high, mode)
end

--- Draw over the velocity strip: `points` are `{ beat, fraction }` as the
--- pointer went (fraction 0 at the bottom, 1 at the top). Each note starting
--- within the stretch drawn over, or within `reach` beats of a click, takes
--- the height drawn above its start; with notes chosen, only those.
function A.draw_velocities(clip, points, reach)
  if #points == 0 then return 0 end
  table.sort(points, function(a, b) return a[1] < b[1] end)
  reach = reach or 0
  local from, to = points[1][1] - reach, points[#points][1] + reach
  local function height(beat)
    if beat <= points[1][1] then return points[1][2] end
    for i = 2, #points do
      local a, b = points[i - 1], points[i]
      if beat <= b[1] then
        return b[1] > a[1] and a[2] + (b[2] - a[2]) * (beat - a[1]) / (b[1] - a[1]) or b[2]
      end
    end
    return points[#points][2]
  end
  local c = daw.clip(clip)
  local only = {}
  local places = M.chosen_notes(clip)
  for _, place in ipairs(places) do only[place] = true end
  local set = {}
  for place, n in ipairs(c:notes()) do
    if (#places == 0 or only[place]) and n.start >= 0 and n.start >= from - 1e-9 and n.start <= to + 1e-9 then
      set[#set + 1] = { index = place, velocity = daw.util.clamp(math.floor(height(n.start) * 127 + 0.5), 1, 127) }
    end
  end
  if #set > 0 then
    c:edit_notes({ set = set })
    if #places > 0 then choose(clip, places) end
  end
  return #set
end

--- The length a click on the grid gives a note, and that insert mode and
--- step input enter: the piano roll's note length. 0 or nil for one grid step.
function A.set_note_length(length)
  daw.ui.views.pianoroll:set_step(length and length > 0 and length or nil)
end

--- The snap button: whether the pointer's notes land on the grid.
function A.toggle_note_snap()
  daw.opt.note_snap = not daw.opt.note_snap
end

--- Quantize: the chosen notes of `clip`, or all of them with none chosen,
--- start on the nearest step of the piano roll's grid, keeping their
--- lengths (a note that would leave the clip stops at its end). `strength`
--- from 0 to 1 moves them that part of the way (1 without).
function A.quantize_notes(clip, strength)
  strength = daw.util.clamp(strength or 1, 0, 1)
  local c = daw.clip(clip)
  local notes = c:notes()
  local places = M.chosen_notes(clip)
  local kept = #places > 0
  if not kept then
    for place in ipairs(notes) do places[place] = place end
  end
  local set, wanted = {}, {}
  for _, place in ipairs(places) do
    local n = notes[place]
    local start = math.max(0, math.min(n.start + (note_snap(n.start) - n.start) * strength, c.length - daw.opt.note_grid))
    set[#set + 1] = { index = place, start = start, length = math.min(n.length, c.length - start) }
    wanted[#wanted + 1] = { start = start, pitch = n.pitch }
  end
  if #set == 0 then return 0 end
  c:edit_notes({ set = set })
  if kept then choose(clip, places_of(clip, wanted)) end
  return #set
end

-- Step input: with it on, the piano roll open and the transport stopped,
-- each note a MIDI keyboard plays is entered at the roll's cursor with the
-- roll's note length. Notes held together make a chord; the cursor steps
-- on when the last of them is let go.
local stepping = { on = false, held = {}, entered = false }

function M.step_input() return stepping.on end

function A.toggle_step_input()
  stepping.on, stepping.held, stepping.entered = not stepping.on, {}, false
  daw.notify(stepping.on and "step input: play notes on a MIDI keyboard to enter them at the cursor" or "step input off")
  api.ui_redraw()
end

daw.on("midi.in", function(event)
  if not stepping.on or not daw.ui.visible("pianoroll") or api.transport_get().playing then return end
  local roll = daw.ui.views.pianoroll
  local clip = roll:clip()
  if not clip or not event.pitch then return end
  if event.type == "note_on" and (event.velocity or 0) > 0 then
    local length = roll:step_length()
    if roll.beat + length > clip.length + 1e-9 then
      clip.length = daw.time.bar_ceil(clip.start + roll.beat + length - 1e-9) - clip.start
    end
    clip:edit_notes({
      remove = roll:starting_here(clip, event.pitch),
      add = { { pitch = event.pitch, start = roll.beat, length = length, velocity = event.velocity } },
    })
    roll.pitch = event.pitch
    stepping.held[event.pitch], stepping.entered = true, true
    api.ui_redraw()
  elseif event.type == "note_off" or event.type == "note_on" then
    stepping.held[event.pitch] = nil
    if stepping.entered and next(stepping.held) == nil then
      stepping.entered = false
      roll:step(1)
    end
  end
end)

--- A click on the piano roll's ruler: the playhead to that beat of the clip.
function A.roll_seek(clip, beat)
  api.transport_seek(math.max(0, daw.clip(clip).start + math.max(0, beat)))
end

-- Automation. A lane is drawn over a stretch of its range (`lane_span`),
-- and a frontend names a height in it as a fraction, 0 at the bottom.

local function lane_value(lane, fraction)
  local lo, hi = M.lane_span(api.lane_get(lane))
  return lo + daw.util.clamp(fraction, 0, 1) * (hi - lo)
end

--- The lane of a track for "volume", "pan", or a parameter (by key) of one
--- of its devices: the one there is, or a new one.
function A.lane(track, target, device, param)
  for _, lane in ipairs(api.lane_list(track)) do
    if lane.target == target and (target ~= "param" or (lane.device == device and lane.param == param)) then
      return lane.id
    end
  end
  return api.lane_add(track, { target = target, device = device, param = param })
end

function A.add_point(lane, beat, fraction)
  api.lane_add_point(lane, snap(beat), lane_value(lane, fraction))
end

function A.move_point(lane, index, beat, fraction)
  local points = api.lane_points(lane)
  table.remove(points, index)
  points[#points + 1] = { snap(beat), lane_value(lane, fraction) }
  api.lane_set_points(lane, points)
end

--- Draw over a lane with a pencil: `points` are `{ beat, fraction }` as
--- they were drawn. They replace what the lane held over the stretch drawn
--- across, at most one to a quarter of a grid step.
function A.draw_lane(lane, points)
  if #points == 0 then return end
  table.sort(points, function(a, b) return a[1] < b[1] end)
  local step = daw.opt.grid / 4
  local from, to = math.max(0, points[1][1]), math.max(0, points[#points][1])
  local out = {}
  for _, p in ipairs(api.lane_points(lane)) do
    if p[1] < from - 1e-9 or p[1] > to + 1e-9 then out[#out + 1] = p end
  end
  local last
  for i, p in ipairs(points) do
    local beat = math.max(0, p[1])
    if not last or beat - last >= step - 1e-9 or i == #points then
      out[#out + 1] = { beat, lane_value(lane, p[2]) }
      last = beat
    end
  end
  api.lane_set_points(lane, out)
end

function A.toggle_lane(lane)
  api.lane_set(lane, "enabled", not api.lane_get(lane).enabled)
end

function A.clear_lane(lane)
  api.lane_set_points(lane, {})
end

-- Controller moves in a MIDI clip: the pitch wheel, pressure, or a control
-- change by number. Heights are fractions, 0 at the bottom; the wheel rests
-- in the middle.

local function control_value(kind, fraction)
  fraction = daw.util.clamp(fraction, 0, 1)
  return kind == "bend" and fraction * 2 - 1 or fraction
end

--- Draw controller moves with a pencil: `points` are `{ beat, fraction }`
--- in the clip. They replace the moves of that kind over the stretch drawn
--- across, one to a note-grid step.
function A.draw_controls(clip, kind, number, points)
  if #points == 0 then return end
  table.sort(points, function(a, b) return a[1] < b[1] end)
  local c = daw.clip(clip)
  local grid = daw.opt.note_grid
  local from, to = note_snap(points[1][1]), note_snap(points[#points][1])
  local same = function(control)
    return control.type == kind and control.key == nil and (kind ~= "cc" or control.number == number)
  end
  local out = {}
  for _, control in ipairs(c:controls()) do
    if not (same(control) and control.start >= from - 1e-9 and control.start <= to + 1e-9) then out[#out + 1] = control end
  end
  -- Each step takes the height drawn nearest to it.
  local steps, nearest = {}, {}
  for _, p in ipairs(points) do
    local at = note_snap(p[1])
    local off = math.abs(p[1] - at)
    if not nearest[at] or off < nearest[at] then steps[at], nearest[at] = p[2], off end
  end
  for beat = from, to + 1e-9, grid do
    local fraction = steps[note_snap(beat)]
    if fraction and beat < c.length then
      out[#out + 1] = { start = note_snap(beat), type = kind, number = kind == "cc" and number or nil, value = control_value(kind, fraction) }
    end
  end
  c:set_controls(out)
end

--- Remove the moves of one kind from a clip.
function A.clear_controls(clip, kind, number)
  local c = daw.clip(clip)
  local out = {}
  for _, control in ipairs(c:controls()) do
    if not (control.type == kind and control.key == nil and (kind ~= "cc" or control.number == number)) then out[#out + 1] = control end
  end
  c:set_controls(out)
end

function A.remove_point(lane, index)
  local points = api.lane_points(lane)
  table.remove(points, index)
  api.lane_set_points(lane, points)
end

-- Devices.

local function param_of(device, key)
  for _, p in ipairs(api.device_get(device).param_info) do
    if p.key == key then return p end
  end
  error("the device has no parameter `" .. tostring(key) .. "`", 3)
end

--- Set a parameter from a slider's position, 0 to 1 across its range.
function A.set_param(device, key, fraction)
  local p = param_of(device, key)
  api.device_set_param(device, key, daw.params.from_fraction(p, fraction))
end

--- Back to where the device starts out: a double click on a slider.
function A.reset_param(device, key)
  api.device_set_param(device, key, param_of(device, key).default)
end

function A.toggle_bypass(device)
  api.device_set(device, "bypass", not api.device_get(device).bypass)
end

function A.add_device(kind, query)
  return daw.fx.add(assert(daw.cursor.track(), "no track selected"), kind, { query = query }).id
end

--- Move a device one place earlier (-1) or later (1) in its track's chain.
function A.move_device(device, by)
  local d = api.device_get(device)
  api.device_move(device, d.track, daw.util.clamp(d.index + by, 1, #api.track_get(d.track).devices))
end

return M
