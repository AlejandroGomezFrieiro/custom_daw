# Plugins and built-in devices

## Plugins

Installed CLAP, LV2 and VST3 plugins are devices like the built-in ones. Their
kinds are `clap:<id>`, `lv2:<uri>` and `vst3:<name>`; `:devices` lists them, and
`:device.add` takes any part of a kind or name (`:device.add dragonfly hall`).

```lua
local amp = guitar:add_device("lv2:urn:brummer:neuralrack")
local verb = guitar:add_device("clap:michaelwillis.dragonfly.hall")
for _, p in ipairs(verb:info().params) do print(p.key, p.name, p.min, p.max) end
verb:set("dry_level", 80)       -- by key, or by the name the plugin shows
```

- **Where they are found.** `~/.clap`, `~/.lv2`, `~/.vst3`, the Nix profiles and
  `/usr/lib`, or the directories in `CLAP_PATH`, `LV2_PATH` and `VST3_PATH`.
- **Parameters** are listed per instance, with keys made from their names. VST3
  values are normalized to 0..1; CLAP and LV2 use the plugin's own ranges.
- **State** is saved in the project file, restored on load, and carried over to
  offline renders and engine restarts. Parameters set through the project are
  applied on top of it.
- **Editors.** A plugin's own window opens with `device:open_editor()`, `ge` on
  a track or a device in the panel (Enter on a device row too), or the `edit` button in the
  graphical frontend; `device.editor` is `"open"`, `"closed"` or nil. The
  windows belong to the kernel process, so they also work when the UI is a
  terminal. What is changed in an editor is read back: the project shows the
  plugin's value, and stops applying a value of its own for that parameter.
  A plugin added by hand (the device picker, `:device.add`, the window's
  "Add a device" box) opens its editor at once, as REAPER does: some
  instruments make no sound until it has been open. One added by a script,
  by loading a project, or with nobody at the program (`-l`, a kernel no
  window is watching) does not. `daw.opt.editor_on_add = false` turns it off.

  | Editor kind | How it is shown |
  | --- | --- |
  | CLAP, VST3 and LV2 editors for X11 (JUCE, DPF, VSTGUI, Xputty, …) | Embedded in a window of the host's, through XWayland on a Wayland desktop. |
  | LV2 editors in any toolkit that open their own window (`ui:showInterface`, and the older "external UI"): Gtk and Qt among them | They run in their own window. Gtk 3 and Qt ones are native Wayland windows when the toolkit is set up for it. |
  | LV2 editors that are a bare Gtk 2 or Gtk 3 widget | Put in a Gtk window, using the copy of Gtk the editor brings. |
  | CLAP editors that can only float | Left to make their own window, a native Wayland one if they can. |

  Editors are told the screen's scale (`Xft.dpi`, or `DAW_UI_SCALE=1.5`), so
  they are not tiny or blurred on a dense screen. A plugin's X11 mistakes do
  not end the program, and editors that cannot be resized say so to the window
  manager. Not shown: an LV2 editor that is a bare Qt widget with no way to
  show itself.
