--[[
	Police lightbars (sh_police.lua): on spawn a marked police car gets its livery and the bar,
	parented to the car. The driver switches the lights (audio_engine_lights, sent by the light key
	in cl_police.lua): off -> CODE 2 -> CODE 3 -> off. The mode is NW2 audio_lights on the car,
	the bar NW2 audio_lightbar; the clients draw the flashing.
]]
local E = AUDIO_ENGINE

local KEY_COOLDOWN = 0.25
local warnedModel = false

-- spawn-menu cars that fell back to the test script keep the PERP script they stand for (sh_perp.lua)
local function policeEntry(veh)
	local vt = veh.VehicleTable
	local script = istable(vt) and vt.AudioPerpScript or E.VehicleScriptOf(veh)

	return script and E.POLICE_BY_SCRIPT[string.lower(script)]
end

local function attachLightbar(veh, police)
	if IsValid(veh.audioLightbar) then return end
	if not util.IsValidModel(E.LIGHTBAR_MODEL) then
		if not warnedModel then
			warnedModel = true
			MsgN("[Audio Engine] police cars get no lightbar: ", E.LIGHTBAR_MODEL, " isn't mounted")
		end
		return
	end
	local bar = ents.Create("prop_dynamic")
	bar:SetModel(E.LIGHTBAR_MODEL)
	bar:SetPos(veh:LocalToWorld(police.mount))
	bar:SetAngles(veh:LocalToWorldAngles(E.LIGHTBAR_ANGLE))
	bar:SetParent(veh)
	bar:Spawn()
	bar:SetSolid(SOLID_NONE)
	bar:DrawShadow(false)
	veh:DeleteOnRemove(bar)
	veh.audioLightbar = bar
	veh:SetNW2Entity("audio_lightbar", bar)
end

local function setupPolice(veh)
	if not IsValid(veh) or not veh:IsVehicle() then return end
	local police = policeEntry(veh)
	if not police then return end
	if police.skin > 0 and police.skin < veh:SkinCount() then veh:SetSkin(police.skin) end
	for name, value in pairs(police.bodygroups or {}) do
		local id = veh:FindBodygroupByName(name)
		if id >= 0 then veh:SetBodygroup(id, value) end
	end
	attachLightbar(veh, police)
end

hook.Add("OnEntityCreated", "audio_engine_police", function(ent)
	if ent:GetClass() ~= "prop_vehicle_jeep" then return end
	timer.Simple(0, function() setupPolice(ent) end)
end)

-- lua refresh: cars already out there
for _, veh in ipairs(ents.FindByClass("prop_vehicle_jeep")) do setupPolice(veh) end

-- no argument: the next mode; 0 = off, 1 = CODE 2, 2 = CODE 3
concommand.Add("audio_engine_lights", function(ply, _, args)
	if not IsValid(ply) then return end
	local veh = ply:GetVehicle()
	if not IsValid(veh) or veh:GetDriver() ~= ply or not IsValid(veh.audioLightbar) then return end
	if (ply.audioLightsNext or 0) > CurTime() then return end
	ply.audioLightsNext = CurTime() + KEY_COOLDOWN
	local modes = #E.LIGHT_MODES
	local mode = tonumber(args[1])
	if mode then
		mode = math.Clamp(math.floor(mode), 0, modes)
	else
		mode = (veh:GetNW2Int("audio_lights", 0) + 1) % (modes + 1)
	end
	veh:SetNW2Int("audio_lights", mode)
end, nil, "Police lightbar of the car you're driving: no argument = next mode, 0 = off, 1 = CODE 2, 2 = CODE 3")
