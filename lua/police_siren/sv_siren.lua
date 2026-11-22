--[[
	Police siren, server side: the driver's tone key (sent by cl_siren.lua's key or bound by
	hand). Only the driver of a car with a lightbar, while the lights are on. The driver getting out
	silences it (the lights stay on).
]]
local PoliceSiren = POLICE_SIREN

local KEY_COOLDOWN = 0.2

local function drivenSirenCar(player)
	local vehicle = player:GetVehicle()
	if not IsValid(vehicle) or vehicle:GetDriver() ~= player or not PoliceSiren.HasSiren(vehicle) then return nil end

	return vehicle
end

concommand.Add("police_siren_tone", function(player)
	if not IsValid(player) then return end
	local vehicle = drivenSirenCar(player)
	if not vehicle then return end
	local lightMode = vehicle:GetNW2Int(PoliceSiren.LIGHTS_NW, 0)
	if lightMode == 0 or (player.sirenToneAllowedAt or 0) > CurTime() then return end
	player.sirenToneAllowedAt = CurTime() + KEY_COOLDOWN
	vehicle:SetNW2String("siren_tone", PoliceSiren.NextTone(vehicle, PoliceSiren.ChosenTone(vehicle)))
	vehicle:SetNW2Int("siren_at", lightMode)
end, nil, "Police siren of the car you're driving: the next tone (with the lights on)")

-- the driver getting out silences the siren; the lights stay on (the user). "No tone" is chosen for
-- the light mode the car is in, so it stays quiet when they get back in until the tone key or a new
-- light mode. Only the driver's seat: a passenger's is a pod without a lightbar
hook.Add("PlayerLeaveVehicle", "police_siren", function(player, vehicle)
	if not PoliceSiren.HasSiren(vehicle) then return end
	local lightMode = vehicle:GetNW2Int(PoliceSiren.LIGHTS_NW, 0)
	if lightMode == 0 or not PoliceSiren.SoundingTone(vehicle) then return end
	vehicle:SetNW2String("siren_tone", "")
	vehicle:SetNW2Int("siren_at", lightMode)
end)
