--[[
	Audio Engine - sound bank (client)

	For each registered car this renders, in the background over a few frames:
	  * one seamless loop per rpm band, on throttle and off throttle
	  * a rev-limiter loop
	  * start-up one-shots (normal and "emotion" start), a shut-down one-shot
	  * a few overrun pops
	and registers them as game sounds with sound.Generate.

	Every car's stock engine also ships pre-generated (dev/baker renders this same build to
	sound/audio_engine/, described by cl_baked.lua). A bank whose sound key has a baked copy
	loads from those files instantly; only tuned engines are generated in game.
]]

local AudioEngine = AUDIO_ENGINE
local Synth = AudioEngine.Synth
local Bank = AudioEngine.Bank or {}
AudioEngine.Bank = Bank
Bank.list = Bank.list or {}
Bank.serial = Bank.serial or 0

local sampleRateConVar = CreateClientConVar("audio_engine_samplerate", "44100", true, false,
	"Sample rate for generated engine sounds: 44100 or 22050 (lower = faster to generate)")
local budgetConVar = CreateClientConVar("audio_engine_genbudget", "6", true, false,
	"Milliseconds per frame spent generating engine sounds", 1, 50)

-- the rpm the emotion start flares to, as the name of its baked variant ("4015")
function Bank.EmotionFlareKey(config)
	return tostring(math.floor(AudioEngine.Drivetrain.EmotionFlare(config) + 0.5))
end

local function currentSampleRate()
	local rate = sampleRateConVar:GetInt()
	if rate ~= 22050 and rate ~= 11025 then rate = 44100 end
	return rate
end

local function peakOf(buffer, peak)
	for i = 1, #buffer do
		local magnitude = buffer[i]
		if magnitude < 0 then magnitude = -magnitude end
		if magnitude > peak then peak = magnitude end
	end
	return peak
end

local function scale(buffer, gain)
	for i = 1, #buffer do buffer[i] = buffer[i] * gain end
end

