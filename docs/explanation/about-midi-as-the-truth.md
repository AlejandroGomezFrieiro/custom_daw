# About MIDI as the truth

In paw, the MIDI notes of a clip are the truth. They are what plays, and
every view edits them: the piano roll, Ex, the language servers, MIDI
export, the score of the notation extension. This page tells why paw
keeps one truth, and how extensions keep data that MIDI cannot hold.

## One truth, many views

A score shows more than MIDI can say: the letter name of a pitch (G sharp
or A flat), the voice of a note, a staccato, a dynamic. An easy design gives the score a
model of its own and renders MIDI from it. Then there are two truths. An
edit in the piano roll changes the MIDI, and the score does not know.
The two drift apart, and one of them must win.

paw does not do this. The notes belong to nobody: any view or extension
edits them, and nothing asks or refuses. A score is a view of the notes,
as the notation editor of REAPER is. An edit in the score is an edit of
the MIDI. A note that you enter is a MIDI note at the written place, with
the written length. A dynamic sets the velocities of the notes when you
write it.

After that, the MIDI is free. The piano roll can give a note marked `f` a
different velocity, and the mark stays as a label.

## Data that MIDI cannot hold

An extension keeps its data about a note in `note.meta`, under a key of
its own. `meta.lyric` holds a sung syllable. `meta.notation` holds a
letter name and a voice. It keeps data about a clip in `clip.meta`. The core
keeps this data with the note through moves, copies, undo and project
files.
The core never reads it.

Because the data is on the note, it goes where the note goes. A note
moved, copied or pasted in the piano roll keeps its letter name and its
voice. A deleted note takes its data with it.

## Without the extension

Nothing in the core knows about notation or about sung notes. Without the
extension, a clip written in notation is a MIDI clip like all other clips.
Its notes play, and every view edits them. The data of the extension
stays on the notes and is saved with the project. When the extension
loads again, it shows the notes as they are now, with the data on the
notes that are left.

This is why the rule is strict. If an extension owned the clip data, a
project would need the extension to play. With MIDI as the truth, a
project always plays.

## Attributes are MIDI

A MIDI 2.0 note-on can carry an attribute, for example an articulation of
the orchestral articulation profile. This is not `meta`: it is MIDI. So
the core keeps it, plays it, records it and writes it in MIDI files. The
articulations extension only gives the numbers names for each instrument.
See [Project objects in Lua](../reference/lua-objects.md#note-attributes-noteattr).

## Compared with REAPER

The model is the model of REAPER. MIDI belongs to the item, and notation
shows it. REAPER keeps what MIDI cannot say as notation events on the
notes (spelling, voice, articulation, text) and with the item (dynamics,
clefs, key signatures). paw keeps the same things in `meta`.

One difference: the notation extension reads played music itself
(strums, swing, drift, voices, hands, grace notes, tuplets). REAPER
quantizes for the display only. The settings of the transcription belong
to the clip (`:notation.set`).
