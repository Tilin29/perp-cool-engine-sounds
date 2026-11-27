"""
Overrun pops and bangs for every baked engine bank: a pop-only bake (SOUND_IMPROVEMENTS.md, section 1).

Each file is ONE burst (the bursts' rhythm is played at runtime by cl_engine.lua): a train of
cracks at the exhaust pulse rate (render_event), as a real burble's pops are; a lone crack sounded
like popcorn (the user, popgen-1). Each crack (render_crack):
  pop1-5   a sharp pulse + sizzle on a short body (the header pipe's 120-450 Hz resonance), pipe
           reflections and a muffler / tailpipe ring with scatter; 0.08-0.2 s of pulses
  bang1-3  the same with more low body (60-110 Hz), a longer ring and one stronger crack; 0.18-0.32 s
Same names and count as the old cluster files, so no new sound patches. Per engine: the body pitch
and fullness from the layout (big V8/V12 low and full, fours and rotaries small and bright), turbos
with some top taken off by the turbine housing, and each of the five a little different.

Level (measured on the recordings, SOUND_IMPROVEMENTS.md progress notes): a real pop's first 25 ms is
about as loud, full band, as the engine around it; it stands out by its treble. So each bank's pops
are baked so their first 25 ms at cl_engine's playback (popVolume 0.7 x the crack's runtime level)
sit POP_OVER_ENGINE_DB over the bank's on-throttle loop at ~60% of redline as cl_engine plays it
(band trim and cylinder gain included), bangs BANG_OVER_ENGINE_DB; capped at PEAK_CAP.

  python popgen.py <addon root> --preview <folder>   render to <folder>/<bank dir>/ and print the measurements
  python popgen.py <addon root> --write              write into sound/audio_engine/<dir>/ and the peaks into cl_baked.lua
  --only <dir prefix>[,<dir prefix>...]              just these banks

Needs numpy and scipy. Deterministic: the random seeds come from the bank's folder name.
Files are written as a new file + rename (never in place), cl_baked.lua in binary with LF line endings.
"""
import os, re, sys, wave, zlib
import numpy as np
from scipy import signal

GENERATOR_VERSION = "popgen-6"
SR = 44100
POP_COUNT, BANG_COUNT = 5, 3
POP_SECONDS, BANG_SECONDS = 0.4, 0.5
# a burst (render_event): exhaust pulses at OVERRUN_SHARE x redline (x 0.8-1.2 per file), filling a burst of
# POP_SECONDS_RANGE / BANG_SECONDS_RANGE; each after the first fires with FIRE_CHANCE, timing +-CRACK_JITTER
OVERRUN_SHARE = 0.5
POP_SECONDS_RANGE, BANG_SECONDS_RANGE = (0.1, 0.2), (0.18, 0.3)
# nearly every pulse fires, evenly timed: a pitched, buzzy blat like a DSG upshift "fart" (the user; popgen-5 skipped
# 40% and jittered 15%, a broken rattle); the uneven levels are its rasp. PITCH_DROP: the pulses slow by this
# much over the burst, the revs falling
FIRE_CHANCE, CRACK_JITTER, PITCH_DROP = 0.93, 0.05, 0.15
# the burst's levels: the opening thump ("B"), the rattle between ("R-A", falling 30% over it), the closing crack ("P")
B_LEVEL, RATTLE_LEVEL, P_LEVEL = 1.0, 0.85, 0.8
TRAIN_RING = 0.6              # each crack's ring shorter in a train (they overlap)
PLAYBACK_GAIN = 0.7            # cl_engine: popVolume = ... x 0.7
RUNTIME_LEVEL = 0.8            # the burble's average per-crack level (cl_engine plays them at 0.55..1)
POP_OVER_ENGINE_DB = 1.0
BANG_OVER_ENGINE_DB = 5.0
PEAK_CAP = 0.95
# the event's parts (render_event): the crack's pulse and sizzle, the pipe body, the muffler ring, the low thump
PULSE, SIZZLE, BODY, RING, THUMP_POP, THUMP_BANG = 0.9, 0.15, 1.6, 0.2, 0.5, 0.7
# the crack's top (Hz, lowpass, 3rd order): summed in a train, brighter crinkled like tin foil (the user, popgen-2)
CRACK_TOP, CRACK_TOP_TURBO = 3000, 2200
RING_TOP = 6500
# the exhaust pulse under each crack (render_crack's puff): level and width (s)
PUFF, PUFF_WIDTH = 2.6, 0.0062
BODY_PITCH = 0.8             # x the layout's body Hz (VOICES)
# cl_engine's CYLINDER_GAIN_DB (engineLoudness): the loops play this much louder
CYLINDER_GAIN_DB = {5: 0.5, 6: 1, 8: 2, 10: 2.5, 12: 3, 16: 3.5}

