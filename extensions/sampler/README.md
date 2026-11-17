# sampler

paw's own sample player. It plays SFZ and Decent Sampler instruments, and
each note can choose its articulation by its MIDI 2.0 attribute, so a chord
can mix sustain and staccato on one channel. It is a CLAP plugin
(`dev.paw.sampler`) the extension builds from its own source, in Rust, and
it works in any CLAP host too. No sfizz or other player is in it.

```
extensions/sampler/
  init.lua, lua/sampler/   the kind of track, the instrument picker, describe
  native/                  the plugin's source (its own Cargo workspace)
  nix/                     how the plugin and the extension are packaged
```

## Building it

With Nix, the plugin and its command on their own:

```
nix build .#paw-sampler        # lib/clap/paw-sampler.clap, bin/paw-sampler
```

and paw with the extension: `paw.withExtensions (exts: [ exts.sampler ])`,
or `programs.paw.extensions = [ "sampler" ]` in home-manager.

From the source tree, `extensions/sampler/native/build.sh` builds it (in the
dev shell, into `target/sampler`) and puts it where the extension looks:
`clap/paw-sampler.clap` and `bin/paw-sampler` beside this file. The
`sampler_plugin_dir` option names another folder. The extension adds that
folder to the plugin scan (`paw.plugins.add_dir`); until a build of paw has
that, put the folder in `CLAP_PATH` or link the plugin into `~/.clap`.

## Using it

- `:sampler.track [file or words]` adds a sampler track (`:track.add sampler`
  does the same, and `:track.new` and the window offer it). With a file it
  loads that; with words, or nothing, it opens the instrument picker.
- `:sampler.load [file or words]` chooses the instrument of the cursor's
  sampler track; the track menu has "Sampler instrument…".
- The picker lists every `.sfz` and `.dspreset` under the folders in
  `paw.opt.sampler_libraries` (separated by `:`) and under
  `~/.local/share/paw/instruments`. As the selection rests on one, it is
  loaded as a trial and a short phrase in its range plays through the
  track; Enter keeps it (one undo step), Escape puts back what was there.
- `:sampler.info` says what the instrument is: its range, articulations
  with their codes and keyswitches, and what in the file is not played.
- `K` and the track header say "Sampler track · Violins · SFZ · 3
  articulations".

Loading is an edit like loading a preset: undo takes it back, and the
project keeps the plugin's state, which names the file and the
parameters. A project opened where the file is missing keeps its path and
says so (`:sampler.info`).

Parameters: gain, polyphony (1 to 256 voices), tune, transpose, attack and
release scale, velocity sensitivity, release trigger level, filter cutoff
offset, and the interpolation (linear, Hermite, sinc).

## Articulations

An instrument's articulations come from its keyswitches: SFZ's `sw_last`
keys (named by `sw_label`, `label_keyN` or the group's label) and Decent
Sampler's `<midi><note>` bindings that turn groups or tags on and off (named
after the groups they turn on), and the options of a Decent Sampler menu that
does the same. Each gets a code of the MIDI 2.0 orchestral articulation
profile (M2-123) from its name (`Staccato` is 11.0, `Pizz` 11.A, `Legato`
10.2); one whose name says nothing gets a custom code (classifications 1A to
1F, in order).

- A note whose MIDI 2.0 attribute is an articulation (types 0x10 to 0x1F)
  plays that articulation, that note only. One the instrument lacks falls
  back as the profile says: another variation, subclass 0, then 10.0. The
  attribute's reset-round-robin bit starts the round robins again.
- A note with none plays what the keyswitches chose: a keyswitch note at the
  same moment, before the note, counts, and it sticks, as in SFZ.
- The plugin names its keyswitch keys through CLAP `note-name`.

`paw.api.device_call(device, "describe")` answers JSON: `name`, `format`,
`path`, `range` (`[lo, hi]`, keyswitches left out), `keyswitches` (`{ pitch,
name }`), `articulations` (`{ name, m2, keyswitch?, default?, custom?,
delay_ms }`), `delay_ms`, `ccs` and `keys` (labels), `regions`, `samples`,
`memory` (bytes), `load_ms`, `round_robin`, `release_triggers`,
`warnings`, `error`, and `params`. `paw-sampler describe file.sfz` prints
the same from a shell.

`delay_ms` is how late the attack comes in the samples: for each sample,
measured once as it is loaded, the time from where the region starts
playing (after its `offset`) to the first frame that reaches a tenth
(-20 dB) of the sample's peak; for an articulation, the median over the
attack regions it plays, and for the instrument over all of them (null
when there are none). The articulations extension writes it into the
instrument's `.art.toml` as `delay`, so that such notes can be played
earlier.

## What it reads

