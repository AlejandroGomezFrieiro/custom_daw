# musicops: musical operators

The edits a musician makes to notes all day (humanize, strum, arpeggiate,
quantize with swing, crescendo, transpose within the key, ...) as operators,
so that motions, text objects, visual selections, counts, `.` and macros all
work with them. Also phrase and chord text objects, phrase motions, the
project's key, and a scale lock for entering and moving notes.

```lua
daw.ext.load("/path/to/daw/extensions/musicops")   -- or link it into ~/.config/daw/extensions
```

Every key starts with `gz`.

## Operators

An operator acts on what a motion, a text object or a selection covers:

- in the **piano roll** (`pianoroll`) and the **vocal editor** (`utau`), on
  the notes of the region, the way `d` and `>` do: `gzkip` moves the phrase
  under the cursor a step up the scale, `gzs2w` strums the next two notes,
  `vjjgzq` quantizes a selection;
- in the **arrange view**, on the notes of the MIDI clips the region reaches.
  For a stretch of time that is the notes that start inside it (`gzkic` the
  clip under the cursor, `gzh2W` two bars); typed twice it takes whole tracks
  (`gzkk` every clip of the track, `3gzkk` of three tracks). Each clip is
  edited on its own.

Typed twice, an operator takes the whole row: every note of the pitch under
the cursor in the piano roll (`gzhh`), the whole track in the arrange view.
`.` repeats any of them, and they record into macros.

**Counts.** With a motion or a text object the count belongs to it, as for
every operator (`gzk3w`, `gzk2ip`). In visual mode, a count typed before the
operator sets its amount instead: `vip2gzk` is two scale steps, `vip50gzq`
quantizes half way. Each operator below says what its count means.

| Keys | What it does | Count in visual mode | Views | Example |
| --- | --- | --- | --- | --- |
| `gzh` | humanize: nudge starts and velocities at random, seeded | timing in 1/100 beat and velocity range | all | `gzhip` loosens the phrase |
| `gzs` `gzS` | strum each chord upwards, downwards: notes start `musicops_strum` beats apart and still end together | step in 1/100 beat | roll, arrange | `gzsih` strums the chord at the cursor |
| `gzp` `gzP` | arpeggiate each chord up, down, for as long as it lasts | steps per beat (4: sixteenths) | roll, arrange | `gzpih`, `vah4gzP` |
| `gzb` `gzB` | arpeggiate up and down; in the order its notes were played | steps per beat | roll, arrange | `gzBic` the whole clip |
| `gzl` | legato: hold each note to the next | | all | `gzlip` |
| `gzt` | staccato: shorten each note to `musicops_staccato` of it | percent of the length kept | all | `vip25gzt` a quarter |
| `gzq` | quantize to the grid, with `musicops_strength` and `musicops_swing` | strength in percent | all | `gzqip`, `vip50gzq` |
| `gzw` | quantize with swing (`musicops_swing_amount`, triplet swing by default) | swing in percent of a step | all | `gzw2W` |
| `gz>` `gz<` | crescendo, diminuendo: up to `musicops_ramp` more (less) velocity by the last note | the velocity added or taken | roll, arrange | `gz>ip`, `vip20gz<` |
| `gzc` | compress velocities half way to their average (`musicops_compress`) | ratio in percent (above 100 expands) | roll, arrange | `gzcip` |
| `gzv` | even out velocities: all at their average | the velocity to set | roll, arrange | `vip90gzv` |
| `gze` | accent: louder notes on the beat (`musicops_accent`) | velocity added | roll, arrange | `gzeic` |
| `gzr` | reverse the passage in time (retrograde) | | all | `gzrip` |
| `gzd` `gzD` | double time, half time, from the first note | | all | `gzdip` |
| `gzu` `gzU` | invert each chord up (the lowest note goes an octave up), down | how many inversions | roll, arrange | `gzuih`, `vah2gzU` |
| `gzk` `gzj` | up, down a step of the project's scale | scale steps | all | `gzkip`, `vip3gzj` |
| `gzn` | snap notes outside the key to it (`musicops_snap`) | | all | `gznic` |
| `gzm` | mirror the melody around its first note, in scale steps | | all | `gzmip` |
| `gzo` `gzO` | double every note an octave up, down | octaves | roll, arrange | `gzoip` |
| `gzx` | remove overlapping notes of one pitch | | all | `gzxic` |

"All" is the piano roll, the vocal editor and the arrange view. Strumming,
arpeggios, chord inversions, velocity edits and octave doubling are left out
of the vocal editor: it sings one voice, and new notes would repeat lyrics.
In the vocal editor notes keep their lyrics and tuning through every edit.

`gzh` uses a new seed each time and says which (`humanized, seed 1234`); set
`daw.opt.musicops_seed` to that number to get the same result again, or to
any number to make every humanize reproducible.

Notes pushed past the end of their clip (half time, an arpeggio) make the
clip longer, to the next grid step. In the arrange view that can make it
overlap the clip after it.

## Text objects and motions

In the piano roll and the vocal editor:

