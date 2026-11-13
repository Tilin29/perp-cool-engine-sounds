--[[
	Audio Engine - stability control (server)

	Works like a real car's stability control, but arcade-friendly. Every tick, for each driven
	registered car, it works out how fast the car SHOULD be rotating for the driver's steering keys
	(A/D) at this speed, and compares that with how fast it IS rotating:

	  * rotating more than asked (oversteer, a spin starting)  -> catches it. With the handbrake
	    held it allows a lot more, so handbrake drifts still work.
	  * rotating against the steering (a snap the other way)  -> helps stop the rotation
	  * rotating less than asked (pushing wide, understeer)    -> adds turn-in, up to turnShare of
	    the asked rotation; braking (locked front tyres plough on) up to brakeTurn, applied firmer
	  * last-resort guard: if the tail still slides out past the drift angle, it slows the
	    rotation down (it never turns a sliding car's travel: that launched it where the nose pointed)
	  * lateral grip: without the handbrake, extra tyre grip (gripAssist g) takes sideways speed
	    away at any slip angle; the forward speed is never touched, so it can't launch the car
	  * how much the car is sliding (0..1, vehicle.audioSlideAmount) goes to traction control
	    (sv_handling.lua), which takes power away: a strong car stepping out under throttle
	    keeps sliding as long as it has full power, whatever the yaw correction does
	  * slip limit: steering without the handbrake keeps the tail-out slip angle near slipMax
	    (the nose rotates no faster than the car's path), so fast corners turn instead of drift
	  * straight-line hold: throttle with no steering (and no handbrake/drift) keeps the car
	    on its heading at any speed, from a standstill, and any rotation cuts the power

	A drift starts with the handbrake and lasts as long as the car stays sideways (past
	driftHold degrees), handbrake held or not. While drifting the car may slide and rotate
	freely, counter-steering holds the angle instead of being fought, and only a real spin
	(past handbrakeAngle) is caught.

	It never reacts to the normal angle of a car going round a tight bend (the body naturally
	points a little across its path at low speed), only to the tail stepping OUT.
	It only acts on the ground, moving forward, above minSpeed.
]]

local AudioEngine = AUDIO_ENGINE

local stabilityConVar = CreateConVar("audio_engine_stability", "0", FCVAR_ARCHIVE + FCVAR_NOTIFY,
	"1 = stability control on registered cars")

local DEFAULTS = {
	steerSlow = 35,        -- front wheel angle at full lock, parking speeds (degrees)
	steerFast = 10,        -- ... at speed (100+ km/h)
	grip = 1.5,            -- how many g of cornering the car may pull before it counts as sliding (arcade)
	yawAllow = 10,         -- deg/s of extra rotation allowed before it steps in
	driftYaw = 70,         -- ... with the handbrake held (drifting)
	overDamp = 9,          -- how firmly it catches oversteer (per second)
	turnHelp = 4,          -- how much turn-in it adds when the car pushes wide (per second)...
	-- ...up to this share of the rotation the steering asks for. Off (0): with the throttle held it
	-- pushed the tyres to their side limit, leaving no grip to drive, and turns bled 3-4 mph/s
	turnShare = 0,
	-- braking (S held, rolling forward): the front tyres lock and the car ploughs straight on.
	-- It still turns, less: turn-in help up to brakeTurn of the asked rotation, applied firmer
	brakeTurn = 0.6,
	brakeHelp = 6,         -- per second
	driftAngle = 20,       -- last-resort guard: tail-out slide angle (degrees)
	handbrakeAngle = 70,   -- ... while drifting
	driftHold = 8,         -- a drift lasts while the car slides at least this many degrees
	-- (normal fast cornering has a few degrees of tail out: below slideFrom it keeps its power)
	slideFrom = 8,         -- tail-out slide angle (degrees) where it starts to count as sliding...
	slideFull = 16,        -- ...fully sliding here (power cut hardest)
	minSpeed = 8,          -- km/h
	-- slip limit (steering without the handbrake): no drifting out of fast corners
	slipMax = 4,           -- tail-out slip angle (degrees) it lets the car reach
	slipReturn = 4,        -- deg/s of nose turned back per degree beyond it
	slipDamp = 12,         -- how firmly (per second)
	-- extra sideways tyre grip without the handbrake (g): stops slides, turns fast cars. Off (0) by
	-- choice with turnShare: the cars drive better on their own tyres (it also scrubbed speed in turns)
	gripAssist = 0,
	-- straight-line hold (throttle with no steering): no spin-outs when accelerating
	straightDamp = 20,     -- how firmly it stops rotation (per second)
	straightHold = 3,      -- deg/s of turn back per degree off the held heading
	straightMax = 45,      -- further off than this (a crash) and it holds the new heading instead
	-- taken over from a turn (still rotating): it only damps the rotation, following the car's
	-- heading, until the rotation is under holdSettled (at most holdGrace), then holds that line
	holdGrace = 1,         -- s
	holdSettled = 3,       -- deg/s
}
AudioEngine.STABILITY_DEFAULTS = DEFAULTS

local deg, rad, atan2, abs, min, max, sqrt, tan = math.deg, math.rad, math.atan2, math.abs, math.min, math.max, math.sqrt, math.tan
local function clamp(value, low, high) if value < low then return low elseif value > high then return high end return value end
local function sign(value) return value >= 0 and 1 or -1 end

-- nose direction and wheelbase, from the wheel attachments (cached per model)
local geometryCache = {}
local function geometry(vehicle)
	local model = vehicle:GetModel()
	if geometryCache[model] then return geometryCache[model] end
	local wheelPositions = {}
	for _, attachmentName in ipairs({ "wheel_fl", "wheel_fr", "wheel_rl", "wheel_rr" }) do
		local attachmentId = vehicle:LookupAttachment(attachmentName)
		local attachment = attachmentId and attachmentId > 0 and vehicle:GetAttachment(attachmentId)
		if not attachment then return { forward = Vector(0, 1, 0), wheelbase = 2.6 } end
		wheelPositions[attachmentName] = vehicle:WorldToLocal(attachment.Pos)
	end
	local forward = ((wheelPositions.wheel_fl + wheelPositions.wheel_fr) - (wheelPositions.wheel_rl + wheelPositions.wheel_rr)) * 0.5
	forward.z = 0
	local length = forward:Length()
	if length < 1 then return { forward = Vector(0, 1, 0), wheelbase = 2.6 } end
	local wheelbase = clamp(length * 0.0254, 1.8, 4.5)
	forward:Normalize()
	geometryCache[model] = { forward = forward, wheelbase = wheelbase }
	return geometryCache[model]
end
AudioEngine.CarGeometry = geometry

-- is the car on the ground? (a short trace down from its floor)
local function onGround(vehicle)
	local upDirection = vehicle:GetUp()
	local start = vehicle:GetPos() + upDirection * 12
	local trace = util.TraceLine({ start = start, endpos = start - upDirection * 40, filter = vehicle, mask = MASK_SOLID })
	return trace.Hit
end

-- extra tyre grip: takes up to `g` of sideways speed (vr, inches/s along `right`) away per
-- second, like a tyre's side force. The forward speed is never touched, so it can't launch a
-- sideways car where its nose points (turning the whole velocity toward the nose did that)
local function lateralGrip(physics, right, sidewaysSpeed, grip, deltaTime)
	local removed = min(abs(sidewaysSpeed), grip * 9.81 / 0.0254 * deltaTime)
	if removed > 0 then physics:AddVelocity(right * (-sign(sidewaysSpeed) * removed)) end
end

local function assist(vehicle, carConfig, deltaTime)
	local driver = vehicle:GetDriver()
	if not IsValid(driver) then return end
	local physics = vehicle:GetPhysicsObject()
	if not IsValid(physics) or not physics:IsMotionEnabled() then return end
	if not onGround(vehicle) then return end

	local settings = carConfig.stability or {}
	local function setting(key) local value = settings[key]; if value == nil then value = DEFAULTS[key] end return value end

	local carGeometry = geometry(vehicle)
	local upDirection = vehicle:GetUp()
	local forward = vehicle:LocalToWorld(carGeometry.forward) - vehicle:GetPos()
	forward = forward - upDirection * forward:Dot(upDirection)
	forward:Normalize()
	local right = forward:Cross(upDirection)

	local velocity = physics:GetVelocity()
	local forwardSpeed, sidewaysSpeed = velocity:Dot(forward), velocity:Dot(right)
	local speedInches = sqrt(forwardSpeed * forwardSpeed + sidewaysSpeed * sidewaysSpeed)            -- inches/s
	local speed = speedInches * 0.0254                         -- m/s
	local speedKmh = speed * 3.6
	local minSpeed = setting("minSpeed")

	-- the driver's steering, smoothed like the wheels turn (left = +)
	local steerInput = (driver:KeyDown(IN_MOVELEFT) and 1 or 0) - (driver:KeyDown(IN_MOVERIGHT) and 1 or 0)
	local smoothedSteer = vehicle.audioSteerInput or 0
	smoothedSteer = smoothedSteer + clamp(steerInput - smoothedSteer, -deltaTime * 4, deltaTime * 4)
	vehicle.audioSteerInput = smoothedSteer

	vehicle.audioSlideAmount, vehicle.audioSlideTime, vehicle.audioOverRotating = 0, CurTime(), true

	-- straight-line hold: throttle, no steering, no handbrake or drift -> the car keeps the
	-- heading it had when the keys were let go, from a standstill up (launch spins start below
	-- minSpeed). Any rotation counts as sliding, so traction control cuts the power too
	if steerInput == 0 and abs(smoothedSteer) < 0.05 and driver:KeyDown(IN_FORWARD) and not driver:KeyDown(IN_JUMP)
		and not vehicle.audioDrift and forwardSpeed > -40 then
		local heading = deg(atan2(forward.y, forward.x))         -- left = +, like the yaw rate
		local headingError = vehicle.audioHeldHeading and math.NormalizeAngle(vehicle.audioHeldHeading - heading) or 0
		local yawRate = physics:GetAngleVelocity().z
		if not vehicle.audioHeldHeading or abs(headingError) > setting("straightMax") then
			vehicle.audioHeldHeading, headingError = heading, 0           -- (re)captured: after a crash or a spin it holds the new line
			vehicle.audioHoldGraceUntil = abs(yawRate) > setting("holdSettled") and CurTime() + setting("holdGrace") or nil
		end
		-- still rotating out of a turn: holding the line it had when the keys were let go turned it
		-- back against its tyres for seconds (read as a slide, power cut). Follow it until it settles
		local settling = vehicle.audioHoldGraceUntil and CurTime() < vehicle.audioHoldGraceUntil and abs(yawRate) > setting("holdSettled")
		if settling then
			vehicle.audioHeldHeading, headingError = heading, 0
		else
			vehicle.audioHoldGraceUntil = nil
		end
		local targetYawRate = clamp(headingError * setting("straightHold"), -30, 30)
		physics:AddAngleVelocity(Vector(0, 0, (targetYawRate - yawRate) * min(1, setting("straightDamp") * deltaTime)))
		local slipAngle = speed > 2 and abs(deg(atan2(sidewaysSpeed, forwardSpeed))) or 0
		lateralGrip(physics, right, sidewaysSpeed, setting("gripAssist") * clamp((speedKmh - minSpeed) / 12, 0, 1), deltaTime)
		local yawSlide = settling and 0 or (abs(yawRate - targetYawRate) - 4) / 15
		vehicle.audioSlideAmount = clamp(max(yawSlide, (slipAngle - 3) / 10), 0, 1)
		vehicle.audioLogYawError, vehicle.audioLogSlipAngle = yawRate - targetYawRate, slipAngle
		return
	end
	vehicle.audioHeldHeading, vehicle.audioLogYawError, vehicle.audioLogSlipAngle = nil, nil, nil

	if speedKmh < minSpeed or forwardSpeed <= 0 then return end
	local fade = clamp((speedKmh - minSpeed) / 12, 0, 1)
	local slipAngle = deg(atan2(sidewaysSpeed, forwardSpeed))                      -- + = nose rotated left of the travel
	-- drifting: started with the handbrake, held while the car stays sideways
	if driver:KeyDown(IN_JUMP) then vehicle.audioDrift = true
	elseif abs(slipAngle) < setting("driftHold") then vehicle.audioDrift = false end
	local handbrake = vehicle.audioDrift

	-- rotation the driver is asking for (deg/s, left = +): what the steering angle would give
	-- at this speed, capped by what the tyres can actually hold
	-- (sv_handling may have widened the car's lock at speed: vehicle.audioFastSteerScale)
	local fastLock = setting("steerFast") * (vehicle.audioFastSteerScale or 1)
	local lock = rad(setting("steerSlow") + (fastLock - setting("steerSlow")) * clamp((speedKmh - 20) / 80, 0, 1))
	local turnSpeed = max(speed, 2)
	local kinematicYawRate = deg(turnSpeed * tan(lock) / carGeometry.wheelbase)
	local gripYawRate = deg(setting("grip") * 9.81 / turnSpeed)
	local askedYawRate = smoothedSteer * min(kinematicYawRate, gripYawRate)

	local yawRate = physics:GetAngleVelocity().z                -- deg/s, left = +
	local yawCorrection = 0
	local absSlipAngle = abs(slipAngle)
	local tailOut = slipAngle * yawRate > 0                       -- sliding the way it rotates (oversteer)

	-- how fast the slip angle changes (smoothed; a stale reading from an earlier pass is dropped)
	local now = CurTime()
	local slipAngleChange = vehicle.audioSlipAngle and now - vehicle.audioSlipAngleTime < deltaTime * 2.5 and (slipAngle - vehicle.audioSlipAngle) / deltaTime or 0
	vehicle.audioSlipAngle, vehicle.audioSlipAngleTime = slipAngle, now
	vehicle.audioSlipAngleRate = (vehicle.audioSlipAngleRate or 0) + (slipAngleChange - (vehicle.audioSlipAngleRate or 0)) * min(1, 15 * deltaTime)

	local yawAllowance = handbrake and setting("driftYaw") or (setting("yawAllow") + 0.15 * abs(askedYawRate))
	local oversteerDamping = setting("overDamp")
	local braking = driver:KeyDown(IN_BACK) and not driver:KeyDown(IN_FORWARD)
	local turnInShare = braking and setting("brakeTurn") or setting("turnShare")

	if yawRate * askedYawRate >= 0 then
		-- turning the way the driver steers: catch only the part beyond what was asked
		local excess = abs(yawRate) - abs(askedYawRate) - yawAllowance
		if excess > 0 then
			yawCorrection = yawCorrection - sign(yawRate) * excess * min(1, oversteerDamping * deltaTime)
		elseif not handbrake and abs(askedYawRate) > 4 and speed > 5 and abs(yawRate) < abs(askedYawRate) * turnInShare
			and not (tailOut and absSlipAngle > setting("slipMax") * 0.5) then
			-- pushing wide (or ploughing on under braking): help it turn in
			local turnInRate = braking and setting("brakeHelp") or setting("turnHelp")
			yawCorrection = yawCorrection + sign(askedYawRate) * (abs(askedYawRate) * turnInShare - abs(yawRate)) * min(1, turnInRate * deltaTime)
		end
	elseif not handbrake then
		-- rotating against the steering (a snap the other way): stop it. Not while drifting:
		-- there counter-steering is how the driver holds the angle
		local excess = abs(yawRate) - yawAllowance * 0.5
		if excess > 0 then yawCorrection = yawCorrection - sign(yawRate) * excess * min(1, oversteerDamping * deltaTime) end
	end

	-- slip limit (no handbrake): steering at speed turns, it doesn't drift. Past slipMax the nose
	-- may only rotate as fast as the car's path does (yaw - slipAngleChange/dt), less a little to bring the
	-- slip angle back. It only ever takes rotation away (the travel direction is never touched)
	if not handbrake and tailOut and absSlipAngle > setting("slipMax") then
		local returnRate = min(60, (absSlipAngle - setting("slipMax")) * setting("slipReturn"))
		local slipCorrection = -vehicle.audioSlipAngleRate - sign(slipAngle) * returnRate
		if slipCorrection * slipAngle < 0 then yawCorrection = yawCorrection + slipCorrection * min(1, setting("slipDamp") * deltaTime) end
	end

	-- lateral grip (no handbrake): extra tyre grip that takes sideways speed away
	if not handbrake then lateralGrip(physics, right, sidewaysSpeed, setting("gripAssist") * fade, deltaTime) end

	-- last-resort guard: tail stepping OUT (slide in the same direction as the rotation)
	local slideLimit = handbrake and setting("handbrakeAngle") or setting("driftAngle")
	if tailOut and absSlipAngle > slideLimit * 0.6 then
		local guardStrength = clamp((absSlipAngle - slideLimit * 0.6) / (slideLimit * 0.4), 0, 1)
		if absSlipAngle > slideLimit then
			guardStrength = 1 + (absSlipAngle - slideLimit) / 10
			yawCorrection = yawCorrection - sign(slipAngle) * min(90, (absSlipAngle - slideLimit) * 4) * deltaTime * 4    -- ease the nose back
		end
		yawCorrection = yawCorrection - yawRate * min(1, oversteerDamping * 0.6 * guardStrength * deltaTime)
	end

	-- how much it's sliding, for the power cut: the tail out past slideFrom, or rotating well
	-- beyond what the steering asks. Not in a drift: there the driver wants the power.
	-- audioOverRotating: over-rotating, cut hard; only the tail out (the car still turns as asked) is a
	-- corner taken fast, and it keeps enough power to pull through it (sv_handling slideTurnFloor)
	-- the keys just let go, the steering still coming back (until the straight-line hold takes
	-- over): the turn's own rotation isn't over-rotating, it read as a spin and dipped the power
	if not handbrake then
		local returning = steerInput == 0
		local overRotation = returning and 0
			or yawRate * askedYawRate >= 0 and (abs(yawRate) - abs(askedYawRate) - yawAllowance) / 20 or (abs(yawRate) - yawAllowance * 0.5) / 20
		local tailOutSlide = slipAngle * yawRate > 0 and (absSlipAngle - setting("slideFrom")) / (setting("slideFull") - setting("slideFrom")) or 0
		vehicle.audioSlideAmount = clamp(max(overRotation, tailOutSlide), 0, 1) * fade
		vehicle.audioOverRotating = overRotation > 0
	end
	vehicle.audioLogYawError, vehicle.audioLogSlipAngle = yawRate - askedYawRate, slipAngle

	if yawCorrection ~= 0 then
		physics:AddAngleVelocity(Vector(0, 0, yawCorrection * fade))
	end
end

hook.Add("Tick", "audio_engine_stability", function()
	if not stabilityConVar:GetBool() then return end
	local deltaTime = engine.TickInterval()
	for vehicle in pairs(AudioEngine.TrackedVehicles or {}) do
		if IsValid(vehicle) then
			local carConfig = AudioEngine.GetCarConfig(vehicle)
			-- not on spiked tyres (sv_handling.lua): a stinger is meant to make the car hard to drive
			if carConfig and carConfig.stability ~= false and not vehicle.audioSpiked then assist(vehicle, carConfig, deltaTime) end
		end
	end
end)
