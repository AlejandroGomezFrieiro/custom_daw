-- Run by extensions/notation/tests_midi.lua in a kernel of its own, without the
-- notation extension: a project written in notation is opened and edited
-- in the piano roll as plain MIDI (a note moved, one raised, one deleted,
-- one added, a velocity, a note copied, an undo and a redo), and saved.
-- Prints one line for each thing wrong, each starting `wrong:`, then `done`.
--   PLAIN_IN=in.daw PLAIN_OUT=out.daw daw --clean --no-plugins --no-listen --audio null -l extensions/notation/fixtures/plain_roll.lua
local api = daw.api
local function wrong(text) print("wrong: " .. text) end
local ok, err = pcall(function()
  if package.loaded["notation"] or daw.ext.loaded.notation then wrong("the notation extension is loaded") end
  daw.cmd("open!", { os.getenv("PLAIN_IN") })
  daw.flush()
  local clip = daw.tracks()[1]:clips()[1]
  local roll = daw.ui.views.pianoroll
  roll:edit(clip)
  daw.ui.focus("pianoroll")
  daw.keymap.set_mode("n")
  local function keys(text)
    daw.keymap.feed(text)
    api.undo_checkpoint()
  end
  local function place(pitch, start)
    for i, n in ipairs(clip:notes()) do
      if n.pitch == pitch and math.abs(n.start - start) < 1e-6 then return i end
    end
  end
  daw.opt.note_grid = 0.25
  -- The D a step later, the E up a semitone, the G deleted.
  roll:set(62, 1)
  keys("L")
  roll:set(64, 2)
  keys("+")
  roll:set(67, 4)
  keys("x")
  -- A note drawn where there was none.
  roll.length = 1
  roll:set(79, 6)
  keys("<CR>")
  -- A velocity.
  clip:set_note(place(65, 3), { velocity = 100 })
  api.undo_checkpoint()
  -- The F at beat 3 copied to beat 7, taken back and put again.
  roll:set(65, 3)
  keys("yin")
  roll:set(65, 7)
  keys("P")
  keys("u")
  keys("<C-r>")
  if not place(65, 7) then wrong("the copy is not at beat 7") end
  daw.cmd("write", { os.getenv("PLAIN_OUT") })
end)
if not ok then wrong(tostring(err)) end
print("done")
api.quit(0)