| Keys | What it names |
| --- | --- |
| `ip` | the phrase at the cursor: notes with no rest longer than `musicops_phrase_rest` beats (half a beat) between them. From a rest, the next phrase. `2ip` two phrases |
| `ap` | the phrase and the rest after it, up to the next phrase |
| `ih` | the chord sounding at the cursor: its notes, as a block from their lowest to their highest pitch |
| `ah` | the chord and every note that starts while it sounds |
| `)` `(` | motions: the start of the next phrase; the start of this phrase, or the previous one. With a count, that many |

`dip` deletes a phrase, `yap` yanks it with the rest after it, `vih` selects
the chord, `gzsih` strums it, `d)` deletes to the next phrase.

## Key and scale

The project's key is kept in `project.meta.musicops` (`{ root = "D", scale =
"minor" }`), so it is saved with the project and undone like any edit.
Without one, the operators work in C major.

| Command | |
| --- | --- |
| `:key D minor`, `:musicops.key F# dorian` | set the key; the scale defaults to major |
| `:key` | show it |
| `:key off` | clear it |
| `:musicops.scales` | list the scales |
| `:musicops.lock`, `:musicops.lock on`, `gzL` | the scale lock, on or off |
| `:musicops.apply <function> name=value ...` | apply a module function to the whole clip being edited (the piano roll's or vocal editor's, else the clip under the arrange cursor): `:musicops.apply humanize timing=0.05 seed=3`, `:musicops.apply transpose_scale 2` |

Scales: `major` (`ionian`), `minor` (`aeolian`), `harmonic_minor`,
`melodic_minor`, `dorian`, `phrygian`, `lydian`, `mixolydian`, `locrian`,
`pentatonic`, `minor_pentatonic`, `blues`, `whole_tone`, `chromatic`, and any
other in `daw.music.scales`.

**Scale lock** (`musicops_scale_lock`, `gzL`). While it is on:

