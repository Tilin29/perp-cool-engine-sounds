--[[
	Audio Engine - sound bank (client)

	Every engine's sounds are rendered offline and shipped as WAV files under
	sound/audio_engine/<dir>/, described by cl_baked.lua (written by the baker). Nothing is
	generated in game. A bank holds, per engine:
	  * one seamless loop per rpm band, on throttle and off throttle (with each band's trim)
	  * a rev-limiter loop
	  * start-up one-shots (normal and "emotion" start), a shut-down one-shot
	  * pops and bangs
	and the shared env bank holds road, wind, turbo, blow-off, the EV sounds and the supercharger.
]]

local AudioEngine = AUDIO_ENGINE
local Bank = AudioEngine.Bank or {}
AudioEngine.Bank = Bank
Bank.list = Bank.list or {}

-- the rpm the emotion start flares to, as the name of its baked variant ("4015")
function Bank.EmotionFlareKey(config)
	return tostring(math.floor(AudioEngine.Drivetrain.EmotionFlare(config) + 0.5))
end

-- a manifest's files, if the content is mounted: stem -> sound path
local function bakedFiles(manifest, probeStem)
	if not manifest then return nil end
	local directory = "audio_engine/" .. manifest.dir .. "/"
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

-- the shared bank (nil without the content: looked for again every ENV_RETRY seconds, not every frame)
local ENV_RETRY = 5
local envLookedAt = -math.huge
function Bank.GetEnv()
	if not Bank.env and RealTime() - envLookedAt >= ENV_RETRY then
		envLookedAt = RealTime()
		Bank.env = bakedEnv()
	end
	return Bank.env
end

-- (warned once per engine: its sounds aren't in the content)
local missingWarned = {}

--[[
	The bank for an engine config, loaded on first use (when a car using it is in hearing). Cars
	with the same engine share one bank. An engine with no baked sounds (the content missing or
	older than the car list) plays `fallback`'s (the car's stock engine), else stays silent.
]]
function Bank.Get(config, fallback)
	local bank = Bank.list[config.id]
	if bank == nil then
		bank = bakedBank(config) or false
		Bank.list[config.id] = bank
		if not bank and not missingWarned[config.id] then
			missingWarned[config.id] = true
			MsgN("[Audio Engine] no baked sounds for " .. tostring(config.engineName or config.name or config.id) .. " (is the content mounted and up to date?)")
		end
	end
	if bank then return bank end
	if fallback and fallback.id ~= config.id then return Bank.Get(fallback) end
	return nil
end

hook.Add("InitPostEntity", "audio_engine_bank", Bank.GetEnv)
if IsValid(LocalPlayer()) then Bank.GetEnv() end -- lua refresh / late load
