# Results

This DAW (branch `stress` after merging `main` at 3e0867f) against Tracktion
Engine 3.5.0 (commit c629312, JUCE 7ff644f), on the workloads both can run.
How to run everything: [README.md](README.md). Raw numbers:
`results/final.jsonl` (after the merge) and `results/premerge.jsonl` (the same
matrix before it).

## Since then: several threads, and one note at a time

The two largest weaknesses below were taken up after these results were
written. The engine now processes tracks that do not feed each other on a
pool of worker threads (one thread per core by default; renders are
bit-identical whatever the number), and `daw.api` has calls for one note
(`clip_note_set`, `clip_note_add`, `clip_note_remove`, `clip_notes_edit`),
which the piano roll and the graphical frontend use. Measured on the same
machine, under load from other jobs (load average 5 to 15), each figure the
median of three interleaved runs; "before" is the build these results were
taken from. As everywhere here, the synth rows compare synths more than
engines.

| Render (32 s of audio) | 1 thread | 12 threads | Tracktion, 24 threads |
| --- | ---: | ---: | ---: |
| 100 audio tracks | 1.59 s | 0.44 s | 2.04 s |
| 500 audio tracks + delay + automation | 8.6 s | 2.5 s | 9.5 s |
| 100 synth tracks + delay | 6.7 s | 1.15 s | 7.9 s |
| 500 synth tracks + delay + automation | 34.0 s | 5.5 s | 36.2 s |

On one thread the times are what they were before the change, within the
noise of this machine (interleaved with the old build: 1.77 against 1.79 s
for 100 audio tracks, 7.1 against 7.4 s for 500).

| Playing live (null backend), worst block | 1 thread | 4 threads | 12 threads | Budget |
| --- | ---: | ---: | ---: | ---: |
| 100 synth tracks, 128 frames | 2.08 ms | 0.79 ms | 0.49 ms | 2.67 ms |
| 500 audio tracks + delay, 256 frames | 5.29 ms | 1.95 ms | 1.53 ms | 5.33 ms |
| 500 synth tracks + delay, 512 frames | 26.3 ms | 7.9 ms | 3.8 ms | 10.7 ms |

| Editing notes, each edit an undo step and a sync | Before | Now | Tracktion |
| --- | ---: | ---: | ---: |
| 1000 note moves in a 1000-note clip | 700 ms | 33 ms | 1.8 ms |
| the same without the sync to the engine | 870 ms | 12.6 ms | |
| 1000 note deletes | 360 ms | 18 ms | |
| 5000 note moves in a 5000-note clip | 17.3 s | 0.54 s | |

What that leaves: a note edit still costs in proportion to the clip (33 µs at
1000 notes, 108 µs at 5000), because the clip is copied for undo and compiled
again for the engine; Tracktion's 2 µs per note leaves out its graph rebuild.
With several threads the adding-up of what tracks send on is still done on
one, which is what limits 100 plain audio tracks to 3.6 times faster on 12
threads. The audio callback of the PipeWire backend was found to run without
real-time priority on this machine (the workers match it, so they do not
either); the path where a real-time callback's workers become real-time is
covered by a test, not by a real device.

## Machine and method

