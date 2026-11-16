-- A completion source that continues the phrase before the cursor: the
-- last bar again, a step higher or lower in the key, or its last motif
-- rising. A small example of `daw.complete.register`; see README.md.
local continue = require("continue")

daw.complete.register({
  name = "continue",
  priority = 10,
  views = { "pianoroll" },
  auto = true,
  complete = function(ctx, done)
    ctx.bar = daw.time.bar(ctx.start + ctx.at)
    done(continue.suggest(ctx))
  end,
})
