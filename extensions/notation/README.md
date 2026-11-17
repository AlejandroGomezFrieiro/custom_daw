# notation

Staff notation for a clip, to read and to write: in the terminal, drawn in
text cells, and engraved with a music font (Leland) wherever there are
pixels: in a window of the graphical frontend, and on a terminal that shows
images.

A clip written in notation is a **score clip**: it keeps a written score,
and its notes are what the score plays. Writing changes the score (a tie
stays a tie, a dotted rhythm stays dotted, a voice stays a voice, a spelling
stays a spelling), and the notes follow, in the same undo step. A plain
MIDI clip is shown as a musician would write down what was played, to read;
the first edit in notation (or `:score.from-midi`) writes it as a score,
keeping how it was played.

```lua
daw.ext.load("extensions/notation")   -- or put it in ~/.config/daw/extensions
```

## Opening it

| | |
| --- | --- |
| `:notation` | the clip under the arrange cursor, or the piano roll's clip |
| `,n` | the same, in the arrange view and in the piano roll |
| Open as notation | in the window's right-click menu of a MIDI clip |

The view opens at the bottom of the terminal, taking two thirds of the
height, and in a window of its own in the graphical frontend. `,n` goes back
to the arrange view, as it came; `:q`, `ZZ` and `Ctrl-w c` close the view, and
so does closing the window. `Esc` in normal mode stays in the view, as it
does in Vim: it drops a count, an operator or a selection, and pressed again
soon it says how to leave.

## Score clips

A score clip keeps its score in `clip.meta.score` (`notation.doc`): staves
with their clefs, measures with their time signatures, and in each measure
the voices of each staff, each a list of chords and rests that fills the
bar. Values are fractions of a whole note (`{ 1, 4 }` a quarter) with their
dots and tuplets, so nothing drifts however long the piece; pitches are
spelled (`step` 0 to 6 from C, `alter`, `octave`); every measure, chord,
note and mark has an id that stays. Dynamics, hairpins, slurs and text are
marks at places in measures; repeat signs are on the measures.

| | |
| --- | --- |
| `:score.from-midi` | write the clip under the cursor as a score: its transcription, keeping what was decided on its notes before (spellings, voices, hands, articulations, dynamics, slurs) and how it was played, as each note's feel |
| `:score.detach` | plain MIDI again: the notes the score plays, without the score |
| `:score.reset-performance`, `:notation.quantize` | forget every note's feel: the notes play exactly as written |
| `:notation.retranscribe`, `g=` | write the score (or the bars of a selection) again from what its notes play |

**What the notes play.** The score is rendered one way, measure by
measure, and only the measures an edit changed are rendered again: tied
notes are one note; an acciaccatura sounds a 32nd before its note, an
appoggiatura on the beat, taking time from it; a note sounds 90% of its
value, staccato half, staccatissimo a quarter, tenuto and notes under a
slur all of it; the dynamic in force gives the velocity (`ppp` 25 to `fff`
124, `mf` 80 where none is written), a hairpin ramps it to the next
dynamic, an accent adds 20 and a marcato 30. Each note carries
`meta.score = { e, n }`, the ids of its chord and its written note.

**The piano roll on a score clip.** The roll (and anything else that
writes notes, through `daw.Clip`) edits the same clip, and the score's
owner (`notation.owner`, a clip owner of `daw.clips`) says what each
change means:

| In the roll | | |
| --- | --- | --- |
| a note's pitch | written | the written note gets that pitch, spelled by the key |
| a note added | written | it joins a chord of the same start and length, else fills silence in voice 1, else in voice 2, 3 or 4, on the staff its pitch belongs to |
| a note deleted | written | its chord loses it, or becomes a rest |
| moved or made longer or shorter by whole steps of the grid | written | written again where it starts, as long as it is, the values as the metre has them |
| nudged off the grid, a velocity | feel | kept with the note as its feel, relative to what is written |
| quantized | | the feel goes |

