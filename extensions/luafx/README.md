# luafx

Devices written in Lua, to use and to start your own from. Loading the
extension adds them to the device picker beside the built-in ones:

```lua
paw.ext.load("extensions/luafx")   -- or put the directory in ~/.config/paw/extensions
```

| Device | Kind | What it does |
| --- | --- | --- |
| Gain and pan (Lua) | `lua:gain_pan` | a level in dB, a balance, and stereo, mono or swapped sides |
| Drive (Lua) | `lua:drive` | a soft clipper with a low-pass tone control and a dry/wet mix |
| Chords (Lua) | `lua:chords` | a MIDI effect: each note played becomes a chord on it |
| Sine (Lua) | `lua:sine` | an instrument: eight voices of sine with attack and release |

They are the files in `devices/`. An extension ships devices by having that
directory, and needs nothing else for it. To change one, copy it into
`~/.config/paw/devices/` (a script there wins over one of the same name in
an extension) and edit it there: it is loaded again when it is saved, and
the devices made from it keep their parameters. How to write one is in
[How to write a device in Lua](../../docs/how-to/write-a-device-in-lua.md).
