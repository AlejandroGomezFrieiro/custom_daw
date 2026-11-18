<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 17: Ranges, :s and :g: edit by line

*This lesson takes about ten minutes. To do it in paw, type `:ext.load tutor`, then `:tutor 17`.*

In this lesson, we change bars, tracks and notes of a song from the command line.

Operators and visual mode do their action at the cursor. The command line can do an action at many places at the same time. A range before a command gives the places, as in the Ex of Vim, with bars for lines. `:2,3d` makes bars 2 and 3 empty. `:t2 4d` makes only bar 4 of track 2 empty. `:%s/c4/d4/g` changes each C4 of the song to a D4.

Each of the three tracks here has four clips of one bar. While you type, look at the right end of the command line. It shows what the line will do, and the views highlight the items, before paw changes them.

## The idea

A range can be of time. `5,8` is bars and `5.3` is a beat. `%` is all, `.` is the bar of the cursor and `$` is the last bar. `'a,'b` is marks, `'<,'>` is the selection and `.+4` is an offset. It can be of tracks (`t2,t4`, `t*`, `t/Drums/`), or of the two (`:t2 5,8d`).

The commands are `d` `y` `co` `m` `>` `<` `j`, `mute` `solo` `volume` `pan`, `transpose` `quantize`, `normal`, `s` and `g`. A pattern selects notes or clips by their fields: `c4`, `vel>100`, `len<1/8`, `name:Verse`. Each line is one undo step.

## If you know Vim

Ranges, `:d` `:y` `:co` `:m` `:>` `:j` and `:normal` are from Vim. `:s` with `g`, `c` and `n`, `:&`, `:g` and `:v` are also from Vim. A bar is in place of a line. `inccommand` is from Neovim.

Without `g`, only the first match in each bar changes. In Vim, only the first match on each line changes. paw does not have the `:t` of Vim, because `t` starts a range of tracks.

## Steps

The tutor opens a practice project for this lesson. It checks each step when you do it.

1. Type `:2,3d` (bars 2 to 3, delete). Before you press Enter, look at the right end of the line: it shows `bars 2–3`, and the ruler shades them. Then press `<CR>`.
   - ✓ Bars 2 and 3 are empty on all tracks. The register contains the deleted clips.
2. The whole line is one change. Press `u`.
   - ✓ The bars are back, in one step.
3. The tracks come first: `:t2 4d` makes only bar 4 of track 2, Bass, empty. Type it and press `<CR>`.
   - ✓ Only Bass lost its last bar.
4. Press `u` again.
   - ✓ The bar is back.
5. `t*` is all the tracks. Make them all 3 dB quieter: type `:t* volume -3`, then press `<CR>`.
   - ✓ Each fader went down by 3 dB. `=-6` sets them all to -6 dB.
6. Now we use `:s`. Type `:%s/c4/d4/g`. The line counts the C4 notes of the song, and the clips that contain them are highlighted. Press `<CR>`.
   - *Hint:* `<Esc>` leaves the line and changes nothing. Then type `:` and the command again.
   - ✓ Each C4 is a D4 now. `%` was the whole song, and `g` was each match in each bar.
7. `:g` runs a command on each match. Mute the Bass clips by their name: type `:g/name:b/mute`, then press `<CR>`.
   - ✓ The four Bass clips are muted. `:g/vel>100/` with no command puts the matches in the quickfix list, for `]q`.

## What we did

We used `:2,3d`, `:t2 4d`, `:t* volume -3`, `:%s/c4/d4/g` and `:g/name:b/mute`: a range, then a command, one undo step for each.

Previous: [The bundled extensions](16-extensions.md) · [All lessons](README.md)
