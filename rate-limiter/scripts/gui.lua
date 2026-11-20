-- Panel next to the machine window, and the dialog for the selection tool.
local types = require("scripts.types")
local L = require("scripts.limiter")
local rates = require("scripts.rates")
local render = require("scripts.render")

local G = {}

G.PRESETS = { 100, 75, 50, 25, 0 }
local PANEL_PREFIX = "rl_panel_"
local MASS = "rl_mass"
local ITEM_UNITS = { "s", "min" }
local ENERGY_UNITS = { "kW", "MW" }

local function pstate(player)
  storage.players = storage.players or {}
  local ps = storage.players[player.index]
  if not ps then
    ps = { mass_pct = 50 }
    storage.players[player.index] = ps
  end
  return ps
end
G.pstate = pstate

-------------------------------------------------------------------------------
-- Formatting
-------------------------------------------------------------------------------
local function trim(s)
  if s:find("%.") then s = s:gsub("0+$", ""):gsub("%.$", "") end
  return s
end

function G.fmt_amount(v)
  v = v or 0
  local a = math.abs(v)
  local s
  if a >= 100 then s = string.format("%.1f", v)
  elseif a >= 10 then s = string.format("%.2f", v)
  elseif a >= 0.1 then s = string.format("%.3f", v)
  else s = string.format("%.4f", v) end
  return trim(s)
end

function G.fmt_watts(w)
  w = w or 0
  local a = math.abs(w)
  if a >= 1e9 then return G.fmt_amount(w / 1e9) .. " GW" end
  if a >= 1e6 then return G.fmt_amount(w / 1e6) .. " MW" end
  if a >= 1e3 then return G.fmt_amount(w / 1e3) .. " kW" end
  return G.fmt_amount(w) .. " W"
end

local function fmt_share(d) return L.format_num((d or 1) * 100, 2) end

local function icon(key)
  if key.type == "fluid" then return "[fluid=" .. key.name .. "]" end
  if key.type == "electricity" or key.type == "heat" then return "" end
  return "[item=" .. key.name .. "]"
end

local function key_name(key)
  if key.type == "electricity" then return { "rl.electricity" } end
  if key.type == "heat" then return { "rl.heat" } end
  local ok, n = pcall(function()
    local p = key.type == "fluid" and prototypes.fluid[key.name] or prototypes.item[key.name]
    return p and p.localised_name
  end)
  if ok and n then return n end
  return key.name
end

local function same_key(a, b) return a and b and a.type == b.type and a.name == b.name end

-- Rate in base units (per second, or watts) -> number shown for the unit, and back.
local function to_unit(v, unit)
  if unit == "min" then return v * 60 end
  if unit == "kW" then return v / 1e3 end
  if unit == "MW" then return v / 1e6 end
  return v
end
local function from_unit(v, unit)
  if unit == "min" then return v / 60 end
  if unit == "kW" then return v * 1e3 end
  if unit == "MW" then return v * 1e6 end
  return v
end

local function units_for(key)
  if key and rates.is_energy(key.type) then return ENERGY_UNITS end
  return ITEM_UNITS
end

local function unit_caption(unit)
  return { "rl.unit-" .. unit }
end

local function fmt_rate(v, key, per_minute)
  if rates.is_energy(key.type) then return G.fmt_watts(v) end
  if per_minute then return G.fmt_amount(v * 60) .. "/min" end
  return G.fmt_amount(v) .. "/s"
end

local function can_wire(entity)
  if types.is_ghost(entity) then
    local ok, v = pcall(function() return entity.ghost_prototype.get_max_circuit_wire_distance() end)
    if ok and type(v) == "number" then return v > 0 end
    return false
  end
  local ok, conns = pcall(function() return entity.get_wire_connectors(true) end)
  if not ok or type(conns) ~= "table" then return false end
  for id in pairs(conns) do
    if id == defines.wire_connector_id.circuit_red or id == defines.wire_connector_id.circuit_green then return true end
  end
  return false
end

