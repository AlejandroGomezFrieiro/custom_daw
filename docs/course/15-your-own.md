<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 15: Making it your own: options, keys, commands

*About ten minutes. In paw, with the tutor loaded: `:tutor 15`.*

Every key you have used is an ordinary mapping, and every command an ordinary Lua function, defined with the same calls you can use yourself. Your own file, `~/.config/daw/init.lua`, runs at startup: options, mappings and commands put there are yours every time.

In this lesson you try each one live with `:lua`, which runs one line of Lua, and then copy what you like into `init.lua`. What you set here lasts until you quit, except the grid, which the tutor puts back when you leave it.

## The idea

`daw.opt.name = value` sets an option (`:lua daw.opt.grid = 0.5`; `,fo` lists them). `daw.keymap.set(keys, command or function, { desc = ..., view = ... })` maps keys; `<leader>` stands for the leader (`,`). `daw.command(name, function(ctx) ... end, { desc = ... })` defines a command, which `:name` then runs and a mapping can name. `:reload` runs `init.lua` again without touching the project.

## If you know Vim

This is Neovim's `init.lua` with `daw.opt`, `daw.keymap.set` and `daw.command` in place of `vim.opt`, `vim.keymap.set` and `vim.api.nvim_create_user_command`. `:lua` is the same. Any built-in module can be replaced by a file of the same name in `~/.config/daw/lua/`.

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. An option: type `:lua daw.opt.grid = 0.5` and `<CR>`, then press `l`: the cursor moves half a beat now.
   - *Hint:* Type it exactly, spaces included; `<Up>` on the command line brings back what you typed before.
   - ✓ The grid is half a beat; the status line shows `grid 0.5`. `]g` and `[g` change it too.
2. A key of your own: type `:lua daw.keymap.set("<leader>z", "transport.metronome", { desc = "Click" })` and `<CR>`, then press `,z`.
   - ✓ `,z` switches the click: your mapping, listed by `?` with its description.
3. A command of your own: type `:lua daw.command("hello", function() daw.notify("hello from my command") end)` and `<CR>`, then `:hello` and `<CR>`.
   - ✓ Your command ran. It is in `:commands` and the `,,` picker now, like the built-in ones.
4. To keep them, open `~/.config/daw/init.lua` in your text editor, add the same three lines without `:lua`, save, and type `:reload` here.
   - *Hint:* In init.lua each line is plain Lua: `daw.opt.grid = 0.5` and so on. `:extensions` and `:messages` show errors if something is wrong.
   - *The tutor cannot check this step* (The tutor does not read or write your configuration); `,hn` goes on.
5. Listen with your click: `<Space>`, `<Space>` to stop, and `,z` to switch the click off.
   - ✓ Your own key, at work.

## What you did

An option, a mapping and a command, made live with `:lua`, and where to keep them.

Previous: [Finding any command or key](14-finding.md) · [All lessons](README.md) · Next: [The bundled extensions](16-extensions.md)
