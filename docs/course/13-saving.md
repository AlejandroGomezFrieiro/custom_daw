<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 13: Saving and rendering

*About ten minutes. In paw, load the tutor with `:ext.load tutor`, then `:tutor 13`.*

A project is a file (JSON) with everything in it: tracks, devices and their settings, clips and notes, automation, the loop. Recordings sit in a `media` folder beside it. Rendering plays the whole song into a WAV file that any other program can play.

This practice project already has a file, in the tutor's folder, so `:w` saves it there. Your own projects are saved wherever you say: `:w song.json`.

## The idea

`:w` saves (`<C-s>` too), `:w name.json` saves under a new name, `:e name.json` opens a project (`:e song.mid` makes one of a MIDI file, with no file of its own until `:w name.json`), `:new` starts an empty one, `:wq` or `ZZ` save and quit, `:q` or `ZQ` quit without saving. The status line shows the project's name, with `[+]` when there are changes not saved yet. `:render name.wav` writes the song to a file; `tail=2` adds two seconds for echoes to die away, `bits=16` makes a 16-bit file. A relative name is relative to the folder paw was started from.

## If you know Vim

`:w`, `:e`, `:wq`, `:x`, `ZZ`, `ZQ` as in Vim, with projects for files. There is one project open at a time; `:e` replaces it. `:w name.json` is Vim's `:saveas`: the project goes on in the new file. Vim's `:w name` writes a copy and stays in the old one; there is no such copy here.

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. Change something first: `&` repeats the chords after themselves. Press `&`: the status line's project name gets a `[+]`.
   - ✓ `[+]`: there are changes that are not saved.
2. Type `:w` and `<CR>` to save. (`<C-s>` does the same.)
   - ✓ Saved: the `[+]` is gone, and the message line says where.
3. `:render` plays the song into a WAV file. Type `:render tutor-song.wav tail=2` and `<CR>`.
   - *Hint:* `tail=2` keeps two more seconds after the last note, so the echo is not cut off.
   - ✓ tutor-song.wav is in the folder you started paw from: its length and peak level are on the message line.
4. `:messages` shows the messages you have missed. Type `:messages` and `<CR>`, then `q` to close it.
   - ✓ Every message since paw started, saves and renders among them.
5. Listen to the song you rendered in any player. Here, `<Space>` plays it in paw; `<Space>` stops.
   - ✓ Saved and rendered.

## What you did

`:w` to save, `[+]` for unsaved changes, `:render name.wav tail=2` to make a file, `:messages` for what was said.

Previous: [Recording audio and MIDI](12-recording.md) · [All lessons](README.md) · Next: [Finding any command or key](14-finding.md)
