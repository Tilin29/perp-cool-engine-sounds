--[[
	Audio Engine - cruise control (server)

	Middle mouse button: on at the speed you're going, rounded to the nearest 5 mph (from
	E.CRUISE.minMph), or off again. Mouse wheel while it's on: 5 mph up or down.

	It holds W for the driver, in the player's own command, so Source's physics, traction
	control and the stability assist see a driver on the throttle, and trims the engine's power
	to hold the speed (sv_handling.lua, veh.audioCruisePow: smooth, where pressing W on and off
	surged the car and swung the engine sound between full throttle and none). It only lets go
	of W when the car runs coastAbove over (downhill). Holding W yourself accelerates past it
	at full power (it comes back once you let go); S or the handbrake cancels it, as do getting
	out, the engine stopping and the car coming to a stop against something.

	The set speed goes to the car as audio_cruise (mph, 0 = off) for the HUD and the sound.
]]
local E = AUDIO_ENGINE

local cvOn = CreateConVar("audio_engine_cruise", "1", FCVAR_ARCHIVE + FCVAR_NOTIFY,
	"1 = cruise control on registered cars (middle mouse button; mouse wheel sets the speed)")

E.CRUISE = {
	step = 5,         -- mph per press / wheel notch, and what the speed rounds to
	minMph = 10,      -- the lowest set speed
	coastAbove = 3,   -- mph over the set speed where it lets go of W (downhill)...
	resumeAt = 1,     -- ...and under which it holds W again
	-- the power trim (sv_handling.lua): share of the car's power, PI on the speed error (mph)
	kp = 0.06, ki = 0.04, minPow = 0.03, startPow = 0.35,
	stuckMph = 3,     -- slower than this for stuckTime s (against a wall): off
	stuckTime = 1.5,
}

local function speedMph(veh)
	local phys = veh:GetPhysicsObject()
	return IsValid(phys) and phys:GetVelocity():Length() / E.HU_PER_MPH or 0
end

-- the registered car this player drives
local function drivenCar(ply)
	local veh = ply:GetVehicle()
	if IsValid(veh) and veh:GetDriver() == ply and E.TrackedVehicles and E.TrackedVehicles[veh] then return veh end
end

local function running(veh)
	return veh:GetNW2Bool("audio_on", false) and veh.audioStart == nil
end

local function setCruise(veh, mph)
	veh.audioCruise, veh.audioCruiseThr, veh.audioCruiseStuck = mph, false, 0
	veh.audioCruiseI, veh.audioCruiseOwn = E.CRUISE.startPow, false
	veh:SetNW2Float("audio_cruise", mph or 0)
end

-- the set speed, in steps, between minMph and the car's own top speed
local function limit(veh, mph)
	local C = E.CRUISE
	local top = veh:GetNW2Float("audio_vmax", 0) / 1.609344
	mph = math.floor(mph / C.step + 0.5) * C.step
	if top > C.minMph then mph = math.min(mph, math.floor(top / C.step) * C.step) end
	return math.max(C.minMph, mph)
end

hook.Add("PlayerButtonDown", "audio_engine_cruise", function(ply, button)
	if button ~= MOUSE_MIDDLE or not cvOn:GetBool() then return end
	local veh = drivenCar(ply)
	if not veh then return end
	if veh.audioCruise then setCruise(veh, nil) return end
	if not running(veh) then return end
	local mph = speedMph(veh)
	if mph + E.CRUISE.step / 2 < E.CRUISE.minMph then return end
	setCruise(veh, limit(veh, mph))
end)

hook.Add("StartCommand", "audio_engine_cruise", function(ply, cmd)
	local veh = drivenCar(ply)
	if not veh or not veh.audioCruise then return end
	local C = E.CRUISE
	local buttons = cmd:GetButtons()
	if not cvOn:GetBool() or not running(veh) or bit.band(buttons, IN_BACK + IN_JUMP) ~= 0 then
		setCruise(veh, nil)
		return
	end
	local wheel = cmd:GetMouseWheel()
	if wheel ~= 0 then
		local mph = limit(veh, veh.audioCruise + (wheel > 0 and C.step or -C.step))
		if mph ~= veh.audioCruise then veh.audioCruise = mph; veh:SetNW2Float("audio_cruise", mph) end
	end
	-- the driver's own W: let them accelerate past it (full power: audioCruiseOwn)
	veh.audioCruiseOwn = bit.band(buttons, IN_FORWARD) ~= 0
	if veh.audioCruiseOwn then return end
	local v = speedMph(veh)
	if v < C.stuckMph then
		veh.audioCruiseStuck = veh.audioCruiseStuck + engine.TickInterval()
		if veh.audioCruiseStuck > C.stuckTime then setCruise(veh, nil) return end
	else
		veh.audioCruiseStuck = 0
	end
	if veh.audioCruiseThr then
		if v > veh.audioCruise + C.coastAbove then veh.audioCruiseThr = false end
	elseif v < veh.audioCruise + C.resumeAt then
		veh.audioCruiseThr = true
	end
	if veh.audioCruiseThr then cmd:SetButtons(bit.bor(buttons, IN_FORWARD)) end
end)

hook.Add("PlayerLeaveVehicle", "audio_engine_cruise", function(_, veh)
	if IsValid(veh) and veh.audioCruise then setCruise(veh, nil) end
end)
