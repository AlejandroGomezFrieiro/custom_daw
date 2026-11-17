-- Lesson 2: motions, counts, and why keys change meaning.
return {
  id = "moving",
  title = "Moving around, and why keys change meaning",
  intro = [[
In the arrange view a track is a line and time runs along it, a beat to a grid
step. A clip on a track is like a word on a line. The keys that move the cursor
are called motions, and they come in families: small steps, clips, bars, the
ends of things, other tracks. A number typed first repeats a motion.

The same key can mean different things: in a different mode (normal, visual,
insert), or in a different view (the arrange view, the piano roll, the mixer).
The status line always says which mode you are in, and the view with the
keyboard has a brighter frame or highlight.]],
  idea = [[
Motions: `h` `l` a grid step, `w` `b` `e` clips (next start, this start, this
end), `W` `B` bars, `0` `^` `$` the start of the project, the first clip, the end
of the last clip, `j` `k` tracks, `gg` `G` the first and last track, `5|` bar 5.
A count goes in front: `4l`, `2W`, `3j`. Modes: NORMAL for moving and acting,
VISUAL for selecting (`v`), INSERT for entering notes (`i`), PENDING while an
operator waits for its motion. `<Esc>` returns to NORMAL.]],
  vim = [[
`hjkl`, `w` `b` `e`, `W` `B`, `0` `^` `$`, `gg` `G`, counts and `|` are all here.
Differences: `w` goes to clip starts (there is no WORD), `W` `B` are bars, `0` is
the start of the project, `^` the first clip, `|` and `:5` take a bar number,
not a column or a line.]],
  setup = function(look)
    paw.project.tempo = 96
    local drums = paw.add_track({ name = "Drums" })
    drums:add_device("drums")
    drums:add_clip({ name = "beat", start = 0, length = 28, notes = look.drums(look.beat, 7) })
    local bass = paw.add_track({ name = "Bass", volume = -4 })
    bass:add_device("synth", { wave = 2, cutoff = 700, release = 0.05 })
    bass:add_clip({ name = "verse", start = 0, length = 8, notes = look.pulse("D2", 8) })
    bass:add_clip({ name = "chorus", start = 12, length = 8, notes = look.pulse("G1", 8) })
    bass:add_clip({ name = "outro", start = 24, length = 4, notes = look.pulse("D2", 4) })
    local lead = paw.add_track({ name = "Lead", volume = -8 })
    lead:add_device("synth", { wave = 1, cutoff = 2500, release = 0.2 })
    lead:add_clip({ name = "melody", start = 16, length = 8, notes = look.notes("D5:0:1 F5:1:1 A5:2:2 G5:4:1 F5:5:1 E5:6:2") })
    local pad = paw.add_track({ name = "Pad", volume = -12 })
    pad:add_device("synth", { wave = 3, attack = 0.3, release = 0.6, cutoff = 1500 })
    pad:add_clip({ name = "pad", start = 16, length = 12, notes = look.chord({ "D4", "F4", "A4" }, 12) })
  end,
  at = function() paw.cursor.set_track(paw.track("Bass")) end,
  steps = {
    {
      say = "The cursor is on the Bass track at the start. `l` moves it right one grid step (a beat), `h` left. Press `l` three times.",
      keys = { "l", "l", "l" },
      check = function() return paw.cursor.beat == 3 end,
      done = "Three beats on: the clock at the top left of the arrange view says 1.4.00, bar 1 beat 4.",
    },
    {
      say = "A number before a motion repeats it. Press `4l` to go four beats on.",
      keys = { "4l" },
      check = function() return paw.cursor.beat == 7 end,
      done = "Beat 7, near the end of the clip `verse`.",
      hint = "Type the 4 and then the l. If you went elsewhere, `0` goes to the start and `3l` back to beat 3.",
    },
    {
      say = "`0` goes back to the start of the project. Press `0`.",
      keys = { "0" },
      check = function(ctx, look) return look.ran(ctx, "cursor.start") and paw.cursor.beat == 0 end,
      done = "Back at the start.",
    },
    {
      say = "A clip is like a word: `w` jumps to the start of the next clip on the track. Press `w`.",
      keys = { "w" },
      check = function() return paw.cursor.beat == 12 end,
      done = "On `chorus`, which starts at beat 12 (bar 4).",
    },
    {
      say = "`e` goes to the end of the clip and `b` back to its start. Press `e`, then `b`.",
      keys = { "e", "b" },
      check = function(ctx, look)
        return look.ran(ctx, "cursor.clip_end") and look.ran(ctx, "cursor.prev_clip") and paw.cursor.beat == 12
      end,
      done = "`w` `b` `e`: next start, this start, this end.",
    },
    {
      say = "`W` and `B` move by bars (four beats here). Press `2W` to go two bars on.",
      keys = { "2W" },
      check = function() return paw.cursor.beat == 20 end,
      done = "Bar 6 (beat 20).",
    },
    {
      say = "`$` goes to the end of the track's last clip (and `^` to its first clip). Press `$`.",
      keys = { "$" },
      check = function() return paw.cursor.beat == 28 end,
      done = "At the end of `outro`, where the song ends.",
    },
    {
      say = "Tracks are lines: `G` goes to the last track and `gg` to the first. Press `G`.",
      keys = { "G" },
      check = function(_, look) return look.cursor_track() == "Pad" end,
      done = "On Pad, the last track. `3G` would go to track 3.",
    },
    {
      say = "`5|` goes to bar 5 (typing `:5` and `<CR>` does the same). Press `5|`.",
      keys = { "5|" },
      check = function() return paw.cursor.beat == 16 end,
      done = "Bar 5, where the pad comes in.",
      hint = "`|` is the bar key, usually shift and backslash.",
    },
    {
      say = "Now the same keys in another mode. Press `v`: the status line says VISUAL, and moving stretches a selection. Press `l` twice to stretch it.",
      keys = { "v", "l", "l" },
      check = function() return paw.keymap.mode == "x" and paw.cursor.beat == 18 end,
      done = "In visual mode `l` still moves, but it also selects. Lesson 7 is about what to do with a selection.",
    },
    {
      say = "`<Esc>` always brings you back to NORMAL. Press `<Esc>`.",
      keys = { "<Esc>" },
      check = function(ctx, look) return look.became(ctx, "normal", paw.keymap.mode == "n") end,
      done = "NORMAL again.",
    },
    {
      say = "And in another view: `<CR>` (Enter) on a clip opens it in the piano roll. Press `<CR>` on the pad clip.",
      keys = { "<CR>" },
      check = function(_, look) return look.focused() == "pianoroll" end,
      done = "The piano roll has the keyboard now.",
      hint = "The cursor must be on a clip: `5|` on the Pad track puts it there.",
    },
    {
      say = "Here the rows are pitches, so `k` goes up a semitone instead of a track. Press `k` twice (you hear each pitch).",
      keys = { "k", "k" },
      start = function(ctx) ctx.pitch = paw.ui.views.pianoroll.pitch end,
      check = function(ctx, look)
        return look.focused() == "pianoroll" and paw.ui.views.pianoroll.pitch == ctx.pitch + 2
      end,
      done = "Same key, different view, different meaning: but still 'up'.",
    },
    {
      say = "`<Esc>` stays where it is, in every view; `<C-w>p` goes back to the window before. Press `<C-w>p` to leave the piano roll. Then `gp` puts the playhead at the cursor and `<Space>` plays from there; `<Space>` again stops.",
      keys = { "<C-w>p", "gp", "<Space>", { wait = 300 }, "<Space>" },
      check = function(ctx, look)
        return look.focused() == "arrange" and look.ran(ctx, "transport.to_cursor") and look.played(ctx)
      end,
      done = "You played the song from bar 5, where the melody comes in.",
      hint = "`<S-CR>` (shift and Enter) plays from the cursor in one go, where the terminal can tell it from Enter.",
    },
  },
  outro = "Motions by step, clip, bar and track, with counts; and the same keys meaning other things in visual mode and in the piano roll.",
}
