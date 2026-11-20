-- Core: per-entity limit, smooth slowdown through local effects, pulses (duty cycle), scheduling.
--
-- A limit p (0..1) must scale output, input, power and pollution of the machine by p.
-- * Effect receivers get a local effect on speed and consumption. Pollution follows power by
--   itself. The total effect cannot go below -80%, i.e. a multiplier of 0.2, so when p times the
--   machine's own multiplier (modules, beacons) falls under 0.2 the rest is done by pulses.
--   If the game rounds the effect, the small remainder is also corrected by (rare) pulses.
-- * Other machines only get pulses: they are switched on for the share p of each cycle. The
--   on-time carries its fractional remainder to the next cycle, so the average is exact.
-- The limit is either a percentage or a rate of one product; a rate is turned into a percentage
-- from the machine's maximum rate of that product, recomputed on every re-check.
local types = require("scripts.types")
local render = require("scripts.render")
local rates = require("scripts.rates")

local L = {}

L.FLOOR = 0.2          -- lowest multiplier the game allows for speed and consumption
L.TAG = "rate_limiter" -- blueprint / ghost tag name
L.EPS = 1e-9
L.EFFECT_RESOLUTION = 1e-4 -- module effects have a resolution of 0.01%

L.on_changed = nil     -- set by control.lua: function(unit_number) called after a state change

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------
local function setting(name, default)
  local s = settings.global[name]
  if s then return s.value end
  return default
end

function L.cycle_ticks() return math.max(2, setting("rl-duty-cycle-ticks", 60)) end
function L.refresh_ticks() return math.max(10, setting("rl-refresh-ticks", 120)) end
function L.circuit_ticks() return math.max(1, setting("rl-circuit-ticks", 30)) end

-------------------------------------------------------------------------------
-- Storage
-------------------------------------------------------------------------------
function L.init_storage()
  storage.entries = storage.entries or {} -- unit_number -> entry
  storage.ghosts = storage.ghosts or {}   -- unit_number -> { entity, render }
  storage.duty_q = storage.duty_q or {}   -- tick -> array of unit_numbers
  storage.wake_q = storage.wake_q or {}   -- tick -> array of unit_numbers
  storage.memory = storage.memory or {}   -- position key -> { cfg, tick }
  storage.players = storage.players or {}
  -- entries from 0.1.0 kept pct/circuit on the entry itself
  for _, e in pairs(storage.entries) do
    if not e.cfg then
      e.cfg = { mode = "percent", pct = e.pct or 100, circuit = e.circuit }
      e.pct, e.circuit = nil, nil
    end
  end
end

-------------------------------------------------------------------------------
-- Values and configs
-------------------------------------------------------------------------------
-- A percentage as typed: any number of decimals, clamped to 0..100.
function L.clamp_pct(v)
  v = tonumber(v)
  if not v or v ~= v then return nil end
  if v < 0 then v = 0 elseif v > 100 then v = 100 end
  return v
end
L.round_pct = L.clamp_pct

-- Up to 6 decimals, trailing zeros dropped.
function L.format_num(v, decimals)
  v = tonumber(v) or 0
  local s = string.format("%." .. (decimals or 6) .. "f", v)
  if s:find("%.") then s = s:gsub("0+$", ""):gsub("%.$", "") end
  if s == "-0" then s = "0" end
  return s
end

function L.format_pct(v)
  return L.format_num(L.clamp_pct(v) or 100, 6)
end

local function copy_signal(s)
  if not s then return nil end
  return { type = s.type, name = s.name, quality = s.quality }
end

local function copy_key(k)
  if not k then return nil end
  return { type = k.type, name = k.name }
end

function L.copy_cfg(cfg)
  if not cfg then return nil end
  local c = {
    mode = cfg.mode == "rate" and "rate" or "percent",
    pct = L.clamp_pct(cfg.pct) or 100,
    product = copy_key(cfg.product),
    rate = tonumber(cfg.rate),
    unit = cfg.unit,
  }
  if c.rate and c.rate < 0 then c.rate = 0 end
  if c.mode == "rate" and not (c.product and c.rate) then c.mode = "percent" end
  if cfg.circuit then
    c.circuit = { enabled = cfg.circuit.enabled == true, signal = copy_signal(cfg.circuit.signal) }
  end
  return c
