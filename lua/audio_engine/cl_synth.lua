--[[
	Audio Engine - procedural engine synthesizer (client, pure Lua)

	Based on the "Rev Bench" sound generator (per-cylinder firing pulses on a 720 degree crank
	cycle, exhaust resonators, combustion noise, slow leveller, and its WebAudio chain:
	high-pass -> tanh drive -> 95 Hz peak -> low shelf -> rpm/throttle-tracking low-pass ->
	4.2 kHz low-pass -> exhaust tube -> high shelf -> small outdoor space).

	On top of that, to sound like a real car instead of a synth (cfg.realism):
	  * two exhaust banks (V engines), each with its own slightly different pipe resonances
	  * every cylinder a little different (strength and timing), plus cycle-to-cycle
	    combustion variation that is larger at idle than under load -> the uneven "half order"
	    rumble real engines have
	  * turbulent exhaust flow noise, band-passed and pulsed by the firing, rising with load
	  * a third (muffler) resonance, faint valvetrain ticking, a tailpipe stage
	  * turbochargers soften the exhaust pulses under boost
	Plus turbo whine and blow-off sounds that the game drives from a boost model.

	The synth renders into plain Lua arrays; cl_soundbank.lua turns those into game sounds
	with sound.Generate.
]]

AUDIO_ENGINE = AUDIO_ENGINE or {}
local Synth = {}
AUDIO_ENGINE.Synth = Synth

local bit = bit or require("bit")
local bxor, lshift, rshift = bit.bxor, bit.lshift, bit.rshift
local exp, sqrt, sin, cos, min, max, abs, floor = math.exp, math.sqrt, math.sin, math.cos, math.min, math.max, math.abs, math.floor
local tanh = math.tanh
local pi = math.pi
local TAU = 6.283185307

---------------------------------------------------------------------------
-- engine layouts: firing angles over one 720 degree cycle, pulse strength, exhaust bank
---------------------------------------------------------------------------
local function evenAngles(n)
	local t = {}
	for i = 0, n - 1 do t[i + 1] = i * 720 / n end
	return t
end

local function offsetAngles(n, f)
	local t = evenAngles(n)
	for i = 1, n do t[i] = t[i] + f(i - 1) end
	return t
end

local V8CROSS = "LRLLRLRR"

Synth.LAYOUTS = {
	single  = { angles = { 0 }, amp = { 1 }, banks = "L" },
	vtwin   = { angles = { 0, 315 }, amp = { 1, 0.9 }, banks = "LR" },
	ptwin   = { angles = { 0, 270 }, amp = { 1, 0.95 }, banks = "LL" },
	triple  = { angles = evenAngles(3), amp = { 1, 0.94, 1.03 }, banks = "LLL" },
	i4      = { angles = evenAngles(4), amp = { 1, 0.93, 1.04, 0.9 }, banks = "LLLL" },
	boxer   = { angles = offsetAngles(4, function(i) return ({ 0, 34, 10, 46 })[i + 1] end), amp = { 1, 0.8, 1.06, 0.78 }, banks = "LLRR" },
	i5      = { angles = evenAngles(5), amp = { 1, 0.9, 1.05, 0.93, 0.98 }, banks = "LLLLL" },
	i6      = { angles = evenAngles(6), amp = { 1, 0.98, 1.01, 0.99, 1.02, 0.98 }, banks = "LLLLLL" },
	v6odd   = { angles = { 0, 90, 240, 330, 480, 570 }, amp = { 1, 0.9, 1, 0.9, 1, 0.9 }, banks = "LRLRLR" },
	v8cross = {
		angles = offsetAngles(8, function(i) return V8CROSS:sub(i + 1, i + 1) == "R" and 26 or 0 end),
		amp = { 1, 0.84, 1, 1, 0.84, 1, 0.84, 0.84 }, banks = V8CROSS,
	},
	v8flat  = { angles = evenAngles(8), amp = { 1, 0.95, 1, 0.95, 1, 0.95, 1, 0.95 }, banks = "LRLRLRLR" },
	v10     = { angles = offsetAngles(10, function(i) return i % 2 == 1 and 5 or 0 end), amp = { 1, .95, 1, .96, 1, .94, 1, .95, 1, .96 }, banks = "LRLRLRLRLR" },
	v12     = { angles = evenAngles(12), amp = { 1, 0.97, 1, 0.97, 1, 0.97, 1, 0.97, 1, 0.97, 1, 0.97 }, banks = "LRLRLRLRLRLR" },
	-- even-firing 60 degree V6 (most modern V6s): one firing every 120 degrees, banks alternate
	v6      = { angles = evenAngles(6), amp = { 1, 0.95, 1.02, 0.96, 1, 0.94 }, banks = "LRLRLR" },
	-- flat-six: each bank of three fires every 240 degrees into its own header, the banks
	-- alternate. Two three-cylinder streams give the flat-six its hard-edged howl
	flat6   = { angles = evenAngles(6), amp = { 1, 0.9, 1.03, 0.92, 1.01, 0.9 }, banks = "LRLRLR" },
	-- flat-twelve (180 degree V12): even firing, a bit lumpier than a V12
	flat12  = { angles = offsetAngles(12, function(i) return i % 2 == 1 and 4 or 0 end), amp = { 1, 0.93, 1, 0.94, 1, 0.92, 1, 0.93, 1, 0.94, 1, 0.92 }, banks = "LRLRLRLRLRLR" },
	-- W16: two narrow-angle VR8s on one crank, two exhausts. Firings come in pairs (the VR8's
	-- offset banks) and each pair goes to the same side, so each exhaust hears a lumpy stream
	-- at half the firing rate: a deep growl under the 16-cylinder hum, not a thin even buzz
	w16     = { angles = offsetAngles(16, function(i) return i % 2 == 1 and -12 or 0 end),
		amp = { 1, 0.9, 0.98, 0.86, 1, 0.92, 0.97, 0.88, 1, 0.9, 0.98, 0.86, 1, 0.92, 0.97, 0.88 }, banks = "LLRRLLRRLLRRLLRR" },
	-- Wankel rotary: each rotor fires once per turn of the eccentric shaft, so a twin-rotor
	-- fires 4 times per 720 degrees (like an inline-4) and a triple-rotor 6 times. The exhaust
	-- port opens all at once, so each pulse is long and hard-edged: the rotary buzz
	rotary2 = { angles = evenAngles(4), amp = { 1, 0.96, 1, 0.96 }, banks = "LLLL" },
	rotary3 = { angles = evenAngles(6), amp = { 1, 0.96, 0.98, 1, 0.96, 0.98 }, banks = "LLLLLL" },
	-- electric motor: no combustion at all (Synth.EVRender); one dummy entry keeps the tables happy
	electric = { angles = { 0 }, amp = { 1 }, banks = "L" },
}

-- separate, fixed-seed generator for the engine's "build character" (same on every client)
local function seededRand(seed)
	local s = seed
	return function()
		s = bxor(s, lshift(s, 13)); s = bxor(s, rshift(s, 17)); s = bxor(s, lshift(s, 5))
		return s / 2147483648
	end
end

--[[
	Each engine type's own voice (used as "realism" goes up):
	  f1, f2, f3  the exhaust's main resonances (Hz): big/deep pipes for a V8, thin and high
	              for an inline-4, high and smooth for V10/V12
	  w           exhaust pulse width (wider = deeper and rounder, narrower = buzzier)
	  o1, o05     how strongly the firing is shaped once per crank turn (1st order) and once
	              per cycle (half order). These low orders are the rhythm you recognise: the
	              V8 burble, the boxer rumble, the five-cylinder warble.
]]
Synth.CHARACTER = {
	single  = { f1 = 70,  f2 = 250, f3 = 140, w = 1.30, o1 = 0.00, o05 = 0.00 },
	vtwin   = { f1 = 72,  f2 = 260, f3 = 150, w = 1.20, o1 = 0.10, o05 = 0.00 },
	ptwin   = { f1 = 80,  f2 = 300, f3 = 160, w = 1.10, o1 = 0.10, o05 = 0.00 },
	triple  = { f1 = 95,  f2 = 360, f3 = 190, w = 1.00, o1 = 0.15, o05 = 0.12 },
	i4      = { f1 = 115, f2 = 430, f3 = 230, w = 0.85, o1 = 0.06, o05 = 0.05 },
	boxer   = { f1 = 80,  f2 = 300, f3 = 170, w = 1.05, o1 = 0.12, o05 = 0.24 },
	i5      = { f1 = 95,  f2 = 370, f3 = 200, w = 0.95, o1 = 0.12, o05 = 0.20 },
	i6      = { f1 = 90,  f2 = 380, f3 = 190, w = 0.95, o1 = 0.05, o05 = 0.05 },
	v6odd   = { f1 = 82,  f2 = 320, f3 = 170, w = 1.00, o1 = 0.15, o05 = 0.14 },
	v8cross = { f1 = 62,  f2 = 240, f3 = 130, w = 1.15, o1 = 0.20, o05 = 0.30 },
	v8flat  = { f1 = 95,  f2 = 460, f3 = 230, w = 0.85, o1 = 0.08, o05 = 0.05 },
	v10     = { f1 = 88,  f2 = 480, f3 = 220, w = 0.85, o1 = 0.08, o05 = 0.08 },
	v12     = { f1 = 85,  f2 = 420, f3 = 210, w = 0.90, o1 = 0.06, o05 = 0.06 },
	v6      = { f1 = 88,  f2 = 360, f3 = 185, w = 0.95, o1 = 0.08, o05 = 0.07 },
	flat6   = { f1 = 100, f2 = 450, f3 = 225, w = 0.85, o1 = 0.12, o05 = 0.10 },
	flat12  = { f1 = 82,  f2 = 400, f3 = 200, w = 0.92, o1 = 0.08, o05 = 0.10 },
	w16     = { f1 = 48,  f2 = 205, f3 = 110, w = 1.40, o1 = 0.24, o05 = 0.32 },   -- V8-strength low orders: the growl
	rotary2 = { f1 = 125, f2 = 540, f3 = 270, w = 1.25, o1 = 0.00, o05 = 0.08 },
	rotary3 = { f1 = 120, f2 = 560, f3 = 280, w = 1.20, o1 = 0.00, o05 = 0.06 },
	electric = { f1 = 100, f2 = 400, f3 = 200, w = 1.00, o1 = 0.00, o05 = 0.00 },
}

