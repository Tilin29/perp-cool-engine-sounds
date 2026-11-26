# Audio Engine

Synthesized engine sound (rendered offline, shipped as WAVs), rpm/gear model and speed / rpm HUD for Garry's Mod cars: all 165 PERPHeads cars, plus an example police car (Mercedes SL65 AMG, RTU liveries) with its own model, in a separate addon (`addons/sl65amg_rtu/`, temporary: not part of the final addon).

**Requires** the TDM Cars content (shared materials and wheels), same as the model.

## Install
Drop this folder into `garrysmod/addons/`. For the example car, also copy `addons/sl65amg_rtu/` into `garrysmod/addons/` (it is its own addon: GMod doesn't load addons inside an addon). Spawn it from **Vehicles → Police**:
- SL65 AMG (Police): skin 0
- SL65 AMG (RTU Blue): skin 1
- SL65 AMG (RTU Yellow): skin 2

## Starting the engine
The engine is off when you get in, and the car is silent and can't drive. Press **R** to start it: it cranks, catches, flares and settles to idle, and the car only drives once that has finished (about 2 s, or about 3.5 s with the rev flare). Press **R** again to switch it off.
- Pick your own key with `audio_engine_startkey` (a key name such as `k` or `f1`, or `none`). `bind <key> audio_engine_toggle` also works.
- `audio_engine_autostart 1` on the server starts the engine by itself when a driver gets in (the car still waits for the start-up to finish).

## Debug tools (not for the final version)
A separate module on top of the addon, for tuning on a test server: `lua/audio_engine_debug/`. It loads automatically whenever that folder is there, so delete the folder to ship without it. It's on by default (`audio_engine_debug 0` switches it off), and only superadmins (or the host of a listen or single-player game) can use it. Open it with `audio_engine_debug_menu`, `!enginedebug`, or right-click a car → **Engine debug tools**. It works on the car you're in or looking at. Every change is a live test: copy what works back into the files. The pages are:
- **Handling script:** loads the vehicle script the car is linked to and lets you edit every value. **Apply live** puts the changes on the car. Values marked `respawn` (wheel radius, materials, sounds) only take effect when the car spawns. **Copy txt** puts the whole edited file on the clipboard, and **Save to data/** writes it to `garrysmod/data/audio_engine_debug/scripts/`, so it can go into PERP's script pack. Without PERP's scripts mounted, it shows `test_car.txt` carrying PERP's physics values (what the car really drives on) and says so.
- **Gearing:** the number of gears (1–8) and, per gear, the speed and rpm where it changes up and the speed it changes down under. The gears don't have to be evenly spaced, and each line shows how far the revs drop at the shift. A drop under 12% is flagged as barely audible, and every gear is kept at least 10% taller than the one below. A chart shows the full-throttle sawtooth. **Apply live** applies it for everyone. **Copy for sh_carlist** gives an `E.CAR_GEARING` entry.
- **Rev response:** how fast the revs climb and drop back when you rev standing still (Space + W), for this car or every car, with the time to rev and fall back and a chart against the default. **Copy** gives an `E.CAR_REV` entry or the `DT.REV` line.
- **Handling:** one switch for PERP's own handling (anti-spin setup, traction control and stability control all off), each of them on its own, and their main values (slide power cut, straight-line hold, grip, lock at speed) live.
- **Settings:** the client and server convars and the test commands as controls.

## How the sound works
Every engine's sounds are synthesized (no recordings), rendered offline and shipped as WAV files in
`sound/audio_engine/`, described by `lua/audio_engine/cl_baked.lua`. Nothing is generated in game, so cars load
instantly and cost no CPU. There's no in-game engine editor. The old Lua synthesizer and its tools were removed;
a new offline generator is being written, and until it exists the shipped sounds stay as they are.
## PERPHeads cars
All 165 PERP cars use this engine, matched by the TDM/PERP model they already use (no models are included here), whatever tier script PERP spawns them with (used, upgrades, spiked, cop...). Their TDM engine recordings are muted (`audio_engine_mutestock`). For testing in sandbox they're listed under **Vehicles → PERP cars (Audio Engine)**. The developer log for putting this on the PERP server is `INTEGRATION.md`.

What each engine ships:
- One loop per rpm point (about 1.26× apart), on and off throttle. Each is pitched by at most about ±12% and cross-faded, so the exhaust resonances stay put.
- A rev-limiter loop, start-up sounds (normal and "emotion"), a shut-down sound, pops and bangs.
- Shared by every car: tyre roar, wind, the turbo whistle, two blow-off sounds, the electric cars' sounds and the supercharger whine. So switching the turbo or blow-off valve on or off, or changing their volume, needs no new engine sounds.
Every car gets a small random detune (±1.5%), so a row of them doesn't sound like one cloned recording.

Playback is kept clean:
- Every loop glides to its new volume instead of jumping once per frame, which would click (zipper noise).
- Each car keeps its own mix under full scale, using the measured peak of every sound, including pops and bangs that overlap. Revving in neutral may go a few dB louder than driving.

Around the engine:
- **Doppler:** a car coming toward you sounds higher, and drops in pitch as it passes, from the real speeds of the car and of you, at four times the real shift so a drive-by stands out. At 130 km/h that's about +72% then −30%. Your own car is never shifted.
- **Tyre roar and wind:** a road roar that grows with speed, and a faint wind that only becomes noticeable near top speed. They're shared by every car. They play even with the engine off, while the car rolls.

The rpm and gear come from a small automatic-gearbox model:
- It uses the car's real speed and the driver's keys.
- Pulling away, the torque converter flares to about 2,300 rpm, then the revs climb with the car.
- The gearbox is arcade-style, because W and S are on/off keys:
  - **W held:** each gear runs to 92% of redline, then shifts up (briefly pulling torque). If the revs are under 60% when you press W, it kicks down, skipping gears if needed.
  - **Coasting:** it keeps the gear, and the revs fall with the car. It only changes gear if it would over-rev or lug.
  - **Braking:** once the engine drops below 80% of redline, it shifts down one gear, as long as the lower gear lands under 96%. Each downshift is rev-matched with a throttle blip.
  - All shift points are in the `shift` table in `sh_config.lua`. The comments there give them in rpm for the SL65.
- Holding **Space + W** at a standstill revs it in neutral against the limiter. It's a few dB louder than driving.

The HUD tachometer and the model's own dashboard tach needle both follow the revs.

## Handling
**Using your own vehicle script** (for example a server's `sl65amg_cop.txt`): the handling comes from that script, not the one in this addon. Things that make a car spin:
- a raised `MassCenterOverride` (positive z)
- a very low `StabilizerConstant`
- `SteeringExponent` 0, so any tap of A/D is full lock
- `SkidMaterial` set to `jeeptire`, so slides snap back

Also remove the engine `Gear`/`State` sounds from that script, or they play on top of this addon's engine.

`addons/sl65amg_rtu/scripts/vehicles/plpd/sl65amg_rtu.txt` is tuned to be calm on its own:
- lower centre of mass and a cap on body rotation speed
- near-neutral anti-roll balance, so it turns in properly
- less rear brake bias and slight front drive
- only a touch of power cut while steering

### Handling model
Source simulates every car on the server only, so crashes between players always agree. On the server
(`sv_handling.lua`), Source's jeep still handles the engine, brakes, suspension and every collision. On top of it,
a handling model (`sh_handling.lua`) takes over the car's rotation and sideways grip each tick. The rotation
follows what the steering asks at that speed (never more than the tyres can hold), and a slide loses its sideways
speed at the grip limit. It never adds speed along the nose, so it can't launch a car. The handbrake lets the rear
go and starts a drift, which lasts while the car stays sideways. A spin is caught. After a crash the model lets go
until the crash has played out. Spiked tyres get no model.

Cars are drawn where Source has them. (A client-side driving prediction was tried and removed.)
## Convars
| Convar | Realm | Default | |
|---|---|---|---|
| `audio_engine_volume` | client | 1 | engine volume, 0–2 |
| `audio_engine_roadnoise` | client | 1 | tyre roar volume, 0–2 (0 = off) |
| `audio_engine_windnoise` | client | 1 | wind volume, 0–2 (0 = off) |
| `audio_engine_doppler` | client | 1 | Doppler on passing cars, 0 = off, 1 = real, 4 = four times real (the maximum) |
| `audio_engine_police_doppler` | client | 1 | Doppler on passing police sirens, 0 = off, 1 = default (half of real), 2 = real |
| `audio_engine_passby` | client | 1 | how much passing cars swell in loudness, 0 = off, up to 2 |
| `audio_engine_tunnel` | client | 1 | Source DSP preset for cars in tunnels, 0 = off, 1 = the map's own, 6 = medium tunnel, 7 = large tunnel |
| `audio_engine_hud` | client | 1 | show the HUD |
| `audio_engine_units` | client | mph | `mph` or `kmh` |
| `audio_engine_hud_scale` | client | 1 | HUD size |
| `audio_engine_startkey` | client | r | key that starts and stops the engine (`none` = no key) |
| `audio_engine_mutestock` | shared | 1 | silence the TDM engine recordings of cars that use this engine |
| `audio_engine_muteskid` | shared | 1 | silence the TDM tyre screech when braking (shared by all TDM cars) |
| `audio_engine_mutetyrescrape` | shared | 1 | silence the scrape of sliding tyres (a global change: glass bottle and dirt surface sounds) |
| `audio_engine_autostart` | server | 0 | 1 = start the engine when a driver gets in; 0 = the driver starts it |
| `audio_engine_emotionstart` | server | 1 | rev flare on start-up (high-powered cars only: `CAR_EMOTION`) |
| `audio_engine_keeprunning` | server | 1 | keep idling after the driver gets out (0 = getting out switches the engine off; not saved, set it in server.cfg) |
| `audio_engine_cruise` | server | 1 | speed limiter on registered cars (middle mouse switches it, the mouse wheel sets the limit) |
| `audio_engine_drivemodel` | shared | 1 | the handling model on registered cars (rotation follows the steering, grip limit, handbrake drifts); 0 = Source's own tyres alone |
| `audio_engine_debug` | shared | 1 | the debug tools for superadmins; 0 = off (debug module only) |

Commands:
- `audio_engine_debug_menu` opens the debug tools (also `!enginedebug`; superadmins, debug module).
- `audio_engine_handling_info` (admins) prints the handling setup of the car you're in or looking at.
- `audio_engine_accel_log [seconds]` (admins) logs speed, gear, rpm, the steering and the rotation asked vs. what the car does, to the console (default 12 s, max 60).
- `audio_engine_toggle` (bindable) switches the engine of the car you're driving on or off, like the start key.
- `audio_engine_wingflap` (superadmins) shows the brake flap for 10 s on the P1 or SLR you're in or looking at.
- `audio_engine_bonedump` (superadmins) writes the bone manipulations of the car you're in or looking at to `data/audio_engine_bones.txt`.

## Files to edit
- `lua/audio_engine/sh_carlist.lua`: which preset each of the server's 165 cars uses, with a few per-car changes (redline, tone). Register a car by name once its model is known: `AUDIO_ENGINE.RegisterCarNamed("models/....mdl", "Ferrari 458 Spider")`.
- `lua/audio_engine/sh_presets.lua`: the engine presets and gearbox presets. A car's `preset` picks which baked sounds it plays.
- `lua/audio_engine/sh_config.lua`: per car. Sets:
  - the stock `preset`
  - `topSpeed` (the gearing fit). `"auto"` reads MaxSpeed from the car's vehicle script.
  - `shift`: the gearbox shift points
  - `wheelRadius`, `soundLevel` and `volume`
  - `stability`: the assist (`false` turns it off)
- `addons/sl65amg_rtu/scripts/vehicles/plpd/sl65amg_rtu.txt`: the example car's handling (power, grip, suspension, top speed); its engine settings are in `addons/sl65amg_rtu/lua/sl65amg_rtu/sh_car.lua`.

To give another jeep-rigged car this engine, call `AUDIO_ENGINE.RegisterCar("models/....mdl", { ... })` in `sh_config.lua`.
