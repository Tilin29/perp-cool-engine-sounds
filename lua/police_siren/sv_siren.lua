--[[
	Police siren, server side: the driver's tone key (sent by cl_siren.lua's key or bound by
	hand). Only the driver of a car with a lightbar, while the lights are on.
]]
local PoliceSiren = POLICE_SIREN

local KEY_COOLDOWN = 0.2

local function drivenSirenCar(player)
	local vehicle = player:GetVehicle()
	if not IsValid(vehicle) or vehicle:GetDriver() ~= player or not PoliceSiren.HasSiren(vehicle) then return nil end

	return vehicle
end

-- no argument: the next tone of the scheme's cycle (round and round); "off": no tone (the lights stay)
concommand.Add("police_siren_tone", function(player, _, args)
	if not IsValid(player) then return end
	local vehicle = drivenSirenCar(player)
	if not vehicle then return end
	local lightMode = vehicle:GetNW2Int(PoliceSiren.LIGHTS_NW, 0)
	if lightMode == 0 or (player.sirenToneAllowedAt or 0) > CurTime() then return end
	player.sirenToneAllowedAt = CurTime() + KEY_COOLDOWN
	local toneId = args[1] == "off" and "" or PoliceSiren.NextTone(vehicle, PoliceSiren.ChosenTone(vehicle))
	vehicle:SetNW2String("siren_tone", toneId)
	vehicle:SetNW2Int("siren_at", lightMode)
end, nil, "Police siren of the car you're driving (lights on): no argument = the next tone, off = no tone")