--[[
	cylVar / cylTiming: how different each cylinder is (fraction of strength, degrees).
	o1 / o05: low-order shaping of the cylinder strengths (see CHARACTER).
	Returns firing intervals, strengths, cylinder count and the exhaust bank (1/2) per firing.
]]
function Synth.LayoutParams(key, cylVar, cylTiming, o1, o05)
	local L = Synth.LAYOUTS[key] or Synth.LAYOUTS.i4
	local n = #L.angles
	local a, am, banks = {}, {}, {}
	local r = seededRand(0x1F2E3D4C)
	for i = 1, n do
		a[i] = L.angles[i] + (cylTiming or 0) * r()
		local th = L.angles[i] * pi / 180
		local shape = 1 + (o1 or 0) * cos(th * 2 + 0.7) + (o05 or 0) * cos(th + 1.9)
		am[i] = L.amp[i] * (1 + (cylVar or 0) * r()) * max(0.3, shape)
		banks[i] = L.banks:sub(i, i) == "R" and 2 or 1
	end
	local iv = {}
	for i = 1, n do
		iv[i] = (i < n and a[i + 1] or a[1] + 720) - a[i]
	end
	return iv, am, n, banks
end

---------------------------------------------------------------------------
-- EngineGen
---------------------------------------------------------------------------
-- The original runs its smoothers per sample at the browser rate. Scale them so the
-- character is the same at 22.05 kHz or 44.1 kHz.
local REF_SR = 44100
local function smooth(k, sr) return 1 - (1 - k) ^ (REF_SR / sr) end
local function decay(d, sr) return d ^ (REF_SR / sr) end

-- the engine type's voice, with a car's own changes on top (cfg.character, sh_carlist.lua)
function Synth.CharacterFor(cfg)
	local base = Synth.CHARACTER[cfg.layout] or Synth.CHARACTER.i4
	if type(cfg.character) ~= "table" then return base end
	local c = {}
	for k, v in pairs(base) do c[k] = cfg.character[k] or v end
	return c
end

local function realismOf(cfg)
	local R = cfg.realism or {}
	return {
		spread = R.bankSpread or 0,       -- difference between the two banks' pipes
		combVar = R.combustionVar or 0,   -- extra cycle-to-cycle variation (at idle)
		cylVar = R.cylinderVar or 0,
		cylTiming = R.cylinderTiming or 0,
		flow = R.flowNoise or 0,
		mech = R.mechanical or 0,
		mode3 = R.mufflerMode or 0,
		-- the turbo is a separate, shared sound now (switching it never needs a new engine), so
		-- the exhaust pulses are rendered the same with or without it
		turboSoft = 0,
		tailpipe = R.tailpipe or 0,
		reverb = R.reverb or 0,
		gurgle = cfg.gurgle or 0,
		voice = R.voice or 0,                                   -- how much of the engine type's own voice
		char = Synth.CharacterFor(cfg),
	}
end
Synth.RealismOf = realismOf

function Synth.NewGen(sr, cfg)
	local R = realismOf(cfg)
	local iv, am, cyl, banks = Synth.LayoutParams(cfg.layout, R.cylVar, R.cylTiming, R.char.o1 * R.voice, R.char.o05 * R.voice)
	return {
		sr = sr, rpm = 0, tRpm = 0, thr = 0, tThr = 0,
		pitch = cfg.pitch or 1, tone = cfg.tone or 0.55, cyl = cyl, iv = iv, am = am, banks = banks,
		redline = cfg.redline or 7000, R = R,
		cut = false, crank = 0, on = false,
		gain = 0, deg = 0, idx = 0, jit = 1,
		-- bank 1 (left) and bank 2 (right)
		env = 0, envB = 0, nenv = 0, pp = 0, a1 = 0, a2 = 0, b1 = 0, b2 = 0, k1 = 0, k2 = 0,
		tauA = 1, tauB = 1, tauN = 1,
		envR = 0, envBR = 0, nenvR = 0, ppR = 0, a1R = 0, a2R = 0, b1R = 0, b2R = 0, k1R = 0, k2R = 0,
		tauAR = 1, tauBR = 1, tauNR = 1,
		fz1 = 0, fz2 = 0, mechE = 0, tms = 0.01, glfo = 0,
		pop = 0, nlp = 0, nlp2 = 0, lp = 0, x1 = 0, y1 = 0, seed = 0x2545F491,
		ms = 0.002, agc = 1, popE = 0,
		ev = cfg.layout == "electric",
		allowPops = true,  -- random overrun / limiter pops (off for loops; the game triggers them)
		noFire = false,    -- silence the combustion pulses (used to render pop one-shots)
		fixedAgc = nil,    -- force the leveller to a fixed gain
		k = {
			rpm = smooth(0.0015, sr), thr = smooth(0.002, sr), gain = smooth(0.0004, sr),
			n = smooth(0.06, sr), lp = smooth(0.025, sr), dc = decay(0.996, sr),
			popE = smooth(0.03, sr), popD = decay(0.996, sr),
			ms = smooth(0.00005, sr), agc = smooth(0.0002, sr),
		},
	}
end

function Synth.Rand(g)
	local s = g.seed
	s = bxor(s, lshift(s, 13)); s = bxor(s, rshift(s, 17)); s = bxor(s, lshift(s, 5))
	g.seed = s
	return s / 2147483648
end

local function reso(f, decaySec, sr)
	local w = TAU * f / sr
	local r = exp(-1 / (sr * decaySec))
	return 2 * r * cos(w), r * r, sin(w)
end

--[[
	Electric motor: no firing pulses, one faint whine. It is a single tone locked to the motor
	speed with weak harmonics (so you hear one pitch, not several), under a hiss of bearings and
	cooling air. The motor's speed ripples a little (a fraction of a percent, ~25 Hz), so the tone
	is a narrow band rather than a perfect sine, the one thing that makes a synth whine sound
	like a machine; all harmonics share the ripple, so it stays one pitch. The tone's order (tones per motor
	turn) is picked so it reaches EV_TOP_HZ at redline whatever the redline, rounded to a multiple
	of 0.5 so the loops close seamlessly over a 720 degree cycle. Its level drifts a little, the
	housing and body colour it gently (little below 150 Hz, rolled off above ~4 kHz), and the
	harmonics grow with load and tone. Off throttle the motor regenerates, so it still
	whines, softer. Practically silent at low speed: there you hear the low-speed hum
	(Synth.RenderEVHumLoop).
]]
local EV_TOP_HZ = 450
local EV_PARTIALS = {
	-- { harmonic, level }
	{ 1, 1.00 }, { 2, 0.18 }, { 3, 0.05 },
}

-- how the motor housing and the body pass a tone of fz Hz on
local function evBody(fz, sr)
	if fz > 0.45 * sr then return 0 end
	local d1, d2 = (fz - 700) / 300, (fz - 1800) / 600
	local r = 0.9 + 0.25 / (1 + d1 * d1) + 0.15 / (1 + d2 * d2)
	local hi = fz / 4000
	return r * fz * fz / (fz * fz + 22500) / (1 + hi * hi * hi * hi)
end

function Synth.EVRender(g, out, o, n)
	local sr, K = g.sr, g.k
	local rpmS, thrS, gain = g.rpm, g.thr, g.gain
	local tRpm, tThr, onT = g.tRpm, g.tThr, g.on and 1 or 0
	local redline, pitch, tone = g.redline, g.pitch, g.tone
	local ord = g.evOrder
	if not ord then
		ord = max(1, floor(EV_TOP_HZ * 60 / redline * 2 + 0.5) / 2)
		g.evOrder = ord
	end
	local ph = g.evPh
	if not ph then
		ph = {}
		for j = 1, #EV_PARTIALS do ph[j] = (j * 2.39996) % TAU end   -- spread starting phases
		g.evPh = ph
	end
	local m1, m2, h1, h2, seed = g.evM1 or 0, g.evM2 or 0, g.evH1 or 0, g.evH2 or 0, g.seed
	local j1, j2 = g.evJ1 or 0, g.evJ2 or 0
	local kRpm, kThr, kGain = K.rpm, K.thr, K.gain
	local kM = 1 - exp(-TAU * 3 / sr)            -- level drift, ~3 Hz
	local mN = 1 / (0.28 * sqrt(kM))              -- makes the twice-smoothed noise ~1 rms
	local kJ = 1 - exp(-TAU * 25 / sr)            -- speed ripple, ~25 Hz
	local jN = 1 / (0.28 * sqrt(kJ))
	local kH1, kH2 = 1 - exp(-TAU * 1800 / sr), 1 - exp(-TAU * 5000 / sr)
	local w = TAU / sr
	local np = #EV_PARTIALS
	for i = 0, n - 1 do
		rpmS = rpmS + (tRpm - rpmS) * kRpm
		thrS = thrS + (tThr - thrS) * kThr
		gain = gain + (onT - gain) * kGain
		local f = max(0, rpmS) / 60 * pitch
		local spd = min(1, max(0, rpmS) / redline)
		-- motor torque: full on the pedal, regeneration off it
		local load = 0.4 + 0.6 * thrS
		seed = bxor(seed, lshift(seed, 13)); seed = bxor(seed, rshift(seed, 17)); seed = bxor(seed, lshift(seed, 5))
		local r = seed / 2147483648
		m1 = m1 + (r - m1) * kM; m2 = m2 + (m1 - m2) * kM
		seed = bxor(seed, lshift(seed, 13)); seed = bxor(seed, rshift(seed, 17)); seed = bxor(seed, lshift(seed, 5))
		j1 = j1 + (seed / 2147483648 - j1) * kJ; j2 = j2 + (j1 - j2) * kJ
		local wj = w * (1 + 0.004 * jN * j2)
		local a = 0.18 * spd ^ 0.8 * (0.35 + 0.65 * load) * (1 + 0.05 * mN * m2)
		local bright = (0.5 + 0.5 * load) * (0.5 + tone)
		local s = 0
		for j = 1, np do
			local P = EV_PARTIALS[j]
			local fz = f * ord * P[1]
			local p = ph[j] + wj * fz
			if p > TAU then p = p - TAU end
			ph[j] = p
			local lv = P[1] > 1 and P[2] * bright or P[2]
			s = s + lv * evBody(fz, sr) * sin(p)
		end
		s = s * a
		-- bearings and cooling air: a band of noise around 2-5 kHz
		h1 = h1 + (r - h1) * kH1
		h2 = h2 + ((r - h1) - h2) * kH2
		s = s + h2 * 0.08 * spd ^ 1.2 * (0.6 + 0.4 * load)
		out[o + i] = s * gain * 0.6
	end
	g.rpm, g.thr, g.gain = rpmS, thrS, gain
	g.evM1, g.evM2, g.evH1, g.evH2, g.seed = m1, m2, h1, h2, seed
	g.evJ1, g.evJ2 = j1, j2
