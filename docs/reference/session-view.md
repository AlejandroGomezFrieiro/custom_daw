# The session view

<!-- tags: live launcher live-performance -->

Each track has slots: a column of clips apart from the timeline. You start
and stop these clips while the song plays. A row of slots across the tracks
is a scene. The module is `paw.launcher`. For why paw has this view, see
[About the session view](../explanation/about-the-session-view.md).

## Launch

- A launch starts the clip at the next boundary of its quantize. The
  default quantize is a bar.
- The clip loops while it plays.
- The clip starts on the same frame as the boundary. The engine times the
  launch, not the Lua runtime.
- A launch while the song is stopped starts the clip immediately, and the
  song starts too.
- While a track plays a slot, the clips on its timeline are silent.
- When you stop the clip, the track stays silent. The track plays its
  timeline again when you send it back (`B`), or when the song stops. A
  stop of the song sends every track back.
- A seek, or a turn of the loop, moves each queued launch to the next
  boundary after the new position. Clips that play keep their position in
  their loop.
- A scene launches every clip in its row on one boundary. A track with no
  clip in that row stops its clip. A track that plays its timeline does not
  change.

### Quantize

| Quantize | A launch waits for |
| --- | --- |
| `off` | nothing |
| `1/16` `1/8` `1/4` | the next sixteenth, eighth or quarter note, counted from the start of the bar |
| `beat` | the next beat of the time signature (an eighth in 6/8) |
| `bar` `2bars` `4bars` | the start of the next bar, or of the next group of two or four bars from the first bar |

The project has one quantize (`:launch.quantize`). A slot can have its own
quantize (`:slot.quantize`).

### Launch modes

The mode of a clip sets how the clip obeys the button of its slot.

| Mode | Effect |
| --- | --- |
| `trigger` | A press launches the clip. If the clip plays, it starts again from its start. |
| `gate` | The clip plays while you hold the button: a pad, or the play mark in the graphical window. |
| `toggle` | A press launches the clip. A second press stops it. |

A legato clip (`:slot.legato`) starts at the position in its loop where the
clip that it replaces stopped. A clip that is not legato starts at its own
start.

## Keys

`,l` shows the session view in the terminal. Each track is a column of
slots, and the scenes are on the right. The last row shows what each track
plays: a slot, nothing, or its timeline. A clip that plays is bright and
fills as it goes round its loop. A clip that waits for its boundary has a
mark until it starts.

| Keys | Effect |
| --- | --- |
| `h` `l` | the previous track, the next track |
| `j` `k` | the next slot, the previous slot |
| `gg` `G` | the first slot, the last slot with a clip (with a count: slot N) |
| `0` `$` | the first track, the last track |
| `<CR>` | launch the slot (on an empty slot: stop the track) |
| `L` | launch the scene of the row at the cursor |
| `S` `gS` | stop the clip of the track, stop every clip |
| `s` `M` | solo the track, mute the track (as in every view) |
| `B` `gB` | send the track back to its timeline, send every track back |
| `n` | make a MIDI clip of one bar in the slot (`:slot.new 2` for two bars) |
| `i` | open the notes of the clip in the piano roll |
| `x` `dd` | empty the slot |
| `yy` | copy the clip of the slot into a register |
| `p` | paste a clip into the slot: a clip copied here, or the first clip copied in the arrange view |
| `gp` | copy the clip under the cursor of the arrange view into the slot |
| `m` | the next launch mode |
| `gl` | legato on or off |
| `R` `4R` | record one bar, or four bars, into the empty slot. Again: stop. |
| `grn` | give a name to the scene |
| `C` | capture the launches into the timeline, on or off |

## Graphical window

The Session button shows the session view below the timeline.

| Gesture | Effect |
| --- | --- |
| Press the play mark at the left of a slot | Launch the clip, or stop the track on an empty slot. Release stops a gate clip. |
| Click a slot | Select the slot. |
| Double click a slot | Open its notes in the piano roll. On an empty slot, make a MIDI clip of one bar first. |
| Drag a clip to another slot | Move the clip. With Ctrl: copy it. |
| Drag a clip from the timeline to a slot | Copy the clip into the slot. |
| Click the dot at the right of an empty slot | Record into the slot. |
| Click a scene button | Launch the scene. |
| Click the arrow below a column | Send the track back to its timeline. |

