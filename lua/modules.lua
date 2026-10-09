-- The fire-groupable modules of a Loadout event: for the fire sets'
-- guess, the spin-up sizes, a refit that clears the learned lists, and
-- the entries the screen reader matches the fire group lists against
-- (hud.lua). The tables are data/modules.json.

local M = {}

local tables = data.get("modules")

-- by_order lists a table of entries keyed by item as {item, entry}, lowest
-- order first (ties by item), so the first match is the same
-- each time
local function by_order(t)
  local out = {}
  for item, e in pairs(t) do
    out[#out + 1] = { item = item, e = e }
  end
  table.sort(out, function(a, b)
    if a.e.order ~= b.e.order then
      return a.e.order < b.e.order
    end
    return a.item < b.item
  end)
  return out
end

local utility = by_order(tables.utility)
local weapon_names = by_order(tables.weapon_names)
local weapon_classes = by_order(tables.weapon_classes)

-- text is a string field of a decoded object, "" when it is none
local function text(m, key)
  local v = m[key]
  if type(v) == "string" then
    return v
  end
  return ""
end

-- weapon_class maps a Loadout item to the weapon class its feel is based
-- on
function M.weapon_class(item)
  local i = kit.lower(item)
  for _, r in ipairs(weapon_classes) do
    for _, part in ipairs(r.e.any) do
      if kit.contains(i, part) then
        return r.e.class
      end
    end
  end
  return tables.default_class
end

-- is_weapon_slot: hardpoints, without the utility mounts
local function is_weapon_slot(slot)
  return kit.contains(slot, "hardpoint") and not kit.has_prefix(slot, "tinyhardpoint")
end

local function slot_size(slot)
  for prefix, size in pairs(tables.slot_sizes) do
    if kit.has_prefix(slot, prefix) then
      return size
    end
  end
  return tables.default_size
end

-- fire_group_module is what a fire group shows for a slot and an item;
-- nil when the slot holds none
local function fire_group_module(slot, item)
  slot, item = kit.lower(slot), kit.lower(item)
  for _, u in ipairs(utility) do
    if kit.contains(item, u.item) then
      return { name = u.e.name, class = u.e.class, utility = true, ammo = false, size = 0 }
    end
  end
  if not is_weapon_slot(slot) then
    return nil
  end
  local bare = item
  if kit.has_prefix(bare, "hpt_") then
    bare = string.sub(bare, 5)
  end
  local name = string.upper(bare)
  for _, w in ipairs(weapon_names) do
    if kit.contains(item, w.item) then
      name = w.e.name
      break
    end
  end
  return { name = name, class = M.weapon_class(item), utility = false, ammo = false, size = slot_size(slot) }
end

-- of returns the fire-groupable modules of a Loadout event in slot order:
-- {name, class, utility, ammo, size}, and with ammo its "clip/reserve"
-- text as the fire group lists show it (ammo_text)
function M.of(ev)
  local out = {}
  local list = ev.Modules
  if type(list) ~= "table" then
    return out
  end
  for _, entry in ipairs(list) do
    if type(entry) ~= "table" then
      entry = {}
    end
    local m = fire_group_module(text(entry, "Slot"), text(entry, "Item"))
    if m then
      if type(entry.AmmoInClip) == "number" then
        local hopper = entry.AmmoInHopper
        if type(hopper) ~= "number" then
          hopper = 0
        end
        m.ammo = true
        m.ammo_text = tostring(gomath.trunc(entry.AmmoInClip)) .. "/" .. tostring(gomath.trunc(hopper))
      end
      out[#out + 1] = m
    end
  end
  return out
end

-- same: the same fire-groupable modules in the same slots
function M.same(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i].name ~= b[i].name or a[i].utility ~= b[i].utility then
      return false
    end
  end
  return true
end

return M