end

-- render n samples of raw generator output into out[o] .. out[o+n-1]
function Synth.GenRender(g, out, o, n)
	if g.ev then return Synth.EVRender(g, out, o, n) end
	local sr = g.sr
	local R = g.R
	local sp = sqrt(g.pitch)
	local spr = R.spread
	-- exhaust resonances: Rev Bench's at realism 0, the engine type's own voice at full realism
	local C, v = R.char, R.voice
	local f1 = (78 + (C.f1 - 78) * v) * sp
	local f2 = ((230 + 190 * g.tone) * (1 - v) + C.f2 * (0.85 + 0.3 * g.tone) * v) * sp
	local f3 = (155 + (C.f3 - 155) * v) * sp
	-- left / right bank pipes differ a little in length
	local c1, d1, g1 = reso(f1 * (1 - 0.03 * spr), 0.022, sr)
	local c2, d2, g2 = reso(f2 * (1 + 0.04 * spr), 0.006, sr)
	local c3, d3, g3 = reso(f3 * (1 - 0.05 * spr), 0.012, sr)
	local c1R, d1R, g1R = reso(f1 * (1 + 0.03 * spr), 0.022, sr)
	local c2R, d2R, g2R = reso(f2 * (1 - 0.04 * spr), 0.006, sr)
	local c3R, d3R, g3R = reso(f3 * (1 + 0.05 * spr), 0.012, sr)
	local m3 = R.mode3
	local baseTau = 0.007 * (4 / g.cyl) ^ 0.6 / sp * (1 + (C.w - 1) * v)
	local grit = g.tone
	local popChance = max(0, (g.tone - 0.35) / 0.65)
	local iv, am, banks, nf = g.iv, g.am, g.banks, #g.iv
	local K = g.k
	local kRpm, kThr, kGain, kN, kLp, dc, kPopE, popD, kMs, kAgc =
		K.rpm, K.thr, K.gain, K.n, K.lp, K.dc, K.popE, K.popD, K.ms, K.agc
	local pitch = g.pitch
	local tRpm, tThr, cut, crank, onT = g.tRpm, g.tThr, g.cut, g.crank, g.on and 1 or 0
	local allowPops, noFire, fixedAgc = g.allowPops, g.noFire, g.fixedAgc
	local combVar, turboSoft, mechK = R.combVar, R.turboSoft, R.mech
	local redline = g.redline
	local mechD = exp(-1 / (sr * 0.0012))

	local rpmS, thrS, gain, deg, idx, jit = g.rpm, g.thr, g.gain, g.deg, g.idx, g.jit
	local env, envB, nenv, pp, a1, a2, b1, b2, k1, k2 = g.env, g.envB, g.nenv, g.pp, g.a1, g.a2, g.b1, g.b2, g.k1, g.k2
	local envR, envBR, nenvR, ppR, a1R, a2R, b1R, b2R, k1R, k2R = g.envR, g.envBR, g.nenvR, g.ppR, g.a1R, g.a2R, g.b1R, g.b2R, g.k1R, g.k2R
	local tauA, tauB, tauN, tauAR, tauBR, tauNR = g.tauA, g.tauB, g.tauN, g.tauAR, g.tauBR, g.tauNR
	local pop, nlp, nlp2, lp, x1, y1, seed = g.pop, g.nlp, g.nlp2, g.lp, g.x1, g.y1, g.seed
	local ms, agc, popE = g.ms, g.agc, g.popE
	local fz1, fz2, mechE, tms = g.fz1, g.fz2, g.mechE, g.tms
	local gurgleK, glfo = R.gurgle, g.glfo
	local voice = R.voice
	local jitAmt = 0.018 + 0.017 * voice          -- firing is a little less clockwork with realism
	local barkK = 0.35 * voice
	if fixedAgc then agc = fixedAgc end

	-- exhaust flow noise: band-pass that rises with rpm. Its level follows the engine's own
	-- running loudness (tms), as a share that grows with load and rpm (set per block)
	local flowAmt = R.flow
	local fb0, fa1, fa2, flowLoad = 0, 0, 0, 0
	local rpmFrac = min(1, rpmS / redline)
	if flowAmt > 0 then
		local fc = 300 + 0.1 * rpmS
		local w = TAU * fc / sr
		local Q = 0.5
		local alpha = sin(w) / (2 * Q)
		local a0 = 1 + alpha
		fb0, fa1, fa2 = alpha / a0, -2 * cos(w) / a0, (1 - alpha) / a0
		-- white noise here is uniform (rms 0.577); normalise the band-passed rms to ~1
		local norm = 1 / (0.577 * sqrt((fc / Q) / (sr / 2) * (pi / 2)))
		flowLoad = norm * (0.3 + 0.4 * thrS) * (0.85 + 0.15 * rpmFrac)
	end
	local mechAmt = mechK * 0.6 * (0.8 - 0.3 * rpmFrac)

	local function rnd()
		seed = bxor(seed, lshift(seed, 13)); seed = bxor(seed, rshift(seed, 17)); seed = bxor(seed, lshift(seed, 5))
		return seed / 2147483648
	end

	for i = 0, n - 1 do
		rpmS = rpmS + (tRpm - rpmS) * kRpm
		thrS = thrS + (tThr - thrS) * kThr
		gain = gain + (onT - gain) * kGain
		local gap = iv[idx + 1] * jit
		local rpm = rpmS > 30 and rpmS or 30
		local thr = thrS
		local degPerSec = rpm * 6 * pitch
		deg = deg + degPerSec / sr
		if deg >= gap then
			deg = deg - gap
			idx = (idx + 1) % nf
			jit = 1 + jitAmt * rnd()
			-- pulse length is real time, capped so pulses still separate at high rpm;
			-- turbos smear the pulses out under boost
			local gapSec = iv[idx + 1] / degPerSec
			local boostish = (rpm - 1800) / 2200
			if boostish < 0 then boostish = 0 elseif boostish > 1 then boostish = 1 end
			local soft = 1 + turboSoft * thr * boostish
			local tau = min(baseTau * soft, gapSec * 0.42 * sqrt(soft))
			local tA = exp(-1 / (sr * tau))
			local tB = exp(-1 / (sr * min(tau * 0.22, 0.0018)))
			local tN = exp(-1 / (sr * tau * 0.5))
			local right = banks[idx + 1] == 2
			if right then tauAR, tauBR, tauNR = tA, tB, tN else tauA, tauB, tauN = tA, tB, tN end
			local fire, puff = not cut, false
			if crank == 1 then fire = false; puff = true          -- compression only
			elseif crank == 2 then fire = rnd() > -0.3 end        -- catching: most cylinders light
			if noFire then fire = false; puff = false end
			-- gurgle: off throttle the burn goes ragged. Strengths come in uneven groups (a slow
			-- random drift across firings) and the odd cylinder misfires. Always draw the same
			-- random numbers so on/off-throttle loops keep the same firing phase.
			local gMul = 1
			if gurgleK > 0 then
				local ra, rb = rnd(), rnd()
				glfo = glfo * 0.72 + ra * 0.28
				local gg = gurgleK * (1 - thr) * (1 - thr)
				gMul = 1 + gg * (2.2 * glfo + 0.35 * rb)
				if gMul < 0.15 then gMul = 0.15 end
				if fire and rb > 1 - 0.22 * gg then
					fire = false
					rnd()  -- the draw this firing would have used, so the sequence stays aligned
				end
			end
			if fire then
				-- combustion varies more cycle to cycle at idle than under load
				local st = (0.3 + 0.7 * thr) * am[idx + 1] * (1 + (0.12 + 0.08 * voice + combVar * (1 - thr)) * rnd()) * gMul
				if right then
					envR = envR + st; envBR = envBR + st; nenvR = nenvR + st * (0.3 + 0.5 * thr)
				else
					env = env + st; envB = envB + st; nenv = nenv + st * (0.3 + 0.5 * thr)
				end
				mechE = mechE + mechAmt
				if allowPops and thr < 0.04 and rpm > 3500 and rnd() * 0.5 + 0.5 < 0.04 * popChance then
					pop = (0.25 + 0.1 * rnd()) * popChance
				end
			elseif puff then
				local st = 0.13 * am[idx + 1]
				if right then envR = envR + st; envBR = envBR + st else env = env + st; envB = envB + st end
			elseif allowPops and cut and rpm > 2500 and rnd() * 0.5 + 0.5 < 0.25 * popChance then
				pop = (0.3 + 0.1 * rnd()) * popChance
			end
		end
		env = env * tauA; envB = envB * tauB; nenv = nenv * tauN
		envR = envR * tauAR; envBR = envBR * tauBR; nenvR = nenvR * tauNR
		mechE = mechE * mechD
		local nz = rnd()
		nlp = nlp + (nz - nlp) * kN
		nlp2 = nlp2 + (nlp - nlp2) * kN
		lp = lp + (nz - lp) * kLp
		local rbGain = 0.3 + 0.6 * thr
		-- left bank
		local pulse = env - envB
		local u = pulse - pp; pp = pulse
		local ra = c1 * a1 - d1 * a2 + u * g1; a2 = a1; a1 = ra
		local rb = c2 * b1 - d2 * b2 + u * g2 * rbGain; b2 = b1; b1 = rb
		local rc = c3 * k1 - d3 * k2 + u * g3; k2 = k1; k1 = rc
		-- right bank
		local pulseR = envR - envBR
		local uR = pulseR - ppR; ppR = pulseR
		local raR = c1R * a1R - d1R * a2R + uR * g1R; a2R = a1R; a1R = raR
		local rbR = c2R * b1R - d2R * b2R + uR * g2R * rbGain; b2R = b1R; b1R = rbR
		local rcR = c3R * k1R - d3R * k2R + uR * g3R; k2R = k1R; k1R = rcR

		local s = (pulse + pulseR) * 0.5 + (ra + raR) * 1.1 + (rb + rbR) * (0.15 + 0.45 * grit)
			+ (rc + rcR) * m3
			+ (nenv + nenvR) * nlp2 * (0.2 + 0.8 * grit)
			+ lp * thr * min(rpm / 9000, 1) * (0.1 + 0.25 * grit)
		tms = tms + (s * s - tms) * kMs
		local lvl = sqrt(tms)
		if flowAmt > 0 then
			-- band-pass (constant 0 dB peak): b1 = 0, b2 = -b0; pulsed by the firing
			local fy = fb0 * nz + fz1; fz1 = -fa1 * fy + fz2; fz2 = -fb0 * nz - fa2 * fy
			local pm = (nenv + nenvR) * 1.2
			if pm > 1.5 then pm = 1.5 end
			-- grit rides on each exhaust pulse (rasp), rather than a steady hiss (scream)
			s = s + fy * flowAmt * flowLoad * lvl * (0.12 + 0.88 * pm)
		end
		if mechE > 1e-5 then s = s + mechE * lvl * (nz - nlp) end
		-- pops fade in over ~1 ms so they never start with a click
		popE = popE + (pop - popE) * kPopE; pop = pop * popD
		if popE > 0.002 then s = s + popE * nlp * 2.2 end
		-- exhaust pressure waves steepen as they travel: a little even-order bark
		if voice > 0 then s = s + barkK * s * s / (1 + abs(s)) end
		local y = s - x1 + dc * y1; x1 = s; y1 = y
		-- slow leveller: keeps resonance build-up in check without flattening throttle dynamics
		local ov = y * 0.3
		ms = ms + (ov * ov - ms) * kMs
		if not fixedAgc then
			local want = (0.035 + 0.04 * thr) / (sqrt(ms) + 1e-4)
			if want > 1.4 then want = 1.4 elseif want < 0.45 then want = 0.45 end
			agc = agc + (want - agc) * kAgc
		end
		out[o + i] = ov * agc * gain
	end

	g.rpm, g.thr, g.gain, g.deg, g.idx, g.jit = rpmS, thrS, gain, deg, idx, jit
	g.env, g.envB, g.nenv, g.pp, g.a1, g.a2, g.b1, g.b2, g.k1, g.k2 = env, envB, nenv, pp, a1, a2, b1, b2, k1, k2
	g.envR, g.envBR, g.nenvR, g.ppR, g.a1R, g.a2R, g.b1R, g.b2R, g.k1R, g.k2R = envR, envBR, nenvR, ppR, a1R, a2R, b1R, b2R, k1R, k2R
	g.tauA, g.tauB, g.tauN, g.tauAR, g.tauBR, g.tauNR = tauA, tauB, tauN, tauAR, tauBR, tauNR
	g.pop, g.nlp, g.nlp2, g.lp, g.x1, g.y1, g.seed = pop, nlp, nlp2, lp, x1, y1, seed
	g.ms, g.agc, g.popE = ms, agc, popE
	g.fz1, g.fz2, g.mechE, g.tms = fz1, fz2, mechE, tms
	g.glfo = glfo
