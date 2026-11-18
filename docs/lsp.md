# Language servers and diagnostics

A language server reads part of a project and says what it thinks of it: a
parallel fifth between two voices, a fader that will clip, a master louder
than the delivery allows, a render without dither. This is Neovim's
`vim.lsp` and `vim.diagnostic` for a DAW, built in four layers, none of
which knows any server by name:

1. **Addresses**: a URI for everything a server could talk about.
2. **Subjects**: what a server is shown, as projections of the project.
3. **Clients**: how a server is run and spoken to.
4. **Features**: diagnostics, labels, hover, actions and suggestions, kept
   by location and drawn by each view where it belongs.

[MIDI LSP](#midi-lsp), which comes with the source as an extension, is one
server among any number; `extensions/mixdiag` is another, run in this
process.

## Using them

What any server (or any plugin) says shows the same way, in the terminal
first and in the window:

- **Notes** a diagnostic is about are underlined in the piano roll in the
  colour of its severity (red error, amber warning, blue information, grey
  hint), with the message after the last of them and a mark on the ruler.
  The window outlines them and says what is wrong in the hint line.
- **Tracks**: a sign before the name on the track's header and at the end
  of its name plate on the mixer strip. A server's label on a track (a
  loudness readout, say) is shown on the strip's peak row.
- **Devices and parameters**: a sign and the message after the device's
  name in the device panel, a sign before a parameter's name.
- **Stretches of time**: marked on the arrange view's ruler.
- **Renders**: listed by `:diagnostics` under Renders, with fixes that render
  again.
- **The status line** counts them: `E1 W2` for the piano roll's clip, or the
  whole project when none is open.

| Keys | |
| --- | --- |
| `]d` `[d` | the next, previous diagnostic the focused view shows (piano roll, arrange view, mixer, device panel); the cursor goes there |
| `gK` | what is known about what is under the cursor: diagnostics, labels, and each server's hover |
| `,ca` | fixes and actions for what is under the cursor; Enter makes one, as one undo step |
| `:diagnostics` | every diagnostic, grouped by what it is about; Enter goes there |
| `:lsp` | `:lsp info` (each server, how it runs, what it is shown and can do, its last error), `:lsp start\|stop\|restart [name]`, `:lsp log` |

In the window, Ctrl and a right click on a note opens its fixes and "What
the language servers say about it".

## Addresses

Everything has a URI built from ids, so it survives edits
(`paw.address`, see [Addresses, diagnostics and lists in Lua](reference/lua-addresses.md) for the whole list):
`paw://project`, `paw://track/12` (`paw://track/0` is the master),
`paw://track/12/device/3`, `paw://track/12/device/3/param/cutoff`,
`paw://track/12/send/5`, `paw://clip/7`, `paw://clip/7/note/41`,
`paw://lane/9`, `paw://tempo`, `paw://marker/5`,
`paw://render/<the file's path>`. Extensions add kinds of their own.

**Notes have ids.** Every note in the model has an id that stays with it
through every move and change, given when it is made; a copy pasted beside
its original is another note with an id of its own. `paw://clip/7/note/41`
is that note wherever it goes, so a diagnostic stays on its notes and a fix
changes the right one after other edits. (Before, notes were found again
by pitch and start; that is gone.)

A **location** is an address and, optionally, a part of it: `{ uri, selector }`
with `selector = { time = { from, to } }` (beats), `{ notes = { ids } }`,
`{ pitch = { lo, hi } }`, `{ seconds = { from, to } }` (in a render) or
`{ value = x }`.

A **workspace edit** is a list of changes, each `{ uri, set = { ... } }`,
`{ uri, insert = { ... } }` or `{ uri, delete = true }`, all checked before
any is made and made as one undo step: a note's pitch, start, length or
velocity; a clip's notes inserted; a track's volume, pan, mute, solo, name or
output, a device inserted on it; a device's bypass or parameters; a
parameter's value; a send's level; a render made again with other options.
Every fix and every edit a server asks for goes through it.

## Subjects

