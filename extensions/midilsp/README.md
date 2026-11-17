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
`reaper-midi-lsp` on the PATH. What the engine is sent is in
[docs/lsp.md](../../docs/lsp.md). Its tests run against the real engine
when one is found and are skipped otherwise.

| Command | Keys | |
| --- | --- | --- |
| `:midilsp` | | where the engine is and how it runs; `:midilsp start`, `:midilsp stop` |
| `:midilsp.preset strict-counterpoint` | | the rules to check, as one of the engine's profiles |
| `:midilsp.rule parallel-perfect off` | `,Lr` | a rule on or off; alone, a list to switch them in |
| `:problems` | `,Lp` | every server's diagnostics with their fixes: Enter goes to one, or applies a fix |
| | `,Li` | the language servers and what they can do |
