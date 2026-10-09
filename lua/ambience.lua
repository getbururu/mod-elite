-- The continuous feels that follow the ship's state, and the reboot feel.
-- Most are layer rules in rules/ambience.rules.json (stages ship_ambience,
-- planet, thargoid, damage), which main.lua runs in order. The layers
-- here bend their voices with opts.add, which rules cannot do yet, so
-- they stay Lua; each runs next to its stage.

local state = require("state")
local lib = require("lib")
local clock = require("clock")

local M = {}
local S = bururu.state

S.reboot_for = clock.NEVER -- the shutdown whose reboot was played

-- the helpers the ambience layers' expressions call

-- in_srv: in the SRV (s may be nil)
function lib.in_srv(s)
  return (s or state.zero).flags.InSRV == true
end

local function smooth(x)
  return x * x * (3 - 2 * x)
end

-- hyperspace_swell: s seconds into the hyperspace tunnel, the swell's
-- level. It rises for half a second and dies away by 2.5 s.
function lib.hyperspace_swell(s)
  if s < 0 or s >= 2.5 then
    return 0
  elseif s < 0.5 then
    return smooth(s / 0.5)
  end
  return 1 - smooth((s - 0.5) / 2)
end

-- reboot plays the reboot feel once per shutdown, as the systems come back,
-- first in the tick
function M.reboot(t)
  if state.shutdown_phase(t.now) == "rebooting" and S.reboot_for ~= S.shutdown_at then
    S.reboot_for = S.shutdown_at
    feel.play("systems_reboot")
  end
end

-- ground_rush is the planet ambience's last part, after the planet stage (the
-- glide): the ground rushing up when dropping fast near the surface
function M.ground_rush(t)
  local st = S.status
  if not state.in_ship(st) or st.flags2.GlideMode then
    return
  end
  local alt, rate, ok = state.descent(t.now)
  if ok and not state.parked(st) and alt < 2500 and rate > 15 then
    local near = 1 - alt / 2500
    local level = gomath.min(1, (rate - 15) / 120) * (0.35 + 0.65 * near)
    feel.layer("ground_rush", "ground_rush", level, { add = { f0_hz = 90 * near, trem_hz = 5 * near } })
  end
end

-- damage is the damage ambience up to its last layer, before the damage stage
-- (the shields offline): from the HUD, low shields crackling and a weak
-- hull creaking
function M.damage(t)
  local st = S.status
  if not state.in_ship(st) or state.parked(st) then
    return
  end
  local hs = sensors.hud
  if st.flags.ShieldsUp and hs ~= nil then
    local shield = hs.shield
    if kit.fresh(shield, t.now, 3000) and shield.value <= 40 then
      local p = (40 - shield.value) / 40
      feel.layer("shield_low", "shield_low", 0.15 + 0.5 * p, { add = { gate_hz = 12 * p } })
    end
  end
  if st.flags.Supercruise or st.flags.FSDJump then
    return
  end
  if hs ~= nil then
    local hull = hs.hull
    if kit.fresh(hull, t.now, 5000) and hull.value <= 30 then
      local p = (30 - hull.value) / 30
      feel.layer("hull_creak", "hull_creak", 0.2 + 0.6 * p, { add = { f0_hz = 25 * p, trem_hz = 0.9 * p } })
    end
  end
end

-- debug adds the reboot's shutdown to the state table (state.debug)
function M.debug(d, t)
  d.reboot_for = S.reboot_for
end

state.debug_part(M.debug)

return M
