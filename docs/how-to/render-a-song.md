# How to render a song

This guide shows you how to render the song to a file with tags, for
example an MP3 to share. For each option, see [Render](../reference/render.md).

1. Set the tags of the project one time:

   ```
   :render.tags artist=Ana album="First one" track=3/12 year=2026 cover=cover.png
   ```

2. To render a WAV or FLAC master, type `:render mix.flac`. To render an
   MP3, type `:render mix.mp3 quality=best`.
3. Wait for the message that the render is complete. The status line shows
   the progress. To stop the render, press `Esc`.

The file is next to the project, unless you give a path.

If `:render mix.mp3` fails because `ffmpeg` is missing, install `ffmpeg`,
or set `paw.opt.ffmpeg` to its path. WAV and FLAC need no other program.

If reverbs or delays continue after the last clip, add `tail=4` for four
seconds after the end.

If you need a loudness target, add `loudness=-14`. To also keep the peaks
below a level, add `normalize=-1`.

To render only the loop, add `range=loop`. To render a region, add
`range=Verse`.

To render the song for a CD, use `:render cd.wav rate=44100 bits=16 dither=true`.

## Use the graphical window

1. Select File → Render….
2. Type the tags under Tags. They become the tags of the project.
3. Select the format and the options, and start the render.
