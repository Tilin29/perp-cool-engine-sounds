--[[
	Audio Engine - speed limiter (server)

	Middle mouse button: on at exactly the speed you're going, or off again. Mouse wheel while
	it's on: the limit moves to the next 5 mph step up or down.

	You still drive the car: W accelerates at full power up to AudioEngine.CRUISE.band under the limit,
	then the engine's power is trimmed to hold the limit exactly (sv_handling.lua,
	vehicle.audioLimiterPower: smooth, no surging). Let go of W and the car coasts as usual. Over the
	limit (it was lowered, or downhill) the power is cut and it brakes, harder the further over
	it is, up to brakeMax: a lowered limit pulls the car down briskly, but like real brakes.
	Getting out and the engine stopping switch it off.

	To the clients: audio_cruise = the limit (mph, 0 = off) for the HUD, and audio_limst =
	0 free / 1 holding at the limit (sounds like the throttle held 80% down) / 2 over it (throttle shut).
]]
local AudioEngine = AUDIO_ENGINE

local limiterConVar = CreateConVar("audio_engine_cruise", "1", FCVAR_ARCHIVE + FCVAR_NOTIFY,
	"1 = speed limiter on registered cars (middle mouse button; mouse wheel sets the limit)")

AudioEngine.CRUISE = {
	step = 5,         -- mph per mouse wheel notch (the limit snaps to these steps)
	minMph = 5,       -- the lowest limit
	-- the power trim (sv_handling.lua), from band mph under the limit: it wants the car to gain
	-- k x (mph still to go) mph/s and moves the power (share of the car's) at ki per mph/s of
	-- difference, so it finds the power that holds the speed by itself, for any car. (A PI on
	-- the speed error overshot by 1-2 mph and settled slowly.)
	band = 6, accelerationGain = 1.2, powerGain = 0.25, minPower = 0.02,
	reentry = 0.1,    -- the power when the brake lets go (it's slowing to a lower speed)
	-- over the limit: power off and braking from brakeOver mph over until under brakeOff
	brakeOver = 0.6, brakeOff = 0.15,
	brakeBase = 0.6,  -- m/s2 as it starts...
	brakeGain = 0.7,  -- ...more per mph over...
	brakeMax = 3.5,   -- ...up to this (~0.35 g): 60 to 40 mph in about 2.5 s
	powerStep = 0.02,   -- the power is re-sent to the physics when it moved this much
}

local function speedMph(vehicle)
	local physics = vehicle:GetPhysicsObject()
	return IsValid(physics) and physics:GetVelocity():Length() / AudioEngine.HU_PER_MPH or 0
end

-- the registered car this player drives
local function drivenCar(player)
	local vehicle = player:GetVehicle()
	if IsValid(vehicle) and vehicle:GetDriver() == player and AudioEngine.TrackedVehicles and AudioEngine.TrackedVehicles[vehicle] then return vehicle end
end

local function engineRunning(vehicle)
	return vehicle:GetNW2Bool("audio_on", false) and vehicle.audioStart == nil
end

local function setState(vehicle, state)
	if vehicle.audioLimiterState ~= state then vehicle.audioLimiterState = state; vehicle:SetNW2Int("audio_limst", state) end
end

local function setLimit(vehicle, mph)
	vehicle.audioSpeedLimit, vehicle.audioLimiterHolding, vehicle.audioLimiterBraking = mph, false, false
	vehicle.audioLimiterHoldPower = 1
	vehicle:SetNW2Float("audio_cruise", mph or 0)
	setState(vehicle, 0)
end

-- within minMph and the car's own top speed
local function clampLimit(vehicle, mph)
	local topSpeedMph = vehicle:GetNW2Float("audio_vmax", 0) / 1.609344
	if topSpeedMph > AudioEngine.CRUISE.minMph then mph = math.min(mph, topSpeedMph) end
	return math.max(AudioEngine.CRUISE.minMph, mph)
end

hook.Add("PlayerButtonDown", "audio_engine_cruise", function(player, button)
	if button ~= MOUSE_MIDDLE or not limiterConVar:GetBool() then return end
	local vehicle = drivenCar(player)
	if not vehicle then return end
	if vehicle.audioSpeedLimit then setLimit(vehicle, nil) return end
	if not engineRunning(vehicle) then return end
	setLimit(vehicle, clampLimit(vehicle, speedMph(vehicle)))
end)

-- the mouse wheel moves the limit to the next step
hook.Add("StartCommand", "audio_engine_cruise", function(player, command)
	local vehicle = drivenCar(player)
	if not vehicle or not vehicle.audioSpeedLimit then return end
	local wheel = command:GetMouseWheel()
	if wheel == 0 then return end
	local limiterConfig, currentLimit = AudioEngine.CRUISE, vehicle.audioSpeedLimit
	local mph = wheel > 0 and (math.floor(currentLimit / limiterConfig.step + 1e-3) + 1) * limiterConfig.step
		or (math.ceil(currentLimit / limiterConfig.step - 1e-3) - 1) * limiterConfig.step
	mph = clampLimit(vehicle, mph)
	if mph ~= currentLimit then vehicle.audioSpeedLimit = mph; vehicle:SetNW2Float("audio_cruise", mph) end
end)

hook.Add("Tick", "audio_engine_cruise", function()
	local limiterConfig, deltaTime = AudioEngine.CRUISE, engine.TickInterval()
	for vehicle in pairs(AudioEngine.TrackedVehicles or {}) do
		if IsValid(vehicle) and vehicle.audioSpeedLimit then
			local driver = vehicle:GetDriver()
			if not limiterConVar:GetBool() or not IsValid(driver) or not engineRunning(vehicle) then
				setLimit(vehicle, nil)
			else
				local physics = vehicle:GetPhysicsObject()
				local speed = speedMph(vehicle)
				local overLimit = speed - vehicle.audioSpeedLimit
				-- over the limit: power off and brake, harder the further over
				if overLimit > limiterConfig.brakeOver then
					vehicle.audioLimiterBraking = true
				elseif vehicle.audioLimiterBraking and overLimit < limiterConfig.brakeOff then
					vehicle.audioLimiterBraking, vehicle.audioLimiterHoldPower = false, limiterConfig.reentry
				end
				-- W held near the limit: the power trim holds it (sv_handling.lua)
				local holding = driver:KeyDown(IN_FORWARD) and overLimit > -limiterConfig.band
				if holding and not vehicle.audioLimiterHolding and not vehicle.audioLimiterBraking then vehicle.audioLimiterHoldPower = 1 end
				vehicle.audioLimiterHolding = holding
				if vehicle.audioLimiterBraking and IsValid(physics) then
					local deceleration = math.min(limiterConfig.brakeMax, limiterConfig.brakeBase + limiterConfig.brakeGain * math.max(0, overLimit - limiterConfig.brakeOff))
					local velocity = physics:GetVelocity()
					-- impulse: kg x in/s (velocities are inches/s)
					physics:ApplyForceCenter(-velocity:GetNormalized() * physics:GetMass() * deceleration / 0.0254 * deltaTime)
				end
				setState(vehicle, vehicle.audioLimiterBraking and 2 or holding and 1 or 0)
			end
		end
	end
end)

hook.Add("PlayerLeaveVehicle", "audio_engine_cruise", function(_, vehicle)
	if IsValid(vehicle) and vehicle.audioSpeedLimit then setLimit(vehicle, nil) end
end)
