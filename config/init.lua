-- A configuration to start from: every bundled plugin loaded, and the
-- settings worth knowing about, each with what it does. It runs at startup
-- and again on `:reload`.
--
-- To make it yours, link this directory as the configuration directory:
--
--   ln -s /home/alejandro/custom_daw/config ~/.config/daw
--
-- or try it for one run with `daw --config /home/alejandro/custom_daw/config`
-- (`daw-gui` takes the same option).

-- Where the bundled plugins are: the `extensions` directory beside this one,
-- or wherever $DAW_HOME says the source tree is.
local home = os.getenv("DAW_HOME") or "/home/alejandro/custom_daw"
local plugins = home .. "/extensions"

-- The plugins. Take a line out, or put `--` before it, to leave one out;
-- each has a README in its directory saying what it adds and which keys.
for _, name in ipairs({
  "drums",      -- drum tracks in one step, a grid of the kit's pieces (`,kn`; `:drums.track`)
  "notation",   -- a MIDI clip as staff notation, to read and edit (`,n` on a clip)
  "utau",       -- singing synthesis and the vocal editor (`,v` adds a vocal track)
  "vinput",     -- virtual inputs: a guitar heard as MIDI through gdi2m (`,i`)
  "templates",  -- tracks, groups and device chains saved under a name (`,Tl` makes one, `,Ts` saves)
  "pattern",    -- clips written as a line of pattern text (`,tt`)
  "sections",   -- named sections of the song, and arranging by section (`,S…`)
  "musicops",   -- humanize, strum, arpeggiate, scales and the project's key
  "mixdiag",    -- the mix measured: loudness, true peak, phase (`,x…`)
  "undotree",   -- the undo tree, named checkpoints, A/B listening (`,u…`)
  "rpp",        -- opening and writing REAPER projects
  "tutor",      -- the course: `:tutor` starts it
}) do
  daw.ext.load(plugins .. "/" .. name)
end

-- Audio. The devices are chosen once from the engine menu (`:audio`) and
-- remembered for this machine; name them here instead to pin them.
-- daw.audio.use({ output = "UR22mkII Stereo", input = "UR22mkII", buffer = 128 })

-- How things look and behave. These are the values the program starts with;
-- change one and take the `--` away.
-- daw.opt.zoom = 4              -- columns per beat in the terminal's arrange view
-- daw.opt.track_height = "auto" -- rows per track in the terminal; a number to fix it
-- daw.opt.header_width = "auto" -- columns for the terminal's track headers
-- daw.opt.termcolors = "auto"   -- "true" for 24-bit colour, "256", or "auto" to ask the terminal
-- daw.opt.ascii = false         -- draw the terminal with plain ASCII characters only
-- daw.opt.braille = true        -- curves in braille dots; false for lines
-- daw.opt.grid = 1              -- beats the cursor and clips snap to
-- daw.opt.note_grid = 0.25      -- beats notes snap to (a sixteenth)
-- daw.opt.autosave = 60         -- seconds between safety copies; 0 for none
-- daw.opt.reopen_last = false   -- start with the project that was open last, when none is named
-- daw.opt.threads = 0          -- audio threads; 0 leaves it to the machine
-- daw.opt.keybar = true         -- the line of keys at the bottom of the terminal
-- daw.opt.editor_on_add = true  -- a plugin added by hand (picker, `:device.add`, the window) opens its own window

-- A colour of your own for anything on screen:
-- daw.ui.hl("Playhead", { bg = "#ff5555" })

-- A key of your own: `,y` adds a track with a synth on it.
-- daw.keymap.set("<leader>y", function()
--   local track = daw.add_track({ name = "Synth" })
--   track:add_device("synth")
--   daw.cursor.set_track(track)
-- end, { desc = "Add a synth track" })
