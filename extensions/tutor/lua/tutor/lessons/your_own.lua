-- Lesson 15: options, mappings and commands of your own, and init.lua.
return {
  id = "your-own",
  title = "Making it your own: options, keys, commands",
  intro = [[
Every key you have used is an ordinary mapping, and every command an ordinary
Lua function, defined with the same calls you can use yourself. Your own file,
`~/.config/paw/init.lua`, runs at startup: options, mappings and commands put
there are yours every time.

In this lesson you try each one live with `:lua`, which runs one line of Lua,
and then copy what you like into `init.lua`. What you set here lasts until you
quit, except the grid, which the tutor puts back when you leave it.]],
  idea = [[
`paw.opt.name = value` sets an option (`:lua paw.opt.grid = 0.5`; `,fo` lists
them). `paw.keymap.set(keys, command or function, { desc = ..., view = ... })`
maps keys; `<leader>` stands for the leader (`,`), `<localleader>` for the leader of one view's own keys (a backslash). `paw.command(name, function(ctx)
... end, { desc = ... })` defines a command, which `:name` then runs and a
mapping can name. `:reload` runs `init.lua` again without touching the project.]],
  vim = [[
This is Neovim's `init.lua` with `paw.opt`, `paw.keymap.set` and `paw.command`
in place of `vim.opt`, `vim.keymap.set` and `vim.api.nvim_create_user_command`.
`:lua` is the same. Any built-in module can be replaced by a file of the same
name in `~/.config/paw/lua/`.]],
  setup = function(look)
    paw.project.tempo = 100
    local drums = paw.add_track({ name = "Drums", volume = -6 })
    drums:add_device("drums")
    drums:add_clip({ name = "beat", start = 0, length = 8, notes = look.drums(look.beat, 2) })
    local keys = paw.add_track({ name = "Keys", volume = -8 })
    keys:add_device("synth", { wave = 3, attack = 0.02, release = 0.4, cutoff = 1800 })
    keys:add_clip({ name = "chords", start = 0, length = 8, notes = look.chord({ "E4", "G4", "B4" }, 8) })
    paw.transport.loop_start, paw.transport.loop_end, paw.transport.loop_enabled = 0, 8, true
  end,
  at = function() paw.cursor.set_track(paw.track("Drums")) end,
  steps = {
    {
      say = "An option: type `:lua paw.opt.grid = 0.5` and `<CR>`, then press `l`: the cursor moves half a beat now.",
      keys = { ":lua paw.opt.grid = 0.5", "<CR>", "l" },
      check = function() return paw.opt.grid == 0.5 and paw.cursor.beat == 0.5 end,
      done = "The grid is half a beat; the status line shows `grid 0.5`. `]g` and `[g` change it too.",
      hint = "Type it exactly, spaces included; `<Up>` on the command line brings back what you typed before.",
    },
    {
      say = "A key of your own: type `:lua paw.keymap.set(\"<leader>z\", \"transport.metronome\", { desc = \"Click\" })` and `<CR>`, then press `,z`.",
      keys = { ":lua paw.keymap.set(\"<leader>z\", \"transport.metronome\", { desc = \"Click\" })", "<CR>", ",z" },
      check = function() return paw.transport.metronome end,
      done = "`,z` switches the click: your mapping, listed by `?` with its description.",
    },
    {
      say = "A command of your own: type `:lua paw.command(\"hello\", function() paw.notify(\"hello from my command\") end)` and `<CR>`, then `:hello` and `<CR>`.",
      keys = { ":lua paw.command(\"hello\", function() paw.notify(\"hello from my command\") end)", "<CR>", ":hello", "<CR>" },
      check = function(ctx, look) return look.said(ctx, "hello from my command") end,
      done = "Your command ran. It is in `:commands` and the `,,` picker now, like the built-in ones.",
    },
    {
      say = "To keep them, open `~/.config/paw/init.lua` in your text editor, add the same three lines without `:lua`, save, and type `:reload` here.",
      keys = {},
      unchecked = "The tutor does not read or write your configuration.",
      done = "Done.",
      hint = "In init.lua each line is plain Lua: `paw.opt.grid = 0.5` and so on. `:extensions` and `:messages` show errors if something is wrong.",
    },
    {
      say = "Listen with your click: `<Space>`, `<Space>` to stop, and `,z` to switch the click off.",
      keys = { "<Space>", { wait = 300 }, "<Space>", ",z" },
      check = function(ctx, look) return look.played(ctx) and not paw.transport.metronome end,
      done = "Your own key, at work.",
    },
  },
  outro = "An option, a mapping and a command, made live with `:lua`, and where to keep them.",
}
