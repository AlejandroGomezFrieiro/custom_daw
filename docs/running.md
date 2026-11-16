# Running it

The dev shell provides the Rust toolchain and the PipeWire libraries.

```sh
nix develop
cargo run -- -e 'dofile("examples/demo.lua")'       # open a demo song in the UI
cargo run -- --config examples/config                # the same UI with an example configuration
cargo run -- -l examples/demo.lua demo.wav           # no UI: build the song and render it
cargo run -p daw-gui -- -e 'dofile("examples/demo.lua")'   # the graphical frontend
cargo test                                           # the end-to-end suite
cargo run -- --output UR22 --input UR22              # open these audio devices (a part of the name is enough)
cargo run -- doctor                                  # check the audio, plugins and environment, and print a report
```

## Installing with Nix

The flake builds the program as a package, so that it can be run or installed
without the dev shell, on any Linux with Nix and flakes (no NixOS or
home-manager is needed):

```sh
nix run .                       # the terminal UI (`daw`)
nix run .#daw-gui               # the window; `.#daw` and `.#daw-mcp` are the others
nix build                       # ./result/bin/{daw,daw-gui,daw-mcp}
nix profile install .           # into your profile: daw, daw-gui and daw-mcp on the PATH
nix profile remove daw          # and out again
```

Run these in a checkout, where `.` is the flake. One build gives all three programs, and `.#daw`, `.#daw-gui` and `.#daw-mcp` are
only the one named, out of it. The window starts its own kernel, which is the
`daw` beside it, so it needs no other install.

What the package takes care of, which the dev shell does otherwise:

- The window's libraries (Wayland, xkbcommon, X11, fontconfig, OpenGL) and
  the ones that plugins built elsewhere open by name are written into the
  programs, so they run from any shell. The OpenGL driver for
  `--renderer gpu` is the system's (on NixOS `hardware.graphics.enable`).
- LuaJIT is built with `LUAJIT_ENABLE_CHECKHOOK`, as `.cargo/config.toml`
  asks, so that `daw.limit` can stop a runaway loop.
- The runtime's Lua and the window's fonts are compiled into the binaries.
  The extensions, `examples` and `config` are installed under
  `share/daw`, and the programs start with `DAW_HOME` pointing there (unless
  you set it): `daw doctor` finds its script that way, and
  `daw.ext.load(os.getenv("DAW_HOME") .. "/extensions/sections")` loads an
  extension from the package.
- `ffmpeg` is on the programs' PATH, after your own, for rendering to MP3,
  Ogg Vorbis and Opus; nothing else needs it. `daw.opt.ffmpeg` names
  another.
- The tests do not run in the build: they drive plugins, audio devices and
  an X server, which a build sandbox has none of. They run in the dev shell
  (`cargo test`, `tests/tools/suite.sh`).

The project's state (recent projects, the window's layout, the plugin cache)
is kept under your home directory as with any build, in `~/.local/state/daw`
and `~/.cache/daw`.

The audio devices are the system's default output and input until others are
chosen: with `:audio` (a list of every output, input and block size), with a
click on the engine indicator at the right of the window's transport bar, or
with `--output` and `--input`. A choice made in the program belongs to the
machine, not to a project: it is kept in `~/.local/state/daw/audio.json` and
opened at the next start; when a remembered device is not connected, the
default is opened instead and the program says so.

Every project opened or saved is remembered, newest first, twenty at most, in
`~/.local/state/daw/recent.json`; the list belongs to the machine, and a file
that is gone drops out of it. `:recent` chooses from it (`,fR`), `:recent 2`
opens the second, `:recent.clear` forgets them, and the window's File menu has
them under "Open recent", asking about unsaved changes as "Open" does. With
`daw.opt.reopen_last = true` a start with no project named opens the newest
one; if it will not open, that is a message and the program starts anyway.
Nothing is remembered under `--clean` or in a script. In Lua:
`daw.recent.list()` gives `{ path, name, time }` for each.

The suite hosts real plugins in all three formats. The dev shell provides them
(LSP Plugins and Surge XT, through `DAW_TEST_PLUGINS`); outside it those tests
are skipped.

`cargo test -p daw-gui` also drives the real window
(`crates/daw-gui/tests/window.rs`): each scenario starts Xvfb on a free display
from `:120` up, openbox and the window (with no session bus, so that nothing
reaches the desktop), makes pointer and key gestures with xdotool, and asks
the kernel what it holds afterwards. Menu entries and dialog buttons are found
by reading the screen: ImageMagick takes a picture of the window and tesseract
reads the words on it, so that a new entry in a menu moves nothing the tests
rely on. The tests need `Xvfb`, `openbox`, `xdotool`, ImageMagick and
`tesseract` (the dev shell has them), and the MP3 one `ffmpeg`. Without them
these tests say what is missing and pass. A failed scenario leaves
`failure.png` and the window's output under `target/tmp/window/<scenario>`.
`-- --ignored` runs the ones that are marked `#[ignore]`: how reliably the
screen is read (a measurement of several minutes), and known bugs, when there
are any.

