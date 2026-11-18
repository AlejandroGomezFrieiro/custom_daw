# Make music with paw

In these five lessons, we make one short song with paw, from an empty
project to an MP3 file. We write drums, a bass and chords. We play a lead
on a MIDI keyboard and record a guitar. Then we arrange the song, mix it
and render it. Each lesson takes 15 to 25 minutes and ends with music that
you hear.

The lessons are for musicians. You know what a DAW, a track, a plugin and
a MIDI keyboard are. You do not need to know Vim or Lua. paw is played
from the keyboard, so each step gives the keys to press. The lessons show
the terminal, and the graphical window shows the same views.

| | Lesson | What we make |
| --- | --- | --- |
| 1 | [Your first song](01-first-song.md) | Drums, a bass and chords in a loop of four bars, saved as a project. |
| 2 | [Play a synth from a MIDI keyboard](02-play-a-midi-keyboard.md) | A lead that we play live, record over the loop and quantize. |
| 3 | [Record a guitar](03-record-a-guitar.md) | A guitar through an amp chain, two takes, the best parts of each, and a fade. |
| 4 | [Arrange the song](04-arrange-the-song.md) | Verse and chorus, markers for the parts, a new tempo, and jumps to a part. |
| 5 | [Mix and render the song](05-mix-and-render.md) | Levels, pan, an equalizer, a compressor, a reverb on a send, automation, a WAV and an MP3. |

## Before you start

- Install paw (see [How to install paw with Nix](../../how-to/install-paw.md)).
- Make a folder for your songs, and open a terminal in it. paw saves and
  renders into the folder where it starts.
- For lesson 2, connect a MIDI keyboard. For lesson 3, connect an audio
  interface with a guitar on its input 1.

Each lesson from lesson 2 opens a practice project: the song as the lesson
before left it. So you can do any lesson again, or start at any lesson.
The practice projects are Lua files in the `examples/tutorials/make-music`
folder of paw. The package of paw sets `PAW_HOME` to the folder that holds
`examples`. If you run paw from its source folder, set `PAW_HOME` to that
folder first.

**CAUTION:** Set the volume of your speakers or headphones low before you
start. A new synth can be loud.

## After these lessons

[The course](../course/README.md) teaches the keys of paw in seventeen
short lessons, also inside paw as `:tutor`. The
[how-to guides](../../README.md#how-to-guides) give the steps for one
task each. [Keys, by idea](../../reference/keys.md) is a page of keys to
keep near the keyboard.
