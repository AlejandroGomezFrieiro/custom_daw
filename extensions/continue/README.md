# continue

A small completion source: it suggests how the phrase before the cursor in
the piano roll might go on. It knows nothing but the notes and the key, so
it is quick and always the same, and it shows how a source for
`paw.complete` is written before a language server is connected.

```lua
paw.ext.load("extensions/continue")   -- or put the directory in ~/.config/paw/extensions
```

It looks at the bar before where the suggestion starts (the cursor, or the
end of the chosen notes) and offers:

| Alternative | What it is |
| --- | --- |
| the bar again | the same notes, a bar later |
| a step higher | the bar a degree higher in the key: a sequence |
| a step lower | a degree lower |
| the motif, rising | the last half bar twice, a degree higher each time |

The key is `paw.harmony.key` where there is such a module, else guessed from
the clip's notes: the major or minor scale that holds the most of their
sounding time. A note outside the key keeps its distance from the degree
below it.

With the extension loaded, suggestions come by themselves a moment after an
edit (`paw.opt.complete_auto`), or with `Ctrl-Space`. `Tab` takes one,
`Ctrl-l` its next note or chord, `Ctrl-n` and `Ctrl-p` show the others,
`Esc` dismisses it. See [Completion](../../docs/reference/completion.md).

The whole source is `init.lua`, a dozen lines, and the music is plain
functions in `lua/continue.lua`: `suggest(ctx)`, `guess_key(notes)` and
`shift(pitch, steps, key)`.
