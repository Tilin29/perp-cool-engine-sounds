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

local E = AUDIO_ENGINE

local cvMute = CreateConVar("audio_engine_mutestock", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"1 = silence the TDM engine recordings of cars that use the procedural engine")
local cvSkid = CreateConVar("audio_engine_muteskid", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"1 = silence the TDM tyre screech when braking (shared by all TDM cars)")
local cvScrape = CreateConVar("audio_engine_mutetyrescrape", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"1 = silence the scrape of sliding tyres (glass bottle / dirt surface sounds; global)")

-- the scrape sounds of the surface materials PERP's wheels slide and brake on
-- (glassbottle; slidingrubbertire / brakingrubbertire / snow, which all scrape as dirt)
E.TYRE_SCRAPE_SOUNDS = { "GlassBottle.ScrapeRough", "GlassBottle.ScrapeSmooth", "Dirt.Scrape" }

local PACKS = { "tdmcars", "jarheads", "perp2" }
local TIERS = { "", "used/", "upgrade_1/", "upgrade_2/", "spiked/" }

-- variant scripts whose name doesn't start with their car's base script name
E.PERP_SCRIPT_ALIASES = E.PERP_SCRIPT_ALIASES or {
	["tdmcars/charger_cop"] = "tdmcars/chargersrt8",
}

