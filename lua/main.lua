-- Elite Dangerous as a mod: every handler, in the order a tick runs them.
-- Handlers of one kind run in the order they are registered.

local state      = require("state")      -- the session: hull, timers, music, altitude, moments
local firegroups = require("firegroups") -- fire sets, firing shares, the lists learned from the HUD
local heat       = require("heat")       -- the heat estimate and the heat feel
local ambience   = require("ambience")   -- the reboot feel and the ambience layers that bend their voices
local lights     = require("lights")     -- lights.json's helpers and the triggers' capacitor slack
local weapons    = require("weapons")    -- fire sets, spin-up, railgun, missiles, utilities, thrust; boost, on foot
local turning    = require("turning")    -- the turn feel: gyro and sticks outside the blue zone (turn@1)
local hud        = require("hud")        -- what the HUD reader is asked to read
local checks     = require("checks")     -- the raw sticks and gyro log lines, the setup items
require("lib")                           -- the rule expressions' lib (rule_env); modules may add to it

-- Reading: the bindings first, then the journal and Status.json, then the facts
bururu.on("game:check", checks.on_check)       -- the raw sticks line
-- (the bound boost needs no handler: boost.lua reads sensors.binds.has.boost)
bururu.on("binds:change", turning.on_binds)    -- the turn sticks and the mouse
bururu.on("binds:change", checks.on_binds)     -- the setup items: the custom preset, the dead zones
bururu.on("journal:*", state.on_journal)       -- every journal event
bururu.on("journal:Loadout", hud.on_loadout)   -- Loadout -> hud loadout
bururu.on("journal:ShipTargeted", hud.on_target) -- a new target: its numbers start over
bururu.on("status:change", state.on_status)    -- every Status.json change
bururu.facts(state.facts)                      -- Active, InMenu, Context

-- The screen: what to read before it is read, then what it showed
bururu.before_screen(hud.asks)                 -- read the HUD while in a ship, with the fire groups
bururu.on("hud:shield_hit", hud.on_shield_hit) -- the last shield hit
bururu.after_screen(hud.after)                 -- read faster while firing, before the lists' log line
bururu.after_screen(firegroups.learn)          -- the fire lists learned from the HUD
state.debug_part(firegroups.debug)              -- fire sets and shares in the state table

-- Idle ticks: the game is not in front, or haptics are off
bururu.on_idle(state.silence)                  -- head look off
bururu.on_idle(heat.silence)                   -- the heat estimate starts cold
bururu.on_idle(weapons.silence)                -- the trigger holds and spin-ups go
bururu.on_idle(turning.silence)                -- the turn's rotation and virtual stick, head look off

-- Driving: the pad, the bound actions, the tick
bururu.on_pad(state.on_pad)                    -- the triggers held, the ship controls
bururu.on("binds:action", weapons.on_action)   -- heat-sink cooling, the bound boost
bururu.on("binds:action=mouse_reset", turning.on_mouse_reset) -- the virtual stick centred
bururu.on_tick(function(t)                     -- the feels, in the order they play
  local dead = state.shutdown_phase(t.now) == "dead"
  ambience.reboot(t)                            -- the reboot feel, once per shutdown
  local heat_in = weapons.tick(t)               -- flying (weapons, thrust, boost) or on foot; the trigger reset
  turning.tick(t)                               -- the turn feel at flying's end (nothing plays between), or its reset
  if not dead then
    rules.stage("ship_ambience")                -- the drive charging, the tunnel, scooping, overheating, interdiction
  end
  heat.tick(t, heat_in)                         -- the heat estimate
  if not dead then
    heat.feel(t)                                -- the heat feel (heat@1)
    rules.stage("heat")                         -- add-ons' layers after the heat feel
    rules.stage("planet")                       -- the glide
    ambience.ground_rush(t)
  end
  rules.stage("thargoid")
  if not dead then
    ambience.damage(t)                          -- low shields, a weak hull
    rules.stage("damage")                       -- the shields offline
  end
end)
bururu.on_tick(checks.check_gyro)              -- the gyro check, after the tick

-- Lights: what the lights read each frame
bururu.before_frame(lights.values)             -- the triggers' capacitor slack for lights.json
state.debug_part(lights.debug)                  -- the slack in the state table

-- the state table, for tests that follow the mod's state
bururu.export("debug", state.debug)
