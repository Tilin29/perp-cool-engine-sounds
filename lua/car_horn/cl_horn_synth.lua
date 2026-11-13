--[[
	Car horn synth: renders one horn of CAR_HORN.CONFIG as one sound: the horn's attack, then a
	seamless loop that holds while the key is held (it starts at the returned loopStart sample).
	Plain Lua (no game calls): the game builds its sounds from it and dev/honk_studio runs the
	same file in the browser, so the studio plays exactly what the game will.

	A horn is one or more horn units (an ordinary car has a pair, a high and a low one; a truck's
	air horn three trumpets), each a buzzing diaphragm: a wavetable of the horn's harmonics, plus
	`rasp`, a burst of noise each cycle where the diaphragm strikes its stop. `air` is a steady
	rush of air under the tone (an air horn), at full from the moment it's pressed.
	No real horn holds still, and a perfectly steady one sounds synthetic:
	  * `jitter`: each unit's pitch wanders on its own, a smooth random drift
	  * `shimmer`: each cycle of each unit comes out a little louder or softer than the last
	  * `roughness`: each cycle a little longer or shorter than the last (a hard-driven diaphragm):
	    the blat that keeps an air horn from sounding like a musical chord
	  * `growl`: every other cycle stronger, a rumble an octave under the note
	On pressing, the units scoop up to pitch over attack.time from attack.pitch while the level
	rises, ragged at first: roughness, rasp and air stronger (the diaphragm catching), settling by
	the attack's end. Then a speaker as the siren's:
	highpass, drive (soft clipping), a resonant peak (the horn's trumpet) and a lowpass, and
	`grille`: the short reflections of the bumper and grille the horn sits behind.
	Letting go is played, not rendered: a fade over release.time falling to release.pitch.
	The loop lines up at its ends:
	  * every wobble (flutter, jitter, shimmer, noise) is read by the position in the loop, so it repeats with it
	  * each unit is tuned (by a cent or two) to a whole number of cycles over the loop
	  * SETTLE_SECONDS of steady sound after the attack feeds the filters and the grille exactly what the
	    loop's end does, so they're in the same state when it wraps
	The inside-the-car version adds a steeper lowpass (the car's body muffling it).
]]
CAR_HORN = CAR_HORN or {}
local Synth = {}
CAR_HORN.Synth = Synth

local TABLE_SIZE = 2048
local NYQUIST_SHARE = 0.45
local LOOP_SECONDS = 2
local SETTLE_SECONDS = 0.05
local RASP_DECAY = 12
-- extra at the very start of the attack (x the horn's own), gone by its end: the diaphragm catching
local ATTACK_RASP = 1.5
local ATTACK_ROUGHNESS = 2
local ATTACK_AIR = 2
local AIR_NOISE_SHIFT = 104729   -- the air reads the noise table elsewhere than the units' rasp
local PEAK = 0.95
local YIELD_EVERY = 8192
local TWO_PI = math.pi * 2
-- the bumper and grille: { delay (s), gain } of each reflection
local GRILLE_TAPS = { { 0.0007, 0.45 }, { 0.0013, -0.3 }, { 0.0021, 0.25 }, { 0.0034, -0.15 }, { 0.0052, 0.1 } }

Synth.LOOP_SECONDS = LOOP_SECONDS

local floor, sin, cos, exp, max, min, abs = math.floor, math.sin, math.cos, math.exp, math.max, math.min, math.abs

local function round(value)
	return floor(value + 0.5)
end

local function tanh(value)
	if value > 15 then return 1 end
	if value < -15 then return -1 end
	local exponential = exp(2 * value)

	return (exponential - 1) / (exponential + 1)
end

-- the same random numbers every render, -1..1 (Park-Miller: exact in doubles and in integers)
local function randomTable(count, seed)
	local values, state = {}, seed
	for i = 0, count - 1 do
		state = (state * 16807) % 2147483647
		values[i] = state / 2147483647 * 2 - 1
	end

	return values
end

-- a smooth random curve over one loop: `points` random values, eased between, the last into the first
local function driftTable(count, points, seed)
	local anchors, values = randomTable(points, seed), {}
	for i = 0, count - 1 do
		local position = i / count * points
		local index = floor(position)
		local blend = 0.5 - 0.5 * cos(math.pi * (position - index))
		values[i] = anchors[index] + (anchors[(index + 1) % points] - anchors[index]) * blend
	end

	return values
end

-- a single cycle holding the harmonics that stay under the Nyquist limit at this top frequency
local function wavetable(harmonics, topFreq, sampleRate)
	local waveTable, peak = {}, 0
	local limit = sampleRate * NYQUIST_SHARE
	for i = 0, TABLE_SIZE - 1 do
		local sample, phase = 0, TWO_PI * i / TABLE_SIZE
		for harmonic = 1, #harmonics do
			local amplitude = harmonics[harmonic] or 0
			if amplitude ~= 0 and harmonic * topFreq < limit then sample = sample + amplitude * sin(harmonic * phase) end
		end
		waveTable[i] = sample
		peak = max(peak, abs(sample))
	end
	if peak > 0 then
		for i = 0, TABLE_SIZE - 1 do waveTable[i] = waveTable[i] / peak end
	end
	waveTable[TABLE_SIZE] = waveTable[0]

	return waveTable
end

-- RBJ biquad coefficients: "hp", "lp" or "peak"
local function biquad(kind, frequency, q, gainDb, sampleRate)
	frequency = min(max(frequency, 10), sampleRate * NYQUIST_SHARE)
	q = max(q, 0.1)
	local omega = TWO_PI * frequency / sampleRate
	local cw, alpha = cos(omega), sin(omega) / (2 * q)
	local b0, b1, b2, a0, a1, a2
	if kind == "hp" then
		b0, b1, b2 = (1 + cw) / 2, -(1 + cw), (1 + cw) / 2
		a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
	elseif kind == "lp" then
		b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
		a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
	else
		local gainFactor = 10 ^ (gainDb / 40)
		b0, b1, b2 = 1 + alpha * gainFactor, -2 * cw, 1 - alpha * gainFactor
		a0, a1, a2 = 1 + alpha / gainFactor, -2 * cw, 1 - alpha / gainFactor
	end

	return { b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0, 0, 0, 0, 0 }
end

local function runBiquad(filter, input)
	local output = filter[1] * input + filter[2] * filter[6] + filter[3] * filter[7] - filter[4] * filter[8] - filter[5] * filter[9]
	filter[7], filter[6] = filter[6], input
	filter[9], filter[8] = filter[8], output

	return output
end

-- one unit's frequency at every sample of the loop: its note, the flutter, its own drift and its
-- roughness, scaled so the loop holds a whole number of its cycles (an even one with growl, which
-- alternates them). Returns the table, the cycle count, the top and the roughness alone (octaves,
-- nil without it: the attack strengthens it)
local function unitFrequencies(unit, unitIndex, horn, loopCount, sampleRate)
	local loopSeconds = loopCount / sampleRate
	local flutter, jitter = horn.flutter or {}, horn.jitter or {}
	local flutterCycles = (flutter.rate or 0) > 0 and max(1, round(flutter.rate * loopSeconds)) or 0
	local flutterDepth = (flutter.depth or 0) / 1200
	local jitterPoints = (jitter.rate or 0) > 0 and max(2, round(jitter.rate * loopSeconds)) or 0
	local jitterDepth = (jitter.depth or 0) / 1200
	local drift = jitterPoints > 0 and jitterDepth ~= 0 and driftTable(loopCount, jitterPoints, 1000 + unitIndex * 7777)
	-- a new random length about every other cycle
	local roughnessDepth = max(horn.roughness or 0, 0) / 1200
	local roughness
	if roughnessDepth > 0 then
		roughness = driftTable(loopCount, max(2, round(unit.f * loopSeconds / 2)), 9000 + unitIndex * 1231)
		for i = 0, loopCount - 1 do roughness[i] = roughness[i] * roughnessDepth end
	end

	local frequencies, cycles = {}, 0
	for i = 0, loopCount - 1 do
		local octaves = 0
		if flutterCycles > 0 then octaves = octaves + flutterDepth * sin(TWO_PI * flutterCycles * i / loopCount) end
		if drift then octaves = octaves + jitterDepth * drift[i] end
		if roughness then octaves = octaves + roughness[i] end
		frequencies[i] = unit.f * 2 ^ octaves
		cycles = cycles + frequencies[i]
	end
	cycles = cycles / sampleRate
	local wholeCycles = max(1, round(cycles))
	if (horn.growl or 0) > 0 then wholeCycles = max(2, 2 * round(cycles / 2)) end
	local scale, top = wholeCycles / cycles, 0
	for i = 0, loopCount - 1 do
		frequencies[i] = frequencies[i] * scale
		top = max(top, frequencies[i])
	end

	return frequencies, wholeCycles, top, roughness
end

--[[
	Renders horn `horn` with the settings `config` (CAR_HORN.CONFIG's sampleRate/cabin).
	Returns the samples (1-based, peak PEAK), the sample rate, the length in samples and the
	sample the loop starts at (0-based, as sound.Generate's loopStart takes it).
	`yield`, if given, is called every few thousand samples (the game renders in a coroutine).
	`inside`: the version heard inside the car, muffled at config.cabin.muffle Hz.
]]
function Synth.Render(horn, config, yield, inside)
	local sampleRate = config.sampleRate or 44100
	local loopCount = round(LOOP_SECONDS * sampleRate)
	local attack = horn.attack or {}
	local attackCount = round(max(attack.time or 0, 0) * sampleRate)
	local attackPitch = attack.pitch or 1
	local attackCurve = max(attack.curve or 1, 0.05)
	local loopStart = attackCount + round(SETTLE_SECONDS * sampleRate)
	local sampleCount = loopStart + loopCount

	local harmonics = horn.harmonics or { 1 }
	local shimmer = max(horn.shimmer or 0, 0)
	local growl = min(max(horn.growl or 0, 0), 1)
	local voices = {}
	for unitIndex, unit in ipairs(horn.units or {}) do
		local level = unit.level or 1
		if (unit.f or 0) > 0 and level > 0 then
			local frequencies, cycles, top, roughness = unitFrequencies(unit, unitIndex, horn, loopCount, sampleRate)
			-- the attack's extra roughness can lift the pitch over the loop's top
			if roughness then top = top * 2 ^ (max(horn.roughness, 0) / 1200 * ATTACK_ROUGHNESS) end
			voices[#voices + 1] = {
				frequencies = frequencies, roughness = roughness, level = level, phase = 0, cycle = 0, cycles = cycles,
				cycleGains = shimmer > 0 and randomTable(cycles, 5000 + unitIndex * 3331),
				waveTable = wavetable(harmonics, top * max(attackPitch, 1), sampleRate),
				noiseShift = unitIndex * 7919,
			}
		end
	end

	local rasp = max(horn.rasp or 0, 0)
	local air = max(horn.air or 0, 0)
	local noise = (rasp > 0 or air > 0) and randomTable(loopCount, 12345)

	local speaker = horn.speaker or {}
	local highpass = biquad("hp", speaker.highpass or 20, 0.707, 0, sampleRate)
	local lowpass = biquad("lp", speaker.lowpass or 20000, 0.707, 0, sampleRate)
	local resonance = biquad("peak", speaker.resonance or 1000, speaker.resonanceQ or 1, speaker.resonanceGain or 0, sampleRate)
	local drive = max(speaker.drive or 0, 0)
	local driveNorm = drive > 0 and 1 / tanh(drive) or 1
	local muffleHz = inside and config.cabin and config.cabin.muffle
	local muffleLowpassA = muffleHz and biquad("lp", muffleHz, 0.707, 0, sampleRate)
	local muffleLowpassB = muffleHz and biquad("lp", muffleHz, 0.707, 0, sampleRate)

	local grille = max(horn.grille or 0, 0)
	local grilleTaps, history, historySize = {}, {}, 1
	if grille > 0 then
		for _, tap in ipairs(GRILLE_TAPS) do
			local delay = max(1, round(tap[1] * sampleRate))
			grilleTaps[#grilleTaps + 1] = { delay = delay, gain = tap[2] * grille }
			historySize = max(historySize, delay + 1)
		end
		for i = 0, historySize - 1 do history[i] = 0 end
	end

	local out, outPeak = {}, 0
	for i = 0, sampleCount - 1 do
		local loopIndex = (i - loopStart) % loopCount
		local pitchFactor, envelope, raspFactor, airFactor, attackLeft = 1, 1, rasp, air, 0
		if i < attackCount then
			local progress = (i / attackCount) ^ attackCurve
			attackLeft = 1 - i / attackCount
			pitchFactor = attackPitch + (1 - attackPitch) * progress
			envelope = sin(progress * math.pi / 2)
			raspFactor = rasp * (1 + ATTACK_RASP * attackLeft)
			airFactor = air * (1 + ATTACK_AIR * attackLeft)
		end

		local sample = 0
		for v = 1, #voices do
			local voice = voices[v]
			local frequency = voice.frequencies[loopIndex] * pitchFactor
			if attackLeft > 0 and voice.roughness then frequency = frequency * 2 ^ (voice.roughness[loopIndex] * ATTACK_ROUGHNESS * attackLeft) end
			local phase = voice.phase + frequency / sampleRate
			if phase >= 1 then
				phase = phase % 1
				voice.cycle = (voice.cycle + 1) % voice.cycles
			end
			voice.phase = phase
			local tablePosition = phase * TABLE_SIZE
			local tableIndex = floor(tablePosition)
			local waveTable = voice.waveTable
			local value = waveTable[tableIndex] + (waveTable[tableIndex + 1] - waveTable[tableIndex]) * (tablePosition - tableIndex)
			if noise then value = value + raspFactor * noise[(loopIndex + voice.noiseShift) % loopCount] * exp(-RASP_DECAY * phase) end
			if voice.cycleGains then value = value * (1 + shimmer * voice.cycleGains[voice.cycle]) end
			if growl > 0 then value = value * (voice.cycle % 2 == 0 and 1 + growl or 1 - growl) end
			sample = sample + voice.level * value
		end
		sample = sample * envelope
		if air > 0 then sample = sample + airFactor * noise[(loopIndex + AIR_NOISE_SHIFT) % loopCount] end
		sample = runBiquad(highpass, sample)
		if drive > 0 then sample = tanh(sample * drive) * driveNorm end
		sample = runBiquad(lowpass, runBiquad(resonance, sample))
		if grille > 0 then
			local slot = i % historySize
			history[slot] = sample
			for t = 1, #grilleTaps do
				local tap = grilleTaps[t]
				sample = sample + tap.gain * history[(slot - tap.delay) % historySize]
			end
		end
		if muffleLowpassA then sample = runBiquad(muffleLowpassB, runBiquad(muffleLowpassA, sample)) end
		out[i + 1] = sample
		outPeak = max(outPeak, abs(sample))
		if yield and i % YIELD_EVERY == 0 then yield() end
	end

	local normalizeGain = outPeak > 0 and PEAK / outPeak or 0
	for i = 1, sampleCount do out[i] = out[i] * normalizeGain end

	return out, sampleRate, sampleCount, loopStart
end
