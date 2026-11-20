-- Alt-mode labels over limited machines and ghosts: an icon and the percentage.
local R = {}

local COLOR_LIMITED = { 1, 0.75, 0.2, 1 }
local COLOR_STOPPED = { 1, 0.3, 0.25, 1 }
local COLOR_CIRCUIT = { 0.45, 0.85, 1, 1 }
local COLOR_GHOST = { 0.75, 0.75, 0.75, 0.9 }
local COLOR_RATE = { 0.6, 1, 0.45, 1 }

local function enabled()
  local s = settings.global["rl-alt-labels"]
  return s == nil or s.value
end

local function fmt(v)
  local s = string.format("%.2f", v or 100):gsub("0+$", ""):gsub("%.$", "")
  return s .. "%"
end

local function destroy_list(list)
  if not list then return end
  for _, obj in pairs(list) do
    if obj and obj.valid then obj.destroy() end
  end
end

-- Label sits on the lower edge of the machine, where it does not cover the recipe icon.
local function y_offset(entity)
  local ok, box = pcall(function()
    if entity.type == "entity-ghost" then return entity.ghost_prototype.selection_box end
    return entity.prototype.selection_box
  end)
  if ok and box and box.right_bottom then
    return math.max(0, box.right_bottom.y - 0.45)
  end
  return 0.3
end

local function draw(entity, text, color)
  local list = {}
  local y = y_offset(entity)
  list[1] = rendering.draw_sprite({
    sprite = "rl-alt-icon",
    surface = entity.surface,
    target = { entity = entity, offset = { -0.42, y } },
    x_scale = 0.32, y_scale = 0.32,
    only_in_alt_mode = true,
    forces = { entity.force },
  })
  list[2] = rendering.draw_text({
    text = text,
    surface = entity.surface,
    target = { entity = entity, offset = { -0.18, y - 0.27 } },
    color = color,
    scale = 1.0,
    alignment = "left",
    only_in_alt_mode = true,
    forces = { entity.force },
  })
  return list
end

-- "0.7/s", "42/min", "1.5 MW" for a rate config (rate stored per second or in watts).
function R.rate_text(cfg)
  local unit = cfg.unit or "s"
  local v = cfg.rate or 0
  local suffix = "/s"
  if unit == "min" then v = v * 60; suffix = "/min"
  elseif unit == "kW" then v = v / 1000; suffix = " kW"
  elseif unit == "MW" then v = v / 1e6; suffix = " MW" end
  local s = string.format("%.3f", v):gsub("0+$", ""):gsub("%.$", "")
  return s .. suffix
end

function R.destroy_entry(e)
  destroy_list(e.render)
  e.render = nil
end

function R.update_entry(e)
  R.destroy_entry(e)
  local ent = e.entity
  if not (ent and ent.valid) or not enabled() then return end
  local cfg = e.cfg or {}
  local pct = e.applied_pct or cfg.pct or 100
  local circuit = cfg.circuit and cfg.circuit.enabled
  if pct >= 100 and not circuit and cfg.mode ~= "rate" then return end
  local color = COLOR_LIMITED
  if cfg.mode == "rate" then color = COLOR_RATE end
  if circuit then color = COLOR_CIRCUIT end
  if pct <= 0 then color = COLOR_STOPPED end
  e.render = draw(ent, fmt(pct), color)
end

function R.destroy_ghost(unit)
  local g = storage.ghosts[unit]
  if g then destroy_list(g.render) end
  storage.ghosts[unit] = nil
end

function R.update_ghost(ghost, cfg)
  local unit = ghost.unit_number
  if not unit then return end
  R.destroy_ghost(unit)
  if not enabled() then return end
  if cfg == nil then return end
  local circuit = cfg.circuit and cfg.circuit.enabled
  if (cfg.pct or 100) >= 100 and not circuit and cfg.mode ~= "rate" then return end
  local text = fmt(cfg.pct)
  if cfg.mode == "rate" then text = R.rate_text(cfg) end
  storage.ghosts[unit] = { entity = ghost, render = draw(ghost, text, COLOR_GHOST) }
  script.register_on_object_destroyed(ghost)
end

return R
