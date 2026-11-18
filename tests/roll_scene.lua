-- Tests of the piano roll as a window shows it: from its scene (its grid a
-- plane of beats and pitches, each note on it a role a window paints
-- between cells), with the pointer coming back in fractions of a cell
-- (`scene.input`) to the same gestures the terminal's mouse reaches.
-- Loaded by tests/suite.lua with its helpers.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = paw.api
local roll = paw.ui.views.pianoroll

local W, H, CELL = 120, 30, { w = 8, h = 16 }

-- What the window's watcher keeps of a drag under way.
local held = {}

--- Draw the roll's scene for a window that paints notes and buttons, as
--- the kernel sends it.
local function redraw()
  paw.ui.render_scene("pianoroll", W, H, CELL)
  local patch = api.scene_end(0, "roll")
  return patch and api.json_decode(patch)
end

--- A clip of two bars open in the roll with notes as given; and where a
--- pitch and a beat are in the window's units (the middle of the row).
local function opened(notes)
  fresh()
  paw.keymap.feed("<Esc><Esc>")
  local saved = { zoom = paw.opt.note_zoom, grid = paw.opt.note_grid, snap = paw.opt.note_snap }
  T.after(function()
    paw.opt.note_zoom, paw.opt.note_grid, paw.opt.note_snap = saved.zoom, saved.grid, saved.snap
    roll:set_step(nil)
    paw.mouse.forget()
    api.scene_forget(0)
    paw.ui.hide("pianoroll")
  end)
  paw.opt.note_zoom, paw.opt.note_grid, paw.opt.note_snap = 8, 0.25, true
  local t = paw.add_track({ name = "keys" })
  local clip = t:add_clip({ name = "riff", start = 0, length = 8, notes = notes or {} })
  roll:edit(clip)
  roll.top, roll.scroll, roll.pitch, roll.beat = 72, 0, 60, 0
  api.undo_checkpoint()
  api.scene_forget(0)
  api.scene_roles(0, { "note", "button" })
  redraw()
  local g = roll.geometry
  local function at(pitch, beat) return g.keys + (beat - roll.scroll) * g.zoom, g.head + (roll.top - pitch) + 0.5 end
  return clip, at
end

--- A pointer event from the window, in units of the roll's window; then
--- the roll drawn again, as the kernel does after a turn.
local function input(kind, x, y, extra)
  local e = { kind = kind, x = x, y = y, button = "left" }
  for k, v in pairs(extra or {}) do e[k] = v end
  local taken = paw.roles.input(0, "roll", roll, nil, e, held)
  api.undo_checkpoint()
  redraw()
  return taken
end

local function drag(x0, y0, x1, y1, extra)
  input("down", x0, y0, extra)
  for i = 1, 4 do input("move", x0 + (x1 - x0) * i / 4, y0 + (y1 - y0) * i / 4, extra) end
  input("up", x1, y1, extra)
end