- AMD Ryzen AI 9 HX 370 (12 cores, 24 threads), 32 GB, NixOS, Linux 7.3.1
  PREEMPT_RT. rustc 1.95.0 (release, thin LTO, baseline x86-64); Tracktion with
  GCC 15.3, `-O3` (JUCE's recommended release flags), no `-march`, no LTO.
- **The machine was shared.** Other builds ran during most measurements (load
  average 4–40 on 24 threads). Each configuration ran 3 times and the tables
  show the median; before/after comparisons of my own changes use the minimum
  of 3–5 interleaved runs. Expect ±15% noise in single numbers; differences
  smaller than that are not findings.
- Both engines: 48 kHz, 512-frame blocks for offline renders, 120 BPM, 4/4,
  24-bit WAV output, the same 2 s 48 kHz WAV for audio clips, the same notes
  (per bar a 4-note chord and 8 eighth notes) for MIDI.
- **Threads.** This DAW rendered and played on one thread when these were
  measured (see the section above for what it does now). Tracktion is run
  twice: limited to the calling thread (`×1`, `getNumberOfCPUsToUseForAudio`
  = 1) and with all 24 (`×N`). For renders Tracktion's default is N.
- **What each engine does differs:**
  - *Synths.* MIDI goes through each engine's own synth: this DAW's `synth`
    (one band-limited oscillator, a state-variable low-pass, an ADSR, 16
    voices) and Tracktion's 4OSC set as close as it goes (one saw oscillator,
    a low-pass, 16 voices, effects off). 4OSC still does far more per voice
    (four oscillator slots, two filters' worth of envelopes, LFOs, the
    modulation matrix), so **the MIDI rows compare synths more than engines**.
  - *Effects.* `delay` against Tracktion's `DelayPlugin`, both stereo
    feedback delays. Each Tracktion track also carries its default
    volume/pan and level meter plugins; this DAW's fader is built in.
  - *Render overhead.* Tracktion reads audio files through a background
    reader and writes through a threaded writer; its render waits for the
    reader, which gives it a floor of about 0.5 s on any render and blocks
    of ~10 ms in its per-block numbers (`block_p99` ≈ 10 ms at every size).
    This DAW decodes files into memory when a clip is added and writes the
    file on the render thread (its `render_ms` includes the writing).
  - *Editing.* Every DAW edit here is a "turn" as the UI makes it: the
    change, the sync to the engine, the change events, an undo step.
    Tracktion's edit calls change its model and undo history only; it
    rebuilds its playback graph later on its message loop, which the driver
    never runs. The "without the sync" tables measure the DAW the same way.
  - *Real time.* The DAW's per-callback times come from its engine's own
    histogram while the null backend calls it on a real-time clock (a plain,
    not real-time-priority, thread). Tracktion's come from timing
    `HostedAudioDeviceInterface::processBlock` called back to back. Neither is
    a real audio device.
- **Tracktion limits.** By default an edit holds at most 400 tracks and a
  track 1500 clips, and `Edit::ensureNumberOfAudioTracks` loops forever when
  it reaches the track limit (it hung the first 400-track runs). The driver
  raises both limits through `EngineBehaviour::getEditLimits`.
- Not run: 500 tracks of 4OSC on one Tracktion thread (over 4 minutes per
  run); plugin hosting on either side (the DAW's CLAP/LV2/VST3 paths are
  covered by its test suite, not benchmarked).

## Headline

| Workload | This DAW (1 thread) | Tracktion ×1 | Tracktion ×N |
| --- | ---: | ---: | ---: |
| Render 100 audio tracks, 32 s | 1.72 s | 3.61 s | 2.35 s |
| Render 500 audio tracks + delay + automation | 9.8 s | 34.3 s | 9.6 s |
| Render 100 synth tracks (different synths) | 6.2 s | 45.4 s | 7.1 s |
| Worst block, 100 synth tracks at 128 frames (budget 2.67 ms) | 1.68 ms | 14.1 ms | 5.7 ms |
| Save / load 500 tracks × 8 clips | 16 / 64 ms | 296 / 520 ms | |
| Resident memory, 500 tracks × 8 clips | 170 MB | 499 MB | |
| Start (no plugins) | 15 ms | 117 ms | |
| 1000 clip moves, each an undo step (DAW without / with the engine sync) | 12 / 50 ms | 3.5 ms | |
| 1000 note moves in a 1000-note clip (DAW, with or without the sync) | 0.6–0.9 s | 1.8 ms | |

Where it wins: rendering audio clips (single-threaded, it beats Tracktion
on 24 threads up to 100 tracks and ties at 500 with effects), small renders
(no 0.5 s floor), saving, loading, memory,
start-up. Where it loses: editing, by 3–15× for clips and by two to three
orders of magnitude for single notes (see "What remains").


## Before and after my changes

Original build (aff0862) against the final one, same machine, minimum of 3–5
interleaved runs unless noted. Renders are bit-identical before and after for
every performance change (checked by hashing renders of all four synth waves,
the drums and delays).

