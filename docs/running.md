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
`:set zoom=4` and `:set follow!` change options; `:open` opens a project or a
sound file. After an error the bottom line says how to read it whole (`,fn`
picks among the messages, `:messages` shows them all, newest at the bottom)
until you have. Stop halfway through a command and the keys
that can follow are listed.

New to it? There is a course of sixteen short lessons that runs inside the
program, in the manner of `vimtutor`: load `extensions/tutor` (see
[Extensions](extensions.md#extensions)) and type `:tutor`. The same lessons are in
[docs/course](course/README.md) for reading, with a one-page
[key reference](course/keys.md).
