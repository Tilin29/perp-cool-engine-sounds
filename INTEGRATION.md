# Bringing the Audio Engine into PERPHeads

This is the log of how the procedural engine was fitted to PERPHeads' cars, and the
checklist for the developer who drops it into the live addons. Everything here lives in this
addon folder. Nothing in PERP's own addons or content was changed, and no models were copied:
cars are matched by the model paths PERP already uses.

## 1. What PERP's car system is (from the installed content)

The PERP gamemode's Lua isn't on the workshop: across the ten installed addons (workshop app
4000: content 1, the Paralake maps, the dev pack 3792392486, TDM Cars 2103606343...) the only Lua
file is an empty placeholder. The car system therefore had to be reconstructed from the content:

| Piece | Where | What it tells |
|---|---|---|
| Car models | `models/tdmcars/*.mdl` (TDM pack 2103606343, 174 models), `models/sickness/stretchdr_tdmcars.mdl`, `models/perp2.5/swat_van*.mdl` | every sellable car is a TDM model, used in place |
| Handling | `scripts/vehicles/{tdmcars,jarheads,perp2}/<car>.txt` in the dev pack (879 scripts) | PERP's own vehicle scripts (authored by StephenPuffs, Xquality...) |
| Car tiers | same name under `used/`, `upgrade_1/`, `upgrade_2/`, `spiked/` | **used**: torque split shifted rearward (worn). **upgrade_1/2**: more MaxSpeed, lower MaxRPM, softer springs. **spiked**: wheels shrink 15 → 12, ice/snow tyre materials, torque moved to one axle (stingers) |
| Variants | `<car>_cop`, `_taxi`, `_unmarked`, `_medic`, `_fire`, `_police` | emergency versions: same model, own script (e.g. SL65 cop: 330 hp, 130 mph, stiffer springs) |
| Engine sound | each script's `Vehicle_Sounds` → `State` blocks (`SS_IDLE`, `SS_GEAR_n`...) naming TDM soundscripts (`slsamg_idle`, `slsamg_firstgear`...) → `sound/vehicles/tdmcars/<car>/*.wav` | stock Source jeep sound: one recording per gear state |
| Other car assets | `models/perpheads/vehicles/license_plate*.mdl`, `taxi_sign.mdl`, `sound/jarheads/vehicles/*` (doors, indicators, car wash), `sound/jarheads/sirens/*`, `sound/perp2.5/car_horn*.wav`, `materials/lelios/road_spikes` | plates, taxi sign, indicators, horns, sirens, spike strips: all PERP gamemode features that this addon leaves alone |

So a PERP car is just `prop_vehicle_jeep` + TDM model + one of PERP's scripts for its tier. The
engine sound system keys off the **model**, so it follows a car through every tier and variant
without knowing which one PERP spawned.

## 2. What was added to this addon

