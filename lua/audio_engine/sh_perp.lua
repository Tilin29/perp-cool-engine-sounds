--[[
	Audio Engine - PERPHeads integration (shared)

	PERP's cars are TDM Cars models driven by PERP's own vehicle scripts (scripts/vehicles/...).
	Their "Vehicle_Sounds" states play the TDM engine recordings through soundscripts such as
	"slsamg_idle", so with the procedural engine on top both would play. Until PERP's scripts get
	empty engine states (see INTEGRATION.md), this mutes those soundscripts by name, on the server
	and the clients, for every registered car: its base script, the tier copies PERP keeps next to
	it (used/, upgrade_1/, upgrade_2/, spiked/) and its variants (<base>_cop, _taxi, _medic...).
	A name that any other vehicle script uses too (the bus, fire trucks, tow trucks...) is left
	alone, so those vehicles keep their sound. Crash sounds are never touched.

	audio_engine_mutestock 0 puts the original soundscripts back.

	The TDM tyre screech when braking hard (the scripts' Skid_* sounds, "tdmcars_skid" and
	"tdmcars_skid_less") is muted too; audio_engine_muteskid 0 brings it back. Those soundscripts
	are shared by every TDM car, so this goes for all of them. The rim scrape of spiked tyres
	("wheelrim_scrape", spiked/ scripts only) is kept.

	The scraping while cornering is a different sound: the tyres' surface materials. When a wheel
	slides, Source plays its skid/brake material's scrape sound, and about a third of PERP's
	scripts use "glassbottle" there (the glass bottle scrape), the rest rubber (base "dirt":
	Dirt.Scrape). audio_engine_mutetyrescrape 1 (default) silences those game sounds. They're
	global, so props of those materials also scrape silently.

	It also lists every PERP car in the spawn menu (Vehicles > PERP cars (Audio Engine)) with its
	base script, and the police / fire / EMS / taxi variants in PERP job vehicles (Audio Engine)
	on their own scripts and livery skins, for testing outside the PERP gamemode.
]]

local AudioEngine = AUDIO_ENGINE

local muteStockConVar = CreateConVar("audio_engine_mutestock", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"1 = silence the TDM engine recordings of cars that use the procedural engine")
local muteSkidConVar = CreateConVar("audio_engine_muteskid", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"1 = silence the TDM tyre screech when braking (shared by all TDM cars)")
local muteScrapeConVar = CreateConVar("audio_engine_mutetyrescrape", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"1 = silence the scrape of sliding tyres (glass bottle / dirt surface sounds; global)")

-- the scrape sounds of the surface materials PERP's wheels slide and brake on
-- (glassbottle; slidingrubbertire / brakingrubbertire / snow, which all scrape as dirt)
AudioEngine.TYRE_SCRAPE_SOUNDS = { "GlassBottle.ScrapeRough", "GlassBottle.ScrapeSmooth", "Dirt.Scrape" }

local CONTENT_PACKS = { "tdmcars", "jarheads", "perp2" }
local SCRIPT_TIERS = { "", "used/", "upgrade_1/", "upgrade_2/", "spiked/" }

-- variant scripts whose name doesn't start with their car's base script name
AudioEngine.PERP_SCRIPT_ALIASES = AudioEngine.PERP_SCRIPT_ALIASES or {
	["tdmcars/charger_cop"] = "tdmcars/chargersrt8",
}

