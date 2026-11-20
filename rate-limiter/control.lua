local types = require("scripts.types")
local L = require("scripts.limiter")
local P = require("scripts.persist")
local G = require("scripts.gui")
local render = require("scripts.render")

local TOOL = "rl-selection-tool"

L.on_changed = function(unit) G.refresh_unit(unit) end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------
script.on_init(function()
  L.init_storage()
end)

script.on_configuration_changed(function()
  L.init_storage()
  L.revalidate()
  for _, player in pairs(game.players) do
    G.close_entity(player)
    G.close_mass(player)
  end
end)

script.on_event(defines.events.on_tick, function(event)
  L.on_tick(event.tick)
end)

script.on_nth_tick(3600, function()
  P.cleanup_memory()
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting == "rl-alt-labels" then
    for _, e in pairs(storage.entries) do render.update_entry(e) end
    for unit, g in pairs(storage.ghosts) do
      if g.entity and g.entity.valid then render.update_ghost(g.entity, L.cfg_from_tags(g.entity.tags))
      else render.destroy_ghost(unit) end
    end
  end
end)

-------------------------------------------------------------------------------
-- Building, removing, copying
-------------------------------------------------------------------------------
local build_filters = types.build_filters()
script.on_event(defines.events.on_built_entity, P.on_built, build_filters)
script.on_event(defines.events.on_robot_built_entity, P.on_built, build_filters)
script.on_event(defines.events.on_space_platform_built_entity, P.on_built, build_filters)
script.on_event(defines.events.script_raised_built, P.on_built, build_filters)
script.on_event(defines.events.script_raised_revive, P.on_built, build_filters)

local remove_filters = types.remove_filters()
script.on_event(defines.events.on_player_mined_entity, P.on_mined, remove_filters)
script.on_event(defines.events.on_robot_mined_entity, P.on_mined, remove_filters)
script.on_event(defines.events.on_space_platform_mined_entity, P.on_mined, remove_filters)
script.on_event(defines.events.script_raised_destroy, P.on_mined, remove_filters)
script.on_event(defines.events.on_entity_died, P.on_died, remove_filters)
script.on_event(defines.events.on_post_entity_died, P.on_post_died)
script.on_event(defines.events.on_object_destroyed, P.on_destroyed)

script.on_event(defines.events.on_entity_settings_pasted, function(event)
  P.on_settings_pasted(event)
end)
script.on_event(defines.events.on_entity_cloned, P.on_cloned)
script.on_event(defines.events.on_player_setup_blueprint, P.on_setup_blueprint)

-------------------------------------------------------------------------------
-- GUI
-------------------------------------------------------------------------------
script.on_event(defines.events.on_gui_opened, function(event)
  if event.gui_type ~= defines.gui_type.entity then return end
  local player = game.get_player(event.player_index)
  local entity = event.entity
  if types.is_supported(entity) then
    G.open_entity(player, entity)
  else
    G.close_entity(player)
  end
end)

script.on_event(defines.events.on_gui_closed, function(event)
  local player = game.get_player(event.player_index)
  if event.gui_type == defines.gui_type.entity then
    local entity = event.entity
    G.close_entity(player)
    -- modules may have been changed while the window was open
    if entity and entity.valid then L.refresh_entity(entity) end
  elseif event.element then
    G.on_closed_element(event)
  end
end)

script.on_event(defines.events.on_player_fast_transferred, function(event)
  if event.entity and event.entity.valid then L.refresh_entity(event.entity) end
end)

script.on_event(defines.events.on_gui_value_changed, G.on_value_changed)
script.on_event(defines.events.on_gui_text_changed, G.on_text_changed)
script.on_event(defines.events.on_gui_confirmed, G.on_confirmed)
script.on_event(defines.events.on_gui_click, G.on_click)
script.on_event(defines.events.on_gui_checked_state_changed, G.on_checked)
script.on_event(defines.events.on_gui_elem_changed, G.on_elem_changed)
script.on_event(defines.events.on_gui_selection_state_changed, G.on_selection_changed)

-------------------------------------------------------------------------------
-- Selection tool
-------------------------------------------------------------------------------
local function selected_supported(entities)
  local list = {}
  for _, ent in pairs(entities or {}) do
    if types.is_supported(ent) then
      local proto = types.is_ghost(ent) and ent.ghost_prototype or ent.prototype
      local hidden = false
      pcall(function() hidden = proto.hidden or proto.has_flag("not-selectable-in-game") end)
      if not hidden then list[#list + 1] = ent end
    end
  end
  return list
end

script.on_event(defines.events.on_player_selected_area, function(event)
  if event.item ~= TOOL then return end
  local player = game.get_player(event.player_index)
  local list = selected_supported(event.entities)
  if #list == 0 then
    player.create_local_flying_text({ text = { "rl.mass-nothing" }, create_at_cursor = true })
    return
  end
  G.open_mass(player, list)
end)

script.on_event(defines.events.on_player_alt_selected_area, function(event)
  if event.item ~= TOOL then return end
  local player = game.get_player(event.player_index)
  local list = selected_supported(event.entities)
  for _, ent in ipairs(list) do L.set_pct(ent, 100) end
  player.create_local_flying_text({ text = { "rl.mass-reset", #list }, create_at_cursor = true })
end)

local function give_tool(player)
  if player.cursor_stack and player.cursor_stack.valid_for_read and player.cursor_stack.name == TOOL then
    player.clear_cursor()
    return
  end
  if player.clear_cursor() then
    player.cursor_stack.set_stack({ name = TOOL, count = 1 })
  end
end

script.on_event("rl-get-tool", function(event)
  give_tool(game.get_player(event.player_index))
end)

script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name ~= "rl-shortcut" then return end
  give_tool(game.get_player(event.player_index))
end)

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------
commands.add_command("rl-reset-all", { "rl.cmd-reset" }, function(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if player and not player.admin then
    player.print({ "rl.cmd-admin" })
    return
  end
  local n = L.reset_all()
  game.print({ "rl.cmd-reset-done", n })
end)

commands.add_command("rl-info", { "rl.cmd-info" }, function(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if not player then return end
  local ent = player.selected
  local e = ent and L.get_entry(ent)
  if not e then
    player.print({ "rl.cmd-info-none" })
    return
  end
  local info = e.info or {}
  player.print(string.format("[Rate Limiter] %s #%d: pct=%s applied=%s mode=%s d=%s speed=%s power=%s effects=%s pulses=%s",
    ent.name, e.unit, tostring(e.cfg.mode) .. ":" .. tostring(e.cfg.mode == "rate" and e.cfg.rate or e.cfg.pct), tostring(e.applied_pct), tostring(info.kind), tostring(info.d),
    tostring(info.speed), tostring(info.power), tostring(e.effect), tostring(e.duty_ok)))
end)
