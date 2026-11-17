-- Lesson 8: yank, paste, registers, undo with counts, macros.
local HOOK = "A4:0:0.5 C5:0.5:0.5 E5:1:1 D5:2:0.5 C5:2.5:0.5 A4:3:1"

--- The hook's notes moved by `by` semitones, as `look.melody` writes them.
local function hook(look, by)
  local notes = look.notes(HOOK)
  for _, n in ipairs(notes) do n.pitch = n.pitch + by end
  local out = {}
  for i, n in ipairs(notes) do out[i] = string.format("%d@%g+%g", n.pitch, n.start, n.length) end
  table.sort(out)
  return table.concat(out, " ")
end

local function sorted(look, clip)
  local list = {}
  for item in look.melody(clip):gmatch("%S+") do list[#list + 1] = item end
  table.sort(list)
  return table.concat(list, " ")
end

return {
  id = "registers",
  title = "Yank, paste, registers and macros",
  intro = [[
Deleting and yanking put what they took in a register; pasting takes it out.
There is one register you use without naming it, and named ones (`"a` to `"z`)
for keeping several things at once. Every change can be undone, a count at a
time. And a macro records keys into a register to play them again.

The Lead track has a short hook; Bass has two clips, A and B.]],
  idea = [[
`y` yanks, `d` and `x` delete into the register, `p` pastes after the clip (or
note) under the cursor and `P` at the cursor; `3p` pastes three in a row, and `p`
again carries on from the last paste. `"a` before a command names the register:
`"ayic`, `"ap`. `"0` keeps the last yank even after deletes, `"_` throws away,
`:registers` shows them all. `u` undoes, `3u` three times, `<C-r>` redoes. `qq`
records keys into register q until `q`; `@q` plays them, `@@` plays the last
macro again, `5@q` five times.]],
  vim = [[
Registers, `"0`, `"_`, `qq`…`q`, `@q`, `@@` and `@:` are Vim's. What a register
holds is clips, tracks, notes or a device rather than text, and pasted time
replaces what was there (`:lua daw.opt.ripple = true` makes it push along).]],
  setup = function(look)
    daw.project.tempo = 100
    local drums = daw.add_track({ name = "Drums", volume = -6 })
    drums:add_device("drums")
    drums:add_clip({ name = "beat", start = 0, length = 16, notes = look.drums(look.beat, 4) })
    local lead = daw.add_track({ name = "Lead", volume = -6 })
    lead:add_device("synth", { wave = 1, cutoff = 2400, release = 0.2 })
    lead:add_clip({ name = "hook", start = 0, length = 4, notes = look.notes(HOOK) })
    local bass = daw.add_track({ name = "Bass", volume = -4 })
    bass:add_device("synth", { wave = 2, cutoff = 600, release = 0.05 })
    bass:add_clip({ name = "A", start = 0, length = 4, notes = look.pulse("A1", 4) })
    bass:add_clip({ name = "B", start = 4, length = 4, notes = look.pulse("F1", 4) })
    daw.transport.loop_start, daw.transport.loop_end, daw.transport.loop_enabled = 0, 16, true
  end,
  at = function() daw.cursor.set_track(daw.track("Lead")) end,
  steps = {
    {
      say = "The cursor is on the hook. Press `yic` to yank (copy) the clip.",
      keys = { "yic" },
      start = function(ctx) ctx.before = daw.keymap.getreg() end,
      check = function(ctx)
        local r = daw.keymap.getreg()
        return r ~= ctx.before and r and r.kind == "range" and daw.keymap.getreg("0") == r
      end,
      done = "The hook is in the unnamed register, and in register 0, which keeps the last yank.",
    },
    {
      say = "`p` pastes after the clip under the cursor. Press `p`.",
      keys = { "p" },
      check = function(_, look) return look.layout("Lead") == "hook@0+4 hook@4+4" end,
      done = "A second hook, right after the first.",
    },
    {
      say = "A count pastes several in a row, and `p` again carries on from the last paste. Press `2p`.",
      keys = { "2p" },
      check = function(_, look) return look.layout("Lead") == "hook@0+4 hook@4+4 hook@8+4 hook@12+4" end,
      done = "Four hooks, filling four bars.",
    },
    {
      say = "Named registers keep several things at once. Press `j` to go to Bass, `0` to its start, and `\"ayic` to yank clip A into register a.",
      keys = { "j", "0", "\"ayic" },
      start = function(ctx) ctx.before = daw.keymap.getreg("a") end,
      check = function(ctx)
        local r = daw.keymap.getreg("a")
        return r and r ~= ctx.before and r.kind == "range" and r.rows[1] and r.rows[1][1] and r.rows[1][1].name == "A"
      end,
      done = "Register a holds A.",
      hint = "`\"` is the double quote key: `\"`, then `a`, then `yic`.",
    },
    {
      say = "Press `w` to go to B and `\"byic` to yank it into register b.",
      keys = { "w", "\"byic" },
      start = function(ctx) ctx.before = daw.keymap.getreg("b") end,
      check = function(ctx)
        local r = daw.keymap.getreg("b")
        return r and r ~= ctx.before and r.kind == "range" and r.rows[1] and r.rows[1][1] and r.rows[1][1].name == "B"
      end,
      done = "Register b holds B.",
    },
    {
      say = "`:registers` shows what each register holds. Type `:registers` and `<CR>`, look, and press `q` to close it.",
      keys = { ":registers", "<CR>", "q" },
      check = function(ctx, look) return look.ran(ctx, "registers") and not look.float() end,
      done = "`\"a` and `\"b` are there, beside `\"0` and the unnamed `\"\"`.",
    },
    {
      say = "Press `$` to go to the end of B, then `\"ap` to paste A there and `\"bp` to paste B after it.",
      keys = { "$", "\"ap", "\"bp" },
      check = function(_, look) return look.names("Bass") == "A B A B" end,
      done = "A B A B: the bass line goes round twice.",
    },
    {
      say = "Undo takes a count too: press `2u` to take both pastes back.",
      keys = { "2u" },
      check = function(ctx, look) return look.ran(ctx, "undo") and look.names("Bass") == "A B" end,
      done = "A B again. (`2<C-r>` would redo both.)",
    },
    {
      say = "Now a macro. Press `k` to go up to Lead and `0` to its start, then `qq` to start recording keys into register q.",
      keys = { "k", "0", "qq" },
      check = function(_, look) return daw.keymap.recording() == "q" and look.cursor_track() == "Lead" and daw.cursor.beat == 0 end,
      done = "The status line says `recording @q`.",
    },
    {
      say = "Type the change to record: `vic` (select the clip), `12<C-a>` (its notes up an octave: on a track `<C-a>` is the fader), `w` (on to the next clip), then `q` to stop recording.",
      keys = { "vic", "12<C-a>", "w", "q" },
      start = function(ctx) ctx.before = daw.keymap.registers.q end,
      check = function(ctx)
        local r = daw.keymap.registers.q
        return daw.keymap.recording() == nil and r ~= ctx.before and r and r.kind == "keys" and r.keys == "vic12<C-a>w"
      end,
      done = "The first hook went up an octave while you recorded, and register q holds `vic12<C-a>w`.",
      hint = "If it went wrong, `u` undoes the change and `qq` records again.",
    },
    {
      say = "`@q` plays the macro on the clip under the cursor, and `@@` plays it again. Press `@q`, then `@@`.",
      keys = { "@q", "@@" },
      check = function(_, look)
        local clips = look.clips("Lead")
        return #clips == 4 and sorted(look, clips[2]) == hook(look, 12) and sorted(look, clips[3]) == hook(look, 12)
          and sorted(look, clips[4]) == hook(look, 0)
      end,
      done = "Three hooks an octave up, the last one as it was.",
    },
    {
      say = "Listen: `gs`, `<Space>`, and `<Space>` to stop.",
      keys = { "gs", "<Space>", { wait = 300 }, "<Space>" },
      check = function(ctx, look) return look.ran(ctx, "transport.start") and look.played(ctx) end,
      done = "A hook that climbs and comes back down.",
    },
  },
  outro = "`yic` and `p` with counts, named registers, `:registers`, `2u`, and a macro recorded with `qq` and played with `@q` and `@@`.",
}
