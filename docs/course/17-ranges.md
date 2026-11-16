<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 17: Ranges, :s and :g: editing by line

*About ten minutes. In paw, with the tutor loaded: `:tutor 17`.*

Operators and visual mode act where the cursor is. The command line can act anywhere at once: a range in front of a command says where, as in Vim's Ex, with bars for lines. `:2,3d` empties bars 2 and 3, `:t2 4d` bar 4 of track 2 alone, `:%s/c4/d4/g` makes every C4 of the song a D4.

The three tracks here have four one-bar clips each. Watch the right end of the command line while you type: it says what the line would do, and the views light it up, before anything changes.

## The idea

A range is of time (`5,8` bars, `5.3` a beat, `%` all, `.` the cursor's bar, `$` the last, `'a,'b` marks, `'<,'>` the selection, `.+4` offsets), of tracks (`t2,t4`, `t*`, `t/Drums/`), or both (`:t2 5,8d`). Commands: `d` `y` `co` `m` `>` `<` `j`, `mute` `solo` `volume` `pan`, `transpose` `quantize`, `normal`, `s` and `g`. A pattern names notes or clips by their fields: `c4`, `vel>100`, `len<1/8`, `name:Verse`. Each line is one undo step.

## If you know Vim

Ranges, `:d` `:y` `:co` `:m` `:>` `:j` `:normal`, `:s` with `g`, `c` and `n`, `:&`, `:g` and `:v` are Vim's, with a bar where Vim has a line; `inccommand` is Neovim's. Without `g` only the first match in each bar changes, as in Vim only the first on each line. Vim's `:t` is not here: `t` starts tracks.

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. Type `:2,3d` (bars 2 to 3, delete). Before Enter, see the right end of the line say `bars 2–3` and the ruler shade them; then press `<CR>`.
   - ✓ Bars 2 and 3 are empty on every track, and what was there is in the register.
2. The whole line is one change: press `u`.
   - ✓ Back, in one step.
3. Tracks go first: `:t2 4d` empties bar 4 of track 2, Bass, alone. Type it and press `<CR>`.
   - ✓ Only Bass lost its last bar.
4. Press `u` again.
   - ✓ Back.
5. `t*` is every track. Turn them all down 3 dB: `:t* volume -3`, then `<CR>`.
   - ✓ Every fader went down 3 dB; `=-6` would have set them all to -6 dB.
6. Now `:s`. Type `:%s/c4/d4/g`: the line counts the C4s of the song, and the clips that hold them light up. Press `<CR>`.
   - *Hint:* `<Esc>` leaves the line without changing anything; then `:` and type it again.
   - ✓ Every C4 is a D4. `%` was the whole song, `g` every match in each bar.
7. `:g` runs a command on every match. Mute the Bass clips by name: `:g/name:b/mute`, then `<CR>`.
   - ✓ All four Bass clips are muted. `:g/vel>100/` with no command puts the matches in the quickfix list, for `]q`.

## What you did

`:2,3d`, `:t2 4d`, `:t* volume -3`, `:%s/c4/d4/g` and `:g/name:b/mute`: a range, then a command, each one undo step.

Previous: [The bundled extensions](16-extensions.md) · [All lessons](README.md)
