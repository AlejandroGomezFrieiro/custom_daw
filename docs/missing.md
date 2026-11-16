# What is missing

- Language servers: only clips are sent (MIDI LSP's `track`, `project` and
  `render` documents and its one-shot servers are not); a server's own code
  actions (`codeActionProvider`) and `workspace/executeCommand` have no
  menu, only the fixes that come with diagnostics; the related notes of
  other tracks a diagnostic names are kept but not drawn; the window shows
  what servers say about a note through the float, not a tooltip of its own,
  and marks no clips with diagnostics in its arrange view (the terminal's does).

- A tempo curve that is smooth: a drawn stroke makes a change a beat or so,
  each ramping to the next.
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
- Groups that link faders without routing (VCA style); groups here are by routing into the group's track.
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
  seat; a view docked by an extension after a seat opened shows only in
  the seat that docked it; a window's seat does not survive `:reload`.
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
- The window's GPU renderer as the default: it is tried only on a software
  OpenGL (llvmpipe) so far, where it draws correctly but costs more than
  the software renderer.
- The window's position on Wayland: the compositor places windows and a
  program cannot ask for a place, so only X11 keeps it.
- The flake's `flake.lock` names the `nixpkgs` of this machine as a path in
  its Nix store, so the package builds here but not from a URL elsewhere
  until it is locked to a release (`nix flake update`). The package is built
  for x86_64 and aarch64 Linux, and tried only on the first.
