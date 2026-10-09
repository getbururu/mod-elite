-- What the journal and Status.json made of the session, with the
-- triggers held and the facts. It lives in bururu.state, so rules
-- read it as state.<field>:
--   status            the last Status.json taken; M.zero before
--   have_status       a Status.json was taken
--   music, hull, main_menu, closed, shields_seen
--   fsd_charge_start, hyperspace_start, died_at, shutdown_at
--                     ns since the session started, clock.NEVER for none
--   moments           recent live moments {kind, at}, oldest first
--   modules           the loadout's fire-groupable modules (modules.lua)
--   fire_lists        what the HUD showed, by fire key (firegroups.lua)
--   fired_at          a fire trigger was last pulled (clock.NEVER: never)
--   trigger_at        the same for the HUD's lists ask (the session's)
--   triggers_held     {l2, r2}: pulled on a pad that answers
--   altitude          {metres, descent, ok, at}

local modules = require("modules")
local clock = require("clock")

local M = {}
local S = bururu.state

local music = data.get("music")
local NO_PANEL = data.get("guifocus").no_panel

-- times in ns
local COUNTDOWN = 18e9      -- StartJump(Hyperspace) to FSDJump
local COUNTDOWN_KEEP = 23e9 -- COUNTDOWN + 5 s: a jump that never came is forgotten
local ENTRY = 5e9           -- StartJump to the tunnel
local SILENCE = 27e9        -- a Thargoid shutdown field's dead systems
local REBOOT_END = 30e9     -- SILENCE and the reboot
local MOMENTS_KEPT = 5e9    -- how long moments are kept, longer than any flash
local ALTITUDE_FRESH = 2.5e9

-- moment kinds, numbered as game.MomentKind
M.moment = {
  hull_damaged = 0, shields_raised = 1, shields_lost = 2, attacked = 3, kill = 4,
  heat_warning = 5, jet_cone_boost = 6, interdicted = 7, docking_granted = 8, docking_denied = 9,
}

-- zero is the status before the first Status.json (elite.Status{}); a bit
-- it lacks reads nil
M.zero = {
  Flags = 0, Flags2 = 0, FireGroup = 0, GuiFocus = 0, SelectedWeapon = "",
  Pips = kit.null, Health = kit.null, Altitude = kit.null, flags = {}, flags2 = {},
}

S.status, S.have_status = M.zero, false
S.music, S.hull = "", 1
S.main_menu, S.closed, S.shields_seen = false, false, false
S.fsd_charge_start, S.hyperspace_start = clock.NEVER, clock.NEVER
S.died_at, S.shutdown_at = clock.NEVER, clock.NEVER
S.moments, S.modules, S.fire_lists = {}, {}, {}
S.fired_at, S.trigger_at = clock.NEVER, clock.NEVER
S.triggers_held = { l2 = false, r2 = false }
S.altitude = { metres = 0, descent = 0, ok = false, at = clock.NEVER }

-- the tick context, kept for the state table between ticks
local tick

-- text is a string field of an event, "" when it is none
local function text(ev, key)
  local v = ev[key]
  if type(v) == "string" then
    return v
  end
  return ""
end

