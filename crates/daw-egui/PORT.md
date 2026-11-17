# Moving the window from Slint to egui

A working note while the port is under way; it goes when the port is done.

The new window grows in `crates/daw-egui` (binary `daw-egui`) beside the
Slint one, which stays the default `daw-gui` until the new one does
everything docs/window.md says. Then `crates/daw-gui` is replaced by it.

Order:

1. eframe app (glow) showing the state the kernel pushes: transport,
   status line, panes, the arrange view with its gestures. Menus are the
   kernel's (`daw.frontend.menu`, runtime/lua/daw/window_menus.lua, built on
   the terminal's `daw.mouse_menus`). Frames only when something changed.
2. Device panel, mixer, piano roll with its strip and side panel.
3. Session view, views in windows of their own, painted and cell panes,
   the roll's own window, portal dialogs, drops, connect.
4. Tests: egui_kittest in-process for the gestures (a stand-in kernel that
   records calls), the window tests on Xvfb for end to end.
5. Swap: `crates/daw-gui` becomes this crate; Slint, build.rs, ui/*.slint,
   the flake's Slint bits and the README badge go.
6. Docs (window.md, architecture.md, README), pictures.
