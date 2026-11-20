-- What a machine produces and consumes per second at full (unlimited) speed, with its own modules,
-- beacons, quality and productivity. The limiter multiplies these by the applied share.
--
-- Result of R.compute(entity, nat):
--   products    = { { type, name, rate } }   items/fluids per second, or watts for type "electricity"/"heat"
--   ingredients = { { type, name, rate } }
--   power       = { kind = "electric"|"burner"|"heat"|"fluid"|nil, watts }   energy taken by the machine
--   fuel        = { name, rate }             fuel items per second (burner machines), if known
--   pollution   = { { name, per_minute } }
-- nat = { speed, consumption, productivity, pollution } multipliers / bonus of the machine itself.
local R = {}

local function try(f, ...)
  local ok, v = pcall(f, ...)
  if ok then return v end
  return nil
end

local function quality_of(entity)
  return try(function() return entity.quality end)
end

-- Call a prototype method that takes a quality in 2.x, falling back to a plain field.
local function qcall(proto, method, field, quality)
  local v = try(function() return proto[method](quality) end)
  if v == nil then v = try(function() return proto[method]() end) end
  if v == nil and field then v = try(function() return proto[field] end) end
  return v
end

local function proto_name(x)
  if type(x) == "string" then return x end
  return try(function() return x.name end)
end

-- Expected amount of one product per craft (before productivity), and the part productivity applies to.
local function product_amount(p)
  local amount = p.amount
  if amount == nil then amount = ((p.amount_min or 0) + (p.amount_max or 0)) / 2 end
  local prob = p.probability or 1
  local base = amount * prob + (p.extra_count_fraction or 0)
  local ignored = math.min(base, (p.ignored_by_productivity or 0) * prob)
  return base, base - ignored
end

