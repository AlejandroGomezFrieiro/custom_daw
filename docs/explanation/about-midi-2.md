# About MIDI 2.0 in paw

MIDI 1.0 has seven-bit values: 128 steps for a controller, and one pitch
wheel for each channel. A slow filter sweep in 128 steps can sound as
steps, and a bend of one note bends all the notes of the channel. MIDI 2.0
has 32-bit values and controllers for each note. paw keeps all MIDI at the
resolution of MIDI 2.0, and changes it to MIDI 1.0 only at the edge, for a
device or a port that needs MIDI 1.0. For the reference, see
[MIDI](../reference/midi.md).

## Fractions, not steps

A value in a clip is a fraction, not a count of seven-bit steps. A sweep
that you draw or record keeps its full resolution in the project file.
When a device takes only MIDI 1.0, paw rounds the value at that point. So
a better device, or a later version of a plugin, gets the full data from
the same project.

## Controllers for each note

A controller move with a `key` belongs to one note. This is how MIDI 2.0
and the note expressions of CLAP and VST3 work: one note of a chord can
bend while the others stay. paw keeps these moves on the clip as any other
move, and gives them to each device in the best form that the device
takes: note expressions for CLAP and VST3, MIDI 2.0 for a CLAP plugin that
prefers it. A device with only MIDI 1.0 cannot get them, because MIDI 1.0
has no bend for one note.

## Ports: read MIDI 2.0, widen MIDI 1.0

paw opens the ALSA sequencer as a MIDI 2.0 client. A MIDI 2.0 keyboard
then arrives with all its data, and a MIDI 1.0 keyboard arrives as the
same events with less resolution. When the kernel has no MIDI 2.0
sequencer, paw widens MIDI 1.0 by the rules of the specification. So the
rest of paw reads one form of MIDI, from any port and any kernel.

## MPE for MIDI 1.0 synths

A hardware synth with MIDI 1.0 can still play the controllers of each
note, with MIDI Polyphonic Expression. MPE gives each note a channel of
its own, so the pitch bend of the channel is the bend of the note. paw
gives a note the channel that was released first, so that the release
of a note that still sounds does not bend with the next note. The bend
range is 48 semitones, the same as the bend range of a note in paw, so a
bend sounds the same through MPE and through MIDI 2.0.

## Why the audio thread stamps MIDI output

A hardware synth must sound at the same time as the tracks. The audio
thread knows when each message is heard, with the output latency and the
delay of the plugins. It puts this time on the message, and a different
thread schedules it on a sequencer queue. The audio thread never waits
for the sequencer, and the synth sounds in time.
