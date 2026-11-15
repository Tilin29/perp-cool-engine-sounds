--[[
	Audio Engine - handling (server)

	Runs once on every registered car as it spawns, before its physics are captured as the
	base for engine tuning (sv_engine.lua):

	1. PERP physics on the test script. Off the PERP server, PERP's vehicle scripts aren't mounted
	   and the spawn menu falls back to scripts/vehicles/audio_engine/test_car.txt (sh_perp.lua).
	   The car's own PERP base script values (sv_perp_physics.lua: horsepower, top speed, gearing,
	   mass, steering, suspension, torque and brake split, manual gearbox) are then put on it, so it accelerates,
	   tops out and handles like on the server. They're applied as ratios to test_car.txt's own
	   values, so Source's internal units never matter.
	2. Anti-spin setup (audio_engine_handling 1): brakes biased to the front (a locking rear
	   spins the car), at most a 20% power cut while steering at speed, a slightly lower centre of mass, at
	   least normal grip, and more steering lock at speed. Relative changes only.
	3. Stability assist (sv_stability.lua) for the PERP cars, with each car's own steering angles.
	4. Launch traction control (audio_engine_traction 1). Source turns horsepower into wheel torque
	   that is biggest at low wheel speed, so a strong, light car (Veyron 490 hp, SLR 420 hp at
	   1700 kg) just spins its tyres off the line, barely moving, then hooks up and rockets once
	   it's fast. While the driven wheels turn faster than the car moves, the horsepower is
	   trimmed until they grip, and given back as they do. Off the line it may cut to 1/4 of the
	   power; from ~36 mph to no less than 60%, so it catches slides without holding the car back.
	   When the car slides (tail out or over-rotating, from sv_stability.lua; not in a handbrake
	   drift) it cuts the power quickly, down to 20% at any speed, until it straightens up.
	5. High-speed steering: the wider lock of step 2 tightens to 0.9 between ~45 and
	   90 mph (AudioEngine.HIGH_SPEED_STEER), so the car turns well at town speeds and holds its speed in fast turns.

	A car on a spiked/ tier script (tyres shot by a stinger) gets none of it: it's meant to be
	hard to drive.
]]

local AudioEngine = AUDIO_ENGINE

local handlingConVar = CreateConVar("audio_engine_handling", "0", FCVAR_ARCHIVE,
	"1 = anti-spin setup on cars with the procedural engine (front brake bias, less power while steering at speed, lower centre of mass, "
		.. "wider lock at speed); 0 = the vehicle script's own handling. Applies at once")

---------------------------------------------------------------------------
-- setting vehicle params
---------------------------------------------------------------------------
local HU_PER_MPH = 17.6   -- GetVehicleParams speeds are inches/s; SetVehicleParams takes mph
local SPEED_KEYS = { "maxSpeed", "maxRevSpeed", "boostMaxSpeed" }
AudioEngine.HU_PER_MPH = HU_PER_MPH

-- p is a table as GetVehicleParams returns it (speeds in its units). Sets it on the car, giving
-- SetVehicleParams the speeds it wants, and checks the unit took.
function AudioEngine.SetParams(vehicle, params)
	params = table.Copy(params)
	for _, speedKey in ipairs(SPEED_KEYS) do
		if params.engine and params.engine[speedKey] then params.engine[speedKey] = params.engine[speedKey] / HU_PER_MPH end
	end
	if not pcall(vehicle.SetVehicleParams, vehicle, params) then return false end
	-- self-check the speed unit: if the engine took our mph as inches/s, set it again scaled
	local succeeded, applied = pcall(vehicle.GetVehicleParams, vehicle)
	if succeeded and istable(applied) and applied.engine and applied.engine.maxSpeed and params.engine and params.engine.maxSpeed then
		local expectedSpeed = params.engine.maxSpeed * HU_PER_MPH
		if math.abs(applied.engine.maxSpeed - params.engine.maxSpeed) < math.abs(applied.engine.maxSpeed - expectedSpeed) then
			for _, speedKey in ipairs(SPEED_KEYS) do
				if params.engine[speedKey] then params.engine[speedKey] = params.engine[speedKey] * HU_PER_MPH end
			end
			pcall(vehicle.SetVehicleParams, vehicle, params)
		end
	end
	return true
end

---------------------------------------------------------------------------
-- which script the car spawned with
---------------------------------------------------------------------------
AudioEngine.TEST_SCRIPT = "scripts/vehicles/audio_engine/test_car.txt"

function AudioEngine.VehicleScriptOf(vehicle)
	local keyValues = vehicle:GetKeyValues() or {}
	local script = keyValues.vehiclescript or keyValues.VehicleScript or keyValues.vehicleScript
	if (not script or script == "") and istable(vehicle.VehicleTable) and istable(vehicle.VehicleTable.KeyValues) then
		script = vehicle.VehicleTable.KeyValues.vehiclescript
	end
	if not isstring(script) or script == "" then return nil end
	return (string.lower(script):gsub("\\", "/"))
