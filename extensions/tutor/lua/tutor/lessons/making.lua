-- Lesson 3: tracks, instruments, clips, notes, hearing them.
return {
  id = "making",
  title = "Tracks, clips and notes",
  intro = [[
A track holds clips on the timeline and a chain of devices: an instrument that
turns notes into sound, then effects. A clip holds notes (a MIDI clip) or a
recording (an audio clip). A new track is silent until it has an instrument.

In this lesson you add a track, give it a name and a synth, draw a few notes
with the keyboard, and listen. There is a drum beat to play along to.]],
  idea = [[
Small letters in normal mode act on what is under the cursor: `o` opens a new
track below (as `o` opens a new line in Vim), `a` adds a device, `i` inserts
notes, `x` deletes the clip, `&` repeats it. `u` undoes and `<C-r>` redoes, so
nothing you try here can do lasting harm.]],
  vim = [[
`o` `O` add a track below and above, like lines. `i` opens the clip under the
cursor (or a new one) in the piano roll in insert mode, where the cursor draws
notes rather than typing text. `grn` renames, as in Neovim's LSP keys.]],
  setup = function(look)
    daw.project.tempo = 100
    local drums = daw.add_track({ name = "Drums" })
    drums:add_device("drums")
    drums:add_clip({ name = "beat", start = 0, length = 16, notes = look.drums(look.beat, 4) })
    daw.transport.loop_start, daw.transport.loop_end, daw.transport.loop_enabled = 0, 16, true
  end,
  steps = {
    {
      say = "`o` adds a track below the one the cursor is on. Press `o`.",
      keys = { "o" },
      start = function(ctx) ctx.tracks = #daw.tracks() end,
      check = function(ctx) return #daw.tracks() == ctx.tracks + 1 end,
      done = "A new, empty track, and the cursor is on it.",
    },
    {
      say = "Name it: press `grn`, clear the old name with `<C-u>`, type `Bass` and press `<CR>`.",
      keys = { "grn", "<C-u>", "Bass", "<CR>" },
      check = function(_, look) return look.cursor_track() == "Bass" end,
      done = "The track is called Bass.",
      hint = "`grn` asks on the command line, with the old name filled in. `<C-u>` is Ctrl and u. `<Esc>` cancels.",
    },
    {
      say = "A track is silent until it has an instrument. Press `a`, type `synth` and press `<CR>`.",
      keys = { "a", "synth", "<CR>" },
      check = function(_, look) return look.device("Bass", "synth") ~= nil end,
      done = "Bass has a synth.",
      hint = "`a` opens a list of every device; typing narrows it, `<CR>` takes the top one.",
    },
    {
      say = "`i` makes a clip at the cursor and opens it for drawing notes: insert mode. Press `i`.",
      keys = { "i" },
      check = function(_, look) return look.mode() == "i" and look.focused() == "pianoroll" end,
      done = "INSERT: the piano roll is open on C4, and the title row shows the note being drawn.",
    },
    {
      say = "`l` draws the note a step longer: `4l` makes it a beat. `<CR>` keeps it and starts the next where it ends, `2k` goes up two semitones. Press `4l`, `<CR>`, `2k`, `4l`, `<CR>`, `2k`, `4l`, and `<Esc>` to write them.",
      keys = { "4l", "<CR>", "2k", "4l", "<CR>", "2k", "4l", "<Esc>" },
      check = function(_, look)
        local clip = look.clip("Bass")
        return clip and look.melody(clip) == "60@0+1 62@1+1 64@2+1" and look.mode() == "n"
      end,
      done = "Three notes, C D E, written when you left insert mode.",
      hint = "What is drawn shows in green and is written by `<Esc>`. `h` makes a note shorter, `j` moves it down.",
    },
    {
      say = "Press `<Esc>` to go back to the arrange view.",
      keys = { "<Esc>" },
      check = function(ctx, look) return look.became(ctx, "back", look.mode() == "n" and look.focused() == "arrange") end,
      done = "Back in the arrange view, in NORMAL mode.",
    },
    {
      say = "Press `<Space>` to hear your notes with the drums, and `<Space>` to stop.",
      keys = { "<Space>", { wait = 300 }, "<Space>" },
      check = function(ctx, look) return look.played(ctx) end,
      done = "That is your bass line.",
    },
    {
      say = "`&` repeats the clip right after itself. Press `&` twice.",
      keys = { "&", "&" },
      check = function(_, look) return #look.clips("Bass") == 3 end,
      done = "Three copies, one after another.",
      hint = "The cursor has to be on the clip: `0` goes to the start.",
    },
    {
      say = "`u` undoes the last change and `<C-r>` (Ctrl and r) redoes it. Press `u`, then `<C-r>`.",
      keys = { "u", "<C-r>" },
      check = function(ctx, look) return look.ran(ctx, "undo") and look.ran(ctx, "redo") and #look.clips("Bass") == 3 end,
      done = "Undone and redone: every key that changes the project is one step to undo.",
    },
    {
      say = "`x` deletes the clip under the cursor. Press `x`.",
      keys = { "x" },
      check = function(_, look) return #look.clips("Bass") == 2 end,
      done = "Deleted. (`u` would bring it back.)",
    },
    {
      say = "Listen to what you made: `gs` to the start, `<Space>` to play, `<Space>` to stop.",
      keys = { "gs", "<Space>", { wait = 300 }, "<Space>" },
      check = function(ctx, look) return look.ran(ctx, "transport.start") and look.played(ctx) end,
      done = "A bass line on a track of your own.",
    },
  },
  outro = "You made a track, gave it a name and an instrument, entered notes, repeated and deleted clips, and undid a change.",
}