- **Presets.** A device's settings are saved under a name and loaded again,
  into the same kind of device in any project, as one undo step. `:preset`
  (`c` on a device in the panel) chooses one in a picker, the user's first and
  then the device's own; `:preset Warm` loads one by name or part of it;
  `:preset.next` and `:preset.prev` (`]p` `[p`) step through them;
  `:preset.save Warm` (`,w`) saves the device as it is; `:preset.default`
  (`,W`, or `Ctrl-s` in the picker) makes new devices of that kind added by
  hand start from the one loaded (`:preset.default none` stops that), and
  `:preset.delete` deletes one. In the window, a device's card shows its
  preset between `◀` and `▶`, and a click on the name opens a menu of them
  with "Save as a preset…". The device's own presets are those its format
  lists: CLAP preset discovery (Surge XT's patches, for one), `.vstpreset`
  files in `~/.vst3/presets/<vendor>/<plugin>`, `/usr/share/vst3/presets`,
  `$VST3_PRESET_PATH` and the plugin's bundle, LV2 presets known to lilv,
  and for the built-in devices the tables in `runtime/lua/daw/device_presets.lua`.
  Your presets are JSON files in `~/.local/share/daw/presets/<kind>/`
  (`daw.opt.presets_dir` puts them elsewhere) holding the plugin's state and
  every parameter's value; `defaults.json` beside them names the default of
  each kind. From Lua: `daw.fx.save(device, name)`, `daw.fx.load(device,
  name)`, `daw.fx.presets(device)`, `daw.fx.step(device, 1)`,
  `daw.fx.set_default(kind, name)`.
- **Plugins with hundreds of parameters.** `:param` (`f` in the device
  panel, or the "and N more parameters" line on the window's card) finds one
  by typing part of its name; Enter chooses it in the panel and shows it
  first on the card, which shows sixteen. The parameters chosen this way are
  kept with the device in the project (`Ctrl-x` in that picker stops
  showing one first). The parameter last moved, in the plugin's own window
  or here, is the *last touched*: the device panel goes to it when it moves
  in the plugin's window, the card shows it first, and `:param.last` (`t`)
  goes to it; `:param.last automate` shows its lane, `:param.last learn`
  binds a controller to it.
- **Each plugin runs in a process of its own**, a helper started from the
  same program. A plugin that crashes or hangs is lost alone: the session
  says which one and why, the track plays on (an effect that is gone is
  passed through, an instrument is silent), and `:device.restart` (`R` in
  the device panel, the Restart button in the window) starts it again with
  the state the project last had of it. Audio crosses in shared memory, and
  the audio thread waits for a plugin no longer than about a block lasts, so
  a slow plugin costs its own track a block and not everyone a dropout.
  One that answers no block for two seconds has hung: it is ended and
  reported like one that crashed, and `:device.restart` starts it again.
  A render waits for a plugin's block at most 20 seconds, once; after that
  the plugin is left out of the rest of the render, which says so.
  Every other request has a time limit: a plugin that hangs while it is
  made or saving its state is ended and reported instead of freezing the
  program. Plugin files are looked into in a process of their own too, and
  what is learnt is kept at once, so one that crashes there is only noted.
  A file that crashed or hung while it was looked into (or that was being
  looked into when the program itself was ended) is remembered with its
  modification time and passed over at later starts, with one line saying
  which, until the file changes or `:plugins.rescan` (every file) or
  `:plugins.rescan <name>` (files or plugins with that in their name) asks
  for it again.
  `--plugins-in-process` (or `DAW_PLUGIN_SANDBOX=0`) loads them into the
  program itself, which saves the crossing and gives up the protection.
- **Loading does not hold the program up.** When a project opens or a
  plugin is added, the device is there at once, marked `loading` (an
  instrument silent, an effect passing the sound through), while its helper
  makes it, four at a time. When it is ready it takes its place with its
  saved state and `device.ready` is sent. One that fails, or takes longer
  than 45 seconds, is `stopped` with the reason, like a plugin that crashed,
  and `:device.restart` tries again. A device that is loading or stopped
  keeps the state it was opened with: saving writes that back unchanged.
  Rendering waits for devices that are loading, and refuses, naming the
  device, when one could not be made. A device's `status` (in
  `device:get()` and the frontend's state) is `running`, `loading`,
  `stopped`, `offline` or `missing`. Scripts run with `-l` wait for each
  plugin as it is added unless they call `daw.api.load_apart(true)`.
- **A plugin that is not installed** stays in the project as it was: shown
  under its name (`missing`, "not installed"), with its saved state and
  parameter values, passed over in the chain, and written back unchanged
  when the project is saved. Opened where the plugin is installed, it is
  the plugin again.
- **Offline devices.** A device set offline is not made at all (no process,
  no sound) and is passed over; it keeps its state and parameters, and the
  flag is saved with the project. `o` in the device panel or
  `:device.offline` sets the selected device offline or back online, as do
  `device:set_offline(true)` and the plug button on a plugin's card in the
  window (an offline card says so and has an Online button). To open a project without its plugins: `daw --plugins-offline
  song.json`, `:edit song.json offline`, `daw.open(path, { plugins_offline =
  true })`, or the "(plugins offline)" entries of `:recover` (`:recover 1
  offline`). `:plugins.online` brings every offline device up, and
  `:plugins.offline` sets every plugin offline. Offline flags set this way
  are saved with the project like any other.
- **A plugin that could not be loaded is remembered.** One that failed or
  hung while a project was opening is noted beside the project's other
  state (`$XDG_STATE_HOME/daw/projects/`), not in the project file, and the
  next time the project is opened it is opened offline, with a message
  saying so; `:edit song.json online` opens it without holding any back.
  Once it loads it is forgotten.
- **Libraries a plugin needs.** A plugin built elsewhere expects the system
  to have the libraries it names. Where they are not on the loader's path
  (NixOS), they are looked for in the nix-ld directory, the system and user
  profiles, where the build found them (the dev shell says, in
  `DAW_PLUGIN_LIB_DIRS`) and the usual places of other systems, and loaded
  from there; `DAW_PLUGIN_LIBS` adds directories. The display's libraries
  (`libX11` and its relatives) are loaded ahead for every plugin, because a
  plugin's toolkit opens them by name when it makes its window: without
  them an editor is an empty black window.
- **Windows plugins through yabridge** draw and take the pointer in Wine,
  not here. If such an editor ignores clicks in part of the screen, or
  everywhere on one monitor, Wine's idea of the monitors is out of date: a
  Wine server that outlives a change of monitors or scaling keeps the old
  screen size and confines the pointer to it. `wineserver -k` (the one
  belonging to the Wine that yabridge uses) ends it, and the next plugin
  starts one that sees the screens as they are.

## Built-in devices

| Kind | Parameters |
| --- | --- |
| `synth` | `wave` (sine, saw, square, triangle), `attack`, `decay`, `sustain`, `release`, `cutoff`, `resonance`, `gain` |
| `drums` | `gain`, `kick_tune`, `decay`. Output pairs Kit, Kick, Snare, Hats, Toms, Cymbals and Percussion (see [Instruments with several outputs](mixing.md#mixing-midi-and-rendering-in-the-core)). A synthesized kit on the General MIDI drum notes: kick (35, 36), rim (37), snare (38, 40), clap (39), closed, pedal and open hat (42, 44, 46; the closed and pedal hat cut the open one off), six toms (41 to 50), crashes, china and splash (49, 57, 52, 55), ride (51, 59), ride bell (53), tambourine (54), cowbell (56). |
| `sampler` | `gain`. One sound file per note, each with a level, pan, tuning and choke group. The kit is the device's state: text lines `note level pan tune group path`, set with `daw.api.device_set(id, "state", base64)`; the files are read off the audio thread. `extensions/drums` makes kits from folders. |
| `gain` | `gain` |
| `delay` | Echoes: `time` (ms), or `sync` to a note length at the tempo of the moment (`1/8.`, `1/4T`...), `feedback`, `mix` (the echoes' level; the dry stays at full level), `mode` (stereo or ping-pong), `low_cut` and `high_cut` on the repeats (off at the ends of their ranges), `width`. A new time glides there, like tape. |
| `chorus` | Doubles and widens a guitar or a pad: `rate` or `sync`, `depth`, `delay`, `feedback`, `spread` (the right side's LFO behind the left's), `mix`, `voices`. |
| `flanger` | The jet sweep: `rate` or `sync`, `depth`, `delay`, `feedback` (negative for the hollow sound), `spread`, `mix`. |
| `phaser` | `rate` or `sync`, `depth` (up to three octaves each way), `center`, `stages` (2 to 12), `feedback`, `spread`, `mix`. |
| `tremolo` | `mode` (tremolo, or auto-pan at equal power), `rate` or `sync`, `depth`, `shape` (sine, triangle, a softened square). Synced LFOs lock to the song's position while it plays. |
| `limiter` | The last device on the master: `ceiling` (default -1 dB), `gain` (drive into it), `release`, `true_peak` (on by default: the peaks between samples are held under the ceiling too, as a BS.1770 meter reads them, with 0.2 dB to spare). Looks 5 ms ahead, so nothing leaves it above the ceiling; the rest of the mix waits for it. `daw.params.read(l, "meters")` gives `gr` and `input` in dB. |
| `eq` | A parametric equaliser for shaping any track or bus: eight bands, each with `bN_on`, `bN_type` (low cut 12 or 24 dB/oct, low shelf, bell, high shelf, high cut 12 or 24, notch, band pass), `bN_freq`, `bN_gain`, `bN_q`, and `output`. Flat until a band is moved; settings glide without clicks. `daw.params.read(eq, "curve", n)` gives its response in dB at `n` frequencies from 20 Hz to 20 kHz on a log scale, for drawing. |
| `compressor` | Evens out a vocal, glues a drum bus, or (with `mix` below 100 %) compresses in parallel: `threshold`, `ratio` (the top of its range is a limit), `knee`, `attack`, `release`, `auto_release` (a fast release after short peaks, a slow one after sustained compression), `makeup`, `auto_makeup` (gives back half of what a 0 dB peak loses), `lookahead` (reported as latency), `detector_hp` (so the kick does not drive it), `detect` (peak or RMS), `mix`, `link`, `listen` (play the side-chain as the detector hears it). With a side-chain (see [Side-chains](mixing.md#mixing-midi-and-rendering-in-the-core)) the detector hears that track instead of its own input. `daw.params.read(c, "meters")` gives `gr`, `input` and `output` in dB; `"curve"` the static curve. |
| `reverb` | Room and plate sounds for vocals, drums and buses: an eight-line feedback delay network whose lines drift slowly so that it does not ring. `size`, `decay` (seconds to fall 60 dB), `predelay`, `damp_high` and `damp_low` (where the highs and lows start dying sooner; off at the ends of their ranges), `diffusion`, `early` (early reflections against the tail), `width`, `mix` (the dry stays at full level up to 50 %, the wet reaches full level there). |
| `utility` | Level and stereo fixes: `gain`, `pan` (a balance: the far side fades out), `width` (0 % is mono, 200 % twice as wide), `mono_below` (the sides taken out under this frequency; off at 20 Hz), `invert_l`, `invert_r`, `swap`, `dc` (a 5 Hz high-pass). |
| `saturation` | Warmth or grit on a bass, a drum bus or a vocal: `drive`, `curve` (tape: soft and symmetric; tube: biased, adds even harmonics; hard clip), `oversample` (2x or 4x, so the harmonics do not fold back as noise), `tone` (a high shelf after the curve), `mix`, `output`. Quiet audio passes at its own level; 31 samples late (0.65 ms at 48 kHz), reported as latency. |
| `meter` | Measures and passes the audio through untouched, for the master or any track: `daw.params.read(m, "meters")` gives `momentary`, `short_term` and `integrated` loudness (LUFS, EBU R 128 with its gates), `true_peak` (dBTP) and `sample_peak` held since `daw.params.read(m, "reset")` (or for 3 s with `hold`), `rms_l`, `rms_r` and `correlation` over 300 ms; `"spectrum", n` gives dB in `n` bands from 20 Hz to 20 kHz. Readings not taken yet are -200. |
| `tuner` | Tunes a guitar or a bass: `daw.params.read(t, "pitch")` gives `freq`, `note` (`E2`), `midi`, `cents` and `confidence`, from the last 85 ms (YIN); `reference` sets A4, `mute` silences the track while tuning. |
| `gate` | Cuts the spill between hits on a drum track, or the noise between phrases: `mode` (gate or expander), `threshold`, `range`, `ratio` (expander), `attack`, `hold`, `release`, `hysteresis`, `lookahead`, `detector_hp`, `detect`, `link`, `listen`. Keyed by a side-chain like the compressor (a pad that opens on the hi-hat). The same meters as the compressor. |

In the device panel the equaliser draws its curve, the compressor, gate and limiter their gain reduction, the meter its loudness and the tuner a needle, under their names. `:eq` and `:tuner` show the track's equaliser or tuner (adding one if it has none), `:loudness` the master's meter; in the window each opens a window of its own (also from the track menu, and the timeline's for the meter), and in the equaliser's window a band's dot is dragged to move it, the wheel over it changes its Q, and a double click turns a band off, or on as a bell where the empty space was clicked.

`daw.params.presets(kind)` lists a device's starting points (vocal high-pass and presence, drum bus glue, plate, room and others, kept in [device_presets.lua](../runtime/lua/daw/device_presets.lua)) and `daw.params.apply(device, name)` sets one. `daw.params.format(param, value)` shows a value in its unit (`2.5 kHz`, `-18.0 dB`, `4:1`, `1/8.`); frequencies, times and ratios move on a log scale from the keyboard and on sliders. One instance of each costs, on one core at 48 kHz (`bench/devices.lua`): reverb 1.0 %, saturation 0.7 % (2x; about twice that at 4x), limiter 0.5 %, chorus 0.3 %, meter 0.3 %, phaser 0.3 %, EQ with every band working 0.2 %, flanger 0.2 %, compressor 0.1 %, gate, delay, tremolo, utility and tuner under 0.1 %.

**Every device, built in or a plugin, has a wet/dry mix and an output gain**
from the host: two parameters after its own, `fx_wet` (Wet, 0 to 100 %)
and `fx_gain` (Output, -24 to +24 dB). The dry part is the device's input,
held back by the device's latency so that the two line up. They are set,
automated, learnt and kept in presets like any other parameter
(`daw.fx.set_wet(device, 50)`). The window's device card has both under the
preset; the terminal's device panel shows `wet 50%` on the device's line
when it is not 100 %, `+` `-` there change it, and both are the last rows of
the device. Bypassing a device or switching it on again, and any change of
the mix, fades over 5 ms instead of clicking; a bypassed device holds
nothing back.

New devices implement the `Device` trait in `daw-engine` and are added to the
registry in [devices/mod.rs](../crates/daw-engine/src/devices/mod.rs).

## Writing a device in Lua

A device can be a Lua file, in the spirit of REAPER's JSFX: parameters and a
`process` function given each block of sound. Saved in
`~/.config/daw/devices/`, it shows in the device picker beside the built-in
devices and plugins as `lua:<file name>`, and its parameters are set,
automated, learnt, saved with the project and kept in presets like any
other device's.

```lua
-- ~/.config/daw/devices/tilt.lua: a tilt equaliser
local dsp = require("daw.dsp")

local dev = dsp.device {
  name = "Tilt",
  params = {
    { key = "tilt", name = "Tilt", min = -6, max = 6, default = 0, unit = "dB" },
    { key = "output", name = "Output", min = -12, max = 12, default = 0, unit = "dB" },
  },
}

local low, high

function dev.init(sample_rate)
  low = { dsp.biquad(), dsp.biquad() }
  high = { dsp.biquad(), dsp.biquad() }
end

function dev.process(b)
  local p = b.params
  for ch = 1, 2 do
    low[ch]:set("lowshelf", 800, 0.7, -p.tilt, b.sample_rate)
    high[ch]:set("highshelf", 800, 0.7, p.tilt, b.sample_rate)
  end
  local g = dsp.gain(p.output)
  for i = 0, b.frames - 1 do
    b.left[i] = g * high[1]:process(low[1]:process(b.left[i]))
    b.right[i] = g * high[2]:process(low[2]:process(b.right[i]))
  end
end

return dev
```

- **The file returns its device**, made with `dsp.device { ... }`: `name`
  (else the file's name), `category` (`"effect"`, the default, or
  `"instrument"`), `vendor`, and `params`, a list of `{ key, name, min,
  max, default, unit }` or of choices, `{ key = "mode", choices = {
  "Soft", "Hard" }, default = "Soft" }` (a choice's value is its number
  from 0). `dev.init(sample_rate, max_block)` runs once before the first
  block.
- **`dev.process(b)` runs each block.** `b.left` and `b.right` are the
  block's two channels, `ffi` float arrays counted from 0, `b.frames` long:
  an effect changes them, an instrument adds to them. `b.params` holds the
  parameters' values by key, `b.sample_rate` the rate, and the transport is
  in `b.playing`, `b.tempo`, `b.beat`, `b.seconds`, `b.bar`, `b.bar_start`,
  `b.sig_num` and `b.sig_den`. Loops over the arrays are compiled by
  LuaJIT; a gain costs under a microsecond a block. Instead of `process`, a
  device may give `dev.sample(l, r, b)`, which takes one frame and returns
  the new pair.
- **MIDI.** `b.events[0]` to `b.events[b.nevents - 1]` are the block's
  events in order, each with `frame`, `type`, `channel` (1 to 16), `key`
  and `value`. Types are `dsp.NOTE_ON` (`value` is the velocity, 0 to 1),
  `dsp.NOTE_OFF`, `dsp.CC` (`key` is the controller, `value` 0 to 1),
  `dsp.BEND` (-1 to 1), `dsp.PRESSURE`, `dsp.PROGRAM`, `dsp.ALL_NOTES_OFF`,
  and `dsp.OTHER` for the rest (a note's own controllers, RPNs).
  `b:note_on(frame, key, velocity, channel)`, `b:note_off(frame, key,
  channel)`, `b:cc(frame, number, value, channel)` and `b:send(frame, type,
  key, value, channel)` send events to the devices after it, in any order;
  `b:pass(e)` sends on one that came in as it is. What comes in is passed
  on by itself, with what the device sends added; a device declared with
  `midi_effect = true` (an arpeggiator, a chord maker) replaces it instead.
- **A side-chain.** `sidechain = true` lets the device listen to another
  track (see [Side-chains](mixing.md#mixing-midi-and-rendering-in-the-core)):
  `b.key_left` and `b.key_right` hold it, nil when nothing is connected.
- **The helpers** in `daw.dsp`: `dsp.gain(db)` and `dsp.db(gain)`,
  `dsp.mtof(note)`, `dsp.pan(p)` (equal-power gains), `dsp.clamp`,
  `dsp.saturate(x)` (a soft clip), `dsp.buffer(n)` (a float array for a
  delay line), `dsp.onepole(hz, sr)` with `:lowpass(x)` and `:highpass(x)`,
  `dsp.biquad(shape, hz, q, gain_db, sr)` with `:set(...)` and
  `:process(x)` (lowpass, highpass, bandpass, notch, peak, lowshelf,
  highshelf), and `dsp.smoother(ms, sr)` with `:next(target)` for gliding
  to a new value. One filter or smoother per channel. Modules beside the
  file are found by `require`.
- **Scripts talk to it.** `dev.call(method, data)` answers
  `daw.api.device_call(device, method, data)` from the session's Lua: it
  runs in the device's own state between two blocks (a block that comes
  meanwhile waits for it, so keep it short), `data` is a string, and what it
  returns (a string, a number or nothing) is the answer; an error is the
  caller's error, and the device plays on. `daw.api.device_post(kind,
  topic, data)` calls `dev.call(topic, data)` on every device of a kind:
  those there now at once, and every one made later before its first
  block, the private devices of an offline render among them. The latest
  data of each topic is kept for those, so devices made at any time agree
  (`nil` forgets a topic). `dev.values` holds the parameters as the last
  block had them.
- **Large data goes as files.** Sound for a device to play (a sampler's
  samples, a singer's phrases) is too big to pass as a string each time:
  the script writes it to a file of 32-bit floats and calls the device with
  the path, and the device maps it with `dsp.map(path)`, which gives
  `m.data[0]` to `m.data[m.n - 1]`, read in at once and shared by every
  device that maps the same file. Map in `dev.call` or `dev.init`, never in
  `process`; `m:close()` lets go of it. Write a new file for new data rather
  than writing over one a device has mapped. extensions/utau plays its
  singing this way.
- **Where scripts are found.** `~/.config/daw/devices/`, and `devices/` in
  each extension: an extension ships devices by having that directory.
  A script in the configuration directory wins over an extension's of the
  same name. `extensions/luafx` has four to start from (a gain and pan, a
  drive, a chord maker and a sine instrument); `daw.luadev.add_dir(dir)`
  looks in another directory.
- **Saved, it is loaded again.** Each second the files are looked at
  (`daw.opt.lua_devices_watch`, in ms, 0 for never); a script that changed
  is loaded, and the devices made from it start again from the new code,
  keeping their parameters' values. A new parameter starts at its default.
  `:device.reload` does it at once for the device chosen in the panel, or
  every Lua device of the track. `:device.scripts` lists the scripts, where
  they are, and why any did not load.
- **Errors are shown, not fatal.** A script that does not load (a syntax
  error, no `process`, a top level that runs for more than five seconds)
  is reported with its file and line, and a device already running from an
  earlier version goes on as it was. A script that fails while it runs
  stops alone: the session shows the device as stopped with the error
  (`tilt.lua:23: attempt to index a nil value`), the track plays on with
  an effect passed over and an instrument silent, and `:device.restart` or
  saving the file starts it again.
- **Each Lua device runs in a process of its own**, the helper plugins get,
  with a LuaJIT state to itself. LuaJIT allocates as it runs, which the
  audio thread must never do, so the engine hands the helper each block
  through shared memory and waits for it within the block, exactly as for
  a plugin: no latency is added, a script that is slow costs its own track
  a block, and one that hangs or crashes (`ffi` can) is ended and shown as
  stopped without touching anything else. This holds with
  `--plugins-in-process` too.
