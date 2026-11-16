<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 9: Devices, parameters and plugins

*About ten minutes. In paw, with the tutor loaded: `:tutor 9`.*

Each track has a chain of devices: first an instrument, which turns notes into sound, then effects, each working on the sound of the one before. The device panel lists the chain of the track under the cursor, each device with its parameters, and is driven with the same kind of keys as everything else.

Built in are `synth`, `drums`, `gain`, `delay` and `limiter`. Installed CLAP, LV2 and VST3 plugins are devices too, and most have a window of their own.

## The idea

In the device panel `j` `k` choose a row (a device's name or one of its parameters), `h` `l` change a parameter a little and `H` `L` a lot, `a` adds a device, `x` removes one, `b` bypasses, `yy` `dd` `p` copy and move devices (to other tracks too), `<A-j>` `<A-k>` reorder, `e` or `<CR>` open a plugin's window. `,d` shows and hides the panel; `<C-w>c` closes it; `ge` in the arrange view opens the track's plugin window.

## If you know Vim

`<C-w>c` closes a panel as it closes a window in Vim. `yy` `dd` `p` work on devices as they work on lines.

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. The cursor is on Lead. Press `,d` (comma, then d) to show its device panel on the right; the keyboard goes there.
   - *Hint:* `,` is the leader key: it starts many two-key commands.
   - ✓ The panel: the synth's name, then a row per parameter.
2. `j` and `k` choose a row. Press `6j` to go down to `cutoff`, the brightness of the sound.
   - ✓ `cutoff` is chosen.
3. `l` raises the parameter a little and `L` a lot (`h` and `H` lower it). Press `L` three times.
   - ✓ Brighter. The bar and the number show the new value.
4. Listen while you change it: press `<Space>`, then `h` a few times to darken it, and `<Space>` to stop.
   - ✓ Parameters change while the song plays.
5. `a` adds a device after the instrument. Press `a`, type `delay` and press `<CR>`.
   - ✓ An echo after the synth.
6. Press `5j` to go down to the `Delay` heading.
   - *Hint:* Count the rows: Synth's heading, eight parameters, its Wet and Output, then Delay. `k` goes back up.
   - ✓ The delay is chosen.
7. `b` bypasses the chosen device: it stays in the chain but does nothing. Press `b`, then `b` again to switch it back on.
   - ✓ Bypassing is how you compare with and without an effect.
8. `e` opens a plugin's own window. Built-in devices have none, and the message line says so: press `e`.
   - ✓ With a plugin the window opens; `e` again closes it, and `ge` does the same from the arrange view.
9. If plugins are installed, `a` lists them with the built-in devices: press `a`, type part of a plugin's name, `<CR>`, then `e` to see its window. `:devices` lists everything.
   - *The tutor cannot check this step* (Which plugins are installed differs from one computer to the next, and a window needs a desktop); `,hn` goes on.
10. `<C-w>c` closes the panel and gives the keyboard back to the arrange view. Press `<C-w>c`.
   - ✓ Closed. `,d` brings it back.
11. Listen to the line through its echo: `<Space>`, and `<Space>` to stop.
   - ✓ A synth and a delay, set by ear.

## What you did

The device panel, choosing and changing parameters, adding and bypassing a device, and where plugins' windows open.

Previous: [Yank, paste, registers and macros](08-registers.md) · [All lessons](README.md) · Next: [Mixing: faders, pan, buses, sends, automation](10-mixing.md)
