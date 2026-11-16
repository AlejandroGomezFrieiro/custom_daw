# midilsp

MIDI LSP, the language server for music from openutau_reaper_editor
(`projects/midi-lsp`), as an entry for `daw.lsp`: this extension says where
its engine is and how to start it, keeps its preset and rules with the
project, and lists every server's problems. Everything it shows goes
through the core's generic consumers (`daw.diagnostic`, `daw.harmony`,
`daw.complete`), so any other server that speaks the same protocol is shown
the same way.

```lua
daw.ext.load("/path/to/daw/extensions/midilsp")
```

The engine is `daw.opt.midilsp_cmd`, else `$MIDI_LSP_ENGINE`, else
`reaper-midi-lsp` on the PATH. Commands, keys and what the engine is sent
are in [docs/lsp.md](../../docs/lsp.md). Its tests run against the real
engine when one is found and are skipped otherwise.
