<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 4: The piano roll and entering notes

*About ten minutes. In paw, with the tutor loaded: `:tutor 4`.*

The piano roll shows the notes of one clip: a row per pitch, with the names on the left, and time running to the right in steps of a sixteenth note. In normal mode you move about and change single notes; in insert mode you draw notes with the cursor, as long as you like, and they are written when you leave it.

The clip `tune` has three notes in its second bar. You will add to it.

## The idea

Moving: `h` `l` a step, `j` `k` a semitone, `<C-d>` `<C-u>` an octave, `w` `b` notes, `0` `$` the start and end of the clip. Changing the note under the cursor: `<CR>` adds or removes, `+` `-` (and `<C-a>` `<C-x>`) its pitch, `<A-h>` `<A-l>` its length, `H` `L` move it, `[` `]` velocity, `gh` hear the pitch. Insert mode (`i`, or `a` after the note) draws a note from the cursor: `l` `h` longer and shorter, `j` `k` `<C-d>` `<C-u>` its pitch, `<CR>` keeps it and draws the next where it ends, `<Space>` after a rest, `o` from the same start for a chord, `<BS>` takes back, `<Esc>` writes and leaves. `I` makes the keyboard a piano instead: `a w s e d f t g y h u j k` are C up to the next C. `<Esc>` in normal mode stays in the roll; `<C-w>p` goes back to the arrange view.

## If you know Vim

`<C-a>` and `<C-x>` add and subtract, as on numbers in Vim; here they move a note's pitch, as `+` `-` do: the main value of a note is its pitch. Insert mode does not insert text: it draws a note, and all of it is one undo step, which `.` repeats at the cursor, as Vim repeats an insert.

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. The cursor is on the clip `tune`. Press `<CR>` (Enter) to open it in the piano roll.
   - ✓ The piano roll. The cursor is on E4 at the start of the clip.
2. `j` and `k` move a semitone down and up (`<C-d>` `<C-u>` an octave, half a page as in Vim), and you hear each pitch. Press `k` three times to reach G4.
   - *Hint:* Watch the title row of the piano roll: it shows the pitch under the cursor.
   - ✓ G4: the name is in the title row and highlighted on the left.
3. `<CR>` adds a note at the cursor (or removes the one there). Press `<CR>`.
   - ✓ A short G4: one step, a sixteenth.
4. `<A-l>` makes the note under the cursor a step longer, `<A-h>` shorter, as they do to a clip in the arrange view. Press `<A-l>` three times.
   - ✓ Now it lasts a beat.
5. `<C-a>` (or `+`) moves the note up a semitone and `<C-x>` (or `-`) down. Press `<C-a>` twice.
   - *Hint:* `<C-a>` is Ctrl and a. The cursor must be on the note.
   - ✓ A4 now, and the cursor went with it.
6. Go a beat on with `4l`, and press `i` to draw a note there.
   - ✓ INSERT at beat 2: a note starts here, nothing long yet. The title row shows its pitch and length.
7. In insert mode `l` makes the note a step longer and `h` shorter; `j` `k` move its pitch. Press `2j` (down to G) and `4l` (a beat long).
   - *Hint:* Counts work as in normal mode: `4l` is `l` four times. `h` takes a step back off the note.
   - ✓ A G a beat long, in green: drawn, not written yet. The cursor sits at its end.
8. `<CR>` keeps the note and starts the next where it ends. Press `<CR>`, `2j` (F), `4l`, `<CR>`, `j` (E) and `4l`.
   - *Hint:* Each new note starts with no length: `4l` draws it. `<BS>` takes the last one kept back.
   - ✓ G, F, and an E being drawn.
9. `<Esc>` writes what was drawn and leaves insert mode. Press `<Esc>`.
   - ✓ A G F E, running into the E D C that was there. All of it is one step to undo.
10. Now a chord at the end of the clip. Press `$` (the end), `i`, `4j` (down to C) and `4l`.
   - ✓ A C a beat long, past the end of the clip: it will grow to hold it.
11. `o` keeps the note and starts another from the same place, as long, for a chord. Press `o` and `4k` (E), then `o` and `3k` (G).
   - ✓ C and E kept, G being drawn.
12. `<CR>` goes on after the chord; `<C-d>` and `<C-u>` move an octave. Press `<CR>`, `<C-d>` and `7j` (the C below), `4l`, and `<Esc>`.
   - *Hint:* `<Space>` would have left a step's rest before the next note instead.
   - ✓ A C major chord, then C3 under it.
13. `<Esc>` in normal mode stays in the piano roll, as in every view; `<C-w>p` goes back to the window before. Press `<C-w>p`, then `gs` and `<Space>` to listen; `<Space>` stops.
   - ✓ Your tune, over the drums.

## What you did

You moved by pitch and time, added and changed a note in normal mode, and drew a line and a chord in insert mode.

Previous: [Tracks, clips and notes](03-making.md) · [All lessons](README.md) · Next: [The grammar: operators, motions, text objects](05-grammar.md)