-------------------------------------------------------------------------------
-- Percent controls: slider, number field, presets (also used by the selection tool dialog)
-------------------------------------------------------------------------------
local function build_value_controls(parent, pct)
  local row = parent.add({ type = "flow", name = "rl_row", direction = "horizontal" })
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 8
  local slider = row.add({
    type = "slider", name = "rl_slider",
    minimum_value = 0, maximum_value = 100, value = math.floor(pct + 0.5), value_step = 1,
  })
  slider.style.horizontally_stretchable = true
  slider.style.minimal_width = 120
  local text = row.add({
    type = "textfield", name = "rl_text", text = L.format_pct(pct),
    numeric = true, allow_decimal = true, allow_negative = false, lose_focus_on_confirm = true,
    tooltip = { "rl.text-tooltip" },
  })
  text.style.width = 80
  text.style.horizontal_align = "center"
  row.add({ type = "label", caption = "%" })

  local presets = parent.add({ type = "flow", name = "rl_presets", direction = "horizontal" })
  presets.style.horizontal_spacing = 4
  for _, v in ipairs(G.PRESETS) do
    local b = presets.add({ type = "button", name = "rl_preset_" .. v, caption = v .. "%" })
    b.style.minimal_width = 0
    b.style.width = 48
    b.style.height = 28
    b.style.padding = 0
  end
end

local function set_value_controls(container, pct, keep_text)
  local row = container and container.rl_row
  if not row then return end
  row.rl_slider.slider_value = math.floor(pct + 0.5)
  local cur = L.clamp_pct(row.rl_text.text)
  if not keep_text or cur == nil or math.abs(cur - pct) > 1e-9 then row.rl_text.text = L.format_pct(pct) end
end

