# Limits: what paw does not do yet

<!-- tags: missing -->

This page lists what paw does not do, and the known limits of what it does.
Each item is a fact about the current version. An item goes away when paw
gets the function.

- Undo shares a clip's notes between steps in runs of a few hundred, but
  not its controller moves: a step that changes a clip keeps a whole copy
  of those. A clip that changed is played again from all its notes: an
  edit or an undo on a clip of 200,000 notes takes some milliseconds to
  reach the engine.
- A MIDI clip's length is its own, as in REAPER: deleting its last notes
  does not shorten it (`:clip.resize`, or dragging its end, does).

- Harmony:
  - The reading uses steps of half a beat. So it reads a chord shorter
    than about a beat as passing tones (a technical name).
  - The arrange ruler does not show the chords and the key. Only the piano
    roll shows them.
  - A slash chord can have a bass that is not a chord tone. Then its name
    comes from the full set of pitches: C G B D is Cmaj9, not G/C.
  - paw reads the full song again after each edit. This is fast for songs
    of some thousands of notes, but it is not incremental.
- Snippets:
  - Only the piano roll offers snippets. A snippet can name other views,
    but nothing opens the picker there yet.
  - A snippet taken as a suggestion (`Ctrl-Space`) has no choices.
  - The preview of the picker uses the layer of the snippet, not
    `paw.complete.show`.
  - A melody of eighth notes alone can give chords, because a beat with
    two pitches is a sign of a chord.
- Pickers you can hear: `paw.opt.audition_level` sets the level of sound
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
  folders of samples and `.dslibrary` archives are not read; FLAC samples
  are kept as floats (twice the memory of 16-bit). The plugin lists no
  presets for `:preset`, has no editor
  window of its own, one stereo output, and ignores per-note controllers,
  MPE and note-off velocity.
- The waveform of an audio clip in cells (`paw.opt.wave_scale`) draws each
  column's lowest to highest sample and nothing of its loudness: there is no
  darker inner band for the RMS. The window draws a clip's peaks from the
  same data (`paw.frontend.peaks`: the lowest, the highest and the loudness
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
  A view's locator (`paw.ui.locator`, where in the project the view's
  cursor is) belongs to the view, not to each of its windows; phase 2
  makes it per window.
- The quickfix list: `:g/pattern/` and `:vimgrep` fill it, but no `:grep`
  (there are no files to run a program over) nor `/` searches; `:cfdo` runs once per track, as there
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

- Searching: the pickers' regex mode and `:vimgrep` read the common kind of
  regular expression made into Lua patterns, so a group cannot repeat
  (`(ab)+`), and there is no `\b`, no backreference and no lookaround. A
  picker's preview draws a clip as a piano roll or a waveform, not as a score
  snippet (the notation extension draws staves only in its own view). A
  picker over a hundred thousand notes takes most of a second to open. The
  `,fg` live grep searches text kept in the project, not text a plugin
  shows; the text of automation and of devices' parameters is not searched.
  `:select` chooses notes and clips; tracks, devices, markers and points
  found go to the quickfix list only. `]]` and `[[` stay on the cursor's
  track. The open-in-split keys of a picker open the first of the marked
  lines, as a view is shown in one window at a time.

- Help (`:help`): pages are laid out 78 columns wide, not to the window;
  `:helpgrep` takes words, not patterns; there is no `:helptags` (the tags
  are made the first time help is asked for, in about half a second) and
  no help in other languages. The Nix package installs the extensions
  beside the program but not `docs/`, so installed, help has the
  extensions' pages and not the manual's, until `PAW_HOME` names a source
  tree.

