# About cues

<!-- tags: cue cues clips-off-the-timeline -->

The timeline is one fixed order of clips. Some music does not have a fixed
order: you play parts live, in a different order each time. A cue plays a
clip on a track from a beat, in place of the timeline of the track, until
you stop it. The core of paw has cues. The clip launcher
(`extensions/launcher`) uses them for its slots and scenes. A live looper,
cue points or a step sequencer can use them too.

## Why the engine times a cue

A cue must start on the beat. If the Lua runtime started the clip, the
start would depend on when the main thread runs, and a busy kernel would
start clips late. In paw, the kernel sends the cue to the engine with its
boundary. The audio thread starts the clip on the frame of that boundary.
The main thread can be late by a few milliseconds and the clip still starts
on the beat. A seek, or a turn of the loop, moves a queued cue to the next
boundary.

## Why a cue silences the timeline

A track plays one thing at a time: its timeline, or one clip that is cued.
If a cue added to the timeline, a cue could double a part. So a cue
replaces the timeline of its track. A stop does not return the track to its
timeline: the track stays silent until you send it back, or until the song
stops. A performer can then silence a part without a jump to other music.

## Why a render plays only the timeline

A render must give the same file each time. Cues are events in time that a
performer makes, and a render cannot play them again. So a render plays
only the timeline, and a new engine has nothing cued. To render a
performance, write it into the timeline first. The capture of the clip
launcher does this. Each part that a track played from a cue becomes a
looped copy of the clip on the timeline.

## Why the clips of cues are usual clips

A clip off the timeline is a usual clip of the track, with no place in
time. So the piano roll, undo, copy and paste, and the project file treat
it as any other clip. The data of the clip launcher (the row of a slot, its
mode, the names of the scenes) is in `meta`. So a project opens and plays
without the extension, and keeps the clips. MIDI is the truth: see
[About MIDI as the truth](about-midi-as-the-truth.md).

## The calls

| Call | Effect |
| --- | --- |
| `paw.api.clip_add(track, { cue = true, ... })` | a clip off the timeline. It starts at 0 and loops over its length while it plays |
| `paw.api.cue_list(track)` | the clips off the timeline of a track |
| `paw.api.clip_to_cues(clip, track)` | a copy of a clip, off the timeline of a track |
| `paw.api.cue({ { track =, clip = }, { track =, stop = true }, { track =, timeline = true } })` | cues that start together, each on the boundary of its `quantize` (`bar` when not given) |
| `paw.api.cue_state()` | what each track plays: `clip` or `stopped`, `phase`, `length`, `since`, and what is queued (`queued`, `at`) |

The hook `cue.changed` says that the clips off the timeline of a track
changed. The keys, the commands and the view of the clip launcher are in
its README (`:help launcher`).