end

---------------------------------------------------------------------------
-- WebAudio-equivalent biquads (Audio EQ Cookbook as specified by WebAudio:
-- lowpass/highpass Q is in dB, shelves use slope S = 1)
---------------------------------------------------------------------------
local function biquad(kind, f0, sr, Q, gainDb)
	local w0 = TAU * f0 / sr
	local cw, sw = cos(w0), sin(w0)
	local b0, b1, b2, a0, a1, a2
	if kind == "lowpass" or kind == "highpass" then
		local alpha = sw / (2 * 10 ^ (Q / 20))
		if kind == "lowpass" then
			b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2
		else
			b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2
		end
		a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
	elseif kind == "bandpass" then
		local alpha = sw / (2 * Q)
		b0 = alpha; b1 = 0; b2 = -alpha
		a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
	elseif kind == "peaking" then
		local A = 10 ^ (gainDb / 40)
		local alpha = sw / (2 * Q)
		b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A
		a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A
	else
		local A = 10 ^ (gainDb / 40)
		local alphaS = sw / 2 * sqrt(2)
		local sA = 2 * alphaS * sqrt(A)
		if kind == "lowshelf" then
			b0 = A * ((A + 1) - (A - 1) * cw + sA)
			b1 = 2 * A * ((A - 1) - (A + 1) * cw)
			b2 = A * ((A + 1) - (A - 1) * cw - sA)
			a0 = (A + 1) + (A - 1) * cw + sA
			a1 = -2 * ((A - 1) + (A + 1) * cw)
			a2 = (A + 1) + (A - 1) * cw - sA
		else -- highshelf
			b0 = A * ((A + 1) + (A - 1) * cw + sA)
			b1 = -2 * A * ((A - 1) + (A + 1) * cw)
			b2 = A * ((A + 1) + (A - 1) * cw - sA)
			a0 = (A + 1) - (A - 1) * cw + sA
			a1 = 2 * ((A - 1) - (A + 1) * cw)
			a2 = (A + 1) - (A - 1) * cw - sA
		end
	end
	return { b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0, 0, 0 }
end
Synth.Biquad = biquad

local function setCoefs(f, c)
	f[1], f[2], f[3], f[4], f[5] = c[1], c[2], c[3], c[4], c[5]
end

-- low-pass cutoff the page drives from rpm and throttle
function Synth.CutoffFor(rpm, thr, tone, pitch, voice)
	local fc = (420 + 1500 * thr * (0.5 + tone) + rpm * 0.22) * pitch
	if voice and voice > 0 then
		-- the engine's body, not its fizz: a lower, gentler opening with revs and throttle
		local dark = (320 + 1000 * thr * (0.5 + tone) + rpm * 0.12) * pitch
		if dark > 2800 then dark = 2800 end
		fc = fc + (dark - fc) * voice
	end
	if fc < 200 then fc = 200 elseif fc > 5500 then fc = 5500 end
	return fc
end

local function zeros(n)
	local t = {}
	for i = 1, n do t[i] = 0 end
	return t
end

function Synth.NewChain(sr, cfg)
	local tone = cfg.tone
	local R = realismOf(cfg)
	-- a car's silencer (cfg.muffle 0-1, economy cars): lower cutoffs and more treble cut
	local muffle = cfg.muffle or 0
	local d = floor(0.0052 * sr + 0.5)
	local k = 0.15 + 1.6 * tone * tone
	local tp = floor(0.0115 * sr + 0.5)
	-- small outdoor space (the page used a 0.11 s decaying noise burst; this is a Schroeder
	-- reverb with the same ~0.75 s decay)
	local combs = {}
	for i, ms in ipairs({ 25.3, 26.9, 28.9, 30.7 }) do
		local len = floor(ms / 1000 * sr + 0.5)
		combs[i] = { buf = zeros(len), n = len, pos = 1, lp = 0, fb = 10 ^ (-3 * (ms / 1000) / 0.75) }
	end
	local aps = {}
	for i, ms in ipairs({ 12.6, 10.0 }) do
		local len = floor(ms / 1000 * sr + 0.5)
		aps[i] = { buf = zeros(len), n = len, pos = 1 }
	end
	return {
		sr = sr,
		hpf = biquad("highpass", 30, sr, 0.7),
		drive = k, driveNorm = 1 / tanh(k),
		peak = biquad("peaking", 95, sr, 1.0, 3 + tone * 5),
		low = biquad("lowshelf", 130 + 20 * R.voice, sr, 1, 4 + 2 * R.voice),
		lpf = biquad("lowpass", 700, sr, 0.5),
		lpf2 = biquad("lowpass", (4200 - 800 * R.voice) * (1 - 0.5 * muffle), sr, 0.6),
		tloop = biquad("lowpass", 1900, sr, 1),
		shelf = biquad("highshelf", 2500, sr, 1, -8 - 8 * muffle),
		tube = zeros(d), tubeN = d, tubePos = 1,
		tail = zeros(tp), tailN = tp, tailPos = 1, tailLp = 0,
		tailWet = R.tailpipe, tailK = 1 - exp(-TAU * 1200 / sr),
		combs = combs, aps = aps, verbWet = R.reverb, verbLpK = 0.35,
		fc = 700, fcTarget = 700, muffleK = 1 - 0.35 * muffle,
		ev = cfg.layout == "electric",
	}
end

-- WebAudio setTargetAtTime(fc, t, 0.06): approach the new cutoff with a 60 ms time constant
local function updateCutoff(ch, n)
	local a = 1 - exp(-(n / ch.sr) / 0.06)
	ch.fc = ch.fc + (ch.fcTarget - ch.fc) * a
	setCoefs(ch.lpf, biquad("lowpass", ch.fc * ch.muffleK, ch.sr, 0.5))
end

