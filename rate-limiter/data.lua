local types = require("scripts.types")

local filters = {}
for _, name in ipairs(types.LIST) do filters[#filters + 1] = name end
filters[#filters + 1] = "entity-ghost"

local ICON = "__rate-limiter__/graphics/icons/rate-limiter.png"
local TOOL_ICON = "__rate-limiter__/graphics/icons/selection-tool.png"

data:extend({
  {
    type = "sprite",
    name = "rl-alt-icon",
    filename = "__rate-limiter__/graphics/icons/alt-icon.png",
    size = 64,
    flags = { "gui-icon" },
  },
  {
    type = "selection-tool",
    name = "rl-selection-tool",
    icon = TOOL_ICON,
    icon_size = 64,
    flags = { "only-in-cursor", "not-stackable", "spawnable" },
    hidden = true,
    stack_size = 1,
    draw_label_for_cursor_render = false,
    select = {
      border_color = { 1, 0.7, 0.15 },
      cursor_box_type = "entity",
      mode = { "any-entity", "same-force" },
      entity_type_filters = filters,
    },
    alt_select = {
      border_color = { 0.3, 0.8, 1 },
      cursor_box_type = "entity",
      mode = { "any-entity", "same-force" },
      entity_type_filters = filters,
    },
  },
  {
    type = "custom-input",
    name = "rl-get-tool",
    key_sequence = "CONTROL + ALT + R",
    consuming = "game-only",
    action = "lua",
    order = "a",
  },
  {
    type = "shortcut",
    name = "rl-shortcut",
    action = "lua",
    associated_control_input = "rl-get-tool",
    icon = ICON,
    icon_size = 64,
    small_icon = ICON,
    small_icon_size = 64,
    order = "r[rate-limiter]",
  },
})
