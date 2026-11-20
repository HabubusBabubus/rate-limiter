-- Keeping the limit across blueprints, copy/paste of settings, ghosts, rebuilding and undo.
--
-- * Blueprints (and copy/cut) store the config as an entity tag; ghosts carry it in their tags and
--   hand it to the entity built from them.
-- * A machine that dies leaves a ghost: the config is written into that ghost.
-- * A machine that is mined (by hand, robot, platform, fast-replace or upgrade) leaves a short-lived
--   memory at its position; a supported machine built at the same spot picks it up. This covers
--   undo, fast-replace and upgrade planners.
local types = require("scripts.types")
local L = require("scripts.limiter")
local render = require("scripts.render")

local P = {}

P.MEMORY_TICKS = 60 * 60 * 60 -- one hour of game time

local function pos_key(surface_index, force_name, pos)
  return string.format("%d|%s|%.1f|%.1f", surface_index, force_name or "", pos.x, pos.y)
end

local function key_of(entity)
  local force = entity.force
  return pos_key(entity.surface.index, force and force.name, entity.position)
end

function P.remember(entity)
  local e = L.get_entry(entity)
  if not e then return end
  local cfg = L.get_config(entity)
  if L.is_default(cfg) then return end
  storage.memory[key_of(entity)] = { cfg = cfg, tick = game.tick }
end

function P.take_memory(entity)
  local key = key_of(entity)
  local m = storage.memory[key]
  if not m then return nil end
  storage.memory[key] = nil
  if game.tick - m.tick > P.MEMORY_TICKS then return nil end
  return m.cfg
end

function P.cleanup_memory()
  local now = game.tick
  for key, m in pairs(storage.memory) do
    if now - m.tick > P.MEMORY_TICKS then storage.memory[key] = nil end
  end
end

-------------------------------------------------------------------------------
-- Build / remove events
-------------------------------------------------------------------------------
function P.on_built(event)
  local entity = event.entity or event.destination
  if not types.is_supported(entity) then return end
  local cfg = L.cfg_from_tags(event.tags)
  if types.is_ghost(entity) then
    render.update_ghost(entity, cfg or L.cfg_from_tags(entity.tags))
    return
  end
  local mem = P.take_memory(entity)
  cfg = cfg or mem
  if cfg and not L.is_default(cfg) then L.set_config(entity, cfg) end
end

function P.on_mined(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  if types.is_ghost(entity) then
    render.destroy_ghost(entity.unit_number)
    return
  end
  local e = L.get_entry(entity)
  if not e then return end
  P.remember(entity)
  L.remove(e, false)
end

function P.on_died(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  if L.get_entry(entity) then P.remember(entity) end
  -- the entry stays until on_object_destroyed, so on_post_entity_died can still read it
end

function P.on_post_died(event)
  local ghost = event.ghost
  local e = event.unit_number and storage.entries[event.unit_number]
  if not e then return end
  if ghost and ghost.valid then
    local cfg = e.cfg
    if not L.is_default(cfg) then L.set_config(ghost, cfg) end
  end
end

function P.on_destroyed(event)
  local unit = event.useful_id
  if not unit then return end
  local e = storage.entries[unit]
  if e and not (e.entity and e.entity.valid) then
    render.destroy_entry(e)
    storage.entries[unit] = nil
  end
  local g = storage.ghosts[unit]
  if g and not (g.entity and g.entity.valid) then render.destroy_ghost(unit) end
end

-------------------------------------------------------------------------------
-- Settings copy (Shift+RMB / Shift+LMB) and cloning
-------------------------------------------------------------------------------
function P.on_settings_pasted(event)
  local src, dst = event.source, event.destination
  if not (types.is_supported(src) and types.is_supported(dst)) then return end
  L.set_config(dst, L.get_config(src))
end

function P.on_cloned(event)
  local src, dst = event.source, event.destination
  if not (types.is_supported(src) and types.is_supported(dst)) then return end
  local cfg = L.get_config(src)
  if not L.is_default(cfg) then L.set_config(dst, cfg) end
end

-------------------------------------------------------------------------------
-- Blueprints
-------------------------------------------------------------------------------
local function blueprint_targets(event)
  local list = {}
  local player = event.player_index and game.get_player(event.player_index)
  local function add(bp)
    if not bp then return end
    local ok, good = pcall(function()
      if bp.object_name == "LuaItemStack" then return bp.valid_for_read and bp.is_blueprint end
      return bp.valid
    end)
    if ok and good then list[#list + 1] = bp end
  end
  add(event.stack)
  add(event.record)
  if #list == 0 and player then
    add(player.blueprint_to_setup)
    add(player.cursor_stack)
  end
  return list
end

function P.on_setup_blueprint(event)
  local mapping = event.mapping
  local ok, map = pcall(function() return mapping and mapping.valid and mapping.get() end)
  if not ok or type(map) ~= "table" then return end
  local tags = {}
  for index, entity in pairs(map) do
    if types.is_supported(entity) then
      local cfg = L.get_config(entity)
      if not L.is_default(cfg) then tags[index] = cfg end
    end
  end
  if next(tags) == nil then return end
  for _, bp in ipairs(blueprint_targets(event)) do
    for index, cfg in pairs(tags) do
      pcall(function() bp.set_blueprint_entity_tag(index, L.TAG, cfg) end)
    end
  end
end

return P
