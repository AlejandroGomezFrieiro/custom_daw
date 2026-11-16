# Editing, mixing and rendering

## Mixing, MIDI and rendering in the core

**Threads.** Playback and renders use one thread per core (`daw.opt.threads =
4` or `:engine threads=4` for another number, 1 for the audio thread alone,
0 to leave it to the machine; `daw.render(path, { threads = 1 })` for one
render). `daw.api.engine_get().threads` says how many are in use. When the
audio thread runs with real-time priority the workers take the same
priority; if the system refuses them that, the engine stays on the audio
thread rather than make it wait for threads that anything may push aside.

**Fades.** An audio clip has `fade_in` and `fade_out`, in beats
(`clip.fade_in = 1`, `:clip.fade in=1 out=2`). `:clip.crossfade 1` runs a clip
on under the start of the next and fades the two across each other. An edge
that cuts into the middle of a recording gets three milliseconds of fade
whether asked for or not, so that splitting and cutting audio does not click.

**Tempo and time signature.** Both can change along the song. A tempo change
either holds until the next one or ramps to it, the tempo moving linearly in
time as REAPER's linear tempo points do; a time signature change starts a
new bar where it is, cutting short a bar it falls inside. `daw.project.tempo`
and the signature fields are the ones at the start, and a project with one
tempo and one signature saves as it always has. The engine follows the map
sample by sample: the playhead, the loop, MIDI clips, automation, the
metronome (the first beat of each bar accented, a click on each beat of the
signature, so six in a bar of 6/8), recording and renders. Plugins are told
the tempo, signature, bar and time at each block (CLAP transport, VST3
process context, LV2 `time:Position`, through the sandbox too).

```lua
daw.tempo.set(17, 96)                    -- 96 BPM from beat 17 on
daw.tempo.set(32, 120, { ramp = true })  -- ramp from 120 at beat 32 to the next change
daw.tempo.set_signature(9, 6, 8)         -- 6/8 from bar 9
daw.tempo.at(40)  daw.tempo.signature_at(40)  daw.tempo.points()  daw.tempo.remove(17)
daw.tempo.beats_to_seconds(16)  daw.tempo.seconds_to_beats(8)  daw.tempo.bar_of(33)
daw.time.format(33.5)                    -- "9.4.00": bar 9, fourth eighth
```

`:tempo 96` sets the tempo at the start, `:tempo 96 at 17` from bar 17 (or
`17.3`, bar and beat), `:tempo 96 here` from the cursor; `:tempo.ramp`
makes the change at or before the cursor ramp to the next (again to hold),
`:tempo.remove` removes it, `:tempo.list` lists the map, `:tempo.tap` (again
and again, in time) sets the tempo from taps; `:timesig 6/8` starts 6/8 at
the cursor's bar (`at 9` for bar 9), `:timesig.remove`. Each is one undo
step. Rulers number bars and draw bar and beat lines by the map; the
terminal's arrange ruler marks a tempo change `▾96` (`▾120>` for a ramp)
and a signature change `‖6/8`, and the window flags them on its ruler. The
status line and the window's transport show the tempo and signature at the
playhead.

