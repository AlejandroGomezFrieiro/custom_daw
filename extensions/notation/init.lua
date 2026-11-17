-- Notation for daw: a MIDI clip shown as staff notation, to read and to
-- edit, in the terminal and in a window of the graphical frontend.
-- See README.md beside this file.
local view = require("notation")
require("notation.marks")
require("notation.tab")
require("notation.tui")
require("notation.gui")
require("notation.keys")
require("notation.roll")
require("notation.write")
require("notation.popover")
require("notation.files")

daw.ui.view("notation", view)
daw.ui.dock("notation", { side = "bottom", hidden = true })
-- Staves need rows: the panel takes twice the share of the arrange view.
local function weigh(node)
  for _, child in ipairs(node) do
    if child.view == "notation" then child.weight = 2 end
    weigh(child)
  end
end
weigh(daw.ui.layout)
