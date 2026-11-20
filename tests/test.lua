-- Run from anywhere: lua5.2 tests/test.lua
local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
dofile(here .. "harness.lua")
require("control")
local L = require("scripts.limiter")
local G = require("scripts.gui")

local passed = 0
local function test(name, f)
  local ok, err = pcall(f)
  if not ok then
    print("FAIL " .. name .. ": " .. tostring(err))
    os.exit(1)
  end
  passed = passed + 1
  print("ok   " .. name)
end

local function approx(a, b, tol, msg)
  tol = tol or 1e-6
  if math.abs(a - b) > tol then error((msg or "value") .. ": got " .. tostring(a) .. " expected " .. tostring(b), 2) end
end

-- Average speed/power multiplier of an entity over n ticks: effect multiplier while on, 0 while off.
local function measure(ent, n)
  local on, speed, power = 0, 0, 0
  run_ticks(n, function()
    if not ent.disabled_by_script then
      on = on + 1
      local eff = ent.effects
      if eff then
        speed = speed + 1 + eff.speed
        power = power + 1 + eff.consumption
      else
        speed = speed + 1
        power = power + 1
      end
    end
  end)
  return on / n, speed / n, power / n
end

local function natural(ent)
  return math.max(0.2, 1 + ent._nat_speed), math.max(0.2, 1 + ent._nat_cons)
end

handlers.init()
local player = make_player(1)

test("50% on a plain assembler is smooth", function()
  local a = make_entity({ type = "assembling-machine", name = "assembling-machine-2" })
  L.set_pct(a, 50)
  local e = L.get_entry(a)
  assert(e and e.effect and e.duty_ok, "entry with capabilities")
  assert(e.info.kind == "effect", "kind " .. tostring(e.info.kind))
  approx(a.local_effect.speed, -0.5)
  approx(a.local_effect.consumption, -0.5)
  local share, s, p = measure(a, 600)
  approx(share, 1, 0, "always on")
  approx(s, 0.5); approx(p, 0.5)
end)

test("50% with +100% speed modules halves the real speed", function()
  local a = make_entity({ type = "assembling-machine", name = "assembling-machine-3", nat_speed = 1.0, nat_cons = 2.4 })
  L.set_pct(a, 50)
  local share, s, p = measure(a, 300)
  local ns, nc = natural(a)
  approx(s, 0.5 * ns, 1e-6, "speed"); approx(p, 0.5 * nc, 1e-6, "power")
  assert(share == 1)
end)

test("10% mixes the effect floor with pulses and keeps the average exact", function()
  local a = make_entity({ type = "furnace", name = "electric-furnace" })
  L.set_pct(a, 10)
  local e = L.get_entry(a)
  assert(e.info.kind == "mixed", e.info.kind)
  approx(e.info.d, 0.5)
  local _, s, p = measure(a, 6000)
  approx(s, 0.1, 1e-3, "speed"); approx(p, 0.1, 1e-3, "power")
end)

test("12.345% on a boiler: pulses, exact long-run share, decimals kept", function()
  local b = make_entity({ type = "boiler", name = "boiler" })
  L.set_pct(b, 12.345)
  assert(L.get_config(b).pct == 12.345, "decimals kept")
  assert(L.get_entry(b).info.kind == "duty")
  local share = measure(b, 60000)
  approx(share, 0.12345, 2 / 60000 * 60, "share")
end)

test("0.1% still runs now and then; 0% stops", function()
  local g = make_entity({ type = "generator", name = "steam-engine" })
  L.set_pct(g, 0.1)
  local share = measure(g, 120000)
  approx(share, 0.001, 0.0006, "0.1%")
  L.set_pct(g, 0)
  local share0 = measure(g, 600)
  assert(share0 == 0, "stopped")
  assert(L.get_entry(g).info.kind == "stopped")
end)

test("back to 100% removes the entry and restores the machine", function()
  local a = make_entity({ type = "mining-drill", name = "electric-mining-drill" })
  L.set_pct(a, 5)
  run_ticks(100)
  L.set_pct(a, 100)
  assert(L.get_entry(a) == nil, "entry removed")
  assert(a.local_effect == nil, "effect cleared")
  assert(a.disabled_by_script == false, "enabled")
  local share = measure(a, 200)
  assert(share == 1)
end)

