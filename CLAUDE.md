# Audio Engine addon: notes for Claude Code

Garry's Mod addon for the PERPHeads server (128 players, up to ~40 cars in one area, 165 car models).
It started as a police RTU Mercedes SL65 AMG (TDM Cars based), and has grown into a shared engine
system for every car. Engine sounds are **generated procedurally** by a synth ported from the "Rev Bench" web page. Every car's stock engine
is rendered offline by that same synth (`dev/baker`) and shipped as WAVs; only engines tuned in game are generated on the client.
Keep the synth the single source of every sound (no recordings). Porting the sounds into PERP: `PORTING.md`.

## Layout
- `lua/autorun/audio_engine_init.lua`: loader. Shared: sh_config, sh_presets, sh_drivetrain, sh_carlist, sh_perp, sh_police. Client: cl_baked, cl_synth, cl_soundbank, cl_engine, cl_hud, cl_menu, cl_police. Server: sv_engine, sv_stability, sv_cruise, sv_police, sv_seats.
  Then the debug module (`lua/audio_engine_debug/`, see "Debug module" below), if that folder exists: deleting it is all it takes to ship without it.
- `sh_config.lua`: `RegisterCar(model, cfg)`, `GetCarConfig` (keeps each model path's lower case: called per car per tick/frame); the SL65 entry (shift points, stability, wheel radius). `audio_engine_editor`
  (shared, default 0, `AudioEngine.EditorEnabled()`): the Rev Bench menu (cl_menu: command, `!engine`, context menu; sv_engine rejects `audio_engine_set`) only when 1.
  cl_menu has no gear card any more (its ratio editor never reached the car; it forces `fit = 1`).
- `sh_presets.lua`: layouts, gearbox presets, 38 engine presets, profile Sanitize/Encode/Decode
  (21 pipe-separated fields, ending `...|popTone|turboVol|bovVol`), `ResolveProfile`, `CarStockProfile`.
  `config.soundKey` = what forces a new sound bank (layout, pitch, tone, idle, redline, realism, gurgle, popTone).
  Turbo, BOV, volumes and pop frequency are runtime-only.
- `sh_carlist.lua`: `CAR_ENGINES[name] = { preset, stock = {overrides} }` for all 165 cars from the engine list (Engine Types.xlsx), and
  `CAR_MODELS[name] = { model, PERP base script, wheel radius }` (built by `dev/perp_carmodels.py`); all 165 are registered
  with `RegisterCarNamed`, `stability = false` (`AudioEngine.PERP_STABILITY`). Models are TDM/PERP content paths, never copied here.
  10 work/emergency vehicles on their own models (BearCat, ambulances, F350 fire/tow, stockade, fire truck, Transit 2016s, courier truck)
  reuse baked families (H1 diesel, F350 V8, Transit). `AudioEngine.JOB_VEHICLES` { spawn name, car, script, skin }: police/fire/EMS/taxi variants
  on their own scripts (`_cop`, `_medic`, `dodgeramff`...), job livery = skin 11 on TDM models (0-10 paint, 12 often chief; Crown Vic
  11 taxi / 12 police). Left out: perp2/bus, tdmcars/airtug (raw .wav engine sounds, can't be muted), porcycle (pedal), lee/subimpreza/
  perp2/towtruck (no model in the content packs). CrSk GT63s/Phantom materials ship without models.
  Stock pops/BOV are per car, not per preset: `CAR_POPS[name]` (frequency, unlisted = off), `CAR_BOV[name]` (audible stock
  blow-off only), volumes `STOCK_POP_VOLUME` 0.7 / `STOCK_BOV_VOLUME` 0.6, applied in `CarStockProfile` (runtime only: no re-bake).
  Preset pops/bov are just the starting point when retuning in the menu. Big pop events scale with pops^2 (cl_engine).
  Pop timing (cl_engine): lifting off over half redline starts a burble 0.12-0.3 s later, uneven clusters thinning out over
  (0.8 + 2.2 x pops) s and with the revs; back on the throttle ends it; a long coast only pops now and then (a per-frame chance
  spread lone pops over every coast: popcorn).
  `CAR_SUPERCHARGER[name]` = "sport" | "regular" | "heavy" (13 cars; heavy: trucks, none stock): the blower whine, locked to the revs
  (env loops `sc_<v>_<k>` in octave bands `Synth.SC_BANDS` 375..6000 rpm, cross-faded by rpm x scPitch so the pitch stays ~55-200%:
  one loop at rpm / 2800 played at 27% at idle, stepping 3.7% a whole-percent pitch step; level x `SC_VARIANTS[v].level` x (rpm/redline)^0.9,
  off throttle the bypass loop `sc_<v>_<k>_off` at half). The bypass follows the throttle, not the limiter's fuel cuts (`car.superchargerThrottle`,
  shuts 0.15 s / opens 0.1 s), and on the limiter the whine holds at 0.985 x redline (`superchargerRpm`): following the cuts it warbled.
  Played at `SC_GAIN` 0.7; at speed it fades to `SC_FAST_GAIN` 0.4 (-8 dB) between `SC_FADE_FROM` 0.4 and `SC_FADE_TO` 0.8 of
  `config.topSpeed` (fixed km/h: slow cars never faded). `AudioEngine.SC_PITCH[name]` (config.scPitch) for a blower geared unlike the ~20 lobe
  passes per crank turn (twin-screws SLR, C32, Ford GT, Hellcat 0.52; hot-rod Roots 0.35). The loops are seamless (every tone and wobble whole cycles over the loop, only
  the air noise cross-faded): random wobbles put the tone out of phase at the seam, a 5 dB dip each pass.
  A supercharged car's preset turbo/BOV is off (CarStockProfile). Runtime only.
  `CAR_EMOTION[name]`: high-powered cars that rev-flare on start-up (`config.emotionStart`, picked by sv_engine; runtime only); others get the gentle start.
  `ECONOMY[name]` + `ECONOMY_SOUND`: economy cars get tone x0.5 and gurgle 0 (in the sound key: re-bake), volume 0.8, soundLevel 80.
- `sh_perp.lua`: mutes the TDM engine soundscripts named in registered cars' PERP scripts (base + used/upgrade_1/upgrade_2/spiked
  + `<base>_*` variants), keeping names other vehicles share; `audio_engine_mutestock`. Also the TDM brake screech
  (Skid_* soundscripts `tdmcars_skid`/`_less`, global to all TDM cars; spiked rim scrape kept): `audio_engine_muteskid`.
  Sliding tyres scrape with their surface material's sound (PERP uses `glassbottle` on ~1/3 of scripts, rubber = `Dirt.Scrape`):
  `audio_engine_mutetyrescrape` mutes `AudioEngine.TYRE_SCRAPE_SOUNDS` (global game soundscripts). Spawn-menu categories for testing: PERP cars, and PERP job vehicles (own script, skin via `PlayerSpawnedVehicle`;
  `AudioPerpScript` picks the fallback physics). Door soundscripts are never muted. `AudioEngine.PERP_SCRIPT_UNUSED`: model-less scripts ignored.
