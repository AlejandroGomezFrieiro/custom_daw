# Live performance

Besides its timeline, every track has slots: a column of clips kept apart
from the song, to be started and stopped while it plays. A row of slots
across the tracks is a scene. This is what Ableton Live calls the session
view, and it is how a song is played live, or how one is found by trying
parts against each other before they are put on the timeline.

## Launching

Launching a slot starts its clip on the next boundary of its quantize, a
bar unless it says otherwise, and the clip loops for as long as it plays.
It starts on the very frame the bar does: the engine waits for it, not the
program around it. Launched while the song is stopped, a clip starts at
once, and so does the song.

While a track plays a slot, its clips on the timeline are silent. Stopping
the clip leaves the track silent; it plays its timeline again when it is
sent back to the arrangement (`b`, or the arrow under its column in the
window), or when the song stops: stopping the song sends every track back.
A seek, or the loop going round, moves what is queued to the next boundary
from where the song now is; clips that play keep their place in their loop.

| Quantize | A launch waits for |
| --- | --- |
| `off` | nothing |
| `1/16` `1/8` `1/4` | the next sixteenth, eighth or quarter note, counted from the start of the bar |
| `beat` | the next beat of the signature (an eighth in 6/8) |
| `bar` `2bars` `4bars` | the start of the next bar, or of the next pair or four of bars from the first |

