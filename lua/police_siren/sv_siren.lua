--[[
	Police siren, server side: the driver's tone key and horn (sent by cl_siren.lua's keys or
	bound by hand). Only the driver of a car with a lightbar; the tone key works while the
	lights are on.
]]
local PS = POLICE_SIREN

local KEY_COOLDOWN = 0.2

local function drivenSirenCar(ply)
	local veh = ply:GetVehicle()
	if not IsValid(veh) or veh:GetDriver() ~= ply or not PS.HasSiren(veh) then return nil end

	return veh
end

concommand.Add("police_siren_tone", function(ply)
	if not IsValid(ply) then return end
	local veh = drivenSirenCar(ply)
	if not veh then return end
	local lights = veh:GetNW2Int(PS.LIGHTS_NW, 0)
	if lights == 0 or (ply.sirenToneNext or 0) > CurTime() then return end
	ply.sirenToneNext = CurTime() + KEY_COOLDOWN
	veh:SetNW2String("siren_tone", PS.NextTone(PS.ChosenTone(veh)))
	veh:SetNW2Int("siren_at", lights)
end, nil, "Police siren of the car you're driving: the next tone (with the lights on)")

concommand.Add("police_siren_horn", function(ply, _, args)
	if not IsValid(ply) then return end
	local veh = drivenSirenCar(ply)
	if veh then veh:SetNW2Bool("siren_horn", args[1] == "1") end
end, nil, "Police siren horn of the car you're driving: 1 = on, 0 = off")

hook.Add("PlayerLeaveVehicle", "police_siren", function(_, veh)
	if IsValid(veh) and veh:GetNW2Bool("siren_horn", false) then veh:SetNW2Bool("siren_horn", false) end
end)
