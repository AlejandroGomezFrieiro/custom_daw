# How to fix a plugin editor that does not work

This guide shows you how to repair a plugin editor that is black, ignores
clicks, or is too small. For how paw shows each kind of editor, see
[Plugins](../reference/plugins.md#editors).

## The editor is an empty black window

The toolkit of the plugin did not find the display libraries, or other
libraries that the plugin needs.

1. If you build paw from the source, start it from the dev shell. The dev
   shell sets `PAW_PLUGIN_LIB_DIRS`.
2. If the libraries are in a different directory, add that directory to
   `PAW_PLUGIN_LIBS` before you start paw.
3. Open the editor again with `ge`.

## A Windows plugin ignores clicks in a part of the screen

A Windows plugin through yabridge draws and reads the pointer in Wine, not
in paw. An editor can ignore clicks in a part of the screen, or on one
monitor. Then the Wine server has an old size of the screen. This occurs
when the Wine server continues to run after a change of monitors or of
scale.

1. Close the editors of the Windows plugins.
2. Stop the Wine server of the Wine that yabridge uses: `wineserver -k`.
3. Open the editor again with `ge`. The next plugin starts a new Wine
   server with the correct screens.

## The editor is too small or blurred

1. Set the scale of the editors before you start paw:
   `PAW_UI_SCALE=1.5`. Else paw uses `Xft.dpi`.
2. Start paw again, and open the editor with `ge`.

## An instrument makes no sound until its editor opens

paw opens the editor when you add a plugin by hand, because some
instruments need this. If you set `paw.opt.editor_on_add = false`, open the
editor one time with `ge` after you add the instrument.
