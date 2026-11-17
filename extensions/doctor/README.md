# doctor: a guided check of the real hardware

Most of this program has been tried against stand-ins: the null audio
backend, injected MIDI, plugins in a test set. The doctor is for the real
thing. It walks through a list of checks. Each one is started, watched or
listened to by you, and answered ("heard it", "did not", skip), or measures by
itself. What was found is kept, and at the end a report is written as
Markdown, with the machine's facts at the top and, when an earlier report
exists, what changed since.

```
:doctor              open the page: the checks, how each went, the question being asked
:doctor all          run every check
:doctor input        run one (by name or number); :doctor unattended runs those that need nobody
:doctor stop         end a run, tidy up, write the report
:doctor report       where the last report is
daw doctor           from the shell: the checks that need nobody, report on standard output
```

Load it in `init.lua` (`config/init.lua` has the line) or with
`daw.ext.load("/path/to/daw/extensions/doctor")`. `daw doctor` needs neither:
it loads the extension from the source tree beside the binary, or from
`$DAW_HOME`.

The page floats over the terminal; in the window the same page is painted in
pixels, with buttons for what the keys do and a button for each answer.

| Key on the page | What it does |
| --- | --- |
| `j` `k` | the check under the cursor |
| `<CR>` | run it |
| `A` | run every check; `u` those that need nobody |
| `y` `n` `s` `w` `r` `l` `b` `a` `d` | answer the question being asked (the keys are listed under it); `s` also skips the check going on |
| `o` | where the report is |
| `<Esc>` | stop the run; the page stays (`q` closes it) |
| `q` | close the page |

## What each check needs from you

| Check | What you do | Without anybody |
| --- | --- | --- |
| 1. The sound system | nothing | runs |
| 2. Output | listen to a gentle tone (-18 dB), a second each on the left, the right and both; say whether and where you heard it, or play it again | not run |
| 3. Input levels | play or speak into each input; the level of each channel is shown live, and the loudest each reached is kept; press `d` when done. A channel that stayed silent is named | listens for three seconds |
| 4. Round trip latency | connect an output to an input with a cable, or let a microphone hear the speakers (the click is loud: turn the volume down); say yes. Three clicks are played and recorded; the median delay is measured and the recording offset (`daw.transport.record_offset`) offered | not run |
| 5. Dropouts | nothing: a song of many synth voices plays for twenty seconds (`daw.opt.doctor_seconds`), then again while a long sound file is read from the disk. Counts of xruns and late plugin blocks, the CPU load and how long a block took are reported for both | runs |
| 6. MIDI input | press a key, then move a knob or fader, within twenty seconds each; the port, channel, note and controller that arrived are recorded | lists the ports |
| 7. Recording | play or speak for four seconds while a track records from the first input (the first pair, if there are two); the take is played back, its peak shown, and you say whether you heard it | records what arrives, and says if it is silent |
| 8. Plugins | nothing, unless a plugin you named is silent: it offers to open its editor, which some instruments need once before they sound | runs |
| 9. The environment | nothing | runs |

Every wait has a limit and every question a timeout (a question nobody
answers is a skipped one); `s` skips the check going on and `<Esc>` ends the
run. A check that raises an error is reported as failed with the error, and
the run goes on.

### What they look at

1. **The sound system**: the backend, the output and input chosen and every
   one found (`daw.audio.devices()`), the sample rate, the block, the latencies
   reported (`daw.api.engine_get()`). It warns about the traps known so far:
   a Bluetooth output (its latency is high; headphones that are the system's
   default catch everything), an output latency over 80 ms, the interface
   connected but not the output in use, a device whose own sample rate is
   not the program's, a block over 25 ms, no input open, and the null
   backend.
2. **Output**: a tone made for the check, played from a track of its own.
3. **Input levels**: `daw.audio.levels()` sampled every few hundredths of a
   second. Below -60 dBFS counts as silent; a channel that reached full scale
   is warned about.
4. **Round trip latency**: a track plays a click, a muted track armed on the
   first input records, and the click's place in the take is found. What the
   program already takes off a take (what the audio system reports, plus the
   offset) is subtracted, and what is left is added to the offset, if you say
   so. It is set for this session; the report says what to put in
   `init.lua` to keep it. A tone or noise that was there before the click
   was played is told apart from a loop-back, and so is silence.
5. **Dropouts**: `xruns`, `late_blocks`, MIDI events dropped and the CPU load
   from `daw.api.engine_get()`, with `engine_reset_stats` before each run.
   The long file is a quiet tone written for the check, long enough that
   its decoded sound is past `daw.opt.media_stream`; it is brought in and
   played, and `daw.media.list()` says whether it was read from the disk.
   The decoded copy stays in `~/.cache/daw/media`, where the cache's own limit
   takes care of it.
6. **MIDI input**: the ports from `daw.midi.inputs()`, and the `midi.in`
   events, which name the port they came from.
7. **Recording**: the take's file is read back for its peak per channel, its
   length and its format.
