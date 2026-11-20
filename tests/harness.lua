-- Minimal Factorio runtime stubs to exercise the mod's logic outside the game.
-- The mod sources live in ../rate-limiter relative to this file.
local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
package.path = here .. "../rate-limiter/?.lua;" .. package.path

-------------------------------------------------------------------------------
-- defines
-------------------------------------------------------------------------------
local function enum(list)
  local t = {}
  for _, n in ipairs(list) do t[n] = n end
  return t
end

defines = {
  events = enum({
    "on_tick", "on_built_entity", "on_robot_built_entity", "on_space_platform_built_entity",
    "script_raised_built", "script_raised_revive", "on_player_mined_entity", "on_robot_mined_entity",
    "on_space_platform_mined_entity", "script_raised_destroy", "on_entity_died", "on_post_entity_died",
    "on_object_destroyed", "on_entity_settings_pasted", "on_entity_cloned", "on_player_setup_blueprint",
    "on_gui_opened", "on_gui_closed", "on_player_fast_transferred", "on_gui_value_changed",
    "on_gui_text_changed", "on_gui_confirmed", "on_gui_click", "on_gui_checked_state_changed",
    "on_gui_elem_changed", "on_player_selected_area", "on_player_alt_selected_area", "on_lua_shortcut",
    "on_runtime_mod_setting_changed", "on_gui_selection_state_changed",
  }),
  gui_type = enum({ "entity", "custom" }),
  relative_gui_type = enum({
    "assembling_machine_gui", "assembling_machine_select_recipe_gui", "furnace_gui", "rocket_silo_gui",
    "mining_drill_gui", "lab_gui", "agriculture_tower_gui", "boiler_gui", "entity_with_energy_source_gui",
    "reactor_gui", "pump_gui", "asteroid_collector_gui",
  }),
  relative_gui_position = enum({ "top", "bottom", "left", "right" }),
  wire_connector_id = { circuit_red = 1, circuit_green = 2, pole_copper = 5 },
  entity_status_diode = enum({ "green", "red", "yellow" }),
  target_type = enum({ "entity" }),
}

-------------------------------------------------------------------------------
-- script, commands, settings
-------------------------------------------------------------------------------
handlers = {}
nth_handlers = {}
filters_of = {}
commands_list = {}
registered_destroy = {}

script = {
  on_init = function(f) handlers.init = f end,
  on_load = function(f) handlers.load = f end,
  on_configuration_changed = function(f) handlers.config = f end,
  on_event = function(id, f, filters) handlers[id] = f; filters_of[id] = filters end,
  on_nth_tick = function(n, f) nth_handlers[n] = f end,
  register_on_object_destroyed = function(ent) registered_destroy[ent.unit_number] = true; return ent.unit_number end,
}
commands = { add_command = function(name, help, f) commands_list[name] = f end }

settings = {
  global = {
    ["rl-duty-cycle-ticks"] = { value = 60 },
    ["rl-refresh-ticks"] = { value = 120 },
    ["rl-circuit-ticks"] = { value = 30 },
    ["rl-alt-labels"] = { value = true },
  },
}

storage = {}
log = function() end

prototypes = {
  item = {
    coal = { name = "coal", fuel_value = 4e6, localised_name = { "item-name.coal" } },
    ["iron-ore"] = { name = "iron-ore", localised_name = { "item-name.iron-ore" } },
    ["iron-plate"] = { name = "iron-plate", localised_name = { "item-name.iron-plate" } },
  },
  fluid = {
    water = { name = "water", default_temperature = 15, heat_capacity = 200 },
    steam = { name = "steam", default_temperature = 15, heat_capacity = 200 },
  },
  recipe = {},
  airborne_pollutant = { pollution = { localised_name = { "airborne-pollutant-name.pollution" } } },
}

-------------------------------------------------------------------------------
-- rendering
-------------------------------------------------------------------------------
render_alive = 0
rendering = {}
local function render_obj(spec)
  render_alive = render_alive + 1
  local o = { valid = true, spec = spec }
  o.destroy = function()
    if o.valid then o.valid = false; render_alive = render_alive - 1 end
  end
  return o
end
rendering.draw_sprite = render_obj
rendering.draw_text = render_obj

-------------------------------------------------------------------------------
-- GUI elements
-------------------------------------------------------------------------------
local Element = {}
local function new_element(spec, parent)
  local el = { _children = {}, _fields = {}, parent = parent, valid = true, style = {} }
  for k, v in pairs(spec) do el._fields[k] = v end
  el._fields.name = spec.name or ""
  if spec.type == "slider" then el._fields.slider_value = spec.value or 0 end
  if spec.type == "choose-elem-button" then el._fields.elem_value = spec.signal end
  if spec.type == "checkbox" then el._fields.state = spec.state or false end
  if spec.type == "textfield" then el._fields.text = spec.text or "" end
  if el._fields.visible == nil then el._fields.visible = true end
  return setmetatable(el, Element)
end

Element.__index = function(t, k)
  local f = rawget(t, "_fields")
  if f[k] ~= nil then return f[k] end
  if k == "add" then
    return function(spec)
      local child = new_element(spec, t)
      table.insert(t._children, child)
      return child
    end
  elseif k == "destroy" then
    return function()
      t.valid = false
      local p = rawget(t, "parent")
      if p then
        for i, c in ipairs(p._children) do if c == t then table.remove(p._children, i) break end end
      end
    end
  elseif k == "children" then
    local list = {}
    for i, c in ipairs(t._children) do list[i] = c end
    return list
  elseif k == "clear" then
    return function()
      for _, c in ipairs(t._children) do c.valid = false end
      t._children = {}
    end
  elseif k == "force_auto_center" then
    return function() end
  end
  for _, c in ipairs(t._children) do
    if c._fields.name == k and k ~= "" then return c end
  end
  return nil