The project has one quantize (`:launch.quantize 1/8`); a slot can have its
own (`:slot.quantize 1/16`, `:slot.quantize` for the project's again).

How a clip answers its slot's button is its mode (`:slot.mode`, `m`):

| Mode | |
| --- | --- |
| `trigger` | pressing launches it, again from its start if it plays |
| `gate` | it plays while the button is held: a pad, or the play mark in the window |
| `toggle` | pressing launches it, pressing again stops it |

A legato clip (`:slot.legato`, `gl`) takes over where the clip it replaces
had got to in its loop, instead of starting from its own beginning.

A scene (`L`, `:scene 2`, a scene's button in the window) launches every
clip in its row together, on one boundary; a track with nothing in that row
stops the clip it plays, and a track that plays its timeline is left alone.

## The session view

`,l` shows the session view in the terminal; the window's Session button
shows it under the timeline. Each track is a column of slots, the scenes
are down the right, and the last row says what each track plays: a slot,
nothing, or its timeline. A clip that plays is lit and fills as it goes
round its loop; one waiting for its boundary is marked until it starts.

| Keys | |
| --- | --- |
| `h` `l` `j` `k` | previous, next track; next, previous slot (`gg` `G` first, last) |
| `<CR>` | launch the slot; an empty one stops the track |
| `L` | launch the scene of the cursor's row |
| `S` `gS` | stop the track's clip, every clip (`s` `M` solo and mute the track, as everywhere) |
| `B` `gB` | the track back to its timeline, every track |
| `n` | a new MIDI clip of a bar in the slot (`:slot.new 2` for two) |
| `i` | open the clip's notes in the piano roll |
| `x` `dd` | empty the slot |
| `yy` `p` | yank the slot's clip; paste a clip into the slot (one yanked here, or the first yanked in the arrange view) |
| `gp` | copy the clip under the arrange view's cursor into the slot |
| `m` `gl` | the next launch mode, legato on or off |
| `R` `4R` | record a bar, or four, into the empty slot; again to stop |
| `grn` | name the scene |
| `C` | capture what is launched into the timeline |

In the window, the play mark at the left of a slot is its button: pressing
it launches the clip (or stops the track, on an empty slot) and letting go
stops a gate clip. A click elsewhere on a slot chooses it, a double click
opens its notes in the piano roll, and a double click on an empty slot
makes a MIDI clip of a bar there first. A clip dragged within the session
view moves to another slot (with Ctrl, a copy goes); a clip dragged from
the timeline onto a slot is copied into it. The bar along the top sets the
quantize, captures, sends every track back and stops every clip.

## Recording into a slot

`R` on an empty slot (`:slot.record`, or the dot at the right of an empty
slot in the window) records into it: from the next boundary of the
project's quantize, for a bar, or for as many bars as a count says (`4R`,
`:slot.record 4`). The track is armed if it was not, and goes silent at
that boundary while it records. The take is made by the program's usual
recording, through the track's input; when the bars are done, the part of
it between the two boundaries becomes the slot's clip, the take leaves the
timeline, and the clip plays on at once, in step, as if it had been
playing since the bar the recording began on. `R` again, or stopping the
song, ends it early and keeps what was recorded. Punch recording, and with
it the pre-roll, is set aside while a slot records; a count-in still leads
in when the song was stopped. Launching while stopped plays at once, with
neither.

## Commands

| Command | |
| --- | --- |
| `:launch`, `:launch 2` | launch the slot under the cursor, or a row, of the selected track |
| `:launch.stop`, `:launch.stop all` | stop the track's clip, every clip |
| `:launch.back`, `:launch.back all` | back to the timeline |
| `:launch.quantize 1/8` | where launches land |
| `:launch.capture` | capture what is launched into the timeline, or stop capturing |
| `:scene`, `:scene 2` | launch a scene |
| `:scene.name Chorus` | name the cursor's scene |
| `:slot.new`, `:slot.copy`, `:slot.delete`, `:slot.edit` | make, copy in, empty, open |
| `:slot.record 2` | record two bars into the empty slot from the next boundary |
| `:slot.mode gate`, `:slot.legato`, `:slot.quantize 1/16`, `:slot.length 2` | how the clip launches, and how many bars it loops over |

## From a MIDI controller

Pads and buttons are learned like knobs (see [MIDI controllers](mixing.md#midi-controllers)):
`:learn` in the session view waits for a pad to launch the slot under the
cursor, and `:learn scene`, `:learn stop` and `:learn stop all` for the
other buttons. A pad that sends notes is bound by its note; one that sends
a controller presses when the value goes past the middle. Letting go of a
pad lets go of a gate clip.

```lua
daw.learn.bind({ note = 36, channel = 10 }, { track = drums.id, target = "launch", slot = 0 })
daw.learn.bind({ cc = 20 }, { target = "scene", slot = 1 })
daw.learn.bind({ note = 48 }, { target = "stop" })          -- every clip
```

## Rendering and capturing

A render plays the timeline: what is launched is not rendered. To keep a
performance, capture it: with capture on (`C`, `:launch.capture`, the
Capture button), when the song stops every stretch a track played a slot
becomes a looped copy of that clip on its timeline, from the boundary it
started on to the one it stopped on, and every stretch it was stopped is
cleared there. That is one undo step, and the song then renders as it was
played.

## In scripts

The clips are clips like any other, saved with the project and undone like
any edit; `daw.api.clip_add` puts one in a slot when given a `slot` (rows
count from 0 in scripts, from 1 on screen and in commands).

```lua
local id = daw.api.clip_add(track.id, { slot = 0, length = 8, notes = { ... }, mode = "gate", quantize = "1/4" })
daw.api.clip_set(id, "row", 2)                -- also "track", "mode", "legato", "quantize"
daw.api.slot_list(track.id)                    -- the clips in its slots, each with `slot`, `mode`, ...
daw.api.clip_to_slot(clip.id, track.id, 1)     -- a copy of a clip in a slot

daw.launcher.launch(track.id, 0)               -- or press(track, row) / release(track, row), by its mode
daw.launcher.scene(1)
daw.launcher.stop(track.id)                    -- with no track, every clip
daw.launcher.back()                            -- every track back to its timeline
daw.launcher.state()                           -- by track: slot or stopped, phase, length, since, queued, at
daw.api.launch({ { track = a, slot = 0 }, { track = b, stop = true }, { track = c, arrangement = true } })
```

`daw.api.launch` sends launches that are timed together, each with its own
`quantize` and `legato` if not its slot's. Scene names are kept in
`project.meta.scenes`.