8. **Plugins**: how many of each format the scan found, and what the scan
   said about files it could not use (the log lines "plugin scan: …"). For
   each name fragment in `daw.opt.doctor_plugins` (`{ "MT-PowerDrumKit",
   "Ugritone" }`), a plugin whose name has it is loaded on a track, sent five
   notes (a drum plugin plays kick, snare, hat and more), and the track's
   meter says whether sound came out. Windows plugins through yabridge are
   named the same way. A plugin that does not start, is not installed or is
   silent is said so, with the known fact that some need their editor
   opened once (`ge` on the track).
9. **The environment**: `DISPLAY`, `WAYLAND_DISPLAY` and `XAUTHORITY` as the
   program sees them (after it has put a stale display name right), whether
   the sockets and the authority file are there, the free space where
   recordings go, whether `ffmpeg` and `gdi2m` are on the `PATH`, the
   kernel's version, `daw.api.limit_async` and the engine's threads.

## Your project is not touched

A check needs tracks, clips and recordings of its own. The doctor does not
add them to your project and take them away: that would leave steps in its
undo history and move things. When a check first needs one, your project is
put aside whole, with its undo tree, its transport and its changed flag
(`daw.api.project_shelve`), and an empty scratch project opens in its place;
when the run ends, however it ends, the scratch project is closed and yours
comes back exactly as it was, down to the playhead. The checks that only
look (1, 3, 6, 9, and 8 with nothing named) never put anything aside.

While your project is aside a copy of it is kept in `doctor/open-project.json`
in the state directory, and removed when it is back. If the program dies in
between, that file is the project: open it with `:edit`. Autosave is turned
off for the run, since a safety copy of the scratch project would take the
place of yours, and turned on again after. Plugins on your tracks are
stopped while the project is aside and started again when it is back.

Everything a check adds goes when it ends, also when it is cancelled and when
it fails: its tracks, the files it wrote, the take it recorded.

## The report

`<state directory>/doctor/<year-month-day-time>.md`, with the same data as
`.json` beside it for the next report to compare with. At the top the
machine: program, kernel, system, processor, memory, sound system, devices,
rate, block, display, configuration. Then a table of the checks and a
section on each with what was found. Under "Changed since the report of
…" are the machine's facts and each check's findings that differ from the
last report: a device that went, a rate that moved, a plugin that stopped
sounding. Measurements that are never the same twice (peaks, CPU, latency)
are reported but not compared.

`daw doctor` takes `--seconds 20` (the length of the dropout runs),
`--plugin MT-PowerDrumKit` (repeatable; else `daw.opt.doctor_plugins`),
`--only system,plugins`, and the program's audio options (`--audio`,
`--output`, `--input`, `--buffer`, `--rate`). Unlike other scripts it opens
the sound device, since that is what it looks at; it makes sound while it
runs. It exits with 1 if a check failed.

## Adding a check

A check is a table in `require("doctor").checks`. Add it from your
`init.lua` or an extension, after the doctor is loaded:

```lua
table.insert(require("doctor").checks, {
  name = "Footswitch",                       -- shown in the list and the report
  help = "Press the footswitch once.",       -- what it needs from the person
  unattended = false,                        -- true if it can run with nobody there
  limit = 60,                                -- seconds before it is stopped (120 by default)
  run = function(ctx)
    local pressed = false
    local handler = daw.on("midi.in", function(e) if e.type == "cc" and e.number == 64 then pressed = true end end)
    ctx:cleanup(function() daw.off(handler) end)
    ctx:ask("Press the footswitch.", { { "s", "skip" } }, { timeout = 15, done = function() return pressed end, default = "timeout" })
    if not pressed then return "fail", "no pedal message arrived" end
    ctx:fact("pedal", "sustain")
    return "ok", "the footswitch sends sustain"
  end,
})
```

`run(ctx)` returns `"ok"`, `"warn"`, `"fail"` or `"skip"` and a sentence. It
runs in a coroutine woken from a timer, so it waits with the context's
functions and never with a loop of its own that does not yield:

| `ctx:` | |
| --- | --- |
| `say(text)` | a line shown while it works |
| `log(text)`, `warn(text)` | a line for the report; a warning turns "ok" into "warn" |
| `fact(key, value)`, `measure(key, value)` | what was found: compared with the last report, or only reported |
| `sleep(ms)`, `wait_for(fn, ms)` | let time pass; until `fn()`, true or false |
| `ask(question, choices, opts)` | ask for a key: `{ { "y", "yes" }, ... }`; returns the key, `"skip"` when nobody is there, `opts.default` on timeout, `"done"` when `opts.done()` is true; `opts.each()` is called while waiting |
| `track(opts)` | a track in the scratch project, removed when the check ends |
| `file(path)`, `dir()` | a file to delete, a directory of the run's own |
| `cleanup(fn)` | run `fn` when the check ends, however it ends |
| `play(beat, seconds)`, `stop()` | play the scratch project; stop it |
| `attended()` | whether a person is there |

An error raised inside a check ends it as failed. A `pcall` inside one must
pass on an error that is a table (the doctor ends a cancelled or timed-out
check with one).

## What it cannot do

It has been run on the null backend only, where a test input gives two
channels of tone and `daw.midi.inject` stands in for a controller. The
hardware paths (a Bluetooth output, a UR22mkII, PipeWire's own latency, a
loop-back cable, real plugin windows) are written from the program's own
reports and have not been run against the devices themselves.
