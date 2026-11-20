data:extend({
  {
    type = "int-setting", name = "rl-duty-cycle-ticks", setting_type = "runtime-global",
    default_value = 60, minimum_value = 2, maximum_value = 600, order = "a",
  },
  {
    type = "int-setting", name = "rl-refresh-ticks", setting_type = "runtime-global",
    default_value = 120, minimum_value = 10, maximum_value = 3600, order = "b",
  },
  {
    type = "int-setting", name = "rl-circuit-ticks", setting_type = "runtime-global",
    default_value = 30, minimum_value = 1, maximum_value = 600, order = "c",
  },
  {
    type = "bool-setting", name = "rl-alt-labels", setting_type = "runtime-global",
    default_value = true, order = "d",
  },
})
