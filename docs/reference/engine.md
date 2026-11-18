# The audio engine

<!-- tags: engine threads latency xruns -->

The engine plays the project on the audio thread and on a pool of worker
threads. For the design, see
[About the audio engine](../explanation/about-the-audio-engine.md).

## Commands

| Command | Effect |
| --- | --- |
| `:engine` | Show the backend, the device, the sample rate, the threads and the xruns. |
| `:engine pipewire rate=48000 buffer=256` | Restart the engine with a backend, a sample rate and a block size. |
| `:engine threads=4` | Set the number of threads (`paw.opt.threads`). |
| `:engine.status` | Show the problems while the song played, in one line: CPU, xruns, late plugin blocks, dropped MIDI events, lost recorded frames, stopped devices. |

## Threads

Playback and renders use one thread for each core.

| Way | Effect |
| --- | --- |
| `paw.opt.threads = 4`, `:engine threads=4` | Use four threads. |
| `paw.opt.threads = 1` | Use the audio thread only. |
| `paw.opt.threads = 0` | Default: one thread for each core. |
| `paw.render(path, { threads = 1 })` | The number of threads for one render. |

- `paw.api.engine_get().threads` gives the number of threads in use.
- When the audio thread has real-time priority, the worker threads get the
  same priority. If the system refuses this priority, the engine uses only
  the audio thread.
- A render is the same to the bit with any number of threads.

## State of the engine

`paw.api.engine_get()` gives a table. `paw.frontend.state()` gives the
same values to the graphical window and the status line.

| Field | Value |
| --- | --- |
| `backend`, `device`, `input_device` | The backend and the devices. |
| `sample_rate`, `block` | The sample rate and the block size. |
| `input_latency`, `output_latency` | The latencies, in ms (see [Audio devices](audio-devices.md#latency)). |
| `latency` | How far the output is behind the transport, in ms, with delay compensation. |
| `threads` | The number of threads in use. |
| `lost` | The name of a lost device, or nil. |
| `xruns` | The number of xruns. |
| `late_blocks` | The number of blocks that plugins did not give in time. |
| `midi_dropped` | The number of MIDI events dropped because a queue was full. |
| `record_dropped` | The number of frames of a take lost because the disk was slow. |
| `devices_stopped` | The number of stopped devices. |

## Delay compensation

- A device that looks ahead reports the delay of its output. CLAP, VST3
  and LV2 plugins report it. Of the built-in devices, the `limiter`, the
  `saturation`, and the `compressor` and `gate` with `lookahead` report
  it.
- paw delays each other path to the same place by the difference, through
  buses and sends, so that all the sound arrives together.
- A render removes the delay from the start of the file.
- paw does not delay the clips of a track to match the sound that is routed
  into the track.

## A device that fails

- paw guards the processing of each device on the audio thread. A device
  that panics is marked failed, and the chain ignores it after that. An
  instrument is silent, and an effect lets its input through.
- The event `device.stopped` tells, as for a plugin whose helper crashed.
  The device panel shows the device as stopped. `:device.restart` makes a
  new device.
- paw replaces samples that come out of a device as NaN or infinity with
  silence at its output. They never reach a fader, a meter or the master.
  The event `device.invalid` and a message tell it one time.
- A panic in any other part of paw writes a safety copy of the work that
  is not saved, before paw stops. Then paw restores the terminal and says
  where the copy is. `:recover` offers it at the next start (see
  [Project files](project-files.md#safety-copies)).

## Memory

paw releases decoded audio that the project and the undo steps do not use.
It does this when another project opens, and at intervals while you edit.
So a long session does not keep each file that it played.

## Scripts and the engine

| Function | Effect |
| --- | --- |
| `paw.api.engine_restart(spec)` | Restart the engine (see [Audio devices](audio-devices.md#test-backends)). |
| `paw.api.engine_audible(ids)` | Play only these tracks, and what their sound goes through. `scope_rest=mute` uses it (see [Narrowing](narrowing.md)). |
| `paw.api.engine_hold(track, file)` | Play a file instead of a track. `scope_rest=frozen` uses it. |
| `paw.wait(ms)` | Let time pass, with timers and events. `paw.api.sleep` does not run timers or events. A script run with `-l` is otherwise one long turn. |