Either way the note plays where the roll put it: the feel takes up what
the writing does not say, and goes with the note when the writing changes
(a pitch changed in notation keeps the note's nudge; a dynamic keeps the
roll's accents over the new loudness). Undo goes back through both, one
step per edit, score and notes together.

## What is written of a MIDI clip

Between a MIDI clip's notes and the page is a transcription (`notation.score`),
which is also how a MIDI clip is written as a score:
the notes are transcribed into written chords, each knowing which played
notes it stands for. Everything the score does not show (each note's offset
from its written place, its real length, its velocity) stays in the notes as
played.

- **Chords and strums**: onsets within 35 ms are one chord in any order; a
  strum or a roll (each string up to 70 ms after the last, low to high or high
  to low, the earlier ones still ringing, at most 450 ms) is one chord too,
  written where it starts. A roll slower than 160 ms gets an arpeggio sign
  with its direction.
- **Onsets** go on the simplest grid that explains each beat: the beat, its
  halves, quarters or eighths, or triplets (in 6/8 the beat's eighths, or a
  duplet), chosen per beat by how well it fits against how complex it is. A
  lone triplet among plainly duple beats needs more to convince.
- **Drift**: the player's distance from the grid is followed, first beat by
  beat and then by a line fitted through the onsets around each beat, so a
  part played ahead of the beat or slowing down (a ritardando against the
  grid) is still written on the beat.
- **Swing**: eighths played long-short are recognised and written straight.
- **Lengths**: a chord lasts to the next onset in its voice when the silence
  before it is short (articulation, not a rest); a note much shorter than
  that, within a beat, is a staccato; a note held into the next is legato,
  not a tie; otherwise the value nearest what was played, by proportion, so
  a long note let go early is still a long note.
- **Grace notes**: a note shorter than 100 ms (and a sixth of a beat) just
  before a longer note of another pitch, let go by the time it sounds.
- **Voices**: a note held well past the next onset under (or over) notes
  that move is a second voice, stems down (or up), with its own rests.
- **Hands**: on a grand staff each chord's notes are split between the hands
  by where each hand has been, so a melody that goes below middle C stays in
  the right hand.
- **Tuplets** are bracketed; quarter-note triplets over two beats are one
  bracket. **Rests** are merged as the metre divides the bar.
- Notes drawn exactly on the grid (in the piano roll) are written as they
  are: the interpretation is for what was played.

Each of these has a setting, kept with the clip in `clip.meta.notation.settings`:

| `:notation.set` | default | |
| --- | --- | --- |
| `chord` | 35 | ms: onsets this close are one chord |
| `strum`, `strum_span` | 70, 450 | ms between strings of a strum (0 off); its longest |
| `arpeggio` | 160 | ms: a strum this long gets an arpeggio sign (0 never) |
| `triplets` | on | beats may be written in triplets (duplets in 6/8) |
| `finest` | 0.25 | the shortest duple subdivision, in beats |
| `simplicity` | 1 | how strongly simple grids are preferred (0 to 2) |
| `gap` | 0.3 | a silence shorter than this share of the time to the next onset is articulation |
| `staccato` | on | short detached notes written with a staccato mark |
| `grace` | 100 | ms: the longest grace note (0 off) |
| `swing` | auto | `auto`, `off`, or the long eighth's share of the beat (0.66) |
| `voices` | on | held notes as a second voice |
| `split` | auto | or a pitch: the hands split there |
| `follow` | on | follow the player's drift from the grid |
| `mode` | score | `raw`: every note as played, rounded to `daw.opt.notation_grid` |

`:notation.set` alone lists them, `:notation.set swing off` sets one,
`:notation.set swing default` forgets it, `:notation.reset` forgets them all.
`:notation.raw` (`gR`) switches the raw view on and off: every note as it is,
rounded to the grid, one chord per start, middle C splitting the hands, for
checking.

**What you decide** is kept, and survives changes made elsewhere: on each
note in `meta.notation` (its voice, its hand, a grace note or not, a strum's
arpeggio sign, notes that are one chord, a broken beam, its spelling, its
articulations), and with the clip (triplets on a beat, dynamics, hairpins,
text, repeats, slurs). A note's own marks go where the note goes.

The rest of the page:

- **Measures** follow the song's bars. Where the kernel keeps time signatures
  along the song (`daw.time.signature_at`), each bar takes its own, and the
  new signature is written where it changes.
- **Clef**: treble when the notes stay above A3, bass when they stay below
  E4, a grand staff when they need both. `:notation.clef bass` fixes it for
  the track (`treble`, `treble8` for guitar, `bass`, `grand`, `auto`), kept
  in `track.meta.notation`.
- **Key**: the project's key, as the `musicops` extension keeps it in
  `project.meta.musicops`; modes and minor keys take the signature of their
  relative major. `:notation.key Eb major` sets it, `:notation.key off`
  clears it.
- **Spelling**: notes of the key take its letters; the others lean the way
  the key does. Accidentals are remembered to the end of the bar, a tied
  note keeps its accidental across the barline without a sign, and a note
  altered in one bar is reminded back in the next.
- **Stems** go by the note furthest from the middle line, or by the voice;
  **beams** join eighths and shorter within a beat (four eighths in half a
  4/4 bar, three in 6/8), within a tuplet, with part beams.
- **Tablature**: `:notation.tab guitar` (or `bass`, `dropd`, `dadgad`,
  `7string`, `bass5`, or the strings' notes from the lowest, `E2 A2 D3 G3 B3
  E4`) puts a tab staff under the track's notation, kept in
  `track.meta.notation.tab`, and writes a guitar in its treble clef an octave
  up. Each chord's notes go on different strings within a hand's reach,
  moving the hand as little as possible; `meta.notation.string` on a note
  fixes its string.
- **Lyrics**: a note's `meta.lyric` (the `utau` extension's vocal clips keep
  theirs there) is written under it.
- **Several tracks**: `:notation.tracks` (`gT`) shows every track with MIDI
  over the open clip's stretch as one system of staves, each named, to read;
  a click on a note sounds it. The same again goes back to the clip alone, to
  edit.

## Keys

In the notation view. Counts, registers, `.`, macros and marks work as
everywhere; the view's rows are pitches, so the piano roll's operators and
visual modes work on it, on the notes the score plays, which the score's
owner makes changes of the score as it does the roll's. On a plain MIDI
clip every key that edits writes it as a score first (one undo step with
the edit), and says so.

| Keys | |
| --- | --- |
| `h` `l` | back, on by the chosen value |
| `j` `k`, `J` `K` | down, up a line or space; an octave |
| `w` `b` `e` | next, previous note or rest; end of the note |
| `W` `B`, `0` `^` `$`, `gg` `G` | next, previous bar; start of the clip, first note, end; the highest, lowest note's line |
| `Enter` | add a note of the chosen value at the cursor, or take away the one there |
| `x` | delete the note under the cursor |
| `Ctrl-a` `Ctrl-x` | sharpen, flatten it (a semitone, spelled with a sharp or a flat) |
| `Alt-k` `Alt-j` | move it up, down a step of the key |
| `}` `{` | move it up, down an octave |
| `+` `-` | lengthen, shorten its chord by the chosen value, ties included |
| `g.` | dot its chord, or take the dot away |
| `g2` … `g7` | choose the value: 32nd, 16th, eighth, quarter, half, whole (the numbers MuseScore uses) |
| `gd` | dotted values on or off |
| `d` `y` `c` `>` `<` `=` `gl` | operators: delete, yank, change, move later or earlier by the chosen value, play the notes exactly as written (forget their feel), loop |
| `in` `ib` `ic` | the note, the bar, the clip |
| `v` `V` `Ctrl-v`, then `x` `Ctrl-a` `Ctrl-x` `Alt-k` `Alt-j` `}` `{` | on a selection, which takes in the note under the cursor, as Vim's takes the character |
| `:` on a selection | a command for it: the line starts `:'<,'>` (`:'<,'>notation.cresc`) |
| `p` `P` | paste after the note, at the cursor |
| `i`, `a` | enter notes at the cursor, after the note |
| `gh`, `gp` | hear the cursor's pitch; playhead to the cursor |
| `zi` `zo` | spread the notes out, draw them closer; on the engraved page, a larger, smaller staff |
| `zg` | the engraved page as one long system scrolled sideways (the galley), or wrapped |
| `zp` | the engraved systems on pages of paper, under the title and composer (the page view), or without pages |
| `gS` | start a system at the cursor's bar; again, let the bar go where it fits |
| `gJ` | keep the cursor's bar on the system before; again, let it go where it fits |
| `:notation.bars-per-system 4` | that many bars on every system; without a number, as they fit |
| `,n` | back to the arrange view |
| `:q` `ZZ` `Ctrl-w c` | close the view |
| `Esc` | stay: drop a count, an operator or a selection |

**Entering notes** (`i`), the way notation programs do it: a letter `c` to
`b` enters that note at the cursor with the chosen value, in the octave
nearest the note before (within a fourth), as the key alters it, and steps
on; a capital stays, to build a chord (`CEg`). Notes go into a voice of
the staff the note is written on: the voice of the note the cursor is on at
`i` (else the one chosen, 1 unless `v` or `:notation.voice` says), over what
that voice had there: a chord it cuts into keeps what is before, the rest
of it is a rest; a note longer than what is left of the bar is tied over
the barline. No other voice and no other staff is touched.

| Keys | |
| --- | --- |
| `a` … `g`, `A` … `G` | enter a note and step on; enter it and stay |
| `2` … `7` | choose the value |
| `.` | dotted values on or off |
| `+` `#`, `-` | sharpen, flatten the note just entered |
| `'` `,` | the note just entered an octave up, down |
| `Alt-2` … `Alt-8` | add a second … an octave above the note just entered, in the key, to its chord (`C` `Alt-3` `Alt-3` is a C major triad) |
| `~` | hold the note just entered on by the chosen value, tied where it crosses a beat or a barline, and step on |
| `t` | enter triplets of the chosen value (a triplet of rests is made where there is none, and filled), or plain values again |
| `v` | enter in the other voice (1 or 2); `:notation.voice 3` chooses any of four |
| `R` | enter the last chord (or note) again here, and step on |
| `r` `0` | a rest: clear the chosen value and step on |
| `Space` | step on, leaving what is there |
| `Backspace` | step back and remove what starts there |
| `Esc` | back to normal mode |

**Editing the score.** These work on the written chord under the cursor;
its notes keep their feel:

| Keys | |
| --- | --- |
| `Alt-l` `Alt-h` | move the chord later, earlier by the chosen value, with its grace notes and marks; what is there in its voice gives way |
| `+` `-` `g.` | its written length longer, shorter, dotted, ties included |
| `X` | delete the chord: a rest (`x` deletes the one note) |
| `=` | an operator: the notes exactly as written (their feel forgotten), e.g. `=in`, `=ib`, or on a selection |
| `g=` | an operator: the bars written again from what the notes play |
| `gv` | the note (or the chord) into the other voice, and enter in that voice |
| `gH` | the chord onto the other staff of a grand staff, in a voice free there |
| `gs` | arpeggio sign up, down, none; on a selection, the chords one chord (a strum) |
| `gG` | the chord a grace note of the next (its time goes to the chord before), or the chord's grace notes notes again |
| `gb` | break the beam before the chord, or join it |
| `gt` | the beat in triplets (a duplet in 6/8), or not: the bar written again so |
| `ge` | respell the note: G sharp, A flat |
| `g'` `g>` `g_` `g^` | staccato, accent, tenuto, marcato on the chord (or a selection), and played so |
| `(` | on a selection: a slur, the notes played legato |
| `+` `-` | on a selection: each chord longer, shorter by the chosen value |
| `gR` `gT` | the raw view; several tracks |

`:notation.quantize` makes the whole clip play what is written,
`:notation.retranscribe` writes it again from what it plays.
`:notation.transpose 2` moves the chord under the cursor up two semitones,
spelled by the key (`-1 steps` a step of the key down).

**Ranges.** Every `notation.*` command that works on notes or places marks
takes a range in front, as in Vim: `:'<,'>` the last selection (what `:`
types from visual mode), `:5,8` bars 5 to 8, `:5` bar 5. So
`:5,8notation.transpose 2`, `:'<,'>notation.slur`, `:9notation.dyn p`,
`:1,4notation.repeat` (both signs around bars 1 to 4), `:5,8notation.quantize`.
The commands that take one are `art`, `dyn`, `cresc`, `dim`, `slur`, `text`,
`repeat`, `quantize`, `retranscribe` and `transpose`.

**Marks that play.** `:notation.dyn mf` puts a dynamic at the cursor (`ppp` to
`fff`, `off`): the notes from there to the next dynamic play at its
loudness, each note's feel (how the player made it differ) on top. `:notation.cresc` and
`:notation.dim` put a hairpin over the selection or range (or to the end of the bar)
that ramps the loudness to the next dynamic. `:notation.slur` slurs the
selection. `:notation.text Allegro` writes text above the staff, and
`:notation.repeat start` (`end`, `off`) a repeat sign at the cursor's bar;
these two are written only (the song's timeline plays as it is). Staccato
plays a note half its written length, tenuto its full length, an accent 20
louder, a marcato 30.

## The engraved page

In a window, and on a terminal's pixel surface where the terminal shows
images, the staff is engraved with the SMuFL font Leland: the font's own
note heads, clefs, accidentals, flags, rests and marks, its engraving
defaults for the thickness of staff lines, stems, beams, ties and slurs,
and stems attached where the font says. Everything that is a line is drawn
on whole pixels; the staff space is a whole number of pixels (`zi` `zo` step
through 6 to 24), a third of a cell's height on a terminal (9 px in a 27 px
cell), so a staff of one hand fits in five or six rows, where the cell view
needs eleven or more. On a terminal each measure is a whole number of
columns wide and each system a whole number of rows high, and the drawing
says where the barlines are, so the terminal is sent the page as images
cut at barlines and an edit re-sends only the measure it changed.

Behind Bars (Gould) is the reference for the details. Beams slope by at
most a staff space and sit on, straddle or hang from a staff line, and
stand the font's beam spacing apart on whole pixels. Ties are flat and
close to the heads, on the side away from the stem (a chord's upper notes
tie up, its lower ones down), and rise a little more the longer they are,
never more than 0.6 of a space; slurs are rounder. Ties and slurs are
thicker in the middle. A chord's accidentals stand in columns, and
spacing gives accidentals (in parentheses too), grace notes and arpeggios
room only where the notes' own spacing leaves too little: half a space
clear of the note before. A tuplet under a beam of its own has only its
number, past the beam; any other has a bracket from its first head to its
last, clear of the stems and what stands on them. With two voices on a
staff, a rest moves out of the way of the other voice's notes. A lyric
gets the room it needs: its note is spaced so that syllables do not touch.

**What stands outside the staff is placed, not put.** Each staff of a
system has a skyline, the outline of its notes, stems, beams, flags,
accidentals, ledger lines, articulations, ties and tuplets seen from above
and from below (`notation.skyline`). Against it are placed, nearest first,
each clear of all before it and then part of the outline: slurs, the bar
number, lyrics, dynamics and hairpins, text, and the kinds other features
add (chord symbols, rehearsal marks, tempo text). The dynamics and hairpins
of a system stand on one line along it (Sibelius' magnetic layout), under
the staff, or over it on a staff with lyrics (Gould); a hairpin runs over
barlines and systems and stops short of a dynamic at either end, and at
the next dynamic inside it. The space between the staves of a system, and
the height of each system, is what their skylines need, so nothing
overlaps: a grand staff with dynamics between its hands opens up just
there.

**Slurs bend round the notes.** A slur goes under the heads when every
stem under it points up, else over them (in two voices, the upper voice's
over, the lower's under); its ends sit half a space off the end notes, at
the heads or past the stems. It is as round as its length asks, rounder
where the notes under it need, and where a slur cannot be rounder without
looking wrong its ends rise, each for what is near it. Of two slurs one
inside the other, the inner is placed first. A slur over a system break is
drawn in two parts, the second from after the clef and key.

**Systems break balanced.** Measures are broken into systems over the whole
clip at once, not filled one system at a time (`notation.breaks`, a total
fit in the manner of Knuth and Plass): a system's cost grows with the
square of how far its bars are stretched, so the stretch is shared out
evenly, none is stretched past twice its bars' own width while another way
exists, and a bar is left alone on the last system only when everything
else is worse. Every system but the last is spread to the width, and the
last too when it is three quarters full. `gS` starts a system at the
cursor's bar, `gJ` keeps it on the system before, and
`:notation.bars-per-system 4` fixes the count; they are kept in the score
(`score.layout`, each break with an id and its measure's id), undone like
any edit, and the terminal's cell view breaks the same way, in whole
cells. A tie into a new system starts after the clef and key, as long as a
tie.

The ink is the terminal's foreground colour (the
window's text colour), staff lines are lighter, and the selection, the
cursor, suggestions and diagnostics take the theme's accents. Light ink on
a dark page is drawn a little thinner, as it looks heavier.

The page is systems wrapped down the screen, or with `zg` one long system
scrolled sideways (the galley), which keeps the start of the system at the
left and, while playing, the playhead a third of the way across. With `zp`
(the page view) the systems are laid on sheets of paper: A4 (or US letter,
option `notation_sheet`) at 1.75 mm to the staff space (a staff 7 mm
high), with margins, the project's title (`meta.title`, else its name) and
composer (`meta.composer`) at the head of the first page, page numbers on
the others, a system that does not fit starting the next page, and the
systems of a full page spread over it. The paper is white with black ink
(option `notation_paper`: `"theme"` keeps the theme's colours), and the
staff space is the largest whose page fits the width, unless zoomed. Over the
page are drawn, each apart from it: the selection (a faint band, its notes
in the accent), suggestions from `daw.complete` (the notes laid out as they
would be written, faint), diagnostics from `daw.diagnostic` (a wavy line
under the staff, the notes tinted, a mark in the margin, the message on the
info line when the cursor is on it), the cursor (a hairline at its beat and
the note `Enter` or a click would put there, half transparent; on a note,
that note in the accent), and the playhead.

In the window the toolbar chooses the value (whole to 32nd), the dot, rests,
and the accidental notes are entered with (flat, natural, sharp; none takes
the key's); then marks on the chord under the cursor (staccato, accent,
tenuto, slur, triplet, second voice) and at the cursor (p, mf, f, crescendo,
diminuendo); and zooms. The line at the bottom says what is under the
cursor and, at the right, the key, the time signature and the track. On a
terminal the toolbar and that line are left out: the terminal's own bars
say it.

| Pointer | |
| --- | --- |
| click | the cursor to that note (and hear it), or to that line or space and time: on the chosen value within the beat (an eighth chosen, on an eighth; in triplets, on a third of the beat), so notes typed next fall on the beat |
| Alt-click | the same, on the sixteenths' grid (`notation_grid`) |
| Shift-click | a selection from the cursor to there |
| drag on the paper | select a box (a block) |
| drag a note | move it in time (on the grid) and up or down the staff; it keeps its distance from the key (a sharp stays a sharp) |
| double click | enter notes from there (insert mode) |
| click in insert mode | put a note of the chosen value there, at that line or space and time (snapped as a click is; Alt on the grid), and hear it; with Rest on, clear that stretch. The note to enter follows the pointer |
| right click | a menu of what can be done there: delete, sharpen, flatten, respell, marks, voice, triplets; on the paper, a note or a rest of the chosen value, paste; the galley |
| wheel | scroll the systems (the galley sideways); with Ctrl, zoom |

Every key of the terminal view works in the window too, and the pointer
works the same in the terminal's cell view, a cell at a time: a click on a
head chooses that note, on a line or space that place and time; the drag,
Shift, the double click, the click in insert mode and the right click's menu
are as above, and the wheel scrolls by measures. There the cursor off a note
is drawn as the note that would be entered (a shadow note), and in insert
mode it follows the pointer; the status line says the note and time under
the pointer.

**Coming from MuseScore.** The note input is MuseScore's in spirit and the
paw's in its keys. Insert mode (`i`, `a`, or a double click) is MuseScore's
note input: a letter enters that note in the nearest octave and steps on, a
capital adds it to the chord, `Alt-2` … `Alt-8` add an interval above, `t`
enters triplets, `~` ties, `R` repeats the chord, and the note to be entered
shows where it would go. Durations are chosen by number as in MuseScore
(`5` a quarter, `4` an eighth), but there is no 1 or 9: paw's values
go from a 32nd to a whole note. Pitches are moved with the keys the piano
roll uses (`Ctrl-a` `Ctrl-x` a semitone, `Alt-k` `Alt-j` a step of the key,
`}` `{` an octave), not the arrows, which move the cursor as everywhere
else; and in normal mode the letters are motions and operators, so notes
are only entered by letter in insert mode. A click chooses rather than
enters, as in MuseScore outside note input.

## Export

`:notation.export tune.musicxml` writes the clip under the cursor (or the
one open in the view) as MusicXML, which MuseScore, Finale, Sibelius and
Dorico open; a path ending in `.ly` writes LilyPond source instead.
`:notation.export lead.ly track` writes every MIDI clip of the track on one
timeline. Both are made from the score layer's result, as the views draw
it: values, ties, tuplets, both voices of a staff, grace notes, arpeggio
signs, articulations, key, clefs (the guitar's too), time signatures where
they change, and the grand staff. MusicXML also carries the accidentals,
stems, beams, dynamics, hairpins, text, slurs, lyrics and each note's
string and fret when there is tablature. Without a path the file is named
after the clip and written to the working directory.

`:notation.export pdf` (or a path ending in `.pdf`) writes the engraved
pages as the page view lays them out, on white paper, as a PDF of as many
pages as there are; `svg` writes each page as an SVG file (numbered after
the first), `png` the first page as an image. They are drawn from the same
drawing operations as the screen (`daw.api.canvas_export`, in
crates/daw-raster), with the music font's glyphs and the text as outlines,
so the files need no fonts.

## From Lua

```lua
local model = require("notation.model")
local layout = model.layout(clip:notes(), { length = 8, num = 6, den = 8, fifths = -1, tempo = 100 })
print(model.text(layout))           -- "q. F4 e G4 ... | R"
model.layout(notes, { length = 4, settings = { mode = "raw" } })   -- note for note
require("notation.score").transcribe(notes, ctx)   -- the score events alone
model.spell(70, -1)                 -- { letter = 6, alter = -1, octave = 4, step = 41 }: B flat
require("notation.export").lilypond(layout, { title = "tune" })   -- or .musicxml(layout, { title, part })

-- Scores.
local view, D = require("notation"), require("notation.doc")
local sc = view.score_of(clip:get())            -- the clip's score, to read (nil for plain MIDI)
local s = sc.staves[1].id
D.put_chord(sc, 2, s, 1, D.Q, 2 * D.Q, { { step = 4, alter = 0, octave = 4 } })   -- a half G4 on beat two of bar two
require("notation.render").render(sc)           -- the notes it plays
require("notation.layout").layout(sc, { length = 8 })   -- its layout, as model.layout's
```

A score is changed by the view's `write(fn)`, which gives `fn` the clip's
score to change and then keeps it and renders its notes, as one undo step:
`view:write(function(sc) ... end)`. In the clip it is kept with each
measure as JSON text and the feel as a line of text (`notation.doc`'s
`encode` and `decode`), so that reading the clip stays quick.

`notation.engrave` turns a layout into drawing operations for `daw.canvas`
(`engrave.style`, `engrave.systems`, and each measure's and system's ink);
`notation.smufl.font()` is the font's metadata as the engraver reads it,
from the fonts the kernel embeds (`daw.api.smufl`; Leland, Bravura and
Petaluma, under the SIL Open Font License, in crates/daw-raster/fonts).
`tools/paintbench.lua`
times the paint: run it with `daw --clean --no-plugins --no-listen --audio
null -l extensions/notation/tools/paintbench.lua 64`.

A feature with marks of its own (chord symbols, rehearsal marks, tempo
text, lyrics drawn its own way) makes their kind known to the placer, and
puts them on the layout's measures (`m.marks`, from a decorator) or finds
them itself with `collect`:

```lua
local skyline = require("notation.skyline")
skyline.kind("chord", {
  order = skyline.ORDER.chord,   -- nearer the staff first: number 5, slur 10, lyric 20,
                                 -- dynamics 30, text 40, chord 50, rehearsal 60, tempo 70
  side = "above",                -- or "below", or function(item) return ... end
  pad = 0.6,                     -- staff spaces clear of what is there already
  row = "chords",                -- optional: a row's marks on a system share one line
  staff = 1,                     -- optional: default the mark's `staff`, else 1; "last" the lowest
  ink = function(ink, st, item)  -- draw at item.x, its line at y 0; the placer moves it clear
    ink:text(item.x, 0, item.value, st.ink, math.floor(1.4 * st.sp), true)
  end,
  collect = function(m, add) end, -- optional: add({ at = beat, staff = k, value = ... }) for marks not on m.marks
})
```

A mark on `m.marks` is `{ at, kind, value, to?, staff? }` in beats of the
clip; `item` has its fields and `x`, `staff` and `system`. `ink` takes the
engraver's ink calls (`glyph(st, x, y, name, colour, scale)`, `text(x, y,
text, colour, size, bold, align, width)`, `rect`, `path`); what it draws is
the mark's shape. `notation.breaks.lines(widths, prefix, width, { breaks,
joins, per })` is the line breaker on its own.

`layout.score.events` are the written chords (`start`, `length`, `staff`,
`voice`, `notes` with each played note's `index` and `offset`, `grace`,
`arpeggio`, `staccato`); `layout.measures[i].staves[s]` lists what is drawn
on each staff: notes and rests with their start, value (`base`, `dots`),
`tuplet`, `voice`, ties, accidentals, stems and beams.

## Not done

Importing MusicXML; editing several tracks at once (they are shown to read);
tablature in the several-tracks view and as its own staff in MusicXML (the
string and fret are on each note); first and second endings, D.C. and D.S.;
clefs other than treble, the guitar's treble and bass; key changes within a
clip; trills and other ornaments; a mark's own room in the terminal when the
panel is low (dynamics then fall below what shows). On the engraved page:
page breaks of one's own (pages fill as systems come), the style as a
buffer to edit (staff size, spacing, slur height), a choice of Bravura or
Petaluma (the kernel has them; nothing chooses them yet); staccato and
tenuto inside a slur (a slur goes over every articulation), and slurs that
keep clear of the staff lines; systems that interlock (each system's band
holds all of its ink); the cell view places its marks on fixed rows, not
against skylines; text in a PDF is outlines, so it cannot be searched. For score
clips: tempo marks that play, repeats unfolded, trills and fermatas played,
swing, key and clef changes per measure, the piano roll showing which notes
are written and their feel (see docs/missing.md). A plain MIDI clip is
still transcribed whole after each change of its notes; a score clip is laid
out, rendered and engraved again only in the measures an edit changed.
