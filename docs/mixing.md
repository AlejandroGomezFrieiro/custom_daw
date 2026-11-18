# Editing, mixing and rendering

## Mixing, MIDI and rendering in the core

**Threads.** Playback and renders use one thread per core (`paw.opt.threads =
4` or `:engine threads=4` for another number, 1 for the audio thread alone,
0 to leave it to the machine; `paw.render(path, { threads = 1 })` for one
render). `paw.api.engine_get().threads` says how many are in use. When the
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
new bar where it is, cutting short a bar it falls inside. `paw.project.tempo`
and the signature fields are the ones at the start, and a project with one
tempo and one signature saves as it always has. The engine follows the map
sample by sample: the playhead, the loop, MIDI clips, automation, the
metronome (the first beat of each bar accented, a click on each beat of the
signature, so six in a bar of 6/8), recording and renders. Plugins are told
the tempo, signature, bar and time at each block (CLAP transport, VST3
process context, LV2 `time:Position`, through the sandbox too).

```lua
paw.tempo.set(17, 96)                    -- 96 BPM from beat 17 on
paw.tempo.set(32, 120, { ramp = true })  -- ramp from 120 at beat 32 to the next change
paw.tempo.set_signature(9, 6, 8)         -- 6/8 from bar 9
paw.tempo.at(40)  paw.tempo.signature_at(40)  paw.tempo.points()  paw.tempo.remove(17)
paw.tempo.beats_to_seconds(16)  paw.tempo.seconds_to_beats(8)  paw.tempo.bar_of(33)
paw.time.format(33.5)                    -- "9.4.00": bar 9, fourth eighth
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

**Groups of tracks.** `paw.groups.make({ violins, violas, cellos }, "Strings")`
(`:track.group Strings` on the selected tracks, `,g`) makes a group: a track
the others belong to. The members play into it, so its fader, mute and
devices act on all of them; they stand under it, a step in and in its
colour; and `za` folds them away into it (`zM` folds every group, `zR` opens
them all). `:track.into Strings` moves a track in, `:track.ungroup` (`,G`)
takes one out or dissolves a group. Groups hold groups. A group is an
ordinary track marked in its `meta`, so it is saved, copied and undone like
any other, and `paw.groups.rows()` is the list of tracks that are drawn:
all but those folded away.

**Linked faders.** `:group.link` (`,vl`) on a group, routed or not, links the
faders of its members: moving one moves the others by as many dB, so their
balance stays (a fader stops at its end, and the others go on). The group's
own fader is left alone. It is an option of the group, kept in its `meta`
(`paw.groups.link(group, true)`), and one undo step undoes the whole move.

<!-- tags: narrowing scope -->
**Narrowing to a group.** In a large project, `:narrow Strings` (`zn` on a
group's header or on one of its tracks) opens a tab that holds that group and
every track inside it, however deep, and nothing else, much as REAPER opens a
subproject; `:widen` (`zw`) closes it and goes back to the tab it came from,
and `gt` goes between them as between any tabs. It is the same project with
one undo tree: an edit made in the narrowed tab is undone from any other. In
that tab the arrange view, the mixer, the device panel, the session view,
`paw://tracks`, the pickers, the track motions (`gg`, `G`, `j`) and the Ex
ranges see only those tracks (`t1` is the group, `t*` and `%` are its tracks,
`:g` and `:s` look in them alone); the group's own fold is open there. The
status line says `narrowed Strings`, the tab is named after the group, and a
track added there goes into the group. Several groups can be open at once,
each in a tab of its own, and `:narrow` of one that has a tab goes to it. The
window shows the tab as the terminal does. What the rest of the song does
while a narrowed tab is in front is `:set scope_rest=`: `play` (the default)
plays it as a reference, `mute` silences it (as a solo of the group would,
so what the group's sound passes through still plays; the project's mutes
and solos are not touched), and `frozen` renders each part of the rest in the
background (each whole group, and each track outside a group) and plays the
files, so that their devices rest; a part edited meanwhile plays live until it
has been rendered again, and the files are let go when the tab is no longer
in front. Neither changes the project. In Lua: `paw.scope.narrow(group)`,
`paw.scope.widen()`, `paw.scope.current()`, `paw.scope.tracks()` (what the
current tab sees), `paw.scope.contains(track)`; a tab's scope is its
`scope` field. `paw.api.engine_audible(ids)` and `paw.api.engine_hold(track,
file)` are what `mute` and `frozen` use, and are there for scripts too.