# per layout (the bank folder's prefix): body Hz, fullness (low body share), brightness (crack share), ring (x)
VOICES = {
    "v8m":    dict(body=150, full=1.25, bright=0.95, ring=1.15),
    "v8x":    dict(body=145, full=1.25, bright=0.85, ring=1.1),
    "v8p":    dict(body=165, full=1.15, bright=1.0, ring=1.05),
    "v8r":    dict(body=160, full=1.1, bright=0.85, ring=1.0),
    "v8s":    dict(body=185, full=1.05, bright=1.1, ring=1.0),
    "v8xt":   dict(body=170, full=1.15, bright=0.9, ring=1.05),
    "v8flat": dict(body=230, full=0.9, bright=1.2, ring=0.9),
    "v8h":    dict(body=225, full=0.9, bright=1.15, ring=0.9),
    "v10l":   dict(body=150, full=1.2, bright=0.95, ring=1.1),
    "v10":    dict(body=210, full=1.0, bright=1.15, ring=0.95),
    "v12r":   dict(body=160, full=1.15, bright=0.95, ring=1.1),
    "v12na":  dict(body=215, full=1.0, bright=1.15, ring=0.95),
    "v12t":   dict(body=185, full=1.05, bright=0.95, ring=1.0),
    "sl65":   dict(body=175, full=1.1, bright=0.95, ring=1.05),
    "w16":    dict(body=165, full=1.15, bright=0.9, ring=1.05),
    "f12":    dict(body=220, full=0.95, bright=1.1, ring=0.95),
    "v6":     dict(body=250, full=0.95, bright=1.05, ring=0.95),
    "v6t":    dict(body=240, full=0.95, bright=0.95, ring=0.95),
    "v6odd":  dict(body=230, full=1.0, bright=0.95, ring=1.0),
    "i6":     dict(body=255, full=0.95, bright=1.0, ring=0.95),
    "i6t":    dict(body=250, full=0.95, bright=0.95, ring=0.95),
    "f6":     dict(body=270, full=0.9, bright=1.15, ring=0.9),
    "i5t":    dict(body=265, full=0.9, bright=1.0, ring=0.95),
    "i4":     dict(body=320, full=0.8, bright=1.1, ring=0.85),
    "i4s":    dict(body=340, full=0.75, bright=1.2, ring=0.85),
    "i4t":    dict(body=300, full=0.8, bright=1.0, ring=0.9),
    "i4st":   dict(body=310, full=0.8, bright=1.05, ring=0.9),
    "i4w":    dict(body=300, full=0.8, bright=0.9, ring=0.85),
    "i4q":    dict(body=310, full=0.7, bright=0.8, ring=0.8),
    "i4h":    dict(body=320, full=0.7, bright=0.8, ring=0.8),
    "i3":     dict(body=330, full=0.75, bright=0.95, ring=0.85),
    "f4":     dict(body=290, full=0.85, bright=1.05, ring=0.9),
    "f4air":  dict(body=260, full=0.85, bright=0.85, ring=1.0),
    "boxer":  dict(body=275, full=0.9, bright=0.95, ring=0.95),
    "r2":     dict(body=380, full=0.7, bright=1.3, ring=0.8),
    "r2t":    dict(body=360, full=0.75, bright=1.15, ring=0.85),
    "r3":     dict(body=360, full=0.75, bright=1.3, ring=0.85),
}
TURBO_LAYOUTS = {"v8xt", "v12t", "sl65", "w16", "v6t", "i6t", "i5t", "i4t", "i4st", "boxer", "r2t"}


