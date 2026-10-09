-- The ship turning, from gyro aim or a stick bound to yaw, pitch or roll, is
-- felt only outside the throttle's blue zone (read from the HUD): in the
-- blue zone, where the ship turns best, nothing is felt. Outside it, as
-- turn_feel says: "waves", soft swells about every 2 s while the ship turns,
-- stronger the harder the turn; "push", a soft push when a turn starts,
-- changes or ends, and nothing while it holds; or "off". Both glide out
-- (slower with flight assist off, when the ship keeps rotating), and a
-- sudden flick of the controller adds a soft push. The actuators are smooth
-- around 170 Hz: lower tones are felt as a rattle, higher ones as a buzz,
-- and a steady tone of any pitch soon grates, so nothing here is steady.
--
-- Gyro aim reaches Elite as mouse movement, and Elite's mouse deflects a
-- virtual stick. With mouse decay off the deflection holds when the
-- controller stops: the ship keeps turning until the controller turns back
-- or MouseReset centres it. So the gyro part follows that virtual stick,
-- worked out from the controller's rotation, and a controller held tilted
-- is felt like a held stick. With decay on the virtual stick springs back,
-- and a gyro turn is felt while the controller moves. The gyro part pauses
-- while a finger rests on the touchpad, as the gyro aim does, and while
-- mouse headlook has the mouse, and is off with gyro aim off or when the
-- mouse turns nothing. In the hyperspace tunnel the ship does not turn, and
-- nothing is felt.
--
-- The state lives in bururu.state.turn (rules read state.turn.<field>):
--   gyro        smoothed controller rotation, deg/s
--   mouse       Elite's virtual mouse stick {x, y}, -1..1
--   amount      smoothed turn, 0-1
--   blue_zone   smoothed "throttle in the blue zone", 0-1
--   felt        the turn feel's level before a swell
--   phase       "waves": the swell's phase in cycles (0 is a crest)
--   swell       the swell level, eased so a restart does not click
--   vec         "push": the turn with its direction (the four stick axes,
--               then the virtual mouse X and Y)
--   settled     the same followed slowly; a push is the difference, so a
--               reversal is felt like a start
--   last_kick   the last flick (ns since the session started, clock.NEVER)
--   sticks      the stick axes (lx, ly, rx, ry) bound to yaw, pitch or roll
--   turns       the mouse axes (x, y) that turn the ship
--   holds       the mouse axes with decay off
--   headlook    the mouse moves the view
--   fastest     fastest controller rotation since the last gyro_stats
--   touched     the touchpad was touched since the last gyro_stats
--
-- Hook point turn@1 (scalars), before the turn feel plays, on every flying
-- tick the turn feel can play (native haptics, turn_feel not "off"):
--   mode    the player's turn_feel, "waves" or "push"; "off" plays nothing
--   feel    the voice: "maneuver_waves" or "maneuver_push"
--   level   the turn level 0-1 after the blue zone, flight assist and the
--           step back under one-shots and firing; the layer plays when > 0
--   swell   the swell the level is multiplied by (1 for "push")
--   kick    the flick's scale, 0 for none
--   amount, outside, fa_off: what the level was made of (read only)
-- A value of the wrong type keeps Elite's own; the turn's state is the same
-- whatever a handler does.

local state = require("state")
local clock = require("clock")

local M = {}
local S = bururu.state

-- the stick axes in order (LX, LY, RX, RY)
local STICKS = { "lx", "ly", "rx", "ry" }

-- MOUSE_FULL_TURN: the controller rotation, in degrees, that deflects the
-- virtual stick fully, with Bururu's gyro at sensitivity 1. A guess:
-- Elite does not say, and it depends on Elite's mouse sensitivity.
local MOUSE_FULL_TURN = 20.0
-- MOUSE_STILL: slower rotation, in deg/s, is a steady hand
local MOUSE_STILL = 2.0
-- MOUSE_SPRING: how fast a decaying virtual stick springs back, s
local MOUSE_SPRING = 0.25
-- MOUSE_FORGET: a held deflection fades over this, s, so the estimate does
-- not stay off for long when it went wrong (the reset key pressed while
-- Elite was not in front, the controller turned in the pause menu)
local MOUSE_FORGET = 30.0

-- a stick axis turns the ship past this dead zone
local DEADZONE = 0.12
local LIVE = 0.88 -- 1 - DEADZONE
local TWO_PI = 6.283185307179586 -- 2*pi

