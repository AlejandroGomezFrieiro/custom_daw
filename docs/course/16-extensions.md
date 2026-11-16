<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 16: The bundled extensions

*About ten minutes. In paw, with the tutor loaded: `:tutor 16`.*

Much of what paw can do comes in extensions: directories of Lua in `extensions/` beside the program, which use the same `daw` module as your `init.lua`. Seven come with it besides the tutor. This lesson loads each for this session with `:tutor.try` and tries one thing in it; to have one always, link its directory into `~/.config/daw/extensions`.

Each extension's README.md says everything it does. Their keys live under their own prefixes: `]s` `[s` and `,S` (sections), `gz` (musicops), `,t` (pattern), `,x` and `]d` `[d` (mixdiag), `,u` `g-` `g+` (undotree), `,v` (utau).

## The idea

An extension adds commands, keys, text objects, operators and views with the calls of lesson 15, so what it adds obeys the grammar you know: sections are text objects (`dis`, `yis`), musicops are operators (`gzkip`), and `.`, counts and macros work with them.

## If you know Vim

`:tutor.try name` is like `:packadd`. `:extensions` lists what is loaded.

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. pattern writes drum parts as text. Type `:tutor.try pattern` and `<CR>`, then `:pattern.set bd*2 [~ sn]` and `<CR>`: a new clip on Drums plays it.
   - ✓ Kick, kick, rest, snare, as a clip. `,tt` edits the text of the clip under the cursor.
2. musicops adds musical operators under `gz`. Type `:tutor.try musicops` and `<CR>`, press `j` to go to Keys, and `gzkic` to move every note of the clip a step up the scale.
   - ✓ D E F A F E D: the tune moved within C major. `gzh` humanizes, `gzs` strums, and `.` repeats any of them.
3. sections names the parts of a song. Type `:tutor.try sections` and `<CR>`, then `,Sa`, type `Verse` and `<CR>` to mark a section at the cursor.
   - ✓ Verse is on the ruler. `is` is now a text object: `yis` yanks the section on every track, `]s` goes to the next.
4. undotree shows every state the project has been in. Type `:tutor.try undotree` and `<CR>`, press `,uu` to open the undo tree, look, and `q` to close it.
   - ✓ Nothing undone is lost: `g-` and `g+` walk through time across branches.
5. mixdiag measures the mix and lists problems. Type `:tutor.try mixdiag` and `<CR>`, then press `,xa` to measure the song.
   - ✓ It measures in the background; the message line gives the loudness when it is done, and `,xx` lists what it found.
6. rpp opens and writes REAPER projects. Type `:tutor.try rpp` and `<CR>`, then `:rpp.export tutor-song.rpp` and `<CR>`; a list of what REAPER cannot take opens, and `q` closes it.
   - ✓ tutor-song.rpp is in the folder you started from. The built-in devices stay behind, as the list said.
7. utau sings notes with lyrics through OpenUtau's engines. Type `:tutor.try utau` and `<CR>`, press `o` for a new track, then type `:utau.voice` and `<CR>` to make it a vocal track.
   - ✓ A vocal track. It sings once `reautau-engine` and a voicebank are installed (see extensions/utau/README.md); `,v` then adds a vocal track and asks for its singer in one go.
8. Listen to the pattern and the tune: `gs`, `<Space>`, and `<Space>` to stop.
   - ✓ That is the course.

## What you did

pattern, musicops, sections, undotree, mixdiag, rpp and utau: each one thing. Their READMEs have the rest.

Previous: [Making it your own: options, keys, commands](15-your-own.md) · [All lessons](README.md)
