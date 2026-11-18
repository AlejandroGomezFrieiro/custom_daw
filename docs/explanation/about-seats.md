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
