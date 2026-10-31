# Porting into PERP (baked sounds only)

Moving the system into PERP's own files, with no in-game sound generation.
Background: `CLAUDE.md` and the code. Paths below are relative to this addon.

## 1. Content
1. Re-bake if the synth or car list changed: `cd dev/baker && node bake.js`
2. Put `sound/audio_engine/` into PERP's content workshop addon.
3. Clients must download it: `resource.AddWorkshop("<content id>")`

## 2. Lua files
1. Copy into PERP's gamemode, e.g. `gamemode/modules/audio_engine/`.
2. Shared, in this order: `sh_config`, `sh_presets`, `sh_drivetrain`, `sh_carlist`, `sh_perp`.
3. Client: `cl_baked`, `cl_soundbank`, `cl_engine`, `cl_hud` (optional).
4. Server, in this order: `sv_perp_physics`, `sv_handling`, `sv_engine`, `sv_stability`.
5. Skip `cl_synth.lua` and `cl_menu.lua` (the generator and the tuning menu).
6. Define `AUDIO_ENGINE = AUDIO_ENGINE or {}` before the first include.
7. Mirror `lua/autorun/audio_engine_init.lua` (AddCSLuaFile + include), then delete it.

## 3. Strip generation from `cl_soundbank.lua`
1. Delete `build`, `buildEnv` and the DSP helpers above them.
2. Delete the `Think` queue hook, `prebuild` and `Bank.RebuildAll`.
3. Also delete `audio_engine_rebuild` and both `cvars.AddChangeCallback` calls.
4. Delete the convars `samplerate`, `genbudget`, `maxsounds` and `baked`.
5. Keep `Bank.EmotionFlareKey`, `bakedFiles`, `bakedEntry`, `bakedBank`, `bakedEnv`.
6. In `bakedFiles`, drop the `cvBaked` check.
7. Replace `Bank.Build`, `Bank.Get` and `Bank.GetEnv` with:

```lua
local NOBANK = { ready = false }

-- false = no baked files for this engine (checked once, not every frame)
function Bank.Build(cfg)
	local b = bakedBank(cfg) or false
	Bank.list[cfg.id] = b
	return b or nil
end

local function find(cfg)
	local b = Bank.list[cfg.id]
	if b == nil then b = Bank.Build(cfg) end
	return b or nil
end

-- a tuned engine without baked files plays the car's stock sound
function Bank.Get(cfg, fallback)
	return find(cfg) or (fallback and find(fallback)) or NOBANK
end

function Bank.GetEnv()
	Bank.env = Bank.env or bakedEnv() or NOBANK
	return Bank.env
end
```

## 4. Server tuning (optional)
1. No menu: remove the `audio_engine_set` receiver in `sv_engine.lua`.
2. Also remove the `!engine` `PlayerSay` hook there.
3. Keeping tuning? Only runtime fields change sound (see note).

Note: turbo, BOV, volumes and pop frequency work without generation. Fields in
`cfg.soundKey` (layout, pitch, tone, idle, redline, realism, gurgle, popTone) fall back
to the stock sound, except a lower redline within the same family (`E.BAKED_FAMILY`).

## 5. Stock TDM sounds
1. In PERP's vehicle scripts, set each engine `State`'s `"Sound"` to `""`.
2. Leave `CrashSound` and `Skid_*` lines untouched.
3. States: `SS_START_IDLE`, `SS_IDLE`, `SS_SHUTDOWN`, `SS_REVERSE`,
   `SS_GEAR_0`-`SS_GEAR_4`, `SS_GEAR_0_RESUME`-`SS_GEAR_4_RESUME`, `SS_SLOWDOWN`,
   `SS_SLOWDOWN_HIGHSPEED`, `SS_TURBO`, `SS_START_WATER`, `SS_SHUTDOWN_WATER`.
4. Example: `scripts/vehicles/plpd/sl65amg_rtu.txt`.
5. Edit scripts; don't redefine soundscripts (service vehicles share some, below).
6. Then remove the mute code from `sh_perp.lua`.
7. Also remove its spawn-menu block (sandbox testing only).

Shared soundscripts: `crownvic_*` (perp2/ambulance), `f350_*` (perp2/f350_firetruck),
`transit_*` (jarheads/transit2016, perp2/ambulance), `dodgeram_*` and `charger2012_idle`
(tdmcars/dodgeramff).

## 6. Ignition and HUD
1. Server convar `audio_engine_autostart 0`: the driver starts the engine.
2. Start key: client `audio_engine_startkey` (default I), or `audio_engine_toggle`.
3. Both call `E.ToggleEngine(veh)`; wrap it to check keys/fuel.
4. Force on/off (e.g. no fuel): `E.SetEngine(veh, on, instant)`.
5. PERP has its own HUD? Leave out `cl_hud.lua`.

## 7. Test
1. Syntax check: `node dev/baker/check_syntax.js`
2. Baked coverage: `node dev/baker/test_integration.js <mount folders>`
3. In game: every car audible, `cl_synth` never loaded.
4. Console must show no `generated ... sounds` lines.
