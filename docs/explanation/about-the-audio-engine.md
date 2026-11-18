# About the audio engine

The audio engine must give a block of sound on time, each time. If it is
late, the listener hears a dropout. This page tells how the engine of paw
uses many cores and stays on time, and how it protects the mix from a bad
device. For the commands and fields, see
[The audio engine](../reference/engine.md). For the place of the engine in
paw, see [About the architecture](about-the-architecture.md).

## Many cores, one result

The engine processes the tracks on a pool of worker threads, one for each
core. Tracks that do not depend on each other run at the same time. A
track that sends, keys or plays into a different track runs before that
track.

A render must give the same file each time. So each worker treats
denormal numbers as zero, as the audio thread does, and a track sounds the
same on any thread. A render is the same to the bit with one thread or
with sixteen. The workers take work with one atomic operation, and do not
allocate or lock.

The workers get the real-time priority of the audio thread. If the system
refuses this priority, the engine does not use the workers. A worker
without real-time priority can wait behind any other program, and the
audio thread would then wait for it. One thread on time is better than
many threads that are late.

## Delay compensation

Some devices look ahead: a limiter must see a peak before it arrives. Such
a device delays its output, and reports the delay. If one path to the
master has a limiter and another path does not, the two paths do not
align. So paw delays each other path by the difference, through buses,
sends, side-chains and output pairs, and all the sound arrives together.
A render removes the total delay from the start of the file.

## A device that fails

A device can panic, or give NaN or infinity. One bad sample can make a
filter unstable, and a NaN in a bus can silence the master. So paw guards
each device on the audio thread. A device that panics stops, and the chain
ignores it after that. A sample that is not a number becomes silence at
the output of the device, before it reaches a fader or a meter. The rest
of the mix continues to play.

A plugin can also crash its process. For this, see
[About the plugin sandbox](about-the-plugin-sandbox.md).

## Long files from the disk

A recording of one hour, decoded, takes gigabytes of memory. paw decodes
such a file one time into a cache on the disk, and maps the cache into
memory. The system reads the pages when the engine needs them, and
releases them when memory is low. The kernel asks for the next seconds
before the playhead, so that the audio thread never waits for the disk.
The decoded sound stays in the cache between runs, so the second open is
immediate.
