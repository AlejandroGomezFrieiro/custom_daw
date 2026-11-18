-- Tests of the arrange view as a window shows it: from its scene (its
-- timeline a plane of beats and lines, each clip on it a role a window
-- paints between cells, its headers' switches and levels widgets), with
-- the pointer coming back in fractions of a cell (`scene.input`) to the
-- same gestures the terminal's mouse reaches. Loaded by tests/suite.lua
-- with its helpers.
local T = ...
local test, eq, near, fresh = T.test, T.eq, T.near, T.fresh
local api = paw.api
local view = paw.ui.views.arrange

local W, H, CELL = 160, 40, { w = 8, h = 17 }
local ROLES = { "clip", "beats", "curve", "hmeter", "peak", "switch", "playhead" }

-- What the window's watcher keeps of a drag under way.
local held = {}

--- Draw the arrange view's scene for a window that paints its roles, as
--- the kernel sends it.
local function redraw()
  paw.ui.render_scene("arrange", W, H, CELL)
  local patch = api.scene_end(0, "arr")
  return patch and api.json_decode(patch)
end

--- Two tracks, a MIDI clip on the first from beat 4 to 8, an audio clip
--- on the second from 8 to 12, at three columns a beat; and where a beat
--- is on a track's row in the window's units (`dy` lines under its top).
local function song()
  fresh()
  paw.keymap.feed("<Esc><Esc>")
  local saved = { zoom = paw.opt.zoom, grid = paw.opt.grid, height = paw.opt.track_height }
  T.after(function()
    paw.opt.zoom, paw.opt.grid, paw.opt.track_height = saved.zoom, saved.grid, saved.height
    paw.mouse.forget()
    api.scene_forget(0)
  end)
  paw.opt.zoom, paw.opt.grid, paw.opt.track_height = 3, 1, 4
  local a, b = paw.add_track({ name = "keys" }), paw.add_track({ name = "loop" })
  local riff = a:add_clip({ name = "riff", start = 4, length = 4, notes = { { pitch = 60, start = 0, length = 1 } } })
  local samples = {}
  for i = 1, 48000 * 4 do samples[i] = 0.25 * math.sin(i / 20) end
  local wav = b:add_clip({ name = "wav", file = T.write_wav(T.scratch .. "/arrange-scene.wav", samples), start = 8, length = 4 })
  paw.flush()
  view.scroll, view.top = 0, 1
  api.undo_checkpoint()
  api.scene_forget(0)
  api.scene_roles(0, ROLES)
  redraw()
  local function at(track, beat, dy)
    local g = view.geometry
    for _, row in ipairs(g.layout.rows) do
      if row.kind == "track" and row.id == track.id then return g.hw + (beat - view.scroll) * g.zoom, row.y + (dy or 1.5) end
    end
  end
  return a, b, riff, wav, at
end

--- A pointer event from the window, in units of the arrange view's window;
--- then the view drawn again, as the kernel does after a turn.
local function input(kind, x, y, extra)
  local e = { kind = kind, x = x, y = y, button = "left" }
  for k, v in pairs(extra or {}) do e[k] = v end
  local taken = paw.roles.input(0, "arr", view, nil, e, held)
  api.undo_checkpoint()
  redraw()
  return taken
end

local function drag(x0, y0, x1, y1, extra)
  input("down", x0, y0, extra)
  for i = 1, 4 do input("move", x0 + (x1 - x0) * i / 4, y0 + (y1 - y0) * i / 4, extra) end
  input("up", x1, y1, extra)
end

--- The nodes of the scene a window that paints the arrange view's roles
--- is sent, by role.
local function nodes_of(role)
  api.scene_forget(0)
  local patch = redraw()
  local out = {}
  for _, n in ipairs(patch.set) do
    if n.role == role then out[#out + 1] = n end
  end
  return out
end

test("the arrange view's scene: its timeline a plane, each clip on it a role between cells, its headers' controls widgets", function()
  local a, _, riff, wav = song()
  api.scene_forget(0)
  local patch = redraw()
  local plane
  for _, n in ipairs(patch.set) do
    if n.t == "plane" then plane = n end
  end
  eq(plane ~= nil and plane.x.domain .. " " .. plane.y.domain, "beat line", "the timeline, a plane of beats along and the view's lines down")
  eq(plane.x.per .. " " .. plane.x.from, "3 0", "three units a beat from the left edge")
  local clips = {}
  for _, n in ipairs(nodes_of("clip")) do clips[n.props.id] = n end
  local row = view.geometry.layout.rows[1]
  eq(api.json_encode(clips[riff.id].r), api.json_encode({ 4, row.y, 4, row.h }), "a clip where it is in the plane's domain")
  eq(clips[riff.id].props.midi and clips[riff.id].props.content ~= nil, true, "with the key of what it shows")
  eq(clips[wav.id].props.midi, false, "an audio clip")
  eq(clips[wav.id].props.fade_in .. " " .. clips[wav.id].props.gain, "0 0", "with its fades and gain")
  local letters = {}
  for _, n in ipairs(nodes_of("switch")) do letters[#letters + 1] = n.props.letter end
  eq(table.concat(letters):sub(1, 4), "MSRI", "a header's switches")
  local bound = {}
  for _, n in ipairs(nodes_of("hmeter")) do bound[#bound + 1] = n.bind end
  eq(table.concat(bound, " "):find("meter:" .. a.id, 1, true) ~= nil, true, "a header's level, bound to the track's meter: " .. table.concat(bound, " "))
  eq(nodes_of("playhead")[1].bind, "position", "the playhead, bound to the position")
  eq(#nodes_of("beats") >= 2, true, "each row's ground with its lines")
end)

test("in a window a clip dragged by fractions of a cell moves on the grid by the beats it went, and to another track", function()
  local _, b, riff, _, at = song()
  local x, y = at(riff:track(), 5.2)
  drag(x, y, x + 0.4, y)
  eq(riff:get().start, 4, "a click that wavers moves nothing")
  eq(paw.frontend.chosen_clips()[1], riff.id, "and chooses it")
  -- Not the second press of a double click.
  paw.mouse.forget()
  drag(x, y, x + 2.4 * 3, y)
  eq(riff:get().start, 6, "two beats and a bit on, on the grid")
  x, y = at(riff:track(), 7.2)
  local _, y1 = at(b, 7.2)
  paw.mouse.forget()
  drag(x, y, x, y1)
  eq(paw.clip(riff.id):get().track, b.id, "a row down, onto the next track")
end)

test("in a window either end of a clip is trimmed from within a cell of it", function()
  local _, _, riff, _, at = song()
  local x, y = at(riff:track(), 4)
  drag(x + 0.3, y, x + 0.3 + 3, y)
  eq(riff:get().start .. "+" .. riff:get().length, "5+3", "its start, a beat on")
  x = at(riff:track(), 8)
  drag(x - 0.3, y, x - 0.3 + 6, y)
  eq(riff:get().start .. "+" .. riff:get().length, "5+5", "its end, two beats on")
end)

test("in a window an audio clip's fade handle and gain line take the pointer, which a terminal cell is too big for", function()
  local _, b, _, wav, at = song()
  local x, y = at(b, 8, 0.2)
  drag(x + 0.2, y, x + 0.2 + 3, y)
  near(wav:get().fade_in, 1, 0.05, "the fade in, a beat long")
  eq(wav:get().start, 8, "and the clip where it was")
  x = at(b, 12)
  drag(x - 0.2, y, x - 0.2 - 1.5, y)
  near(wav:get().fade_out, 0.5, 0.05, "the fade out, half a beat")
  x = at(b, 10)
  y = select(2, at(b, 10, 0.15))
  drag(x, y, x, y - 1)
  near(wav:get().gain, 4, 0.01, "the gain up four dB, a line")
end)

test("in a window the header's switches and its volume take the pointer", function()
  local a, _, _, _, at = song()
  local _, y = at(a, 0, 0.5)
  input("down", view.flags.mute + 0.4, y)
  input("up", view.flags.mute + 0.4, y)
  eq(a:get().mute, true, "M mutes it")
  local x = view.geometry.hw - 6
  drag(x, y + 1, x + 3.5, y + 1)
  near(a:get().volume, 3.5, 0.01, "the volume, a dB a column")
end)

test("in a window the ruler puts the playhead on the step under the pointer, a drag loops, and Ctrl and the wheel zoom about the pointer", function()
  local a, _, _, _, at = song()
  local x = at(a, 6.5)
  input("down", x, 0.5)
  input("up", x, 0.5)
  eq(api.transport_get().position, 6, "the playhead on the step under the pointer")
  -- On a grid of quarter beats: where the pointer was, not the cells it
  -- was in (which would be 2 to 5.75).
  paw.opt.grid = 0.25
  paw.mouse.forget()
  drag(at(a, 2.2), 0.5, at(a, 5.6), 0.5)
  local t = api.transport_get()
  eq(t.loop_start .. " " .. t.loop_end, "2.25 5.5", "the loop from where the drag began to where it ended, on the grid")
  x = at(a, 8)
  input("wheel", x, 10, { dy = 1, ctrl = true })
  eq(paw.opt.zoom > 3, true, "zoomed in")
  near(view.scroll + (x - view.geometry.hw) / paw.opt.zoom, 8, 0.01, "the beat under the pointer where it was")
end)

test("the arrange view moves on its own only by its live roles, but for the playhead leaving it", function()
  song()
  eq(table.concat(view.live_roles, " "), "playhead hmeter peak", "the playhead and the meters")
  eq(view:moves(), false, "stopped, it does not move")
end)
