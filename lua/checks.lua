-- Elite's one-time log lines and the setup items of its schema
-- (setup.bindings, setup.deadzones), from the bindings sensor and the turn
-- stats.
--
-- It keeps in bururu.state:
--   told_raw_sticks  the raw sticks line was written
--   flight_ns        flight time counted for the gyro check
--   gyro_checked     the gyro check is done

local state   = require("state")
local turning = require("turning")
local clock = require("clock")

local M = {}
local S = bururu.state

local MINUTE = 60e9 -- ns of flight before the gyro check

S.told_raw_sticks, S.flight_ns, S.gyro_checked = false, 0, false

-- no_turn_dead_zone says which of roll and pitch are on a stick of the
-- controller with no dead zone in Elite: "your roll and pitch dead zones
-- are 0", "your pitch dead zone is 0"; "" when each one on a stick has a
-- dead zone, or without a custom preset
local function no_turn_dead_zone(b)
  local dz = b and b.deadzones
  if type(dz) ~= "table" then
    return ""
  end
  local zero = {}
  for _, axis in ipairs({ "roll", "pitch" }) do
    local v = dz[axis]
    if type(v) == "number" and v <= 0 then
      zero[#zero + 1] = axis
    end
  end
  if #zero == 0 then
    return ""
  elseif #zero == 1 then
    return "your " .. zero[1] .. " dead zone is 0"
  end
  return "your roll and pitch dead zones are 0"
end

-- on_check is the game:check handler, first of every process check:
-- once, that Elite reads the sticks raw while the ship preset gives
-- roll or pitch no dead zone, so a stick that rests a little off centre
-- turns the ship
function M.on_check(ev)
  if S.told_raw_sticks then
    return
  end
  local zero = no_turn_dead_zone(sensors.binds)
  if zero == "" then
    return
  end
  S.told_raw_sticks = true
  log.info("Bindings: Elite gets the sticks raw now; " .. zero .. "; set about 0.08 in Elite's controls if the ship drifts")
end

-- dead_zones is the dead zone item as the Controller page's check words
-- it: state and text
local function dead_zones(b)
  if b == nil or b.custom ~= true then
    return "warn", "Elite's dead zones are not known"
  end
  local zero = no_turn_dead_zone(b)
  if zero ~= "" then
    -- a note: it matters only if the sticks drift, which most do not
    return "ok", "Elite gets the sticks raw now; " .. zero .. ". Set about 0.08 in Elite's controls if the ship drifts"
  end
  -- %g: string.format prints the numbers as the app does
  local dz = type(b.deadzones) == "table" and b.deadzones or {}
  local roll, pitch = dz.roll, dz.pitch
  if type(roll) == "number" and type(pitch) == "number" then
    return "ok", string.format("Elite has dead zones on roll (%g) and pitch (%g)", roll, pitch)
  elseif type(roll) == "number" then
    return "ok", string.format("Elite has a dead zone on roll (%g)", roll)
  elseif type(pitch) == "number" then
    return "ok", string.format("Elite has a dead zone on pitch (%g)", pitch)
  end
  return "ok", "No stick of the controller rolls or pitches the ship"
end

-- on_binds is the binds:change handler: the setup items from the preset
-- read. bindings: a custom preset is read (the heat sink, chaff and shield
-- cell feels need one); deadzones: Elite's dead zones on roll and pitch.
-- Their words without a text are the schema's.
function M.on_binds(ev)
  local b = ev.new
  if b ~= nil and b.custom == true then
    setup.item("bindings", "ok")
  else
    setup.item("bindings", "warn")
  end
  setup.item("deadzones", dead_zones(b))
end

-- check_gyro is an on_tick handler, after the turn feel: once, after a
-- minute of flight while the gyro is held, whether gyro data reaches
-- Bururu (the turn feel needs it). While Bururu aims with the gyro, it
-- watches the motion itself.
function M.check_gyro(t)
  if not t.pad.ok then
    return
  end
  local st = S.status
  if not t.caps.motion or not t.core.gyro_aim or S.gyro_checked or not t.gyro.held or not state.in_ship(st)
      or state.parked(st) or state.in_panel(st) then
    return
  end
  S.flight_ns = S.flight_ns + t.core.poll_ms * 1e6
  if S.flight_ns <= MINUTE then
    return
  end
  local fastest, touched = turning.gyro_stats()
  if fastest < 1 then
    local hint = t.words.no_motion_hint -- the backend's words
    if hint ~= nil then
      log.info(hint)
    end
  else
    log.info("Gyro: OK (fastest turn %.0f deg/s, touchpad %s)", fastest, tostring(touched))
  end
  S.gyro_checked = true
end

-- silence is an on_idle handler: a restart that keeps the game (t.reason
-- "restart") starts the session's trigger times and the gyro check over, as
-- a new session does
function M.silence(t)
  if t.reason == "restart" then
    S.trigger_at, S.triggers_held = clock.NEVER, { l2 = false, r2 = false }
    S.flight_ns, S.gyro_checked = 0, false
  end
end

bururu.on_idle(M.silence) -- as the module loads: before main.lua's on_idle handlers, which read none of it

return M
