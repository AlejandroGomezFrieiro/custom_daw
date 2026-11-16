# notation

A MIDI clip shown as staff notation, to read and to edit: in the terminal,
drawn in text cells, and in a window of the graphical frontend, engraved
properly. What is written is an interpretation of what was played, as a
musician would write it down, not a print-out of every note: a strum is a
chord on the beat, a note played a little early is on the beat, swing is
straight eighths. The played notes are never changed by being shown; edits
made in the score change them sensibly, through the clip's ordinary notes,
so the piano roll and the notation always agree and undo works as it does
everywhere else.

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

## What is written

Between the clip's notes and the page is a score layer (`notation.score`):
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
visual modes work on it.

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
| `+` `-` | lengthen, shorten its chord by the chosen value (the played lengths scale with it) |
| `g.` | dot its chord, or take the dot away |
| `g2` … `g7` | choose the value: 32nd, 16th, eighth, quarter, half, whole (the numbers MuseScore uses) |
| `gd` | dotted values on or off |
| `d` `y` `c` `>` `<` `=` `gl` | operators: delete, yank, change, move later or earlier by the chosen value, play the notes exactly as they are written, loop |
| `in` `ib` `ic` | the note, the bar, the clip |
| `v` `V` `Ctrl-v`, then `x` `Ctrl-a` `Ctrl-x` `Alt-k` `Alt-j` `}` `{` | on a selection, which takes in the note under the cursor, as Vim's takes the character |
| `:` on a selection | a command for it: the line starts `:'<,'>` (`:'<,'>notation.cresc`) |
| `p` `P` | paste after the note, at the cursor |
| `i`, `a` | enter notes at the cursor, after the note |
| `gh`, `gp` | hear the cursor's pitch; playhead to the cursor |
| `zi` `zo` | spread the notes out, draw them closer |
| `,n` | back to the arrange view |
| `:q` `ZZ` `Ctrl-w c` | close the view |
| `Esc` | stay: drop a count, an operator or a selection |

**Entering notes** (`i`), the way notation programs do it: a letter `c` to
`b` enters that note at the cursor with the chosen value, in the octave
nearest the note before (within a fourth), as the key alters it, and steps
on; a capital stays, to build a chord (`CEg`). What started in that stretch
of the staff, in the same voice, gives way, and a note of that voice still
sounding there is cut to end where the new one starts. Other staves and
voices are left alone: a bass note entered under a melody makes a grand
staff and keeps the melody. Notes go into the voice of the note the cursor
is on at `i` (the first voice where there is none), so entering over a
second voice changes it alone.

| Keys | |
| --- | --- |
| `a` … `g`, `A` … `G` | enter a note and step on; enter it and stay |
| `2` … `7` | choose the value |
| `.` | dotted values on or off |
| `+` `#`, `-` | sharpen, flatten the note just entered |
| `'` `,` | the note just entered an octave up, down |
| `r` `0` | a rest: clear the chosen value and step on |
| `Space` | step on, leaving what is there |
| `Backspace` | step back and remove what starts there |
| `Esc` | back to normal mode |

**Editing through the score.** These work on the written chord under the
cursor and change its played notes as a musician would expect:

| Keys | |
| --- | --- |
| `Alt-l` `Alt-h` | move the chord later, earlier by the chosen value: its notes keep their strum and loudness |
| `+` `-` `g.` | its written length longer, shorter, dotted: the played lengths are scaled by as much |
| `X` | delete the chord, every note of it (`x` deletes the one note) |
| `=` | an operator: the notes exactly as written (quantize to the notation), e.g. `=in`, `=ib`, or on a selection |
| `g=` | an operator: forget what was decided by hand there, so the score follows the playing again |
| `gv` | the note into the other voice |
| `gH` | the chord onto the other hand (staff) of a grand staff |
| `gs` | arpeggio sign up, down, none, as played; on a selection, the notes one chord (a strum) |
| `gG` | the note a grace note, or the chord's grace note not one |
| `gb` | break the beam before the chord, or join it |
| `gt` | the beat in triplets (a duplet in 6/8), or as played |
| `ge` | respell the note: G sharp, A flat |
| `g'` `g>` `g_` `g^` | staccato, accent, tenuto, marcato on the chord (or a selection), and played so |
| `(` | on a selection: a slur, the notes played legato |
| `+` `-` | on a selection: each chord longer, shorter by the chosen value |
| `gR` `gT` | the raw view; several tracks |

A note added in the score goes exactly on the grid, as loud as the notes
around it. `:notation.quantize` makes the whole clip what is written,
`:notation.retranscribe` forgets every decision made by hand.
`:notation.transpose 2` moves the chord under the cursor up two semitones
(`-1 steps` a step of the key down).

**Ranges.** Every `notation.*` command that works on notes or places marks
takes a range in front, as in Vim: `:'<,'>` the last selection (what `:`
types from visual mode), `:5,8` bars 5 to 8, `:5` bar 5. So
`:5,8notation.transpose 2`, `:'<,'>notation.slur`, `:9notation.dyn p`,
`:1,4notation.repeat` (both signs around bars 1 to 4), `:5,8notation.quantize`.
The commands that take one are `art`, `dyn`, `cresc`, `dim`, `slur`, `text`,
`repeat`, `quantize`, `retranscribe` and `transpose`.

**Marks that play.** `:notation.dyn mf` puts a dynamic at the cursor (`ppp` to
`fff`, `off`): the notes from there to the next dynamic are moved to its
loudness, keeping how the player made them differ. `:notation.cresc` and
`:notation.dim` put a hairpin over the selection or range (or to the end of the bar)
that ramps the loudness to the next dynamic. `:notation.slur` slurs the
selection. `:notation.text Allegro` writes text above the staff, and
`:notation.repeat start` (`end`, `off`) a repeat sign at the cursor's bar;
these two are written only (the song's timeline plays as it is). Staccato
plays a note at most half its written length, tenuto its full length, an
accent 20 louder, a marcato 30.

## In the window

The toolbar chooses the value (whole to 32nd), the dot, rests, and the
accidental notes are entered with (flat, natural, sharp; none takes the
key's); then marks on the chord under the cursor (staccato, accent, tenuto,
slur, triplet, second voice) and at the cursor (p, mf, f, crescendo,
diminuendo); and zooms. The bar at the bottom says what is under the cursor
and, at the right, the key, the time signature and the track. On the staff:

| Pointer | |
| --- | --- |
| click | put a note of the chosen value there, at that line or space and time, and hear it; with Rest on, clear that stretch; on a note, hear it |
| drag a note | move it in time and up or down the staff; it keeps its distance from the key (a sharp stays a sharp) |
| right click a note | remove it |
| wheel | scroll down the systems; with Ctrl, zoom |

Every key of the terminal view works in the window too.

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

## From Lua

```lua
local model = require("notation.model")
local layout = model.layout(clip:notes(), { length = 8, num = 6, den = 8, fifths = -1, tempo = 100 })
print(model.text(layout))           -- "q. F4 e G4 ... | R"
model.layout(notes, { length = 4, settings = { mode = "raw" } })   -- note for note
require("notation.score").transcribe(notes, ctx)   -- the score events alone
model.spell(70, -1)                 -- { letter = 6, alter = -1, octave = 4, step = 41 }: B flat
require("notation.export").lilypond(layout, { title = "tune" })   -- or .musicxml(layout, { title, part })
```

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
panel is low (dynamics then fall below what shows).
