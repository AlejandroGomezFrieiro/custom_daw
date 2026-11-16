-- Tests of the piano roll's insert mode drawing a note with the cursor
-- (`daw.roll_draw`), and of the other way, the keyboard as a piano. Loaded
-- by tests/suite.lua with its helpers.
local T = ...
local eq, fresh, melody = T.eq, T.fresh, T.melody
local api = daw.api
local draw = daw.roll_draw
local roll = daw.ui.views.pianoroll

-- Each test leaves the piano roll as it found it: closed, the keyboard in
-- the arrange view, in normal mode, insert mode drawing.
local function test(name, fn)
  T.test(name, function()
    local ok, err = xpcall(fn, debug.traceback)
    daw.keymap.feed("<Esc><Esc>")
    daw.roll_clips.only()
    daw.opt.roll_insert = "draw"
    daw.ui.hide("pianoroll")
    daw.ui.focus("arrange")
    if not ok then error(err, 0) end
  end)
end

--- Type keys one at a time, as a person does: the kernel closes the undo
--- step after each.
local function typed(text)
  for _, key in ipairs(daw.keymap.parse(text)) do
    daw.keymap.feed(key)
    api.undo_checkpoint()
  end
end

--- A track with an empty clip four beats long, open in the piano roll with
--- the cursor on C4 at its start.
local function empty()
  fresh()
  daw.keymap.feed("<Esc><Esc>")
  while daw.ui.float do daw.ui.close() end
  daw.ui.focus("arrange")
  daw.opt.note_grid, daw.opt.velocity, daw.opt.note_zoom = 0.25, 100, 8
  local track = daw.add_track({ name = "Lead" })
  track:add_device("synth")
  local clip = track:add_clip({ name = "tune", start = 0, length = 4 })
  api.undo_checkpoint()
  daw.ui.show("pianoroll")
  roll:edit(clip)
  roll:set(60, 0)
  return clip, track
end

local function at() return roll.pitch .. "@" .. roll.beat end

test("i l l Escape on C with no note there writes a C two grid steps long", function()
  local clip = empty()
  typed("i")
  eq(daw.keymap.mode, "i", "i starts insert mode")
  eq(select(2, draw.text()), "60@0+0", "with a note at the cursor, nothing long yet")
  typed("ll")
  eq(select(2, draw.text()), "60@0+0.5", "each l makes it a grid step longer")
  eq(at(), "60@0.5", "and the cursor follows its end")
  eq(melody(clip), "", "nothing is written while it is drawn")
  typed("<Esc>")
  eq(melody(clip), "60@0+0.5", "Escape writes it")
  eq(clip:notes()[1].velocity, 100, "as loud as the velocity option")
  eq(daw.keymap.mode, "n", "and leaves insert mode")
end)

test("l and h grow and shrink the note by grid steps, with counts and the arrows", function()
  local clip = empty()
  typed("i4l")
  eq(select(2, draw.text()), "60@0+1", "4l: four steps, a beat")
  typed("h")
  eq(select(2, draw.text()), "60@0+0.75", "h a step shorter")
  typed("<Right><Right><Left>")
  eq(select(2, draw.text()), "60@0+1", "the arrows too")
  typed("12l")
  eq(select(2, draw.text()), "60@0+4", "a count of two digits")
  typed("20h")
  eq(select(2, draw.text()), "60@0+0", "no shorter than nothing")
  local edits = api.project_get().edits
  typed("<Esc>")
  eq(melody(clip), "", "a note of no length is not written")
  eq(api.project_get().edits, edits, "and nothing changes")
  daw.opt.note_grid = 0.5
  typed("i3l<Esc>")
  eq(melody(clip), "60@0+1.5", "the step is the piano roll's grid")
end)

test("j and k move the note being drawn by semitones, J and K by octaves", function()
  local clip = empty()
  typed("i2l3k")
  eq(select(2, draw.text()), "63@0+0.5", "3k: up three semitones")
  typed("J")
  eq(at(), "51@0.5", "J an octave down, and the cursor with it")
  typed("K<Up><Down><Down>")
  eq(select(2, draw.text()), "62@0+0.5", "K, and the arrows")
  typed("]")
  eq(daw.opt.velocity, 110, "] makes the notes louder")
  typed("<Esc>")
  eq(melody(clip), "62@0+0.5", "written where it was drawn to")
  eq(clip:notes()[1].velocity, 110, "as loud as that")
  daw.opt.velocity = 100
end)

