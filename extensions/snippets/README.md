# snippets: a starting set of snippets

Snippets for the core's snippet engine (`paw.snippet`), as
friendly-snippets is for LuaSnip: chords that lead into the next chord of
the song, parts made of the chords already there, and voices for a
selection.

```lua
paw.ext.load("/path/to/paw/extensions/snippets")   -- or link it into ~/.config/paw/extensions
```

In the piano roll, `<C-s>` and a few letters, or `:snippet dominant`.
Before a C major chord `dominant` writes G7 from the cursor up to it; `<Tab>`
goes to its choices and `<C-n>` steps one (the voicing first); `u` takes it
all away. What each snippet writes and its choices are listed in
[Snippets](../../docs/reference/snippets.md#the-first-set), with
[How to write a snippet](../../docs/how-to/write-a-snippet.md).

- `snippets/harmony.lua`: `dominant`, `secondary`, `two-five`, `tritone`,
  `passing-dim`, `sus`, `cadence`.
- `snippets/patterns.lua`: `pedal`, `arp`, `bass`.
- `snippets/voices.lua`: `harmonize`, `voice-lead`.
- `lua/snippets/init.lua` (`require("snippets")`): what they share, for
  snippets of your own: the voicing and length choices, `dominant_tones`,
  `split` (a span cut on the grid), `progression` (chords voiced each from
  the one before), `next_chord`.

A snippet of yours with the same name, in `init.lua` or
`<config>/snippets/`, is used instead of the one here.

`tests.lua` is run by the suite: the owner's example (G7 before a C major
chord on another track, and in the same clip through the picker), every
snippet's chords on known material, choices, counts and undo.
