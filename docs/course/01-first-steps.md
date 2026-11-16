<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 1: First steps: the screen, playing, quitting

*About ten minutes. In paw, with the tutor loaded: `:tutor 1`.*

paw is driven from the keyboard. Everything on the screen is a view: the arrange view in the middle has a row per track and time running to the right, the status line at the bottom says which mode you are in (`NORMAL` now), and the line below it is where commands are typed and messages appear. This panel at the bottom is the tutor: it says what to do and notices when you have done it.

Keys are written as Vim writes them: `j` is the j key, `J` is shift and j, `<C-r>` is Ctrl and r, `<CR>` is Enter, `<Esc>` is Escape, `<Space>` the space bar, `<BS>` Backspace. `gs` means g, then s.

## The idea

Nothing here needs the mouse. A key either does something at once (`<Space>` plays) or starts something that more keys finish (`:` starts a command line, `g` starts two-key commands such as `gs`). If you are ever unsure what state you are in, `<Esc>` gets you back to normal mode, and `?` lists the keys that work where you are.

## If you know Vim

`:q`, `ZZ` and `ZQ` mean what they mean in Vim, and `:w` saves. `:` takes commands by name (`:tempo 120`), not Ex commands.

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. This short song has three tracks: Drums, Bass and Keys. Press `<Space>` to play it.
   - *Hint:* `<Space>` is the space bar. Watch the ▶ in the status line and the playhead moving across the clips.
   - ✓ It plays, round and round: the loop is on (the status line says `loop`).
2. Press `<Space>` again to stop.
   - ✓ Stopped. The playhead stays where it stopped.
3. `gs` puts the playhead back at the start: press `g`, then `s`.
   - *Hint:* Type the two keys one after the other, not together.
   - ✓ The playhead is at the start: the clock in the status line says 1.1.00 (bar 1, beat 1).
4. The highlighted track header is the cursor. `j` moves it down a track and `k` up. Press `j` twice to reach Keys.
   - *Hint:* If you went past it, `k` goes back up.
   - ✓ The cursor is on Keys.
5. `?` lists every key that works in the view you are in. Press `?`, type `mute` to narrow the list down, then press `<Esc>` to close it.
   - *Hint:* Typing narrows the list; `<Esc>` closes it.
   - ✓ That list is always there when you forget a key; `<CR>` (Enter) on a line runs its key.
6. `:` opens the command line at the bottom. Type `:tempo 130` and press `<CR>` (Enter) to speed the song up.
   - *Hint:* Type the colon too. `<Esc>` abandons a command line you have started; `<BS>` on an empty one closes it.
   - ✓ 130 beats per minute: the status line shows it.
7. Press `<Space>` to hear it faster, and `<Space>` to stop.
   - ✓ Faster.
8. To quit paw, type `:q` and `<CR>` (or `ZQ`; `ZZ` saves first). Do it now: the tutor keeps your place, and `:tutor` next time brings you to lesson 2.
   - *Hint:* If you would rather not quit now, `,hn` goes on to lesson 2.
   - ✓ Quitting.

## What you did

You have played a song, moved the cursor, used the command line and seen where to find every key.

[All lessons](README.md) · Next: [Moving around, and why keys change meaning](02-moving.md)