test("Enter, Space and o keep the note and draw the next: after it, after a rest, at the same place", function()
  local clip = empty()
  typed("i2l<CR>")
  eq(draw.text(), "60@0+0.5", "Enter keeps the note")
  eq(select(2, draw.text()), "60@0.5+0", "and the next starts where it ends")
  typed("2k2l<Space>")
  eq(select(2, draw.text()), "62@1.25+0", "Space leaves a step's rest before the next")
  typed("2k4lo")
  eq(select(2, draw.text()), "64@1.25+1", "o draws another as long from the same start")
  typed("3k")
  eq(melody(clip), "", "none of it is written yet")
  typed("<Esc>")
  eq(melody(clip), "60@0+0.5 62@0.5+0.5 64@1.25+1 67@1.25+1", "a line and a chord, written together")
  -- An o with the note not moved after it does not write the note twice.
  roll:set(72, 3)
  typed("i2lo<Esc>")
  eq(select(2, melody(clip):gsub("72@3%+0.5", "")), 1, "no note twice")
  -- Backspace takes the last note kept back, to draw again.
  typed("$i2l<CR>2k<BS>")
  eq(select(2, draw.text()), "72@4+0.5", "Backspace makes the note kept last the one being drawn")
  typed("l<Esc>")
  eq(melody(clip):match("%S+$"), "72@4+0.75", "and it is written as drawn again")
  eq(clip.length, 8, "the clip grew a bar to hold what was drawn past its end")
end)

test("one insert is one undo step, the clip's growth with it", function()
  local clip = empty()
  roll:set(60, 3)
  typed("i2l<CR>2k4l<Space>k2l<Esc>")
  eq(melody(clip), "60@3+0.5 62@3.5+1 63@4.75+0.5", "three notes drawn, running past the end")
  eq(clip.length, 8, "the clip grew to hold them")
  typed("u")
  eq(melody(clip) .. " " .. clip.length, " 4", "u takes them all back at once, and the growth")
  typed("<C-r>")
  eq(melody(clip), "60@3+0.5 62@3.5+1 63@4.75+0.5", "Ctrl-r puts them back")
end)

test("dot draws the last insert again at the cursor, moved to its pitch", function()
  local clip = empty()
  typed("i2l<CR>4k2l<Esc>")
  eq(melody(clip), "60@0+0.5 64@0.5+0.5", "a shape drawn")
  roll:set(67, 2)
  typed(".")
  eq(melody(clip), "60@0+0.5 64@0.5+0.5 67@2+0.5 71@2.5+0.5", "the same shape from G at beat 3")
  eq(daw.keymap.mode, "n", "back in normal mode")
  typed("u")
  eq(melody(clip), "60@0+0.5 64@0.5+0.5", "a step of its own to undo")
  -- `a` starts after the note under the cursor, or a step after the cursor.
  roll:set(60, 0)
  typed("a2l<Esc>")
  eq(melody(clip), "60@0+0.5 60@0.5+0.5 64@0.5+0.5", "a draws from where the note under the cursor ends")
  roll:set(72, 2)
  typed("al<Esc>")
  eq(melody(clip):match("%S+$"), "72@2.25+0.25", "with no note there, a step after the cursor")
end)

test("with several clips edited, what is drawn goes into the active one", function()
  fresh()
  daw.keymap.feed("<Esc><Esc>")
  daw.ui.focus("arrange")
  daw.opt.note_grid = 0.25
  local a = daw.add_track({ name = "A" }):add_clip({ name = "a", start = 0, length = 4 })
  local b = daw.add_track({ name = "B" }):add_clip({ name = "b", start = 0, length = 4 })
  api.undo_checkpoint()
  daw.ui.show("pianoroll")
  roll:edit(a)
  daw.roll_clips.open({ a.id, b.id }, b.id)
  roll:set(65, 1)
  typed("i4l<Esc>")
  eq(melody(a) .. "|" .. melody(b), "|65@1+1", "into b, the active clip, where both are")
  daw.roll_clips.activate(a.id)
  roll:set(67, 2)
  typed("i4l<Esc>")
  eq(melody(a) .. "|" .. melody(b), "67@2+1|65@1+1", "and into a once it is the active one")
end)