-- run buf[o .. o+n-1] through the chain in place
local function chainBlock(ch, buf, o, n)
	if ch.ev then return end   -- an electric motor has no exhaust: the whine goes out as it is
	local h, p, lw, lp1, lp2, tl, sh = ch.hpf, ch.peak, ch.low, ch.lpf, ch.lpf2, ch.tloop, ch.shelf
	local hb0, hb1, hb2, ha1, ha2, hz1, hz2 = h[1], h[2], h[3], h[4], h[5], h[6], h[7]
	local pb0, pb1, pb2, pa1, pa2, pz1, pz2 = p[1], p[2], p[3], p[4], p[5], p[6], p[7]
	local wb0, wb1, wb2, wa1, wa2, wz1, wz2 = lw[1], lw[2], lw[3], lw[4], lw[5], lw[6], lw[7]
	local lb0, lb1, lb2, la1, la2, lz1, lz2 = lp1[1], lp1[2], lp1[3], lp1[4], lp1[5], lp1[6], lp1[7]
	local mb0, mb1, mb2, ma1, ma2, mz1, mz2 = lp2[1], lp2[2], lp2[3], lp2[4], lp2[5], lp2[6], lp2[7]
	local tb0, tb1, tb2, ta1, ta2, tz1, tz2 = tl[1], tl[2], tl[3], tl[4], tl[5], tl[6], tl[7]
	local sb0, sb1, sb2, sa1, sa2, sz1, sz2 = sh[1], sh[2], sh[3], sh[4], sh[5], sh[6], sh[7]
	local k, kn = ch.drive, ch.driveNorm
	local tube, tN, tPos = ch.tube, ch.tubeN, ch.tubePos
	local tail, tlN, tlPos, tlLp, tlWet, tlK = ch.tail, ch.tailN, ch.tailPos, ch.tailLp, ch.tailWet, ch.tailK
	local combs, aps, vWet, vK = ch.combs, ch.aps, ch.verbWet, ch.verbLpK
	local c1, c2, c3, c4 = combs[1], combs[2], combs[3], combs[4]
	local ap1, ap2 = aps[1], aps[2]
	for i = o, o + n - 1 do
		local x = buf[i]
		-- high-pass 30 Hz
		local y = hb0 * x + hz1; hz1 = hb1 * x - ha1 * y + hz2; hz2 = hb2 * x - ha2 * y
		-- drive (WaveShaper tanh curve; input outside +-1 sits on the curve ends)
		if y > 1 then y = 1 elseif y < -1 then y = -1 end
		x = tanh(k * y) * kn
		-- 95 Hz peak
		y = pb0 * x + pz1; pz1 = pb1 * x - pa1 * y + pz2; pz2 = pb2 * x - pa2 * y
		-- low shelf 130 Hz +4 dB
		x = y
		y = wb0 * x + wz1; wz1 = wb1 * x - wa1 * y + wz2; wz2 = wb2 * x - wa2 * y
		-- tracking low-pass
		x = y
		y = lb0 * x + lz1; lz1 = lb1 * x - la1 * y + lz2; lz2 = lb2 * x - la2 * y
		-- 4.2 kHz low-pass
		x = y
		y = mb0 * x + mz1; mz1 = mb1 * x - ma1 * y + mz2; mz2 = mb2 * x - ma2 * y
		-- exhaust tube: 5.2 ms delay, low-passed, fed back at -0.3, 0.3 wet
		x = y
		local dOut = tube[tPos]
		local lo = tb0 * dOut + tz1; tz1 = tb1 * dOut - ta1 * lo + tz2; tz2 = tb2 * dOut - ta2 * lo
		tube[tPos] = x - 0.3 * lo
		tPos = tPos + 1; if tPos > tN then tPos = 1 end
		x = x + 0.3 * lo
		-- tailpipe: a longer, darker reflection
		if tlWet > 0 then
			local tOut = tail[tlPos]
			tlLp = tlLp + (tOut - tlLp) * tlK
			tail[tlPos] = x - 0.25 * tlLp
			tlPos = tlPos + 1; if tlPos > tlN then tlPos = 1 end
			x = x + tlWet * tlLp
		end
		-- high shelf 2.5 kHz -8 dB
		y = sb0 * x + sz1; sz1 = sb1 * x - sa1 * y + sz2; sz2 = sb2 * x - sa2 * y
		-- outdoor space
		if vWet > 0 then
			local acc = 0
			local cb = c1; local v = cb.buf[cb.pos]; cb.lp = cb.lp + (v - cb.lp) * vK; cb.buf[cb.pos] = y + cb.lp * cb.fb; cb.pos = cb.pos % cb.n + 1; acc = acc + v
			cb = c2; v = cb.buf[cb.pos]; cb.lp = cb.lp + (v - cb.lp) * vK; cb.buf[cb.pos] = y + cb.lp * cb.fb; cb.pos = cb.pos % cb.n + 1; acc = acc + v
			cb = c3; v = cb.buf[cb.pos]; cb.lp = cb.lp + (v - cb.lp) * vK; cb.buf[cb.pos] = y + cb.lp * cb.fb; cb.pos = cb.pos % cb.n + 1; acc = acc + v
			cb = c4; v = cb.buf[cb.pos]; cb.lp = cb.lp + (v - cb.lp) * vK; cb.buf[cb.pos] = y + cb.lp * cb.fb; cb.pos = cb.pos % cb.n + 1; acc = acc + v
			acc = acc * 0.25
			local a = ap1; local bv = a.buf[a.pos]; local ao = bv - 0.5 * acc; a.buf[a.pos] = acc + 0.5 * ao; a.pos = a.pos % a.n + 1
			a = ap2; bv = a.buf[a.pos]; local ao2 = bv - 0.5 * ao; a.buf[a.pos] = ao + 0.5 * ao2; a.pos = a.pos % a.n + 1
			y = y + vWet * ao2
		end
		buf[i] = y
	end
	h[6], h[7] = hz1, hz2; p[6], p[7] = pz1, pz2; lw[6], lw[7] = wz1, wz2
	lp1[6], lp1[7] = lz1, lz2; lp2[6], lp2[7] = mz1, mz2; tl[6], tl[7] = tz1, tz2; sh[6], sh[7] = sz1, sz2
	ch.tubePos = tPos
	ch.tailPos, ch.tailLp = tlPos, tlLp
end
Synth.ChainBlock = chainBlock

local BLOCK = 256

---------------------------------------------------------------------------
-- Renderer: generator + chain, driven by a control function at 60 Hz like the page
---------------------------------------------------------------------------
--[[
	opts.control(t, dt) -> called every 1/60 s, returns a table of generator targets:
	    { tRpm=, tThr=, cut=, crank=, on= }  (the same message the page posts to its worklet)
	Returns the rendered array (1-based) from sample skip+1 to total.
]]
function Synth.RenderControlled(g, ch, opts, total, yieldFn)
	local sr = g.sr
	local out = {}
	local ctlEvery = floor(sr / 60 + 0.5)
	local nextCtl = 0
	local t = 0
	local pos = 0
	local tone, pitch = g.tone, g.pitch
	local skip = opts.skip or 0
	local scratch = {}
	local sinceYield = 0
	while pos < total do
		if pos >= nextCtl then
			local m = opts.control(t, ctlEvery / sr)
			if m then
				for key, v in pairs(m) do g[key] = v end
				ch.fcTarget = Synth.CutoffFor(m.tRpm or g.tRpm, m.tThr or g.tThr, tone, pitch, g.R.voice)
			end
			nextCtl = nextCtl + ctlEvery
			t = t + ctlEvery / sr
		end
		local n = min(BLOCK, nextCtl - pos, total - pos)
		updateCutoff(ch, n)
		Synth.GenRender(g, scratch, 1, n)
		chainBlock(ch, scratch, 1, n)
		for i = 1, n do
			local idx = pos + i - skip
			if idx >= 1 then out[idx] = scratch[i] end
		end
		pos = pos + n
		sinceYield = sinceYield + n
		if yieldFn and sinceYield >= 4096 then sinceYield = 0; yieldFn() end
	end
	return out
end

local function newEngine(cfg, sr)
	return Synth.NewGen(sr, cfg), Synth.NewChain(sr, cfg)
end
Synth.NewEngine = newEngine

-- turn buf[1 .. L+X] into a seamless loop of length L by cross-fading the tail into the head
local function makeLoop(buf, L, X)
	local y = {}
	for i = 1, L do y[i] = buf[i] end
	for i = 1, X do
		local a = (i - 0.5) / X                 -- 0 -> 1
		local fin = 0.5 - 0.5 * cos(pi * a)     -- raised cosine
		y[i] = buf[i] * fin + buf[L + i] * (1 - fin)
	end
	return y
end
Synth.MakeLoop = makeLoop

--[[
	A steady loop at one rpm and throttle. Loops with the same rpm have the same length and
	the same firing phase (same random seed, pops off), so on/off-throttle layers of a band
	can be cross-faded in game without the pulses flamming.
]]
function Synth.RenderSteadyLoop(cfg, sr, rpm, thr, yieldFn, loopSec)
	local g, ch = newEngine(cfg, sr)
	g.allowPops = false
	g.on = true; g.gain = 1
	g.rpm, g.tRpm, g.thr, g.tThr = rpm, rpm, thr, thr
	local fc = Synth.CutoffFor(rpm, thr, cfg.tone, cfg.pitch, g.R.voice)
	ch.fc, ch.fcTarget = fc, fc
	local cycle = sr * 120 / (rpm * cfg.pitch)           -- samples per 720 degree cycle
	local nCycles = math.max(2, math.ceil(sr * (loopSec or 1.6) / cycle))
	local L = floor(nCycles * cycle + 0.5)
	local X = floor(min(sr * 0.12, L * 0.25))
	local warm = floor(sr * 1.0)
	local buf = Synth.RenderControlled(g, ch, {
		skip = warm,
		control = function() return { tRpm = rpm, tThr = thr, cut = false, crank = 0, on = true } end,
	}, warm + L + X, yieldFn)
	return makeLoop(buf, L, X), L, g.agc
end

