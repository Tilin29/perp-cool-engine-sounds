# Code review: agreed fixes (2026-11-20)

Three reviewers checked the addon, each on a different model and a different part of the code:

- **A (Opus):** the engine sound path.
- **B (Sonnet):** driving, prediction and the server.
- **C (Fable):** lights, siren, horn, the car list, HUD/menu and the debug module.

Three verifiers then checked each report against the code, each on a different model from the one that wrote it (Fable checked A, Opus checked B, Sonnet checked C). This file only lists what survived that check. Verdicts:

- **Confirmed:** traced in the code.
- **Plausible:** the mechanism is right, but it depends on engine behaviour nobody could confirm offline.

No critical bugs were found.

What passed:
- `check_syntax`, `test_handling`, `test_prediction` and `test_debug` all pass.
- The car list is consistent: every name in CAR_POPS, CAR_BOV, CAR_SUPERCHARGER, ECONOMY, JOB_VEHICLES, POLICE_VEHICLES, horn scripts and so on exists.
- Every server net receiver and command checks the sender: `audio_engine_set`, `audio_engine_toggle`, `car_horn`, lights, siren and `audio_dbg_*`.

Full reports: the session scratchpad's `review/` folder (`reviewer_*.md`, `verify_*.md`).

---

## 1. Fix first (real bugs, cheap fixes)