| File | What |
|---|---|
| `lua/audio_engine/sh_carlist.lua` | `E.CAR_MODELS`: all 165 cars from the engine list (`Engine Types.xlsx`) → model, PERP base script, wheel radius (read from the script). All registered at load. `E.PERP_STABILITY = false`: the steering assist stays off on PERP cars (PERP tunes their handling; spiked tyres must stay undrivable) |
| `lua/audio_engine/sh_perp.lua` | PERP glue: mutes the TDM engine recordings of registered cars (section 4), and lists all 165 cars in the spawn menu (Vehicles → *PERP cars (Audio Engine)*) for testing in sandbox |
| `lua/audio_engine/cl_baked.lua` | **generated** manifest of the pre-generated sounds |
| `sound/audio_engine/<preset>_<redline>_<hash>/*.wav` | **pre-generated** engine sounds: one folder per distinct stock engine (73, e.g. `v8x_6500_2cf9f8`), plus `env_<hash>/` (road, wind, turbo whistle, blow-off) |
| `lua/audio_engine/cl_soundbank.lua` | loads a baked bank when one exists for the engine's sound key, otherwise generates as before |
| `dev/baker/` | the offline renderer (Node + wasmoon running the addon's own Lua), plus `check_syntax.js` and `test_integration.js` |
| `dev/perp_carmodels.py` | rebuilds the car → model / script table from the PERP dev pack |

### Pre-generated sounds
The sounds are still made by the same synthesizer, but offline: `dev/baker/bake.js` runs
`cl_soundbank.lua`'s real build for every stock engine and writes what `sound.Generate` would
have received as 16-bit mono WAVs (loops carry a `cue ` point at sample 1, the loop start
`sound.Generate` uses). Clients play those files; nothing is generated for a stock car, and only
a car retuned in the `!engine` menu is generated in game (~2 s CPU, as before).

- 165 cars share **73 distinct engines** (same preset + same per-car changes = same sounds).
  The spreadsheet's 25 engine+turbo types become 73 because many cars carry their own redline,
  idle or tone (`stock = {...}` in `CAR_ENGINES`), and each of those is its own set of loops. The
  turbo isn't one of them: it is a shared layer played on top.
- Size: 275 MB at 44.1 kHz (3.2–4 MB per engine). `node bake.js --rate 22050` halves it.
- A bank is only loaded when a car using that engine is near the player.
- Folders are named `<preset>_<redline>_<hash>` after the engine, not a car: cars with the same
  engine share one folder (`cl_baked.lua` lists the cars of each). The hash covers the sound key
  and the synth sources, so a re-bake after any synth change writes new names and no client
  plays a stale cached copy.
- Without the content (or with `audio_engine_baked 0`), everything still works by generating.

## 3. Checklist: introducing it on the server

1. **Install** this folder as an addon on the server (`garrysmod/addons/`). The Lua is sent to
   clients automatically.
2. **Ship the sounds to clients.** `sound/audio_engine/` (275 MB) must reach players: add it
   to PERP's content workshop addon (easiest: alongside the dev content pack) or FastDL. Only
   `sound/audio_engine/` and the `lua/` folder are needed; `dev/` stays out of the release
   (`addon.json` ignores `dev/*`; it used to ignore `*.wav`, which would have dropped the baked sounds).
   `models/plpd/`, `materials/plpd/` and `scripts/vehicles/plpd/` are the RTU SL65 and are only
   needed if the police keep that example car.
3. **Silence the TDM engine recordings** (section 4). Out of the box this is done at runtime;
   the clean fix is to empty the engine states in PERP's scripts.
4. **Decide the ignition** (section 5): PERP keys/fuel vs. this addon's start key.
5. **Lock down the tuning menu.** `audio_engine_tuneaccess 1` (default) = admins only. To keep
   players out entirely use `2` (superadmins). The chat command `!engine` / `/engine` is
   swallowed by `PlayerSay`: check it doesn't collide with a PERP command.
6. **HUD.** The addon draws its own speed/rpm/gear HUD. If PERP's car HUD stays, set
   `audio_engine_hud 0` as the client default (or remove `cl_hud.lua` from the loader).
7. **Test** on a dev server (section 7).

## 4. Muting the stock engine sound

Each PERP script still names TDM soundscripts for its engine states, and Source plays them on
its own.

**Runtime (default, `sh_perp.lua`):** at `InitPostEntity` (and again 3 s later, as TDM / PERP
define their soundscripts in their own autorun files), every soundscript named in an engine
`State` of a registered car's scripts (base, the four tier folders, `<base>_*` variants and
`tdmcars/charger_cop`) is redefined to `common/null.wav`, on server and client. Names that any
other vehicle script uses too are kept, so the bus, ambulances, fire and tow trucks, SWAT van,
Bearcat, airtug, courier truck and tricycle keep their sound. The originals are saved first;
`audio_engine_mutestock 0` puts them back. Crash and skid sounds are untouched. Offline this mutes 904 soundscripts and keeps 32 shared ones.

**Five cars still play their TDM recording with the runtime mute**, because PERP's service
vehicles reuse their soundscripts (muting them would silence those vehicles):

| Registered car | Soundscripts | Also used by |
|---|---|---|
| Ford Crown Victoria | `crownvic_*` | `perp2/ambulance` |
| Ford F350 | `f350_*` | `perp2/f350_firetruck` |
| Ford Transit | `transit_*` | `jarheads/transit2016`, `perp2/ambulance` (slowdown) |
| Dodge RAM SRT10 | `dodgeram_*` | `tdmcars/dodgeramff` |
| Dodge Charger 2012 | `charger2012_idle` | `tdmcars/dodgeramff` |

For these five, do the permanent fix below on their scripts (base, tiers and `_cop` / `_taxi` /
`_unmarked` variants), or give the service vehicles the procedural engine too (section 8).

To verify in game: `lua_run_cl for k in pairs(AUDIO_ENGINE.PERP_MUTED) do print(k) end`, and drive a
car: there should be only the procedural engine. If a TDM recording still plays, that
soundscript was (re)defined after the mute ran; call `AUDIO_ENGINE.ApplyStockMute()` after
PERP's vehicle sounds are set up (both realms).

**Permanent (recommended):** in PERP's scripts for the 165 cars (and their tiers/variants), set
the `"Sound"` of every engine `State` to `""`, like `scripts/vehicles/plpd/sl65amg_rtu.txt` in
this addon. Leave `CrashSound` and the `Skid_*` lines. Then set `audio_engine_mutestock 0`.
The engine states are: `SS_START_IDLE`, `SS_IDLE`, `SS_SHUTDOWN`, `SS_REVERSE`,
`SS_GEAR_0`–`SS_GEAR_4`, `SS_GEAR_0_RESUME`–`SS_GEAR_4_RESUME`, `SS_SLOWDOWN`,
`SS_SLOWDOWN_HIGHSPEED`, `SS_TURBO`, `SS_START_WATER`, `SS_SHUTDOWN_WATER`.

## 5. Ignition, keys and fuel

By default a registered car is **off** when someone gets in, and the driver starts it with **I**
(`audio_engine_startkey`, per player) or `audio_engine_toggle`. The server holds the car
(`EnableEngine(false)`) until the start-up sound reaches idle.

