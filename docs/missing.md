# What is missing

- Editing the tempo lane with the mouse in the terminal (it draws the curve;
  changes are made by command there), and a tempo curve that is smooth: a
  drawn stroke makes a change a beat or so, each ramping to the next.
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
- For instances on other machines: encryption of network connections
  (SSH does it today), hearing the instance's sound on the machine you sit
  at, sending it files from that machine, and a cursor and mode for each
  connection (every terminal and window of an instance shares one).
- Per-track loudness and spectrum in the painted mix report: the measurement
  gives each track only its peak, so the track meters are peaks, not LUFS
  or RMS. What an extension draws on the terminal's arrange view shows in
  the window only as a band it adds too.
- Dropping files where the pointer is: the window cannot learn where a file
  from a file manager is dropped (winit 0.30 reports no position), and on
  Wayland it is told of no drops at all. The desktop's file dialogs are
  not shown for a kernel the window attached to with `--socket`.
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
