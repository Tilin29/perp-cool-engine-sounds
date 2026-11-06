# Audio Engine

Procedurally generated engine sound, rpm/gear model and speed / rpm HUD for Garry's Mod cars: all 165 PERPHeads cars, plus an example police car (Mercedes SL65 AMG, RTU liveries) with its own model.

**Requires** the TDM Cars content (shared materials and wheels), same as the model.

## Install
Drop the `sl65amg_rtu` folder into `garrysmod/addons/`. Spawn the example car from **Vehicles → Police**:
- SL65 AMG (Police): skin 0
- SL65 AMG (RTU Blue): skin 1
- SL65 AMG (RTU Yellow): skin 2

## Starting the engine
The engine is off when you get in, and the car is silent and can't drive. Press **I** to start it: it cranks, catches, flares and settles to idle, and the car only drives once that has finished (about 2 s, or about 3.5 s with the rev flare). Press **I** again to switch it off.
- Pick your own key with `audio_engine_startkey` (a key name such as `k` or `f1`, or `none`). `bind <key> audio_engine_toggle` also works.
- `audio_engine_autostart 1` on the server starts the engine by itself when a driver gets in (the car still waits for the start-up to finish).

## Engine tuning in game
Open the tuning menu any of these ways:
- type `!engine` in chat
- run `audio_engine_menu` in the console
- right-click the car in the context menu (C) and choose **Engine tuning**

You need to be in the car or looking at it. The menu has the Rev Bench controls:
- **Presets:** one for every engine type on the server: V12 (and turbo), flat-12, W16, V10 (and big-block), V8 crossplane / high-revving / flat-plane / twin-turbo / hybrid, V6 (even-fire, odd-fire, twin-turbo), flat-6, inline-6 (and turbo), inline-5 turbo, inline-4 (everyday, high-revving, turbo, hybrid), inline-3, flat-4 (FR-S, air-cooled, Subaru turbo), 2- and 3-rotor Wankel, and an electric motor. Plus the SL65's own V12 biturbo and the classic Rev Bench inline-4.
- **Sound:**
  - engine layout, pitch, exhaust tone, volume and realism (0 = the Rev Bench sound)
  - **Gurgle:** the burble off throttle and on the overrun. The burn goes ragged: firings come in uneven groups and the odd one misfires. It fades out under full throttle.
  - **Pops & bangs (how often):** Off, Rare, Occasional, Frequent, Constant. It covers overrun crackle, plus bangs on lift-off, upshifts and the limiter.
  - **Pops & bangs volume:** 0–200%, separate from how often.
  - **Pops & bangs tone:** Muffled, Sport, Loud pipe, Straight pipe. Muffled is mostly the scatter of the pop rattling through the silencers; Straight pipe is mostly the sharp crack.
  - turbo (whistle), with an optional **blow-off valve**, and a volume for each (0–200%). Like the pop volume, these change instantly without regenerating the engine.
- **RPM & performance:**
  - idle and redline
  - **Acceleration** (×0.5–2.5 engine power) and **Top speed** (km/h). These change the car's real physics. The revs, gears and sound follow.
  - live stats: cylinders, firing frequency, and how many loops get generated
  - **Sound quality:** 44.1 kHz or 22.05 kHz. This only affects your own PC: 22.05 kHz generates twice as fast and uses half the memory. Changing it regenerates every engine.
- **Gear ratios:** gearbox presets, number of gears (3–8), every ratio, final drive, and "fit gearing to the top speed". That last one is on by default and sets the final drive so top gear reaches redline at the car's top speed, so every gear gets used. Top speed per gear is shown live.

**Apply to car** changes that car for everyone. **Back to stock** resets everything, including performance. Switching engine presets keeps your acceleration and top speed.

A new engine is generated in the background on every client near the car (about 1.5–2 s of CPU). The old sound keeps playing until it's ready. Cars with the same engine settings share one set of sounds.

## How the sound works
Every sound comes from a Lua engine synthesizer based on Rev Bench, with no recordings. The stock engine of every car is rendered offline by that same synthesizer (`dev/baker`) and ships as WAV files in `sound/audio_engine/`, so stock cars load instantly and cost no CPU. An engine retuned in the menu is generated in game, spread over a few seconds of frames in the background. Look for `[Audio Engine] ... generated 30 sounds` in the console. `audio_engine_baked 0` makes the client generate everything, as before.