**SFZ.** Headers `<control> <global> <master> <group> <region> <curve>`
with opcodes inherited down the chain; `#define`, `#include`, comments.
Mapping: `sample` (files and `*sine *saw *square *triangle *noise
*silence`), `default_path`, `key lokey hikey lovel hivel lochan hichan`,
`note_offset octave_offset`, `loccN hiccN`, `lorand hirand`, `seq_length
seq_position`. Keyswitches: `sw_lokey sw_hikey sw_last sw_lolast sw_hilast
sw_default sw_label sw_down sw_up sw_previous` (not `sw_vel`). Triggers: `trigger`
(attack, release, release_key, first, legato), `rt_decay`. Pitch:
`pitch_keycenter` (a key or `sample`), `pitch_keytrack tune transpose
pitch_veltrack bend_up bend_down`, `pitcheg_*`. The sample: `offset
offset_random end delay loop_mode loop_start loop_end loop_crossfade` and a
WAV's own loop and key (`smpl`). Level: `volume amplitude pan width
position amp_veltrack amp_velcurve_N ampeg_*` (with `vel2*`). Filter:
`fil_type` (lpf/hpf 1p, 2p, 4p; bpf_2p, brf_2p) `cutoff resonance
fil_keytrack fil_keycenter fil_veltrack fileg_*`. Crossfades: `xfin_*
xfout_*` by key, velocity and controller, `xf_keycurve xf_velcurve
xf_cccurve`. Controllers: `amplitude volume gain pan pitch tune cutoff
resonance` with `_onccN` (or `_ccN`) and `_curveccN`; `set_ccN set_hdccN
label_ccN label_keyN`. Voices: `group off_by off_mode off_time polyphony
note_polyphony`. Anything else is listed in `warnings`, never an error.

**Decent Sampler.** `<groups>`, `<group>` and `<sample>` with their
attributes inherited down: `path rootNote loNote hiNote loVel hiVel start
end tuning groupTuning globalTuning pitchKeyTrack volume` (linear or dB)
`pan ampVelTrack attack decay sustain release ampEnvEnabled trigger
releaseTriggerDecay seqMode seqLength seqPosition loopStart loopEnd
loopEnabled loopCrossfade delay loCCN hiCCN previousNotes tags
silencedByTags silencingMode silencingDecay`; `<tags>` (`enabled`,
`polyphony`); keyswitches as `<midi><note>` bindings of `ENABLED` and
`TAG_ENABLED` (and `swallowNotes`), and `<ui>` menus whose options do the
same. `<effects>`, `<modulators>` and `<buses>` are reported, not played.

Sound files: WAV (8, 16, 24 and 32-bit, float), AIFF, FLAC and Ogg Vorbis
(these two through symphonia); files with more than two channels play
their first two.

A format is one reader (`native/src/formats/`) that fills the one model in
`native/src/model.rs`; nothing else changes to add one.

## How it plays

Samples are read whole into memory when the instrument is loaded, on up
to eight threads at once, 16-bit ones kept as 16-bit. Voices come from a fixed pool (the polyphony
parameter, at most 256, and 32 more for stolen voices to fade in); a voice
stolen is a released one first (the quietest), else the oldest, and fades
in 6 ms. Nothing on the audio thread allocates, locks or reads a file (a
test counts). Events are sample-accurate. Resampling is a windowed sinc
(16 taps, Kaiser β 8, 256 phases interpolated) with tables for eight speeds
up to four times the sample's rate, so a note pitched up is filtered
before it folds; Hermite and linear are cheaper settings. Round robins and
random choices start the same at every reset, so renders repeat exactly.

Measured (`paw-sampler bench`, the best of five runs, on a machine busy
with other builds): a voice of a stereo sample costs about 20 ns a frame
with sinc, 10 with Hermite, 6 linear, so 64 voices at 48 kHz take 6 % of a
core with sinc and 256 voices 25 %. A library of 1000 stereo 24-bit files
(550 MB on disk, 770 MB in memory) loads in about 110 ms when the files are
in the system's cache.

Through paw's plugin helper, each instance costs about 8 µs a block more
than in the program's own process. Played in real time on the null
backend, 512-frame blocks, each instance holding a note: 1 instance keeps
the engine 0.8 % busy (0.5 % in process), 16 instances 3.1 % (1.3 %), 64
instances 8.1 % (3.5 %), at most 13 % (5 %). An offline render of 20 s
takes 132, 525 and 1549 ms with 1, 16 and 64 instances (118, 211 and 506
in process). With small blocks the crossing weighs more, as it is paid per
block; `--plugins-in-process` saves it.

## Testing

`cargo test` in `native/` (in the dev shell): the readers, seventeen renders
of the fixture instruments checked by pitch and level (round robin order,
keyswitches, attributes per note with fallback, release triggers and the
pedal, loops without clicks, envelopes, choke groups, velocity layers, a FLAC sample,
polyphony), the plugin through its CLAP entry with MIDI 2.0 note-ons
carrying attributes, and a counting allocator over everything the audio
thread does. `native/test.sh` builds the plugin and runs the extension's
tests in paw (`tests.lua`) with it on the plugin path; the suite alone
runs those that need no plugin. `paw-sampler fixtures <dir>` writes the
fixture instruments (sines of known pitches) for trying things by hand.