<!-- tags: freezing frozen -->
**Freezing.** `:freeze` renders the track at the cursor, or a group with
every track inside it, in place, and from then on plays that file instead of
its clips and devices, whose processing rests: a heavy instrument costs
nothing while it is frozen. `:freeze Strings` names one, `:t2,t4freeze` takes
a range, `tail=4` renders 4 seconds after the end (2 by default), and
`:unfreeze` plays the clips and devices again (on a track inside a frozen
group it unfreezes the group). The freeze is taken before the fader: the
fader, pan, mute and sends stay live, so the mix can go on around a frozen
track (to print the fader as well, `:track.bounce`). The tracks inside a
frozen group are held: silent, their devices resting, since the group's file
holds their sound; a send from one of them to a track outside the group is
not heard while the group is frozen. The arrange view marks a frozen track's
header `F`, and `f` on each track held inside one. The freeze is kept in the track's
`meta` (`frozen = { file }`), so it is one undo step and saved with the
project; the file goes to the project's `media` folder and is named relative
to the project as recordings are. Clips, notes and devices are not touched,
and editing them on a frozen track asks once whether to unfreeze it (the
edit is kept either way, and heard when the track is unfrozen). A render of
the song plays the frozen file, and sounds as it did before freezing (the
suite compares them sample by sample). Changing the tempo does not render it
again: unfreeze and freeze. In Lua `paw.freeze.freeze(track, { tail = 2 })`,
`paw.freeze.unfreeze(track)`, `paw.freeze.state(track)` (`"frozen"`,
`"held"` or nil), and `paw.render(path, { freeze = id })` renders what a
freeze of `id` would (the core's crates/paw-core/src/freeze.rs). The
extensions/utau vocal freeze is its own, as it waits for the singing.

**VCAs.** A VCA is a fader, a mute and a solo that belong to other tracks
without carrying their sound, as on a desk. `:vca.make Drums` (`,vn`) makes
one over the selected tracks (or the cursor track), `:vca.assign Drums`
(`,va`; alone it asks) puts the selected tracks under one, `:vca.release`
(`,vr`) takes them out of one or of all, and `:vca.dissolve` (`,vx`) takes a
VCA away. Nothing is routed: the tracks play where they played. Moving the VCA
fader moves each member by that many dB without changing the member's own
fader; the VCA's mute mutes them and its solo solos them (their own mute and
solo are not touched). A track may be under several VCAs, and the gains add in
dB. The VCA's fader has automation like a track's (`:automation`, `,al`): its
lanes add to each member's own, in dB, so a member's level is its fader, plus
its lane, plus every VCA's fader or lane. In a script:

```lua
local drums = paw.vca.make({ kick, snare, hats }, "Drums")
drums.volume = -3                 -- every member 3 dB quieter
drums:automate("volume"):set_points({ { 0, 0 }, { 16, -12 } })
paw.vca.assign(room, drums)       -- also `unassign`, `members`, `of`, `dissolve`
```

A VCA is an ordinary track marked in its `meta` (and each member names its
VCAs in its own), so it is saved, copied and undone like any other; it has no
devices and plays nothing, and `paw.groups.rows()`, so the arrange view and
the window, put the VCAs after the other tracks. The sync folds the VCAs into
each member: a fixed fader into the member's gain, and lanes into one lane for
the member, which is the sum of the lines in dB (a point wherever any of them
has one). The audio thread plays that as it plays any lane, sample by sample,
so a render hears what playing does, on any number of threads. In the
terminal mixer VCAs have strips after the tracks, naming the tracks under
them, and a track's strip names its VCAs; in the window the same, and the
right-click menus of a track's header and of a mixer strip make, assign and
release VCAs.