end
Element.__newindex = function(t, k, v) t._fields[k] = v end

function find_element(root, name)
  if root._fields.name == name then return root end
  for _, c in ipairs(root._children) do
    local r = find_element(c, name)
    if r then return r end
  end
  return nil
end

-------------------------------------------------------------------------------
-- Entities
-------------------------------------------------------------------------------
local next_unit = 1
entities = {}

local Entity = {}
local CLAMP = -0.8
local function clamp(v) if v < CLAMP then return CLAMP end return v end

Entity.__index = function(t, k)
  local f = rawget(t, "_f")
  if k == "effects" then
    if not rawget(t, "_effect_receiver") then return nil end
    local L = f.local_effect or {}
    local ls, lc = L.speed or 0, L.consumption or 0
    if rawget(t, "_ignore_local") then ls, lc = 0, 0 end
    local res = rawget(t, "_resolution")
    if res then ls = math.floor(ls / res) * res; lc = math.floor(lc / res) * res end
    return { speed = clamp(t._nat_speed + ls), consumption = clamp(t._nat_cons + lc), productivity = 0 }
  elseif k == "local_effect" then
    if not rawget(t, "_effect_receiver") then error("no effect receiver") end
    return f.local_effect
  elseif k == "tags" then
    if f.type ~= "entity-ghost" then error("tags only on ghosts") end
    return f.tags
  elseif k == "get_circuit_network" then
    return function(wid)
      local nets = rawget(t, "_nets")
      return nets and nets[wid] or nil
    end
  elseif k == "get_wire_connectors" then
    return function()
      if not rawget(t, "_wires") then return {} end
      return { [1] = {}, [2] = {} }
    end
  end
  return f[k]
end

Entity.__newindex = function(t, k, v)
  local f = rawget(t, "_f")
  if k == "local_effect" then
    if not rawget(t, "_effect_receiver") then error("no effect receiver") end
    f.local_effect = v
  elseif k == "disabled_by_script" then
    if rawget(t, "_no_duty") then return end
    f.disabled_by_script = v
  elseif k == "tags" then
    if f.type ~= "entity-ghost" then error("tags only on ghosts") end
    f.tags = v
  else
    f[k] = v
  end
end

local effect_types = { ["assembling-machine"] = true, furnace = true, ["mining-drill"] = true, lab = true, ["rocket-silo"] = true, ["agricultural-tower"] = true }

surface1 = { index = 1, name = "nauvis" }
force1 = { name = "player", index = 1 }

function make_entity(o)
  local unit = next_unit
  next_unit = next_unit + 1
  local proto = {
    name = o.name, type = o.type, hidden = false,
    selection_box = { left_top = { x = -1.5, y = -1.5 }, right_bottom = { x = 1.5, y = 1.5 } },
    has_flag = function() return false end,
    get_max_circuit_wire_distance = function() return o.wires and 9 or 0 end,
  }
  for k, v in pairs(o.proto or {}) do proto[k] = v end
  local f = {
    valid = true, unit_number = unit, name = o.name, type = o.type,
    position = o.position or { x = unit * 10 + 0.5, y = 0.5 },
    surface = surface1, force = force1, prototype = proto,
    disabled_by_script = false,
    productivity_bonus = o.productivity or 0,
    mining_target = o.mining_target,
    get_recipe = function() return o.recipe end,
  }
  if o.ghost_type then
    f.type = "entity-ghost"
    f.name = "entity-ghost"
    f.ghost_type = o.ghost_type
    f.ghost_name = o.name
    f.ghost_prototype = proto
    f.tags = o.tags
  end
  local ent = setmetatable({
    _f = f,
    _effect_receiver = effect_types[o.ghost_type or o.type] or false,
    _nat_speed = o.nat_speed or 0,
    _nat_cons = o.nat_cons or 0,
    _ignore_local = o.ignore_local or false,
    _no_duty = o.no_duty or false,
    _wires = o.wires or false,
    _nets = o.nets,
  }, Entity)
  entities[unit] = ent
  return ent
end

function destroy_entity(ent)
  rawget(ent, "_f").valid = false
end

-------------------------------------------------------------------------------
-- Players and game
-------------------------------------------------------------------------------
local function root(name) return new_element({ type = "root", name = name }, nil) end

flying = {}
function make_player(index)
  local p = {
    index = index, admin = true, opened = nil, selected = nil,
    gui = { relative = root("relative"), screen = root("screen") },
    printed = {},
  }
  p.print = function(msg) table.insert(p.printed, msg) end
  p.create_local_flying_text = function(spec) table.insert(flying, spec) end
  p.cursor_stack = { valid_for_read = false, set_stack = function(s) p.cursor_stack.valid_for_read = true; p.cursor_stack.name = s.name; return true end }
  p.clear_cursor = function() p.cursor_stack.valid_for_read = false; p.cursor_stack.name = nil; return true end
  game.players[index] = p
  return p
end

game = {
  tick = 0,
  players = {},
  get_player = function(i) return game.players[i] end,
  print = function() end,
}

-- run the on_tick handler for n ticks; calls f(tick) after each tick if given
function run_ticks(n, f)
  for _ = 1, n do
    game.tick = game.tick + 1
    handlers.on_tick({ tick = game.tick })
    if f then f(game.tick) end
  end
end
