# Pictures in the terminal

<!-- tags: extensions-pictures-in-the-terminal -->

This page describes how a view shows pixels in the terminal and in the
graphical window: strips, `paw.plot`, and what a frontend does with
strips. "Pictures" in [The terminal interface](../terminal.md) tells which
terminals show pictures.

## Strips

A view that draws cells can show a part of itself in pixels. In its
`render`, it keeps a **strip** of cells, and tells how to draw the strip.
It also draws its cells as usual.

```lua
render = function(self, buf, ctx)
  local plot = buf:sub(10, 2, buf.width - 10, buf.height - 3)
  plot:fill(0, 0, plot.width, plot.height, " ", "Lane")
  local pictured = plot:strip(0, 0, plot.width, plot.height, {
    key = "mylane:" .. ctx.win.id,       -- the name of the strip: one for each window
    under = true,                         -- the cells drawn here stay, above the picture
    draw = function(g, px)                -- after the screen is drawn. px: w, h, cell = { w, h }, fg, bg
      paw.plot.curve(g, px, { points = points, from = left, pixels_per_beat = zoom * px.cell.w,
        lo = 0, hi = 1, color = paw.draw.track_colour(track) })
    end,
  })
  if not pictured then draw_the_curve_in_cells(plot) end
  draw_the_cursor_and_points(plot)       -- cells, over the picture or alone
end
```

`buf:strip(x, y, w, h, opts)` returns false where there are no pixels:
`paw.opt.graphics` is off, the terminal shows no images, tmux, or `paw
attach` from such a terminal. The view then draws its cells there.

| Option | Effect |
| --- | --- |
| `key` | the name of the strip, and of the images that the terminal keeps. Default: the view and its window. A view with more than one strip names each strip |
| `under` | true: the picture is under the text. The backgrounds of the cells show where the picture draws nothing. False: the cells of the strip are blank |
| `draw(g, px)` | draws the pixels with a painter of `paw.canvas` (`g:rect`, `g:poly`, `g:text`, `g:cut`, `g:layer`, as in `paint`) |

- In a terminal where a colored background hides the picture (Konsole),
  paw paints the backgrounds of the cells into the picture. A background
  that is one run along one row (a cursor block, the note under the
  cursor) stays a cell.
- Draw a cursor that moves over the picture as such a block, or as a
  glyph (a line on the left edge of the cell). Do not draw it as a column
  of blocks.
- A strip can extend past its window, for example an audio clip that is
  half out of view. Then `px.w` and `px.h` are the size of the full strip,
  drawn from its own corner. `px.view` (`x`, `y`, `w`, `h`) is the part
  that shows.
- `paw.plot.span(px, step)` gives the part to draw, in whole steps from the
  left of the strip. A part drawn before is the same after a scroll, so
  paw moves its pieces and does not send them again.
- The frontend makes the pixels. It cuts them into pieces at the `g:cut`
  marks of the drawing, and keeps each piece by the hash of its pixels. A
  strip that draws the same pixels again sends nothing. An edit sends
  only the pieces that it changed.
- `buf:surface(x, y, w, h)` is the same, over the text, for the full
  `paint` of a view.

## `paw.plot`

`paw.plot` draws in strips what views show over time, with the same
appearance in all views.

`paw.plot.curve(g, px, opts)` draws a curve:

- the lines of the bars and beats, from the tempo map
  (`paw.draw.bar_lines`), cut at each bar on the edge of a cell
- the area under the curve, and the line, with one sample for each pixel
  from `paw.curves.value_at`
- a small mark at each point

It draws no background unless `opts.background` gives one, so the
backgrounds of the cells show under the text. It returns `x(beat)` and
`y(value)` for the rest of the drawing.

| Option | Value |
| --- | --- |
| `points` | the points, as `paw.curves` gives them |
| `from` | the beat at the left |
| `pixels_per_beat` | the zoom |
| `frac(value)`, or `lo` and `hi` | the value as 0 to 1 |
| `flat`, `color`, `fill` (the opacity of the area), `width`, `top`, `bottom` | the appearance |
| `grid`, `beats`, `guides`, `markers`, `background` | what else to draw |
| `shape = "hold"` | each value holds until the next point |

The curve editor (`paw.curves.editor.picture`), the controller strip of
the piano roll (with `shape = "hold"`) and the curve of the utau editor
use `paw.plot.curve`.

