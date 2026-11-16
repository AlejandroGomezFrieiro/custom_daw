-- Lesson 4: the piano roll and insert mode.
return {
  id = "pianoroll",
  title = "The piano roll and entering notes",
  intro = [[
The piano roll shows the notes of one clip: a row per pitch, with the names on
the left, and time running to the right in steps of a sixteenth note. In
normal mode you move about and change single notes; in insert mode the keyboard
is a piano and every key enters a note and steps on.

The clip `tune` has three notes in its second bar. You will add to it.]],
  idea = [[
Moving: `h` `l` a step, `j` `k` a semitone, `J` `K` an octave, `w` `b` notes, `0`
`$` the start and end of the clip. Changing the note under the cursor: `<CR>`
adds or removes, `+` `-` length, `H` `L` move it, `<C-a>` `<C-x>` pitch, `[` `]`
velocity, `gh` hear the pitch. Insert mode (`i`, or `a` after the note): `a w s
e d f t g y h u j k` are C up to the next C, a capital stays in place for a
chord, `1`-`9` set the note length in steps, `<Space>` is a rest, `<BS>` takes
back, `z` `x` change octave, `<Esc>` leaves.]],
  vim = [[
`<C-a>` and `<C-x>` add and subtract, as on numbers in Vim; here they move a
note's pitch. Insert mode does not insert text: each key is a note.]],
  setup = function(look)
    daw.project.tempo = 90
    local drums = daw.add_track({ name = "Drums", volume = -4 })
    drums:add_device("drums")
    drums:add_clip({ name = "beat", start = 0, length = 12, notes = look.drums(look.beat, 3) })
    local piano = daw.add_track({ name = "Piano" })
    piano:add_device("synth", { wave = 1, cutoff = 2200, release = 0.3 })
    piano:add_clip({ name = "tune", start = 0, length = 8, notes = look.notes("E4:4:1 D4:5:1 C4:6:2") })
  end,
  at = function() daw.cursor.set_track(daw.track("Piano")) end,
  steps = {
    {
      say = "The cursor is on the clip `tune`. Press `<CR>` (Enter) to open it in the piano roll.",
      keys = { "<CR>" },
      check = function(_, look) return look.focused() == "pianoroll" end,
      done = "The piano roll. The cursor is on E4 at the start of the clip.",
    },
    {
      say = "`j` and `k` move a semitone down and up (`J` `K` an octave), and you hear each pitch. Press `k` three times to reach G4.",
      keys = { "k", "k", "k" },
      check = function() return daw.ui.views.pianoroll.pitch == 67 end,
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
      say = "`+` makes the note under the cursor a step longer, `-` shorter. Press `+` three times.",
      keys = { "+", "+", "+" },
      check = function(_, look) return look.melody(look.clip("Piano")):find("67@0+1", 1, true) ~= nil end,
      done = "Now it lasts a beat.",
    },
    {
      say = "`<C-a>` moves the note up a semitone and `<C-x>` down. Press `<C-a>` twice.",
      keys = { "<C-a>", "<C-a>" },
      check = function(_, look) return look.melody(look.clip("Piano")):find("^69@0%+1") ~= nil end,
      done = "A4 now, and the cursor went with it.",
      hint = "`<C-a>` is Ctrl and a. The cursor must be on the note.",
    },
    {
      say = "Go a beat on with `4l`, and press `i` to start entering notes there.",
      keys = { "4l", "i" },
      check = function() return daw.keymap.mode == "i" and daw.ui.views.pianoroll.beat == 1 end,
      done = "INSERT at beat 2. The title row shows the octave (C4), the step and the velocity.",
    },
    {
      say = "Digits set how many steps long the next notes are. Press `4` (a beat), then type `gfd` for G, F and E.",
      keys = { "4", "gfd" },
      check = function(_, look)
        return look.melody(look.clip("Piano")):find("69@0+1 67@1+1 65@2+1 64@3+1 64@4+1", 1, true) ~= nil
      end,
      done = "A G F E, running into the E D C that was there.",
      hint = "`a` is C, `s` D, `d` E, `f` F, `g` G, `h` A, `j` B, `k` the C above. `<BS>` takes the last one back.",
    },
    {
      say = "`<Space>` is a rest: it steps on without a note. Press `<Space>` four times to step past the notes already there.",
      keys = { "<Space>", "<Space>", "<Space>", "<Space>" },
      check = function() return daw.ui.views.pianoroll.beat == 8 end,
      done = "At the end of the clip, which grew a bar to make room.",
    },
    {
      say = "A capital letter enters a note and stays, for chords. Type `AD` (C and E, staying), then `g` (G, stepping on).",
      keys = { "AD", "g" },
      check = function(_, look)
        return look.melody(look.clip("Piano")):find("60@8+1 64@8+1 67@8+1", 1, true) ~= nil
      end,
      done = "A C major chord.",
      hint = "Shift and a, shift and d, then a small g.",
    },
    {
      say = "`z` goes down an octave and `x` up. Press `z`, then `a` for a low C.",
      keys = { "z", "a" },
      check = function(_, look) return look.melody(look.clip("Piano")):find("48@9+1", 1, true) ~= nil end,
      done = "C3 under the chord.",
    },
    {
      say = "Press `<Esc>` twice (out of insert mode, out of the piano roll), then `gs` and `<Space>` to listen; `<Space>` stops.",
      keys = { "<Esc>", "<Esc>", "gs", "<Space>", { wait = 300 }, "<Space>" },
      check = function(ctx, look) return look.focused() == "arrange" and look.played(ctx) end,
      done = "Your tune, over the drums.",
    },
  },
  outro = "You moved by pitch and time, added and changed a note in normal mode, and entered a line and a chord in insert mode.",
}
