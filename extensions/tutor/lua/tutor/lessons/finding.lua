-- Lesson 14: finding any command or key.
return {
  id = "finding",
  title = "Finding any command or key",
  intro = [[
Nobody remembers every key. paw tells you what you can do at every point:
stop half way through a key sequence and it lists what can follow; `?` lists
every key of the view you are in; `:` runs any command by name, with Tab to
complete it; and pickers find a command, a key, a track or a clip from a few
letters of its name.

Every key is a command with a name, so whatever you can do with a key you can
also type, and whatever you find by name you can map to a key of your own.]],
  idea = [[
Key hints appear when you pause after the start of a sequence (`g`, `,`, `d`,
`"`). `?` is the list of keys for the focused view. `:commands` lists every
command with what it does. `,,` (or `,fc`) picks a command, `,fk` a key, `,ft` a
track, `,fl` a clip, `,fa` a device, `,fm` a mark, `,fr` a register, `,fp` any
picker. In a picker, typing narrows the list (letters in order, not
necessarily together), `<C-n>` `<C-p>` move, `<CR>` chooses, `<Esc>` cancels.
`K` describes the clip and track under the cursor.]],
  vim = [[
Hints are which-key's, built in. The pickers are Telescope's way: fuzzy, with
`<C-n>` `<C-p>`. `:` completes with Tab and keeps a history (`<Up>`).]],
  setup = function(look)
    paw.project.tempo = 100
    local drums = paw.add_track({ name = "Drums", volume = -6 })
    drums:add_device("drums")
    drums:add_clip({ name = "beat", start = 0, length = 8, notes = look.drums(look.beat, 2) })
    local bass = paw.add_track({ name = "Bass", volume = 0 })
    bass:add_device("synth", { wave = 2, cutoff = 700, release = 0.05 })
    bass:add_clip({ name = "bass", start = 0, length = 8, notes = look.pulse("C2", 8) })
    paw.transport.loop_start, paw.transport.loop_end, paw.transport.loop_enabled = 0, 8, true
  end,
  at = function() paw.cursor.set_track(paw.track("Drums")) end,
  steps = {
    {
      say = "Press `g` and wait: after half a second a box lists every key that can follow `g`. Then press `<Esc>` to drop it.",
      keys = { "g", { wait = 700 }, "<Esc>" },
      check = function(ctx)
        if paw.keymap.hints() then ctx.hints = true end
        return ctx.hints and paw.keymap.pending() == ""
      end,
      done = "Any half-typed command shows what can come next: try `,` or `d` or `\"` some time.",
      hint = "Wait without pressing anything until the box appears.",
    },
    {
      say = "`:commands` lists every command and what it does. Type `:commands` and `<CR>`, look, and `q` to close it.",
      keys = { ":commands", "<CR>", "q" },
      check = function(ctx, look) return look.ran(ctx, "commands") and not look.float() end,
      done = "Every key you have learned runs one of those commands.",
    },
    {
      say = "Tab completes command names. Press `j` to go to Bass, type `:track.vol`, press `<Tab>` (it becomes `track.volume`), then `<Space>`, `-6` and `<CR>`.",
      keys = { "j", ":track.vol", "<Tab>", "<Space>", "-6", "<CR>" },
      check = function(_, look) return look.track("Bass").volume == -6 end,
      done = "Bass is at -6 dB: `track.volume` is the command behind `+` and `-`.",
    },
    {
      say = "`,,` opens a picker of every command: type a few letters and `<CR>` runs the one on top. Press `,,`, type `metro` and `<CR>`.",
      keys = { ",,", "metro", "<CR>" },
      check = function() return paw.transport.metronome end,
      done = "The metronome is on: you ran `transport.metronome` without knowing its name or its key.",
    },
    {
      say = "`,fk` finds a key by what it does. Press `,fk`, type `loop` to see every key about looping, then `<Esc>`.",
      keys = { ",fk", "loop", "<Esc>" },
      check = function(ctx, look)
        local state = paw.pick.state()
        if state and state.query == "loop" then ctx.found = true end
        return ctx.found and not look.float()
      end,
      done = "`gL`, `gl`, `il`: and `<CR>` would have typed the key for you.",
    },
    {
      say = "`,ft` goes to a track by name. Press `,ft`, type `dr` and `<CR>`.",
      keys = { ",ft", "dr", "<CR>" },
      check = function(ctx, look) return look.ran(ctx, "pick.tracks") and look.cursor_track() == "Drums" end,
      done = "On Drums. `,fl` does the same for clips.",
    },
    {
      say = "`K` describes what is under the cursor: the clip, the track, its devices. Press `K`, then `q` to close.",
      keys = { "K", "q" },
      check = function(ctx, look) return look.ran(ctx, "info") and not look.float() end,
      done = "`K` is the quickest way to see a track's devices, sends and automation.",
    },
    {
      say = "Listen with the click: `<Space>`, then `<Space>` to stop and `gm` to switch the click off.",
      keys = { "<Space>", { wait = 300 }, "<Space>", "gm" },
      check = function(ctx, look) return look.played(ctx) and not paw.transport.metronome end,
      done = "The quieter bass, with the click you found by name.",
    },
  },
  outro = "Key hints, `?`, `:commands`, Tab on the command line, `,,` and the `,f` pickers, and `K`.",
}
