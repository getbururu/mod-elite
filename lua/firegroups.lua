-- What each trigger fires (the fire_groups setting, else what the HUD
-- showed for this fire group, else a guess from the loadout), how much of
-- it is still firing, and the fire group lists learned from the HUD. A
-- trigger's side is "l2" (the HUD's secondary list) or "r2" (the
-- primary). The learned lists live in bururu.state.fire_lists: by fire
-- key, {l2 = list, r2 = list}, each list as the HUD snapshot's fire_lists
-- entry had it: plain is true when its classes are utilities, bare counts
-- the weapons without ammo, counted the weapons with ammo in the last
-- read and busy those of them reloading.

local clock = require("clock")

local M = {}
local S = bururu.state

-- the lists in the HUD's order: secondary, then primary
local SIDES = { "l2", "r2" }
local TRIGGER_WORDS = { l2 = "L2 (secondary)", r2 = "R2 (primary)" }

-- key identifies what a list shows: the fire group and whether the
-- hardpoints are out
function M.key(st)
  local k = st.FireGroup * 2
  if st.flags.HardpointsDeployed then
    k = k + 1
  end
  return k
end

-- guess: the most common weapon class on R2, the next on L2; ties go to
-- the bigger weapon, then to the slot order
local function guess()
  local count, biggest, order = {}, {}, {}
  for _, m in ipairs(S.modules) do
    if not m.utility then
      local c = m.class
      if count[c] == nil then
        count[c], biggest[c] = 0, 0
        order[#order + 1] = c
      end
      count[c] = count[c] + 1
      if m.size > biggest[c] then
        biggest[c] = m.size
      end
    end
  end
  if #order == 0 then
    return { "generic" }, { "generic" }
  elseif #order == 1 then
    return { order[1] }, { order[1] }
  end
  -- a stable insertion sort, as sort.SliceStable
  for i = 2, #order do
    local c, j = order[i], i - 1
    while j >= 1 do
      local o = order[j]
      local before
      if count[c] ~= count[o] then
        before = count[c] > count[o]
      else
        before = biggest[c] > biggest[o]
      end
      if not before then
        break
      end
      order[j + 1] = o
      j = j - 1
    end
    order[j + 1] = c
  end
  return { order[1] }, { order[2] }
end

-- sets returns what each trigger fires now: {l2 = set, r2 = set}, a set
-- being {classes = {...}, utility = bool}. settings are the
-- mod's values (fire_groups).
function M.sets(settings)
  local st = S.status
  local primary, secondary = guess()
  local sets = { l2 = { classes = secondary, utility = false }, r2 = { classes = primary, utility = false } }
  local lists = S.fire_lists[M.key(st)]
  if lists then
    for _, side in ipairs(SIDES) do
      local l = lists[side]
      if l and l.known then
        sets[side] = { classes = l.classes, utility = l.plain }
      end
    end
  end
  local groups = settings and settings.fire_groups
  local fg = type(groups) == "table" and groups[tostring(st.FireGroup + 1)]
  if type(fg) == "table" then
    for _, side in ipairs(SIDES) do
      local class = fg.secondary
      if side == "r2" then
        class = fg.primary
      end
      if type(class) == "string" and class ~= "" and class ~= "auto" then
        sets[side] = { classes = { class }, utility = false }
      end
    end
  end
  return sets
end

-- share: for a trigger's list, from a fresh HUD read, the part of its
-- weapons still firing (1 = all, 0 = all reloading)
function M.share(side, now)
  local hs = sensors.hud
  local read = hs and hs.fire_lists[side]
  if read == nil or read.at == 0 or clock.since(now, read.at) > 1500000000 or read.busy == 0 then
    return 1
  end
  local total = read.counted
  local lists = S.fire_lists[M.key(S.status)]
  if lists and lists[side] and lists[side].known then
    total = total + lists[side].bare
  end
  if total <= 0 then
    return 1
  end
  return gomath.max(0, 1 - read.busy / total)
end

-- same_names: the same modules, in any order
local function same_names(a, b)
  if #a ~= #b then
    return false
  end
  local x, y = {}, {}
  for i = 1, #a do
    x[i], y[i] = a[i], b[i]
  end
  table.sort(x)
  table.sort(y)
  for i = 1, #x do
    if x[i] ~= y[i] then
      return false
    end
  end
  return true
end

-- list_text is a list as the log shows it: "BEAM LASER x2, HEATSINK"
local function list_text(l)
  local parts = {}
  for i, n in ipairs(l.names) do
    parts[i] = n
    local c = l.counts[i] or 0
    if c > 1 then
      parts[i] = n .. " x" .. tostring(c)
    end
  end
  return table.concat(parts, ", ")
end

-- the screen snapshot learned last: each Take makes a new one
local learned

-- learn keeps what the HUD showed for each fire group, once per screen
-- reading (LearnFireLists). A list is logged when its modules change:
-- counts can flicker with a missed entry.
function M.learn()
  local hs = sensors.hud
  if hs == nil or hs == learned then
    return
  end
  learned = hs
  for _, side in ipairs(SIDES) do
    local l = hs.fire_lists[side]
    if l.known then
      local lists = S.fire_lists[l.key]
      if lists == nil then
        lists = {}
        S.fire_lists[l.key] = lists
      end
      local old = lists[side]
      lists[side] = l
      if not same_names(old and old.names or {}, l.names) then
        local hardpoints = "hardpoints out"
        if gomath.mod(l.key, 2) == 0 then
          hardpoints = "hardpoints in"
        end
        log.info("Fire group " .. tostring(gomath.trunc(l.key / 2) + 1) .. ", " .. hardpoints .. ": "
          .. TRIGGER_WORDS[side] .. " fires " .. list_text(l) .. " (read from the HUD)")
      end
    end
  end
end

-- set_text is a fire set as "beam,pulse", or "u:heatsink" for utilities
function M.set_text(s)
  local t = table.concat(s.classes, ",")
  if s.utility then
    t = "u:" .. t
  end
  return t
end

-- known_text is a learned list's classes, "-" when unknown
local function known_text(l)
  if l == nil or not l.known then
    return "-"
  end
  return M.set_text(l)
end

-- lists_text is the learned lists by key: "3:l2=beam|r2=u:heatsink;5:..."
function M.lists_text()
  local keys = {}
  for k in pairs(S.fire_lists) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local parts = {}
  for i, k in ipairs(keys) do
    local lists = S.fire_lists[k]
    parts[i] = tostring(k) .. ":l2=" .. known_text(lists.l2) .. "|r2=" .. known_text(lists.r2)
  end
  return table.concat(parts, ";")
end

-- debug is the fire part of the state table (state.debug_part): what
-- each trigger fires, the learned lists and the firing shares
function M.debug(d, t)
  local sets = M.sets(t.settings)
  d["fire_set.r2"], d["fire_set.l2"] = M.set_text(sets.r2), M.set_text(sets.l2)
  d.fire_lists = M.lists_text()
  d["firing_share.r2"], d["firing_share.l2"] = M.share("r2", t.now), M.share("l2", t.now)
end

return M