test("effect not taken by the machine: falls back to pure pulses", function()
  local a = make_entity({ type = "assembling-machine", name = "restricted", ignore_local = true })
  L.set_pct(a, 40)
  local e = L.get_entry(a)
  assert(e.info.kind == "duty", e.info.kind)
  assert(a.local_effect == nil, "local effect removed again")
  local share, s, p = measure(a, 6000)
  approx(share, 0.4, 1e-3); approx(s, 0.4, 1e-3); approx(p, 0.4, 1e-3)
end)

test("machine that cannot be switched off: effects only, marked partial", function()
  local a = make_entity({ type = "lab", name = "lab", no_duty = true })
  L.set_pct(a, 5)
  local e = L.get_entry(a)
  assert(not e.duty_ok)
  assert(e.info.partial, "partial")
  local _, s = measure(a, 100)
  approx(s, 0.2, 1e-6, "lowest allowed")
  local sp = make_entity({ type = "solar-panel", name = "solar-panel", no_duty = true })
  L.set_pct(sp, 50)
  assert(L.get_entry(sp).info.kind == "unsupported")
end)

test("module change is picked up on the next re-check", function()
  local a = make_entity({ type = "assembling-machine", name = "am" })
  L.set_pct(a, 50)
  rawset(a, "_nat_speed", 0.5) -- player inserted speed modules
  run_ticks(130)
  local _, s = measure(a, 60)
  approx(s, 0.75, 1e-6)
end)

test("blueprint stores the config, building from it restores it", function()
  local a = make_entity({ type = "assembling-machine", name = "am-bp" })
  L.set_pct(a, 33.3)
  local stored = {}
  local stack = { object_name = "LuaItemStack", valid_for_read = true, is_blueprint = true,
    set_blueprint_entity_tag = function(i, k, v) stored[i] = { [k] = v } end }
  handlers.on_player_setup_blueprint({ player_index = 1, stack = stack,
    mapping = { valid = true, get = function() return { [7] = a } end } })
  assert(stored[7] and stored[7].rate_limiter.pct == 33.3, "tag written")
  -- ghost placed from the blueprint, then built by a robot
  local ghost = make_entity({ ghost_type = "assembling-machine", name = "am-bp", tags = stored[7] })
  handlers.on_built_entity({ entity = ghost })
  local built = make_entity({ type = "assembling-machine", name = "am-bp" })
  handlers.on_robot_built_entity({ entity = built, tags = ghost.tags })
  assert(L.get_entry(built) and L.get_config(built).pct == 33.3, "config from tags")
end)

test("Shift+RMB / Shift+LMB copies the limit, also 100%", function()
  local a = make_entity({ type = "assembling-machine", name = "a1" })
  local b = make_entity({ type = "assembling-machine", name = "a2" })
  L.set_pct(a, 20)
  handlers.on_entity_settings_pasted({ source = a, destination = b, player_index = 1 })
  assert(L.get_config(b).pct == 20)
  local c = make_entity({ type = "assembling-machine", name = "a3" })
  handlers.on_entity_settings_pasted({ source = c, destination = b, player_index = 1 })
  assert(L.get_entry(b) == nil, "100% pasted resets")
end)

test("mined and rebuilt at the same spot (undo, fast-replace) keeps the limit", function()
  local a = make_entity({ type = "furnace", name = "stone-furnace", position = { x = 100.5, y = 5.5 } })
  L.set_pct(a, 60)
  handlers.on_player_mined_entity({ entity = a, player_index = 1 })
  destroy_entity(a)
  assert(storage.entries[a.unit_number] == nil)
  local b = make_entity({ type = "furnace", name = "steel-furnace", position = { x = 100.5, y = 5.5 } })
  handlers.on_built_entity({ entity = b, player_index = 1 })
  assert(L.get_entry(b) and L.get_config(b).pct == 60, "restored")
  -- memory is used only once
  local c = make_entity({ type = "furnace", name = "stone-furnace", position = { x = 100.5, y = 5.5 } })
  handlers.on_built_entity({ entity = c })
  assert(L.get_entry(c) == nil)
end)

