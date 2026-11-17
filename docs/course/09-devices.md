<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 9: Devices, parameters and plugins

*About ten minutes. In paw, with the tutor loaded: `:tutor 9`.*

Each track has a chain of devices: first an instrument, which turns notes into sound, then effects, each working on the sound of the one before. The device panel lists the chain of the track under the cursor, each device with its parameters, and is driven with the same kind of keys as everything else.

Built in are `synth`, `drums`, `gain`, `delay` and `limiter`. Installed CLAP, LV2 and VST3 plugins are devices too, and most have a window of their own.

## The idea

In the device panel `j` `k` choose a row (a device's name or one of its parameters) and `w` `b` a device, `+` `-` change a parameter a step and a count first (`10+`) more, `a` adds a device, `x` removes one, `gc` bypasses, `yy` `dd` `p` copy and move devices (to other tracks too), `<A-j>` `<A-k>` reorder, `ge` opens a plugin's window. `,d` shows and hides the panel; `<C-w>c` closes it; `ge` in the arrange view opens the track's plugin window.

## If you know Vim

`<C-w>c` closes a panel as it closes a window in Vim. `yy` `dd` `p` work on devices as they work on lines, and `+` `-` change a value as `<C-a>` `<C-x>` change a number. `gc` bypasses, as it comments a line out.

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. The cursor is on Lead. Press `,d` (comma, then d) to show its device panel on the right; the keyboard goes there.
   - *Hint:* `,` is the leader key: it starts many two-key commands.
   - ✓ The panel: the synth's name, then a row per parameter.
2. `j` and `k` choose a row. Press `6j` to go down to `cutoff`, the brightness of the sound.
   - ✓ `cutoff` is chosen.
3. `+` raises the parameter a step and `-` lowers it; a count first is how many steps. Press `10+` three times.
   - ✓ Brighter. The bar and the number show the new value.
4. Listen while you change it: press `<Space>`, then `-` a few times to darken it, and `<Space>` to stop.
   - ✓ Parameters change while the song plays.
5. `a` adds a device after the instrument. Press `a`, type `delay` and press `<CR>`.
   - ✓ An echo after the synth.
6. `w` goes to the next device, as it goes to the next word. Press `w` to go down to the `Delay` heading.
   - *Hint:* `b` goes back to the device before, `j` `k` a row at a time.
   - ✓ The delay is chosen.
7. `gcc` bypasses the chosen device: it stays in the chain but does nothing. Press `gcc`, then `gcc` again to switch it back on.
   - ✓ Bypassing is how you compare with and without an effect: `gc` is mute in every view.
8. `ge` opens a plugin's own window. Built-in devices have none, and the message line says so: press `ge`.
   - ✓ With a plugin the window opens; `ge` again closes it, here and in every view.
9. If plugins are installed, `a` lists them with the built-in devices: press `a`, type part of a plugin's name, `<CR>`, then `ge` to see its window. `:devices` lists everything.
   - *The tutor cannot check this step* (Which plugins are installed differs from one computer to the next, and a window needs a desktop); `,hn` goes on.
10. `<C-w>c` closes the panel and gives the keyboard back to the arrange view. Press `<C-w>c`.
   - ✓ Closed. `,d` brings it back.
11. Listen to the line through its echo: `<Space>`, and `<Space>` to stop.
   - ✓ A synth and a delay, set by ear.

## What you did

The device panel, choosing and changing parameters, adding and bypassing a device, and where plugins' windows open.

Previous: [Yank, paste, registers and macros](08-registers.md) · [All lessons](README.md) · Next: [Mixing: faders, pan, buses, sends, automation](10-mixing.md)