-- times in ns
local FIRING = 2e8 -- the turn steps back for 200 ms after a trigger fired
local KICK_GAP = 3e8 -- at most one flick in 300 ms

local function zeros(n)
  local t = {}
  for i = 1, n do
    t[i] = 0
  end
  return t
end

-- defaults: without bindings, the left stick turns the ship, and the mouse
-- turns it and springs back, so a gyro turn is felt while the controller
-- moves
S.turn = {
  gyro = 0, mouse = { 0, 0 }, amount = 0, blue_zone = 0, felt = 0,
  phase = 0, swell = 0, vec = zeros(6), settled = zeros(6),
  last_kick = clock.NEVER,
  sticks = { true, true, false, false }, turns = { true, true }, holds = { false, false },
  headlook = false, fastest = 0, touched = false,
}
local T = S.turn

-- the tick's turn with its direction, refilled by turn_vector
local now_vec = zeros(6)

-- reset_mouse: the mouse reset key centres the virtual stick
local function reset_mouse()
  T.mouse[1], T.mouse[2] = 0, 0
end

-- move_mouse moves the virtual mouse stick with the controller's rotation
-- (deg/s, sideways and up-down); full_x and full_y are the rotations, in
-- degrees, that deflect it fully
local function move_mouse(rx, ry, dt, full_x, full_y)
  local rates, full = { rx, ry }, { full_x, full_y }
  for i = 1, 2 do
    if not T.turns[i] then
      T.mouse[i] = 0
    else
      local r = rates[i]
      if gomath.abs(r) < MOUSE_STILL then
        r = 0
      end
      local back = MOUSE_SPRING
      if T.holds[i] then
        back = MOUSE_FORGET
      end
      T.mouse[i] = gomath.max(-1, gomath.min(1, T.mouse[i] * gomath.exp(-dt / back) + r * dt / full[i]))
    end
  end
end

-- mouse_turn: the virtual mouse stick's deflection as a turn amount (0-1).
-- What is left after turning back, a few degrees, is not felt: the estimate
-- is not that exact.
local function mouse_turn()
  return gomath.max(0, gomath.min(1, (gomath.hypot(T.mouse[1], T.mouse[2]) - 0.08) / 0.92))
end

-- stick_turn: the largest deflection of a stick axis that turns the ship
local function stick_turn(sticks)
  local best = 0
  for i = 1, 4 do
    if T.sticks[i] then
      best = gomath.max(best, (gomath.abs(sticks[STICKS[i]]) - DEADZONE) / LIVE)
    end
  end
  return gomath.min(1, best)
end

-- turn_vector: the turn with its direction, for "push": each stick axis
-- that turns the ship past its dead zone, and the virtual mouse stick
-- scaled to its turn amount
local function turn_vector(sticks)
  local v = now_vec
  for i = 1, 6 do
    v[i] = 0
  end
  for i = 1, 4 do
    if T.sticks[i] then
      local s = sticks[STICKS[i]]
      local a = gomath.max(0, (gomath.abs(s) - DEADZONE) / LIVE)
      v[i] = gomath.copysign(gomath.min(1, a), s)
    end
  end
  local h = gomath.hypot(T.mouse[1], T.mouse[2])
  if h > 0 then
    local m = mouse_turn()
    v[5], v[6] = T.mouse[1] / h * m, T.mouse[2] / h * m
  end
  return v
end

-- turn_level: silent when not turning, then felt from the start of a turn
-- and rising with it (0.12 at the start, about 0.3 at half, 0.45 at full),
-- under the combat effects
local function turn_level(x)
  if x < 0.02 then
    return 0
  end
  return (0.12 + 0.33 * gomath.pow(x, 0.9)) * gomath.min(1, (x - 0.02) / 0.04)
end

local function moving(list)
  for i = 1, #list do
    if list[i] ~= 0 then
      return true
    end
  end
  return false
end

-- stop: not flying; no kick on the first frames back. The virtual mouse
-- stick holds through menus and panels, as it does in Elite, and is
-- centred when the ship is left or parked.
local function stop(now, flying)
  if T.gyro > 0 or T.amount > 0 or moving(T.vec) or moving(T.settled) then
    T.gyro, T.amount, T.felt = 0, 0, 0
    for i = 1, 6 do
      T.vec[i], T.settled[i] = 0, 0
    end
    T.last_kick = now
  end
  T.phase, T.swell = 0, 0
  if not flying then
    reset_mouse()
  end
