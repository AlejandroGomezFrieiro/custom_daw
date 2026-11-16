# Harmony, completion and snippets

Seeing and writing the harmony of a song: what is wrong with the notes and
how to fix it, the chords and key that sound, suggestions of what could
come next, named snippets of music made from what is around the cursor,
and the notes of several tracks in one piano roll. Each is a core module a
plugin can feed, after Neovim's: `daw.diagnostic` and `daw.lsp` (as
`vim.diagnostic` and `vim.lsp`), `daw.harmony`, `daw.complete`,
`daw.snippet`. Without an extension loaded they are there and quiet.

## Language servers and diagnostics

A language server (MIDI LSP, or any program speaking its protocol) is sent
the clip in the piano roll with the notes of every other track that sound
with it, and what it says comes back to the places everyone uses:

- **diagnostics**, such as a parallel fifth: the notes underlined in the
  piano roll of the terminal and outlined in the window's, a mark on the
  ruler, a count in the status line, `]d` `[d` to go from one to the next,
  `:diagnostics` to list them;
- **fixes**: `,ca` on a note (Ctrl and a right click in the window), one
  undo step each;
- **hover**: `gK` on a note, what the servers say about it;
- **the chords and key it hears**, offered to `daw.harmony`;
- **suggestions**, offered to `daw.complete` as a source.

A plugin written in Lua publishes diagnostics just as a server does, with
`daw.diagnostic.set`. The whole story, the protocol and MIDI LSP's
extension are in [Language servers and diagnostics](lsp.md).

## Completion

A suggestion is shown as ghost notes in the piano roll: dashed in the
terminal, see-through with a bright edge in the window, in the track's
colour. A badge over it says which alternative shows, of how many, and
where it came from: `1/4 continue: the bar again`. Nothing is written until
it is accepted, and accepting is one undo step.

Suggestions come from **sources**, which extensions register. Without one
nothing is ever suggested; `extensions/continue` is a small one to start
with (it repeats the last bar, or moves it a step up or down the key), and
a language server or a snippet set can be another. `:complete.sources`
lists those there are.

**When.** `Ctrl-Space` in the piano roll (normal or insert mode) asks every
source at once. With `daw.opt.complete_auto` on (the default; the window's
toolbar has a Suggest switch), the sources are also asked by themselves when
nothing has been edited for `daw.opt.complete_idle_ms` (1.2 seconds) while
the piano roll has the keyboard. Never while the transport plays or records:
a suggestion that came by itself hides when it starts.

**Where.** A suggestion starts after the chosen notes, if some are chosen
(with the pointer, or a selection in visual mode), else at the cursor. In
insert mode that is right after the notes just entered, so entering a few
notes and pausing is enough to be offered more.

**Keys** while a suggestion shows, in normal and insert mode:

| Keys | What they do |
| --- | --- |
| `Tab` | accept it all; the cursor goes to where it ends |
| `Ctrl-l` | accept its next note, or its next chord: the notes that start first, together; the rest keeps showing |
| `Ctrl-n` `Ctrl-p` | the next or previous alternative |
| `Alt-1` … `Alt-9` | show that alternative |
| `Ctrl-e`, `Esc` | dismiss it (in insert mode `Esc` dismisses first and leaves insert mode only when nothing shows) |
| `gh` | hear it through the track, from a bar before, with the notes already there (normal mode) |

Otherwise those keys do what they always do. An edit of the clip, undo, or
another request dismisses what shows. Each terminal and window attached to
an instance has its own suggestion; an edit from any of them dismisses a
suggestion for that clip in all. With `daw.opt.complete_audition` on,
every alternative shown is heard that way by itself; the project is never
changed by hearing one. `:complete`, `:complete.accept` (`next` for the next
notes only), `:complete.dismiss` and `:complete.audition` do the same as the
keys.

**In the window** the ghost notes are drawn over the clip's own, with a row of
chips over them: one numbered chip per alternative (a click shows it) and one
saying what shows (a click accepts it). The keys work the same with the
piano roll focused.

**Deadlines.** A request waits `daw.opt.complete_deadline_ms` (300 ms) for
the sources, then shows what has arrived, the higher priority sources first;
answers that come later are added at the end, so a slow source never holds
up a quick one. A source that fails, answers twice or answers nonsense is
skipped and the piano roll goes on as before.

### Writing a source

```lua
daw.complete.register({
  name = "octaves", priority = 10,
  views = { "pianoroll" },
  auto = true,                         -- may be asked without a key press
  complete = function(ctx, done)
    local items = {}
    for _, n in ipairs(ctx.selection or {}) do
      items[#items + 1] = { pitch = n.pitch + 12, start = n.start, length = n.length }
    end
    done({ { label = "an octave up", notes = items } })   -- or done(nil): nothing to say
  end,
  cancel = function(ctx) end,          -- a newer request replaced ctx.id
})
```

`complete` may call `done` at once or any time later (from a timer, or when a
helper program answers); only its first call counts, and only while the
request is still the newest. `ctx` holds `clip` and `track` (ids), `start`
and `length` (where the clip is, in project beats), `at` (where the
suggestion starts, in the clip's beats), `pitch` (the cursor's), `notes` (the
clip's notes), `selection` (the chosen notes or nil), `grid`, `view`,
`trigger` ("manual" or "auto"), `id`, and `key` when a module gives the key
(`daw.harmony.key`).

An item has a `label`, an optional `detail`, and any of: `notes` to add
(`{ pitch, start, length, velocity }`, `start` in the clip's beats as
`clip:notes()` gives them; velocity 1 to 127, `daw.opt.velocity` when left
out), `remove` (places of the clip's notes it replaces, as `clip:notes()`
numbers them), `velocities` (`{ [place] = velocity }`) and `controls`
(controller moves to add). `daw.complete.show(items, { keys = false })`
shows items as ghost notes without being a source, for a preview; with the
keys left on they can be accepted like any suggestion.
