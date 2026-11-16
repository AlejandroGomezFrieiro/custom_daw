# vinput: virtual inputs

A virtual input is a chain that turns something else into an input a track
can take. The kind there is so far turns a guitar into MIDI: play chords or
single notes into the audio interface, and a track hears them as notes, to
play an instrument with or to record.

```
 source            level        gdi2m            notes           MIDI port
 UR22mkII Input 2 ─▶ × 1.20 ─▶ hears the notes ─▶ channel 1 ─▶ “Guitar” ─▶ any track
```

The notes are heard by [gdi2m](https://github.com/maximmashkov1/gdi2m), a
small neural network, as packaged in guitar_tracker. It runs as a program of
its own beside paw: it takes the audio from the port itself and sends
its notes to a MIDI port paw makes for it, so nothing of it runs on the
paw's audio thread.

```lua
daw.ext.load("/path/to/daw/extensions/vinput")   -- or link it into ~/.config/daw/extensions

local vinput = require("vinput")
vinput.add({ name = "Guitar", source = "Input 2", gain = 1.2 })
local track = daw.add_track({ name = "Pad" })
track:add_device("synth")
track.midi_input = { port = "Guitar" }            -- as for any MIDI port
track.armed = true                                -- hear it; record it
```

## What it needs

- **gdi2m** with its model. It is looked for in `daw.opt.vinput_gdi2m`,
  `$GDI2M`, on the `PATH`, and in `~/guitar_tracker/result/bin`.
- **PipeWire**, through which gdi2m finds the audio port and paw's MIDI
  port.
- **A real audio device** in paw. On the null backend the MIDI ports are
  not open, and no tracker is started (`daw.opt.vinput_run = true` starts
  them regardless).
- **A guitar tuned to A440**, dry, straight into the interface. A quarter
  tone out and chords fall apart; this is the tracker's nature, not a
  setting.

## Using it

`<leader>i` (`:vinput`) shows the inputs. In the graphical frontend the
`Track` button and the timeline's menu have "Virtual inputs…" and "New track
from a virtual input", which makes the first input if there is none, a track
that takes it, and shows the inputs so the source can be chosen.

Each input is shown as its chain and what it is doing, with its settings
under it:

| Setting | |
| --- | --- |
| Name | the MIDI port tracks take; renaming it takes the tracks along |
| Source | the audio port the guitar is plugged into, from the ports gdi2m lists |
| Gain | level ahead of the tracker, which was trained at one level (0.1 to 8). After a run in which it heard playing, the tracker says what it would rather have, and `g` or the button beside the slider takes it |
| Threshold | how sure the tracker must be to start a note (0.85): lower finds more notes and more wrong ones |
| Damping | how far the level must fall, in dB, for damped strings to end every note (20); 0 leaves it to the tracker |
| Ringing | how sure the tracker must stay that a note still rings (0.35): lower holds notes longer |
| Velocity | always 100, or as hard as the string was picked |
| Channel | the MIDI channel the notes are sent on |
| Split | notes from a pitch upward on another channel: `E3:2`, or up to three, `E3:2, E4:3` |

| Keys in the panel | |
| --- | --- |
| `j` `k`, `gg` `G` | move along the rows |
| `h` `l`, `H` `L` | less and more of a setting, by one step or ten (a count multiplies); on a heading, off and on |
| `Enter` | on a heading, the input on or off; on a setting, flip it, choose it from a list, or type it |
| `=` | the setting's usual value |
| `o` | the input on or off |
| `s` | choose the source |
| `g` | take the gain the tracker asked for |
| `a`, `D` | a new input; take this one away |
| `t` | a track that takes the input, with an instrument, armed |
| `r`, `R` | start the tracker again; look for audio ports again |
| `Esc` | back to the arrange view |

In the window: a tab for each input and `+ Add`; the chain as boxes (a click
on the source opens the ports, on the port its name, on gdi2m starts it
again); sliders are dragged, nudged with the wheel and put back with a double
click; the bottom line says what the tracker is doing. Every key of the panel
works there too.

| Command | |
| --- | --- |
| `vinput [name]` | show the inputs |
| `vinput.add [name] [source=… gain=…]` | a new guitar-to-MIDI input |
| `vinput.source [part of a port's name]` | choose the source from a list, or set it |
| `vinput.set <setting> <value> [input=name]` | change a setting: `vinput.set threshold 0.8` |
| `vinput.on`, `vinput.off`, `vinput.restart`, `vinput.remove` `[name]` | the input on, off, started again, taken away |
| `vinput.gain [name]` | take the gain the tracker asked for after its last run |
| `vinput.track [name] [instrument]` | a track that takes the input |
| `vinput.status` | what every input is doing |

Any track takes an input where it takes any MIDI port: `in` on its header in
the window, `I` in the terminal, `:track.midi Guitar`.

## What an input is doing

| State | |
| --- | --- |
| off | turned off, or paw has no real audio device |
| not ready | no source chosen, or gdi2m was not found |
| starting | the tracker is being started; it is started again after any change to a setting |
| running | with the level the tracker hears (it wants about −18 dBFS while playing), the notes it has sent, and the milliseconds it takes for each 5.3 ms of sound |
| stopped | the tracker ended four times in a row; what it said is shown. A change to a setting, or `r`, tries again |

While an input is on, its tracker uses about half of one processor core
whether or not anything is played. Turn the input off when it is not needed.

## Where things are kept

The inputs belong to the machine, not to a project: they name audio ports of
this computer. They are kept in `~/.local/state/daw/vinput.json`
(`daw.opt.vinput_file` names another file) and are there at the next start.
A project keeps only the name of the port its tracks take. What each tracker
prints goes to `vinput/<name>.log` beside that file.

## How it works

- `daw.midi.open_port(name)` makes a MIDI port of paw's own. PipeWire
  shows it to other programs as `daw:<name>`, and whatever arrives there
  goes to the tracks that chose `name`.
- The extension runs `gdi2m live --device <source> --port "daw:<name>
  (playback)"` with the input's settings, through `daw.api.proc_spawn`. A
  change to a setting ends that program and starts it with the new values,
  which takes about a second.
- The program is asked to finish (`daw.api.proc_stop`) so that it sends its
  note-offs; if it has to be cut off, the port is made again, which releases
  what was held on it. It also ends when paw does, however paw ends.
- A kind of input is a table in `require("vinput").kinds`: its stages and
  their settings, the command to run, and how to read what the program
  prints. Another kind is added by adding a table.

## What it does not do

- Pitch bends and vibrato: every note is a whole semitone, and two strings
  playing the same pitch are one note.
- Change settings without a gap: the tracker is started again.
- Audio effects ahead of the tracker, or MIDI effects after it: the chain's
  stages are the ones gdi2m has.
- Two DAWs at once with an input of the same name: the tracker cannot tell
  their ports apart and says so.
- Run without PipeWire.