| Function | Draws |
| --- | --- |
| `paw.plot.lines(w, from, pixels_per_beat, cell_w)` | the lines of the bars and the beats only |
| `paw.plot.bars(g, px, opts)` | a bar from the bottom for each of `opts.items`, `{ beat, value, color, bright }`, `value` 0 to 1. Options: `from`, `pixels_per_beat`, `width`, `color` |
| `paw.plot.wave(g, px, opts)` | a waveform. `opts.peaks(n)` gives `n` values `{ min, max, rms }` across the strip (`api.clip_peaks`). The RMS is a brighter band inside (`rms`, false for none). A column at full scale is in `clipped` (red). The scale is `paw.opt.wave_scale`. It draws in parts of eight cells. The arrange view draws its audio clips this way |

Each function has a twin in cells, for where there are no pictures. It
takes the same options, and `zoom` (cells for each beat) in place of
`pixels_per_beat`:

| Function | Cells |
| --- | --- |
| `paw.plot.curve_cells(buf, opts)` | connected sextants (`paw.opt.curve_glyphs`) |
| `paw.plot.bars_cells(buf, opts)` | eighth blocks |
| `paw.plot.wave_cells(buf, opts)` | `paw.draw.waveform` |

## What a frontend does with strips

A frontend that draws the screen itself (a remote terminal) gets the grid
of cells and its strips. Each strip is a `Surface`
(`crates/paw-core/src/grid.rs`). Over `paw attach`, they are the
`surfaces` of `ui.grid` (`crates/paw-core/src/remote.rs`).

| Field | Meaning |
| --- | --- |
| `key` | the name of the strip. Keep what you make of it (images, textures) by key. Drop it when a frame has no strip with that key |
| `rect` | the cells of the screen that the strip shows |
| `whole` | the size of the full strip in cells, when a part is off its window. (0, 0) when all of it shows |
| `offset` | the cells of the strip to the left of `rect` and above it |
| `cell` | the size of a cell in pixels, for the drawing |
| `ops` | the drawing, in pixels from the corner of the full strip: the operations of `paw.canvas` (`r` rectangles, `p` paths, `t` text, `m` runs of cells, `g` music glyphs, `cut` where it can be cut into pieces, `layer` for what comes next) |
| `under` | false: the cells of the strip are blank, and the picture is over all of `rect`. true: draw the picture after the backgrounds of the cells and before their text |
| `covered` | a flag for each cell, row by row (`covered_runs` over the wire): cells that something draws over the strip later (a menu, a floating view). Do not draw the picture in them |

- Draw `ops` with `paw_raster::Drawing`, or with the painter of the
  frontend. Scale by the cell size of the frontend over `cell`, translate
  by `-offset * cell`, and clip to `rect`.
- With `under` true, the characters of the view (its cursor, points,
  labels, the playhead) are over the picture. The backgrounds of the cells
  show where the picture draws nothing.
- A frontend that paints its pictures in pieces (the terminal does, with
  the kitty protocol) cuts the full strip at the `cut` marks. It keeps
  each piece by the hash of the operations in it (`Drawing::piece_key`). It
  does not make a piece again when the piece did not change, or only
  moved.

### In the graphical window

The graphical window (`crates/paw-gui`, on egui) does not get the grid. A
view that it shows in a pane, or in a window of its own, comes as a scene
(`crates/paw-scene`, and "Scenes" in [The control
protocol](protocol.md)).

- `paw.ui.render_scene(name, w, h, cell, win)` makes the scene from the
  writes of the view. Each `buf:text` is a run and each `buf:fill` is a
  fill, kept by place. paw sends what changed.
- While paw draws the view for a scene, `buf:strip` keeps each strip under
  the text (`paw.ui.pictures`) and returns true. The `draw(g, px)` of the
  strip, at the cell size of the window, is a picture of the scene, cut to
  the part that shows (`px.view`).
- The window draws the backgrounds of the cells first, then the pictures
  under the text, then the text in its own font. A view that paints is one
  picture.
- So the curve editor and the vocal editor show curves in pixels in the
  window, and nothing in `crates/paw-gui` knows about strips.
- The scene is made from the writes of the view. So a view must draw only
  through the buffer that it gets. `tests/scene_parity.lua` checks each
  view, the views of extensions too. It also checks that the scene, lowered
  to cells, is the drawing of the view.
- A view that the window draws natively (the arrange view, the piano roll,
  the mixer) draws its curves and waveforms with the painter of egui, and
  has no strips.