-- scripts with no model in PERP's content packs: nothing spawns on them, so the soundscripts
-- they share don't keep a registered car's recording playing (the GTA IV tow truck's "bus_*"
-- would keep the fire truck's)
AudioEngine.PERP_SCRIPT_UNUSED = AudioEngine.PERP_SCRIPT_UNUSED or {
	["perp2/towtruck"] = true,
	["tdmcars/lee"] = true,
	["tdmcars/subimpreza"] = true,
}

-- only soundscripts can be redefined; a raw path ("vehicles\...\x.wav") can't be. Door sounds
-- (the GTA IV vehicles start up with "tdm_door_open") aren't the engine and may play elsewhere
local function addSoundName(soundSet, soundName)
	if soundName and soundName ~= "" and not soundName:find("[%.\\/]") and not soundName:lower():find("door", 1, true) then
		soundSet[soundName:lower()] = soundName
	end
end

-- soundscript names of a vehicle script's engine states, into set[lower] = original spelling,
-- and of its Skid_* sounds into skids
local function collectStateSounds(path, soundSet, skidSounds)
	local scriptText = file.Read(path, "GAME")
	if not scriptText then return end
	for block in scriptText:gmatch('"[Ss][Tt][Aa][Tt][Ee]"%s*(%b{})') do
		addSoundName(soundSet, block:match('"[Ss][Oo][Uu][Nn][Dd]"%s*"([^"]*)"'))
	end
	if skidSounds then
		for soundName in scriptText:gmatch('"[Ss][Kk][Ii][Dd]_%a+"%s*"([^"]*)"') do addSoundName(skidSounds, soundName) end
	end
end

local function collectSoundNames()
	local claimed = {}
	local function claim(script)
		local pack, base = (script or ""):lower():match("^scripts/vehicles/([^/]+)/([^/]+)%.txt$")
		if pack then claimed[pack .. "/" .. base] = { pack = pack, base = base } end
	end
	for _, carConfig in pairs(AudioEngine.Cars) do claim(carConfig.script) end
	-- job variants not named <base>_something (dodgeramff)
	for _, job in ipairs(AudioEngine.JOB_VEHICLES or {}) do claim(job[3]) end
	-- is this script one of a registered car's (its own name, or "<base>_something")?
	local function isOurScript(pack, name)
		if AudioEngine.PERP_SCRIPT_ALIASES[pack .. "/" .. name] or claimed[pack .. "/" .. name] then return true end
		for _, claimedScript in pairs(claimed) do
			if claimedScript.pack == pack and name:sub(1, #claimedScript.base + 1) == claimedScript.base .. "_" then return true end
		end
		return false
	end

	local ourSounds, otherSounds, skidSounds = {}, {}, {}
	for _, pack in ipairs(CONTENT_PACKS) do
		for _, tier in ipairs(SCRIPT_TIERS) do
			local directory = "scripts/vehicles/" .. pack .. "/" .. tier
			for _, fileName in ipairs((file.Find(directory .. "*.txt", "GAME"))) do
				local name = fileName:lower():gsub("%.txt$", "")
				if not AudioEngine.PERP_SCRIPT_UNUSED[pack .. "/" .. name] then
					local isOurs = isOurScript(pack, name)
					-- spiked scripts scrape on the rims: that one stays
					collectStateSounds(directory .. fileName, isOurs and ourSounds or otherSounds, isOurs and tier ~= "spiked/" and skidSounds or nil)
				end
			end
		end
	end
	-- registered cars whose script lives somewhere else (e.g. the example police car in scripts/vehicles/plpd/)
	for _, carConfig in pairs(AudioEngine.Cars) do
		if carConfig.script then collectStateSounds(carConfig.script, ourSounds, skidSounds) end
	end

	local muted, keptCount = {}, 0
	for lowerName, name in pairs(ourSounds) do
		if otherSounds[lowerName] then keptCount = keptCount + 1 else muted[lowerName] = name end
	end
	return muted, keptCount, skidSounds
end

AudioEngine.PERP_SAVED = AudioEngine.PERP_SAVED or {}
local SILENT_SOUND = "common/null.wav"

-- point a soundscript at silence, or put the original back
local function muteSound(name, silence)
	local saved = AudioEngine.PERP_SAVED[name]
	if saved == nil then
		local properties = sound.GetProperties(name)
		saved = (properties and properties.sound ~= SILENT_SOUND) and properties or false
		AudioEngine.PERP_SAVED[name] = saved
	end
	if silence then
		sound.Add({ name = name, channel = CHAN_STATIC, volume = 1, level = 0, pitch = 100, sound = SILENT_SOUND })
	elseif saved then
		sound.Add(saved)
	end
end

function AudioEngine.ApplyStockMute()
	local muted, keptCount, skidSounds = collectSoundNames()
	AudioEngine.PERP_MUTED, AudioEngine.PERP_SKIDS = muted, skidSounds
	local muteEngines, muteSkids = muteStockConVar:GetBool(), muteSkidConVar:GetBool()
	local mutedCount, mutedSkidCount = 0, 0
	for _, name in pairs(muted) do muteSound(name, muteEngines) mutedCount = mutedCount + 1 end
	for lowerName, name in pairs(skidSounds) do
		if not muted[lowerName] then muteSound(name, muteSkids) mutedSkidCount = mutedSkidCount + 1 end
	end
	if muteEngines then
		MsgN(string.format("[Audio Engine] muted %d TDM engine sounds of PERP cars (%d shared with other vehicles kept)", mutedCount, keptCount))
	end
	if muteSkids and mutedSkidCount > 0 then
		MsgN(string.format("[Audio Engine] muted %d TDM tyre screech sounds", mutedSkidCount))
	end
	local muteScrapes = muteScrapeConVar:GetBool()
	for _, name in ipairs(AudioEngine.TYRE_SCRAPE_SOUNDS) do muteSound(name, muteScrapes) end
end

-- TDM / PERP define their soundscripts in their own autorun files, which may load after this
-- one: (re)apply once everything is loaded, and once more a little later
hook.Add("InitPostEntity", "audio_engine_perp", function()
	AudioEngine.ApplyStockMute()
	timer.Simple(3, AudioEngine.ApplyStockMute)
end)
cvars.AddChangeCallback("audio_engine_mutestock", function() AudioEngine.ApplyStockMute() end, "audio_engine_perp")
cvars.AddChangeCallback("audio_engine_muteskid", function() AudioEngine.ApplyStockMute() end, "audio_engine_perp")
cvars.AddChangeCallback("audio_engine_mutetyrescrape", function() AudioEngine.ApplyStockMute() end, "audio_engine_perp")
if (SERVER and #player.GetAll() > 0) or (CLIENT and IsValid(LocalPlayer())) then AudioEngine.ApplyStockMute() end -- lua refresh

-- spawn menu entries (sandbox and derived gamemodes; PERP's own dealer ignores them).
-- PERP's vehicle scripts come in a workshop pack (3792392486) that the PERP server sends, and
-- Garry's Mod only mounts it while connected there. A jeep without its script has no physics
-- and can't drive, so off the server the cars fall back to a generic test script.
-- Job vehicles (sh_carlist.lua AudioEngine.JOB_VEHICLES) get a tab of their own, each on its own script and in
-- its livery skin; a car whose base script is a job's spawns from that tab only.
-- AudioPerpScript tells sv_handling which script's physics to put on a car that fell back to the
-- test script, AudioSkin is the skin (sandbox only passes whitelisted KeyValues on)
local TEST_SCRIPT = "scripts/vehicles/audio_engine/test_car.txt"
local fallbackCount = 0
local carsByName, jobOnlyCars = {}, {}
for _, carConfig in pairs(AudioEngine.Cars) do carsByName[carConfig.name] = carConfig end
for _, job in ipairs(AudioEngine.JOB_VEHICLES or {}) do
	local carConfig = carsByName[job[2]]
	if carConfig and carConfig.script == job[3] then jobOnlyCars[carConfig.name] = true end
end

local function addSpawnEntry(entryId, name, carConfig, perpScript, category, skin)
	if not (carConfig.perp and perpScript and file.Exists(carConfig.model, "GAME")) then return end
	local script, info = perpScript, "PERP handling"
	if not file.Exists(script, "GAME") then
		script, info = TEST_SCRIPT, "generic test handling with PERP's values (PERP's vehicle scripts aren't mounted)"
		fallbackCount = fallbackCount + 1
	end
	list.Set("Vehicles", entryId, {
		Name = name,
		Class = "prop_vehicle_jeep",
		Category = category,
		Author = "PERPHeads / TDM",
		Information = name .. ": " .. info .. ", procedural engine sound.",
		Model = carConfig.model,
		KeyValues = { vehiclescript = script },
		AudioPerpScript = perpScript,
		AudioSkin = skin,
	})
end

for _, carConfig in pairs(AudioEngine.Cars) do
	if not jobOnlyCars[carConfig.name] then
		addSpawnEntry("perp_" .. carConfig.carId, carConfig.name, carConfig, carConfig.script, "PERP cars (Audio Engine)")
	end
end
for _, job in ipairs(AudioEngine.JOB_VEHICLES or {}) do
	local carConfig = carsByName[job[2]]
	if carConfig then
		addSpawnEntry("perp_job_" .. string.lower((job[1]:gsub("[^%w]+", "_"))), job[1], carConfig, job[3],
			"PERP job vehicles (Audio Engine)", job[4])
	end
end
if fallbackCount > 0 then
	MsgN(string.format("[Audio Engine] %d PERP spawn entries use the generic test handling: their PERP vehicle scripts aren't mounted", fallbackCount))
end

if SERVER then
	hook.Add("PlayerSpawnedVehicle", "audio_engine_jobskin", function(spawner, vehicle)
		local vehicleTable = vehicle.VehicleTable
		if istable(vehicleTable) and vehicleTable.AudioSkin and vehicleTable.AudioSkin > 0 then vehicle:SetSkin(vehicleTable.AudioSkin) end
	end)
end