end

---------------------------------------------------------------------------
-- 1. PERP physics on a car that's on the test script
---------------------------------------------------------------------------
-- test_car.txt's values (keep in step with the file): the PERP value is applied as
-- current * perp / test, so whatever unit Source keeps a field in, the result is right
local TEST = {
	engine = { horsepower = 320, maxRPM = 6000, maxSpeed = 125, maxRevSpeed = 20, shiftUpRPM = 5600, shiftDownRPM = 2600 },
	body = { massOverride = 1600, maxAngularVelocity = 200, massCenterZ = -5 },
	steering = { degreesSlow = 38, degreesFast = 14, degreesBoost = 10, powerSlideAccel = 150 },
	axles = {
		{ suspension_springConstant = 110, suspension_springDamping = 0.9, suspension_springDampingCompression = 5.5,
		  suspension_stabilizerConstant = 120, suspension_maxBodyForce = 30, wheels_mass = 170 },
		{ suspension_springConstant = 105, suspension_springDamping = 0.9, suspension_springDampingCompression = 5.5,
		  suspension_stabilizerConstant = 110, suspension_maxBodyForce = 30, wheels_mass = 170 },
	},
}

-- scale a field by perp / test, if the car has it and both values are usable
local function scaleByRatio(section, key, perp, test)
	if not (section and section[key] and perp and test and test ~= 0) then return end
	section[key] = section[key] * perp / test
end
-- a unitless field (fractions, ratios, multipliers): set it straight
local function setValue(section, key, value)
	if section and section[key] ~= nil and value ~= nil then section[key] = value end
end

