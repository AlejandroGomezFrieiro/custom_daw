# Harmony, completion and snippets

The program knows which chords and which key sound at each moment of the
song, over every pitched track. That reading is drawn over the piano roll,
named in Roman numerals as well as chord symbols, and used by snippets:
named bits of music written from their context, such as the dominant of
the chord that comes next. Completion and language servers build on the
same pieces (see [lsp.md](lsp.md) when it is there).

## Harmony

`daw.harmony` reads the notes of every track except drum tracks, muted
tracks and muted clips. A drum track is one with a drum map (the drums
extension's), a `drums` device, or a name with drum, perc, kit or beat in
it.

**Chords.** Time is cut into windows of half a beat (`daw.opt.harmony_step`).
Each window weighs its pitch classes by how long they sound, a short note
off the beat counting half and the lowest note half again. Every chord
(twelve roots, and the qualities major, minor, dim, aug, sus4, sus2, 5, 7,
maj7, m7, m7b5, dim7, m(maj7), 6, m6, 7sus4, add9, 9, maj9, m9) is scored
against that: the weight of its tones less the weight of the rest, less
something for each tone missing (a triad's fifth costs little), less a
little for each tone past three, plus a bonus when the bass is its root. A
chord holds from window to window unless another fits better by more than
a change costs, so a melody's passing notes do not make chords of their
own. The shortest chord found is about a beat. A chord holds over rests up
to the next chord; the last one ends with its notes. The bass names
inversions: `C/E`, `G7/B`.

**Keys.** Each bar's pitch classes (with half of the bars beside it and a
quarter of the next ones, and the roots of its chords counted again) are
compared with Krumhansl and Kessler's major and minor key profiles for all
twelve tonics. A key loses for what sounds outside its scale, and every
bar leans a little to the song's overall key. A key holds unless another
fits better by more than a modulation costs, which is a few bars' worth: a
modulation is found where the new key is established (at its dominant,
usually), not at a pivot chord that belongs to both.

A key set with `:key D minor` wins over the one read, everywhere. It is
kept in `project.meta.musicops`, where the musicops extension kept it
before the core did, so older projects and the notation extension go on
reading it. `:key` comes with musicops; from a script, `daw.harmony.set_key`.

**Names.** Chord symbols are spelled as the key writes them (Bb in F major,
A# in B major; in C major and without a key, the usual C#, Eb, F#, Ab, Bb).
A diminished chord outside the key is named as the leading note it is:
G#dim7 before A minor. Roman numerals count from the tonic as in the major
scale, in every mode: `bVII`, `bVI`, `i`, `V7`, `viiø7`, `ii°`.

**In the piano roll** the chords are written in a row over the ruler, each
from where it starts, and the key the view starts in on the left. In the
window the row is the top of the ruler. `daw.opt.chords` says what is
written: `"names"` (the default), `"roman"`, `"both"`, or `false` for no
row. The arrange view does not show chords.

Tested on the demo song (`examples/demo-song.lua`: A minor, Am F/C
Fadd9/G Am7 Cmaj9 G) and on progressions written for the purpose:
inversions, sevenths, half-diminished and diminished chords, a melody of
passing notes over block chords, and a modulation from C to G major
(`tests/harmony.lua`).

### From a script

```lua
daw.harmony.chords(0, 16)   --> { { at = 0, length = 4, root = 9, quality = "min", bass = 9,
                            --      tones = { 9, 0, 4 }, name = "Am", roman = "i" }, ... }
daw.harmony.at(8)  daw.harmony.next(8)  daw.harmony.prev(8)   -- a chord, or nil
daw.harmony.key(8)          --> { tonic = 9, mode = "minor", name = "A minor", root = 9, scale = "minor", steps = {...} }
daw.harmony.keys()          --> every key read, { at, length, tonic, mode, name }
daw.harmony.set_key("D minor")   daw.harmony.project_key()   -- the key set, or nil
daw.on("harmony.changed", fn)    -- the reading changed
```

Positions are project beats. The reading is made again only when the
project changes, so asking on each key press costs nothing.

**Providers.** The reading comes from the highest-priority provider that
answers. The built-in one has priority 0; a language server, or a script,
can answer instead:

```lua
daw.harmony.provide("my-analysis", function(from, to)
  return { { at = 0, length = 4, root = 2, quality = "m7" }, ... },   -- chords
         { { at = 0, length = 64, tonic = 0, mode = "major" } }     -- keys
end, 100)
daw.harmony.provide("my-analysis", nil)   -- removed
daw.harmony.invalidate()                  -- my answer changed
```

A provider returning nil leaves it to the next. Names and numerals are
filled in. `daw.harmony.provider()` says whose reading it is.

**Theory.** `parse_key("F# dorian")`, `key_name(key)`, `pc_name(pc, key)`,
`in_key(key, pitch)`, `snap(key, pitch, dir)`, `degree(key, pitch)`,
`degree_pitch(key, degree)`, `step(key, pitch, n)` (by scale degrees),
`scales`, `scale_names()`; `tones(root, quality)`, `parse_chord("F#m7b5/C")`,
`chord_name(chord, key)`, `chord_roman(chord, key)`. `daw.harmony.read` has
the built-in reading as pure functions on note lists.

**Voicings.** `daw.harmony.voice.voice(tones, opts)` gives pitches for a
chord (`tones` are pitch classes, root first) within `low`..`high`, in a
`style` ("close", "drop2", "open", "spread", or "smooth": whichever leads
best), moving least from `prev` and into `next` (pitches of the chords
around it), with `bass` lowest if asked and `count` voices (the root is
doubled for more, the fifth left out for fewer).

**Ranges.** `daw.harmony.range(track)` is the range a part for the track
is written in: `track.meta.range = { low, high }` when set, else guessed
from words in the track's and its devices' names (bass E1 to G3, guitar,
strings, voices by part, woodwinds and brass, as MIDI LSP guesses them,
narrowed to where the instrument sounds well), else C3 to C6.

## Snippets

A snippet is named music made from where the cursor is. `dominant` before
a C major chord writes G7 from the cursor up to the C, voiced in the
track's range and led smoothly from the chord before it; a count chains
dominants back (`2` writes D7 then G7).

- `:snippet dominant` expands one at the piano roll's cursor;
  `:snippet` alone, or `<C-s>` in the piano roll (normal, insert or visual
  mode), opens a picker over the snippets of the piano roll. Typing narrows
  it; its pane shows what the one under the selection would write (the
  notes, and the choices it has), and the piano roll shows those notes as
  ghosts. Enter writes it.
- A count repeats: `3<C-s>`, `:3snippet walk`. Each repeat starts where
  the one before ended. A snippet that takes the count itself (`dominant`,
  `bass`, `pedal`) uses it its own way.
- Over a selection (visual mode, then `<C-s>` or `:snippet`), the snippet
  is given the selected notes: `harmonize` adds a voice under them,
  `voice-lead` voices them again.

Expanding is one undo step, and the snippet stays **active**: its notes
are drawn marked (in a colour of their own; in the window, outlined), its
span is a band along the bottom of the roll with its name and its choice.

| Keys (piano roll, normal and insert mode) | |
| --- | --- |
| `<Tab>` `<S-Tab>` | the next choice, the one before |
| `<C-n>` `<C-p>` | the choice's next value, the one before (the first choice when none is chosen); the notes are written again within the same undo step |
| `<C-y>`, `<Esc>` | done: keep the notes as they are |

Moving the cursor out of the snippet's span, or any other edit, ends it too.
One `u` takes the whole snippet away, however many choices were changed.
When no snippet is active these keys do what they do elsewhere: `<Tab>`
goes to the next view, `<C-y>` redoes, `<Esc>` goes back to the arrange
view. In the piano roll `<C-s>` opens the picker rather than saving; `:w`
saves.

### The starting set

`extensions/snippets` (load it with `daw.ext.load`, or link it into
`<config>/extensions`):

| Snippet | Writes | Choices |
| --- | --- | --- |
| `dominant` | V7 of the next chord, from the cursor up to it; a count chains dominants back | voicing, kind (7, 9, 7b9, 7sus4, triad), length |
| `secondary` | V7 of a chord of the key: the next chord's, or ii, iii, IV, V, vi | voicing, of, kind |
| `two-five` | ii7 then V7 into the next chord (iiø7 and V7b9 before a minor one), sharing the time | voicing, split (half, 3:1, 1:3) |
| `tritone` | bII7, the tritone substitute of the next chord's dominant | voicing, kind |
| `passing-dim` | a diminished seventh into the next chord: on its leading note, or on its root | voicing, kind, length |
| `sus` | the next chord suspended up to it, resolving when it comes | voicing, sus (sus4, sus2, 7sus4), resolve |
| `cadence` | V–I (or IV–V–I, ii–V–I, IV–I) to the key's tonic, a bar each | voicing, kind, each |
| `pedal` | a held tonic, dominant or chord root at the bottom of the range | note, length |
| `arp` | the chord at the cursor, arpeggiated over its length | pattern (up, down, up-down, broken), rate, voicing |
| `bass` | root and fifth (or roots, or octaves) under the chords, in a bass's range | pattern, length |
| `harmonize` | a voice a third or a sixth from each selected note, in the key at the note | interval |
| `voice-lead` | the selected chords voiced again to move least, keeping or freeing the bass | bass, voicing |

The voicing choice is `smooth` first: whichever voicing moves least from
what this clip plays before the cursor (or, when it plays nothing there,
from what the other tracks play in its range) and into what comes after.

### Writing a snippet

In `init.lua`, or a file of its own in `<config>/snippets/` (each file
either calls `daw.snippet.add` or returns a list of snippets). An
extension's `snippets/` directory is loaded with it; a snippet of yours
with the same name as an extension's wins.

```lua
daw.snippet.add({
  name = "plagal", desc = "IV then I of the key, two beats each",
  views = { "pianoroll" },
  choices = { { name = "voicing", values = { "smooth", "close", "open" } } },
  expand = function(ctx)
    local tonic = ctx.key.root
    local four = ctx:chord(ctx.harmony.tones((tonic + 5) % 12, "maj"), ctx.at, ctx.at + 2)
    local one = ctx:chord(ctx.harmony.tones(tonic, "maj"), ctx.at + 2, ctx.at + 4)
    for _, n in ipairs(one) do four[#four + 1] = n end
    return { notes = four }
  end,
})
```

`expand(ctx)` returns `{ notes, choices, remove }`, or nil and a reason the
picker and the command line show ("no chord after the cursor").

- `notes` are in **project beats**: `{ pitch, start, length, velocity }`,
  velocity 1 to 127 (`daw.opt.velocity` when left out). They go into the
  clip open in the piano roll, which grows to hold them.
- `choices` are `{ name, values }`, given with the result or with the
  snippet. When one is stepped the snippet is expanded again with
  `ctx.values[name]` set to the new value, on the clip as it was before, so
  it sees what it saw the first time. A choice may instead have
  `apply(result, value)` returning the notes.
- `remove` lists notes of `ctx.selection` the snippet replaces.
- `count = true` on the snippet: it takes `ctx.count` itself rather than
  being repeated.

`ctx` has `at` (the cursor, project beats), `pitch` (the cursor's row),
`clip` and `track` (objects), `clip_id`, `track_id`, `start` (the clip's
start), `notes` (the clip's notes in project beats), `selection` (the
selected notes, with their `place`, or nil) and `region` (`{ from, to }`),
`harmony` (the module), `key` (at the cursor), `range` (the track's), `grid`,
`count`, `values`, `velocity`, `opt`. And helpers:

- `ctx:voice(tones, opts)`: pitches for a chord in the track's range, led
  from the chord before `opts.from` (the cursor) and into what is at
  `opts.to`; the `voicing` choice is its style. `prev` and `next` (pitches,
  or false for none), `bass`, `count`, `low`, `high` as `voice.voice`.
- `ctx:chord(tones, from, to, opts)`: the same as notes from `from` to `to`.
- `ctx:before(beat)`, `ctx:after(beat)`: this clip's chord before a beat
  and at it; `ctx:around(beat, before)`: what other tracks play there in
  this track's range.
- `ctx:until_next()`: the next chord's start, else the end of the bar.

From a script: `daw.snippet.expand(name, { count, at, values })`,
`daw.snippet.preview(name)` (what it would write, without writing),
`daw.snippet.active()`, `jump(dir)`, `step(dir)`, `finish()`, `pick()`,
`offered(view)`, `get(name)`, `remove(name)`, `load_dir(dir, source)`.
Events: `snippet.expanded`, `snippet.finished`.
