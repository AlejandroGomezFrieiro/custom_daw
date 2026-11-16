# Input and recording

## Input and recording

**Devices.** The engine opens one output device and one input device. Which
ones is the machine's business, not the project's: chosen with `:audio`, the
engine indicator in the window, `--output`/`--input`, or from Lua, and kept
in `$XDG_STATE_HOME/daw/audio.json` for the next start. A remembered device
that is not connected is replaced by the system's default, with a message.

```lua
daw.audio.devices()      -- { outputs = { { name, id, channels, sample_rate, min_block, max_block }, ... }, inputs = {...}, output, input }
daw.audio.use({ input = "UR22" })                 -- by name, id or a part of the name; "default" for the system's
daw.audio.use({ output = "UR22mkII Stereo", buffer = 128 })   -- buffer 0: the device's own block size
daw.audio.levels()       -- the level arriving at each input channel, 0 to 1
daw.api.engine_get()     -- device, input_device, sample_rate, block, input_latency, output_latency (ms)
```

`:audio` lists the outputs, inputs and block sizes, with the sample rate,
block size and input and output latency at the top; `:audio.output <name>`,
`:audio.input <name>` and `:audio.buffer <frames>` do the same one at a time
(Tab completes the names). A name that matches nothing is refused with the
list of what there is. A part of a name finds the device with the most
channels that has it, so `UR22` opens a Steinberg UR22mkII's whole two-channel
input rather than one of the mono halves PipeWire can also offer.

With PipeWire, each device is a PipeWire node, opened by its node name: the
list leaves out the system's "default" entries, other programs' streams, and
sinks offered again as inputs. The block size is asked of PipeWire as the
node's latency and is a request: the graph may run another, which
`engine_get().block` reports.

**A track's input.** A track takes audio input from one channel or a pair of
neighbouring channels of the input device. The input is added to the track
ahead of its devices, so a guitar goes through the amp simulator on its track.

```lua
local gtr = daw.add_track({ name = "Guitar" })
gtr.input = "1/2"            -- or "1", "3", nil for none
gtr.monitor = true           -- hear it without arming
gtr.armed = true             -- record it
daw.transport.record()       -- recording on, and play
daw.transport.stop()         -- the take becomes a clip at the position recording began
daw.transport.recording = false

local keys = daw.add_track({ name = "Keys" })
keys.midi_input = { port = "Keystation 49", channel = 1 }   -- MIDI from one port (and channel); nil for all
```

