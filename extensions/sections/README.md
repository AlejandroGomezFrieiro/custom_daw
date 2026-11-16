# sections

Song sections for daw: intro, verse, chorus and the rest as named stretches of
the timeline. A section has a name and a start, and runs to the start of the
next one; the last runs to the end of the project (at least one bar). They are
text objects and motions, so the operators you already use work on a whole
section, and they are the units to rearrange the song by: move a chorus past
the verse, repeat it, cut it out, put a copy of it somewhere else, on every
track at once and as one undo step.

```lua
daw.ext.load("extensions/sections")   -- or put it in ~/.config/daw/extensions
```

## On screen

Each section's name is on a second row of the arrange view's ruler, under
the bar numbers, where it starts; the row is there while there are sections.
The section under the cursor is lit in amber. When a section's start has scrolled
off the left edge its name stays at the left, after a `‹`, so you can see
which section you are in. The column where each section starts is tinted
across the tracks.

## Keys

In the arrange view.

| Keys | |
| --- | --- |
| `]s` `[s` | start of the next section; of this one, or the one before. A count goes further. After the last section `]s` goes to the end of the project. They are motions: `d]s`, `y[s`, `v]s` |
| `is` | text object: the section under the cursor, on every track; `2is` that one and the next |
| `as` | the same, widened outwards to whole bars (for a section that starts with a pickup) |
| `<leader>Sa` | add a section at the cursor (asks for a name; Tab offers the usual ones) |
| `<leader>Sr` | rename the section at the cursor |
| `<leader>Sx` | remove the section's marker; what is on the timeline stays |
| `<leader>Ss` | go to a section, chosen from a list |
| `<leader>Sl` | show the list of sections |
| `<leader>SL` `<leader>SH` | move the section later past the next one, or earlier past the one before; with a count, further |
| `<leader>S&` | repeat the section right after itself, pushing the rest of the song along |
| `<leader>Sd` | delete the section from every track and close the gap; it goes into the register |
| `<leader>Sy` | yank the section with its automation and marker |
| `<leader>Sp` `<leader>SP` | insert the register after or before the section at the cursor, on every track, pushing the rest along |
| `<leader>Sc` | insert a copy of a section, chosen from the list, before the section at the cursor |

With the text objects the built-in operators need nothing more: `dis` empties
the section on every track (or closes the gap with `daw.opt.ripple`), `yis`
yanks it, `glis` loops it, `>is` nudges its clips, `vis` selects it. `<leader>Sd`
then `<leader>SP` elsewhere is how a section is moved further than past its
neighbour. Registers (`"a<leader>Sy`), counts and `.` work as everywhere else.

The list uses `daw.pick` when there is one; without it `<leader>Ss` and
`<leader>Sc` ask for a name on the command line (Tab completes), and
`<leader>Sl` shows the list as a page.

## Commands

| Command | |
| --- | --- |
| `section.add [name] [at=beat]` | add a section at the cursor, or at a beat; asks for the name if none is given |
| `section.rename [name] [section=old]` | rename the section at the cursor, or the one named by `section=` |
| `section.remove [name]` | remove a section's marker |
| `section.list` | show the sections |
| `section.goto [name or number]` | go to a section; with neither, choose from the list |
| `section.move [name] [by=1]` | move a section past its neighbours, `by=-1` earlier |
| `section.duplicate [name]` | repeat a section after itself |
| `section.delete [name]` | delete a section and close the gap, into the register |
| `section.yank [name]` | yank a section into the register |
| `section.put [before=true]` | insert the register after (or before) the section at the cursor |
| `section.copy [name] [after=true]` | insert a copy of a section before (or after) the section at the cursor |

Without a name the commands act on the section under the cursor. A name
matches exactly, then ignoring case, then by its start (`chor`).

## What moves

Every arranging command works on every track at once. Clips reaching across a
section's edges are cut there first, and the pieces go with their sections;
a MIDI note belongs to the piece it starts in and is shortened to fit it, as
with the built-in operators. A clip that moves keeps its id and its `meta`.

Automation lanes (volume, pan and device parameters, on every track and the
master track) move with their sections too. Each piece of the song takes the
lane's values at its edges with it as points, so a moved section sounds the
way it did, and where it meets a different neighbour the lane steps from one
value to the other. Points that change nothing are dropped afterwards.

Section markers move with what they mark: moving a chorus moves its name,
duplicating it makes a second chorus, deleting it removes it, and a section
yanked with `<leader>Sy` or deleted with `<leader>Sd` brings its marker back
when it is inserted.

Tempo, the time signature, the loop and the playhead are not moved.

## The Lua module

```lua
local sections = require("sections")

sections.list()                 -- { { index, name, start, finish }, ... } in order
sections.at(beat)               -- the section a beat is in, nil before the first
sections.current()              -- the one under the edit cursor
sections.find("chor")           -- by name: exact, any case, or the start of it
sections.get(which)             -- an index, a name, a section, or nil for the current one
sections.next_start(beat)       sections.prev_start(beat)

sections.add("Chorus", 64)      -- fails if a section starts there already
sections.rename("Chorus", "Hook")
sections.remove(3)
sections.set_start("Hook", 60)  -- move the marker only
sections.set({ { name = "A", start = 0 }, { name = "B", start = 32 } })

-- Arranging, on every track; each returns the section where it ended up.
sections.move("Verse", 1)       -- past the next one; -1 past the one before
sections.duplicate("Chorus")
local value = sections.delete("Bridge")   -- a register value
sections.insert(value, 96)                -- push what is at 96 along and put it there
sections.copy("Chorus", 128)
sections.yank("Chorus")
sections.rebuild(plan)          -- the general form; see lua/sections/arrange.lua

daw.on("sections.changed", function(event) print(#event.sections) end)
```

Sections are stored in the project as `project.meta.sections`, a list of
`{ name, start }`, so they are saved and loaded with it and every change is
undone with `u` like any edit. `sections.changed` is emitted when the list
changes for any reason, edits, undo, redo, a new or loaded project included,
once the command that changed it has returned (or on `daw.flush()`).

A register value from `sections.yank` or `sections.delete` is an ordinary
`range` value, so `p` and `P` paste it too (from the cursor's track down,
without automation or markers). It has `lanes` and `sections` besides.

## Not done

- The status line does not show the current section: it is part of the
  runtime and has no place for extensions to add to. The ruler keeps the
  current section's name in view instead.
- Inserting a section matches tracks by position: if tracks were added,
  removed or reordered between yanking and inserting, its clips land on the
  tracks now in those places. Automation is matched by target, parameter and
  device position on the track; a lane with no counterpart where the section
  goes is left out.
- Notes that sound across a section's edge are shortened, not carried over.
- The right half of a clip cut at a section's edge is a new clip; it keeps
  the clip's `meta`, but not its id.
- Sections can't be dragged with the mouse, and the graphical frontend does
  not show them.
