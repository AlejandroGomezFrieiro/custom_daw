# How to fix crackles and dropouts

This guide shows you how to stop clicks, crackles and short gaps in the
sound. They occur when the computer cannot compute a block of sound in
time. For each command, see [The audio engine](../reference/engine.md).

## Find the cause

1. Play the part that crackles.
2. Type `:engine.status`. The message gives the CPU use and the problems
   while the song played: the xruns (blocks that came too late), the late
   plugin blocks, and other counts.
3. If the late plugin blocks increase, one plugin is too slow. Go to
   "Make the song lighter" below.
4. If the xruns increase, the block size is too small for the computer.
   Go to "Make the block size larger".

## Make the block size larger

1. Type `:audio.buffer 256`. A larger block gives the computer more time
   for each block.
2. Play the part again. If it still crackles, try `512`, then `1024`.

A larger block also makes the delay between a key and its sound longer.
When you record, use the smallest block that does not crackle. When you
mix, a large block is correct.

## Make the song lighter

- Freeze a heavy instrument: put the cursor on its track and type
  `:freeze`. paw renders the track to a file and plays the file. See
  [How to freeze a heavy track](freeze-a-heavy-track.md).
- Bypass the devices that you do not need now: press `gcc` on a device in
  the device panel.
- If the computer is busy with other work, use fewer threads for the
  audio: `:engine threads=2`. To use one thread for each core again, type
  `:engine threads=0`.

## Check the system

- Close the programs that use much CPU, for example a web browser with
  video.
- In a shell, type `paw doctor`. It checks for dropouts and prints a
  report.
