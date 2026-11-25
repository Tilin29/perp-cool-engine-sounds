# Audio Engine addon: notes for Claude Code

Garry's Mod addon for the PERPHeads server (128 players, up to ~40 cars in one area, 165 car models).
It started as a police RTU Mercedes SL65 AMG (TDM Cars based), and has grown into a shared engine
system for every car. Engine sounds are **generated procedurally** by a synth ported from the "Rev Bench" web page. Every car's stock engine
is rendered offline by that same synth (`dev/baker`) and shipped as WAVs; only engines tuned in game are generated on the client.
Keep the synth the single source of every sound (no recordings). Porting the sounds into PERP: `PORTING.md`.

## Layout
- `lua/autorun/audio_engine_init.lua`: loader. Shared: sh_config, sh_presets, sh_drivetrain, sh_handling, sh_carlist, sh_perp, sh_police. Client: cl_baked, cl_synth, cl_soundbank, cl_engine, cl_hud, cl_menu, cl_police, cl_handling. Server: sv_perp_physics, sv_handling, sv_engine, sv_cruise, sv_police, sv_seats.
  Then the debug module (`lua/audio_engine_debug/`, see "Debug module" below), if that folder exists: deleting it is all it takes to ship without it.
- `sh_config.lua`: `RegisterCar(model, cfg)`, `GetCarConfig` (keeps each model path's lower case: called per car per tick/frame). `audio_engine_editor`
  (shared, default 0, `AudioEngine.EditorEnabled()`): the Rev Bench menu (cl_menu: command, `!engine`, context menu; sv_engine rejects `audio_engine_set`) only when 1.
  cl_menu has no gear card any more (its ratio editor never reached the car; it forces `fit = 1`).
- `sh_presets.lua`: layouts, gearbox presets, 39 engine presets, profile Sanitize/Encode/Decode
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
  lenses of `models/perpheads/props/police_lightbar.mdl`, workshop 2897742669 (its textures live in that item's content.gma under
  materials/models/jarheads/props/police_lightbar/; copies of the 6 the bar uses and an LED rebuild of it are in this
  addon (see "Police lightbar" below)): model space long axis X, front +Y like the cars, so `AudioEngine.LIGHTBAR_ANGLE` 0; its mesh is in a root bone
  turned -90 deg, which `module()` undoes; -X driver's side, red; +X blue; centre white). `sv_police.lua`: on spawn (script, or the
  spawn entry's `AudioPerpScript`) sets the livery skin (11; Crown Vic police 12, its 11 is the taxi; Transit has one skin), hides the
  Crown Vic's taxi sign/meter, parents a `prop_dynamic` bar (NW2 `audio_lightbar`); `audio_engine_lights [0-2]` (driver only) steps
  off / CODE 2 / CODE 3 (NW2 `audio_lights`). `cl_police.lua`: the LED bar (this addon's) lights its own lenses (its skin's
  VMTs); nothing is drawn over a bar any more, PERP's original included (the user: no overlaid colours); built-in lamps still get a drawn
  additive lens quad per lit module; sv_police prints which bar model is in use at load; the glow
  is one dynamic light per car (the nearest `MAX_DLIGHT_CARS` 8) in the colour flashing then, over the side it flashes on (the user:
  `BAR_LIGHT_OFFSETS` x -22 driver's / +22 passenger's / front centre; built-in lamps: that side's lamps' middle), colours `COLORS` = the lit
  lens PNGs' average, at full brightness (blue 45, 139, 255: the old 25, 70, 255 looked wrong in the dark, the user) (the user: one light source,
  not a sprite per lens + a light per side); key `audio_engine_lightkey` (default lshift;
  no police script has a Source boost block, so shift is free). HUD shows the mode, plus whatever the `audio_engine/lights-label`
  hook returns (veh) after a dot: the police siren module (below) answers with its tone.
- Passenger seats: `sv_seats.lua` (`audio_engine_seats`, default 1). PERP's own: `AudioEngine.PERP_SEATS[name]` { seats { x, y, z, p, y, r }
  = the airboat-seat pod's origin + angles in the car's space, exits { x, y, z } } (sh_carlist, `config.perpSeats`), 173 of 175 cars, written
  by `dev/perp_seats.py <garrysmod/cache/lua> <sh_carlist.lua>` from the PERP gamemode's VEHICLE.PassengerSeats / ExitPoints (shared files in
  a client's Lua cache: 32-byte hash + LZMA alone; replayed statement by statement, job variants are copies of their civilian car).
  The others (Transit 2016 Prisoner Transport, SWAT Stockade) keep the estimate `AudioEngine.CAR_SEATS[name]` (`config.seats`):
  laid out from the driver's `vehicle_feet_passenger0`, front passenger mirrored, back row `AudioEngine.SEAT_REAR_PITCH` 0.3 x wheelbase
  behind, `SEAT_REAR_RISE` 4 up; unlisted 4, lists { side, back, up[, width] }. E (`PlayerUse`) enters the free seat nearest the
  player (the driver's = Source's own entering); a seat is a no-draw `prop_vehicle_prisoner_pod` made only while occupied
  (physics frozen, collision group world), entered a tick after it's made and checked a tick after that (entered in the
  PlayerUse tick it was created, the user got a view snapped to the floor and no seat), failures printed to the player's
  console (incl. CanPlayerEnterVehicle refusing it), eyes set forward (0, 90, 0); removed on getting out, the player put at the nearest clear PERP exit point (looked for `EXIT_LIFT` 16 up: they sit at the car's origin), else beside their door (else other side / behind / roof, hull-traced). Locked cars refuse passengers. Out of any seat (the driver's too) no seat is entered until E is let go (`audioSeatUseHeld`, KeyRelease) and `USE_COOLDOWN` 0.75 s is over: the E that got the driver out went on to put them in the nearest free seat, now and then the passenger's. Getting out of any seat you keep looking where you looked (the game turned you to look at the ground): `CanExitVehicle` takes the view in world angles as you ask to get out (`audioSeatView`, the seat's LocalToWorldAngles of EyeAngles, roll 0; PlayerLeaveVehicle may already see the turned ones), set back a tick after leaving.
  `AudioEngine.RiddenCar(player)` (sh_config): the car a player drives or sits in; cl_engine treats it as the listener's own car.
- `cl_baked.lua`: GENERATED by `dev/baker/bake.js`. Per sound key: folder under `sound/audio_engine/`, band rpms, peaks, timings.
  Redline families: `config.familyKey` = sound key minus redline (not electric). Each family is baked once at its highest redline;
  `AudioEngine.BAKED_FAMILY[familyKey]` points lower redlines at it (unused top bands stay silent, cl_engine pitches the limiter loop by
  `config.redline / bank.limiter.rpm`). The emotion start flares to 0.55 x redline, so families also ship `starte_<flare>.wav`
  variants (`startEmoAt`); a tuned engine whose flare has no variant gets the closest one.
