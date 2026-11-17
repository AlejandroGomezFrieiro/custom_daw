-- Lesson 10: faders, pan, mute, solo, buses, sends, automation.
local api = daw.api

local function near(a, b) return math.abs(a - b) < 1e-6 end

return {
  id = "mixing",
  title = "Mixing: faders, pan, buses, sends, automation",
  intro = [[
Mixing is setting how loud each track is (its fader, in dB), where it sits
from left to right (pan), which tracks to silence (mute) or hear alone (solo),
and where its sound goes: to the master, into a bus that groups tracks under
one fader, or partly to an effect track through a send. Automation changes a
fader (or any parameter) over time.

The mixer shows a strip per track; the same changes can be made from the
arrange view.]],
  idea = [[
In the mixer tracks run across, so `h` `l` choose a strip and `j` `k` a row of
it (its devices, sends, fader, pan, mute, solo, arm). `+` `-` change the row
under the cursor, by 1 dB on the fader, `]` `[` pan, `M` `s` `r` mute, solo,
arm. In the arrange view the same are `+` `-`, `]` `[`, `M` `s` `r`. Routing is done by command:
`:track.output Bus` sends the track into the track called Bus, `:track.output`
alone back to the master. `A` adds a volume automation point at the cursor,
`,at` switches the automation off and on, `,ax` clears it.]],
  vim = [[
The mixer turns the grid sideways: `h` `l` move between tracks because tracks
are its columns, and `j` `k` only ever move, as everywhere. `6<C-x>` lowers the
row by six, as `<C-x>` lowers a number in Vim. `<C-w>c` closes it.]],
  setup = function(look)
    daw.project.tempo = 100
    local drums = daw.add_track({ name = "Drums", volume = -6 })
    drums:add_device("drums")
    drums:add_clip({ name = "beat", start = 0, length = 16, notes = look.drums(look.beat, 4) })
    local bass = daw.add_track({ name = "Bass", volume = -4 })
    bass:add_device("synth", { wave = 2, cutoff = 600, release = 0.05 })
    local line = {}
    for i, root in ipairs({ "A1", "F1", "C2", "G1" }) do
      for _, n in ipairs(look.pulse(root, 4, (i - 1) * 4)) do line[#line + 1] = n end
    end
    bass:add_clip({ name = "bass", start = 0, length = 16, notes = line })
    local keys = daw.add_track({ name = "Keys", volume = -10 })
    keys:add_device("synth", { wave = 3, attack = 0.05, release = 0.4, cutoff = 1800 })
    local chords = {}
    for i, chord in ipairs({ { "A3", "C4", "E4" }, { "F3", "A3", "C4" }, { "G3", "C4", "E4" }, { "G3", "B3", "D4" } }) do
      for _, n in ipairs(look.chord(chord, 4, (i - 1) * 4)) do chords[#chords + 1] = n end
    end
    keys:add_clip({ name = "chords", start = 0, length = 16, notes = chords })
    local lead = daw.add_track({ name = "Lead", volume = -8 })
    lead:add_device("synth", { wave = 1, cutoff = 2400, release = 0.2 })
    lead:add_clip({ name = "melody", start = 0, length = 16, notes = look.notes("E5:0:1 C5:1:1 A4:2:2 F4:4:1 A4:5:1 C5:6:2 E5:8:1 G5:9:1 E5:10:2 D5:12:2 B4:14:2") })
    local echo = daw.add_track({ name = "Echo", volume = -6 })
    echo:add_device("delay", { mix = 1, feedback = 0.45 })
    daw.transport.loop_start, daw.transport.loop_end, daw.transport.loop_enabled = 0, 16, true
  end,
  at = function() daw.cursor.set_track(daw.track("Drums")) end,
  steps = {
    {
      say = "Press `,m` to open the mixer along the bottom: a strip per track, with its fader and meter.",
      keys = { ",m" },
      check = function(_, look) return look.focused() == "mixer" end,
      done = "The mixer has the keyboard. The master is on the right.",
    },
    {
      say = "Here `h` and `l` choose a strip and the cursor starts on its fader; `-` and `+` move the row under the cursor down and up by 1 dB. Press `l` to go to Bass, then `-` three times.",
      keys = { "l", "-", "-", "-" },
      check = function(_, look) return look.cursor_track() == "Bass" and near(look.track("Bass").volume, -7) end,
      done = "Bass is at -7 dB, three quieter than it was. `3-` or `3<C-x>` does it in one go.",
    },
    {
      say = "`]` and `[` pan the strip right and left, wherever the cursor is on it. Press `]` three times.",
      keys = { "]", "]", "]", { wait = 1000 } },
      check = function(_, look) return near(look.track("Bass").pan, 0.3) end,
      done = "Bass leans to the right.",
    },
    {
      say = "`s` solos a track: only soloed tracks are heard. Press `<Space>` to play, `s` to hear Bass alone, `s` again to hear everything, and `<Space>` to stop.",
      keys = { "<Space>", "s", { wait = 200 }, "s", "<Space>" },
      check = function(ctx, look)
        local _, n = look.ran(ctx, "track.solo")
        return n >= 2 and not look.track("Bass").solo and look.played(ctx)
      end,
      done = "Solo is for listening closely; it changes nothing in the mix.",
    },
    {
      say = "`M` mutes. Press `l` to go to Keys and `M` to mute it.",
      keys = { "l", "M" },
      check = function(_, look) return look.track("Keys").mute end,
      done = "Keys is muted: its `M` is lit.",
    },
    {
      say = "Press `M` again to unmute Keys, and `<C-w>c` to close the mixer.",
      keys = { "M", "<C-w>c" },
      check = function(ctx, look) return look.became(ctx, "back", not look.track("Keys").mute and not look.visible("mixer")) end,
      done = "Back in the arrange view, still on Keys. Here too `+` `-` are the fader and `]` `[` the pan.",
    },
    {
      say = "A bus is a track that others play into. Type `:track.add Bus` and `<CR>` to add one.",
      keys = { ":track.add Bus", "<CR>" },
      check = function(_, look) return look.track("Bus") ~= nil end,
      done = "A track called Bus, below Keys. The cursor is on it.",
    },
    {
      say = "Route Keys into it: `/Keys` and `<CR>` find the track, then type `:track.output Bus` and `<CR>`.",
      keys = { "/Keys", "<CR>", ":track.output Bus", "<CR>" },
      check = function(_, look) return api.track_get(look.track("Keys").id).output == look.track("Bus").id end,
      done = "Keys now plays through Bus: Bus's fader turns the chords up and down, with anything else you route there.",
    },
    {
      say = "A send copies some of a track to another, here to Echo, which has a delay. There is no key for it yet: type `:lua daw.track(\"Lead\"):send(daw.track(\"Echo\"), -6)` and `<CR>`.",
      keys = { ":lua daw.track(\"Lead\"):send(daw.track(\"Echo\"), -6)", "<CR>" },
      check = function(_, look)
        for _, send in ipairs(api.track_get(look.track("Lead").id).sends) do
          if send.target == look.track("Echo").id and near(send.level, -6) then return true end
        end
      end,
      done = "Lead sends to Echo 6 dB down: the melody now has an echo, and Echo's fader sets how much.",
      hint = "`:lua` runs Lua; Tab does not complete inside it, so type it as it is.",
    },
    {
      say = "Automation: `A` adds a volume point at the cursor and asks its value. On Keys, press `0`, `A`, `<C-u>` to clear the value, type `-30` and `<CR>`.",
      keys = { "0", "A", "<C-u>", "-30", "<CR>" },
      check = function(_, look)
        local lane = look.track("Keys"):lane("volume")
        return lane and #lane:points() == 1 and lane:points()[1][1] == 0 and near(lane:points()[1][2], -30)
      end,
      done = "A point: -30 dB at the start. An `A` appears in the track header.",
      hint = "The cursor must be on Keys: `/Keys` and `<CR>`.",
    },
    {
      say = "Press `2W` to go two bars on, then `A`, `<C-u>`, `-10` and `<CR>`: the chords fade in over two bars.",
      keys = { "2W", "A", "<C-u>", "-10", "<CR>" },
      check = function(_, look)
        local lane = look.track("Keys"):lane("volume")
        local p = lane and lane:points()
        return p and #p == 2 and p[2][1] == 8 and near(p[2][2], -10)
      end,
      done = "The line between the points is drawn in the track's lane.",
    },
    {
      say = "Listen from the start: `gs`, `<Space>`, and `<Space>` to stop.",
      keys = { "gs", "<Space>", { wait = 300 }, "<Space>" },
      check = function(ctx, look) return look.ran(ctx, "transport.start") and look.played(ctx) end,
      done = "Chords fading in through a bus, a melody with an echo, the bass to the right.",
    },
  },
  outro = "The mixer's faders, pan, solo and mute; a bus with `:track.output`; a send; volume automation with `A`.",
}