-------------------------------------------------------------------------------
-- Rate controls
-------------------------------------------------------------------------------
local function product_list(stats)
  local list = {}
  for _, p in ipairs(stats and stats.products or {}) do list[#list + 1] = { type = p.type, name = p.name } end
  return list
end

local function product_items(list)
  local items = {}
  for i, key in ipairs(list) do
    local ic = icon(key)
    items[i] = { "", ic ~= "" and (ic .. " ") or "", key_name(key) }
  end
  return items
end

local function rate_info_caption(entity, cfg)
  local e = L.get_entry(entity)
  if not e then return "" end
  if e.rate_missing then return { "rl.rate-missing" } end
  if e.max_rate then
    return { "rl.rate-info", L.format_num(e.applied_pct or 100, 2), fmt_rate(e.max_rate, cfg.product, cfg.unit == "min") }
  end
  return ""
end

local function build_rate_controls(parent, entity, cfg, stats)
  local list = product_list(stats)
  local idx = 1
  for i, key in ipairs(list) do if same_key(key, cfg.product) then idx = i end end
  local prow = parent.add({ type = "flow", name = "rl_product_row", direction = "horizontal" })
  prow.style.vertical_align = "center"
  prow.add({ type = "label", caption = { "rl.product" } })
  local dd = prow.add({ type = "drop-down", name = "rl_product", items = product_items(list), selected_index = #list > 0 and idx or 0 })
  dd.style.horizontally_stretchable = true
  dd.tags = { keys = list }

  local key = cfg.product or list[1]
  local units = units_for(key)
  local unit = cfg.unit
  local uidx = 1
  for i, u in ipairs(units) do if u == unit then uidx = i end end
  unit = units[uidx]
  local rrow = parent.add({ type = "flow", name = "rl_rate_row", direction = "horizontal" })
  rrow.style.vertical_align = "center"
  local field = rrow.add({
    type = "textfield", name = "rl_rate", text = L.format_num(to_unit(cfg.rate or 0, unit), 6),
    numeric = true, allow_decimal = true, allow_negative = false, lose_focus_on_confirm = true,
    tooltip = { "rl.rate-tooltip" },
  })
  field.style.width = 100
  field.style.horizontal_align = "center"
  local unit_items = {}
  for i, u in ipairs(units) do unit_items[i] = unit_caption(u) end
  local udd = rrow.add({ type = "drop-down", name = "rl_unit", items = unit_items, selected_index = uidx })
  udd.tags = { units = units }
  local info = parent.add({ type = "label", name = "rl_rate_info", caption = rate_info_caption(entity, cfg) })
  info.style.single_line = false
  info.style.maximal_width = 290
end

-------------------------------------------------------------------------------
-- Entity panel
-------------------------------------------------------------------------------
local function info_caption(entity)
  if types.is_ghost(entity) then return { "rl.info-ghost" } end
  local e = L.get_entry(entity)
  local info = e and e.info
  if not info or info.kind == "full" then return { "rl.info-full" } end
  if info.kind == "stopped" then return { "rl.info-stopped" } end
  if info.kind == "unsupported" then return { "rl.info-unsupported" } end
  if info.kind == "effect" then return { "rl.info-effect", G.fmt_amount(info.speed), G.fmt_amount(info.power) } end
  if info.kind == "mixed" then return { "rl.info-mixed", G.fmt_amount(info.speed), fmt_share(info.d) } end
  return { "rl.info-duty", fmt_share(info.d) }
end

local function circuit_caption(entity, cfg)
  if not (cfg.circuit and cfg.circuit.enabled) then return "" end
  if types.is_ghost(entity) then return { "rl.circuit-ghost" } end
  local e = L.get_entry(entity)
  if e and e.circuit_value ~= nil then
    if cfg.mode == "rate" then
      return { "rl.circuit-value-rate", fmt_rate(L.signal_to_rate(e.circuit_value, cfg.product), cfg.product, false) }
    end
    return { "rl.circuit-value", L.format_num(L.clamp_pct(e.circuit_value), 2) }
  end
  return { "rl.circuit-none" }
end

-- Lines of the reference block: output, input, fuel, power, pollution at the current limit.
local function fill_stats(flow, entity, per_minute)
  flow.clear()
  local stats, p = L.stats(entity)
  if not stats then
    flow.add({ type = "label", caption = { "rl.stats-ghost" } })
    return
  end
  local function line(caption)
    local l = flow.add({ type = "label", caption = caption })
    l.style.single_line = false
    l.style.maximal_width = 290
    return l
  end
  local function list(title, entries)
    if #entries == 0 then return end
    line({ "", "[font=default-semibold]", title, "[/font]" })
    for _, x in ipairs(entries) do
      local ic = icon(x)
      local cap = { "", "    ", ic ~= "" and (ic .. " ") or "", key_name(x), ": ", fmt_rate(x.rate * p, x, per_minute) }
      if p < 1 - 1e-9 then cap = { "", cap, "  ", { "rl.stats-max", fmt_rate(x.rate, x, per_minute) } } end
      line(cap)
    end
  end
  list({ "rl.stats-output" }, stats.products)
  list({ "rl.stats-input" }, stats.ingredients)
  if stats.fuel then
    local key = { type = "item", name = stats.fuel.name }
    line({ "", "[font=default-semibold]", { "rl.stats-fuel" }, "[/font] ", icon(key), " ", fmt_rate(stats.fuel.rate * p, key, per_minute) })
  end
  if stats.power then
    line({ "", "[font=default-semibold]", { "rl.stats-power-" .. stats.power.kind }, "[/font] ", G.fmt_watts(stats.power.watts * p) })
  end
  for _, pol in ipairs(stats.pollution) do
    local ok, name = pcall(function() return prototypes.airborne_pollutant[pol.name].localised_name end)
    line({ "", "[font=default-semibold]", { "rl.stats-pollution" }, "[/font] ", (ok and name) or pol.name, ": ",
      G.fmt_amount(pol.per_minute * p), "/min" })
  end
  if #flow.children == 0 then line({ "rl.stats-none" }) end
end

local function fill_panel(frame, player, entity)
  local cfg = L.get_config(entity)
  local ghost = types.is_ghost(entity)
  local stats = (not ghost) and L.stats(entity) or nil
  local has_products = stats and #stats.products > 0
  local inner = frame.add({ type = "frame", name = "rl_inner", direction = "vertical", style = "inside_shallow_frame_with_padding" })
  inner.style.maximal_width = 320

  local mode = cfg.mode
  if mode == "rate" and ghost then
    local key = cfg.product
    local l = inner.add({ type = "label", name = "rl_ghost_rate", caption = { "rl.ghost-rate", icon(key) .. " ", key_name(key), render.rate_text(cfg) } })
    l.style.single_line = false
  end
  if not ghost then
    local mflow = inner.add({ type = "flow", name = "rl_mode", direction = "horizontal" })
    mflow.add({ type = "radiobutton", name = "rl_mode_percent", caption = { "rl.mode-percent" }, state = mode ~= "rate" })
    local rb = mflow.add({ type = "radiobutton", name = "rl_mode_rate", caption = { "rl.mode-rate" }, state = mode == "rate",
      tooltip = has_products and { "rl.mode-rate-tooltip" } or { "rl.mode-rate-none" } })
    rb.enabled = has_products or mode == "rate"
  end
  if mode == "rate" and not ghost then
    build_rate_controls(inner, entity, cfg, stats)
  else
    build_value_controls(inner, cfg.pct)
  end

  local info = inner.add({ type = "label", name = "rl_info", caption = info_caption(entity) })
  info.style.single_line = false
  info.style.maximal_width = 290
  local warn = inner.add({ type = "label", name = "rl_warn", caption = { "rl.info-partial" } })
  warn.style.single_line = false
  warn.style.maximal_width = 290
  warn.style.font_color = { 1, 0.6, 0.3 }
  local e = L.get_entry(entity)
  warn.visible = (e and e.info and e.info.partial) == true

  if can_wire(entity) then
    inner.add({ type = "line", direction = "horizontal" })
    local enabled = cfg.circuit and cfg.circuit.enabled or false
    inner.add({ type = "checkbox", name = "rl_circuit", caption = { "rl.circuit" },
      tooltip = mode == "rate" and { "rl.circuit-tooltip-rate" } or { "rl.circuit-tooltip" }, state = enabled })
    local flow = inner.add({ type = "flow", name = "rl_signal_row", direction = "horizontal" })
    flow.style.vertical_align = "center"
    flow.add({ type = "label", caption = { "rl.circuit-signal" } })
    local signal = cfg.circuit and cfg.circuit.signal or { type = "virtual", name = "signal-S" }
    flow.add({ type = "choose-elem-button", name = "rl_signal", elem_type = "signal", signal = signal })
    local lbl = inner.add({ type = "label", name = "rl_circuit_info", caption = circuit_caption(entity, cfg) })
    lbl.style.single_line = false
    lbl.style.maximal_width = 290
  end

  -- reference block
  local ps = pstate(player)
  inner.add({ type = "line", direction = "horizontal" })
  local head = inner.add({ type = "flow", name = "rl_stats_head", direction = "horizontal" })
  head.style.vertical_align = "center"
  head.add({ type = "label", caption = { "rl.stats-title" }, style = "caption_label" })
  local filler = head.add({ type = "empty-widget" })
  filler.style.horizontally_stretchable = true
  local ub = head.add({ type = "button", name = "rl_stats_unit", caption = ps.per_minute and "/min" or "/s", tooltip = { "rl.stats-unit-tooltip" } })
  ub.style.minimal_width = 0
  ub.style.width = 48
  ub.style.height = 24
  ub.style.padding = 0
  local sflow = inner.add({ type = "flow", name = "rl_stats", direction = "vertical" })
  sflow.style.vertical_spacing = 0
  fill_stats(sflow, entity, ps.per_minute)
end

local function panels(player)
  local list = {}
  for _, child in pairs(player.gui.relative.children) do
    if child.name:sub(1, #PANEL_PREFIX) == PANEL_PREFIX then list[#list + 1] = child end
  end
  return list
end

function G.close_entity(player)
  for _, p in ipairs(panels(player)) do p.destroy() end
  pstate(player).opened = nil
end

function G.gui_names(entity_type)
  return types.GUI[entity_type] or { "entity_with_energy_source_gui" }
end

function G.open_entity(player, entity)
  G.close_entity(player)
  if not types.is_supported(entity) then return end
  -- fresh numbers (recipe, modules, fuel may have changed)
  local e = L.get_entry(entity)
  if e then L.apply(e) end
  local names = G.gui_names(types.real_type(entity))
  local created = 0
  for i, gname in ipairs(names) do
    local gt = defines.relative_gui_type[gname]
    if gt then
      local frame = player.gui.relative.add({
        type = "frame", name = PANEL_PREFIX .. i, direction = "vertical", caption = { "rl.panel-title" },
        anchor = { gui = gt, position = defines.relative_gui_position.right, names = { types.real_name(entity) }, ghost_mode = "both" },
      })
      fill_panel(frame, player, entity)
      created = created + 1
    end
  end
  if created > 0 then pstate(player).opened = entity end
end

local function rebuild(player)
  local ent = pstate(player).opened
  if ent and ent.valid then G.open_entity(player, ent) else G.close_entity(player) end
end

local function refresh_panel(player, frame, entity)
  local inner = frame.rl_inner
  if not inner then return end
  local cfg = L.get_config(entity)
  local built_rate = inner.rl_rate_row ~= nil
  if built_rate ~= (cfg.mode == "rate" and not types.is_ghost(entity)) then
    return true -- mode changed: needs a rebuild
  end
  if built_rate then
    -- products may have changed with the recipe
    local list = product_list(L.stats(entity))
    local dd = inner.rl_product_row.rl_product
    local old = dd.tags and dd.tags.keys or {}
    local changed = #old ~= #list
    if not changed then for i = 1, #list do if not same_key(old[i], list[i]) then changed = true end end end
    if changed then return true end
    local unit = cfg.unit
    local units = inner.rl_rate_row.rl_unit.tags.units
    local shown = unit
    if not (unit == units[1] or unit == units[2]) then shown = units[1] end
    local cur = tonumber(inner.rl_rate_row.rl_rate.text)
    local want = to_unit(cfg.rate or 0, shown)
    if cur == nil or math.abs(cur - want) > 1e-9 * math.max(1, math.abs(want)) then
      inner.rl_rate_row.rl_rate.text = L.format_num(want, 6)
    end
    inner.rl_rate_info.caption = rate_info_caption(entity, cfg)
  else
    set_value_controls(inner, cfg.pct, true)
  end
  inner.rl_info.caption = info_caption(entity)
  local e = L.get_entry(entity)
  inner.rl_warn.visible = (e and e.info and e.info.partial) == true
  if inner.rl_circuit then
    inner.rl_circuit.state = (cfg.circuit and cfg.circuit.enabled) or false
    if cfg.circuit and cfg.circuit.signal then inner.rl_signal_row.rl_signal.elem_value = cfg.circuit.signal end
    inner.rl_circuit_info.caption = circuit_caption(entity, cfg)
  end
  if inner.rl_stats then fill_stats(inner.rl_stats, entity, pstate(player).per_minute) end
  return false
end

-- Update the panels of every player who has this machine open.
function G.refresh_unit(unit)
  for _, player in pairs(game.players) do
    local ps = storage.players and storage.players[player.index]
    local ent = ps and ps.opened
    if ent then
      if not ent.valid then
        G.close_entity(player)
      elseif ent.unit_number == unit then
        local need = false
        for _, frame in ipairs(panels(player)) do
          if refresh_panel(player, frame, ent) then need = true end
        end
        if need then rebuild(player) end
      end
    end
  end
end

-------------------------------------------------------------------------------
-- Selection tool dialog
-------------------------------------------------------------------------------
function G.close_mass(player)
  local f = player.gui.screen[MASS]
  if f then f.destroy() end
  pstate(player).pending = nil
end

function G.open_mass(player, entities)
  G.close_mass(player)
  local ps = pstate(player)
  ps.pending = entities
  local frame = player.gui.screen.add({ type = "frame", name = MASS, direction = "vertical" })
  local bar = frame.add({ type = "flow", name = "rl_bar", direction = "horizontal" })
  bar.drag_target = frame
  bar.add({ type = "label", caption = { "rl.mass-title" }, style = "frame_title", ignored_by_interaction = true })
  local filler = bar.add({ type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true })
  filler.style.horizontally_stretchable = true
  filler.style.height = 24
  filler.style.minimal_width = 24
  bar.add({ type = "sprite-button", name = "rl_mass_close", sprite = "utility/close", style = "frame_action_button" })

  local inner = frame.add({ type = "frame", name = "rl_inner", direction = "vertical", style = "inside_shallow_frame_with_padding" })
  inner.add({ type = "label", name = "rl_count", caption = { "rl.mass-count", #entities } })
  build_value_controls(inner, ps.mass_pct or 50)
  local hint = inner.add({ type = "label", caption = { "rl.mass-hint" } })
  hint.style.single_line = false
  hint.style.maximal_width = 300

  local buttons = frame.add({ type = "flow", name = "rl_buttons", direction = "horizontal" })
  buttons.style.top_padding = 8
  local f2 = buttons.add({ type = "empty-widget" })
  f2.style.horizontally_stretchable = true
  buttons.add({ type = "button", name = "rl_mass_cancel", caption = { "rl.mass-cancel" } })
  buttons.add({ type = "button", name = "rl_mass_apply", caption = { "rl.mass-apply" }, style = "confirm_button" })
  frame.force_auto_center()
  player.opened = frame
end

function G.apply_mass(player)
  local ps = pstate(player)
  local pct = ps.mass_pct or 100
  local n = 0
  for _, ent in pairs(ps.pending or {}) do
    if types.is_supported(ent) then
      L.set_pct(ent, pct)
      n = n + 1
    end
  end
  player.create_local_flying_text({ text = { "rl.mass-done", n, L.format_num(pct, 2) }, create_at_cursor = true })
  G.close_mass(player)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
local function root_of(element)
  local el = element
  while el do
    local name = el.name
    if name == MASS or name:sub(1, #PANEL_PREFIX) == PANEL_PREFIX then return el end
    el = el.parent
  end
  return nil
end

local function opened_entity(player)
  local ent = pstate(player).opened
  if ent and ent.valid then return ent end
  G.close_entity(player)
  return nil
end

local function on_value(player, element, pct)
  pct = L.clamp_pct(pct)
  if not pct then return end
  local root = root_of(element)
  if not root then return end
  local ps = pstate(player)
  if root.name == MASS then
    ps.mass_pct = pct
    set_value_controls(root.rl_inner, pct, element.name == "rl_text")
    return
  end
  local ent = opened_entity(player)
  if not ent then return end
  L.set_pct(ent, pct)
  -- set_config notifies refresh_unit, which keeps the number the player is typing
end

-- Current values of the rate controls of a panel: product key, unit.
local function rate_controls(root)
  local inner = root.rl_inner
  local dd = inner.rl_product_row.rl_product
  local keys = dd.tags and dd.tags.keys or {}
  local product = keys[dd.selected_index]
  local udd = inner.rl_rate_row.rl_unit
  local unit = udd.tags.units[udd.selected_index] or udd.tags.units[1]
  return product, unit
end

function G.on_value_changed(event)
  local el = event.element
  if not (el and el.valid and el.name == "rl_slider") then return end
  local player = game.get_player(event.player_index)
  on_value(player, el, el.slider_value)
  local root = root_of(el)
  if root then root.rl_inner.rl_row.rl_text.text = L.format_pct(el.slider_value) end
end

function G.on_text_changed(event)
  local el = event.element
  if not (el and el.valid) then return end
  local player = game.get_player(event.player_index)
  if el.name == "rl_text" then
    local v = tonumber(el.text)
    if v then on_value(player, el, v) end
  elseif el.name == "rl_rate" then
    local v = tonumber(el.text)
    local root = root_of(el)
    local ent = opened_entity(player)
    if not (v and root and ent) then return end
    local product, unit = rate_controls(root)
    if product then L.set_rate(ent, product, from_unit(math.max(0, v), unit), unit) end
  end
end

function G.on_confirmed(event)
  local el = event.element
  if not (el and el.valid) then return end
  local player = game.get_player(event.player_index)
  local root = root_of(el)
  if not root then return end
  if root.name == MASS then
    if el.name == "rl_text" then G.apply_mass(player) end
    return
  end
  local ent = opened_entity(player)
  if not ent then return end
  local cfg = L.get_config(ent)
  if el.name == "rl_text" then
    el.text = L.format_pct(cfg.pct)
  elseif el.name == "rl_rate" then
    local _, unit = rate_controls(root)
    el.text = L.format_num(to_unit(cfg.rate or 0, unit), 6)
  end
end

function G.on_click(event)
  local el = event.element
  if not (el and el.valid) then return end
  local player = game.get_player(event.player_index)
  local name = el.name
  if name == "rl_mass_close" or name == "rl_mass_cancel" then
    G.close_mass(player)
  elseif name == "rl_mass_apply" then
    G.apply_mass(player)
  elseif name == "rl_stats_unit" then
    local ps = pstate(player)
    ps.per_minute = not ps.per_minute
    rebuild(player)
  else
    local v = name:match("^rl_preset_(%d+)$")
    if v then
      on_value(player, el, tonumber(v))
      local root = root_of(el)
      if root and root.name == MASS then set_value_controls(root.rl_inner, tonumber(v), false) end
    end
  end
end

local function switch_mode(player, to_rate)
  local ent = opened_entity(player)
  if not ent then return end
  local cfg = L.get_config(ent)
  if to_rate == (cfg.mode == "rate") then return end
  local stats, p = L.stats(ent)
  if to_rate then
    -- start from what the machine makes now, so switching does not change anything
    local list = product_list(stats)
    local key = list[1]
    if cfg.product then for _, k in ipairs(list) do if same_key(k, cfg.product) then key = k end end end
    if not key then rebuild(player); return end
    local max = rates.product_rate(stats, key) or 0
    local unit = units_for(key)[1]
    if rates.is_energy(key.type) and max * p >= 1e6 then unit = "MW" end
    L.set_rate(ent, key, max * p, unit)
  else
    local e = L.get_entry(ent)
    L.set_pct(ent, e and e.applied_pct or cfg.pct or 100)
  end
  rebuild(player)
end

function G.on_checked(event)
  local el = event.element
  if not (el and el.valid) then return end
  local player = game.get_player(event.player_index)
  if el.name == "rl_mode_percent" then
    switch_mode(player, false)
    return
  elseif el.name == "rl_mode_rate" then
    switch_mode(player, true)
    return
  end
  if el.name ~= "rl_circuit" then return end
  local ent = opened_entity(player)
  if not ent then return end
  local cfg = L.get_config(ent)
  local root = root_of(el)
  local signal = root and root.rl_inner.rl_signal_row.rl_signal.elem_value
  cfg.circuit = { enabled = el.state, signal = signal or (cfg.circuit and cfg.circuit.signal) or { type = "virtual", name = "signal-S" } }
  L.set_config(ent, cfg)
end

function G.on_selection_changed(event)
  local el = event.element
  if not (el and el.valid) then return end
  if el.name ~= "rl_product" and el.name ~= "rl_unit" then return end
  local player = game.get_player(event.player_index)
  local ent = opened_entity(player)
  local root = root_of(el)
  if not (ent and root) then return end
  local cfg = L.get_config(ent)
  local product, unit = rate_controls(root)
  if not product then return end
  if el.name == "rl_product" then
    if same_key(product, cfg.product) then return end
    -- new product: start from its current output
    local stats, p = L.stats(ent)
    local max = rates.product_rate(stats, product) or 0
    local u = units_for(product)
    unit = u[1]
    if rates.is_energy(product.type) and max * p >= 1e6 then unit = "MW" end
    L.set_rate(ent, product, max * p, unit)
    rebuild(player)
  else
    -- same rate, shown in another unit
    L.set_rate(ent, product, cfg.rate or 0, unit)
    root.rl_inner.rl_rate_row.rl_rate.text = L.format_num(to_unit(cfg.rate or 0, unit), 6)
  end
end

function G.on_elem_changed(event)
  local el = event.element
  if not (el and el.valid and el.name == "rl_signal") then return end
  local player = game.get_player(event.player_index)
  local ent = opened_entity(player)
  if not ent then return end
  local cfg = L.get_config(ent)
  local enabled = cfg.circuit and cfg.circuit.enabled or false
  cfg.circuit = { enabled = enabled and el.elem_value ~= nil, signal = el.elem_value }
  L.set_config(ent, cfg)
end

function G.on_closed_element(event)
  local el = event.element
  if el and el.valid and el.name == MASS then
    G.close_mass(game.get_player(event.player_index))
  end
end

return G
