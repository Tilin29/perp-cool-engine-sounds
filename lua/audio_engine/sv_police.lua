--[[
	Emergency lights (sh_police.lua): on spawn a police, fire or medical car gets its livery and
	the bar, parented to the car (a car with lights of its own in the model carries them itself:
	the car is its own audio_lightbar). The driver switches the lights (audio_engine_lights, sent
	by the light key in cl_police.lua): off -> CODE 2 -> CODE 3 -> off. The mode is NW2
	audio_lights on the car, the bar NW2 audio_lightbar, the colours NW2 audio_lightscheme; the
	clients draw the flashing.
]]
local AudioEngine = AUDIO_ENGINE

local KEY_COOLDOWN = 0.25
local warnedModel = false

-- spawn-menu cars that fell back to the test script keep the PERP script they stand for (sh_perp.lua)
local function policeEntry(vehicle)
	local vehicleTable = vehicle.VehicleTable
	local script = istable(vehicleTable) and vehicleTable.AudioPerpScript or AudioEngine.VehicleScriptOf(vehicle)

	return script and AudioEngine.POLICE_BY_SCRIPT[string.lower(script)]
end

local function attachLightbar(vehicle, police)
	if IsValid(vehicle.audioLightbar) then return end
	vehicle:SetNW2String("audio_lightscheme", police.scheme or "police")
	if police.builtin then
		vehicle.audioLightbar = vehicle
		vehicle:SetNW2Entity("audio_lightbar", vehicle)
		return
	end
	if not util.IsValidModel(AudioEngine.LIGHTBAR_MODEL) then
		if not warnedModel then
			warnedModel = true
			MsgN("[Audio Engine] police cars get no lightbar: ", AudioEngine.LIGHTBAR_MODEL, " isn't mounted")
		end
		return
	end
	local lightbar = ents.Create("prop_dynamic")
	lightbar:SetModel(AudioEngine.LIGHTBAR_MODEL)
	lightbar:SetPos(vehicle:LocalToWorld(police.mount))
	lightbar:SetAngles(vehicle:LocalToWorldAngles(AudioEngine.LIGHTBAR_ANGLE))
	lightbar:SetParent(vehicle)
	lightbar:Spawn()
	lightbar:SetSolid(SOLID_NONE)
	lightbar:DrawShadow(false)
	vehicle:DeleteOnRemove(lightbar)
	vehicle.audioLightbar = lightbar
	vehicle:SetNW2Entity("audio_lightbar", lightbar)
end

local function setupPolice(vehicle)
	if not IsValid(vehicle) or not vehicle:IsVehicle() then return end
	local police = policeEntry(vehicle)
	if not police then return end
	if police.skin > 0 and police.skin < vehicle:SkinCount() then vehicle:SetSkin(police.skin) end
	for name, value in pairs(police.bodygroups or {}) do
		local bodygroupId = vehicle:FindBodygroupByName(name)
		if bodygroupId >= 0 then vehicle:SetBodygroup(bodygroupId, value) end
	end
	attachLightbar(vehicle, police)
end

hook.Add("OnEntityCreated", "audio_engine_police", function(entity)
	if entity:GetClass() ~= "prop_vehicle_jeep" then return end
	timer.Simple(0, function() setupPolice(entity) end)
end)

-- lua refresh: cars already out there
for _, vehicle in ipairs(ents.FindByClass("prop_vehicle_jeep")) do setupPolice(vehicle) end

-- no argument: the next mode; 0 = off, 1 = CODE 2, 2 = CODE 3
concommand.Add("audio_engine_lights", function(player, _, args)
	if not IsValid(player) then return end
	local vehicle = player:GetVehicle()
	if not IsValid(vehicle) or vehicle:GetDriver() ~= player or not IsValid(vehicle.audioLightbar) then return end
	if (player.audioLightsAllowedAt or 0) > CurTime() then return end
	player.audioLightsAllowedAt = CurTime() + KEY_COOLDOWN
	local modeCount = #AudioEngine.LIGHT_MODES
	local mode = tonumber(args[1])
	if mode then
		mode = math.Clamp(math.floor(mode), 0, modeCount)
	else
		mode = (vehicle:GetNW2Int("audio_lights", 0) + 1) % (modeCount + 1)
	end
	vehicle:SetNW2Int("audio_lights", mode)
end, nil, "Emergency lights of the car you're driving: no argument = next mode, 0 = off, 1 = CODE 2, 2 = CODE 3")
