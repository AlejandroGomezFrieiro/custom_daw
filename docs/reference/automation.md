# Automation

<!-- tags: automation automation-modes lane-write -->

Automation lanes move a fader, a pan or a parameter while the song plays.
This page describes the automation modes, which write lanes when you move
a control. For the keys that draw and edit lanes, see
[Keys, by idea](keys.md). For the steps, see
[How to write automation with the faders](../how-to/write-automation-with-the-faders.md).

## Automation modes

Each track has an automation mode: `track.automation`.

| Mode | While the song plays |
| --- | --- |
| `read` | Default. The lanes play. A move of a control writes nothing. |
| `touch` | A control writes while you hold or move it. When you release it, the lane controls it again, and the written part joins the lane. |
| `latch` | A control writes from its first move until the song stops. |
| `write` | Each lane of the track is written from where the song starts to play, with or without a move. |
| `off` | The lanes stay but do not play. The fader, the pan and the parameters stay where you set them. |

| Keys, command | Effect |
| --- | --- |
| `:automation touch` | Set the mode of the track. |
| `:automation read all` | Set the mode of every track. |
| `:automation`, `,am` | The next mode. |
| `:lane.write`, `,aw` | Write on, for the full song. Again: off. `:lane.write off`: off. |
| `,al` | Select what to automate, and show its lane. |

In the graphical window, the `A` flag on the track header shows the mode.

## Rules

- A control is a fader, a pan or a parameter. A move can come from the
  keyboard, a frontend, a MIDI controller or the editor of a plugin.
- paw writes into the lane at the playhead, over what the lane had there.
  If there is no lane, paw makes one.
- In the graphical window, a control is held while the pointer holds it
  (`paw.api.automation_hold`). Any other control counts as held for a
  little more than half a second after its last move.
- While `:lane.write` is on, each track that does not write in its own
  mode latches.
- The track header in the terminal shows `T`, `L` or `W` in red while a
  track writes, and `-` when its automation is off.

## Undo of a control move

A fader that you drag in the graphical window, or a knob on a controller,
sets its value many times each second. paw makes the moves of one control
that come less than one second apart into one undo step. So one undo
removes the full sweep. Each command and each key is one step.
