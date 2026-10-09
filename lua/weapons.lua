-- The weapons, thrust, the heat sink and the bound boost while flying,
-- and the trigger holds. Elite does not report firing, so it is read from
-- the triggers.
--
-- State, in bururu.state (rules read it as state.<field>):
--   weapons           per trigger ("r2" fires the primary list, "l2" the
--                     secondary): down (pulled last tick), held {1, 2} and
--                     spin {1, 2} per weapon class on the trigger,
--                     firing_at (last fired), utility_at (last utility feel);
--                     times in ns since the session started, clock.NEVER
--                     for none
--   last_tick         the last on_tick's t.now
-- tick returns the heat the weapons add per second, for heat.lua; a heat
-- sink (fired from a fire group or bound) calls heat.sink().
--
-- Hook point weapon_layer@1 runs before each weapon layer (the weapon's
-- texture, the multi-cannon spin-up, the railgun charge) with a payload of
-- scalars: trigger ("r2"|"l2"), class, key, feel, level, side, skip. A
-- handler may change feel, level and side, or set skip.

local state      = require("state")
local firegroups = require("firegroups")
local boost      = require("boost")
local heat       = require("heat")
local onfoot     = require("onfoot")
local lib        = require("lib")
local clock = require("clock")

local M = {}
local S = bururu.state

-- the triggers in order: R2 (the primary list) first
local TRIGGERS = {
  { side = "r2", held = "r2_held", pan = "right", effect = "fire_primary",
    keys = { "fire_primary", "fire_primary_2" }, spin = { "fire_primary_spin", "fire_primary_2_spin" } },
  { side = "l2", held = "l2_held", pan = "left", effect = "fire_secondary",
    keys = { "fire_secondary", "fire_secondary_2" }, spin = { "fire_secondary_spin", "fire_secondary_2_spin" } },
}

-- 2*pi*14: the firing flutter on the motors, 14 Hz
local FLUTTER_RAD = 87.96459430051421

-- estimated heat per second while a weapon class fires
local WEAPON_HEAT = {
  beam = 0.07, plasma = 0.05, railgun = 0.05, mining = 0.04, burst = 0.04,
  pulse = 0.03, cannon = 0.015, fragment = 0.015,
}

-- the hardpoint size as the settings name it; medium when unknown
local SIZE_NAMES = { [1] = "small", [3] = "large", [4] = "huge" }

-- the utilities that play once per press: the feel and the gap (ns) before
-- the next one; scanner and point defence are their own
local UTILITY_ONCE = {
  heatsink = { "heat_sink", 2e9 }, chaff = { "chaff", 1e9 }, shieldcell = { "shield_cell", 3e9 },
  ecm = { "ecm", 2e9 }, limpet = { "limpet", 3e8 },
}
local UTILITY_OTHER = { "utility", 2e8 }

local function trigger()
  return { down = false, held = { clock.NEVER, clock.NEVER }, spin = { 0, 0 },
           firing_at = clock.NEVER, utility_at = clock.NEVER }
end

S.weapons = { r2 = trigger(), l2 = trigger() }
S.last_tick = clock.NEVER

-- the tick context, kept so lib.firing reads the time of the phase it
-- runs in (one table, updated in place)
local tick

-- reset_holds forgets the held times and the spin-ups (Silence, a lost pad,
-- a panel)
local function reset_holds()
  for _, side in ipairs({ "r2", "l2" }) do
    local w = S.weapons[side]
    w.held[1], w.held[2] = clock.NEVER, clock.NEVER
    w.spin[1], w.spin[2] = 0, 0
  end
end

-- spin_up_secs: multi-cannons only; with several on the ship, the smallest
-- fires first, in seconds
local function spin_up_secs(class, settings)
  if class ~= "multicannon" then
    return 0
  end
  local size = 0
  for _, m in ipairs(S.modules) do
    if m.class == class and not m.utility and m.size > 0 and (size == 0 or m.size < size) then
      size = m.size
    end
  end
  local ms, by_size = 0, settings and settings.spin_up_ms
  local v = type(by_size) == "table" and by_size[SIZE_NAMES[size] or "medium"]
  if type(v) == "number" then
    ms = gomath.trunc(v)
  end
  return clock.secs(ms * 1000000)
end

