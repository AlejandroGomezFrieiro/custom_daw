-- The line of keys at the bottom of the screen: the few keys worth knowing
-- first, for the view and the mode you are in. `?` lists them all.
--
-- An extension adds a line for its own view:
--   daw.ui.keybar.set("myview", "n", { { "<CR>", "open" }, { "x", "delete" } })
-- Each entry is a key as mappings write it and a word or two for what it
-- does; a third value replaces how the key is shown.
local M = { lines = {} }

--- Set the keys shown for a view in a mode ("n", "x", "i").
function M.set(view, mode, entries)
  M.lines[view] = M.lines[view] or {}
  M.lines[view][mode] = entries
  daw.api.ui_redraw()
end

local names = { ["<Space>"] = "Space", ["<CR>"] = "Enter", ["<Esc>"] = "Esc", ["<BS>"] = "Bksp", ["<Tab>"] = "Tab", ["<lt>"] = "<" }

--- A key as a person reads it: `<leader>m` is `,m`, `<C-w>c` is `Ctrl-w c`.
function M.show(lhs)
  local out = lhs:gsub("<leader>", function() return daw.opt.leader end)
  out = out:gsub("<C%-(.)>(.*)", "Ctrl-%1 %2"):gsub("%s+$", "")
  return names[out] or out
end

--- The entries for what has the keyboard now, as `{ shown key, text }`.
function M.entries()
  local view = daw.ui.focused
  local mode = daw.keymap.mode
  local lines = M.lines[view]
  -- A view that takes every key itself has none of the usual ones.
  local modal = daw.ui.views[view] and daw.ui.views[view].modal
  if modal and not lines then return {} end
  local entries = lines and (lines[mode] or mode ~= "n" and {} or nil) or mode == "n" and M.lines.default.n or {}
  local out = {}
  for i, entry in ipairs(entries or {}) do out[i] = { entry[3] or M.show(entry[1]), entry[2] } end
  return out
end

--- The keys shown that nothing is mapped to, as `view mode key` strings:
--- empty when every line tells the truth.
function M.check()
  local wrong = {}
  for view, modes in pairs(M.lines) do
    for mode, entries in pairs(modes) do
      local mapped = {}
      for _, map in ipairs(daw.keymap.list(mode, view ~= "default" and view or nil)) do mapped[map.lhs] = true end
      for _, entry in ipairs(entries) do
        -- Leaving a mode with Escape is not a mapping: it always works.
        local built_in = entry[1] == "<Esc>" and mode ~= "n"
        if not mapped[entry[1]] and not built_in then wrong[#wrong + 1] = view .. " " .. mode .. " " .. entry[1] end
      end
    end
  end
  table.sort(wrong)
  return wrong
end

M.lines.default = {
  n = { { "<Tab>", "next panel" }, { "<leader><leader>", "commands" }, { "?", "keys" } },
}
M.lines.arrange = {
  n = {
    { "<Space>", "play" }, { "o", "track" }, { "a", "device" }, { "i", "notes" }, { "<CR>", "open clip" },
    { "x", "delete" }, { "u", "undo" }, { "<leader>m", "mixer" }, { "<leader><leader>", "commands" }, { "?", "keys" },
  },
  x = { { "d", "delete" }, { "y", "copy" }, { ">", "later" }, { "<lt>", "earlier" }, { "gl", "loop" }, { "<Esc>", "done" } },
}
M.lines.pianoroll = {
  n = {
    { "<CR>", "note" }, { "i", "type notes" }, { "x", "delete" }, { "+", "longer" }, { "-", "shorter" },
    { "w", "next note" }, { "<Space>", "play" }, { "<Esc>", "back" }, { "?", "keys" },
  },
  x = { { "d", "delete" }, { "y", "copy" }, { ">", "later" }, { "<lt>", "earlier" }, { "<C-a>", "up" }, { "<Esc>", "done" } },
  i = {
    { "a", "notes, w e t y u between", "a s d f g h j k" }, { "<Space>", "rest" }, { "<BS>", "back" },
    { "z", "octave down" }, { "x", "octave up" }, { "<Esc>", "done" },
  },
}
M.lines.mixer = {
  n = {
    { "l", "next" }, { "h", "previous" }, { "k", "louder" }, { "j", "quieter" }, { ">", "pan right" }, { "<lt>", "pan left" },
    { "M", "mute" }, { "s", "solo" }, { "r", "arm" }, { "<C-w>c", "close" },
  },
}
M.lines.session = {
  n = {
    { "<CR>", "launch" }, { "L", "scene" }, { "s", "stop" }, { "b", "timeline" }, { "n", "new clip" },
    { "e", "notes" }, { "m", "mode" }, { "<Space>", "play" }, { "?", "keys" },
  },
}
M.lines.devices = {
  n = {
    { "j", "next" }, { "l", "raise" }, { "h", "lower" }, { "a", "add" }, { "b", "bypass" }, { "e", "window" },
    { "x", "remove" }, { "<C-w>c", "close" },
  },
}

return M
