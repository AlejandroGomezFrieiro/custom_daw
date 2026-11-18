# About the session view

The timeline is one fixed order of clips. Some music does not start with a
fixed order. You find a song when you try parts against each other, and you
play some songs live in a different order each time. Ableton Live has a
session view for this, and paw copies the idea. Each track has slots, and
a row of slots across the tracks is a scene.

## Why the engine times a launch

A launch must start on the beat. If the Lua runtime started the clip, the
start would depend on when the main thread runs, and a busy kernel would
start clips late. In paw, the kernel sends the launch to the engine with its
boundary. The audio thread starts the clip on the frame of that
boundary. The main thread can be late by a few milliseconds and the clip
still starts on the beat.

## Why a slot silences the timeline

A track plays one thing at a time: its timeline, or one of its slots. If a
slot added to the timeline, a launch could double a part. So a launched
slot replaces the timeline of its track. A stop does not return the track
to its timeline: the track stays silent until you send it back, or until
the song stops. A performer can then silence a part without a jump to
other music.

## Why a render needs a capture

A render must give the same file each time. Launches are events in time
that a performer makes, and a render cannot play them again. So a render
plays only the timeline. A capture changes the performance into usual clips
on the timeline, and then the render plays it.

## Why slot clips are usual clips

A clip in a slot is a usual clip with a `slot` field. So the piano roll,
undo, copy and paste, and the project file treat it as any other clip. No
part of paw needs a second kind of clip.

See [The session view](../reference/session-view.md) for the keys and
commands, and
[How to record a performance from the session view](../how-to/record-a-performance-from-the-session-view.md).
