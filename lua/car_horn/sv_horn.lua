--[[
	Car horn, server side: the driver's honk key (net car_horn, sent by cl_horn.lua on press and
	release) sets the car's horn_on and counts the presses. Only the driver; it stops when they get
	out (or die or leave the game, which gets them out).

	Overuse (car_horn_limit, CONFIG.limit, sh_horn.lua's charge): each player's horn charge is worked
	out here and is what counts. While a horn sounds it drains, and the car's horn_power follows how
	strong it still is; run dry, it croaks and stops, and presses are ignored until it's back. The
	player's charge is networked to them on every change, so their own client predicts the same.
]]
local CarHorn = CAR_HORN

-- presses closer together than this are ignored (a key bound to a spam script)
local MIN_PRESS_GAP = 0.06
-- horn_power is sent when it moved this much (it changes smoothly while a horn weakens)
local POWER_STEP = 0.02

util.AddNetworkString("car_horn")

-- the car's vehicle script, lower case with forward slashes (a spawn-menu car that fell back to a
-- stand-in script names the one it stands for in AudioPerpScript)
local function scriptOf(vehicle)
	local vehicleTable = vehicle.VehicleTable
	local script = istable(vehicleTable) and vehicleTable.AudioPerpScript
	if not isstring(script) or script == "" then
		local keyValues = vehicle:GetKeyValues() or {}
		script = keyValues.vehiclescript or keyValues.VehicleScript
		if (not isstring(script) or script == "") and istable(vehicleTable) and istable(vehicleTable.KeyValues) then
			script = vehicleTable.KeyValues.vehiclescript
		end
	end
	if not isstring(script) or script == "" then return nil end

	return (string.lower(script):gsub("\\", "/"))
end

-- CONFIG.scripts: the horn of a car whose script has its own (police versions of civilian cars)
local function pickScriptHorn(vehicle)
	if not IsValid(vehicle) or vehicle:GetClass() ~= "prop_vehicle_jeep" then return end
	local scripts = CarHorn.CONFIG.scripts or {}
	local script = scriptOf(vehicle)
	local hornId = script and scripts[script]
	if hornId and CarHorn.CONFIG.horns[hornId] and vehicle:GetNW2String(CarHorn.ID_NW, "") ~= hornId then
		vehicle:SetNW2String(CarHorn.ID_NW, hornId)
	end
end

hook.Add("OnEntityCreated", "car_horn_script", function(entity)
	if entity:GetClass() ~= "prop_vehicle_jeep" then return end
	timer.Simple(0, function() pickScriptHorn(entity) end)
end)

-- lua refresh: cars already out there
for _, vehicle in ipairs(ents.FindByClass("prop_vehicle_jeep")) do pickScriptHorn(vehicle) end

local honking = {}   -- player -> true while their horn sounds (drained every tick)

local function chargeOf(player)
	if not player.hornCharge then player.hornCharge = CarHorn.NewCharge(CurTime()) end

	return player.hornCharge
end

local function sendCharge(player)
	local state = player.hornCharge
	player:SetNW2Float(CarHorn.CHARGE_NW, state.charge)
	player:SetNW2Float(CarHorn.CHARGE_AT_NW, state.at)
	player:SetNW2Bool(CarHorn.EXHAUSTED_NW, state.exhausted)
end

local function setPower(vehicle, power)
	local current = vehicle:GetNW2Float(CarHorn.POWER_NW, 1)
	if math.abs(power - current) >= POWER_STEP or (power ~= current and (power == 0 or power == 1)) then
		vehicle:SetNW2Float(CarHorn.POWER_NW, power)
	end
end

local function setHorn(vehicle, down)
	if vehicle:GetNW2Bool(CarHorn.ON_NW, false) == down then return end
	if down then
		vehicle:SetNW2Int(CarHorn.PRESSES_NW, (vehicle:GetNW2Int(CarHorn.PRESSES_NW, 0) + 1) % CarHorn.PRESSES_WRAP)
	end
	vehicle:SetNW2Bool(CarHorn.ON_NW, down)
end

local function stopHonk(player)
	local vehicle = player.hornVehicle
	player.hornVehicle = nil
	honking[player] = nil
	if player.hornCharge and player.hornCharge.honking then CarHorn.ReleaseCharge(player.hornCharge, CurTime()) end
	if player.hornCharge then sendCharge(player) end
	if IsValid(vehicle) then setHorn(vehicle, false) end
end

net.Receive("car_horn", function(_, player)
	local down = net.ReadBool()
	local vehicle = player:GetVehicle()
	if not IsValid(vehicle) or vehicle:GetDriver() ~= player or not CarHorn.HornOf(vehicle) then return end
	if not down then
		stopHonk(player)
		return
	end
	local now = CurTime()
	if player.hornPressedAt and now - player.hornPressedAt < MIN_PRESS_GAP then return end
	player.hornPressedAt = now
	-- a honk something else plays (car_horn/replace: the police siren's horn override) isn't charged.
	-- horn_on is still set: that's how whatever replaces it hears the key
	player.hornReplaced = hook.Run("car_horn/replace", vehicle) == true
	if CarHorn.Limited(vehicle) and not player.hornReplaced then
		local state = chargeOf(player)
		local sounds = CarHorn.PressCharge(state, now)
		sendCharge(player)
		if not sounds then return end
		setPower(vehicle, CarHorn.ChargeStrength(state))
	else
		setPower(vehicle, 1)
	end
	player.hornVehicle = vehicle
	honking[player] = true
	setHorn(vehicle, true)
end)

-- draining the horns that sound: weaker as they run low, a croak and silence when they run dry
hook.Add("Tick", "car_horn", function()
	if next(honking) == nil then return end
	local now = CurTime()
	for player in pairs(honking) do
		local vehicle = IsValid(player) and player.hornVehicle
		if not IsValid(vehicle) or vehicle:GetDriver() ~= player then
			if IsValid(player) then stopHonk(player) else honking[player] = nil end
		elseif CarHorn.Limited(vehicle) and not player.hornReplaced then
			local state = chargeOf(player)
			if CarHorn.HoldCharge(state, now) then
				setPower(vehicle, CarHorn.ChargeStrength(state))
			else
				stopHonk(player)
			end
		end
	end
end)

hook.Add("PlayerLeaveVehicle", "car_horn", function(player, vehicle)
	if player.hornVehicle then stopHonk(player) end
	if IsValid(vehicle) and vehicle:GetNW2Bool(CarHorn.ON_NW, false) then setHorn(vehicle, false) end
end)

hook.Add("PlayerDisconnected", "car_horn", function(player)
	honking[player] = nil
end)
