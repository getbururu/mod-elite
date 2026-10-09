-- the helpers Elite's rule expressions call as lib.<name> (the manifest's
-- rule_env): tests on Status.json and questions on the game state.
-- s is a Status.json snapshot
-- (st, new, old; nil reads as no status yet), t the tick context. Another
-- module of this mod adds its own helpers while the mod loads:
--   local lib = require("lib")
--   function lib.my_helper(s) ... end

local clock = require("clock")
local state = require("state")
local firegroups = require("firegroups")

local lib = {}

-- since and secs: times in ns, for rule expressions (clock.lua)
lib.since = clock.since
lib.secs = clock.secs

-- in_ship: in the main ship or a fighter
lib.in_ship = state.in_ship
-- parked: docked or landed
lib.parked = state.parked
-- on_foot: Odyssey's on foot
lib.on_foot = state.on_foot
-- in_panel: a panel or a map has the controls (GuiFocus)
lib.in_panel = state.in_panel

-- free_space: neither in supercruise nor docked
function lib.free_space(s)
  local f = (s or state.zero).flags
  return not (f.Supercruise == true or f.Docked == true)
end

-- active: the player is in the game
function lib.active()
  return state.active()
end

-- in_combat: combat music, or danger
function lib.in_combat()
  return state.in_combat()
end

-- thargoid_music: a track that plays near Thargoids
function lib.thargoid_music()
  return state.thargoid_music()
end

-- shutdown: "none", "dead" or "rebooting" (a Thargoid shutdown field)
function lib.shutdown(t)
  return state.shutdown_phase(t.now)
end

-- systems_dead: the ship's systems are dead in a shutdown field
function lib.systems_dead(t)
  return state.shutdown_phase(t.now) == "dead"
end

-- rebooting: the systems come back after a shutdown field
function lib.rebooting(t)
  return state.shutdown_phase(t.now) == "rebooting"
end

-- reboot_progress: how far the reboot is, 0-1
function lib.reboot_progress(t)
  return state.reboot_progress(t.now)
end

-- countdown: a hyperspace jump counts down
function lib.countdown(t)
  local _, counting = state.hyperspace_countdown(t.now)
  return counting
end

-- countdown_left: the part of the hyperspace countdown left, 0-1
function lib.countdown_left(t)
  local left = state.hyperspace_countdown(t.now)
  return left
end

-- in_tunnel: the ship is in the hyperspace tunnel
function lib.in_tunnel(t)
  local _, inside = state.tunnel(t.now)
  return inside
end

-- tunnel_ns: how long the ship has been in the tunnel, ns
function lib.tunnel_ns(t)
  local d = state.tunnel(t.now)
  return d
end

-- fsd_charging: the frame shift drive charges, until the tunnel
function lib.fsd_charging(t)
  return state.fsd_charging(t.now)
end

-- descending: a fresh altitude over a planet's surface is known
function lib.descending(t)
  local _, _, ok = state.descent(t.now)
  return ok
end

-- altitude: metres over the surface while fresh, else 0
function lib.altitude(t)
  local metres = state.descent(t.now)
  return metres
end

-- descent_rate: m/s going down (smoothed) while fresh, else 0
function lib.descent_rate(t)
  local _, rate = state.descent(t.now)
  return rate
end

-- fire_key: the fire group and hardpoints as the HUD's lists key them
function lib.fire_key(s)
  return firegroups.key(s or state.zero)
end

-- firing_share: the part of a trigger's weapons still firing ("l2" or
-- "r2"), from a fresh HUD read; 1 without one
function lib.firing_share(side, t)
  return firegroups.share(side, t.now)
end

return lib
