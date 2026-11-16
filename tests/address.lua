-- Tests of daw.address: a URI for everything, notes that keep their names,
-- workspace edits, address kinds of an extension's own, change events.
-- Loaded by tests/suite.lua with its helpers.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = daw.api
local A = daw.address

local function ids(clip)
  local out = {}
  for _, n in ipairs(clip:notes()) do out[#out + 1] = n.pitch .. "#" .. tostring(n.id) end
  return table.concat(out, " ")
end

test("address: every note has an id that stays with it through moves, and a copy gets its own", function()
  fresh()
  local clip = daw.add_track({ name = "Keys" }):add_clip({ start = 0, length = 4,
    notes = { { pitch = 60, start = 0, length = 1 }, { pitch = 64, start = 1, length = 1 } } })
  daw.flush()
  api.undo_checkpoint()
  eq(ids(clip), "60#1 64#2", "named in order")
  -- A note moved before the other keeps its name.
  clip:set_note(2, { start = 0, pitch = 55 })
  daw.flush()
  api.undo_checkpoint()
  eq(ids(clip), "55#2 60#1", "moved, its name with it")
  -- A copy pasted beside it is another note.
  local notes = clip:notes()
  notes[#notes + 1] = daw.util.merge(notes[1], { start = 3 })
  clip:set_notes(notes)
  daw.flush()
  api.undo_checkpoint()
  eq(ids(clip), "55#2 60#1 55#3", "the copy is named anew")
  daw.undo()
  eq(ids(clip), "55#2 60#1", "undo brings back the names it had")
  local uri = A.note(clip.id, 1)
  eq(A.resolve(uri).pitch, 60, "a note's address finds it wherever it went")
  eq(A.resolve(uri).place, 2, "and says its place")
end)

test("address: addresses are made, resolved, and walked up and down", function()
  fresh()
  local t = daw.add_track({ name = "Bass" })
  local d = t:add_device("synth")
  local clip = t:add_clip({ start = 0, length = 4, notes = { { pitch = 40, start = 0, length = 1 } } })
  daw.flush()
  local other = daw.add_track({ name = "Bus" })
  t.sends = { { target = other.id, level = -6 } }
  daw.flush()
  eq(A.of(t), "daw://track/" .. t.id, "a track")
  eq(A.of(daw.device(d.id)), "daw://track/" .. t.id .. "/device/" .. d.id, "a device, under its track")
  eq(A.of(clip), "daw://clip/" .. clip.id, "a clip")
  eq(A.of(api.clip_get(clip.id)), "daw://clip/" .. clip.id, "or what daw.api gives")
  local param = A.param(d.id, "cutoff")
  eq(A.resolve(param).key, "cutoff", "a parameter")
  eq(A.resolve(param).value, api.device_get(d.id).params.cutoff, "with its value")
  eq(A.resolve(A.send(t.id, other.id)).level, -6, "a send")
  eq(A.resolve(A.track(0)).name, api.track_get(0).name, "the master")
  eq(A.resolve("daw://track/999"), nil, "what is gone resolves to nothing")
  eq(A.resolve("http://example.com"), nil, "nor what is not an address")
  eq(A.parent(param), "daw://track/" .. t.id .. "/device/" .. d.id, "a parameter's parent")
  eq(A.parent(A.clip(clip.id)), A.track(t.id), "a clip's")
  eq(A.parent(A.note(clip.id, 1)), A.clip(clip.id), "a note's")
  eq(A.within(A.note(clip.id, 1), A.track(t.id)), true, "a note lies within its track")
  eq(A.within(A.clip(clip.id), A.track(other.id)), false, "not another's")
  eq(A.track_of(param), t.id, "a parameter's track")
  local kids = table.concat(A.children(A.track(t.id)), " ")
  eq(kids:find("/device/" .. d.id, 1, true) ~= nil and kids:find("/send/" .. other.id, 1, true) ~= nil
    and kids:find("daw://clip/" .. clip.id, 1, true) ~= nil, true, "a track holds its devices, sends and clips: " .. kids)
  eq(A.children(A.clip(clip.id))[1], A.note(clip.id, 1), "a clip its notes")
  eq(A.parse(A.render("/tmp/a mix.wav")).path, "/tmp/a mix.wav", "a render's path survives the encoding")
  eq(A.matches("daw://track/*", A.track(3)), true, "a pattern of one level")
  eq(A.matches("daw://track/*", param), false, "not deeper")
  eq(A.matches("daw://track/**", param), true, "unless asked")
end)

test("address: a workspace edit is checked whole and made as one undo step", function()
  fresh()
  local t = daw.add_track({ name = "Lead" })
  local d = t:add_device("synth")
  local clip = t:add_clip({ start = 0, length = 4, notes = { { pitch = 60, start = 0, length = 1 }, { pitch = 62, start = 1, length = 1 } } })
  daw.flush()
  api.undo_checkpoint()
  local before = api.project_get().edits
  local ok, why = A.edit({
    { uri = A.track(t.id), set = { volume = -6 } },
    { uri = A.note(clip.id, 2), set = { pitch = 61 } },
    { uri = "daw://track/999", set = { volume = 0 } },
  }, "Nothing")
  eq(ok, nil, "refused")
  eq(why, "daw://track/999 is gone", "with why")
  eq(api.project_get().edits, before, "and nothing was done")
  eq(select(2, A.edit({ { uri = A.track(t.id), set = { colour = 1 } } })), "daw://track/" .. t.id .. ": cannot set `colour`", "an unknown field is refused")
  ok = A.edit({
    { uri = A.track(t.id), set = { volume = -6, pan = 0.25 } },
    { uri = A.note(clip.id, 2), set = { pitch = 61 } },
    { uri = A.note(clip.id, 1), delete = true },
    { uri = A.clip(clip.id), insert = { pitch = 67, start = 3, length = 1 } },
    { uri = A.param(d.id, "cutoff"), set = { value = 1000 } },
    { uri = A.device(d.id), set = { bypass = true } },
    { uri = A.track(t.id), insert = { device = "delay" } },
  }, "Everything at once")
  eq(ok, true, "made")
  daw.flush()
  api.undo_checkpoint()
  local tr = api.track_get(t.id)
  eq(tr.volume .. " " .. tr.pan, "-6 0.25", "the track")
  eq(ids(clip), "61#2 67#3", "the notes")
  eq(api.device_get(d.id).params.cutoff, 1000, "the parameter")
  eq(api.device_get(d.id).bypass, true, "the device")
  eq(#tr.devices, 2, "a device inserted")
  daw.undo()
  tr = api.track_get(t.id)
  eq(tr.volume .. " " .. #tr.devices .. " " .. ids(clip), "0 1 60#1 62#2", "one undo takes all of it back")
end)

test("address: an extension adds a kind of address, and it is edited like the others", function()
  fresh()
  local words = { [1] = "la", [2] = "lu" }
  A.scheme("lyric", {
    resolve = function(_, p) local w = words[tonumber(p.segments[2])] return w and { text = w } end,
    children = function() return { "daw://lyric/1", "daw://lyric/2" } end,
    edit = function(change, p) words[tonumber(p.segments[2])] = change.set.text end,
  })
  eq(A.resolve("daw://lyric/2").text, "lu", "resolved by the extension")
  eq(A.parent("daw://lyric/2"), "daw://project", "inside the project")
  eq(#A.children("daw://lyric"), 2, "its children")
  eq(A.edit({ { uri = "daw://lyric/1", set = { text = "lo" } } }), true, "edited")
  eq(words[1], "lo", "by the extension")
  A.schemes.lyric = nil
end)

test("address: changes are told as addresses, and renders are kept by path", function()
  fresh()
  local seen = {}
  local handler = daw.on("address.changed", function(e) for _, u in ipairs(e.uris) do seen[u] = true end end)
  local t = daw.add_track({ name = "Pad" })
  daw.flush()
  t.volume = -3
  daw.flush()
  daw.off(handler)
  eq(seen[A.track(t.id)], true, "the track's address")
  eq(seen[A.project()], true, "and the project's")
  local path = T.scratch .. "/address.wav"
  t:add_device("synth")
  t:add_clip({ start = 0, length = 1, notes = { { pitch = 60, start = 0, length = 1 } } })
  daw.render(path, { bits = 16, tail = 0 })
  local r = A.resolve(A.render(path))
  eq(r and r.bits, 16, "the render, with what it was")
  eq(r.opts.bits, 16, "and what it was asked")
end)
