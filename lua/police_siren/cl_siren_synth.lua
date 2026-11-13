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

local function round(value)
	return floor(value + 0.5)
end

local function tanh(value)
	if value > 15 then return 1 end
	if value < -15 then return -1 end
	local exponential = exp(2 * value)

	return (exponential - 1) / (exponential + 1)
end

-- the pattern as timed segments over one loop: a glide into each point, then its hold
function Synth.Segments(pattern)
	local segments, time = {}, 0
	local pointCount = #pattern
	for i = 1, pointCount do
		local point = pattern[i]
		local previousPoint = pattern[i == 1 and pointCount or i - 1]
		local glide, hold = max(point.glide or 0, 0), max(point.hold or 0, 0)
		if glide > 0 then
			segments[#segments + 1] = { startTime = time, endTime = time + glide, startHz = previousPoint.f, endHz = point.f, curve = point.curve or 1 }
			time = time + glide
		end
		if hold > 0 then
			segments[#segments + 1] = { startTime = time, endTime = time + hold, startHz = point.f, endHz = point.f, curve = 1 }
			time = time + hold
		end
	end
	if time < MIN_LOOP then
		local frequency = pointCount > 0 and pattern[1].f or 440
		segments = { { startTime = 0, endTime = MIN_LOOP, startHz = frequency, endHz = frequency, curve = 1 } }
		time = MIN_LOOP
	end

	return segments, time
end

--[[
	A glide's shape: curve 1 = even; above 1 = slow at first (progress ^ curve); below 1 = fast at
	first, easing out (1 - (1 - progress) ^ (1 / curve)), the way a siren's motor spins up. Fast at
	first used to be progress ^ curve, whose slope at the start is infinite: the wail's rise (0.25)
	leapt two semitones in its first millisecond, a jump at the bottom of every cycle, heard as a cut
	at the loop's seam.
]]
function Synth.GlideShape(progress, curve)
	curve = max(curve or 1, 0.05)
	progress = min(max(progress, 0), 1)
	if curve < 1 then return 1 - (1 - progress) ^ (1 / curve) end

	return progress ^ curve
end

local function segmentFrequency(segment, time, logGlide)
	if segment.startHz == segment.endHz then return segment.startHz end
	local progress = Synth.GlideShape((time - segment.startTime) / (segment.endTime - segment.startTime), segment.curve)
	if logGlide and segment.startHz > 0 and segment.endHz > 0 then return segment.startHz * (segment.endHz / segment.startHz) ^ progress end

	return segment.startHz + (segment.endHz - segment.startHz) * progress
end

-- the pattern's frequency at every sample of the loop
local function patternFrequencies(tone, pitch, sampleRate)
	local segments, loopSeconds = Synth.Segments(tone.pattern or {})
	local sampleCount = round(loopSeconds * sampleRate)
	local frequencies, segmentIndex = {}, 1
	for i = 0, sampleCount - 1 do
		local time = i / sampleRate
		while segmentIndex < #segments and time >= segments[segmentIndex].endTime do segmentIndex = segmentIndex + 1 end
		frequencies[i] = segmentFrequency(segments[segmentIndex], time, tone.logGlide ~= false) * pitch
	end

	return frequencies, sampleCount, loopSeconds
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

-- scales a voice's frequencies so the loop holds a whole number of its cycles
local function wholeCycles(frequencies, sampleCount, sampleRate)
	local cycles = 0
	for i = 0, sampleCount - 1 do cycles = cycles + frequencies[i] end
	cycles = cycles / sampleRate
	if cycles <= 0 then return end
	local scale = max(1, round(cycles)) / cycles
	for i = 0, sampleCount - 1 do frequencies[i] = frequencies[i] * scale end
end

local function wholeRate(rate, loopSeconds)
	if not rate or rate <= 0 then return 0 end

	return max(1, round(rate * loopSeconds))
end

--[[
	Renders tone `tone` with the settings `cfg` (POLICE_SIREN.CONFIG's pitch/sampleRate/cabin).
	Returns the samples (1-based, peak PEAK), the sample rate and the loop length in samples.
	`yield`, if given, is called every few thousand samples (the game renders in a coroutine).
	`inside`: the version heard inside the car, muffled at config.cabin.muffle Hz.
]]
function Synth.Render(tone, config, yield, inside)
	local sampleRate = config.sampleRate or 44100
	local mainFrequencies, sampleCount, loopSeconds = patternFrequencies(tone, config.pitch or 1, sampleRate)

	local vibrato = tone.vibrato or {}
	local vibratoCycles, vibratoDepth = wholeRate(vibrato.rate, loopSeconds), (vibrato.depth or 0) / 1200
	if vibratoCycles > 0 and vibratoDepth ~= 0 then
		for i = 0, sampleCount - 1 do mainFrequencies[i] = mainFrequencies[i] * 2 ^ (vibratoDepth * sin(TWO_PI * vibratoCycles * i / sampleCount)) end
	end

	local voice2 = tone.voice2 or {}
	local secondFrequencies
	if voice2.on then
		local ratio = 2 ^ (((voice2.semitones or 0) + (voice2.cents or 0) / 100) / 12)
		local shift = round((voice2.offset or 0) * sampleCount) % sampleCount
		secondFrequencies = {}
		for i = 0, sampleCount - 1 do secondFrequencies[i] = mainFrequencies[(i + shift) % sampleCount] * ratio end
		wholeCycles(secondFrequencies, sampleCount, sampleRate)
	end
	wholeCycles(mainFrequencies, sampleCount, sampleRate)

	local mainTop, secondTop = 0, 0
	for i = 0, sampleCount - 1 do
		mainTop = max(mainTop, mainFrequencies[i])
		if secondFrequencies then secondTop = max(secondTop, secondFrequencies[i]) end
	end
	local harmonics = tone.harmonics or { 1 }
	local mainTable = wavetable(harmonics, mainTop, sampleRate)
	local secondTable = secondFrequencies and wavetable(harmonics, secondTop, sampleRate)
	local secondLevel = voice2.level or 0

	local tremolo = tone.tremolo or {}
	local tremoloCycles, tremoloDepth = wholeRate(tremolo.rate, loopSeconds), min(max(tremolo.depth or 0, 0), 1)

	local speaker = tone.speaker or {}
	local highpass = biquad("hp", speaker.highpass or 20, 0.707, 0, sampleRate)
	local lowpass = biquad("lp", speaker.lowpass or 20000, 0.707, 0, sampleRate)
	local resonance = biquad("peak", speaker.resonance or 1000, speaker.resonanceQ or 1, speaker.resonanceGain or 0, sampleRate)
	local drive = max(speaker.drive or 0, 0)
	local driveNorm = drive > 0 and 1 / tanh(drive) or 1
	local muffleHz = inside and config.cabin and config.cabin.muffle
	local muffleLowpassA = muffleHz and biquad("lp", muffleHz, 0.707, 0, sampleRate)
	local muffleLowpassB = muffleHz and biquad("lp", muffleHz, 0.707, 0, sampleRate)

	local out, outPeak = {}, 0
	local mainPhase, secondPhase = 0, 0
	for pass = 1, 2 do
		for i = 0, sampleCount - 1 do
			mainPhase = (mainPhase + mainFrequencies[i] / sampleRate) % 1
			local tablePosition = mainPhase * TABLE_SIZE
			local tableIndex = floor(tablePosition)
			local sample = mainTable[tableIndex] + (mainTable[tableIndex + 1] - mainTable[tableIndex]) * (tablePosition - tableIndex)
			if secondFrequencies then
				secondPhase = (secondPhase + secondFrequencies[i] / sampleRate) % 1
				tablePosition = secondPhase * TABLE_SIZE
				tableIndex = floor(tablePosition)
				sample = sample + secondLevel * (secondTable[tableIndex] + (secondTable[tableIndex + 1] - secondTable[tableIndex]) * (tablePosition - tableIndex))
			end
			if tremoloCycles > 0 then
				sample = sample * (1 - tremoloDepth * (0.5 - 0.5 * cos(TWO_PI * tremoloCycles * i / sampleCount)))
			end
			sample = runBiquad(highpass, sample)
			if drive > 0 then sample = tanh(sample * drive) * driveNorm end
			sample = runBiquad(lowpass, runBiquad(resonance, sample))
			if muffleLowpassA then sample = runBiquad(muffleLowpassB, runBiquad(muffleLowpassA, sample)) end
			if pass == 2 then
				out[i + 1] = sample
				outPeak = max(outPeak, abs(sample))
			end
			if yield and i % YIELD_EVERY == 0 then yield() end
		end
	end

	local normalizeGain = outPeak > 0 and PEAK / outPeak or 0
	for i = 1, sampleCount do out[i] = out[i] * normalizeGain end

	return out, sampleRate, sampleCount
end
