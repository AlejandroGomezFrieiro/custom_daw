-- An example configuration. Copy it to ~/.config/daw/init.lua, or try it with
--   daw --config examples/config
-- Everything here goes through the same `daw` module the built-in commands,
-- keys and views are written with (see runtime/lua/daw/defaults.lua).

-- Options.
daw.opt.zoom = 4            -- columns per beat in the arrange view
daw.opt.grid = 0.5          -- cursor step in beats
daw.opt.leader = ","

-- Colours: override any highlight group.
daw.ui.hl("ClipMidi", { fg = "#1a1b26", bg = "#bb9af7" })
daw.ui.hl("Playhead", { bg = "#f7768e" })

-- A command of your own. `ctx.args` holds what was typed after the name,
-- `ctx.count` the number typed before a key mapping.
daw.command("track.synth", function(ctx)
  local track = daw.add_track({ name = ctx.args[1] or "Synth" })
  track:add_device("synth", { wave = 1, cutoff = tonumber(ctx.args.cutoff) or 1800 })
  track:add_device("delay", { mix = 0.2 })
  daw.cursor.set_track(track)
end, { desc = "Add a track with a synth and a delay: `track.synth Lead cutoff=900`" })

-- Keys. The right-hand side is a command line or a function.
daw.keymap.set("<leader>s", "track.synth", { desc = "Add a synth track" })
daw.keymap.set("<leader>w", "write", { desc = "Save" })
daw.keymap.set("<leader>8", function()
  -- Loop the eight bars starting where the cursor is.
  local bar = daw.time.bar()
  local from = math.floor(daw.cursor.beat / bar) * bar
  daw.transport.loop_start, daw.transport.loop_end = from, from + 8 * bar
  daw.transport.loop_enabled = true
end, { desc = "Loop eight bars from the cursor" })

-- Events: react to what happens in the project.
daw.on("track.added", function(event)
  local track = daw.track(event.id)
  -- Give every new track a colour tag that other extensions could use.
  track.meta = { created = os.date("%Y-%m-%d") }
end)

daw.on("project.saved", function(event)
  daw.notify("saved to " .. event.path)
end)
