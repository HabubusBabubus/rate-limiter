-- Which entities can be limited, how, and which entity windows the panel attaches to.
local T = {}

-- Effect receivers: slowed smoothly through LuaEntity::local_effect (speed and consumption),
-- with pulses added only below the game's -80% effect limit.
T.EFFECT_TYPES = {
  ["assembling-machine"] = true,
  ["furnace"] = true,
  ["rocket-silo"] = true,
  ["mining-drill"] = true,
  ["lab"] = true,
  ["agricultural-tower"] = true,
}

-- Everything else that produces something: slowed by pulses (on part of the time).
T.DUTY_TYPES = {
  ["boiler"] = true,
  ["generator"] = true,
  ["burner-generator"] = true,
  ["reactor"] = true,
  ["solar-panel"] = true,
  ["offshore-pump"] = true,
  -- Space Age
  ["fusion-reactor"] = true,
  ["fusion-generator"] = true,
  ["asteroid-collector"] = true,
}

T.ALL = {}
T.LIST = {}
for name in pairs(T.EFFECT_TYPES) do T.ALL[name] = true end
for name in pairs(T.DUTY_TYPES) do T.ALL[name] = true end
for name in pairs(T.ALL) do T.LIST[#T.LIST + 1] = name end
table.sort(T.LIST)

-- defines.relative_gui_type names, per entity type. The panel is anchored with a filter on the
-- entity name, so a candidate that does not match the opened window simply stays hidden.
T.GUI = {
  ["assembling-machine"] = { "assembling_machine_gui", "assembling_machine_select_recipe_gui" },
  ["furnace"] = { "furnace_gui" },
  ["rocket-silo"] = { "rocket_silo_gui" },
  ["mining-drill"] = { "mining_drill_gui" },
  ["lab"] = { "lab_gui" },
  ["agricultural-tower"] = { "agriculture_tower_gui" },
  ["boiler"] = { "boiler_gui" },
  ["generator"] = { "entity_with_energy_source_gui" },
  ["burner-generator"] = { "entity_with_energy_source_gui" },
  ["reactor"] = { "reactor_gui" },
  ["solar-panel"] = { "entity_with_energy_source_gui" },
  ["offshore-pump"] = { "pump_gui" },
  ["fusion-reactor"] = { "reactor_gui", "entity_with_energy_source_gui" },
  ["fusion-generator"] = { "entity_with_energy_source_gui" },
  ["asteroid-collector"] = { "asteroid_collector_gui" },
}

function T.is_ghost(entity)
  return entity.type == "entity-ghost"
end

function T.real_type(entity)
  if entity.type == "entity-ghost" then return entity.ghost_type end
  return entity.type
end

function T.real_name(entity)
  if entity.type == "entity-ghost" then return entity.ghost_name end
  return entity.name
end

function T.is_supported(entity)
  return entity ~= nil and entity.valid and T.ALL[T.real_type(entity)] == true
end

-- Event filters for build events: every supported type and every ghost.
function T.build_filters()
  local f = {}
  for _, name in ipairs(T.LIST) do f[#f + 1] = { filter = "type", type = name } end
  f[#f + 1] = { filter = "ghost" }
  return f
end

function T.remove_filters()
  local f = {}
  for _, name in ipairs(T.LIST) do f[#f + 1] = { filter = "type", type = name } end
  return f
end

return T
