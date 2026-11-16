-- A one-file extension that adds a view: the transport position in big digits.
-- `,c` shows and hides it.
local glyphs = {
  ["0"] = { "█▀█", "█ █", "▀▀▀" }, ["1"] = { " █ ", " █ ", " ▀ " }, ["2"] = { "▀▀█", "█▀▀", "▀▀▀" },
  ["3"] = { "▀▀█", " ▀█", "▀▀▀" }, ["4"] = { "█ █", "▀▀█", "  ▀" }, ["5"] = { "█▀▀", "▀▀█", "▀▀▀" },
  ["6"] = { "█▀▀", "█▀█", "▀▀▀" }, ["7"] = { "▀▀█", "  █", "  ▀" }, ["8"] = { "█▀█", "█▀█", "▀▀▀" },
  ["9"] = { "█▀█", "▀▀█", "▀▀▀" }, ["."] = { " ", " ", "▀" },
}

daw.ui.hl("ClockDigits", { fg = "#ff9e64", bold = true })
daw.ui.hl("ClockPlaying", { fg = "#9ece6a", bold = true })

daw.ui.view("clock", {
  focusable = false,
  render = function(_, buf)
    local transport = daw.transport.get()
    local text = daw.time.format(transport.position)
    local x = 2
    for ch in text:gmatch(".") do
      local glyph = glyphs[ch]
      for row, line in ipairs(glyph) do
        buf:text(x, row - 1, line, transport.playing and "ClockPlaying" or "ClockDigits")
      end
      x = x + daw.api.str_width(glyph[1]) + 1
    end
    buf:text(x + 2, 1, string.format("%g bpm", daw.project.tempo), "Dim")
  end,
})

daw.ui.dock("clock", { side = "top", size = 3 })
daw.command("clock", function() daw.ui.toggle("clock") end, { desc = "Show or hide the big clock" })
daw.keymap.set("<leader>c", "clock", { desc = "Show or hide the big clock" })