# --------------------------------------------------------------------------- small DSP helpers
def butter(x, kind, fc, order=2):
    b, a = signal.butter(order, fc, kind, fs=SR)
    return signal.lfilter(b, a, x)

def resonator(x, f, q):
    """band pass with peak gain 1 (RBJ cookbook, constant 0 dB peak)"""
    w0 = 2 * np.pi * f / SR
    alpha = np.sin(w0) / (2 * q)
    b0, b1, b2 = alpha, 0.0, -alpha
    a0, a1, a2 = 1 + alpha, -2 * np.cos(w0), 1 - alpha
    return signal.lfilter([b0 / a0, b1 / a0, b2 / a0], [1, a1 / a0, a2 / a0], x)

def delayed(x, seconds, length):
    out = np.zeros(length)
    start = int(round(seconds * SR))
    if start < length:
        part = x[:length - start]
        out[start:start + len(part)] = part
    return out


# --------------------------------------------------------------------------- one event: a burst
def pulses_per_second(prefix, cylinders, rpm):
    """exhaust pulses a second reaching one tailpipe: a V / flat / W engine has a pipe per bank"""
    if prefix.startswith("r"):
        return rpm / 60 * {"r2": 2, "r2t": 2, "r3": 3}[prefix]
    pipes = 1 if prefix[0] == "i" else 2
    return rpm / 60 * (cylinders / pipes) / 2


