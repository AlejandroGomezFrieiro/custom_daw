# How to write a snippet

This guide shows you how to add a snippet that writes music from the
harmony at the cursor. The example writes IV, then I, of the key. For each
field, see [Snippets](../reference/snippets.md).

1. Make the file `<config>/snippets/plagal.lua`.
2. Add the snippet:

   ```lua
   paw.snippet.add({
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

3. Start paw again. paw loads the files in `<config>/snippets/` when it
   starts.
4. Open a clip in the piano roll and put the cursor where the chords must
   start.
5. Press `<C-s>` and type `plagal`. The piano roll shows the notes as ghost
   notes.
6. Press `Enter`. The snippet writes the notes and stays active.
7. Press `<Tab>` to select the `voicing` choice. Press `<C-n>` to try the
   next value.
8. Press `<Esc>` to keep the notes.

`ctx:chord` puts the chord in the range of the track and leads it from the
chord before. The `voicing` choice sets its style automatically.

If the snippet cannot write anything at the cursor, return nil and a
reason: `return nil, "no key here"`. The picker shows the reason.

If the snippet uses the count itself, add `count = true` and read
`ctx.count`. Else paw repeats the snippet for the count.

To ship snippets with an extension, put the files in the `snippets/`
directory of the extension.
