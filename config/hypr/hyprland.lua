-- CachyOS Hyprland Configuration

require("config.animations")
require("config.autostart")
require("config.colors")
require("config.decorations")
require("config.variables")
require("config.environment")
require("config.inputs")
require("config.binds")
require("config.misc")
require("config.monitors")
require("config.windowrules")
require("config.autopip")
require("config.workspaces")

-- HyprMod managed settings
require("hyprland-gui")

-- For Noctalia Color templates
require("noctalia").apply_theme()