-- spin_up follows a weapon class's spin-up and reports whether it fires,
-- and the spin. Multi-cannons spin their barrels up before the
-- first shot, longer the bigger they are, and spin down when released: a
-- quick second press fires sooner.
local function spin_up(t, w, k, class, down)
  local d = spin_up_secs(class, t.settings)
  if d <= 0 then
    w.spin[k] = 0
    return down, 1
  elseif down then
    w.spin[k] = gomath.min(1, w.spin[k] + t.dt / d)
  else
    w.spin[k] = gomath.max(0, w.spin[k] - t.dt / d)
  end
  return down and w.spin[k] >= 1, w.spin[k]
end

-- weapon_feel is the layer feel of a weapon class: its own, else
-- weapon_other
local function weapon_feel(class)
  local name = "weapon_" .. class
  if feel.exists(name) then
    return name
  end
  return "weapon_other"
end

-- weapon_layer holds one weapon layer this tick, after the weapon_layer@1
-- hook; a handler's value of the wrong type keeps what the layer had
local function weapon_layer(tr, class, key, name, level, gain, add)
  local p = hook.run("weapon_layer@1", { trigger = tr.side, class = class, key = key, feel = name,
                                         level = level, side = tr.pan, skip = false })
  if p.skip == true then
    return
  end
  if type(p.feel) == "string" then
    name = p.feel
  end
  if type(p.level) == "number" and p.level == p.level then -- NaN keeps the level
    level = p.level
  end
  local side = tr.pan
  if p.side == "both" or p.side == "left" or p.side == "right" then
    side = p.side
  end
  feel.layer(key, name, level, { side = side, gain = gain, add = add })
end

-- fire is the feel of one weapon class on a trigger (k: which class on
-- it; share: how much of it is firing). Both classes share the trigger's
-- gain.
local function fire(t, class, key, tr, w, k, down, share)
  if share <= 0 then
    down = false
  end
  if class == "railgun" then
    -- charges while held, cracks on release
    if down then
      if w.held[k] == clock.NEVER then
        w.held[k] = t.now
      end
      local p = gomath.min(1, clock.secs(clock.since(t.now, w.held[k])))
      weapon_layer(tr, class, key, "railgun_charge", share, tr.effect,
        { f0_hz = 160 * p, level = 0.5 * p, trem_hz = 20 * p })
    elseif w.held[k] ~= clock.NEVER then
      if clock.since(t.now, w.held[k]) > 250000000 then
        feel.play("rail_crack", { side = tr.pan })
      end
      w.held[k] = clock.NEVER
    end
  elseif class == "missile" then
    if not down then
      w.held[k] = clock.NEVER
    elseif w.held[k] == clock.NEVER then
      feel.play("missile_launch", { side = tr.pan })
      w.held[k] = t.now
    end
  elseif down then
    weapon_layer(tr, class, key, weapon_feel(class), share, tr.effect, nil)
  end
end

-- utility_once plays a utility's feel on a press, at most once per gap
local function utility_once(t, w, pressed, name, gap)
  if pressed and clock.since(t.now, w.utility_at) > gap then
    feel.play(name)
    w.utility_at = t.now
  end
end

-- utility_fire: a trigger that fires utilities only
local function utility_fire(t, classes, tr, w, pulled, pressed)
  local class = classes[1]
  if class == nil then
    return
  end
  if class == "scanner" then
    -- scanners work while held: a slow sweeping hum on that side
    if pulled then
      feel.layer("scanner", "scanner", 1, { side = tr.pan, rumble = "scanner" })
    end
    return
  elseif class == "pointdefence" then
    return -- fires on its own
  end
  local once = UTILITY_ONCE[class] or UTILITY_OTHER
  if class == "heatsink" and pressed and clock.since(t.now, w.utility_at) > once[2] then
    heat.sink() -- a heat sink takes the heat away
  end
  utility_once(t, w, pressed, once[1], once[2])
end

