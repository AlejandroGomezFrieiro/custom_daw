<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 8: Yank, paste, registers and macros

*About ten minutes. In the DAW, with the tutor loaded: `:tutor 8`.*

Deleting and yanking put what they took in a register; pasting takes it out. There is one register you use without naming it, and named ones (`"a` to `"z`) for keeping several things at once. Every change can be undone, a count at a time. And a macro records keys into a register to play them again.

The Lead track has a short hook; Bass has two clips, A and B.

## The idea

`y` yanks, `d` and `x` delete into the register, `p` pastes after the clip (or note) under the cursor and `P` at the cursor; `3p` pastes three in a row, and `p` again carries on from the last paste. `"a` before a command names the register: `"ayic`, `"ap`. `"0` keeps the last yank even after deletes, `"_` throws away, `:registers` shows them all. `u` undoes, `3u` three times, `<C-r>` redoes. `qq` records keys into register q until `q`; `@q` plays them, `@@` plays the last macro again, `5@q` five times.

## If you know Vim

Registers, `"0`, `"_`, `qq`…`q`, `@q`, `@@` and `@:` are Vim's. What a register holds is clips, tracks, notes or a device rather than text, and pasted time replaces what was there (`:lua daw.opt.ripple = true` makes it push along).

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. The cursor is on the hook. Press `yic` to yank (copy) the clip.
   - ✓ The hook is in the unnamed register, and in register 0, which keeps the last yank.
2. `p` pastes after the clip under the cursor. Press `p`.
   - ✓ A second hook, right after the first.
3. A count pastes several in a row, and `p` again carries on from the last paste. Press `2p`.
   - ✓ Four hooks, filling four bars.
4. Named registers keep several things at once. Press `j` to go to Bass, `0` to its start, and `"ayic` to yank clip A into register a.
   - *Hint:* `"` is the double quote key: `"`, then `a`, then `yic`.
   - ✓ Register a holds A.
5. Press `w` to go to B and `"byic` to yank it into register b.
   - ✓ Register b holds B.
6. `:registers` shows what each register holds. Type `:registers` and `<CR>`, look, and press `q` to close it.
   - ✓ `"a` and `"b` are there, beside `"0` and the unnamed `""`.
7. Press `$` to go to the end of B, then `"ap` to paste A there and `"bp` to paste B after it.
   - ✓ A B A B: the bass line goes round twice.
8. Undo takes a count too: press `2u` to take both pastes back.
   - ✓ A B again. (`2<C-r>` would redo both.)
9. Now a macro. Press `k` to go up to Lead and `0` to its start, then `qq` to start recording keys into register q.
   - ✓ The status line says `recording @q`.
10. Type the change to record: `12<C-a>` (up an octave), `w` (on to the next clip), then `q` to stop recording.
   - *Hint:* If it went wrong, `u` undoes the change and `qq` records again.
   - ✓ The first hook went up an octave while you recorded, and register q holds `12<C-a>w`.
11. `@q` plays the macro on the clip under the cursor, and `@@` plays it again. Press `@q`, then `@@`.
   - ✓ Three hooks an octave up, the last one as it was.
12. Listen: `gs`, `<Space>`, and `<Space>` to stop.
   - ✓ A hook that climbs and comes back down.

## What you did

`yic` and `p` with counts, named registers, `:registers`, `2u`, and a macro recorded with `qq` and played with `@q` and `@@`.

Previous: [Visual mode: select, then act](07-visual.md) · [All lessons](README.md) · Next: [Devices, parameters and plugins](09-devices.md)
