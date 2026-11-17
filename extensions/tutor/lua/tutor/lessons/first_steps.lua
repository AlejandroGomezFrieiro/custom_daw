-- Lesson 1: the screen, playing, the command line, quitting.
return {
  id = "first-steps",
  title = "First steps: the screen, playing, quitting",
  intro = [[
paw is driven from the keyboard. Everything on the screen is a view: the
arrange view in the middle has a row per track and time running to the right,
the status line at the bottom says which mode you are in (`NORMAL` now), and
the line below it is where commands are typed and messages appear. This panel
at the bottom is the tutor: it says what to do and notices when you have done it.

Keys are written as Vim writes them: `j` is the j key, `J` is shift and j,
`<C-r>` is Ctrl and r, `<CR>` is Enter, `<Esc>` is Escape, `<Space>` the space
bar, `<BS>` Backspace. `gs` means g, then s.]],
  idea = [[
Nothing here needs the mouse. A key either does something at once (`<Space>`
plays) or starts something that more keys finish (`:` starts a command line, `g`
starts two-key commands such as `gs`). If you are ever unsure what state you are
in, `<Esc>` gets you back to normal mode, and `?` lists the keys that work where
you are.]],
  vim = [[
`:q`, `ZZ` and `ZQ` mean what they mean in Vim, and `:w` saves. `:` takes
commands by name (`:tempo 120`), and Ex commands over bars and tracks
(`:5,8d`, `:%s/c4/d4/g`): lesson 17.]],
  setup = function(look)
    daw.project.tempo = 100
    local drums = daw.add_track({ name = "Drums" })
    drums:add_device("drums")
    drums:add_clip({ name = "beat", start = 0, length = 8, notes = look.drums(look.beat, 2) })
    local bass = daw.add_track({ name = "Bass", volume = -4 })
    bass:add_device("synth", { wave = 2, cutoff = 600, release = 0.05 })
    local line = look.pulse("A1", 4)
    for _, n in ipairs(look.pulse("F1", 4, 4)) do line[#line + 1] = n end
    bass:add_clip({ name = "bass", start = 0, length = 8, notes = line })
    local keys = daw.add_track({ name = "Keys", volume = -10 })
    keys:add_device("synth", { wave = 3, attack = 0.05, release = 0.4, cutoff = 2000 })
    local chords = look.chord({ "A3", "C4", "E4" }, 4)
    for _, n in ipairs(look.chord({ "F3", "A3", "C4" }, 4, 4)) do chords[#chords + 1] = n end
    keys:add_clip({ name = "chords", start = 0, length = 8, notes = chords })
    daw.transport.loop_start, daw.transport.loop_end, daw.transport.loop_enabled = 0, 8, true
  end,
  steps = {
    {
      say = "This short song has three tracks: Drums, Bass and Keys. Press `<Space>` to play it.",
      keys = { "<Space>" },
      check = function() return daw.transport.playing end,
      done = "It plays, round and round: the loop is on (the status line says `loop`).",
      hint = "`<Space>` is the space bar. Watch the ▶ in the status line and the playhead moving across the clips.",
    },
    {
      say = "Press `<Space>` again to stop.",
      keys = { "<Space>" },
      check = function(ctx, look) return look.became(ctx, "stopped", not daw.transport.playing) end,
      done = "Stopped. The playhead stays where it stopped.",
    },
    {
      say = "`gs` puts the playhead back at the start: press `g`, then `s`.",
      keys = { "gs" },
      check = function(ctx, look) return look.ran(ctx, "transport.start") and daw.transport.position == 0 end,
      done = "The playhead is at the start: the clock in the status line says 1.1.00 (bar 1, beat 1).",
      hint = "Type the two keys one after the other, not together.",
    },
    {
      say = "The highlighted track header is the cursor. `j` moves it down a track and `k` up. Press `j` twice to reach Keys.",
      keys = { "j", "j" },
      check = function(_, look) return look.cursor_track() == "Keys" end,
      done = "The cursor is on Keys.",
      hint = "If you went past it, `k` goes back up.",
    },
    {
      say = "`?` lists every key that works in the view you are in. Press `?`, type `mute` to narrow the list down, then press `<Esc>` to close it.",
      keys = { "?", "mute", "<Esc>" },
      check = function(ctx, look) return look.ran(ctx, "pick.keys") and not look.float() end,
      done = "That list is always there when you forget a key; `<CR>` (Enter) on a line runs its key.",
      hint = "Typing narrows the list; `<Esc>` closes it.",
    },
    {
      say = "`:` opens the command line at the bottom. Type `:tempo 130` and press `<CR>` (Enter) to speed the song up.",
      keys = { ":tempo 130", "<CR>" },
      check = function() return daw.project.tempo == 130 end,
      done = "130 beats per minute: the status line shows it.",
      hint = "Type the colon too. `<Esc>` abandons a command line you have started; `<BS>` on an empty one closes it.",
    },
    {
      say = "Press `<Space>` to hear it faster, and `<Space>` to stop.",
      keys = { "<Space>", { wait = 300 }, "<Space>" },
      check = function(ctx, look) return look.played(ctx) end,
      done = "Faster.",
    },
    {
      say = "To quit paw, type `:q` and `<CR>` (or `ZQ`; `ZZ` saves first). Do it now: the tutor keeps your place, and `:tutor` next time brings you to lesson 2.",
      keys = { { sim = "quit", instead = { ":q", "<CR>" } } },
      on_quit = true,
      done = "Quitting.",
      hint = "If you would rather not quit now, `,hn` goes on to lesson 2.",
    },
  },
  outro = "You have played a song, moved the cursor, used the command line and seen where to find every key.",
}
