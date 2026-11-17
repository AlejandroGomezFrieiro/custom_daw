-- How long the notation view's paint takes in the kernel, and how big its
-- drawing is: the first paint, a paint with nothing changed, a cursor move,
-- an edit (one note moved, then undone), and the layout thrown away.
--
--   daw --clean --no-plugins --no-listen --audio null -l extensions/notation/tools/paintbench.lua [bars] [window] [score]
--
-- With `window` it paints as the window is asked (glyphs as paths, with the
-- toolbar); else as a terminal's pixel surface is (glyph ops, 13 x 27 px cells).
-- With `score` the clip is written as a score first, and the edit's time is
-- the edit itself (the score changed and its notes rendered) and the paint.
local daw = require("daw")
local api = daw.api
local args = { ... }
local bars = tonumber(args[1]) or 16
local window = args[2] == "window" or args[3] == "window"
local as_score = args[2] == "score" or args[3] == "score"
daw.ext.load("extensions/notation")
local bench = require("notation.bench")
local result = bench.run(bars, window and { cell = { w = 7.8, h = 17 } } or { glyphs = true, surface = true, cell = { w = 13, h = 27 } }, nil,
  { score = as_score })
print(bench.format(result))
