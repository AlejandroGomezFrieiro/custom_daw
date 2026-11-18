# How to run the graphical window without a graphics card

This guide shows you how to start the graphical window without a graphics
card. Use it also when the driver of the card does not work. The
window then draws with Mesa's llvmpipe on the processor.

1. Make sure that Mesa is installed. On NixOS, set
   `hardware.graphics.enable = true`.
2. Start the window with the software renderer:

   ```sh
   paw-gui --renderer software song.json
   ```

3. To use the software renderer each time, set the variable in your shell
   profile:

   ```sh
   export PAW_GUI_RENDERER=software
   ```

If the window shows one line about OpenGL and stops, OpenGL cannot start
at all. Then use the terminal (`paw song.json`), which has the same views.

At rest, the window uses no processor time. While the song plays, expect
about one core for llvmpipe. See [Drawing](../reference/window.md#drawing)
for the measured values.