-- status tests (elite.Status's methods); s may be nil
function M.in_ship(s)
  local f = (s or M.zero).flags
  return f.InMainShip == true or f.InFighter == true
end

function M.parked(s)
  local f = (s or M.zero).flags
  return f.Docked == true or f.Landed == true
end

function M.on_foot(s)
  return (s or M.zero).flags2.OnFoot == true
end

function M.in_panel(s)
  return (s or M.zero).GuiFocus ~= NO_PANEL
end

-- remember records a moment and forgets old ones
local function remember(kind, at)
  local kept = {}
  for _, m in ipairs(S.moments) do
    if clock.since(at, m.at) < MOMENTS_KEPT then
      kept[#kept + 1] = m
    end
  end
  kept[#kept + 1] = { kind = kind, at = at }
  S.moments = kept
end

-- track_altitude: Altitude is from the surface unless
-- AltitudeFromAverageRadius is set (high up)
local function track_altitude(s, now)
  local a, f = S.altitude, s.flags
  if type(s.Altitude) ~= "number" or not f.HasLatLong or f.AltitudeFromAverageRadius or f.Supercruise
      or f.Docked or f.Landed then
    a.ok, a.descent = false, 0
    return
  end
  local metres = s.Altitude
  if not a.ok then
    a.descent = 0
  else
    local dt = clock.secs(clock.since(now, a.at))
    if dt >= 0.05 and dt < 5 then
      local v = (a.metres - metres) / dt
      a.descent = a.descent + (v - a.descent) * gomath.min(1, dt / 0.6)
    end
  end
  a.metres, a.ok, a.at = metres, true, now
end

-- take_status takes a Status.json: s is the new Status.json snapshot
local function take_status(s, now)
  local f = s.flags
  if f.FSDCharging and not (S.have_status and S.status.flags.FSDCharging) then
    S.fsd_charge_start = now
  end
  if not f.FSDJump and S.hyperspace_start ~= clock.NEVER and clock.since(now, S.hyperspace_start) > COUNTDOWN_KEEP then
    S.hyperspace_start = clock.NEVER
  end
  if f.ShieldsUp then
    S.shields_seen = true
  end
  track_altitude(s, now)
  S.status, S.have_status = s, true
end

-- descent returns the altitude and how fast it drops while fresh
-- (Status.json only changes when something changes): metres, rate, ok
function M.descent(now)
  local a = S.altitude
  if not a.ok or clock.since(now, a.at) > ALTITUDE_FRESH then
    return 0, 0, false
  end
  return a.metres, a.descent, true
end

-- shutdown_phase is "none", "dead" (the systems of a Thargoid shutdown
-- field) or "rebooting"
function M.shutdown_phase(now)
  if S.shutdown_at == clock.NEVER then
    return "none"
  end
  local el = clock.since(now, S.shutdown_at)
  if el < SILENCE then
    return "dead"
  elseif el < REBOOT_END then
    return "rebooting"
  end
  return "none"
end

-- reboot_progress: how far the reboot after a shutdown is, 0-1
function M.reboot_progress(now)
  local at = S.shutdown_at
  if at ~= clock.NEVER then
    at = at + SILENCE
  end
  return clock.secs(clock.since(now, at)) / 3
end

-- hyperspace_countdown: while a hyperspace jump counts down, the part of
-- the countdown left (0-1) and true
function M.hyperspace_countdown(now)
  if S.hyperspace_start == clock.NEVER then
    return 0, false
  end
  local rem = COUNTDOWN - clock.since(now, S.hyperspace_start)
  if rem <= 0 then
    return 0, false
  end
  return clock.secs(rem) / 18, true
end

-- tunnel: how long (ns) the ship has been in the hyperspace tunnel, and
-- whether it is in it. Elite sets the FSD jump flag from the start of the
-- countdown, so the tunnel is timed from StartJump; the flag ends it.
function M.tunnel(now)
  if S.hyperspace_start == clock.NEVER or not S.status.flags.FSDJump then
    return 0, false
  end
  local d = clock.since(now, S.hyperspace_start) - ENTRY
  return d, d >= 0
end

-- fsd_charging: the drive charging, until the hyperspace tunnel
function M.fsd_charging(now)
  local _, in_tunnel = M.tunnel(now)
  return S.status.flags.FSDCharging == true and not in_tunnel
end

-- active: the player is in the game, not in the main menu, not closed
function M.active()
  if not S.have_status or S.closed or S.music == music.main_menu then
    return false
  end
  return S.status.Flags ~= 0 or S.status.Flags2 ~= 0
end

-- in_menu: the main menu, or one of the given GuiFocus panels
function M.in_menu(panels)
  if S.closed then
    return false
  elseif S.main_menu then
    return true
  elseif not S.have_status then
    return false
  end
  local focus = S.status.GuiFocus
  if focus == NO_PANEL or type(panels) ~= "table" then
    return false
  end
  for _, p in ipairs(panels) do
    if p ~= NO_PANEL and focus == p then
      return true
    end
  end
  return false
end

-- context is a short description of the situation, for the log
function M.context()
  local f, f2 = S.status.flags, S.status.flags2
  if not M.active() then
    return "not in game"
  elseif f2.OnFoot then
    return "on foot"
  elseif f.InSRV then
    return "SRV"
  elseif f.Docked then
    return "docked"
  elseif f.Landed then
    return "landed"
  elseif f.FSDJump then
    return "hyperspace"
  elseif f.Supercruise then
    return "supercruise"
  elseif f.HardpointsDeployed and f.AnalysisMode then
    return "normal space, scanners out"
  elseif f.HardpointsDeployed then
    return "normal space, weapons out"
  end
  return "normal space"
end

local function listed(list, s)
  for _, v in ipairs(list) do
    if v == s then
      return true
    end
  end
  return false
end

-- in_combat: combat music, or danger
function M.in_combat()
  return kit.has_prefix(S.music, music.combat_prefix) or listed(music.combat, S.music)
      or S.status.flags.InDanger == true
end

-- thargoid_music: a track that plays near Thargoids
function M.thargoid_music()
  return listed(music.thargoid, S.music)
end

-- the state@1 hook point: after each journal or Status.json update, a copy
-- of the state for add-ons (read only: what they change is dropped)
local function state_hook(input, live, at)
  hook.run("state@1", {
    input = input, live = live, at = at, hull = S.hull, music = S.music, main_menu = S.main_menu,
    closed = S.closed, shields_seen = S.shields_seen, have_status = S.have_status,
    active = M.active(), context = M.context(),
  })
end

local function repairs_hull(ev)
  local items = kit.lower(text(ev, "Item"))
  if type(ev.Items) == "table" then
    for _, it in ipairs(ev.Items) do
      if type(it) == "string" then
        items = items .. " " .. kit.lower(it)
      end
    end
  end
  return kit.contains(items, "hull") or kit.contains(items, "wear") or kit.contains(items, "all")
end

local function on_loadout(ev)
  if type(ev.HullHealth) == "number" then
    S.hull = ev.HullHealth
  end
  local mods = modules.of(ev)
  if not modules.same(mods, S.modules) then
    S.fire_lists = {} -- another ship or a refit: the lists are read again
  end
  S.modules = mods
  S.shields_seen = S.status.flags.ShieldsUp == true
end

local function repaired_all()
  S.hull = 1
  S.died_at, S.shutdown_at = clock.NEVER, clock.NEVER
end

local function shutdown_over()
  S.shutdown_at = clock.NEVER
end

local function jump_over()
  S.hyperspace_start = clock.NEVER
end

-- what each journal event does to the state; live
-- is false while the history is read at startup: no moments, no times
local journal = {
  Fileheader = function()
    S.closed, S.main_menu = false, true
  end,
  LoadGame = function()
    S.closed, S.main_menu = false, false
    if S.music == music.main_menu then
      S.music = ""
    end
  end,
  Shutdown = function()
    S.closed, S.main_menu = true, false
  end,
  Music = function(ev)
    S.music = text(ev, "MusicTrack")
    if S.music == music.main_menu then
      S.main_menu = true
    end
  end,
  Loadout = on_loadout,
  HullDamage = function(ev, live, now)
    -- only the hull of whatever the player flies
    if (ev.Fighter == true) ~= (S.status.flags.InFighter == true) then
      return
    end
    local h = ev.Health
    if type(h) == "number" then
      if live and h < S.hull - 0.001 then
        remember(M.moment.hull_damaged, now)
      end
      S.hull = h
    end
  end,
  RepairAll = repaired_all,
  Resurrect = repaired_all,
  Repair = function(ev)
    if repairs_hull(ev) then
      S.hull = 1
    end
  end,
  Died = function(ev, live, now)
    if live then
      S.died_at = now
    end
    S.shutdown_at = clock.NEVER
  end,
  SystemsShutdown = function(ev, live, now)
    if live then
      S.shutdown_at = now
    end
  end,
  Docked = shutdown_over,
  Touchdown = shutdown_over,
  StartJump = function(ev, live, now)
    if live and text(ev, "JumpType") == "Hyperspace" then
      S.hyperspace_start = now
    end
  end,
  FSDJump = jump_over,
  SupercruiseExit = jump_over,
  SupercruiseEntry = jump_over,
}

local function kill()
  return M.moment.kill
end

-- the live events worth a flash or a buzz
local moment_of = {
  ShieldState = function(ev)
    if ev.ShieldsUp == true then
      return M.moment.shields_raised
    end
    return M.moment.shields_lost
  end,
  UnderAttack = function(ev)
    if text(ev, "Target") == "You" then
      return M.moment.attacked
    end
    return nil
  end,
  Bounty = kill,
  FactionKillBond = kill,
  CapShipBond = kill,
  HeatWarning = function() return M.moment.heat_warning end,
  JetConeBoost = function() return M.moment.jet_cone_boost end,
  Interdicted = function() return M.moment.interdicted end,
  DockingGranted = function() return M.moment.docking_granted end,
  DockingDenied = function() return M.moment.docking_denied end,
}

-- on_journal takes each journal input
function M.on_journal(ev)
  local name, live, now = text(ev, "event"), ev.live, ev.at
  local touched = false
  local apply = journal[name]
  if apply then
    apply(ev, live, now)
    touched = true
  end
  local moment = moment_of[name]
  if live and moment then
    local kind = moment(ev)
    if kind then
      remember(kind, now)
      touched = true
    end
  end
  if touched then
    state_hook(ev.input, live, now)
  end
end

-- on_status takes each new Status.json
function M.on_status(ev)
  take_status(ev.new, ev.at)
  state_hook(ev.input, ev.live, ev.at)
end

-- live_facts are the Home card's facts (the schema's live.facts): the fire
-- group from 1 while in a ship, the shield and heat the HUD read in the
-- last 10 s
local function live_facts(t)
  local st = S.status
  local game = sensors.game
  if game ~= nil and game.running and S.have_status and M.in_ship(st) then
    status.fact("fire_group", st.FireGroup + 1)
  end
  local hs = sensors.hud
  if hs ~= nil then
    if kit.fresh(hs.shield, t.now, 10000) then
      status.fact("shield", hs.shield.value)
    end
    if kit.fresh(hs.heat, t.now, 10000) then
      status.fact("heat", hs.heat.value)
    end
  end
end

-- facts ends the reading: the first Status.json read is silent
-- (sensors.json first_change), so it is taken here, after the tick's
-- journal; then Active, InMenu and Context
function M.facts(t)
  tick = t
  if not S.have_status and sensors.status ~= nil then
    take_status(sensors.status, t.now)
    state_hook("status:change", true, t.now)
  end
  live_facts(t)
  return { active = M.active(), menu = M.in_menu(t.settings.gyro_off_gui_focus), context = M.context() }
end

-- on_pad starts the driving: when a fire trigger was pulled, which
-- ones are held, and the ship controls for the bindings' combo detector
-- (head look toggles only with them live; out of the ship it is off)
function M.on_pad(t)
  local p, st = t.pad, S.status
  if p.r2_held or p.l2_held then
    S.fired_at, S.trigger_at = t.now, t.now
  end
  S.triggers_held.l2 = p.ok and p.l2_held
  S.triggers_held.r2 = p.ok and p.r2_held
  local ship = M.in_ship(st)
  if not ship then
    sensor.set("binds", { reset_headlook = true })
  end
  sensor.set("binds", { look_controls = ship and not M.in_panel(st) })
end

-- silence is the idle tick's: head look is off
-- where presses cannot be followed; a restart keeping the game keeps it
function M.silence(t)
  if t.reason ~= "restart" then sensor.set("binds", { reset_headlook = true }) end
end

local function flag(b)
  if b then
    return 1
  end
  return 0
end

-- the parts other modules add to the state table
local parts = {}

-- debug_part adds fn(d, t) to the state table: it sets its own keys in d,
-- t being the tick context
function M.debug_part(fn)
  parts[#parts + 1] = fn
end

-- debug is the flat state table that tests follow: numbers (booleans 0
-- or 1, times ns since the session start, clock.NEVER for none) and texts;
-- then each part's keys
function M.debug()
  if tick == nil then
    return {}
  end
  local a = S.altitude
  local d = {
    hull = S.hull, music = S.music, main_menu = flag(S.main_menu), closed = flag(S.closed),
    shields_seen = flag(S.shields_seen), have_status = flag(S.have_status),
    fsd_charge_start = S.fsd_charge_start, hyperspace_start = S.hyperspace_start,
    died_at = S.died_at, shutdown_at = S.shutdown_at, fired_at = S.fired_at,
  }
  d["descent.metres"], d["descent.rate"] = a.metres, a.descent
  d["descent.ok"], d["descent.at"] = flag(a.ok), a.at
  local moments = {}
  for i, m in ipairs(S.moments) do
    moments[i] = tostring(m.kind) .. "@" .. string.format("%g", m.at)
  end
  d.moments = table.concat(moments, ",")
  local mods = {}
  for i, m in ipairs(S.modules) do
    mods[i] = m.class .. "/" .. tostring(m.size)
    if m.utility then
      mods[i] = mods[i] .. "/u"
    end
  end
  d.modules = table.concat(mods, ",")
  for _, fn in ipairs(parts) do
    fn(d, tick)
  end
  return d
end

return M