local function applyPerpPhysics(params, perpPhysics)
	local engineParams, bodyParams, steeringParams = params.engine, params.body, params.steering
	local perpEngine, perpBody, perpSteering = perpPhysics.engine or {}, perpPhysics.body or {}, perpPhysics.steering or {}
	scaleByRatio(engineParams, "horsepower", perpEngine.horsepower, TEST.engine.horsepower)
	scaleByRatio(engineParams, "maxRPM", perpEngine.maxrpm, TEST.engine.maxRPM)
	scaleByRatio(engineParams, "maxSpeed", perpEngine.maxspeed, TEST.engine.maxSpeed)
	scaleByRatio(engineParams, "maxRevSpeed", perpEngine.maxreversespeed, TEST.engine.maxRevSpeed)
	scaleByRatio(engineParams, "shiftUpRPM", perpEngine.shiftuprpm, TEST.engine.shiftUpRPM)
	scaleByRatio(engineParams, "shiftDownRPM", perpEngine.shiftdownrpm, TEST.engine.shiftDownRPM)
	setValue(engineParams, "axleRatio", perpEngine.axleratio)
	-- PERP's scripts are manual (autotransmission 0): Source keeps one ratio up to top speed.
	-- The test script is automatic, and its box sat in top gear (slow) until the revs passed
	-- maxRPM, then dropped into 1st and rocketed: the Veyron crawled to 70 mph, then flew
	if perpEngine.autotransmission ~= nil then setValue(engineParams, "isAutoTransmission", perpEngine.autotransmission ~= 0) end
	if engineParams and istable(engineParams.gearRatio) and perpEngine.gears and #perpEngine.gears > 0 then
		engineParams.gearRatio = table.Copy(perpEngine.gears)
		setValue(engineParams, "gearCount", #perpEngine.gears)
	end

	scaleByRatio(bodyParams, "massOverride", perpBody.massoverride, TEST.body.massOverride)
	scaleByRatio(bodyParams, "maxAngularVelocity", perpBody.maxangularvelocity, TEST.body.maxAngularVelocity)
	setValue(bodyParams, "addGravity", perpBody.addgravity)
	setValue(bodyParams, "counterTorqueFactor", perpBody.countertorquefactor)
	if bodyParams and isvector(bodyParams.massCenterOverride) and perpBody.masscenter and bodyParams.massCenterOverride.z ~= 0 then
		-- the test script's centre is (0, 0, -5): that tells the unit
		local centreScale = bodyParams.massCenterOverride.z / TEST.body.massCenterZ
		bodyParams.massCenterOverride = Vector(perpBody.masscenter[1] * centreScale, perpBody.masscenter[2] * centreScale, perpBody.masscenter[3] * centreScale)
	end

	scaleByRatio(steeringParams, "degreesSlow", perpSteering.degreesslow, TEST.steering.degreesSlow)
	scaleByRatio(steeringParams, "degreesFast", perpSteering.degreesfast, TEST.steering.degreesFast)
	scaleByRatio(steeringParams, "degreesBoost", perpSteering.degreesboost, TEST.steering.degreesBoost)
	scaleByRatio(steeringParams, "powerSlideAccel", perpSteering.powerslideaccel, TEST.steering.powerSlideAccel)
	setValue(steeringParams, "turnThrottleReduceSlow", perpSteering.turnthrottlereduceslow)
	setValue(steeringParams, "turnThrottleReduceFast", perpSteering.turnthrottlereducefast)

	for axleIndex, axle in ipairs(params.axles or {}) do
		local perpAxle, testAxle = perpPhysics.axles and perpPhysics.axles[axleIndex], TEST.axles[axleIndex]
		if perpAxle and testAxle then
			scaleByRatio(axle, "suspension_springConstant", perpAxle.springconstant, testAxle.suspension_springConstant)
			scaleByRatio(axle, "suspension_springDamping", perpAxle.springdamping, testAxle.suspension_springDamping)
			scaleByRatio(axle, "suspension_springDampingCompression", perpAxle.springdampingcompression, testAxle.suspension_springDampingCompression)
			scaleByRatio(axle, "suspension_stabilizerConstant", perpAxle.stabilizerconstant, testAxle.suspension_stabilizerConstant)
			scaleByRatio(axle, "suspension_maxBodyForce", perpAxle.maxbodyforce, testAxle.suspension_maxBodyForce)
			scaleByRatio(axle, "wheels_mass", perpAxle.mass, testAxle.wheels_mass)
			setValue(axle, "torqueFactor", perpAxle.torquefactor)
			setValue(axle, "brakeFactor", perpAxle.brakefactor)
		end
	end
end

---------------------------------------------------------------------------
-- 2. anti-spin setup (relative changes, any car, any script)
---------------------------------------------------------------------------
AudioEngine.ANTI_SPIN = {
	frontBrake = 0.6,       -- at least this share of the braking on the front axle
	-- at most this much power cut while steering at speed (the scripts cut 0.5-0.9: a fast turn
	-- lost its speed and revs; spins are caught by sv_stability and the traction control's slide cut)
	throttleReduceFast = 0.2,
	powerSlide = 1.0,       -- handbrake slide push x this (1 = the script's own: lower kills drifts)
	minGravity = 1.0,       -- at least normal grip
	lowerCentre = 0.25,     -- lower the centre of mass by this many wheel radii
	steerFast = 1.5,        -- steering angle at speed x this (the scripts' 8-13 degrees turn too little; 1.3 still did)
}

local function applyAntiSpin(params)
	local antiSpinConfig = AudioEngine.ANTI_SPIN
	local frontAxle, rearAxle = params.axles and params.axles[1], params.axles and params.axles[2]
	if frontAxle and rearAxle and frontAxle.brakeFactor and rearAxle.brakeFactor then
		local brakeSum = frontAxle.brakeFactor + rearAxle.brakeFactor
		if brakeSum > 0 and frontAxle.brakeFactor / brakeSum < antiSpinConfig.frontBrake then
			frontAxle.brakeFactor, rearAxle.brakeFactor = brakeSum * antiSpinConfig.frontBrake, brakeSum * (1 - antiSpinConfig.frontBrake)
		end
	end
	local steeringParams, bodyParams = params.steering, params.body
	if steeringParams and steeringParams.turnThrottleReduceFast then
		steeringParams.turnThrottleReduceFast = math.min(steeringParams.turnThrottleReduceFast, antiSpinConfig.throttleReduceFast)
	end
	if steeringParams and steeringParams.powerSlideAccel then
		steeringParams.powerSlideAccel = steeringParams.powerSlideAccel * antiSpinConfig.powerSlide
	end
	if steeringParams and steeringParams.degreesFast then steeringParams.degreesFast = steeringParams.degreesFast * antiSpinConfig.steerFast end
	if bodyParams and bodyParams.addGravity then bodyParams.addGravity = math.max(bodyParams.addGravity, antiSpinConfig.minGravity) end
	-- only when the script set a centre (a zero vector means "none": moving it would shift the car)
	if bodyParams and isvector(bodyParams.massCenterOverride) and bodyParams.massCenterOverride:LengthSqr() > 0 and frontAxle and frontAxle.wheels_radius then
		bodyParams.massCenterOverride = bodyParams.massCenterOverride - Vector(0, 0, frontAxle.wheels_radius * antiSpinConfig.lowerCentre)
	end
end

---------------------------------------------------------------------------
-- on spawn
---------------------------------------------------------------------------
function AudioEngine.PrepareHandling(vehicle)
	if vehicle.audioPrepared then return end
	vehicle.audioPrepared = true
	local carConfig = AudioEngine.GetCarConfig(vehicle)
	if not carConfig then return end
	local script = AudioEngine.VehicleScriptOf(vehicle)
	vehicle.audioScript = script
	vehicle.audioSpiked = script ~= nil and script:find("/spiked/", 1, true) ~= nil

	local succeeded, params = pcall(vehicle.GetVehicleParams, vehicle)
	if not succeeded or not istable(params) or not istable(params.engine) then return end
	if vehicle.audioSpiked then
		vehicle.audioScriptParams = table.Copy(params)
		return
	end
	local changed = false
	-- the script the spawn entry asked for (a job variant's own), else the car's base script
	local wantedScript = istable(vehicle.VehicleTable) and vehicle.VehicleTable.AudioPerpScript or carConfig.script
	local perpPhysics = wantedScript and AudioEngine.PERP_PHYSICS and (AudioEngine.PERP_PHYSICS[wantedScript] or AudioEngine.PERP_PHYSICS[carConfig.script])
	if perpPhysics and script == AudioEngine.TEST_SCRIPT then
		applyPerpPhysics(params, perpPhysics)
		vehicle.audioPerpPhysics = true
		changed = true
	end
	-- the car's handling before the anti-spin setup: AudioEngine.RebaseHandling starts from it
	vehicle.audioScriptParams = table.Copy(params)
	if handlingConVar:GetBool() then
		applyAntiSpin(params)
		vehicle.audioAntiSpin = true
		vehicle.audioFastSteerScale = AudioEngine.ANTI_SPIN.steerFast   -- sv_stability expects the wider lock
		changed = true
	end
	if changed then
		AudioEngine.SetParams(vehicle, params)
		-- the chassis mass, in case the params don't move the physics object
		local physics = vehicle:GetPhysicsObject()
		if vehicle.audioPerpPhysics and IsValid(physics) and perpPhysics.body and perpPhysics.body.massoverride then
			physics:SetMass(perpPhysics.body.massoverride)
		end
	end
end

--[[
	Rebuild the car's base params (what sv_engine's AudioEngine.ApplyPerformance starts from) from its script
	handling (vehicle.audioScriptParams, or `scriptParams` to replace it, e.g. edited live by the debug
	module), with the anti-spin setup only while audio_engine_handling is on. Switching that convar
	runs this on every car, so it applies at once (it used to take effect on cars spawned after).
]]
function AudioEngine.RebaseHandling(vehicle, scriptParams)
	if scriptParams then vehicle.audioScriptParams = table.Copy(scriptParams) end
	local savedParams = vehicle.audioScriptParams
	if not savedParams then return false end
	local params = table.Copy(savedParams)
	if handlingConVar:GetBool() and not vehicle.audioSpiked then
		applyAntiSpin(params)
		vehicle.audioAntiSpin = true
		vehicle.audioFastSteerScale = AudioEngine.ANTI_SPIN.steerFast * (vehicle.audioSteerLockScale or 1)
	else
		-- the lock at speed (traction tick) goes with the anti-spin setup
		vehicle.audioAntiSpin, vehicle.audioFastSteerScale, vehicle.audioSteerLockScale, vehicle.audioSteerLockSent = nil, nil, nil, nil
	end
	vehicle.audioBase = params
	if AudioEngine.RefreshCarStats then AudioEngine.RefreshCarStats(vehicle, params) end
	if AudioEngine.ApplyPerformance then AudioEngine.ApplyPerformance(vehicle, AudioEngine.DecodeProfile(vehicle:GetNW2String("audio_prof", ""))) end
	return true
end

cvars.AddChangeCallback("audio_engine_handling", function()
	for vehicle in pairs(AudioEngine.TrackedVehicles or {}) do
		if IsValid(vehicle) then AudioEngine.RebaseHandling(vehicle) end
	end
end, "audio_engine_rebase")

---------------------------------------------------------------------------
-- 3. stability assist for the PERP cars, with their own steering angles
---------------------------------------------------------------------------
for _, carConfig in pairs(AudioEngine.Cars) do
	local perpPhysics = carConfig.perp and carConfig.script and AudioEngine.PERP_PHYSICS and AudioEngine.PERP_PHYSICS[carConfig.script]
	if perpPhysics and carConfig.stability == nil and perpPhysics.steering and perpPhysics.steering.degreesslow then
		carConfig.stability = {
			steerSlow = perpPhysics.steering.degreesslow,
			steerFast = perpPhysics.steering.degreesfast or 12,
		}
	end
end

---------------------------------------------------------------------------
-- 4. launch traction control
---------------------------------------------------------------------------
local tractionConVar = CreateConVar("audio_engine_traction", "0", FCVAR_ARCHIVE,
	"1 = traction control: less power while the driven wheels spin (strong cars launch instead of spinning)")

AudioEngine.TRACTION = {
	slip = 0.25,      -- wheel surface speed this much above the car's speed counts as spinning
	minSpeed = 2,     -- m/s: below this the slip is measured against this speed
	-- it works at any speed, but how much it may take away shrinks from fadeFrom to fadeTo. (A
	-- hard cut-off at 40 m/s held a car whose wheels read as slipping at the floor all the way to
	-- ~85 mph, then gave it 4x the power at once; switching it off by fadeTo let them slide.)
	fadeFrom = 6,     -- m/s (~13 mph)
	fadeTo = 16,      -- m/s (~36 mph)
	floorFast = 0.6,  -- the least power it leaves from fadeTo up (wheelspin)
	-- sliding (sv_stability.lua's vehicle.audioSlideAmount: tail out or over-rotating, not in a drift):
	-- the wheel speeds can't show it, but cutting the power is what stops it
	slideCut = 4,     -- per second at full slide
	slideFloor = 0.2, -- it may take the power down to this while sliding, at any speed...
	slideTurnFloor = 0.6, -- ...but only to this when the car still turns as steered (tail out in a fast corner)
	-- a slide that lasts longer than this stops holding the power down (it comes back at `restore`)
	-- until the slide reading clears: the straight-line hold out of a turn read as sliding for
	-- seconds and kept a car at slideFloor until W was pressed again
	slideMaxTime = 1,
	cut = 2.5,        -- how fast it takes power away while spinning (per second)
	restore = 1.2,    -- ... and gives it back while gripping
	floor = 0.25,     -- never below this share of the power (at a standstill)
	step = 0.04,      -- only re-sends the params when the trim moved this much
}

-- steering lock at speed, x the (already widened) degreesFast: 1 up to fromMph, `scale` from toMph.
-- Tightens from town speeds on: a fast turn on the wide lock scrubbed off speed and revs
-- (11 deg script x 1.5 x 0.9 = ~14.9 deg at 90 mph; 1.3 x 0.65 by 80 mph, then 1.3 x 0.8, turned too little)
AudioEngine.HIGH_SPEED_STEER = { fromMph = 45, toMph = 90, scale = 0.9 }

local function highSpeedSteerScale(mph)
	local highSpeedSteer = AudioEngine.HIGH_SPEED_STEER
	local blend = math.Clamp((mph - highSpeedSteer.fromMph) / (highSpeedSteer.toMph - highSpeedSteer.fromMph), 0, 1)
	blend = blend * blend * (3 - 2 * blend)
	return 1 + (highSpeedSteer.scale - 1) * blend
end

--[[
	The scripts blend DegreesSlow (~38) into DegreesFast (~11) by 35 mph (FastCarSpeed), so at
	30 mph the wheels were nearly at the high-speed lock already. The lock we want instead fades
	from the slow lock to the (widened) fast one over AudioEngine.STEER_CURVE.toMph, (1 - mph/toMph)^power:
	the SL65 (38.5 / 16.5) gets ~28 deg at 30 mph and ~23 at 50 (was ~20 and ~16).
	Source keeps blending below blendMph, so degreesFast is set to what makes its blend land there.
	Returns the multiplier on the car's degreesFast (vehicle.audioSteerLockScale).
]]
AudioEngine.STEER_CURVE = { toMph = 90, power = 1.5, blendMph = 35 }

--[[
	...and never wider than the tyres can use: on a keyboard every turn is full lock, and past the
	angle that gives the most cornering the front tyres only scrub. At 60 mph the curve still had
	~20 deg: with W held turns slowed the cars at ~1 g. The lock is capped at the angle a turn of
	`g` needs at this speed and wheelbase, plus the tyres' `slip` angle (deg)
]]
AudioEngine.STEER_GRIP = { g = 1.5, slip = 6 }

local function gripLimitedLock(vehicle, mph)
	local geometry = AudioEngine.CarGeometry and AudioEngine.CarGeometry(vehicle)
	local wheelbase = geometry and geometry.wheelbase or 2.6
	local speed = math.max(mph / 2.23694, 1)
	local turnAngle = math.deg(math.atan(wheelbase * AudioEngine.STEER_GRIP.g * 9.81 / (speed * speed)))

	return turnAngle + AudioEngine.STEER_GRIP.slip
end

local function steerLockScale(vehicle, mph)
	local steering = vehicle.audioBase and vehicle.audioBase.steering
	local slowLock, fastLock = steering and steering.degreesSlow, steering and steering.degreesFast
	if not (slowLock and fastLock and fastLock > 0) then return highSpeedSteerScale(mph) end
	local steerCurve = AudioEngine.STEER_CURVE
	local curveShare = (1 - math.Clamp(mph / steerCurve.toMph, 0, 1)) ^ steerCurve.power
	local wantedLock = math.min((fastLock + (slowLock - fastLock) * curveShare) * highSpeedSteerScale(mph), gripLimitedLock(vehicle, mph))
	local blendShare = mph / steerCurve.blendMph
	local fastSetting = blendShare >= 1 and wantedLock or (blendShare > 0.05 and slowLock + (wantedLock - slowLock) / blendShare or fastLock)
	return math.Clamp(fastSetting / fastLock, 0.3, 4)
end

-- the fastest-turning driven wheel's surface speed (m/s), from the wheel physics objects
local function drivenWheelSpeed(vehicle)
	local base = vehicle.audioBase
	if not (base and base.axles) then return nil end
	local fastest
	for axle = 1, #base.axles do
		local axleParams = base.axles[axle]
		if (axleParams.torqueFactor or 0) > 0 and axleParams.wheels_radius then
			for side = 0, 1 do
				local wheel = vehicle:GetWheel((axle - 1) * 2 + side)
				if IsValid(wheel) then
					-- deg/s about the axle; the steering turn is small next to a spinning wheel
					local surfaceSpeed = math.rad(wheel:GetAngleVelocity():Length()) * axleParams.wheels_radius * 0.0254
					if not fastest or surfaceSpeed > fastest then fastest = surfaceSpeed end
				end
			end
		end
	end
	return fastest
end

local profileCache = setmetatable({}, { __mode = "k" })
local function profileOf(vehicle)
	local profileString = vehicle:GetNW2String("audio_prof", "")
	local cached = profileCache[vehicle]
	if cached and cached.s == profileString then return cached.p end
	local profile = AudioEngine.DecodeProfile(profileString)
	profileCache[vehicle] = { s = profileString, p = profile }
	return profile
end

-- traction control and the steering lock at speed: both change the car's params on the fly
hook.Add("Tick", "audio_engine_traction", function()
	local tractionOn = tractionConVar:GetBool()
	local traction, deltaTime = AudioEngine.TRACTION, engine.TickInterval()
	for vehicle in pairs(AudioEngine.TrackedVehicles or {}) do
		-- no driver and nothing left to put back (full power, no limiter): nothing to do. The
		-- steering lock is caught up on the first tick someone drives it
		local nothingToDo = IsValid(vehicle) and not IsValid(vehicle:GetDriver()) and (vehicle.audioTractionPowerSent or 1) == 1
			and vehicle.audioLimiterPowerSent == nil and not vehicle.audioSpeedLimit and not vehicle.audioParamsDirty
		if IsValid(vehicle) and not vehicle.audioSpiked and vehicle.audioBase and not nothingToDo then
			local physics = vehicle:GetPhysicsObject()
			local speed = IsValid(physics) and physics:GetVelocity():Length() * 0.0254 or 0
			-- steering: only on cars that got the wider lock (anti-spin setup)
			local steerLock = vehicle.audioAntiSpin and steerLockScale(vehicle, speed * 2.23694) or nil
			if steerLock and math.abs(steerLock - (vehicle.audioSteerLockSent or 1)) >= 0.03 then
				vehicle.audioSteerLockScale = steerLock   -- (not audioSteerInput: sv_stability keeps the A/D input there)
				vehicle.audioSteerLockSent = steerLock
				vehicle.audioFastSteerScale = AudioEngine.ANTI_SPIN.steerFast * steerLock   -- sv_stability follows the lock
				vehicle.audioParamsDirty = true
			end

			local tractionPower = vehicle.audioTractionPower or 1
			local targetPower = tractionPower
			local driver = vehicle:GetDriver()
			-- the lowest trim allowed at this speed: T.floor at a standstill, T.floorFast from fadeTo
			local fade = math.Clamp((speed - traction.fadeFrom) / (traction.fadeTo - traction.fadeFrom), 0, 1)
			local powerFloor = traction.floor + (traction.floorFast - traction.floor) * fade * fade * (3 - 2 * fade)
			if tractionOn and IsValid(driver) and IsValid(physics) and driver:KeyDown(IN_FORWARD) then
				-- (only a fresh reading: with the stability assist off nothing updates it)
				local slideAmount = CurTime() - (vehicle.audioSlideTime or 0) < 0.2 and vehicle.audioSlideAmount or 0
				local wheelSpeed = drivenWheelSpeed(vehicle)
				local wheelSlip = wheelSpeed and (wheelSpeed - speed) / math.max(speed, traction.minSpeed) or 0
				vehicle.audioWheelSlip = wheelSlip
				if slideAmount > 0.05 then
					vehicle.audioSlideSince = vehicle.audioSlideSince or CurTime()
				else
					vehicle.audioSlideSince = nil
				end
				local slideCutsPower = slideAmount > 0.05 and CurTime() - vehicle.audioSlideSince < traction.slideMaxTime
				if slideCutsPower then
					targetPower = tractionPower - traction.slideCut * slideAmount * deltaTime
					powerFloor = math.min(powerFloor, vehicle.audioOverRotating == false and traction.slideTurnFloor or traction.slideFloor)
				elseif wheelSlip > traction.slip then targetPower = tractionPower - traction.cut * deltaTime
				else targetPower = tractionPower + traction.restore * deltaTime end
				targetPower = math.Clamp(targetPower, math.min(powerFloor, tractionPower), 1)
			else
				targetPower = 1
				vehicle.audioSlideSince = nil
			end
			-- speed limiter (sv_cruise.lua): W held near the limit, the power trimmed to hold it;
			-- over it, off (it brakes there too)
			local limiterPower
			if vehicle.audioSpeedLimit then
				local limiterConfig, mph = AudioEngine.CRUISE, speed * 2.23694
				-- the car's acceleration (mph/s, smoothed)
				local acceleration = vehicle.audioLimiterLastMph and (mph - vehicle.audioLimiterLastMph) / deltaTime or 0
				vehicle.audioLimiterAcceleration = (vehicle.audioLimiterAcceleration or 0) + (acceleration - (vehicle.audioLimiterAcceleration or 0)) * math.min(1, deltaTime * 10)
				vehicle.audioLimiterLastMph = mph
				if vehicle.audioLimiterBraking then
					limiterPower = limiterConfig.minPower
				elseif vehicle.audioLimiterHolding then
					-- the acceleration it wants shrinks to nothing at the limit; the power follows
					local wantedAcceleration = limiterConfig.accelerationGain * (vehicle.audioSpeedLimit - mph)
					local powerChange = limiterConfig.powerGain * (wantedAcceleration - vehicle.audioLimiterAcceleration) * deltaTime
					vehicle.audioLimiterHoldPower = math.Clamp((vehicle.audioLimiterHoldPower or 1) + powerChange, limiterConfig.minPower, 1)
					limiterPower = vehicle.audioLimiterHoldPower
				end
			else
				vehicle.audioLimiterLastMph, vehicle.audioLimiterAcceleration = nil, nil
			end
			local limiterStep = vehicle.audioSpeedLimit and AudioEngine.CRUISE.powerStep or traction.step
			if math.abs((limiterPower or 1) - (vehicle.audioLimiterPowerSent or 1)) >= limiterStep or (limiterPower == nil and vehicle.audioLimiterPowerSent ~= nil) then
				vehicle.audioLimiterPowerSent = limiterPower
				vehicle.audioParamsDirty = true
			end
			vehicle.audioLimiterPower = limiterPower
			-- params are re-sent only on a real change (and always when it's back to full)
			if math.abs(targetPower - (vehicle.audioTractionPowerSent or 1)) >= traction.step or (targetPower == 1 and (vehicle.audioTractionPowerSent or 1) ~= 1) then
				vehicle.audioTractionPowerSent = targetPower
				vehicle.audioParamsDirty = true
			end
			vehicle.audioTractionPower = targetPower
			if vehicle.audioParamsDirty then
				vehicle.audioParamsDirty = false
				AudioEngine.ApplyPerformance(vehicle, profileOf(vehicle))
			end
		end
	end
end)

-- audio_engine_accel_log [seconds]: logs the car you drive to the console 4x a second (admins).
-- Source's own gear and rpm (GetOperatingParams) next to speed, wheel slip, traction trim and the
-- steering scale: shows where a car's acceleration goes during a launch.
concommand.Add("audio_engine_accel_log", function(player, _, args)
	if IsValid(player) and not player:IsAdmin() then return end
	local vehicle = IsValid(player) and player:GetVehicle()
	if not IsValid(vehicle) then return end
	local seconds = math.Clamp(tonumber(args[1]) or 12, 1, 60)
	local startTime = CurTime()
	local function printLine(line) if IsValid(player) then player:PrintMessage(HUD_PRINTCONSOLE, line) end end
	printLine("[Audio Engine] accel log: t | mph | Source gear, rpm | wheel slip | slide | power x | steer x | wheel angle deg"
		.. " | yaw off what's asked deg/s, slip angle deg")
	local timerId = "audio_engine_accel_log_" .. vehicle:EntIndex()
	-- calibration for the acceleration model (sh_presets.lua AudioEngine.GEAR_ACCEL): the time to each share of the
	-- top speed, next to the model's. Start from a standstill and hold W on a straight road
	local topKmh = AudioEngine.CarTopSpeed(vehicle, AudioEngine.GetCarConfig(vehicle))
	local powerToWeight = AudioEngine.CarPower(vehicle, AudioEngine.GetCarConfig(vehicle)) * ((AudioEngine.DecodeProfile(vehicle:GetNW2String("audio_prof", "")) or {}).accel or 1)
	local marks, reached, setOffTime = { 0.25, 0.5, 0.75, 0.9, 0.95 }, {}, nil
	local function report()
		local parts = {}
		for _, mark in ipairs(marks) do
			parts[#parts + 1] = string.format("%d%% %s (model %.1f)", mark * 100,
				reached[mark] and string.format("%.1fs", reached[mark]) or "-", AudioEngine.GearModelTime(topKmh, powerToWeight, mark))
		end
		printLine(string.format("[Audio Engine] top %.0f mph, %.0f W/kg: time to share of top speed: %s",
			topKmh / 1.609344, powerToWeight, table.concat(parts, ", ")))
	end
	local config = AudioEngine.GetEngineConfig(vehicle)
	if config and config.gears and config.final then
		local redlineSpeeds, rpmPerSpeed = {}, 60 / (2 * math.pi * (config.wheelRadius or 0.33))
		for i, gearRatio in ipairs(config.gears) do redlineSpeeds[i] = string.format("%.0f", config.redline / (rpmPerSpeed * gearRatio * config.final) * 2.23694) end
		printLine("[Audio Engine] sound gears reach redline at " .. table.concat(redlineSpeeds, " / ") .. " mph")
	end
	local ticks = math.floor(seconds * 4)
	timer.Create(timerId, 0.25, ticks, function()
		if not IsValid(vehicle) then timer.Remove(timerId) return end
		local physics = vehicle:GetPhysicsObject()
		local mph = IsValid(physics) and physics:GetVelocity():Length() * 0.0254 * 2.23694 or 0
		if not setOffTime and mph > 0.5 then setOffTime = CurTime() - 0.125 end   -- (it set off within the last sample)
		if setOffTime then
			for _, mark in ipairs(marks) do
				if not reached[mark] and mph * 1.609344 >= topKmh * mark then reached[mark] = CurTime() - setOffTime end
			end
		end
		ticks = ticks - 1
		if ticks <= 0 or reached[0.95] then timer.Remove(timerId) report() end
		local gotParams, operatingParams = pcall(vehicle.GetOperatingParams, vehicle)
		operatingParams = gotParams and istable(operatingParams) and operatingParams or {}
		local holdColumns = vehicle.audioLogYawError and string.format(" | %5.1f %5.1f", vehicle.audioLogYawError, vehicle.audioLogSlipAngle) or ""
		printLine(string.format("  %5.2fs | %5.1f | G%s %5.0f | %5.2f | %.2f | %.2f | %.2f | %5.1f%s", CurTime() - startTime, mph,
			tostring(operatingParams.gear or "?"), operatingParams.RPM or 0, vehicle.audioWheelSlip or 0, vehicle.audioSlideAmount or 0, vehicle.audioTractionPower or 1,
			vehicle.audioSteerLockScale or 1, operatingParams.steeringAngle or 0, holdColumns))
	end)
end, nil, "Log speed, Source gear/rpm, wheel slip and traction trim of the car you drive (admins)")

-- what the car you look at got: audio_engine_handling_info
concommand.Add("audio_engine_handling_info", function(player)
	if IsValid(player) and not player:IsAdmin() then return end
	local vehicle = IsValid(player) and player:GetVehicle()
	if IsValid(player) and not IsValid(vehicle) then vehicle = player:GetEyeTrace().Entity end
	local function printLine(line) if IsValid(player) then player:PrintMessage(HUD_PRINTCONSOLE, line) else print(line) end end
	if not IsValid(vehicle) or not vehicle:IsVehicle() then printLine("[Audio Engine] look at or sit in a car") return end
	local carConfig = AudioEngine.GetCarConfig(vehicle)
	local succeeded, params = pcall(vehicle.GetVehicleParams, vehicle)
	printLine(string.format("[Audio Engine] %s | script %s | PERP physics %s | anti-spin %s | spiked %s | stability %s",
		carConfig and carConfig.name or vehicle:GetModel(), tostring(vehicle.audioScript), tostring(vehicle.audioPerpPhysics or false),
		tostring(vehicle.audioAntiSpin or false), tostring(vehicle.audioSpiked or false),
		tostring(carConfig ~= nil and carConfig.stability ~= false and not vehicle.audioSpiked)))
	if succeeded and istable(params) and params.engine then
		local frontAxle, rearAxle = params.axles and params.axles[1] or {}, params.axles and params.axles[2] or {}
		local physics = vehicle:GetPhysicsObject()
		printLine(string.format("  traction control: power x%.2f, last wheel slip %.2f", vehicle.audioTractionPower or 1, vehicle.audioWheelSlip or 0))
		printLine(string.format("  %.0f hp, top %.0f mph, mass %.0f kg, brakes %.2f/%.2f, torque %.2f/%.2f, grip x%.2f, centre %s",
			params.engine.horsepower or 0, (params.engine.maxSpeed or 0) / HU_PER_MPH, IsValid(physics) and physics:GetMass() or 0,
			frontAxle.brakeFactor or 0, rearAxle.brakeFactor or 0, frontAxle.torqueFactor or 0, rearAxle.torqueFactor or 0,
			params.body and params.body.addGravity or 0, tostring(params.body and params.body.massCenterOverride)))
	end
end, nil, "Print the handling setup of the car you're in or looking at (admins)")
