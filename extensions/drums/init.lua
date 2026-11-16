-- Drum tracks: a track made for drums in one step, and a grid whose rows are
-- the pieces of the kit, by name, in the terminal and in a window.
-- See README.md beside this file.
daw.option.define("drums_map", "gm")        -- the map a new drum track gets
daw.option.define("drums_step", 0.25)       -- beats a column of the grid is (a sixteenth)
daw.option.define("drums_velocity", 100)    -- how hard a new hit is
daw.option.define("drums_swing", 0.33)      -- how far `gs` moves every other step, as part of a step

require("drums")
require("drums.grid")
require("drums.commands")
require("drums.gui")
require("drums.kit")