-- rough loudness: rms above ~250 Hz (the ear barely counts the 80 Hz boom)
local function loudness(buffer, sampleRate)
	local filter = Synth.Biquad("highpass", 250, sampleRate, 0.7)
	local b0, b1, b2, a1, a2, state1, state2 = filter[1], filter[2], filter[3], filter[4], filter[5], 0, 0
	local sumSquares = 0
	for i = 1, #buffer do
		local input = buffer[i]
		local output = b0 * input + state1; state1 = b1 * input - a1 * output + state2; state2 = b2 * input - a2 * output
		sumSquares = sumSquares + output * output
	end
	return math.sqrt(sumSquares / #buffer) + 1e-9
end

-- gentle look-ahead leveller: keep any 20 ms window from getting louder than capDb
local function capLoudness(buffer, sampleRate, capDb, capBroadDb)
	local filter = Synth.Biquad("highpass", 250, sampleRate, 0.7)
	local b0, b1, b2, a1, a2, state1, state2 = filter[1], filter[2], filter[3], filter[4], filter[5], 0, 0
	local blockSize = math.floor(sampleRate * 0.02)
	local blockCount = math.ceil(#buffer / blockSize)
	local blockGains = {}
	for block = 1, blockCount do
		local sumSquares, broadSumSquares, count = 0, 0, 0
		for i = (block - 1) * blockSize + 1, math.min(#buffer, block * blockSize) do
			local input = buffer[i]
			local output = b0 * input + state1; state1 = b1 * input - a1 * output + state2; state2 = b2 * input - a2 * output
			sumSquares = sumSquares + output * output; broadSumSquares = broadSumSquares + input * input; count = count + 1
		end
		count = math.max(count, 1)
		local levelDb = 20 * math.log10(math.sqrt(sumSquares / count) + 1e-9)
		local broadLevelDb = 20 * math.log10(math.sqrt(broadSumSquares / count) + 1e-9)
		blockGains[block] = math.min(1, 10 ^ ((capDb - levelDb) / 20), 10 ^ ((capBroadDb - broadLevelDb) / 20))
	end
	-- look ahead / hold: each block takes the lowest gain of its neighbours
	local heldGains = {}
	for block = 1, blockCount do
		local lowest = 1
		for job = math.max(1, block - 3), math.min(blockCount, block + 3) do lowest = math.min(lowest, blockGains[job]) end
		heldGains[block] = lowest
	end
	for i = 1, #buffer do
		local position = (i - 1) / blockSize + 0.5
		local block = math.floor(position)
		local fraction = position - block
		local gainBefore = heldGains[math.max(1, math.min(blockCount, block))]
		local gainAfter = heldGains[math.max(1, math.min(blockCount, block + 1))]
		buffer[i] = buffer[i] * (gainBefore + (gainAfter - gainBefore) * fraction)
	end
end

--[[
	Look-ahead peak limiter: turns down only the few loudest firing pulses so a loop can be
	played louder without clipping. Gain is worked out per 1 ms block, held across the
	neighbouring blocks (look-ahead), smoothed, and interpolated per sample. `circular` treats
	the buffer as a loop so the gain is continuous across the loop point.
]]
local function limitPeaks(buffer, sampleRate, ceiling, circular)
	local blockSize = math.max(1, math.floor(sampleRate * 0.001))
	local sampleCount = #buffer
	local blockCount = math.ceil(sampleCount / blockSize)
	local blockGains = {}
	local anyLimited = false
	for block = 1, blockCount do
		local blockPeak = 0
		for i = (block - 1) * blockSize + 1, math.min(sampleCount, block * blockSize) do
			local magnitude = buffer[i]
			if magnitude < 0 then magnitude = -magnitude end
			if magnitude > blockPeak then blockPeak = magnitude end
		end
		blockGains[block] = blockPeak > ceiling and ceiling / blockPeak or 1
		if blockGains[block] < 1 then anyLimited = true end
	end
	if not anyLimited then return 0 end
	local function blockAt(values, block)
		if circular then return values[(block - 1) % blockCount + 1] end
		return values[math.max(1, math.min(blockCount, block))]
	end
	local heldGains = {}
	for block = 1, blockCount do
		local lowest = 1
		for job = block - 4, block + 4 do lowest = math.min(lowest, blockAt(blockGains, job)) end
		heldGains[block] = lowest
	end
	local smoothedGains = {}
	for block = 1, blockCount do
		local sum = 0
		for job = block - 3, block + 3 do sum = sum + blockAt(heldGains, job) end
		smoothedGains[block] = sum / 7
	end
	local deepestCut = 1
	for i = 1, sampleCount do
		local position = (i - 1) / blockSize + 0.5
		local block = math.floor(position)
		local fraction = position - block
		local gainBefore = blockAt(smoothedGains, circular and block or math.max(1, block))
		local gainAfter = blockAt(smoothedGains, block + 1)
		local gain = gainBefore + (gainAfter - gainBefore) * fraction
		if gain < deepestCut then deepestCut = gain end
		buffer[i] = buffer[i] * gain
	end
	return -20 * math.log10(deepestCut)
end
Bank.LimitPeaks = limitPeaks

-- every engine is matched to the same loudness (rms above 250 Hz of its on-throttle loops),
-- so a V8 isn't quieter than an inline-4. Electric motors sit well below the engines: their
-- top-speed on-throttle loop is set to TARGET_EV_DB rms over the whole band (most of their
-- whine is below 250 Hz for much of the speed range, so the engines' measure would miss it).
-- In game they're turned down further (cl_engine AudioEngine.EV_VOLUME).
local TARGET_DB, TARGET_EV_DB = -21, -32

local function build(bank)
	local config, sampleRate = bank.config, bank.sampleRate
	local yield = coroutine.yield
	local jobs = {}
	local function addSound(name, data, loop, ownLevel)
		jobs[#jobs + 1] = { name = bank.prefix .. name, data = data, loop = loop, own = ownLevel }
		return bank.prefix .. name
	end

	-- rpm bands
	local bandCount = #config.bands
	local referenceDb
	local bandGains = {}
	local popLeveller, popBandDistance = 1, math.huge
	local loudest, loudestBroad = -200, -200
	for i, bandRpm in ipairs(config.bands) do
		local offLoop, _, offLeveller = Synth.RenderSteadyLoop(config, sampleRate, bandRpm, 0, yield)
		local onLoop = Synth.RenderSteadyLoop(config, sampleRate, bandRpm, 1, yield)
		-- loudness curve: on-throttle gets ~5 dB louder from the lowest to the highest band
		local levelDb = 20 * math.log10(loudness(onLoop, sampleRate))
		referenceDb = referenceDb or levelDb
		local wantedFlare = referenceDb + 3 * (bandCount > 1 and (i - 1) / (bandCount - 1) or 0)
		local gain = math.min(4, math.max(0.5, 10 ^ ((wantedFlare - levelDb) / 20)))
		-- an electric motor keeps its natural levels: near silent at low speed, the whine
		-- growing with speed (evening the bands out would blow the faint low end up)
		if config.electric then gain = 1 end
		bandGains[i] = gain
		scale(offLoop, gain); scale(onLoop, gain)
		loudest = math.max(loudest, levelDb + 20 * math.log10(gain))
		if i > 1 or bandCount == 1 then
			-- the idle band can boom when the firing rate sits on the 78 Hz resonance; leave it out
			local sumSquares = 0
			for index = 1, #onLoop do sumSquares = sumSquares + onLoop[index] * onLoop[index] end
			loudestBroad = math.max(loudestBroad, 20 * math.log10(math.sqrt(sumSquares / #onLoop) + 1e-9))
		end
		bank.layers[i] = { rpm = bandRpm, off = addSound("b" .. i .. "off", offLoop, true), on = addSound("b" .. i .. "on", onLoop, true) }
		if math.abs(bandRpm - 4200) < popBandDistance then popBandDistance = math.abs(bandRpm - 4200); popLeveller = offLeveller end
		yield()
	end

	-- rev limiter
	local limiterLoop = Synth.RenderLimiterLoop(config, sampleRate, yield)
	scale(limiterLoop, bandGains[bandCount])
	bank.limiter = { off = addSound("lim", limiterLoop, true), rpm = config.redline }

	-- start / stop
	local startSound, fadeAt, duration = Synth.RenderStart(config, sampleRate, false, yield)
	scale(startSound, bandGains[1])
	capLoudness(startSound, sampleRate, loudest + 1, loudestBroad + 1)
	bank.start = { name = addSound("start", startSound, false), fadeAt = fadeAt, dur = duration }
	local emotionStart, emotionFadeAt, emotionDuration = Synth.RenderStart(config, sampleRate, true, yield)
	scale(emotionStart, bandGains[1])
	capLoudness(emotionStart, sampleRate, loudest + 1, loudestBroad + 1)
	yield()
	bank.startEmo = { name = addSound("starte", emotionStart, false), fadeAt = emotionFadeAt, dur = emotionDuration }
	-- the baker shares one bank between the redlines of an engine family; the emotion start
	-- flares to a share of redline, so it renders one more per flare (b.startRedlines)
	bank.startEmoAt = {}
	local baseFlareKey = Bank.EmotionFlareKey(config)
	for _, redline in ipairs(bank.startRedlines or {}) do
		local redlineConfig = {}
		for key, value in pairs(config) do redlineConfig[key] = value end
		redlineConfig.redline = redline
		local flareKey = Bank.EmotionFlareKey(redlineConfig)
		if flareKey ~= baseFlareKey and not bank.startEmoAt[flareKey] then
			local flareStart, flareFadeAt, flareDuration = Synth.RenderStart(redlineConfig, sampleRate, true, yield)
			scale(flareStart, bandGains[1])
			capLoudness(flareStart, sampleRate, loudest + 1, loudestBroad + 1)
			bank.startEmoAt[flareKey] = { name = addSound("starte_" .. flareKey, flareStart, false), fadeAt = flareFadeAt, dur = flareDuration }
			yield()
		end
	end
	local stopSound, stopDuration = Synth.RenderStop(config, sampleRate, yield)
	scale(stopSound, bandGains[1])
	bank.stop = { name = addSound("stop", stopSound, false), dur = stopDuration }

	-- pops & bangs: always generated, the profile decides how often and how loud
	-- (not for an electric motor)
	bank.bangs = {}
	if not config.electric then
		local function headRms(buffer, headLength)
			local sumSquares, count = 0, math.min(#buffer, headLength)
			for i = 1, count do sumSquares = sumSquares + buffer[i] * buffer[i] end
			return math.sqrt(sumSquares / count) + 1e-9
		end
		local referenceLevel = 10 ^ (loudestBroad / 20)
		local headWindow = math.floor(sampleRate * 0.05)
		-- small pops and quick crackle bursts for the overrun, big bangs for lift-off
		local kinds = { "pop", "pop", "crackle", "pop", "crackle" }
		for i, kind in ipairs(kinds) do
			local pop = Synth.RenderBackfire(config, sampleRate, 1234 + i * 777, kind, yield)
			-- 4 dB under the loudest band, played at half volume so the pop volume can go to 200%
			-- (was 2 dB over and bangs 9: they stood out over the engine like firecrackers)
			scale(pop, referenceLevel * 10 ^ (-4 / 20) / headRms(pop, math.floor(sampleRate * 0.02)))
			bank.pops[i] = addSound("pop" .. i, pop, false, true)
		end
		bank.bangs = {}
		for i = 1, 3 do
			local bang = Synth.RenderBackfire(config, sampleRate, 4321 + i * 999, "bang", yield)
			scale(bang, referenceLevel * 10 ^ (3 / 20) / headRms(bang, headWindow))
			bank.bangs[i] = addSound("bang" .. i, bang, false, true)
		end
	end

	-- the limiter loop has gaps (fuel cuts); bring its level up to the top band's full throttle
	do
		local function rms(buffer)
			local sumSquares = 0
			for i = 1, #buffer do sumSquares = sumSquares + buffer[i] * buffer[i] end
			return math.sqrt(sumSquares / #buffer) + 1e-9
		end
		local topOnLoop = nil
		for _, job in ipairs(jobs) do
			if job.name == bank.layers[bandCount].on then topOnLoop = job.data end
			if job.name == bank.limiter.off then
				local targetRms = topOnLoop and rms(topOnLoop) * 1.15 or rms(job.data)
				scale(job.data, math.min(3, targetRms / rms(job.data)))
			end
		end
	end

	-- (turbo whistle and blow-off valve are shared by every engine: see the shared bank below)

	-- one gain for everything, so the relative levels stay as rendered: set by loudness, so
	-- every engine plays equally loud. The loudest pulses of loops and one-shots are then
	-- limited to stay under full scale; pops & bangs are only turned down if they would clip.
	local levelSum, levelCount = 0, 0
	for i = (bandCount > 1 and 2 or 1), bandCount do
		local onData
		for _, job in ipairs(jobs) do if job.name == bank.layers[i].on then onData = job.data end end
		if onData then levelSum = levelSum + 20 * math.log10(loudness(onData, sampleRate)); levelCount = levelCount + 1 end
	end
	local gain = levelCount > 0 and 10 ^ ((TARGET_DB - levelSum / levelCount) / 20) or 1
	if config.electric then
		for _, job in ipairs(jobs) do
			if job.name == bank.layers[bandCount].on then
				local sumSquares = 0
				for i = 1, #job.data do sumSquares = sumSquares + job.data[i] * job.data[i] end
				gain = 10 ^ (TARGET_EV_DB / 20) / (math.sqrt(sumSquares / #job.data) + 1e-9)
			end
		end
	end
	gain = math.min(gain, 30)
	bank.limitedDb = 0
	for _, job in ipairs(jobs) do
		if not job.own then
			scale(job.data, gain)
			local levelDb = limitPeaks(job.data, sampleRate, 0.95, job.loop)
			if job.loop then bank.limitedDb = math.max(bank.limitedDb, levelDb) end
			yield()
		end
	end
	yield()

	--[[
		A sound's volume can't go over 1, and the loudness matching leaves many bands peaking far
		under full scale (the Furai's high revs at 0.23-0.5), so those could never swell on a
		drive-by. Each band's loops are stored as hot as they go; layer.trim is the volume that
		plays them at the level they had. b.peak stays the level at volume 1 before the trim.
	]]
	if not config.electric then
		local jobsByName = {}
		for _, job in ipairs(jobs) do jobsByName[job.name] = job end
		for _, layer in ipairs(bank.layers) do
			local onJob, offJob = jobsByName[layer.on], jobsByName[layer.off]
			layer.trim = math.min(1, math.max(peakOf(onJob.data, 0), peakOf(offJob.data, 0)) / 0.95)
			scale(onJob.data, 1 / layer.trim); scale(offJob.data, 1 / layer.trim)
			onJob.trim, offJob.trim = layer.trim, layer.trim
			yield()
		end
	end

	for _, job in ipairs(jobs) do
		local data = job.data
		local samples = data
		if job.loop then
			-- one pre-roll sample, then loop from sample 1: [y_L, y_1 .. y_L] with loopStart = 1
			samples = { data[#data] }
			for i = 1, #data do samples[i + 1] = data[i] end
		end
		local sampleCount = #samples
		local jobGain = 1
		if job.own then
			jobGain = gain
			local peak = peakOf(samples, 0)
			if peak * jobGain > 0.98 then jobGain = 0.98 / peak end
		end
		-- the peak each sound plays at (cl_engine keeps the car's mix under full scale with it)
		bank.peak = bank.peak or {}
		bank.peak[job.name] = math.min(1, peakOf(samples, 0) * jobGain * (job.trim or 1))
		bank.samples = (bank.samples or 0) + sampleCount   -- (the memory a generated bank holds: audio_engine_perf)
		sound.Generate(job.name, sampleRate, sampleCount / sampleRate, function(sampleIndex)
			local value = (samples[(sampleIndex % sampleCount) + 1] or 0) * jobGain
			if value > 1 then value = 1 elseif value < -1 then value = -1 end
			return value
		end, job.loop and 1 or nil)
		job.data = nil
		yield()
	end

	bank.ready = true
	bank.buildTime = SysTime() - bank.buildStarted
	MsgN(string.format("[Audio Engine] %s: generated %d sounds at %d Hz in %.1fs",
		config.engineName or config.name or config.id, #jobs, sampleRate, bank.buildTime))
end

local maxSoundsConVar = CreateClientConVar("audio_engine_maxsounds", "10", true, false,
	"How many different engine sounds to keep generated (each ~4 MB)", 2, 40)

Bank.queue = Bank.queue or {}
Bank.count = Bank.count or 0

-- road & wind loops, shared by every car (built once)
local function buildSharedBank(bank)
	local sampleRate, yield = bank.sampleRate, coroutine.yield
	local function rms(buffer)
		local sumSquares = 0
		for i = 1, #buffer do sumSquares = sumSquares + buffer[i] * buffer[i] end
		return math.sqrt(sumSquares / #buffer) + 1e-9
	end
	-- name, buffer, level (rms), loop, level measured over the first n seconds
	-- The turbo sounds are generated 6 dB hot and played at half volume by default, so their
	-- volume sliders can go to 200%. Every engine is matched to the same loudness, so one
	-- turbo and one blow-off level suit them all, and switching the turbo on or off (or its
	-- volumes) never needs a new engine.
	local jobs = {
		{ "road", Synth.RenderRoadLoop(sampleRate, yield), 0.07, true },
		{ "wind", Synth.RenderWindLoop(sampleRate, yield), 0.06, true },
		{ "turbo", Synth.RenderTurboLoop(sampleRate, yield), 0.027, true },
		{ "evhum", Synth.RenderEVHumLoop(sampleRate, yield), 0.06, true },
		{ "bov1", Synth.RenderBlowoff(sampleRate, 0xB10F + 4099, yield), 0.093, false, 0.15 },
		{ "bov2", Synth.RenderBlowoff(sampleRate, 0xB10F + 2 * 4099, yield), 0.093, false, 0.15 },
	}
	-- superchargers: on boost and bypass open per variant and rpm band (sc_<variant>_<band>). The
	-- on loop is set to about 0.38 of a loudness-matched engine's top band (full band rms), as in
	-- the clips they were picked from; the bypass loop keeps the gain of its on loop (6th field),
	-- so it stays quieter
	for _, variant in ipairs(Synth.SC_ORDER) do
		for band, bandRpm in ipairs(Synth.SC_BANDS) do
			local onName = "sc_" .. variant .. "_" .. band
			jobs[#jobs + 1] = { onName, Synth.RenderSuperchargerLoop(sampleRate, variant, yield, false, bandRpm), 0.057, true }
			jobs[#jobs + 1] = { onName .. "_off", Synth.RenderSuperchargerLoop(sampleRate, variant, yield, true, bandRpm), 0, true, nil, onName }
		end
	end
	local gains = {}
	bank.peak = {}
	for _, job in ipairs(jobs) do
		local data, targetRms, loop, headSeconds = job[2], job[3], job[4], job[5]
		local measured = data
		if headSeconds then
			measured = {}
			for i = 1, math.min(#data, math.floor(sampleRate * headSeconds)) do measured[i] = data[i] end
		end
		local gain = job[6] and gains[job[6]] or targetRms / rms(measured)
		gains[job[1]] = gain
		local peak = peakOf(data, 0)
		if peak * gain > 0.98 then gain = 0.98 / peak end
		local samples
		if loop then
			samples = { data[#data] * gain }
			for i = 1, #data do samples[i + 1] = data[i] * gain end
		else
			samples = {}
			for i = 1, #data do samples[i] = data[i] * gain end
		end
		local sampleCount = #samples
		local name = bank.prefix .. job[1]
		bank.peak[job[1]] = math.min(1, peak * gain)
		bank.peak[name] = bank.peak[job[1]]
		bank.samples = (bank.samples or 0) + sampleCount
		sound.Generate(name, sampleRate, sampleCount / sampleRate, function(sampleIndex)
			local value = samples[(sampleIndex % sampleCount) + 1] or 0
			if value > 1 then value = 1 elseif value < -1 then value = -1 end
			return value
		end, loop and 1 or nil)
		bank[job[1]] = name
		yield()
	end
	bank.blowoff = { bank.bov1, bank.bov2 }
	bank.ready = true
end

---------------------------------------------------------------------------
-- pre-generated banks (cl_baked.lua + sound/audio_engine/<dir>/*.wav)
---------------------------------------------------------------------------
local bakedConVar = CreateClientConVar("audio_engine_baked", "1", true, false,
	"1 = stock engines play the pre-generated sounds from the content; 0 = generate everything in game")

local function bakedFiles(manifest, probeStem)
	if not manifest or not bakedConVar:GetBool() then return nil end
	local directory = "audio_engine/" .. manifest.dir .. "/"
	-- the content pack may be missing or out of date: then generate as before
	if not file.Exists("sound/" .. directory .. probeStem .. ".wav", "GAME") then return nil end
	return function(stem) return directory .. stem .. ".wav" end
end

-- the baked entry for an engine: its own, or its family's (the same engine baked at a higher
-- redline: the bands it never reaches just stay silent, the limiter is pitched down to it)
local function bakedEntry(config)
	if not AudioEngine.BAKED then return nil end
	local manifest = AudioEngine.BAKED[config.id]
	if manifest then return manifest end
	local servingKey = config.familyKey and AudioEngine.BAKED_FAMILY and AudioEngine.BAKED_FAMILY[config.familyKey]
	manifest = servingKey and AudioEngine.BAKED[servingKey]
	if manifest and manifest.limiter >= config.redline then return manifest end
end
Bank.BakedEntry = bakedEntry

local function bakedBank(config)
	local manifest = bakedEntry(config)
	local pathOf = bakedFiles(manifest, "b1on")
	if not pathOf then return nil end
	local bank = {
		config = config, key = config.id, sampleRate = manifest.sr, ready = true, baked = true, cyl = manifest.cyl,
		layers = {}, pops = {}, bangs = {}, peak = {}, limitedDb = manifest.limitedDb,
	}
	for i, rpm in ipairs(manifest.layers) do
		bank.layers[i] = { rpm = rpm, off = pathOf("b" .. i .. "off"), on = pathOf("b" .. i .. "on"), trim = manifest.trims and manifest.trims[i] }
	end
	bank.limiter = { off = pathOf("lim"), rpm = manifest.limiter }
	bank.start = { name = pathOf("start"), fadeAt = manifest.start.fadeAt, dur = manifest.start.dur }
	bank.startEmo = { name = pathOf("starte"), fadeAt = manifest.startEmo.fadeAt, dur = manifest.startEmo.dur }
	-- a lower redline in the family flares lower: its own emotion start, else the closest one
	if manifest.startEmoAt then
		local wantedFlare = tonumber(Bank.EmotionFlareKey(config))
		local bestDistance = math.abs(wantedFlare - AudioEngine.Drivetrain.EmotionFlare({ redline = manifest.limiter }))
		for flareKey, start in pairs(manifest.startEmoAt) do
			local distance = math.abs(wantedFlare - tonumber(flareKey))
			if distance < bestDistance then
				bestDistance = distance
				bank.startEmo = { name = pathOf("starte_" .. flareKey), fadeAt = start.fadeAt, dur = start.dur }
			end
		end
	end
	bank.stop = { name = pathOf("stop"), dur = manifest.stop.dur }
	for i = 1, manifest.pops do bank.pops[i] = pathOf("pop" .. i) end
	for i = 1, manifest.bangs do bank.bangs[i] = pathOf("bang" .. i) end
	for stem, peak in pairs(manifest.peak) do
		local name = pathOf(stem)
		bank.peak[name] = peak
		util.PrecacheSound(name)
	end
	return bank
end

local function bakedEnv()
	local manifest = AudioEngine.BAKED_ENV
	local pathOf = bakedFiles(manifest, "road")
	if not pathOf then return nil end
	local bank = { sampleRate = manifest.sr, ready = true, baked = true, peak = {} }
	for stem, peak in pairs(manifest.peak) do
		bank[stem] = pathOf(stem)
		bank.peak[stem] = peak
		bank.peak[bank[stem]] = peak
		util.PrecacheSound(bank[stem])
	end
	bank.blowoff = { bank.bov1, bank.bov2 }
	return bank
end

function Bank.GetEnv()
	if Bank.env then return Bank.env end
	local baked = bakedEnv()
	if baked then
		Bank.env = baked
		return baked
	end
	Bank.serial = Bank.serial + 1
	local bank = { sampleRate = 22050, ready = false, prefix = "audenv_" .. Bank.serial .. "_" }
	bank.buildCoroutine = coroutine.create(function() buildSharedBank(bank) end)
	Bank.queue[#Bank.queue + 1] = bank
	Bank.env = bank
	return bank
end

function Bank.Build(config)
	-- a stock engine with a baked copy: no generation, and it doesn't count toward maxsounds
	local baked = bakedBank(config)
	if baked then
		if Bank.list[config.id] and not Bank.list[config.id].baked then Bank.count = Bank.count - 1 end
		Bank.list[config.id] = baked
		return baked
	end
	Bank.serial = Bank.serial + 1
	local _, _, cyl = Synth.LayoutParams(config.layout)
	local bank = {
		config = config, key = config.id, sampleRate = currentSampleRate(), ready = false, cyl = cyl,
		prefix = "audeng_" .. Bank.serial .. "_",
		layers = {}, pops = {}, buildStarted = SysTime(),
	}
	bank.buildCoroutine = coroutine.create(function() build(bank) end)
	if not Bank.list[config.id] then Bank.count = Bank.count + 1 end
	Bank.list[config.id] = bank
	Bank.queue[#Bank.queue + 1] = bank
	return bank
end

--[[
	The bank for an engine config: built on first use. Cars with the same engine sound share
	one bank. Past the audio_engine_maxsounds limit, new engines fall back to `fallback`
	(the car's stock engine) instead of generating more.
	urgent = true moves it to the front of the queue (the car you're driving).
]]
function Bank.Get(config, fallback, urgent)
	local bank = Bank.list[config.id]
	if not bank then
		if fallback and fallback.id ~= config.id and Bank.count >= maxSoundsConVar:GetInt() then
			return Bank.Get(fallback, nil, urgent)
		end
		bank = Bank.Build(config)
	end
	if urgent and bank.buildCoroutine and Bank.queue[1] ~= bank then
		for index, queued in ipairs(Bank.queue) do
			if queued == bank then table.remove(Bank.queue, index) break end
		end
		table.insert(Bank.queue, 1, bank)
	end
	return bank
end

hook.Add("Think", "audio_engine_bank", function()
	local bank = Bank.queue[1]
	if not bank then return end
	if not bank.buildCoroutine then table.remove(Bank.queue, 1) return end
	local startTime = SysTime()
	local budget = budgetConVar:GetFloat() / 1000
	while SysTime() - startTime < budget do
		local resumed, message = coroutine.resume(bank.buildCoroutine)
		if not resumed then
			ErrorNoHalt("[Audio Engine] sound generation failed: " .. tostring(message) .. "\n")
			bank.buildCoroutine = nil
		elseif coroutine.status(bank.buildCoroutine) == "dead" then
			bank.buildCoroutine = nil
		end
		if not bank.buildCoroutine then
			table.remove(Bank.queue, 1)
			break
		end
	end
end)

-- right after joining: the shared bank, and the stock engines that have no baked copy, while
-- there are few enough of them. Baked engines load (instantly) when a car using one shows up,
-- so a player only holds the sounds of the cars around them.
local function prebuild()
	Bank.GetEnv()
	local toGenerate = {}
	for _, carConfig in pairs(AudioEngine.Cars) do
		local config = AudioEngine.ResolveProfile(carConfig)
		if not bakedEntry(config) then toGenerate[config.id] = config end
	end
	if table.Count(toGenerate) <= maxSoundsConVar:GetInt() then
		for _, config in pairs(toGenerate) do Bank.Get(config) end
	end
end
hook.Add("InitPostEntity", "audio_engine_bank", prebuild)
if IsValid(LocalPlayer()) then prebuild() end -- lua refresh / late load

function Bank.RebuildAll()
	local oldList = Bank.list
	Bank.list, Bank.queue, Bank.count = {}, {}, 0
	Bank.env = nil
	Bank.GetEnv()
	for _, bank in pairs(oldList) do Bank.Build(bank.config) end
	MsgN("[Audio Engine] regenerating engine sounds at " .. currentSampleRate() .. " Hz...")
end
concommand.Add("audio_engine_rebuild", Bank.RebuildAll, nil, "Regenerate the procedural engine sounds (after changing the synth or presets)")

-- switching between 44.1 and 22.05 kHz regenerates everything at the new rate
cvars.AddChangeCallback("audio_engine_samplerate", function(_, oldValue, newValue)
	if oldValue ~= newValue then Bank.RebuildAll() end
end, "audio_engine_rebuild")
cvars.AddChangeCallback("audio_engine_baked", function(_, oldValue, newValue)
	if oldValue ~= newValue then Bank.RebuildAll() end
end, "audio_engine_rebuild")