- Emergency lights: `sh_police.lua` (`AudioEngine.POLICE_VEHICLES` = the 9 marked police job vehicles + fire (RAM SRT10, F350 Fire Rescue:
  its own roof lights are amber, so it gets a bar too, Defender, Fire Truck) and medical (RS4 Avant, Prius, Ambulance, F450 Ambulance)
  by spawn name: roof `mount` in the car's model space, measured from the meshes (mesh tops sit ~10.5 under the game's on TDM models:
  the user fixed the 340i 57.5 -> 68.5; the new mounts have +10.5 and may need nudging, `lua_run ... GetNW2Entity("audio_lightbar"):SetLocalPos`),
  + `bodygroups`, `scheme` police / fire (red, yellow) / medical (red, white), NW2 `audio_lightscheme`; `builtin` = no bar,
  the model's own lamps `AudioEngine.BUILTIN_LIGHTS[model]` { bone, lamps { pos, n, w, h, color, side, group } } in the body bone's space
  (GTA IV ports turn car.body 90 deg; drawn through `GetBoneMatrix`), picked from the lens material's vertices and texture colours
  with an MDL/VVD reader (headlights, tail lights, indicators left out); such a car is its own NW2 `audio_lightbar`; `AudioEngine.POLICE_BY_SCRIPT` from `AudioEngine.JOB_VEHICLES`; `AudioEngine.LIGHTBAR_MODULES` = the LED
  lenses of `models/perpheads/props/police_lightbar.mdl`, workshop 2897742669: model space long axis X, front +Y like the cars, so `AudioEngine.LIGHTBAR_ANGLE` 0; its mesh is in a root bone
  turned -90 deg, which `module()` undoes; -X driver's side, red; +X blue; centre white). `sv_police.lua`: on spawn (script, or the
  spawn entry's `AudioPerpScript`) sets the livery skin (11; Crown Vic police 12, its 11 is the taxi; Transit has one skin), hides the
  Crown Vic's taxi sign/meter, parents a `prop_dynamic` bar (NW2 `audio_lightbar`); `audio_engine_lights [0-2]` (driver only) steps
  off / CODE 2 / CODE 3 (NW2 `audio_lights`). `cl_police.lua`: the bar's LEDs are plain textures, so lit modules get an additive lens
  quad + a glow sprite faded by facing, the nearest 4 cars a dynamic light per side; key `audio_engine_lightkey` (default lshift;
  no police script has a Source boost block, so shift is free). HUD shows the mode, plus whatever the `audio_engine/lights-label`
  hook returns (veh) after a dot: the police siren module (below) answers with its tone.
- Passenger seats: `sv_seats.lua` (`audio_engine_seats`, default 1). No content pack defines any (the models only have the driver's
  `vehicle_feet_passenger0`), so they're laid out from that attachment: front passenger mirrored across the centre line, back row
  `AudioEngine.SEAT_REAR_PITCH` 0.3 x wheelbase behind (rear cushions measured 0.25-0.36 in the meshes), `SEAT_REAR_RISE` 4 up.
  `AudioEngine.CAR_SEATS[name]` (sh_carlist, `config.seats`): unlisted 4, 2 = two-seaters, 1 = Furai, lists { side, back, up[, width] }
  for the McLaren F1 (centre driver) and vans/trucks/work vehicles (estimates). E (`PlayerUse`) enters the free seat nearest the
  player (the driver's = Source's own entering); a seat is a no-draw `prop_vehicle_prisoner_pod` made only while occupied
  (physics frozen, collision group world), entered a tick after it's made and checked a tick after that (entered in the
  PlayerUse tick it was created, the user got a view snapped to the floor and no seat), failures printed to the player's
  console (incl. CanPlayerEnterVehicle refusing it), eyes set forward (0, 90, 0); removed on getting out, the player put beside their door (else other side / behind / roof, hull-traced). Locked cars refuse passengers.
  `AudioEngine.RiddenCar(player)` (sh_config): the car a player drives or sits in; cl_engine treats it as the listener's own car.
- `cl_baked.lua`: GENERATED by `dev/baker/bake.js`. Per sound key: folder under `sound/audio_engine/`, band rpms, peaks, timings.
  Redline families: `config.familyKey` = sound key minus redline (not electric). Each family is baked once at its highest redline;
  `AudioEngine.BAKED_FAMILY[familyKey]` points lower redlines at it (unused top bands stay silent, cl_engine pitches the limiter loop by
  `config.redline / bank.limiter.rpm`). The emotion start flares to 0.55 x redline, so families also ship `starte_<flare>.wav`
  variants (`startEmoAt`); a tuned engine whose flare has no variant gets the closest one.
