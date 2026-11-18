# About seats

One instance of paw can have more than one person, or more than one
screen, at a time. `paw attach` adds a terminal, and `paw-gui` adds a
graphical window. Each is a seat. This page tells why the state of a
module is divided between the seats and the project.

## One project, many points of view

All seats edit one project. There is one list of tracks, one set of
notes, one undo tree. But each person looks at a different part of it.
One person edits the drums in the piano roll while another person moves
the faders in the mixer. If the two seats shared one cursor, each key of
one person would move the view of the other person.

So paw keeps two kinds of state:

- The state of the project: notes, clips, tracks, the lanes that the
  project saves, the diagnostics of the project. All seats share it.
- The state of a view. Each seat has its own. It includes the focused
  view, the cursor, the mode, the selection, registers, marks and the
  scroll. It also includes a drag, a prompt, a suggestion on the screen
  and keys that are not complete.

Seat 0 belongs to the instance. It is the terminal of the instance, if
there is one, and each connection that has no seat of its own (`paw ctl`,
scripts). A graphical window that started its own kernel shares seat 0.

## Why modules do not change

The simple solution is to give each module a table of state for each seat,
and to make all code find the current seat. This makes each module
more difficult to write, and each module that a person forgets is
incorrect.

paw does a different thing. A module keeps its state where it usually
keeps it: in locals, or in the table of its view. It names that state one
time, with `paw.seats.keep` or `paw.seats.fields`. When the turn of
another seat starts, paw puts the values of that seat in place. The code
that reads the values does not know about seats. With one seat, nothing
moves, so the cost is zero for the usual case.

The rule has a consequence: a table that a module keeps is changed as a
whole. A new seat must get a new table, or two seats share one table.

## Turns

The kernel runs one turn at a time, and each turn runs in one seat. A
timer runs in the seat that started it. `paw.seats.within` runs code in
another seat, then returns to the current seat.

[Timers, programs and other modules](../reference/lua-other.md#pawseats-the-state-of-each-seat)
lists the functions.

## Frontends on one instance
A paw instance is one kernel with one project. Many frontends can show it
at the same time: `paw attach` in a terminal, and `paw-gui --socket` or
`paw-gui --connect` for a graphical window. They can be on the same
computer or on other computers.

### Each frontend has a seat

Each attached frontend has a seat of its own. The seat holds its cursor, its
mode and its selection. It also holds the keys that are not complete, its
registers, its prompt and the panels that it shows. The project is the same
for all seats. So two people can edit one song, each in a different view,
and neither person moves the cursor of the other.

The options in `paw.opt`, for example the zoom, belong to the instance.
All seats share them.

A graphical window that starts its own kernel shares the seat of that
kernel. So `paw ctl` acts on what the window shows. A connection that does
not attach (`paw ctl`, a script) also uses that seat.

### One undo history

An edit from one seat shows at once in all the others. Two edits of the
same thing are two steps in the one undo history, and the last edit
stays. `u` undoes the last step, from any seat. paw does not try to merge
edits: one history is easier to understand than one history for each seat.

### What stays on the computer of the instance

The plugin windows, the files that Save and Render write, and the recording
from its sound device stay on the computer of the instance. A frontend on
another computer shows the project, but the files are on the instance's
disk. For this reason, `:upload` sends a sound file to the instance before
paw imports it.

### Why the network connection is safe

A connection over the network uses TLS. The instance makes its own
certificate the first time that it listens. No certificate authority signs
it. The client trusts the certificate at the first connection, and
remembers its fingerprint in `~/.local/state/paw/known_instances`. After
that, the client refuses a different certificate. This is the model of SSH.

A connection must also show that it knows the token of the instance. The
token itself never goes over the network. So a computer that listens on
the network cannot copy the token, and a false instance cannot get it.

### Why the remote sound is late

The sound to a client goes as 16-bit samples at half the rate of the
engine: 24 kHz for 48 kHz. With the data of the protocol, this is about
1 Mbit/s. A home network carries it, but a slow link does not. The client
waits until it has a fifth of a second of sound before it plays, and keeps
not more than one second. This gives a smooth sound on a network that is not
regular, but the sound is late. For this reason, use the remote sound to
monitor a mix, not to play with the song.

### See also

- [How to work on paw from another computer](../how-to/work-from-another-computer.md).
- [The control protocol](../reference/protocol.md).
