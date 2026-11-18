-- The roles of views that show notes on a plane of beats and pitches (the
-- piano roll, paw/views/pianoroll.lua): a note, drawn in cells as the
-- terminal always drew it, painted in a window where it is between cells
-- (crates/paw-gui/src/roles.rs).
local role = paw.roles.define

--- A note: a bar of `style` (the terminal's) with a mark at its start and,
--- when it is four cells or longer, its `label` (its name, or the
--- articulation it carries). A window paints it in `color` (its track's),
--- fainter the softer its `velocity`, lit when `selected`, outlined when
--- the keyboard's cursor is on it (`cursor`); `pending` for a note being
--- drawn in insert mode, not yet written.
role("note", {
  props = {
    label = "string", style = "highlight group", color = "#rrggbb", velocity = "number 0..127",
    selected = "boolean", cursor = "boolean", pending = "boolean",
  },
  cells = function(buf, p)
    local w = buf.width
    buf:fill(0, 0, w, 1, " ", p.style)
    buf:text(0, 0, paw.draw.g.clip_start)
    if w >= 4 and p.label then buf:text(1, 0, tostring(p.label):sub(1, w - 1)) end
  end,
})