- `sh_drivetrain.lua`: rpm/gear model shared by client and server. Start-up sequence (catch, flare, settle: drivable after 2.2 s, 3.6 s with the emotion flare; electric = `Drivetrain.EV_START_SECONDS` 3 s power-up, the user's: it was 0.6 s),
  arcade automatic driven by RPM thresholds (W/S/Space are on/off keys), torque converter, turbo boost and BOV event.
  Upshift point follows the car's acceleration (`upRpm` pulling hard .. `lazyUpRpm` creeping), so power-limited cars reach top gear.
  Past `upRpm` it changes up even inside the post-shift hold (close-geared hard pullers like the M5 E60 hit the in-gear limiter).
  Neutral (Space+W rev) latches until W or S is pressed. Space drops into it only after `Drivetrain.NEUTRAL_HOLD` 0.35 s at a standstill
  (tapping Space with W held swung the revs 3000 <-> 7000 twice a second: the user's "alien noise"; `DRIVE=spam` in dev/drive_demo, SPAM_W / SPAM_SPACE). The limiter loop (cl_engine) plays only while W is held near redline.
  Free-revving uses `Drivetrain.REV` { rise, fall } 500/500 (`Drivetrain.FreeSpinRate`; per car `config.revRise/revFall` from `AudioEngine.CAR_REV`), not
  `Drivetrain.TMAX` 320, which stays for the synth's baked limiter loops and start tails (changing TMAX needs a re-bake). 500 falls from 90% to near idle in ~2.5 s (320: ~3.8 s).
  A car's own gearing (`AudioEngine.CAR_GEARING[name]` -> `car.gearing`, sh_presets `AudioEngine.ApplyGearing`, only with `fit > 0`): per gear `{ mph, rpm }` where it
  changes up flat out (lazy upshifts at the same lazyUpRpm/upRpm share of it), `down` mph to change down coasting/braking, last entry = top gear
  (`topRpm` at `config.topSpeed`); sets `config.gears` as overall ratios, `final = 1`, `config.shiftPlan` { up = rpm[g], down = m/s[g] }. Each gear at least
  `AudioEngine.GEAR_MIN_STEP` 1.1 taller. Kickdown/corner landings also stay under the target gear's up rpm.
  Fitted gearing comes from the top speed only, deliberately not realistic (the user's choice; a time-based, realistic spacing
  with up to 7 gears was tried and reverted) (`AudioEngine.FitGearEnds`, `AudioEngine.GEAR_FIT`): 1 gear per `kmhPerGear` 20 km/h, steps at most
  `stepMax` 2.3x, 1st ends at `firstShare` 0.28 of top speed (at least `firstMin` 25 km/h), gear ends evenly spaced in speed^`spread` 3
  (was 40 / 2.2: most PERP cars, under ~140 km/h, got 3 gears and sat in the last for about half a flat-out pull, the user's complaint;
  now ~0.2 of it, median, in the drive demo's acceleration model);
  2 to `maxCount` 5 gears (or the box's count if lower). The top speed is the tier script's MaxSpeed (PERP spawns base / upgrade_1 / upgrade_2,
  each with its own, so each tier has its own gearing; NW2 `audio_vmax`); used/ and spiked/ cars keep the gearing of the tier they came from
  (`config.gearTopSpeed`, NW2 `audio_gear_vmax`, sv_engine `AudioEngine.GearingTopSpeed`): used = the base script's MaxSpeed (read from the file,
  else `PERP_PHYSICS`), spiked = the car of the same model removed within 2 s / 200 units of where it spawned (PERP respawning it), else the base's.
  `config.topSpeed` stays the car's own (supercharger fade, debug chart). `CAR_GEARS[name]` overrides the count, 2..8: Furai 6 (the only 6-speed), both Mini Coopers 3.
  Manual gearing (`AudioEngine.CAR_GEARING`, debug gearing editor) still replaces the fitted gears.
  `AudioEngine.GearAccel`/`AudioEngine.GEAR_ACCEL` (pull `perWkg` 0.035 x power to weight, W/kg from NW2 `audio_pwr`) is now only the model that
  `audio_engine_accel_log` and dev/drive_demo compare against, not used for the gear spacing. HUD speed defaults to mph (`audio_engine_units`).
  The top gear never reaches redline: at top speed it turns `AudioEngine.TOP_GEAR_DROP` 1000 rpm under redline (`AudioEngine.TopGearShare`, at least
  `AudioEngine.TOP_GEAR_MIN` 0.7 of it, the user's rule; FitFinal; test_debug.js checks every car at 0.8-1.3x its base top speed), the gears are spaced up to
  that gear's redline speed, and there's no lazy upshift into it: the car changes up near top speed and settles lower.
  Cruise (`inp.cruise`): highest gear above `cruiseLand` 0.45, down only below `sagRpm`, no kickdown, steady `cruiseThr` 0.8 (pedal 80% down).
  Cornering (A/D, networked as input bit 8; `inp.steer`): no lazy/stall upshifts, changes down below `cornerRpm` 0.65 (to under `cornerLand` 0.88); coasting lugRpm 0.4.
  Downshifts with W held (kick/sag/corner) judge the wheels' revs, not `st.rpm`: converter slip keeps that over ~0.47 x redline
  with W held, so a car slowed by a turn stuck in its gear. No lazy upshift while slowing (`st.accel > 0`), and slowing isn't a stall.
  Upshifts under load: a torque cut `Drivetrain.UPSHIFT_CUT` 0.09 s (sound throttle 0.05) then `UPSHIFT_TAKE_UP` 0.12 s back,
  the revs dropping at `Drivetrain.UPSHIFT_REV_RATE` 8 (~0.28 s; 14, ~0.15 s, swept the pitch down so fast the user heard it as
  robotic; was 7 with an ease from 0.3 over 0.32 s); cl_engine
  follows the throttle at 30/s through it (12 otherwise), dev/drive_demo too.
  Braking downshifts are low and gentle (`brakeRpm` 0.45, `brakeLand` 0.70, `softShift`: blip 0.25, rise rate 8): at 0.80/0.96 with
  a full blip hard braking ran a sawtooth near redline that sounded cartoonish. cl_engine feeds the model the car's full speed
  signed by the nose (`car.driveSpeed`), not the speed along the nose, which collapsed in a slide (revs plunged, then shot back up).
- `cl_synth.lua`: generator. Firing pulses on a 720° cycle, two exhaust banks, per-layout CHARACTER (f1/f2/f3, w, o1, o05),
  gurgle, flow grit, bark. Every engine has its own random numbers (`Synth.EngineSeed` = `Synth.SeedFor(config.familyKey)`, LuaJIT- and
  5.4-exact: the cylinder unevenness and the firing's jitter; it was one seed for every engine, so all had the same unevenness, which
  a tester heard as "too similar, robotic"; electric keeps the old seed). Layers that skip the exhaust's filters (`bypassBuffer`, filled
  by GenRender, added after the chain in `RenderControlled`; not in pop/bang renders, which keep the old in-exhaust ticking): intake
  (each firing's breath ringing an airbox resonance `intakeHz` + a throttle-body howl band, airflow ~ throttle^1.5 and revs; muffle
  cuts it 60%), valvetrain (clicks at each firing and halfway, ringing `valveHz` and 1.47x; 0.55 x (1 - 0.6 x revs share) x (0.5 + 0.5 x throttle):
  it rose with revs at any throttle and high up the dense clicks were a hiss, over the exhaust above 2 kHz off throttle, the
  "vacuum" the user heard revving), gear whine (a sine at `whineOrder` per
  crank turn, 0 = 17..31 from the seed, 0.25 + 0.75 x throttle). Per-layout defaults `INDUCTION_DEFAULTS`, merged into CHARACTER;
  a voice can set them (`AudioEngine.CHARACTER_FIELDS` in sh_presets = the character fields in the sound key). Levels
  `INTAKE_RESONANCE_LEVEL` 0.010 / `INTAKE_HOWL_LEVEL` 0.14 / `VALVETRAIN_LEVEL` 0.035 / `WHINE_LEVEL` 0.015: at 50-95% redline full
  throttle intake -33..-45 dB under the exhaust (0.026 / 0.35, -25..-38, revved like a vacuum cleaner: the user), valvetrain -24..-33, whine -41..-46 (rms above 250 Hz). The user's: the first
  levels (15 dB more intake, 6 more ticking, 12 more whine) covered the engine ("mainly the gears"), the steady whine sounded
  robotic, the intake should be faint. The whine wavers (~3 Hz drift, +-45% level, 0.4% pitch).
  Compared with real recordings (YouTube: M3 E92, S2000, Mustang GT, R8 V10 pulls next to drive_demo renders): real engines'
  sound above ~1 kHz is rev-locked harmonics, ours was noise; the low pipe mode rang as a fixed drone (~75-110 Hz); gear
  changes glided. So: a steeper pulse attack (`PULSE_ATTACK_SHARE` 0.12 / `PULSE_ATTACK_MAX` 0.9 ms, was 0.22 / 1.8),
  broadband noise x `NOISE_SHARE` 0.5, `LOW_RESONANCE_DECAY` 10 ms (was 22), the tracking low-pass with voice opens to
  340 + 1300 x throttle x (0.5 + tone) + 0.3 x rpm, cap 4.8 kHz (was 320 + 1000 .. + 0.12 x rpm, cap 2.8 kHz), top low-pass
  4200 + 1300 x voice (was - 800), high shelf -8 + 4 x voice (- 10 x muffle), the 95 Hz body peak halved with voice. 1-2 kHz
  line-ness (mean/median power) went from 2.2-3.4 dB to 2.8-4.6 (real 2.5-5.4); the fixed 65-100 Hz share in the upper bands
  is 5-9 dB lower. Tried and dropped: shorter pulses (`PULSE_SECONDS` 0.004: high in the revs pulses are capped at 42% of the
  firing gap anyway) and double cylinder variation (no change; the cabin clips' low end is the cabin's). Not yet heard by the user. `Synth.EVRender` for the electric motor, after the e-NVH literature (the user asked for real EV
  sound): orders per motor turn `EV_PARTIALS` 9.5 (reduction gear 2nd stage mesh, the classic whine: ~1 kHz at 60 mph), 19, 24 (motor
  electromagnetic), 31 (1st stage mesh), 48 (31/48 kept faint, 0.16/0.08: at 0.30/0.24 the top of the revs whistled at 7-11 kHz, the user
  said too high), gear meshes rattling at the shaft rate (`EV_MESH_RATTLE`, side tones +-1 order), a slight speed ripple, a bearing/air
  hiss (1.5-3.5 kHz); housing response passes 0.3-4 kHz, steep above (`evBodyResponse`); level follows torque (regen softer) and
  speed (0.35 + 0.65 x share^0.5, so there's a whine from pulling away); orders whole/half for the 720 deg loop. Bands 1.35x apart;
  electric bands keep natural levels, no per-band loudness matching, the top band's on loop is set to `TARGET_EV_DB` -22 dB rms full band;
  cl_engine plays EVs at `AudioEngine.EV_VOLUME` 0.1 (the user's: 0.5, then 0.2, were too loud, 0.05 too quiet) and their warning sound at `AudioEngine.EV_HUM_VOLUME` 0.2 (the user's). (Before: one tone capped at 450 Hz, -32 dB and 0.1:
  ~30 dB under the engines, "no sound" in the Tesla.) Measured A-weighted in dev/drive_demo, the Tesla ran 3-5 dB under a BMW 1M at 0.5, 7-9 dB at 0.2; at 0.1 the motor is ~6 dB under that, and at speed the road noise (not scaled) is much of what you hear.
  No inverter (PWM carrier) tone: it doesn't follow the revs, so it can't live in the pitched band loops. `RenderEVHumLoop`: the
  pedestrian warning sound (AVAS, env bank `evhum`, rms 0.12): 330 Hz + octave and a faint 800 Hz in a little air (two third-octave
  bands, as UN R138 / FMVSS 141 ask; 1.25 kHz and more air was a loud "idle fan" to the user); cl_engine plays it at EV_HUM_VOLUME x 0.35 x (0.35
  standing .. `EV_HUM_MOVING_GAIN` 2 moving: the user wanted it louder driving slow, was 1), standing still heard only near the car (the user: ~5 m; `EV_HUM_FULL_DISTANCE` 3 to `EV_HUM_SILENT_DISTANCE` 5 m from
  the body, `NearestPoint`, smoothstep; not for whoever sits in it); moving it carries like the motor (the limit fades out by 2 m/s, `movingShare`:
  the user, it was near-only at any speed; driving, it measures -43 dBA in dev/drive_demo, the motor -44..-49 at 20-80 mph), full to `EV_HUM_FULL_MPH` 30 mph, gone by `EV_HUM_GONE_MPH` 35 (the user's; was 20 -> 30 km/h), pitch +0.8% per km/h (the UN rule). `RenderEVChime`: a chime as an
  EV powers up (the user's idea): `Synth.EV_CHIME_NOTES` { hz, at, level }, soft rising notes ringing into each other (E5 A5 C#6, 0.14 s
  apart, mellow detuned bells, ~1.6 s; was three equal 880 Hz dings 0.32 s apart, which the user heard as an error warning) (env bank `evchime`); cl_engine `playIgnitionChime` plays it
  once the car is ready (phase run, `car.chimeAtReady`; it was at the key) only for whoever sits in the car (CreateSound on LocalPlayer, sound level 0 = 2D) at `AudioEngine.EV_CHIME_VOLUME` 0.3, on a
  real start (not one skipped on joining). `RenderEVPowerUp` (env bank `evpowerup`, 3.4 s, played at the key at the car,
  `AudioEngine.EV_POWERUP_VOLUME` 0.06 (the user: 0.03 a bit quiet), sound level `EV_POWERUP_SOUNDLEVEL` 65): pre-charge relay tick + capacitor whine (1.4-2.2 kHz),
  main contactor clunk at 0.5 s, then the motor energising 165 -> 330 Hz into the warning hum's notes, easing back 6 dB from 2.2 s and fading
  as the hum comes in at ready, so its end stays a few dB over the standing hum (without the ease, 0.1 was 15 dB over).
  dev/drive_demo applies EV_VOLUME and the warning sound like cl_engine (`STEMS=1` also writes motor / hum / road / other tracks + speeds). Exhaust chain (WebAudio biquads). Pops via `RenderBackfire`:
  a ~1 ms thump + 35-100 ms muffler scatter, body peak 140-190 Hz, low-passed (a 0.4 ms click with light saturation sounded like
  firecrackers); crackles are ragged 4-8 pulse "b-r-rap" runs. Levels (cl_soundbank): pops 4 dB under the loudest band, bangs 3 dB over;
  played at 0.7 x (cl_engine `popVolume`, ~3 dB up on the 0.5 they used to play at).
- `cl_soundbank.lua`: builds a bank per soundKey in a coroutine (6 ms/frame budget). It holds:
  - one on/off-throttle loop pair per rpm band (bands ~1.26x apart), a limiter loop, start/stop one-shots, pops and bangs
  - **natural levels** (the user's: matching every band of every engine to -21 dB made them sound alike): bands and engines as rendered,
    one gain for all (`NATURAL_GAIN_DB` 0), a band whose on loop (rms above 250 Hz) would go over `CAP_DB` -18.4 (the loudest band under the
    old matching; the user: never louder than that) turned down to it, others untouched; electric `TARGET_EV_DB` as before. Then `limitPeaks` (look-ahead, circular for loops)
  - band loops stored at 0.95 peak with `layer.trim` (manifest `trims`) as the volume that restores their level: volume caps at 1, so quiet bands had no room for the pass-by swell (not electric)

  A shared env bank holds road, wind, turbo whistle, the EV hum, 2 blow-off sounds and the supercharger loops (`Synth.RenderSuperchargerLoop`: on boost + bypass per variant and band; the bypass loop keeps its on loop's gain). Sample rate is `audio_engine_samplerate`, 44100 or 22050; changing it rebuilds.
  - `Bank.Build` first tries the baked copy (`Bank.BakedEntry(cfg)`: own key or family, + file exists): names are then file paths `audio_engine/<dir>/<stem>.wav`.
    `audio_engine_baked 0` forces generation. Baked banks load lazily (when a car using them appears) and don't count toward maxsounds.
  - `Bank.Get`: past `audio_engine_maxsounds` an engine that would be generated (no baked copy, stock ones too: content missing)
    gets its car's stock bank, else a built bank of the same layout (`Bank.substitutes`); a failed build (`bank.failed`) falls back
    the same way. `Bank.RebuildAll` only clears: banks are made again as cars in hearing ask, the env bank swaps in once built
    (`replacesEnv`), and cl_engine restarts a car's loops when `Bank.env` changes (`car.envBank`).
- `cl_engine.lua`: per-car playback.
  - band crossfade with pitch; volumes glide (VOLUME_SLEW), which avoids per-frame zipper clicks
  - per-car headroom (ceiling 0.66 driving / 0.68 neutral, leaving room for band peaks lining up mid cross-fade, using measured peaks; pops/BOV limited with `popPeakLoad`)
  - Doppler pitch bends over past `DOPPLER_KNEE` 4 semitones towards `DOPPLER_MAX` 7 (`softPitch`): at four times real it was nearly an octave at 40 m/s
  - tunnels (`isTunnelAt`: roof, close walls, long open run, map only; 17 traces, listener at 4 Hz, cars one per frame): only for listeners outside a car (sitting in one, nothing changes): a car in one or any car while you're in one gets DSP
    `audio_engine_tunnel` (0 = off, default 1 = Source's auto preset, 7 = large tunnel, `CSoundPatch:SetDSP`); a car in one carries `TUNNEL_LEVEL` 8 dB further; both inside: no pass-by drop with range.
    SetDSP/SetSoundLevel go on before PlayEx (`startPatch`) and loops restart when the room changes (`roomGeneration`): not known to reach a playing sound
  - once a second each active loop is checked with `IsPlaying` and restarted if the game dropped it (`car.revive`)
  - `stopsound` kills every channel but not a CSoundPatch's own playing flag (Source's soundenvelope: `IsPlaying` is that flag,
    only `Stop()` clears it), so the revive never fired and cars stayed silent. Lua isn't told when stopsound runs: a key bound to
    it is caught (`PlayerBindPress`, 0.1 s later), typed in the console it needs `audio_engine_restart_sounds` (`AudioEngine.RestartSounds`:
    stopAll on every car, groups start again next update). The siren and horn restart theirs on the generic `audio_engine/restart-sounds`
    hook and catch the bind themselves too (each works without the engine)
    A typed stopsound (sirens stayed dead, the user): a volume change on a sound whose channel is gone starts it again (Source's
    S_StartSound falls through to starting it), so loops whose volume moves came back alone and steady ones didn't. Once a second
    every playing loop gets a volume change (`KEEPALIVE_SHARE` 0.002 under its level, alternating, ~0.02 dB): engine groups
    (`car.keepAliveLow`), sirens, held honks. Didn't bring the sirens back (the user), nor did a Stop + PlayEx: stopsound seems
    to drop sound.Generate data (the siren and horn are generated; the engines' WAV files came back). So the siren's and horn's
    restarts build every tone again under a new serial (`police_siren_restart`, `car_horn_restart`, also run by
    audio_engine_restart_sounds). Not yet confirmed in game; if it works, WAV files baked offline would survive a typed stopsound
    "Clean up everything" (game.CleanUpMap) broke the sirens the same way (the user); it's announced: `PostCleanupMap` restarts the
    engine (stopAll + `Bank.RebuildAll`, generated banks die too), the siren and the horn (each hooks it itself)
  - each car's update runs in a pcall (`updateCarSafely`, printed once per car): one failing car stopped every car after it.
    Every client `EntityRemoved` hook (cl_engine, cl_handling, cl_siren, cl_horn) ignores `fullUpdate` (entities stay).
    Back from dormancy a car takes the engine state as it is (no shut-down sound for an engine switched off out of view).
    Out of range / over budget: no bank lookup, Doppler or swell (`car.position` = this frame's GetPos, reused).
    `Drivetrain.Step` clamps the gear to `#config.gears` (a rebuilt config with fewer gears errored) and ignores a zero step
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
  - speed (`sampleSpeed`): position change over real time, sampled every 0.05 s or more, median of 3, frames over 0.3 s held, motion along the car's up axis left out; the car you drive takes the prediction's velocity instead (`AudioEngine.PredictedVelocity`, cl_handling, when it ran in the last 0.1 s: Source's position is ~a ping + interp late, so were the revs and gear changes pulling away / braking);
    the gearbox's speed (`car.driveSpeed`) moves at most `SPEED_SLEW` 40 m/s2. Dividing by the capped frame dt made stutters read as several times the real speed
  - Doppler (`audio_engine_doppler`: 1 = default, real, 4 = maximum, four times real. The scale was 0.25 = real until the user asked for 1:
    clients with the old `audio_engine_doppler_moved` cookie get their saved value x4 once (`audio_engine_doppler_real1` cookie)), road/wind, turbo/BOV from the env bank, pops logic
  - `audio_engine_reset_settings` (client): every engine player setting (`AudioEngine.PLAYER_SETTINGS` in sh_config: the client convars of
    cl_engine, cl_hud, cl_handling, cl_soundbank, cl_police) back to its default, printing each changed one's old value.
    The siren and horn have their own: `police_siren_reset_settings`, `car_horn_reset_settings`.
    `audio_engine_settings` (sh_config, both realms): prints every convar with its value (+ default where it differs): in a client's
    console theirs + the server's replicated ones (others "only the server can read it"), in the server console / rcon the server's.
    The engine's come from `AudioEngine.PLAYER_SETTINGS` / `SERVER_SETTINGS` (a new convar goes in one of them); the siren (cl_siren),
    horn (sh_horn) and debug module (sh_debug) append theirs through the generic `audio_engine/settings` hook { title, player, server }
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
- `cl_hud.lua`: the instrument cluster (the old panel is gone), centred at the bottom of the screen, no panel behind it
  (the user's), from the user's design canvas "Speedometer HUD" (claude.ai artifact 9u8bvacxqDaVy57zJ6s3tr: artboards A classic, B
  floating arc, C motorsport strip, A2 classic + police, A3 60s vintage, A4 80s digital, A5 German hatch, D modern digital, D2 wide-screen, D3 angled display; positions are its pixels x `CLUSTER_SIZE` x screen height / 1080 x
  `audio_engine_hud_scale`; the 1000 x 460 ones all use A's box, so they sit in the same place; the rev counter is always on the left of the speedometer, the user's: D, A5 and D2 were mirrored for it, in the design too). `audio_engine_cluster` 0..9 (the user's order: 1 = A, 2 = D,
  3 = A5, 4 = A3, 5 = A4, 6 = D2, 7 = D3 (its hexagonal screen and bezel drawn at `H.screenAlpha` 0.99, barely see-through: the user's, 0.8 and 0.9 were too much; the sweeps go through the stencil, their rectangles overlap, 8 = B, 9 = C; not yet seen in game); 0 = automatic = A; client, NOT archived: every load starts on 0).
  Clusters with emergency-light controls (`CLUSTERS[id].police`: A, D, A5, D2, D3 (its STATUS column): LIGHTS / SIREN in its centre panel over the warning / "Systems OK" line; its speed / revs / fuel are rings of bars on two round faces, solid digits (the design's outlined ones: the user didn't like them), every lamp in the centre panel (the user's design: outside the faces their grey was lost on bright scenery; dark pods were tried first), the gears N..top round the rev ring's foot) show them in any emergency car (a light bar or built-in lights, NW2 `audio_lightbar`:
  police, fire and medical, `EMERGENCY_SCHEMES` by `audio_lightscheme`; not unmarked cars): each scheme's siren buttons are named for its tones
  (police WAIL / YELP / PHASER, fire WAIL / YELP / PHASER matching FIRE WAIL ..., EMS WAIL / HI-LO / YELP matching EMS WAIL, HI-LO, EMS YELP: the
  siren module's tone names through `audio_engine/lights-label`; the third = the horn key's tone), CODE 2 / D's dot in the bar's second colour
  (blue, fire yellow, medical white). A becomes A2 (its palette `A2`, a metatable over `A`, + the panel), D shows LIGHTS (dot red/blue with the car's sides) / SIREN in its centre panel (other cars: the panel shrinks to just round the fuel),
  A5 CODE 2 / CODE 3 and WAIL / YELP / PHASER buttons (LED strip, flashing with the lights) under its LCD; elsewhere the light mode stays in the status line.
  Every cluster has a check-engine lamp (the user added it to the design): lit while the engine isn't running (off / starting), `engine` in the cluster-lights hook.
  New clusters' dial numbers are ~3 px over the design's (as A's). A2's panel: WAIL / YELP / PHASER lit by the
  `audio_engine/lights-label` hook's answer (the siren module returns the playing tone, PHASER while the horn plays its honk tone),
  CODE 2 / CODE 3 from NW2 `audio_lights`, the bar's LEDs flashing like the design. Dials scale per car (tach to redline + 500, red
  from redline; speedo from `config.topSpeed` x 1.1). Roboto Condensed (ships with the game) for the design's Barlow / Chakra Petch.
  Indicators, hazards and headlights are lamps on the cluster only, nothing on the car (the user's: "ready to be implemented into
  PERP"): left click = left indicator, right click = right, both within 0.15 s = hazards, F = headlights, Space = handbrake lamp.
  PERP's own vehicle methods win where they exist (IsIndicating / GetIndicatorDirection true = left / HasHazardLights /
  GetHeadlights / GetFuel 0..10000, low under 1000 / IsHandBraking;
  the indicators tick (the user: only for the driver and passengers): the driver's client sends its indicator mode on a change (net
  `audio_engine_indicator`, sv_engine: NW2 `audio_indicator` 0 off / 1 left / 2 right / 3 hazards, `audio_indicator_at` = when it
  went on, the flash starts lit then for everyone), every rider (`AudioEngine.RiddenCar`) plays a generated clock-like "tic" as the lamps
  come on and a lower "toc" as they go off (the user's pick of four takes; ringing tones + a thump were funny, filtered noise + contact bounces too clicky, dull and sharp), 2D on the listener (CreateSound on LocalPlayer, level 0), `audio_engine_indicator_volume`
  0.5; cars with PERP's own indicator methods keep PERP's tick; rebuilt on PostCleanupMap / `audio_engine/restart-sounds`. Not yet heard in game; `vehicle.indicatorOn` = PERP's flash phase, read from PERP's
  cached client Lua), and the `audio_engine/cluster-lights` hook (vehicle, lights { left, right, hazards, headlights, fuel 0..1,
  handbrake, engine }) can fill them in. No PERP: fuel shows full. Lamps just light up (the user: no circles round them); only the indicators keep a soft glow disc (`indicatorGlow`). A's dial numbers are 25/25/21 design px (the user: the design's 19/18/16 were small); A2's panel is buttons only (the user took the siren icon and LED strip off): WAIL / YELP / PHASER 80 x 30, CODE 2 / CODE 3 100 x 30, 16 px plain text (the design's 10 px with a blurred glow came out smeared); PHASER red like CODE 3; the active CODE button flashes with the car's own lights (`AudioEngine.PoliceSideLit(vehicle, side)` in cl_police, its isLit timing, either side), dim between flashes;
  on the classic CODE 3 blinks once a second instead (`CODE3_BUTTON_BLINK` 1 s, lit the first half, on `AudioEngine.LightPhaseTime`; the quick flashes flickered it, then 0.5 s was still too fast, the user); text drawn on whole pixels. Needles move like a stepper-motor gauge (`stepGauge`; the user: jittery on the speed limiter, then "should move robotically and not sway"): the value filtered (`SPEED_GAUGE` 0.25 s / `RPM_GAUGE` 0.15 s), the needle holds until that is `band` away (0.8 mph-or-km/h / 120 rpm), then travels to it eased at slowest..fastest per s and stops; digits show the needle (rpm in 50s). Offline: a cruise wobbling +-1 mph / +-150 rpm moves the needles ~0-2% of frames; pulling 10 mph/s the needle trails ~3.5 mph; a 6500 -> 4000 gear change lands in ~0.7 s. The speed needle no longer steps (the user: clunky, moved in steps, fast cars fluctuated a lot): its speed is the server's physics (`AudioEngine.ServerSpeed`, the driver's drive state, cl_handling), else a least squares line through the last `SPEED_FIT_SECONDS` 0.3 s of positions on CurTime (`fittedSpeed`: single player, listen host, prediction off; the frame-to-frame position speed jittered more the faster the car); the needle follows smoothly over `SPEED_NEEDLE_TIME` 0.15 s, the digits move once it is `SPEED_DIGIT_HOLD` 0.6 past them. The rpm needle (A, A2) keeps `stepGauge`, but once caught up it follows while the revs keep moving one way faster than `drift` 40 rpm/s (rate over `rateTime` 0.3 s; the user: at top speed it went up in steps; offline a 50 rpm/s climb is followed within the band, a +-150 rpm cruise wobble and limiter bounce still hold it); B's rev bar, C's LED segments, D's lit arcs and A4's blocks follow `smoothRpmValue` (`RPM_SMOOTH_TIME` 0.05 s, digits held `RPM_DIGIT_HOLD` 75 rpm; `CLUSTERS[id].smoothRevs`): with the stepper value they moved in steps (the user: A fine, the other two buggy). Not yet seen in game. Engine-off prompt and (unless the cluster shows the police controls) the light mode sit above it.
  Speed limiter on every cluster (the design's, `Limiter` in cl_hud): a "LIM 70" badge (limit in the HUD's units) where the design puts it, outlined
  in the cluster's dim colours, filled amber with dark text once the car is held at it (within `Limiter.REACHED_MPH` 1 mph, or `audio_limst` 2);
  round speed dials (A/A2, D, A5, A3, D2) and D3's speed scale also get a 4 px mark at the limit (dimmed until held at it). D3 has a "Limiter"
  status row instead of a badge, and its Fuel row carries a level bar along its foot (the design's latest). The old "LIMIT n mph" text above the cluster is gone.
  Offline render check (mocked GMod -> SVG -> headless Chrome) lives in the scratchpad, not the repo.
- `sv_engine.lua`: ignition, run by the server.
  - Engine off on entry; start key `audio_engine_startkey` (default R; polled by cl_engine, which sends `audio_engine_toggle`: the server's
    PlayerButtonDown rides on usercmds and missed presses). A press within 1.5 s of starting can't switch it off (`START_LOCK`: at 150 ms ping a second press did). Getting out leaves it
    idling (`audio_engine_keeprunning` 1, default, not archived: a saved 0 from the old default overrode it); getting back in drives off.
  - The server runs `Drivetrain.StartSequence` and keeps `EnableEngine(false)` until the start-up reaches idle.
  - Parking brake (`updateParkBrake`, NW2 `audio_parkbrake`, default on = Source's driverless handbrake): getting out with the engine
    on, it's on if Space is held as you get out, else off; engine off (or starting) in the car, Space toggles it (switching the engine
    off: on if Space is held then), getting out keeps it. Off = neutral, the car rolls (woken on exit; a released one is released
    again every Think while driverless). Engine off it's set on Source's controls every Think (+ throttle 0); driving, Space is
    Source's handbrake and the latch is off. The cluster's handbrake lamp shows it while the engine isn't running.
    Released = SetHandbrake(false) + ReleaseHandbrake() (Source holds a driverless jeep's handbrake on: getting out with it off,
    the car stayed braked, the user), also the tick after getting out. A car nobody has set it on gets it off on being got into
    (it was on: getting in and out of a parked car untouched put it on; the user's rule: only on if switched on, or Space held
    getting out with the engine on).
    Engine off, Source doesn't steer: sv_handling's tick puts the model's steering (`state.steer`) on with `SetSteering(-steer, 0)`.
    The user's design; not yet run in game (whether Source re-applies a driverless handbrake by itself is unknown).
  - Also: `audio_engine_autostart`, input bits NW2, `ApplyPerformance` (accel/top speed), the tuning net message.
- `sv_cruise.lua`: speed limiter (was cruise control). Middle mouse on at exactly the current speed / off; mouse wheel moves the
  limit to the next 5 mph step (`StartCommand`: `cmd:GetMouseWheel()`). The driver's own W drives: from `band` 6 mph under the limit
  the horsepower is trimmed (`vehicle.audioLimiterPower`, sv_cruise's `powerTrim`, applied in `ApplyPerformance` on a 0.02 change) by tracking a wanted acceleration
  `k` x (mph to go), which finds the holding power for any car (a PI on the speed error overshot 1-2 mph). Over the limit (lowered,
  downhill): power off and a braking impulse from 0.6 mph over until 0.15 (0.6 + 0.7/mph, max 3.5 m/s2: 60 to 40 mph in ~2.5 s).
  Exit/engine off cancel. NW2 `audio_cruise` (limit, mph) for the HUD ("LIMIT"), `audio_limst` 0 free / 1 holding (sounds like
  steady part throttle, `inp.cruise`) / 2 over (throttle shut). `audio_engine_cruise`.
- Handling (the user scrapped the old assists, sv_stability / anti-spin / traction control / lock at speed, for this): every car's motion
  is the server's alone (Source's jeep: engine, brakes, suspension, all collisions), so crashes between players agree; the driver's
  client only draws ahead of it. The average PERP player has 150 ms ping: a key showed ~0.25 s late (half ping up, half down, cl_interp 0.1).
  - `sh_handling.lua` (`AudioEngine.Handling`): the model, plain Lua on numbers (no Vector/Angle: no allocations, and it runs offline).
    Bodies { px.. position, vx.. velocity (in/s), ax.. model x axis, bx.. y (left), cx.. z (up), yawRate (deg/s, left +), groundShare,
    controlShare }. `Control` per tick: keyboard steering ramps (`steerRate` 7 / `steerReturn` 8 / `steerReverse` 9 per s; were 4.5 / 6), the yaw rate
    follows a bicycle-model target (on grip: the target eased at `yawFollow` 12/s (was 8: ~0.5 s to the full turn) and the car put on it every tick, `state.yawTarget`, sent to the
    driver; closing 12% of the gap a tick, Source's tyres held it well short: "barely turns" at 40-70 mph; not yet run in game; handbrake/drift:
    drawn at their follow rates) (lock `lockSlow` 32 -> `lockFast` 5 deg by `lockFadeSpeed` 40 m/s (was 30: the lock, not the tyres, capped the turn at 40-60 mph, the user found cars stiff there; full lock now 86 deg/s at 40, 74 at 50, 65 at 60 mph on a 3.4 m wheelbase, was 68 / 60 / 49; measured in game at the old values: set = measured), wheelbase from the
    attachments, `AudioEngine.CarGeometry`, moved here from sv_stability) capped at `grip` x g / speed, and sideways speed goes at up to
    `grip` g towards a rolling car's (the rear axle along its wheels: the middle moves into the turn at wheelbase/2 x yaw rate; slip
    angles are the rear axle's): held at 0 it set the rear tyres across their path, Source's tyres fought the model and W-held turns bled
    speed, as the old sv_stability's turn-in help / side grip did (both were off there for it); 0 in a handbrake slide or drift.
    The car's speed is never raised (no launching). Handbrake (Space, forward): grip x0.35, rotation x1.6,
    follow 2/s; over `driftMinSpeed` 7 m/s starts a drift that lasts while the slip angle > `driftHold` 10 (grip x0.6, follow 2.5);
    past `spinAngle` 70 it's caught. Under `minSpeed` 1.5 m/s (+ `fadeSpeed` 3) Source alone. `AudioEngine.HANDLING` (debug-tunable, also
    sent to clients: Global2 `audio_dbg_handling`), per car `AudioEngine.CAR_HANDLING[name]` (sh_carlist: CAR_EMOTION grip 1.3, ECONOMY 1.05,
    others 1.15; CAR_EMOTION also `downforce` 0.5: grip x (1 + downforce x (speed / `downforceSpeed` 50 m/s)^2, capped at 1),
    `Handling.GripAt`, the user asked fast cars to turn more at speed: 15 -> 22 deg/s at 50 m/s); every car: `cornerGrip` 0.5 (x grip on the keys' turn, not slides: `Handling.SlideGripAt`), all of it to
    `cornerGripFrom` 11 m/s, none from `cornerGripTo` 36 (smoothstep): the turn went from the lock's to grip's at ~20 mph and the circle doubled
    by 30 (the user: "instantly stiff at 25 mph"); full lock now 85 deg/s at 25 mph easing to 51 at 40, 28 at 60, unchanged from 80. `sideHold`
    1.15: sideways held that much over the turn (it's held on its target every tick, so at the limit it drifted wide). Source's DegreesFast
    is now fitted to the model's turn at FastCarSpeed x1.1 + 0.5 (at most DegreesSlow; was at most the script's DegreesFast).
    `turnFloor` (every car 53, AudioEngine.HANDLING: per car it left lower tiers turning badly at 50 mph, the user: the turn shouldn't follow
    a car's class; `Handling.TurnLimit`): the full-lock turn at least turnFloor deg/s at `turnFloorSpeed` 36 m/s,
    x (that / speed)^`turnFloorPower` 0.7 elsewhere (0.5 left 50-60 mph short) (the user: the SLR should do a tight 180 at 80 mph; tyres alone gave 26 deg/s, a 180 in 7 s;
    now 3.9 s, 2.8 at 40 mph), the sideways grip raised to cover it. Control also returns `forwardChange` (4th): the sideways change only
    turns the velocity, the speed is kept (pushed along the right alone, a held turn gained speed: offline the SLR circling from 20 mph
    reached 60 in 10 s), read through `Handling.SettingsFor` (HANDLING is the same table over a Lua refresh, set to the file's values on every load, the debug
    module putting tuned values back on top: it follows `AudioEngine.HANDLING_DEFAULTS`; it kept its own copy from its first load and put every
    value back to it on each refresh, so a changed default never reached a running server, the SRT-8's turn floor; CAR_HANDLING is built anew
    on every load; a live proxy: the car's CAR_HANDLING entry, then HANDLING, read on every access; it copied the
    entry once, so cars spawned before a Lua refresh kept old values: the SLR's turn floor never arrived). Also: `Integrate` (prediction: gravity along the ground, on its wheels no speed along the car's up carried on (a bump's kick drew the car
    bobbing over rough ground; other cars' lead too, cl_handling),
    learned acceleration along the nose, rotation about up; velocity not turned), the learner (`NewLearner`/`Learn`/`LearnedAcceleration`:
    per `DriveMode` (coast, throttle, brake, reverse, handbrake, limited, idle) x 2.5 m/s bins, starts from power to weight `audio_pwr` and
    `audio_vmax`), `Predict` (replay: integrate then control, the server's order), the smoother (`SmootherAbsorb`: a correction kept as
    offset + small rotation, `SmootherDecay` time constant, `SmootherApply`). Buttons are a number (1 W, 2 S, 4 A, 8 D, 16 Space; no bit lib).
    `audio_engine_drivemodel` (replicated, archived, default 1) is created here.
  - `sv_handling.lua`: on spawn `AudioEngine.PrepareHandling` (before `captureBase`): PERP base physics from generated `sv_perp_physics.lua` onto
    cars on `test_car.txt` (as ratios to test_car's values: keep the `TEST` table in step with the file), nothing else changed except, where
    the model runs (`steerForModel`, also in RebaseHandling; the drivemodel convar's change rebases every car), Source's steering: turnThrottleReduce 0
    and degreesFast = the model's grip-capped turn at `STEER_FIT_SPEED` = FastCarSpeed 35 mph (`Handling.TurnAngle`, ~7.5 deg; PERP ~11; fitted at 25 m/s, ~3 deg, Source held 3 deg from 35 mph where the model asks ~7 and cars under throttle hardly turned): both braked cars in a turn
    (throttle cut up to 90%, front tyres scrubbing across the path). Source's steering rates are the model's too (`steeringRate*` = steerRate,
    `steeringRestRate*` = steerReturn, brake/throttle/boost factors 1): at a script's ~2-3/s its wheels were still turned ~0.3 s
    after letting go and kept rotating the car between ticks, which the replay can't know (drawn car short in turns, snapping
    round on release, the user; test_prediction `SOURCE_STEER=script SOURCE_PULL=20` shows it: 6.2 / 5.6 deg held / released,
    1.8 / 2.4 matched). Other cars' wheels (Source's pose) now reach full lock in ~0.14 s. `audioScriptParams` stays the script's own; adds the
    PhysicsCollide callback (`audioImpactAt` on a velocity change over `impactSpeed` 120 in/s, not floor/ceiling normals: the model is off
    `impactHold` 0.35 s, eases back over `impactEase` 0.5). Tick: on driven cars (`AudioEngine.DrivenVehicles`, kept by sv_engine's
    Think; sv_engine's OnEntityCreated only times jeeps), reads the physics, ground share from `GetWheelContactPoint`
    (trace fallback), runs Control and applies it (`AddAngleVelocity` local z, `AddVelocity` along the right; tried and reverted for the Furai
    climbing walls: a wall check leaving pushes into walls out (scraping a wall should still slow the car) and the push laid flat (it
    didn't help, and measured along the car's right but pushed flat, on cambered roads it never converged and dragged the car, a Mini
    struggled up a forest hill).
    Control's `forwardChange` only takes speed off (a held turn gains none), never adds it: keeping the speed both ways turned a slide's
    (a wall's) velocity back along the nose at full speed, and scraping a wall the car kept its speed and climbed it. Obstructed
    (`blockedYaw` 15 + `blockedShare` 0.5 x the turn under what was set last tick, `state.yawSet`): `blockedTime` 0.3 s of the gentle
    yawFollow pull instead of the every-tick hold, only while touching something (`body.touching`: a side PhysicsCollide, any speed, within
    `contactHold` 0.5 s, `vehicle.audioContactAt`; without it Source's own tyres taking the rotation back tripped it and cars turned much
    less, the user's "used to turn a lot better"; not yet run in game); controlShare 0 on spiked cars,
    `carConfig.stability == false`, or with the convar off. Every ~30 ms (every other tick at 66) an unreliable net `audio_engine_drive` to the
    driver (only one whose client predicts: not single player / the listen host / userinfo `audio_engine_predict` 0): entity, the command clock (`Handling.CommandClock`:
    one command a tick, drawn to the last command number from `StartCommand`; whole + 1/256ths. GMod's default cl_cmdrate 30 gives the
    server two commands a packet at 66 tick while physics steps once a tick, so the raw number jumped 2 / 0 and the replay was a tick
    long / short by turns; test_prediction `150 2`: per-frame jumps 0.10 -> 0.05 m), CurTime as a double (a float is ~0.06 s coarse after days), pos, angles,
    velocity, yaw rate, steer, drift, drivable, impact, ground/control share, buttons, limiter state, model on, impact age (the replay
    eases controlShare back with `Handling.ImpactShare` as the server will; it kept the base's), blockedFor (the replay carries on a wall's
    gentle follow) (~65 bytes). `AudioEngine.SetParams` checks the speed unit once (`speedsInMph`), not on every re-send. No vehicle params set while
    driving, except Source's wheels over FastCarSpeed (`matchSteering`, `AudioEngine.MatchedSteering`): the params get DegreesFast = the model's
    turn x1.1 + 0.5 deg at the car's speed and FastCarSpeed = that speed (`vehicle.audioSteerOverride`, put on by `AudioEngine.SetParams`,
    re-sent through ApplyPerformance every 2 mph / 0.2 deg; off under FastCarSpeed, getting out, model off). Source holds DegreesFast (~8)
    over 35 mph, where the model's turn shrinks (~1.2 deg at 112 mph): the front tyres braked fast cars in turns (the user, after downforce).
    The steering params' speeds are mph (Source compares them with the speed in mph). `SetSteeringDegrees` was tried first: it sets
    DegreesSlow too, and Source draws the wheels' turn as a share of DegreesSlow (full lock shown at any speed; the user: the wheels
    turned way too much, slow cars couldn't turn). Simulated on all 175 scripts: under FastCarSpeed identical, over it never under the
    model, excess over it at most 1.2 deg (3 between updates; was up to 17). Not yet run in game. Known, old: scripts with DegreesSlow
    under the model's lockSlow 32 (1970 Challenger 26, Carrera GT 28, ...) steer a few degrees under the model at parking speeds. `AudioEngine.RebaseHandling(veh[, params])` rebuilds `vehicle.audioBase` from `vehicle.audioScriptParams`, refreshes NW2
    `audio_vmax`/`audio_pwr` (`AudioEngine.RefreshCarStats`, sv_engine) and re-applies performance. `audio_engine_accel_log`, `audio_engine_handling_info`.
  - `cl_handling.lua`: the driver's prediction (`audio_engine_predict` 1; off in single player / for a listen host; `audio_engine_predict_amount`
    0..1, default 1, a tester's ask: how far ahead it draws your car, a blend from Source's pose, the other cars' lead scaled with it). Client `StartCommand`
    keeps each command's buttons by number (skip number 0, it happens); each frame, from the newest state, `Predict` through the commands
    after its number (at most `maxCommands` 32) + the fraction of the next; without matching numbers, one ping of the keys held. A new state's
    jump goes into the smoother (`smoothTime` 0.1 s, 0.04 during an impact, snap over 250 in). `clearShare`: a hull trace from the server's car
    to the shown one at its leading end (world and props, not cars or players) stops it at a wall. An end already in something
    (`StartSolid`: the server's car nose against a wall) was taken as clear and the car drawn up to a lead deep into the wall: now swept
    from the car's middle (`endClearShare`). Travel mostly sideways (|travel . nose| < `SIDEWAYS_SHARE` 0.7): both ends traced. Other cars
    (`carStop`, after `updateOthers` now): your drawn car stops at their drawn footprints (2D boxes, `carShrink` 0.9 of the bounds, heights
    checked; parked ones where Source has them), cars already overlapped at the server's pose left out; it drove through a car it pushed
    or a parked one by the lead. The learner only learns on a straight run on the same keys (|steer| <= 0.15, no drift, buttons/limiter
    unchanged): turns' scrub was learned as weak throttle. A hit facing up like ground (normal within ~45 deg of the car's up,
    `groundNormal` 0.7) isn't one: traced again `traceRetryLift` 24 in higher (uneven ground pulled the drawn car and camera back by the lead
    and let go the next frame: the camera zoomed in and out for clients, the user). Drawing (poses worked out at CalcView with nothing moved, put on at PreDrawOpaqueRenderables, taken off at PostRender: the render origin moves bones and attachments, and left on, the game's eye-attachment view arrived already moved and the camera ran ~2x the lead ahead, out of sight and shaking, the first multiplayer test): `SetRenderOrigin` + the Entity
    `SetRenderAngles` (Player's is something else) + `InvalidateBoneCache` on the car and its children (pods, lightbar), render bounds widened
    by the offset (culling goes by Source's position: your car vanished otherwise), players in it via PrePlayerDraw; stale overrides cleared.
    `AudioEngine.DisplayPose(entity)` (cl_police's lightbar lenses and lights use it).
    Your car's `vehicle_steer` pose (wheels, steering wheel) is the predicted steering x Source's wheel share at that speed
    (learned per 5 m/s band), moving at `WHEEL_RATE` 3/s (a script's usual rate): at the model's steerRate 7 the wheels snapped
    to full lock (the user). Not yet seen in game.
    The replay's length comes from the client's command clock (`Handling.ClientClockSeen/ClientClockNow`: command numbers run at one
    a tick in real time; the upper envelope of number - time / tick, sinking 0.2 a second), not from the newest command + the time
    since its frame: commands are made at a frame's start, so at 50 fps the drawn car moved 1 tick one frame and 2 the next (camera
    stutter, the user; test_prediction `TICK=22 FPS=50`: frame-to-frame speed unevenness 22% -> 2.5%, `OLDCLOCK=1|client|server` for the old ways).
    Other cars' lead = yours + (how much later than yours Source draws them): `drawnLag`, GetNetworkOrigin - GetPos along the velocity,
    smoothed 1 s (the user: at 100 mph a car length behind); the debug readout shows both.
    The replay has a world (`Handling.Predict`'s last argument, `ownWorld` in cl_handling: `world.move` after each step's motion):
    the road (`Handling.RoadResponse`: put on it at the clearance of the replay's own starting state (`ownWorld.begin`, within
    12 in of `own.clearance`, learned from the states), pitched along it, no speed into it; it flies only where the road drops
    more than `TAKEOFF_GAP` 2 in in a step, and lands on it. With the learned clearance and "faster than gravity" (~0.1 in a step)
    a fast corner's body bounce counted as flying: no grip, steering or throttle, the drawn car slowed and ran wide in corners,
    the camera snapped (the user); test_prediction `BOUNCE` (default 1 in) catches it: heading worst 8.4 -> 3.8 deg. A car
    flying off a smooth crest shows as flying once the server's state says so) and walls (`Handling.WallResponse`, `stopEnd`:
    a box 95% of the car's width at the leading end, both ends going sideways, swept from the end's place before the step
    (position and nose: turning swings it) at any speed; an end already in a wall (the server's car flush against it: the box
    starts solid, which counted as clear, the car went half into walls pushing slowly, the user) finds the wall from the car's
    middle and keeps no motion into it; speed into it off with a 0.1 bounce, 0.3 scrub, a hit over impactSpeed lets go of the
    model for the rest of the replay); up to 2 hull + 2 line traces a step, your car only. It ran through everything and was cut short afterwards along the line from the server's car, changing frame to frame:
    into walls then a snap, stopping short, shaking against them, pinned to the road over crests the server's car flew off (the user).
    test_prediction has a dip and a crest (`WORLD=0` for none): height off the server's 0.90 m -> 0.05 m.
    The nearest `GROUND_CARS` 6 moved other cars still get `followGround` (their axles put as high over the road as Source has them).
    The camera (third person: further than the car's half length from its middle) takes the same corrections over
    `cameraSmoothTime` 0.6 s, the car over `smoothTime` 0.1 (`own.cameraSmoother`, `own.cameraEntry` used by calcView): it moved
    rigidly with the car, so every correction moved the view, twitchy at higher ping (the user); test_prediction's "corrections
    moving the camera" at 300 ms: 3.4 -> 2.3 m/s 95th percentile (`OLDCAMERA=1` for the old way). The worst left are handbrake slides.
    Around a collision (a wall met in the replay, `replayHitWall`, or the server's impact) the camera takes the car's 0.1 s
    instead (eased in over 0.12 s, held 0.4 s, out over 0.6 s), and it never trails the car by over `CAMERA_LAG_MAX` 30 in /
    0.1 rad: on/off with the impact flag it stayed at the spot of the crash, then lurched (the user). Not yet run in game.
    The stop at other cars (carStop) eases: the share of the way let go closes over `CAR_STOP_CLOSE` 0.03 s, opens over 0.25 s.
    Shadows: the placements (and riders' render origins) go on at the end of calcView with MarkShadowAsDirty, not at
    PreDrawOpaqueRenderables (shadows are drawn before it: they stayed where Source has the car, the user). Sound: after the frame
    your car's position is moved to where it was drawn for the sound update (`audio_engine_predict_sound` 1), put back on Think /
    the next update / cl_engine's Think (`AudioEngine.PredictSoundBack`) unless the game set it since; other cars' sounds stay at
    Source's (the siren's and horn's Doppler sample positions). Not yet run in game.
    Drawn less leaning (drawing only, the user's: not the handling): cars in `AudioEngine.CAR_LEAN_LEVEL[name]` (sh_carlist, share of the
    lean taken out; the Defender 0.6, not yet seen in game: SpringConstant 10, no anti-roll bar, it leaned right over under the model's
    cornering and its inside wheels hung off the road) within 4000 in: 4 traces down from the body's corners (its OBB, 80% out, 24 in
    over its bottom; not the wheel attachments: they ride on the wheel bones, read before the car is drawn they can be one point) to the
    road each frame, each side's height over it (`audio_engine_lean_info` prints what it measures; `audio_engine_lean_set <0..1>` tries a share on the car you sit in, this client only, until a reload; works in game, the user), turned about the lower side's wheels on the road (`levelCar`, after the prediction, smoothed 0.08 s);
    the camera follows the car you sit in when it's drawn moved (`cameraCar`).
    Third-person vehicle camera is ours (`thirdPersonOrigin`, in calcView; lost in the 11-20 rollback, back since): it orbits the car's
    middle as the camera has it (`own.cameraEntry`, else as drawn; `CAMERA_RISE` 0.35 of its height up), not the driver's eyes (the user's),
    at `CAMERA_DISTANCE` 0.7 x the car's render bounds diagonal (the user's; 1.7 was too far), looking as turned with the drawn car
    (the player's own look direction follows Source's car a ping late: the car swung left/right in the frame), hull-traced off walls:
    pulled in at once, back out over `CAMERA_REACH_RETURN` 0.25 s. No mouse-wheel zoom (base `GM:VehicleMove` still sets the camera distance, ignored; the wheel is the
    speed limiter's). The base camera's distance follows the render bounds, which widenBounds pads while a car is drawn moved: the lean
    correction coming and going made the camera jump in and out (the user's "flickers"). The camera: `hook.Call` is wrapped for "CalcView" only
    (re-wrapped every 2 s if a hook library replaced it; every wrapper we made is in `AudioEngine.predictHookCalls`, they call the newest
    `AudioEngine.PredictCalcView`, and inside one CalcView (`AudioEngine.predictInCalcView`) the next of ours passes it on: nested wrappers
    moved the camera twice; `updateFrame` runs in a pcall), so any gamemode/addon camera is moved with the car; if the camera didn't run through
    it in a frame, nothing is moved (PreDrawOpaqueRenderables). Others (`audio_engine_predict_others` 1): the nearest 16 moving cars within
    5000 in are carried on over the lead (their smoothed velocity and yaw rate from interpolated poses, along the arc, wall-traced): without
    it your car (drawn ~RTT + interp ahead) drove into ones you only followed. The lead: found by matching Source's interpolated car to the
    received states' path (the server time it shows) against the predicted one's, smoothed; until then ping + interp. `audio_engine_predict_debug`
    (red server / yellow Source / green shown boxes), `audio_engine_predict_stats`. Not yet run in game: the hook.Call path for CalcView,
    SetRenderOrigin on players in seats, shadows following the render origin and StartCommand's client command numbers in a vehicle are
    the things to check first. Own car's engine sound stays at Source's position (a few metres behind the camera at speed).
  - `dev/baker/test_prediction.js [ping] [commands a packet]` (2 = cl_cmdrate 30; `NOCLOCK=1`: the raw command number): a "Source" server the client doesn't know (own engine, brakes, tyres, lock, bumps), 150 ms with
    jitter and 3% loss, 144 fps: predicted ~0.2 m off where the server will be vs ~6 m plain, steering shows ~250 ms sooner, corrections
    under 7 cm a frame, an unpredicted crash back within 0.5 m ~80 ms after its state arrives.
  - Speed limiter (`sv_cruise`) still trims horsepower through `ApplyPerformance`, nothing else does now.
- The server also has its own `sl65amg_cop.txt` (fixed copy given to the user separately).

## SL65 AMG RTU (separate addon, temporary)
`addons/sl65amg_rtu/`: the original example police car, its own GMod addon (copied into garrysmod/addons/ next to this one; GMod doesn't load
addons nested in an addon), not part of the final addon: delete the folder to drop it. Holds the model/materials (`models/plpd`, `materials/plpd`),
its handling `scripts/vehicles/plpd/sl65amg_rtu.txt`, the spawn entries (Vehicles > Police, skins 0-2) and `lua/sl65amg_rtu/sh_car.lua`: its
`AudioEngine.RegisterCar("models/plpd/sl65amg_rtu.mdl", ...)` (shift points, stability, wheel radius; plain Lua), included by its autorun file
once `AUDIO_ENGINE.RegisterCar` exists (autorun goes in name order, else at Initialize), which also gives it the trumpet horn in `CAR_HORN.CONFIG.models`.
The core never names it. The dev harnesses still use it as their test car: they dofile sh_car.lua after sh_config (dev/build.py inlines it too).
`dev/baker/check_syntax.js` also compiles `addons/*/lua`.

## Police lightbar (in this addon)
The light bar's files are part of this addon (`models/`, `materials/`; the user: no separate addon, no install step), mounted with it:
`models/perpheads/props/police_lightbar_leds.mdl`, `materials/police_lightbar/` (lens / flash VMTs, `leds_large` / `leds_small` VTFs) and
`materials/models/jarheads/props/police_lightbar/` (the repaintable copies). Tools: `dev/police_lightbar/` (README there).
- The rebuild `models/perpheads/props/police_lightbar_leds.mdl`: PERP's bar (workshop 2897742669) body only, every LED lens on its own
  material `materials/police_lightbar/lens_<face>_<side>_<inner|outer>` / `lens_front_centre` / `lens_corner_<side>_<front|side|rear>`
  (15; only the front face has a centre lens), so each lens can be lit by itself. In the original all lenses shared 2 materials (`LEDs` /
  `LEDs2`) and every lens quad mapped the whole texture (UV 0..1): no texture could light them separately. Made by our own decompiler
  (`dev/police_lightbar/`, README there; no Crowbar): SMD = the mesh as stored, which studiomdl's `$staticprop` turns +90: model = mesh (x, y) ->
  (-y, x), front +Y like the cars. The first build was turned -90 (as the original seemed to be drawn: its message board at the rear) and
  sat back to front on the cars in game (the user), so PERP's original bar (the fallback) may sit back to front too; wound for studiomdl; checked against the original's mesh turned +90 (`verify.py`): all 608 triangles in place,
  same winding, same uvs, every lens within 0.5 of sh_police's module table (written in model space now). Left out (unused by us): screen bodygroups, 11 message skins, the screen bone, screenflip.
  `AudioEngine.LIGHTBAR_MODEL` = it when `util.IsValidModel`, else the original (`LIGHTBAR_ORIGINAL_MODEL`).
- The lenses light themselves, in VMTs (the user: not Lua; a Lua material proxy was tried first): `materials/police_lightbar/leds_large.vtf`
  (faces) / `leds_small.vtf` (corners) have 5 frames (0 unlit, 1 red, 2 white, 3 blue, 4 yellow; the user's PNGs, `dev/police_lightbar/make_vtf.py`),
  lit frames' alpha = the `$selfillum` mask. The model's 13 skins (`$texturegroup`, `make_vmts.py`): 0 unlit, then police / fire / medical x
  CODE 2 / CODE 3 x phase 0 / 1, each lens on a `flash_<size>_<colour>_<code>_<a|b|c>` VMT whose Source proxies (CurrentTime, Add, WrapMinMax,
  LessOrEqual) run its pattern into `$frame`. The server sets the skin with the mode: `AudioEngine.SetLights(vehicle, mode)` (sv_police; every
  `audio_lights` change goes through it), `AudioEngine.LightbarSkin` (sh_police). Phase = EntIndex % 2, half a period later
  (`AudioEngine.LightPhaseTime`, which cl_police's drawn lights, glow and the HUD's `PoliceSideLit` use too): neighbours alternate. It was 4
  offsets of 0.37 s, but studiomdl caps a model at 64 materials (4 needed 121; 2 = a/b swapped, 51). `check_vmts.py` simulates the proxies
  against cl_police's `isLit`: 0 differences. Nothing is drawn over this bar.
- Copies of the bar's 6 VTFs at their original path `materials/models/jarheads/props/police_lightbar/` (housing, housing_nrm, housing_exp,
  led_small, led_large, plastic) for the user to repaint: they replace the workshop's by path (the lens VMTs use led_small / led_large).
  Not yet confirmed in game that the addon's copy wins over the workshop item's.
- Players need this addon's content (workshop) to see any of it; without the model the cars get PERP's original bar, unlit.

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
Tone sets (the user's): police cycle wail, yelp; EMS emswail, hilo; fire firewail, fireyelp. Horn override (`honkTone`, top
level for police and per scheme): police phaser, EMS emsyelp, fire firephaser. While a siren tone sounds, the car horn's key
(Alt) plays the honkTone instead of the horn, back to the siren tone on letting go; lights alone (no tone) = the horn.
`PoliceSiren.HonkTone(vehicle)` (sh_siren) answers the horn module's `car_horn/replace` hook (shared: the server then doesn't
charge that honk against the spam limit); cl_siren reads the key from the horn's NW2 `horn_on` / `horn_presses`
(`PoliceSiren.HORN_NW` / `HORN_PRESSES_NW`, a press = at least `HONK_MIN_OVERRIDE` 0.15 s) and, for your own car, the horn's
`car_horn/held` hook (no wait for the server). The honk tone is built as soon as the siren sounds; until then the siren tone
keeps playing. startTone cuts a fading patch of the same name on the car first (same entity + name = one sound to the game).
The siren studio plays it too (hold Alt with the lights on) and exports `honkTone` (scheme lines too).
In a siren car the spawn menu (Q) is blocked (`SpawnMenuOpen`), and the tone shows after the light mode on the engine's HUD through
the engine's generic `audio_engine/lights-label` hook (cl_hud; the engine still never names the siren).
- `sh_siren_config.lua`: `PoliceSiren.CONFIG`, written by the studio's export (the user pastes it back): volume, soundLevel (85, the engines' own: it was 88 = 85 + 3, the user lowered it, sirens carried too far) and
  `soundLevels[model]` (the user's: Cayenne 89, SL65 92; the 340i, M5 E60 and Charger SRT-8 were 94, then the base (88, now 85)
  (the user found the sirens carried a bit far); 95 was a touch far, 94 for all carried too far on the others, 86 lost to the SL65's engine), `distance` { full 20 m, at 150 m, volume 0.4 }: the siren's own fade on top of the game's (the user: "you can't really tell the
  distance"; the game keeps 85 dB at full volume ~16 m then 1/distance, and a near-pure tone gives no other cue; a muffled far
  version was ruled out: little change on a pure tone, and two copies cross-faded would partly cancel), even in dB over log
  distance, none inside; cl_siren `distanceGain`, sent when it moves over 0.005, glided 0.1 s; the studio's Drive past uses it,
  doppler (1 = real), attack/release (release 0.08: an electronic siren cuts off; 0.5 s with stopPitch 0.7, a motor wind-down, sounded wonky), stopPitch (pitch drop on fade-out, 1 = none), pitch,
  sampleRate, `lightTones` { CODE 2, CODE 3 }, `cycle`, `schemes[name]` { lightTones, cycle } (fire, medical; the studio keeps them
  through its export but plays the police rules), `cabin` { volume, muffle Hz }, `keys` { tone }, `tones[id]` (pattern of
  points { f, glide, hold, curve }, logGlide, harmonics, voice2, vibrato, tremolo, speaker). Must stay plain Lua (the studio runs it).
- `cl_siren_synth.lua`: plain Lua, game and studio. Glide shape `Synth.GlideShape`: curve < 1 eases out (1 - (1 - p)^(1/curve)),
  > 1 is p^curve. It was p^curve for both: the wail's 0.25 spin-up leapt 1.8 semitones in its first millisecond, a jump at the
  bottom of every cycle the user heard as a bad loop (the seam test can't see a pitch jump: `--test` now also fails a tone whose
  pitch moves over 0.75 semitones in a millisecond anywhere, across the seam too). The studio's pattern drawing mirrors it. Wavetable of the harmonics (bandlimited to the tone's top pitch), second voice,
  highpass -> tanh drive -> resonant peak -> lowpass (+ a 4-pole lowpass at cabin.muffle for the inside version). Seamless loops: each
  voice scaled to whole cycles per loop, vibrato/tremolo whole cycles, rendered twice and the second pass kept, peak 0.95.
- `sh_siren.lua`: `PoliceSiren.SoundingTone(veh)`: the driver's pick (NW2 `siren_tone`, valid while NW2 `siren_at` = the light mode it was
  picked in), else `lightTones[mode]` of the car's scheme (`PoliceSiren.Scheme`). `sv_siren.lua`: `police_siren_tone` (next in the scheme's cycle,
  then off), driver only, lights on. The driver getting out silences it, lights left on (the user): siren_tone "" at the current mode
  (`PlayerLeaveVehicle` on the car itself; passengers' pods have no lightbar), so it stays off back in until the tone key or a new mode.
- `cl_siren.lua`: builds a tone twice (outside / inside) in a coroutine (5 ms/frame; stored as the engine's loops are, one
  pre-roll sample [y_L, y_1 .. y_L] with loopStart 1: the game loops from sample 1, and without it every pass skipped y_1,
  a tick the user heard on the wail) the first time a car near sounds it (a failed one isn't retried); `sound.Generate`
  names carry `PoliceSiren.Serial` (lua refresh); one CSoundPatch per car (fade-in a frame after PlayEx; once a second it's checked with IsPlaying and restarted at full volume if the game dropped it; only the nearest `police_siren_maxcars` (12, 0 = all) sounding cars are heard, others released, back at 2 places inside: with many cars driving, the engines' loops took the channels and a siren, starting at volume 0, stayed silent), swapped in 0.15 s on getting in/out
  (without restarting the loop, the user: a car you sit in, or within `PARTNER_RANGE` ~30 m when its tone starts, plays both versions from
  the same moment, the unheard one at `PARTNER_VOLUME` 0.001 and the same pitch, so the swap is a cross-fade and the tone carries on;
  dropped past `PARTNER_DROP_RANGE` when you're not in it or if the game drops it; a car got into without one still restarts the tone)
  (driver or a seat parented to the car, and the view on the player: watching through a camera = outside, as the engine). Doppler from its own speed sampling (every siren car within `TRACK_MARGIN` 1.2 x the audible range, audio_engine_range at its siren level, tracked while silent too, `velocityTracks`, and a tone starts at its Doppler pitch: started at the plain pitch with an empty track, it swept to the Doppler one as it faded in, a "water drop" each time a passing siren started, the user, 30-car race; positions >= 0.05 s apart, gaps > 0.3 s and teleports
  dropped, smoothed); a siren already sounding when you start or stop hearing it (into / out of the budget, dormancy, first seen)
  fades over `HEARD_FADE` 0.5 s, not the tone's attack / release (the user: a "water drop" per car joining; `lastSoundingTone`),
  a tone switched on or changed keeps `CONFIG.attack`, the listener's too (the view entity or ply:EyePos(): global EyePos() in Think jittered), the pitch eased at 14/s,
  none inside the car. Tones are generated an octave low (rate sr/2) and played at pitch 200: Source pitch is whole percent, and on
  the near-pure tone 1 % Doppler steps were audible; so the pitch stays within 150..255 (-5..+4 semitones). Key `police_siren_tonekey` (q; alt/shift/ctrl = left one),
  `police_siren_volume`, `audio_engine_police_doppler` (0-2, x CONFIG.doppler 0.375: the user rescaled twice so the cvar's 1 is what they liked,
  first half of real (0.5), then that x 0.75; the user
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
- Hooks for other modules (the horn never names them): `car_horn/replace` (vehicle) -> true = something else plays this car's
  honk (the siren's horn override): no horn sound, no charge, horn_on still set so it hears the key; `car_horn/held`
  (vehicle or nil, held), client: your own key the moment it changes.
- Overuse (the user's pick; replicated `car_horn_limit` 1, `CONFIG.limit`): each player has `charge` 8 s of horn, drained
  while sounding + `pressCost` 0.15 s per press, refilled at 0.75 s/s (the user found the first 5 s / 0.3 / 0.25 / resume 1
  "way too much"); under `weakBelow` 0.3 of it the horn weakens to
  `weakVolume` 0.35 x / `weakPitch` 0.94 x (dying battery); run dry it's exhausted at once, croaks `croak` 0.15 s at its
  weakest, then presses are refused until `resume` 0.5 s is back; held over `relaxAfter` 4 s it eases to `relaxVolume` 0.6.
  The rules live in sh_horn.lua (`CarHorn.PressCharge/HoldCharge/ReleaseCharge/ChargeStrength/WeakFactors/RelaxFactor`),
  run by the server (Tick, only while someone honks; NW2 `horn_power` on the car, `horn_charge`/`horn_charge_at`/
  `horn_exhausted` on the player) and by the driver's client to predict their own horn. The studio mirrors them in JS (charge
  meter, "Overuse limit" box). No listener-side damping (the user said skip it). A single hold runs dry at ~8 s, easing
  down from 4 s.
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
  `horns[id]` { units { f, level }, harmonics, strike, rasp, air, jitter { rate, depth }, shimmer, grille, roughness, growl, flutter,
  direct, resonances { f, q, level }, attack { time, pitch, curve }, release { time, pitch }, speaker (+ asymmetry) }), written by
  the studio's export. Must stay plain Lua.
  Horns (the user kept these; a meep and a klaxon were dropped): dual (disc pair 415/520), trumpet, sport, american, airhorn
  (semi truck: two trumpets, the user's 190/246.4, 24 brassy harmonics, roughness 35 cents + growl 0.2 + heavy rasp, no
  grille, a ragged 0.12 s start with only a 5% pitch rise), police (a siren amplifier's electronic "air horn" through its PA speaker: `sweep`, a square wave swept
  `low` -> `high` and back `rate` times a second, `rise`/`hold` shares, `riseCurve`/`fallCurve`; the rate is the buzz you hear.
  Federal Signal patent US4980837: 500 -> 1650 Hz in 2.2 ms, hold 1.1, back over 8.4 ms, 85/s. Set from the user's recording
  (police Dacia Logan): 68.5/s, ~540 <-> 1200 Hz, rising slow then fast; PA speaker 500-1500 Hz, an 850 Hz body resonance at 1.5 with direct 0.59 (the user's tuning); the user: "perfect". `unlimited = true`: never runs out (the user's ask; `CarHorn.Limited(vehicle)` is false for it, server, own client and studio).
  A first try as a diaphragm horn at 156 Hz (from YouTube iG55bsscAHA) didn't sound right to the user; the user tunes it in the
  studio, which has a sweep section and presets; a sweep horn saved there before sweeps existed is replaced by the file's). Police cars: `CONFIG.scripts[script]` (horn per vehicle script, over `models`: the police cars share
  their civilian models; sv_horn reads the script on spawn, AudioPerpScript first, and sets NW2 `horn_id`, `CarHorn.ID_NW`,
  which `HornOf` checks first) for every police vehicle: the 9 marked cars, the Crown Victoria Unmarked, the BearCat, the SWAT Stockade and the Transit Prisoner Transport (own models also by model); the SL65 RTU addon picks it when
  it exists. Alt plays it; while the siren sounds Alt still plays the siren's honkTone (the user's pick).
  `models`: a horn per car model, picked by what the real car would have (the horn module doesn't read the engine's car list):
  trumpet = German/British luxury and classic GTs (Mercedes, BMW, Aston, Jaguar, Range Rover, Maserati, Lexus, Cayenne,
  Veyron, the 250s and Miura), sport = supercars, american = US cars/trucks/work vehicles (+ Holden, DeLorean, Tesla),
  airhorn = Fire Truck, Courier Truck, SWAT Stockade, Lenco BearCat (the user's pick); the other 62 (European/Japanese everyday cars, vans) the default dual. The user said a three-trumpet major chord and a smooth
  0.2 s glide up from 0.75 sounded "harmonic, not like an actual air horn, especially the wind up": no musical glides or chords.
  The user found the first versions "way too artificial" (the trumpet "out of GTA:SA"): they were dead steady with the note
  loudest. Now every horn has jitter (each unit's own random pitch drift), shimmer (per-cycle level) and, on cars, a grille
  (bumper reflections), and the disc horns' harmonics are weak at the note and loudest around 2-3 kHz, like a real disc horn.
  The user then still found them "very cartoonish", not fitting the game. Now (the 4 car horns; the air horn stays as the user
  tuned it, its new fields neutral: strike 0, direct 1, no resonances, asymmetry 0, rendering bit-identical to before):
  no pitch gestures (attack 10-15 ms from 0.97-0.98, was 20-35 ms from 0.92: a "bwah"; release 25-35 ms at pitch 1, was a fall
  to 0.94-0.95: a "boop"; jitter 3 Hz / 3 cents, was 8-10 Hz / 8-10 cents, a vibrato), and a source-filter horn: `strike` 0.8-1
  (harmonics in cosine phase: a kick each cycle), nearly flat harmonics (n^-0.35..0.5), the kicks ringing fixed `resonances`
  (disc: 2350/3500/1100 Hz Q 6/8/2, direct 0.25; sport 3000/4400/1400; trumpet 1250/2500/620 broad, direct 0.5; american
  "seashell" 1700/2900/800, direct 0.35) so each cycle is a knock + short ring that varies with rasp/roughness (4-6 cents),
  `asymmetry` 0.2 for the pair's difference tone; drive 3.2-3.5 on the disc/seashell horns keeps the loudness within ~1 dB
  of before (asymmetry costs peak headroom: 0.4 was 2.5 dB quieter). Not yet heard by the user in game.
- `cl_horn_synth.lua`: plain Lua, game and studio. One sound per horn: the attack (pitch scoop + level rise), `SETTLE_SECONDS`
  0.05 steady, then a `LOOP_SECONDS` 2 s seamless loop (every wobble and noise read by the position in the loop, units tuned to
  whole cycles; the settle is fed exactly what the loop's end is, so filters and grille wrap in the same state; `--test` checks
  that the two match); returns `loopStart` for `sound.Generate`'s loopStart. Rasp = noise burst each cycle where the diaphragm hits
  its stop. Chain: units (+ air) -> highpass -> `resonances` (band passes, peak 1, + `direct`) -> drive (tanh, `asymmetry` offset,
  then a 20 Hz DC block) -> peak -> lowpass -> grille -> cabin muffle. Without resonances the bare harmonics pass (direct 1). The release isn't rendered: played as a volume fade + pitch fall (in game ChangeVolume/ChangePitch over release.time).
- `dev/honk_studio/build.js [--test]` builds `dev/honk_studio.html` (as the siren studio; `--test` checks every horn, outside and
  inside, for length, peak and the loop seam). Hold the honk key or the Honk button; "Beep beep" = two taps. Saves edits in
  localStorage (`honk_studio_settings_v1`).

## Debug module (not part of the final addon)
`lua/audio_engine_debug/`, loaded by audio_engine_init.lua when the folder exists (delete it to ship). On by default (`audio_engine_debug` 1, shared; 0 = off);
superadmins, listen host or single player (`EngineDebug.Allowed`). `audio_engine_debug_menu`, `!enginedebug`, context menu. The core never refers to it:
it wraps `AudioEngine.GetEngineConfig` (`EngineDebug.Install`, `EngineDebug.BaseConfig` = the core's) and uses `AudioEngine.ApplyGearing`, `AudioEngine.RebaseHandling`, the E tables.
- `sh_kv.lua`: Valve KeyValues parse into entries with value spans (`KeyValues.Rebuild` keeps the file byte for byte; `root` = top block, `KeyValues.EntryId` = root/path|key|occurrence, the same across cars' scripts;
  `KeyValues.IsHandling`: false for all of vehicle_sounds and `KeyValues.NOT_HANDLING` (steering dustcloud): this addon never uses the scripts' sounds), `KeyValues.PARAMS` script key -> GetVehicleParams
  field, `KeyValues.ApplyValue` scales by new / file value (unit-free; a file 0 is taken as is, mph -> in/s for speeds). Unmapped keys (wheel radius, materials, sounds) = respawn.
- `sh_debug.lua`: `EngineDebug.SERVER_CVARS`, `EngineDebug.TUNABLES` (AudioEngine.HANDLING values set live; mirrored to clients through Global2 `audio_dbg_handling`, `EngineDebug.FollowGlobalHandling` in the GetEngineConfig wrapper), gearing text
  (`EngineDebug.EncodeGearing`), `EngineDebug.GearingFromConfig`, rev "rise,fall". Live overrides: NW2 `audio_dbg_gear` / `audio_dbg_rev` per car, Global2 `audio_dbg_rev` -> Drivetrain.REV.
- `sv_debug.lua`: net `audio_dbg_*` (`audio_dbg_copy_req`/`audio_dbg_copy`: another car's script text for copying: a spawned car's, or a path under scripts/vehicles/, PERP_PHYSICS fallback). Script = the car's `vehiclescript`, or on test_car the PERP script it stands for, synthesized as test_car.txt with
  `AudioEngine.PERP_PHYSICS` values; baseline (`vehicle.audioDebugBaseline`: file text, params, mass) taken on first request, edits always scaled from it. `audio_engine_debug 0` undoes everything.
- `cl_debug.lua`: script data per car (`EngineDebug.ScriptData(vehicle)`, `OnScript` listeners, `ApplyScript`; an apply's echo keeps edits made after it was sent).
  Pages Handling script (edit, apply live, copy, save to data/audio_engine_debug/scripts/; blocks fold by hand-laid sections, Vehicle_Sounds and
  non-handling "Effects" folded by default, fold state kept per session; "Copy handling from...": a spawned car or any CAR_MODELS / JOB_VEHICLES
  script + tier, chosen parts (body, engine, steering, axles; wheel radius off) into the editor unapplied, only keys both scripts have;
  save history: every Apply live / Save to data/ / overlay Save version adds v<n> + time + values changed from the file (unchanged = no new
  version) to data/audio_engine_debug/history/<script>.json, hover = changes from the previous version, click = load into the editor), Gearing (shift speeds, chart, audibility
  check, copies an AudioEngine.CAR_GEARING entry), Rev response (copies AudioEngine.CAR_REV / Drivetrain.REV), Handling (PERP default handling = audio_engine_drivemodel 0; the HANDLING values), Settings.
- `cl_handling_overlay.lua`: while driving, the pinned and changed values on the right of the HUD; holding C (sandbox
  context menu) shows an editable copy parented to `g_ContextMenu` (it needs `SetMouseInputEnabled(true)`: a context-menu child takes no clicks
  otherwise, the first version's buttons did nothing; keyboard via sandbox's OnTextEntryGetFocus/LoseFocus hooks). - / + / scroll (Shift finer) apply
  0.3 s after the last step, typing 1 s after the last key or at once on Enter / clicking away; chat quiet. Rows shown stay while you sit in
  that car (`overlayKept` in cl_debug, cleared on leaving it) until x or the menu's dot (= on the overlay or not: `EngineDebug.ToggleOverlay`)
  takes them off; a dismissed changed value comes back when it changes again. `audio_engine_debug_overlay`
  (client, 1; Hide sets 0, the menu's "C overlay in the car" box). Pins/dismissals: data/audio_engine_debug/overlay.json.
- `cl_perf.lua` / `sv_perf.lua`: profiler. Measures nothing until turned on (the user's rule): the wrappers on the addon's hooks
  (names `audio_engine*` / `police_siren*`), util.Trace*, CreateSound / CSoundPatch methods, DynamicLight, render quads/sprites,
  NW2 setters (`audio_*`/`siren_*`, changes only), net.Start/Send, and `AudioEngine.PerfCar` (cl_engine's per-car timing point, a nil check
  otherwise) go on only while a capture or the overlay runs and come off after; the server's poll timer exists only then; a Lua
  refresh takes the old wrappers off (`EngineDebug.PerfClient/PerfServer.Uninstall`). `audio_engine_perf [s] [client|server|both]` prints
  a console report; `audio_engine_perf_hud` live overlay (server figures once a second to subscribers; `SECTIONS` client / sound / memory /
  server: per figure now, average and peak (worst: lowest fps) over `HISTORY_SECONDS` 60 of 1 s samples + a bar graph of that minute,
  green / amber / red against each figure's good / warn, else the section's colour; then cars by state + the costliest, busiest
  hooks; scaled with the screen height; a CLEAR 60 s button in its header, clickable with C held (an invisible DButton on
  `g_ContextMenu` over it), or `audio_engine_perf_hud_clear`; smoke-tested in a mock, not yet seen in game); `audio_engine_perf_snapshot`
  cars, patches, memory with no timing; `audio_engine_perf_spawn <n> [car|mixed] [lights] [mph] [grid|race]` / `_clear` stress test.
  race: a column 60 m down the road coming at you, 5 m to your right, zig-zag +-1.4 m, random 8-25 m gaps (`RACE` in sv_perf),
  every car setting off together once all engines started, at 3x the grid's acceleration (21 m/s2): drive-by Doppler / pass-by.
  With mph the cars drive off: handbrake released (a driverless jeep holds it on: it kept them standing) and pushed along their nose each tick (~7 m/s2 up to mph, then held, kept straight; a car still standing after 3 s, or not started after 8, is reported to the console; hook
  `audio_dbg_perf_drive` only while any drive), sounding W held (NW2 audio_in 1) and at speed the limiter's hold (audio_limst 1).
  Memory: generated banks keep their samples in Lua tables (8 B each, held by the sound.Generate callbacks) + the engine's copy
  (~2 B); counted as `bank.samples` (cl_soundbank); baked banks = their WAV file sizes; the siren's `PoliceSiren.Stats()` (cl_siren).
  Smoke-tested in a mock (wrappers off after each run); not yet measured in game.

## dev/ (not needed in game)
- `dev/baker/` (Node + wasmoon@1.16.0, `npm install` there): `node bake.js` renders all stock engines (~6 min on 5 workers) into
  `sound/audio_engine/` + `lua/audio_engine/cl_baked.lua`. Re-bake after changing cl_synth, cl_soundbank, sh_presets or the car list.
  `node bake.js --electric` re-bakes only the electric motors + env bank (~15 s) and keeps every other entry and folder:
  only for changes that can't touch other engines (it fails if any other engine's sound key is missing from the manifest).
  `node bake.js --changed` bakes only engines whose sound key isn't in the manifest (a new or retuned preset/car) and keeps every
  other entry, folder and the env bank (a sh_presets edit changes the synth version hash, so a full bake would rename every folder:
  a full re-download for players). Not after cl_synth / cl_soundbank changes.
  `node bake.js --dry` renders everything and writes nothing, printing each engine's band levels as played (`bank.levelReport`);
  `--out <dir> --only 3,7` writes those engines' WAVs and a manifest for just them to <dir> (dev/drive_demo plays them with
  `AE_SOUND=<dir>`, `AE_OUT` for its output: compare against recordings without touching the shipped bake).
  `analyze_wav.js <wav|folder>` prints loudness and pitch per band. `test_handling.js` checks sv_handling (PERP physics on the test script) and the handling model with a fake vehicle. `test_prediction.js` checks the driving prediction. `test_debug.js` checks the gearing/rev core and the debug module's shared code. `check_syntax.js` compiles all Lua; `test_integration.js <PERP dev pack dir>` checks muting and baked banks.
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
  Worker -> worklet straight over a MessagePort. No bands live, so worker.js `level` stands in for the bank's levels. Generational Lua GC:
  the default collector paused up to 120 ms. Turbo/BOV aren't previewed. Also draggable exhaust resonances and firing bars (custom layouts: 1-16 firings),
  start from a preset, silencer; exports changes as text + JSON to paste back: `sound`/`character` as ever; `muffle` = car.muffle; `layoutDef` = a new
  entry for Synth.LAYOUTS, Synth.CHARACTER (voice of `voiceFrom`), AudioEngine.LAYOUT_CYL and AudioEngine.LAYOUT_ORDER. Per-car voice: `P(preset, stock, character)` in sh_carlist (cl_synth `Synth.CharacterFor`, part of the sound key).
  Preset-scope voice: a preset's own `character` (used when the car has none) and `muffle` (the car's silencer, over the economy one).
  Presets that used their layout's voice now have their own (v12na, v12t, v10l, v8x, v8s, v8xt, v8h, v6t, i6, i6t, i4s, i4t, i4h,
  boxer, f4air, r2t; not heard by the user yet); sl65, f12, w16, v10, v8flat, v6, v6odd, f6, f4, i3, i5t, r2, r3 keep the layout's.
  V12 voices (the user's, Tone Studio, 2026-11): v12na "raw bellow" (modern Ferraris, Diablo, Murcielagos, Reventon, McLaren F1), v12r "deep rumble"
  (silencer 0.6, tone 0.15, redline 6500, V8-strength low orders o1 0.18 / o05 0.26: Astons DBS/Rapide/V12 Vantage, Miura, Zonda C12, Ferrari 250 GT/GTO). Lower
  resonances alone didn't help: the user still heard a scream, which is the firing rate and the filter opening up the revs.
  V8 voices: v8x heavy duty (trucks, work vehicles), v8m old muscle, v8p modern performance, v8r refined sedan. I4: i4/i4st sporty, i4w warm hatch (regular cars), i4q quiet hum (cheaper cars). `economyTuned` presets were tuned on an
  economy car, so economy cars keep their tone and gurgle (no x0.5, no gurgle 0).
  Engine ideas panel: `dev/tone_studio/candidates.json` lists sounds to audition before they reach sh_carlist (each is an ordinary edit of its
  example car; `[]` hides the panel). Nothing in it reaches the game.

## Git
- Branches are named `cc/<feature>` (the user's rule), e.g. `cc/tier-gearing`: never the session's generated name.

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
  the tables the debug menu tunes by key name (HANDLING, CRUISE, ...), sh_police lamp data keys
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
- Electric whine layer for hybrids; an inverter carrier tone for EVs (its own fixed-pitch loop); per-car EV voices (Leaf PMSM vs Model S induction); real diesel character (diesels currently use softened petrol presets).
- Confirm the uncertain car mappings (INTEGRATION.md section 8) against PERP's dealer table.
