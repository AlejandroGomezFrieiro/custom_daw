-- Lesson 5: operators, motions, text objects, counts and `.` on clips.
return {
  id = "grammar",
  title = "The grammar: operators, motions, text objects",
  intro = [[
This is the heart of the DAW. Most editing is a short sentence: an operator
(what to do) followed by a motion or a text object (what to do it to).
`d` is delete, `w` is "to the next clip", so `dw` deletes up to the next clip.
`ic` is "the clip I am in", so `dic` deletes this clip. A count says how many:
`d2W` deletes two bars. Typing the operator twice takes whole tracks: `dd`.
And `.` repeats the last change wherever the cursor is now.

The Beat track has four clips: kick, snare, fill, crash. Bass plays under them.]],
  idea = [[
Operators: `d` delete, `y` yank (copy), `c` change, `>` `<` move later and
earlier, `=` snap to the grid, `gc` mute, `gl` loop. Motions: every key from
lesson 2. Text objects: `ic` the clip, `ac` the clip and the gap after it, `ib`
the bar, `il` the loop, `it` everything on the track, `ie` the entire project.
Learn a few of each and you know their products: six operators and ten motions
are sixty commands.]],
  vim = [[
This is Vim's grammar, unchanged: operator, count, motion or text object; the
operator twice for whole lines (tracks); `.` with a new count. `gc` is
commenting out, here muting. `gl` (loop) is new. `c` empties the stretch and
opens a fresh clip in insert mode.]],
  setup = function(look)
    daw.project.tempo = 104
    local beat = daw.add_track({ name = "Beat" })
    beat:add_device("drums")
    beat:add_clip({ name = "kick", start = 0, length = 4, notes = look.drums({ [36] = "x...x...x...x..." }) })
    beat:add_clip({ name = "snare", start = 4, length = 4, notes = look.drums({ [36] = "x.......x.......", [38] = "....x.......x..." }) })
    beat:add_clip({ name = "fill", start = 8, length = 4, notes = look.drums({ [36] = "x.......", [38] = "........x.x.xxxx" }) })
    beat:add_clip({ name = "crash", start = 12, length = 4, notes = look.drums({ [36] = "x...", [46] = "x......." }) })
    local bass = daw.add_track({ name = "Bass", volume = -6 })
    bass:add_device("synth", { wave = 2, cutoff = 600, release = 0.05 })
    bass:add_clip({ name = "bass", start = 0, length = 16, notes = look.pulse("E2", 16) })
  end,
  at = function() daw.cursor.set_track(daw.track("Beat")) end,
  steps = {
    {
      say = "The cursor is at the start of `kick`. `d` is the delete operator and `w` the motion to the next clip: press `dw`.",
      keys = { "dw" },
      check = function(_, look) return look.names("Beat") == "snare fill crash" end,
      done = "`kick` is gone: `dw` deleted from the cursor to where `snare` starts.",
      hint = "After `d` the status line says PENDING: the operator waits for its motion. `<Esc>` cancels it.",
    },
    {
      say = "Press `u` to bring it back.",
      keys = { "u" },
      check = function(ctx, look) return look.ran(ctx, "undo") and look.names("Beat") == "kick snare fill crash" end,
      done = "All four clips again.",
    },
    {
      say = "A text object names a thing instead of a movement: `ic` is the clip under the cursor. Press `w` to go to `snare`, then `dic`.",
      keys = { "w", "dic" },
      check = function(_, look) return look.names("Beat") == "kick fill crash" end,
      done = "`dic`: delete in clip. A gap is left where `snare` was.",
    },
    {
      say = "`.` repeats the last change. Press `w` to go to `fill`, then `.` to delete it too.",
      keys = { "w", "." },
      check = function(_, look) return look.names("Beat") == "kick crash" end,
      done = "`.` did `dic` again, on the clip under the cursor now.",
    },
    {
      say = "Undo both: press `u` twice.",
      keys = { "u", "u" },
      check = function(ctx, look) return look.ran(ctx, "undo") and look.names("Beat") == "kick snare fill crash" end,
      done = "Back to four clips.",
    },
    {
      say = "A count goes with the motion: `d2W` deletes two bars from the cursor. Press `0`, then `d2W`.",
      keys = { "0", "d2W" },
      check = function(_, look) return look.names("Beat") == "fill crash" end,
      done = "Two bars of Beat deleted; Bass is untouched, since the operator works on the cursor's track.",
    },
    {
      say = "Press `u` to undo that.",
      keys = { "u" },
      check = function(ctx, look) return look.ran(ctx, "undo") and look.names("Beat") == "kick snare fill crash" end,
      done = "Restored.",
    },
    {
      say = "Other operators take the same motions and objects. `gc` mutes: press `gcic` to mute `kick`.",
      keys = { "gcic" },
      check = function(_, look) local c = look.clip("Beat", "kick") return c and c.muted end,
      done = "`kick` is muted (greyed). `gcic` again would unmute it.",
    },
    {
      say = "Press `w` to go to `snare` and `.` to mute it the same way.",
      keys = { "w", "." },
      check = function(_, look) local c = look.clip("Beat", "snare") return c and c.muted end,
      done = "`.` repeats any change: deleting, muting, moving.",
    },
    {
      say = "Typed twice, an operator takes whole tracks: `dd` deletes a track. Press `j` to go to Bass, then `dd`.",
      keys = { "j", "dd" },
      check = function(_, look) return look.track("Bass") == nil end,
      done = "The Bass track is gone, and it is in the register.",
    },
    {
      say = "`p` puts what was deleted back after the cursor: for a track, below it. Press `p`.",
      keys = { "p" },
      check = function(ctx, look) return look.became(ctx, "back", look.track("Bass") ~= nil and #daw.tracks() == 2) end,
      done = "Bass is back, with its synth and clip. Deleting is cutting.",
    },
    {
      say = "`gl` is the loop operator. Go up to Beat with `k`, put the cursor on `snare` with `0` and `w`, then press `glic`.",
      keys = { "k", "0", "w", "glic" },
      check = function()
        return daw.transport.loop_enabled and daw.transport.loop_start == 4 and daw.transport.loop_end == 8
      end,
      done = "The loop is the snare clip: the ruler shows it.",
    },
    {
      say = "Unmute `snare` with `gcic`, and press `<Space>` to hear the loop; `<Space>` stops.",
      keys = { "gcic", "<Space>", { wait = 300 }, "<Space>" },
      check = function(ctx, look)
        local c = look.clip("Beat", "snare")
        return c and not c.muted and look.played(ctx)
      end,
      done = "The snare bar and the bass, round and round.",
    },
  },
  outro = "Operator plus motion (`dw`, `d2W`), operator plus text object (`dic`, `gcic`, `glic`), twice for tracks (`dd`), and `.` to repeat.",
}
