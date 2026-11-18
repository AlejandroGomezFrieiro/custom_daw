# How to route the outputs of a drum plugin

This guide shows you how to give each output of a drum plugin a track of
its own. For each rule, see
[Routing](../reference/routing.md#instruments-with-several-outputs).

1. Add the drum plugin to a track.
2. Open the device panel and select the plugin.
3. Type `:device.spread`. paw makes a track for each output pair that
   plays nowhere, with the name of the pair. paw puts these tracks and the
   drum track in a group.
4. Play the song. Each drum now plays on its own track. The device line
   shows `outs 6/6`.

To route only one pair, press `O` in the device panel, select the pair,
then select the track. Or type `:device.output 2 Kick`.

To remove a route, type `:device.output 2 none`.

In the graphical window, use the Outs row on the card of the device.

The built-in `drums` device also has a pair for each family of drums.