end

-- fired_lately: a weapon on either trigger fired within the last 200 ms
-- (weapons.lua keeps the times in bururu.state.weapons)
local function fired_lately(now)
  local w = S.weapons
  if w == nil then
    return false
  end
  return clock.since(now, w.r2.firing_at) < FIRING or clock.since(now, w.l2.firing_at) < FIRING
end

local function number_or(v, default)
  if type(v) == "number" then
    return v
  end
  return default
end

-- turning is the end of a flying tick
local function turning(t, fa_off)
  local p, dt, now, core = t.pad, t.dt, t.now, t.core
  local raw = p.aim_dps
  T.fastest = gomath.max(T.fastest, raw)
  -- yaw and a share of roll move the mouse sideways, as Bururu's gyro
  -- does; pitch moves it up and down
  local g = p.gyro_dps
  local rx, ry = g[2] + core.gyro_roll_mix * g[3], g[1]
  if not core.gyro_aim or (not T.turns[1] and not T.turns[2]) then
    raw, rx, ry = 0, 0, 0 -- flying with the sticks: moving the controller turns nothing
  end
  if p.touch then
    raw, rx, ry = 0, 0, 0
    T.touched = true
  end
  if T.headlook then
    raw, rx, ry = 0, 0, 0
  end
  local prev = T.gyro
  -- smoothed (0.1 s) to even out the hand's uneven speed
  T.gyro = T.gyro + (raw - T.gyro) * (1 - gomath.exp(-dt / 0.1))
  local accel = (T.gyro - prev) / dt -- deg/s per second
  move_mouse(rx, ry, dt, MOUSE_FULL_TURN / core.gyro_sensitivity_x, MOUSE_FULL_TURN / core.gyro_sensitivity_y)
  local _, tunnel = state.tunnel(now)
  if tunnel then
    stop(now, true) -- the virtual stick holds for the arrival
    return
  end

  local target = gomath.max(mouse_turn(), stick_turn(p.sticks))
  local tau = 0.15 -- eases in, glides out when the turn ends
  if target < T.amount and fa_off then
    tau = 1.5
  elseif target < T.amount then
    tau = 0.45
  end
  T.amount = T.amount + (target - T.amount) * (1 - gomath.exp(-dt / tau))
  local change = 0
  local v = turn_vector(p.sticks)
  for i = 1, 6 do
    T.vec[i] = T.vec[i] + (v[i] - T.vec[i]) * (1 - gomath.exp(-dt / tau))
    T.settled[i] = T.settled[i] + (T.vec[i] - T.settled[i]) * (1 - gomath.exp(-dt / 0.35))
    change = change + (T.vec[i] - T.settled[i]) * (T.vec[i] - T.settled[i])
  end
  -- a swell about every 2.2 s; a turn that starts, or grows much harder in
  -- a trough, brings the next crest forward
  local crest = 0.5 + 0.5 * gomath.cos(TWO_PI * T.phase)
  if T.amount < 0.02 or (target - T.amount > 0.15 and crest < 0.5) then
    T.phase, crest = 0, 1
  end
  T.phase = gomath.mod(T.phase + 0.45 * dt, 1)
  T.swell = T.swell + (crest - T.swell) * (1 - gomath.exp(-dt / 0.1))
  local blue = 0
  local hs = sensors.hud
  if hs ~= nil and kit.fresh(hs.blue_zone, now, 2000) and hs.blue_zone.value == true then
    blue = 1
  end
  T.blue_zone = T.blue_zone + (blue - T.blue_zone) * (1 - gomath.exp(-dt / 0.2))
  if gomath.abs(blue - T.blue_zone) < 0.01 then
    T.blue_zone = blue
  end
  local mode = t.settings.turn_feel
  T.felt = 0
  if not t.native or mode == "off" then
    return
  end
  local outside = 1 - T.blue_zone
  local felt, swell, voice = T.amount, T.swell, "maneuver_waves"
  if mode == "push" then
    -- about a second per push, fading out; a small change is not felt
    felt = gomath.max(0, gomath.min(1, 2 * gomath.sqrt(change)) - 0.1) / 0.9
    swell, voice = 1, "maneuver_push"
  end
  local level = turn_level(felt) * outside
  if level > 0 then
    if fa_off then
      level = gomath.min(1, level * 1.25) -- flight assist off: every turn is felt more
    end
    -- stay under the other effects: step back while a one-shot plays and
    -- while firing
    if t.ducked.turn then
      level = level * 0.4
    elseif fired_lately(now) then
      level = level * 0.6
    end
    T.felt = level
  end
  local kick_at = 2000
  if fa_off then
    kick_at = 1400
  end
  local kick = 0
  if accel > kick_at and T.gyro > 70 and clock.since(now, T.last_kick) > KICK_GAP then
    if outside > 0.5 then
      kick = gomath.min(1, 0.35 + accel / 10000)
    end
    T.last_kick = now
  end
  local h = hook.run("turn@1", {
    mode = mode, feel = voice, level = level, swell = swell, kick = kick,
    amount = T.amount, outside = outside, fa_off = fa_off,
  })
  -- a value of the wrong type from a handler keeps Elite's own
  if h.mode == "off" then
    return
  end
  level, swell, kick = number_or(h.level, level), number_or(h.swell, swell), number_or(h.kick, kick)
  if type(h.feel) == "string" then
    voice = h.feel
  end
  if level > 0 then
    feel.layer("maneuver", voice, level * swell)
  end
  if kick > 0 then
    feel.play("maneuver_kick", { scale = kick })
  end
