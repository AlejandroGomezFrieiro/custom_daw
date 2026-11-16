# mixdiag

Mix diagnostics: the mix is measured, and what is wrong with it is reported
the way a language server reports problems in code, as a list of findings.
Each finding has a severity, a message with the number that caused it, what
would fix it, and a place (a track and a beat) that `]d` and `[d` jump to.

```lua
daw.ext.load("extensions/mixdiag")      -- or put it in ~/.config/daw/extensions
```

`,xa` measures the song (in visual mode, the selection), `,xx` lists the
findings, `]d` and `[d` go from one to the next in the arrange view.

## What is measured, and by which standard

The measuring is Rust, in `crates/daw-core/src/measure/`, and is open to any
script as `daw.api.measure*` (below). The project is rendered by a private
engine, the same way `daw.render` renders it, but into memory, on a worker
thread, and measured as it is rendered.

| Measurement | How | Standard |
| --- | --- | --- |
| Integrated loudness (LUFS) | K-weighting; 400 ms blocks every 100 ms; absolute gate -70 LUFS, relative gate -10 LU | ITU-R BS.1770-4, EBU R 128 |
| Momentary and short-term maximum | 400 ms and 3 s windows every 100 ms | EBU Tech 3341 |
| Loudness range (LRA) | 3 s windows, gates -70 LUFS and -20 LU, 95th minus 10th percentile | EBU Tech 3342 |
| True peak (dBTP) | 4x oversampling below 96 kHz, 2x above, with a 24-tap-per-phase Kaiser-windowed sinc interpolator | BS.1770-4 annex 2 (the method; the filter is our own) |
| Sample peak, clipped runs | runs of 3 or more samples at full scale (Audacity's default), or any sample over it; runs closer than 3 samples join | convention |
| DC offset | median of 1 s means per channel, and the 1 s means over time | none (MIDI LSP's convention) |
| Crest factor, peak-to-loudness ratio | sample peak over RMS; true peak minus integrated loudness | arithmetic |
| Correlation, width, side level | Pearson correlation of left and right; side energy over mid plus side | arithmetic |
| Mono-sum loss | K-weighted loudness of (L+R)/2 on both sides, over the blocks the stereo reading kept | arithmetic on BS.1770 |
| Spectral balance | Hann-windowed FFT of the mid signal, frames of about 1/6 s; energy share per octave band, IEC 61260-1 base-ten mid frequencies 31.5 Hz to 16 kHz, plus `sub` below and `air` above | the band layout is IEC's; no target curve |
| Per-track peaks | each track's post-fader meter, read every engine block (1024 samples) | |
| Series every 100 ms | momentary and short-term loudness, correlation (400 ms and per 100 ms), mono loss, sample and true peak; DC per second | |

### Checked against

Rust tests (`cargo test -p daw-core --lib measure`) generate the signals:

| Signal | Expected | Read |
| --- | --- | --- |
| K-weighting at 48 kHz | the coefficients printed in BS.1770-4 | equal to 1e-8 |
| 997 Hz stereo sine at -20 dBFS, 44.1, 48 and 96 kHz | -20.0 LUFS | -20.00 ± 0.02 |
| Tech 3341 case 1: 1 kHz stereo sine at -23 dBFS | -23.0 ± 0.1 (M, S, I) | -22.99 |
| case 2: the same at -33 dBFS | -33.0 | -32.99 |
| case 3: -36 / -23 / -36 dBFS for 10 / 60 / 10 s | -23.0 | -23.01 |
| case 4: -72 / -36 / -23 / -36 / -72 dBFS | -23.0 | -23.01 |
| case 5: -26 / -20 / -26 dBFS for 20 / 20.1 / 20 s | -23.0 | -22.98 |
| case 9: 1.34 s at -20 and 1.66 s at -30 dBFS, 20 times | short-term -23.0 throughout | -23.0 ± 0.1 at every point |
| a tone at -75 dBFS alone | gated out: no reading | none |
| Tech 3342 cases 1 to 4 (20 s steps of -20/-30, -20/-15, -40/-20, -50/-35/-20/-35/-50) | LRA 10, 5, 20, 15 ± 1 | 10.0, 5.0, 20.0, 15.0 |
| sine at fs/4, 45° phase, peak -6.02 dBFS | true peak -6.02, samples 3.01 dB lower | -6.02 dBTP, -9.03 dBFS |
| sine at fs/6, samples 30° from the crest | true peak -6.02, samples 1.25 dB lower | -6.02, -7.27 |
| fs/4 at 1.2 (an inter-sample over) | +1.58 dBTP with every sample under 0 dBFS | +1.58 dBTP, -1.43 dBFS |
| 5, 10, 15, 19 kHz at three phases, 44.1 and 48 kHz | within Tech 3341's +0.2 / -0.4 dB | worst error 0.003 dB |
| a 100 Hz sine cut flat at full scale for 1 s | 200 clipped runs | 200 |
| left side offset by 0.01 | DC 0.0100 | 0.0100 |
| identical, opposite and unrelated sides | correlation 1, -1, 0; mono loss 0, total, 3.01 dB | as expected |
| 1 kHz tone; 100 Hz and 4 kHz tones of equal level | all in the 1k band; -3.01 dB in each | as expected |

The extension's tests read a 16-bit WAV of a 1 kHz sine at -23 dBFS back
through `daw.api.measure` as -23 LUFS.

### How long it takes

A song of 5 minutes, 9 tracks of built-in synths, drums and delays, measured
in about 3 s in a debug build (the workspace's dev profile), where `daw.render`
of the same song alone takes most of that. The render and the analysis run on
two worker threads, a few pieces apart. The interface is held for about 1 ms
to set the engine up (more with plugins, which are instantiated afresh, as for
a render), a tenth of a millisecond per check on progress, and 2 ms to bring
the result (some 20 000 numbers) into Lua and run the rules. The analysis
alone runs at about 140 times real time.

## Findings

Severities are `error`, `warn`, `info` and `hint`. Each rule is a table in
`require("mixdiag").rules`, and its thresholds are fields that can be changed.

| Rule | Finds | Threshold | Severity |
| --- | --- | --- | --- |
| `silent` | the measured stretch never passes -60 dBFS | | error |
| `clip` | the master over full scale, with where, how many runs and samples, and how much to lower it | a run (above); runs within `merge` = 4 beats are one finding, at most `max` = 20 | error |
| `true_peak` | true peak over the target's ceiling (Spotify: -1, or -2 when louder than -14 LUFS; EBU: -1); with no target, over 0 dBTP while no sample clips | | error for a delivery target, else warn |
| `loudness` | EBU R 128: integrated loudness more than `tolerance` (1 LU) from -23 LUFS. Streaming: louder than -14 by more than `slack` (0.5 LU), with how much it is turned down; quieter, when the true peak stops the service raising it all the way, with how much quieter it plays | | error (EBU, whole song), info (streaming, or a stretch) |
| `track_over` | a track's post-fader output over full scale, where it first went over | 0 dBFS | warn when the master clips too, else info |
| `phase` | a passage with correlation under `floor` for at least `seconds`, while louder than `audible` | -0.2, 2 s, -50 LUFS | warn |
| `mono` | the whole stretch losing more than `limit` in mono, or cancelling completely | 4 dB (unrelated sides lose 3.0) | warn; error when it cancels |
| `dc` | DC offset over the whole render, or in a passage of `seconds` whole seconds whose means are over `limit` on one side of zero | 0.01 (-40 dBFS), 2 s | warn |
| `silence` | silence at the start of the render, or before its end (the tail added for releases not counted) | `start` 1 s, `ending` 2 s | info |
| `infrasonic` | the energy below the 31.5 Hz octave band (22 Hz) over `limit` of the total | -20 dB (1 %) | info |
| `forgotten` | a soloed track (the measurement heard only solos); a muted track with clips in the stretch; muted clips; bypassed devices; automation lanes switched off that have points | | warn for solo, else hint |
| `no_sound` | an unmuted track with clips in the stretch whose output never passed `floor` (no instrument, or a bypassed one) | -100 dBFS | hint |

Rules about delivery (`loudness`, `true_peak`) speak only in the frame of the
chosen target; with the target `none` loudness is reported as numbers, not as
findings. When a track's contribution is measured, they are left out.

## Keys and commands

| Keys | Command | |
| --- | --- | --- |
| `<leader>xa` | `mix.analyze` | measure the song; in visual mode the selection |
| `<leader>xl` | `mix.analyze loop` | the loop |
| `<leader>xk` | `mix.analyze track` | the cursor track's contribution: the song with that track as if soloed |
| `<leader>xx` | `mix.list` | the findings, in `daw.pick` when there is one, else in the report |
| `<leader>xr` | `mix.report` | the report: what was measured (or how far a measurement has got), the numbers, the findings by severity and the target; `j` `k` choose a finding, Enter goes there, `a` measures the song, `l` the loop, `t` the cursor's track, `T` the next target, `q` closes |
| `<leader>xs` | `mix.summary` | LUFS, true peak, LRA, short-term maximum and mono loss of the last measurement |
| `<leader>xt` | `mix.target [name]` | the next delivery target, or the one named |
| `<leader>xc` | `mix.clear` | forget the findings |
| `<leader>xq` | `mix.cancel` | stop a measurement that is running |
| `]d` `[d` | `mix.next` `mix.prev` | in the arrange view: the next and previous finding (a count goes further; they wrap), its message shown; `<C-o>` comes back |
| | `mix.file path` | measure an audio file |

When a measurement finishes, its summary line is shown as a message, and a
row above the arrange view marks each finding with `E`, `W`, `I` or `H` at its
beat, lined up with the timeline; it says `measuring 40%` while it runs and
`(old)` once the project has changed since.

In the graphical frontend the report opens in a window of its own (More ▸
Mix report, or `:view.window mixdiag`), where it stays open while Enter or a
second click on a finding goes to it, and the findings that have a place are
flags in a band under the ruler, in the colour of their severity: a click on
one goes there.

## Options

| Option | Default | |
| --- | --- | --- |
| `mixdiag_target` | `"streaming"` | `streaming` (-14 LUFS, -1 dBTP; Spotify's page), `ebu` (-23 ± 1 LUFS, -1 dBTP; EBU R 128 v5), `none`, or one of your own |
| `mixdiag_tail` | `1` | seconds measured after the end, for releases and echoes |
| `mixdiag_ignore` | `""` | rules to skip, by name: `"silence,forgotten"` |
| `mixdiag_strip` | `true` | the row of marks above the arrange view |

## The Lua module

```lua
local mixdiag = require("mixdiag")          -- also package.loaded["daw.mixdiag"]

mixdiag.analyze("song")                     -- or "loop", "selection", "track",
                                            -- { start = 0, ["end"] = 32, track = id }, { file = "x.wav" }
mixdiag.analyze("loop", { done = function(findings) end })
local findings = mixdiag.analyze("song", { wait = true })   -- block until measured
mixdiag.findings      -- { severity, message, fix, beat, track, seconds, rule }
mixdiag.result        -- the measurement (below)
mixdiag.summary()     -- "LUFS -14.2  TP -1.3 dBTP  LRA 6.1 LU  …"
mixdiag.marks()       -- { beat, severity, text, track } for a ruler to draw
mixdiag.step(1)       -- what ]d does
mixdiag.list()  mixdiag.clear()  mixdiag.cancel()  mixdiag.stale()

-- A rule of your own:
mixdiag.rules.too_wide = {
  desc = "Side louder than mid",
  check = function(ctx, add, rule)
    if ctx.result.side > 0 then
      add({ severity = "info", message = string.format("side %.1f dB over mid", ctx.result.side),
            fix = "narrow the widest parts", beat = ctx.range.start, track = 0 })
    end
  end,
}
-- A target of your own:
mixdiag.targets.album = { name = "my album", kind = "deliver", integrated = -16, tolerance = 1, true_peak = -1 }
```

A rule's `ctx` has `result`, `range` (`start`, `end`, `label`, `track`),
`kind` (`mix`, `track` or `file`), `whole` (the whole song or file), `target`,
and the helpers `beat(seconds)`, `where(beat, seconds)` and `track_name(id)`.
`mixdiag.done` is emitted when findings are ready.

### `daw.api.measure`

```lua
daw.api.measure({ start = 0, ["end"] = 64, tail = 1, sample_rate = 48000, track = id })  -- waits
daw.api.measure({ file = "master.wav" })
local id = daw.api.measure_start(opts)          -- on a worker thread
daw.api.measure_poll(id)    -- { done = false, progress = 0.4, elapsed } or { done = true, result | error }
daw.api.measure_cancel(id)
```

The result: `integrated`, `momentary_max`, `short_term_max`, `lra`, `lra_low`,
`lra_high`, `mono_integrated` (LUFS, nil when nothing passes the gates);
`true_peak`, `true_peak_at`, `sample_peak`, `sample_peak_at` (dB, seconds);
`plr`, `crest`, `rms`; `clipped_samples`, `over_samples`, `clip_runs`, `runs`
(`{ at, frames, peak }`, the first 2000); `dc`, `dc_mean` (`{ left, right }`,
linear); `correlation`, `width`, `side`, `mono_loss`; `sound_start`,
`sound_end`; `bands` (`{ name, low, high, share }`); `tracks` (`{ id, peak,
peak_at, over_at }`); `series` (`hop`, `momentary`, `short_term`,
`correlation`, `correlation_hop`, `mono_loss`, `sample_peak`, `true_peak`,
`dc_left`, `dc_right`), where point `i` describes the window ending at
`(i + 1) * hop` seconds and `-150` means silence; and `sample_rate`, `frames`,
`seconds`, `elapsed`, and for a project `start` (beat), `end`, `tail`,
`tempo`, `track`, `edits`. Times are seconds from the start of the
measurement; `start + seconds * tempo / 60` is the beat.

## Not done

- Per-track loudness, correlation and spectrum: tracks give only their peak.
  A track's own numbers come from measuring its contribution (`,xk`), one
  render per track.
- Which track causes a DC offset, a phase problem or infrasonic energy: the
  mix is measured, so these point at a time, not at a track.
- Sends: a track's contribution includes what its solo path to the master
  carries, which leaves out effect returns fed by its sends.
- A spectrum compared with reference tracks; no target curves are shipped,
  deliberately.
- Tempo changes (the DAW has none yet), and integer-render settings: the
  measurement is of the floating-point mix, before any dither.
- Mono files are read as two identical channels, so they measure 3 dB louder
  than a mono-aware meter would read them.
- Fixes are advice only; nothing in the project is changed.
- Every number is only as current as the measurement, which is not redone
  by itself after edits: `(old)` and `mix.summary` say when the project has
  changed since.
- Plugins on the worker thread are tested with LSP's stereo limiter in all
  three formats (its peak matches a render's); other plugins that insist on
  one audio thread are not tried.