- `sh_drivetrain.lua`: rpm/gear model shared by client and server. Start-up sequence (catch, flare, settle; electric = short power-up),
  arcade automatic driven by RPM thresholds (W/S/Space are on/off keys), torque converter, turbo boost and BOV event.
  Upshift point follows the car's acceleration (`upRpm` pulling hard .. `lazyUpRpm` creeping), so power-limited cars reach top gear.
  Past `upRpm` it changes up even inside the post-shift hold (close-geared hard pullers like the M5 E60 hit the in-gear limiter).
  Neutral (Space+W rev) latches until W or S is pressed. The limiter loop (cl_engine) plays only while W is held near redline.
  Free-revving uses `Drivetrain.REV` { rise, fall } 500/500 (`Drivetrain.FreeSpinRate`; per car `config.revRise/revFall` from `AudioEngine.CAR_REV`), not
  `Drivetrain.TMAX` 320, which stays for the synth's baked limiter loops and start tails (changing TMAX needs a re-bake). 500 falls from 90% to near idle in ~2.5 s (320: ~3.8 s).
  A car's own gearing (`AudioEngine.CAR_GEARING[name]` -> `car.gearing`, sh_presets `AudioEngine.ApplyGearing`, only with `fit > 0`): per gear `{ mph, rpm }` where it
  changes up flat out (lazy upshifts at the same lazyUpRpm/upRpm share of it), `down` mph to change down coasting/braking, last entry = top gear
  (`topRpm` at `config.topSpeed`); sets `config.gears` as overall ratios, `final = 1`, `config.shiftPlan` { up = rpm[g], down = m/s[g] }. Each gear at least
  `AudioEngine.GEAR_MIN_STEP` 1.1 taller. Kickdown/corner landings also stay under the target gear's up rpm.
  Fitted gearing comes from the top speed only, deliberately not realistic (the user's choice; a time-based, realistic spacing
  with up to 7 gears was tried and reverted) (`AudioEngine.FitGearEnds`, `AudioEngine.GEAR_FIT`): 1 gear per `kmhPerGear` 40 km/h, steps at most
  `stepMax` 2.3x, 1st ends at `firstShare` 0.28 of top speed (at least `firstMin` 25 km/h), gear ends evenly spaced in speed^`spread` 2.2;
  2 to `maxCount` 5 gears (or the box's count if lower). `CAR_GEARS[name]` overrides the count, 2..8: Furai 6 (the only 6-speed), both Mini Coopers 3.
  Manual gearing (`AudioEngine.CAR_GEARING`, debug gearing editor) still replaces the fitted gears.
  `AudioEngine.GearAccel`/`AudioEngine.GEAR_ACCEL` (pull `perWkg` 0.035 x power to weight, W/kg from NW2 `audio_pwr`) is now only the model that
  `audio_engine_accel_log` and dev/drive_demo compare against, not used for the gear spacing. HUD speed defaults to mph (`audio_engine_units`).
  The top gear never reaches redline: at top speed it turns `AudioEngine.TOP_GEAR_DROP` 1000 rpm under redline (`AudioEngine.TopGearShare`, at least
  `AudioEngine.TOP_GEAR_MIN` 0.6 of it; FitFinal), the gears are spaced up to
  that gear's redline speed, and there's no lazy upshift into it: the car changes up near top speed and settles lower.
  Cruise (`inp.cruise`): highest gear above `cruiseLand` 0.45, down only below `sagRpm`, no kickdown, steady `cruiseThr` 0.8 (pedal 80% down).
  Cornering (A/D, networked as input bit 8; `inp.steer`): no lazy/stall upshifts, changes down below `cornerRpm` 0.65 (to under `cornerLand` 0.88); coasting lugRpm 0.4.
  Downshifts with W held (kick/sag/corner) judge the wheels' revs, not `st.rpm`: converter slip keeps that over ~0.47 x redline
  with W held, so a car slowed by a turn stuck in its gear. No lazy upshift while slowing (`st.accel > 0`), and slowing isn't a stall.
  Braking downshifts are low and gentle (`brakeRpm` 0.45, `brakeLand` 0.70, `softShift`: blip 0.25, rise rate 8): at 0.80/0.96 with
  a full blip hard braking ran a sawtooth near redline that sounded cartoonish. cl_engine feeds the model the car's full speed
  signed by the nose (`car.driveSpeed`), not the speed along the nose, which collapsed in a slide (revs plunged, then shot back up).
- `cl_synth.lua`: generator. Firing pulses on a 720° cycle, two exhaust banks, per-layout CHARACTER (f1/f2/f3, w, o1, o05),
  gurgle, flow grit, bark. `Synth.EVRender` for the electric motor (one faint whine: a tone of order chosen to reach
  `EV_TOP_HZ` 450 Hz at redline, weak harmonics, a slight speed ripple so it isn't a pure sine, under a bearing/air hiss; regen whines softer off throttle; near silent at
  low speed; bands 1.35x apart; electric bands keep natural levels, no per-band loudness matching, the top band's on loop is set
  to `TARGET_EV_DB` -32 dB rms full band; cl_engine plays EVs and their hum at `AudioEngine.EV_VOLUME` 0.1). `RenderEVHumLoop`: the steady low-speed EV hum (env bank `evhum`), played by
  cl_engine at a near-fixed pitch, fading out between 8% and 20% of redline. Exhaust chain (WebAudio biquads). Pops via `RenderBackfire`:
  a ~1 ms thump + 35-100 ms muffler scatter, body peak 140-190 Hz, low-passed (a 0.4 ms click with light saturation sounded like
  firecrackers); crackles are ragged 4-8 pulse "b-r-rap" runs. Levels (cl_soundbank): pops 4 dB under the loudest band, bangs 3 dB over;
  played at 0.7 x (cl_engine `popVolume`, ~3 dB up on the 0.5 they used to play at).
- `cl_soundbank.lua`: builds a bank per soundKey in a coroutine (6 ms/frame budget). It holds:
  - one on/off-throttle loop pair per rpm band (bands ~1.26x apart), a limiter loop, start/stop one-shots, pops and bangs
  - **loudness matching** (TARGET_DB -21, electric -30, measured as rms above 250 Hz of the on-throttle loops), then `limitPeaks` (look-ahead, circular for loops)
  - band loops stored at 0.95 peak with `layer.trim` (manifest `trims`) as the volume that restores their level: volume caps at 1, so quiet bands had no room for the pass-by swell (not electric)

  A shared env bank holds road, wind, turbo whistle, the EV hum, 2 blow-off sounds and the supercharger loops (`Synth.RenderSuperchargerLoop`: on boost + bypass per variant and band; the bypass loop keeps its on loop's gain). Sample rate is `audio_engine_samplerate`, 44100 or 22050; changing it rebuilds.
  - `Bank.Build` first tries the baked copy (`Bank.BakedEntry(cfg)`: own key or family, + file exists): names are then file paths `audio_engine/<dir>/<stem>.wav`.
    `audio_engine_baked 0` forces generation. Baked banks load lazily (when a car using them appears) and don't count toward maxsounds.
- `cl_engine.lua`: per-car playback.
  - band crossfade with pitch; volumes glide (VOLUME_SLEW), which avoids per-frame zipper clicks
  - per-car headroom (ceiling 0.66 driving / 0.68 neutral, leaving room for band peaks lining up mid cross-fade, using measured peaks; pops/BOV limited with `popPeakLoad`)
  - Doppler pitch bends over past `DOPPLER_KNEE` 4 semitones towards `DOPPLER_MAX` 7 (`softPitch`): at four times real it was nearly an octave at 40 m/s
  - tunnels (`isTunnelAt`: roof, close walls, long open run, map only; 17 traces, listener at 4 Hz, cars one per frame): only for listeners outside a car (sitting in one, nothing changes): a car in one or any car while you're in one gets DSP
    `audio_engine_tunnel` (0 = off, default 1 = Source's auto preset, 7 = large tunnel, `CSoundPatch:SetDSP`); a car in one carries `TUNNEL_LEVEL` 8 dB further; both inside: no pass-by drop with range.
    SetDSP/SetSoundLevel go on before PlayEx (`startPatch`) and loops restart when the room changes (`roomGeneration`): not known to reach a playing sound
  - once a second each active loop is checked with `IsPlaying` and restarted if the game dropped it (`car.revive`)
  - performance (`updateRestState()`, `car.restState`, shown by `audio_engine_perf_snapshot`): engine off, standing, silent = asleep, looked at every
    `SLEEP_STEP` 0.25 s; idling, standing, no keys, not your car = parked: only the engine's idle plays (supercharger whine, turbo fade out;
    the EV hum stays: it's the EV's idle), every `PARKED_STEP` 0.1 s while the listener is under `PARKED_LISTENER_SPEED` 6 m/s, volume/pitch gliding over
    that (`car.changeFadeTime`). Dormancy, ignition or a key wakes them that frame (`needsUpdateNow()`). A resting car's longer step runs the rpm model in
    `DRIVETRAIN_SLICE` 0.02 s slices (one 0.1 s step: the idle control swung 640-760 rpm), keeping limiter/BOV events from any slice; frame steps are unsliced.
    Not "in neutral": a car driven and stopped stays in D. `audio_engine_range` (client, m, default 250, 0 = off) for an 85 dB car, scaled
    by (level - 50) / 35 (Source falloff ~ distance x 20/(level-50)): past it silent (`car.outOfRange`, stopAll, no one-shots, rpm model still runs),
    fading over the last 25%, back on inside 95%. Volume/pitch only sent on change (`sendPatch`: pitch by its whole number, volume over
    1% + 0.0005), tracked in `car.sentVolumes/sentPitches` (set by startPatch). setGroup's name/volume lists are reused (`singleNameList`, `namePairOf`, `volumeList`),
    silent inactive groups skipped, settings read once a frame (`settings`). Tunnel probes skip cars that moved under 1 m since their last one.
  - sound budget (`rankCars`, `audio_engine_maxcars` client, default 16, 0 = all): only the nearest cars with something to play are
    heard; one past it fades over `BUDGET_FADE` 0.5 s and goes silent like an out-of-range car, back at `BUDGET_MARGIN` 2 places inside.
    The game mixes only so many sounds (a few hundred, the siren's and its own included): a car holds ~6 loops driving, up to ~16 while
    its revs sweep the bands (the converter flare crosses 5 in ~0.3 s), and 40 cars setting off together (perf_spawn race) took them all:
    sirens and the game's own sounds went missing. Groups also start only at `GROUP_START_VOLUME` 0.01 (~-40 dB; was any trace) and stop
    once under `GROUP_STOP_VOLUME` 0.004 for `GROUP_STOP_HOLD` 0.1 s (was 0.002 for 0.3 s).
    Offline check: the scratchpad-style mock test (mocked client + real sh_config/sh_presets/sh_drivetrain/cl_engine) is not in the repo.
  - speed (`sampleSpeed`): position change over real time, sampled every 0.05 s or more, median of 3, frames over 0.3 s held, motion along the car's up axis left out;
    the gearbox's speed (`car.driveSpeed`) moves at most `SPEED_SLEW` 40 m/s2. Dividing by the capped frame dt made stutters read as several times the real speed
  - Doppler (`audio_engine_doppler`: 1 = default, real, 4 = maximum, four times real. The scale was 0.25 = real until the user asked for 1:
    clients with the old `audio_engine_doppler_moved` cookie get their saved value x4 once (`audio_engine_doppler_real1` cookie)), road/wind, turbo/BOV from the env bank, pops logic
  - pass-by swell (`audio_engine_passby`): other cars follow (5 m / distance)^curve down to 30 m (after the headroom; start/stop one-shots too), up to x2 at 2.5 m, all by speed
    (`pace` 5-30 m/s): curve 0.35 (-5.4 dB at 30 m) to 0.7 (-10.9 dB; steep on every car, slow ones stopped carrying), the part over 1 scales with pace and is held under a 0.95 peak;
    a car counts as 0.2 s of its speed closer (a 60 m/s pass is otherwise a blink); combustion cars at full pace are 5 dB down from the front, 3 dB up from behind (exhaust direction);
    `car.rushAmount` adds a road/wind whoosh within 10 m of cars over 12 m/s, after the headroom.
    Speed here = the car's own, capped at its speed relative to the listener: a car keeping pace beside you gets no swell, whoosh or
    exhaust bias (it drowned out your own engine). Sitting in a car, other cars are `CABIN_DB` 3 dB down, even with the swell off.
    Doppler and swell apply unless you're in the car and looking from it (a camera view entity counts as outside);
    `CAR_EMOTION` cars get sound level `AudioEngine.EMOTION_SOUNDLEVEL` 92 (others 85, economy 80)
  - the `vehicle_guage` pose follows the revs (tach needle), except on `AudioEngine.GAUGE_PARTS` cars (sh_carlist): 14 TDM models
    also animate wings/vents on that pose (flapped with the revs; Source's speed value folds the R8 Plus/LaFerrari wings back
    down near the top). Those follow speed through per-model {rest, up} pose ranges: up from `AudioEngine.WING_UP` 0.7 x top speed,
    down under `AudioEngine.WING_DOWN_MPH` 30 (`config.topSpeed`, km/h). The server picks the position (`AudioEngine.WingPose`, sv_engine `Tick`) and sends it in 0.02 steps
    (NW2 `audio_wing`, set only when it changed); cl_engine glides to it at `AudioEngine.WING_RATE`. Parked cars (physics asleep, no driver) with
    settled wings are skipped (`vehicle.audioWingsSettled`; `audio_engine_wingflap` clears it). sv_handling's traction tick skips cars
    with no driver once the power trim is back to 1 and no limiter is set. Source writes its speed value to this pose in the driver's move: writing
    ours over it server-side stuttered on real servers (fine in single player), set in Think it lost to the networked value. Both this and the tach pose are applied in the car's `RenderOverride`
    (`ent.audioGaugePose`, chains any existing override)
  - brake wings `AudioEngine.BRAKE_WINGS` (P1, SLR; sv_engine, bone manipulation): S held 0.5 s over 15 mph tilts the flap (P1 `spoilerbrake`
    pose, SLR `spoiler` bone 22.5 deg: its airbrake pose compiled empty); the P1 wing sits tucked (`tuck` = per-bone pos/ang, placed
    with the sandbox bone editor) and rises by the spoiler speed rules (`AudioEngine.WingSpeedUp`) or while the flap is up.
    `audio_engine_bonedump` (superadmin) writes the car's bone manipulations to data/audio_engine_bones.txt; `audio_engine_wingflap`
    shows the flap for 10 s. `lua_run` lines over ~255 chars are cut, and pasting several lines joins them
- `sv_engine.lua`: ignition, run by the server.
  - Engine off on entry; start key `audio_engine_startkey` (default R; polled by cl_engine, which sends `audio_engine_toggle`: the server's
    PlayerButtonDown rides on usercmds and missed presses). A press within 1.5 s of starting can't switch it off (`START_LOCK`: at 150 ms ping a second press did). Getting out leaves it
    idling (`audio_engine_keeprunning` 1, default, not archived: a saved 0 from the old default overrode it); getting back in drives off.
  - The server runs `Drivetrain.StartSequence` and keeps `EnableEngine(false)` until the start-up reaches idle.
  - Also: `audio_engine_autostart`, input bits NW2, `ApplyPerformance` (accel/top speed), the tuning net message.
- `sv_cruise.lua`: speed limiter (was cruise control). Middle mouse on at exactly the current speed / off; mouse wheel moves the
  limit to the next 5 mph step (`StartCommand`: `cmd:GetMouseWheel()`). The driver's own W drives: from `band` 6 mph under the limit
  the horsepower is trimmed (`vehicle.audioLimiterPower`, sv_handling's tick, applied in `ApplyPerformance`) by tracking a wanted acceleration
  `k` x (mph to go), which finds the holding power for any car (a PI on the speed error overshot 1-2 mph). Over the limit (lowered,
  downhill): power off and a braking impulse from 0.6 mph over until 0.15 (0.6 + 0.7/mph, max 3.5 m/s2: 60 to 40 mph in ~2.5 s).
  Exit/engine off cancel. NW2 `audio_cruise` (limit, mph) for the HUD ("LIMIT"), `audio_limst` 0 free / 1 holding (sounds like
  steady part throttle, `inp.cruise`) / 2 over (throttle shut). `audio_engine_cruise`.
- Handling: the PERPHeads server's by default (the user's choice; the shipped port, PORTING.md, has no handling changes at all):
  `audio_engine_handling`, `audio_engine_stability` and `audio_engine_traction` default 0, all archived (a server keeps what it saved).
  The cars then drive on PERP's vehicle scripts only (`addons/perp_vehicle_scripts_local` locally; on the test-script fallback
  `applyPerpPhysics` puts PERP's values on). The assists below are kept, switched off; the speed limiter only acts when switched on.
- `sv_stability.lua`: steering-intent ESC (reference yaw from the A/D keys, catches spins, allows handbrake drifts). Skips `vehicle.audioSpiked`.
  Straight-line hold: W with no A/D, no handbrake/drift holds the heading from a standstill (`straightDamp`/`straightHold`/`straightMax`)
  and reports any rotation as `vehicle.audioSlideAmount`, so traction control cuts the power. Taken over from a turn (still rotating), it only damps
  the rotation and follows the car's heading until under `holdSettled` 3 deg/s (at most `holdGrace` 1 s), then holds that line: holding
  the line from the moment the keys were let go turned the car back against its tyres for seconds (yaw off 10-20 deg/s), read as a slide. `audio_engine_accel_log` prints the yaw off what's asked (hold or steering) and the slip angle.
  Slip limit (no handbrake): past `slipMax` 4 deg tail-out the nose rotates no faster than the path (yaw - slipAngleChange/dt); the turn-in help
  stops while the tail is out, so fast corners turn instead of drifting.
  Lateral grip (no handbrake, also in the straight-line hold): `gripAssist` g of extra side grip removes sideways speed at any slip
  angle, forward speed untouched (turning the whole velocity toward the nose launched cars before). Off: 0 (was 1).
  Turn-in help (understeer): up to `turnShare` of the asked rotation at `turnHelp` 4/s. Off: 0 (was 0.9; with W held it pushed the
  tyres to their side limit, no grip left to drive: turns at 60 mph bled 3-4 mph/s at full power; the user prefers both off).
  Braking (S, locked fronts plough on) still up to `brakeTurn` 0.6 at `brakeHelp` 6/s.
  Never turns a sliding car's velocity (that launched cars toward the nose). A drift starts with the handbrake and lasts while
  the slide angle > `driftHold`; while drifting counter-steer isn't damped. Grip 1.5 g; `vehicle.audioFastSteerScale` widens the lock at speed.
- `sv_handling.lua`: on spawn (`AudioEngine.PrepareHandling`, before `captureBase`): PERP base physics from generated `sv_perp_physics.lua` onto cars
  on `test_car.txt` (as ratios to test_car's values: keep the `TEST` table in step with the file), anti-spin `AudioEngine.ANTI_SPIN`
  (`audio_engine_handling`; also steering at speed x1.5, handbrake slide left as scripted),
  launch traction control `AudioEngine.TRACTION` (`audio_engine_traction`): driven-wheel slip from `GetWheel` angular speed trims
  horsepower via `vehicle.audioTractionPower` in `ApplyPerformance` (strong light cars like the Veyron spun their tyres off the line); it may cut to
  `floor` 0.25 at launch, rising to `floorFast` 0.6 by 16 m/s; while sliding (`vehicle.audioSlideAmount` from sv_stability: tail out / over-rotating,
  not in a handbrake drift) it cuts at `slideCut` down to `slideFloor` 0.2 at any speed (no hard speed cut-off: that held cars at 1/4 power, then gave it all back),
  only to `slideTurnFloor` 0.6 when it isn't over-rotating (`vehicle.audioOverRotating` false: tail out in a fast corner, `slideFrom` 8 .. `slideFull` 16 deg),
  for at most `slideMaxTime` 1 s of unbroken slide, then restores (`vehicle.audioSlideSince`; it only ever recovered on releasing W, so a stuck slide reading held a car at 0.2);
  the lock at speed tightens to x0.9 between 45 and 90 mph (`AudioEngine.HIGH_SPEED_STEER`, `vehicle.audioSteerLockScale`; x1.3 x0.65 turned too little), and is
  capped by `AudioEngine.STEER_GRIP` (angle a `g` 1.5 turn needs at that speed and wheelbase, `AudioEngine.CarGeometry`, + `slip` 6 deg): keyboard steering is
  always full lock, and the curve's ~20 deg at 60 mph scrubbed ~1 g off turns once the turn-in help was off; the scripts'
  power cut while steering at speed (`turnThrottleReduceFast` 0.5-0.9) is capped at `AudioEngine.ANTI_SPIN.throttleReduceFast` 0.2: fast turns kept their revs. `audio_engine_accel_log`
  logs Source's gear/rpm (GetOperatingParams), slip and trims while driving. Also spiked detection from the `vehiclescript` keyvalue, per-car ESC steering. `AudioEngine.SetParams` = checked SetVehicleParams.
  `vehicle.audioScriptParams` = params after PERP physics, before the anti-spin setup; `AudioEngine.RebaseHandling(veh[, params])` rebuilds `vehicle.audioBase`
  from it (anti-spin only while `audio_engine_handling` is on; off clears the lock-at-speed state), refreshes NW2 `audio_vmax`/`audio_pwr`
  (`AudioEngine.RefreshCarStats`, sv_engine) and re-applies performance. The `audio_engine_handling` change callback runs it on every car: it applies at once.
- `scripts/vehicles/plpd/sl65amg_rtu.txt`: handling. The server also has its own `sl65amg_cop.txt` (fixed copy given to the user separately).

## Police siren (separate module, may not stay)
Own loader `lua/autorun/police_siren_init.lua`, files in `lua/police_siren/`, studio in `dev/siren_studio/`: delete those three
to drop it. Never referenced by the audio engine and never calls it (the user wants them kept apart); it only reads the lights'
NW2 vars (`audio_lightbar`, `audio_lights`, `audio_lightscheme`: `PoliceSiren.LIGHTBAR_NW`/`PoliceSiren.LIGHTS_NW`/`PoliceSiren.SCHEME_NW`), so any car with a
lightbar (or built-in lights) has a siren. Fire and medical cars get their own tones (`CONFIG.schemes`): fire = an electronic
wail / yelp / phaser like a modern fire engine's (560 <-> 1200 Hz; the wail only to 900 Hz, the user's pick, 1.8 s up / 2.6 s down) with a brasher horn-speaker colour
(odd harmonics, light drive, a 1.2 kHz peak); a Q-siren style spin-up / coast-down growl sounded like an air raid siren (the user said no), medical = a higher, brighter electronic wail (emswail 720 <-> 1480 Hz, emsyelp) and the hi-lo. Global `POLICE_SIREN` (PS).
No horn (the user removed it). Tones copied from the reference recording the user picked (YouTube HKieGUH9pzg, "Police Siren Sound
Effect"), measured with an analyser in the browser: wail 613 <-> 1190 Hz, rise 1.5 s (spin-up, curve 0.25), fall 3.15 s (even in
log pitch), cycle 4.7 s; nearly pure: harmonics 2-10 at -25, -22, -34, -32, -42, -42, -54, -54, -61 dB, so a clean speaker (no drive,
no resonance). Yelp and phaser use the same range and colour. Easy to listen to for long, which the user asked for.
In a siren car the spawn menu (Q) is blocked (`SpawnMenuOpen`), and the tone shows after the light mode on the engine's HUD through
the engine's generic `audio_engine/lights-label` hook (cl_hud; the engine still never names the siren).
- `sh_siren_config.lua`: `PoliceSiren.CONFIG`, written by the studio's export (the user pastes it back): volume, soundLevel (88 = the engines' 85 + 3) and
  `soundLevels[model]` (94 on the police cars on CAR_EMOTION (95 a touch far), engine 92: the user wants the siren heard before the engine, not much
  further; 94 for all carried too far on the others, 86 lost to the SL65's engine), doppler (1 = real), attack/release (release 0.08: an electronic siren cuts off; 0.5 s with stopPitch 0.7, a motor wind-down, sounded wonky), stopPitch (pitch drop on fade-out, 1 = none), pitch,
  sampleRate, `lightTones` { CODE 2, CODE 3 }, `cycle`, `schemes[name]` { lightTones, cycle } (fire, medical; the studio keeps them
  through its export but plays the police rules), `cabin` { volume, muffle Hz }, `keys` { tone }, `tones[id]` (pattern of
  points { f, glide, hold, curve }, logGlide, harmonics, voice2, vibrato, tremolo, speaker). Must stay plain Lua (the studio runs it).
- `cl_siren_synth.lua`: plain Lua, game and studio. Wavetable of the harmonics (bandlimited to the tone's top pitch), second voice,
  highpass -> tanh drive -> resonant peak -> lowpass (+ a 4-pole lowpass at cabin.muffle for the inside version). Seamless loops: each
  voice scaled to whole cycles per loop, vibrato/tremolo whole cycles, rendered twice and the second pass kept, peak 0.95.
- `sh_siren.lua`: `PoliceSiren.SoundingTone(veh)`: the driver's pick (NW2 `siren_tone`, valid while NW2 `siren_at` = the light mode it was
  picked in), else `lightTones[mode]` of the car's scheme (`PoliceSiren.Scheme`). `sv_siren.lua`: `police_siren_tone` (next in the scheme's cycle,
  then off), driver only, lights on.
- `cl_siren.lua`: builds a tone twice (outside / inside) in a coroutine (5 ms/frame; stored as the engine's loops are, one
  pre-roll sample [y_L, y_1 .. y_L] with loopStart 1: the game loops from sample 1, and without it every pass skipped y_1,
  a tick the user heard on the wail) the first time a car near sounds it (a failed one isn't retried); `sound.Generate`
  names carry `PoliceSiren.Serial` (lua refresh); one CSoundPatch per car (fade-in a frame after PlayEx; once a second it's checked with IsPlaying and restarted at full volume if the game dropped it; only the nearest `police_siren_maxcars` (12, 0 = all) sounding cars are heard, others released, back at 2 places inside: with many cars driving, the engines' loops took the channels and a siren, starting at volume 0, stayed silent), swapped in 0.15 s on getting in/out
  (driver or a seat parented to the car, and the view on the player: watching through a camera = outside, as the engine). Doppler from its own speed sampling (positions >= 0.05 s apart, gaps > 0.3 s and teleports
  dropped, smoothed), the listener's too (the view entity or ply:EyePos(): global EyePos() in Think jittered), the pitch eased at 14/s,
  none inside the car. Tones are generated an octave low (rate sr/2) and played at pitch 200: Source pitch is whole percent, and on
  the near-pure tone 1 % Doppler steps were audible; so the pitch stays within 150..255 (-5..+4 semitones). Key `police_siren_tonekey` (q; alt/shift/ctrl = left one),
  `police_siren_volume`, `audio_engine_police_doppler` (0-2, x CONFIG.doppler 0.5 = half of real: the user wanted that strength as the cvar's 1; the user
  picked the name, it is the siren's).
- `dev/siren_studio/build.js [--test]` builds `dev/siren_studio.html` (wasmoon from dev/baker, opens from disk; Chrome automation needs
  it served over http). `--test` renders every tone in Node and checks length, peak and the loop seam. The page mirrors sh_siren's rules
  for its in-game test (Shift = lights), previews the inside version and a Doppler pass-by, and writes the export in the file's layout
  (header comment taken from the file). Saves edits in localStorage (`siren_studio_settings_v2`).

## Car horns (separate module)
Own loader `lua/autorun/car_horn_init.lua`, files in `lua/car_horn/`, studio in `dev/honk_studio/`: delete those three to drop it.
Kept apart from the engine like the siren (never calls it; it only reads the `audio_engine_range` convar by name, falling back
to 250 m). Global `CAR_HORN` (`CarHorn`). Key: held `lalt` (`CONFIG.keys.honk`, the user's pick; client `car_horn_key`).
- `sh_horn.lua`: `CarHorn.HornOf(vehicle)` = `CONFIG.models[model]` or `CONFIG.default`, any prop_vehicle_jeep (passenger pods
  aren't: only the driver honks). NW2 `horn_on` + `horn_presses` (counted per press, wraps at 1024): a tap's press and release
  can land in one tick, the count still reaches every client.
- `sv_horn.lua`: net `car_horn` (bool, press/release), driver only, presses under 0.06 s apart ignored; off on PlayerLeaveVehicle.
- `cl_horn.lua`: builds horns ahead in a coroutine (4 ms/frame): the out version of every car within the silent range, the
  inside version of the car you sit in; a horn wanted before it's built goes next in the queue. One CSoundPatch per honking car:
  PlayEx at its volume (the attack is in the sound), loop while held, release = ChangeVolume(0, release.time) +
  ChangePitch(x release.pitch). A press sounds at least `MIN_HONK` 0.12 s; a new press while sounding restarts it (beep-beep).
  Each horn version is registered `COPIES` 4 times (samples shared) and a car's honks take turns: the game knows a playing
  sound by entity + name, so a fading honk's fade/stop killed a new one of the same name (the user: pressed twice, the horn
  never sounded again). Keep any sound that can overlap itself on one entity under distinct names.
  Your own car follows your key at once (not the server's echo; the count is still tracked so getting out isn't a "press").
  Generated an octave low, played at pitch 200 (half-percent Doppler steps, as the siren). Doppler from sampled positions,
  tracked while silent too so a honk starts at the right pitch. Fall-off `CONFIG.distance` { full 0.1, at 0.6, volume 0.3,
  silent 1 } in shares of the engine's range at the horn's soundLevel (the user's spec: loud close up, 30% at 60% of the
  engine's distance, still falling), x Source's own falloff; inside: cabin volume, no fall-off/Doppler. Nearest
  `car_horn_maxcars` 8 honking cars heard (yours always). Revived once a second if the game dropped it. Key ignored while
  typing, in menus or unfocused (alt-tab lets go). Client: `car_horn_volume`, `car_horn_doppler`, `car_horn_maxcars`, `car_horn_key`.
  Offline check: a mock (mocked GMod + the real config/synth/cl_horn under the baker's wasmoon) is not in the repo.
- `sh_horn_config.lua`: `CAR_HORN.CONFIG` (volume, soundLevel, sampleRate, cabin, keys, `default` horn, `models[model]` = horn id,
  `horns[id]` { units { f, level }, harmonics, rasp, air, jitter { rate, depth }, shimmer, grille, roughness, growl, flutter,
  attack { time, pitch, curve }, release { time, pitch }, speaker }), written by the studio's export. Must stay plain Lua.
  Horns (the user kept these; a meep and a klaxon were dropped): dual (disc pair 415/520), trumpet, sport, american, airhorn
  (semi truck: two trumpets, the user's 190/246.4, 24 brassy harmonics, roughness 35 cents + growl 0.2 + heavy rasp, no
  grille, a ragged 0.12 s start with only a 5% pitch rise).
  `models`: a horn per car model, picked by what the real car would have (the horn module doesn't read the engine's car list):
  trumpet = German/British luxury and classic GTs (Mercedes, BMW, Aston, Jaguar, Range Rover, Maserati, Lexus, Cayenne,
  Veyron, the 250s and Miura), sport = supercars, american = US cars/trucks/work vehicles (+ Holden, DeLorean, Tesla),
  airhorn = Fire Truck, Courier Truck, SWAT Stockade, Lenco BearCat (the user's pick); the other 62 (European/Japanese everyday cars, vans) the default dual. The user said a three-trumpet major chord and a smooth
  0.2 s glide up from 0.75 sounded "harmonic, not like an actual air horn, especially the wind up": no musical glides or chords.
  The user found the first versions "way too artificial" (the trumpet "out of GTA:SA"): they were dead steady with the note
  loudest. Now every horn has jitter (each unit's own random pitch drift), shimmer (per-cycle level) and, on cars, a grille
  (bumper reflections), and the disc horns' harmonics are weak at the note and loudest around 2-3 kHz, like a real disc horn.
- `cl_horn_synth.lua`: plain Lua, game and studio. One sound per horn: the attack (pitch scoop + level rise), `SETTLE_SECONDS`
  0.05 steady, then a `LOOP_SECONDS` 2 s seamless loop (every wobble and noise read by the position in the loop, units tuned to
  whole cycles; the settle is fed exactly what the loop's end is, so filters and grille wrap in the same state; `--test` checks
  that the two match); returns `loopStart` for `sound.Generate`'s loopStart. Rasp = noise burst each cycle where the diaphragm hits
  its stop. The release isn't rendered: played as a volume fade + pitch fall (in game ChangeVolume/ChangePitch over release.time).
- `dev/honk_studio/build.js [--test]` builds `dev/honk_studio.html` (as the siren studio; `--test` checks every horn, outside and
  inside, for length, peak and the loop seam). Hold the honk key or the Honk button; "Beep beep" = two taps. Saves edits in
  localStorage (`honk_studio_settings_v1`).

## Debug module (not part of the final addon)
`lua/audio_engine_debug/`, loaded by audio_engine_init.lua when the folder exists (delete it to ship). On by default (`audio_engine_debug` 1, shared; 0 = off);
superadmins, listen host or single player (`EngineDebug.Allowed`). `audio_engine_debug_menu`, `!enginedebug`, context menu. The core never refers to it:
it wraps `AudioEngine.GetEngineConfig` (`EngineDebug.Install`, `EngineDebug.BaseConfig` = the core's) and uses `AudioEngine.ApplyGearing`, `AudioEngine.RebaseHandling`, the E tables.
- `sh_kv.lua`: Valve KeyValues parse into entries with value spans (`KeyValues.Rebuild` keeps the file byte for byte), `KeyValues.PARAMS` script key -> GetVehicleParams
  field, `KeyValues.ApplyValue` scales by new / file value (unit-free; a file 0 is taken as is, mph -> in/s for speeds). Unmapped keys (wheel radius, materials, sounds) = respawn.
- `sh_debug.lua`: `EngineDebug.SERVER_CVARS`, `EngineDebug.TUNABLES` (AudioEngine.TRACTION / STABILITY_DEFAULTS / ANTI_SPIN / HIGH_SPEED_STEER values set live), gearing text
  (`EngineDebug.EncodeGearing`), `EngineDebug.GearingFromConfig`, rev "rise,fall". Live overrides: NW2 `audio_dbg_gear` / `audio_dbg_rev` per car, Global2 `audio_dbg_rev` -> Drivetrain.REV.
- `sv_debug.lua`: net `audio_dbg_*`. Script = the car's `vehiclescript`, or on test_car the PERP script it stands for, synthesized as test_car.txt with
  `AudioEngine.PERP_PHYSICS` values; baseline (`vehicle.audioDebugBaseline`: file text, params, mass) taken on first request, edits always scaled from it. `audio_engine_debug 0` undoes everything.
- `cl_debug.lua`: pages Handling script (edit, apply live, copy, save to data/audio_engine_debug/scripts/), Gearing (shift speeds, chart, audibility
  check, copies an AudioEngine.CAR_GEARING entry), Rev response (copies AudioEngine.CAR_REV / Drivetrain.REV), Handling (PERP default handling = handling/traction/stability 0), Settings.
- `cl_perf.lua` / `sv_perf.lua`: profiler. Measures nothing until turned on (the user's rule): the wrappers on the addon's hooks
  (names `audio_engine*` / `police_siren*`), util.Trace*, CreateSound / CSoundPatch methods, DynamicLight, render quads/sprites,
  NW2 setters (`audio_*`/`siren_*`, changes only), net.Start/Send, and `AudioEngine.PerfCar` (cl_engine's per-car timing point, a nil check
  otherwise) go on only while a capture or the overlay runs and come off after; the server's poll timer exists only then; a Lua
  refresh takes the old wrappers off (`EngineDebug.PerfClient/PerfServer.Uninstall`). `audio_engine_perf [s] [client|server|both]` prints
  a console report; `audio_engine_perf_hud` live overlay (server figures once a second to subscribers); `audio_engine_perf_snapshot`
  cars, patches, memory with no timing; `audio_engine_perf_spawn <n> [car|mixed] [lights] [mph] [grid|race]` / `_clear` stress test.
  race: a column 60 m down the road coming at you, 5 m to your right, zig-zag +-1.4 m, random 8-25 m gaps (`RACE` in sv_perf),
  every car setting off together once all engines started, at 3x the grid's acceleration (21 m/s2): drive-by Doppler / pass-by.
  With mph the cars drive off: handbrake released (a driverless jeep holds it on: it kept them standing) and pushed along their nose each tick (~7 m/s2 up to mph, then held, kept straight; a car still standing after 3 s, or not started after 8, is reported to the console; hook
  `audio_dbg_perf_drive` only while any drive), sounding W held (NW2 audio_in 1) and at speed the limiter's hold (audio_limst 1).
  Memory: generated banks keep their samples in Lua tables (8 B each, held by the sound.Generate callbacks) + the engine's copy
  (~2 B); counted as `bank.samples` (cl_soundbank); baked banks = their WAV file sizes; the siren's `PoliceSiren.Stats()` (cl_siren).
  Smoke-tested in a mock (wrappers off after each run); not yet measured in game.
- Power cut after a turn: releasing A/D with W held enters sv_stability's straight-line hold, which counted the turn's leftover yaw as `audioSlideAmount`,
  and traction control cut to `slideFloor` 0.2. In game the reading stayed 0.4-1.0 for 3-6 s (wheel slip 0) until W was pressed again: now
  `holdGrace` and `slideMaxTime` (both on the Handling page). Why the hold's reading persisted isn't known yet: the log's last two columns show it.

## dev/ (not needed in game)
- `dev/baker/` (Node + wasmoon@1.16.0, `npm install` there): `node bake.js` renders all stock engines (~6 min on 5 workers) into
  `sound/audio_engine/` + `lua/audio_engine/cl_baked.lua`. Re-bake after changing cl_synth, cl_soundbank, sh_presets or the car list.
  `node bake.js --electric` re-bakes only the electric motors + env bank (~15 s) and keeps every other entry and folder:
  only for changes that can't touch other engines (it fails if any other engine's sound key is missing from the manifest).
  `analyze_wav.js <wav|folder>` prints loudness and pitch per band. `test_handling.js` checks sv_handling with a fake vehicle. `test_debug.js` checks the gearing/rev core and the debug module's shared code. `check_syntax.js` compiles all Lua; `test_integration.js <PERP dev pack dir>` checks muting and baked banks.
  wasmoon leaks stack slots on `doString` return values: return results through a JS callback (`__result`).
- Offline harnesses run under LuaJIT (`luajit file.lua` from `dev/`). Fix the hard-coded paths at the top first: they point at /home/claude/....
  - `gmod_sim5.lua`: drive mix
  - `showcase.lua`: rev clip per preset (`PRESET=v8x luajit showcase.lua`)
  - `bov_test.lua`
  - `sv_ignition_test.lua`
  - `measure_loud.lua`: loudness and limiting per preset
  - `presets_test.lua`
  - `menu_test.lua`
  - `drive_preset.lua`
- Browser test page (runs the addon's real Lua in Lua 5.4/WASM via wasmoon, plays it with Web Audio like Source):
  - Source files: `template.html`, `host.js`, `bridge.lua`, `gmod_shim.lua`.
  - `build.py` inlines everything. It needs wasmoon@1.16.0 from npm; set the path at the top.
  - Output: `rev_bench.html`.
- Tone Studio (`dev/tone_studio/`: `studio.lua`, `worker.js`, `worklet.js`, `template.html`): `node dev/tone_studio/build.js [--test]` builds
  `dev/tone_studio.html` (self-contained, opens from disk; uses dev/baker's wasmoon). Streams any car live with the real synth
  (same files as the baker, ~4.4x real time at 44.1 kHz in WASM, so no JS port): `LIVE.step` renders one 735-sample control tick through
  `Synth.RenderControlled`, AudioEngine.Drivetrain drives the revs (Rev/Drive/Sweep/Hold; W/S, Space, B for A/B). A change reaches the ear in ~160 ms:
  `LIVE.config` copies what NewGen/NewChain derive onto the running engine, keeping its state, so keep `GEN_FIELDS`/`CHAIN_*` in step with them.
  Worker -> worklet straight over a MessagePort. No bands live, so worker.js `level` stands in for the bank's loudness matching. Generational Lua GC:
  the default collector paused up to 120 ms. Turbo/BOV aren't previewed. Also draggable exhaust resonances and firing bars (custom layouts: 1-16 firings),
  start from a preset, silencer; exports changes as text + JSON to paste back: `sound`/`character` as ever; `muffle` = car.muffle; `layoutDef` = a new
  entry for Synth.LAYOUTS, Synth.CHARACTER (voice of `voiceFrom`), AudioEngine.LAYOUT_CYL and AudioEngine.LAYOUT_ORDER. Per-car voice: `P(preset, stock, character)` in sh_carlist (cl_synth `Synth.CharacterFor`, part of the sound key).
  Preset-scope voice: a preset's own `character` (used when the car has none) and `muffle` (the car's silencer, over the economy one).
  V8 voices: v8x heavy duty (trucks, work vehicles), v8m old muscle, v8p modern performance, v8r refined sedan. I4: i4/i4st sporty, i4w warm hatch (regular cars), i4q quiet hum (cheaper cars). `economyTuned` presets were tuned on an
  economy car, so economy cars keep their tone and gurgle (no x0.5, no gurgle 0).
  Engine ideas panel: `dev/tone_studio/candidates.json` lists sounds to audition before they reach sh_carlist (each is an ordinary edit of its
  example car; `[]` hides the panel). Nothing in it reaches the game.

## Naming (the code is reviewed by people: keep names spelled out)
- Module aliases: `local AudioEngine = AUDIO_ENGINE`, `Drivetrain`, `EngineDebug` (AUDIO_ENGINE.Debug), `KeyValues` (AUDIO_ENGINE.KV),
  `PoliceSiren` (POLICE_SIREN). Locals and fields are full words: `config` (was cfg), `engineState` (the drivetrain state, car.engineState),
  `deltaTime`, `vehicle`, `player` (`requester` where a file also uses the `player` library), `entity`.
- Drivetrain state: throttle, soundThrottle, fuelCut, limiterCutTimer, limiterHoldTimer, limiterEvent, shiftTimer, shiftDirection,
  gearHoldTimer, blowOffEvent, acceleration, ...; its controls { forward, backward, handbrake, steering, holdingSpeedLimit, speed }.
- Synth generator messages { targetRpm, targetThrottle, fuelCut, crankMode, ignitionOn } (tone_studio/studio.lua sends them too and
  copies GEN_FIELDS / CHAIN_FIELDS / CHAIN_FILTERS by name: keep those lists in step with Synth.NewGen / NewChain).
- Kept as they were, because something outside the code reads or writes them: convar, NW2, net, hook and concommand names, sound
  file names, profile fields (accel, vmax, popVol, turboVol, bovVol... and the pipe string), preset / CHARACTER (f1, w, o1, o05) /
  LAYOUTS fields, the bake manifest (cl_baked.lua: sr, cyl, dur ...), siren CONFIG fields, CAR_GEARING { mph, rpm, down, topRpm },
  the tables the debug menu tunes by key name (TRACTION, ANTI_SPIN, STABILITY_DEFAULTS, ...), sh_police lamp data keys
  (position, normal, width, height). Filter maths keeps the Audio EQ Cookbook names (b0..a2, w0, alpha).
- The baker's folder hash covers cl_synth / cl_soundbank / sh_presets sources: the next bake after a rename-only change gives every
  engine new file names (a full re-download for players), though the sound is bit-identical.

## Gotchas
- `sound.Generate` sounds can't be freed or overridden; names are `audeng_<serial>_<name>`. Volume caps at 1, pitch 0-255 and truncates to an integer.
- CSoundPatch volume/pitch only change once per frame. Never jump volumes; use the glide.
- Lua 5.1/LuaJIT idiom bug to avoid: `x and (y == "1") or nil` returns nil for false (this broke the BOV toggle once).
- PERP's vehicle scripts (workshop 3792392486) are a server download: mounted only on the PERP server. A jeep spawned with a
  missing vehiclescript has no physics and can't drive; sh_perp's spawn entries fall back to `scripts/vehicles/audio_engine/test_car.txt`.
  For 1:1 local testing, `addons/perp_vehicle_scripts_local/` (outside this repo, never shipped) holds a copy of the pack's
  `scripts/vehicles`: cars then spawn on their real scripts and `applyPerpPhysics` is skipped.
- wasmoon: never return JS `null` to Lua (crashes); use `''`.
- Generation cost: ~2 s CPU per engine at 44.1 kHz in game (~16 s in the browser page); ~4 MB each, `audio_engine_maxsounds` cap.

## Open ideas (not requested yet)
- Electric whine layer for hybrids; real diesel character (diesels currently use softened petrol presets).
- Confirm the uncertain car mappings (INTEGRATION.md section 8) against PERP's dealer table.