`I` in the arrange view (or the header's input button in the window) lists
everything a track can take in, under three headings: audio (no audio input,
each channel and each neighbouring pair, named with the device:
`UR22mkII · 1`, `UR22mkII · 1/2`), MIDI (every port, or one) and MIDI channel
(every channel, or one), and where the track sends MIDI (MIDI out, and its
channel: see [MIDI output to hardware](mixing.md#mixing-midi-and-rendering-in-the-core)).
`daw.audio.choices(track)` is that list and
`daw.audio.choose(track, choice)` takes one; a choice that is saved but not
there now (a pair the device lacks, a port that is unplugged) is listed as
chosen and marked missing. `:track.input 1/2` and `:track.midi Keystation ch=1`
set them by name for scripts, and Tab completes both.

The header shows what the track takes in (`UR22mkII · 1/2`) and the level
arriving at its input, whether or not it is armed or monitored, so a guitar
can be seen arriving before anything else. `I` beside `M S R` in the terminal,
and the loudspeaker beside the input button in the window, switch monitoring;
`<A-i>` does too.

- **Monitoring.** A track's input is heard when the track is armed or its
  monitor switch is on. Arming always monitors, so what is recorded is what you
  hear. A track with no input ignores both.
- **What records.** While `daw.transport.recording` is on and the transport
  plays, every armed track with an input records its dry input (before its
  devices) to a WAV file, and every armed track without one plays and records
  MIDI input: from every port, or from the port (and channel) in its
  `midi_input`. Stopping or turning recording off ends the take, and seeking
  starts a new one. Its clips, audio and MIDI alike, are added as one undo
  step. Notes still held when it ends are cut off there.
- **Recording round the loop makes takes.** With the loop on, recording
  goes round it, and every time round becomes a take of one clip over the
  loop: the last is the one that plays, and the clip's name says which
  (`take 3 ‹3/3›`). What was played on the way into the loop is a clip of its
  own before it. The first time round counts if it began at the loop's start
  or before; the last if it got at least half way. With the loop off a take
  is one continuous clip. See [Takes](recording.md#takes).
- **Count-in.** `daw.opt.count_in` is how many bars the metronome counts
  before a take begun with the song stopped (0, the default, for none):
  `:countin 1`, `:countin off`, or `:countin` alone to turn it off and on;
  `gC` does the same. The record button, `R` and `daw.transport.record()`
  count in, and so does playing with record mode on; punching in by hand
  while playing does not. The clicks are at the tempo and in the signature
  at the playhead, a click on every beat of the signature and a higher one
  on each bar's first, whether or not the metronome is on, and heard as late
  as the song is. The playhead stays where it is while counting, and the
  song and the take start on the frame after the count, so what is recorded
  lines up exactly as without one. `daw.transport.counting` is the number of
  beats still to count (0 when none is under way); the status line reads
  `count 3` and so does the window's clock, with the record button blinking
  on the beats. Stop, or `Esc`, during the count calls it off: no take,
  nothing recorded, record mode off.
- **Punch in and out.** With `daw.transport.punch_enabled` on, a take is
  recorded only from `punch_start` to `punch_end` (beats) while the song
  plays on either side: capturing starts and stops on the frame at those
  points, and the clip made covers exactly the range (a note held across the
  punch out is cut there). Started inside the range, it records from the
  playhead to the punch out; started after it, it records nothing and says
  so. With the loop on as well, each time through the range is a take of one
  clip over it, as each time round the loop is without punching (the first
  time counts if it began at the punch in or before, the last if it got at
  least half way; a range reaching past the loop's end is cut there). `:punch`
  turns it on and off, `:punch 5 8` punches over bars 5 to 8 (as
  `:transport.loop` counts them), and `:punch selection` over the visual
  selection, or the loop when there is none; the first `:punch` with no range
  set does the same. `gI` toggles it, and on a selection punches over it. The
  range is saved with the project, like the loop, and is not undoable. It is
  red on the ruler of both frontends, under the loop in the window, where
  its ends are dragged like the loop's; the timeline's menu has the entries.
- **Pre-roll.** `daw.opt.pre_roll` (whole bars, 0 to 16) and
  `daw.opt.pre_roll_seconds` (0 to 30) say how long before the punch in a
  take punched in from a stop starts playing: `:preroll 2`, `:preroll 3s`,
  `:preroll off`, or `:preroll` alone to turn it off and on (the window's
  timeline menu has the same). With punch on, the transport stopped and
  recording begun, the playhead goes back to the bars before the bar line
  at or before the punch in, and then back the seconds more, and the song
  plays from there; nothing is recorded until the punch in, where the take
  begins on the frame as without a pre-roll, so the clip starts exactly at
  the punch in. A playhead already further back than that stays where it is;
  one inside the range or past it, a take begun while playing, and a take
  without punch have none. A count-in comes before the pre-roll: it counts
  at the pre-roll's start, and the song plays from there when it is done.
  The pre-roll is yours, as the count-in is: it is not saved with a project.
- **Files** go in a `media` directory beside the project file. A project that
  has never been saved records into `~/.local/share/daw/recordings`; saving it
  links or copies those files into `media` beside it and points the clips
  there, leaving the originals for earlier undo steps.
- **Takes that end badly.** A take's WAV header is brought up to date and
  the file flushed to the disk every two seconds, so a file left by a crash
  or a power cut is a valid WAV of all but its last seconds. The take is in
  the safety copy from the moment it begins: after a crash, `:recover` puts it
  back as a clip where it began, on its track. Opening a project whose `media`
  directory holds takes that no clip refers to and that were written after
  the project was last saved says so, and `:recover` lists them to bring in
  (on the track they were recorded for), also after the project's folder
  has been moved. If a file cannot be written (the
  disk is full), recording stops, what was written is kept as a clip, and a
  message says why. Recording that starts with room on the disk for less
  than `daw.opt.record_warn_minutes` (30) minutes says how many are left.
- **MIDI input** comes from every ALSA sequencer port, which with PipeWire
  includes its MIDI devices, and from ports that appear later. `daw.midi.inputs()`
  lists them, `daw.midi.select({ "Keystation" })` keeps only some open (by id or
  part of a name, `nil` for all). A track's `midi_input` names its port by name,
  so it is found again when the keyboard is plugged in later or elsewhere.
  Notes held on a port that goes away are released. Ports are only opened with
  a real audio device; scripts on the null backend can play
  `daw.midi.note_on("C4", 100)` and `daw.midi.note_off("C4")`, or
  `daw.midi.inject({ type = "note_on", pitch = 60, velocity = 100, port = "Keys A" })`
  as if from a port. `:midi.inputs` and `:midi.select` do the same from the UI.
- **MIDI from other programs.** `daw.midi.open_port("Guitar")` makes a port of
  the program's own that others send to: PipeWire and the sequencer show it
  as `daw: Guitar`, it is listed among the inputs, and a track takes it by
  that name like any port. What arrives there is that port's, whoever sent
  it. `daw.midi.close_port("Guitar")` takes it away. The
  [vinput](../extensions/vinput) extension feeds such a port from a guitar.
- **Sound files** are brought in with `:import take.mp3` (alone, it lists
  files to choose from; `daw.pick.file` is that list for extensions),
  `daw.import_audio(path, { track = ..., start = ... })`, or by naming the
  file where a project would be named on the command line. `:clip.import`
  puts one on the cursor track.
- **MIDI files** (`.mid`, `.midi`, `.smf`, `.kar`; format 0, 1 and 2, any
  number of ticks to a beat, or frames of SMPTE time) open as a project of
  their own with `:open song.mid` (or `:e song.mid`): a track for each of the
  file's tracks that has notes (a format 0 file is split by channel), named
  after it or "Channel N", one clip on each over the bars it plays, with its
  controllers, pitch bend, pressure and program changes as the clip's
  controls (the curve editor's `daw://clip/C/control/cc/N`), the file's tempo
  map, time signatures and markers, and its lyrics on the notes they start
  (`note.meta.lyric`). A track that plays on channel 10 alone gets the
  built-in drum kit; the others get no instrument, as a new track has none.
  The project has no file: `:w` asks where it goes, and never writes over the
  .mid. `:import song.mid` brings the tracks into the open project instead,
  below the cursor's track, with the file's start at the edit cursor, as one
  undo step; the tempo map stays the project's unless asked for with
  `:import song.mid tempo=yes` (the file's from the cursor on).
  `:clip.import riff.mid` puts every note of the file in one clip on the
  cursor track. What a file holds that has no place here (sysex, key
  signatures, text) is left out, and the message says how much.
  `:export song.mid` writes the project as a format 1 file with its tempo
  map, time signatures and markers; `:export riff.mid clip` the clip at the
  cursor, `:export part.mid selection` the selected tracks. In scripts:
  `daw.midifile` (see [Scripting](scripting.md)).
- **Latency.** cpal runs input and output as separate streams, joined by a
  ring that holds at most one input period plus one output block; when the
  clocks drift, the excess is dropped or the last frame repeated.
  `daw.api.engine_get()` reports `input_latency` (the system's capture delay
  plus that ring) and `output_latency`, in milliseconds, as the backend
  measures them. `--no-input` leaves the input closed.
- **A device that goes away.** When the audio device is lost (a USB
  interface unplugged, the sound server gone), the transport stops, a take
  being recorded is closed and kept, the program says which device was lost
  and goes on without sound, so editing, saving and rendering carry on.
  Every three seconds it looks for the device, and once it is back opens it
  again with the same sample rate, block size and input, saying so; the
  tracks keep their inputs. `:audio.reconnect` tries at once, and
  `daw.opt.audio_reconnect = false` leaves reopening to that command. The
  engine indicator reads `lost: UR22mkII` meanwhile, and
  `daw.api.engine_get().lost` names the device. A MIDI input that goes away
  and comes back is told of both times, with the tracks that take it; they
  take it again by its name.
- **Testing without hardware.** The null backend can generate input: input
  channel `n` carries a sine at `n` times the frequency, offered as the input
  device `test signal`; `test_midi` gives it MIDI ports to list.
  `daw.api.engine_restart({ backend = "null", test_input = { frequency = 440, level = -12, channels = 2 }, test_midi = { "Keys A" } })`.
  With `midi = true` the null backend opens the real MIDI ports all the same,
  for trying MIDI from hardware or another program with no sound. The
  `test` backend is the null backend with a pretend device that can be
  unplugged: `daw.api.audio_test_device({ fail_after = 100, back_after =
  2000 })` loses it 100 blocks into the next stream and brings it back two
  seconds later; `daw.api.midi_test_ports({ "Keys A" })` changes the MIDI
  ports the null backend lists.

## Takes

A clip can hold several versions of what it plays, of which one plays.
Recording round the loop makes them (see [Input and recording](recording.md#input-and-recording));
`:take.new` makes one by hand, keeping what the clip plays and carrying on
in a copy.

| Keys, command | |
| --- | --- |
| `]t` `[t`, `:take next`, `:take prev` | the clip's next take; the one before |
| `:take 2` | play the second |
| `:take.list` | choose from a list |
| `:take.new` | keep what the clip plays as a take and carry on in a copy of it |
| `:take.remove`, `:take.remove 1` | throw away the playing take, or the one numbered |
| `:take.keep` | throw away every take but the one that plays |
| `:take.explode` | every other take as a clip on a new track of its own |
| `zt`, `:take.lanes` | show the track's takes as lanes under its clips, or hide them |

**Comping**, choosing the best of each take: cut the clip where the choice
changes (`s`) and choose a take for each piece. Every piece keeps all the
takes, lined up, so a cut can be moved and a choice changed afterwards; a
start that is trimmed or slipped moves every take alike. With a stretch of
time selected, `:take 2` cuts at its ends and plays the second take there.
In the window the clip's menu has a Takes entry with all of this.

**Take lanes.** `zt` (or `:take.lanes`, the Takes entry of a clip's menu,
or the track's menu in the window) shows a track's takes as lanes under its
clips: lane k holds take k of every clip of the track that has takes, each
over the clip's own stretch of time, so the pieces of a comp line up into
lanes. What plays is lit, the rest dimmed; each piece shows its take's
waveform or notes and its name. After recording round the loop nothing
opens by itself, but `zt` shows every time round at once. In the window,
**swiping** comps: press on lane k and drag across a stretch of time, and on
release take k plays over exactly that stretch, the clips being cut at its
ends where needed, as one undo step; a click on lane k chooses take k for the
piece under the pointer. The ends land on the grid unless Shift is held, and
a drag shorter than a grid step is a click. Pieces side by side that then
play the same take are joined back into one where that is exact, so swiping
back and forth leaves no slivers: for sound, when every take is lined up
across the join (the same file and gain, the second piece starting in each
take where the first ends), the clips have the same name and mute and there
is no fade at the join; for notes, when the takes' names match and no note
is hidden past either piece's edge. A note cut in two by an earlier cut stays
two notes after the join, as it played. In the terminal the lanes are a line
each under the track, read-only: the playing take is lit and named, and
comping is `:take 2` over a selection. Which tracks show take lanes is kept
for the session, like automation lanes shown as rows, not in the project.

In scripts: `daw.takes.count(clip)`, `daw.takes.select(clip, n)`,
`daw.takes.step(clip, 1)`, `daw.takes.new(clip)`, `daw.takes.remove(clip, n)`,
`daw.takes.keep(clip)`, `daw.takes.explode(clip)`,
`daw.takes.comp(track, n, from, to)` (take n over beats `from` to `to`,
then the joining above), `daw.takes.choose_at(track, n, beat)`,
`daw.takes.join_pieces(track, from, to)`, `daw.takes.content(clip, n)`
(what take n plays: file, offset and gain, or notes), and
`daw.takes.show_lanes(track, on)`, `daw.takes.lane_count(track)`. The
window's gestures are `daw.frontend.act.take_lanes(track)`,
`act.comp(track, n, from, to, free)` and `act.take_click(track, n, beat)`;
`daw.frontend.take_preview(clip, n, points)` draws a take that is not
playing, from `daw.api.media_peaks(file, offset, seconds, points)`, the
waveform of any stretch of a file. They are kept in
`clip.meta.takes` (`runtime/lua/daw/takes.lua` says how); the files of takes
that are not playing count as the project's files, are moved into `media`
when it is first saved, and are found again when they go missing.