test("a suggestion's keys come before the drawing ones: Escape dismisses it, and drawing goes on", function()
  local clip = empty()
  local complete = daw.complete
  local source = {
    name = "drawinsert", priority = 0,
    complete = function(_, done) done({ { label = "fifth", notes = { { pitch = 67, start = 1, length = 1 } } } }) end,
  }
  local auto = daw.opt.complete_auto
  daw.opt.complete_auto = false
  complete.register(source)
  local ok, err = xpcall(function()
    typed("i2l<C-Space>")
    eq(complete.current() ~= nil, true, "a suggestion shows while a note is drawn")
    typed("<Esc>")
    eq(complete.current(), nil, "the first Escape dismisses it")
    eq(draw.active(), true, "and the note is still being drawn")
    eq(melody(clip), "", "nothing written yet")
    typed("l<Esc>")
    eq(melody(clip), "60@0+0.75", "the second Escape writes it")
  end, debug.traceback)
  complete.unregister(source.name)
  complete.dismiss()
  daw.opt.complete_auto = auto
  if not ok then error(err, 0) end
end)

-- The terminal's piano roll as cells: what is at a beat and pitch of the
-- roll, with its colours, from the view drawn by itself.
local function cell(beat, pitch)
  local shot = api.ui_view_snapshot("pianoroll", 100, 30)
  -- The rows above the notes (title, chord row, ruler) as the view counted them.
  local g = roll.geometry
  local x = g.keys + math.floor((beat - roll.scroll) * g.zoom + 0.5)
  local y = g.head + roll.top - pitch
  for _, run in ipairs(shot.rows[y + 1] or {}) do
    if x >= run.x and x < run.x + run.w then
      local chars = {}
      for ch in run.text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
      return { ch = chars[x - run.x + 1] or " ", fg = run.fg, bg = run.bg }
    end
  end
end

test("the note being drawn is drawn in insert mode's colour, its pitch and length in the title and on the key line", function()
  local clip = empty()
  local palette = require("daw.theme").palette
  typed("i2k4l")
  local note = cell(0.5, 62)
  eq(note.fg, palette.insert, "the note being drawn has the insert colour")
  eq(note.bg, daw.draw.mix(palette.bg, palette.insert, 0.3), "on a faint shade of it")
  eq(cell(1, 62).bg, palette.insert, "the cursor is at its end")
  local screen = table.concat(api.ui_snapshot(120, 40), "\n")
  eq(screen:find("DRAW D4  4 steps · 1 beat  vel 100", 1, true) ~= nil, true, "the title says what is being drawn")
  local line = daw.ui.keybar.entries()
  eq(line[1][1] .. " " .. line[1][2], "D4 4 steps · 1 beat", "the key line starts with it")
  eq(line[2][1] .. " " .. line[2][2], "l longer", "then the keys that draw")
  eq(#daw.ui.keybar.check(), 0, "every key it shows is mapped")
  local _, over = roll:marks(clip.id)
  eq(#over == 1 and over[1].pitch .. "@" .. over[1].start .. "+" .. over[1].length, "62@0+1", "the window is given it to draw")
  typed("<CR>")
  local kept = cell(0.5, 62)
  eq(kept.fg ~= palette.insert and kept.bg ~= note.bg, true, "a note kept no longer looks like the one being drawn")
  typed("<Esc>")
  eq(melody(clip), "62@0+1", "it is written")
  eq(cell(0.5, 62).bg, kept.bg, "and looks as it did when kept: what was seen is what is written")
end)

test("I, or the roll_insert option, makes the keyboard a piano instead", function()
  local clip = empty()
  daw.opt.octave = 4
  roll.length = nil
  typed("Is")
  eq(draw.active(), false, "I draws nothing")
  typed("d<Esc>")
  eq(melody(clip), "62@0+0.25 64@0.25+0.25", "s and d are D and E, entered as typed")
  daw.opt.roll_insert = "keys"
  roll:set(60, 2)
  typed("ia<Esc>")
  eq(melody(clip):match("%S+$"), "60@2+0.25", "with roll_insert = keys, i does the same")
  daw.opt.roll_insert = "draw"
  typed("i")
  eq(draw.active(), true, "and draws again when it is set back")
  eq(daw.ui.keybar.entries()[2][1], "l", "with the drawing keys on the key line")
  typed("<Esc>I")
  eq(daw.ui.keybar.entries()[1][1], "a s d f g h j k", "and the piano's on I")
  typed("<Esc>")
end)
