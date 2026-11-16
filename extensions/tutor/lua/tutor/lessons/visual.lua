-- Lesson 7: visual mode, selecting first and acting after.
return {
  id = "visual",
  title = "Visual mode: select, then act",
  intro = [[
Sometimes it is easier to see what you are about to change before you change
it. Visual mode turns that round: first select, with the motions you know, then
press an operator, and it acts on the selection.

`v` selects a stretch of time (and `j` `k` stretch it across tracks), `V` whole
tracks, and in the piano roll `<C-v>` a rectangle of pitches and time. The
three tracks here have four one-bar clips each.]],
  idea = [[
In visual mode motions stretch the selection, `o` jumps to its other end, and an
operator (`d` `y` `c` `>` `<` `gc` `gl`) or one of the selection keys acts on it:
`x` delete, `p` replace it with the register, `~` mute, `J` join clips,
`<C-a>` `<C-x>` transpose (with a count: `12<C-a>` an octave). `gv` selects the
last selection again. `<Esc>` leaves without doing anything.]],
  vim = [[
`v` `V` `<C-v>`, `o`, `gv` and operators on a selection are Vim's. A count
typed in visual mode before `>` `<` or `<C-a>` is the amount, as in Vim.
In the arrange view `v` stretched with `j` `k` is already a block of time on
some tracks; `V` whole tracks are Vim's whole lines.]],
  setup = function(look)
    daw.project.tempo = 100
    local function track(name, device, params, make)
      local t = daw.add_track({ name = name, volume = name == "Keys" and -10 or -4 })
      t:add_device(device, params)
      for i = 1, 4 do t:add_clip({ name = name:sub(1, 1):lower() .. i, start = (i - 1) * 4, length = 4, notes = make(i) }) end
    end
    track("Drums", "drums", {}, function() return look.drums(look.beat) end)
    local roots = { "A1", "F1", "C2", "G1" }
    track("Bass", "synth", { wave = 2, cutoff = 600, release = 0.05 }, function(i) return look.pulse(roots[i], 4) end)
    local chords = { { "A3", "C4", "E4" }, { "F3", "A3", "C4" }, { "G3", "C4", "E4" }, { "G3", "B3", "D4" } }
    track("Keys", "synth", { wave = 3, attack = 0.05, release = 0.4, cutoff = 1800 }, function(i) return look.chord(chords[i], 4) end)
    daw.transport.loop_start, daw.transport.loop_end, daw.transport.loop_enabled = 0, 16, true
  end,
  at = function() daw.cursor.set_track(daw.track("Drums")) end,
  steps = {
    {
      say = "Press `v` to start selecting (the status line says VISUAL), then `W` to stretch the selection over the first bar.",
      keys = { "v", "W" },
      check = function()
        local s = daw.keymap.selection()
        return s and s.kind == "char" and s.c0 == 0 and s.c1 == 4
      end,
      done = "The first bar of Drums is selected.",
    },
    {
      say = "`j` stretches it down to the next track. Press `j`.",
      keys = { "j" },
      check = function()
        local s = daw.keymap.selection()
        return s and s.r0 == 1 and s.r1 == 2 and s.c1 == 4
      end,
      done = "The first bar of Drums and Bass.",
    },
    {
      say = "Now act on it: `x` deletes the selection. Press `x`.",
      keys = { "x" },
      check = function(_, look) return look.names("Drums") == "d2 d3 d4" and look.names("Bass") == "b2 b3 b4" end,
      done = "Deleted from both tracks, and back in NORMAL.",
    },
    {
      say = "Press `u` to undo it.",
      keys = { "u" },
      check = function(ctx, look) return look.ran(ctx, "undo") and look.names("Drums") == "d1 d2 d3 d4" and look.names("Bass") == "b1 b2 b3 b4" end,
      done = "Back.",
    },
    {
      say = "`V` selects whole tracks. Press `V`, `j` to take Drums and Bass, and `y` to yank (copy) them.",
      keys = { "V", "j", "y" },
      check = function()
        local r = daw.keymap.getreg()
        return r and r.kind == "tracks" and #r.tracks == 2 and daw.keymap.mode == "n"
      end,
      done = "Two tracks are in the register.",
      hint = "`<Esc>` leaves visual mode if it went wrong; then `gg` and start again.",
    },
    {
      say = "`G` goes to the last track and `p` pastes the tracks below it. Press `G`, then `p`.",
      keys = { "G", "p" },
      check = function() return #daw.tracks() == 5 end,
      done = "Five tracks: copies of Drums and Bass at the bottom.",
    },
    {
      say = "Press `u` to take the copies away again.",
      keys = { "u" },
      check = function(ctx, look) return look.ran(ctx, "undo") and #daw.tracks() == 3 end,
      done = "Three tracks.",
    },
    {
      say = "`gv` selects what was selected last: the two tracks. Press `gv`, then `~` to mute them.",
      keys = { "gv", "~" },
      check = function(_, look) return look.track("Drums").mute and look.track("Bass").mute end,
      done = "Drums and Bass are muted: their `M` flags are lit. On whole tracks `~` mutes the tracks; on a stretch of time, the clips in it.",
    },
    {
      say = "Press `gv` and `~` again to unmute them.",
      keys = { "gv", "~" },
      check = function(ctx, look) return look.became(ctx, "unmuted", not look.track("Drums").mute and not look.track("Bass").mute) end,
      done = "`~` switches muting on and off.",
    },
    {
      say = "In the piano roll too. Press `3G` to go to Keys and `<CR>` to open its first clip.",
      keys = { "3G", "<CR>" },
      check = function(_, look)
        local _, clip = look.roll()
        return look.focused() == "pianoroll" and clip and clip.name == "k1"
      end,
      done = "The A minor chord of `k1`.",
    },
    {
      say = "`v` selects a stretch of time at every pitch. Press `v`, then `12<C-a>` to move everything that starts in it up an octave.",
      keys = { "v", "12<C-a>" },
      check = function(_, look)
        local _, clip = look.roll()
        return clip and look.melody(clip) == "69@0+4 72@0+4 76@0+4" and daw.keymap.mode == "n"
      end,
      done = "The chord is an octave higher. A count in visual mode is how much.",
      hint = "Type 1, 2, then Ctrl and a, while the status line still says VISUAL.",
    },
    {
      say = "Press `<Esc>` to go back to the arrange view, and `<Space>` to listen; `<Space>` stops.",
      keys = { "<Esc>", "<Space>", { wait = 300 }, "<Space>" },
      check = function(ctx, look) return look.focused() == "arrange" and look.played(ctx) end,
      done = "The first chord rings out an octave up.",
    },
  },
  outro = "`v` and `V` with motions, then `x` `y` `~` or a count and `<C-a>`; `gv` to select again; the same in the piano roll.",
}
