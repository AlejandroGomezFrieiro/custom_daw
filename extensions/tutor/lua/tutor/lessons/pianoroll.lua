-- Lesson 4: the piano roll and insert mode.
return {
  id = "pianoroll",
  title = "The piano roll and entering notes",
  intro = [[
The piano roll shows the notes of one clip: a row per pitch, with the names on
the left, and time running to the right in steps of a sixteenth note. In
normal mode you move about and change single notes; in insert mode you draw
notes with the cursor, as long as you like, and they are written when you leave
it.

The clip `tune` has three notes in its second bar. You will add to it.]],
  idea = [[
Moving: `h` `l` a step, `j` `k` a semitone, `<C-d>` `<C-u>` an octave, `w` `b` notes, `0`
`$` the start and end of the clip. Changing the note under the cursor: `<CR>`
adds or removes, `+` `-` (and `<C-a>` `<C-x>`) its pitch, `<A-h>` `<A-l>` its length, `H` `L` move it, `[` `]`
velocity, `gh` hear the pitch. Insert mode (`i`, or `a` after the note) draws a
note from the cursor: `l` `h` longer and shorter, `j` `k` `<C-d>` `<C-u>` its pitch,
`<CR>` keeps it and draws the next where it ends, `<Space>` after a rest, `o`
from the same start for a chord, `<BS>` takes back, `<Esc>` writes and leaves.
`I` makes the keyboard a piano instead: `a w s e d f t g y h u j k` are C up to
the next C. `<Esc>` in normal mode stays in the roll; `<C-w>p` goes back to the arrange view.]],
  vim = [[
`<C-a>` and `<C-x>` add and subtract, as on numbers in Vim; here they move a
note's pitch, as `+` `-` do: the main value of a note is its pitch. Insert mode does not insert text: it draws a note, and all of it
is one undo step, which `.` repeats at the cursor, as Vim repeats an insert.]],
  setup = function(look)
    paw.project.tempo = 90
    local drums = paw.add_track({ name = "Drums", volume = -4 })
    drums:add_device("drums")
    drums:add_clip({ name = "beat", start = 0, length = 12, notes = look.drums(look.beat, 3) })
    local piano = paw.add_track({ name = "Piano" })
    piano:add_device("synth", { wave = 1, cutoff = 2200, release = 0.3 })
    piano:add_clip({ name = "tune", start = 0, length = 8, notes = look.notes("E4:4:1 D4:5:1 C4:6:2") })
  end,
  at = function() paw.cursor.set_track(paw.track("Piano")) end,
  steps = {
    {
      say = "The cursor is on the clip `tune`. Press `<CR>` (Enter) to open it in the piano roll.",
      keys = { "<CR>" },
      check = function(_, look) return look.focused() == "pianoroll" end,
      done = "The piano roll. The cursor is on E4 at the start of the clip.",
    },
    {
      say = "`j` and `k` move a semitone down and up (`<C-d>` `<C-u>` an octave, half a page as in Vim), and you hear each pitch. Press `k` three times to reach G4.",
      keys = { "k", "k", "k" },
      check = function() return paw.ui.views.pianoroll.pitch == 67 end,
      done = "G4: the name is in the title row and highlighted on the left.",
      hint = "Watch the title row of the piano roll: it shows the pitch under the cursor.",
    },
    {
      say = "`<CR>` adds a note at the cursor (or removes the one there). Press `<CR>`.",
      keys = { "<CR>" },
      check = function(_, look) return look.melody(look.clip("Piano")):find("67@0+0.25", 1, true) ~= nil end,
      done = "A short G4: one step, a sixteenth.",
    },
    {
      say = "`<A-l>` makes the note under the cursor a step longer, `<A-h>` shorter, as they do to a clip in the arrange view. Press `<A-l>` three times.",
      keys = { "<A-l>", "<A-l>", "<A-l>" },
      check = function(_, look) return look.melody(look.clip("Piano")):find("67@0+1", 1, true) ~= nil end,
      done = "Now it lasts a beat.",
    },
    {
      say = "`<C-a>` (or `+`) moves the note up a semitone and `<C-x>` (or `-`) down. Press `<C-a>` twice.",
      keys = { "<C-a>", "<C-a>" },
      check = function(_, look) return look.melody(look.clip("Piano")):find("^69@0%+1") ~= nil end,
      done = "A4 now, and the cursor went with it.",
      hint = "`<C-a>` is Ctrl and a. The cursor must be on the note.",
    },
    {
      say = "Go a beat on with `4l`, and press `i` to draw a note there.",
      keys = { "4l", "i" },
      check = function() return paw.keymap.mode == "i" and paw.ui.views.pianoroll.beat == 1 end,
      done = "INSERT at beat 2: a note starts here, nothing long yet. The title row shows its pitch and length.",
    },
    {
      say = "In insert mode `l` makes the note a step longer and `h` shorter; `j` `k` move its pitch. Press `2j` (down to G) and `4l` (a beat long).",
      keys = { "2j", "4l" },
      check = function() return select(2, paw.roll_draw.text()) == "67@1+1" end,
      done = "A G a beat long, in green: drawn, not written yet. The cursor sits at its end.",
      hint = "Counts work as in normal mode: `4l` is `l` four times. `h` takes a step back off the note.",
    },
    {
      say = "`<CR>` keeps the note and starts the next where it ends. Press `<CR>`, `2j` (F), `4l`, `<CR>`, `j` (E) and `4l`.",
      keys = { "<CR>", "2j", "4l", "<CR>", "j", "4l" },
      check = function() return paw.roll_draw.text() == "67@1+1 65@2+1" and select(2, paw.roll_draw.text()) == "64@3+1" end,
      done = "G, F, and an E being drawn.",
      hint = "Each new note starts with no length: `4l` draws it. `<BS>` takes the last one kept back.",
    },
    {
      say = "`<Esc>` writes what was drawn and leaves insert mode. Press `<Esc>`.",
      keys = { "<Esc>" },
      check = function(_, look)
        return paw.keymap.mode == "n" and look.melody(look.clip("Piano")):find("69@0+1 67@1+1 65@2+1 64@3+1 64@4+1", 1, true) ~= nil
      end,
      done = "A G F E, running into the E D C that was there. All of it is one step to undo.",
    },
    {
      say = "Now a chord at the end of the clip. Press `$` (the end), `i`, `4j` (down to C) and `4l`.",
      keys = { "$", "i", "4j", "4l" },
      check = function() return select(2, paw.roll_draw.text()) == "60@8+1" end,
      done = "A C a beat long, past the end of the clip: it will grow to hold it.",
    },
    {
      say = "`o` keeps the note and starts another from the same place, as long, for a chord. Press `o` and `4k` (E), then `o` and `3k` (G).",
      keys = { "o", "4k", "o", "3k" },
      check = function() return paw.roll_draw.text() == "60@8+1 64@8+1" and select(2, paw.roll_draw.text()) == "67@8+1" end,
      done = "C and E kept, G being drawn.",
    },
    {
      say = "`<CR>` goes on after the chord; `<C-d>` and `<C-u>` move an octave. Press `<CR>`, `<C-d>` and `7j` (the C below), `4l`, and `<Esc>`.",
      keys = { "<CR>", "<C-d>", "7j", "4l", "<Esc>" },
      check = function(_, look)
        local m = look.melody(look.clip("Piano"))
        return paw.keymap.mode == "n" and m:find("60@8+1 64@8+1 67@8+1", 1, true) ~= nil and m:find("48@9+1", 1, true) ~= nil
      end,
      done = "A C major chord, then C3 under it.",
      hint = "`<Space>` would have left a step's rest before the next note instead.",
    },
    {
      say = "`<Esc>` in normal mode stays in the piano roll, as in every view; `<C-w>p` goes back to the window before. Press `<C-w>p`, then `gs` and `<Space>` to listen; `<Space>` stops.",
      keys = { "<C-w>p", "gs", "<Space>", { wait = 300 }, "<Space>" },
      check = function(ctx, look) return look.focused() == "arrange" and look.played(ctx) end,
      done = "Your tune, over the drums.",
    },
  },
  outro = "You moved by pitch and time, added and changed a note in normal mode, and drew a line and a chord in insert mode.",
}