-- free-revving in neutral against the limiter (the page with the pedal held in N)
function Synth.LimiterControl(cfg)
	local DT = AUDIO_ENGINE.Drivetrain
	local st = { rpm = cfg.redline - 600, limT = 0 }
	local steps = 0
	local events = {}
	local fn = function(t, dt)
		local thr, cut = 1, false
		if st.rpm >= cfg.redline then
			if st.limT <= 0 then events[#events + 1] = steps end
			st.limT = 0.07
		end
		if st.limT > 0 then st.limT = st.limT - dt; thr = 0; cut = true end
		local idleThr = DT.clamp((cfg.idle - st.rpm) / 400, 0, 0.3)
		local engThr = cut and 0 or math.max(thr, idleThr)
		local Te = engThr * DT.TMAX * DT.TorqueNorm(cfg, st.rpm) - DT.TMAX * (0.05 + 0.12 * st.rpm / cfg.redline)
		st.rpm = DT.clamp(st.rpm + Te * 42 * (cfg.redline / 7000) * dt, 0, cfg.redline + 150)
		steps = steps + 1
		return { tRpm = st.rpm, tThr = engThr, cut = cut, crank = 0, on = true }
	end
	return fn, events
end

function Synth.RenderLimiterLoop(cfg, sr, yieldFn)
	-- find the bounce period first (cheap, control rate only)
	local probe, ev = Synth.LimiterControl(cfg)
	for i = 0, 600 do probe(i / 60, 1 / 60) end
	local period = 6
	if #ev >= 4 then period = ev[#ev] - ev[#ev - 1] end
	local nb = math.max(1, math.floor(60 * 1.0 / period + 0.5))  -- ~1 s of bounces
	local spc = floor(sr / 60 + 0.5)
	local L = nb * period * spc
	local X = floor(min(sr * 0.03, period * spc * 0.4))
	local warmSteps = 240 + (period - 240 % period)
	local warm = warmSteps * spc
	local g, ch = newEngine(cfg, sr)
	g.allowPops = false
	g.on = true; g.gain = 1
	g.rpm, g.tRpm = cfg.redline - 600, cfg.redline - 600
	local ctl = Synth.LimiterControl(cfg)
	local buf = Synth.RenderControlled(g, ch, { skip = warm, control = ctl }, warm + L + X, yieldFn)
	return makeLoop(buf, L, X), L
end

--[[
	Start-up one-shot: the page's catch -> flare -> settle sequence, followed by a short
	stretch of idle that fades out while the idle loops fade in.
]]
function Synth.RenderStart(cfg, sr, emotion, yieldFn)
	local DT = AUDIO_ENGINE.Drivetrain
	local st = DT.New()
	DT.Start(st, emotion)
	local tail = 0.45
	local ctl = function(t, dt)
		if st.phase ~= "run" then
			DT.StartSequence(st, cfg, dt)
		else
			local idleThr = DT.clamp((cfg.idle - st.rpm) / 400, 0, 0.3)
			local Te = idleThr * DT.TMAX * DT.TorqueNorm(cfg, st.rpm) - DT.TMAX * (0.05 + 0.12 * st.rpm / cfg.redline)
			st.rpm = st.rpm + Te * 42 * (cfg.redline / 7000) * dt
			st.soundThr = idleThr
		end
		return { tRpm = st.rpm, tThr = st.soundThr, cut = st.cut, crank = st.crankMode, on = true }
	end
	-- dry run at control rate to learn the length
	local probe = DT.New(); DT.Start(probe, emotion)
	local steps = 0
	while probe.phase ~= "run" and steps < 60 * 10 do DT.StartSequence(probe, cfg, 1 / 60); steps = steps + 1 end
	local fadeAt = steps / 60
	local dur = fadeAt + tail
	local total = floor(dur * sr)
	local g, ch = newEngine(cfg, sr)
	g.allowPops = false
	g.rpm, g.tRpm = 150, 150
	local buf = Synth.RenderControlled(g, ch, { control = ctl }, total, yieldFn)
	local f0 = floor(fadeAt * sr)
	for i = f0 + 1, total do
		local a = (i - f0) / (total - f0)
		buf[i] = buf[i] * (0.5 + 0.5 * cos(pi * a))
	end
	return buf, fadeAt, dur
end

-- Shut-down one-shot: ignition off at idle, the crank spins down with compression thumps
function Synth.RenderStop(cfg, sr, yieldFn)
	local g, ch = newEngine(cfg, sr)
	g.allowPops = false
	local idle = cfg.idle
	local rpm = idle
	local warm = floor(sr * 1.2)
	local ctl = function(t, dt)
		if t < warm / sr then
			return { tRpm = idle, tThr = 0.08, cut = false, crank = 0, on = true }
		end
		rpm = math.max(0, rpm - (500 + rpm * 1.6) * dt)
		return { tRpm = rpm, tThr = 0, cut = true, crank = rpm < 450 and 1 or 0, on = rpm > 25 }
	end
	g.on = true; g.gain = 1
	g.rpm, g.tRpm, g.thr, g.tThr = idle, idle, 0.08, 0.08
	local dur = 1.6
	local buf = Synth.RenderControlled(g, ch, { skip = warm, control = ctl }, warm + floor(dur * sr), yieldFn)
	-- a short fade-in so it can start on top of the fading loops, and a fade-out of the reverb tail
	local fi = floor(sr * 0.02)
	for i = 1, fi do buf[i] = buf[i] * (i / fi) end
	local fo = floor(sr * 0.25)
	for i = 1, fo do local j = #buf - fo + i; buf[j] = buf[j] * (1 - i / fo) end
	return buf, dur
end

-- Overrun pop one-shot: the page's pop noise burst through the same chain
function Synth.RenderPops(cfg, sr, seed, count, agc, yieldFn)
	local g, ch = newEngine(cfg, sr)
	g.seed = seed
	g.allowPops = false
	g.noFire = true
	g.fixedAgc = agc or 1
	g.on = true; g.gain = 1
	local rpm = 4200
	g.rpm, g.tRpm = rpm, rpm
	local fc = Synth.CutoffFor(rpm, 0, cfg.tone, cfg.pitch)
	ch.fc, ch.fcTarget = fc, fc
	local popChance = 0.6  -- fixed strength; how often and how loud is up to the game
	local times = {}
	local tt = 0.004
	for i = 1, count do
		times[i] = tt
		tt = tt + 0.025 + 0.05 * (Synth.Rand(g) * 0.5 + 0.5)
	end
	local fired = 0
	local dur = tt + 0.2
	local buf = Synth.RenderControlled(g, ch, {
		control = function(t)
			if fired < count and t >= times[fired + 1] then
				fired = fired + 1
				g.pop = (0.3 + 0.1 * Synth.Rand(g)) * popChance
			end
			return { tRpm = rpm, tThr = 0, cut = true, crank = 0, on = true }
		end,
	}, floor(dur * sr), yieldFn)
	return buf, dur
end

--[[
	Bang: a big backfire. A sharp pressure pulse through both exhaust banks' resonators (the
	boom) plus a burst of the pop noise (the crack).
]]
function Synth.RenderBang(cfg, sr, seed, agc, yieldFn)
	local g, ch = newEngine(cfg, sr)
	g.seed = seed
	g.allowPops = false
	g.noFire = true
	g.fixedAgc = agc or 1
	g.on = true; g.gain = 1
	local rpm = 3500
	g.rpm, g.tRpm = rpm, rpm
	local fc = Synth.CutoffFor(rpm, 1, cfg.tone, cfg.pitch)
	ch.fc, ch.fcTarget = fc, fc
	local tA, tB, tN = exp(-1 / (sr * 0.018)), exp(-1 / (sr * 0.0012)), exp(-1 / (sr * 0.03))
	local fired = false
	local dur = 0.6
	local buf = Synth.RenderControlled(g, ch, {
		control = function(t)
			if not fired and t >= 0.01 then
				fired = true
				local k = 2.2 + 0.4 * Synth.Rand(g)
				g.tauA, g.tauB, g.tauN, g.tauAR, g.tauBR, g.tauNR = tA, tB, tN, tA, tB, tN
				g.env, g.envB, g.nenv = k, k, k * 0.8
				g.envR, g.envBR, g.nenvR = k * 0.9, k * 0.9, k * 0.7
				g.pop = 1.0 + 0.2 * Synth.Rand(g)
			end
			return { tRpm = rpm, tThr = 1, cut = true, crank = 0, on = true }
		end,
	}, floor(dur * sr), yieldFn)
	local fo = floor(sr * 0.15)
	for i = 1, fo do local j = #buf - fo + i; buf[j] = buf[j] * (1 - i / fo) end
	return buf, dur
end