end

function L.default_cfg() return { mode = "percent", pct = 100 } end

function L.is_default(cfg)
  if cfg == nil then return true end
  if cfg.mode == "rate" then return false end
  return (cfg.pct or 100) >= 100 and not (cfg.circuit and cfg.circuit.enabled)
end

function L.cfg_from_tags(tags)
  local t = tags and tags[L.TAG]
  if type(t) ~= "table" then return nil end
  return L.copy_cfg(t)
end

-------------------------------------------------------------------------------
-- Low level entity access (guarded: some writes are ignored or unsupported by some entities)
-------------------------------------------------------------------------------
local function set_local(entity, eff)
  local ok = pcall(function() entity.local_effect = eff end)
  if not ok and eff == nil then
    -- if nil is not accepted, a zero effect clears it just as well
    ok = pcall(function() entity.local_effect = { speed = 0, consumption = 0 } end)
  end
  return ok
end

local function read_effects(entity)
  local ok, eff = pcall(function() return entity.effects end)
  if not ok or type(eff) ~= "table" then return nil end
  return eff
end

local function mult(sum)
  local m = 1 + (sum or 0)
  if m < L.FLOOR then m = L.FLOOR end
  return m
end

local function effect_mults(entity)
  local eff = read_effects(entity)
  if not eff then return 1, 1 end
  return mult(eff.speed), mult(eff.consumption)
end

-- The machine's own multipliers (modules, beacons, quality bonuses, research), without our effect.
-- The caller must have cleared our local effect first.
function L.read_natural(entity)
  local nat = { speed = 1, consumption = 1, productivity = 0, pollution = 1 }
  local eff = read_effects(entity)
  if eff then
    nat.speed = mult(eff.speed)
    nat.consumption = mult(eff.consumption)
    nat.pollution = mult(eff.pollution)
    nat.productivity = math.max(0, eff.productivity or 0)
  end
  local ok, pb = pcall(function() return entity.productivity_bonus end)
  if ok and type(pb) == "number" then nat.productivity = math.max(0, pb) end
  return nat
end

local function write_disabled(entity, v)
  local ok = pcall(function() entity.disabled_by_script = v end)
  if not ok then ok = pcall(function() entity.active = not v end) end
  return ok
end

local function read_disabled(entity)
  local ok, v = pcall(function() return entity.disabled_by_script end)
  if ok and v ~= nil then return v end
  ok, v = pcall(function() return entity.active end)
  if ok and v ~= nil then return not v end
  return false
end

local function set_disabled(e, v)
  if e.disabled == v then return end
  write_disabled(e.entity, v)
  e.disabled = v
end

local function set_status(e, status)
  local ent = e.entity
  if status then
    pcall(function() ent.custom_status = status end)
    e.status_set = true
  elseif e.status_set then
    pcall(function() ent.custom_status = nil end)
    e.status_set = nil
  end
end

-- What this entity supports, checked once when it gets an entry.
local function detect(entity)
  local caps = { effect = false, duty = false }
  if types.EFFECT_TYPES[entity.type] then
    caps.effect = pcall(function() return entity.local_effect end)
  end
  if not read_disabled(entity) then
    if write_disabled(entity, true) and read_disabled(entity) then caps.duty = true end
    write_disabled(entity, false)
  end
  return caps
end

