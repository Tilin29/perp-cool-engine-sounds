--[[
	Car horn, server side: the driver's honk key (net car_horn, sent by cl_horn.lua on press and
	release) sets the car's horn_on and counts the presses. Only the driver; it stops when they get
	out (or die or leave the game, which gets them out).
]]
local CarHorn = CAR_HORN

-- presses closer together than this are ignored (a key bound to a spam script)
local MIN_PRESS_GAP = 0.06

util.AddNetworkString("car_horn")

local function setHorn(vehicle, down)
	if vehicle:GetNW2Bool(CarHorn.ON_NW, false) == down then return end
	if down then
		vehicle:SetNW2Int(CarHorn.PRESSES_NW, (vehicle:GetNW2Int(CarHorn.PRESSES_NW, 0) + 1) % CarHorn.PRESSES_WRAP)
	end
	vehicle:SetNW2Bool(CarHorn.ON_NW, down)
end

net.Receive("car_horn", function(_, player)
	local down = net.ReadBool()
	local vehicle = player:GetVehicle()
	if not IsValid(vehicle) or vehicle:GetDriver() ~= player or not CarHorn.HornOf(vehicle) then return end
	if down then
		local now = CurTime()
		if now - (player.hornPressedAt or 0) < MIN_PRESS_GAP then return end
		player.hornPressedAt = now
	end
	setHorn(vehicle, down)
end)

hook.Add("PlayerLeaveVehicle", "car_horn", function(_, vehicle)
	if IsValid(vehicle) then setHorn(vehicle, false) end
end)
