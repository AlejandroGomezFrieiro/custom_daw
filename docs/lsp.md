# Language servers and diagnostics

A language server for music reads the notes you write and says what it
thinks of them: a parallel fifth between two voices, a leap too wide for a
flute, the chord and key it hears, what might come next. This is Neovim's
`vim.lsp` and `vim.diagnostic` for a DAW. The core knows the protocol and
shows what any server says; which server runs is an extension's business.
[MIDI LSP](#midi-lsp) is the one that comes with the source.

## Diagnostics

A diagnostic is something wrong (or worth knowing) about some notes of a
MIDI clip: a severity (error, warning, information, hint), a message, the
rule that found it, who said it, and the fixes for it. They are shown the
same way whoever published them:

- **In the piano roll**, each note a diagnostic is about is underlined in
  its severity's colour (red, amber, blue, grey), the message follows the
  last of its notes while there is room, and a mark on the ruler shows
  where it starts. In the window the notes are outlined in that colour and
  the ruler is marked the same way; the pointer on such a note says what is
  wrong with it in the hint line.
- **The status line** counts them: `E1 W2` for the clip in the piano roll,
  or for the whole project when none is open.
- **The arrange view** marks a clip that has any at its right end.
- `]d` and `[d` go to the next and previous diagnostic of the piano roll's
  clip; in the arrange view, to the next and previous clip with any (with
  extensions/mixdiag loaded, they go to its mix findings there instead).
- `:diagnostics` lists every one (`:diagnostics clip`, those of the piano
  roll's clip) in a picker, as Neovim's quickfix list: Enter goes there.

**Fixes.** `,ca` in the piano roll lists the fixes for the note under the
cursor (off a note, for the diagnostics where the cursor is); Enter carries
one out. In the window, Ctrl and a right click on a note opens the same
list, with "What the language servers say about it" at its foot. A fix is
always one undo step, and finds its notes by pitch and start, so other
edits made since do not make it change the wrong note.

**What a server says about a note.** `gK` in the piano roll (`K` is an
octave up there) opens a small float with the diagnostics about the note
under the cursor and each server's answer about that place: for MIDI LSP,
the note's degree in the key and the chord it sounds in.

## Language servers

A server is a program that speaks MIDI LSP's protocol: JSON-RPC 2.0 on its
standard input and output, one message a line (as MIDI LSP's engine does
with `--stdio`) or with LSP's `Content-Length` headers. It is started from
a config, as `vim.lsp.config`:

```lua
daw.lsp.config("range", {
  cmd = { "python3", "/home/me/servers/range_lint.py" },  -- or a function giving it
  framing = "lines",                       -- or "headers"
  attach = { kinds = { "clip" }, tracks = { "Flute*", "Violin*" }, drums = false },
  init_options = { lo = 60, hi = 96 },    -- sent once, at initialize
  settings = { severity = "warning" },    -- sent at initialize, and again when changed
  restart = { max = 3, within_s = 60 },   -- restarts after it dies (none by default)
})
daw.lsp.enable("range")
```

What happens then:

1. The server is started with pipes (`daw.api.proc_spawn(argv, { pipe = true })`);
   what it writes on its error output goes to
   `$XDG_STATE_HOME/daw/lsp-<name>.log`.
2. It is sent `initialize` with `protocolVersion = 2`, and answers with what
   it can do (`diagnosticProvider`, `hoverProvider`, `completionProvider`
   with its lanes, `analysisProvider`). Everything below is turned on from
   those answers, never from the server's name.
3. The clip open in the piano roll is sent as a document, if the server's
   `attach` takes it: `midi/didOpen` the first time, `midi/didChange` once
   edits have paused for a quarter of a second, `midi/didClose` when another
   clip is opened. With several people on one instance, every clip open in
   anyone's piano roll is sent.
4. What it publishes goes to the generic places: `midi/publishDiagnostics`
   to `daw.diagnostic` under the server's name, `midi/publishAnalysis` (the
   chords and keys it hears) to `daw.harmony` as a provider, its suggestions
   to `daw.complete`, its hover to the float above.
5. If it dies it is marked dead, its diagnostics go, and it is started again
   if `restart` allows.

**The document** is MIDI LSP's snapshot of a take, built from a clip: its
URI is `daw://clip/<id>`, times are ticks from the clip's start at 960 to
the beat, a note's `id` is its place in the clip less one. It carries the
track's name and devices, the signature and the bar the clip starts in,
the tempo and signature changes over it, the project's key (from
`daw.harmony`, or extensions/musicops), the clip's controller moves, and as
`context` the notes of every other track's MIDI clip that sounds with it,
in this clip's ticks, with their tracks (a drum track is tagged `drums`).

