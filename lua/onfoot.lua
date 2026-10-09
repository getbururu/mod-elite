-- On foot, a shot on each R2 press, repeating while held for automatic
-- weapons.
--
-- State, in bururu.state: last_shot (ns since the session started,
-- clock.NEVER before the first shot).

local state = require("state")
local clock = require("clock")

local M = {}
local S = bururu.state

S.last_shot = clock.NEVER

-- the weapon names (Status.json SelectedWeapon, lower case) that shoot no
-- shot, then those with a plasma, then a laser shot; any other weapon is
-- kinetic
local NO_SHOT = { "fists", "tool", "scanner", "cutter", "energylink" }
local PLASMA = { "plasma", "manticore", "executioner", "intimidator", "oppressor", "tormentor" }
local LASER = { "laser", "takada", "aphelion", "eclipse", "zenith", "tk_" }

-- the time between shots of a held trigger, ns
local PERIOD = { shot_kinetic = 125000000, shot_laser = 200000000, shot_plasma = 700000000 }

local function any_in(w, parts)
  for _, p in ipairs(parts) do
    if kit.contains(w, p) then
      return true
    end
  end
  return false
end

-- shot_of is the shot feel of an on-foot weapon; "" for tools and fists
local function shot_of(weapon)
  local w = ""
  if type(weapon) == "string" then
    w = kit.lower(weapon)
  end
  if w == "" or any_in(w, NO_SHOT) then
    return ""
  elseif any_in(w, PLASMA) then
    return "shot_plasma"
  elseif any_in(w, LASER) then
    return "shot_laser"
  end
  return "shot_kinetic"
end

-- tick: a shot on an R2 press, or again once the weapon's period passed
-- while R2 is held past 180
function M.tick(t, st, pad)
  local shot = shot_of(st.SelectedWeapon)
  if shot == "" then
    shot = "shot_kinetic"
  end
  if not pad.pressed.r2 and (pad.r2 <= 180 or clock.since(t.now, S.last_shot) < PERIOD[shot]) then
    return
  end
  if t.native then
    feel.play(shot, { side = "right" })
  else
    feel.play("onfoot_shot")
  end
  S.last_shot = t.now
end

-- the on-foot part of the state table (state.debug_part)
local function debug(d)
  d.last_shot = S.last_shot
end

state.debug_part(debug)

return M