-- flying: what the controller does while flying: weapons, thrust, boost
-- (the turn feel follows in on_tick). It returns the heat the weapons add
-- per second.
local function flying(t, st, pad)
  local f = st.flags
  local heat_in = 0
  -- no weapon fires in supercruise, hardpoints out or not
  local weapons = f.HardpointsDeployed == true and not (f.AnalysisMode == true or f.Supercruise == true)
  local sets = firegroups.sets(t.settings)
  local flutter = 0.85 + 0.15 * gomath.sin(FLUTTER_RAD * kit.seconds(t.unix_ms))
  for _, tr in ipairs(TRIGGERS) do
    local w = S.weapons[tr.side]
    local pulled = pad[tr.held] == true
    local pressed = pulled and not w.down
    w.down = pulled
    local set = sets[tr.side]
    if set.utility then
      if f.AnalysisMode ~= true then
        utility_fire(t, set.classes, tr, w, pulled, pressed)
      end
    else
      local down = weapons and pulled
      local share = firegroups.share(tr.side, t.now) -- weapons reloading fall silent
      -- up to two weapon classes on a trigger, the second a bit softer
      local n = #set.classes
      if n > 2 then
        n = 2
      end
      for k = 1, n do
        local class = set.classes[k]
        local firing, spin = spin_up(t, w, k, class, down)
        if firing then
          w.firing_at = t.now
          heat_in = heat_in + (WEAPON_HEAT[class] or 0.01) / k
        end
        if not t.native then
          if k == 1 and firing and share > 0 then
            feel.rumble(tr.effect, tr.effect, flutter * share)
          end
        else
          if down and not firing then
            -- the barrels winding up: a smooth rising whir
            weapon_layer(tr, class, tr.spin[k], "spin_up", 1, "spin_up", { f0_hz = 60 * spin, level = 0.23 * spin })
          end
          fire(t, class, tr.keys[k], tr, w, k, firing, share / k)
        end
      end
    end
  end
  if pad.held.r1 then
    feel.layer("thrust", "thrust", 1, { rumble = "thrust" })
    feel.layer("thrust_low", "thrust_low", 1)
  end
  boost.flying(t, st, pad)
  return heat_in
end

-- tick is the controller part of the tick (on_tick, before the turn feel):
-- flying or on foot while the pad answers, no panel is open and the
-- systems live; the trigger holds are forgotten while the pad is lost or a
-- panel is open. It returns the heat the weapons add per second.
function M.tick(t)
  tick = t
  S.last_tick = t.now
  local st, pad = S.status, t.pad
  local panel = state.in_panel(st)
  local heat_in = 0
  if pad.ok and not panel and state.shutdown_phase(t.now) ~= "dead" then
    if state.in_ship(st) and not state.parked(st) then
      heat_in = flying(t, st, pad)
    elseif state.on_foot(st) and not (st.flags2.OnFootSocialSpace == true or st.flags2.OnFootInStation == true) then
      onfoot.tick(t, st, pad)
    end
  end
  if not pad.ok or panel then
    reset_holds()
  end
  return heat_in
end

-- on_action: the bound actions' state (OnActions): a heat sink cools, a
-- bound boost boosts (their plays: actions.rules.json and boost.lua)
function M.on_action(ev)
  local st = S.status
  if not state.in_ship(st) or st.flags.Docked == true or state.in_panel(st)
      or state.shutdown_phase(ev.at) == "dead" then
    return
  end
  if ev.action == "heat_sink" then
    heat.sink()
  elseif ev.action == "boost" then
    if not (st.flags.Supercruise == true or st.flags.Landed == true) then
      boost.start(ev.at, "binds")
    end
  end
end

-- silence is Silence's trigger part (on_idle): the holds and spin-ups go
function M.silence(t)
  tick = t
  reset_holds()
end

-- lib.firing(side, ms[, t]): a weapon on that trigger ("r2"|"l2") fired
-- in the last ms (the HUD feels' firing)
function lib.firing(side, ms, t)
  local w = S.weapons[side]
  if w == nil or w.firing_at == clock.NEVER then
    return false
  end
  local now = (t or tick).now
  return clock.since(now, w.firing_at) < ms * 1000000
end

local function flag(b)
  if b then
    return 1
  end
  return 0
end

-- the weapons' part of the state table (state.debug_part)
local function debug(d)
  for _, side in ipairs({ "r2", "l2" }) do
    local w, p = S.weapons[side], "trigger." .. side .. "."
    d[p .. "down"] = flag(w.down)
    d[p .. "firing_at"], d[p .. "utility_at"] = w.firing_at, w.utility_at
    d[p .. "held1"], d[p .. "held2"] = w.held[1], w.held[2]
    d[p .. "spin1"], d[p .. "spin2"] = w.spin[1], w.spin[2]
  end
  d.last_tick = S.last_tick
end

state.debug_part(debug)

return M