| # | Where | Problem | Fix | Verdict |
|---|---|---|---|---|
| 1 | `sh_drivetrain.lua:177/306` | The current gear is kept when the config is rebuilt (an `audio_vmax` / `audio_gear_vmax` / `audio_pwr` / profile change). If the new config has fewer gears, `config.gears[gear]` is nil and the code errors with `nil * number`. | Clamp the gear to `#config.gears` at the top of `Drivetrain.Step`. That covers cl_engine, sv_engine, drive_demo and tone_studio at once. | Confirmed. Medium with the editor or debug gearing, low in production. |
| 2 | `cl_engine.lua:1250-1265` | The `audio_engine_cars` Think hook loops over every car with no error protection. One car's error freezes every car after it in `pairs` order, and skips the tunnel probe, every frame. | Run each `updateCar` through `xpcall` and print the error once per car. Same in `cl_handling.lua:607-609`: `calcView` runs `updateFrame()` unprotected before the original CalcView, so an error there breaks every addon's camera. | Confirmed. |
| 3 | every client `EntityRemoved` hook: `cl_engine.lua:1286`, `cl_handling.lua:678`, `cl_siren.lua:392`, `cl_horn.lua:486` | GMod passes `EntityRemoved(entity, fullUpdate)`, and a full update (common with packet loss at ~150 ms ping) "removes" entities that still exist. None of the hooks checks that argument, so every car's sound stops and its state is thrown away. Cars come back up to 0.5 s later at idle in gear 0: a silent gap, then a rev glitch. | `if fullUpdate then return end` in each hook. | Plausible: the verifier recalled the argument, and it is on the GMod wiki (`GM:EntityRemoved`). Confirm on the wiki before changing anything. |
| 4 | `cl_soundbank.lua` `Bank.RebuildAll` / `cl_engine.lua:751,768` | A rebuild swaps in a new env bank that isn't ready yet. A turbo or EV-hum group that is playing calls `singleNameList(nil)` and fails with "table index is nil". Road, wind and supercharger loops freeze at their last volume. | Keep the old env bank until the new one is ready, then swap. Making `singleNameList` nil-safe is not enough on its own. | Confirmed, low-medium: it only happens on `audio_engine_baked` / sample rate / `audio_engine_rebuild`. |
| 5 | `cl_engine.lua` (dormancy) | A car switched off while out of PVS plays its shut-down sound when it comes back into view, possibly minutes later. rpm and `lastEngineOn` freeze while dormant, and the stop path has no timestamp check (the start path has `audio_on_t`). | Set `car.firstUpdate = true` when a car leaves dormancy, so it takes the current state with no one-shot. | Confirmed. |
| 6 | `cl_soundbank.lua` `Bank.Get` | The `audio_engine_maxsounds` cap is only checked when the fallback id differs from the config's, which is never the case for a stock car. With the baked WAVs missing or out of date, every distinct engine nearby is generated and kept for good. `Bank.RebuildAll` also regenerates every old bank past the cap, and generated sounds can't be freed, so each rebuild adds a full set to memory. | Apply the cap to every generated bank, baked fallback or not. Build only the banks of cars currently near on a rebuild. | Confirmed. How much memory each engine keeps on the Lua side is plausible (~12 MB, if GMod keeps the `sound.Generate` callback). |
| 7 | `cl_soundbank.lua` | A failed bank build stays not-ready forever, so the car is silent with no fallback. | Mark it failed and fall back to the family's or the preset's baked bank. | Confirmed, low. |
| 8 | `sv_horn.lua:147` | `PlayerDisconnected` only clears `honking`. If the driver drops while honking, `horn_on` can stay true, and everyone hears the horn (or the siren's honk tone) held on. | Call `stopHonk(player)` there. | Plausible, harmless to fix: it depends on whether `PlayerLeaveVehicle` fires on disconnect. |
| 9 | `cl_siren.lua` | A car that drops out of the siren list while still valid (for example, its bar entity reads as invalid out of PVS) keeps its loop playing forever. | Stop any patch whose car is no longer in the list, as `cl_horn` does. | Confirmed mechanism. |
| 10 | `sv_seats.lua:206` | During the use cooldown `PlayerUse` returns nil, so Source's own use runs. If E is held, the passenger can take the free driver seat, and the pod is then removed silently. | `return false` while the cooldown runs. | Plausible: depends on PlayerUse repeating while E is held. |
| 11 | `cl_handling.lua:604-633` | `ourCalls` is local to the file load and a 2 s timer re-wraps `hook.Call`. If another addon wraps it after us and calls through, or on a Lua refresh, `calcView` runs twice: the "camera 2x ahead" bug again. | A nesting guard, and keep the handler in a global so a refresh swaps it instead of nesting a second one. | Confirmed. |
| 12 | `cl_engine.lua` budget (`BUDGET_MARGIN`) | With `audio_engine_maxcars` 1 or 2, a car that goes over budget never comes back: the margin of 2 makes the test always true. | Clamp the return threshold to at least 1. | Confirmed, low. |

## 2. Performance (worth doing before a 40-car test)

| # | Where | What | Fix |
|---|---|---|---|
| P1 | `cl_police.lua:116-173` | ~10 Vector/Angle objects per lit lens per frame, and two material switches per lens. With 10-15 lit cars that is ~100-200k short-lived objects a second and hundreds of material switches per frame. | One matrix per bar, reused vectors updated in place, all lens quads in one pass then all glow sprites in another, and a cap on how many cars are drawn at full detail. |
| P2 | `cl_engine.lua` per car | ~7 Vector/Angle allocations per frame (`GetPos` called repeatedly, subtractions, `GetAngles`), plus 3 closures built per `Drivetrain.Step` while in gear. At 40 cars and 144 fps: ~40k userdata and ~17k closures a second. | One `GetPos` / `GetAngles` per car per frame into scratch values. Move the closures in `Step` to file-level functions that take the state as an argument. |
| P3 | `cl_engine.lua` | Out-of-range and over-budget cars still run the full update and load their banks (~40 `PrecacheSound` calls, or a tuned generation) for cars nobody hears. | Run only the rpm model for silent cars, and load their bank when they come within range or budget. |
| P4 | `sv_engine` / `sv_handling` / `sv_cruise` | `OnEntityCreated` starts a timer for every entity on the server. Three Tick hooks plus Think loop over all tracked cars every tick, calling `GetModel` / `GetDriver` even for parked cars. | Filter on `GetClass() == "prop_vehicle_jeep"` (not `IsVehicle`, which also passes the seat pods). Keep a set of driven cars from Enter/Leave, and cache the car config on the entity. |
| P5 | `sv_handling` | `audio_engine_drive` (~2 KB/s each) goes to every driver, including single player, a listen host and clients with prediction off, who all throw it away. | Send only to clients that report `audio_engine_predict` 1 (a userinfo convar) and aren't the listen host. |
| P6 | `cl_handling` others | For up to 17 other cars per frame: 1-2 hull traces and table allocations, and the handling settings read through a function-based `__index` inside the replay. | Throttle the wall traces (every 2-3 frames per car) and read the settings into locals once per predict. **Keep `MarkShadowAsDirty`**: without it the shadows stay at Source's pose, metres behind at speed. |
| P7 | `cl_hud.lua`, key-polling / sorting Think hooks | ~400 small tables rebuilt per frame in the HUD, plus small per-frame allocations. | Reuse tables. Low priority. |

## 3. Worth checking in game (can't be settled offline)

Each of these needs a test on a real server, because the answer depends on engine behaviour nobody could confirm:
- **Engine sound revive.** Does `CSoundPatch:IsPlaying()` notice a loop the game dropped? If not, the once-a-second revive never fires (A11). When the revive does restart a sound, it restarts only one half of a band's on/off pair, which breaks the pair's shared firing phase. Restart the whole group instead.
- **`sound.Generate` and the 6 ms budget.** Does `sound.Generate` run its callback per sample inside the call? If so, the generation budget overruns (A9).
- **Commands, state and timing in vehicles.** Client and server `CommandNumber` in a vehicle, `GetWheelContactPoint`'s third return value, and `PlayerLeaveVehicle` firing on disconnect (B13). Also, B3: the speed limiter's middle-click still uses `PlayerButtonDown`, the hook that missed engine-start presses. If it misses presses too, move it to a client-polled concommand like the start key.
- **`SetVehicleParams` on a moving car** (steering match, limiter trim) has unknown side effects (B7). If it's fine, cache the unit self-check per vehicle.
- **Lua refresh** leaves old sound loops playing (cl_engine, siren, horn). This is dev only: stop all patches when the file reloads.
- **Police respawns.** A police car respawned by PERP on a civilian tier script (stingered) would lose its livery, lightbar, siren and horn: setup goes by the exact script path (C6). A job vehicle whose script is set after the one-tick `OnEntityCreated` delay would miss police setup too (VC-M3).

## 4. Before shipping into PERP

- **PERP's own lights (C2).** PERP may already give job vehicles their own lightbar and siren. Check, and either detect an existing bar or add a convar to turn ours off. Put the answer in PORTING.md.
- **Debug module (C8).** It's on by default and loads whenever its folder exists. Delete `lua/audio_engine_debug/` from the shipped copy: it gives superadmins live physics edits and an uncapped stress-test spawner. Its profiler's uninstall also overwrites other addons' wrappers of `net.Start` / `util.TraceLine`.
- **Horn spam (C7).** A modified client can still spam `car_horn` at ~16 presses/s on police horns or with `car_horn_limit 0`. Add a per-player press rate cap in `sv_horn`.

## 5. Docs and small items

- CLAUDE.md says `AudioEngine.PERP_STABILITY` is false; `sh_carlist.lua:1543` has `true`. Find out which is meant and fix the other.
- CLAUDE.md doesn't mention the siren's `air` and `street` settings.
- The `sv_handling.lua` header says no vehicle params are set while driving, but `matchSteering` and the speed limiter do set them.
- The speed limiter uses the full 3D velocity, vertical part included (VB-M5): it brakes a little early downhill. Use the speed along the ground.
- `stopAll` doesn't stop the EV power-up and chime one-shots (A14).
- Engine-off coasting cars past the budget flip in and out every fraction of a second (A12). Hold them out a little longer.
- The car geometry fallback is cached permanently if the attachments aren't ready on first use (B8). Don't cache the fallback.
- The prediction doesn't expire if the server stops sending state (B11). Drop it after ~0.5 s without a state.
- The horn's charge sync compares a CurTime as a NW2 float (C4). It only goes wrong after days of uptime: use a sync counter.

## 6. Sound engineer's review (audio, compared with real cars)

What was measured:
- 15 engine folders: cross-plane and flat-plane V8, I3, I4, I5, I6, flat-6, V10, V12, boxer, rotary, W16, the BearCat diesel.
- The EV and the env bank.
- The loop point of all 992 loops.

Its renders, made through the baker's wasmoon with patches in memory only, match the shipped files exactly. Full report: scratchpad `review/sound_engineer.md`.

**Fix**
1. **The firing-timing jitter is a random walk** (`cl_synth.lua:621,629`; verified). Each firing gap is multiplied by a fresh `1 + jitterAmount * random`, so the error adds up instead of staying close to the crank angle. This causes two problems:
   - **Harmonics turn into noise from about 250 Hz up.** Only -10 to -14 dB of the 250 Hz-1 kHz energy sits on the rev-locked lines. With the jitter as a per-firing offset from the grid, it is -0.4 to -2.8 dB.
   - **The loop seam is audible.** The 0.12 s loop cross-fade blends two firing phases up to 0.82 of a gap apart (correlation -0.18). At steady revs that is a hollow, phasey blip about every 1.6 s. It is the same flaw already fixed in the supercharger loops.

   Fix: jitter each firing as a ±0.5-1 degree offset from its grid position, keeping the seed's unevenness. That brings the drift to 0.01-0.08 of a gap and the correlation to 0.77-0.96. The engines will sound cleaner and more tonal, and the user once found engines "robotic", so try it in the Tone Studio before re-baking. It needs a full re-bake.
2. **The timbre jumps at band crossovers.** The mid and muffler pipe resonances are fixed inside each band's loop, so they move ±12% with playback pitch. Adjacent bands differ by 4-9 dB averaged over the spectrum, and by 10-25 dB in single third-octaves. Lowering their Q (decay 6 to 2.5 ms and 12 to 5 ms) brought the V12 from 8.2 to 4.9 dB and the V8 from 5.6 to 3.4 dB. Denser bands would also help, at about twice the files. Re-bake.
3. **Clean:** no clicks at any loop point, the pre-roll is correct everywhere, nothing clips, and the DC offset is at most 5.7e-3.

**Improve (by payoff against effort)**
- **Loudness barely rises with the revs:** 4-10 dB(A) from idle to redline. Real full-throttle run-ups rise about 8-12 dB(A) per doubling of rpm. This can be done at runtime in cl_engine by turning the low revs down, so no re-bake, and the cap stays as the redline ceiling.
- **On/off throttle differ by about 7 dB on every engine**, exactly the leveller's 0.075/0.035 target ratio. Real cars differ by 15-25 dB(A), because they cut fuel on overrun. A runtime cut on the off layer is cheap. Keep the burble on cars tuned for it.
- **No interior sound:** the driver hears the outside loops. Cabin copies (low-passed, with a low-mid boom) would fix it, as the siren and horn already have.
- **Diesels** have no combustion clatter (they reuse petrol presets).
- **The limiter** bounces at 6.7 Hz on every engine with 27 dB-deep gaps. Real cut limiters run at about 10-20 Hz and only 10-15 dB down.
- **The start-up** has no starter-motor sound.
- **Far cars keep their full brightness.** Add air absorption: a low-pass that closes with distance.
- **Smaller items:**
  - V8 and boxer bank offsets are crank angles, where they should be time delays.
  - Low sub-orders peak up to +12 dB over the firing order on the lowest pipe resonance.
  - The road-noise loop sits too low in pitch and barely grows with speed.
  - The turbo whistle's pitch sweep is narrow.
  - `config.pitch` offsets the firing rate 14-25% from the true rpm (a user/Rev Bench choice: flagged only).

**Already good:** every layout sounds distinct and right. The I4 is led by order 2, the V12 by 6, the I5 by 2.5. Flat-plane and cross-plane V8s contrast correctly, and the boxer has its rumble. The on/off layers are phase-locked, and the env and supercharger loops are seamless. The EV whine is physically grounded and rises about 21 dB with speed. The band cross-fade, headroom, Doppler knee, per-car detune, pass-by and pop timing are solid.

## Rejected or changed in verification (don't do these)

- **B4:** "DeleteOnRemove the seat pods with the car" would leave pods and passengers floating, because removing a parent only unlinks its children. Leave it as it is.
- **B9:** storing `audio_on_t` as an int would gain nothing, because `CurTime()` is itself a 32-bit float.
- **B10:** dropping `MarkShadowAsDirty` for other cars would leave their shadows behind at speed (see P6).
- **B14:** `MASK_SOLID_BRUSHONLY` does hit solid props, so the prediction's wall trace is fine.
- **A4(b):** the hard restart on a tunnel/room change is the documented design, and it only fires when a tunnel threshold is crossed.
- **C12, "175 cars, not 165":** 165 cars plus 10 job vehicles is 175, which CLAUDE.md already says.