## PERPHeads cars
All 165 PERP cars use the procedural engine, matched by the TDM/PERP model they already use (no models are included here), whatever tier script PERP spawns them with (used, upgrades, spiked, cop...). Their TDM engine recordings are muted (`audio_engine_mutestock`). For testing in sandbox they're listed under **Vehicles → PERP cars (Audio Engine)**. The developer log for putting this on the PERP server is `INTEGRATION.md`.

On top of the Rev Bench synth, the **Realism** slider adds:
- **each engine type's own voice:** its exhaust resonances (big and deep for a V8, thin and high for an inline-4, high and smooth for a V10 or V12), pulse width, and its low-order rhythm (the V8 burble, the boxer rumble, the five-cylinder warble)
- two exhaust banks, each with slightly different pipe resonances
- slightly different strength and timing per cylinder, plus cycle-to-cycle combustion variation (bigger at idle)
- combustion that varies from firing to firing, with slightly loose timing, so it never sounds like a perfect machine-made tone
- exhaust grit that rides on each pulse instead of a steady hiss
- a touch of uneven (asymmetric) distortion, like a real exhaust pipe pushed hard, which gives the bark
- a muffler resonance, faint valvetrain ticking, a tailpipe reflection and a small outdoor space
- a top-end filter that keeps the engine's body instead of fizz at high revs
- turbos: a whistle that builds with boost and a blow-off "pssh" when you lift

What gets generated:
- One loop per rpm point (10 points, about 1.26× apart), on and off throttle. Each is pitched by at most about ±12% and cross-faded, so the exhaust resonances stay put.
- A rev-limiter loop, start-up sounds (normal and "emotion"), a shut-down sound, three pops and two bangs.
- Shared by every car, generated once: tyre roar, wind, the turbo whistle and two blow-off sounds. So switching the turbo or blow-off valve on or off, or changing their volume, never generates a new engine. Only layout, pitch, exhaust tone, idle, redline, realism, gurgle and pop tone do.
- Every engine is matched to the same loudness, so a V8 plays as loud as an inline-4 (electric motors sit well below). Each loop's few loudest pulses are limited so nothing clips.

Every car gets a small random detune (±1.5%), so a row of them doesn't sound like one cloned recording.

Playback is kept clean:
- Every loop glides to its new volume instead of jumping once per frame, which would click (zipper noise).
- Each car keeps its own mix under full scale, using the measured peak of every generated sound, including pops and bangs that overlap. Revving in neutral may go a few dB louder than driving.

Around the engine:
- **Doppler:** a car coming toward you sounds higher, and drops in pitch as it passes, from the real speeds of the car and of you, at four times the real shift so a drive-by stands out. At 130 km/h that's about +72% then −30%. Your own car is never shifted.
- **Tyre roar and wind:** a road roar that grows with speed, and a faint wind that only becomes noticeable near top speed. These are generated once and shared by every car. They play even with the engine off, while the car rolls.

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

Also remove the engine `Gear`/`State` sounds from that script, or they play on top of the generated engine.

`scripts/vehicles/plpd/sl65amg_rtu.txt` is tuned to be calm on its own:
- lower centre of mass and a cap on body rotation speed
- near-neutral anti-roll balance, so it turns in properly
- less rear brake bias and slight front drive
- only a touch of power cut while steering

On top of that, a server-side **stability control** (`sv_stability.lua`) works out how fast the car *should* be rotating for your steering keys at that speed, and compares it with how fast it *is* rotating:
- rotating more than you asked (a spin starting): it catches it. With the handbrake held it allows much more, so drifts still work.
- rotating against your steering (counter-steering out of a slide): it helps stop the rotation
- rotating less than you asked (pushing wide): it adds a little turn-in
- last resort: if the tail still slides out past the drift angle, it pulls the car's travel back toward the nose without losing speed

It never reacts to the normal angle of a car in a tight bend, only to the tail stepping out. It only acts on the ground, moving forward. Tune it per car with the `stability` table in `sh_config.lua`.