`:lsp` (`:lsp info`) lists the servers, their state, the command, what they
can do, the documents they hold and where their errors are written. `:lsp
start [name]`, `:lsp stop [name]`, `:lsp restart [name]`, and `:lsp log`
for the last messages to and from them.

### Writing a server

Any language will do. A server reads a message a line from its input and
writes its answers a line each to its output. It must answer `initialize`
with `protocolVersion`, `serverInfo` and `capabilities`, take
`midi/didOpen` and `midi/didChange` (the snapshot above) and answer them,
and may publish `midi/publishDiagnostics`:

```json
{ "jsonrpc": "2.0", "method": "midi/publishDiagnostics",
  "params": { "uri": "daw://clip/3", "hash": "…as sent…",
    "diagnostics": [ { "code": "range", "severity": "warning", "message": "C7 is too high",
                       "start": 960, "end": 1920, "notes": [1],
                       "fixes": [ { "title": "Move C7 to C6", "edits": [ { "note": 1, "pitch": 84 } ] } ] } ] } }
```

An edit sets `pitch`, or `delete`s the note. `tests/fixtures/range_lint.py`
is a complete server in a hundred lines, with hover and completion too.

## Diagnostics from Lua

A plugin need not be a server to say what is wrong. `daw.diagnostic` is
open to any Lua (see [Scripting](scripting.md)):

```lua
daw.diagnostic.set("mylint", clip, {
  { notes = { 3 }, severity = "warning", rule = "range", message = "too high",
    fixes = { { title = "Down an octave", edits = { { note = 3, pitch = 72 } } } } },
})
```

## MIDI LSP

`extensions/midilsp` is MIDI LSP's entry, from openutau_reaper_editor
(`projects/midi-lsp`): its engine checks voice leading, counterpoint,
ranges, rhythm and form, hears chords and keys, and suggests melodies,
velocities and controller curves.

```lua
daw.ext.load("/path/to/daw/extensions/midilsp")
```

The engine is found in `daw.opt.midilsp_cmd` (words, such as `"reaper-midi-lsp
--rules /home/me/rules"`), else `$MIDI_LSP_ENGINE`, else `reaper-midi-lsp`
on the PATH. To build one: `nix build <openutau_reaper_editor>#midi-lsp-engine`.
It is started when the extension loads (`daw.opt.midilsp_autostart`), as two
servers: `midi-lsp`, the language role, and `midi-lsp-suggest`, the
suggestion role (`daw.opt.midilsp_suggest`), so that a slow suggestion never
holds up a diagnostic.

| Command | Key | What it does |
| --- | --- | --- |
| `:midilsp` | | where the engine is, the settings, the servers |
| `:midilsp start`, `:midilsp stop` | | |
| `:midilsp.preset strict-counterpoint` | | the rules to check, as one of the engine's profiles |
| `:midilsp.rule parallel-perfect off` | `,Lr` alone: a list to switch rules in | a rule on or off |
| `:problems` | `,Lp` | every server's diagnostics, each with its fixes: Enter goes to one, or applies a fix |
| `:lsp info` | `,Li` | |

The preset and the rules are kept with the project and sent to the engine
as soon as they change; its diagnostics follow.