- insert mode in the piano roll moves the note being drawn by steps of the
  scale (`j` `k`, `2k` from C is E in C major), and with the keyboard as a
  piano (`I`) enters the nearest pitch of the key: in C major `w` (C#)
  enters D;
- `<C-a>` and `<C-x>` move the note under the cursor in the piano roll, and
  the selected notes in the piano roll and the vocal editor, by steps of the
  scale instead of semitones (`3<C-a>`: three steps).

This is done by putting mappings over the runtime's ones for those keys,
which hand back to the runtime's own while the lock is off. Nothing in the
runtime is changed.

## The module

`require("musicops")` is a set of pure functions on lists of notes `{ pitch,
start, length, velocity, meta }`, usable from any script. Each returns a new
list in time order and leaves its input alone; notes keep their `meta`, and
notes an edit adds copy the `meta` of the note they come from. Results are
kept playable: pitches 0..127, whole velocities 1..127, no start before 0,
lengths of at least 1/64 beat.

```lua
local mo = require("musicops")
local clip = daw.tracks()[1]:clips()[1]
clip:set_notes(mo.humanize(clip:notes(), { timing = 0.02, velocity = 8, seed = 7 }))
clip:set_notes(mo.arpeggiate(clip:notes(), { mode = "updown", step = 0.25 }))
clip:set_notes(mo.transpose_scale(clip:notes(), 2, "D minor"))
```

| Function | Options (defaults) |
| --- | --- |
| `humanize(notes, opts)` | `timing` 0.02 beats either way, `velocity` 8, `length` 0 (a fraction), `seed` 1 |
| `quantize(notes, opts)` | `grid` 0.25, `strength` 1, `swing` 0 (fraction of a step that every second grid line moves later; 1/3 is triplet swing at eighths), `lengths` false |
| `legato(notes, opts)` | `gap` 0: each note lasts until the next one starts; chords reach the next chord; the last notes stay |
| `staccato(notes, opts)` | `factor` 0.5 |
| `set_length(notes, opts)` | `length` 0.25 |
| `reverse(notes)` | mirrored in time within the first start and the last end |
| `stretch(notes, opts)` | `factor` 1, `anchor` the first start |
| `double_time(notes, opts)`, `half_time(notes, opts)` | `anchor` |
| `strum(notes, opts)` | `step` 0.05, `dir` "up" or "down", `tolerance` |
| `arpeggiate(notes, opts)` | `mode` "up", "down", "updown" or "played", `step` 0.25, `gate` 1, `tolerance`. A lone note stays |
| `invert(notes, opts)` | `dir` 1 or -1, `times` 1, `tolerance` |
| `add_octave(notes, opts)` | `by` 12 |
| `transpose(notes, semitones)` | |
| `transpose_scale(notes, degrees, key)` | key: a name or a key; the project's when nil. Notes outside the key keep their distance from the scale note below them |
| `snap_scale(notes, key, opts)` | `dir` "nearest" (halfway goes up), "up", "down" |
| `mirror(notes, opts)` | `axis` (a pitch or name; the first note's), `key` (mirror in scale steps; without, in semitones) |
| `ramp(notes, opts)` | `from` 40, `to` 110: velocities on a straight line from the first start to the last |
| `crescendo(notes, opts)`, `diminuendo(notes, opts)` | `amount` 30: added (taken) in full at the last start, none at the first; accents stay |
| `compress(notes, opts)` | `ratio` 0.5, `center` their average |
| `set_velocity(notes, opts)` | `velocity` (their average when nil) |
| `accent(notes, opts)` | `grid` 1, `offset` 0, `amount` 20 |
| `remove_overlaps(notes)` | a note is cut where a later one of its pitch starts; of notes starting together on a pitch the longest stays |

Helpers: `chords(notes, tolerance)` groups notes starting within `tolerance`
beats (1/16) of each other; `phrases(notes, rest)` returns `{ start, finish,
notes }` for each phrase; `sounding(notes, beat)` the notes sounding at a beat;
`span(notes)` the first start and last end; `random(seed)` the generator
`humanize` uses (Park and Miller's, the same numbers on every machine).

`require("musicops").scale` (also `musicops.scale`) is the theory:
`parse("D minor")` returns `{ root = 2, scale = "minor", steps = {...} }`;
`name(key)`, `contains(key, pitch)`, `snap(key, pitch, dir)`, `step(key, pitch,
n)`, `degree(key, pitch)` and `pitch(key, degree)` (absolute scale degrees),
`names()`, `scales`; `project()` the project's key or nil, `current()` the key
to work in, `set(spec)` sets it (nil clears it) and emits `musicops.key`.

`require("musicops.keys")` has what the keys use: `apply(view, region, fn)`,
`apply_arrange(region, fn)`, `apply_to_clip(clip, pick, fn)`,
`phrase_region`, `chord_region`, `phrase_motion`, and `operator(lhs, desc,
views, fn)` to add an operator of your own the same way.

## Options

| Option | Default | |
| --- | --- | --- |
| `musicops_seed` | nil | fixed seed for `gzh`; nil for a new one each time |
| `musicops_humanize_timing` `musicops_humanize_velocity` `musicops_humanize_length` | 0.02, 8, 0 | how far `gzh` goes |
| `musicops_strum` | 0.05 | beats between the notes of a strum |
| `musicops_arp_step` `musicops_arp_gate` | nil (the piano roll's grid), 1 | arpeggio step and note length in steps |
| `musicops_legato_gap` | 0 | beats `gzl` leaves between notes |
| `musicops_staccato` | 0.5 | what `gzt` keeps |
| `musicops_strength` `musicops_swing` | 1, 0 | `gzq` (the grid is `note_grid`) |
| `musicops_swing_amount` | 1/3 | `gzw` |
| `musicops_ramp` | 30 | `gz>` `gz<` |
| `musicops_compress` | 0.5 | `gzc` |
| `musicops_accent` | 20 | `gze` |
| `musicops_together` | 1/16 | notes starting this close are one chord |
| `musicops_phrase_rest` | 0.5 | a rest longer than this ends a phrase |
| `musicops_snap` | "nearest" | where `gzn` and the scale lock send notes outside the key: "nearest", "up", "down" |
| `musicops_mirror_chromatic` | false | `gzm` mirrors in semitones |
| `musicops_scale_lock` | false | entry and `<C-a>` `<C-x>` stay in the key |

## Tests

`tests.lua` beside this file is run by the suite (`daw --clean --no-plugins -l
tests/suite.lua musicops`): every function on known notes with exact results,
the operators through typed keys in the piano roll, the arrange view and the
vocal editor with `.`, counts and visual counts, the text objects and
motions, the key through undo, redo, save and load, and the scale lock.

## Not done

- **Counts in normal mode** go to the motion or text object, never to the
  amount: `3gzkip` is three phrases a step up, not one phrase three steps.
  Use visual mode for an amount.
- **Typed twice is the whole row.** `gzhh`, `gzjj`, `gzkk`, `gzll`, `gzww`,
  `gzbb`, `gzee` take whole pitches (whole tracks), as `>>` does, so the
  motions `h` `j` `k` `l` `w` `b` `e` cannot directly follow the operator
  with the same last key. For the same reason no operator ends in `i` or `a`,
  which would swallow the text objects.
- **The key is not shown** in the piano roll, and out-of-key rows are not
  shaded: the piano roll draws its rows itself and offers no hook for it. It
  would need the piano roll's `render` to ask for a style per row (for
  example a `row_style(pitch)` function on the view, or an event), which the
  runtime does not have.
- **Scale lock** covers insert mode and `<C-a>` `<C-x>` only. The cursor's `j`
  `k`, `Enter` (add a note at the cursor), the mouse and pasted notes stay
  chromatic. It does not apply in the arrange view (where `<C-a>` transposes
  a whole clip in semitones) or in the vocal editor's normal mode, which has
  no `<C-a>` of its own.
- **Arrange-view operators** edit each clip on its own: a phrase spread over
  two clips is reversed, stretched or ramped clip by clip. Notes of a clip
  that start before the region are left alone even if they sound in it.
- The `]p`/`[p` style of motion is not used, so that `]` and `[` (velocity in
  the piano roll) do not wait for a second key.
- Not tried by hand in a terminal: everything was checked through
  `daw.keymap.feed` in the suite.