test("a destroyed machine passes the limit to its ghost", function()
  local a = make_entity({ type = "assembling-machine", name = "am-d", position = { x = 200.5, y = 1.5 } })
  L.set_pct(a, 45)
  handlers.on_entity_died({ entity = a })
  destroy_entity(a)
  local ghost = make_entity({ ghost_type = "assembling-machine", name = "am-d", position = { x = 200.5, y = 1.5 } })
  handlers.on_post_entity_died({ ghost = ghost, unit_number = a.unit_number })
  assert(ghost.tags and ghost.tags.rate_limiter.pct == 45, "ghost tagged")
  handlers.on_object_destroyed({ useful_id = a.unit_number, type = defines.target_type.entity })
  assert(storage.entries[a.unit_number] == nil, "entry cleaned")
end)

test("circuit network sets the limit; without wires the manual value is used", function()
  local value = 30
  local net = { get_signal = function(sig) if sig.name == "signal-S" then return value end return 0 end }
  local a = make_entity({ type = "assembling-machine", name = "am-c", wires = true })
  L.set_config(a, { pct = 80, circuit = { enabled = true, signal = { type = "virtual", name = "signal-S" } } })
  local e = L.get_entry(a)
  assert(e.applied_pct == 80, "no network yet")
  rawset(a, "_nets", { [1] = net })
  run_ticks(35)
  assert(e.applied_pct == 30, "from network: " .. tostring(e.applied_pct))
  value = 250
  run_ticks(35)
  assert(e.applied_pct == 100, "clamped")
  value = -5
  run_ticks(35)
  assert(e.applied_pct == 0, "clamped low")
  assert(a.disabled_by_script == true, "stopped by signal")
  -- circuit control at 100% keeps the entry (it must keep reading)
  L.set_config(a, { pct = 100, circuit = { enabled = true, signal = { type = "virtual", name = "signal-S" } } })
  assert(L.get_entry(a), "kept for circuit")
end)

