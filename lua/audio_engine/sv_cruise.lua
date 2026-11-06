--[[
	Audio Engine - speed limiter (server)

	Middle mouse button: on at exactly the speed you're going, or off again. Mouse wheel while
	it's on: the limit moves to the next 5 mph step up or down.

	You still drive the car: W accelerates at full power up to E.CRUISE.band under the limit,
	then the engine's power is trimmed to hold the limit exactly (sv_handling.lua,
	veh.audioCruisePow: smooth, no surging). Let go of W and the car coasts as usual. Over the
	limit (it was lowered, or downhill) the power is cut and it brakes, harder the further over
	it is, up to brakeMax: a lowered limit pulls the car down briskly, but like real brakes.
	Getting out and the engine stopping switch it off.

	To the clients: audio_cruise = the limit (mph, 0 = off) for the HUD, and audio_limst =
	0 free / 1 holding at the limit (sounds like the throttle held 80% down) / 2 over it (throttle shut).
]]
local E = AUDIO_ENGINE

local cvOn = CreateConVar("audio_engine_cruise", "1", FCVAR_ARCHIVE + FCVAR_NOTIFY,
	"1 = speed limiter on registered cars (middle mouse button; mouse wheel sets the limit)")

E.CRUISE = {
	step = 5,         -- mph per mouse wheel notch (the limit snaps to these steps)
	minMph = 5,       -- the lowest limit
	-- the power trim (sv_handling.lua), from band mph under the limit: it wants the car to gain
	-- k x (mph still to go) mph/s and moves the power (share of the car's) at ki per mph/s of
	-- difference, so it finds the power that holds the speed by itself, for any car. (A PI on
	-- the speed error overshot by 1-2 mph and settled slowly.)
	band = 6, k = 1.2, ki = 0.25, minPow = 0.02,
	reentry = 0.1,    -- the power when the brake lets go (it's slowing to a lower speed)
	-- over the limit: power off and braking from brakeOver mph over until under brakeOff
	brakeOver = 0.6, brakeOff = 0.15,
	brakeBase = 0.6,  -- m/s2 as it starts...
	brakeGain = 0.7,  -- ...more per mph over...
	brakeMax = 3.5,   -- ...up to this (~0.35 g): 60 to 40 mph in about 2.5 s
	powStep = 0.02,   -- the power is re-sent to the physics when it moved this much
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

local function setState(veh, s)
	if veh.audioLimSt ~= s then veh.audioLimSt = s; veh:SetNW2Int("audio_limst", s) end
end

local function setLimit(veh, mph)
	veh.audioCruise, veh.audioLimHold, veh.audioLimBrake = mph, false, false
	veh.audioCruiseI = 1
	veh:SetNW2Float("audio_cruise", mph or 0)
	setState(veh, 0)
end

-- within minMph and the car's own top speed
local function clampLimit(veh, mph)
	local top = veh:GetNW2Float("audio_vmax", 0) / 1.609344
	if top > E.CRUISE.minMph then mph = math.min(mph, top) end
	return math.max(E.CRUISE.minMph, mph)
end

hook.Add("PlayerButtonDown", "audio_engine_cruise", function(ply, button)
	if button ~= MOUSE_MIDDLE or not cvOn:GetBool() then return end
	local veh = drivenCar(ply)
	if not veh then return end
	if veh.audioCruise then setLimit(veh, nil) return end
	if not running(veh) then return end
	setLimit(veh, clampLimit(veh, speedMph(veh)))
end)

-- the mouse wheel moves the limit to the next step
hook.Add("StartCommand", "audio_engine_cruise", function(ply, cmd)
	local veh = drivenCar(ply)
	if not veh or not veh.audioCruise then return end
	local wheel = cmd:GetMouseWheel()
	if wheel == 0 then return end
	local C, lim = E.CRUISE, veh.audioCruise
	local mph = wheel > 0 and (math.floor(lim / C.step + 1e-3) + 1) * C.step
		or (math.ceil(lim / C.step - 1e-3) - 1) * C.step
	mph = clampLimit(veh, mph)
	if mph ~= lim then veh.audioCruise = mph; veh:SetNW2Float("audio_cruise", mph) end
end)

hook.Add("Tick", "audio_engine_cruise", function()
	local C, dt = E.CRUISE, engine.TickInterval()
	for veh in pairs(E.TrackedVehicles or {}) do
		if IsValid(veh) and veh.audioCruise then
			local drv = veh:GetDriver()
			if not cvOn:GetBool() or not IsValid(drv) or not running(veh) then
				setLimit(veh, nil)
			else
				local phys = veh:GetPhysicsObject()
				local v = speedMph(veh)
				local over = v - veh.audioCruise
				-- over the limit: power off and brake, harder the further over
				if over > C.brakeOver then
					veh.audioLimBrake = true
				elseif veh.audioLimBrake and over < C.brakeOff then
					veh.audioLimBrake, veh.audioCruiseI = false, C.reentry
				end
				-- W held near the limit: the power trim holds it (sv_handling.lua)
				local hold = drv:KeyDown(IN_FORWARD) and over > -C.band
				if hold and not veh.audioLimHold and not veh.audioLimBrake then veh.audioCruiseI = 1 end
				veh.audioLimHold = hold
				if veh.audioLimBrake and IsValid(phys) then
					local decel = math.min(C.brakeMax, C.brakeBase + C.brakeGain * math.max(0, over - C.brakeOff))
					local vel = phys:GetVelocity()
					-- impulse: kg x in/s (velocities are inches/s)
					phys:ApplyForceCenter(-vel:GetNormalized() * phys:GetMass() * decel / 0.0254 * dt)
				end
				setState(veh, veh.audioLimBrake and 2 or hold and 1 or 0)
			end
		end
	end
end)

hook.Add("PlayerLeaveVehicle", "audio_engine_cruise", function(_, veh)
	if IsValid(veh) and veh.audioCruise then setLimit(veh, nil) end
end)
