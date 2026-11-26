# Porting the engine sounds into PERP

This guide adds only the new engine sounds to PERP. You don't need handling
changes, handling model, speed limiter, ignition key or HUD. The cars drive exactly as PERP's
vehicle scripts say. Only what you hear changes.

Paths are relative to this addon unless stated. Background: `CLAUDE.md`.

## How it fits PERP

PERP's cars come from four workshop packs:

| Pack | Holds | Changed by this port? |
|---|---|---|
| 2103606343 | TDM car models (`models/tdmcars/...`) | no |
| 2894498893 | TDM materials and stock engine recordings (`sound/vehicles/tdmcars/...`) | no |
| 2897742669 | PERP's own content (`sound/perp2.5/...`, materials, models) | gets `sound/audio_engine/` |
| 3792392486 | PERP's vehicle scripts (`scripts/vehicles/{tdmcars,jarheads,perp2}/`, plus tier copies in `used/`, `upgrade_1/`, `upgrade_2/`, `spiked/`) | no |

- **Cars are matched by model.** `sh_carlist.lua` maps 175 car models to their engine: the 165 PERP cars,
  plus 10 work and emergency vehicles on models of their own (ambulances, fire trucks, the BearCat,
  the stockade, the Transit 2016s, the courier truck).
  Every tier and variant (`used`, `upgrade_1/2`, `spiked`, `_cop`, `_taxi`...) uses the same model,
  so it gets the same engine sound.
- **Top speed comes from the spawned script.** The server reads each car's `MaxSpeed` when it spawns,
  so an `upgrade_2` car gets longer gears in the sound than a `used` one. Nothing is written back to the car.
- **The sounds are pre-rendered.** All 80 distinct engines are WAV files in `sound/audio_engine/`
  (44 engine folders plus one shared folder for road, wind, turbo and supercharger sounds, ~190 MB).
  Clients only play files: nothing is generated in game.
- **No vehicle script edits are needed.** The TDM engine recordings are muted at runtime by soundscript name.

## 1. Content

1. Copy `sound/audio_engine/` into PERP's content pack, next to `sound/perp2.5/` in 2897742669,
   and re-upload the pack. A separate pack also works, as long as the server adds it with
   `resource.AddWorkshop("<id>")` like the others.

Nothing is generated in game: a client without the files hears no engine (it prints
`[Audio Engine] no baked sounds for ...` once per engine). Ship the content before, or together with, the Lua.

The Lua and the content must match. `cl_baked.lua` names the folders the sounds live in, so ship both
together whenever the sounds are rendered again (the old Lua baker was removed; a new offline generator
is being written and has to write the same `cl_baked.lua` format).
## 2. Lua

The easiest route is a server-side addon, for example `garrysmod/addons/perp_engine_sound/`.
It only needs Lua: the content comes from the workshop pack.

```
lua/autorun/audio_engine_init.lua      (the loader below)
lua/audio_engine/sh_config.lua         copied unchanged
lua/audio_engine/sh_presets.lua        copied unchanged
lua/audio_engine/sh_drivetrain.lua     copied unchanged
lua/audio_engine/sh_carlist.lua        copied unchanged
lua/audio_engine/sh_perp.lua           copied; delete the spawn-menu block at the end (step 4)
lua/audio_engine/cl_baked.lua          copied unchanged (written by the offline renderer)
lua/audio_engine/cl_soundbank.lua      copied unchanged
lua/audio_engine/cl_engine.lua         copied unchanged
lua/audio_engine/sv_engine_sound.lua   new, step 3
```

Don't copy these files. They hold the extras:

| File | What it does |
|---|---|
| `sv_engine.lua` | ignition key that holds the car until start-up ends, brake wings (P1, SLR) |
| `sh_handling.lua`, `sv_handling.lua`, `sv_perp_physics.lua` | the handling model, PERP physics on the test script |
| `sv_cruise.lua` | speed limiter (middle mouse) |
| `cl_camera.lua` | third-person car camera |
| `cl_hud.lua` | rpm/speed HUD |
| `sh_police.lua`, `sv_police.lua`, `cl_police.lua` | emergency lightbars and light modes on job vehicles |
| `sv_seats.lua` | passenger seats |
| `lua/audio_engine_debug/` | debug menu, handling overlay, profiler |
| `lua/autorun/police_siren_init.lua`, `lua/police_siren/` | police siren: a separate module that needs the lightbars above |
| `lua/autorun/car_horn_init.lua`, `lua/car_horn/` | car horns: a separate module |
| `scripts/` | the test script cars fall back on off the PERP server |
| `addons/sl65amg_rtu/` | the example police car: a separate addon, not part of the port |

None of the ported files needs any of these. If PERP's passenger seats are parented to the car,
passengers hear it as their own car, as the driver does (`AUDIO_ENGINE.RiddenCar`).

Loader (`lua/autorun/audio_engine_init.lua`):

```lua
-- Audio Engine: engine sounds for PERP's cars (sound only)
AUDIO_ENGINE = AUDIO_ENGINE or {}

local base = "audio_engine/"
local shared = { "sh_config.lua", "sh_presets.lua", "sh_drivetrain.lua", "sh_carlist.lua", "sh_perp.lua" }
local client = { "cl_baked.lua", "cl_soundbank.lua", "cl_engine.lua" }

if SERVER then
	for _, f in ipairs(shared) do AddCSLuaFile(base .. f) end
	for _, f in ipairs(client) do AddCSLuaFile(base .. f) end
end

for _, f in ipairs(shared) do include(base .. f) end

if SERVER then
	include(base .. "sv_engine_sound.lua")
else
	for _, f in ipairs(client) do include(base .. f) end
end
```

To put the files inside PERP's gamemode instead, keep the same load order and change `base` to
the folder you put them in.

The example SL65 RTU police car is a separate addon (`addons/sl65amg_rtu/`): nothing in the files above refers to it.

## 3. Server file

Create `lua/audio_engine/sv_engine_sound.lua`. It sends each client the engine on/off state,
the driver's keys and the car's top speed, which is all the sound needs. It also sends the wing
position of the 14 cars whose spoilers hang off the dashboard gauge's animation (below). It never changes how a car drives:

