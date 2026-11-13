--[[
	Car horn: which horn a car has and whether it sounds. Separate from the audio engine: any
	car (prop_vehicle_jeep) has a horn, CONFIG.models' for its model or CONFIG.default.

	The driver's honk key sets NW2 horn_on on the car (sv_horn.lua) and counts every press in
	horn_presses: a tap's press and release can land in the same tick, and the count still tells
	every client it was pressed.
]]
local CarHorn = CAR_HORN

CarHorn.ON_NW = "horn_on"
CarHorn.PRESSES_NW = "horn_presses"
CarHorn.PRESSES_WRAP = 1024

-- the car's horn: an id of CONFIG.horns, or nil (not a car)
function CarHorn.HornOf(vehicle)
	if not IsValid(vehicle) or vehicle:GetClass() ~= "prop_vehicle_jeep" then return nil end
	local config = CarHorn.CONFIG
	local hornId = config.models[string.lower(vehicle:GetModel() or "")]
	if not config.horns[hornId or ""] then hornId = config.default end

	return config.horns[hornId] and hornId or nil
end
