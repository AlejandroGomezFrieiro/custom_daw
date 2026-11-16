-- Lesson 9: instruments, effects, parameters, plugins and their windows.
local function selected()
  local device, row = daw.ui.views.devices:selected()
  return device, row
end

return {
  id = "devices",
  title = "Devices, parameters and plugins",
  intro = [[
Each track has a chain of devices: first an instrument, which turns notes into
sound, then effects, each working on the sound of the one before. The device
panel lists the chain of the track under the cursor, each device with its
parameters, and is driven with the same kind of keys as everything else.

Built in are `synth`, `drums`, `gain`, `delay` and `limiter`. Installed CLAP,
LV2 and VST3 plugins are devices too, and most have a window of their own.]],
  idea = [[
In the device panel `j` `k` choose a row (a device's name or one of its
parameters), `h` `l` change a parameter a little and `H` `L` a lot, `a` adds a
device, `x` removes one, `b` bypasses, `yy` `dd` `p` copy and move devices (to
other tracks too), `<A-j>` `<A-k>` reorder, `e` or `<CR>` open a plugin's window.
`,d` shows and hides the panel; `<C-w>c` closes it; `ge` in the arrange view
opens the track's plugin window.]],
  vim = [[
`<C-w>c` closes a panel as it closes a window in Vim. `yy` `dd` `p` work on
devices as they work on lines.]],
  setup = function(look)
    daw.project.tempo = 96
    local drums = daw.add_track({ name = "Drums", volume = -6 })
    drums:add_device("drums")
    drums:add_clip({ name = "beat", start = 0, length = 8, notes = look.drums(look.beat, 2) })
    local lead = daw.add_track({ name = "Lead", volume = -6 })
    lead:add_device("synth", { wave = 1, cutoff = 900, resonance = 0.3, release = 0.15 })
    lead:add_clip({ name = "line", start = 0, length = 8, notes = look.notes("D4:0:0.5 F4:0.5:0.5 A4:1:1 G4:2:0.5 F4:2.5:0.5 D4:3:1 C4:4:1 D4:5:3") })
    daw.transport.loop_start, daw.transport.loop_end, daw.transport.loop_enabled = 0, 8, true
  end,
  at = function() daw.cursor.set_track(daw.track("Lead")) end,
  steps = {
    {
      say = "The cursor is on Lead. Press `,d` (comma, then d) to show its device panel on the right; the keyboard goes there.",
      keys = { ",d" },
      check = function(_, look) return look.focused() == "devices" end,
      done = "The panel: the synth's name, then a row per parameter.",
      hint = "`,` is the leader key: it starts many two-key commands.",
    },
    {
      say = "`j` and `k` choose a row. Press `6j` to go down to `cutoff`, the brightness of the sound.",
      keys = { "6j" },
      check = function()
        local _, row = selected()
        return row and row.param and row.param.key == "cutoff"
      end,
      done = "`cutoff` is chosen.",
    },
    {
      say = "`l` raises the parameter a little and `L` a lot (`h` and `H` lower it). Press `L` three times.",
      keys = { "L", "L", "L" },
      start = function(ctx, look) ctx.cutoff = look.param(look.device("Lead", "synth"), "cutoff") end,
      check = function(ctx, look) 
        -- Each `L` is a tenth of the range, some 2000 Hz.
        return look.param(look.device("Lead", "synth"), "cutoff") > ctx.cutoff + 5000
      end,
      done = "Brighter. The bar and the number show the new value.",
    },
    {
      say = "Listen while you change it: press `<Space>`, then `h` a few times to darken it, and `<Space>` to stop.",
      keys = { "<Space>", { wait = 200 }, "h", "h", "h", { wait = 200 }, "<Space>" },
      start = function(ctx, look) ctx.cutoff = look.param(look.device("Lead", "synth"), "cutoff") end,
      check = function(ctx, look) return look.played(ctx) and look.param(look.device("Lead", "synth"), "cutoff") < ctx.cutoff end,
      done = "Parameters change while the song plays.",
    },
    {
      say = "`a` adds a device after the instrument. Press `a`, type `delay` and press `<CR>`.",
      keys = { "a", "delay", "<CR>" },
      check = function(_, look) return look.device("Lead", "delay") ~= nil end,
      done = "An echo after the synth.",
    },
    {
      say = "Press `5j` to go down to the `Delay` heading.",
      keys = { "5j" },
      check = function()
        local device, row = selected()
        return device and device.kind == "delay" and row and not row.param
      end,
      done = "The delay is chosen.",
      hint = "Count the rows: Synth's heading, eight parameters, its Wet and Output, then Delay. `k` goes back up.",
    },
    {
      say = "`b` bypasses the chosen device: it stays in the chain but does nothing. Press `b`, then `b` again to switch it back on.",
      keys = { "b", "b" },
      check = function(ctx, look)
        local _, n = look.ran(ctx, "device.bypass")
        return n >= 2 and not look.device("Lead", "delay").bypass
      end,
      done = "Bypassing is how you compare with and without an effect.",
    },
    {
      say = "`e` opens a plugin's own window. Built-in devices have none, and the message line says so: press `e`.",
      keys = { "e" },
      check = function(ctx, look) return look.said(ctx, "no device with an editor window") end,
      done = "With a plugin the window opens; `e` again closes it, and `ge` does the same from the arrange view.",
    },
    {
      say = "If plugins are installed, `a` lists them with the built-in devices: press `a`, type part of a plugin's name, `<CR>`, then `e` to see its window. `:devices` lists everything.",
      keys = {},
      unchecked = "Which plugins are installed differs from one computer to the next, and a window needs a desktop.",
      done = "Done.",
    },
    {
      say = "`<C-w>c` closes the panel and gives the keyboard back to the arrange view. Press `<C-w>c`.",
      keys = { "<C-w>c" },
      check = function(ctx, look) return look.became(ctx, "closed", not look.visible("devices") and look.focused() == "arrange") end,
      done = "Closed. `,d` brings it back.",
    },
    {
      say = "Listen to the line through its echo: `<Space>`, and `<Space>` to stop.",
      keys = { "<Space>", { wait = 300 }, "<Space>" },
      check = function(ctx, look) return look.played(ctx) end,
      done = "A synth and a delay, set by ear.",
    },
  },
  outro = "The device panel, choosing and changing parameters, adding and bypassing a device, and where plugins' windows open.",
}
