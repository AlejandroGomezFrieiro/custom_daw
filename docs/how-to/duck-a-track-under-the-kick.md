# How to duck a track under the kick

This guide shows you how to make a compressor on the bass react to the
kick (a side-chain). For each rule, see
[Routing](../reference/routing.md#side-chains).

1. Select the bass track and type `:device.add compressor`.
2. Open the device panel and select the compressor.
3. Type `:device.sidechain Kick`, or press `gS` and select the kick track.
   The device line shows `key Kick`.
4. Set `threshold` and `ratio` until the bass ducks on each kick.
5. To hear what the detector hears, set `listen` on. Set it off again
   after.

If you want the kick to key the compressor but not to be heard, mute the
kick and key before its fader: `:device.sidechain Kick pre=1`.

To duck under a plugin compressor, use the same steps. The plugin must
have a side-chain input.

To remove the side-chain, type `:device.sidechain none`.

If paw refuses the side-chain, it makes a loop: for example, the kick
plays into the bass. The message gives the reason.