A server is shown subjects, each a projection of part of the project as
plain data, sent as a document named by its address (and `#subject` when the
subject is not the address's own):

| Subject | Document | What it holds | By focus |
| --- | --- | --- | --- |
| `clip` | `paw://clip/7` | MIDI LSP's take: the notes in ticks (960 to the beat) with their ids, the track and its devices, the signature and bar the clip starts in, the tempo map over it, the key, the controller moves, and as `context` the notes of other tracks that sound with it | the clips open in a piano roll |
| `track` | `paw://track/3` | the track's fader, pan, mute, solo, output, sends, its devices with their parameters' values and ranges, and its clips | the track a cursor is on |
| `mix` | `paw://project#mix` | every track as above with its address, the master, the tempo and signatures, the sample rate, the loudness targets (`paw.opt.loudness_target`, `paw.opt.true_peak_target`), the last render's options | |
| `project` | `paw://project` | the whole, summarised: tracks with how many clips and devices, markers, the tempo, its length | |
| `render` | `paw://render/...` | a rendered file: its path, format, rate, bits, channels, length, peak and loudness as measured, the options it was made with, the master's devices | |

A document is sent when a server becomes attached to it, again (debounced)
when the addresses it depends on change and it comes out different, and
closed when it goes. A server is attached by its config,
`attach = { subjects = { "mix", "render" }, where = { focus = true, tracks = { "Flute*" }, drums = false } }`,
or else by what it asks for at initialize (`capabilities.paw.subjects`), or
else to clips. `focus = true` means only what someone is looking at (the
open piano roll's clip, the cursor's track); without it, a mix or render
server is sent the whole, all the time.

## Running a server

```lua
paw.lsp.config("mixcheck", {
  cmd = { "python3", "/home/me/servers/mixcheck.py" },  -- or a function giving it
  framing = "lines",                       -- or "headers" (Content-Length)
  attach = { subjects = { "mix" } },
  init_options = { target = -14 },         -- sent once, at initialize
  settings = { strict = true },            -- sent at initialize, and again when changed
  restart = { max = 3, within_s = 60 },    -- restarts after it dies (none by default)
})
paw.lsp.enable("mixcheck")
```

A server is one of three things:

- **A process** speaking JSON-RPC on its standard input and output, one
  message a line or with LSP's `Content-Length` headers. Its errors go to
  `$XDG_STATE_HOME/paw/lsp-<name>.log`.
- **A one-shot command** (`kind = "oneshot"`), run once per version of each
  subject it is attached to, with a timeout (`timeout_ms`). In `cmd`,
  `{file}` (a render's path), `{input}` (a file holding the subject as JSON,
  or what `input(doc)` makes of it), `{uri}`, `{subject}` and each setting
  are put in; a word that is only a placeholder with no value is left out
  with the option before it. The subject is also written to its input. It
  prints `{ "findings": [ { "rule", "severity", "message", "time_s"? } ] }`
  (severity `off` is left out); `diagnostic(finding, doc)` in the config may
  give a location and fixes; `accepts(doc)` says which documents it takes.
  Printing `{ "error": ... }`, or what is not JSON, marks it failed, with the
  reason in `:lsp info`.
- **A Lua table** in this process (`server = { initialize = fn, ... }`):
  its handlers are called directly with the parameters and a `ctx` whose
  `notify(method, params)` sends this program a notification and
  `request(method, params)` asks it something.

### Writing a server for the mix

The protocol is LSP's own; this program's locations and workspace edits
travel in the `data` fields LSP leaves free. A server must:

1. answer `initialize` with its capabilities, saying which subjects it wants:
   `{ "capabilities": { "hoverProvider": true, "codeActionProvider": true, "paw": { "subjects": ["mix"], "annotations": true } } }`;
   the client offers `capabilities.paw = { subjects, addresses, workspaceEdit, features }`;
2. take `textDocument/didOpen` (`{ textDocument: { uri, languageId: "paw-mix", version, text } }`,
   `text` the subject as JSON), `didChange` (the whole text again) and
   `didClose`;
3. publish what it finds with `textDocument/publishDiagnostics`:

```json
{ "uri": "paw://project#mix",
  "diagnostics": [ { "severity": 2, "code": "hot-fader", "source": "mixcheck",
    "message": "Bass's fader is at +3.0 dB: it may clip",
    "data": { "location": { "uri": "paw://track/4" },
              "fixes": [ { "title": "Bring Bass to 0 dB",
                           "edit": [ { "uri": "paw://track/4", "set": { "volume": 0 } } ] } ] } } ] }
```

and may also send `paw/publishAnnotations` (`{ uri, annotations: [ { location, label, kind } ] }`,
labels on things), `paw/publishAnalysis` (`{ uri, chords, keys, key }` in
project beats, for `paw.harmony`), answer `textDocument/hover` and
`textDocument/codeAction` (both with `params.paw.location`, what is asked
about; actions are `{ title, edit: { paw: changes } }` or `{ title, command }`),
`textDocument/completion` on clips (`params.paw.at`; items' `data.notes`),
and ask for `workspace/applyEdit` (`{ edit: { paw: changes }, label }`).
`tests/fixtures/mix_lint.py` is a complete server for the mix in a hundred
lines, and `tests/fixtures/range_lint.py` one for clips.

### Writing one in Lua

```lua
local doc
paw.lsp.config("loud", { server = {
  initialize = function() return { capabilities = { paw = { subjects = { "mix" } } } } end,
  ["textDocument/didOpen"] = function(p, ctx)
    doc = p.textDocument.uri
    local list = {}
    for _, t in ipairs(p.textDocument.data.tracks) do   -- in-process: the subject as a table
      if t.volume > 6 then
        list[#list + 1] = { severity = 2, message = t.name .. " is very loud", data = { location = { uri = t.address } } }
      end
    end
    ctx.notify("textDocument/publishDiagnostics", { uri = doc, diagnostics = list })
  end,
  ["textDocument/didChange"] = function(p, ctx) end,
} })
paw.lsp.enable("loud")
```

extensions/mixdiag is such a server: its measurements' findings become
diagnostics on the tracks they name, with a fix wherever a finding says by
how much to lower a fader, so its report and `:diagnostics` agree.

### Dialects

A server that speaks another protocol gets an **adapter**
(`paw.lsp.adapter(name, spec)` and `adapter = name` in its config): small
functions that turn the subject into its messages and its answers into
locations and workspace edits (see `runtime/lua/paw/lsp/standard.lua` for
what an adapter has). MIDI LSP's `midi/*` dialect is one, in
`extensions/midilsp/lua/midilsp/adapter.lua`.

## Diagnostics from Lua

A plugin need not be a server. `paw.diagnostic` is open to any Lua:

```lua
paw.diagnostic.set("mylint", "mylint", {
  { location = { uri = "paw://track/3" }, severity = "warning", message = "too loud",
    fixes = { { title = "Lower it", edit = { { uri = "paw://track/3", set = { volume = -6 } } } } } },
})
```

The older form for the notes of a clip still works:
`paw.diagnostic.set("mylint", clip, { { notes = { 3 }, message = "...", fixes = { { title, edits = { { note = 3, pitch = 72 } } } } } })`,
with notes by their place when published.

## MIDI LSP

`extensions/midilsp` is the entry of MIDI LSP, a language server for music:
its engine checks voice leading, counterpoint, ranges, rhythm and form, hears
chords and keys, and suggests melodies, velocities and controller curves; its
delivery and settings checks look at rendered masters.

```lua
paw.ext.load("/path/to/paw/extensions/midilsp")
```

The engine is found in `paw.opt.midilsp_cmd` (words, such as `"reaper-midi-lsp
--rules /home/me/rules"`), else `$MIDI_LSP_ENGINE`, else `reaper-midi-lsp`
on the PATH.
It is started when the extension loads (`paw.opt.midilsp_autostart`), as
two servers on clips in MIDI LSP's dialect: `midi-lsp`, the language role,
and `midi-lsp-suggest`, the suggestion role (`paw.opt.midilsp_suggest`).

With `paw.opt.midilsp_render_checks` (on by default) two one-shot servers
check every render, when their programs are installed beside the engine:

- `midilsp-delivery` runs `reaper-midi-lsp-delivery` on each WAV render:
  integrated loudness, true peak, clipping, the loudest passage and the
  loudness range, against `paw.opt.midilsp_delivery_target` (`spotify`,
  `ebu-r128`, or empty for information only). Too loud, or over the
  true-peak ceiling, comes with a fix that lowers the master by what is
  over.
- `midilsp-settings` runs `reaper-midi-lsp-settings` on the settings it
  reads from REAPER, made here from the render's options and the master's
  devices: a 16-bit render without dither (fixed by rendering again with
  dither), normalising on, a rate other than the project's (fixed by
  rendering again at it), a limiter on the master bypassed (fixed by
  switching it on) or not last. Its messages name REAPER's render dialog
  where this program has the render's options.

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
