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