local function notes_of(clip)
  local out = {}
  for _, n in ipairs(clip:notes()) do out[#out + 1] = string.format("%d@%g+%g", n.pitch, n.start, n.length) end
  return table.concat(out, " ")
end

test("the roll's scene: its grid a plane, each note on it a role, and a row of tools as buttons", function()
  local clip = opened({ { pitch = 60, start = 1.5, length = 0.5, velocity = 90 } })
  local patch
  api.scene_forget(0)
  patch = redraw()
  local plane, note, tools = nil, nil, {}
  for _, n in ipairs(patch.set) do
    if n.t == "plane" and n.hit and n.hit.kind == "grid" then plane = n end
    if n.role == "note" then note = n end
    if n.role == "button" then tools[#tools + 1] = n.props.label end
  end
  eq(plane ~= nil and plane.x.domain .. " " .. plane.y.domain, "beat pitch", "the grid, a plane of beats and pitches")
  eq(plane.x.per .. " " .. plane.y.from .. " " .. plane.y.per, "8 73 -1", "eight units a beat, a row a pitch down from the top")
  eq(api.json_encode(note.r), "[1.5,60,0.5,1]", "the note where it is in the plane's domain, between cells")
  eq(note.hit.clip .. " " .. note.hit.place, clip.id .. " 1", "named by its clip and place for the pointer")
  eq(note.props.label .. " " .. note.props.velocity, "C4 90", "with what a window paints it by")
  eq(table.concat(tools, " "):find("quantize step list", 1, true) ~= nil, true, "the tools: " .. table.concat(tools, " "))
end)

test("in a window a press on empty grid draws a note on the step under the pointer, and a drag draws it as long", function()
  local clip, at = opened()
  local x, y = at(64, 1.1)
  input("down", x, y)
  input("up", x, y)
  eq(notes_of(clip), "64@1+0.25", "a click: one step, on the step the pointer was in")
  x, y = at(67, 2.05)
  local x1 = at(67, 2.9)
  drag(x, y, x1, y)
  eq(notes_of(clip), "64@1+0.25 67@2+1", "to the end of the step it was let go in")
end)

test("in a window a note wavering under a click is only chosen, and a drag moves it by the beats and rows the pointer went", function()
  local clip, at = opened({ { pitch = 60, start = 0, length = 1 } })
  local x, y = at(60, 0.5)
  drag(x, y, x + 0.3, y + 0.2)
  eq(paw.frontend.chosen_notes(clip.id)[1], 1, "chosen")
  eq(notes_of(clip), "60@0+1", "and left where it was")
  paw.mouse.forget()
  drag(x, y, x + 8, y - 2)
  eq(notes_of(clip), "62@1+1", "a beat on and two semitones up")
end)

test("in a window the end of a note drags by a fraction of a cell", function()
  local clip, at = opened({ { pitch = 60, start = 1, length = 1 } })
  -- Within the last unit of the note's eight: its end.
  local x, y = at(60, 1.95)
  drag(x, y, x + 4, y)
  eq(notes_of(clip), "60@1+1.5", "half a beat longer")
end)

test("in a window the velocity strip is drawn on and a tool of the row is clicked", function()
  local clip, at = opened({ { pitch = 60, start = 0.1, length = 1 }, { pitch = 62, start = 1, length = 1 } })
  local g = roll.geometry
  eq(g.vel > 0, true, "the strip shows")
  local top = g.head + g.rows
  local x0, x1 = at(60, 0.1), at(62, 1)
  drag(x0, top + 0.1, x1, top + 0.1)
  eq(clip:notes()[1].velocity > 110 and clip:notes()[2].velocity > 110, true, "both near the top")
  -- The quantize button, where the row of tools has it.
  local snap = api.ui_view_snapshot("pianoroll", W, H)
  local row, text = snap.rows[2], ""
  for _, run in ipairs(row) do text = text .. run.text end
  local col = text:find(" quantize ", 1, true)
  eq(col ~= nil, true, "the row of tools: " .. text)
  input("down", col + 2.5, 1.5)
  input("up", col + 2.5, 1.5)
  eq(notes_of(clip), "60@0+1 62@1+1", "the notes quantized")
end)

test("a right click in a window on empty grid opens the grid's menu, which the window is told of and chooses from", function()
  local clip, at = opened({ { pitch = 60, start = 0, length = 1 }, { pitch = 62, start = 1, length = 1 } })
  local x, y = at(66, 4)
  input("down", x, y, { button = "right" })
  input("up", x, y, { button = "right" })
  local items, count = require("paw.menu").shown()
  eq(items ~= nil, true, "a menu is open")
  eq(paw.frontend.state(-1).modal.menu, count, "the window is told of it")
  local listed = paw.frontend.menu("shown", {})
  eq(listed[1].label, "Choose every note", "and shows its entries")
  paw.frontend.act.menu_choose("shown", {}, { 1 })
  eq(#paw.frontend.chosen_notes(clip.id), 2, "its first chooses every note")
  eq(require("paw.menu").shown(), nil, "and the menu is let go")
  input("down", x, y, { button = "right" })
  input("up", x, y, { button = "right" })
  paw.frontend.act.menu_dismiss()
  eq(require("paw.menu").shown(), nil, "the window letting go of it lets go of it here too")
end)

test("the roll's row of tools works from the terminal too", function()
  local clip = opened({ { pitch = 60, start = 0.1, length = 1 } })
  paw.ui.show("pianoroll")
  paw.ui.focus("pianoroll")
  api.ui_snapshot(W, 40)
  local rect
  for _, r in ipairs(paw.ui.rects) do if r.name == "pianoroll" then rect = r end end
  local snap = api.ui_snapshot(W, 40)
  local text = snap[rect.y + 2]
  local col = text and text:find("quantize", 1, true)
  eq(col ~= nil, true, "the row under the title: " .. tostring(text))
  local x = paw.api.str_width(text:sub(1, col - 1)) + 1
  paw.ui.mouse({ kind = "down", x = x, y = rect.y + 1, button = "left", mods = "" })
  paw.ui.mouse({ kind = "up", x = x, y = rect.y + 1, button = "left", mods = "" })
  eq(notes_of(clip), "60@0+1", "quantized")
end)