The bar along the top sets the quantize, starts a capture, sends every
track back and stops every clip.

## Record into a slot

`R` on an empty slot (`:slot.record`) records into it. The recording starts
at the next boundary of the quantize of the project. It lasts one bar, or
the number of bars of the count (`4R`, `:slot.record 4`).

- If the track is not armed, paw arms it. The track is silent from the
  boundary while it records.
- The take uses the usual recording, through the input of the track.
- At the end, the part of the take between the two boundaries becomes the
  clip of the slot. The take does not stay on the timeline.
- The clip then plays immediately, in time, as if it started at the bar
  where the recording started.
- `R` again, or a stop of the song, ends the recording early. paw keeps
  what it recorded.
- Punch recording and the pre-roll do not apply while a slot records. A
  count-in plays if the song was stopped. A launch while the song is
  stopped plays immediately, without either.

## Capture

A render plays the timeline: a render does not include the launched clips.
When capture is on (`C`, `:launch.capture`, the Capture button), a stop of
the song writes the performance to the timeline:

- Each part of the song where a track played a slot becomes a looped copy
  of that clip on the timeline of the track. The copy goes from the
  boundary where the clip started to the boundary where it stopped.
- Each part where the track was stopped becomes empty on its timeline.
- The capture is one undo step.

## Commands

| Command | Effect |
| --- | --- |
| `:launch`, `:launch 2` | launch the slot at the cursor, or the slot in row 2, of the selected track |
| `:launch.stop`, `:launch.stop all` | stop the clip of the track, stop every clip |
| `:launch.back`, `:launch.back all` | send the track back to its timeline, send every track back |
| `:launch.quantize 1/8` | set the quantize of the project |
| `:launch.capture` | start a capture, or stop it |
| `:scene`, `:scene 2` | launch the scene at the cursor, or scene 2 |
| `:scene.name Chorus` | give a name to the scene at the cursor |
| `:slot.new` | make a MIDI clip in the slot |
| `:slot.copy` | copy the clip under the cursor of the arrange view into the slot |
| `:slot.delete` | empty the slot |
| `:slot.edit` | open the notes of the clip in the piano roll |
| `:slot.record 2` | record two bars into the empty slot from the next boundary |
| `:slot.mode gate` | set the launch mode (alone: the next mode) |
| `:slot.legato` | legato on or off |
| `:slot.quantize 1/16` | set the quantize of the slot (alone: use the quantize of the project) |
| `:slot.length 2` | set the number of bars that the clip loops over |

For pads and buttons on a MIDI controller, see
[MIDI controllers](learn.md): `:learn` in the session view, `:learn scene`,
`:learn stop` and `:learn stop all`.

## Lua

The clips in slots are usual clips. They are saved with the project and
undo changes them as any edit. In Lua, rows start at 0. On the screen and in
commands, rows start at 1.

```lua
local id = paw.api.clip_add(track.id, { slot = 0, length = 8, notes = { ... }, mode = "gate", quantize = "1/4" })
paw.api.clip_set(id, "row", 2)                -- also "track", "mode", "legato", "quantize"
paw.api.slot_list(track.id)                    -- the clips in its slots, each with `slot`, `mode`, ...
paw.api.clip_to_slot(clip.id, track.id, 1)     -- a copy of a clip in a slot

paw.launcher.launch(track.id, 0)               -- or press(track, row) / release(track, row), by its mode
paw.launcher.scene(1)
paw.launcher.stop(track.id)                    -- with no track, every clip
paw.launcher.back()                            -- every track back to its timeline
paw.launcher.state()                           -- by track: slot or stopped, phase, length, since, queued, at
paw.api.launch({ { track = a, slot = 0 }, { track = b, stop = true }, { track = c, arrangement = true } })
```

| Name | Effect |
| --- | --- |
| `paw.api.clip_add` | With a `slot` field, puts the new clip in that slot. |
| `paw.api.launch` | Sends launches that start together. Each launch can have its own `quantize` and `legato`. |
| `paw.launcher.state` | The state of each track: the slot or stopped, the phase, the length, the start time, the queued launch. |

The names of the scenes are in `project.meta.scenes`.
