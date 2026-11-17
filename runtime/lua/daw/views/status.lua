-- The status line: what `daw.statusline` builds from its sections (the
-- mode first, the project's name on the right, a segment dropped when the
-- screen is too narrow for it). See daw/statusline.lua for how to change it.
local view = { focusable = false }

--- A grid in beats as a note value: 1 is `1/4`, 0.25 is `1/16`.
function view.grid_text(grid) return daw.statusline.grid_text(grid) end

--- The segments for a screen `width` wide, as `{ left = {...}, right = {...} }`.
function view.segments(width) return daw.statusline.segments(width) end

function view:render(buf)
  daw.statusline.draw(buf)
end

daw.ui.view("status", view)
return view
