-- Options: `daw.opt.zoom = 4`. Any name can be set; the ones the runtime
-- reads are defined below. Changing one emits `option.changed`.
local M = {}

local defaults = {
  leader = ",",            -- what `<leader>` means in key mappings
  timeoutlen = 800,        -- ms to wait for the rest of a key sequence
  hint_delay = 500,        -- ms before the keys that can follow are listed; 0 for at once
  hints = true,            -- list the keys that can follow a half-typed command
  keybar = true,           -- show the keys worth knowing first on the bottom line
  ripple = false,          -- deleting time closes the gap, pasting makes room
  -- Seconds between safety copies of unsaved work; 0 for none. Off when
  -- started with --clean, which is how tests and experiments run.
  autosave = require("daw.api").env().clean and 0 or 60,
  reopen_last = false,     -- start with the project that was open last, when none is named
  threads = 0,            -- threads to process tracks on; 0 for one per core
  octave = 4,              -- where note entry in insert mode starts: `a` is C of this octave
  grid = 1,                -- arrange cursor step and snap, in beats
  zoom = 2,                -- arrange columns per beat
  track_height = "auto",   -- arrange rows per track; "auto" fits the tracks to the screen, 3 to 6
  header_width = "auto",   -- arrange columns for the track headers; "auto" by the screen's width
  termcolors = "auto",     -- "true" for 24-bit colour, "256", or "auto" to ask the environment
  ascii = false,           -- draw with plain ASCII characters only
  braille = true,          -- draw curves with braille dots
  mouse = true,            -- the terminal reports the pointer; false leaves it to the terminal's own selection
  graphics = true,         -- views that paint show pixels where the terminal shows images; false keeps cells
  follow = true,           -- scroll to keep the playhead in view
  fps = 30,                -- redraw rate while something is moving
  clip_length = 4,         -- beats, for new MIDI clips
  count_in = 0,            -- bars the metronome counts before recording from a stop; 0 for none
  pre_roll = 0,            -- bars a take punched in from a stop plays before the punch in
  pre_roll_seconds = 0,    -- and seconds more, before those bars
  velocity = 100,          -- for notes entered by hand
  note_grid = 0.25,        -- piano roll step and snap, in beats
  note_snap = true,        -- the pointer's notes land on the piano roll's grid
  note_zoom = 8,           -- piano roll columns per beat
  message_time = 4000,     -- ms a message stays on the command line
  -- A sound file whose decoded audio is larger than this many megabytes is
  -- played from the disk instead of being held in memory; 0 holds every
  -- file in memory. And how many gigabytes of decoded sound are kept in the
  -- cache between runs, so that long files are decoded once.
  media_stream = 64,
  media_cache = 16,
  ffmpeg = "ffmpeg",       -- what renders to MP3, Ogg and Opus run: a name on the PATH, or a path
}
local values = {}

local opt = setmetatable({}, {
  __index = function(_, name)
    local v = values[name]
    if v == nil then return defaults[name] end
    return v
  end,
  __newindex = function(self, name, value)
    local old = self[name]
    values[name] = value
    if old ~= value then
      daw.emit("option.changed", { name = name, value = value, old = old })
      daw.api.ui_redraw()
    end
  end,
})

--- Give an option a default, for extensions that add options of their own.
function M.define(name, default)
  defaults[name] = default
end

--- Every option that has a default, by name: { name, default }.
function M.list()
  local out = {}
  for name, default in pairs(defaults) do out[#out + 1] = { name = name, default = default } end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

M.opt = opt
return M
