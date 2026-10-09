-- The boost (Circle boosts when no binding does). A boost needs enough
-- charge in the engine capacitor (read from the HUD); without it the press
-- is a dud. How much it needs differs between ships, so it is learned from
-- what the capacitor does after a press.
--
-- State, in bururu.state.boost: pressed_at (ns since the session started,
-- clock.NEVER when no press waits to be judged), eng_at (the engine
-- capacitor when pressed), need (learned; 0 until then).
--
-- Hook point boost@1 runs before a boost or a dud plays, with a payload of
-- scalars: feel ("boost"|"boost_empty"), source ("circle"|"binds"), eng
-- (the engine capacitor read, absent without a fresh read), need, skip. A
-- handler may change feel, or set skip.

local state = require("state")
local clock = require("clock")

local M = {}
local S = bururu.state

local DEFAULT_NEED = 0.25

S.boost = { pressed_at = clock.NEVER, eng_at = 0, need = 0 }

local function needed()
  if S.boost.need == 0 then
    return DEFAULT_NEED
  end
  return S.boost.need
end

-- capacitors: the HUD's capacitors read in the last 2 s, else nil
local function capacitors(now)
  local hs = sensors.hud
  local caps = hs and hs.capacitors
  if caps ~= nil and kit.fresh(caps, now, 2000) then
    return caps
  end
  return nil
end

-- from_bindings: a binding boosts, so Circle does not (the bindings'
-- UseBoostJuice)
function M.from_bindings()
  local b = sensors.binds
  return b ~= nil and type(b.has) == "table" and b.has.boost == true
end

-- start: the boost feel, or a dud when the engine capacitor cannot pay;
-- now is the press's time, source what pressed it
function M.start(now, source)
  local b = S.boost
  local name = "boost"
  local eng
  local caps = capacitors(now)
  if caps ~= nil then
    eng = caps.eng
    b.pressed_at, b.eng_at = now, eng
    if eng < needed() then
      name = "boost_empty"
    end
  end
  local p = hook.run("boost@1", { feel = name, source = source, eng = eng, need = needed(), skip = false })
  if p.skip == true then
    return
  end
  if type(p.feel) == "string" then
    name = p.feel
  end
  feel.play(name)
end

-- learn: 0.8 s after a press, did the engine capacitor drain? Then that
-- charge was enough; if not, too little. The need settles between the two.
local function learn(now)
  local b = S.boost
  if b.pressed_at == clock.NEVER or clock.since(now, b.pressed_at) < 800000000 then
    return
  end
  b.pressed_at = clock.NEVER
  local caps = capacitors(now)
  if caps == nil then
    return
  end
  local boosted = b.eng_at - caps.eng >= 0.1
  local need = needed()
  if boosted and b.eng_at < need then
    b.need = gomath.max(0.05, b.eng_at - 0.02)
  elseif not boosted and b.eng_at >= need then
    b.need = gomath.min(0.9, b.eng_at + 0.05)
  end
end

-- flying is the boost part of flying: Circle boosts when no binding does
-- and not in supercruise, then a press waiting is judged
function M.flying(t, st, pad)
  if not M.from_bindings() and pad.pressed.circle and st.flags.Supercruise ~= true then
    M.start(t.now, "circle")
  end
  learn(t.now)
end

-- the boost part of the state table (state.debug_part)
local function debug(d)
  local b = S.boost
  d["boost.need"], d["boost.pressed_at"], d["boost.eng_at"] = b.need, b.pressed_at, b.eng_at
  d["boost.from_bindings"] = M.from_bindings() and 1 or 0
end

state.debug_part(debug)

return M