**Outputs and sends from the keyboard.** `:track.output Drum bus` (`,o` for
a list) plays the track into another, `:send Reverb -9` (`,s` for a list;
`pre=1` for ahead of the fader) sends its sound to one as well (at -12 dB
unless told, or at `paw.opt.send_level`; the list offers the tracks with no
instrument of their own, the returns, first), and
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
device, `gS` there chooses from a list, and the panel shows `key Kick` on the
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
`:device.spread` (`paw.routes.spread(kit)`) makes a track for each pair that
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
delay off the start of the file. `paw.api.engine_get().latency` is how far the
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
paw.on("midi.in", function(e) end)       -- everything that arrives at a port, for scripts; `e.port` names the port
paw.midi.ump({ type = "cc", number = 74, value = 1 })   -- as a MIDI 2.0 packet: two words
paw.midi.inject_ump({ 0x40903c00, 0xc0000000 })         -- and a packet, as if from a port
```

They are recorded with the notes, chased when playback starts in the middle,
kept through cutting, joining, copying and undo, and saved exactly. Where they
go: the built-in synth follows the wheel, the sustain pedal and a note's own
bend; CLAP plugins get a note's own controllers as note expressions and the
rest as MIDI 2.0 if they take it, else MIDI 1.0; VST3 plugins get note
expressions and poly pressure, and controllers through the parameters they
assign to them; LV2 plugins, and CLAP plugins that take only MIDI 1.0, get
MIDI 1.0, which has no per-note bend: a note's own controllers do not reach
them (MPE for them, as for a MIDI output, is not there yet).
A note's MIDI 2.0 attribute (an articulation, `note.attr`: see
[Scripting](scripting.md)) is recorded from a MIDI 2.0 note-on, said in a
`midi.in` event as `e.attr`, sent on in MIDI 2.0 ports' note-ons, and
reaches CLAP plugins that prefer MIDI 2.0 notes and Lua devices; a
track's `attr_map` turns it into keyswitches and controllers for the rest.

**Editing controller moves.** The strip under the window's piano roll shows
the velocities or one controller, chosen from its dropdown. A controller is
drawn with the pointer held down; the right button dragged draws a straight
line, a move to each grid step (Shift: each 32nd of a beat); a click on a
move's head chooses it (Ctrl adds or takes it out) and Ctrl and a drag
chooses the moves in a box; dragging a chosen head moves them all in time
and value, landing on the grid; `Delete` or `x` removes them, and a right
click opens a menu (choose all, let go, delete, clear the controller).
`:controls.line cc 74 0 127` draws a line over the piano roll's selection,
or its whole clip, from the terminal (`bend -8192 8191`, `pressure 0 127`).

The event list shows every note and move of the clip in the piano roll, a
row each in time order: its time (bar.beat.hundredths), kind (`note`, `cc`,
`bend`, `pressure`, `registered`, `assignable`, `program`), which (a note's
pitch, a controller's number, the note a move belongs to), value (a
velocity; seven-bit steps with the finer part as decimals; the wheel from
-8192 to 8191; a note's own bend in semitones) and length. `E` in the piano
roll (`:notes.list`) floats it over the terminal; the window's piano roll
opens it in a window of its own with List. `j` `k` `h` `l` move, `Enter`
changes the cell under the cursor (or a double click), `x` deletes the row,
`a` adds a move at its time, `u` undoes, `q` closes. Scripts have the same
through `paw.controls` (`rows`, `cells`, `edit`, `select_box`, `move`,
`line`).

At the ports the program opens as a MIDI 2.0 client and reads Universal MIDI
Packets, so a MIDI 2.0 device arrives whole and a MIDI 1.0 device arrives as
the same events with less detail. That needs a kernel built with
`CONFIG_SND_SEQ_UMP`; without it the ports are MIDI 1.0, and what arrives is
widened by the specification's rules so that both read the same. There is no
MIDI-CI (see What is missing).

**MIDI output to hardware.** A track sends what it plays (its clips' notes
and controllers, and MIDI input passing through it, before its devices) to
a port: `track.midi_output = { port = "UM-ONE: UM-ONE MIDI 1", channel = 2 }`
(`channel` nil keeps each message's own), `:track.midi_out UM-ONE 2` (part
of the name will do; `none` for none), or the MIDI out entries of the input
list (`I`) and of the window's input menu on the track's header.
`paw.midi.outputs()` lists the ports.

What goes out is MIDI 2.0 where the port takes it: when the sequencer has
MIDI 2.0 (`CONFIG_SND_SEQ_UMP`) and the port's program speaks it, the notes,
their own bends and controllers and every value go whole, as Universal MIDI
Packets. Elsewhere it is MIDI 1.0, in the form the route asks for, `form` in
`track.midi_output` (also `:track.midi_out UM-ONE 2 mpe`, and the MIDI out
form entries of the input list and the window's input menu):

- `auto` (the default): MIDI 2.0 where the port takes it, else plain.
- `plain`: MIDI 1.0 as each message has it, in seven bits; a note's own bend
  and controllers are left out, its pressure goes as poly pressure.
- `mpe`: MIDI Polyphonic Expression. Each note gets a channel of its own in
  the lower zone (channel 1 for what is the whole instrument's, `members`
  channels from 2 on, 15 unless said), so that its own bend, pressure and
  brightness (controller 74) are its channel's pitch bend, pressure and
  controller 74. The zone is announced first (MPE's configuration message)
  with a bend range of 48 semitones, which is a note's own bend range here.
  A note takes the channel let go of longest ago, so that a release still
  sounding is not bent by the next note; with every channel busy it shares
  the one with fewest notes. What comes for a note before it starts is sent
  on its channel just before it.
- `cc14`: control changes 0 to 31 as pairs of fourteen bits, the fine part
  on 32 to 63.

On this machine's kernel, without `CONFIG_SND_SEQ_UMP`, only the MIDI 1.0
forms can be tried; the MIDI 2.0 path is the same packets the plugins and
the tests' codec use, untried through a sequencer. The audio thread stamps each message
with when it is heard (the output's latency and the plugins' delay
included) and hands it over a lock-free queue to a thread that schedules it
on an ALSA sequencer queue in real time, so a synth on the port sounds with
the tracks. Stopping, jumping and going round the loop end the notes that
are sounding there, with an All Notes Off on their channels; so do taking
the port away and removing the track. Renders send nothing. Ports are
opened when MIDI input is (with an audio device, or `engine_restart({ midi =
true })`). `paw.midi.open_output("To Surge")` makes a port of the program's
own that other programs read from (`paw out: To Surge`), and a track that
sends to `To Surge` plays them; `paw.midi.close_output` takes it away.
Copies of the track send where it does; templates and project files keep
the port by name.

**Recording offset.** What is played along to the song is heard late and
arrives late. Takes are moved earlier by what the audio system reports, plus
`paw.transport.record_offset` milliseconds for what it does not: record the
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
pointer holds it (`paw.api.automation_hold`); anything else counts as held
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
by name before anything is rendered; `paw.api.render_formats()` lists what
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
`"encoding"`; a render in the foreground says `render.finished`). Each
render is a subject language servers can be shown, so a delivery or settings
check can look at every render and say what it finds as diagnostics with
fixes (extensions/midilsp runs MIDI LSP's; see
[Language servers and diagnostics](lsp.md)); so can a server for the mix,
which is shown every track's fader, pan, sends and devices, and
extensions/mixdiag's findings are diagnostics on the tracks they name. Opus holds only 48 kHz and the usual lower rates, so ffmpeg
resamples to 48 kHz; MP3 above 48 kHz is resampled to 48 kHz too. The project's
name is the file's title tag (see "Tags" below). `ffmpeg` is the program found on the PATH; set
`paw.opt.ffmpeg = "/path/to/ffmpeg"` to name another. Without it, or with an
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

### Tags

A rendered file carries a title, artist, album, track number, year, genre,
comment and a cover picture, when they are set. They belong to the project,
which keeps them (`project.meta.tags`, saved with it) for every render:

```
:render.tags artist=Ana album="First one" track=3/12 year=2026 genre=Ambient comment="a note" cover=cover.png
:render.tags                  " what is set
:render.tags genre=           " an empty value takes one out
```

In Lua `paw.render_tags()` gives the table and `paw.render_tags({ artist = "Ana" })`
sets those fields and keeps the others. `:render` takes the same words
(`:render mix.mp3 artist=Bo`) and `paw.render` a `tags` table, for that file
only; they go over the project's. The title of an MP3, Ogg or Opus file is the project's name unless one
is given, and a lossy stem's is its track's name. A relative `cover` is from the
project's directory; it must be a PNG or JPEG file of at most 8 MiB, and a
render that cannot read it is refused before anything is rendered. The
window's render dialog has them under Tags, and what is typed there becomes
the project's.

Each format holds them its own way: a WAV in a `LIST` chunk of `INFO`
(`INAM`, `IART`, `IPRD`, `ITRK`, `ICRD`, `IGNR`, `ICMT`), a FLAC in Vorbis
comments and a `PICTURE` block, MP3 in ID3v2.3 with the cover as an attached
picture, and Ogg Vorbis and Opus in Vorbis comments, the cover in
`METADATA_BLOCK_PICTURE`. The last three are written by ffmpeg, which is
handed the tags in a file, not on its command line. A WAV has no cover that
players read, so none is written to it.

`paw.render(path, opts)` takes the same as a table (`range`, `start`, `end`,
`tail`, `sample_rate` or `rate`, `bits`, `channels` (1, 2, "mono",
"stereo"), `quality`, `bitrate`, `ffmpeg`, `dither`, `normalize`, `loudness`, `tracks = { id, ... }`,
`master`, `threads`, `tags`) and waits for the file, returning `{ path, frames,
seconds, sample_rate, peak, gain, loudness, format, bits, channels, ... }`;
with `background = true` it returns at once and the events follow:
`render.progress` (`{ path, fraction, seconds, stage }`, a few times a second),
then `render.done` (the table above), `render.failed` (`{ path, error }`) or
`render.cancelled`. `paw.render_status()` gives the running render (`{ path,
fraction, seconds, cancelling, stage, queued }`) and `paw.render_cancel()` stops it;
the window finds the same in `paw.frontend.state().modal.render`.
`paw.render_ranges.chorus = function() return 32, 48 end` adds a named range.
`paw.render_stems(dir, opts)` writes one file per track, which add up to the
mix (to the last bit through sends, returns and buses that only filter, delay
or mix; a compressor or a limiter on a bus they share hears each stem alone,
and acts on it as it would not on the sum, so there they differ a little). `:render stems` writes one file per group instead, each named after it,
into `<project> stems` (or `:render stems out`): every group at the top and
every track outside a group that has clips, each with what its sound passes
through, so that they add up to the mix too. It first shows the plan, each
file and the tracks it holds, and renders on `y` or `Enter` (`n` or `Esc`
leaves it). `:render stems tracks` makes one per track; `:render Strings`
renders one group to `Strings.wav` beside the project; in a narrowed tab,
`:render stems` writes the parts of its group. The options of `:render`
apply (`format=flac`, `tail=`, `bits=`, `master=false`, ...). In Lua
`paw.stems.plan({ dir, format, tracks, group })` gives the list
(`{ id, name, file, holds }`) and `paw.stems.render(plan, opts)` writes it. `:track.bounce` (`paw.bounce(track, { name = ... })`, which returns the
new track) renders a track with its devices to audio on a new track and mutes
the original. Stems and bounces go through `paw.render`, so `render.before` is
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
project, silent, with `offline = true` in their state (`paw.clip(id).offline`,
and in `paw.frontend.state`), and both frontends write "offline" before their
names. Saving keeps the path a missing file was saved with. `:media.relink`
lists the missing files: choose one and then the file it is now (the rest
are then looked for beside it), or choose "Search a directory" and a
directory (`paw.pick.file({ directory = true })`); `:media.relink <dir>` and
`:media.relink <old> <new>` do the same from the command line, and
`:media.missing` lists them. `:media.collect` copies every file from outside
the project's folder into `media` beside it and points the clips at the
copies; the originals stay. `paw.opt.copy_imports = true` makes importing do
that from the start. In Lua: `paw.media.missing()`, `paw.media.list()`
(`{ path, missing, inside }`), `paw.media.relink(old, new)`,
`paw.media.search(dir)`, `paw.media.collect()`; each change is one undo step.
The `media.missing` event (`{ files, found }`) follows opening a project with
files missing or moved. Old projects with full paths open unchanged.

**Sample rates and waveforms.** A sound file at another rate than the
engine's (or than a render's) is converted once when it is loaded, with a
band-limited windowed-sinc resampler (`rubato`, 256 taps): nothing above the
new rate's Nyquist frequency folds back, and a tone keeps its level and
place. Changing the engine's rate converts again. Each file's waveform
overview is kept in `~/.cache/paw/peaks`, named after the file's path, size
and time of change, so that a long file drawn zoomed out after the first
time is drawn from the overview without being decoded.

**Long files are played from the disk.** A file whose decoded sound is
larger than `paw.opt.media_stream` megabytes (64: about three minutes of
stereo at 48 kHz) is not held in memory. It is decoded once, straight into
files in `~/.cache/paw/media` (and converted there, if its rate is not the
engine's), and those are mapped into memory: the engine reads them like any
other samples, the system brings the pages in from the disk and lets them go
again when memory is short, and the kernel asks for the next seconds ahead
of the playhead (and of the loop's start) so that the audio thread does not
wait for the disk. The decoded sound is kept between runs under the
identity of the file it came from, so an hour-long recording opens at once
the second time; the cache is kept within `paw.opt.media_cache` gigabytes
(16), the least recently used going first. `paw.media.list()` says of each
file whether it is `on_disk`. `paw.opt.media_stream = 0` holds every file in
memory, as before. Renders read the same files and are the same to the bit.

**Audio clip operations.** `:clip.reverse` plays the audio clip under the
cursor backwards, from a reversed copy of its part of the file in the
project's `media` folder (its fades change ends). `:clip.normalize -1` brings
its loudest sample to a level by setting its gain. `:clip.glue` joins it and
the audio clips touching or overlapping it on its track into one clip,
playing a new file of what they played together (gains, fades and overlaps,
without the track's devices). None changes the original file; each is one
undo step. In Lua: `paw.media.reverse(clip)`, `paw.media.normalize(clip,
level)`, `paw.media.glue(clip)` or `paw.media.glue({ a, b, c })`.

**Safety copies.** Every `paw.opt.autosave` seconds (60; 0 for none) a project
with unsaved changes is copied to `~/.local/state/paw/recovery`. The copy is
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

**What went wrong while playing.** `paw.api.engine_get()` (and
`paw.frontend.state()`, for the window and the status line) counts `xruns`,
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

**The file is the same every time.** A project is written as JSON with its
fields in the order the model declares them, its maps by key and its numbers
with the fewest digits that read back exactly, so saving a project that did
not change writes the same bytes, and one changed thing is a small diff.
`paw.api.project_file_text(file)` writes a project given as data the same
way (and refuses one that would not open), and `paw.api.undo_project(id)`
is a state of the undo tree as a project file holds it. extensions/projdiff
builds on both: a diff and a three-way merge of projects, and the drivers
that let version control use them.

**For scripts.** `paw.wait(ms)` lets time pass with timers firing and events
delivered, which `paw.api.sleep` does not; a script run with `-l` is otherwise
one long turn. `paw.api.project_shelve()` puts the open project aside whole
(undo tree, playhead, changed flag) and opens an empty one to work in;
`paw.api.project_unshelve()` closes that and brings the first back exactly as
it was, and `paw.api.project_shelved()` says whether one is aside. It is for
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
| `:clip.formants`, `:clip.formants on`, `off` | keep its formants when its pitch is shifted (on and off) |
| `:clip.warp`, `gw` | put a warp marker at the cursor, pinning the sound there |
| `:clip.warp move`, `:clip.warp move 2`, `:clip.warp move 2 8.5` | move the warp marker nearest the cursor (or marker 2) to the cursor (or to beat 8.5) |
| `:clip.warp remove`, `gW`; `:clip.warp snap`; `:clip.warp clear` | take off the marker nearest the cursor; move every marker onto the grid; take them all off |
| `:clip.loop`, `:clip.loop 4`, `:clip.loop off` | loop the clip (on and off), repeating 4 beats, or stop |

In the window, drag the right edge of an audio clip with Alt and Shift held
to stretch it to there (on the grid); double click its top band for a warp
marker, and drag the marker's handle; the clip's menu has "Stretch and
loop" with the rest. A stretched clip says so before its name, in both
frontends: `×1.5`, `+3st`, `♩` (following the tempo), `⟳` (looping), and
`stretching…` while its sound is being made.

**Stretching.** The fields are `clip.stretch` (the ratio, 0.25 to 4),
`clip.pitch` (semitones, fractions allowed, up to 24 either way) and
`clip.stretch_mode`. A stretched or shifted clip does not stretch as it
plays: its file is stretched once, on a thread of its own, and the engine
plays the result as it plays any file. It is made a moment after the last
change (a drag makes it once, when the edge is let go), from its start,
into room laid out for all of it, and the clip plays it as far as it is
made: it is made many times faster than it plays, so a long file is heard
at once. Played past where it has got (the playhead put far into a long
clip just changed), the clip fades out just before that point, is silent,
and fades in again where the making catches up; `clip.made` says how much
is made, from 0 to 1. A render waits until it is all made, and is the same
whenever it is asked for. The version is kept by file, warp, shift, mode,
formants and sample rate, in the media cache when it is large, and found
there again in later runs. `clip.offset` stays in seconds of the file, so
a second of a clip stretched by 2 is half a second of its file.

**Warp markers.** A warp marker pins a moment of the file to a place in the
clip, so that the parts of the sound between markers are each stretched by
their own amount: put one on each beat of a loosely played part and move
each onto its beat, or snap them all (`:clip.warp snap`). Putting one
changes nothing; moving one stretches the sound between it and its
neighbours and nowhere else: where there is no marker between it and the
clip's start or end, that edge is pinned with a marker of its own first.
A marker goes no further than a stretch of 0.25 to 4 on either side
allows. In the terminal a marker is a line down the clip, on the cell's
left edge; in the window a yellow line with a handle on the clip's top band.
They are `clip.warp`, a list of `{ source, target, beat }`: `source` is the
moment of the file in seconds, `beat` where it plays now, and `target`,
what is saved, is where the moment would be heard with no markers, in
seconds of the file before the clip's stretch, which still applies to the
whole. They are saved, copied and cut with the clip, undone as any edit,
and stay pinned to the file when the clip is trimmed or slipped. In
scripts: `paw.stretch.warp_add(clip, beat)`, `paw.stretch.warp_move(clip, i,
beat)`, `paw.stretch.warp_remove(clip, i)`, `paw.stretch.warp_snap(clip)`,
or `clip.warp = {}` to take them all off.

There are two ways of stretching, both written for this program in Rust
(`crates/paw-core/src/stretch.rs`). `tonal` is a phase vocoder with
identity phase locking that starts its phases afresh at each onset: for
held and melodic sound, at any ratio. `percussive` overlaps pieces of the
file at its own speed (WSOLA), each placed where it carries on best from
the last, and plays each onset once, whole, where it belongs: for drums and
speech. `auto`, the default, takes a sound with two onsets a second or more
for percussive. Both keep the two channels one image. A pitch shift is a
stretch followed by a resampling, so formants move with the pitch, and a
voice shifted far sounds smaller or larger, unless the clip keeps its
formants (`clip.formants`, `:clip.formants`): then the vocoder finds each
frame's spectral envelope (the cepstrum, liftered at 1.5 ms) and moves it
the other way before the resampling moves it back, so that the formants,
which say what vowel is sung, stay where they were while the harmonics
move. A clip that keeps its formants is stretched the `tonal` way whatever
its mode.

**Following the tempo.** A clip in the `stretch` timebase (`:clip.tempo`,
or `clip.timebase = "stretch"`) keeps its start and its length on their
beats when the tempo changes: its stretch changes so that it fits, and its
pitch stays. `clip.source_tempo` is its sound's own tempo: set when the
timebase is turned on (the tempo at its start, times its stretch), by hand
(`:clip.tempo 100` makes a loop recorded at 100 BPM play at the song's
tempo), and by recording, which notes the tempo a take was made at on every
clip it makes. Where the tempo changes inside such a clip (a ramp, or a
change part way), it is not stretched evenly but bent along the tempo map:
each beat of its sound, at `clip.source_tempo`, lands on a beat of the
song (`clip.bent` says so). A looped clip is stretched evenly all the same.


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

In scripts: `paw.stretch.set(clip, 1.5)`, `paw.stretch.to(clip, 8)`,
`paw.stretch.fit(clip, from, to)`, `paw.stretch.reset(clip)`,
`paw.stretch.pitch(clip, 3)`, `paw.stretch.follow(clip, bpm)`,
`paw.stretch.loop(clip, true, 4)`, or the fields themselves
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
In scripts: `paw.markers.add(16, "Chorus")`, `paw.markers.add(0, "Intro", { length = 16 })`,
`paw.markers.list()`, `paw.markers.find("Chorus")`, `paw.markers.set(id, { beat = 24 })`,
`paw.markers.remove(id)`, `paw.markers.render_regions(dir, opts)`.

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
the target's value, instead of jumping it there (`paw.opt.learn_pickup =
false` for jumping). A binding is by controller number and channel; which
port a message came through is not told apart. In scripts:
`paw.learn.bind({ cc = 74, channel = 1 }, { track = t.id, target = "param", device = d.id, param = "cutoff" })`,
`paw.learn.bindings()`, `paw.learn.unbind(n)`, `paw.learn.start(target)`.