Audio clips keep their length in seconds: changing the tempo neither
stretches nor cuts a recording, and its end beat follows from the map. What
an audio clip keeps of its start is its `timebase`: `"time"` (the default,
as REAPER's audio items) keeps its start at the same second, so the clip
moves in beats when the tempo before it changes; `"beats"` keeps it on its
beat (`clip.timebase = "beats"`); `"stretch"` keeps its start and its
length on their beats, stretching its sound to fit (see
[Stretching and looping clips](mixing.md#stretching-and-looping-clips)). MIDI clips
and automation stay on their beats.

**Groups of tracks.** `daw.groups.make({ violins, violas, cellos }, "Strings")`
(`:track.group Strings` on the selected tracks, `,g`) makes a group: a track
the others belong to. The members play into it, so its fader, mute and
devices act on all of them; they stand under it, a step in and in its
colour; and `za` folds them away into it (`zM` folds every group, `zR` opens
them all). `:track.into Strings` moves a track in, `:track.ungroup` (`,G`)
takes one out or dissolves a group. Groups hold groups. A group is an
ordinary track marked in its `meta`, so it is saved, copied and undone like
any other, and `daw.groups.rows()` is the list of tracks that are drawn:
all but those folded away.

**Outputs and sends from the keyboard.** `:track.output Drum bus` (`,o` for
a list) plays the track into another, `:send Reverb -9` (`,s` for a list;
`pre=1` for ahead of the fader) sends its sound to one as well, and
`:send.remove Reverb` takes the send away.

**Sends before the fader.** `track:send(reverb, -6, { pre = true })` takes the
signal after the track's devices and before its fader and pan, so the send
keeps its level when the fader moves. Muting the track still silences it.

**Side-chains.** A device can listen to another track: a compressor on the
bass that ducks under the kick, a gate on a pad that opens on the hi-hat.
`comp:set_sidechain(kick)` (or `comp.sidechain = kick.id`) takes the kick
after its fader, as a send does; `{ pre = true }` (`comp.sidechain_pre`)
takes it after its devices but before its fader, pan and mute, so that a
muted "ghost" kick still keys. Soloing another track does not cut a key: a
track silenced by a solo still keys what listens to it, after its fader, as
if it were heard; muting it does cut a key taken after the fader. `comp:set_sidechain(nil)` takes it away. The
built-in `compressor` and `gate` key their detector from it (`listen` plays
it); CLAP, VST3 and LV2 plugins get it on their first side-chain input (a
CLAP audio port that is not the main one, a VST3 auxiliary bus, an LV2 port
marked `isSideChain` or in a group that is the side-chain of another), and
`device.ports.sidechain` says whether a device has one. Other devices ignore
it. The track listened to is processed first, like a track that sends; a
side-chain that would make a loop (from the device's own track, the master,
or any track the device's track plays, sends or keys into, directly or
through others) is refused with the reason, and so are outputs and sends
that would close one. The key is lined up with what the device hears: it is
held back by the latency of the devices before it, or holds the device's
track back when it is the later. Removing the track takes the side-chain
away (undo brings it back); copying a track keeps it, a track restored after
its key is gone (or where it would loop) drops it with a message, and
templates leave it out. `:device.sidechain Kick` (`pre=1` for before the
fader, `none` to take it away; alone, a list) acts on the device panel's
device, `K` there chooses from a list, and the panel shows `key Kick` on the
device's line. In the window a device that can listen to one has a Key row
on its card, with a menu of the tracks it can hear.

**Instruments with several outputs.** A drum plugin with a pair per drum,
or Surge XT's scene outputs: `device.ports.outputs` names the pairs (from
the plugin: CLAP audio ports, VST3 output buses, which are all switched on,
LV2 output ports two by two; a port wider than two is taken in pairs too).
The first plays on the device's own track, as ever. A further pair plays
only where it is routed, as in REAPER, where it would sit unheard on
channels 3 and up: `kit:set_output(2, kick)` (`kit.outputs` is a table of
pair number to track), `:device.output 2 Kick` (`none` to take it away;
alone, a list of pairs and then of tracks; `O` in the device panel), and
`:device.spread` (`daw.routes.spread(kit)`) makes a track for each pair that
plays nowhere, named after it, and puts them and the device's track in a
group (`<track> outputs`, or the group the track is in already; the
device's track cannot be the group itself, since its pairs feed the new
tracks). A pair is taken from the device as it comes out, before the rest
of the chain: the fader, pan and mute of its own track do not act on it,
those of the track it plays into do. It is added in before that track's
devices, so that track is processed after it, and it is lined up with the
rest like any other connection. Loops are refused as for side-chains, and
so are pairs of a device on the master. Removing the track a pair plays
into takes the route away; a copy of the track plays its pairs nowhere;
templates leave them out. The built-in `drums` has a pair for each family
of pieces (Kick, Snare, Hats, Toms, Cymbals, Percussion): a family whose
pair is routed plays there and leaves the kit's own pair. The device panel
shows `outs 2/6` (pairs routed of those there are) on the device's line, and
the window's card an Outs row whose menu routes each pair and spreads them.
Main pairs wider than stereo (surround) are not handled; a mono plugin on a
stereo track plays on both sides.

**Delay compensation.** A device that looks ahead says how late its output is
(CLAP, VST3 and LV2 plugins do; of the built-in devices the `limiter` does).
Every other path to the same place is held back by the difference, through
buses and sends, so that everything arrives together; a render leaves the
delay off the start of the file. `daw.api.engine_get().latency` is how far the
output is behind the transport, in milliseconds. A track's own clips are not
held back to match what is routed into it.

**MIDI, at the resolution of MIDI 2.0.** Besides notes, a MIDI clip holds
controller moves (`clip:controls()`, `clip:set_controls(...)`): control
changes, the pitch wheel, pressure, registered and assignable controllers,
program changes. Values are fractions, not seven-bit steps, and a move with a
`key` belongs to the note on that key alone: its own pitch bend, pressure or
controller, as MIDI 2.0 has them.

```lua
clip:set_controls({
  { start = 0, type = "cc", number = 64, value = 1 },         -- pedal down
  { start = 2, type = "bend", value = -0.5 },                 -- the wheel
  { start = 2, type = "bend", key = "E4", value = 1 / 48 },   -- one note, a semitone up
  { start = 4, type = "program", program = 12, bank = 258 },
})
track:midi({ type = "cc", number = 1, value = 0.3 })           -- now, to the track's devices
daw.on("midi.in", function(e) end)       -- everything that arrives at a port, for scripts; `e.port` names the port
daw.midi.ump({ type = "cc", number = 74, value = 1 })   -- as a MIDI 2.0 packet: two words
daw.midi.inject_ump({ 0x40903c00, 0xc0000000 })         -- and a packet, as if from a port
```

They are recorded with the notes, chased when playback starts in the middle,
kept through cutting, joining, copying and undo, and saved exactly. Where they
go: the built-in synth follows the wheel, the sustain pedal and a note's own
bend; CLAP plugins get a note's own controllers as note expressions and the
rest as MIDI 2.0 if they take it, else MIDI 1.0; VST3 plugins get note
expressions and poly pressure, and controllers through the parameters they
assign to them; LV2 plugins get MIDI 1.0, which has no per-note bend.

At the ports the program opens as a MIDI 2.0 client and reads Universal MIDI
Packets, so a MIDI 2.0 device arrives whole and a MIDI 1.0 device arrives as
the same events with less detail. That needs a kernel built with
`CONFIG_SND_SEQ_UMP`; without it the ports are MIDI 1.0, and what arrives is
widened by the specification's rules so that both read the same. There is no
MIDI-CI, and no editor for controller moves yet.

**MIDI output to hardware.** A track sends what it plays (its clips' notes
and controllers, and MIDI input passing through it, before its devices) to
a port: `track.midi_output = { port = "UM-ONE: UM-ONE MIDI 1", channel = 2 }`
(`channel` nil keeps each message's own), `:track.midi_out UM-ONE 2` (part
of the name will do; `none` for none), or the MIDI out entries of the input
list (`I`) and of the window's input menu on the track's header.
`daw.midi.outputs()` lists the ports. The audio thread stamps each message
with when it is heard (the output's latency and the plugins' delay
included) and hands it over a lock-free queue to a thread that schedules it
on an ALSA sequencer queue in real time, so a synth on the port sounds with
the tracks. Stopping, jumping and going round the loop end the notes that
are sounding there, with an All Notes Off on their channels; so do taking
the port away and removing the track. Renders send nothing. Ports are
opened when MIDI input is (with an audio device, or `engine_restart({ midi =
true })`). `daw.midi.open_output("To Surge")` makes a port of the program's
own that other programs read from (`daw out: To Surge`), and a track that
sends to `To Surge` plays them; `daw.midi.close_output` takes it away.
Copies of the track send where it does; templates and project files keep
the port by name.

**Recording offset.** What is played along to the song is heard late and
arrives late. Takes are moved earlier by what the audio system reports, plus
`daw.transport.record_offset` milliseconds for what it does not: record the
metronome through a loop-back cable, measure, and set it once in `init.lua`.

**Writing automation by moving things.** Each track has an automation mode
(`track.automation`, `:automation touch`, `,am` for the next in turn, the
`A` flag on its header in the window):

| Mode | While the song plays |
| --- | --- |
| `read` | the lanes play; moving a control writes nothing (the usual) |
| `touch` | a control writes while it is held or being moved, and when it is let go the lane takes over again, joined back to what it held |
| `latch` | a control writes from its first move until the song stops |
| `write` | everything the track's lanes move is written over from where the song starts playing, moved or not |
| `off` | the lanes are kept but do not play: the fader, the pan and the parameters are where they were set |

A control is a fader, a pan or a parameter, moved from the keyboard, a
frontend, a MIDI controller or a plugin's own window. What is written goes
into its lane at the playhead, over what the lane had there; a lane is made
if there is none. In the window a control is held for as long as the
pointer holds it (`daw.api.automation_hold`); anything else counts as held
for a little over half a second after its last move. `:lane.write` (`,aw`)
is a switch for the whole song: while it is on, every track that is not
writing in a way of its own latches. The terminal's track header shows `T`,
`L` or `W` in red while a track writes, and `-` when its automation is off.

**A control moved is one undo step.** A fader dragged in the window or a
knob turned on a controller sets its value many times a second; the moves
of one control that follow each other within a second are one step, so one
undo takes the whole sweep back. Commands and keys are a step each, as ever.

**Rendering.** `:render mix.flac` renders the song to a file, WAV or FLAC by
the file's extension (without a name, `<project>.wav` beside the project). It
runs on a thread of its own: the status line shows `rendering mix.flac 43% ·
Esc cancels`, `Esc` in normal mode or `:render.cancel` stops it, and a message
says when it is done. The render plays a snapshot of the project taken when it
starts, so editing meanwhile changes the project and not the file. The file
is written as `.mix.flac.part` beside the target and renamed when complete, so
a render that fails or is cancelled leaves nothing under the name. Formats
that need an encoder this program does not have (AAC, AIFF, WMA) are refused
by name before anything is rendered; `daw.api.render_formats()` lists what
can be written (`{ name, extensions, bits, lossy, available, why }`).

MP3 (`.mp3`), Ogg Vorbis (`.ogg`) and Opus (`.opus`) are made by `ffmpeg`,
when it is installed: no encoder for them is linked into the program. The
song is rendered to a hidden 32-bit float WAV beside the target (no dither;
at the sample rate asked for), and ffmpeg encodes that into a `.part` file
that is renamed when complete; the WAV is removed whether the encode succeeds,
fails or is cancelled. The encode runs on the render's thread too: the status
line says `encoding mix.mp3 61%` (and the window "Encoding") instead of
sitting at 100%, `Esc` or `:render.cancel` stops ffmpeg as well, and
`render.done`, `render.failed` or `render.cancelled` come once, for the final
file (`render.progress` and `render_status()` carry `stage`, `"rendering"` or
`"encoding"`). Opus holds only 48 kHz and the usual lower rates, so ffmpeg
resamples to 48 kHz; MP3 above 48 kHz is resampled to 48 kHz too. The project's
name is the file's title tag. `ffmpeg` is the program found on the PATH; set
`daw.opt.ffmpeg = "/path/to/ffmpeg"` to name another. Without it, or with an
ffmpeg built without the encoder, `:render mix.mp3` fails before anything is
rendered, saying so and naming the formats that need nothing (WAV and FLAC),
and `render_formats()` gives `available = false` and `why`; the window's
dialog then does not offer the format.

`quality=low|medium|high|best` (high by default) means the same in each
format; `bitrate=192` (kbit/s) takes its place when you want a number:

| quality | MP3 (LAME) | Ogg Vorbis | Opus |
|---|---|---|---|
| low | VBR `-q:a 6` (about 115 kbit/s) | `-q:a 3` | 64 kbit/s |
| medium | VBR `-q:a 4` (about 165) | `-q:a 5` | 96 kbit/s |
| high | VBR `-q:a 2` (about 190) | `-q:a 7` | 128 kbit/s |
| best | constant 320 kbit/s | `-q:a 9` | 192 kbit/s |

A bitrate is constant for MP3 and the target for Opus and Vorbis. `bits=` and
`dither=` do not apply to these formats. The command takes
(and `<Tab>` completes) `range=song|loop|selection`, or `start=` and `end=` in
beats; `tail=2` (seconds after the end, for reverbs; 1 by default);
`rate=44100`; `bits=16|24|32` (32 is float, WAV only; 24 by default);
`channels=mono|stereo` (mono mixes the sides at half level each);
`quality=high` or `bitrate=192` (MP3, Ogg and Opus); `dither=true`; `normalize=-1` (peak, dB); `loudness=-14` (integrated LUFS,
measured as BS.1770; with `normalize` too, the peak level is a ceiling);
`tracks=selected` or `tracks=3,5` for a stem of those tracks;
`master=false` to leave out the master's devices, fader and pan;
`stems=true` to write one file per track into a directory; `wait=true` to
render in the foreground. `:stems out format=flac master=false` renders stems
too. Normalizing renders the song once into a raw temporary file, measures it
and encodes from there.

`daw.render(path, opts)` takes the same as a table (`range`, `start`, `end`,
`tail`, `sample_rate` or `rate`, `bits`, `channels` (1, 2, "mono",
"stereo"), `quality`, `bitrate`, `ffmpeg`, `dither`, `normalize`, `loudness`, `tracks = { id, ... }`,
`master`, `threads`) and waits for the file, returning `{ path, frames,
seconds, sample_rate, peak, gain, loudness, format, bits, channels, ... }`;
with `background = true` it returns at once and the events follow:
`render.progress` (`{ path, fraction, seconds, stage }`, a few times a second),
then `render.done` (the table above), `render.failed` (`{ path, error }`) or
`render.cancelled`. `daw.render_status()` gives the running render (`{ path,
fraction, seconds, cancelling, stage, queued }`) and `daw.render_cancel()` stops it;
the window finds the same in `daw.frontend.state().modal.render`.
`daw.render_ranges.chorus = function() return 32, 48 end` adds a named range.
`daw.render_stems(dir, opts)` writes one file per track, which add up to the
mix. `:track.bounce` (`daw.bounce(track, { name = ... })`, which returns the
new track) renders a track with its devices to audio on a new track and mutes
the original. Stems and bounces go through `daw.render`, so `render.before` is
heard. Plugins are told when a render is offline and given a moment to
prepare before it starts: many load what a setting needs in the background,
and would otherwise still be silent when a fast render was over.

**Media files.** A saved project names the sound files inside its own folder
by a path relative to the project file, and files elsewhere by their full
path, so a project folder can be moved or copied whole. On opening, a file
that is not where the project says is looked for relative to the project
(the last steps of its old path), then by name in the project's folder tree
and in the directories where other missing files turned up. Files found
elsewhere make the project modified, so that saving keeps the new place.
What is still missing is reported in one message; its clips stay in the
project, silent, with `offline = true` in their state (`daw.clip(id).offline`,
and in `daw.frontend.state`), and both frontends write "offline" before their
names. Saving keeps the path a missing file was saved with. `:media.relink`
lists the missing files: choose one and then the file it is now (the rest
are then looked for beside it), or choose "Search a directory" and a
directory (`daw.pick.file({ directory = true })`); `:media.relink <dir>` and
`:media.relink <old> <new>` do the same from the command line, and
`:media.missing` lists them. `:media.collect` copies every file from outside
the project's folder into `media` beside it and points the clips at the
copies; the originals stay. `daw.opt.copy_imports = true` makes importing do
that from the start. In Lua: `daw.media.missing()`, `daw.media.list()`
(`{ path, missing, inside }`), `daw.media.relink(old, new)`,
`daw.media.search(dir)`, `daw.media.collect()`; each change is one undo step.
The `media.missing` event (`{ files, found }`) follows opening a project with
files missing or moved. Old projects with full paths open unchanged.

**Sample rates and waveforms.** A sound file at another rate than the
engine's (or than a render's) is converted once when it is loaded, with a
band-limited windowed-sinc resampler (`rubato`, 256 taps): nothing above the
new rate's Nyquist frequency folds back, and a tone keeps its level and
place. Changing the engine's rate converts again. Each file's waveform
overview is kept in `~/.cache/daw/peaks`, named after the file's path, size
and time of change, so that a long file drawn zoomed out after the first
time is drawn from the overview without being decoded.

**Long files are played from the disk.** A file whose decoded sound is
larger than `daw.opt.media_stream` megabytes (64: about three minutes of
stereo at 48 kHz) is not held in memory. It is decoded once, straight into
files in `~/.cache/daw/media` (and converted there, if its rate is not the
engine's), and those are mapped into memory: the engine reads them like any
other samples, the system brings the pages in from the disk and lets them go
again when memory is short, and the kernel asks for the next seconds ahead
of the playhead (and of the loop's start) so that the audio thread does not
wait for the disk. The decoded sound is kept between runs under the
identity of the file it came from, so an hour-long recording opens at once
the second time; the cache is kept within `daw.opt.media_cache` gigabytes
(16), the least recently used going first. `daw.media.list()` says of each
file whether it is `on_disk`. `daw.opt.media_stream = 0` holds every file in
memory, as before. Renders read the same files and are the same to the bit.

**Audio clip operations.** `:clip.reverse` plays the audio clip under the
cursor backwards, from a reversed copy of its part of the file in the
project's `media` folder (its fades change ends). `:clip.normalize -1` brings
its loudest sample to a level by setting its gain. `:clip.glue` joins it and
the audio clips touching or overlapping it on its track into one clip,
playing a new file of what they played together (gains, fades and overlaps,
without the track's devices). None changes the original file; each is one
undo step. In Lua: `daw.media.reverse(clip)`, `daw.media.normalize(clip,
level)`, `daw.media.glue(clip)` or `daw.media.glue({ a, b, c })`.

**Safety copies.** Every `daw.opt.autosave` seconds (60; 0 for none) a project
with unsaved changes is copied to `~/.local/state/daw/recovery`. The copy is
removed when the project is saved or closed with nothing unsaved. One left by a
session that ended badly is announced at the next start, and `:recover` opens
it under the name of the project it was a copy of. `:q` refuses to quit with
unsaved changes; `:q!` quits without them.

**A device that fails.** Each device's processing is guarded on the audio
thread. One that panics is marked failed and passed over from then on (an
instrument falls silent, an effect lets its input through): a
`device.stopped` event says so, as for a plugin whose helper crashed, the
device panel shows it as stopped, and `:device.restart` makes a new one.
Samples that come out of a device as NaN or infinity are replaced by silence
at its output, so they never reach a fader, a meter or the master; a
`device.invalid` event and a message say so once. A panic anywhere else in
the program writes a safety copy of unsaved work to the recovery directory
before the program ends, restores the terminal, and says where the copy is;
`:recover` offers it at the next start.

**What went wrong while playing.** `daw.api.engine_get()` (and
`daw.frontend.state()`, for the window and the status line) counts `xruns`,
`late_blocks` (blocks plugins did not deliver in time), `midi_dropped`
(MIDI events dropped because a queue was full), `record_dropped` (frames of
the take being recorded lost to a slow disk) and `devices_stopped`.
`:engine.status` prints them in one line. Decoded audio that neither the
project nor any undo step uses is let go when another project is opened and
every so often while editing, so a long session does not hold every file it
ever played.

**Saving.** A save writes a temporary file beside the project, flushes it to
the disk, renames it over the project and flushes the directory, so the file
on disk is always either the old project or the new one, whole. The file as
it was before the save is kept beside it as `song.json.bak`. A project that
will not open (cut short, or damaged) is not only an error: the message says
what can stand in for it, and `:recover` lists its newest safety copy and its
`.bak` first. Either opens under the damaged project's name, unsaved, so a
`:w` puts it back. Started with such a project on the command line, the
program starts anyway, with that message. A `.bak` names media relative to
the project, as the project does, so it opens with them.

**For scripts.** `daw.wait(ms)` lets time pass with timers firing and events
delivered, which `daw.api.sleep` does not; a script run with `-l` is otherwise
one long turn. `daw.api.project_shelve()` puts the open project aside whole
(undo tree, playhead, changed flag) and opens an empty one to work in;
`daw.api.project_unshelve()` closes that and brings the first back exactly as
it was, and `daw.api.project_shelved()` says whether one is aside. It is for
tools that need tracks of their own without touching the person's work (the
[doctor](../extensions/doctor) does). `tests/*.lua` and `extensions/*/tests.lua`
are run by the suite, each given the suite's helpers.

## Stretching and looping clips

An audio clip can play its file longer or shorter without changing its
pitch, higher or lower without changing its length, and in time with the
tempo whatever it is; any clip can loop. Each is a field of the clip,
saved with the project, copied, pasted, cut and undone with it.

| Command | |
| --- | --- |
| `:clip.stretch 1.5` | play the file 1.5 times as long (2 is half speed); the clip grows with it |
| `:clip.stretch to=8` | stretch what the clip plays to last 8 beats |
| `:clip.stretch selection`, `:clip.stretch loop` | stretch it over the time selection, or the loop |
| `:clip.stretch reset` | play the file at its own speed again |
| `:clip.pitch 3`, `:clip.pitch -0.5` | play it 3 semitones higher, or a quarter tone lower, at the same length |
| `:clip.tempo`, `:clip.tempo 100`, `:clip.tempo off` | follow the tempo: keep its beats when the tempo changes, its sound being at the tempo it plays at now, or at 100 BPM; or keep its seconds again |
| `:clip.stretch_mode tonal` | how it is stretched: `tonal`, `percussive` or `auto` |
| `:clip.loop`, `:clip.loop 4`, `:clip.loop off` | loop the clip (on and off), repeating 4 beats, or stop |

In the window, drag the right edge of an audio clip with Alt and Shift held
to stretch it to there (on the grid); the clip's menu has "Stretch and
loop" with the rest. A stretched clip says so before its name, in both
frontends: `×1.5`, `+3st`, `♩` (following the tempo), `⟳` (looping), and
`stretching…` while its sound is being made.

**Stretching.** The fields are `clip.stretch` (the ratio, 0.25 to 4),
`clip.pitch` (semitones, fractions allowed, up to 24 either way) and
`clip.stretch_mode`. A stretched or shifted clip does not stretch as it
plays: its file is stretched once, on a thread of its own, and the engine
plays the result as it plays any file. It is made a moment after the last
change (a drag makes it once, when the edge is let go), kept by file,
ratio, shift, mode and sample rate, in the media cache when it is large,
and found there again in later runs. Until it is ready the clip is silent;
a render waits for it. `clip.offset` stays in seconds of the file, so a
second of a clip stretched by 2 is half a second of its file.

There are two ways of stretching, both written for this program in Rust
(`crates/daw-core/src/stretch.rs`). `tonal` is a phase vocoder with
identity phase locking that starts its phases afresh at each onset: for
held and melodic sound, at any ratio. `percussive` overlaps pieces of the
file at its own speed (WSOLA), each placed where it carries on best from
the last, and plays each onset once, whole, where it belongs: for drums and
speech. `auto`, the default, takes a sound with two onsets a second or more
for percussive. Both keep the two channels one image. A pitch shift is a
stretch followed by a resampling, so formants move with the pitch.

**Following the tempo.** A clip in the `stretch` timebase (`:clip.tempo`,
or `clip.timebase = "stretch"`) keeps its start and its length on their
beats when the tempo changes: its stretch changes so that it fits, and its
pitch stays. `clip.source_tempo` is its sound's own tempo: set when the
timebase is turned on (the tempo at its start, times its stretch), by hand
(`:clip.tempo 100` makes a loop recorded at 100 BPM play at the song's
tempo), and by recording, which notes the tempo a take was made at on every
clip it makes.

**Looping.** A looped clip (`clip.loop`) repeats `clip.loop_length` beats of
what it plays over its whole length: drag its end out and the content comes
round again, a notch marking each repeat in both frontends. The length is
by default, when looping is turned on, the clip's length for MIDI and the
rest of its file from where it starts for sound; when it loops, an audio
clip's repeat is measured in seconds at its start, as its sound is.
`clip.loop_start` (0 or less) is where the repeated stretch begins, from
the clip's start. With a loop:

- the repeats are sample for sample the same: audio is played again from
  the same file, a fade of a few milliseconds put at the seams only where
  the sound does not run on into its own start; MIDI notes are played again,
  each cut at the end of its repeat;
- trimming the start turns the loop round instead of running out of file:
  what is left plays where it did, and dragging the start out again brings
  earlier repeats back; Alt and an edge slips the pattern round inside the
  clip;
- a cut gives both pieces the whole loop, each from where it begins, so the
  pieces sound as the clip did (a cut through sound is faded out and in over
  3 ms, as any cut is);
- a fade in belongs to the first repeat and a fade out to the last, each no
  longer than its repeat;
- takes: the playing take's files and the others' are all played through
  the clip's stretch and loop. Comping keeps both on every piece, and
  joins pieces back only where they are stretched, shifted and looped alike
  and the second carries the first's repeats on. In the take lanes the
  playing take is drawn as it plays; another take is its file squeezed or
  spread in time as far as the clip stretches it, repeated as it loops.

In scripts: `daw.stretch.set(clip, 1.5)`, `daw.stretch.to(clip, 8)`,
`daw.stretch.fit(clip, from, to)`, `daw.stretch.reset(clip)`,
`daw.stretch.pitch(clip, 3)`, `daw.stretch.follow(clip, bpm)`,
`daw.stretch.loop(clip, true, 4)`, or the fields themselves
(`clip.stretch = 2` changes the ratio without changing the clip's length).

## Markers and regions

A marker is a named place in the song; a region is a named stretch. They
are on a second row of the ruler (a band of their own in the window), move
with the beats when the tempo changes, and are saved with the project.

| Keys, command | |
| --- | --- |
| `g'`, `:marker Chorus` | a marker at the cursor |
| `:region Verse` | a region over the selection, or over the loop |
| `]'` `['` | the next marker or region start; the one before (motions: `d]'`) |
| `g"`, `:marker.list` | all of them in a list; choosing one goes there |
| `:marker.goto 3`, `:marker.goto Chorus` | by number or by name |
| `:marker.rename Bridge`, `:marker.move`, `:marker.remove` | the one at the cursor |
| `:region.loop Verse` | loop a region |
| `:render out.wav range=Verse` | a region is a range to render |
| `:render.regions out` | every region to a file of its own, `01 Intro.wav` and so on |

In the window: right click on the timeline puts a marker there or makes a
region over the selection or the loop; a click on a marker goes to it, a
drag moves it, its menu renames or removes it and loops a region.
In scripts: `daw.markers.add(16, "Chorus")`, `daw.markers.add(0, "Intro", { length = 16 })`,
`daw.markers.list()`, `daw.markers.find("Chorus")`, `daw.markers.set(id, { beat = 24 })`,
`daw.markers.remove(id)`, `daw.markers.render_regions(dir, opts)`.

## MIDI controllers

A knob, fader or wheel of a MIDI controller can move a track's fader or
pan, or a parameter of a device.

| Command | |
| --- | --- |
| `:learn` | bind what was moved last (or the parameter under the device panel's cursor): then move the controller |
| `:learn volume`, `:learn pan`, `:learn cutoff` | the selected track's fader, pan, or a parameter by name |
| `:learn launch`, `:learn scene`, `:learn stop`, `:learn stop all` | a pad or button that launches the slot under the session view's cursor, its scene, or stops (see [Live performance](live.md)) |
| `:learn.list` | what is bound; choosing one takes it away |
| `:learn.remove 2`, `:learn.remove volume`, `:learn.clear` | take bindings away |

In the window, the plug beside a device's parameter learns it, and a
track's menu has the fader and the pan. The bindings belong to the project
and are saved with it. A move from the controller is a move like any
other: it writes automation when the track's mode says so, and a sweep is
one undo step. A control only takes hold of its target once it has reached
the target's value, instead of jumping it there (`daw.opt.learn_pickup =
false` for jumping). A binding is by controller number and channel; which
port a message came through is not told apart. In scripts:
`daw.learn.bind({ cc = 74, channel = 1 }, { track = t.id, target = "param", device = d.id, param = "cutoff" })`,
`daw.learn.bindings()`, `daw.learn.unbind(n)`, `daw.learn.start(target)`.
