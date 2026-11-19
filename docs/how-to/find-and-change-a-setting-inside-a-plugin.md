# How to find and change a setting inside a plugin

This guide shows you how to see the saved state of a plugin. Then you
find where it keeps a setting, and change that setting from paw. It works for plugins
made with JUCE, DPF, iPlug2, LSP, Dplug and nih-plug, and for LV2
plugins. It assumes that the plugin is on a track and that the
[plugstate](../../extensions/plugstate/README.md) extension is loaded
(`:ext.load plugstate`).

## See the state of the plugin

1. Open the device panel and put its row on the plugin.
2. Type `:plugstate.tree`. paw shows the state as a tree. The first line
   names the framework of the plugin and the layers around its data.
3. To see one part, give its path: `:plugstate.tree /LSP/Parameters`.

`:plugstate.info` also names the framework, with the count of the
parameters that the state holds.

## Find where the plugin keeps a setting

1. Type `:plugstate.mark`. paw keeps the state of the plugin.
2. Change one setting in the window of the plugin.
3. Type `:plugstate.changes`. paw lists the paths that changed, for
   example `set /LSP/Parameters@g_out: 1 → 0.5`.

A list of more than one path can show other values that changed. An
example is the size of the window of the plugin.

## Change the setting from paw

1. Type `:plugstate.path` with the path and the new value:
   `:plugstate.path /LSP/Parameters@g_out 0.5`. paw loads the changed
   state into the plugin as one undo step.
2. To see a value, give only the path: `:plugstate.path /LSP/Parameters@g_out`.
3. To return to the value before, press `u`.

## Keep the change as a preset

1. Type `:plugstate.mark`, and change the settings in the plugin.
2. Type `:plugstate.preset_write ~/quiet`. paw writes the changes after the
   mark to `~/quiet.jucepreset`.
3. To load the preset into this plugin on another track, type
   `:plugstate.load ~/quiet.jucepreset`.
4. To change to the preset at a point of the song, put the cursor there
   and type `:plugstate.at ~/quiet.jucepreset`.

A preset of a JUCE, DPF or LSP plugin goes into each format of the
plugin. For the paths and the forms of each framework, see
[The saved state of plugins](../reference/plugin-state.md).
