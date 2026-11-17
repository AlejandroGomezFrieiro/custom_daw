-- Lesson 17: Ex lines, ranges of time and tracks, `:s` and `:g`.
return {
  id = "ranges",
  title = "Ranges, :s and :g: editing by line",
  intro = [[
Operators and visual mode act where the cursor is. The command line can act
anywhere at once: a range in front of a command says where, as in Vim's Ex,
with bars for lines. `:2,3d` empties bars 2 and 3, `:t2 4d` bar 4 of track 2
alone, `:%s/c4/d4/g` makes every C4 of the song a D4.

The three tracks here have four one-bar clips each. Watch the right end of the
command line while you type: it says what the line would do, and the views
light it up, before anything changes.]],
  idea = [[
A range is of time (`5,8` bars, `5.3` a beat, `%` all, `.` the cursor's bar,
`$` the last, `'a,'b` marks, `'<,'>` the selection, `.+4` offsets), of
tracks (`t2,t4`, `t*`, `t/Drums/`), or both (`:t2 5,8d`). Commands: `d` `y`
`co` `m` `>` `<` `j`, `mute` `solo` `volume` `pan`, `transpose` `quantize`,
`normal`, `s` and `g`. A pattern names notes or clips by their fields: `c4`,
`vel>100`, `len<1/8`, `name:Verse`. Each line is one undo step.]],
  vim = [[
Ranges, `:d` `:y` `:co` `:m` `:>` `:j` `:normal`, `:s` with `g`, `c` and `n`,
`:&`, `:g` and `:v` are Vim's, with a bar where Vim has a line; `inccommand`
is Neovim's. Without `g` only the first match in each bar changes, as in Vim
only the first on each line. Vim's `:t` is not here: `t` starts tracks.]],
  setup = function(look)
    paw.project.tempo = 100
    local function track(name, device, params, make)
      local t = paw.add_track({ name = name, volume = name == "Keys" and -10 or -4 })
      t:add_device(device, params)
      for i = 1, 4 do t:add_clip({ name = name:sub(1, 1):lower() .. i, start = (i - 1) * 4, length = 4, notes = make(i) }) end
    end
    track("Drums", "drums", {}, function() return look.drums(look.beat) end)
    local roots = { "A1", "F1", "C2", "G1" }
    track("Bass", "synth", { wave = 2, cutoff = 600, release = 0.05 }, function(i) return look.pulse(roots[i], 4) end)
    local chords = { { "A3", "C4", "E4" }, { "F3", "A3", "C4" }, { "G3", "C4", "E4" }, { "G3", "B3", "D4" } }
    track("Keys", "synth", { wave = 3, attack = 0.05, release = 0.4, cutoff = 1800 }, function(i) return look.chord(chords[i], 4) end)
    paw.transport.loop_start, paw.transport.loop_end, paw.transport.loop_enabled = 0, 16, true
  end,
  at = function() paw.cursor.set_track(paw.track("Drums")) end,
  steps = {
    {
      say = "Type `:2,3d` (bars 2 to 3, delete). Before Enter, see the right end of the line say `bars 2–3` and the ruler shade them; then press `<CR>`.",
      keys = { ":2,3d", "<CR>" },
      check = function(_, look) return look.names("Drums") == "d1 d4" and look.names("Keys") == "k1 k4" end,
      done = "Bars 2 and 3 are empty on every track, and what was there is in the register.",
    },
    {
      say = "The whole line is one change: press `u`.",
      keys = { "u" },
      check = function(ctx, look) return look.ran(ctx, "undo") and look.names("Drums") == "d1 d2 d3 d4" end,
      done = "Back, in one step.",
    },
    {
      say = "Tracks go first: `:t2 4d` empties bar 4 of track 2, Bass, alone. Type it and press `<CR>`.",
      keys = { ":t2 4d", "<CR>" },
      check = function(_, look) return look.names("Bass") == "b1 b2 b3" and look.names("Drums") == "d1 d2 d3 d4" end,
      done = "Only Bass lost its last bar.",
    },
    {
      say = "Press `u` again.",
      keys = { "u" },
      check = function(ctx, look) return look.ran(ctx, "undo") and look.names("Bass") == "b1 b2 b3 b4" end,
      done = "Back.",
    },
    {
      say = "`t*` is every track. Turn them all down 3 dB: `:t* volume -3`, then `<CR>`.",
      keys = { ":t* volume -3", "<CR>" },
      check = function(_, look) return look.track("Keys").volume == -13 and look.track("Drums").volume == -7 end,
      done = "Every fader went down 3 dB; `=-6` would have set them all to -6 dB.",
    },
    {
      say = "Now `:s`. Type `:%s/c4/d4/g`: the line counts the C4s of the song, and the clips that hold them light up. Press `<CR>`.",
      keys = { ":%s/c4/d4/g", "<CR>" },
      check = function(_, look)
        local c4, d4 = 0, 0
        for _, c in ipairs(look.clips("Keys")) do
          for _, n in ipairs(c:notes()) do
            if n.pitch == 60 then c4 = c4 + 1 elseif n.pitch == 62 then d4 = d4 + 1 end
          end
        end
        return c4 == 0 and d4 == 4
      end,
      done = "Every C4 is a D4. `%` was the whole song, `g` every match in each bar.",
      hint = "`<Esc>` leaves the line without changing anything; then `:` and type it again.",
    },
    {
      say = "`:g` runs a command on every match. Mute the Bass clips by name: `:g/name:b/mute`, then `<CR>`.",
      keys = { ":g/name:b/mute", "<CR>" },
      check = function(_, look) return look.layout("Bass"):gsub("[^m]", "") == "mmmm" end,
      done = "All four Bass clips are muted. `:g/vel>100/` with no command puts the matches in the quickfix list, for `]q`.",
    },
  },
  outro = "`:2,3d`, `:t2 4d`, `:t* volume -3`, `:%s/c4/d4/g` and `:g/name:b/mute`: a range, then a command, each one undo step.",
}