-------------------------------------------------------------------------------
-- Scheduling
-------------------------------------------------------------------------------
local function push(q, tick, unit)
  local b = q[tick]
  if not b then b = {}; q[tick] = b end
  b[#b + 1] = unit
end

local function schedule_duty(e, tick)
  e.duty_tick = tick
  push(storage.duty_q, tick, e.unit)
end

local function schedule_wake(e, tick)
  e.wake_tick = tick
  push(storage.wake_q, tick, e.unit)
end

-------------------------------------------------------------------------------
-- Entries
-------------------------------------------------------------------------------
function L.get_entry(entity)
  if not (entity and entity.valid) then return nil end
  local unit = entity.unit_number
  return unit and storage.entries[unit]
end

local function new_entry(entity)
  local caps = detect(entity)
  local e = {
    entity = entity,
    unit = entity.unit_number,
    cfg = L.default_cfg(),
    effect = caps.effect,
    duty_ok = caps.duty,
    disabled = false,
  }
  storage.entries[e.unit] = e
  script.register_on_object_destroyed(entity)
  return e
end

local function circuit_on(cfg)
  return cfg.circuit and cfg.circuit.enabled and cfg.circuit.signal and cfg.circuit.signal.name and true or false
end

-- Sum of the chosen signal on red and green, or nil if no network is connected.
local function read_circuit(e)
  local cfg = e.cfg
  if not circuit_on(cfg) then return nil end
  local ent = e.entity
  local total, wired = 0, false
  for _, wid in pairs({ defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green }) do
    local ok, net = pcall(function() return ent.get_circuit_network(wid) end)
    if ok and net then
      wired = true
      local ok2, v = pcall(function() return net.get_signal(cfg.circuit.signal) end)
      if ok2 and v then total = total + v end
    end
  end
  if not wired then return nil end
  return total
end

-- Signal value in rate mode: per minute for items and fluids, kW for electricity and heat.
function L.signal_to_rate(v, product)
  if v < 0 then v = 0 end
  if product and rates.is_energy(product.type) then return v * 1000 end
  return v / 60
end

-- The percentage in force, from the manual value, the rate or the circuit network.
function L.target_pct(e)
  local cfg = e.cfg
  local cv = e.circuit_value
  e.rate_missing = nil
  e.max_rate = nil
  if cfg.mode == "rate" then
    local target = cfg.rate or 0
    if cv ~= nil then target = L.signal_to_rate(cv, cfg.product) end
    e.target_rate = target
    local max = rates.product_rate(e.stats, cfg.product)
    if not max or max <= 0 then
      -- the machine does not make this product now (no recipe, other recipe, no resource):
      -- keep the last limit until it does
      e.rate_missing = true
      return e.last_pct or 100
    end
    e.max_rate = max
    local pct = L.clamp_pct(100 * target / max)
    e.last_pct = pct
    return pct
  end
  if cv ~= nil then return L.clamp_pct(cv) end
  return cfg.pct
end

local function stop_duty(e)
  e.d = nil
  e.duty_tick = nil
  e.duty_phase = nil
end

local function start_duty(e, d)
  local was = e.d
  e.d = d
  if not was then
    -- spread machines over the cycle so they do not all switch on the same tick
    e.acc = ((e.unit or 0) % 97) / 97
    e.duty_phase = "start"
    schedule_duty(e, game.tick + 1)
  end
end

local function round_up_effect(v)
  -- a hair above the grid point, so that a game rounding down still lands on it
  return math.ceil(v / L.EFFECT_RESOLUTION - 1e-6) * L.EFFECT_RESOLUTION + L.EFFECT_RESOLUTION * 1e-3
end

-- Recompute and apply the limit for an entry. Called on every change and periodically.
function L.apply(e)
  local ent = e.entity
  if not (ent and ent.valid) then return end
  e.circuit_value = read_circuit(e)
  if e.effect then set_local(ent, nil) end
  local nat = L.read_natural(ent)
  e.nat = nat
  e.stats = rates.compute(ent, nat)
  local pct = L.target_pct(e)
  local p = pct / 100
  e.applied_pct = pct
  e.last_apply = game.tick
  e.info = nil

  if p >= 1 - L.EPS then
    stop_duty(e)
    set_disabled(e, false)
    set_status(e, nil)
    e.info = { kind = "full" }
    render.update_entry(e)
    return
  end

  if p <= L.EPS then
    if e.duty_ok then
      stop_duty(e)
      set_disabled(e, true)
      set_status(e, { diode = defines.entity_status_diode.red, label = { "rl.status-stopped" } })
      e.info = { kind = "stopped" }
      render.update_entry(e)
      return
    end
    p = 0 -- cannot be switched off: go as low as effects allow
  end

  local d = p
  local partial = false
  if e.effect then
    local nat_s, nat_c = nat.speed, nat.consumption
    local ts, tc = p * nat_s, p * nat_c
    d = math.min(1, ts / L.FLOOR, tc / L.FLOOR)
    if not e.duty_ok and d < 1 then d = 1; partial = true end
    local ms, mc
    if d > L.EPS then
      ms, mc = math.max(L.FLOOR, ts / d), math.max(L.FLOOR, tc / d)
    else
      ms, mc = L.FLOOR, L.FLOOR
    end
    local ls, lc = ms - nat_s, mc - nat_c
    if ls < -L.EPS or lc < -L.EPS then
      set_local(ent, { speed = ls, consumption = lc })
      local act_s, act_c = effect_mults(ent)
      if math.abs(act_s - ms) > 1e-3 or math.abs(act_c - mc) > 1e-3 then
        -- the effect was not taken (restricted machine or recipe): fall back to pure pulses,
        -- which scale every quantity of the machine evenly
        set_local(ent, nil)
        d = e.duty_ok and p or 1
        partial = not e.duty_ok
        e.info = { kind = "duty" }
      else
        if act_s < ms - L.EPS or act_c < mc - L.EPS then
          -- the game rounded the effect down: round it up and let pulses take off the rest
          set_local(ent, { speed = round_up_effect(ls), consumption = round_up_effect(lc) })
          act_s, act_c = effect_mults(ent)
        end
        if e.duty_ok and act_s > L.EPS then d = math.min(1, ts / act_s) end
        if d >= 1 - 1e-7 then d = 1 end
        e.info = { kind = d < 0.999 and "mixed" or "effect", speed = act_s / nat_s, power = act_c / nat_c }
      end
    else
      e.info = { kind = "duty" }
    end
  elseif not e.duty_ok then
    d = 1
    partial = true
    e.info = { kind = "unsupported" }
  else
    e.info = { kind = "duty" }
  end

  if d >= 1 - L.EPS then
    stop_duty(e)
    set_disabled(e, false)
    set_status(e, nil)
  else
    e.info.d = d
    start_duty(e, d)
    set_status(e, { diode = defines.entity_status_diode.yellow, label = { "rl.status-limited", L.format_num(pct, 2) } })
  end
  if partial and e.info.kind ~= "unsupported" then e.info.partial = true end
  render.update_entry(e)
end

-- Remove an entry, giving the machine back its normal state.
function L.remove(e, restore)
  if restore and e.entity and e.entity.valid then
    if e.effect then set_local(e.entity, nil) end
    if e.disabled then write_disabled(e.entity, false) end
    if e.status_set then pcall(function() e.entity.custom_status = nil end) end
  end
  render.destroy_entry(e)
  storage.entries[e.unit] = nil
end

-------------------------------------------------------------------------------
-- Stats for the panel
-------------------------------------------------------------------------------
-- Rates at full speed and the share currently applied.
function L.stats(entity)
  if not (entity and entity.valid) or types.is_ghost(entity) then return nil, 1 end
  local e = L.get_entry(entity)
  if e and e.stats then return e.stats, (e.applied_pct or 100) / 100 end
  return rates.compute(entity, L.read_natural(entity)), 1
end

-------------------------------------------------------------------------------
-- Config API used by GUI, blueprints, paste, rebuild
-------------------------------------------------------------------------------
function L.get_config(entity)
  if not (entity and entity.valid) then return L.default_cfg() end
  if types.is_ghost(entity) then
    return L.cfg_from_tags(entity.tags) or L.default_cfg()
  end
  local e = L.get_entry(entity)
  if not e then return L.default_cfg() end
  return L.copy_cfg(e.cfg)
end

local function notify(unit)
  if L.on_changed then L.on_changed(unit) end
end

local function wake_interval(e)
  if circuit_on(e.cfg) then return math.min(L.circuit_ticks(), L.refresh_ticks()) end
  return L.refresh_ticks()
end

function L.set_config(entity, cfg)
  if not types.is_supported(entity) then return end
  cfg = L.copy_cfg(cfg) or L.default_cfg()
  if types.is_ghost(entity) then
    local tags = entity.tags or {}
    if L.is_default(cfg) then tags[L.TAG] = nil else tags[L.TAG] = cfg end
    entity.tags = tags
    render.update_ghost(entity, cfg)
    notify(entity.unit_number)
    return
  end
  local e = L.get_entry(entity)
  if L.is_default(cfg) then
    if e then L.remove(e, true) end
    notify(entity.unit_number)
    return
  end
  if not e then e = new_entry(entity) end
  if cfg.mode ~= "rate" or not (e.cfg.product and cfg.product and e.cfg.product.name == cfg.product.name) then
    e.last_pct = nil
  end
  e.cfg = cfg
  L.apply(e)
  schedule_wake(e, game.tick + wake_interval(e))
  notify(e.unit)
end

function L.set_pct(entity, pct)
  local cfg = L.get_config(entity)
  cfg.mode = "percent"
  cfg.pct = L.clamp_pct(pct) or 100
  L.set_config(entity, cfg)
end

-- Limit by the rate of one product. rate is per second (items, fluids) or in watts (energy).
function L.set_rate(entity, product, rate, unit)
  local cfg = L.get_config(entity)
  cfg.mode = "rate"
  cfg.product = copy_key(product)
  cfg.rate = math.max(0, tonumber(rate) or 0)
  cfg.unit = unit or cfg.unit
  L.set_config(entity, cfg)
end

-- Re-measure right away (for example after the player changed the modules or the recipe).
function L.refresh_entity(entity)
  local e = L.get_entry(entity)
  if e then L.apply(e); notify(e.unit) end
end

-------------------------------------------------------------------------------
-- Ticks
-------------------------------------------------------------------------------
local function duty_step(e, tick)
  local ent = e.entity
  if not (ent and ent.valid) then return end
  local C = e.cycle or L.cycle_ticks()
  if e.duty_phase == "off" then
    set_disabled(e, true)
    e.duty_phase = "start"
    schedule_duty(e, e.cycle_start + C)
    return
  end
  -- start of a cycle
  C = L.cycle_ticks()
  e.cycle = C
  e.cycle_start = tick
  local want = e.acc + e.d * C
  local n = math.floor(want + 1e-9)
  e.acc = want - n
  if n >= C then
    set_disabled(e, false)
    schedule_duty(e, tick + C)
  elseif n <= 0 then
    set_disabled(e, true)
    schedule_duty(e, tick + C)
  else
    set_disabled(e, false)
    e.duty_phase = "off"
    schedule_duty(e, tick + n)
  end
end

local function wake(e, tick)
  local ent = e.entity
  if not (ent and ent.valid) then return end
  if circuit_on(e.cfg) then
    local v = read_circuit(e)
    if v ~= e.circuit_value or tick - (e.last_apply or 0) >= L.refresh_ticks() then
      L.apply(e)
      notify(e.unit)
    end
  elseif e.effect or e.cfg.mode == "rate" then
    L.apply(e)
    notify(e.unit)
  end
  schedule_wake(e, tick + wake_interval(e))
end

function L.on_tick(tick)
  local dq = storage.duty_q[tick]
  if dq then
    storage.duty_q[tick] = nil
    for _, unit in ipairs(dq) do
      local e = storage.entries[unit]
      if e and e.duty_tick == tick and e.d then duty_step(e, tick) end
    end
  end
  local wq = storage.wake_q[tick]
  if wq then
    storage.wake_q[tick] = nil
    for _, unit in ipairs(wq) do
      local e = storage.entries[unit]
      if e and e.wake_tick == tick then wake(e, tick) end
    end
  end
end

-- After a load with changed mods: drop invalid entries, re-apply the rest and rebuild the queues.
function L.revalidate()
  storage.duty_q = {}
  storage.wake_q = {}
  for unit, e in pairs(storage.entries) do
    if e.entity and e.entity.valid then
      e.d = nil
      e.duty_tick = nil
      e.wake_tick = nil
      L.apply(e)
      schedule_wake(e, game.tick + 1 + (unit % L.refresh_ticks()))
    else
      render.destroy_entry(e)
      storage.entries[unit] = nil
    end
  end
  for unit, g in pairs(storage.ghosts) do
    if not (g.entity and g.entity.valid) then
      render.destroy_ghost(unit)
    end
  end
end

-- Give every machine back its normal speed (command /rl-reset-all).
function L.reset_all()
  local n = 0
  for _, e in pairs(storage.entries) do
    L.remove(e, true)
    n = n + 1
  end
  storage.duty_q = {}
  storage.wake_q = {}
  return n
end

return L