test("panel: open, slider, number field, presets", function()
  local a = make_entity({ type = "assembling-machine", name = "am-gui", wires = true })
  handlers.on_gui_opened({ player_index = 1, gui_type = defines.gui_type.entity, entity = a })
  local panels = player.gui.relative.children
  assert(#panels == 2, "two candidate anchors for assemblers")
  assert(panels[1].anchor.names[1] == "am-gui")
  local slider = find_element(panels[1], "rl_slider")
  slider.slider_value = 40
  handlers.on_gui_value_changed({ player_index = 1, element = slider })
  assert(L.get_config(a).pct == 40)
  assert(find_element(panels[2], "rl_text").text == "40", "other panel synced")
  local text = find_element(panels[1], "rl_text")
  text.text = "12.5"
  handlers.on_gui_text_changed({ player_index = 1, element = text })
  assert(L.get_config(a).pct == 12.5)
  assert(text.text == "12.5", "typed text kept")
  text.text = "12."
  handlers.on_gui_text_changed({ player_index = 1, element = text })
  assert(L.get_config(a).pct == 12 and text.text == "12.", "typing a decimal point is not interrupted")
  local preset = find_element(panels[1], "rl_preset_75")
  handlers.on_gui_click({ player_index = 1, element = preset })
  assert(L.get_config(a).pct == 75)
  assert(find_element(panels[1], "rl_info").caption[1] == "rl.info-effect")
  -- circuit checkbox
  local cb = find_element(panels[1], "rl_circuit")
  assert(cb, "circuit section shown for wired machine")
  cb.state = true
  handlers.on_gui_checked_state_changed({ player_index = 1, element = cb })
  assert(L.get_config(a).circuit.enabled == true)
  assert(L.get_config(a).circuit.signal.name == "signal-S")
  handlers.on_gui_closed({ player_index = 1, gui_type = defines.gui_type.entity, entity = a })
  assert(#player.gui.relative.children == 0, "panels closed")
end)

test("panel on a ghost writes the ghost tags", function()
  local g = make_entity({ ghost_type = "boiler", name = "boiler" })
  handlers.on_gui_opened({ player_index = 1, gui_type = defines.gui_type.entity, entity = g })
  local panels = player.gui.relative.children
  assert(#panels == 1 and panels[1].anchor.ghost_mode == "both")
  local preset = find_element(panels[1], "rl_preset_25")
  handlers.on_gui_click({ player_index = 1, element = preset })
  assert(g.tags.rate_limiter.pct == 25)
  assert(storage.ghosts[g.unit_number], "ghost label")
  handlers.on_gui_closed({ player_index = 1, gui_type = defines.gui_type.entity, entity = g })
end)

test("selection tool: dialog applies to all, Shift resets", function()
  local list = {
    make_entity({ type = "assembling-machine", name = "m1" }),
    make_entity({ type = "boiler", name = "b1" }),
    make_entity({ type = "transport-belt", name = "belt" }),
    make_entity({ ghost_type = "furnace", name = "f1" }),
  }
  handlers.on_player_selected_area({ player_index = 1, item = "rl-selection-tool", entities = list })
  local dlg = player.gui.screen.rl_mass
  assert(dlg, "dialog open")
  assert(find_element(dlg, "rl_count").caption[2] == 3, "belt skipped")
  local text = find_element(dlg, "rl_text")
  text.text = "37.5"
  handlers.on_gui_text_changed({ player_index = 1, element = text })
  assert(L.get_entry(list[1]) == nil, "not applied before confirm")
  handlers.on_gui_click({ player_index = 1, element = find_element(dlg, "rl_mass_apply") })
  assert(player.gui.screen.rl_mass == nil, "closed")
  assert(L.get_config(list[1]).pct == 37.5)
  assert(L.get_config(list[2]).pct == 37.5)
  assert(list[4].tags.rate_limiter.pct == 37.5)
  handlers.on_player_alt_selected_area({ player_index = 1, item = "rl-selection-tool", entities = list })
  assert(L.get_entry(list[1]) == nil and L.get_entry(list[2]) == nil)
  assert(list[4].tags.rate_limiter == nil)
end)

test("shortcut gives and takes the tool", function()
  handlers.on_lua_shortcut({ player_index = 1, prototype_name = "rl-shortcut" })
  assert(player.cursor_stack.name == "rl-selection-tool")
  handlers["rl-get-tool"]({ player_index = 1 })
  assert(not player.cursor_stack.valid_for_read)
end)

test("alt-mode labels follow the entries", function()
  local a = make_entity({ type = "assembling-machine", name = "lbl" })
  local before = render_alive
  L.set_pct(a, 50)
  assert(render_alive == before + 2, "icon and text")
  L.set_pct(a, 30)
  assert(render_alive == before + 2, "replaced, not added")
  L.set_pct(a, 100)
  assert(render_alive == before, "removed")
end)

test("configuration change re-applies and rebuilds the queues", function()
  local b = make_entity({ type = "reactor", name = "nuclear-reactor" })
  L.set_pct(b, 50)
  local dead = make_entity({ type = "reactor", name = "dead" })
  L.set_pct(dead, 50)
  destroy_entity(dead)
  handlers.config({})
  assert(storage.entries[dead.unit_number] == nil, "invalid dropped")
  local share = measure(b, 6000)
  approx(share, 0.5, 2e-3)
end)

test("reset command restores everything", function()
  local a = make_entity({ type = "assembling-machine", name = "r1" })
  L.set_pct(a, 0)
  assert(a.disabled_by_script)
  commands_list["rl-reset-all"]({ player_index = 1 })
  assert(next(storage.entries) == nil)
  assert(a.disabled_by_script == false and a.local_effect == nil)
end)


-------------------------------------------------------------------------------
-- 0.2.0: rate mode, precision, reference block
-------------------------------------------------------------------------------
local ore_res = { valid = true, amount = 1000, prototype = { name = "iron-ore", infinite_resource = false,
  mineable_properties = { mining_time = 1, products = { { type = "item", name = "iron-ore", amount = 1 } } } } }
local drill_proto = {
  mining_speed = 0.5,
  get_max_energy_usage = function() return 90000 / 60 end,
  electric_energy_source_prototype = { emissions_per_minute = { pollution = 10 } },
}

test("precision: 33.3333% gives exactly that speed", function()
  local a = make_entity({ type = "assembling-machine", name = "prec" })
  L.set_pct(a, 33.3333)
  local _, s = measure(a, 120)
  approx(s, 0.333333, 1e-9)
  assert(L.format_pct(33.3333) == "33.3333")
  assert(L.format_pct(12.5) == "12.5" and L.format_pct(100) == "100")
end)

test("rate mode: drill limited to 0.35 ore/s with productivity and modules", function()
  local d = make_entity({ type = "mining-drill", name = "electric-mining-drill", proto = drill_proto, mining_target = ore_res, productivity = 0.4 })
  local stats = L.stats(d)
  approx(stats.products[1].rate, 0.7, 1e-9, "max 0.5 * 1.4")
  approx(stats.power.watts, 90000, 1e-6, "90 kW")
  approx(stats.pollution[1].per_minute, 10, 1e-9)
  L.set_rate(d, { type = "item", name = "iron-ore" }, 0.35, "s")
  local e = L.get_entry(d)
  approx(e.applied_pct, 50, 1e-9)
  local _, s = measure(d, 120)
  approx(s * 0.7, 0.35, 1e-9, "ore per second")
  -- speed modules: the max rises, the mod lowers the percentage on the next re-check
  rawset(d, "_nat_speed", 1.0)
  run_ticks(130)
  approx(e.applied_pct, 25, 1e-9, "re-computed")
  local _, s2 = measure(d, 60)
  approx(s2 * 0.5 * 1.4, 0.35, 1e-9, "still 0.35/s")
  local st, p = L.stats(d)
  approx(st.products[1].rate * p, 0.35, 1e-9, "panel shows the limited output")
end)

test("rate mode: refinery limited by one of several products", function()
  local recipe = { name = "advanced-oil-processing", energy = 5,
    products = { { type = "fluid", name = "heavy-oil", amount = 25 }, { type = "fluid", name = "light-oil", amount = 45 }, { type = "fluid", name = "petroleum-gas", amount = 55 } },
    ingredients = { { type = "fluid", name = "water", amount = 50 }, { type = "fluid", name = "crude-oil", amount = 100 } },
    prototype = { emissions_multiplier = 1, maximum_productivity = 3 } }
  local r = make_entity({ type = "assembling-machine", name = "oil-refinery", recipe = recipe,
    proto = { get_crafting_speed = function() return 1 end, get_max_energy_usage = function() return 420000 / 60 end,
      electric_energy_source_prototype = { emissions_per_minute = { pollution = 6 } } } })
  local stats = L.stats(r)
  assert(#stats.products == 3)
  approx(stats.products[3].rate, 11, 1e-9)
  L.set_rate(r, { type = "fluid", name = "petroleum-gas" }, 5.5, "s")
  approx(L.get_entry(r).applied_pct, 50, 1e-9)
  local st, p = L.stats(r)
  approx(st.products[1].rate * p, 2.5, 1e-9, "heavy oil follows")
  approx(st.ingredients[2].rate * p, 10, 1e-9, "crude oil follows")
  approx(st.power.watts * p, 210000, 1e-6, "power follows")
  approx(st.pollution[1].per_minute * p, 3, 1e-9, "pollution follows")
  -- recipe removed: keeps the last limit
  rawget(r, "_f").get_recipe = function() return nil end
  L.refresh_entity(r)
  assert(L.get_entry(r).rate_missing)
  approx(L.get_entry(r).applied_pct, 50, 1e-9)
end)

test("rate mode on electricity and on steam", function()
  local g = make_entity({ type = "generator", name = "steam-engine", proto = {
    get_max_power_output = function() return 15000 end, get_fluid_usage_per_tick = function() return 0.5 end,
    fluidbox_prototypes = { { production_type = "input", filter = prototypes.fluid.steam } } } })
  local st = L.stats(g)
  approx(st.products[1].rate, 900000, 1e-6)
  approx(st.ingredients[1].rate, 30, 1e-9)
  L.set_rate(g, { type = "electricity", name = "electricity" }, 450000, "kW")
  approx(L.get_entry(g).applied_pct, 50, 1e-9)
  local b = make_entity({ type = "boiler", name = "boiler", proto = {
    get_max_energy_usage = function() return 30000 end, target_temperature = 165,
    burner_prototype = { effectivity = 1, emissions_per_minute = { pollution = 30 } },
    fluidbox_prototypes = { { production_type = "input-output", filter = prototypes.fluid.water }, { production_type = "output", filter = prototypes.fluid.steam } } } })
  rawget(b, "_f").burner = { currently_burning = { name = prototypes.item.coal } }
  local sb = L.stats(b)
  approx(sb.products[1].rate, 60, 1e-9, "steam/s")
  approx(sb.fuel.rate, 0.45, 1e-9, "coal/s")
  L.set_rate(b, { type = "fluid", name = "steam" }, 15, "s")
  approx(L.get_entry(b).applied_pct, 25, 1e-9)
end)

test("rate mode from the circuit network: per minute", function()
  local value = 21
  local net = { get_signal = function() return value end }
  local d = make_entity({ type = "mining-drill", name = "drill-c", proto = drill_proto, mining_target = ore_res, wires = true })
  L.set_config(d, { mode = "rate", product = { type = "item", name = "iron-ore" }, rate = 0.5, unit = "s",
    circuit = { enabled = true, signal = { type = "virtual", name = "signal-S" } } })
  rawset(d, "_nets", { [2] = net })
  run_ticks(35)
  approx(L.get_entry(d).applied_pct, 70, 1e-9, "21/min of 0.5/s")
end)

test("effect rounded by the game is corrected by pulses", function()
  local a = make_entity({ type = "assembling-machine", name = "rounding" })
  rawset(a, "_resolution", 1e-4)
  L.set_pct(a, 33.33333)
  local e = L.get_entry(a)
  local eff = a.effects
  approx((1 + eff.speed) * (e.d or 1), 0.3333333, 1e-9, "effect * on-share")
end)

test("panel: rate mode, product, unit, reference block", function()
  local recipe = { name = "iron-plate", energy = 3.2,
    products = { { type = "item", name = "iron-plate", amount = 1 } },
    ingredients = { { type = "item", name = "iron-ore", amount = 1 } }, prototype = {} }
  local f = make_entity({ type = "furnace", name = "stone-furnace", recipe = recipe, proto = {
    get_crafting_speed = function() return 1 end, get_max_energy_usage = function() return 90000 / 60 end,
    burner_prototype = { effectivity = 1, emissions_per_minute = { pollution = 2 } } } })
  rawget(f, "_f").burner = { currently_burning = { name = prototypes.item.coal } }
  handlers.on_gui_opened({ player_index = 1, gui_type = defines.gui_type.entity, entity = f })
  local panel = player.gui.relative.children[1]
  local stats = find_element(panel, "rl_stats")
  assert(#stats.children >= 5, "output, input, fuel, power, pollution lines")
  handlers.on_gui_checked_state_changed({ player_index = 1, element = find_element(panel, "rl_mode_rate") })
  panel = player.gui.relative.children[1]
  local field = find_element(panel, "rl_rate")
  assert(field, "rate controls")
  approx(tonumber(field.text), 1 / 3.2, 1e-6, "starts at current output")
  field.text = "0.1"
  handlers.on_gui_text_changed({ player_index = 1, element = field })
  approx(L.get_entry(f).applied_pct, 32, 1e-9)
  local unit = find_element(panel, "rl_unit")
  unit.selected_index = 2
  handlers.on_gui_selection_state_changed({ player_index = 1, element = unit })
  assert(find_element(panel, "rl_rate").text == "6", "6 per minute")
  assert(L.get_config(f).unit == "min")
  approx(L.get_config(f).rate, 0.1, 1e-12, "same rate")
  -- per-minute reference
  handlers.on_gui_click({ player_index = 1, element = find_element(panel, "rl_stats_unit") })
  panel = player.gui.relative.children[1]
  assert(find_element(panel, "rl_stats_unit").caption == "/min")
  -- back to percent keeps the machine where it is
  handlers.on_gui_checked_state_changed({ player_index = 1, element = find_element(panel, "rl_mode_percent") })
  approx(L.get_config(f).pct, 32, 1e-9)
  handlers.on_gui_closed({ player_index = 1, gui_type = defines.gui_type.entity, entity = f })
end)

test("old 0.1.0 entries are migrated", function()
  local a = make_entity({ type = "assembling-machine", name = "old" })
  storage.entries[a.unit_number] = { entity = a, unit = a.unit_number, pct = 40, effect = true, duty_ok = true, disabled = false }
  handlers.config({})
  assert(L.get_config(a).pct == 40 and L.get_config(a).mode == "percent")
end)

print(passed .. " tests passed")