- If PERP has its own ignition/keys: set `audio_engine_autostart 1` (engine starts when the driver
  enters), or drive it from PERP's code instead:
  - `AUDIO_ENGINE.SetEngine(veh, true)` starts with the start-up sequence; `SetEngine(veh, true, true)` is instant
  - `AUDIO_ENGINE.SetEngine(veh, false)` switches off (e.g. out of fuel, engine destroyed, impounded)
  - `AUDIO_ENGINE.ToggleEngine(veh)`
  - Set the start key to `none` so players use PERP's key instead.
- `audio_engine_keeprunning 1` keeps the engine idling after the driver leaves.
- Don't call `EnableEngine` / `StartEngine` on a registered car from PERP code while the engine
  is off: `sv_engine.lua` re-asserts its own state every tick while a driver is in.

## 6. Upgrades, tiers and engine tuning

- PERP's tiers are vehicle scripts, so the physics come from PERP. The engine reads the car's
  `MaxSpeed` when it spawns (`audio_vmax`) and fits the gearing to it, so an `upgrade_2` car
  revs out at its higher top speed with no extra work.
- If PERP changes a car's params **after** spawning it (`SetVehicleParams`), clear the cached
  base with `veh.audioBase = nil`, then call `AUDIO_ENGINE.ApplyPerformance(veh, AUDIO_ENGINE.DecodeProfile(veh:GetNW2String("audio_prof", "")))`.
- Engine upgrades could be sold through PERP's shop by setting the car's profile server-side:
  `veh:SetNW2String("audio_prof", AUDIO_ENGINE.EncodeProfile(prof))` then `E.ApplyPerformance(veh, prof)`
  (start from `E.CarStockProfile(E.GetCarConfig(veh))`, change `accel`, `vmax`, `turbo`, `pops`...).
  A tuned engine is generated on nearby clients (~2 s), so keep tuned sounds rare: turbo, BOV,
  volumes and pop frequency are runtime layers and never cost a generation.
- The profile is networked per entity and isn't saved: if PERP persists cars, store the string
  with the car and set it back on spawn.

## 7. Testing

Offline (from `dev/baker`, after `npm install`):
- `node check_syntax.js`: every Lua file compiles.
- `node test_integration.js <folder with the dev pack's scripts/>`: runs the real `sh_perp.lua` and
  `cl_soundbank.lua`: how many soundscripts get muted, that service vehicles keep theirs, that
  all 165 cars load a baked bank and every file it names exists.

In game (not done yet, nothing here has run inside Garry's Mod):
1. Spawn a few cars from *Vehicles → PERP cars (Audio Engine)* on a sandbox dev server with the
   PERP content mounted. Console: `[Audio Engine] muted N TDM engine sounds...`, and no
   `generated N sounds` lines for stock cars (they load baked files).
2. Check the loops play seamlessly at a steady rpm (the WAV cue point) and that only the
   procedural engine is heard.
3. Spawn the same car with its `upgrade_2/` and `spiked/` script: engine still present, gearing
   follows the top speed.
4. On the PERP gamemode: buy/spawn cars through the dealer, check ignition with PERP's own
   key/lock flow, and look at 30–40 cars together (each running car plays ~4–6 sound patches).

## 8. Open points for the PERP developer

- **Mappings to confirm** against PERP's dealer table (matched from file names, with no PERP Lua to check):
  - Mercedes G-Class → `models/tdmcars/gwagon.mdl` + `jarheads/gwagon` (there's also an unused `models/tdmcars/mercedes.mdl`)
  - Porsche 911 GT3 → `models/tdmcars/gt3rs.mdl` + `jarheads/gt3rs`
  - Dundreary Limousine → `models/sickness/stretchdr_tdmcars.mdl` + `perp2/stretch`
  - Ford Crown Victoria → `models/tdmcars/crownvic_taxi.mdl` (one model for the civilian, cop, unmarked and taxi scripts)
  - Subaru Impreza WRX STI → `sub_wrxsti08.mdl` + `subimpreza08` (`subimpreza.txt` is a second, unmatched Impreza script)
- **Not registered** (not in the engine list): bus, ambulances, fire trucks, tow trucks, SWAT van,
  Bearcat, Transit 2016, airtug, courier truck, Porsche tricycle, `lee`, `dodgeramff`, `cit_2cv`.
  They keep their TDM sound. To give one the procedural engine, add it to `CAR_ENGINES` and
  `CAR_MODELS` in `sh_carlist.lua` and re-bake.
- Adding or changing a car's engine: edit `sh_carlist.lua`, then `cd dev/baker && node bake.js`, and
  ship the new `sound/audio_engine/` and `cl_baked.lua` together. Same after any change to
  `cl_synth.lua`, `cl_soundbank.lua` or `sh_presets.lua`; until re-baked, changed engines fall
  back to in-game generation.
- Vehicle scripts in addons other than `tdmcars/`, `jarheads/` and `perp2/` aren't scanned by the
  mute. If such a script shares a soundscript name with a PERP car, that vehicle goes quiet too.
