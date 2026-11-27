# Recorded pops

The pops and bangs every engine bank ships (`popgen.py`'s default; `--synth` renders the generated ones
instead). Picked by ear by the user on 2026-11-27, after six generated versions missed. Cut from CC0
recordings on Freesound (no attribution required), then bass added and the 1-5 kHz "chuff" cut (the user:
the first install sounded "more like exhaust or valve than an actual pop" and lacked a pop's bass).

| File | Used as | Source | Cut at |
|---|---|---|---|
| `antique_2_thumpH_cutkickH.wav` | pop1-5 of sporty engines ("for more sporty cars") | [R03-12-Antique Auto Sputter and Backfire](https://freesound.org/s/481663/) by craigsmith, CC0 | 23.28 s, 178 ms |
| `antique_3_both_cutkickD.wav` | pop1-5 of bassy engines (`BASSY_LAYOUTS`: "for sporty bassy cars") | same recording | 21.16 s, 193 ms |
| `antilag_3_both_cutkickL.wav` | bang1-3, played on a flat-out upshift ("the antilag when shifting") | [Car Antilag (No cleanup, 32float)](https://freesound.org/s/797835/) by modusmogulus, CC0 | 1.77 s, 108 ms |

Processing (scratchpad scripts `cut_pops.py`, `bassup.py`, `punch.py`, not in the repo), in order:
- cut from the Freesound HQ preview (MP3): 8 ms before the burst to 90 ms after, 35 Hz high-pass, peak 0.9
- bass: `thumpH` = a 6.5 ms exhaust puff (push + suction) under every crack, at 1.2x, + an 85 Hz thump at
  the first crack; `both` = the same at 0.8x + a +6 dB low shelf under 180 Hz
- `cut` = -7 dB peaking at 2.5 kHz (Q 0.7) and -3 dB at 1.2 kHz (Q 0.9)
- `kick` = a sine swept down at the onset: `kickH` 130 -> 55 Hz in 12 ms, decaying in 60 ms, at 1.1x;
  `kickD` 100 -> 45 Hz, 90 ms, 1.1x; `kickL` 130 -> 55 Hz, 60 ms, 0.6x

44.1 kHz mono 16-bit, peak 0.9. `popgen.py` writes pop1-5 at pitch 0.96-1.04 and bang1-3 at 0.97-1.03
("switch them up and down in pitch slightly, not a lot"), levels them against each bank's engine loop and
then takes `RECORDED_LEVEL_DB` (-4 dB: "maybe they're too loud") off.