def render_event(rng, voice, turbo, is_bang, variant, prefix, cylinders, redline):
    """
    One pop: a burst of cracks (B-R-A-P: see below), one per exhaust pulse that still has fuel burning in it, as the
    recordings show (the F-Type's pops are ~180 ms trains of cracks ~9 ms apart, one bank's four
    cylinders at ~3500 rpm, swelling and fading; the R8's shorter trains of 3-5). A single crack
    alone sounded like popcorn (the user). Pulses are skipped at random (not every cycle misfires
    into the pipe), the levels and timing are uneven.
    """
    seconds = BANG_SECONDS if is_bang else POP_SECONDS
    n = int(seconds * SR)
    rpm = OVERRUN_SHARE * redline * variant["rpm"]
    interval = 1 / pulses_per_second(prefix, cylinders, rpm)
    low, high = BANG_SECONDS_RANGE if is_bang else POP_SECONDS_RANGE
    cycles = max(3, int(round((low + (high - low) * rng.random()) / interval)))
    # B-R-A-P (the user: "more like a BRAP sound"; popgen-4 swelled up softly and faded out): a hard
    # first thump, a rattle of uneven pulses (only FIRE_CHANCE of them burn: you hear the gaps), and
    # a last crack after a short pause that ends it
    out = np.zeros(n)
    at = 0.0
    strongest = int(rng.integers(1, max(2, cycles // 3))) if is_bang else -1
    for index in range(cycles):
        first, last = index == 0, index == cycles - 1
        if last:
            at += interval * (0.2 + 0.5 * rng.random())          # the short pause before the "P"
        fires = first or last or index == strongest or rng.random() < FIRE_CHANCE
        if fires:
            if first:
                level = B_LEVEL
            elif last:
                level = P_LEVEL * (0.85 + 0.15 * rng.random())
            else:
                level = RATTLE_LEVEL * (1 - 0.3 * index / cycles) * (0.6 + 0.4 * rng.random()) * (1.6 if index == strongest else 1)
            start = int(round(at * SR))
            if start >= n - 64: break
            crack = render_crack(rng, voice, turbo, is_bang, dict(variant, ring=variant["ring"] * TRAIN_RING), n - start)
            out[start:] += level * crack
        at += interval * (1 + PITCH_DROP * index / cycles) * (1 + CRACK_JITTER * (2 * rng.random() - 1))
    fade = int(0.02 * SR)
    out[-fade:] *= np.cos(np.linspace(0, np.pi / 2, fade)) ** 2
    return out


def render_crack(rng, voice, turbo, is_bang, variant, n):
    t = np.arange(n) / SR

    body_hz = voice["body"] * variant["body"] * BODY_PITCH
    ring_scale = voice["ring"] * variant["ring"] * (1.5 if is_bang else 1.0)
    bright = voice["bright"] * variant["crack"]
    full = voice["full"] * (1.6 if is_bang else 1.0)

    # crack: the burning charge leaving the pipe, a near-instant pressure step that decays in ~1 ms
    # (positive lobe) with a smaller, slower suction lobe after it, plus a sizzle of broadband noise
    rise = 0.00015 + 0.0001 * rng.random()
    tau = 0.0009 + 0.0005 * rng.random()
    pulse = (1 - np.exp(-t / rise)) * np.exp(-t / tau)
    suction = -0.45 * (1 - np.exp(-t / (3 * tau))) * np.exp(-t / (4 * tau))
    noise_env = np.exp(-t / (0.003 + 0.0015 * rng.random())) * (1 - np.exp(-t / rise))
    sizzle = butter(butter(rng.standard_normal(n), "highpass", 900), "lowpass", 3500) * noise_env * SIZZLE
    crack = PULSE * (pulse + suction) + sizzle
    # the muffler and (on turbos) the turbine take some top off; never a dull thump
    crack = butter(crack, "lowpass", (CRACK_TOP_TURBO if turbo else CRACK_TOP) * (0.9 + 0.2 * rng.random()), 3)

    # pipe reflections: copies of the crack coming back off the muffler and the collector, each
    # darker, open ends inverting; this gives the crack its ragged "crackle" edge
    reflections = np.zeros(n)
    for index, (delay, gain) in enumerate(((0.0013, 0.45), (0.0031, 0.32), (0.0058, 0.22), (0.0105, 0.14))):
        copy = butter(crack, "lowpass", 6000 / (1 + index * 0.6))
        sign = -1 if rng.random() < 0.5 else 1
        reflections += delayed(copy, delay * (0.8 + 0.4 * rng.random()), n) * gain * sign * (0.7 + 0.6 * rng.random())

    # body: the header pipe ringing, a few damped modes, the pitch settling as the gas cools
    onset = 1 - np.exp(-t / 0.0004)
    body = np.zeros(n)
    for ratio, level, tau_ms in ((1.0, 1.0, 16), (2.07, 0.45, 10), (3.3, 0.22, 6)):
        frequency = body_hz * ratio * (1 + 0.12 * np.exp(-t / 0.012))
        phase = 2 * np.pi * np.cumsum(frequency) / SR + rng.random() * 0.6
        body += level * np.sin(phase) * np.exp(-t / (tau_ms * 0.001 * ring_scale))
    body *= onset
    # the low thump (a bang's chest punch; a little of it on big engines' pops)
    thump_hz = (60 + 50 * rng.random()) * (body_hz / 200) ** 0.3
    thump_phase = 2 * np.pi * np.cumsum(thump_hz * (1 + 0.2 * np.exp(-t / 0.015))) / SR
    thump = np.sin(thump_phase) * np.exp(-t / (0.022 * ring_scale)) * onset
    thump_level = (THUMP_BANG if is_bang else THUMP_POP) * full

    # puff: the exhaust pulse itself, a few ms of positive pressure out of the pipe and the suction
    # that follows it (no net flow). In a train these are the "BRAP": the firing rate and its first
    # harmonics, ~100-300 Hz (popgen-3 had only the clicks: "should be more bassy", the user)
    width = PUFF_WIDTH * (1.3 if is_bang else 1.0) * (0.85 + 0.3 * rng.random())
    puff = np.zeros(n)
    push = min(n, int(width * SR))
    puff[:push] = np.sin(np.pi * np.arange(push) / push)
    pull = min(n - push, int(3 * width * SR))
    puff[push:push + pull] = -np.sin(np.pi * np.arange(pull) / pull) / 3

    # ring and scatter: the muffler's and tailpipe's modes, excited by noise that dies away
    ring_noise = rng.standard_normal(n) * np.exp(-t / (0.035 * ring_scale)) * onset
    ring = np.zeros(n)
    for f, q, level in ((400, 2, 0.9), (900, 2.5, 0.8), (1700, 3, 0.5), (2600, 3, 0.3)):
        ring += level * resonator(ring_noise, f * (0.8 + 0.4 * rng.random()), q)
    scatter = butter(rng.standard_normal(n), "highpass", 2500) * np.exp(-t / (0.007 * ring_scale))
    # (the band passes' skirts and the scatter carry noise to 16 kHz: rolled off like the crack)
    ring = butter(ring + 0.05 * bright / RING * scatter, "lowpass", RING_TOP, 2)

    event = (1.0 * bright * crack + 0.9 * bright * reflections
             + BODY * full * body + thump_level * thump + PUFF * full * puff
             + RING * ring)
    return butter(event, "highpass", 28, 1)                  # no DC / sub rumble


def variants(rng, count):
    out = []
    for _ in range(count):
        out.append(dict(body=0.85 + 0.3 * rng.random(), ring=0.8 + 0.45 * rng.random(), crack=10 ** ((rng.random() * 6 - 3) / 20),
                        rpm=0.8 + 0.4 * rng.random()))
    return out


# --------------------------------------------------------------------------- measuring
OCTAVES = [63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

def first_window(x):
    i = int(np.argmax(np.abs(x)))
    return x[max(0, i - int(0.002 * SR)): i + int(0.025 * SR)]

def rms(x):
    return float(np.sqrt(np.mean(x * x)))

def octave_shape(x):
    f, p = signal.welch(x, SR, nperseg=min(len(x), 1024))
    levels = np.array([10 * np.log10(p[(f >= c / 1.414) & (f < c * 1.414)].sum() + 1e-20) for c in OCTAVES])
    return levels - levels.max()

def decay_ms(x, below_db):
    e = np.sqrt(np.convolve(x * x, np.ones(44) / 44, "same"))
    i = int(np.argmax(e))
    tail = 20 * np.log10(e[i:] / e[i] + 1e-12)
    hit = np.nonzero(tail < -below_db)[0]
    return hit[0] / SR * 1000 if len(hit) else len(tail) / SR * 1000


# --------------------------------------------------------------------------- the manifest
def read_manifest(path):
    text = open(path, "rb").read().decode("utf-8")
    start = text.index("E.BAKED = {")
    entries = []
    for match in re.finditer(r'\n\t\["([^"]+)"\] = \{\n(.*?)\n\t\},', text[start:], re.S):
        body = match.group(2)
        field = lambda name: re.search(r"\n?\t\t" + name + r" = ([^\n]+),", "\n" + body)
        entries.append(dict(
            key=match.group(1),
            dir=re.search(r'dir = "([^"]+)"', body).group(1),
            cyl=int(field("cyl").group(1)),
            pops=int(field("pops").group(1)),
            bangs=int(field("bangs").group(1)),
            limiter=float(field("limiter").group(1)),
            layers=[float(v) for v in re.search(r"layers = \{([^}]*)\}", body).group(1).split(",")],
            trims=[float(v) for v in re.search(r"trims = \{([^}]*)\}", body).group(1).split(",")],
        ))
    return text, entries

def read_wav(path):
    with wave.open(path, "rb") as w:
        assert w.getsampwidth() == 2 and w.getnchannels() == 1
        return np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float64) / 32768, w.getframerate()

def write_wav(path, x):
    data = (np.clip(x, -1, 1) * 32767).round().astype("<i2").tobytes()
    temporary = path + ".new"
    with wave.open(temporary, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(data)
    os.replace(temporary, path)

def engine_reference(root, entry):
    """the on-throttle loop nearest 60% of redline, at cl_engine's level (trim, cylinder gain)"""
    target = 0.6 * entry["limiter"]
    index = min(range(len(entry["layers"])), key=lambda i: abs(entry["layers"][i] - target))
    loop, _ = read_wav(os.path.join(root, "sound", "audio_engine", entry["dir"], "b%don.wav" % (index + 1)))
    cylinder_db = max([gain for count, gain in CYLINDER_GAIN_DB.items() if entry["cyl"] >= count] or [0])
    return rms(loop) * entry["trims"][index] * 10 ** (cylinder_db / 20)


def voice_of(dir_name):
    prefix = dir_name.split("_")[0]
    return prefix, VOICES[prefix], prefix in TURBO_LAYOUTS


def render_bank(root, entry):
    prefix, voice, turbo = voice_of(entry["dir"])
    rng = np.random.default_rng(zlib.crc32((GENERATOR_VERSION + entry["dir"]).encode()))
    engine_rms = engine_reference(root, entry)
    files = {}
    for is_bang, count, over_db, stem in ((False, entry["pops"], POP_OVER_ENGINE_DB, "pop"), (True, entry["bangs"], BANG_OVER_ENGINE_DB, "bang")):
        for number, variant in enumerate(variants(rng, count), 1):
            x = render_event(rng, voice, turbo, is_bang, variant, prefix, entry["cyl"], entry["limiter"])
            wanted = engine_rms * 10 ** (over_db / 20) / (PLAYBACK_GAIN * RUNTIME_LEVEL)
            x *= wanted / rms(first_window(x))
            capped = np.abs(x).max() > PEAK_CAP
            if capped:
                x *= PEAK_CAP / np.abs(x).max()
            files["%s%d" % (stem, number)] = (x, capped)
    return files, engine_rms


# --------------------------------------------------------------------------- recorded pops (the default)
# The user's picks (2026-11-27) after six generated versions missed: cut from CC0 Freesound recordings, bass
# added and the 1-5 kHz chuff cut (scratchpad bassup.py, punch.py; README in dev/popgen/recorded/).
#   pop1-5   the bank's set (RECORDED_SETS by layout), at RECORDED_POP_PITCHES: a lift's pop
#   bang1-3  the anti-lag blat at RECORDED_BANG_PITCHES: cl_engine plays it on an upshift
# "Just switch the antiques up and down in pitch slightly (not a lot)" (the user): no per-engine pitching.
RECORDED_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "recorded")
RECORDED_SPORTY = "antique_2_thumpH_cutkickH.wav"     # the user: "for more sporty cars"
RECORDED_BASSY = "antique_3_both_cutkickD.wav"        # the user: "for sporty bassy cars"
RECORDED_SHIFT = "antilag_3_both_cutkickL.wav"        # the user: "the antilag when shifting"
# big crossplane V8s, the Viper V10, the rumbly / turbo V12s, the W16 (and the DeLorean's odd-fire V6); the rest sporty
BASSY_LAYOUTS = {"v8m", "v8x", "v8p", "v8r", "v8s", "v8xt", "v10l", "v12r", "v12t", "sl65", "w16", "v6odd"}
RECORDED_POP_PITCHES = (0.96, 0.98, 1.0, 1.02, 1.04)
RECORDED_BANG_PITCHES = (0.97, 1.0, 1.03)
# Level: by how loud they sound, not by their peak (the kicks hold the peak, and the ear hardly counts deep
# bass: levelled by peak with -4 dB on top they played no louder than the engine's off-throttle loop, "too
# quiet, can barely hear them", the user). A pop's loudest 50 ms, perceived (`perceived_db`) at cl_engine's
# playback, sits RECORDED_OVER_ENGINE_DB over the bank's on-throttle loop at 60% redline; peaks over
# LIMIT_KNEE x PEAK_CAP are softly limited (the kick's peak, not the whole sound, gives way).
RECORDED_OVER_ENGINE_DB = 2
BANG_OVER_SHIFT_DB = 7        # the anti-lag (bang files) over the off loop near redline (an upshift's torque cut), and
BANG_UNDER_FLAT_OUT_DB = -2   # at least this over the engine flat out near redline (cl_engine dips the engine ~8 dB under it)
LOAD_LIFT_DB = 4              # cl_engine's LOAD_LIFT_DB (full throttle near redline)
POP_PLAYBACK, BANG_PLAYBACK = 1.0 * 0.9, 1.0 * 0.9    # levelled for: POP_GAIN 1 x 0.8-1; the upshift now plays at 1 (~+1 dB on top)
LIMIT_KNEE = 0.5


def perceived_db(x, window=None):
    """loudness roughly as the ear weighs it (K-weighting-like: 100 Hz high-pass, +4 dB over 2 kHz), dB;
    window (s): the loudest stretch of that length, else the whole sound"""
    b, a = signal.butter(2, 100, "highpass", fs=SR); y = signal.lfilter(b, a, x)
    b, a = signal.butter(1, 2000, "highpass", fs=SR); y = y + 0.58 * signal.lfilter(b, a, y)
    power = y * y
    if window:
        n = int(window * SR); power = np.convolve(power, np.ones(n) / n, "valid").max()
    else:
        power = power.mean()
    return 10 * np.log10(power + 1e-12)


def engine_perceived_db(root, entry, share=0.6, kind="on"):
    """the on- (or off-) throttle loop nearest share x redline, perceived, at cl_engine's level (trim, cylinder gain)"""
    target = share * entry["limiter"]
    index = min(range(len(entry["layers"])), key=lambda i: abs(entry["layers"][i] - target))
    loop, _ = read_wav(os.path.join(root, "sound", "audio_engine", entry["dir"], "b%d%s.wav" % (index + 1, kind)))
    cylinder_db = max([gain for count, gain in CYLINDER_GAIN_DB.items() if entry["cyl"] >= count] or [0])
    return perceived_db(loop * entry["trims"][index] * 10 ** (cylinder_db / 20))


def soft_limit(x, ceiling, knee=LIMIT_KNEE):
    start = knee * ceiling
    over = np.abs(x) > start
    y = x.copy()
    y[over] = np.sign(x[over]) * (start + (ceiling - start) * np.tanh((np.abs(x[over]) - start) / (ceiling - start)))
    return y


def level_perceived(x, wanted_db, playback):
    """scale x so its loudest 50 ms at playback sit at wanted_db, limiting peaks to PEAK_CAP; returns x, dB limited"""
    gain = 1.0
    for _ in range(6):
        y = soft_limit(x * gain, PEAK_CAP)
        gain *= 10 ** ((wanted_db - perceived_db(y * playback, 0.05)) / 20)
    y = soft_limit(x * gain, PEAK_CAP)
    return y, 20 * np.log10(max(np.abs(x * gain).max(), 1e-9) / max(np.abs(y).max(), 1e-9))


def pitched(x, factor):
    """play x at factor x the speed (higher pitch, shorter), by polyphase resampling"""
    from fractions import Fraction
    ratio = Fraction(1 / factor).limit_denominator(200)
    return signal.resample_poly(x, ratio.numerator, ratio.denominator)


def render_bank_recorded(root, entry):
    prefix = entry["dir"].split("_")[0]
    engine_rms = engine_reference(root, entry)
    pop_db = engine_perceived_db(root, entry) + RECORDED_OVER_ENGINE_DB
    # the anti-lag plays on a flat-out upshift, inside its torque cut (the off loop plays): over the off loop near
    # redline (levelled against the on loop at 60%
    # redline it came out 2-4 dB under the flat-out engine, "cannot really hear the DSG farts on the Furai", the user)
    bang_db = max(engine_perceived_db(root, entry, 0.95, "off") + BANG_OVER_SHIFT_DB,
                  engine_perceived_db(root, entry, 0.95) + LOAD_LIFT_DB + BANG_UNDER_FLAT_OUT_DB)
    pop_file = RECORDED_BASSY if prefix in BASSY_LAYOUTS else RECORDED_SPORTY
    files = {}
    limited = []
    for name, pitches, count, playback, wanted_db, stem in ((pop_file, RECORDED_POP_PITCHES, entry["pops"], POP_PLAYBACK, pop_db, "pop"),
                                                            (RECORDED_SHIFT, RECORDED_BANG_PITCHES, entry["bangs"], BANG_PLAYBACK, bang_db, "bang")):
        source, rate = read_wav(os.path.join(RECORDED_DIR, name))
        assert rate == SR, name
        for number in range(1, count + 1):
            x, limited_db = level_perceived(pitched(source, pitches[(number - 1) % len(pitches)]), wanted_db, playback)
            limited.append(limited_db)
            files["%s%d" % (stem, number)] = (x, limited_db > 6)
    print("%-20s pops %.1f dB over the on loop (perceived), peaks limited by %.1f-%.1f dB" % (entry["dir"], RECORDED_OVER_ENGINE_DB, min(limited), max(limited)))
    return files, engine_rms


def main(argv):
    root = argv[1]
    preview = argv[argv.index("--preview") + 1] if "--preview" in argv else None
    write = "--write" in argv
    only = argv[argv.index("--only") + 1].split(",") if "--only" in argv else None
    if not (preview or write):
        print(__doc__); return
    manifest_path = os.path.join(root, "lua", "audio_engine", "cl_baked.lua")
    text, entries = read_manifest(manifest_path)
    peaks = {}
    shapes = []
    for entry in entries:
        if entry["pops"] + entry["bangs"] == 0: continue
        if only and not any(entry["dir"].startswith(p) for p in only): continue
        files, engine_rms = render_bank(root, entry) if "--synth" in argv else render_bank_recorded(root, entry)
        folder = os.path.join(preview, entry["dir"]) if preview else os.path.join(root, "sound", "audio_engine", entry["dir"])
        os.makedirs(folder, exist_ok=True)
        capped = []
        for stem, (x, was_capped) in files.items():
            write_wav(os.path.join(folder, stem + ".wav"), x)
            peaks[(entry["dir"], stem)] = float(np.abs(x).max())
            if was_capped: capped.append(stem)
            shapes.append((stem.startswith("bang"), octave_shape(x), decay_ms(x, 20), decay_ms(x, 40)))
        pop1 = files["pop1"][0]
        print("%-20s engine rms %.3f  pop1 peak %.2f rms25 %.3f  shape %s  -10dB %3.0fms -20dB %3.0fms -40dB %3.0fms%s" % (
            entry["dir"], engine_rms, np.abs(pop1).max(), rms(first_window(pop1)),
            " ".join("%5.1f" % v for v in octave_shape(pop1)), decay_ms(pop1, 10), decay_ms(pop1, 20), decay_ms(pop1, 40),
            ("  capped: " + ",".join(capped)) if capped else ""))
    for is_bang, name in ((False, "pops"), (True, "bangs")):
        group = [s for s in shapes if s[0] == is_bang]
        if not group: continue
        print("median %-5s whole file %s | -20 dB %3.0f ms, -40 dB %3.0f ms" % (
            name, " ".join("%5.1f" % v for v in np.median([s[1] for s in group], 0)),
            np.median([s[2] for s in group]), np.median([s[3] for s in group])))
    print("octaves:", OCTAVES)
    if write:
        def replace_peaks(match):
            block = match.group(0)
            directory = re.search(r'dir = "([^"]+)"', block).group(1)
            for (d, stem), peak in peaks.items():
                if d == directory:
                    block = re.sub(r"(\n\t\t\t" + stem + r" = )[0-9.e-]+,", lambda m: m.group(1) + ("%g" % round(peak, 6)) + ",", block)
            return block
        head, tail = text[:text.index("E.BAKED = {")], text[text.index("E.BAKED = {"):]
        tail = re.sub(r'\n\t\["[^"]+"\] = \{\n.*?\n\t\},', replace_peaks, tail, flags=re.S)
        source = GENERATOR_VERSION if "--synth" in argv else "recorded: dev/popgen/recorded, CC0"
        note = "\tPops and bangs (pop1-5, bang1-3): dev/popgen/popgen.py (" + source + ")\n"
        if "dev/popgen/popgen.py" not in head:
            head = head.replace("\tSynth version:", note + "\tSynth version:", 1)
        else:
            head = re.sub(r"\tPops and bangs [^\n]*\n", note, head)
        open(manifest_path, "wb").write((head + tail).encode("utf-8"))
        print("wrote", len(peaks), "files' peaks into", manifest_path)


if __name__ == "__main__":
    main(sys.argv)
