# What is missing

- Harmony: chords are read per half beat, so a chord shorter than about a
  beat is taken for passing notes; the chords and the key are not shown in
  the arrange view's ruler (only over the piano roll); slash chords whose
  bass is not a chord tone are named by the full pitch set (C G B D is
  Cmaj9, not G/C). The reading is redone over the whole song after each
  edit, which is quick for songs of some thousands of notes but not
  incremental.
- Snippets are offered in the piano roll only (a snippet may name other
  views, but nothing opens the picker there yet). Taken as a suggestion
  (`Ctrl-Space`) a snippet has no choices to step through, and the picker's
  preview is drawn by the snippet's own layer rather than through
  `daw.complete.show`. A melody of eighth notes alone may be read as
  chords (a beat with two pitches in it is evidence of one).
- Pickers you can hear: `daw.opt.audition_level` sets the level of sound
  files only; a phrase plays through the track at the track's own level,
  so that a preset is heard as it would be. A phrase is timed by the
  kernel's timers rather than the engine, so it can be a few milliseconds
  uneven under load. A plugin factory preset takes as long to try as to
  load (some plugins hold the program up to a third of a second). The
  pickers of templates, UTAU presets and singers, sends and drum maps are
  not heard. The window shows a picker's pane as text, the outline of a
  sound file in block characters, not as a drawn waveform.
- paw's sampler (extensions/sampler) reads an instrument's samples whole
  into memory while the program waits, and nothing streams from disk: a
  library that takes more than 30 s to read is ended by the plugin
  helper's time limit. Not played: SFZ's LFOs (`amplfo_*`, `fillfo_*`,
  `pitchlfo_*`, `lfoN_*`), its v2 envelopes (`egN_*`), `<effect>`,
  `amp_keytrack`, `sw_vel`, controllers on envelope times and offsets, and
  smoothing per controller (`_smoothccN`); Decent Sampler's effects,
  modulators, buses, glide, `legatoInterval` and oscillators. SoundFont 2,
  folders of samples and `.dslibrary` archives are not read, nor FLAC or
  Ogg samples. The plugin lists no presets for `:preset`, has no editor
  window of its own, one stereo output, and ignores per-note controllers,
  MPE and note-off velocity.
- The waveform of an audio clip in cells (`daw.opt.wave_scale`) draws each
  column's lowest to highest sample and nothing of its loudness: there is no
  darker inner band for the RMS. The window draws a clip's peaks from the
  same data (`daw.frontend.peaks`: the lowest, the highest and the loudness
  of each point) as it did before.
- Windows, buffers and tabs (phase 1 is built): a built-in view is still
  one buffer shown in one window at a time, as its state (cursor, scroll,
  the clip open) is one table; phase 2 splits each view's state into the
  buffer's and the window's, so that two windows can show two clips in
  piano rolls, or one clip twice. Floating views (help, pickers, pages)
  are not yet windows of a tab, the window title bar (Neovim's winbar) is
  drawn by each view itself, layouts are not saved with the project, and
  the graphical frontend keeps its own layout of panels. `:new` still
  starts a new project; `:vnew` and `Ctrl-w n` open an empty window.
  A view's locator (`daw.ui.locator`, where in the project the view's
  cursor is) belongs to the view, not to each of its windows; phase 2
  makes it per window.
- The quickfix list: `:g/pattern/` with no command fills it, but no `:grep`
  or `:vimgrep` does yet, nor `/` searches; `:cfdo` runs once per track, as there
  are no files; lists are not kept with the project or between runs; a
  location list stays with its window's number after the window closes.
  The window's status bar does not count it.