```lua
--[[
	Audio Engine, sound only (server). Networks what every client's engine sound follows:
	engine on/off, the driver's keys and the car's top speed, plus the wing position of the
	cars whose spoilers move with the gauge pose. It never touches how the car drives: PERP's
	vehicle scripts stay in charge.
]]

local AudioEngine = AUDIO_ENGINE
local trackedVehicles = {}

local function track(vehicle)
	if not IsValid(vehicle) or not vehicle:IsVehicle() or not AudioEngine.GetCarConfig(vehicle) then return end
	trackedVehicles[vehicle] = true
	-- the top speed of the script it spawned with (base, used, upgrade_1/2, spiked):
	-- the clients space the gears up to it. GetVehicleParams speeds are inches/s (17.6 per mph)
	local succeeded, params = pcall(vehicle.GetVehicleParams, vehicle)
	if succeeded and istable(params) and istable(params.engine) and (params.engine.maxSpeed or 0) > 0 then
		vehicle:SetNW2Float("audio_vmax", params.engine.maxSpeed / 17.6 * 1.609344)
	end
end

hook.Add("OnEntityCreated", "audio_engine", function(entity)
	timer.Simple(0, function() track(entity) end)
end)

-- on = start-up sound (or the stop sound when off); instant = straight to idle, no start-up
function AudioEngine.SetEngine(vehicle, on, instant)
	vehicle:SetNW2Bool("audio_on", on)
	if on then
		local carConfig = AudioEngine.GetCarConfig(vehicle)
		vehicle:SetNW2Float("audio_on_t", instant and 0 or CurTime())
		-- high-powered cars rev-flare on start-up (sh_carlist.lua CAR_EMOTION)
		vehicle:SetNW2Bool("audio_emo", carConfig ~= nil and carConfig.emotionStart == true)
	end
end

-- like TDM's stock sounds: the engine starts as the driver gets in and stops as they get out
hook.Add("PlayerEnteredVehicle", "audio_engine", function(player, vehicle)
	if not trackedVehicles[vehicle] then track(vehicle) end
	if trackedVehicles[vehicle] and not vehicle:GetNW2Bool("audio_on", false) then AudioEngine.SetEngine(vehicle, true) end
end)

hook.Add("PlayerLeaveVehicle", "audio_engine", function(player, vehicle)
	if trackedVehicles[vehicle] then AudioEngine.SetEngine(vehicle, false) end
end)

-- the driver's W / S / Space / steering, for the rpm model on every client
hook.Add("Think", "audio_engine", function()
	for vehicle in pairs(trackedVehicles) do
		if not IsValid(vehicle) then
			trackedVehicles[vehicle] = nil
		else
			local driver = vehicle:GetDriver()
			local inputBits = 0
			if IsValid(driver) then
				if driver:KeyDown(IN_FORWARD) then inputBits = inputBits + 1 end
				if driver:KeyDown(IN_BACK) then inputBits = inputBits + 2 end
				if driver:KeyDown(IN_JUMP) then inputBits = inputBits + 4 end
				if driver:KeyDown(IN_MOVELEFT) ~= driver:KeyDown(IN_MOVERIGHT) then inputBits = inputBits + 8 end
			end
			if inputBits ~= vehicle.audioInputBits then
				vehicle.audioInputBits = inputBits
				vehicle:SetNW2Int("audio_in", inputBits)
			end
		end
	end
end)

-- wings and vents that hang off the vehicle_guage pose (sh_carlist.lua GAUGE_PARTS, 14 models):
-- cl_engine points that pose at the revs for the tach needle on other cars, and on these at the
-- position sent here, picked from speed. Without it their wings stay at rest.
local WING_STEP = 0.02
hook.Add("Tick", "audio_engine_wings", function()
	for vehicle in pairs(trackedVehicles) do
		local carConfig = IsValid(vehicle) and AudioEngine.GetCarConfig(vehicle)
		local gaugeParts = carConfig and carConfig.gaugeParts
		local physics = gaugeParts and vehicle:GetPhysicsObject()
		-- parked (physics asleep, no driver) with the wings down: nothing moves until it's woken
		local asleep = physics and IsValid(physics) and physics:IsAsleep() and not IsValid(vehicle:GetDriver())
		if gaugeParts and not (asleep and vehicle.audioWingsSettled) then
			local speedKmh = IsValid(physics) and physics:GetVelocity():Length() * 0.09144 or 0   -- in/s -> km/h
			local topSpeed = AudioEngine.CarTopSpeed(vehicle, carConfig)
			local pose = math.Round(AudioEngine.WingPose(vehicle, gaugeParts, speedKmh, topSpeed) / WING_STEP) * WING_STEP
			if pose ~= vehicle.audioWingSent then
				vehicle.audioWingSent = pose
				vehicle:SetNW2Float("audio_wing", pose)
			end
			vehicle.audioWingsSettled = asleep
		end
	end
end)

-- the start key (audio_engine_startkey, R by default) sends this from every client. This port
-- has no ignition, so it does nothing: without it the server prints "Unknown command"
concommand.Add("audio_engine_toggle", function() end)

-- lua refresh
for _, entity in ipairs(ents.GetAll()) do track(entity) end
```

The start-up sound takes about a second, as TDM's did. The car can already drive during it, and
the revs pick up once it ends. Each client runs the rpm and gear model from these networked keys,
so the server sends only a few bits per car whenever a key changes.

