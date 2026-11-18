# How to move, copy, split and trim clips

<!-- tags: edit-clips -->

This guide shows you how to change the clips of the arrange view with the
keys. The keys act on the clip under the cursor. A count before a key
does it more than one time. Each key is one undo step, so `u` takes it
back. For all the keys, see [Motions, operators and modes](../reference/grammar.md).

To put the cursor on a clip, press `w` for the next clip or `b` for the
start of this clip. Press `j` and `k` to go to a different track.

## Move a clip

- Press `L` to move the clip one grid step later. Press `H` to move it
  earlier. `4L` moves it four steps.
- To move a clip to a different track, press `x` to cut it. Then move the
  cursor to the new place, and press `P`.

## Copy a clip

1. Press `yic`. paw copies the clip under the cursor.
2. Move the cursor to where the copy must start.
3. Press `P`. The copy starts at the cursor.

To repeat the clip directly after itself, press `&`. Press `&` again for
the next copy.

## Split a clip

1. Put the cursor where the clip must split, for example with `l`.
2. Press `S`. The clip is now two clips.

## Trim a clip

- To make the clip shorter at its end, press `<A-h>`. To make it longer,
  press `<A-l>`. Each press is one grid step.
- To remove the start of a clip, put the cursor at the new start. Press
  `S`, then `h` to go onto the first part, then `x` to delete it.

To make the steps finer or coarser, press `[g` or `]g`. The status line
shows the grid.

In the graphical window, drag a clip to move it, or drag it with `Ctrl` to
copy it. Drag an edge of the clip to trim it. The right-click menu of a
clip has split.

## See also

- [The arrange view](../reference/arrange-view.md): all its keys.
- [Media files and audio clips](../reference/media.md): fades and the gain of audio clips.