| Change | Workload | Before | After |
| --- | --- | ---: | ---: |
| Delay wraps without `%` | 500 audio tracks + delay + automation, render | 8.53 s | 7.03 s |
| Synth/drums phase without libm; wave chosen per voice (+ delay) | 100 synth tracks + delay + automation, render | 6.58 s | 5.63 s |
| Synth/drums alone | all four waves + drums, engine time | 226 ms | 185 ms |
| Delay alone | the same with a delay per synth | 199 ms | 132 ms |
| Notes read and written directly | 1000 note moves in a 1000-note clip | 1.25 s | 0.60 s |
| Per-clip event cache, pointer diff | sync per clip move, 1000 clips × 12 notes on a track | 167 µs | 139 µs |
| LV2 scan cached | start with LSP Plugins + Surge XT, warm cache | 1180 ms | 15 ms |
| `routing_of`/solo in one pass | one volume change, 1000-track project | 0.44 ms | 0.55 ms ¹ |
| Denormals off for null backend and renders | 20 synths into delays, 120 s tail | 1.51 s | 1.50 s ² |

¹ No gain: the quadratic parts were not what dominated at 1000 tracks (the
per-sync hash maps over every track and device are), and the final tree,
which includes the merged work (undo tree, autosave, latency compensation,
MIDI 2.0), is about 20% slower than the original here. I did not find out
which part.
² With the built-in devices a signal spends very little time in the denormal
range; the change makes the null backend and renders behave like the cpal
callback, which already set the flag, and matters for plugins' tails.

**The merge.** Comparing `premerge.jsonl` and `final.jsonl`: audio renders
without effects 1518 → 1723 ms (100 tracks) and 5977 → 6119 ms (500 tracks),
per-block p99 0.72 ms at 100 tracks in both, real-time 500-track p50 2.05 ms in
both. Those are within the noise, so the per-route delay lines and fade checks
added on the audio path made no measurable difference. Rows with the delay
are faster after (13.1 → 9.8 s at 500 tracks) because of the delay change
above.

## Defects found and fixed

Each has a test in `tests/suite.lua` or a Rust test that fails on the code before the fix (checked by building the original commit in a scratch copy), unless marked as a performance change, which has before/after numbers instead.

