# How to switch amp models and presets from paw

<!-- tags: amp-models switch-presets tone3000 soundshed -->

This guide shows you how to change the preset, the amp model and the
impulse response of an amp plugin. You use keys and commands, and you do
not open the window of the plugin. The examples use TONE3000 and Soundshed Guitar.
The same steps work for Neural Amp Modeler and the other plugins that
[plugstate](../../extensions/plugstate/README.md) knows.

The guide assumes a guitar track with the amp plugin on it. See
[How to record a guitar or a bass](record-a-guitar-or-a-bass.md).

## Load the extension

Type `:ext.load plugstate` and press `Enter`. To load it at each start,
see [How to load an extension](load-an-extension.md).

## Step through the presets

1. Put the cursor on the guitar track, and press `,d`. The device panel
   opens.
2. Press `]m`. The plugin loads the next preset, and the message line
   shows its name.
3. Press `[m` to return to the preset before. A count skips more: `3]m`.
4. If you do not like the change, press `u`. The preset before plays
   again.

paw finds the factory presets that come with the plugin. To add your own
presets and packs, add their folder to `paw.opt.plugstate_folders`.

## Find a preset by name

Type `:plugstate.load` and words of the name, then press `Enter`. For
example, `:plugstate.load bogner`. If the words find more than one preset,
a list opens. The selected preset plays while you move in the list.
`Enter` keeps it, and `Esc` puts back the preset before.

## Put a model or an impulse response into a block

1. Type `:plugstate.info` and press `Enter`. Then type `:messages` and
   press `Enter`. The list shows the blocks of the chain, for example
   `block2` or `amp1`.
2. Type `:plugstate.load slot=block2 ~/models/deluxe.nam` and press
   `Enter`. The block plays the model.

A `.wav` file goes into a block in the same way, as an impulse response.
TONE3000 keeps the bytes of the file in the project. Soundshed Guitar
keeps the path of the file, so do not move the file.

## Change the scene of a Soundshed preset

A preset of Soundshed Guitar has up to four scenes, for example `Rhythm`
and `Solo`. To change the scene, type `:plugstate.load slot=scene solo` and
press `Enter`.

## Switch between your own sounds

1. Press `\s` in the device panel. paw keeps the state of the plugin as
   snapshot A.
2. Load another preset or model, and press `\s` again for snapshot B.
3. Press `]v` and `[v` to switch between the snapshots.

The project keeps the snapshots. See
[plugstate](../../extensions/plugstate/README.md#keys) for each key and
command.