- Ex (`:5,8d`, `:%s`, `:g`): `d`, `m` and `co` move clips, not automation,
  tempo changes or markers in the range; `:m`, `:co` and `:>` move notes as
  the piano roll does; a spelling typed in a replacement (`:s/c4/db4/`) is
  not kept for notation, which spells it by the key; a term of a pattern holds no
  spaces, so `name=` cannot name a clip with one; Vim's `:t` (copy) is not
  there, as `t` starts a range of tracks, nor `:k`, `:j!`, `:retab` and the
  like. Of the preview the window is handed the piano roll's matches and
  ghosts (as the roll's marks) and the count (`prompt.note`), but does not
  show the count yet, nor shade the range or light clips in the arrange view.

- Help (`:help`): pages are laid out 78 columns wide, not to the window;
  `:helpgrep` takes words, not patterns; there is no `:helptags` (the tags
  are made the first time help is asked for, in about half a second) and
  no help in other languages. The Nix package installs the extensions
  beside the program but not `docs/`, so installed, help has the
  extensions' pages and not the manual's, until `DAW_HOME` names a source
  tree.

- Lists edited as text (`daw://tracks` and the others): a track's input,
  MIDI ports, height and automation, a device's side-chain, outputs and
  parameters, and a send's place among a track's sends are not fields of
  their lines (a copy keeps them); a device is not renamed or replaced by
  editing its name; the lines are not laid out in columns again until the
  buffer is read again (`:w`, `:e!`); `:s` takes Lua patterns with `\d`
  `\s` `\w` `\(` `\)` of Vim's, not Vim's whole syntax; there is no `:g`,
  no completion of track and device names while typing, and no buffer of
  clips, lanes or notes yet. In the graphical frontend a text buffer is
  drawn as the terminal draws it, in the monospace font, not with the
  window's own widgets.

- One key grammar (docs/terminal.md, "Keys: one grammar"): the window's
  mixer and device cards do not draw the row the cursor is on, though the
  keys typed there move it and act on it as in the terminal; a selection
  across mixer strips with different devices or sends picks rows by what
  they are (the fader, the second send), and skips a strip that has none.
  `]` and `[` wait a moment for `]d` `]g` and the like before they run, as
  Vim's keys do when a longer mapping starts with them. `daw.opt.keys =
  "classic"` brings back the keys of before, and is to go after a release.
  The session view's `m` and `n` still mean launch mode and a new clip, not
  Vim's mark and next match.

- Notation: a tempo mark writes a point of the song's tempo
  map when it is written, and nothing keeps the two together after (moving
  the clip or the mark leaves the point where it was; no option makes the
  score own the song's tempo); repeats and endings are written, not
  unfolded; trills, mordents, turns and tremolos are written, not played,
  and a fermata holds its note's whole value but does not stop the time;
  playing techniques (`pizz.`, `con sord.`) are written text that switches
  no articulation of the instrument; swing and expression maps are not
  rendered; no CC1 or CC11 is written for sustained instruments; a key
  change after the first bar is not read by `daw.harmony` (there is no key
  track in the core: the key the score starts in is the project's); a
  time signature written in notation is the song's, for every track. A mark
  writes the MIDI only when it is written: notes the piano roll moves under
  a dynamic later keep their velocities, and a slur writes nothing (the
  notes are as long as they are). What notation keeps of a note does not
  hold a tie the metre does not need (a tied note is one MIDI note, written
  again as the metre divides it); a grace note before a clip's first beat
  is kept before the clip, where it is hidden and does not play; the clefs
  a clip was written on are kept where its notes would choose others, so a
  note the roll puts far below a treble staff does not make it a grand
  staff. MusicXML in and out: a stem direction set by hand, a beam
  joined over a beat, a system kept on the line before (`zj`) and bars
  to a system are not written out, and stems in a file are left to the
  layout; cross-staff chords are split by staff; nested tuplets read as one
  ratio; D.C., D.S., segno, coda, pedal, octave lines, fingering, string
  and fret, bowings, glissandi, figured bass, cue notes, microtones and
  tablature staves are counted and left out; a pickup is a first bar whose
  start is before the clip, which shows its rests; a `rit.` read from a
  file is written, not ramped in the tempo map; only the first part's time
  signatures go to the song; the drag-and-drop of a file onto the window
  and the file pickers do not offer MusicXML (`:open` and `:import` with a
  path do); a score brought in from a file is written as the clip's
  transcription when it goes out again; LilyPond writes chord symbols as
  text, not `ChordNames`. The notation window outlines the roll's note in
  the terminal only; the several-tracks view and a track's export
  transcribe what the clips play. Tuplets are read from the MIDI within a
  beat (and quarter-note triplets over two); nine to a beat, five over two
  beats and the like are written only when said in notation.
  Of the grammar for music: `!` does not run a snippet (snippets expand in
  the piano roll) nor hand a filter MusicXML (it hands it a line of text an
  event); `in` takes no count; a chord tied only in some of its notes is
  written again with those ties lost when it is moved or pasted; `Tab`
  takes suggestions made for the piano roll's clip (notation does not ask
  for them); `Ctrl-t` asks on the command line, not in a popover.

- Engraved notation: page breaks of one's own (pages fill as systems
  come), and the engraving options as a buffer to edit (staff size,
  spacing, font); articulations inside a slur; systems whose skylines
  interlock; in the terminal's cell view marks keep fixed rows rather than
  skylines; the text of an exported PDF is outlines, not searchable text.

- Language servers: documents are sent whole, never as incremental
  changes; the related notes of other tracks a diagnostic names are kept but
  not drawn; annotations are drawn on mixer strips, devices and the ruler,
  not yet on clips or notes; a fix that renders again is not an undo step
  (a render is not an edit of the project); the window shows the marks on
  notes only (tracks, devices, time and renders are marked in the terminal,
  and the window shows them through `:diagnostics` and the float); MIDI LSP's
  settings check names REAPER's render dialog in its messages.

- Pictures in the terminal: only by the kitty graphics protocol, as direct
  placements (not Sixel, not iTerm's, not Unicode placeholders), so not
  through tmux, which does not pass them on; a terminal that puts images
  over images well is known only by its name (kitty, Ghostty, herdr), and
  any other has the moving parts drawn into the page; one that puts text
  over images under it (a strip `under` the text) also only by its name
  (kitty, Ghostty, herdr, WezTerm); in any other (Konsole) the cells'
  backgrounds are painted into the picture, and one only a few cells have
  (twelve or fewer: a cursor block, a short selection) hides the line under
  it. Only the score, the curve editor's plot and the
  utau editor's pitch and curves are pictures: the arrange view's automation
  lanes and audio waveforms are still cells in the terminal.
- A tempo curve that is smooth: a drawn stroke makes a change a beat or so,
  each ramping to the next (the curve editor writes a smooth stretch of it
  as ramps a sixteenth of a beat long).
- In the curve editor: send levels and clip gain are not curves yet; a
  controller's moves only hold (a ramp is written as many moves); the
  window draws a lane's held and smooth stretches straight, though they
  play as shaped; waves are not `daw.snippet` snippets, which write notes.
- The mouse in the terminal: an audio clip's fades and gain are not dragged
  (the keys and the clip's commands set them), a track's height is not
  dragged (the wheel with Ctrl over the headers changes every track's), and
  the volume curve drawn over a track's lane
  is not edited with the pointer (its lane shown as a row is). Heights in a
  lane are as fine as its two lines, and finer only by dragging a point.
  Where the terminal keeps Shift for its own selection, Shift does not
  reach the program.
- In stretching: ratios are 0.25 to 4 (each part between warp markers
  too) and shifts 24 semitones either way; a stretch is always made from
  the start of its file, so the playhead put far into a long clip just
  changed is silent there until the making gets that far; formants are
  kept only by the tonal way; a looped clip following the tempo is
  stretched evenly, not bent along a ramp inside it; warp markers are not
  found by themselves at onsets (each is put by hand), and the other takes
  of a clip share its markers.
- Plugins with main buses wider than stereo (surround), and inputs beyond
  the main pair and one side-chain.
- Pre-roll without a punch (a take from the playhead is not played in from
  before it), and pre-roll in fractions of a bar.
- MIDI-CI: no discovery, profiles or property exchange. It is SysEx, which
  the MIDI ports neither send nor read yet, so a loopback could not test
  it.
- MPE for plugins that take only MIDI 1.0 (LV2, some CLAP): a note's own
  bend and controllers do not reach them; MPE is a form of MIDI output only.
- MIDI 2.0 output through the sequencer is untried here: this machine's
  kernel has no `CONFIG_SND_SEQ_UMP`, so its MIDI ports are MIDI 1.0 (the
  MIDI 1.0 forms, plain, MPE and 14-bit, are tried through the program's
  own ports).
- A VCA over a group's own fader, a VCA under a VCA, and VCA gain on the master. A VCA is a track here (so it shows in the arrange view as a row, with lanes like any other), and what it moves is the tracks assigned to it, not what they are routed into. A VCA's solo makes its members the only sound; it does not solo what they feed.
- Rendering to MP3, Ogg Vorbis or Opus without ffmpeg: there is no encoder
  for them in pure Rust of a quality worth shipping, and no C library is
  linked for them; they need ffmpeg installed (see Rendering; the Nix
  package puts one on the PATH).
- A cover in a WAV file (a WAV has no cover that players read; the
  other formats carry it), and a file dialog for the cover in the render
  dialog: its path is typed. Tags are text only: no lyrics, ISRC, composer,
  disc number or replay gain.
- For instances on other machines: the sound is sent as plain 16-bit
  samples (about 1 Mbit/s) rather than Opus, which has no encoder in pure
  Rust worth shipping; nothing is sent the other way (recording from the
  client's microphone); only sound files are sent and imported from the
  client's disk (there is no MIDI file import at all, and projects open
  and save on the instance's disk); options such as the zoom, MIDI step
  input, the automation lanes and tempo lane shown are shared by every
  seat; a window's seat does not survive `:reload`.
- Per-track loudness and spectrum in the painted mix report: the measurement
  gives each track only its peak, so the track meters are peaks, not LUFS
  or RMS. What an extension draws on the terminal's arrange view shows in
  the window only as a band it adds too.
- Dropping files where the pointer is: the window cannot learn where a file
  from a file manager is dropped (winit 0.30 reports no position), and on
  Wayland it is told of no drops at all. For a kernel the window attached
  to, the desktop's file dialog is only shown to import (the file chosen is
  sent to the kernel); Open and Save as browse the kernel's disk.
- For devices written in Lua: a window of their own drawn by the script
  (they show their parameters as sliders, like any device), sample-accurate
  parameter moves within a block (a block reads each parameter once), state
  beyond the parameters' values (a pattern an arpeggiator keeps), more
  than one stereo output, and reporting latency of their own to delay
  compensation.
- The window measured on a real graphics card: it is tried only on Mesa's
  llvmpipe so far, where playing costs more than a core.
- In the window, kanji, hanzi and hangul where the system has no font for
  them: only kana are built in, and the rest show as boxes then.
- In clip launching: follow actions (a clip that launches the next, or a
  random one, after so many bars); under a tempo ramp a slot's clip spreads
  each block's beats evenly over it, so its notes can land up to a frame or
  so from where the timeline would put them; and launches are not rendered
  as they are: they are captured into the timeline first.
- The window's position on Wayland: the compositor places windows and a
  program cannot ask for a place, so only X11 keeps it.
- The flake's `flake.lock` names the `nixpkgs` of this machine as a path in
  its Nix store, so the package builds here but not from a URL elsewhere
  until it is locked to a release (`nix flake update`). The package is built
  for x86_64 and aarch64 Linux, and tried only on the first.
- In the piano roll with several clips: `i` on a selection of clips in the
  arrange view does not open them (`i` there begins a text object; `Enter`
  does); musicops' phrase and chord text objects see the active clip only;
  the window does not shade the gaps between the clips edited; a click on a
  note shown behind always makes its clip active, so a note cannot be
  added on top of one by a click (a drag draws it).
- Insert mode's drawing writes nothing until it ends: notes drawn are not
  heard when the song plays meanwhile, nor seen by suggestions or language
  servers, and the window shows them as marks, not as notes to drag. The
  keyboard as a piano (`I`) still writes as it goes, a step to undo each key.
  Notes drawn have no length shorter than the grid, and a count before `i`
  does not draw the insert several times.
- Suggestions in the arrange view (whole clips) and the drum view: sources
  may say they offer them (`views`), but only the piano roll asks and shows
  them. A suggestion's controller moves are written when accepted but not
  drawn beforehand, and its badge has no list of the alternatives' details
  to read through; hearing one uses the track's live input, so it is timed
  by the kernel's timers rather than the engine's clock.
- MIDI files: key signatures, sysex, text and copyright events and SMPTE
  offsets are left out (counted in the message), for the project has no
  place for them; lyrics go only on notes of their own track, so a karaoke
  file with its words in a track of their own keeps none; controller moves
  on a channel or track with no notes are left out; a format 1 track that
  plays on several channels stays one track (each note keeps its channel in
  `meta.channel`, its controls are merged). A melodic track gets no
  instrument (the drum kit only on channel 10). `:export` writes MIDI clips
  only, a looped clip once, a tempo ramp as steps a sixteenth apart, a
  note's own bend and controllers (MIDI 2.0) not at all, and every control
  on its track's channel.
- Kinds of track: a kind says how a track is made and how its clips are
  opened, not how a new clip on it starts (no `new_clip`: a double click
  makes an empty clip on any track), and a track's kind is changed by
  commands of the extension (`:utau.voice`, `:drums.map off`), not from a
  list. The header shows a kind's letter in the column before the name, the
  same one diagnostics mark, which draw over it. Extensions bring devices
  written in Lua; one cannot bring a native plugin (CLAP, VST3) of its own
  to be found when it loads, nor package one with Nix: plugins are found
  where the system keeps them.
- Packaged extensions (`paw.withExtensions`) are loaded at startup and
  cannot be left out for one run other than by running the plain program.
