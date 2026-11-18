# The device panel

<!-- tags: devices-panel -->

The device panel shows the devices of a track. `,d` shows it. It is a grid
of rows: the heading of a device, then its parameters, then the next
device.

## Keys

| Keys | Effect |
| --- | --- |
| `j` `k` | Go to the next and the previous row. |
| `w` `b` | Go to the next and the previous device. |
| `e` | Goes to the last parameter of the device. |
| `gg` `G` | Go to the first and the last row. |
| `+` `-` | Change the parameter by 1/100 of its range (`10+`, `5 Ctrl-x`). On the row of a device, change its wet mix. |
| `c`, `=` | Types the value of the parameter in its own unit. A choice takes its name. `+2` and `-3` step from the value. |
| `x` | Sets the parameter to its default. On the row of a device, removes the device. |
| `Enter`, `gC` | Open the curve of the parameter in the [curve editor](curve-editor.md). On the row of a device, `Enter` shows the window of the device. |
| `A` | Automates the parameter (`:param.automate`): makes its lane with a point at its value, at the beat of the arrange cursor, and shows the lanes of the track with the cursor on the new lane. |
| `c` | On the row of a device: chooses a preset. |
| `ge` | Shows the window of the plugin. |
| `[p` `]p` | Step through the presets. |
| `,w` | Saves a preset. |
| `,W` | Makes the preset the default of the device. |
| `dd` | Cuts a device. On a parameter, sets it to its default. |
| `yy` | Copies a device. |
| `p` `P` | Paste a device after or before the cursor, also on a different track. |
| `y` over parameters | Copies their settings. Then `p` puts them on the device under the cursor: `yj`, then `p` on a different synth copies two settings. |
| `gcc` | Bypasses the device. |
| `V` | Selects several devices or parameters, for the keys above. |
| `.` | Repeats the last change. |
| `Alt-j` `Alt-k` | Move the device down or up the chain. |
| `f` | Finds a parameter. |
| `t` | Goes to the last parameter that you changed. |
| `gS` | Chooses the track that the device listens to, as its side-chain. |
| `O` | Chooses where the further output pairs of the device play. |
| `K` | Describes the device or the parameter. |
| `s` | Solos the track. |
| `:device.copy_to <track>` | Copies the selected device to a track. |
| `:device.move_to <track>` | Moves the selected device to a track. |

A right click on a parameter offers to automate it, and to open its curve.

In the graphical window, drag a device card by its name onto the header of
a track to move the device there. With `Ctrl`, the drag copies it. A drag
up or down the list changes the order.