## Convars
| Convar | Realm | Default | |
|---|---|---|---|
| `audio_engine_volume` | client | 1 | engine volume, 0–2 |
| `audio_engine_roadnoise` | client | 1 | tyre roar volume, 0–2 (0 = off) |
| `audio_engine_windnoise` | client | 1 | wind volume, 0–2 (0 = off) |
| `audio_engine_doppler` | client | 1 | Doppler on passing cars, 0 = off, 0.25 = real, 1 = four times real (the maximum) |
| `audio_engine_passby` | client | 1 | how much passing cars swell in loudness, 0 = off, up to 2 |
| `audio_engine_tunnel` | client | 7 | Source DSP preset for cars in tunnels, 0 = off, 6 = medium tunnel, 7 = large tunnel |
| `audio_engine_hud` | client | 1 | show the HUD |
| `audio_engine_units` | client | mph | `mph` or `kmh` |
| `audio_engine_hud_scale` | client | 1 | HUD size |
| `audio_engine_samplerate` | client | 44100 | 44100 or 22050 (twice as fast, half the memory); changing it regenerates everything |
| `audio_engine_genbudget` | client | 6 | milliseconds per frame spent generating sounds, 1–50 |
| `audio_engine_maxsounds` | client | 10 | how many different engines to keep generated (about 4 MB each); past this, cars fall back to their stock sound |
| `audio_engine_baked` | client | 1 | stock engines play the pre-generated sounds; 0 = generate everything in game |
| `audio_engine_startkey` | client | i | key that starts and stops the engine (`none` = no key) |
| `audio_engine_mutestock` | shared | 1 | silence the TDM engine recordings of cars that use the procedural engine |
| `audio_engine_muteskid` | shared | 1 | silence the TDM tyre screech when braking (shared by all TDM cars) |
| `audio_engine_mutetyrescrape` | shared | 1 | silence the scrape of sliding tyres (a global change: glass bottle and dirt surface sounds) |
| `audio_engine_autostart` | server | 0 | 1 = start the engine when a driver gets in; 0 = the driver starts it |
| `audio_engine_emotionstart` | server | 1 | rev flare on start-up (high-powered cars only: `CAR_EMOTION`) |
| `audio_engine_keeprunning` | server | 1 | keep idling after the driver gets out (0 = getting out switches the engine off; not saved, set it in server.cfg) |
| `audio_engine_cruise` | server | 1 | speed limiter on registered cars (middle mouse switches it, the mouse wheel sets the limit) |
| `audio_engine_stability` | server | 1 | drift-friendly stability assist (all cars except spiked tyres) |
| `audio_engine_handling` | server | 1 | anti-spin setup: front brake bias, less power while steering at speed, lower centre of mass (cars spawned after) |
| `audio_engine_traction` | server | 1 | traction control: less power while the driven wheels spin |
| `audio_engine_tuneaccess` | server | 1 | who can retune engines: 0 = whoever drives the car, 1 = admins, 2 = superadmins |
| `audio_engine_tunecooldown` | server | 5 | seconds between engine changes per player |

Commands:
- `audio_engine_menu` opens the tuning menu (also `!engine` in chat).
- `audio_engine_handling_info` (admins) prints the handling setup of the car you're in or looking at.
- `audio_engine_accel_log [seconds]` (admins) logs speed, gear, rpm, wheel slip and power trims of the car you drive to the console (default 12 s, max 60).
- `audio_engine_toggle` (bindable) switches the engine of the car you're driving on or off, like the start key.
- `audio_engine_rebuild` regenerates all engine sounds (after editing the synth or presets).
- `audio_engine_wingflap` (superadmins) shows the brake flap for 10 s on the P1 or SLR you're in or looking at.
- `audio_engine_bonedump` (superadmins) writes the bone manipulations of the car you're in or looking at to `data/audio_engine_bones.txt`.

## Files to edit
- `lua/audio_engine/sh_carlist.lua`: which preset each of the server's 165 cars uses, with a few per-car changes (redline, tone). Register a car by name once its model is known: `AUDIO_ENGINE.RegisterCarNamed("models/....mdl", "Ferrari 458 Spider")`.
- `lua/audio_engine/sh_presets.lua`: the engine presets and gearbox presets. Add your own here and they show up in the menu.
- `lua/audio_engine/sh_config.lua`: per car. Sets:
  - the stock `preset`
  - `topSpeed` (the gearing fit). `"auto"` reads MaxSpeed from the car's vehicle script.
  - `shift`: the gearbox shift points
  - `wheelRadius`, `soundLevel` and `volume`
  - `stability`: the assist (`false` turns it off)
- `scripts/vehicles/plpd/sl65amg_rtu.txt`: handling (power, grip, suspension, top speed).

To give another jeep-rigged car this engine, call `AUDIO_ENGINE.RegisterCar("models/....mdl", { ... })` in `sh_config.lua`.
