# Engine sound: research and suggested improvements

2026-11-27, branch `cc/engine-sound-research`. Real recordings of each engine type were compared with what the
addon ships (`sound/audio_engine/`, the drive demo's mix of them), and the pop timing in `cl_engine.lua` was checked
against how real cars crackle. Nothing in the addon is changed by this file; it is the brief for the new offline
generator and for the runtime changes that can be made now. The sounds stay synthesized: the recordings were only
measured, nothing from them is meant to ship.

## Progress (work on these suggestions, newest last)

Kept up to date while working, so the next session can carry on from here.

- 2026-11-27, started on items 1-2 (pops). Plan: a pop-only generator `dev/popgen/popgen.py` (Python, numpy/scipy:
  the new generator isn't in Lua) re-renders `pop1-5` / `bang1-3` in every bank folder as single cracks (same names,
  same count) and rewrites their peaks in `cl_baked.lua`; `cl_engine.lua`'s burble timing changes in the same step
  (the new dense timing only works with single-crack files, the old cluster files need the old timing).
  Level measured on the recordings: a real pop's first 25 ms is about as loud, full band, as the engine around it
  (median 0..+3 dB, strong ones +5..7, `poplevel.py` in the session scratchpad); it stands out by its treble.
  The recordings and a working Python venv from the research session are in
  `%TEMP%\claude\d3135cb6556adea7\a7194552-de70-4106-9084-5d5168a793cf\scratchpad\` (`ref/`, `venv/`, `tools/`):
  temporary, may be gone.
  - [x] `dev/popgen/popgen.py` written (`--preview <dir>` / `--write`, `--only <dir prefix>`)
  - [x] rendered and measured: first 25 ms, median over all banks, dB under the loudest octave at
    63..16k: -8.5 -8.0 0 -9.2 -14.2 -10.7 -9.4 -15.4 -23.5 (recordings: 2k -3..-24, 4k -1..-30, 8k -9..-40,
    16k -21..-53; old files 8k -51..-63, 16k -79..-88); -20 dB in ~19 ms (real 15-45), -40 dB by ~83 ms.
    Took four tries: a bare 0.5 ms pulse was right in spectrum but decayed -20 dB in 8 ms and was all peak (a
    click); too much body was too dark; now a ~1 ms pulse + a 3 ms 0.9-6 kHz sizzle, pipe reflections, body, ring.
    Nearly every file sits at the 0.95 peak cap: the level target (engine loop + 1 dB) wants more than fits,
    so they're as loud as the peak allows. Engines with louder loops (W16, V8 trucks) get relatively quieter pops.
  - [x] written into all 42 combustion banks (336 files) and their peaks into `cl_baked.lua` (header line names
    popgen). The old files are in git (`git checkout HEAD~ -- sound/audio_engine/*/pop*.wav ...` once committed).
  - [x] `cl_engine.lua` burble timing (comment above `local popFrequency`). Section 1's suggested rate
    (6 + 10 P a second) overshot the recordings when simulated (19 cracks per lift vs the F-Type's 9): now
    3 + 6 P, groups of 1-3, closing bang 0.6 P^2 late in the window. `playPop` avoids the last two names;
    `popPeakLoad` decays at 0.012 s.
  - [x] `dev/drive_demo/render.js` mirrors it, `DRIVE=pops` drive (blips, then lifts in gear). In that mix the 3+ kHz
    band peaks at -28 dB on the pops against a -72 dB median (old: -40 max: the pops had no treble at all).
  - [x] CLAUDE.md updated (Pop timing, the baked-WAV contract's pop line, drive demo)
  - [ ] heard in game (the user). Not committed (the user's rule: cl_* changes stay on the cc/ branch until asked).
    Knobs if they're off: loudness `POP_OVER_ENGINE_DB` / `BANG_OVER_ENGINE_DB` in popgen (or cl_engine's 0.7);
    brightness the crack lowpass (6500 / turbo 4600 Hz) and `SIZZLE`; length the body taus and the ring's 0.035 s.
  - The user's verdict on that first version: "the pops sound like popcorn". Compared with the F-Type on a
    spectrogram: a real burble pop isn't one crack but a ~180 ms train of cracks at one bank's exhaust pulse rate
    (~9 ms apart at ~3500 rpm), swelling and fading; the R8's are shorter trains. Ours were lone ~1 ms ticks.
    popgen-2: each file is such a train (pop 8-20 pulses at ~0.5 x redline, bang 16-28; see `render_event`),
    the crack darker (lowpass 5000 / turbo 3600 Hz, less sizzle: summed in a train they were too bright),
    median over all banks 1k..16k -13 -14.5 -14 -20 -26 dB (the recordings' median -10 -11 -15 -20 -33).
    cl_engine plays bursts (0.15-0.45 s) / (0.5 + P) apart instead of crack groups; `popPeakLoad` 0.06 s.
    In the F-Type demo the in-gear burble now looks like the real one (bursts ~0.1-0.15 s, ~3-4 a second); what
    still differs is between the bursts: the engine itself is dark there (item 3). Written to all banks.
  - The user on popgen-2: "sounds like tin foil being shouted into". Measured over the whole burst (the earlier
    check only looked at the first 25 ms, which is bright on real pops too): ours were 8-15 dB too bright from
    4 kHz up (F-Type bursts 4k -18..-24, 8k -29..-40, 16k -41..-48; ours -12..-18, -20..-25, -24..-30), and a
    pulse train through fixed Q 4-6 ring modes at 700-4500 Hz is how a voice makes vowels ("shouted").
    popgen-3: crack lowpass 3000 / turbo 2200 Hz (`CRACK_TOP`), sizzle 0.35 to 3.5 kHz, ring modes 400-2600 Hz
    at Q 2-3 (moving with every crack) rolled off at `RING_TOP` 6500 Hz with the scatter, more body (1.6) and
    thump; popgen now reports whole-file spectra. Median over all banks, whole file, 1k..16k:
    -13 -18 -22 -31 -48 (the F-Type's bursts -8..-13 -8..-18 -18..-24 -29..-40 -41..-48). RING_TOP 4000 gave
    8k -38 / 16k -56: too dull again (the original complaint), so the F-Type's range is the target, not darker.
  - The user on popgen-3: "closer, but it should be more bassy, like a BRAP sound". The cracks were near
    zero-mean clicks with the body at 150-450 Hz; the "BR" is the exhaust pulses themselves, a few ms of positive
    pressure each, whose train puts its weight at the firing rate (~100-300 Hz). popgen-4: a `PUFF` (1.5, a 4.5 ms
    half-sine push and a 3x longer, third-height suction, no net flow) under every crack, the body at 0.8 x
    (`BODY_PITCH`), and each burst a duration (pop 0.08-0.2 s, bang 0.18-0.32 s) filled at the engine's pulse rate
    instead of a pulse count (V12s got ~50 ms bursts). Whole file, all banks: 63..16k -3 -0.5 -0.7 -8 -14 -19 -23
    -32 -49 (125 Hz now 14 dB over 1 kHz, was 5; the F-Type's ~11). Waveforms now show its big periodic low pulses.
  - The user on popgen-4: "more like a BRAP sound, but otherwise good" (the bass and top end stay). The bursts
    swelled up softly and faded, 85% of pulses firing: a smooth buzz. popgen-5: B-R-A-P shape, a hard first
    thump (`B_LEVEL` 1), a rattle at `RATTLE_LEVEL` 0.7 falling 30% with only `FIRE_CHANCE` 0.6 of the pulses
    burning (the gaps are the "R"), then a pause of 0.5-1.5 pulses and a closing crack (`P_LEVEL` 0.9); pops
    0.12-0.24 s, bangs 0.2-0.32 s (one rattle crack 1.6x). Spectrum as popgen-4.
  - The user asked to try "pops only once at most, but random sounds": cl_engine `POP_ONCE_PER_LIFT` (true now;
    false = the burble, kept): a lift pops at most once (same chance 0.3 + 0.65 P and start delay), any of the
    pop / bang files (a bang with chance 0.25 + 0.35 P), level 0.65-1, pitch `POP_ONCE_PITCH` 85-115% (burble
    92-108); no odd pops on a long coast. Upshift crack and limiter pops unchanged. The drive demo mirrors it
    (`POP_ONCE=0` for the burble; its lift test uses the sound throttle, so a blip held on the limiter can count
    twice there, not in game, where it's the pedal).
  - The user on popgen-5 (one pop per lift): "getting closer, still missing the sound being a BRAP. Also a bit
    more bass. Like a DSG fart". A DSG upshift blat is the exhaust pulse train heard as a low pitched buzz: every
    pulse there, evenly timed, levels rough; the F-Type's bursts show it too (harmonic lines to 2-3 kHz: the
    pulses alike cycle to cycle). popgen-6: `FIRE_CHANCE` 0.93, `CRACK_JITTER` 0.05, `PITCH_DROP` 0.15 (the
    pulses slow over the burst), `RATTLE_LEVEL` 0.85, `P_LEVEL` 0.8 after a 0.2-0.7 pulse pause, `PUFF` 2.6 /
    `PUFF_WIDTH` 6.2 ms, less random noise per crack (`PULSE` 0.9, `SIZZLE` 0.15, `RING` 0.2) so the train is
    coherent: harmonic lines to ~1 kHz now (popgen-5: noise above ~600 Hz); pop 0.1-0.2 s, bang 0.18-0.3 s.
    Whole file, all banks, 63..16k: -0.7 -0.5 -2.7 -9.3 -15.8 -24 -29 -37 -52: the weight at 63-125 Hz (was 250),
    the top 5-7 dB lower relative to it (CRACK_TOP 4000 barely changed that: it's the bass, so left at 3000).
  - The user on popgen-6: "Nope. Can you get some help off the internet. Try to find if there's any sound
    available already. You're not that great at generating these". So pops may now be recorded (an exception to
    "synthesized, not recorded", the user's call). Searched: nothing ready-made and free (Fab "Muffler Crackle
    Sounds" pack is EUR 4.55; Soundstripe / Artlist are subscriptions). Cut 79 candidate pops (`cut_pops.py` in the
    session scratchpad: 800-10k energy 10 dB over a 0.5 s median, bursts 10-600 ms, top 8 per clip, peak 0.9) from
    20 free clips: the research refs (F-Type / C63 Commons CC BY, R8 / crackle / SLS / M3 CC BY, anti-lag / S63 /
    rally pass CC0) and 12 new CC0 Freesound backfire clips (nsstudios 351738/351739, craigsmith 675723/481663,
    Pól 385935, CeebFrack 105351, mudflea2 705363, Mihacappy 875056/827175, Yoyodaman234 667592, inspire153 828733).
    Listening page: `<scratchpad>\candidates\index.html` (+ cuts.json). Waiting for the user's picks. Next: put the
    picks in as pop1-5 / bang1-3 (one shared set, or per engine type), levelled as popgen does, CC BY ones credited
    in a credits file; popgen stays for anything without a recording.
  - The user's picks from the 79: `antilag_3` (modusmogulus 797835, CC0, at 1.77 s: "sounds like a DSG fart kind
    of") and `antique_2` / `antique_3` (craigsmith 481663 "Antique auto sputter and backfire", CC0, at 23.28 /
    21.16 s) "would be good for pops if they had some bass added"; all the others bad. The antique ones peak at
    2 kHz with 63 Hz -31 dB under it. Bass versions of all three (`bassup.py` in the scratchpad, page
    `<scratchpad>\bass\index.html`): orig, low shelf +9 / +15 dB under 180 Hz (EQ alone gets 125 Hz to only -7),
    thump layer light / heavy (popgen's puff under every crack of the recording + an 85 Hz thump at the first:
    63-125 Hz to the top), and thump + shelf +6. Waiting for the user's pick; then they become pop1-5 / bang1-3
    (variants by pitch / level) in every bank.
  - The user picked `antique_2_thumpH`, `antique_3_both`, `antilag_3_both`. Installed in all 42 banks (popgen.py's
    default now; `--synth` for the generated ones): pop1-5 = the three + antique_2 at 0.93 and antique_3 at 1.07
    pitch, bang1-3 = antilag_3 0.86, antique_2 0.82, antique_3 0.85; the set pitched per layout (V8/V12 ~0.9,
    fours ~1.05); levelled as before. Files + README (sources, CC0, cut times) in `dev/popgen/recorded/`. Still
    one pop per lift (`POP_ONCE_PER_LIFT`). Whole file, all banks: 63 Hz loudest, 2k -5, 4k -6.5, 8k -22, 16k -52.
  - The user on the installed recordings: "maybe they're too loud as they sound more like exhaust or valve than an
    actual pop. Maybe they still lack that bass of a pop". Read as: the 1-5 kHz chuff (2k only 5 dB under the top)
    sounds like breath / a valve, and a pop's bass is a short kick-drum punch at the onset, not a buzz. Versions
    (`punch.py` in the scratchpad, page `<scratchpad>\punch\index.html`): now / mid cut (-7 dB at 2.5 kHz, -3 at
    1.2 kHz) / cut + light, heavy or deep punch (a sine swept 130 -> 55 Hz decaying in 60 ms; deep 100 -> 45 Hz,
    90 ms). Waiting for the pick; then install it with the level lowered (popgen `POP_OVER_ENGINE_DB`, ~-4 dB).
  - The user's picks: `antique_2_thumpH_cutkickH` ("for more sporty cars"), `antique_3_both_cutkickD` ("for
    sporty bassy cars"), `antilag_3_both_cutkickL` ("the antilag when shifting"), "switch the antiques up and down
    in pitch slightly (not a lot)". Installed: pop1-5 = the sporty or (`BASSY_LAYOUTS`) the bassy one at 0.96-1.04
    pitch; bang1-3 = the anti-lag at 0.97-1.03; no per-layout pitching; -4 dB (`RECORDED_LEVEL_DB`). cl_engine:
    lifts play pops only, pitch 96-104%; a flat-out upshift over 0.75 x redline plays the anti-lag with chance P
    (was a crack with chance 0.6 P^2); limiter plays pops. Old recorded files replaced (untracked, never committed).
  - The user: "too quiet now, all of the sounds, can barely hear them". Measured (perceived, K-weighting-like):
    they played about as loud as the engine's OFF-throttle loop, 8 dB under the on loop: levelled by peak, and the
    kick holds the peak while the ear hardly counts it; then -4 dB. And cl_engine's pop headroom (pop peak + the
    engine's worst-case mixPeak <= 0.98) took ~7 dB off the upshift anti-lag (mixPeak ~0.66 flat out), ~2 dB off
    lift pops. Now: popgen levels the recorded pops by perceived loudness (`perceived_db`, loudest 50 ms) to
    `RECORDED_OVER_ENGINE_DB` over the on loop, soft-limiting peaks over half of 0.95 (`soft_limit`);
    `RECORDED_LEVEL_DB` gone. cl_engine: `POP_GAIN` (was a bare 0.7), `POP_HEADROOM` (was 0.98) for pops only.
    The user then: "still needs to be louder" -> `RECORDED_OVER_ENGINE_DB` +2 (peaks limited up to 7 dB),
    `POP_GAIN` 1.0, `POP_HEADROOM` 1.5, a lift pop's random level 0.8-1 (was 0.65-1). Against the version that was
    "too quiet": roughly +13 dB perceived on lift pops, more on the upshift anti-lag.
  - The user: "cannot really hear the DSG farts on the Furai. The pops still sound like popcorn, the pattern of how
    they pop is weird when revving." Found:
    - lift detection was broken (old code): "throttle over 0.8 last frame, under 0.5 now", but the throttle falls
      at 7/s (~0.12 a frame at 60 fps): lifts only registered under ~23 fps. What popped when revving was the
      limiter: a P^2 chance on every fuel cut, ~7 a second (Furai ~2-3 random pops a second): the popcorn. Now
      armed over 0.8, fired under 0.5 (`car.liftArmed`), and "back on the throttle" is the pedal over 0.6 (the
      sound throttle is still ~0.4 when the lift fires, which cancelled every pop).
    - one-pop mode: a lift pops with chance 0.6 + 0.4 P, always 0.06-0.1 s after it, `POP_MIN_GAP` 0.3 s; no
      limiter pops.
    - the anti-lag: chance P (the Furai 0.6, 1 of 4 upshifts in the demo) -> 0.4 + P; levelled against the engine
      at 60% redline it played ~4 dB under the Furai flat out (its top band is much louder). Now levelled to
      max(off loop at 95% + 6, flat-out on loop at 95% + load lift - 3) and cl_engine dips the engine's loops
      `ANTILAG_DIP` 0.6 (-8 dB) for 0.08 s, back over 0.17 s, when it fires (a DSG's ignition cut). Demo: every
      Furai upshift fires it, 2-4 dB over the engine just before (was ~4 under).
    - drive demo: pedal throttle in its frames, the same lift detection, the anti-lag on upshifts (bang files) with
      the dip, `DRIVE=pops` lifts only after a shift has settled. Revving in neutral: a pop 0.08-0.1 s after every
      lift.
  - The user on the GTI (P 0.1, no audible BOV): "when you let go of the gas, the pop just acts like a pressure
    relief valve now". With lifts now registering, 0.6 + 0.4 P had it pop on 64% of lifts (before the fix: hardly
    ever), and the sporty antique cut's breath reads as a blow-off on a quiet four. Lift chance now min(1, 1.4 P):
    Furai / F-Type 0.84, R8 0.49, GTI 0.14. The GTI's upshift anti-lag stays (0.4 + P = 0.5: a GTI DSG fart).
  - The user: "okay let's remove the pops for now". cl_engine `POPS_ON_LIFT = false`: no lift pops (and in one-pop
    mode no coast or limiter pops either). Kept: the upshift anti-lag (bang files, `ANTILAG_DIP`), the recorded
    pop files in every bank, popgen.py, the lift-detection fix. The drive demo mirrors it (`POP_LIFT=1` plays them).
    Open: a pop sound that doesn't read as a blow-off valve on quiet fours (the sporty antique cut did on the GTI).
  - The user: "make cars that use the DSG fart sound just slightly louder and 100% of the time": the anti-lag now
    plays on every flat-out upshift (over 0.75 x redline) of a car with pops > 0, at full level (was 0.8-1 x),
    baked 1 dB hotter (`BANG_OVER_SHIFT_DB` 7, `BANG_UNDER_FLAT_OUT_DB` -2): ~+2 dB. Peaks limited up to 7.7 dB.
  - (popgen-6, generated, superseded.) Knobs (popgen.py top): bass `PUFF` / `PUFF_WIDTH`
    (wider = lower); buzz vs rattle `FIRE_CHANCE` / `CRACK_JITTER`; length `POP_SECONDS_RANGE`; top `CRACK_TOP`,
    `SIZZLE`, `RING`.
  - Not done from section 1: the limiter's pops following the limiter's own irregular cuts (needs item 6's new limiter).
- Next: items 3-6 need the new offline generator for the engine loops (not started). Its brief is sections 2.1-2.5;
  popgen.py's manifest reading / WAV writing / peak patching can be its start (same Python, same format).
- Also uncommitted in the working tree, from an earlier session (not this work): `engineLoudness` in cl_engine.lua
  (load lift and cylinder gain) and its CLAUDE.md note.

## The short version, most important first

1. **Pops are the wrong sound.** Each of our pop files is a 0.25-0.6 s *cluster* of 16-50 dull thumps with nothing
   above ~2 kHz (8 kHz is 57 dB down). A real pop is one sharp crack, bright to 12-16 kHz, gone in ~30-40 ms. Ours
   sit in the bass, where the engine is loudest, so they get buried (likely why the P1's stock pops can't be heard).
2. **Pop timing is too sparse and too long.** Real burbles are dense (6-11 cracks, 20-120 ms apart) and short
   (0.5 s on a blip, ~1.5 s in gear). Ours thin out over 1-3 s at 4-6 pops a second. The start delay is about right.
3. **Every engine loop is too dark.** On throttle our loops are 7-8 dB short at 1-2 kHz, 14 dB at 4 kHz and 21-22 dB
   at 8-16 kHz against the median of 31 recordings; at 4 kHz even our brightest quarter is under the recordings'
   darkest quarter. Off throttle it's 10-35 dB, and the 1-4 kHz part is a near pure tone.
4. **Too few harmonics.** Ours put nearly all the energy at the firing frequency and its multiples. Real engines
   have a dense comb at every half engine order, because no two cylinders fire alike. This is the clearest visible
   difference, and most likely the "synthetic / robotic" sound.
5. **The idle is frozen and repeats.** A real V12 idle wanders ~1.2% in pitch; ours 0.1%, and its 1.65 s loop shows
   as a level dip every 1.65 s.
6. **The limiter is a machine gun.** Ours: 6.7 identical cuts a second, 28 dB deep, the same in every bank. Real
   (one clip): ~14 cuts a second, irregular, 14 dB deep.
7. Smaller: the free-rev fall is too quick near idle (real engines ease in); engine types are more alike than real
   ones.

Items 1-2 can be done now (runtime timing in `cl_engine.lua` now; the pop WAVs with the generator, or by a small
pop-only bake). 3-6 are targets for the new generator. Section 4 lists the house rules these keep to.

---

## 1. Pops

### How they happen (research)

An overrun pop is fuel burning in the exhaust instead of the cylinder. On a closed throttle a normal ECU cuts the fuel
(overrun fuel cut), so a stock car is silent. Cars that crackle, from the factory (Jaguar F-Type, AMG, Hyundai N, VAG
sport modes) or with a "pops and bangs" map, keep some fuel going for a moment after the lift and retard the ignition
far past top dead centre. The charge is still burning when the exhaust valve opens and finishes in the hot header: a
crack per misfiring cycle, with "a specifically targeted, very lean misfire once you lift off the throttle". Tuners
gate it by rpm (one example starts the map from 3000 rpm), by load (closed throttle, low manifold pressure) and by
time: "usually only for a few seconds after you let off", one map using a 1.0 s timer before the fuel cut comes back.
Some throttle in the cylinder is needed ("at fully closed throttle there may not be enough air for a burble"), and a
catalytic converter takes some of the edge off. Back on the throttle, or the revs falling to the fuel-cut recovery
point (~1400-2200 rpm in the Link ECU example), ends it.

Sources: [HP Academy, factory style overrun crackle](https://www.hpacademy.com/forum/general-tuning-discussion/show/factory-style-overrun-crackle/),
[HP Academy, pop and bang tuning](https://www.hpacademy.com/forum/general-tuning-discussion/show/pop-and-bang-tuning/),
[Link ECU forum, overrun timing control](https://forums.linkecu.com/topic/8480-overrun-timing-control/),
[The Drive, why your burble tune is bad](https://www.thedrive.com/guides-and-gear/why-your-burble-tune-is-bad),
[Jalopnik, snap-crackle-pop exhausts](https://jalopnik.com/how-snap-crackle-pop-exhaust-sounds-actually-help-or-h-1839378308/amp),
[Wikipedia, backfire](https://en.wikipedia.org/wiki/Backfire_(engine)). Forum material: practical experience, not
measurements. The numbers below come from the recordings.

### When they happen (measured)

A lift = a peak in the clip's level (the throttle snapping shut at the top of a rev); pops = 1-10 kHz transients over
14 dB above the engine's own treble.

| Recording | Lifts that popped | Pops per lift | First pop after the lift | Last pop | Gap between pops |
|---|---|---|---|---|---|
| Jaguar F-Type SVR, factory crackle, driving | 19 of 21 | 9 | +0.07 s (p10 -0.08, p90 +0.34) | burble 1.45 s (p90 2.8 s) | median 85 ms (p10 22 ms) |
| Audi R8 V10, standing blips | 17 of 20 | 6 (up to 11) | +0.29 s (p10 +0.10, p90 +0.35) | +0.8 s | median 57 ms (p10 23, p90 151) |
| Mercedes C63, iPE valve exhaust | 11 of 23 | 1 | irregular | lone pops | median 226 ms |
| Mercedes S63 / BMW M3 (V8) | | | | | median 102 / 119 ms |
| Crackle-map car, street pass-by | | | | | 130-150 ms, then a lone louder one 0.6 s later |
| AMG SLS | 2 of 3 | | the big one at the top of a blip | | 211 ms |

What that means:
- **Pops come in a dense burst, not a slow trickle.** Gaps are 20-120 ms, often in pairs or triples 20-60 ms apart.
  The rate doesn't thin out as the burble goes on: on the R8 the cracks are spread evenly from +0.3 to +0.8 s, then
  stop abruptly once the revs are back down (level about 25 dB under the peak, near idle).
- **The window is short on a blip and longer in gear.** Free-revving, the revs crash in under a second and take the
  pops with them (0.5 s of burble). Driving, the revs fall slowly and the F-Type crackles for ~1.5 s, sometimes ~3 s.
- **How crackly a car is decides how often a lift pops at all:** ~90% for the F-Type and R8, half for the C63,
  and the C63's are lone pops.
- A louder lone pop often closes the burble (the R8's at +0.57 s, the pass-by car's 0.6 s after its cluster).
- The first pop's timing depends on the car: immediate on the factory-crackle Jaguar, ~0.3 s on the R8.

### What a pop sounds like (measured)

|  | Real pops (R8, F-Type, C63, S63, M3, Mustang, crackle car) | Our pop1-5 / bang1-3 |
|---|---|---|
| Shape | one crack: rise under ~2 ms, -10 dB in 3-6 ms, -20 dB in 15-45 ms (median ~30-40 ms), then the exhaust's ring | 244-617 ms each, 16-51 peaks inside (a cluster per file); pop3/pop5 peak 84-91 ms in |
| Spectrum, first 25 ms (dB under the loudest octave) at 2k / 4k / 8k / 16k | -3..-24 / -1..-30 / -9..-40 / -21..-53 | -9..-21 / -27..-39 / -51..-63 / -79..-88 |
| Variation between cars | V8s and the C63 carry more 63-250 Hz body; four-cylinders and turbos are thinner and brighter | the same five files in every bank (timing identical, spectra within 1-2 dB) |
| Over the engine at that moment | 14-20 dB over the engine's 1-10 kHz band (median per clip) | in the band where the engine is loudest |

An older note in CLAUDE.md says a 0.4 ms click "sounded like firecrackers" and a ~1 ms thump with muffler scatter
(140-190 Hz body) worked. That fits these measurements: the crack wants the brightness *and* a body and ring. A bare
click has neither, and without an engine under it, it pokes out. What went too far was the low-pass: the treble went
with the click.

### Suggested runtime changes (`cl_engine.lua`, possible today)

The current code (around `cl_engine.lua:849-897`) starts a burble on lift-off above half redline, waits 0.12-0.3 s,
then plays pops with the intensity falling as `(1 - age)^1.5` over `(0.8 + 2.2 x pops) x (0.5 + 0.5 x highRevShare)`
seconds, gaps either 50-130 ms or `(0.15-0.65 s) / (0.3 + 1.5 x intensity x pops)`.

Suggested (P = the car's `pops` frequency):
- **Whether a lift pops:** chance ~ `0.3 + 0.65 x P` (P 0.7 ≈ 75-90%, like the F-Type/R8; P 0.3 ≈ half, like the C63).
  Low P cars get one or two lone pops instead of a burst.
- **Start:** 0.03-0.12 s after the lift for P ≥ 0.6 (factory-crackle style), 0.2-0.35 s otherwise (as now).
- **Rhythm:** bursts of 2-4 cracks 20-60 ms apart, bursts 80-250 ms apart, about 6 + 10 x P cracks a second.
  Steady over the window (no `^1.5` thinning), easing off only in the last ~30%.
- **Window:** in gear `0.5 + 2 x P` s; free-revving or in neutral it ends when the revs fall under
  `max(1.6 x idle, 0.55 x lift rpm)`. Keep the 0.35 x redline floor and back-on-throttle cancelling.
- **Level:** each crack random over ~6 dB; now and then a louder lone one (a bang) 0.3-0.7 s in, closing the burble.
  The current `pops^2` for big events stays sensible.
- **Upshift crack and limiter pops:** keep. Limiter pops should follow the limiter's own irregular cuts (section 2.5).

Patch use: a pop takes one of the existing pop/bang names, as now. Denser cracks mean more one-shots, but each lives
~150 ms instead of ~500 ms, so overlapping patches stay about the same. Keep the existing rule of never playing
the same name twice in a row.

### Suggested new pop sounds (for the generator, or a pop-only bake)

Same files (`pop1-5`, `bang1-3`, same names and count: no new patches); the burst rhythm moves to runtime, so
**each file is one event**:
- pop: a ~1-2 ms crack (broadband, flat-ish to 4 kHz, -10..-30 dB at 8 kHz, -20..-40 dB at 16 kHz) on a short body
  (a decaying 120-500 Hz burst, the header pipe's resonance), then a muffler/tailpipe ring and scatter,
  -40 dB by ~150 ms. Total file ≤ 0.2 s.
- bang: the same with more body (63-250 Hz), a slower ring (-20 dB at ~60-80 ms), ≤ 0.35 s.
- per engine: body pitch from the exhaust (V8/V10/V12 lower and fuller, I4/I5/turbo smaller and brighter, the
  turbo's housing taking some top off), and each of the five a little different (crack strength, body pitch ±15%,
  ring length) so a burst doesn't sound like one sample repeated.
- level: baked so that at `popVolume` a pop stands ~15 dB over the engine's 2-8 kHz band at mid revs. Re-check
  `popPeakLoad` / headroom once the treble is there: a bright pop has less peak per loudness than the current boom.

Check against the targets with `dev/sound_research/popoct.py ours <files>` and `popmeasure.py`.

---

## 2. Engine loops

Measured on all 42 banks' band loops between 35% and 95% of redline (on and off throttle) and on 31 usable
recordings (loud parts, pops cut out). Octave levels are relative to the 125-500 Hz average.

### 2.1 Brightness

| | 1 kHz | 2 kHz | 4 kHz | 8 kHz | 16 kHz | Spectral flatness 1-4 kHz |
|---|---|---|---|---|---|---|
| Recordings, median (25-75%) | -6 (-9..-2) | -9 (-14..-4) | -13 (-18..-9) | -20 (-27..-11) | -29 (-38..-21) | 0.45 |
| Ours, on throttle | -13 (-14..-10) | -17 (-18..-15) | -27 (-30..-25) | -42 (-43..-39) | -50 (-52..-48) | 0.32 |
| Ours, off throttle | -16 (-20..-13) | -28 (-32..-24) | -39 (-43..-37) | -55 (-58..-54) | -60 (-61..-59) | **0.08** |

Per preset (median of its recordings vs its own bank, on throttle; one to four recordings each, so indicative):

| Preset | Recordings | Real 4k / 8k | Ours 4k / 8k | Short by at 4k / 8k |
|---|---|---|---|---|
| v12na | Aventador SV, F12, F456, Lamborghini | -9 / -14 | -21 / -37 | 12 / 23 |
| v12t | DB11, Continental GT (a W12) | -18 / -25 | -23 / -40 | 5 / 15 |
| v10 | Gallardo | -14 / -22 | -23 / -37 | 9 / 15 |
| v8flat | Ferrari 360 | -5 / -10 | -23 / -38 | 17 / 28 |
| v8s | BMW M3 | -8 / -10 | -25 / -40 | 17 / 30 |
| v8m | open-header V8s, hot rod, muscle idle | -13 / -15 | -28 / -45 | 14 / 29 |
| v8p | Mustang GT S550, C6 Corvette, V8 rev | -18 / -25 | -26 / -43 | 8 / 18 |
| v8x | Silverado 5.3 | -13 / -19 | -28 / -42 | 15 / 23 |
| v8xt | S63 AMG | -19 / -35 | -32 / -45 | 13 / 10 |
| v8r | Caprice | -11 / -26 | -34 / -45 | 23 / 19 |
| v6 | Vitara V6 | -16 / -26 | -27 / -41 | 11 / 16 |
| v6odd | DeLorean (two) | -18 / -23 | -29 / -43 | 11 / 20 |
| f6 | 911, GT3 Cup idle | -25 / -28 | -21 / -36 | -3 / 9 |
| i6 | inline six | -21 / -27 | -30 / -41 | 9 / 13 |
| i4 | Civic | -1 / -7 | -19 / -35 | 18 / 29 |
| i4t | Peugeot 3008 GT, dyno turbo | -9 / -14 | -29 / -42 | 20 / 28 |
| i4s | S2000 | -23 / -28 | -25 / -39 | 2 / 11 |
| f4air | Beetle (two) | -8 / -11 | -31 / -44 | 23 / 33 |
| boxer | WRX, STI idle, Impreza | -32 / -37 | -26 / -42 | -6 / 5 |
| r2 | rotary | -9 / -28 | -25 / -41 | 16 / 14 |

The two exceptions (boxer, flat-six at 4 kHz) are both idle recordings with muffled microphones. Some of the
difference is how the recordings were made (phone/camera mics close to the tailpipe, YouTube compression), but
distance takes treble away, not adds it, so the gap is real. It matches the earlier verdicts in CLAUDE.md
("not crisp enough", real engines are rev-locked harmonics above ~1 kHz).

**Suggested:** bake the loops to the recordings' curve (on throttle within ~3-5 dB of the median row, per preset
the table's direction), as **rev-locked harmonics continuing up to 8-10 kHz** (see 2.2) with some broadband
combustion noise riding on them, not as added hiss (the old synth's hiss was the "vacuum cleaner"). Intake,
valvetrain and gear whine stay faint as the user asked; the missing top is the exhaust's own harmonics.

### 2.2 Harmonic structure: the biggest audible difference

Spectrograms, same scale (see `dev/sound_research/spec.py`):
- **Ferrari 456 V12 idle (real):** lines every ~25 Hz (every half engine order) from 50 to 400+ Hz, of similar
  strength, all wandering together.
- **Our v12na idle (`b1on`):** three strong lines (≈107, 214, 428 Hz: the firing frequency and its multiples) with
  only faint ones between.
- **Real Audi R8 at a held 1500 rpm:** sharp, dense lines up to 5-6 kHz. **Our R8 V10 drive:** widely spaced lines
  (firing orders) fading into noise above ~2.5-3 kHz.

Why: in a real engine no two cylinders are alike (charge, timing, runner and header length, the order the pulses reach
the collector), and each cylinder fires once every two turns. That puts energy at every half order of the crank, not
only at multiples of the firing frequency. Our loops sound like an ideal engine with identical cylinders: a buzzy,
"synth" timbre. The old synth's single random seed per engine ("too similar, robotic") is the same complaint.

**Suggested (generator):** model each cylinder's pulse separately with fixed per-engine differences (amplitude
±10-25%, timing ±1-3% of a firing interval, a slightly different pulse shape per bank), plus small cycle-to-cycle
variation (≈0.5-1% timing, a few % amplitude). Firing order and bank pipe lengths put the half orders where they belong
for each layout (crossplane V8 burble, odd-fire V6, flat-plane V8 and I4 smoothness). Target: half-order lines within
~3-10 dB of the firing orders between 300 Hz and 3 kHz. (`dev/sound_research/orders.py` measures this on our loops
at their known rpm. Its rpm finder isn't reliable on the YouTube clips, so check the recordings by eye on a
spectrogram.)

### 2.3 Off throttle

Off-throttle loops are another 3-13 dB darker than our on-throttle ones above 1 kHz (10-35 dB under the recordings),
and their 1-4 kHz band is almost a pure tone (flatness 0.08 against 0.45 real). Coasting and blipping down then
sound like a muffled hum with a whistle on top. A real engine on overrun is quieter and duller, but keeps its harmonic
comb and a rough, crackly edge (on the R8's falls the harmonics stay visible to ~2.5 kHz with noise between them).
**Suggested:** off loops follow the brighter on loops at roughly the same 3-13 dB under, with irregular combustion
(misfires on a lean overrun) instead of a clean tone. Not measured on the recordings separately (their overrun parts
are full of pops); listen once the generator has it.

### 2.4 Idle

| | Slow pitch drift (sd) | Fast jitter (sd) | Spread (p5..p95) |
|---|---|---|---|
| Ferrari 456 V12, two harmonics | 1.1-1.3% | 0.4-0.6% | -3.0%..+2.0% |
| Our v12na idle loop | 0.11% | 0.41% | -0.6%..+0.9% |
| Our v8m idle loop | 0.9% | 1.9% | -2.0%..+2.9% |

(The other recordings' idles couldn't be tracked cleanly: their lines are too close together.) Every idle loop is
~1.65-1.7 s long, so a parked car repeats a recognisable pattern every 1.65 s, visible as a level dip.
Nothing at runtime moves the idle (only the fixed ±1.5% `detune` per car), and Source pitch moves in whole percent,
so a 1% drift can't be played through `ChangePitch` smoothly.

**Suggested (generator):** bake a slow wander (~1-1.5%, a few seconds per swing) and ~0.5% jitter into the lowest
one or two bands, and make those loops longer (4-6 s). Cost: about 0.4 MB per bank and band for 4 s at 44.1 kHz 16-bit
on+off, ~18 MB for b1 across 44 banks, against the 189 MB now. Or bake the wander with periods that fit the loop
whole, as the siren does (seamless, but it still repeats).

### 2.5 Rev limiter

| | Cuts a second | Level swing (p10-p90) | How regular (autocorrelation at the period) |
|---|---|---|---|
| Subaru launch limiter (real) | ~14 | 14 dB | 0.37 (irregular) |
| Our `lim.wav` (boxer, v8m, same in every bank) | 6.7 | 28 dB | 0.78 (regular) |

One recording, and launch control (two-step) rather than a redline limiter, so treat the numbers as a direction.
**Suggested (generator):** faster, shallower, irregular cuts (interval jitter ±30%), per engine, with the pop car's
crackle on the cuts. At runtime the limiter loop's pitch already follows `config.redline / bank.limiter.rpm`.

### 2.6 Free-rev response

Real blips (R8, F456): idle to ~3000 rpm in ~0.5 s, falling ~0.9-1 octave a second, slowing as it nears idle.
`Drivetrain.FreeSpinRate` falls at `fall x (0.05 + 0.12 x rpm/redline)`, nearly straight: for the R8 ~3400 rpm/s at
6000 and ~2000 rpm/s at 2000, where the real R8 does ~2500 at 4000 but only ~1250 near 2000. Small: the user tuned
`Drivetrain.REV`, so try easing the fall near idle (e.g. scale by `(rpm - idle) / (0.3 x redline)` under that band)
only by ear.

### 2.7 How alike the engines are

At 4 kHz our banks' on-throttle levels span -34..-19 dB with half of them within -30..-25; the recordings span
-32..-1 with half within -18..-9. Some of that spread is the microphones, but the per-preset table shows real
engines differing far more in their top end than ours (flat-plane V8, M3 V8, Civic, Beetle bright; S63, idle boxer
dull). Give the generator's per-preset voice the top end, not only the low formants (`character.f1/f2/f3`).

---

## 3. Per engine type: what we had to go on

| Preset(s) | Recordings used | Notes |
|---|---|---|
| v12na, v12r, sl65 | F456 sweep (close-miked, the best reference here), Aventador SV, F12, Lamborghini idle/rev | v12na 12 / 23 dB dark at 4k / 8k; idle comb and drift (2.2, 2.4) |
| v12t, w16 | DB11, Bentley Continental GT (W12) | Chiron recording found, not downloaded (rate limit) |
| v10, v10l | Gallardo, Audi R8 (revs and pops) | R8 = the pop timing reference; Viper GTS found, not downloaded |
| v8flat, v8h | Ferrari 360 | 458 Speciale / F430 / P1 found, not downloaded |
| v8m, v8p, v8x, v8xt, v8r, v8s | open-header V8s, hot rod, muscle idle, Mustang GT, C6, Silverado, S63, Caprice, M3 | all 8-23 dB dark at 4k |
| v6, v6odd, v6t | Vitara V6, two DeLorean PRV | Kia Stinger GT (v6t) not downloaded |
| f6 | 911, GT3 Cup idle | close at 4k, 9 dB dark at 8k |
| i6, i6t | inline six | Supra A80 / 335i not downloaded |
| i5t | none | TT RS / RS3 found, not downloaded |
| i4, i4s, i4t, i4st | Civic, S2000, 3008 GT, dyno turbo | i4/i4t 18-20 dB dark at 4k |
| f4air, boxer, f4 | two Beetles, WRX, STI idle, Impreza launch limiter | Beetle 23 dB dark; boxer refs muffled; BRZ not downloaded |
| r2, r2t, r3 | one rotary clip | RX-8 / RX-7 found, not downloaded; no 3-rotor anywhere |
| i3, i4q, i4w, i4h, ev, f12 | none | no usable recording found |
| pops | F-Type SVR, R8, C63 iPE, AMG SLS, S63, M3, crackle-map pass-by, anti-lag, rally | section 1 |

`dev/sound_research/commons_engine_clips.tsv` lists 443 CC BY "engine and exhaust sound" recordings on Wikimedia
Commons (car, length, file page): most PERP cars have one. Commons rate-limits downloads heavily (HTTP 429 after a
few files); fetch them slowly.

## 4. House rules these suggestions keep

- No more sound patches per car than now, no new layers: all changes are inside existing files (bands, `lim`,
  `pop1-5`, `bang1-3`) or in runtime timing. Longer idle loops are the same patches.
- Every current sound stays.
- Pops get redone (agreed); nothing here is a cap on overlapping pops.
- Synthesized, not recorded: the recordings are targets to measure against.
- engine-sim and DasEtwas/enginesound stay off the table.

## 5. Limits of this analysis

- The recordings are YouTube uploads (Commons, Opus ~64-120 kbps) and Freesound previews (MP3 128 kbps): microphone,
  distance, wind and compression vary. Only medians over many clips and differences of 10 dB or more are leaned on
  above.
- rpm can't be tracked reliably on these clips (octave jumps), so nothing above depends on knowing their rpm except
  the F456 idle (two harmonics agreeing).
- Pop detection counts 1-10 kHz transients 12-14 dB over a 0.2 s running median: a gear clunk or a door would count
  too. The per-lift tables were checked against the spectrograms (R8, SLS, crackle car, F-Type).
- The limiter numbers come from one launch-control clip.
- Wikimedia stopped serving files after nine (HTTP 429), so several types rest on one or two Freesound clips, and
  some have none (section 3).
- Nothing here has been heard in game.

## 6. Tools (`dev/sound_research/`)

Python 3 with `numpy scipy soundfile imageio-ffmpeg matplotlib` (ffmpeg comes with imageio-ffmpeg; it decodes the
Opus/MP3 references). Run them on copies outside the addon folder: they only read.

| Script | What it does |
|---|---|
| `spec.py <file> <out.png> [t0] [t1\|-] [fmax] [title] [nfft]` | spectrogram + broadband / 1-8 kHz level |
| `popmeasure.py <files>` | pops: count, rise over the engine, attack, decay to -10 / -20 dB, gaps |
| `popoct.py ref <files>` / `popoct.py ours <wavs>` | pop octave spectra: over the engine (refs), shape (ours) |
| `timbre.py ref <out.json> <files>` / `timbre.py ours <out.json> <addon root>` | octave shape, flatness, pulsing |
| `orders.py <file> <cylinders> <t0> <t1> [rpm]` | firing vs half orders, line sharpness (give the rpm) |

## Sources

Wikimedia Commons (CC BY, from YouTube; "RevGuessr" uploads):
[Lamborghini Aventador SV](https://commons.wikimedia.org/wiki/File:Lamborghini_Aventador_SV_-_engine_and_exhaust_sound_(YouTube_qll6WBfaXvM).opus),
[Ferrari F12](https://commons.wikimedia.org/wiki/File:Ferrari_F12_-_engine_and_exhaust_sound_(YouTube_JNvonF5LGYQ).opus),
[Aston Martin DB11](https://commons.wikimedia.org/wiki/File:Aston_Martin_DB11_-_engine_and_exhaust_sound_(YouTube_w8H8cAKQeeU).opus),
[Bentley Continental GT](https://commons.wikimedia.org/wiki/File:Bentley_Continental_GT_-_engine_and_exhaust_sound_(YouTube_-bw4NjaboM4).opus),
[Ford Mustang GT (S550)](https://commons.wikimedia.org/wiki/File:Ford_Mustang_GT_(S550)_-_engine_and_exhaust_sound_(YouTube_2ceiDjGgpI8).opus),
[Honda S2000](https://commons.wikimedia.org/wiki/File:Honda_S2000_-_engine_and_exhaust_sound_(YouTube_aTd8viYxxnU).opus),
[Mercedes-Benz C63 with iPE exhaust](https://commons.wikimedia.org/wiki/File:Mercedes-Benz_C63_with_iPE_exhaust_-_engine_and_exhaust_sound_(YouTube_Y94HruXpYRY).opus),
[Jaguar F-Type SVR](https://commons.wikimedia.org/wiki/File:Jaguar_F-Type_SVR_-_engine_and_exhaust_sound_(YouTube_1aYpunE9cHo).opus),
[Chevrolet Chevelle](https://commons.wikimedia.org/wiki/File:Chevrolet_Chevelle_-_engine_and_exhaust_sound_(YouTube_i8AoOUTIMIk).opus)
(left out of the averages: band-limited at 4 kHz).

Freesound (licence per clip):
[Audi R8 idling, revving, backfire](https://freesound.org/s/457733/) (Jonas_Jocys, CC BY 4.0),
[afterfire crackle-tune pass-by](https://freesound.org/s/873008/) (klankbeeld, CC BY 4.0),
[AMG SLS start, rev, backfire](https://freesound.org/s/789670/) (whillsway, CC BY),
[car anti-lag](https://freesound.org/s/797835/) (modusmogulus, CC0),
[Ferrari 456 V12 sweep](https://freesound.org/s/18771/) (djbono, Sampling+),
[Lamborghini idle and rev](https://freesound.org/s/112075/) (cheesepuff, CC0),
[Lamborghini Gallardo](https://freesound.org/s/222607/) (beansqueso31, CC BY),
[Ferrari 360 Spider](https://freesound.org/s/241083/) (PritzProductions, CC0),
[open-header V8s](https://freesound.org/s/432508/) (holderall, CC0),
[hot-rod V8](https://freesound.org/s/144454/) (Ears68, CC BY 3.0),
[muscle car idle](https://freesound.org/s/486338/) (Scott_Snailham, CC BY),
[V8 rev](https://freesound.org/s/651534/) (overmedium, CC0),
[big-cam C6 Corvette](https://freesound.org/s/712593/) (Angel_soto, CC0),
[Silverado 5.3](https://freesound.org/s/610776/) (Therancher01, CC0),
[S63 AMG V8 revs](https://freesound.org/s/505321/) (marcelweiss, CC0),
[BMW M3](https://freesound.org/s/415276/) (ikbenraar, CC BY 4.0),
[Chevrolet Caprice](https://freesound.org/s/391671/) (romanholtwick, CC0),
[Vitara V6](https://freesound.org/s/249720/) (Keith Selmes, CC BY 4.0),
[DeLorean rev and climb](https://freesound.org/s/146188/) (sndadv, CC BY),
[DeLorean PRV V6](https://freesound.org/s/623436/) (SkyernAklea, CC BY 4.0),
[Porsche 911](https://freesound.org/s/55727/) (mharo, CC0),
[911 GT3 Cup ticking over](https://freesound.org/s/570258/) (FritzSounds, CC BY),
[inline six](https://freesound.org/s/466715/) (dudebrobrodude, CC0),
[Honda Civic](https://freesound.org/s/692112/) (MPooman, CC0),
[Peugeot 3008 GT](https://freesound.org/s/865222/) (Mihacappy, CC0),
[turbo car on a dyno](https://freesound.org/s/496171/) (editboy23, CC0),
[VW Beetle 1961](https://freesound.org/s/544344/) (klankbeeld, CC BY),
[VW Beetle idle](https://freesound.org/s/527731/) (charlie72203, CC BY 4.0),
[WRX exhaust](https://freesound.org/s/273334/) (ulose2piranha, CC0),
[Impreza launch limiter](https://freesound.org/s/369797/) (t33kno, CC0),
[Impreza STI idle](https://freesound.org/s/625702/) (MilanKovanda, CC BY 4.0),
[rotary engine](https://freesound.org/s/100791/) (Fuser10, Sampling+),
[rally car revving](https://freesound.org/s/449893/) (Debsound, CC BY),
[rally car pass](https://freesound.org/s/377133/) (jaromarsalek, CC0).
