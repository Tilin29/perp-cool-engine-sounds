--[[
	Police siren synth: renders one tone of POLICE_SIREN.CONFIG as a seamless loop.
	Plain Lua (no game calls): the game builds its sounds from it and dev/siren_studio runs the
	same file in the browser, so the studio plays exactly what the game will.

	A tone is a pitch pattern (points glided between and held) played on a wavetable made of the
	tone's harmonics, optionally doubled by a second voice, then a horn speaker: highpass, drive
	(soft clipping), a resonant peak and a lowpass. The loop is one pass of the pattern; every
	oscillator, wobble and the filters are made to line up at its ends:
	  * frequencies are scaled (by well under a cent) so each voice ends on a whole cycle
	  * vibrato and tremolo get a whole number of cycles per loop
	  * the loop is rendered twice and the second pass kept, so the filters are already settled
	The inside-the-car version adds a steeper lowpass (the car's body muffling it).
]]
POLICE_SIREN = POLICE_SIREN or {}
local Synth = {}
POLICE_SIREN.Synth = Synth

local TABLE_SIZE = 2048
local NYQUIST_SHARE = 0.45
local MIN_LOOP = 0.05
local PEAK = 0.95
local YIELD_EVERY = 8192
local TWO_PI = math.pi * 2

local floor, sin, cos, exp, max, min, abs = math.floor, math.sin, math.cos, math.exp, math.max, math.min, math.abs

local function round(x)
	return floor(x + 0.5)
end

local function tanh(x)
	if x > 15 then return 1 end
	if x < -15 then return -1 end
	local e = exp(2 * x)

	return (e - 1) / (e + 1)
end

-- the pattern as timed segments over one loop: a glide into each point, then its hold
function Synth.Segments(pattern)
	local segs, t = {}, 0
	local n = #pattern
	for i = 1, n do
		local p = pattern[i]
		local prev = pattern[i == 1 and n or i - 1]
		local glide, hold = max(p.glide or 0, 0), max(p.hold or 0, 0)
		if glide > 0 then
			segs[#segs + 1] = { t0 = t, t1 = t + glide, f0 = prev.f, f1 = p.f, curve = p.curve or 1 }
			t = t + glide
		end
		if hold > 0 then
			segs[#segs + 1] = { t0 = t, t1 = t + hold, f0 = p.f, f1 = p.f, curve = 1 }
			t = t + hold
		end
	end
	if t < MIN_LOOP then
		local f = n > 0 and pattern[1].f or 440
		segs = { { t0 = 0, t1 = MIN_LOOP, f0 = f, f1 = f, curve = 1 } }
		t = MIN_LOOP
	end

	return segs, t
end

local function segmentFreq(s, t, logGlide)
	if s.f0 == s.f1 then return s.f0 end
	local u = (t - s.t0) / (s.t1 - s.t0)
	u = min(max(u, 0), 1) ^ max(s.curve, 0.05)
	if logGlide and s.f0 > 0 and s.f1 > 0 then return s.f0 * (s.f1 / s.f0) ^ u end

	return s.f0 + (s.f1 - s.f0) * u
end

-- the pattern's frequency at every sample of the loop
local function patternFreqs(tone, pitch, sr)
	local segs, T = Synth.Segments(tone.pattern or {})
	local n = round(T * sr)
	local f, k = {}, 1
	for i = 0, n - 1 do
		local t = i / sr
		while k < #segs and t >= segs[k].t1 do k = k + 1 end
		f[i] = segmentFreq(segs[k], t, tone.logGlide ~= false) * pitch
	end

	return f, n, T
end

-- a single cycle holding the harmonics that stay under the Nyquist limit at this top frequency
local function wavetable(harmonics, topFreq, sr)
	local tbl, peak = {}, 0
	local limit = sr * NYQUIST_SHARE
	for i = 0, TABLE_SIZE - 1 do
		local x, ph = 0, TWO_PI * i / TABLE_SIZE
		for h = 1, #harmonics do
			local a = harmonics[h] or 0
			if a ~= 0 and h * topFreq < limit then x = x + a * sin(h * ph) end
		end
		tbl[i] = x
		peak = max(peak, abs(x))
	end
	if peak > 0 then
		for i = 0, TABLE_SIZE - 1 do tbl[i] = tbl[i] / peak end
	end
	tbl[TABLE_SIZE] = tbl[0]

	return tbl
end

-- RBJ biquad coefficients: "hp", "lp" or "peak"
local function biquad(kind, f, q, gainDb, sr)
	f = min(max(f, 10), sr * NYQUIST_SHARE)
	q = max(q, 0.1)
	local w = TWO_PI * f / sr
	local cw, alpha = cos(w), sin(w) / (2 * q)
	local b0, b1, b2, a0, a1, a2
	if kind == "hp" then
		b0, b1, b2 = (1 + cw) / 2, -(1 + cw), (1 + cw) / 2
		a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
	elseif kind == "lp" then
		b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
		a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
	else
		local a = 10 ^ (gainDb / 40)
		b0, b1, b2 = 1 + alpha * a, -2 * cw, 1 - alpha * a
		a0, a1, a2 = 1 + alpha / a, -2 * cw, 1 - alpha / a
	end

	return { b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0, 0, 0, 0, 0 }
end

local function runBiquad(c, x)
	local y = c[1] * x + c[2] * c[6] + c[3] * c[7] - c[4] * c[8] - c[5] * c[9]
	c[7], c[6] = c[6], x
	c[9], c[8] = c[8], y

	return y
end

-- scales a voice's frequencies so the loop holds a whole number of its cycles
local function wholeCycles(f, n, sr)
	local cycles = 0
	for i = 0, n - 1 do cycles = cycles + f[i] end
	cycles = cycles / sr
	if cycles <= 0 then return end
	local k = max(1, round(cycles)) / cycles
	for i = 0, n - 1 do f[i] = f[i] * k end
end

local function wholeRate(rate, T)
	if not rate or rate <= 0 then return 0 end

	return max(1, round(rate * T))
end

--[[
	Renders tone `tone` with the settings `cfg` (POLICE_SIREN.CONFIG's pitch/sampleRate/cabin).
	Returns the samples (1-based, peak PEAK), the sample rate and the loop length in samples.
	`yield`, if given, is called every few thousand samples (the game renders in a coroutine).
	`inside`: the version heard inside the car, muffled at cfg.cabin.muffle Hz.
]]
function Synth.Render(tone, cfg, yield, inside)
	local sr = cfg.sampleRate or 44100
	local f1, n, T = patternFreqs(tone, cfg.pitch or 1, sr)

	local vib = tone.vibrato or {}
	local vibCycles, vibDepth = wholeRate(vib.rate, T), (vib.depth or 0) / 1200
	if vibCycles > 0 and vibDepth ~= 0 then
		for i = 0, n - 1 do f1[i] = f1[i] * 2 ^ (vibDepth * sin(TWO_PI * vibCycles * i / n)) end
	end

	local v2 = tone.voice2 or {}
	local f2
	if v2.on then
		local ratio = 2 ^ (((v2.semitones or 0) + (v2.cents or 0) / 100) / 12)
		local shift = round((v2.offset or 0) * n) % n
		f2 = {}
		for i = 0, n - 1 do f2[i] = f1[(i + shift) % n] * ratio end
		wholeCycles(f2, n, sr)
	end
	wholeCycles(f1, n, sr)

	local top1, top2 = 0, 0
	for i = 0, n - 1 do
		top1 = max(top1, f1[i])
		if f2 then top2 = max(top2, f2[i]) end
	end
	local harmonics = tone.harmonics or { 1 }
	local tbl1 = wavetable(harmonics, top1, sr)
	local tbl2 = f2 and wavetable(harmonics, top2, sr)
	local level2 = v2.level or 0

	local trem = tone.tremolo or {}
	local tremCycles, tremDepth = wholeRate(trem.rate, T), min(max(trem.depth or 0, 0), 1)

	local sp = tone.speaker or {}
	local hp = biquad("hp", sp.highpass or 20, 0.707, 0, sr)
	local lp = biquad("lp", sp.lowpass or 20000, 0.707, 0, sr)
	local peak = biquad("peak", sp.resonance or 1000, sp.resonanceQ or 1, sp.resonanceGain or 0, sr)
	local drive = max(sp.drive or 0, 0)
	local driveNorm = drive > 0 and 1 / tanh(drive) or 1
	local muffleHz = inside and cfg.cabin and cfg.cabin.muffle
	local muffleA = muffleHz and biquad("lp", muffleHz, 0.707, 0, sr)
	local muffleB = muffleHz and biquad("lp", muffleHz, 0.707, 0, sr)

	local out, outPeak = {}, 0
	local ph1, ph2 = 0, 0
	for pass = 1, 2 do
		for i = 0, n - 1 do
			ph1 = (ph1 + f1[i] / sr) % 1
			local p = ph1 * TABLE_SIZE
			local j = floor(p)
			local x = tbl1[j] + (tbl1[j + 1] - tbl1[j]) * (p - j)
			if f2 then
				ph2 = (ph2 + f2[i] / sr) % 1
				p = ph2 * TABLE_SIZE
				j = floor(p)
				x = x + level2 * (tbl2[j] + (tbl2[j + 1] - tbl2[j]) * (p - j))
			end
			if tremCycles > 0 then
				x = x * (1 - tremDepth * (0.5 - 0.5 * cos(TWO_PI * tremCycles * i / n)))
			end
			x = runBiquad(hp, x)
			if drive > 0 then x = tanh(x * drive) * driveNorm end
			x = runBiquad(lp, runBiquad(peak, x))
			if muffleA then x = runBiquad(muffleB, runBiquad(muffleA, x)) end
			if pass == 2 then
				out[i + 1] = x
				outPeak = max(outPeak, abs(x))
			end
			if yield and i % YIELD_EVERY == 0 then yield() end
		end
	end

	local g = outPeak > 0 and PEAK / outPeak or 0
	for i = 1, n do out[i] = out[i] * g end

	return out, sr, n
end