end

-- tick is the turn part of the tick, called where flying() ends (after
-- the weapons, thrust and boost; the trigger reset between plays nothing
-- and leaves the turn alone): the turn feel while flying, else the stop.
-- The head look is the bindings detector's after this tick's actions
-- (SetHeadlook before Tick).
function M.tick(t)
  T.headlook = sensor.call("binds", "headlook") == true
  local st = S.status
  local dead = state.shutdown_phase(t.now) == "dead"
  local ship = state.in_ship(st) and not state.parked(st)
  if t.pad.ok and not state.in_panel(st) and not dead and ship then
    turning(t, st.flags.FlightAssistOff == true)
  else
    stop(t.now, ship and not dead)
  end
end

-- silence is the turn part of the idle tick (head look off;
-- a restart keeps it)
function M.silence(t)
  T.gyro = 0
  reset_mouse()
  if t.reason ~= "restart" then T.headlook = false end
end

-- on_binds is the bindings' turn part: which stick and mouse axes turn the
-- ship, from a custom preset (the defaults without one); the virtual stick
-- is centred
function M.on_binds(ev)
  local b = ev.new
  T.sticks = { true, true, false, false }
  T.turns, T.holds = { true, true }, { false, false }
  if b ~= nil and b.custom == true then
    local sticks, any = {}, false
    for i = 1, 4 do
      sticks[i] = b.turn_sticks[i] == true
      any = any or sticks[i]
    end
    if any then
      T.sticks = sticks
    end
    T.turns = { b.mouse.turns[1] == true, b.mouse.turns[2] == true }
    T.holds = { b.mouse.holds[1] == true, b.mouse.holds[2] == true }
  end
  reset_mouse()
end

-- on_mouse_reset: the bound mouse reset centres the virtual stick, in or
-- out of the ship
function M.on_mouse_reset(ev)
  reset_mouse()
end

-- gyro_stats returns the fastest controller rotation and whether the
-- touchpad was touched since the last call (GyroStats, for the gyro check)
function M.gyro_stats()
  local fastest, touched = T.fastest, T.touched
  T.fastest, T.touched = 0, false
  return fastest, touched
end

local function flag(b)
  if b then
    return 1
  end
  return 0
end

-- debug is the turn part of the state table (state.debug_part)
function M.debug(d, t)
  d["turn.gyro"] = T.gyro
  d["turn.mouse_x"], d["turn.mouse_y"] = T.mouse[1], T.mouse[2]
  d["turn.amount"] = T.amount
  d["turn.blue_zone"] = T.blue_zone
  d["turn.felt"] = T.felt
  d["turn.phase"], d["turn.swell"] = T.phase, T.swell
  for i = 1, 6 do
    d["turn.vec" .. i], d["turn.settled" .. i] = T.vec[i], T.settled[i]
  end
  d["turn.last_kick"] = T.last_kick
  d["turn.headlook"] = flag(T.headlook)
  d["turn.fastest"] = T.fastest
  d["turn.touched"] = flag(T.touched)
end

state.debug_part(M.debug)

return M
