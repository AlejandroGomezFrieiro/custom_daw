-- Lesson 11: looping, the metronome, marks, jumps and search.
return {
  id = "loops",
  title = "Looping, marks and finding your way",
  intro = [[
Working on a part means hearing it over and over: the loop. It can be switched
on and off, set to any stretch with the `gl` operator, and shown on the ruler.
And in a long song you need to get about quickly: search clips and tracks by
name with `/`, leave marks with `m` and come back to them with `'`, and go back
to where you were before a jump.

This song has an intro, a verse and a chorus.]],
  idea = [[
`gL` loop on and off, `gl` + motion or object sets the loop (`glic`, `gl2W`),
`il` is the loop as a text object (`yil`, `dil`). `gm` is the metronome, `gs`
the playhead to the start and `gp` to the cursor. `ma` marks a place, `'a` goes
back to it, `''` back to before the last jump, `<C-o>` `<C-i>` back and forward
through jumps. `/name` finds a clip or track, `n` `N` the next and previous
match, `*` the next clip with the same name.]],
  vim = [[
Marks, `''`, `<C-o>` `<C-i>`, `/` `n` `N` and `*` are Vim's. Marks belong to a
view (the arrange view and the piano roll have their own) and follow their
track when tracks move. `:marks` lists them.]],
  setup = function(look)
    daw.project.tempo = 110
    local drums = daw.add_track({ name = "Drums", volume = -4 })
    drums:add_device("drums")
    drums:add_clip({ name = "intro", start = 0, length = 8, notes = look.drums({ [42] = "x.o.x.o.x.o.x.o." }, 2) })
    drums:add_clip({ name = "verse", start = 8, length = 16, notes = look.drums(look.beat, 4) })
    drums:add_clip({ name = "chorus", start = 24, length = 16, notes = look.drums({ [36] = "x...x...x...x...", [38] = "....x.......x...", [46] = "..x...x...x...x." }, 4) })
    local bass = daw.add_track({ name = "Bass", volume = -4 })
    bass:add_device("synth", { wave = 2, cutoff = 700, release = 0.05 })
    bass:add_clip({ name = "verse", start = 8, length = 16, notes = look.pulse("E2", 16) })
    bass:add_clip({ name = "chorus", start = 24, length = 16, notes = look.pulse("A1", 16) })
    local lead = daw.add_track({ name = "Lead", volume = -8 })
    lead:add_device("synth", { wave = 1, cutoff = 2600, release = 0.2 })
    lead:add_clip({ name = "hook", start = 24, length = 8, notes = look.notes("E5:0:1 E5:1:0.5 D5:1.5:0.5 C5:2:1 A4:3:1 C5:4:2 B4:6:2") })
    daw.transport.loop_start, daw.transport.loop_end, daw.transport.loop_enabled = 0, 8, false
  end,
  at = function() daw.cursor.set_track(daw.track("Drums")) end,
  steps = {
    {
      say = "`gL` switches looping on and off; the status line's `loop` lights up and the ruler shows the loop. Press `gL`.",
      keys = { "gL" },
      check = function() return daw.transport.loop_enabled end,
      done = "Looping is on, over the first two bars.",
    },
    {
      say = "`/` finds a clip or track by name. Type `/chorus` and press `<CR>`.",
      keys = { "/chorus", "<CR>" },
      check = function() return daw.cursor.beat == 24 end,
      done = "On the chorus. `n` would go on to the next match (the chorus of Bass).",
    },
    {
      say = "`gl` is the loop operator. Press `glic` to loop the clip under the cursor.",
      keys = { "glic" },
      check = function() return daw.transport.loop_start == 24 and daw.transport.loop_end == 40 and daw.transport.loop_enabled end,
      done = "The chorus is the loop.",
    },
    {
      say = "`gm` switches the metronome (click) on. Press `gm`, then `gp` (the playhead to the cursor) and `<Space>`; `<Space>` stops.",
      keys = { "gm", "gp", "<Space>", { wait = 300 }, "<Space>" },
      check = function(ctx, look) return daw.transport.metronome and look.played(ctx) end,
      done = "The chorus with a click.",
    },
    {
      say = "Press `gm` to switch the click off again.",
      keys = { "gm" },
      check = function(ctx, look) return look.became(ctx, "quiet", not daw.transport.metronome) end,
      done = "No click.",
    },
    {
      say = "`ma` sets mark a at the cursor. Press `ma`.",
      keys = { "ma" },
      start = function(ctx) ctx.before = daw.keymap.marks("arrange").a end,
      check = function(ctx) local m = daw.keymap.marks("arrange").a return m and m ~= ctx.before and m.beat == 24 end,
      done = "Mark a is on the chorus. `:marks` lists marks.",
    },
    {
      say = "Go somewhere else with `G` (the last track) and `0` (the start), then press `'a` to jump back to the mark.",
      keys = { "G", "0", "'a" },
      check = function(ctx, look)
        local there = look.cursor_track() == "Drums" and daw.cursor.beat == 24
        if not there then ctx.away = true end
        return there and ctx.away
      end,
      done = "Back on the chorus of Drums.",
      hint = "`'` is the apostrophe key.",
    },
    {
      say = "`''` goes back to where you jumped from. Press `''`.",
      keys = { "''" },
      check = function(_, look) return look.cursor_track() == "Lead" and daw.cursor.beat == 0 end,
      done = "On Lead at the start, where you were before `'a`. `''` again would go back to the chorus; `<C-o>` goes further back.",
    },
    {
      say = "`gl` takes motions too: press `3|` to go to bar 3, then `gl2W` to loop two bars from there.",
      keys = { "3|", "gl2W" },
      check = function() return daw.transport.loop_start == 8 and daw.transport.loop_end == 16 end,
      done = "The first two bars of the verse are the loop.",
    },
    {
      say = "Listen: `gp` and `<Space>`; `<Space>` stops.",
      keys = { "gp", "<Space>", { wait = 300 }, "<Space>" },
      check = function(ctx, look) return look.ran(ctx, "transport.to_cursor") and look.played(ctx) end,
      done = "Two bars of the verse, round and round.",
    },
  },
  outro = "`gL`, `glic` and `gl2W` for the loop, `gm` for the click, `/` to find, `ma` `'a` `''` to come and go.",
}