| # | Defect | Found by | Fix |
|---|---|---|---|
| 1 | Saving and loading changed numbers in the last bit (serde_json's default float parser is not exact) | fuzzer, save/load invariant | `float_roundtrip` feature; suite: "saving and loading keeps every number exactly" |
| 2 | NaN and infinity accepted by `track_add` (volume, pan), `device_set_param`, note start/length, clip gain/offset, live and injected note velocities. Saved as `null`, so the project file no longer loaded; NaN velocities and parameters made the audio NaN (meters read 0, because `max` skips NaN) | fuzzer, abuse cases | refused with a message; suite: "numbers that are not finite are refused" |
| 3 | A note with a negative or zero length played its note-off before its note-on: a stuck note. Pitches up to 255 were accepted | abuse cases, review | refused |
| 4 | Project files were not checked: a tempo of 0 made every render run forever (hang, disk filling); negative tempo, a time signature of 0, negative clip lengths, duplicate ids, a track routed into itself, routing loops, out-of-range volumes all loaded | abuse cases | `Project::validate` on load, the file is refused whole with the reason; suite: "a damaged project file is refused whole" |
| 5 | `render` with a huge tail or end ran forever; past 4 GiB a WAV header overflows. A sample rate of 0 panicked inside device set-up (mlua turned it into an error); 4 GHz aborted the process (out of memory); an engine buffer of 1e9 frames hung | abuse cases | sample rates 8000–384000, buffers 16–16384, renders that fit a WAV file; suite: "renders and engines refuse sizes and rates they cannot do" |
| 6 | Loops through sends were accepted (`would_cycle` only followed outputs); the engine then silently dropped one side | review, then test | `would_cycle` follows outputs and sends; suite: "sends cannot make a loop either" |
| 7 | A refused edit still made an (empty) undo step and marked the project modified: the next undo did nothing | review, then test | only successful edits count; suite: "a refused edit leaves no undo step behind" |
| 8 | A track added past the engine's 1024-track limit never got a slot, even after tracks were removed; adding a device to it failed with "could not load `synth`" | abuse cases | a slot-less track is built when there is room, and the schedule rebuilt; suite: "a track the engine had no room for sounds once there is room" |
| 9 | Replacing one track's clips while playing (any clip edit) sent all-notes-off and re-triggered every held note on every track: every edit made every sustained note in the project swell | review, then test | the flush and chase are per track; `crates/daw-engine/tests/clips.rs` |
| 10 | An audio clip gain of 1e9 dB (finite, so accepted) rendered as infinity; a send level of 1e9 was saved into a file that the new validation refused; parameter values and parameter-lane points from a file reached devices unclamped | fuzzer (seeds 4 and 11) | gains and sends clamped like volumes, files checked, parameter values clamped to their declared range in sync; suite: "levels are kept within range" |
| 11 | `device_get` right after an undo that brought a device back reported it as missing, with no parameters, until the end of the turn | fuzzer (seeds 11 and 14) | `device_get` syncs first; suite: "a device brought back by undo reads as loaded at once" |
| 12 | The null backend and offline renders did not treat denormals as zero, unlike the cpal callback | review | same flag on both (scoped for renders, restored afterwards); no measurable speed change with the built-in devices; suite checks the main thread's float mode is restored |
| P1 | `sync` did O(tracks²) work on every edit (routing existence checks, solo paths) | `edit.lua scale` | hash sets, one pass |
| P2 | Every clip edit recompiled and re-sorted every note of the track, and hashed every clip twice | `edit.lua clips`, profiling | per-clip compiled events cached; pointer diff |
| P3 | Note lists crossed into and out of Lua through serde (views ask for them every frame) | `edit.lua notes` | built and read directly, serde as fallback with identical errors |
| P4 | `f32::fract` is a libm call per sample in the synth and drums | profiling by hand | inline truncation, bit-identical output |
| P5 | The LV2 scan was not cached: 1.2 s at every start with plugins | `startup.sh` | cached with bundle modification times; plugins looked up lazily |

Also found, in Tracktion: `Edit::ensureNumberOfAudioTracks` never returns once
an edit reaches its 400-track limit.

Observed, not changed: with the merged undo tree, once more than 1000 states
exist the oldest are pruned but the opened project is kept, so the undo that
reaches the end of the kept window jumps straight back to the project as it
was opened (in `edit.lua`, from 502 clips to none in one undo). That is the
documented pruning rule; it is a large silent jump for a user.

## Reliability runs

- **Fuzzer**: after the last fix, seeds 1–12 × 1500 steps on the merged code
  and seeds 13–20 × 1500 steps before the merge ran clean: about 30% of calls are refused cleanly, about
  200 undo/redo round trips, 30 save/load round trips and 30 double renders per
  seed, all identical; no panic, no non-finite sample.
- **Abuse cases** (`abuse.sh`, 42 cases): none crash, hang or leave a broken
  project; every bad input is refused with a message. Before the fixes: 4
  hangs, 1 abort (out of memory), 2 panics, 5 projects that saved but would not
  load.
- **Allocation guard** (`crates/daw-engine/tests/no_alloc.rs`): no allocation
  or free on the audio thread across every engine message, every built-in
  device, recording, loops, seeks, live and injected MIDI, and a full garbage
  queue (which leaks rather than frees, as designed). Passes after the merge
  too, with its latency delay lines, fades and MIDI 2.0 events. Not covered:
  the CLAP, LV2 and VST3 hosting paths (a counting allocator cannot tell the
  host's allocations from the plugin's); by reading, their event lists are
  bounded by capacity.
- **Soak**: 12 minutes, 40 synth+delay tracks with automation, an edit every
  10 ms (70 518 edits: clip moves, notes, parameters, whole tracks replaced,
  undo, redo): no dropouts counted, nothing leaked from the audio thread,
  p99 2.0 ms of a 5.33 ms budget, and resident memory levels off at 48 MB once
  the undo history is full. One block took 10.2 ms; with the machine at
  load ~15 and the null backend on an ordinary thread I cannot tell whether
  that was the engine or the scheduler. After the merge, 3 minutes: worst
  block 2.07 ms.
- **Memory churn** (30 rounds of build, edit, undo, render, save, load): levels
  off after the first rounds (59.3 → 59.6 MB over the second half).

## What remains slower or weaker

- **Editing notes.** There is no call for one note: the piano roll reads all
  of a clip's notes into Lua, changes one, and writes them all back, and each
  edit copies the clip for undo and recompiles it for the engine. A note move
  in a 1000-note clip costs about 0.6 ms against Tracktion's 2 µs per note
  object; at 5000 notes, 3 ms. A per-note call (`clip_note_set` and so on)
  would remove the Lua round trip, but the views would have to use it.
- **Editing clips on a long track.** Copy-on-write copies the track's list of
  clips on every edit and the sync recompiles the track's event list, so a
  clip edit costs O(clips on the track): 0.05 ms at 1000 clips, 0.25–0.75 ms at
  5000, against Tracktion's 5–30 µs (without its deferred graph rebuild).
  Without the sync the DAW is 3–10× slower than Tracktion for moves and
  deletes, even for adds; its undo is much cheaper (0.5 ms for 998 steps
  against 214 ms for 15 000).
- **Edits in very large projects.** Each sync builds hash maps over every
  track and device: 0.55 ms per edit at 1000 tracks, and building a 1000-track
  project one call at a time takes over a second.
- **One thread.** Renders and playback use one core. Up to 100 audio tracks the
  DAW still beats Tracktion on 24 threads; at 500 tracks with effects they tie
  (9.8 s against 9.6 s), and for 500 synth tracks the DAW is close to its
  real-time limit at 512 frames (block max 17–22 ms against a 10.7 ms budget,
  i.e. it could not play that project live) while Tracktion on 24 threads has
  the same problem with a much heavier synth. Rendering independent tracks on
  several threads, with summing kept in a fixed order so that renders stay
  bit-identical, would fix both; it was not done, because the numbers did not
  require it for the comparison and `Engine::segment` was being changed in
  parallel (delay compensation, pre-fader sends).
- **The delay device** allocates 2 s of both channels per instance (768 kB at
  48 kHz), which is most of the resident memory of large projects.
- **MIDI comparison.** The synths differ too much for the MIDI rows to say
  which engine is faster at playing MIDI; they say this DAW's synth is much
  cheaper than 4OSC.

## Full tables (after the merge)


### Offline render (ms of wall time for 32 s of audio)

| kind | fx | automation | tracks | daw×1 render_ms | tracktion×1 render_ms | tracktion×N render_ms |
| --- | --- | --- | --- | ---: | ---: | ---: |
| audio | 0 | 0 | 1 | 48.4 | 555 | 543 |
| audio | 0 | 0 | 10 | 180 | 794 | 719 |
| audio | 0 | 0 | 100 | 1723 | 3606 | 2350 |
| audio | 0 | 0 | 500 | 6119 | 19711 | 7911 |
| audio | 1 | 1 | 1 | 56.8 | 561 | 557 |
| audio | 1 | 1 | 10 | 242 | 916 | 754 |
| audio | 1 | 1 | 100 | 1860 | 4900 | 2724 |
| audio | 1 | 1 | 500 | 9825 | 34257 | 9634 |
| midi | 0 | 0 | 1 | 87.0 | 994 | 985 |
| midi | 0 | 0 | 10 | 805 | 5437 | 1563 |
| midi | 0 | 0 | 100 | 6195 | 45354 | 7146 |
| midi | 0 | 0 | 500 | 30796 | – | 34127 |
| midi | 1 | 0 | 1 | 120 | 914 | 1025 |
| midi | 1 | 0 | 10 | 862 | 4675 | 1580 |
| midi | 1 | 0 | 100 | 5665 | 49915 | 7950 |
| midi | 1 | 0 | 500 | 34501 | – | 37330 |
| midi | 1 | 1 | 1 | 117 | 971 | 934 |
| midi | 1 | 1 | 10 | 685 | 4771 | 1588 |
| midi | 1 | 1 | 100 | 6639 | 53787 | 7604 |
| midi | 1 | 1 | 500 | 33619 | – | 36599 |

### Offline render, per-block processing time (ms; budget 10.7 ms)

| kind | fx | automation | tracks | daw block_p99_ms | daw block_max_ms | tracktion×1 block_p99_ms | tracktion×1 block_max_ms | tracktion×N block_p99_ms | tracktion×N block_max_ms |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| audio | 0 | 0 | 1 | 0.013 | 0.028 | 10.1 | 11.4 | 10.1 | 11.2 |
| audio | 0 | 0 | 10 | 0.076 | 0.11 | 10.1 | 11.6 | 10.2 | 11.4 |
| audio | 0 | 0 | 100 | 0.72 | 1.23 | 10.6 | 15.2 | 10.4 | 15.0 |
| audio | 0 | 0 | 500 | 2.90 | 3.34 | 12.5 | 47.3 | 12.3 | 51.6 |
| audio | 1 | 1 | 1 | 0.013 | 0.033 | 10.1 | 11.4 | 10.1 | 11.2 |
| audio | 1 | 1 | 10 | 0.11 | 0.13 | 10.2 | 11.7 | 10.2 | 11.6 |
| audio | 1 | 1 | 100 | 1.02 | 1.50 | 11.1 | 16.4 | 10.6 | 15.4 |
| audio | 1 | 1 | 500 | 5.79 | 6.08 | 16.8 | 74.0 | 12.6 | 56.4 |
| midi | 0 | 0 | 1 | 0.038 | 0.072 | 10.1 | 11.7 | 10.1 | 11.2 |
| midi | 0 | 0 | 10 | 0.39 | 0.53 | 10.2 | 11.7 | 10.3 | 11.8 |
| midi | 0 | 0 | 100 | 3.44 | 3.66 | 32.9 | 40.2 | 10.6 | 14.1 |
| midi | 0 | 0 | 500 | 16.4 | 17.5 | – | – | 20.5 | 32.4 |
| midi | 1 | 0 | 1 | 0.054 | 0.093 | 10.1 | 11.9 | 10.2 | 11.2 |
| midi | 1 | 0 | 10 | 0.43 | 0.65 | 10.4 | 12.3 | 10.2 | 11.6 |
| midi | 1 | 0 | 100 | 2.90 | 3.21 | 32.2 | 42.3 | 10.7 | 14.2 |
| midi | 1 | 0 | 500 | 19.5 | 21.7 | – | – | 21.8 | 32.7 |
| midi | 1 | 1 | 1 | 0.054 | 0.099 | 10.1 | 11.5 | 10.1 | 11.3 |
| midi | 1 | 1 | 10 | 0.30 | 0.43 | 10.3 | 12.0 | 10.2 | 11.9 |
| midi | 1 | 1 | 100 | 4.10 | 4.30 | 33.2 | 43.0 | 10.9 | 14.9 |
| midi | 1 | 1 | 500 | 19.5 | 19.8 | – | – | 20.9 | 39.4 |

### Real-time playback, ms per callback (DAW: null backend on a real-time clock; Tracktion: hosted device, back to back)

| kind | tracks | buffer | edits | daw p50_ms | daw p99_ms | daw max_ms | tracktion×1 p50_ms | tracktion×1 p99_ms | tracktion×1 max_ms | tracktion×N p50_ms | tracktion×N p99_ms | tracktion×N max_ms |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| audio | 500 | 256 | 0 | 2.05 | 2.90 | 3.46 | 3.90 | 7.85 | 8.23 | 1.19 | 3.00 | 5.10 |
| audio | 500 | 256 | 239 | 2.05 | 3.44 | 3.69 | – | – | – | – | – | – |
| midi | 10 | 128 | 0 | 0.091 | 0.26 | 0.42 | 0.48 | 0.89 | 1.46 | 0.13 | 0.65 | 0.95 |
| midi | 100 | 128 | 0 | 0.86 | 1.68 | 1.68 | 6.69 | 12.5 | 14.1 | 0.83 | 2.91 | 5.71 |
| midi | 100 | 128 | 247 | 0.86 | 1.62 | 1.62 | – | – | – | – | – | – |

### Clip edits, one undo step each (ms for all of them)

| clips | daw add_ms | daw move_ms | daw delete_ms | daw undo_ms | daw redo_ms | tracktion add_ms | tracktion move_ms | tracktion delete_ms | tracktion undo_ms | tracktion redo_ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 1.37 | 0.85 | 1.02 | 2.84 | 3.79 | 1.54 | 0.12 | 0.13 | 1.19 | 1.14 |
| 1000 | 70.2 | 50.1 | 73.0 | 66.6 | 66.1 | 19.1 | 3.53 | 3.53 | 31.0 | 30.4 |
| 5000 | 1803 | 1199 | 1836 | 57.3 | 56.7 | 155 | 28.8 | 22.5 | 214 | 202 |

### Clip edits without the sync to the engine (DAW) — what Tracktion's numbers above measure

| clips | daw add_ms | daw move_ms | daw delete_ms | daw undo_ms | daw redo_ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| 100 | 0.27 | 0.14 | 0.085 | 0.066 | 0.058 |
| 1000 | 6.38 | 11.8 | 10.6 | 0.46 | 0.43 |
| 5000 | 143 | 289 | 173 | 0.52 | 0.36 |

### Note edits without the sync to the engine (DAW)

| notes | daw add_ms | daw move_ms | daw delete_ms |
| --- | ---: | ---: | ---: |
| 100 | 0.29 | 6.01 | 3.25 |
| 1000 | 13.3 | 859 | 408 |
| 5000 | 211 | 14918 | 7811 |

### Clip edits: ms per edit, first and last tenth

| clips | daw add_first_ms | daw add_last_ms | daw move_first_ms | daw move_last_ms |
| --- | ---: | ---: | ---: | ---: |
| 100 | 0.012 | 0.015 | 0.009 | 0.008 |
| 1000 | 0.019 | 0.14 | 0.049 | 0.051 |
| 5000 | 0.036 | 0.74 | 0.24 | 0.24 |

### Note edits in one clip, one undo step each (ms for all of them)

| notes | daw add_ms | daw move_ms | daw delete_ms | tracktion add_ms | tracktion move_ms | tracktion delete_ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 0.88 | 9.76 | 5.29 | 0.19 | 0.16 | 0.15 |
| 1000 | 24.9 | 625 | 319 | 2.44 | 1.84 | 4.38 |
| 5000 | 566 | 16837 | 8140 | 36.4 | 26.8 | 127 |

### One edit in a project of N tracks (ms, median of 50)

| tracks | daw build_ms | daw volume_ms | daw clip_move_ms | daw undo_ms | daw redo_ms | daw track_add_ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 3.19 | 0.007 | 0.026 | 0.021 | 0.020 | 0.026 |
| 100 | 43.7 | 0.046 | 0.066 | 0.065 | 0.063 | 0.11 |
| 500 | 405 | 0.28 | 0.32 | 0.33 | 0.32 | 0.52 |
| 1000 | 1256 | 0.75 | 0.82 | 0.84 | 0.84 | 1.18 |

### Save and load (ms)

| tracks | clips_per_track | daw build_ms | daw save_ms | daw load_ms | daw file_bytes | tracktion build_ms | tracktion save_ms | tracktion load_ms | tracktion file_bytes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 8 | 1.37 | 0.42 | 0.66 | 190332 | 8.72 | 16.4 | 10.4 | 82179 |
| 100 | 8 | 20.8 | 3.14 | 12.4 | 1899263 | 109 | 44.4 | 81.3 | 812888 |
| 500 | 8 | 181 | 16.4 | 63.8 | 9498863 | 687 | 296 | 520 | 4060489 |

### Resident memory (kB)

| tracks | clips_per_track | undo_steps | daw rss_built_kb | daw rss_undo_kb | tracktion rss_built_kb | tracktion rss_undo_kb |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| 100 | 8 | 1000 | 37308 | 41120 | 112632 | 112844 |
| 500 | 8 | 1000 | 170448 | 257628 | 498588 | 498792 |

### Memory over repeated build/edit/render/load rounds (kB)

| rounds | daw rss_first_kb | daw rss_mid_kb | daw rss_last_kb | daw growth_kb_per_round |
| --- | ---: | ---: | ---: | ---: |
| 30 | 15980 | 59308 | 59604 | 19.7 |

### Startup (ms)

| plugins | daw ms | tracktion ms |
| --- | ---: | ---: |
| cached scan | 15.4 | – |
| cold scan | 1269 | – |
| none | 14.5 | 117 |
