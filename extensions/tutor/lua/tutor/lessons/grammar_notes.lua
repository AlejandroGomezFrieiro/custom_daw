-- Lesson 6: the same grammar on notes.
return {
  id = "grammar-notes",
  title = "The same grammar on notes",
  intro = [[
Everything from the last lesson works in the piano roll, with notes in place of
clips and pitches in place of tracks. `w` goes to the next note, so `dw`
deletes up to it; `in` is the note under the cursor, `ic` every note of the
clip; `dd` deletes a whole row, which here is every note of one pitch; `.`
repeats; `y` and `p` copy.

The clip `riff` is open in the piano roll: C D E G E D C, a beat each.]],
  idea = [[
Learn the grammar once, use it everywhere: the operators are the same (`d` `y`
`c` `>` `<` `=` `gl`), the motions are the same keys (`w` `b` `e` `0` `$` `W`
`B`, `j` `k` by pitch), and the text objects are `in` (note), `ib` (bar) and
`ic` (the whole clip). A note belongs to the stretch it starts in, so `dw`
from the middle of a gap deletes nothing.]],
  vim = [[
`in` stands where `iw` would. `dd` takes a whole row, which is a pitch.
`/d4` searches for a pitch by name, `n` goes on to the next.]],
  setup = function(look)
    daw.project.tempo = 100
    local drums = daw.add_track({ name = "Drums", volume = -4 })
    drums:add_device("drums")
    drums:add_clip({ name = "beat", start = 0, length = 16, notes = look.drums(look.beat, 4) })
    local lead = daw.add_track({ name = "Lead" })
    lead:add_device("synth", { wave = 1, cutoff = 2400, release = 0.2 })
    lead:add_clip({ name = "riff", start = 0, length = 8, notes = look.notes("C4:0:1 D4:1:1 E4:2:1 G4:3:1 E4:4:1 D4:5:1 C4:6:1") })
  end,
  at = function(look)
    local lead = daw.track("Lead")
    daw.cursor.set_track(lead)
    daw.ui.views.pianoroll:edit(look.clip(lead, "riff"))
  end,
  steps = {
    {
      say = "The cursor is on the first note. `w` goes to the next note, wherever its pitch is. Press `w` twice.",
      keys = { "w", "w" },
      check = function() local roll = daw.ui.views.pianoroll return roll.beat == 2 and roll.pitch == 64 end,
      done = "On E4, the third note.",
    },
    {
      say = "`dw` deletes from the cursor up to the next note. Press `dw`.",
      keys = { "dw" },
      check = function(_, look) return not look.melody(look.clip("Lead")):find("64@2+", 1, true) end,
      done = "E4 is gone; the cursor stays in the gap.",
    },
    {
      say = "Press `w` to go to G4, and `.` to delete it the same way.",
      keys = { "w", "." },
      check = function(_, look) return look.melody(look.clip("Lead")) == "60@0+1 62@1+1 64@4+1 62@5+1 60@6+1" end,
      done = "`.` repeated `dw` from the new place.",
      hint = "From inside a gap `dw` reaches the next note's start, and a note belongs to where it starts, so nothing goes. Go onto a note first.",
    },
    {
      say = "Press `u` twice to have both notes back.",
      keys = { "u", "u" },
      check = function(ctx, look) return look.ran(ctx, "undo") and look.melody(look.clip("Lead")) == "60@0+1 62@1+1 64@2+1 67@3+1 64@4+1 62@5+1 60@6+1" end,
      done = "The riff is whole again.",
    },
    {
      say = "`in` is the note under the cursor. `>in` moves it a step later, and the cursor goes with it. Press `>in`, then `.`.",
      keys = { ">in", "." },
      check = function(_, look) return look.melody(look.clip("Lead")):find("67@3.5+1", 1, true) ~= nil end,
      done = "G4 is two steps late now: a little push before the beat.",
      hint = "The cursor must be on G4 (beat 4). `u` takes back a move that went wrong.",
    },
    {
      say = "`yic` yanks every note of the clip. Then `$` goes to the end of the clip and `p` pastes them there. Press `yic`, `$`, `p`.",
      keys = { "yic", "$", "p" },
      check = function(_, look) return #look.clip("Lead"):notes() == 14 end,
      done = "The riff twice, and the clip grew to hold it.",
    },
    {
      say = "`c` changes: `cin` deletes the note under the cursor and starts insert mode in its place. Press `^` (the first note), `cin`, then `7k` and `4l`, and `<Esc>`.",
      keys = { "^", "cin", "7k", "4l", "<Esc>" },
      check = function(_, look)
        local m = look.melody(look.clip("Lead"))
        return m:find("^67@0%+1") ~= nil and not m:find("^60@0") and daw.keymap.mode == "n"
      end,
      done = "The riff starts on G now.",
      hint = "`7k` moves the new note up to G, `4l` makes it a beat long.",
    },
    {
      say = "`/` searches: `/d4` and `<CR>` go to the next D4. Then `dd` deletes every note of that pitch. Press `/d4`, `<CR>`, `dd`.",
      keys = { "/d4", "<CR>", "dd" },
      check = function(_, look) return not look.melody(look.clip("Lead")):find("62@", 1, true) end,
      done = "No D4 left anywhere in the clip.",
    },
    {
      say = "Press `<C-w>p` to go back to the arrange view and `<Space>` to listen; `<Space>` stops.",
      keys = { "<C-w>p", "<Space>", { wait = 300 }, "<Space>" },
      check = function(ctx, look) return look.focused() == "arrange" and look.played(ctx) end,
      done = "Your changed riff.",
    },
  },
  outro = "`dw`, `.`, `>in`, `yic` `p`, `cin`, `dd` and `/`: the grammar of lesson 5, on notes.",
}