The first start looks through every installed plugin, which can take several
seconds (bridged Windows plugins each start Wine). The result is cached in
`~/.cache/daw/plugins.json`; after that a plugin file is only loaded when it
changes or when one of its plugins is used. `--no-plugins` skips plugins
altogether.

`Space` plays, `?` finds a key: it lists every key of the focused view and the
global ones, typing part of a key or of what it does narrows the list, and
Enter runs the one chosen (`:help all` shows them as one page). `:` runs any
command by name, `:q` quits. As you type a command, a list above the command
line shows what it could become, with what each does: command names first,
then what the command takes (tracks by name for `:send`, devices for
`:device.add`, files for `:open`, `:import`, `:render`, `:write`, options
for `:set`). `Tab` and `Shift-Tab` (or `Ctrl-n` `Ctrl-p`) choose one into the
line, `Enter` runs the line, and on a directory goes into it. `:set zoom 4`,
`:set zoom=4` and `:set follow!` change options; `:open` opens a project, a
MIDI file (as a new project) or a sound file. After an error the bottom line says how to read it whole (`,fn`
picks among the messages, `:messages` shows them all, newest at the bottom)
until you have. Stop halfway through a command and the keys
that can follow are listed.

New to it? There is a course of sixteen short lessons that runs inside the
program, in the manner of `vimtutor`: load `extensions/tutor` (see
[Extensions](extensions.md#extensions)) and type `:tutor`. The same lessons are in
[docs/course](course/README.md) for reading, with a one-page
[key reference](course/keys.md).

## On another machine

An instance can be worked on from other terminals and windows, on the
same machine or another: `daw attach` in a terminal, `daw-gui --socket` or
`daw-gui --connect` for a window. Each of them has a seat of its own: its
own cursor, mode, selection, keys half typed, registers, prompt and panels
shown, while the project is one. What one does the others see at once;
two edits of the same thing are two steps in the one undo history, and the
last one stands. `u` undoes the last step whoever made it. Options
(`daw.opt`, such as the zoom) are the instance's and shared. A window that
started its own kernel shares that kernel's seat, so `daw ctl` acts in what
it shows; so does every connection that has not attached (`daw ctl`,
scripts).

Over the network, start the instance with `--listen-tcp`:

```sh
daw --listen-tcp 0.0.0.0:7700            # every network the machine is on
daw --headless --listen-tcp 127.0.0.1:7700
```

Connections are encrypted with TLS. The first time it listens the instance
makes a certificate of its own and keeps it in `~/.local/state/daw/tls`;
it says its fingerprint when it starts (`listening on … certificate
9f1c:…`). A connection must also show that it knows the token in
`~/.local/state/daw/token` on the instance's machine (made at the first
start; copy it to the other machine); the token itself is never sent.

```sh
daw attach --connect studio:7700 --token-file studio.token
daw-gui --connect studio:7700 --token-file studio.token
```

The first connection to an address trusts the certificate it is shown and
remembers its fingerprint in `~/.local/state/daw/known_instances` on the
client's machine; compare it with the one the instance said. Afterwards a
different certificate is refused, with both fingerprints named: either
the instance made a new one (its state directory was lost, or it moved
machine), and `--accept-certificate` takes it, or something between the
two machines is pretending to be it. `--no-tls` on both sides speaks in
the clear, for a network you trust; an instance that only takes TLS tells
a client in the clear so. SSH needs nothing from the program either:

```sh
ssh -N -L /tmp/studio.sock:/run/user/1000/daw.sock studio &
daw attach --socket /tmp/studio.sock
```

**Files from the machine you sit at.** Import and Open browse the
instance's disk. To bring in a sound file from the client's, drop it on a
window attached elsewhere, choose it in the window's Import dialog (the
desktop's own dialog runs on the client), or type `:upload ~/take.wav` in
an attached terminal. It is sent over the connection in pieces into the
project's `media` folder on the instance's machine (beside a saved project,
else a scratch folder) and imported on a new track.

**Hearing it.** The sound plays on the instance's machine. `daw attach
--listen-audio` and `daw-gui --connect … --listen-audio` also play it
through the client's own sound device, and `:listen` (or "Hear it on this
machine" in the window's engine menu) starts and stops that. It is sent as
16-bit samples at half the engine's rate (24 kHz for 48 kHz), about
1 Mbit/s with what the protocol adds: fine on a home network, too much for
a slow link. The client waits until a fifth of a second has arrived before
it plays and keeps at most a second, so it is heard a quarter of a second
late or more: for monitoring a mix, not for playing along.
`daw attach --listen-audio-to heard.wav` writes what it would play to a
file instead.

What stays on the instance's machine: plugin windows, the files that Save
and Render write, and recording from its sound device.