local function add(list, type_, name, rate)
  if not name or rate == nil then return end
  for _, x in ipairs(list) do
    if x.type == type_ and x.name == name then x.rate = x.rate + rate; return end
  end
  list[#list + 1] = { type = type_, name = name, rate = rate }
end

local function emissions(source_proto)
  local em = try(function() return source_proto.emissions_per_minute end)
  if type(em) == "number" then return { pollution = em } end
  if type(em) == "table" then return em end
  return nil
end

-- Energy source of the prototype: kind, base watts (J/tick * 60), emissions, burner effectivity.
local function energy_info(proto, quality)
  local per_tick = qcall(proto, "get_max_energy_usage", "max_energy_usage", quality)
  if not per_tick or per_tick == 0 then per_tick = try(function() return proto.energy_usage end) end
  local watts = (per_tick or 0) * 60
  local elec = try(function() return proto.electric_energy_source_prototype end)
  if elec then return "electric", watts, emissions(elec), 1 end
  local burner = try(function() return proto.burner_prototype end)
  if burner then return "burner", watts, emissions(burner), try(function() return burner.effectivity end) or 1 end
  local heat = try(function() return proto.heat_energy_source_prototype end)
  if heat then return "heat", watts, emissions(heat), 1 end
  local fluid = try(function() return proto.fluid_energy_source_prototype end)
  if fluid then return "fluid", watts, emissions(fluid), 1 end
  return nil, watts, nil, 1
end

local function fill_energy(stats, entity, proto, quality, nat, emission_mult)
  local kind, watts, em, effectivity = energy_info(proto, quality)
  if kind and watts > 0 then
    stats.power = { kind = kind, watts = watts * nat.consumption }
    if kind == "burner" then
      local burning = try(function() return entity.burner.currently_burning end)
      local item = burning and (try(function() return burning.name end) or burning)
      local fuel_value = item and try(function() return (type(item) == "string" and prototypes.item[item] or item).fuel_value end)
      if fuel_value and fuel_value > 0 then
        stats.fuel = { name = proto_name(item), rate = watts * nat.consumption / effectivity / fuel_value }
      end
    end
  end
  if em then
    for name, amount in pairs(em) do
      if amount and amount ~= 0 then
        stats.pollution[#stats.pollution + 1] = {
          name = name, per_minute = amount * nat.consumption * nat.pollution * (emission_mult or 1),
        }
      end
    end
  end
end

local function get_recipe(entity)
  local recipe = try(function() return entity.get_recipe() end)
  if recipe then return recipe end
  local prev = try(function() return entity.previous_recipe end)
  if prev then
    local r = try(function() return prev.name end) or prev
    if type(r) == "string" then r = prototypes.recipe[r] end
    return r
  end
  return nil
end

-------------------------------------------------------------------------------
-- Per type
-------------------------------------------------------------------------------
local function crafting(entity, proto, quality, nat, stats)
  local recipe = get_recipe(entity)
  local base_speed = qcall(proto, "get_crafting_speed", "crafting_speed", quality) or 1
  local emission_mult = 1
  if recipe then
    local energy = try(function() return recipe.energy end) or 1
    local crafts = base_speed * nat.speed / energy
    local prod = nat.productivity
    local max_prod = try(function() return recipe.prototype.maximum_productivity end)
      or try(function() return recipe.maximum_productivity end)
    if max_prod and prod > max_prod then prod = max_prod end
    for _, p in ipairs(try(function() return recipe.products end) or {}) do
      local base, affected = product_amount(p)
      add(stats.products, p.type, p.name, crafts * (base + affected * prod))
    end
    for _, i in ipairs(try(function() return recipe.ingredients end) or {}) do
      add(stats.ingredients, i.type, i.name, crafts * (i.amount or 0))
    end
    emission_mult = try(function() return recipe.prototype.emissions_multiplier end)
      or try(function() return recipe.emissions_multiplier end) or 1
  end
  fill_energy(stats, entity, proto, quality, nat, emission_mult)
end

local function mining(entity, proto, quality, nat, stats)
  local target = try(function() return entity.mining_target end)
  local speed = qcall(proto, "get_mining_speed", "mining_speed", quality) or 0.5
  if target then
    local rproto = target.prototype
    local mp = try(function() return rproto.mineable_properties end) or {}
    local ops = speed * nat.speed / (mp.mining_time or 1)
    local yield = 1
    if try(function() return rproto.infinite_resource end) then
      local normal = try(function() return rproto.normal_resource_amount end)
      if normal and normal > 0 then yield = (target.amount or normal) / normal end
    end
    for _, p in ipairs(mp.products or {}) do
      local base, affected = product_amount(p)
      add(stats.products, p.type, p.name, ops * yield * (base + affected * nat.productivity))
    end
    if mp.required_fluid and mp.fluid_amount then
      add(stats.ingredients, "fluid", mp.required_fluid, ops * mp.fluid_amount / 10)
    end
  end
  fill_energy(stats, entity, proto, quality, nat)
end

local function lab(entity, proto, quality, nat, stats)
  local force = entity.force
  local tech = try(function() return force.current_research end)
  if tech then
    local base = qcall(proto, "get_researching_speed", "researching_speed", quality) or 1
    local bonus = try(function() return force.laboratory_speed_modifier end) or 0
    local unit_ticks = try(function() return tech.research_unit_energy end) or 60
    local units = base * (1 + bonus) * nat.speed / (unit_ticks / 60)
    local drain = (try(function() return proto.science_pack_drain_rate_percent end) or 100) / 100
    for _, i in ipairs(try(function() return tech.research_unit_ingredients end) or {}) do
      add(stats.ingredients, i.type or "item", i.name, units * (i.amount or 1) * drain)
    end
  end
  fill_energy(stats, entity, proto, quality, nat)
end

local function fluidbox_filters(proto)
  local input, output
  for _, fb in ipairs(try(function() return proto.fluidbox_prototypes end) or {}) do
    local filter = fb.filter
    if filter then
      if fb.production_type == "output" then output = output or filter
      elseif fb.production_type == "input" or fb.production_type == "input-output" then input = input or filter end
    end
  end
  return input, output
end

local function boiler(entity, proto, quality, nat, stats)
  local _, watts = energy_info(proto, quality)
  local input, output = fluidbox_filters(proto)
  local target = try(function() return proto.target_temperature end)
  if output and target then
    local cap = try(function() return output.heat_capacity end) or 200
    local t_in = input and try(function() return input.default_temperature end) or 15
    local dt = target - t_in
    if dt > 0 and cap > 0 then
      local rate = watts / (dt * cap)
      add(stats.products, "fluid", output.name, rate)
      if input then add(stats.ingredients, "fluid", input.name, rate) end
    end
  end
  fill_energy(stats, entity, proto, quality, nat)
end

local function generator(entity, proto, quality, nat, stats)
  local power = qcall(proto, "get_max_power_output", "max_power_output", quality)
  if power then add(stats.products, "electricity", "electricity", power * 60) end
  local usage = qcall(proto, "get_fluid_usage_per_tick", "fluid_usage_per_tick", quality)
  local input = fluidbox_filters(proto)
  if usage and input then add(stats.ingredients, "fluid", input.name, usage * 60) end
end

local function burner_generator(entity, proto, quality, nat, stats)
  local power = qcall(proto, "get_max_power_output", "max_power_output", quality)
  if power then
    add(stats.products, "electricity", "electricity", power * 60)
    local burning = try(function() return entity.burner.currently_burning end)
    local item = burning and (try(function() return burning.name end) or burning)
    local fuel_value = item and try(function() return (type(item) == "string" and prototypes.item[item] or item).fuel_value end)
    local eff = try(function() return proto.burner_prototype.effectivity end) or 1
    stats.power = { kind = "burner", watts = power * 60 / eff }
    if fuel_value and fuel_value > 0 then stats.fuel = { name = proto_name(item), rate = power * 60 / eff / fuel_value } end
  end
  local em = emissions(try(function() return proto.burner_prototype end))
  for name, amount in pairs(em or {}) do
    stats.pollution[#stats.pollution + 1] = { name = name, per_minute = amount }
  end
end

local function reactor(entity, proto, quality, nat, stats)
  local _, watts = energy_info(proto, quality)
  if watts > 0 then add(stats.products, "heat", "heat", watts) end
  fill_energy(stats, entity, proto, quality, nat)
end

local function solar(entity, proto, quality, nat, stats)
  local per_tick = qcall(proto, "get_max_energy_production", "max_energy_production", quality)
  if per_tick then
    local mult = try(function() return entity.surface.solar_power_multiplier end) or 1
    add(stats.products, "electricity", "electricity", per_tick * 60 * mult)
  end
end

local function offshore(entity, proto, quality, nat, stats)
  local speed = qcall(proto, "get_pumping_speed", "pumping_speed", quality)
  local fluid = try(function() return entity.surface.get_tile(entity.position.x, entity.position.y).prototype.fluid end)
  local name = fluid and proto_name(fluid)
  if not name then
    local _, out = fluidbox_filters(proto)
    name = out and out.name
  end
  if speed and name then add(stats.products, "fluid", name, speed * 60) end
  fill_energy(stats, entity, proto, quality, nat)
end

local HANDLERS = {
  ["assembling-machine"] = crafting,
  ["furnace"] = crafting,
  ["rocket-silo"] = crafting,
  ["mining-drill"] = mining,
  ["lab"] = lab,
  ["boiler"] = boiler,
  ["generator"] = generator,
  ["burner-generator"] = burner_generator,
  ["reactor"] = reactor,
  ["solar-panel"] = solar,
  ["offshore-pump"] = offshore,
}

function R.compute(entity, nat)
  local stats = { products = {}, ingredients = {}, pollution = {} }
  if not (entity and entity.valid) or entity.type == "entity-ghost" then return stats end
  local handler = HANDLERS[entity.type]
  local proto = entity.prototype
  local quality = quality_of(entity)
  nat = nat or { speed = 1, consumption = 1, productivity = 0, pollution = 1 }
  if handler then
    local ok, err = pcall(handler, entity, proto, quality, nat, stats)
    if not ok then log("[rate-limiter] rates for " .. entity.name .. ": " .. tostring(err)) end
  else
    pcall(fill_energy, stats, entity, proto, quality, nat)
  end
  return stats
end

-- Maximum rate of one product (key = { type, name }) or nil if the machine does not make it.
function R.product_rate(stats, key)
  if not (stats and key) then return nil end
  for _, p in ipairs(stats.products) do
    if p.type == key.type and p.name == key.name then return p.rate end
  end
  return nil
end

function R.is_energy(type_) return type_ == "electricity" or type_ == "heat" end

return R
