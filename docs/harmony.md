# Harmony, completion and snippets

Writing a part means hearing it against the others. The piano roll shows
the other tracks' notes behind the clip it edits, can edit several clips at
once, and draws in layers that language servers, completion and snippets
add to.

## Several tracks in the piano roll

**Context notes.** Behind the clip's own notes the roll shows the notes of
other tracks that sound during it, fainter and each in its track's colour.
Drum tracks (those with a drum map, see `extensions/drums`) are left out.
Which tracks show is `daw.opt.roll_context`: `"all"` (the default), `"group"`
(the tracks of the clip's group), `"none"`, or a list of track ids; each
track can then be shown or hidden on its own with `:roll.tracks` (terminal)
or the side panel (window, Tracks in the toolbar). At most
`daw.opt.roll_context_max` notes (4000) are shown, and they are worked out
again only when the project, the clips edited or the choice of tracks
changes. The keys that sound at the cursor, in every clip shown, are marked
on the keyboard, and the chord they make is named when `daw.harmony` is
there to read it.

**Editing several clips.** The roll edits one *active* clip, where new
notes go, and any number of others with it. Everything that works on notes
works on all of them: motions (`w` goes from note to note across the
clips), operators and text objects (`d`, `y`, `>`, `=`, `ic` is every note
of every clip), visual mode, `p`, the keys on the note under the cursor, the
pointer's clicks, boxes and drags, the velocity strip, quantize, and the
musicops operators (each clip done on its own). A note keeps to its clip: a
drag or `H` stops at the clip's edges, and a move never takes a note into
another clip. Notes yanked from several clips remember theirs, and paste
back into it while it is edited; otherwise into the clip at the cursor. A
command that touches several clips is one undo step.

| | Terminal | Window |
| --- | --- | --- |
| make the clip of a note shown behind active | `ga` on the note | click the note |
| edit it too, or no longer | `gE` on the note | Ctrl and a click, or the box in the side panel |
| the next, the previous clip edited active | `gn` `gN` | a click on its name in the side panel |
| open several clips together | select them in the arrange view, `Enter` | choose them, double click one |
| back to one clip | `:roll.only`, or open a clip | open a clip |

The cursor's beats are the active clip's: when another becomes active the
cursor keeps its place in the song.

## For scripts: `daw.roll_clips`

- `ids()`, `active()`, `editable(id)`, `parts()` (`{ id, clip, offset,
  start, length, track, name }` each, the active one first; `offset` is how
  many beats after the active clip it starts), `span()` (the stretch they
  cover, in the roll's beats).
- `open(ids, active)`, `only()`, `activate(id)`, `toggle(id)`, `cycle(n)`.
- `notes(range)`: the notes of every clip edited in the roll's beats, each
  with `clip` and `place` (its place in its clip, for `Clip:edit_notes`);
  `note_at(pitch, beat)`.
- `tracks()`, `show_track(id, on)`, `context()` (the context notes: `{
  pitch, start, length, velocity, clip, track, color }`), `context_at(pitch,
  beat)`, `sounding(beat)` (pitches and chord name), `rows()`, `pick()`.
- The event `roll_clips.changed` when the set or the active clip changes.
- `daw.edit.roll.yank`, `delete`, `each` and `paste` take the list from
  `parts()` in place of a clip.
- It is kept per seat: two people at one instance edit clips of their own.

## Layers of the piano roll

The roll draws, back to front: the grid, the layers below 0 (the context
notes are "context", at -10), the clips' notes ("notes", at 0), the layers
above (diagnostics, a snippet's marks, suggestions), then the selection and
the cursor. A module adds a layer once and both frontends draw it:

```lua
daw.ui.views.pianoroll.layer("lint", {
  order = 10,
  -- What to draw between two of the roll's beats.
  marks = function(from, to)
    return { { pitch = 60, start = 1, length = 0.5, color = "#e05050", fill = 0.15, edge = 0.9 } }
  end,
  -- Optional, for the terminal: draw yourself instead of the marks.
  -- paint = function(view, L) L.roll:text(L.x(1), L.row(60), "!", "Error") end,
})
```

The window draws marks as rectangles (`fill` and `edge` are how opaque the
inside and the border are), under the notes for a negative order and over
them otherwise; the terminal as cells in `style`, or a faint shade of
`color`. A layer changing without the project changing calls
`daw.frontend.refresh()` for the window to fetch it again. `layer(name,
nil)` takes it away.
