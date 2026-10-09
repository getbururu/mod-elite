-- What the screen reader is asked (sensor "hud", laid out in
-- screen/hud.json): when it reads, what and how fast.
--   before_screen     on in the cockpit (the reader checks that the game
--                     is in front), the fire group lists when worth a read
--   hud:shield_hit    the last shield hit, for the reading speed
--   after_screen      fast while a fight is on or the shields or heat move
--   journal:Loadout   the modules the fire group lists may show
--   journal:ShipTargeted  another target's numbers start over
--
-- It keeps in bururu.state:
--   target        the target locked, "" for none, to tell a new one
--   last_hud_hit  the HUD's last shield hit (ns since the session started,
--                 clock.NEVER for none)

local state      = require("state")
local firegroups = require("firegroups")
local modules    = require("modules")
local clock = require("clock")

local M = {}
local S = bururu.state

local ID = "hud" -- the screen sensor in sensors.json

-- times in ns
local LISTS_AFTER_TRIGGER = 10e9 -- a trigger pulled this lately: the lists are worth a read (utilities)
local FAST_AFTER_HIT = 20e9      -- full speed this long after a shield hit

S.target, S.last_hud_hit = "", clock.NEVER

-- text is a string field of an event, "" when it is none
local function text(ev, key)
  local v = ev[key]
  if type(v) == "string" then
    return v
  end
  return ""
end

-- lists_worth_reading: the fire group lists are read in the main ship,
-- outside analysis mode, with the hardpoints out, or in with a fight on or
-- a trigger pulled lately (utilities). Not in supercruise, where no weapon
-- fires: lists read there were stored under the hardpoints-out key and
-- stood for the next deploy in normal space.
local function lists_worth_reading(st, since_trigger)
  local f = st.flags
  return f.InMainShip == true and not (f.AnalysisMode or f.Supercruise)
      and (f.HardpointsDeployed == true or f.InDanger == true or since_trigger < LISTS_AFTER_TRIGGER)
end

-- asks is the before_screen handler: the reader reads in the cockpit,
-- outside the station, the jump, the panels and a shutdown; the shield %
-- shows while the shields are up, so the colours are checked then; the
-- lists when worth it, with the fire key and the triggers held
function M.asks(t, active)
  local st = S.status
  local f = st.flags
  local on = t.settings.hud_reader ~= false and active and state.in_ship(st) and not (f.Docked or f.FSDJump)
      and not state.in_panel(st) and state.shutdown_phase(t.now) == "none"
  local lists = on and lists_worth_reading(st, clock.since(t.now, S.trigger_at))
  sensor.set(ID, {
    active = on, learn = f.ShieldsUp == true,
    lists = lists, list_key = firegroups.key(st), list_out = f.HardpointsDeployed == true,
    held = { l2 = S.triggers_held.l2, r2 = S.triggers_held.r2 },
  })
end

-- on_shield_hit: a shield hit the HUD saw this tick
function M.on_shield_hit(ev)
  S.last_hud_hit = ev.at
end

-- the screen snapshot of the last reading: each Take makes a new one
local seen

-- after is the after_screen handler, on the ticks with a reading: full
-- speed while a fight is on or the shields or heat move, calmer while
-- cruising. It is registered before the fire lists are learned, so the
-- ask comes before what they log.
function M.after(t)
  local hs = sensors.hud
  if hs == nil or hs == seen then
    return
  end
  seen = hs
  local f = S.status.flags
  local fast = f.HardpointsDeployed == true or f.InDanger == true or f.ShieldsUp ~= true
      or clock.since(t.now, S.last_hud_hit) < FAST_AFTER_HIT
      or hs.shield.ok == true and hs.shield.value < 100 or hs.heat.ok == true and hs.heat.value >= 50
  sensor.set(ID, { fast = fast })
end

-- on_loadout gives the reader the modules the fire group lists may show
-- (also while the journal catches up): weapons carry a mount icon, and
-- modules with ammo show it as "clip/reserve" under their bar
function M.on_loadout(ev)
  local entries = {}
  for i, m in ipairs(modules.of(ev)) do
    entries[i] = { name = m.name, class = m.class, icon = not m.utility, counter = m.ammo,
                   counter_text = m.ammo_text, size = m.size }
  end
  sensor.call(ID, "entries", entries)
end

-- on_target: another target's numbers start over; scan stages and
-- subsystems of the same ship keep them (live lines only)
function M.on_target(ev)
  if not ev.live then
    return
  end
  local key = ""
  if ev.TargetLocked == true then
    key = text(ev, "Ship") .. "|" .. text(ev, "PilotName")
  end
  if key ~= S.target or key == "" then
    sensor.call(ID, "reset", "target_shield")
  end
  S.target = key
end

return M
