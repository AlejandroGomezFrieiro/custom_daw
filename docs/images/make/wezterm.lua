-- The terminal the pictures are taken in: WezTerm as its author uses it
-- (FiraCode Nerd Font, Catppuccin Mocha), without a tab bar or padding.
local wezterm = require 'wezterm'
local config = wezterm.config_builder()
config.color_scheme = 'Catppuccin Mocha'
config.font = wezterm.font('FiraCode Nerd Font')
config.font_size = 12.0
config.front_end = 'Software'
config.enable_tab_bar = false
config.window_padding = { left = 0, right = 0, top = 0, bottom = 0 }
config.check_for_updates = false
config.audible_bell = 'Disabled'
config.window_close_confirmation = 'NeverPrompt'
return config
