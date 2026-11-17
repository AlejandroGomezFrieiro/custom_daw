# midilsp

MIDI LSP, the language server for music from openutau_reaper_editor
(`projects/midi-lsp`), as an entry for `paw.lsp`: this extension says where
its engine is and how to start it, keeps its preset and rules with the
project, and lists every server's problems. Everything it shows goes
through the core's generic consumers (`paw.diagnostic`, `paw.harmony`,
`paw.complete`), so any other server that speaks the same protocol is shown
the same way.

```lua
paw.ext.load("/path/to/paw/extensions/midilsp")
```

The engine is `paw.opt.midilsp_cmd`, else `$MIDI_LSP_ENGINE`, else
`reaper-midi-lsp` on the PATH. Commands, keys and what the engine is sent
are in [docs/lsp.md](../../docs/lsp.md). Its tests run against the real
engine when one is found and are skipped otherwise.
