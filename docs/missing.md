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
- MIDI-CI, an editor for controller moves, and MIDI 2.0 on the way out:
  MIDI output sends MIDI 1.0, so a note's own bend and the finer values
  are lost there.
- Groups that link faders without routing (VCA style); groups here are by routing into the group's track.
- Rendering to MP3, Ogg Vorbis or Opus without ffmpeg: there is no encoder
  for them in pure Rust of a quality worth shipping, and no C library is
  linked for them; they need ffmpeg installed (see Rendering). Nor does the
  file carry more than the title tag (no artist, album or cover).
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
- The window's position on the screen is not remembered, only its size: the window manager decides where it goes.
- A Nix package: for now the binary is built with `cargo` inside the dev shell.