**If PERP has its own ignition** (keys, fuel, engine toggle), delete the two `PlayerEnteredVehicle` /
`PlayerLeaveVehicle` hooks. Then call `AUDIO_ENGINE.SetEngine(veh, true/false)` wherever PERP turns
an engine on or off. Use `instant = true` for a car that should already be running, with no start-up sound.
The empty `audio_engine_toggle` command is where the R key lands, if PERP wants it to switch the engine.

## 4. Stock TDM sounds

`sh_perp.lua` mutes the old engine recordings at runtime. It points their soundscripts (`242turbo_idle`,
`370z_firstgear`...) at `common/null.wav` on the server and on every client, across every tier and variant
of every car in `sh_carlist.lua` (the work and emergency vehicles too: they have new engines).
It keeps any name a vehicle left on its old sound also uses: the bus, the airtug and the pedal cycle,
whose scripts play raw `.wav` paths or have no engine. The server console prints how many it muted and kept.
No vehicle script needs editing, and a newly added car is picked up as soon as it is in `sh_carlist.lua`.

In `sh_perp.lua`, delete everything from `-- spawn menu entries` to the end. It lists the cars and job
vehicles in the sandbox spawn menu and sets the job livery skin on cars spawned from it, for testing only.

Server convars (replicated):

| Convar | Default | Effect |
|---|---|---|
| `audio_engine_mutestock` | 1 | mute the TDM engine recordings of the 175 cars |
| `audio_engine_muteskid` | 1 | mute the TDM brake screech (`tdmcars_skid`, `_less`; spiked rim scrape kept) |
| `audio_engine_mutetyrescrape` | 1 | mute the glass-bottle/dirt scrape of sliding tyres (global game sounds) |

The last two aren't engine sounds. Set them to 0 to keep PERP's tyre sounds as they are now.
The new tyre roar and wind sound play either way.

## 5. What players can change

Client convars, all optional:

| Convar | Default | Effect |
|---|---|---|
| `audio_engine_volume` | 1 | engine volume (0-2) |
| `audio_engine_roadnoise`, `audio_engine_windnoise` | 1 | tyre roar and wind (0-2) |
| `audio_engine_doppler` | 1 | Doppler pitch of passing cars (0 = off, 1 = real, up to 4) |
| `audio_engine_passby` | 1 | how much cars swell in loudness passing close (0-2) |
| `audio_engine_tunnel` | 1 | echo for cars in tunnels (0 = off, 1 = the map's own, 7 = large tunnel) |
| `audio_engine_range` | 250 | metres past which a car goes quiet and stops playing (louder cars carry further; 0 = no limit) |
| `audio_engine_maxcars` | 16 | how many cars are heard at once, the nearest (0 = all) |

`audio_engine_range` and `audio_engine_maxcars` keep busy areas within the game's limit on sounds playing
at once. Set too high, sirens and the game's own sounds can drop out when many cars drive together.
`audio_engine_startkey` does nothing in this port (step 3).

## 6. Test

1. Check coverage against PERP's real packs:
   `node dev/baker/test_integration.js <workshop>/3792392486/content <workshop>/2103606343/content <workshop>/2897742669/content`
   Pass every pack that holds a car model: the work vehicles' models (`models/sickness/`, `models/forest/`,
   `models/ezza/`, `models/perp2.5/`...) are not in the TDM pack. It must end with `all checks passed`.
   It currently reports `baked banks: 175 cars, 80 distinct engines, 80 load from baked files`.
2. On the server:
   - Every PERP car starts when you get in, revs and changes gear with its own sound, and stops when you get out.
   - No TDM recording plays underneath.
   - Fire trucks, ambulances and the other work vehicles have their new engines; the bus still uses its old sound.
   - The server console shows `[Audio Engine] muted ... TDM engine sounds`.
   - A client with the content shows no `[Audio Engine] no baked sounds for ...` lines in console.

