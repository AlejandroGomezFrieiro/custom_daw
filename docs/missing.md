# What is missing

- A tempo lane to draw the tempo as a curve (tempo changes are set by
  command, by script and on the window's ruler).
- In stretching: formants are not kept, so a voice shifted far sounds
  smaller or larger; ratios are 0.25 to 4 and shifts 24 semitones either
  way; a clip following the tempo is stretched evenly over its length, not
  bent along a ramp inside it; a stretch is made whole before it plays,
  so a long file takes a few seconds and is silent meanwhile; no warp
  markers to stretch parts of a clip by different amounts.
- Plugins with main buses wider than stereo (surround), and inputs beyond
  the main pair and one side-chain.
- Pre-roll before a punch: the song plays from wherever the playhead is.
- Comping with the mouse in the terminal: its take lanes are to look at, and
  `:take 2` over a selection comps there.
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
  linked for them; they need ffmpeg installed (see Rendering). Nor does the
  file carry more than the title tag (no artist, album or cover).
- For instances on other machines: encryption of network connections
  (SSH does it today), hearing the instance's sound on the machine you sit
  at, sending it files from that machine, and a cursor and mode for each
  connection (every terminal and window of an instance shares one).
- Painted windows for the undo tree (a tree of nodes to click) and the mix
  report (meters and a spectrum as shapes): in the graphical frontend they
  are their terminal views in a window. What an extension draws on the
  terminal's arrange view shows in the window only as a band it adds too.
- Braille in windows of views drawn in cells: the bundled font has none, so
  curves there are drawn with line characters.
- Dropping files where the pointer is: the window cannot learn where a file
  from a file manager is dropped (winit 0.30 reports no position), and on
  Wayland it is told of no drops at all. The desktop's file dialogs are
  not shown for a kernel the window attached to with `--socket`.
- Devices written in Lua.
- The window's GPU renderer as the default: it is tried only on a software
  OpenGL (llvmpipe) so far, where it draws correctly but costs more than
  the software renderer.
- The window's position on the screen is not remembered, only its size: the window manager decides where it goes.
- A Nix package: for now the binary is built with `cargo` inside the dev shell.