- Lists edited as text (`paw://tracks` and the others): a track's input,
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
  Vim's keys do when a longer mapping starts with them. `paw.opt.keys =
  "classic"` brings back the keys of before, and is to go after a release.
  The session view's `m` and `n` still mean launch mode and a new clip, not
  Vim's mark and next match.

- Notation: a tempo mark writes a point of the song's tempo
  map when it is written, and nothing keeps the two together after (moving
  the clip or the mark leaves the point where it was; no option makes the
  score own the song's tempo); repeats and endings are written, not
  unfolded; trills, mordents, turns and tremolos are written, not played,
  and a fermata holds its note's whole value but does not stop the time;
  playing techniques (`pizz.`, `con sord.`) switch an articulation only
  on a track with an articulation map (extensions/articulations), and
  only from where they are written to the end of the clip or the range;
  swing is not rendered; no CC1 or CC11 is written for sustained instruments; a key
  change after the first bar is not read by `paw.harmony` (there is no key
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
  the terminal only; a track's export transcribes what the clips play.
  Tuplets are read from the MIDI within a
  beat (and quarter-note triplets over two); nine to a beat, five over two
  beats and the like are written only when said in notation.
  The full score is at concert pitch only; a staff of the score and a part
  are every MIDI clip of their track, but a tie does not join two clips,
  a mark's beat in a clip that starts after the score's first is not moved
  with it, and a note entered before a track's first clip goes nowhere
  (one entered in a gap goes into the clip before); in a transposed part

  the popovers' keys and clefs and `:s` go by the sounding notes; a selection
  over staves takes each staff's every pitch (a block keeps its pitches
  within one staff only); a pasted passage is written as it was, not
  moved to the clef or range of the instrument it goes to; condensing
  pairs two players, as two voices where they part, and an edit is made
  for both only where they are written `a2` (`:score.split` parts them);
  `:score` takes an arrange selection's tracks, not a selection of clips;
  cues are flagged, not beamed; MusicXML carries no multi-measure rests or
  cues.

  Of the grammar for music: `!` does not run a snippet (snippets expand in
  the piano roll) nor hand a filter MusicXML (it hands it a line of text an
  event); `in` takes no count; a chord tied only in some of its notes is
  written again with those ties lost when it is moved or pasted; `Tab`
  takes suggestions made for the piano roll's clip (notation does not ask
  for them); `Ctrl-t` asks on the command line, not in a popover.

- Articulations (extensions/articulations): the window shows the notes'
  tags and colours and the shaded, named rows, but not the band, the
  keyboard's labels or menus of its own; keyswitch rows are labelled, not
  folded away; the score draws an articulation's mark in the same ink as a
  written one, and the techniques popover does not offer the map's
  articulations first; a modifier writes MIDI 1.0 controllers, not the
  profile's registered controllers (mute type, playing position);
  `:art.edit` (a map edited in a text buffer) is not there; a generated map
  is not made again when its library changes; Kontakt and SF2 are not
  read. `:art.measure` finds onsets by level alone (a sample with a slow
  swell reads late), and does not yet use the onsets a sampler's
  `describe` could report; linked controllers are a curve of their own,
  not one of the choices of the strip under the roll.

- Engraved notation: page breaks of one's own (pages fill as systems
  come), and the engraving options as a buffer to edit (staff size,
  spacing, font); articulations inside a slur; systems whose skylines
  interlock; in the terminal's cell view marks keep fixed rows rather than
  skylines; the text of an exported PDF is outlines, not searchable text.

- Language servers:
  - paw sends each document complete, never as incremental changes.
  - paw keeps the related notes of other tracks that a diagnostic names,
    but does not draw them.
  - paw draws annotations on mixer strips, devices and the ruler, not yet
    on clips or notes.
  - A fix that renders again is not an undo step, because a render is not
    an edit of the project.
  - The graphical window shows the marks only on notes. The terminal marks
    tracks, devices, time and renders. The graphical window shows them
    through `:diagnostics` and the float.
  - The settings check of MIDI LSP names the render dialog of REAPER in its
    messages.

- Pictures in the terminal: only by the kitty graphics protocol, as direct
  placements (not Sixel, not iTerm's, not Unicode placeholders), so not
  through tmux, which does not pass them on; a terminal that puts images
  over images well is known only by its name (kitty, Ghostty, herdr), and
  any other has the moving parts drawn into the page; one that puts text
  over images under it (a strip `under` the text) also only by its name
  (kitty, Ghostty, herdr, WezTerm); in any other (Konsole) the cells'
  backgrounds are painted into the picture, and one that is a single run
  along one row (a cursor block, the note under the cursor, a selection one
  row high) hides the line under it. The score, the curve editor's plot,
  the piano roll's controller strip, audio waveforms and the utau editor's
  pitch and curves are pictures; the arrange view's automation lanes, the
  velocity strip, the tempo lane and the meters are still cells. In Konsole
  a scrolled strip sends again the pieces at its edges, whose painted
  backgrounds changed.
- Scenes (the window's panes and windows of views the kernel draws; see
  "Scenes" in [the protocol](protocol.md)): runs, fills, pictures, the
  widget roles and hit regions (`buf:mark`, `buf:hit`), but no planes (a
  domain such as beats and pitches mapped onto a rectangle) and no roles
  for clips, notes or curves yet. The window paints the widget roles only;
  an extension's own role (`paw.ui.role`) shows in its cells there, as it
  has no `pixels` drawing yet. The arrange view, the piano roll, the device
  panel and the session view are still the window's own drawings, fed by
  `frontend.watch`. Pictures are made into images by paw-raster when their
  drawing changes, not drawn as egui shapes. Nodes are named by where they
  are written, so a view that scrolls sends what scrolled again. A drag on
  a hit region costs a turn of the kernel for each move, also over
  `--connect`.
- The window's mixer is the terminal's, laid out in cells: its switches
  are a cell wide, and its devices have rows of their own only when it is
  at least twenty rows tall (in the window's usual height they fold into
  one row that counts them). The theme's accent still differs between the
  terminal (amber focus) and the window (blue selection): the owner's
  decision.
- The drum grid is one view for both frontends, in cells: in a window a
  step is three cells wide whatever the clip's length, the wheel does not
  zoom the steps or scroll them sideways (the grid follows the cursor), and
  a hit is drawn as a block character, not a box shaded by velocity.
- A smooth tempo curve: a drawn stroke makes a change about each beat,
  each change a ramp to the next. The curve editor writes a smooth part as
  ramps of a sixteenth of a beat.
- In the curve editor: send levels and clip gain are not curves yet; a
  controller's moves only hold (a ramp is written as many moves); the
  window draws a lane's held and smooth stretches straight, though they
  play as shaped; waves are not `paw.snippet` snippets, which write notes.
- The mouse in the terminal: an audio clip's fades and gain are not dragged
  (the keys and the clip's commands set them), a track's height is not
  dragged (the wheel with Ctrl over the headers changes every track's), and
  the volume curve drawn over a track's lane
  is not edited with the pointer (its lane shown as a row is). Heights in a
  lane are as fine as its two lines, and finer only by dragging a point.
  Where the terminal keeps Shift for its own selection, Shift does not
  reach the program.
- Stretch:
  - Ratios are 0.25 to 4 (also each part between warp markers). Shifts are
    24 semitones at most in each direction.
  - paw always makes a stretch from the start of its file. If you put the
    playhead far into a long clip that just changed, the clip is silent
    there until paw reaches that point.
  - Only the `tonal` method keeps formants.
  - A looped clip that follows the tempo stretches evenly. paw does not
    bend it along a ramp inside it.
  - paw does not find warp markers at onsets: you put each marker by hand.
    The other takes of a clip share its markers.
- Plugins with main buses wider than stereo (surround), and inputs other
  than the main pair and one side-chain.
- Pre-roll without a punch: a take from the playhead does not play in from
  before it. Pre-roll in parts of a bar.
- MIDI-CI: no discovery, profiles or property exchange. MIDI-CI uses
  SysEx, and the MIDI ports do not send or read SysEx yet. So a loopback
  test is not possible.
- MPE for plugins that take only MIDI 1.0 (LV2, some CLAP plugins): the
  bend and controllers of a note do not reach them. MPE is a form of MIDI
  output only.
- The MIDI 2.0 attribute of a note (articulations):
  - The velocity of a note stays seven bits (1 to 127) in the project. The
    sixteen bits of MIDI 2.0 reach and leave the engine.
  - paw does not keep the attribute of a note-off (the endings of M2-123).
  - The `attr_map` of a track does not change notes played on a MIDI
    keyboard into keyswitches. It changes clips and `track:play_note`.
  - In a chord on one channel with different articulations, each
    keyswitch goes before its note. But a controller or a program change
    applies to the full chord (route one with `ch=`).
  - A MIDI file keeps the attribute in an event of paw, not in the NRPN
    form that some other programs read.
  - `paw.plugins.add_dir` finds CLAP and VST3 plugins, not LV2 plugins.
  - paw reads key names only from CLAP plugins. The piano roll of the
    graphical window shows the articulation of a note as a chip, but does
    not show the names on its keyboard.
  - A note that the `delay` of an articulation moves before the loop start
    is late after the loop turns. It starts with the loop, not before its
    end.
  - In the clip of a launched slot, paw moves notes by the tempo of the
    song at the beats of the clip.
- MIDI 2.0 output through the sequencer is not tried: the test computer
  has no `CONFIG_SND_SEQ_UMP`, so its MIDI ports are MIDI 1.0. The tests try
  the MIDI 1.0 forms (plain, MPE and 14-bit) through the ports of paw.
- A freeze after the fader: paw takes a freeze before the fader, so the
  mix stays live (`:track.bounce` also renders the fader).
  - A send from a track inside a frozen group to a track outside it is not
    heard while the group is frozen.
  - paw does not render a frozen track again when the tempo changes.
  - The graphical window does not draw `F` on the header of a frozen track
    yet. The terminal does, and `paw.freeze.state(id)` tells it.
- Narrowed tabs:
  - `:layout save` does not keep a narrowed tab, because the id of a group
    belongs to its project.
  - The graphical window has no mark for a narrowed tab other than the
    name of the tab.
  - With `scope_rest=frozen`, a part of the rest that you edit from a
    different tab plays live until paw renders it again. Renders always
    play it live.
  - A terminal and a graphical window can attach at the same time, each
    with its own tabs. Then the last frontend to change tabs sets what the
    rest does.
- VCAs:
  - No VCA over the own fader of a group, no VCA under a VCA, and no VCA
    gain on the master.
  - A VCA is a track, so it shows in the arrange view as a row, with lanes
    as any other track.
  - A VCA moves the tracks assigned to it, not the tracks that they play
    into. The solo of a VCA makes its members the only sound. It does not
    solo what they feed.
- MP3, Ogg Vorbis and Opus without `ffmpeg`. No encoder for these formats
  in pure Rust has enough quality, and paw links no C library for them.
  They need `ffmpeg` (see [Render](render.md)). The Nix package puts one on
  the PATH.
- Tags:
  - No cover in a WAV file, because players do not read one. The other
    formats have the cover.
  - The render dialog has no file dialog for the cover: you type its path.
  - Tags are text only: no lyrics, ISRC, composer, disc number or replay
    gain.
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
- Lua devices do not have:
  - a window of their own drawn by the script. They show their parameters
    as sliders, as any device.
  - parameter moves inside a block. A block reads each parameter one time.
  - state other than the values of the parameters (for example, the
    pattern of an arpeggiator).
  - more than one stereo output.
  - their own latency for delay compensation.
- The window measured on a real graphics card: it is tried only on Mesa's
  llvmpipe so far, where playing costs more than a core.
- In the window, kanji, hanzi and hangul where the system has no font for
  them: only kana are built in, and the rest show as boxes then.
- Clip launch:
  - No follow actions (a clip that launches the next clip, or a random
    clip, after some bars).
  - Under a tempo ramp, a clip in a slot spreads the beats of each block
    evenly. Its notes can be about one frame from where the timeline puts
    them.
  - paw does not render launches directly. Capture them into the timeline
    first.
- The window's position on Wayland: the compositor places windows and a
  program cannot ask for a place, so only X11 keeps it.
- The flake's `flake.lock` names the `nixpkgs` of this machine as a path in
  its Nix store, so the package builds here but not from a URL elsewhere
  until it is locked to a release (`nix flake update`). The package is built
  for x86_64 and aarch64 Linux, and tried only on the first.
- The piano roll with several clips:
  - `i` on a selection of clips in the arrange view does not open them,
    because `i` there starts a text object. `Enter` opens them.
  - The phrase and chord text objects of musicops see only the active
    clip.
  - The graphical window does not shade the gaps between the edited clips.
  - A click on a context note always makes its clip active. So a click
    cannot add a note on top of a context note. A drag draws it.
- Insert mode's drawing writes nothing until it ends: notes drawn are not
  heard when the song plays meanwhile, nor seen by suggestions or language
  servers, and the window shows them as marks, not as notes to drag. The
  keyboard as a piano (`I`) still writes as it goes, a step to undo each key.
  Notes drawn have no length shorter than the grid, and a count before `i`
  does not draw the insert several times.
- Suggestions:
  - Sources can say that they offer suggestions in the arrange view
    (whole clips) and the drum view (`views`). But only the piano roll asks
    for them and shows them.
  - paw writes the controller moves of a suggestion when you accept it,
    but does not draw them before.
  - The badge has no list of the details of the alternatives.
  - To play a suggestion, paw uses the live input of the track. So the
    timers of the kernel set its time, not the clock of the engine.
- MIDI files:
  - paw does not import key signatures, sysex, text and copyright events,
    and SMPTE offsets. The message counts them. The project has no place
    for them.
  - Lyrics go only on notes of their own track. So a karaoke file with its
    words in a separate track keeps no words.
  - paw does not import controller moves on a channel or track with no
    notes.
  - A format 1 track that plays on several channels stays one track. Each
    note keeps its channel in `meta.channel`, and paw merges the controls.
  - A melodic track gets no instrument. Only channel 10 gets the drum kit.
  - `:export` writes only MIDI clips. It writes a looped clip one time, a
    tempo ramp as steps a sixteenth apart, and every control on the channel
    of its track. It does not write the bend and controllers of a note
    (MIDI 2.0).
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
- Unloading an extension (`paw.ext.unload`) takes away what it registers
  later only when a function of its files is in it or its code made it
  there: a key mapped later to a command's name from a module of the
  core it called is not its own; its timers started with `paw.api.timer_start`
  rather than `paw.every` or `paw.defer` are not stopped. Requirements name
  extensions and the API's version, not versions of the program or of
  plugins. `:checkhealth` has no check of MIDI ports' latency or of the
  frontends attached, and the window does not show it in a view of its own
  (it is a page, as `:messages` is). `edit.before` sees a turn's edits as
  the change events they made, not as the calls that made them, and is not
  asked during an audition trial (the trial's end is). The API reference
  documents the `paw.api` functions whose definition it can read in
  crates/paw-core/src/api.rs; the others (the tempo map's, and a few written
  across lines) are listed without their parameters.
- The status line and the files: the window does not draw `paw.statusline`'s
  line (it is told the pieces, `modal.statusline`) nor the tab line's own
  sections, and `tabline.always` is the terminal's. A "scope" component has
  no meaning here, so there is none; disk recording shows as `take N`, with no
  count of bytes written (the engine does not report one). The file manager
  moves nothing between disks as a folder (a file is copied and then moved),
  has no undo of a file operation but the trash, and cannot drag a line into
  `paw://tracks` (to bring a file in, Enter or `go`); `paw` started with a folder
  does not open it. The graphical window shows a files buffer as any text buffer.
- Project diff and merge (extensions/projdiff): the diff and conflict views
  are drawn in cells, as the window draws any such view, with no painted
  version of their own (they were driven in the terminal, not in the
  window); the folds are the view's own, since a text buffer has no folds. A merge keeps a note edited on both sides as a
  conflict only when its id is the same; a note given a new id by an edit
  on each side is two notes. Lists with nothing to name their items
  (controllers) merge as sets, so a controller moved on both sides shows
  up twice. A conflict is settled by taking one side whole: there is no
  editing the two together. Anything an extension keeps in `meta` and
  points at ids with is not followed when two sides give different things
  the same id: tracks, devices, clips and lanes are renumbered with what
  points at them in the model's own fields only.
