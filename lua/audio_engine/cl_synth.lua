--[[
	Audio Engine - procedural engine synthesizer (client, pure Lua)

	Based on the "Rev Bench" sound generator (per-cylinder firing pulses on a 720 degree crank
	cycle, exhaust resonators, combustion noise, slow leveller, and its WebAudio chain:
	high-pass -> tanh drive -> 95 Hz peak -> low shelf -> rpm/throttle-tracking low-pass ->
	4.2 kHz low-pass -> exhaust tube -> high shelf -> small outdoor space).

	On top of that, to sound like a real car instead of a synth (config.realism):
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
local function evenAngles(count)
	local angles = {}
	for i = 0, count - 1 do angles[i + 1] = i * 720 / count end
	return angles
end

local function offsetAngles(count, offsetOf)
	local angles = evenAngles(count)
	for i = 1, count do angles[i] = angles[i] + offsetOf(i - 1) end
	return angles
end

local V8_CROSSPLANE_BANKS = "LRLLRLRR"

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
		angles = offsetAngles(8, function(i) return V8_CROSSPLANE_BANKS:sub(i + 1, i + 1) == "R" and 26 or 0 end),
		amp = { 1, 0.84, 1, 1, 0.84, 1, 0.84, 0.84 }, banks = V8_CROSSPLANE_BANKS,
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
	local state = seed
	return function()
		state = bxor(state, lshift(state, 13)); state = bxor(state, rshift(state, 17)); state = bxor(state, lshift(state, 5))
		return state / 2147483648
	end
end

--[[
	Each engine type's own voice (used as "realism" goes up):
	  f1, f2, f3  the exhaust's main resonances (Hz): big/deep pipes for a V8, thin and high
	              for an inline-4, high and smooth for V10/V12
	  w           exhaust pulse width (wider = deeper and rounder, narrower = buzzier)
	  o1, halfOrder     how strongly the firing is shaped once per crank turn (1st order) and once
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
	cylinderVariation / cylinderTiming: how different each cylinder is (fraction of strength, degrees).
	o1 / halfOrder: low-order shaping of the cylinder strengths (see CHARACTER).
	Returns firing intervals, strengths, cylinder count and the exhaust bank (1/2) per firing.
]]
function Synth.LayoutParams(layoutKey, cylinderVariation, cylinderTiming, firstOrder, halfOrder)
	local layout = Synth.LAYOUTS[layoutKey] or Synth.LAYOUTS.i4
	local firingCount = #layout.angles
	local angles, strengths, banks = {}, {}, {}
	local random = seededRand(0x1F2E3D4C)
	for i = 1, firingCount do
		angles[i] = layout.angles[i] + (cylinderTiming or 0) * random()
		local angleRadians = layout.angles[i] * pi / 180
		local shapeFilters = 1 + (firstOrder or 0) * cos(angleRadians * 2 + 0.7) + (halfOrder or 0) * cos(angleRadians + 1.9)
		strengths[i] = layout.amp[i] * (1 + (cylinderVariation or 0) * random()) * max(0.3, shapeFilters)
		banks[i] = layout.banks:sub(i, i) == "R" and 2 or 1
	end
	local intervals = {}
	for i = 1, firingCount do
		intervals[i] = (i < firingCount and angles[i + 1] or angles[1] + 720) - angles[i]
	end
	return intervals, strengths, firingCount, banks
end

---------------------------------------------------------------------------
-- EngineGen
---------------------------------------------------------------------------
-- The original runs its smoothers per sample at the browser rate. Scale them so the
-- character is the same at 22.05 kHz or 44.1 kHz.
local REFERENCE_SAMPLE_RATE = 44100
local function smooth(coefficient, sampleRate) return 1 - (1 - coefficient) ^ (REFERENCE_SAMPLE_RATE / sampleRate) end
local function decay(tubeSamples, sampleRate) return tubeSamples ^ (REFERENCE_SAMPLE_RATE / sampleRate) end

-- the engine type's voice, with a car's own changes on top (config.character, sh_carlist.lua)
function Synth.CharacterFor(config)
	local base = Synth.CHARACTER[config.layout] or Synth.CHARACTER.i4
	if type(config.character) ~= "table" then return base end
	local character = {}
	for key, value in pairs(base) do character[key] = config.character[key] or value end
	return character
end

local function realismOf(config)
	local profileRealism = config.realism or {}
	return {
		bankSpread = profileRealism.bankSpread or 0,       -- difference between the two banks' pipes
		combustionVariation = profileRealism.combustionVar or 0,   -- extra cycle-to-cycle variation (at idle)
		cylinderVariation = profileRealism.cylinderVar or 0,
		cylinderTiming = profileRealism.cylinderTiming or 0,
		flowNoise = profileRealism.flowNoise or 0,
		mechanical = profileRealism.mechanical or 0,
		mufflerMode = profileRealism.mufflerMode or 0,
		-- the turbo is a separate, shared sound now (switching it never needs a new engine), so
		-- the exhaust pulses are rendered the same with or without it
		turboSoftening = 0,
		tailpipe = profileRealism.tailpipe or 0,
		reverb = profileRealism.reverb or 0,
		gurgle = config.gurgle or 0,
		voice = profileRealism.voice or 0,                                   -- how much of the engine type's own voice
		character = Synth.CharacterFor(config),
	}
end
Synth.RealismOf = realismOf

function Synth.NewGen(sampleRate, config)
	local realism = realismOf(config)
	local intervals, strengths, cylinderCount, banks = Synth.LayoutParams(config.layout, realism.cylinderVariation, realism.cylinderTiming,
		realism.character.o1 * realism.voice, realism.character.o05 * realism.voice)
	return {
		sampleRate = sampleRate, rpm = 0, targetRpm = 0, throttle = 0, targetThrottle = 0,
		pitch = config.pitch or 1, tone = config.tone or 0.55, cylinderCount = cylinderCount, firingIntervals = intervals, firingStrengths = strengths, firingBanks = banks,
		redline = config.redline or 7000, realism = realism,
		fuelCut = false, crankMode = 0, ignitionOn = false,
		gain = 0, crankAngle = 0, firingIndex = 0, timingJitter = 1,
		-- bank 1 (left) and bank 2 (right)
		pulseSlow = 0, pulseFast = 0, noiseEnvelope = 0, lastPulse = 0,
		lowResonanceState1 = 0, lowResonanceState2 = 0, midResonanceState1 = 0, midResonanceState2 = 0,
		mufflerResonanceState1 = 0, mufflerResonanceState2 = 0,
		pulseSlowDecay = 1, pulseFastDecay = 1, noiseDecay = 1,
		pulseSlowRight = 0, pulseFastRight = 0, noiseEnvelopeRight = 0, lastPulseRight = 0,
		lowResonanceRightState1 = 0, lowResonanceRightState2 = 0, midResonanceRightState1 = 0, midResonanceRightState2 = 0,
		mufflerResonanceRightState1 = 0, mufflerResonanceRightState2 = 0,
		pulseSlowDecayRight = 1, pulseFastDecayRight = 1, noiseDecayRight = 1,
		flowFilterState1 = 0, flowFilterState2 = 0, mechanicalEnvelope = 0, runningMeanSquare = 0.01, gurgleDrift = 0,
		popImpulse = 0, noiseLowpass = 0, noiseLowpass2 = 0, rumbleNoise = 0, dcBlockInput = 0, dcBlockOutput = 0, seed = 0x2545F491,
		levellerMeanSquare = 0.002, levellerGain = 1, popEnvelope = 0,
		electric = config.layout == "electric",
		allowPops = true,  -- random overrun / limiter pops (off for loops; the game triggers them)
		silenceFiring = false,    -- silence the combustion pulses (used to render pop one-shots)
		fixedLevellerGain = nil,    -- force the leveller to a fixed gain
		smoothing = {
			rpm = smooth(0.0015, sampleRate), throttle = smooth(0.002, sampleRate), gain = smooth(0.0004, sampleRate),
			noise = smooth(0.06, sampleRate), rumble = smooth(0.025, sampleRate), dcBlock = decay(0.996, sampleRate),
			popEnvelope = smooth(0.03, sampleRate), popDecay = decay(0.996, sampleRate),
			levellerMeanSquare = smooth(0.00005, sampleRate), levellerGain = smooth(0.0002, sampleRate),
		},
	}
end

function Synth.Rand(generator)
	local state = generator.seed
	state = bxor(state, lshift(state, 13)); state = bxor(state, rshift(state, 17)); state = bxor(state, lshift(state, 5))
	generator.seed = state
	return state / 2147483648
end

local function resonator(frequency, decaySeconds, sampleRate)
	local omega = TAU * frequency / sampleRate
	local radius = exp(-1 / (sampleRate * decaySeconds))
	return 2 * radius * cos(omega), radius * radius, sin(omega)
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
local function evBodyResponse(partialHz, sampleRate)
	if partialHz > 0.45 * sampleRate then return 0 end
	local offset1, offset2 = (partialHz - 700) / 300, (partialHz - 1800) / 600
	local resonance = 0.9 + 0.25 / (1 + offset1 * offset1) + 0.15 / (1 + offset2 * offset2)
	local highRolloff = partialHz / 4000
	return resonance * partialHz * partialHz / (partialHz * partialHz + 22500) / (1 + highRolloff * highRolloff * highRolloff * highRolloff)
end

function Synth.EVRender(generator, out, offset, count)
	local sampleRate, smoothing = generator.sampleRate, generator.smoothing
	local smoothedRpm, smoothedThrottle, gain = generator.rpm, generator.throttle, generator.gain
	local targetRpm, targetThrottle, ignitionTarget = generator.targetRpm, generator.targetThrottle, generator.ignitionOn and 1 or 0
	local redline, pitch, tone = generator.redline, generator.pitch, generator.tone
	local toneOrder = generator.evToneOrder
	if not toneOrder then
		toneOrder = max(1, floor(EV_TOP_HZ * 60 / redline * 2 + 0.5) / 2)
		generator.evToneOrder = toneOrder
	end
	local phases = generator.evPhases
	if not phases then
		phases = {}
		for partialIndex = 1, #EV_PARTIALS do phases[partialIndex] = (partialIndex * 2.39996) % TAU end   -- spread starting phases
		generator.evPhases = phases
	end
	local levelDrift1 = generator.evLevelDrift1 or 0
	local levelDrift2 = generator.evLevelDrift2 or 0
	local harmonic1 = generator.evHissState1 or 0
	local harmonic2 = generator.evHissState2 or 0
	local seed = generator.seed
	local ripple1, harmonic2Wobble = generator.evRipple1 or 0, generator.evRipple2 or 0
	local rpmSmoothing, throttleSmoothing, gainSmoothing = smoothing.rpm, smoothing.throttle, smoothing.gain
	local driftCoefficient = 1 - exp(-TAU * 3 / sampleRate)            -- level drift, ~3 Hz
	local driftNorm = 1 / (0.28 * sqrt(driftCoefficient))              -- makes the twice-smoothed noise ~1 rms
	local rippleCoefficient = 1 - exp(-TAU * 25 / sampleRate)            -- speed ripple, ~25 Hz
	local rippleNorm = 1 / (0.28 * sqrt(rippleCoefficient))
	local hissCoefficient1, hissCoefficient2 = 1 - exp(-TAU * 1800 / sampleRate), 1 - exp(-TAU * 5000 / sampleRate)
	local radiansPerSample = TAU / sampleRate
	local partialCount = #EV_PARTIALS
	for i = 0, count - 1 do
		smoothedRpm = smoothedRpm + (targetRpm - smoothedRpm) * rpmSmoothing
		smoothedThrottle = smoothedThrottle + (targetThrottle - smoothedThrottle) * throttleSmoothing
		gain = gain + (ignitionTarget - gain) * gainSmoothing
		local baseHz = max(0, smoothedRpm) / 60 * pitch
		local speedShare = min(1, max(0, smoothedRpm) / redline)
		-- motor torque: full on the pedal, regeneration off it
		local load = 0.4 + 0.6 * smoothedThrottle
		seed = bxor(seed, lshift(seed, 13)); seed = bxor(seed, rshift(seed, 17)); seed = bxor(seed, lshift(seed, 5))
		local random = seed / 2147483648
		levelDrift1 = levelDrift1 + (random - levelDrift1) * driftCoefficient
		levelDrift2 = levelDrift2 + (levelDrift1 - levelDrift2) * driftCoefficient
		seed = bxor(seed, lshift(seed, 13)); seed = bxor(seed, rshift(seed, 17)); seed = bxor(seed, lshift(seed, 5))
		ripple1 = ripple1 + (seed / 2147483648 - ripple1) * rippleCoefficient
		harmonic2Wobble = harmonic2Wobble + (ripple1 - harmonic2Wobble) * rippleCoefficient
		local rippledRadians = radiansPerSample * (1 + 0.004 * rippleNorm * harmonic2Wobble)
		local level = 0.18 * speedShare ^ 0.8 * (0.35 + 0.65 * load) * (1 + 0.05 * driftNorm * levelDrift2)
		local brightness = (0.5 + 0.5 * load) * (0.5 + tone)
		local sample = 0
		for partialIndex = 1, partialCount do
			local partial = EV_PARTIALS[partialIndex]
			local partialHz = baseHz * toneOrder * partial[1]
			local peakFilter = phases[partialIndex] + rippledRadians * partialHz
			if peakFilter > TAU then peakFilter = peakFilter - TAU end
			phases[partialIndex] = peakFilter
			local partialLevel = partial[1] > 1 and partial[2] * brightness or partial[2]
			sample = sample + partialLevel * evBodyResponse(partialHz, sampleRate) * sin(peakFilter)
		end
		sample = sample * level
		-- bearings and cooling air: a band of noise around 2-5 kHz
		harmonic1 = harmonic1 + (random - harmonic1) * hissCoefficient1
		harmonic2 = harmonic2 + ((random - harmonic1) - harmonic2) * hissCoefficient2
		sample = sample + harmonic2 * 0.08 * speedShare ^ 1.2 * (0.6 + 0.4 * load)
		out[offset + i] = sample * gain * 0.6
	end
	generator.rpm, generator.throttle, generator.gain = smoothedRpm, smoothedThrottle, gain
	generator.evLevelDrift1 = levelDrift1
	generator.evLevelDrift2 = levelDrift2
	generator.evHissState1 = harmonic1
	generator.evHissState2 = harmonic2
	generator.seed = seed
	generator.evRipple1, generator.evRipple2 = ripple1, harmonic2Wobble
end

-- render n samples of raw generator output into out[o] .. out[o+n-1]
function Synth.GenRender(generator, out, offset, count)
	if generator.electric then return Synth.EVRender(generator, out, offset, count) end
	local sampleRate = generator.sampleRate
	local realism = generator.realism
	local pitchRoot = sqrt(generator.pitch)
	local bankSpread = realism.bankSpread
	-- exhaust resonances: Rev Bench's at realism 0, the engine type's own voice at full realism
	local character, voiceShare = realism.character, realism.voice
	local lowResonanceHz = (78 + (character.f1 - 78) * voiceShare) * pitchRoot
	local midResonanceHz = ((230 + 190 * generator.tone) * (1 - voiceShare) + character.f2 * (0.85 + 0.3 * generator.tone) * voiceShare) * pitchRoot
	local mufflerResonanceHz = (155 + (character.f3 - 155) * voiceShare) * pitchRoot
	-- left / right bank pipes differ a little in length
	local lowFeedback1, lowFeedback2, lowInputGain = resonator(lowResonanceHz * (1 - 0.03 * bankSpread), 0.022, sampleRate)
	local midFeedback1, midFeedback2, midInputGain = resonator(midResonanceHz * (1 + 0.04 * bankSpread), 0.006, sampleRate)
	local mufflerFeedback1, mufflerFeedback2, mufflerInputGain = resonator(mufflerResonanceHz * (1 - 0.05 * bankSpread), 0.012, sampleRate)
	local lowFeedbackRight1, lowFeedbackRight2, lowInputGainRight = resonator(lowResonanceHz * (1 + 0.03 * bankSpread), 0.022, sampleRate)
	local midFeedbackRight1, midFeedbackRight2, midInputGainRight = resonator(midResonanceHz * (1 - 0.04 * bankSpread), 0.006, sampleRate)
	local mufflerFeedbackRight1, mufflerFeedbackRight2, mufflerInputGainRight = resonator(mufflerResonanceHz * (1 + 0.05 * bankSpread), 0.012, sampleRate)
	local mufflerAmount = realism.mufflerMode
	local basePulseTime = 0.007 * (4 / generator.cylinderCount) ^ 0.6 / pitchRoot * (1 + (character.w - 1) * voiceShare)
	local grit = generator.tone
	local popChance = max(0, (generator.tone - 0.35) / 0.65)
	local intervals = generator.firingIntervals
	local strengths = generator.firingStrengths
	local banks = generator.firingBanks
	local firingCount = #generator.firingIntervals
	local smoothing = generator.smoothing
	local rpmSmoothing = smoothing.rpm
	local throttleSmoothing = smoothing.throttle
	local gainSmoothing = smoothing.gain
	local noiseSmoothing = smoothing.noise
	local rumbleSmoothing = smoothing.rumble
	local dcBlockFactor = smoothing.dcBlock
	local popEnvelopeSmoothing = smoothing.popEnvelope
	local popDecay = smoothing.popDecay
	local meanSquareSmoothing = smoothing.levellerMeanSquare
	local levellerSmoothing = smoothing.levellerGain
	local pitch = generator.pitch
	local targetRpm = generator.targetRpm
	local targetThrottle = generator.targetThrottle
	local fuelCut = generator.fuelCut
	local crankMode = generator.crankMode
	local ignitionTarget = generator.ignitionOn and 1 or 0
	local allowPops, silenceFiring, fixedLevellerGain = generator.allowPops, generator.silenceFiring, generator.fixedLevellerGain
	local combustionVariation, turboSoftening, mechanicalAmount = realism.combustionVariation, realism.turboSoftening, realism.mechanical
	local redline = generator.redline
	local mechanicalDecay = exp(-1 / (sampleRate * 0.0012))

	local smoothedRpm = generator.rpm
	local smoothedThrottle = generator.throttle
	local gain = generator.gain
	local crankAngle = generator.crankAngle
	local firingIndex = generator.firingIndex
	local timingJitter = generator.timingJitter
	local pulseSlow = generator.pulseSlow
	local pulseFast = generator.pulseFast
	local noiseEnvelope = generator.noiseEnvelope
	local lastPulse = generator.lastPulse
	local lowResonanceState1 = generator.lowResonanceState1
	local lowResonanceState2 = generator.lowResonanceState2
	local midResonanceState1 = generator.midResonanceState1
	local midResonanceState2 = generator.midResonanceState2
	local mufflerResonanceState1 = generator.mufflerResonanceState1
	local mufflerResonanceState2 = generator.mufflerResonanceState2
	local pulseSlowRight = generator.pulseSlowRight
	local pulseFastRight = generator.pulseFastRight
	local noiseEnvelopeRight = generator.noiseEnvelopeRight
	local lastPulseRight = generator.lastPulseRight
	local lowResonanceRightState1 = generator.lowResonanceRightState1
	local lowResonanceRightState2 = generator.lowResonanceRightState2
	local midResonanceRightState1 = generator.midResonanceRightState1
	local midResonanceRightState2 = generator.midResonanceRightState2
	local mufflerResonanceRightState1 = generator.mufflerResonanceRightState1
	local mufflerResonanceRightState2 = generator.mufflerResonanceRightState2
	local pulseSlowDecay = generator.pulseSlowDecay
	local pulseFastDecay = generator.pulseFastDecay
	local noiseDecay = generator.noiseDecay
	local pulseSlowDecayRight = generator.pulseSlowDecayRight
	local pulseFastDecayRight = generator.pulseFastDecayRight
	local noiseDecayRight = generator.noiseDecayRight
	local popImpulse = generator.popImpulse
	local noiseLowpass = generator.noiseLowpass
	local noiseLowpass2 = generator.noiseLowpass2
	local rumbleNoise = generator.rumbleNoise
	local dcBlockInput = generator.dcBlockInput
	local dcBlockOutput = generator.dcBlockOutput
	local seed = generator.seed
	local levellerMeanSquare, levellerGain, popEnvelope = generator.levellerMeanSquare, generator.levellerGain, generator.popEnvelope
	local flowFilterState1 = generator.flowFilterState1
	local flowFilterState2 = generator.flowFilterState2
	local mechanicalEnvelope = generator.mechanicalEnvelope
	local runningMeanSquare = generator.runningMeanSquare
	local gurgleAmount, gurgleDrift = realism.gurgle, generator.gurgleDrift
	local voice = realism.voice
	local jitterAmount = 0.018 + 0.017 * voice          -- firing is a little less clockwork with realism
	local barkAmount = 0.35 * voice
	if fixedLevellerGain then levellerGain = fixedLevellerGain end

	-- exhaust flow noise: band-pass that rises with rpm. Its level follows the engine's own
	-- running loudness (tms), as a share that grows with load and rpm (set per block)
	local flowAmount = realism.flowNoise
	local flowB0, flowA1, flowA2, flowLoad = 0, 0, 0, 0
	local redlineShare = min(1, smoothedRpm / redline)
	if flowAmount > 0 then
		local flowCenterHz = 300 + 0.1 * smoothedRpm
		local omega = TAU * flowCenterHz / sampleRate
		local flowQ = 0.5
		local alpha = sin(omega) / (2 * flowQ)
		local a0 = 1 + alpha
		flowB0, flowA1, flowA2 = alpha / a0, -2 * cos(omega) / a0, (1 - alpha) / a0
		-- white noise here is uniform (rms 0.577); normalise the band-passed rms to ~1
		local saturationNorm = 1 / (0.577 * sqrt((flowCenterHz / flowQ) / (sampleRate / 2) * (pi / 2)))
		flowLoad = saturationNorm * (0.3 + 0.4 * smoothedThrottle) * (0.85 + 0.15 * redlineShare)
	end
	local mechanicalLevel = mechanicalAmount * 0.6 * (0.8 - 0.3 * redlineShare)

	local function nextRandom()
		seed = bxor(seed, lshift(seed, 13)); seed = bxor(seed, rshift(seed, 17)); seed = bxor(seed, lshift(seed, 5))
		return seed / 2147483648
	end

	for i = 0, count - 1 do
		smoothedRpm = smoothedRpm + (targetRpm - smoothedRpm) * rpmSmoothing
		smoothedThrottle = smoothedThrottle + (targetThrottle - smoothedThrottle) * throttleSmoothing
		gain = gain + (ignitionTarget - gain) * gainSmoothing
		local firingGap = intervals[firingIndex + 1] * timingJitter
		local rpm = smoothedRpm > 30 and smoothedRpm or 30
		local throttle = smoothedThrottle
		local degreesPerSecond = rpm * 6 * pitch
		crankAngle = crankAngle + degreesPerSecond / sampleRate
		if crankAngle >= firingGap then
			crankAngle = crankAngle - firingGap
			firingIndex = (firingIndex + 1) % firingCount
			timingJitter = 1 + jitterAmount * nextRandom()
			-- pulse length is real time, capped so pulses still separate at high rpm;
			-- turbos smear the pulses out under boost
			local gapSeconds = intervals[firingIndex + 1] / degreesPerSecond
			local boostShare = (rpm - 1800) / 2200
			if boostShare < 0 then boostShare = 0 elseif boostShare > 1 then boostShare = 1 end
			local softening = 1 + turboSoftening * throttle * boostShare
			local pulseTime = min(basePulseTime * softening, gapSeconds * 0.42 * sqrt(softening))
			local newSlowDecay = exp(-1 / (sampleRate * pulseTime))
			local newFastDecay = exp(-1 / (sampleRate * min(pulseTime * 0.22, 0.0018)))
			local newNoiseDecay = exp(-1 / (sampleRate * pulseTime * 0.5))
			local rightBank = banks[firingIndex + 1] == 2
			if rightBank then
				pulseSlowDecayRight = newSlowDecay
				pulseFastDecayRight = newFastDecay
				noiseDecayRight = newNoiseDecay
			else
				pulseSlowDecay = newSlowDecay
				pulseFastDecay = newFastDecay
				noiseDecay = newNoiseDecay
			end
			local fires, compressionPuff = not fuelCut, false
			if crankMode == 1 then fires = false; compressionPuff = true          -- compression only
			elseif crankMode == 2 then fires = nextRandom() > -0.3 end        -- catching: most cylinders light
			if silenceFiring then fires = false; compressionPuff = false end
			-- gurgle: off throttle the burn goes ragged. Strengths come in uneven groups (a slow
			-- random drift across firings) and the odd cylinder misfires. Always draw the same
			-- random numbers so on/off-throttle loops keep the same firing phase.
			local gurgleScale = 1
			if gurgleAmount > 0 then
				local gurgleRandomA, gurgleRandomB = nextRandom(), nextRandom()
				gurgleDrift = gurgleDrift * 0.72 + gurgleRandomA * 0.28
				local gurgleStrength = gurgleAmount * (1 - throttle) * (1 - throttle)
				gurgleScale = 1 + gurgleStrength * (2.2 * gurgleDrift + 0.35 * gurgleRandomB)
				if gurgleScale < 0.15 then gurgleScale = 0.15 end
				if fires and gurgleRandomB > 1 - 0.22 * gurgleStrength then
					fires = false
					nextRandom()  -- the draw this firing would have used, so the sequence stays aligned
				end
			end
			if fires then
				-- combustion varies more cycle to cycle at idle than under load
				local strength = (0.3 + 0.7 * throttle) * strengths[firingIndex + 1] * (1 + (0.12 + 0.08 * voice + combustionVariation * (1 - throttle)) * nextRandom()) * gurgleScale
				if rightBank then
					pulseSlowRight = pulseSlowRight + strength
					pulseFastRight = pulseFastRight + strength
					noiseEnvelopeRight = noiseEnvelopeRight + strength * (0.3 + 0.5 * throttle)
				else
					pulseSlow = pulseSlow + strength
					pulseFast = pulseFast + strength
					noiseEnvelope = noiseEnvelope + strength * (0.3 + 0.5 * throttle)
				end
				mechanicalEnvelope = mechanicalEnvelope + mechanicalLevel
				if allowPops and throttle < 0.04 and rpm > 3500 and nextRandom() * 0.5 + 0.5 < 0.04 * popChance then
					popImpulse = (0.25 + 0.1 * nextRandom()) * popChance
				end
			elseif compressionPuff then
				local strength = 0.13 * strengths[firingIndex + 1]
				if rightBank then
					pulseSlowRight = pulseSlowRight + strength
					pulseFastRight = pulseFastRight + strength
				else
					pulseSlow = pulseSlow + strength
					pulseFast = pulseFast + strength
				end
			elseif allowPops and fuelCut and rpm > 2500 and nextRandom() * 0.5 + 0.5 < 0.25 * popChance then
				popImpulse = (0.3 + 0.1 * nextRandom()) * popChance
			end
		end
		pulseSlow = pulseSlow * pulseSlowDecay; pulseFast = pulseFast * pulseFastDecay; noiseEnvelope = noiseEnvelope * noiseDecay
		pulseSlowRight = pulseSlowRight * pulseSlowDecayRight
		pulseFastRight = pulseFastRight * pulseFastDecayRight
		noiseEnvelopeRight = noiseEnvelopeRight * noiseDecayRight
		mechanicalEnvelope = mechanicalEnvelope * mechanicalDecay
		local noise = nextRandom()
		noiseLowpass = noiseLowpass + (noise - noiseLowpass) * noiseSmoothing
		noiseLowpass2 = noiseLowpass2 + (noiseLowpass - noiseLowpass2) * noiseSmoothing
		rumbleNoise = rumbleNoise + (noise - rumbleNoise) * rumbleSmoothing
		local midResonanceGain = 0.3 + 0.6 * throttle
		-- left bank
		local pulse = pulseSlow - pulseFast
		local pulseChange = pulse - lastPulse; lastPulse = pulse
		local lowResonance = lowFeedback1 * lowResonanceState1 - lowFeedback2 * lowResonanceState2 + pulseChange * lowInputGain
		lowResonanceState2 = lowResonanceState1
		lowResonanceState1 = lowResonance
		local midResonance = midFeedback1 * midResonanceState1 - midFeedback2 * midResonanceState2 + pulseChange * midInputGain * midResonanceGain
		midResonanceState2 = midResonanceState1
		midResonanceState1 = midResonance
		local mufflerResonance = mufflerFeedback1 * mufflerResonanceState1 - mufflerFeedback2 * mufflerResonanceState2 + pulseChange * mufflerInputGain
		mufflerResonanceState2 = mufflerResonanceState1
		mufflerResonanceState1 = mufflerResonance
		-- right bank
		local pulseRight = pulseSlowRight - pulseFastRight
		local pulseChangeRight = pulseRight - lastPulseRight; lastPulseRight = pulseRight
		local lowResonanceRight = lowFeedbackRight1 * lowResonanceRightState1 - lowFeedbackRight2 * lowResonanceRightState2 + pulseChangeRight * lowInputGainRight
		lowResonanceRightState2 = lowResonanceRightState1
		lowResonanceRightState1 = lowResonanceRight
		local midResonanceRight = midFeedbackRight1 * midResonanceRightState1 - midFeedbackRight2 * midResonanceRightState2 + pulseChangeRight * midInputGainRight * midResonanceGain
		midResonanceRightState2 = midResonanceRightState1
		midResonanceRightState1 = midResonanceRight
		local mufflerResonanceRight = mufflerFeedbackRight1 * mufflerResonanceRightState1 - mufflerFeedbackRight2 * mufflerResonanceRightState2 + pulseChangeRight * mufflerInputGainRight
		mufflerResonanceRightState2 = mufflerResonanceRightState1
		mufflerResonanceRightState1 = mufflerResonanceRight

		local sample = (pulse + pulseRight) * 0.5 + (lowResonance + lowResonanceRight) * 1.1 + (midResonance + midResonanceRight) * (0.15 + 0.45 * grit)
			+ (mufflerResonance + mufflerResonanceRight) * mufflerAmount
			+ (noiseEnvelope + noiseEnvelopeRight) * noiseLowpass2 * (0.2 + 0.8 * grit)
			+ rumbleNoise * throttle * min(rpm / 9000, 1) * (0.1 + 0.25 * grit)
		runningMeanSquare = runningMeanSquare + (sample * sample - runningMeanSquare) * meanSquareSmoothing
		local runningLevel = sqrt(runningMeanSquare)
		if flowAmount > 0 then
			-- band-pass (constant 0 dB peak): b1 = 0, b2 = -b0; pulsed by the firing
			local flowSample = flowB0 * noise + flowFilterState1
			flowFilterState1 = -flowA1 * flowSample + flowFilterState2
			flowFilterState2 = -flowB0 * noise - flowA2 * flowSample
			local pulseModulation = (noiseEnvelope + noiseEnvelopeRight) * 1.2
			if pulseModulation > 1.5 then pulseModulation = 1.5 end
			-- grit rides on each exhaust pulse (rasp), rather than a steady hiss (scream)
			sample = sample + flowSample * flowAmount * flowLoad * runningLevel * (0.12 + 0.88 * pulseModulation)
		end
		if mechanicalEnvelope > 1e-5 then sample = sample + mechanicalEnvelope * runningLevel * (noise - noiseLowpass) end
		-- pops fade in over ~1 ms so they never start with a click
		popEnvelope = popEnvelope + (popImpulse - popEnvelope) * popEnvelopeSmoothing; popImpulse = popImpulse * popDecay
		if popEnvelope > 0.002 then sample = sample + popEnvelope * noiseLowpass * 2.2 end
		-- exhaust pressure waves steepen as they travel: a little even-order bark
		if voice > 0 then sample = sample + barkAmount * sample * sample / (1 + abs(sample)) end
		local dcBlocked = sample - dcBlockInput + dcBlockFactor * dcBlockOutput; dcBlockInput = sample; dcBlockOutput = dcBlocked
		-- slow leveller: keeps resonance build-up in check without flattening throttle dynamics
		local scaledSample = dcBlocked * 0.3
		levellerMeanSquare = levellerMeanSquare + (scaledSample * scaledSample - levellerMeanSquare) * meanSquareSmoothing
		if not fixedLevellerGain then
			local wantedGain = (0.035 + 0.04 * throttle) / (sqrt(levellerMeanSquare) + 1e-4)
			if wantedGain > 1.4 then wantedGain = 1.4 elseif wantedGain < 0.45 then wantedGain = 0.45 end
			levellerGain = levellerGain + (wantedGain - levellerGain) * levellerSmoothing
		end
		out[offset + i] = scaledSample * levellerGain * gain
	end

	generator.rpm = smoothedRpm
	generator.throttle = smoothedThrottle
	generator.gain = gain
	generator.crankAngle = crankAngle
	generator.firingIndex = firingIndex
	generator.timingJitter = timingJitter
	generator.pulseSlow = pulseSlow
	generator.pulseFast = pulseFast
	generator.noiseEnvelope = noiseEnvelope
	generator.lastPulse = lastPulse
	generator.lowResonanceState1 = lowResonanceState1
	generator.lowResonanceState2 = lowResonanceState2
	generator.midResonanceState1 = midResonanceState1
	generator.midResonanceState2 = midResonanceState2
	generator.mufflerResonanceState1 = mufflerResonanceState1
	generator.mufflerResonanceState2 = mufflerResonanceState2
	generator.pulseSlowRight = pulseSlowRight
	generator.pulseFastRight = pulseFastRight
	generator.noiseEnvelopeRight = noiseEnvelopeRight
	generator.lastPulseRight = lastPulseRight
	generator.lowResonanceRightState1 = lowResonanceRightState1
	generator.lowResonanceRightState2 = lowResonanceRightState2
	generator.midResonanceRightState1 = midResonanceRightState1
	generator.midResonanceRightState2 = midResonanceRightState2
	generator.mufflerResonanceRightState1 = mufflerResonanceRightState1
	generator.mufflerResonanceRightState2 = mufflerResonanceRightState2
	generator.pulseSlowDecay = pulseSlowDecay
	generator.pulseFastDecay = pulseFastDecay
	generator.noiseDecay = noiseDecay
	generator.pulseSlowDecayRight = pulseSlowDecayRight
	generator.pulseFastDecayRight = pulseFastDecayRight
	generator.noiseDecayRight = noiseDecayRight
	generator.popImpulse = popImpulse
	generator.noiseLowpass = noiseLowpass
	generator.noiseLowpass2 = noiseLowpass2
	generator.rumbleNoise = rumbleNoise
	generator.dcBlockInput = dcBlockInput
	generator.dcBlockOutput = dcBlockOutput
	generator.seed = seed
	generator.levellerMeanSquare, generator.levellerGain, generator.popEnvelope = levellerMeanSquare, levellerGain, popEnvelope
	generator.flowFilterState1 = flowFilterState1
	generator.flowFilterState2 = flowFilterState2
	generator.mechanicalEnvelope = mechanicalEnvelope
	generator.runningMeanSquare = runningMeanSquare
	generator.gurgleDrift = gurgleDrift
end

---------------------------------------------------------------------------
-- WebAudio-equivalent biquads (Audio EQ Cookbook as specified by WebAudio:
-- lowpass/highpass Q is in dB, shelves use slope S = 1)
---------------------------------------------------------------------------
local function biquad(kind, f0, sampleRate, Q, gainDb)
	local w0 = TAU * f0 / sampleRate
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

local function setCoefficients(filter, coefficients)
	filter[1], filter[2], filter[3], filter[4], filter[5] = coefficients[1], coefficients[2], coefficients[3], coefficients[4], coefficients[5]
end

-- low-pass cutoff the page drives from rpm and throttle
function Synth.CutoffFor(rpm, throttle, tone, pitch, voice)
	local cutoff = (420 + 1500 * throttle * (0.5 + tone) + rpm * 0.22) * pitch
	if voice and voice > 0 then
		-- the engine's body, not its fizz: a lower, gentler opening with revs and throttle
		local darkCutoff = (320 + 1000 * throttle * (0.5 + tone) + rpm * 0.12) * pitch
		if darkCutoff > 2800 then darkCutoff = 2800 end
		cutoff = cutoff + (darkCutoff - cutoff) * voice
	end
	if cutoff < 200 then cutoff = 200 elseif cutoff > 5500 then cutoff = 5500 end
	return cutoff
end

local function zeros(count)
	local list = {}
	for i = 1, count do list[i] = 0 end
	return list
end

function Synth.NewChain(sampleRate, config)
	local tone = config.tone
	local realism = realismOf(config)
	-- a car's silencer (config.muffle 0-1, economy cars): lower cutoffs and more treble cut
	local muffle = config.muffle or 0
	local tubeSamples = floor(0.0052 * sampleRate + 0.5)
	local driveAmount = 0.15 + 1.6 * tone * tone
	local tailSamples = floor(0.0115 * sampleRate + 0.5)
	-- small outdoor space (the page used a 0.11 s decaying noise burst; this is a Schroeder
	-- reverb with the same ~0.75 s decay)
	local combs = {}
	for i, delayMs in ipairs({ 25.3, 26.9, 28.9, 30.7 }) do
		local length = floor(delayMs / 1000 * sampleRate + 0.5)
		combs[i] = { buffer = zeros(length), length = length, position = 1, lowpassState = 0, feedback = 10 ^ (-3 * (delayMs / 1000) / 0.75) }
	end
	local allpasses = {}
	for i, delayMs in ipairs({ 12.6, 10.0 }) do
		local length = floor(delayMs / 1000 * sampleRate + 0.5)
		allpasses[i] = { buffer = zeros(length), length = length, position = 1 }
	end
	return {
		sampleRate = sampleRate,
		highpass = biquad("highpass", 30, sampleRate, 0.7),
		drive = driveAmount, driveNorm = 1 / tanh(driveAmount),
		bodyPeak = biquad("peaking", 95, sampleRate, 1.0, 3 + tone * 5),
		lowShelf = biquad("lowshelf", 130 + 20 * realism.voice, sampleRate, 1, 4 + 2 * realism.voice),
		trackingLowpass = biquad("lowpass", 700, sampleRate, 0.5),
		topLowpass = biquad("lowpass", (4200 - 800 * realism.voice) * (1 - 0.5 * muffle), sampleRate, 0.6),
		tubeLowpass = biquad("lowpass", 1900, sampleRate, 1),
		highShelf = biquad("highshelf", 2500, sampleRate, 1, -8 - 8 * muffle),
		tubeDelay = zeros(tubeSamples), tubeLength = tubeSamples, tubePosition = 1,
		tailDelay = zeros(tailSamples), tailLength = tailSamples, tailPosition = 1, tailLowpassState = 0,
		tailWet = realism.tailpipe, tailLowpassCoefficient = 1 - exp(-TAU * 1200 / sampleRate),
		reverbCombs = combs, reverbAllpasses = allpasses, reverbWet = realism.reverb, reverbDamping = 0.35,
		cutoff = 700, targetCutoff = 700, muffleScale = 1 - 0.35 * muffle,
		electric = config.layout == "electric",
	}
end

-- WebAudio setTargetAtTime(fc, t, 0.06): approach the new cutoff with a 60 ms time constant
local function updateCutoff(chain, count)
	local step = 1 - exp(-(count / chain.sampleRate) / 0.06)
	chain.cutoff = chain.cutoff + (chain.targetCutoff - chain.cutoff) * step
	setCoefficients(chain.trackingLowpass, biquad("lowpass", chain.cutoff * chain.muffleScale, chain.sampleRate, 0.5))
end

-- run buf[o .. o+n-1] through the chain in place
local function chainBlock(chain, buffer, offset, count)
	if chain.electric then return end   -- an electric motor has no exhaust: the whine goes out as it is
	local highpassFilter = chain.highpass
	local peakFilter = chain.bodyPeak
	local lowShelfFilter = chain.lowShelf
	local trackingFilter = chain.trackingLowpass
	local topFilter = chain.topLowpass
	local tubeFilter = chain.tubeLowpass
	local highShelfFilter = chain.highShelf
	local highpassB0 = highpassFilter[1]
	local highpassB1 = highpassFilter[2]
	local highpassB2 = highpassFilter[3]
	local highpassA1 = highpassFilter[4]
	local highpassA2 = highpassFilter[5]
	local highpassState1 = highpassFilter[6]
	local highpassState2 = highpassFilter[7]
	local peakB0 = peakFilter[1]
	local peakB1 = peakFilter[2]
	local peakB2 = peakFilter[3]
	local peakA1 = peakFilter[4]
	local peakA2 = peakFilter[5]
	local peakState1 = peakFilter[6]
	local peakState2 = peakFilter[7]
	local lowShelfB0 = lowShelfFilter[1]
	local lowShelfB1 = lowShelfFilter[2]
	local lowShelfB2 = lowShelfFilter[3]
	local lowShelfA1 = lowShelfFilter[4]
	local lowShelfA2 = lowShelfFilter[5]
	local lowShelfState1 = lowShelfFilter[6]
	local lowShelfState2 = lowShelfFilter[7]
	local trackingB0 = trackingFilter[1]
	local trackingB1 = trackingFilter[2]
	local trackingB2 = trackingFilter[3]
	local trackingA1 = trackingFilter[4]
	local trackingA2 = trackingFilter[5]
	local trackingState1 = trackingFilter[6]
	local trackingState2 = trackingFilter[7]
	local topB0 = topFilter[1]
	local topB1 = topFilter[2]
	local topB2 = topFilter[3]
	local topA1 = topFilter[4]
	local topA2 = topFilter[5]
	local topState1 = topFilter[6]
	local topState2 = topFilter[7]
	local tubeB0 = tubeFilter[1]
	local tubeB1 = tubeFilter[2]
	local tubeB2 = tubeFilter[3]
	local tubeA1 = tubeFilter[4]
	local tubeA2 = tubeFilter[5]
	local tubeState1 = tubeFilter[6]
	local tubeState2 = tubeFilter[7]
	local highShelfB0 = highShelfFilter[1]
	local highShelfB1 = highShelfFilter[2]
	local highShelfB2 = highShelfFilter[3]
	local highShelfA1 = highShelfFilter[4]
	local highShelfA2 = highShelfFilter[5]
	local highShelfState1 = highShelfFilter[6]
	local highShelfState2 = highShelfFilter[7]
	local drive, driveNorm = chain.drive, chain.driveNorm
	local tubeDelay, tubeLength, tubePosition = chain.tubeDelay, chain.tubeLength, chain.tubePosition
	local tailDelay = chain.tailDelay
	local tailLength = chain.tailLength
	local tailPosition = chain.tailPosition
	local tailLowpassState = chain.tailLowpassState
	local tailWet = chain.tailWet
	local tailCoefficient = chain.tailLowpassCoefficient
	local reverbCombs, reverbAllpasses, reverbWet, reverbDamping = chain.reverbCombs, chain.reverbAllpasses, chain.reverbWet, chain.reverbDamping
	local comb1, comb2, comb3, comb4 = reverbCombs[1], reverbCombs[2], reverbCombs[3], reverbCombs[4]
	local allpass1, allpass2 = reverbAllpasses[1], reverbAllpasses[2]
	for i = offset, offset + count - 1 do
		local input = buffer[i]
		-- high-pass 30 Hz
		local output = highpassB0 * input + highpassState1
		highpassState1 = highpassB1 * input - highpassA1 * output + highpassState2
		highpassState2 = highpassB2 * input - highpassA2 * output
		-- drive (WaveShaper tanh curve; input outside +-1 sits on the curve ends)
		if output > 1 then output = 1 elseif output < -1 then output = -1 end
		input = tanh(drive * output) * driveNorm
		-- 95 Hz peak
		output = peakB0 * input + peakState1
		peakState1 = peakB1 * input - peakA1 * output + peakState2
		peakState2 = peakB2 * input - peakA2 * output
		-- low shelf 130 Hz +4 dB
		input = output
		output = lowShelfB0 * input + lowShelfState1
		lowShelfState1 = lowShelfB1 * input - lowShelfA1 * output + lowShelfState2
		lowShelfState2 = lowShelfB2 * input - lowShelfA2 * output
		-- tracking low-pass
		input = output
		output = trackingB0 * input + trackingState1
		trackingState1 = trackingB1 * input - trackingA1 * output + trackingState2
		trackingState2 = trackingB2 * input - trackingA2 * output
		-- 4.2 kHz low-pass
		input = output
		output = topB0 * input + topState1; topState1 = topB1 * input - topA1 * output + topState2; topState2 = topB2 * input - topA2 * output
		-- exhaust tube: 5.2 ms delay, low-passed, fed back at -0.3, 0.3 wet
		input = output
		local tubeOut = tubeDelay[tubePosition]
		local tubeFiltered = tubeB0 * tubeOut + tubeState1
		tubeState1 = tubeB1 * tubeOut - tubeA1 * tubeFiltered + tubeState2
		tubeState2 = tubeB2 * tubeOut - tubeA2 * tubeFiltered
		tubeDelay[tubePosition] = input - 0.3 * tubeFiltered
		tubePosition = tubePosition + 1; if tubePosition > tubeLength then tubePosition = 1 end
		input = input + 0.3 * tubeFiltered
		-- tailpipe: a longer, darker reflection
		if tailWet > 0 then
			local tailOut = tailDelay[tailPosition]
			tailLowpassState = tailLowpassState + (tailOut - tailLowpassState) * tailCoefficient
			tailDelay[tailPosition] = input - 0.25 * tailLowpassState
			tailPosition = tailPosition + 1; if tailPosition > tailLength then tailPosition = 1 end
			input = input + tailWet * tailLowpassState
		end
		-- high shelf 2.5 kHz -8 dB
		output = highShelfB0 * input + highShelfState1
		highShelfState1 = highShelfB1 * input - highShelfA1 * output + highShelfState2
		highShelfState2 = highShelfB2 * input - highShelfA2 * output
		-- outdoor space
		if reverbWet > 0 then
			local combSum = 0
			local comb = comb1
			local combOut = comb.buffer[comb.position]
			comb.lowpassState = comb.lowpassState + (combOut - comb.lowpassState) * reverbDamping
			comb.buffer[comb.position] = output + comb.lowpassState * comb.feedback
			comb.position = comb.position % comb.length + 1
			combSum = combSum + combOut
			comb = comb2
			combOut = comb.buffer[comb.position]
			comb.lowpassState = comb.lowpassState + (combOut - comb.lowpassState) * reverbDamping
			comb.buffer[comb.position] = output + comb.lowpassState * comb.feedback
			comb.position = comb.position % comb.length + 1
			combSum = combSum + combOut
			comb = comb3
			combOut = comb.buffer[comb.position]
			comb.lowpassState = comb.lowpassState + (combOut - comb.lowpassState) * reverbDamping
			comb.buffer[comb.position] = output + comb.lowpassState * comb.feedback
			comb.position = comb.position % comb.length + 1
			combSum = combSum + combOut
			comb = comb4
			combOut = comb.buffer[comb.position]
			comb.lowpassState = comb.lowpassState + (combOut - comb.lowpassState) * reverbDamping
			comb.buffer[comb.position] = output + comb.lowpassState * comb.feedback
			comb.position = comb.position % comb.length + 1
			combSum = combSum + combOut
			combSum = combSum * 0.25
			local allpass = allpass1
			local delayed = allpass.buffer[allpass.position]
			local allpassOut1 = delayed - 0.5 * combSum
			allpass.buffer[allpass.position] = combSum + 0.5 * allpassOut1
			allpass.position = allpass.position % allpass.length + 1
			allpass = allpass2
			delayed = allpass.buffer[allpass.position]
			local allpassOut2 = delayed - 0.5 * allpassOut1
			allpass.buffer[allpass.position] = allpassOut1 + 0.5 * allpassOut2
			allpass.position = allpass.position % allpass.length + 1
			output = output + reverbWet * allpassOut2
		end
		buffer[i] = output
	end
	highpassFilter[6], highpassFilter[7] = highpassState1, highpassState2
	peakFilter[6], peakFilter[7] = peakState1, peakState2
	lowShelfFilter[6], lowShelfFilter[7] = lowShelfState1, lowShelfState2
	trackingFilter[6], trackingFilter[7] = trackingState1, trackingState2
	topFilter[6], topFilter[7] = topState1, topState2
	tubeFilter[6], tubeFilter[7] = tubeState1, tubeState2
	highShelfFilter[6], highShelfFilter[7] = highShelfState1, highShelfState2
	chain.tubePosition = tubePosition
	chain.tailPosition, chain.tailLowpassState = tailPosition, tailLowpassState
end
Synth.ChainBlock = chainBlock

local BLOCK_SIZE = 256

---------------------------------------------------------------------------
-- Renderer: generator + chain, driven by a control function at 60 Hz like the page
---------------------------------------------------------------------------
--[[
	opts.control(t, dt) -> called every 1/60 s, returns a table of generator targets:
	    { targetRpm=, targetThrottle=, cut=, crank=, on= }  (the same message the page posts to its worklet)
	Returns the rendered array (1-based) from sample skip+1 to total.
]]
function Synth.RenderControlled(generator, chain, opts, total, yieldFn)
	local sampleRate = generator.sampleRate
	local out = {}
	local controlInterval = floor(sampleRate / 60 + 0.5)
	local nextControl = 0
	local time = 0
	local position = 0
	local tone, pitch = generator.tone, generator.pitch
	local skip = opts.skip or 0
	local scratch = {}
	local sinceYield = 0
	while position < total do
		if position >= nextControl then
			local message = opts.control(time, controlInterval / sampleRate)
			if message then
				for key, value in pairs(message) do generator[key] = value end
				chain.targetCutoff = Synth.CutoffFor(message.targetRpm or generator.targetRpm, message.targetThrottle or generator.targetThrottle, tone, pitch, generator.realism.voice)
			end
			nextControl = nextControl + controlInterval
			time = time + controlInterval / sampleRate
		end
		local count = min(BLOCK_SIZE, nextControl - position, total - position)
		updateCutoff(chain, count)
		Synth.GenRender(generator, scratch, 1, count)
		chainBlock(chain, scratch, 1, count)
		for i = 1, count do
			local outIndex = position + i - skip
			if outIndex >= 1 then out[outIndex] = scratch[i] end
		end
		position = position + count
		sinceYield = sinceYield + count
		if yieldFn and sinceYield >= 4096 then sinceYield = 0; yieldFn() end
	end
	return out
end

local function newEngine(config, sampleRate)
	return Synth.NewGen(sampleRate, config), Synth.NewChain(sampleRate, config)
end
Synth.NewEngine = newEngine

-- turn buf[1 .. L+X] into a seamless loop of length L by cross-fading the tail into the head
local function makeLoop(buffer, loopLength, crossfadeLength)
	local loop = {}
	for i = 1, loopLength do loop[i] = buffer[i] end
	for i = 1, crossfadeLength do
		local position = (i - 0.5) / crossfadeLength                 -- 0 -> 1
		local fadeIn = 0.5 - 0.5 * cos(pi * position)     -- raised cosine
		loop[i] = buffer[i] * fadeIn + buffer[loopLength + i] * (1 - fadeIn)
	end
	return loop
end
Synth.MakeLoop = makeLoop

--[[
	A steady loop at one rpm and throttle. Loops with the same rpm have the same length and
	the same firing phase (same random seed, pops off), so on/off-throttle layers of a band
	can be cross-faded in game without the pulses flamming.
]]
function Synth.RenderSteadyLoop(config, sampleRate, rpm, throttle, yieldFn, loopSeconds)
	local generator, chain = newEngine(config, sampleRate)
	generator.allowPops = false
	generator.ignitionOn = true; generator.gain = 1
	generator.rpm, generator.targetRpm, generator.throttle, generator.targetThrottle = rpm, rpm, throttle, throttle
	local cutoff = Synth.CutoffFor(rpm, throttle, config.tone, config.pitch, generator.realism.voice)
	chain.cutoff, chain.targetCutoff = cutoff, cutoff
	local cycleSamples = sampleRate * 120 / (rpm * config.pitch)           -- samples per 720 degree cycle
	local cycleCount = math.max(2, math.ceil(sampleRate * (loopSeconds or 1.6) / cycleSamples))
	local loopLength = floor(cycleCount * cycleSamples + 0.5)
	local crossfadeLength = floor(min(sampleRate * 0.12, loopLength * 0.25))
	local warmupSamples = floor(sampleRate * 1.0)
	local rendered = Synth.RenderControlled(generator, chain, {
		skip = warmupSamples,
		control = function() return { targetRpm = rpm, targetThrottle = throttle, fuelCut = false, crankMode = 0, ignitionOn = true } end,
	}, warmupSamples + loopLength + crossfadeLength, yieldFn)
	return makeLoop(rendered, loopLength, crossfadeLength), loopLength, generator.levellerGain
end

-- free-revving in neutral against the limiter (the page with the pedal held in N)
function Synth.LimiterControl(config)
	local Drivetrain = AUDIO_ENGINE.Drivetrain
	local limiterState = { rpm = config.redline - 600, limiterCutTimer = 0 }
	local steps = 0
	local events = {}
	local sampleAt = function(time, deltaTime)
		local throttle, fuelCut = 1, false
		if limiterState.rpm >= config.redline then
			if limiterState.limiterCutTimer <= 0 then events[#events + 1] = steps end
			limiterState.limiterCutTimer = 0.07
		end
		if limiterState.limiterCutTimer > 0 then
			limiterState.limiterCutTimer = limiterState.limiterCutTimer - deltaTime
			throttle = 0
			fuelCut = true
		end
		local idleThrottle = Drivetrain.clamp((config.idle - limiterState.rpm) / 400, 0, 0.3)
		local engineThrottle = fuelCut and 0 or math.max(throttle, idleThrottle)
		local netTorque = engineThrottle * Drivetrain.TMAX * Drivetrain.TorqueNorm(config, limiterState.rpm) - Drivetrain.TMAX * (0.05 + 0.12 * limiterState.rpm / config.redline)
		limiterState.rpm = Drivetrain.clamp(limiterState.rpm + netTorque * 42 * (config.redline / 7000) * deltaTime, 0, config.redline + 150)
		steps = steps + 1
		return { targetRpm = limiterState.rpm, targetThrottle = engineThrottle, fuelCut = fuelCut, crankMode = 0, ignitionOn = true }
	end
	return sampleAt, events
end

function Synth.RenderLimiterLoop(config, sampleRate, yieldFn)
	-- find the bounce period first (cheap, control rate only)
	local probe, bounceSteps = Synth.LimiterControl(config)
	for i = 0, 600 do probe(i / 60, 1 / 60) end
	local period = 6
	if #bounceSteps >= 4 then period = bounceSteps[#bounceSteps] - bounceSteps[#bounceSteps - 1] end
	local bounceCount = math.max(1, math.floor(60 * 1.0 / period + 0.5))  -- ~1 s of bounces
	local samplesPerControl = floor(sampleRate / 60 + 0.5)
	local loopLength = bounceCount * period * samplesPerControl
	local crossfadeLength = floor(min(sampleRate * 0.03, period * samplesPerControl * 0.4))
	local warmSteps = 240 + (period - 240 % period)
	local warmupSamples = warmSteps * samplesPerControl
	local generator, chain = newEngine(config, sampleRate)
	generator.allowPops = false
	generator.ignitionOn = true; generator.gain = 1
	generator.rpm, generator.targetRpm = config.redline - 600, config.redline - 600
	local control = Synth.LimiterControl(config)
	local rendered = Synth.RenderControlled(generator, chain, { skip = warmupSamples, control = control }, warmupSamples + loopLength + crossfadeLength, yieldFn)
	return makeLoop(rendered, loopLength, crossfadeLength), loopLength
end

--[[
	Start-up one-shot: the page's catch -> flare -> settle sequence, followed by a short
	stretch of idle that fades out while the idle loops fade in.
]]
function Synth.RenderStart(config, sampleRate, emotion, yieldFn)
	local Drivetrain = AUDIO_ENGINE.Drivetrain
	local startState = Drivetrain.New()
	Drivetrain.Start(startState, emotion)
	local tailSeconds = 0.45
	local control = function(time, deltaTime)
		if startState.phase ~= "run" then
			Drivetrain.StartSequence(startState, config, deltaTime)
		else
			local idleThrottle = Drivetrain.clamp((config.idle - startState.rpm) / 400, 0, 0.3)
			local netTorque = idleThrottle * Drivetrain.TMAX * Drivetrain.TorqueNorm(config, startState.rpm) - Drivetrain.TMAX * (0.05 + 0.12 * startState.rpm / config.redline)
			startState.rpm = startState.rpm + netTorque * 42 * (config.redline / 7000) * deltaTime
			startState.soundThrottle = idleThrottle
		end
		return { targetRpm = startState.rpm, targetThrottle = startState.soundThrottle, fuelCut = startState.fuelCut, crankMode = startState.crankMode, ignitionOn = true }
	end
	-- dry run at control rate to learn the length
	local probe = Drivetrain.New(); Drivetrain.Start(probe, emotion)
	local steps = 0
	while probe.phase ~= "run" and steps < 60 * 10 do Drivetrain.StartSequence(probe, config, 1 / 60); steps = steps + 1 end
	local fadeAt = steps / 60
	local duration = fadeAt + tailSeconds
	local total = floor(duration * sampleRate)
	local generator, chain = newEngine(config, sampleRate)
	generator.allowPops = false
	generator.rpm, generator.targetRpm = 150, 150
	local rendered = Synth.RenderControlled(generator, chain, { control = control }, total, yieldFn)
	local fadeStart = floor(fadeAt * sampleRate)
	for i = fadeStart + 1, total do
		local position = (i - fadeStart) / (total - fadeStart)
		rendered[i] = rendered[i] * (0.5 + 0.5 * cos(pi * position))
	end
	return rendered, fadeAt, duration
end

-- Shut-down one-shot: ignition off at idle, the crank spins down with compression thumps
function Synth.RenderStop(config, sampleRate, yieldFn)
	local generator, chain = newEngine(config, sampleRate)
	generator.allowPops = false
	local idle = config.idle
	local rpm = idle
	local warmupSamples = floor(sampleRate * 1.2)
	local control = function(time, deltaTime)
		if time < warmupSamples / sampleRate then
			return { targetRpm = idle, targetThrottle = 0.08, fuelCut = false, crankMode = 0, ignitionOn = true }
		end
		rpm = math.max(0, rpm - (500 + rpm * 1.6) * deltaTime)
		return { targetRpm = rpm, targetThrottle = 0, fuelCut = true, crankMode = rpm < 450 and 1 or 0, ignitionOn = rpm > 25 }
	end
	generator.ignitionOn = true; generator.gain = 1
	generator.rpm, generator.targetRpm, generator.throttle, generator.targetThrottle = idle, idle, 0.08, 0.08
	local duration = 1.6
	local rendered = Synth.RenderControlled(generator, chain, { skip = warmupSamples, control = control }, warmupSamples + floor(duration * sampleRate), yieldFn)
	-- a short fade-in so it can start on top of the fading loops, and a fade-out of the reverb tail
	local fadeInSamples = floor(sampleRate * 0.02)
	for i = 1, fadeInSamples do rendered[i] = rendered[i] * (i / fadeInSamples) end
	local fadeOutSamples = floor(sampleRate * 0.25)
	for i = 1, fadeOutSamples do local index = #rendered - fadeOutSamples + i; rendered[index] = rendered[index] * (1 - i / fadeOutSamples) end
	return rendered, duration
end

-- Overrun pop one-shot: the page's pop noise burst through the same chain
function Synth.RenderPops(config, sampleRate, seed, count, levellerGain, yieldFn)
	local generator, chain = newEngine(config, sampleRate)
	generator.seed = seed
	generator.allowPops = false
	generator.silenceFiring = true
	generator.fixedLevellerGain = levellerGain or 1
	generator.ignitionOn = true; generator.gain = 1
	local rpm = 4200
	generator.rpm, generator.targetRpm = rpm, rpm
	local cutoff = Synth.CutoffFor(rpm, 0, config.tone, config.pitch)
	chain.cutoff, chain.targetCutoff = cutoff, cutoff
	local popChance = 0.6  -- fixed strength; how often and how loud is up to the game
	local times = {}
	local nextTime = 0.004
	for i = 1, count do
		times[i] = nextTime
		nextTime = nextTime + 0.025 + 0.05 * (Synth.Rand(generator) * 0.5 + 0.5)
	end
	local fired = 0
	local duration = nextTime + 0.2
	local rendered = Synth.RenderControlled(generator, chain, {
		control = function(t)
			if fired < count and t >= times[fired + 1] then
				fired = fired + 1
				generator.popImpulse = (0.3 + 0.1 * Synth.Rand(generator)) * popChance
			end
			return { targetRpm = rpm, targetThrottle = 0, fuelCut = true, crankMode = 0, ignitionOn = true }
		end,
	}, floor(duration * sampleRate), yieldFn)
	return rendered, duration
end

--[[
	Bang: a big backfire. A sharp pressure pulse through both exhaust banks' resonators (the
	boom) plus a burst of the pop noise (the crack).
]]
function Synth.RenderBang(config, sampleRate, seed, levellerGain, yieldFn)
	local generator, chain = newEngine(config, sampleRate)
	generator.seed = seed
	generator.allowPops = false
	generator.silenceFiring = true
	generator.fixedLevellerGain = levellerGain or 1
	generator.ignitionOn = true; generator.gain = 1
	local rpm = 3500
	generator.rpm, generator.targetRpm = rpm, rpm
	local cutoff = Synth.CutoffFor(rpm, 1, config.tone, config.pitch)
	chain.cutoff, chain.targetCutoff = cutoff, cutoff
	local slowDecay, fastDecay, noiseDecayFactor = exp(-1 / (sampleRate * 0.018)), exp(-1 / (sampleRate * 0.0012)), exp(-1 / (sampleRate * 0.03))
	local fired = false
	local duration = 0.6
	local rendered = Synth.RenderControlled(generator, chain, {
		control = function(t)
			if not fired and t >= 0.01 then
				fired = true
				local strength = 2.2 + 0.4 * Synth.Rand(generator)
				generator.pulseSlowDecay = slowDecay
				generator.pulseFastDecay = fastDecay
				generator.noiseDecay = noiseDecayFactor
				generator.pulseSlowDecayRight = slowDecay
				generator.pulseFastDecayRight = fastDecay
				generator.noiseDecayRight = noiseDecayFactor
				generator.pulseSlow, generator.pulseFast, generator.noiseEnvelope = strength, strength, strength * 0.8
				generator.pulseSlowRight, generator.pulseFastRight, generator.noiseEnvelopeRight = strength * 0.9, strength * 0.9, strength * 0.7
				generator.popImpulse = 1.0 + 0.2 * Synth.Rand(generator)
			end
			return { targetRpm = rpm, targetThrottle = 1, fuelCut = true, crankMode = 0, ignitionOn = true }
		end,
	}, floor(duration * sampleRate), yieldFn)
	local fadeOutSamples = floor(sampleRate * 0.15)
	for i = 1, fadeOutSamples do local index = #rendered - fadeOutSamples + i; rendered[index] = rendered[index] * (1 - i / fadeOutSamples) end
	return rendered, duration
end

--[[
	Exhaust pops & bangs (backfires).
	A backfire is a pressure impulse: a near-instant rise, a few milliseconds of decay, and a
	burst of turbulent gas noise. It has no pitch, so there are no resonators or feedback
	delays here (those make it twang like a string). It's only an impulse plus a very short
	noise burst, shaped by broad filters and a little saturation for the crack.
	kind: "pop" (one small crack), "crackle" (a quick burst of 4-6), "bang" (one big boom)
]]
function Synth.RenderBackfire(config, sampleRate, seed, kind, yieldFn)
	local random = seededRand(seed or 0xBAC4)
	local function random01() return random() * 0.5 + 0.5 end
	local function lerp(from, to, share) return from + (to - from) * share end
	local isBang = kind == "bang"
	-- 0 = muffled (through the silencers), 1 = sharp (straight pipe)
	local sharpness = config.popTone or 0.2

	--[[
		Events (time, strength). Real overrun pops aren't evenly spaced clicks: unburnt fuel lights
		in a few exhaust pulses in a row, so they come as a ragged "b-r-rap" (a run of quick,
		uneven pops that swells and fades) or a single pop with a weaker echo.
	]]
	local events = {}
	if kind == "crackle" then
		local time, count = 0.004, 4 + floor(random01() * 5)
		for i = 1, count do
			local position = (i - 0.5) / count
			local swell = math.sin(math.pi * position) ^ 0.7          -- builds, then dies away
			if i == 1 or random01() > 0.15 then                      -- now and then a pulse doesn't light
				events[#events + 1] = { time, (0.35 + 0.65 * swell) * (0.6 + 0.4 * random01()) }
			end
			time = time + 0.018 + 0.04 * random01() * random01()                -- mostly quick, a few longer gaps
		end
	elseif isBang then
		events[1] = { 0.004, 1 }
		local time = 0.06 + 0.06 * random01()
		for i = 1, floor(random01() * 3) do                          -- an after-pop or two
			events[#events + 1] = { time, (0.45 - 0.12 * i) * (0.7 + 0.3 * random01()) }
			time = time + 0.035 + 0.06 * random01()
		end
	else
		events[1] = { 0.004, 0.8 + 0.2 * random01() }
		if random01() < 0.35 then events[2] = { 0.022 + 0.025 * random01(), 0.3 + 0.2 * random01() } end
	end

	--[[
		Each pop = a pressure thump + the scatter: the wave rattling out through the muffler
		chambers, a dense random burst of reflections tens of ms long. The thump rises over about
		a millisecond and the scatter rings on: a short, sharp spike with a quick tail is what made
		them sound like firecrackers / popcorn. Nothing here is periodic, so nothing has a pitch.
	]]
	local directLevel = lerp(0.18, 0.5, sharpness)
	local riseTime, decayTime = isBang and 0.0012 or 0.0009, isBang and 0.007 or 0.0042
	local scatterAttack = lerp(0.004, 0.0022, sharpness)
	local scatterDecay = isBang and lerp(0.1, 0.07, sharpness) or lerp(0.05, 0.035, sharpness)
	local duration = events[#events][1] + (isBang and 0.45 or 0.24)
	local sampleCount = floor(duration * sampleRate)

	local scatterFilters = {
		biquad("highpass", isBang and 70 or 90, sampleRate, -3),
		biquad("lowpass", lerp(650, 1600, sharpness), sampleRate, -3),
	}
	local shapeFilters = {
		biquad("highpass", isBang and 40 or 55, sampleRate, -3),
		biquad("peaking", isBang and 140 or 190, sampleRate, 0.9, 6),   -- the exhaust's body
		biquad("lowshelf", 150, sampleRate, 1, isBang and 4 or 2),
		biquad("lowpass", lerp(1000, 2200, sharpness), sampleRate, -3),
	}
	local function runFilters(designSampleRate, sample)
		for index = 1, #designSampleRate do
			local filter = designSampleRate[index]
			local output = filter[1] * sample + filter[6]
			filter[6] = filter[2] * sample - filter[4] * output + filter[7]
			filter[7] = filter[3] * sample - filter[5] * output
			sample = output
		end
		return sample
	end

	local raw = {}
	for i = 1, sampleCount do
		local time = (i - 1) / sampleRate
		local thump, scatter = 0, 0
		for _, event in ipairs(events) do
			local sinceEvent = time - event[1]
			if sinceEvent >= 0 and sinceEvent < 0.4 then
				thump = thump + event[2] * (1 - exp(-sinceEvent / riseTime)) * exp(-sinceEvent / decayTime)
				scatter = scatter + event[2] * (1 - exp(-sinceEvent / scatterAttack)) * exp(-sinceEvent / scatterDecay)
			end
		end
		local sample = thump * directLevel * 2.2 + runFilters(scatterFilters, random()) * scatter * 2.0
		raw[i] = runFilters(shapeFilters, sample)
		if yieldFn and i % 8192 == 0 then yieldFn() end
	end

	local peak = 1e-9
	for i = 1, sampleCount do local a = abs(raw[i]); if a > peak then peak = a end end
	local saturation = lerp(0.8, 1.4, sharpness) + (isBang and 0.2 or 0)   -- less saturation: a rounder crack
	local saturationNorm = 1 / tanh(saturation)
	local out = {}
	for i = 1, sampleCount do out[i] = tanh(saturation * raw[i] / peak) * saturationNorm end
	local fadeOutSamples = floor(sampleRate * 0.025)
	for i = 1, fadeOutSamples do local index = sampleCount - fadeOutSamples + i; out[index] = out[index] * (1 - i / fadeOutSamples) end
	return out, duration
end

--[[
	Exhaust pops (the version that's used). Overrun pops are unburnt fuel going off in the
	exhaust: an oversized exhaust pulse that travels through the same pipes and mufflers as
	every other firing. So this fires big pulses straight into the engine's own exhaust model
	(both banks' resonances, the drive, the muffled low-pass, the pipe) instead of
	synthesising a separate bang. They come out as a muffled "bup" in the engine's own voice.
	kind: "pop" (one), "crackle" (a quick uneven burst), "bang" (one big one plus an after-pop)
]]
function Synth.RenderExhaustPop(config, sampleRate, seed, kind, yieldFn)
	local random = seededRand(seed or 0x9091)
	local function random01() return random() * 0.5 + 0.5 end
	local isBang = kind == "bang"
	local generator, chain = newEngine(config, sampleRate)
	generator.seed = seed or 0x9091
	generator.allowPops = false
	generator.silenceFiring = true              -- no regular firing, only our pulses
	generator.fixedLevellerGain = 1
	generator.ignitionOn = true; generator.gain = 1
	local rpm = isBang and 3000 or 3800
	generator.rpm, generator.targetRpm, generator.throttle, generator.targetThrottle = rpm, rpm, 0, 0
	-- muffled: the overrun low-pass, a little brighter for bangs
	local cutoff = Synth.CutoffFor(rpm, isBang and 0.35 or 0.15, config.tone, config.pitch)
	chain.cutoff, chain.targetCutoff = cutoff, cutoff
	chain.trackingLowpass = biquad("lowpass", cutoff, sampleRate, 0.5)
	chain.reverbWet = 0.04            -- dry: no reverb tail

	local events = {}
	if kind == "crackle" then
		local time = 0.004
		for i = 1, 3 + floor(random01() * 3) do
			events[#events + 1] = { time, 0.55 + 0.45 * random01() }
			time = time + 0.03 + 0.07 * random01()
		end
	elseif isBang then
		events[1] = { 0.004, 1 }
		if random01() < 0.75 then events[2] = { 0.07 + 0.05 * random01(), 0.35 + 0.15 * random01() } end
	else
		events[1] = { 0.004, 0.8 + 0.2 * random01() }
	end
	local duration = events[#events][1] + (isBang and 0.32 or 0.16)
	local total = floor(duration * sampleRate)

	local out, scratch = {}, {}
	local position, nextEvent = 0, 1
	while position < total do
		-- fire any pulse due now
		while nextEvent <= #events and events[nextEvent][1] * sampleRate <= position do
			local amplitude = events[nextEvent][2]
			local strength = (isBang and 6 or 3.2) * amplitude * (0.9 + 0.2 * random01())
			local pulseTime = isBang and (0.008 + 0.003 * random01()) or (0.0045 + 0.002 * random01())
			local slowDecay = exp(-1 / (sampleRate * pulseTime))
			local fastDecay = exp(-1 / (sampleRate * min(pulseTime * 0.22, 0.0018)))
			local noiseDecayFactor = exp(-1 / (sampleRate * pulseTime * 0.6))
			if isBang or random01() < 0.5 then
				generator.pulseSlowDecay, generator.pulseFastDecay, generator.noiseDecay = slowDecay, fastDecay, noiseDecayFactor
				generator.pulseSlow = generator.pulseSlow + strength
				generator.pulseFast = generator.pulseFast + strength
				generator.noiseEnvelope = generator.noiseEnvelope + strength * 0.5
			end
			if isBang or random01() >= 0.5 or generator.pulseSlow < 0.01 then
				generator.pulseSlowDecayRight, generator.pulseFastDecayRight, generator.noiseDecayRight = slowDecay, fastDecay, noiseDecayFactor
				local rightStrength = isBang and strength * 0.85 or strength
				generator.pulseSlowRight = generator.pulseSlowRight + rightStrength
				generator.pulseFastRight = generator.pulseFastRight + rightStrength
				generator.noiseEnvelopeRight = generator.noiseEnvelopeRight + rightStrength * 0.5
			end
			nextEvent = nextEvent + 1
		end
		local untilNextEvent = nextEvent <= #events and floor(events[nextEvent][1] * sampleRate) - position or math.huge
		local count = min(128, total - position, math.max(1, untilNextEvent))
		Synth.GenRender(generator, scratch, 1, count)
		chainBlock(chain, scratch, 1, count)
		for i = 1, count do out[position + i] = scratch[i] end
		position = position + count
		if yieldFn and position % 8192 < 128 then yieldFn() end
	end
	-- keep the exhaust's voice but lose the 78 Hz boom: the "bap" lives in the upper pipe modes
	local highpassA = biquad("highpass", isBang and 95 or 140, sampleRate, 0)
	local highpassB = biquad("highpass", isBang and 95 or 140, sampleRate, 0)
	local barkPeak = biquad("peaking", isBang and 380 or 480, sampleRate, 0.7, 7)
	for i = 1, total do
		local x = out[i]
		for _, filter in ipairs({ highpassA, highpassB, barkPeak }) do
			local output = filter[1] * x + filter[6]
			filter[6] = filter[2] * x - filter[4] * output + filter[7]
			filter[7] = filter[3] * x - filter[5] * output
			x = output
		end
		out[i] = x
	end
	local fadeOutSamples = floor(sampleRate * 0.04)
	for i = 1, fadeOutSamples do local index = total - fadeOutSamples + i; out[index] = out[index] * (1 - i / fadeOutSamples) end
	return out, duration
end

---------------------------------------------------------------------------
-- Turbo
---------------------------------------------------------------------------
local function noiseGen(seed)
	local state = seed
	return function()
		state = bxor(state, lshift(state, 13)); state = bxor(state, rshift(state, 17)); state = bxor(state, lshift(state, 5))
		return state / 2147483648
	end
end

local function runBiquad(filter, input)
	local output = filter[1] * input + filter[6]
	filter[6] = filter[2] * input - filter[4] * output + filter[7]
	filter[7] = filter[3] * input - filter[5] * output
	return output
end

--[[
	Turbo loop at full boost: a soft, round compressor whine with a little bearing wobble and
	a narrow band of air around the tone (broadband intake rush sounded like a vacuum cleaner).
	Everything above ~3 kHz is rolled off. The game pitches it with boost.
]]
function Synth.RenderTurboLoop(sampleRate, yieldFn)
	local random = noiseGen(0x5EED7)
	local whineHz = 1700
	local loopLength = floor(sampleRate * 1.5)
	local crossfadeLength = floor(sampleRate * 0.15)
	local totalSamples = loopLength + crossfadeLength
	local buffer = {}
	local phase = 0
	local drift = 0
	local air = biquad("bandpass", whineHz, sampleRate, 3)
	local toneLowpass1 = biquad("lowpass", 3200, sampleRate, 0)
	local toneLowpass2 = biquad("lowpass", 3200, sampleRate, 0)
	for i = 1, totalSamples do
		local noise = random()
		drift = drift + (noise - drift) * 0.0004
		local frequency = whineHz * (1 + 0.008 * drift * 30)
		phase = phase + frequency / sampleRate; if phase >= 1 then phase = phase - 1 end
		local tone = sin(TAU * phase) * 0.8 * (1 + 0.08 * sin(TAU * 7 * i / sampleRate))
		buffer[i] = runBiquad(toneLowpass2, runBiquad(toneLowpass1, tone + runBiquad(air, random()) * 1.4))
		if yieldFn and i % 8192 == 0 then yieldFn() end
	end
	return makeLoop(buffer, loopLength, crossfadeLength), loopLength
end

--[[
	Supercharger loop: a belt-driven blower spins with the crank, so unlike the turbo its whine
	is locked to the revs. Rendered in bands an octave apart (SC_BANDS, rpm at the whine pitch
	the variant is tuned to); cl_engine cross-fades the two around the revs x config.scPitch, like
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
	sport = { whineHz = 1350, harmonics = { 1, 0.16, 0.06 }, rotorRipple = 0.08, lobeCount = 6, airLevel = 1.0, airBandQ = 2.5,
		cutoffHz = 3600, driftAmount = 0.010, level = 1,
		fmDepth = 0.008, amDepth = 0.18, lobePuff = 0.7, runoutAmount = 0.10, timingGearLevel = 0.12, boostHiss = 0.5, partialJitter = 0.2 },
	regular = { whineHz = 1300, harmonics = { 1, 0.11, 0.03 }, rotorRipple = 0.06, lobeCount = 6, airLevel = 1.1, airBandQ = 2,
		cutoffHz = 2900, driftAmount = 0.009, level = 0.6,
		fmDepth = 0.006, amDepth = 0.14, lobePuff = 0.6, runoutAmount = 0.08, timingGearLevel = 0.08, boostHiss = 0.3, partialJitter = 0.18 },
	heavy = { whineHz = 950, harmonics = { 1, 0.20, 0.07 }, rotorRipple = 0.10, lobeCount = 6, airLevel = 1.2, airBandQ = 1.6,
		cutoffHz = 2100, driftAmount = 0.010, level = 0.45,
		fmDepth = 0.010, amDepth = 0.22, lobePuff = 0.85, runoutAmount = 0.12, timingGearLevel = 0.06, boostHiss = 0.15, partialJitter = 0.2 },
}

Synth.SC_ORDER = { "sport", "regular", "heavy" }

function Synth.RenderSuperchargerLoop(sampleRate, variant, yieldFn, bypassOpen, bandRpm)
	local variantConfig = Synth.SC_VARIANTS[variant] or Synth.SC_VARIANTS.sport
	-- designed at SC_DESIGN_RPM and rendered at the band's rpm: render as if at another sample
	-- rate, which is exactly the game pitching it
	local designSampleRate = sampleRate * SC_DESIGN_RPM / bandRpm
	local random = noiseGen(0x5C0A1)
	local loopLength = floor(sampleRate * 1.5)
	local crossfadeLength = floor(sampleRate * 0.15)
	local totalSamples = loopLength + crossfadeLength
	-- the loop's length in design time: every periodic part gets a whole number of cycles in it
	local loopSeconds = loopLength / designSampleRate
	local function wholeCycles(frequency) return max(1, floor(frequency * loopSeconds + 0.5)) / loopSeconds end
	-- the whine, so the rotor turn (whine / lobeCount) comes out whole too
	local whineHz = max(1, floor(variantConfig.whineHz * loopSeconds / variantConfig.lobeCount + 0.5)) * variantConfig.lobeCount / loopSeconds
	local timingGearRatio = floor(1.37 * whineHz * loopSeconds + 0.5) / (whineHz * loopSeconds)
	local firingHz = wholeCycles(SC_DESIGN_RPM / 60 * 4)   -- a V8 fires 4 times a crank turn
	-- slow wobbles: two whole-cycle sines each, random phases, at the size of the low-passed noise
	-- they replace (rms 0.0097 drift, 0.0059 / 0.0059 / 0.0048 partial levels)
	local function wobble(size, frequencyA, frequencyB)
		local cyclesA, cyclesB = wholeCycles(frequencyA), wholeCycles(frequencyB)
		return { cyclesA / designSampleRate, cyclesB / designSampleRate, random() * TAU, random() * TAU, size }
	end
	local wobbles = { wobble(0.0097, 1.9, 3.1), wobble(0.0059, 1.3, 2.3), wobble(0.0059, 1.1, 2.7), wobble(0.0048, 0.95, 1.7) }
	local function wobbleAt(wobble, index) return wobble[5] * (sin(TAU * wobble[1] * index + wobble[3]) + sin(TAU * wobble[2] * index + wobble[4])) end
	local toneBuf, airBuf = {}, {}
	local whinePhase, rotorPhase, firingPhase, gearPhase = 0, 0, 0, 0
	-- bypass open: the tone falls back, darker; on boost the intake hisses
	local toneLevel = bypassOpen and 0.45 or 1
	local cutoff = bypassOpen and variantConfig.cutoffHz * 0.6 or variantConfig.cutoffHz
	local airFilter = biquad("bandpass", variantConfig.whineHz, designSampleRate, variantConfig.airBandQ)
	local hissFilter = biquad("bandpass", 2600, designSampleRate, 0.9)
	local toneLowpass1, toneLowpass2 = biquad("lowpass", cutoff, designSampleRate, 0), biquad("lowpass", cutoff, designSampleRate, 0)
	local airLowpass1, airLowpass2 = biquad("lowpass", cutoff, designSampleRate, 0), biquad("lowpass", cutoff, designSampleRate, 0)
	local harmonic1, harmonic2, harmonic3 = variantConfig.harmonics[1], variantConfig.harmonics[2], variantConfig.harmonics[3]
	local fmDepth = variantConfig.fmDepth
	local amDepth = variantConfig.amDepth
	local puffAmount = variantConfig.lobePuff
	local runoutAmount = variantConfig.runoutAmount
	local gearLevel = variantConfig.timingGearLevel
	local jitterAmount = variantConfig.partialJitter
	local hissLevel = bypassOpen and 0 or variantConfig.boostHiss
	for i = 1, totalSamples do
		local driftWobble, harmonic2Wobble, harmonic3Wobble, levelWobble = wobbleAt(wobbles[1], i), wobbleAt(wobbles[2], i), wobbleAt(wobbles[3], i), wobbleAt(wobbles[4], i)
		-- firing pulses: the belt and rotors speed up and slow a hair on every power stroke
		firingPhase = firingPhase + firingHz / designSampleRate; if firingPhase >= 1 then firingPhase = firingPhase - 1 end
		local pulse = sin(TAU * firingPhase)
		local frequency = whineHz * (1 + variantConfig.driftAmount * driftWobble * 30) * (1 + fmDepth * pulse)
		whinePhase = whinePhase + frequency / designSampleRate; if whinePhase >= 1 then whinePhase = whinePhase - 1 end
		-- rotor turn (lobe pass / lobeCount): runout puts sidebands either side of the whine
		rotorPhase = rotorPhase + frequency / variantConfig.lobeCount / designSampleRate; if rotorPhase >= 1 then rotorPhase = rotorPhase - 1 end
		-- timing gears: a fainter, higher whine at their own ratio
		gearPhase = gearPhase + frequency * timingGearRatio / designSampleRate; if gearPhase >= 1 then gearPhase = gearPhase - 1 end
		local whineAngle = TAU * whinePhase
		local rotorWave = sin(TAU * rotorPhase)
		local tone = harmonic1 * sin(whineAngle + runoutAmount * 3 * rotorWave)
			+ harmonic2 * (1 + jitterAmount * 8 * harmonic2Wobble) * sin(2 * whineAngle + 0.4)
			+ harmonic3 * (1 + jitterAmount * 8 * harmonic3Wobble) * sin(3 * whineAngle + 1.1)
			+ gearLevel * sin(TAU * gearPhase)
		tone = tone * (1 + variantConfig.rotorRipple * rotorWave) * (1 + amDepth * pulse) * (1 + jitterAmount * 6 * levelWobble) * 0.6 * toneLevel
		-- intake air, pushed in puffs as each lobe passes
		local lobe = 0.5 + 0.5 * sin(whineAngle)
		local airSample = runBiquad(airFilter, random()) * variantConfig.airLevel * (1 - puffAmount + puffAmount * 2 * lobe * lobe)
		if hissLevel > 0 then airSample = airSample + runBiquad(hissFilter, random()) * hissLevel * (1 + amDepth * pulse) end
		toneBuf[i] = runBiquad(toneLowpass2, runBiquad(toneLowpass1, tone))
		airBuf[i] = runBiquad(airLowpass2, runBiquad(airLowpass1, airSample))
		if yieldFn and i % 8192 == 0 then yieldFn() end
	end
	-- the tone repeats exactly (its second pass has the filters settled); the noise doesn't, so
	-- it's cross-faded at equal power
	local loop = {}
	for i = 1, loopLength do
		if i <= crossfadeLength then
			local crossfadePosition = (i - 0.5) / crossfadeLength
			loop[i] = toneBuf[loopLength + i] + airBuf[i] * sin(crossfadePosition * pi / 2) + airBuf[loopLength + i] * cos(crossfadePosition * pi / 2)
		else
			loop[i] = toneBuf[i] + airBuf[i]
		end
	end
	return loop, loopLength
end

--[[
	Electric low-speed hum, like the pedestrian warning sound EVs play at walking pace: a soft,
	low tone (220 Hz and a little of its octave) in a breath of air, with a slow shimmer, no motor in it.
	cl_engine plays it at an almost fixed pitch and fades it out by ~30 km/h. Shared by every
	electric car (env bank).
]]
function Synth.RenderEVHumLoop(sampleRate, yieldFn)
	local random = noiseGen(0xE7A5)
	local loopLength = floor(sampleRate * 2)
	local crossfadeLength = floor(sampleRate * 0.2)
	local totalSamples = loopLength + crossfadeLength
	local buffer = {}
	local baseHz = 220
	local airFilter = biquad("bandpass", 900, sampleRate, 0.8)
	local lowpass = biquad("lowpass", 1600, sampleRate, 0)
	for i = 1, totalSamples do
		local time = i / sampleRate
		-- two slightly detuned voices beat slowly (0.5 Hz): a living hum, not a test tone
		local shimmer = 1 + 0.15 * sin(TAU * 0.5 * time)
		local tone = 0.50 * sin(TAU * baseHz * time)
			+ 0.10 * sin(TAU * (baseHz * 2 + 0.5) * time) * shimmer
		buffer[i] = runBiquad(lowpass, tone * 0.5 + runBiquad(airFilter, random()) * 0.25)
		if yieldFn and i % 8192 == 0 then yieldFn() end
	end
	return makeLoop(buffer, loopLength, crossfadeLength), loopLength
end

--[[
	Blow-off: on a recirculating valve (stock) it's a soft, dark "pshh" with a short tail and a
	gentle flutter as the compressor surges.
]]
function Synth.RenderBlowoff(sampleRate, seed, yieldFn)
	local random = noiseGen(seed or 0xB10F)
	local duration = 0.5
	local sampleCount = floor(sampleRate * duration)
	local buffer = {}
	local band1 = biquad("bandpass", 900, sampleRate, 0.7)
	local band2 = biquad("bandpass", 2200, sampleRate, 1.0)
	local lowpass = biquad("lowpass", 4500, sampleRate, 0)
	local flutterHz = 17 + 4 * random()
	for i = 1, sampleCount do
		local time = (i - 1) / sampleRate
		local envelope = min(1, time / 0.008) * exp(-time / 0.12)
		local flutter = 1 - 0.3 * exp(-time / 0.15) * (0.5 + 0.5 * sin(TAU * flutterHz * time))
		local noise = runBiquad(band1, random()) * 1.2 + runBiquad(band2, random()) * 0.5
		buffer[i] = runBiquad(lowpass, noise) * envelope * flutter
		if yieldFn and i % 8192 == 0 then yieldFn() end
	end
	return buffer, duration
end

---------------------------------------------------------------------------
-- Rolling noise (not the engine): tyre roar on the road, and wind. Played by speed.
---------------------------------------------------------------------------
local function loopNoise(sampleRate, seconds, crossfadeSeconds, seed, sampleAt, yieldFn)
	local random = noiseGen(seed)
	local loopLength = floor(sampleRate * seconds)
	local crossfadeLength = floor(sampleRate * crossfadeSeconds)
	local buffer = {}
	for i = 1, loopLength + crossfadeLength do
		buffer[i] = sampleAt(random, (i - 1) / sampleRate)
		if yieldFn and i % 8192 == 0 then yieldFn() end
	end
	return makeLoop(buffer, loopLength, crossfadeLength), loopLength
end

-- tyres on asphalt: a broad low-mid roar over a deep rumble from the road surface
function Synth.RenderRoadLoop(sampleRate, yieldFn)
	local roar1 = biquad("bandpass", 420, sampleRate, 0.6)
	local roar2 = biquad("lowpass", 1300, sampleRate, -3)
	local rumble = biquad("lowpass", 110, sampleRate, -3)
	local highpass = biquad("highpass", 35, sampleRate, -3)
	local loop, loopLength = loopNoise(sampleRate, 2.0, 0.25, 0x0AD5, function(random)
		local roar = runBiquad(roar2, runBiquad(roar1, random()))
		local rumbleNoise = runBiquad(rumble, random()) * 3.0
		return runBiquad(highpass, roar * 1.4 + rumbleNoise)
	end, yieldFn)
	return loop, loopLength
end

-- wind over the body: band-limited noise with slow gusts
function Synth.RenderWindLoop(sampleRate, yieldFn)
	local highpass = biquad("highpass", 280, sampleRate, -3)
	local lowpass = biquad("lowpass", 2600, sampleRate, -3)
	local body = biquad("peaking", 850, sampleRate, 0.6, 4)
	local loop, loopLength = loopNoise(sampleRate, 3.0, 0.3, 0x0B1D, function(random, time)
		local gust = 1 + 0.22 * sin(TAU * time / 3) + 0.12 * sin(TAU * 2 * time / 3 + 1.3)
		return runBiquad(body, runBiquad(lowpass, runBiquad(highpass, random()))) * gust
	end, yieldFn)
	return loop, loopLength
end

return Synth
