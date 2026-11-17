-- Tests of what the extensions' review turned up in notation: a clip undone
-- out of existence under the view, entry at the top of the MIDI range.
-- Loaded by tests.lua.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local paw = require("paw")
local api = paw.api

local function load()
  if not package.loaded["notation.keys"] then paw.ext.load("extensions/notation") end
  return require("notation"), require("notation.model")
end

local function N(pitch, start, length, velocity) return { pitch = pitch, start = start, length = length, velocity = velocity or 80 } end

--- A track with a clip open as notation.
local function song(notes, length)
  fresh()
  local view = load()
  local track = paw.add_track({ name = "Lead" })
  local clip = track:add_clip({ start = 0, length = length or 8, name = "tune", notes = notes or {} })
  paw.flush()
  paw.keymap.set_mode("n")
  view:edit(clip)
  view.value, view.dot, view.voice, view.triplets, view.tuplet = 1, false, 1, false, nil
  api.undo_checkpoint()
  return view, clip, track
end

--- The errors shown since message `from`.
local function errors(from)
  local out = {}
  for i = from + 1, #paw.ui.messages do
    local m = paw.ui.messages[i]
    if m.level == "error" then out[#out + 1] = m.text:match("[^\n]*") end
  end
  return out
end

local LEAVE = { ZZ = true, ["<leader>n"] = true, gT = true }

test("notation: every key of the view says the clip is gone when an undo took it, and a redo brings it back", function()
  fresh()
  local view = load()
  api.undo_checkpoint()
  local track = paw.add_track({ name = "Lead" })
  local clip = track:add_clip({ start = 0, length = 4, notes = { N(60, 0, 1), N(64, 1, 1) } })
  paw.flush()
  api.undo_checkpoint()
  paw.ui.focus("notation")
  paw.keymap.set_mode("n")
  view:edit(clip)
  paw.undo()
  eq(view:clip(), nil, "the clip is gone")
  local screen = table.concat(api.ui_snapshot(120, 30), "\n")
  eq(screen:find("gone: undone or deleted", 1, true) ~= nil, true, "the view says so")
  local from, tried = #paw.ui.messages, 0
  for _, m in ipairs(paw.keymap.list("n", "notation")) do
    if m.scope == "notation" and not LEAVE[m.lhs] then
      paw.ui.focus("notation")
      paw.keymap.set_mode("n")
      paw.keymap.feed(m.lhs .. "<Esc>")
      tried = tried + 1
    end
  end
  eq(tried > 100, true, "every key of the view was tried: " .. tried)
  eq(table.concat(errors(from), "; "), "", "no key raised an error")
  T.keys("G")
  eq(paw.ui.message.text:find("gone (undone or deleted)", 1, true) ~= nil, true, "G says the clip is gone")
  paw.redo()
  eq(view:clip() and view:clip().id, clip.id, "a redo shows it again")
  paw.ui.focus("arrange")
end)

test("notation: entering and moving notes at the top of the MIDI range stops at G9 and raises no error", function()
  local view, clip = song({}, 4)
  paw.ui.focus("notation")
  local from = #paw.ui.messages
  view:set(72, 0)
  T.keys("ieabgab<Esc>")
  T.keys("0kkkkk<C-a><C-a>")
  T.keys("0vwKK<Esc>")
  T.keys("0i3456<Esc>")
  T.keys("0>>")
  eq(table.concat(errors(from), "; "), "", "no error")
  for _, n in ipairs(clip:notes()) do eq(n.pitch <= 127, true, "every pitch within MIDI: " .. n.pitch) end
  eq(#clip:notes() > 0, true, "the notes that fit were entered")
  paw.ui.focus("arrange")
end)
