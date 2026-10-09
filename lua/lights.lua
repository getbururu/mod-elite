-- What the tables of lights.json read. The tables pick the lightbar, the
-- triggers, the player LEDs and the mic field by field; this module gives
-- them the hull colours and the game state's questions as lib helpers,
-- and keeps the one value a table must not work out again each frame: the
-- triggers' weapons-capacitor slack, which has hysteresis and changes only
-- when the triggers' switch reaches it. It lives in bururu.state.wep_slack.

local state = require("state")
local lib = require("lib")
local clock = require("clock")

local M = {}
local S = bururu.state

S.wep_slack = false

-- config.Color's answer for a key the colour table lacks
local WHITE = { 255, 255, 255 }

-- color is the colour of key in a colour table (the colors setting)
local function color(colors, key)
  local c = type(colors) == "table" and colors[key]
  if type(c) == "table" then
    return c
  end
  return WHITE
end

-- hull_rgb is the hull colour at h (1 is a full hull) from the colour
-- table colors: green at 1, amber at 0.5, red at 0.2 and below
function lib.hull_rgb(h, colors)
  local full, half, low = color(colors, "hull_full"), color(colors, "hull_half"), color(colors, "hull_low")
  if h >= 0.5 then
    return kit.mix(half, full, (h - 0.5) / 0.5)
  end
  return kit.mix(low, half, (h - 0.2) / 0.3)
end

-- hull_key is the colour key nearest to what hull_rgb mixes at h: full at
-- 1, half at 0.5, low at 0.2
function lib.hull_key(h)
  if h >= 0.75 then
    return "hull_full"
  elseif h >= 0.35 then
    return "hull_half"
  end
  return "hull_low"
end

-- health is the health on foot from a Status.json snapshot, 1 when it
-- gives none
function lib.health(s)
  local h = (s or state.zero).Health
  if type(h) == "number" then
    return h
  end
  return 1
end

-- hyperspace: a hyperspace jump counts down, or the ship is in the jump
function lib.hyperspace(t)
  local _, counting = state.hyperspace_countdown(t.now)
  return counting or S.status.flags.FSDJump == true
end

-- shields_down: in the ship with the shields down after they were seen up,
-- outside hyperspace and supercruise
function lib.shields_down(t)
  local st = S.status
  local f = st.flags
  return state.in_ship(st) and S.shields_seen and not f.ShieldsUp and not lib.hyperspace(t) and not f.Supercruise
end

-- situation_lights: neither on foot nor parked, where combat, fuel
-- scooping, silent running, the shields, the FSD charge, overheating and
-- interdiction show over the lightbar's base colour
function lib.situation_lights(s)
  return not state.on_foot(s) and not state.parked(s)
end

-- ship_weapons: in the ship, not parked, the hardpoints out and not in
-- analysis mode: the triggers follow the weapons
function lib.ship_weapons(s)
  local f = (s or state.zero).flags
  return state.in_ship(s) and not state.parked(s) and f.HardpointsDeployed == true and not f.AnalysisMode
end

-- reaches_slack: the triggers' switch gets to the capacitor test: no
-- shutdown frame, not in a panel, not on foot, not in the SRV, in the ship
-- and not parked, not interdicted, weapons out and not overheating
local function reaches_slack(st, now)
  local f = st.flags
  return state.shutdown_phase(now) == "none" and not state.in_panel(st) and not state.on_foot(st) and not f.InSRV
      and lib.ship_weapons(st) and not f.BeingInterdicted and not f.Overheating
end

-- values is the before_frame handler. The triggers go slack while firing
-- with the weapons capacitor empty, until it has refilled to 30% (no
-- flicker around empty); the hysteresis moves only on the frames whose
-- triggers reach it, as Renderer.slack.
function M.values(t)
  local st = S.status
  if not reaches_slack(st, t.now) then
    return
  end
  local hs = sensors.hud
  local caps = hs and hs.capacitors
  local fresh = caps ~= nil and kit.fresh(caps, t.now, 2000)
  if clock.since(t.now, S.fired_at) >= 2e9 or not fresh then
    S.wep_slack = false
  elseif S.wep_slack then
    S.wep_slack = caps.wep < 0.3
  else
    S.wep_slack = caps.wep <= 0.1 and (caps.sys > 0.15 or caps.eng > 0.15)
  end
end

-- debug is the lights' part of the state table (state.debug_part)
function M.debug(d, t)
  d.wep_slack = S.wep_slack and 1 or 0
end

return M