-- scripts with no model in PERP's content packs: nothing spawns on them, so the soundscripts
-- they share don't keep a registered car's recording playing (the GTA IV tow truck's "bus_*"
-- would keep the fire truck's)
E.PERP_SCRIPT_UNUSED = E.PERP_SCRIPT_UNUSED or {
	["perp2/towtruck"] = true,
	["tdmcars/lee"] = true,
	["tdmcars/subimpreza"] = true,
}

-- only soundscripts can be redefined; a raw path ("vehicles\...\x.wav") can't be. Door sounds
-- (the GTA IV vehicles start up with "tdm_door_open") aren't the engine and may play elsewhere
local function add(set, snd)
	if snd and snd ~= "" and not snd:find("[%.\\/]") and not snd:lower():find("door", 1, true) then
		set[snd:lower()] = snd
	end
end

-- soundscript names of a vehicle script's engine states, into set[lower] = original spelling,
-- and of its Skid_* sounds into skids
local function stateSounds(path, set, skids)
	local txt = file.Read(path, "GAME")
	if not txt then return end
	for block in txt:gmatch('"[Ss][Tt][Aa][Tt][Ee]"%s*(%b{})') do
		add(set, block:match('"[Ss][Oo][Uu][Nn][Dd]"%s*"([^"]*)"'))
	end
	if skids then
		for snd in txt:gmatch('"[Ss][Kk][Ii][Dd]_%a+"%s*"([^"]*)"') do add(skids, snd) end
	end
end

local function collect()
	local claimed = {}
	local function claim(script)
		local pk, base = (script or ""):lower():match("^scripts/vehicles/([^/]+)/([^/]+)%.txt$")
		if pk then claimed[pk .. "/" .. base] = { pk = pk, base = base } end
	end
	for _, car in pairs(E.Cars) do claim(car.script) end
	-- job variants not named <base>_something (dodgeramff)
	for _, job in ipairs(E.JOB_VEHICLES or {}) do claim(job[3]) end
	-- is this script one of a registered car's (its own name, or "<base>_something")?
	local function ours(pk, name)
		if E.PERP_SCRIPT_ALIASES[pk .. "/" .. name] or claimed[pk .. "/" .. name] then return true end
		for _, c in pairs(claimed) do
			if c.pk == pk and name:sub(1, #c.base + 1) == c.base .. "_" then return true end
		end
		return false
	end

	local mine, others, skids = {}, {}, {}
	for _, pk in ipairs(PACKS) do
		for _, tier in ipairs(TIERS) do
			local dir = "scripts/vehicles/" .. pk .. "/" .. tier
			for _, f in ipairs((file.Find(dir .. "*.txt", "GAME"))) do
				local name = f:lower():gsub("%.txt$", "")
				if not E.PERP_SCRIPT_UNUSED[pk .. "/" .. name] then
					local own = ours(pk, name)
					-- spiked scripts scrape on the rims: that one stays
					stateSounds(dir .. f, own and mine or others, own and tier ~= "spiked/" and skids or nil)
				end
			end
		end
	end
	-- registered cars whose script lives somewhere else (e.g. the example police car in scripts/vehicles/plpd/)
	for _, car in pairs(E.Cars) do
		if car.script then stateSounds(car.script, mine, skids) end
	end

	local muted, kept = {}, 0
	for low, name in pairs(mine) do
		if others[low] then kept = kept + 1 else muted[low] = name end
	end
	return muted, kept, skids
end

E.PERP_SAVED = E.PERP_SAVED or {}
local NULL = "common/null.wav"

-- point a soundscript at silence, or put the original back
local function mute(name, on)
	local saved = E.PERP_SAVED[name]
	if saved == nil then
		local p = sound.GetProperties(name)
		saved = (p and p.sound ~= NULL) and p or false
		E.PERP_SAVED[name] = saved
	end
	if on then
		sound.Add({ name = name, channel = CHAN_STATIC, volume = 1, level = 0, pitch = 100, sound = NULL })
	elseif saved then
		sound.Add(saved)
	end
end

function E.ApplyStockMute()
	local muted, kept, skids = collect()
	E.PERP_MUTED, E.PERP_SKIDS = muted, skids
	local on, skidOn = cvMute:GetBool(), cvSkid:GetBool()
	local n, ns = 0, 0
	for _, name in pairs(muted) do mute(name, on) n = n + 1 end
	for low, name in pairs(skids) do
		if not muted[low] then mute(name, skidOn) ns = ns + 1 end
	end
	if on then
		MsgN(string.format("[Audio Engine] muted %d TDM engine sounds of PERP cars (%d shared with other vehicles kept)", n, kept))
	end
	if skidOn and ns > 0 then
		MsgN(string.format("[Audio Engine] muted %d TDM tyre screech sounds", ns))
	end
	local scrapeOn = cvScrape:GetBool()
	for _, name in ipairs(E.TYRE_SCRAPE_SOUNDS) do mute(name, scrapeOn) end
end

-- TDM / PERP define their soundscripts in their own autorun files, which may load after this
-- one: (re)apply once everything is loaded, and once more a little later
hook.Add("InitPostEntity", "audio_engine_perp", function()
	E.ApplyStockMute()
	timer.Simple(3, E.ApplyStockMute)
end)
cvars.AddChangeCallback("audio_engine_mutestock", function() E.ApplyStockMute() end, "audio_engine_perp")
cvars.AddChangeCallback("audio_engine_muteskid", function() E.ApplyStockMute() end, "audio_engine_perp")
cvars.AddChangeCallback("audio_engine_mutetyrescrape", function() E.ApplyStockMute() end, "audio_engine_perp")
if (SERVER and #player.GetAll() > 0) or (CLIENT and IsValid(LocalPlayer())) then E.ApplyStockMute() end -- lua refresh

-- spawn menu entries (sandbox and derived gamemodes; PERP's own dealer ignores them).
-- PERP's vehicle scripts come in a workshop pack (3792392486) that the PERP server sends, and
-- Garry's Mod only mounts it while connected there. A jeep without its script has no physics
-- and can't drive, so off the server the cars fall back to a generic test script.
-- Job vehicles (sh_carlist.lua E.JOB_VEHICLES) get a tab of their own, each on its own script and in
-- its livery skin; a car whose base script is a job's spawns from that tab only.
-- AudioPerpScript tells sv_handling which script's physics to put on a car that fell back to the
-- test script, AudioSkin is the skin (sandbox only passes whitelisted KeyValues on)
local TEST_SCRIPT = "scripts/vehicles/audio_engine/test_car.txt"
local fallback = 0
local byName, jobOnly = {}, {}
for _, car in pairs(E.Cars) do byName[car.name] = car end
for _, job in ipairs(E.JOB_VEHICLES or {}) do
	local car = byName[job[2]]
	if car and car.script == job[3] then jobOnly[car.name] = true end
end

local function addSpawn(id, name, car, perpScript, category, skin)
	if not (car.perp and perpScript and file.Exists(car.model, "GAME")) then return end
	local script, info = perpScript, "PERP handling"
	if not file.Exists(script, "GAME") then
		script, info = TEST_SCRIPT, "generic test handling with PERP's values (PERP's vehicle scripts aren't mounted)"
		fallback = fallback + 1
	end
	list.Set("Vehicles", id, {
		Name = name,
		Class = "prop_vehicle_jeep",
		Category = category,
		Author = "PERPHeads / TDM",
		Information = name .. ": " .. info .. ", procedural engine sound.",
		Model = car.model,
		KeyValues = { vehiclescript = script },
		AudioPerpScript = perpScript,
		AudioSkin = skin,
	})
end

for _, car in pairs(E.Cars) do
	if not jobOnly[car.name] then
		addSpawn("perp_" .. car.carId, car.name, car, car.script, "PERP cars (Audio Engine)")
	end
end
for _, job in ipairs(E.JOB_VEHICLES or {}) do
	local car = byName[job[2]]
	if car then
		addSpawn("perp_job_" .. string.lower((job[1]:gsub("[^%w]+", "_"))), job[1], car, job[3],
			"PERP job vehicles (Audio Engine)", job[4])
	end
end
if fallback > 0 then
	MsgN(string.format("[Audio Engine] %d PERP spawn entries use the generic test handling: their PERP vehicle scripts aren't mounted", fallback))
end

if SERVER then
	hook.Add("PlayerSpawnedVehicle", "audio_engine_jobskin", function(ply, veh)
		local vt = veh.VehicleTable
		if istable(vt) and vt.AudioSkin and vt.AudioSkin > 0 then veh:SetSkin(vt.AudioSkin) end
	end)
end
