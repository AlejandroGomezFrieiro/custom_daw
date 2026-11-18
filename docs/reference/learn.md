# MIDI controllers

<!-- tags: learn midi-controllers -->

A knob, a fader or a wheel of a MIDI controller can move the fader or the
pan of a track, or a parameter of a device. A pad or a button can launch a
slot or a scene of the [session view](session-view.md), or stop clips. The
module is `paw.learn`.

## Commands

| Command | Effect |
| --- | --- |
| `:learn` | Wait for a controller, then bind it. The target is the parameter at the cursor of the device panel, the fader at the cursor of the mixer, or the slot at the cursor of the session view. Else the target is the last control that moved. |
| `:learn volume`, `:learn pan`, `:learn cutoff` | Bind the fader, the pan, or a parameter (by key or name) of the selected track. |
| `:learn launch` | Bind a pad that launches the slot at the cursor of the session view. |
| `:learn scene` | Bind a pad that launches the scene of the row at the cursor of the session view. |
| `:learn stop`, `:learn stop all` | Bind a button that stops the clip of the selected track, or every clip. |
| `:learn.cancel` | Stop the wait for a controller. |
| `:learn.param 12 cutoff` | Bind a parameter of a device, by the device id and the parameter key. The frontends use it in their menus. |
| `:learn.list` | Show the bindings in a list. Select one to remove it. |
| `:learn.remove 2`, `:learn.remove volume` | Remove a binding, by its number in `:learn.list` or by its target. |
| `:learn.clear` | Remove every binding. |

`:param.last learn` binds the parameter that moved last (see
[Plugins](plugins.md)).

## Graphical window

- The plug icon next to a parameter of a device binds that parameter.
- The menu of a track has the fader and the pan.

## Behavior

- The bindings are part of the project (`project.meta.learn`). They are
  saved with the project, and undo changes them.
- A move from a controller is the same as any other move of a control. It
  writes automation when the automation mode of the track tells it to (see
  [Automation](automation.md)). One sweep is one undo step.
- Pickup: a control moves its target only after it reaches the value of the
  target. The target does not jump to the value of the control.
  `paw.opt.learn_pickup = false` makes the target jump.
- A binding uses the controller number (or the note) and the channel. paw
  does not compare the port that the message came from.
- A pad that sends notes binds by its note. A pad that sends a controller
  is pressed when the value goes above the middle of its range.
- When you release a pad, a gate clip stops.

## Lua

```lua
paw.learn.bind({ cc = 74, channel = 1 }, { track = t.id, target = "param", device = d.id, param = "cutoff" })
paw.learn.bind({ note = 36, channel = 10 }, { track = drums.id, target = "launch", slot = 0 })
paw.learn.bind({ cc = 20 }, { target = "scene", slot = 1 })
paw.learn.bind({ note = 48 }, { target = "stop" })          -- every clip
```

| Function | Effect |
| --- | --- |
| `paw.learn.bind(source, target)` | Bind a source (`cc` or `note`, and `channel`) to a target. |
| `paw.learn.bindings()` | The list of bindings. |
| `paw.learn.unbind(which)` | Remove a binding, by number or by target. |
| `paw.learn.clear()` | Remove every binding. |
| `paw.learn.start(target)` | Wait for a controller for this target. |

A target is a table: `track`, and `target` (`"volume"`, `"pan"`,
`"param"`, `"launch"`, `"scene"` or `"stop"`), with `device` and `param`
for a parameter, and `slot` (from 0) for a launch or a scene.
