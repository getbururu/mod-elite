-- The heat estimate and the heat feel.
-- Elite reports heat only above 100% (Overheating), so without the HUD the
-- heat is estimated (0-1.2) from what heats a ship: weapons fired, silent
-- running, fuel scooping. It cools otherwise, and is pinned to 100% while
-- the game says Overheating. A heat % read from the HUD replaces it.
--
-- The estimate lives in bururu.state.heat (rules read state.heat); a heat
-- sink takes it down through sink(). The heat feel bends its voice with
-- opts.add, which rules cannot do yet, so it stays Lua;
-- rules/heat.rules.json declares the "heat" stage right after it, for
-- layers of add-ons.

local state = require("state")

local M = {}
local S = bururu.state

S.heat = 0

-- tick runs once per active tick: weapons is the heat the
-- weapons add per second, by default bururu.state.heat_in, which
-- weapons.lua sets this tick (0 when not flying)
function M.tick(t, weapons)
  local st = S.status
  local f = st.flags
  local heat_in = weapons or S.heat_in or 0
  if state.in_ship(st) and not state.parked(st) then
    if f.SilentRunning then
      heat_in = heat_in + 0.08
    end
    if f.ScoopingFuel then
      heat_in = heat_in + 0.07
    end
  end
  local h = S.heat + (heat_in - 0.05) * t.dt
  if f.Overheating then
    h = gomath.max(h, 1)
  elseif h > 0.97 then
    h = 0.97
  end
  h = gomath.max(0, gomath.min(1.2, h))
  local hs = sensors.hud
  if hs ~= nil and kit.fresh(hs.heat, t.now, 2500) then
    h = gomath.min(1.5, hs.heat.value / 100)
    if f.Overheating then
      h = gomath.max(h, 1)
    end
  end
  S.heat = h
end

local function number(v, default)
  if type(v) == "number" then
    return v
  end
  return default
end

-- feel is the heat feel: a slow throb that speeds up and roughens as the ship
-- heats up. The heat@1 hook may change its level or p (how far up the
-- throb is, 0-1, which bends its voice), or skip it.
function M.feel(t)
  local st = S.status
  if not state.in_ship(st) or state.parked(st) or S.heat <= 0.4 then
    return
  end
  local p = gomath.min(1, (S.heat - 0.4) / 0.6)
  local level = 0.12 + 0.5 * gomath.pow(p, 1.3)
  local h = hook.run("heat@1", { heat = S.heat, p = p, level = level, skip = false })
  if h.skip == true then
    return
  end
  level, p = number(h.level, level), number(h.p, p)
  feel.layer("heat_build", "heat_build", level, { add = { f0_hz = 60 * p, trem_hz = 2.3 * p } })
end

-- sink is a heat sink taking the heat away (weapons.lua: the bound action
-- and the utility fired from a fire group)
function M.sink()
  S.heat = gomath.min(S.heat, 0.1)
end

-- silence is the idle tick's part: the estimate starts cold
function M.silence(t)
  S.heat = 0
end

-- debug adds the estimate to the state table (state.debug)
function M.debug(d, t)
  d.heat = S.heat
end

state.debug_part(M.debug)

return M