--[[
	Exhaust pops & bangs (backfires).
	A backfire is a pressure impulse: a near-instant rise, a few milliseconds of decay, and a
	burst of turbulent gas noise. It has no pitch, so there are no resonators or feedback
	delays here (those make it twang like a string). It's only an impulse plus a very short
	noise burst, shaped by broad filters and a little saturation for the crack.
	kind: "pop" (one small crack), "crackle" (a quick burst of 4-6), "bang" (one big boom)
]]
function Synth.RenderBackfire(cfg, sr, seed, kind, yieldFn)
	local rnd = seededRand(seed or 0xBAC4)
	local function r01() return rnd() * 0.5 + 0.5 end
	local function lerp(a, b, t) return a + (b - a) * t end
	local big = kind == "bang"
	-- 0 = muffled (through the silencers), 1 = sharp (straight pipe)
	local sharp = cfg.popTone or 0.2

	--[[
		Events (time, strength). Real overrun pops aren't evenly spaced clicks: unburnt fuel lights
		in a few exhaust pulses in a row, so they come as a ragged "b-r-rap" (a run of quick,
		uneven pops that swells and fades) or a single pop with a weaker echo.
	]]
	local ev = {}
	if kind == "crackle" then
		local t, count = 0.004, 4 + floor(r01() * 5)
		for i = 1, count do
			local x = (i - 0.5) / count
			local swell = math.sin(math.pi * x) ^ 0.7          -- builds, then dies away
			if i == 1 or r01() > 0.15 then                      -- now and then a pulse doesn't light
				ev[#ev + 1] = { t, (0.35 + 0.65 * swell) * (0.6 + 0.4 * r01()) }
			end
			t = t + 0.018 + 0.04 * r01() * r01()                -- mostly quick, a few longer gaps
		end
	elseif big then
		ev[1] = { 0.004, 1 }
		local t = 0.06 + 0.06 * r01()
		for i = 1, floor(r01() * 3) do                          -- an after-pop or two
			ev[#ev + 1] = { t, (0.45 - 0.12 * i) * (0.7 + 0.3 * r01()) }
			t = t + 0.035 + 0.06 * r01()
		end
	else
		ev[1] = { 0.004, 0.8 + 0.2 * r01() }
		if r01() < 0.35 then ev[2] = { 0.022 + 0.025 * r01(), 0.3 + 0.2 * r01() } end
	end

	--[[
		Each pop = a pressure thump + the scatter: the wave rattling out through the muffler
		chambers, a dense random burst of reflections tens of ms long. The thump rises over about
		a millisecond and the scatter rings on: a short, sharp spike with a quick tail is what made
		them sound like firecrackers / popcorn. Nothing here is periodic, so nothing has a pitch.
	]]
	local direct = lerp(0.18, 0.5, sharp)
	local tauR, tauD = big and 0.0012 or 0.0009, big and 0.007 or 0.0042
	local scatAtk = lerp(0.004, 0.0022, sharp)
	local scatDec = big and lerp(0.1, 0.07, sharp) or lerp(0.05, 0.035, sharp)
	local dur = ev[#ev][1] + (big and 0.45 or 0.24)
	local n = floor(dur * sr)

	local scatF = {
		biquad("highpass", big and 70 or 90, sr, -3),
		biquad("lowpass", lerp(650, 1600, sharp), sr, -3),
	}
	local shape = {
		biquad("highpass", big and 40 or 55, sr, -3),
		biquad("peaking", big and 140 or 190, sr, 0.9, 6),   -- the exhaust's body
		biquad("lowshelf", 150, sr, 1, big and 4 or 2),
		biquad("lowpass", lerp(1000, 2200, sharp), sr, -3),
	}
	local function run(fs, x)
		for k = 1, #fs do
			local f = fs[k]
			local yv = f[1] * x + f[6]
			f[6] = f[2] * x - f[4] * yv + f[7]
			f[7] = f[3] * x - f[5] * yv
			x = yv
		end
		return x
	end

	local raw = {}
	for i = 1, n do
		local t = (i - 1) / sr
		local src, scat = 0, 0
		for _, e in ipairs(ev) do
			local dt = t - e[1]
			if dt >= 0 and dt < 0.4 then
				src = src + e[2] * (1 - exp(-dt / tauR)) * exp(-dt / tauD)
				scat = scat + e[2] * (1 - exp(-dt / scatAtk)) * exp(-dt / scatDec)
			end
		end
		local x = src * direct * 2.2 + run(scatF, rnd()) * scat * 2.0
		raw[i] = run(shape, x)
		if yieldFn and i % 8192 == 0 then yieldFn() end
	end

	local peak = 1e-9
	for i = 1, n do local a = abs(raw[i]); if a > peak then peak = a end end
	local drive = lerp(0.8, 1.4, sharp) + (big and 0.2 or 0)   -- less saturation: a rounder crack
	local norm = 1 / tanh(drive)
	local out = {}
	for i = 1, n do out[i] = tanh(drive * raw[i] / peak) * norm end
	local fo = floor(sr * 0.025)
	for i = 1, fo do local j = n - fo + i; out[j] = out[j] * (1 - i / fo) end
	return out, dur
end

--[[
	Exhaust pops (the version that's used). Overrun pops are unburnt fuel going off in the
	exhaust: an oversized exhaust pulse that travels through the same pipes and mufflers as
	every other firing. So this fires big pulses straight into the engine's own exhaust model
	(both banks' resonances, the drive, the muffled low-pass, the pipe) instead of
	synthesising a separate bang. They come out as a muffled "bup" in the engine's own voice.
	kind: "pop" (one), "crackle" (a quick uneven burst), "bang" (one big one plus an after-pop)
]]
function Synth.RenderExhaustPop(cfg, sr, seed, kind, yieldFn)
	local rnd = seededRand(seed or 0x9091)
	local function r01() return rnd() * 0.5 + 0.5 end
	local big = kind == "bang"
	local g, ch = newEngine(cfg, sr)
	g.seed = seed or 0x9091
	g.allowPops = false
	g.noFire = true              -- no regular firing, only our pulses
	g.fixedAgc = 1
	g.on = true; g.gain = 1
	local rpm = big and 3000 or 3800
	g.rpm, g.tRpm, g.thr, g.tThr = rpm, rpm, 0, 0
	-- muffled: the overrun low-pass, a little brighter for bangs
	local fc = Synth.CutoffFor(rpm, big and 0.35 or 0.15, cfg.tone, cfg.pitch)
	ch.fc, ch.fcTarget = fc, fc
	ch.lpf = biquad("lowpass", fc, sr, 0.5)
	ch.verbWet = 0.04            -- dry: no reverb tail

	local ev = {}
	if kind == "crackle" then
		local t = 0.004
		for i = 1, 3 + floor(r01() * 3) do
			ev[#ev + 1] = { t, 0.55 + 0.45 * r01() }
			t = t + 0.03 + 0.07 * r01()
		end
	elseif big then
		ev[1] = { 0.004, 1 }
		if r01() < 0.75 then ev[2] = { 0.07 + 0.05 * r01(), 0.35 + 0.15 * r01() } end
	else
		ev[1] = { 0.004, 0.8 + 0.2 * r01() }
	end
	local dur = ev[#ev][1] + (big and 0.32 or 0.16)
	local total = floor(dur * sr)

	local out, scratch = {}, {}
	local pos, nextEv = 0, 1
	while pos < total do
		-- fire any pulse due now
		while nextEv <= #ev and ev[nextEv][1] * sr <= pos do
			local amp = ev[nextEv][2]
			local k = (big and 6 or 3.2) * amp * (0.9 + 0.2 * r01())
			local tau = big and (0.008 + 0.003 * r01()) or (0.0045 + 0.002 * r01())
			local tA, tB, tN = exp(-1 / (sr * tau)), exp(-1 / (sr * min(tau * 0.22, 0.0018))), exp(-1 / (sr * tau * 0.6))
			if big or r01() < 0.5 then
				g.tauA, g.tauB, g.tauN = tA, tB, tN
				g.env, g.envB, g.nenv = g.env + k, g.envB + k, g.nenv + k * 0.5
			end
			if big or r01() >= 0.5 or g.env < 0.01 then
				g.tauAR, g.tauBR, g.tauNR = tA, tB, tN
				local kr = big and k * 0.85 or k
				g.envR, g.envBR, g.nenvR = g.envR + kr, g.envBR + kr, g.nenvR + kr * 0.5
			end
			nextEv = nextEv + 1
		end
		local untilEv = nextEv <= #ev and floor(ev[nextEv][1] * sr) - pos or math.huge
		local n = min(128, total - pos, math.max(1, untilEv))
		Synth.GenRender(g, scratch, 1, n)
		chainBlock(ch, scratch, 1, n)
		for i = 1, n do out[pos + i] = scratch[i] end
		pos = pos + n
		if yieldFn and pos % 8192 < 128 then yieldFn() end
	end
	-- keep the exhaust's voice but lose the 78 Hz boom: the "bap" lives in the upper pipe modes
	local hpA = biquad("highpass", big and 95 or 140, sr, 0)
	local hpB = biquad("highpass", big and 95 or 140, sr, 0)
	local bark = biquad("peaking", big and 380 or 480, sr, 0.7, 7)
	for i = 1, total do
		local x = out[i]
		for _, f in ipairs({ hpA, hpB, bark }) do
			local yv = f[1] * x + f[6]
			f[6] = f[2] * x - f[4] * yv + f[7]
			f[7] = f[3] * x - f[5] * yv
			x = yv
		end
		out[i] = x
	end
	local fo = floor(sr * 0.04)
	for i = 1, fo do local j = total - fo + i; out[j] = out[j] * (1 - i / fo) end
	return out, dur
end

---------------------------------------------------------------------------
-- Turbo
---------------------------------------------------------------------------
local function noiseGen(seed)
	local s = seed
	return function()
		s = bxor(s, lshift(s, 13)); s = bxor(s, rshift(s, 17)); s = bxor(s, lshift(s, 5))
		return s / 2147483648
	end
end

local function runBiquad(f, x)
	local y = f[1] * x + f[6]
	f[6] = f[2] * x - f[4] * y + f[7]
	f[7] = f[3] * x - f[5] * y
	return y
end

--[[
	Turbo loop at full boost: a soft, round compressor whine with a little bearing wobble and
	a narrow band of air around the tone (broadband intake rush sounded like a vacuum cleaner).
	Everything above ~3 kHz is rolled off. The game pitches it with boost.
]]
function Synth.RenderTurboLoop(sr, yieldFn)
	local rnd = noiseGen(0x5EED7)
	local fw = 1700
	local L = floor(sr * 1.5)
	local X = floor(sr * 0.15)
	local total = L + X
	local buf = {}
	local ph = 0
	local drift = 0
	local air = biquad("bandpass", fw, sr, 3)
	local cut1 = biquad("lowpass", 3200, sr, 0)
	local cut2 = biquad("lowpass", 3200, sr, 0)
	for i = 1, total do
		local nz = rnd()
		drift = drift + (nz - drift) * 0.0004
		local f = fw * (1 + 0.008 * drift * 30)
		ph = ph + f / sr; if ph >= 1 then ph = ph - 1 end
		local tone = sin(TAU * ph) * 0.8 * (1 + 0.08 * sin(TAU * 7 * i / sr))
		buf[i] = runBiquad(cut2, runBiquad(cut1, tone + runBiquad(air, rnd()) * 1.4))
		if yieldFn and i % 8192 == 0 then yieldFn() end
	end
	return makeLoop(buf, L, X), L
end

--[[
	Supercharger loop: a belt-driven blower spins with the crank, so unlike the turbo its whine
	is locked to the revs. Rendered in bands an octave apart (SC_BANDS, rpm at the whine pitch
	the variant is tuned to); cl_engine cross-fades the two around the revs x cfg.scPitch, like
	the engine's bands. The game's pitch is a whole percent: one loop pitched from rpm / 2800
	played at ~27% at idle (3.7% steps, a staircase as the revs crept) and a lower-geared blower
	(scPitch 0.35) would have been at ~10%. In bands it stays between ~55 and 200%.
	Each variant has two loops a band: on boost (`off` false) and bypass open (`off` true: off
	the throttle the blower idles through its bypass valve, duller and quieter).
	Beyond the whine itself: the firing pulses wobble the belt and rotor speed (FM at a V8's
	firing rate), each lobe pushes a puff of intake air, rotor runout puts sidebands on the
	whine, the timing gears add a faint second line, boost hisses on load, and the partials
	drift slowly in level.
	  sport    sporty cars (Ford GT, SLR, ZL1, F-Type...): the brightest, with the boost hiss
	  regular  saloons and SUVs: gentler and darker
	  heavy    trucks: a bigger, slower-driven blower (lower whine), deep lobe puffs, little hiss
	fw (whine Hz), cut and the air bands are given at SC_DESIGN_RPM. `level` is how loud the
	variant plays relative to sport (cl_engine, runtime).
	Seamless: every tone (whine, rotor turn, timing gears, firing rate) and every slow wobble is
	rounded to whole cycles over the loop, so its end runs straight into its start. The tone then
	crosses over unchanged and only the air noise is cross-faded (equal power). With random
	wobbles the tone came back out of phase and the cross-fade cancelled it: a 5 dB dip on every
	pass, a pulse ~1.5 times a second when pitched up at redline.
]]
Synth.SC_BANDS = { 375, 750, 1500, 3000, 6000 }
local SC_DESIGN_RPM = 4000
Synth.SC_VARIANTS = {
	sport = { fw = 1350, h = { 1, 0.16, 0.06 }, ripple = 0.08, rippleDiv = 6, air = 1.0, airQ = 2.5,
		cut = 3600, drift = 0.010, level = 1,
		fm = 0.008, am = 0.18, puff = 0.7, runout = 0.10, gear = 0.12, hiss = 0.5, jitter = 0.2 },
	regular = { fw = 1300, h = { 1, 0.11, 0.03 }, ripple = 0.06, rippleDiv = 6, air = 1.1, airQ = 2,
		cut = 2900, drift = 0.009, level = 0.6,
		fm = 0.006, am = 0.14, puff = 0.6, runout = 0.08, gear = 0.08, hiss = 0.3, jitter = 0.18 },
	heavy = { fw = 950, h = { 1, 0.20, 0.07 }, ripple = 0.10, rippleDiv = 6, air = 1.2, airQ = 1.6,
		cut = 2100, drift = 0.010, level = 0.45,
		fm = 0.010, am = 0.22, puff = 0.85, runout = 0.12, gear = 0.06, hiss = 0.15, jitter = 0.2 },
}

Synth.SC_ORDER = { "sport", "regular", "heavy" }

function Synth.RenderSuperchargerLoop(sr, variant, yieldFn, off, bandRpm)
	local v = Synth.SC_VARIANTS[variant] or Synth.SC_VARIANTS.sport
	-- designed at SC_DESIGN_RPM and rendered at the band's rpm: render as if at another sample
	-- rate, which is exactly the game pitching it
	local fs = sr * SC_DESIGN_RPM / bandRpm
	local rnd = noiseGen(0x5C0A1)
	local L = floor(sr * 1.5)
	local X = floor(sr * 0.15)
	local total = L + X
	-- the loop's length in design time: every periodic part gets a whole number of cycles in it
	local T = L / fs
	local function whole(hz) return max(1, floor(hz * T + 0.5)) / T end
	-- the whine, so the rotor turn (whine / rippleDiv) comes out whole too
	local fw = max(1, floor(v.fw * T / v.rippleDiv + 0.5)) * v.rippleDiv / T
	local gearRatio = floor(1.37 * fw * T + 0.5) / (fw * T)
	local fireHz = whole(SC_DESIGN_RPM / 60 * 4)   -- a V8 fires 4 times a crank turn
	-- slow wobbles: two whole-cycle sines each, random phases, at the size of the low-passed noise
	-- they replace (rms 0.0097 drift, 0.0059 / 0.0059 / 0.0048 partial levels)
	local function wobble(rms, hzA, hzB)
		local a, b = whole(hzA), whole(hzB)
		return { a / fs, b / fs, rnd() * TAU, rnd() * TAU, rms }
	end
	local wobbles = { wobble(0.0097, 1.9, 3.1), wobble(0.0059, 1.3, 2.3), wobble(0.0059, 1.1, 2.7), wobble(0.0048, 0.95, 1.7) }
	local function wob(w, i) return w[5] * (sin(TAU * w[1] * i + w[3]) + sin(TAU * w[2] * i + w[4])) end
	local toneBuf, airBuf = {}, {}
	local ph, phr, phf, phg = 0, 0, 0, 0
	-- bypass open: the tone falls back, darker; on boost the intake hisses
	local toneLvl = off and 0.45 or 1
	local cut = off and v.cut * 0.6 or v.cut
	local air = biquad("bandpass", v.fw, fs, v.airQ)
	local hissF = biquad("bandpass", 2600, fs, 0.9)
	local cut1, cut2 = biquad("lowpass", cut, fs, 0), biquad("lowpass", cut, fs, 0)
	local cut3, cut4 = biquad("lowpass", cut, fs, 0), biquad("lowpass", cut, fs, 0)
	local h1, h2, h3 = v.h[1], v.h[2], v.h[3]
	local fm, am, puff, runout, gear, jit = v.fm, v.am, v.puff, v.runout, v.gear, v.jitter
	local hiss = off and 0 or v.hiss
	for i = 1, total do
		local drift, j2, j3, jl = wob(wobbles[1], i), wob(wobbles[2], i), wob(wobbles[3], i), wob(wobbles[4], i)
		-- firing pulses: the belt and rotors speed up and slow a hair on every power stroke
		phf = phf + fireHz / fs; if phf >= 1 then phf = phf - 1 end
		local pulse = sin(TAU * phf)
		local f = fw * (1 + v.drift * drift * 30) * (1 + fm * pulse)
		ph = ph + f / fs; if ph >= 1 then ph = ph - 1 end
		-- rotor turn (lobe pass / rippleDiv): runout puts sidebands either side of the whine
		phr = phr + f / v.rippleDiv / fs; if phr >= 1 then phr = phr - 1 end
		-- timing gears: a fainter, higher whine at their own ratio
		phg = phg + f * gearRatio / fs; if phg >= 1 then phg = phg - 1 end
		local a = TAU * ph
		local rot = sin(TAU * phr)
		local tone = h1 * sin(a + runout * 3 * rot)
			+ h2 * (1 + jit * 8 * j2) * sin(2 * a + 0.4)
			+ h3 * (1 + jit * 8 * j3) * sin(3 * a + 1.1)
			+ gear * sin(TAU * phg)
		tone = tone * (1 + v.ripple * rot) * (1 + am * pulse) * (1 + jit * 6 * jl) * 0.6 * toneLvl
		-- intake air, pushed in puffs as each lobe passes
		local lobe = 0.5 + 0.5 * sin(a)
		local x = runBiquad(air, rnd()) * v.air * (1 - puff + puff * 2 * lobe * lobe)
		if hiss > 0 then x = x + runBiquad(hissF, rnd()) * hiss * (1 + am * pulse) end
		toneBuf[i] = runBiquad(cut2, runBiquad(cut1, tone))
		airBuf[i] = runBiquad(cut4, runBiquad(cut3, x))
		if yieldFn and i % 8192 == 0 then yieldFn() end
	end
	-- the tone repeats exactly (its second pass has the filters settled); the noise doesn't, so
	-- it's cross-faded at equal power
	local y = {}
	for i = 1, L do
		if i <= X then
			local t = (i - 0.5) / X
			y[i] = toneBuf[L + i] + airBuf[i] * sin(t * pi / 2) + airBuf[L + i] * cos(t * pi / 2)
		else
			y[i] = toneBuf[i] + airBuf[i]
		end
	end
	return y, L
end

--[[
	Electric low-speed hum, like the pedestrian warning sound EVs play at walking pace: a soft,
	low tone (220 Hz and a little of its octave) in a breath of air, with a slow shimmer, no motor in it.
	cl_engine plays it at an almost fixed pitch and fades it out by ~30 km/h. Shared by every
	electric car (env bank).
]]
function Synth.RenderEVHumLoop(sr, yieldFn)
	local rnd = noiseGen(0xE7A5)
	local L = floor(sr * 2)
	local X = floor(sr * 0.2)
	local total = L + X
	local buf = {}
	local f0 = 220
	local air = biquad("bandpass", 900, sr, 0.8)
	local cut = biquad("lowpass", 1600, sr, 0)
	for i = 1, total do
		local t = i / sr
		-- two slightly detuned voices beat slowly (0.5 Hz): a living hum, not a test tone
		local shimmer = 1 + 0.15 * sin(TAU * 0.5 * t)
		local tone = 0.50 * sin(TAU * f0 * t)
			+ 0.10 * sin(TAU * (f0 * 2 + 0.5) * t) * shimmer
		buf[i] = runBiquad(cut, tone * 0.5 + runBiquad(air, rnd()) * 0.25)
		if yieldFn and i % 8192 == 0 then yieldFn() end
	end
	return makeLoop(buf, L, X), L
end

--[[
	Blow-off: on a recirculating valve (stock) it's a soft, dark "pshh" with a short tail and a
	gentle flutter as the compressor surges.
]]
function Synth.RenderBlowoff(sr, seed, yieldFn)
	local rnd = noiseGen(seed or 0xB10F)
	local dur = 0.5
	local n = floor(sr * dur)
	local buf = {}
	local b1 = biquad("bandpass", 900, sr, 0.7)
	local b2 = biquad("bandpass", 2200, sr, 1.0)
	local lp = biquad("lowpass", 4500, sr, 0)
	local flutterHz = 17 + 4 * rnd()
	for i = 1, n do
		local t = (i - 1) / sr
		local env = min(1, t / 0.008) * exp(-t / 0.12)
		local fl = 1 - 0.3 * exp(-t / 0.15) * (0.5 + 0.5 * sin(TAU * flutterHz * t))
		local v = runBiquad(b1, rnd()) * 1.2 + runBiquad(b2, rnd()) * 0.5
		buf[i] = runBiquad(lp, v) * env * fl
		if yieldFn and i % 8192 == 0 then yieldFn() end
	end
	return buf, dur
end

---------------------------------------------------------------------------
-- Rolling noise (not the engine): tyre roar on the road, and wind. Played by speed.
---------------------------------------------------------------------------
local function loopNoise(sr, seconds, xfade, seed, fn, yieldFn)
	local rnd = noiseGen(seed)
	local L = floor(sr * seconds)
	local X = floor(sr * xfade)
	local buf = {}
	for i = 1, L + X do
		buf[i] = fn(rnd, (i - 1) / sr)
		if yieldFn and i % 8192 == 0 then yieldFn() end
	end
	return makeLoop(buf, L, X), L
end

-- tyres on asphalt: a broad low-mid roar over a deep rumble from the road surface
function Synth.RenderRoadLoop(sr, yieldFn)
	local roar1 = biquad("bandpass", 420, sr, 0.6)
	local roar2 = biquad("lowpass", 1300, sr, -3)
	local rumble = biquad("lowpass", 110, sr, -3)
	local hp = biquad("highpass", 35, sr, -3)
	local y, L = loopNoise(sr, 2.0, 0.25, 0x0AD5, function(rnd)
		local r = runBiquad(roar2, runBiquad(roar1, rnd()))
		local d = runBiquad(rumble, rnd()) * 3.0
		return runBiquad(hp, r * 1.4 + d)
	end, yieldFn)
	return y, L
end

-- wind over the body: band-limited noise with slow gusts
function Synth.RenderWindLoop(sr, yieldFn)
	local hp = biquad("highpass", 280, sr, -3)
	local lp = biquad("lowpass", 2600, sr, -3)
	local body = biquad("peaking", 850, sr, 0.6, 4)
	local y, L = loopNoise(sr, 3.0, 0.3, 0x0B1D, function(rnd, t)
		local gust = 1 + 0.22 * sin(TAU * t / 3) + 0.12 * sin(TAU * 2 * t / 3 + 1.3)
		return runBiquad(body, runBiquad(lp, runBiquad(hp, rnd()))) * gust
	end, yieldFn)
	return y, L
end

return Synth
